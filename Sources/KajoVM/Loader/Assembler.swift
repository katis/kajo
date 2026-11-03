/// A literal of an assembled method, resolved to an object at load time.
enum Literal: Hashable, Sendable {
    case integer(Int64)
    /// Beyond the SmallInteger range: a LargePositiveInteger or
    /// LargeNegativeInteger, magnitude little-endian.
    case largeInteger(negative: Bool, magnitude: [UInt8])
    /// A double's bits: a SmallFloat when it fits, else a boxed Float.
    case float(UInt64)
    case character(UInt32)
    /// UTF-8 bytes of a String literal (read-only in the image).
    case string([UInt8])
    case symbol(String)
    case classRef(String)
    case nilObject
    case trueObject
    case falseObject
    /// Block method `k` of the method's `blocks`.
    case block(Int)
    /// Pragma `k` of the method's `pragmas`.
    case pragma(Int)
}

struct AssembledPragma {
    let selector: String
    let arguments: [Literal]
}

/// A method or a block method as bytes and a literal frame, verified, not
/// yet in the heap.
struct AssembledMethod {
    let file: String
    let line: Int
    let className: String
    /// A method of the class's metaclass.
    let classSide: Bool
    /// The selector; a block's name for a block method.
    let selector: String
    let argc: Int
    /// Frame words between the arguments and the header (`MethodLayout.temps`).
    let temps: Int
    let primitive: Int
    let bytecodes: [UInt8]
    let literals: [Literal]
    let maxStack: Int
    /// Highest and lowest receiver slot any push_ivar or store_ivar names, or -1.
    let maxIvar: Int
    let minIvar: Int
    let flags: Int64
    let copied: Int
    /// The method's block methods (empty in a block), each referenced by
    /// one `.block(k)` literal of the method or another block.
    let blocks: [AssembledMethod]
    let pragmas: [AssembledPragma]

    var isBlock: Bool { flags & MethodFlags.block != 0 }
}

