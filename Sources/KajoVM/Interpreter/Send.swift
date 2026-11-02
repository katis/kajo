/// The live registers, in machine registers while the loop runs. `code` and
/// `lits` are the two cached raw pointers the interpreter may hold: the
/// running method's bytecodes and literal frame. Both are re-derived from
/// the method oop after any call that can pause (`restore`).
@safe struct Regs {
    var pc: UnsafePointer<UInt8>
    var sp: UnsafeMutablePointer<UInt64>
    var fp: UnsafeMutablePointer<UInt64>
    var hdr: UnsafeMutablePointer<UInt64>
    var code: UnsafePointer<UInt8>
    var lits: UnsafePointer<UInt64>
}

typealias StatePointer = UnsafeMutablePointer<InterpreterState>

@_transparent
func tagged(_ i: Int) -> UInt64 { UInt64(bitPattern: Int64(i)) &<< 1 | 1 }

@_transparent
func untagged(_ w: UInt64) -> Int { Int(truncatingIfNeeded: Int64(bitPattern: w) &>> 1) }

// MARK: - registers to and from the saved form

/// Write the registers into the state as indices and an offset. `pc` is
/// the offset of the next instruction. Every slow path that can pause or
/// stop calls this first.
@inline(__always)
func save(_ s: StatePointer, _ pc: UnsafePointer<UInt8>, _ sp: UnsafeMutablePointer<UInt64>,
          _ fp: UnsafeMutablePointer<UInt64>, _ hdr: UnsafeMutablePointer<UInt64>) {
    let base = unsafe s.pointee.stackBase
    unsafe s.pointee.regs.sp = sp - base
    unsafe s.pointee.regs.fp = fp - base
    unsafe s.pointee.regs.hdr = hdr - base
    unsafe s.pointee.regs.receiver = Oop(raw: fp.pointee)
    if unsafe hdr == base {
        unsafe s.pointee.regs.method = .none
        unsafe s.pointee.regs.pc = 0
    } else {
        let om = unsafe s.pointee.om
        let method = unsafe Oop(raw: hdr.pointee)
        unsafe s.pointee.regs.method = method
        unsafe s.pointee.regs.pc = pc - om.bytesBase(om.load(method, MethodLayout.bytecodes))
    }
}

/// Registers from the saved form, the cached bases re-derived from the
/// method oop. At the host level (no method) pc is the leave code.
@inline(__always)
func restore(_ s: StatePointer) -> Regs {
    let base = unsafe s.pointee.stackBase
    let r = unsafe s.pointee.regs
    let leave = unsafe UnsafePointer(s.pointee.leaveCode)
    if r.hdr == 0 {
        return unsafe Regs(pc: leave, sp: base + r.sp, fp: base + r.fp, hdr: base, code: leave, lits: UnsafePointer(base))
    }
    let om = unsafe s.pointee.om
    let method = unsafe Oop(raw: base[r.hdr])
    let code = unsafe om.bytesBase(om.load(method, MethodLayout.bytecodes))
    let lits = unsafe om.slotsBase(om.load(method, MethodLayout.literals))
    return unsafe Regs(pc: code + r.pc, sp: base + r.sp, fp: base + r.fp, hdr: base + r.hdr, code: code, lits: lits)
}

/// Registers that make the loop leave at its next dispatch.
@inline(__always)
func leaving(_ s: StatePointer, _ r: Regs) -> Regs {
    var out = r
    unsafe out.pc = UnsafePointer(s.pointee.leaveCode)
    return out
}

/// Record an error at the instruction that started `length` bytes before
/// `pc`, and leave.
@inline(never)
func failAt(_ s: StatePointer, _ pc: UnsafePointer<UInt8>, _ sp: UnsafeMutablePointer<UInt64>,
            _ fp: UnsafeMutablePointer<UInt64>, _ hdr: UnsafeMutablePointer<UInt64>, _ length: Int,
            _ kind: VMError.Kind, _ selector: UInt64, _ value: UInt64) -> Regs {
    unsafe save(s, pc, sp, fp, hdr)
    unsafe s.pointee.regs.pc &-= length
    let m = unsafe Machine(state: s)
    m.fail(kind, selector: Oop(raw: selector), receiverClass: m.classIndex(of: Oop(raw: value)))
    return unsafe restoreLeaving(s)
}

