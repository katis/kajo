/// The bytecode verifier: everything the interpreter trusts about a
/// method's bytecodes, established once before the method can run. The
/// kasm assembler runs it on what it encoded; the image loader runs it on
/// every method in a snapshot before anything runs (module 8). It reads
/// only the opcode table (`Opcodes.swift`).
///
/// Checked: every byte is part of a decodable instruction (`ext` only
/// before an extensible opcode); temp, literal and slot operands in range;
/// a send's literal is a selector of the send's arity; a closure's literal
/// is a block method with that many copied values; jumps land on
/// instruction starts; methods return with `return_top`/`return_self` and
/// blocks with `block_return`/`nonlocal_return`, and only a block whose
/// closures carry a home returns non-locally; and the stack-depth tracer:
/// a dataflow pass giving every reachable instruction one depth, never
/// underflowing, never falling off the end, counting each slow path's
/// transient words, and answering `maxStack`. A fused instruction
/// (interpreter speed) is checked as its first part, with its second part
/// required to follow it.

/// What the verifier needs to know of a literal.
enum LiteralInfo: Equatable {
    case selector(arity: Int)
    case block(args: Int, copied: Int, needsHome: Bool)
    case other
}

/// The code body to verify and its context.
struct CodeShape {
    let argc: Int
    /// Addressable temps: arguments, copied values and temps (a block's
    /// closure word is not addressable).
    let addressableTemps: Int
    let literalCount: Int
    let isBlock: Bool
    let needsHome: Bool
    /// Receiver slots `push_ivar`/`store_ivar` may name: `ivarRange`.
    let ivarRange: Range<Int>
    let maxStackLimit: Int
}

struct BytecodeIssue: Error, Equatable {
    let kind: LoadError.Kind
    let message: String
    /// The offending instruction's offset, -1 for the whole method.
    let offset: Int
}

struct VerifiedCode {
    let maxStack: Int
    let instructions: [DecodedInstruction]
    /// Block literals the code creates closures from.
    let closures: [Int]
    let returnsNonLocally: Bool
    /// Module 8c: the traced operand depth before each instruction (-1 for
    /// one no path reaches). Unique per instruction: two paths that meet
    /// with different depths are refused above, so a saved frame's pc and
    /// depth can be checked against it (the image loader's saved-Process
    /// rules).
    var depths: [Int] = []
}

