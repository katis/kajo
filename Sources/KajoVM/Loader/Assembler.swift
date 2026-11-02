/// A literal of an assembled method, resolved to an object at load time.
enum Literal: Hashable, Sendable {
    case integer(Int64)
    case symbol(String)
    case classRef(String)
    case nilObject
    case trueObject
    case falseObject
}

/// A method as bytes and a literal frame, verified, not yet in the heap.
struct AssembledMethod {
    let file: String
    let line: Int
    let className: String
    let selector: String
    let argc: Int
    let temps: Int
    let primitive: Int
    let bytecodes: [UInt8]
    let literals: [Literal]
    let maxStack: Int
    /// Highest receiver slot index any push_ivar or store_ivar names, or -1.
    let maxIvar: Int
}

/// Assemble one parsed method: resolve labels, build the literal frame in
/// first-use order with duplicates merged, encode, and run the stack-depth
/// verifier. Everything the interpreter trusts about a method's bytecodes
/// (operands in range, jumps onto instructions, no underflow, a sound
/// `maxStack`, no falling off the end) is established here.
func assemble(_ m: KasmMethod, limits: LoaderLimits = LoaderLimits()) throws(LoadError) -> AssembledMethod {
    let argc = arity(of: m.selector)
    let nTemps = argc + m.temps
    func fail(_ kind: LoadError.Kind, _ msg: String, _ line: Int) -> LoadError {
        LoadError(kind, "\(m.className)>>\(m.selector): \(msg)", file: m.file, line: line)
    }

    // Pass 1: opcodes, offsets and labels.
    struct Ins {
        let op: Opcode
        let args: [String]
        let line: Int
        let offset: Int
    }
    var ins: [Ins] = []
    var labels: [String: Int] = [:]  // label -> instruction index
    var offset = 0
    for l in m.body {
        switch l.content {
        case .label(let name):
            if labels[name] != nil { throw fail(.duplicateLabel, "label '\(name)' defined twice", l.line) }
            labels[name] = ins.count
        case .instruction(let name, let args):
            guard let op = Opcode(mnemonic: name) else { throw fail(.unknownOpcode, "unknown instruction '\(name)'", l.line) }
            ins.append(Ins(op: op, args: args, line: l.line, offset: offset))
            offset += op.length
            if offset > limits.maxMethodBytes {
                throw fail(.methodTooLarge, "more than \(limits.maxMethodBytes) bytes of bytecode", l.line)
            }
        }
    }
    if ins.isEmpty && m.primitive == 0 { throw fail(.emptyMethod, "no bytecodes and no primitive", m.line) }

    // Pass 2: encode.
    var bytes: [UInt8] = []
    bytes.reserveCapacity(offset)
    var literals: [Literal] = []
    var literalIndex: [Literal: Int] = [:]
    var sendArgc = [Int](repeating: 0, count: ins.count)
    var targets = [Int](repeating: -1, count: ins.count)  // instruction index a jump goes to
    var maxIvar = -1
    func literal(_ lit: Literal, _ line: Int) throws(LoadError) -> UInt8 {
        if let i = literalIndex[lit] { return UInt8(i) }
        if literals.count == limits.maxLiterals { throw fail(.tooManyLiterals, "more than \(limits.maxLiterals) literals", line) }
        literalIndex[lit] = literals.count
        literals.append(lit)
        return UInt8(literals.count - 1)
    }
    for (k, i) in ins.enumerated() {
        let expected = i.op.operands == .none ? 0 : i.op.operands == .send ? 2 : 1
        if i.args.count != expected {
            throw fail(.badOperand, "\(i.op.mnemonic) takes \(expected) operand(s)", i.line)
        }
        bytes.append(i.op.rawValue)
        switch i.op.operands {
        case .none:
            break
        case .index:
            switch i.op {
            case .pushLiteral:
                guard let lit = parseLiteral(i.args[0]) else { throw fail(.badOperand, "bad literal '\(i.args[0])'", i.line) }
                bytes.append(try literal(lit, i.line))
            case .pushTemp, .storeTemp:
                guard let n = Int(i.args[0]), n >= 0, n < nTemps else {
                    throw fail(.badOperand, "temp index must be 0...\(nTemps - 1)", i.line)
                }
                bytes.append(UInt8(n))
            default: // pushIvar, storeIvar; checked against the class at load
                guard let n = Int(i.args[0]), n >= 0, n <= 255 else { throw fail(.badOperand, "slot index must be 0...255", i.line) }
                maxIvar = max(maxIvar, n)
                bytes.append(UInt8(n))
            }
        case .int8:
            guard let n = Int(i.args[0]), n >= -128, n <= 127 else { throw fail(.badOperand, "push_int takes -128...127", i.line) }
            bytes.append(UInt8(bitPattern: Int8(n)))
        case .send:
            let sel = i.args[0]
            guard isSelector(sel) else { throw fail(.badOperand, "bad selector '\(sel)'", i.line) }
            guard let n = Int(i.args[1]), n == arity(of: sel) else {
                throw fail(.badOperand, "\(sel) takes \(arity(of: sel)) argument(s)", i.line)
            }
            bytes.append(try literal(.symbol(sel), i.line))
            bytes.append(UInt8(n))
            sendArgc[k] = n
        case .jump:
            guard let t = labels[i.args[0]] else { throw fail(.unknownLabel, "no label '\(i.args[0])'", i.line) }
            guard t < ins.count else { throw fail(.badStack, "label '\(i.args[0])' is past the last instruction", i.line) }
            targets[k] = t
            let (lo, hi) = OperandDecoding.encodeJump(ins[t].offset - (i.offset + i.op.length))
            bytes.append(lo)
            bytes.append(hi)
        }
    }

    // Pass 3: the stack-depth verifier, a dataflow pass over the
    // instructions. Every reachable instruction gets one depth; each path
    // must agree, never underflow and never fall off the end.
    var depth = [Int](repeating: -1, count: ins.count)
    var work: [Int] = []
    var maxStack = 0
    func reach(_ t: Int, _ d: Int, _ line: Int) throws(LoadError) {
        if t >= ins.count { throw fail(.badStack, "control falls off the end of the method", line) }
        if depth[t] == -1 {
            depth[t] = d
            work.append(t)
        } else if depth[t] != d {
            throw fail(.badStack, "stack depths \(depth[t]) and \(d) meet at one instruction", ins[t].line)
        }
    }
    if !ins.isEmpty { try reach(0, 0, m.line) }
    while let k = work.popLast() {
        let i = ins[k]
        let (pops, pushes) = i.op.stackEffect(argc: sendArgc[k])
        let d = depth[k]
        if d < pops { throw fail(.badStack, "\(i.op.mnemonic) needs \(pops) operand(s), the stack has \(d)", i.line) }
        let after = d - pops + pushes
        if after > limits.maxStack { throw fail(.badStack, "operand stack deeper than \(limits.maxStack)", i.line) }
        maxStack = max(maxStack, after, d)
        if i.op.isJump { try reach(targets[k], after, i.line) }
        if !i.op.endsBlock { try reach(k + 1, after, i.line) }
    }

    return AssembledMethod(file: m.file, line: m.line, className: m.className, selector: m.selector, argc: argc,
                           temps: m.temps, primitive: m.primitive, bytecodes: bytes, literals: literals,
                           maxStack: maxStack, maxIvar: maxIvar)
}

/// Decimal integer (a SmallInteger), `#selector`, `@ClassName`, nil, true, false.
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
    guard let v = Int64(s), Oop.fitsSmallInteger(v) else { return nil }
    return .integer(v)
}