@inline(__always)
func restoreLeaving(_ s: StatePointer) -> Regs { unsafe leaving(s, restore(s)) }

// MARK: - send

/// A send of `sel` with `argc` arguments from an instruction of `length`
/// bytes that ended at `r.pc`. Inlined into the loop: poll, cache probe,
/// then either an out-of-line call (miss, primitive, poll, overflow) or
/// an inline activation.
@_transparent
func send(_ s: StatePointer, _ om: ObjectMemory, _ r: Regs, _ sel: UInt64, _ argc: Int, _ length: Int,
          poll: Bool, count: Bool = true) -> Regs {
    if poll {
        unsafe s.pointee.countdown &-= 1
        if unsafe s.pointee.countdown == 0 || s.pointee.safepointFlag.pointee.load(ordering: .relaxed) != 0 {
            return unsafe pollAndSend(s, r.pc, r.sp, r.fp, r.hdr, sel, argc, length)
        }
    }
    if count { unsafe s.pointee.counters.sends &+= 1 }
    let rcv = unsafe (r.sp - argc).pointee
    let cls = rcv & 1 != 0 ? WellKnown.smallInteger : om.headerWord(rcv) & Header.classMask
    let e = unsafe s.pointee.cache + (Int(truncatingIfNeeded: (sel &>> 4) ^ cls) & (InterpreterState.cacheEntries &- 1))
    var method: UInt64
    if unsafe e.pointee.classIndex == cls && e.pointee.selector == sel {
        method = unsafe e.pointee.method
    } else {
        method = unsafe lookupMiss(s, cls, sel)
        if method == 0 { return unsafe doesNotUnderstand(s, r.pc, r.sp, r.fp, r.hdr, sel, argc, length) }
    }
    return unsafe invoke(s, om, r, method, argc, length)
}

/// Run `method` for the receiver and arguments on top of the stack: its
/// primitive out of line, else an inline activation.
@_transparent
func invoke(_ s: StatePointer, _ om: ObjectMemory, _ r: Regs, _ method: UInt64, _ argc: Int, _ length: Int) -> Regs {
    let prim = om.load(Oop(raw: method), MethodLayout.primitive).raw
    if prim != tagged(0) {
        return unsafe primitiveSend(s, r.pc, r.sp, r.fp, r.hdr, method, untagged(prim) &<< 8 | argc, length)
    }
    return unsafe activate(s, om, r, method, argc, length)
}

/// Push a frame for `method` over the receiver and arguments on top of the
/// stack (SPEC-SHARED "Frames"; Frame in Stack.swift).
@_transparent
func activate(_ s: StatePointer, _ om: ObjectMemory, _ r: Regs, _ method: UInt64, _ argc: Int, _ length: Int) -> Regs {
    let mo = Oop(raw: method)
    let temps = untagged(om.load(mo, MethodLayout.temps).raw)
    let maxStack = untagged(om.load(mo, MethodLayout.maxStack).raw)
    var sp = unsafe r.sp
    // One word more than the frame uses: a unary send that ends in
    // doesNotUnderstand: pushes its Message above the deepest operand.
    if unsafe sp + (temps &+ Frame.headerWords &+ maxStack &+ 1) >= s.pointee.stackEnd {
        return unsafe stackOverflow(s, r.pc, r.sp, r.fp, r.hdr, method, length)
    }
    let nilObject = unsafe s.pointee.nilObject.raw
    var i = 0
    while i < temps {
        unsafe sp += 1
        unsafe sp.pointee = nilObject
        i &+= 1
    }
    let base = unsafe s.pointee.stackBase
    let hdr = unsafe sp + 1
    unsafe hdr[Frame.method] = method
    unsafe hdr[Frame.callerPC] = tagged(r.pc - r.code)
    unsafe hdr[Frame.callerFP] = tagged(r.fp - base)
    unsafe hdr[Frame.callerHdr] = tagged(r.hdr - base)
    unsafe hdr[Frame.context] = nilObject
    let code = unsafe om.bytesBase(om.load(mo, MethodLayout.bytecodes))
    let lits = unsafe om.slotsBase(om.load(mo, MethodLayout.literals))
    return unsafe Regs(pc: code, sp: hdr + (Frame.headerWords &- 1), fp: r.sp - argc, hdr: hdr, code: code, lits: lits)
}