func verifyBytecodes(_ bytes: [UInt8], _ shape: CodeShape, literal: (Int) -> LiteralInfo) throws(BytecodeIssue)
    -> VerifiedCode {
    func fail(_ k: LoadError.Kind, _ m: String, _ off: Int) -> BytecodeIssue { BytecodeIssue(kind: k, message: m, offset: off) }
    // Decode linearly.
    var ins: [DecodedInstruction] = []
    var at: [Int: Int] = [:]  // offset -> instruction index
    var off = 0
    while off < bytes.count {
        guard let d = decodeInstruction(bytes, at: off) else {
            throw fail(.unknownOpcode, "no instruction at offset \(off) (byte \(bytes[off]))", off)
        }
        at[off] = ins.count
        ins.append(d)
        off += d.length
    }
    var targets = [Int](repeating: -1, count: ins.count)
    var closures: [Int] = []
    var nonLocal = false
    for (k, d) in ins.enumerated() {
        let o = d.offset
        // Interpreter speed: a fused instruction is its first part, and its
        // second part follows as a plain, unextended instruction: the loop
        // reads that instruction's operands at fixed offsets.
        if let f = d.fused, let (_, second) = f.fusedParts {
            guard k + 1 < ins.count, ins[k + 1].op == second, ins[k + 1].fused == nil, ins[k + 1].length == second.length else {
                throw fail(.badOperand, "\(f.mnemonic) is not followed by \(second.mnemonic)", o)
            }
        }
        switch d.op {
        case .pushTemp, .storeTemp:
            if d.a >= shape.addressableTemps { throw fail(.badOperand, "temp \(d.a) of \(shape.addressableTemps)", o) }
        case .pushLiteral:
            if d.a >= shape.literalCount { throw fail(.badOperand, "literal \(d.a) of \(shape.literalCount)", o) }
        case .pushIvar, .storeIvar:
            if !shape.ivarRange.contains(d.a) { throw fail(.badClass, "instance variable \(d.a) outside \(shape.ivarRange)", o) }
        case .send, .sendSuper:
            guard d.a < shape.literalCount, case .selector(let n) = literal(d.a) else {
                throw fail(.badOperand, "a send's literal \(d.a) is not a selector", o)
            }
            if n != d.b { throw fail(.badOperand, "a selector of \(n) argument(s) sent with \(d.b)", o) }
        case .pushClosure:
            guard d.a < shape.literalCount, case .block(_, let c, let home) = literal(d.a) else {
                throw fail(.badOperand, "push_closure's literal \(d.a) is not a block method", o)
            }
            if c != d.b { throw fail(.badOperand, "a block of \(c) copied value(s) closed over \(d.b)", o) }
            if home && !(shape.isBlock ? shape.needsHome : true) {
                throw fail(.badOperand, "a block that returns non-locally inside a block without a home", o)
            }
            closures.append(d.a)
        case .pushNewArray:
            if d.a > Header.maxSlots { throw fail(.badOperand, "push_new_array \(d.a) exceeds \(Header.maxSlots)", o) }
        case .pushTempVectorSlot, .storeTempVectorSlot:
            if d.b >= shape.addressableTemps { throw fail(.badOperand, "temp \(d.b) of \(shape.addressableTemps)", o) }
            if d.a >= Header.maxSlots { throw fail(.badOperand, "temp vector slot \(d.a)", o) }
        case .returnTop, .returnSelf:
            if shape.isBlock { throw fail(.badOperand, "\(d.op.mnemonic) in a block (use block_return)", o) }
        case .blockReturn:
            if !shape.isBlock { throw fail(.badOperand, "block_return in a method", o) }
        case .nonlocalReturn:
            if !shape.isBlock { throw fail(.badOperand, "nonlocal_return in a method (use return_top)", o) }
            if !shape.needsHome { throw fail(.badOperand, "nonlocal_return in a block without a home", o) }
            nonLocal = true
        case .jump, .jumpIfTrue, .jumpIfFalse:
            let t = o + d.length + d.a
            guard let ti = at[t] else { throw fail(.badStack, "a jump to offset \(t), not an instruction", o) }
            targets[k] = ti
        default:
            break
        }
    }
    if ins.isEmpty { return VerifiedCode(maxStack: 0, instructions: [], closures: [], returnsNonLocally: false, depths: []) }

    // The stack-depth tracer.
    var depth = [Int](repeating: -1, count: ins.count)
    var work: [Int] = []
    var maxStack = 0
    func reach(_ t: Int, _ d: Int, _ from: Int) throws(BytecodeIssue) {
        if t >= ins.count { throw fail(.badStack, "control falls off the end of the method", from) }
        if depth[t] == -1 {
            depth[t] = d
            work.append(t)
        } else if depth[t] != d {
            throw fail(.badStack, "stack depths \(depth[t]) and \(d) meet at one instruction", ins[t].offset)
        }
    }
    try reach(0, 0, 0)
    while let k = work.popLast() {
        let i = ins[k]
        let (pops, pushes) = i.op.stackEffect(argc: i.b)
        let d = depth[k]
        if d < pops { throw fail(.badStack, "\(i.op.mnemonic) needs \(pops) operand(s), the stack has \(d)", i.offset) }
        let after = d - pops + pushes
        let peak = max(after, d + i.op.transientDepth)
        if peak > shape.maxStackLimit { throw fail(.badStack, "operand stack deeper than \(shape.maxStackLimit)", i.offset) }
        maxStack = max(maxStack, peak)
        if i.op.isJump { try reach(targets[k], after, i.offset) }
        if !i.op.endsBlock { try reach(k + 1, after, i.offset) }
    }
    return VerifiedCode(maxStack: maxStack, instructions: ins, closures: closures, returnsNonLocally: nonLocal, depths: depth)
}
