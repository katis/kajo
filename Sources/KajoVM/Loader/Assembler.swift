/// A literal of an assembled method, resolved to an object at load time.
package enum Literal: Hashable, Sendable {
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
    /// Module 8b: a literal Array (`#(1 $a 'b' #c (2 3))`), read-only with
    /// its elements, and a literal ByteArray (`#[1 2 3]`).
    case array([Literal])
    case byteArray([UInt8])
    /// Module 8d: the Binding of class variable `name` declared by class
    /// `owner` (the image build's class pools). Not in kasm.
    case binding(owner: String, name: String)
}

package struct AssembledPragma: Sendable {
    package let selector: String
    package let arguments: [Literal]
}

/// A method or a block method as bytes and a literal frame, verified, not
/// yet in the heap.
package struct AssembledMethod: Sendable {
    package let file: String
    package let line: Int
    package let className: String
    /// A method of the class's metaclass.
    package let classSide: Bool
    /// The selector; a block's name for a block method.
    package let selector: String
    package let argc: Int
    /// Frame words between the arguments and the header (`MethodLayout.temps`).
    package let temps: Int
    package let primitive: Int
    package let bytecodes: [UInt8]
    package let literals: [Literal]
    package let maxStack: Int
    /// Highest and lowest receiver slot any push_ivar or store_ivar names, or -1.
    package let maxIvar: Int
    package let minIvar: Int
    package let flags: Int64
    package let copied: Int
    /// The method's block methods (empty in a block), each referenced by
    /// one `.block(k)` literal of the method or another block.
    package let blocks: [AssembledMethod]
    package let pragmas: [AssembledPragma]

    package var isBlock: Bool { flags & MethodFlags.block != 0 }
}

/// One line of an assembler body: what the kasm parser's text lowers to,
/// and what the bootstrap compiler (`KajoCompiler`) emits directly. Operands
/// are values, not text; labels are names local to the body.
package struct AsmLine: Sendable {
    package enum Content: Sendable {
        case label(String)
        /// Any opcode whose operands are plain numbers: none, an index, a
        /// signed byte, a vector slot and temp, `push_new_array`'s size.
        case op(Opcode, Int, Int)
        case pushLiteral(Literal)
        /// `send` or `send_super`: the selector and its argument count.
        case send(Opcode, String, Int)
        /// A block of the method by name, and its copied-value count.
        case pushClosure(String, Int)
        /// `jump`, `jump_if_true` or `jump_if_false` to a label.
        case jump(Opcode, String)
        /// Module 9b: the source range (byte offsets in the method's
        /// recorded source, start inclusive, end exclusive) of the next
        /// instruction, a send. Emits nothing; the assembler records the
        /// instruction's pc and the range in the method's source map
        /// (`SourceMap`), the last literal, and sets `MethodFlags.sourceMap`.
        case source(Int, Int)
    }

    package let line: Int
    package let content: Content

    package init(_ content: Content, line: Int) {
        self.content = content
        self.line = line
    }
}

/// A block method of an `AsmMethod`: made by exactly one `push_closure`.
package struct AsmBlock: Sendable {
    package let name: String
    package let line: Int
    package let args: Int
    package let copied: Int
    package let temps: Int
    package var body: [AsmLine]

    package init(name: String, line: Int, args: Int, copied: Int, temps: Int, body: [AsmLine]) {
        self.name = name
        self.line = line
        self.args = args
        self.copied = copied
        self.temps = temps
        self.body = body
    }
}

/// A method for the assembler: kasm lowered, or the bootstrap compiler's
/// output.
package struct AsmMethod: Sendable {
    package var file: String
    package var line: Int
    package var className: String
    package var selector: String
    package var temps: Int
    package var primitive: Int
    package var classSide = false
    package var unwind = false
    package var handler = false
    /// Selector, arguments and source line of each pragma.
    package var pragmas: [(selector: String, arguments: [Literal], line: Int)] = []
    package var body: [AsmLine] = []
    package var blocks: [AsmBlock] = []

    package init(file: String, line: Int, className: String, selector: String, temps: Int, primitive: Int) {
        self.file = file
        self.line = line
        self.className = className
        self.selector = selector
        self.temps = temps
        self.primitive = primitive
    }
}