/// Return `v` to the caller: it replaces the receiver, sp drops to it, the
/// caller's bases are re-derived from its method.
@_transparent
func doReturn(_ s: StatePointer, _ om: ObjectMemory, _ r: Regs, _ v: UInt64) -> Regs {
    let callerFP = unsafe r.hdr[Frame.callerFP]
    if callerFP == Frame.hostFP { return unsafe bottomReturn(s, r.sp, r.fp, r.hdr, v) }
    let base = unsafe s.pointee.stackBase
    let fp = unsafe base + untagged(callerFP)
    let hdr = unsafe base + untagged(r.hdr[Frame.callerHdr])
    unsafe r.fp.pointee = v
    let method = unsafe Oop(raw: hdr[Frame.method])
    let code = unsafe om.bytesBase(om.load(method, MethodLayout.bytecodes))
    let lits = unsafe om.slotsBase(om.load(method, MethodLayout.literals))
    return unsafe Regs(pc: code + untagged(r.hdr[Frame.callerPC]), sp: r.fp, fp: fp, hdr: hdr, code: code, lits: lits)
}

// MARK: - out of line

/// The bottom frame returned: the value goes to the result register (a
/// root until the host takes it) and the loop leaves.
@inline(never)
func bottomReturn(_ s: StatePointer, _ sp: UnsafeMutablePointer<UInt64>, _ fp: UnsafeMutablePointer<UInt64>,
                  _ hdr: UnsafeMutablePointer<UInt64>, _ v: UInt64) -> Regs {
    unsafe s.pointee.regs = SavedRegisters(pc: 0, sp: fp - 1 - s.pointee.stackBase, fp: 0, hdr: 0,
                                           receiver: .none, method: .none, result: Oop(raw: v))
    unsafe s.pointee.exit = .returned
    return unsafe restoreLeaving(s)
}

/// A miss: full lookup, fill the line. 0 when nothing understands `sel`.
@inline(never)
func lookupMiss(_ s: StatePointer, _ cls: UInt64, _ sel: UInt64) -> UInt64 {
    unsafe s.pointee.counters.cacheMisses &+= 1
    let m = unsafe lookupMethod(s.pointee.om, nilObject: s.pointee.nilObject, classIndex: cls, selector: Oop(raw: sel))
    if m == .none { return 0 }
    let e = unsafe s.pointee.cache + (Int(truncatingIfNeeded: (sel &>> 4) ^ cls) & (InterpreterState.cacheEntries &- 1))
    unsafe e.pointee = CacheEntry(classIndex: cls, selector: sel, method: m.raw)
    return m.raw
}

/// The countdown ran out or the safepoint flag was set at a send: flush
/// the registers, run the poll slow path (which may park, stop the world,
/// or suspend the Process with the send rewound so it is re-executed),
/// then send.
@inline(never)
func pollAndSend(_ s: StatePointer, _ pc: UnsafePointer<UInt8>, _ sp: UnsafeMutablePointer<UInt64>,
                 _ fp: UnsafeMutablePointer<UInt64>, _ hdr: UnsafeMutablePointer<UInt64>,
                 _ sel: UInt64, _ argc: Int, _ length: Int) -> Regs {
    unsafe flushForPoll(s, pc, sp, fp, hdr)
    if unsafe pollSlow(s, rewind: length) { return unsafe leavingWithoutStack(s) }
    let r = unsafe restore(s)
    return unsafe send(s, s.pointee.om, r, sel, argc, length, poll: false)
}

/// As `pollAndSend`, at a backward jump (the saved pc is the target).
@inline(never)
func pollAtJump(_ s: StatePointer, _ pc: UnsafePointer<UInt8>, _ sp: UnsafeMutablePointer<UInt64>,
                _ fp: UnsafeMutablePointer<UInt64>, _ hdr: UnsafeMutablePointer<UInt64>) -> Regs {
    unsafe flushForPoll(s, pc, sp, fp, hdr)
    if unsafe pollSlow(s, rewind: 0) { return unsafe leavingWithoutStack(s) }
    return unsafe restore(s)
}