/// Assemble one parsed method and its blocks: resolve labels, build each
/// literal frame in first-use order with duplicates merged (block methods
/// and pragmas are literals too), encode with the `ext` prefix where an
/// operand does not fit a byte, and run the bytecode verifier
/// (`verifyBytecodes`) on every body. Everything the interpreter trusts
/// about the bytecodes is established there.
func assemble(_ m: KasmMethod, limits: LoaderLimits = LoaderLimits()) throws(LoadError) -> AssembledMethod {
    let argc = arity(of: m.selector)
    func fail(_ kind: LoadError.Kind, _ msg: String, _ line: Int) -> LoadError {
        LoadError(kind, "\(m.className)>>\(m.selector): \(msg)", file: m.file, line: line)
    }
    if m.body.isEmpty && m.primitive == 0 { throw fail(.emptyMethod, "no bytecodes and no primitive", m.line) }
    if !m.blocks.isEmpty && m.body.isEmpty { throw fail(.emptyMethod, "blocks in a method with no bytecodes", m.line) }

    // Blocks: names, references, reachability, and which need a home.
    var blockIndex: [String: Int] = [:]
    for (k, b) in m.blocks.enumerated() { blockIndex[b.name] = k }
    func references(_ body: [KasmLine]) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for l in body {
            if case .instruction("push_closure", let args) = l.content, let n = args.first, let k = blockIndex[n] {
                out.append((k, l.line))
            }
        }
        return out
    }
    var refCount = [Int](repeating: 0, count: m.blocks.count)
    for (k, _) in references(m.body) { refCount[k] += 1 }
    for b in m.blocks { for (k, line) in references(b.body) {
        if b.name == m.blocks[k].name { throw fail(.badOperand, "block \(b.name) creates itself", line) }
        refCount[k] += 1
    } }
    for (k, b) in m.blocks.enumerated() where refCount[k] != 1 {
        throw fail(.badOperand, "block \(b.name) is created by \(refCount[k]) push_closure instructions (one wanted)", b.line)
    }
    var reached = Set<Int>()
    var queue = references(m.body).map(\.0)
    while let k = queue.popLast() {
        if !reached.insert(k).inserted { continue }
        queue += references(m.blocks[k].body).map(\.0)
    }
    if let k = (0..<m.blocks.count).first(where: { !reached.contains($0) }) {
        throw fail(.badOperand, "block \(m.blocks[k].name) is not reachable from the method", m.blocks[k].line)
    }
    var needsHome = [Bool](repeating: false, count: m.blocks.count)
    var changed = true
    while changed {
        changed = false
        for (k, b) in m.blocks.enumerated() where !needsHome[k] {
            let direct = b.body.contains { if case .instruction("nonlocal_return", _) = $0.content { return true }; return false }
            if direct || references(b.body).contains(where: { needsHome[$0.0] }) {
                needsHome[k] = true
                changed = true
            }
        }
    }

    // Pragmas.
    var pragmas: [AssembledPragma] = []
    for p in m.pragmas {
        if arity(of: p.selector) != p.arguments.count {
            throw fail(.badOperand, "pragma \(p.selector) takes \(arity(of: p.selector)) argument(s)", p.line)
        }
        var args: [Literal] = []
        for a in p.arguments {
            guard let l = parseLiteral(a) else { throw fail(.badOperand, "bad pragma argument '\(a)'", p.line) }
            args.append(l)
        }
        pragmas.append(AssembledPragma(selector: p.selector, arguments: args))
    }

    struct Body {
        let lines: [KasmLine]
        let argc: Int
        let addressable: Int
        let isBlock: Bool
        let needsHome: Bool
        let line: Int
        let name: String
    }
    func assembleBody(_ b: Body, extraLiterals: [Literal]) throws(LoadError) -> (bytes: [UInt8], literals: [Literal], maxStack: Int,
                                                                              maxIvar: Int, minIvar: Int) {
        struct Ins {
            let op: Opcode
            let args: [String]
            let line: Int
            var a = 0
            var b = 0
            var label: String? = nil
        }
        var ins: [Ins] = []
        var labels: [String: Int] = [:]
        for l in b.lines {
            switch l.content {
            case .label(let name):
                if labels[name] != nil { throw fail(.duplicateLabel, "label '\(name)' defined twice", l.line) }
                labels[name] = ins.count
            case .instruction(let name, let args):
                guard let op = Opcode(mnemonic: name), op != .ext else {
                    throw fail(.unknownOpcode, "unknown instruction '\(name)'", l.line)
                }
                ins.append(Ins(op: op, args: args, line: l.line))
            }
        }
        var literals: [Literal] = []
        var literalIndex: [Literal: Int] = [:]
        func literal(_ lit: Literal, _ line: Int) throws(LoadError) -> Int {
            if let i = literalIndex[lit] { return i }
            if literals.count == limits.maxLiterals { throw fail(.tooManyLiterals, "more than \(limits.maxLiterals) literals", line) }
            literalIndex[lit] = literals.count
            literals.append(lit)
            return literals.count - 1
        }
        var maxIvar = -1, minIvar = -1
        for k in ins.indices {
            let i = ins[k]
            let expected: Int
            switch i.op.operands {
            case .none, .prefix: expected = 0
            case .index, .int8, .jump: expected = 1
            case .send, .closure, .vectorSlot: expected = 2
            }
            if i.args.count != expected { throw fail(.badOperand, "\(i.op.mnemonic) takes \(expected) operand(s)", i.line) }
            func int(_ s: String, _ range: ClosedRange<Int>, _ what: String) throws(LoadError) -> Int {
                guard let n = Int(s), range.contains(n) else {
                    throw fail(.badOperand, "\(what) must be \(range.lowerBound)...\(range.upperBound)", i.line)
                }
                return n
            }
            switch i.op {
            case .pushLiteral:
                guard let lit = parseLiteral(i.args[0]) else { throw fail(.badOperand, "bad literal '\(i.args[0])'", i.line) }
                ins[k].a = try literal(lit, i.line)
            case .pushTemp, .storeTemp:
                ins[k].a = try int(i.args[0], 0...max(0, b.addressable - 1), "temp index")
                if b.addressable == 0 { throw fail(.badOperand, "no temps to name", i.line) }
            case .pushIvar, .storeIvar:
                let n = try int(i.args[0], 0...(Header.maxSlots - 1), "slot index")
                maxIvar = max(maxIvar, n)
                minIvar = minIvar < 0 ? n : min(minIvar, n)
                ins[k].a = n
            case .pushInt:
                ins[k].a = try int(i.args[0], -128...127, "push_int's operand")
            case .send, .sendSuper:
                let sel = i.args[0]
                guard isSelector(sel) else { throw fail(.badOperand, "bad selector '\(sel)'", i.line) }
                guard let n = Int(i.args[1]), n == arity(of: sel) else {
                    throw fail(.badOperand, "\(sel) takes \(arity(of: sel)) argument(s)", i.line)
                }
                ins[k].a = try literal(.symbol(sel), i.line)
                ins[k].b = n
            case .pushClosure:
                guard let bk = blockIndex[i.args[0]] else { throw fail(.badOperand, "no block '\(i.args[0])'", i.line) }
                guard let c = Int(i.args[1]), c == m.blocks[bk].copied else {
                    throw fail(.badOperand, "block \(i.args[0]) has \(m.blocks[bk].copied) copied value(s)", i.line)
                }
                ins[k].a = try literal(.block(bk), i.line)
                ins[k].b = c
            case .pushNewArray:
                ins[k].a = try int(i.args[0], 0...Header.maxSlots, "push_new_array's size")
            case .pushTempVectorSlot, .storeTempVectorSlot:
                ins[k].a = try int(i.args[0], 0...(Header.maxSlots - 1), "temp vector slot")
                ins[k].b = try int(i.args[1], 0...max(0, b.addressable - 1), "temp index")
                if b.addressable == 0 { throw fail(.badOperand, "no temps to name", i.line) }
            case .jump, .jumpIfTrue, .jumpIfFalse:
                guard let t = labels[i.args[0]] else { throw fail(.unknownLabel, "no label '\(i.args[0])'", i.line) }
                guard t < ins.count else { throw fail(.badStack, "label '\(i.args[0])' is past the last instruction", i.line) }
                ins[k].label = i.args[0]
            default:
                break
            }
        }
        for l in extraLiterals { _ = try literal(l, b.line) }
        // Lengths (with prefixes), then offsets, then bytes.
        var offsets = [Int](repeating: 0, count: ins.count + 1)
        for (k, i) in ins.enumerated() {
            let wide = i.op.isExtensible && i.op.operands != .int8 && i.a > 255
            offsets[k + 1] = offsets[k] + i.op.length + (wide ? 2 : 0)
            if offsets[k + 1] > limits.maxMethodBytes {
                throw fail(.methodTooLarge, "more than \(limits.maxMethodBytes) bytes of bytecode", i.line)
            }
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(offsets[ins.count])
        for (k, i) in ins.enumerated() {
            var a = i.a
            if i.op.isExtensible && a > 255 {
                if a > 0xFFFF { throw fail(.badOperand, "operand \(a) exceeds 65535", i.line) }
                bytes.append(Opcode.ext.rawValue)
                bytes.append(UInt8(a >> 8))
                a &= 0xFF
            }
            bytes.append(i.op.rawValue)
            switch i.op.operands {
            case .none, .prefix: break
            case .index: bytes.append(UInt8(a))
            case .int8: bytes.append(UInt8(bitPattern: Int8(a)))
            case .send, .closure, .vectorSlot:
                bytes.append(UInt8(a))
                bytes.append(UInt8(i.b))
            case .jump:
                let rel = offsets[labels[i.label!]!] - offsets[k + 1]
                guard rel >= Int(Int16.min), rel <= Int(Int16.max) else { throw fail(.badOperand, "jump too far", i.line) }
                let (lo, hi) = OperandDecoding.encodeJump(rel)
                bytes.append(lo)
                bytes.append(hi)
            }
        }
        let shape = CodeShape(argc: b.argc, addressableTemps: b.addressable, literalCount: literals.count, isBlock: b.isBlock,
                              needsHome: b.needsHome, ivarRange: 0..<Header.maxSlots, maxStackLimit: limits.maxStack)
        let lits = literals
        do {
            let v = try verifyBytecodes(bytes, shape) { k in
                switch lits[k] {
                case .symbol(let s): return .selector(arity: arity(of: s))
                case .block(let j): return .block(args: m.blocks[j].args, copied: m.blocks[j].copied, needsHome: needsHome[j])
                default: return .other
                }
            }
            return (bytes, literals, v.maxStack, maxIvar, minIvar)
        } catch {
            let k = offsets.firstIndex(of: error.offset) ?? -1
            let line = k >= 0 && k < ins.count ? ins[k].line : (ins.last?.line ?? b.line)
            throw fail(error.kind, "\(b.isBlock ? "block \(b.name): " : "")\(error.message)", line)
        }
    }

    var blocks: [AssembledMethod] = []
    for (k, b) in m.blocks.enumerated() {
        let r = try assembleBody(Body(lines: b.body, argc: b.args, addressable: b.args + b.copied + b.temps, isBlock: true,
                                      needsHome: needsHome[k], line: b.line, name: b.name), extraLiterals: [])
        if r.bytes.isEmpty { throw fail(.emptyMethod, "block \(b.name) has no bytecodes", b.line) }
        blocks.append(AssembledMethod(file: m.file, line: b.line, className: m.className, classSide: m.classSide,
                                      selector: b.name, argc: b.args, temps: b.copied + b.temps + 1, primitive: 0,
                                      bytecodes: r.bytes, literals: r.literals, maxStack: r.maxStack, maxIvar: r.maxIvar,
                                      minIvar: r.minIvar,
                                      flags: MethodFlags.block | (needsHome[k] ? MethodFlags.needsHome : 0), copied: b.copied,
                                      blocks: [], pragmas: []))
    }
    let r = try assembleBody(Body(lines: m.body, argc: argc, addressable: argc + m.temps, isBlock: false, needsHome: false,
                                  line: m.line, name: m.selector),
                             extraLiterals: (0..<pragmas.count).map { .pragma($0) })
    var maxIvar = r.maxIvar, minIvar = r.minIvar
    for b in blocks where b.maxIvar >= 0 {
        maxIvar = max(maxIvar, b.maxIvar)
        minIvar = minIvar < 0 ? b.minIvar : min(minIvar, b.minIvar)
    }
    let flags = (m.unwind ? MethodFlags.unwind : 0) | (m.handler ? MethodFlags.handler : 0)
    return AssembledMethod(file: m.file, line: m.line, className: m.className, classSide: m.classSide, selector: m.selector,
                           argc: argc, temps: m.temps, primitive: m.primitive, bytecodes: r.bytes, literals: r.literals,
                           maxStack: r.maxStack, maxIvar: maxIvar, minIvar: minIvar, flags: flags, copied: 0, blocks: blocks,
                           pragmas: pragmas)
}