/// Lower a parsed kasm method to the assembler's input: opcodes by
/// mnemonic, operands parsed and range-checked against the body's shape.
func lower(_ m: KasmMethod, limits: LoaderLimits = LoaderLimits()) throws(LoadError) -> AsmMethod {
    let argc = arity(of: m.selector)
    func fail(_ kind: LoadError.Kind, _ msg: String, _ line: Int) -> LoadError {
        LoadError(kind, "\(m.className)>>\(m.selector): \(msg)", file: m.file, line: line)
    }
    var blockIndex: [String: Int] = [:]
    for (k, b) in m.blocks.enumerated() { blockIndex[b.name] = k }
    func lowerBody(_ lines: [KasmLine], addressable: Int) throws(LoadError) -> [AsmLine] {
        var out: [AsmLine] = []
        for l in lines {
            switch l.content {
            case .label(let name):
                out.append(AsmLine(.label(name), line: l.line))
            case .instruction(let name, let args):
                guard let op = Opcode(mnemonic: name), op != .ext else {
                    throw fail(.unknownOpcode, "unknown instruction '\(name)'", l.line)
                }
                let expected: Int
                switch op.operands {
                case .none, .prefix: expected = 0
                case .index, .int8, .jump: expected = 1
                case .send, .closure, .vectorSlot: expected = 2
                }
                if args.count != expected { throw fail(.badOperand, "\(op.mnemonic) takes \(expected) operand(s)", l.line) }
                func int(_ s: String, _ range: ClosedRange<Int>, _ what: String) throws(LoadError) -> Int {
                    guard let n = Int(s), range.contains(n) else {
                        throw fail(.badOperand, "\(what) must be \(range.lowerBound)...\(range.upperBound)", l.line)
                    }
                    return n
                }
                let c: AsmLine.Content
                switch op {
                case .pushLiteral:
                    guard let lit = parseLiteral(args[0]) else { throw fail(.badOperand, "bad literal '\(args[0])'", l.line) }
                    c = .pushLiteral(lit)
                case .pushTemp, .storeTemp:
                    let n = try int(args[0], 0...max(0, addressable - 1), "temp index")
                    if addressable == 0 { throw fail(.badOperand, "no temps to name", l.line) }
                    c = .op(op, n, 0)
                case .pushIvar, .storeIvar:
                    c = .op(op, try int(args[0], 0...(Header.maxSlots - 1), "slot index"), 0)
                case .pushInt:
                    c = .op(op, try int(args[0], -128...127, "push_int's operand"), 0)
                case .send, .sendSuper:
                    let sel = args[0]
                    guard isSelector(sel) else { throw fail(.badOperand, "bad selector '\(sel)'", l.line) }
                    guard let n = Int(args[1]), n == arity(of: sel) else {
                        throw fail(.badOperand, "\(sel) takes \(arity(of: sel)) argument(s)", l.line)
                    }
                    c = .send(op, sel, n)
                case .pushClosure:
                    guard let bk = blockIndex[args[0]] else { throw fail(.badOperand, "no block '\(args[0])'", l.line) }
                    guard let n = Int(args[1]), n == m.blocks[bk].copied else {
                        throw fail(.badOperand, "block \(args[0]) has \(m.blocks[bk].copied) copied value(s)", l.line)
                    }
                    c = .pushClosure(args[0], n)
                case .pushNewArray:
                    c = .op(op, try int(args[0], 0...Header.maxSlots, "push_new_array's size"), 0)
                case .pushTempVectorSlot, .storeTempVectorSlot:
                    let slot = try int(args[0], 0...(Header.maxSlots - 1), "temp vector slot")
                    let t = try int(args[1], 0...max(0, addressable - 1), "temp index")
                    if addressable == 0 { throw fail(.badOperand, "no temps to name", l.line) }
                    c = .op(op, slot, t)
                case .jump, .jumpIfTrue, .jumpIfFalse:
                    c = .jump(op, args[0])
                default:
                    c = .op(op, 0, 0)
                }
                out.append(AsmLine(c, line: l.line))
            }
        }
        return out
    }
    var a = AsmMethod(file: m.file, line: m.line, className: m.className, selector: m.selector, temps: m.temps,
                      primitive: m.primitive)
    a.classSide = m.classSide
    a.unwind = m.unwind
    a.handler = m.handler
    a.body = try lowerBody(m.body, addressable: argc + m.temps)
    for b in m.blocks {
        a.blocks.append(AsmBlock(name: b.name, line: b.line, args: b.args, copied: b.copied, temps: b.temps,
                                 body: try lowerBody(b.body, addressable: b.args + b.copied + b.temps)))
    }
    for p in m.pragmas {
        if arity(of: p.selector) != p.arguments.count {
            throw fail(.badOperand, "pragma \(p.selector) takes \(arity(of: p.selector)) argument(s)", p.line)
        }
        var args: [Literal] = []
        for x in p.arguments {
            guard let l = parseLiteral(x) else { throw fail(.badOperand, "bad pragma argument '\(x)'", p.line) }
            args.append(l)
        }
        a.pragmas.append((p.selector, args, p.line))
    }
    return a
}