/// The registers to the saved form before the poll can park or stop the
/// world (the test switch `flushAfterStop` stops first, with stale ones).
@inline(__always)
func flushForPoll(_ s: StatePointer, _ pc: UnsafePointer<UInt8>, _ sp: UnsafeMutablePointer<UInt64>,
                  _ fp: UnsafeMutablePointer<UInt64>, _ hdr: UnsafeMutablePointer<UInt64>) {
    if let vm = unsafe workerOf(s).pointee.vm, unsafe vm.pointee.config.testSwitches.flushAfterStop {
        unsafe stopIfStressed(vm, workerOf(s))
    }
    unsafe save(s, pc, sp, fp, hdr)
}

/// Registers that leave the loop at once without reading the stack: the
/// Process has been published and may already run elsewhere.
@inline(__always)
func leavingWithoutStack(_ s: StatePointer) -> Regs {
    let d = unsafe workerOf(s).pointee.dummy
    let leave = unsafe UnsafePointer(s.pointee.leaveCode)
    return unsafe Regs(pc: leave, sp: d, fp: d, hdr: d, code: leave, lits: UnsafePointer(d))
}

/// A special arithmetic or comparison bytecode whose fast path did not
/// apply: a real send of its selector.
@inline(never)
func specialSend(_ s: StatePointer, _ pc: UnsafePointer<UInt8>, _ sp: UnsafeMutablePointer<UInt64>,
                 _ fp: UnsafeMutablePointer<UInt64>, _ hdr: UnsafeMutablePointer<UInt64>, _ index: Int) -> Regs {
    unsafe s.pointee.counters.specialSendFallbacks &+= 1
    let om = unsafe s.pointee.om
    let base = unsafe s.pointee.stackBase
    let r: Regs
    if unsafe hdr == base {
        r = unsafe Regs(pc: pc, sp: sp, fp: fp, hdr: hdr, code: pc, lits: UnsafePointer(base))
    } else {
        let method = unsafe Oop(raw: hdr.pointee)
        r = unsafe Regs(pc: pc, sp: sp, fp: fp, hdr: hdr, code: om.bytesBase(om.load(method, MethodLayout.bytecodes)),
                        lits: om.slotsBase(om.load(method, MethodLayout.literals)))
    }
    return unsafe send(s, om, r, s.pointee.specialSelectors[index], 1, 1, poll: true)
}

/// Run a primitive. Success: the result replaces receiver and arguments.
/// Failure: the method's bytecodes run as an ordinary activation, or, with
/// none, the error `primitiveFailed`. `primAndArgc` is the primitive
/// number shifted left 8, or'ed with argc (to keep this call's arguments in
/// registers).
@inline(never)
func primitiveSend(_ s: StatePointer, _ pc: UnsafePointer<UInt8>, _ sp: UnsafeMutablePointer<UInt64>,
                   _ fp: UnsafeMutablePointer<UInt64>, _ hdr: UnsafeMutablePointer<UInt64>,
                   _ method: UInt64, _ primAndArgc: Int, _ length: Int) -> Regs {
    let prim = primAndArgc &>> 8, argc = primAndArgc & 0xFF
    unsafe save(s, pc, sp, fp, hdr)
    unsafe s.pointee.counters.primitiveCalls &+= 1
    unsafe s.pointee.sendLength = length
    let m = unsafe Machine(state: s)
    let call = unsafe PrimitiveCall(receiver: Oop(raw: (sp - argc).pointee), argc: argc,
                                    arg0: argc > 0 ? Oop(raw: (sp - argc + 1).pointee) : .none,
                                    arg1: argc > 1 ? Oop(raw: (sp - argc + 2).pointee) : .none)
    let result = primitive(prim, m, call)
    if unsafe s.pointee.exit == .suspended { return unsafe leavingWithoutStack(s) }
    if result != .none {
        let base = unsafe s.pointee.stackBase
        let top = unsafe s.pointee.regs.sp &- argc
        unsafe s.pointee.regs.sp = top
        unsafe base[top] = result.raw
        return unsafe restore(s)  // the primitive may have paused: re-derive the bases
    }
    let om = m.om
    if m.failed {  // outOfMemory inside the primitive
        if unsafe s.pointee.error.selector == .none {
            unsafe s.pointee.error.selector = om.load(Oop(raw: method), MethodLayout.selector)
            unsafe s.pointee.error.receiverClass = m.classIndex(of: call.receiver)
        }
        unsafe s.pointee.regs.pc &-= length
        return unsafe restoreLeaving(s)
    }
    unsafe s.pointee.counters.primitiveFailures &+= 1
    let r = unsafe restore(s)
    if om.count(of: om.load(Oop(raw: method), MethodLayout.bytecodes)) == 0 {
        unsafe s.pointee.regs.pc &-= length
        m.fail(.primitiveFailed, selector: om.load(Oop(raw: method), MethodLayout.selector),
               receiverClass: m.classIndex(of: call.receiver), primitive: prim)
        return unsafe leaving(s, r)
    }
    return unsafe activate(s, om, r, method, argc, length)
}