/// Integers (SmallInteger, else Large), floats, `$c` and `$U+hex`
/// characters, `'strings'`, `#selector`, `@ClassName`, nil, true, false.
func parseLiteral(_ s: String) -> Literal? {
    switch s {
    case "nil": return .nilObject
    case "true": return .trueObject
    case "false": return .falseObject
    default: break
    }
    if s.hasPrefix("#") {
        let sel = String(s.dropFirst())
        return isSelector(sel) ? .symbol(sel) : nil
    }
    if s.hasPrefix("@") {
        let name = String(s.dropFirst())
        return isIdentifier(name) ? .classRef(name) : nil
    }
    if s.hasPrefix("'") {
        let b = Array(s.utf8)
        guard b.count >= 2, b.last == 39 else { return nil }
        var out: [UInt8] = []
        var i = 1
        while i < b.count - 1 {
            if b[i] == 39 {
                guard i + 1 < b.count - 1, b[i + 1] == 39 else { return nil }
                i += 1
            }
            out.append(b[i])
            i += 1
        }
        return .string(out)
    }
    if s.hasPrefix("$") {
        let rest = s.dropFirst()
        if rest.hasPrefix("U+"), rest.count > 2, let v = UInt32(rest.dropFirst(2), radix: 16), Oop.isScalar(UInt64(v)) {
            return .character(v)
        }
        let scalars = Array(rest.unicodeScalars)
        return scalars.count == 1 ? .character(scalars[0].value) : nil
    }
    if let v = Int64(s) { return Oop.fitsSmallInteger(v) ? .integer(v) : .largeInteger(negative: v < 0, magnitude: magnitudeBytes(v.magnitude)) }
    if s.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) {
        guard s.first.map({ $0.isNumber || $0 == "-" }) == true, let d = Double(s), d.isFinite else { return nil }
        return .float(d.bitPattern)
    }
    var digits = Substring(s)
    let negative = digits.hasPrefix("-")
    if negative { digits = digits.dropFirst() }
    guard !digits.isEmpty, digits.utf8.count <= 2000, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
    var mag: [UInt8] = []  // little-endian base 256
    for c in digits.utf8 {
        var carry = Int(c - 48)
        for i in mag.indices {
            let x = Int(mag[i]) * 10 + carry
            mag[i] = UInt8(x & 0xFF)
            carry = x >> 8
        }
        while carry > 0 {
            mag.append(UInt8(carry & 0xFF))
            carry >>= 8
        }
    }
    while mag.last == 0 { mag.removeLast() }
    if mag.isEmpty { return .integer(0) }
    return .largeInteger(negative: negative, magnitude: mag)
}

/// Little-endian bytes of a magnitude, no leading zeros.
func magnitudeBytes(_ v: UInt64) -> [UInt8] {
    var out: [UInt8] = []
    var x = v
    while x != 0 {
        out.append(UInt8(x & 0xFF))
        x >>= 8
    }
    return out
}