/// Assemble one parsed kasm method and its blocks.
func assemble(_ m: KasmMethod, limits: LoaderLimits = LoaderLimits()) throws(LoadError) -> AssembledMethod {
    try assemble(try lower(m, limits: limits), limits: limits)
}

/// Assemble one method and its blocks: resolve labels, build each literal
/// frame in first-use order with duplicates merged (block methods and
/// pragmas are literals too, pragmas after every other literal), encode
/// with the `ext` prefix where an operand does not fit a byte, and run the
/// bytecode verifier (`verifyBytecodes`) on every body. Everything the
/// interpreter trusts about the bytecodes is established there. The kasm
/// loader and the bootstrap compiler both come through here.
package func assemble(_ m: AsmMethod, limits: LoaderLimits = LoaderLimits()) throws(LoadError) -> AssembledMethod {
    let argc = arity(of: m.selector)
    func fail(_ kind: LoadError.Kind, _ msg: String, _ line: Int) -> LoadError {
        LoadError(kind, "\(m.className)>>\(m.selector): \(msg)", file: m.file, line: line)
    }
    if m.body.isEmpty && m.primitive == 0 { throw fail(.emptyMethod, "no bytecodes and no primitive", m.line) }
    if !m.blocks.isEmpty && m.body.isEmpty { throw fail(.emptyMethod, "blocks in a method with no bytecodes", m.line) }

    // Blocks: names, references, reachability, and which need a home.
    var blockIndex: [String: Int] = [:]
    for (k, b) in m.blocks.enumerated() {
        if blockIndex[b.name] != nil { throw fail(.duplicateLabel, "block '\(b.name)' defined twice", b.line) }
        blockIndex[b.name] = k
    }
    func references(_ body: [AsmLine]) throws(LoadError) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for l in body {
            if case .pushClosure(let n, let c) = l.content {
                guard let k = blockIndex[n] else { throw fail(.badOperand, "no block '\(n)'", l.line) }
                if c != m.blocks[k].copied { throw fail(.badOperand, "block \(n) has \(m.blocks[k].copied) copied value(s)", l.line) }
                out.append((k, l.line))
            }
        }
        return out
    }
    var refCount = [Int](repeating: 0, count: m.blocks.count)
    for (k, _) in try references(m.body) { refCount[k] += 1 }
    var blockRefs: [[Int]] = []
    for b in m.blocks {
        var mine: [Int] = []
        for (k, line) in try references(b.body) {
            if b.name == m.blocks[k].name { throw fail(.badOperand, "block \(b.name) creates itself", line) }
            refCount[k] += 1
            mine.append(k)
        }
        blockRefs.append(mine)
    }
    for (k, b) in m.blocks.enumerated() where refCount[k] != 1 {
        throw fail(.badOperand, "block \(b.name) is created by \(refCount[k]) push_closure instructions (one wanted)", b.line)
    }
    var reached = Set<Int>()
    var queue = try references(m.body).map(\.0)
    while let k = queue.popLast() {
        if !reached.insert(k).inserted { continue }
        queue += blockRefs[k]
    }
    if let k = (0..<m.blocks.count).first(where: { !reached.contains($0) }) {
        throw fail(.badOperand, "block \(m.blocks[k].name) is not reachable from the method", m.blocks[k].line)
    }
    var needsHome = [Bool](repeating: false, count: m.blocks.count)
    var changed = true
    while changed {
        changed = false
        for (k, b) in m.blocks.enumerated() where !needsHome[k] {
            let direct = b.body.contains { if case .op(.nonlocalReturn, _, _) = $0.content { return true }; return false }
            if direct || blockRefs[k].contains(where: { needsHome[$0] }) {
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
        pragmas.append(AssembledPragma(selector: p.selector, arguments: p.arguments))
    }

    struct Body {
        let lines: [AsmLine]
        let argc: Int
        let addressable: Int
        let isBlock: Bool
        let needsHome: Bool
        let line: Int
        let name: String
    }
    func assembleBody(_ b: Body, extraLiterals: [Literal]) throws(LoadError) -> (bytes: [UInt8], literals: [Literal], maxStack: Int,
                                                                              maxIvar: Int, minIvar: Int, hasMap: Bool) {
        struct Ins {
            let op: Opcode
            let line: Int
            var a = 0
            var b = 0
            var label: String? = nil
        }
        var ins: [Ins] = []
        var labels: [String: Int] = [:]
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
        // Module 9b: (instruction index, start, end) for each `.source`.
        var sources: [(Int, Int, Int)] = []
        for l in b.lines {
            switch l.content {
            case .source(let start, let end):
                guard start >= 0, end >= start else { throw fail(.badOperand, "source range \(start)..<\(end)", l.line) }
                sources.append((ins.count, start, end))
            case .label(let name):
                if labels[name] != nil { throw fail(.duplicateLabel, "label '\(name)' defined twice", l.line) }
                labels[name] = ins.count
            case .op(let op, let a, let x):
                guard op != .ext, op.operands != .send, op.operands != .jump, op.operands != .closure, op != .pushLiteral else {
                    throw fail(.badOperand, "\(op.mnemonic) needs its own operands", l.line)
                }
                if op == .pushIvar || op == .storeIvar {
                    guard (0..<Header.maxSlots).contains(a) else { throw fail(.badOperand, "slot index \(a)", l.line) }
                    maxIvar = max(maxIvar, a)
                    minIvar = minIvar < 0 ? a : min(minIvar, a)
                }
                if op == .pushInt && !(-128...127).contains(a) { throw fail(.badOperand, "push_int's operand must be -128...127", l.line) }
                if op.operands != .int8 && op.operands != .none && !(0...0xFFFF).contains(a) {
                    throw fail(.badOperand, "operand \(a) out of range", l.line)
                }
                if op.operands == .vectorSlot && !(0...255).contains(x) { throw fail(.badOperand, "temp index \(x)", l.line) }
                ins.append(Ins(op: op, line: l.line, a: a, b: x))
            case .pushLiteral(let lit):
                ins.append(Ins(op: .pushLiteral, line: l.line, a: try literal(lit, l.line)))
            case .send(let op, let sel, let n):
                guard op == .send || op == .sendSuper, isSelector(sel), n == arity(of: sel) else {
                    throw fail(.badOperand, "\(sel) takes \(arity(of: sel)) argument(s)", l.line)
                }
                ins.append(Ins(op: op, line: l.line, a: try literal(.symbol(sel), l.line), b: n))
            case .pushClosure(let name, let c):
                ins.append(Ins(op: .pushClosure, line: l.line, a: try literal(.block(blockIndex[name]!), l.line), b: c))
            case .jump(let op, let label):
                guard op.isJump else { throw fail(.badOperand, "\(op.mnemonic) is not a jump", l.line) }
                ins.append(Ins(op: op, line: l.line, label: label))
            }
        }
        for i in ins {
            guard let label = i.label else { continue }
            guard let t = labels[label] else { throw fail(.unknownLabel, "no label '\(label)'", i.line) }
            guard t < ins.count else { throw fail(.badStack, "label '\(label)' is past the last instruction", i.line) }
        }
        for l in extraLiterals { _ = try literal(l, b.line) }
        if sources.contains(where: { $0.0 >= ins.count }) { throw fail(.badOperand, "a source range after the last instruction", b.line) }
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
            // The second operand (argc, copied count, temp) is one byte, never
            // extended: the syntax fuzzer's crash in module 8c's gate run was a
            // keyword send of more than 255 arguments, which trapped here.
            if i.op.operands == .send || i.op.operands == .closure || i.op.operands == .vectorSlot, i.b < 0 || i.b > 255 {
                throw fail(.badOperand, "operand \(i.b) exceeds 255", i.line)
            }
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
        // Module 9b: the source map is the last literal, never merged with
        // another (an equal `#[...]` literal stays its own).
        var hasMap = false
        if !sources.isEmpty {
            if literals.count == limits.maxLiterals { throw fail(.tooManyLiterals, "more than \(limits.maxLiterals) literals", b.line) }
            literals.append(.byteArray(SourceMap.encode(sources.map { (offsets[$0.0], $0.1, $0.2) })))
            hasMap = true
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
            return (bytes, literals, v.maxStack, maxIvar, minIvar, hasMap)
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
                                      flags: MethodFlags.block | (needsHome[k] ? MethodFlags.needsHome : 0)
                                          | (r.hasMap ? MethodFlags.sourceMap : 0), copied: b.copied,
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
    let flags = (m.unwind ? MethodFlags.unwind : 0) | (m.handler ? MethodFlags.handler : 0) | (r.hasMap ? MethodFlags.sourceMap : 0)
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

/// Module 9b: a method's pc-to-source map, its last literal when
/// `MethodFlags.sourceMap` is set: for each send instruction in pc order,
/// three unsigned LEB128 numbers: the pc minus the previous entry's pc,
/// the source start (a byte offset in the recorded source), and the
/// range's length. The kernel's BytecodeGenerator writes the same bytes and
/// `CompiledMethod>>sourceRangeAt:` reads them.
package enum SourceMap {
    package static func encode(_ entries: [(pc: Int, start: Int, end: Int)]) -> [UInt8] {
        var out: [UInt8] = []
        var prev = 0
        func put(_ v: Int) {
            var x = UInt(v)
            while x >= 128 {
                out.append(UInt8(x & 127) | 128)
                x >>= 7
            }
            out.append(UInt8(x))
        }
        for e in entries {
            put(e.pc - prev)
            put(e.start)
            put(e.end - e.start)
            prev = e.pc
        }
        return out
    }

    /// The entries back (nil when the bytes are not a map).
    package static func decode(_ bytes: [UInt8]) -> [(pc: Int, start: Int, end: Int)]? {
        var out: [(Int, Int, Int)] = []
        var i = 0, pc = 0
        func get() -> Int? {
            var v = 0, shift = 0
            while i < bytes.count, shift < 56 {
                let b = bytes[i]
                i += 1
                v |= Int(b & 127) << shift
                if b < 128 { return v }
                shift += 7
            }
            return nil
        }
        while i < bytes.count {
            guard let d = get(), let s = get(), let n = get() else { return nil }
            pc += d
            out.append((pc, s, s + n))
        }
        return out
    }
}