/// No room for the next frame.
@inline(never)
func stackOverflow(_ s: StatePointer, _ pc: UnsafePointer<UInt8>, _ sp: UnsafeMutablePointer<UInt64>,
                   _ fp: UnsafeMutablePointer<UInt64>, _ hdr: UnsafeMutablePointer<UInt64>,
                   _ method: UInt64, _ length: Int) -> Regs {
    let om = unsafe s.pointee.om
    let argc = untagged(om.load(Oop(raw: method), MethodLayout.argc).raw)
    return unsafe failAt(s, pc, sp, fp, hdr, length, .stackOverflow, om.load(Oop(raw: method), MethodLayout.selector).raw,
                         (sp - argc).pointee)
}

/// Nothing understands `sel`: send `doesNotUnderstand:` with a Message if
/// the receiver's class has it, else stop with the error.
@inline(never)
func doesNotUnderstand(_ s: StatePointer, _ pc: UnsafePointer<UInt8>, _ sp: UnsafeMutablePointer<UInt64>,
                       _ fp: UnsafeMutablePointer<UInt64>, _ hdr: UnsafeMutablePointer<UInt64>,
                       _ sel: UInt64, _ argc: Int, _ length: Int) -> Regs {
    let rcv = unsafe (sp - argc).pointee
    let m = unsafe Machine(state: s)
    let cls = m.classIndex(of: Oop(raw: rcv))
    let handler = unsafe lookupMiss(s, cls, s.pointee.doesNotUnderstand.raw)
    if handler == 0 { return unsafe failAt(s, pc, sp, fp, hdr, length, .doesNotUnderstand, sel, rcv) }
    unsafe save(s, pc, sp, fp, hdr)
    let args = m.allocate(WellKnown.array, slots: argc)
    if args == .none { return unsafe failedAllocation(s, sel, rcv, length) }
    let base = unsafe s.pointee.stackBase
    let top = unsafe s.pointee.regs.sp
    // Fresh objects with no safepoint since: young holders (or old with
    // nothing young). The barrier is kept: it costs one test each.
    for i in 0..<argc { unsafe m.store(args, i, Oop(raw: base[top - argc + 1 + i]), .messageArgument) }
    let message = m.allocate(WellKnown.message, slots: MessageLayout.size, keeping: args)
    if message == .none { return unsafe failedAllocation(s, sel, rcv, length) }
    m.store(message, MessageLayout.selector, Oop(raw: sel), .messageSelector)
    m.store(message, MessageLayout.arguments, args, .messageArguments)
    unsafe base[top - argc + 1] = message.raw
    unsafe s.pointee.regs.sp = top - argc + 1
    let r = unsafe restore(s)
    return unsafe invoke(s, s.pointee.om, r, handler, 1, length)
}

@inline(__always)
func failedAllocation(_ s: StatePointer, _ sel: UInt64, _ rcv: UInt64, _ length: Int) -> Regs {
    unsafe s.pointee.error.selector = Oop(raw: sel)
    unsafe s.pointee.error.receiverClass = Machine(state: s).classIndex(of: Oop(raw: rcv))
    unsafe s.pointee.regs.pc &-= length
    return unsafe restoreLeaving(s)
}
