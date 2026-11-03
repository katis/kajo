/// The live registers, in machine registers while the loop runs. `code` and
/// `lits` are the two cached raw pointers the interpreter may hold: the
/// running method's bytecodes and literal frame. Both are re-derived from
/// the method oop after any call that can pause (`restore`).
@safe struct Regs {
    // Stored in this order (not the initializer's): fp and hdr are not
    // neighbours, so the loop does not load them as one vector pair and
    // unpack it at every dispatch (module 8 measured that order costing the
    // v0 kernels 3 to 10 percent with the larger v1 switch).
    var pc: UnsafePointer<UInt8>
    var fp: UnsafeMutablePointer<UInt64>
    var sp: UnsafeMutablePointer<UInt64>
    var code: UnsafePointer<UInt8>
    var hdr: UnsafeMutablePointer<UInt64>
    var lits: UnsafePointer<UInt64>

    @inline(__always)
    init(pc: UnsafePointer<UInt8>, sp: UnsafeMutablePointer<UInt64>, fp: UnsafeMutablePointer<UInt64>,
         hdr: UnsafeMutablePointer<UInt64>, code: UnsafePointer<UInt8>, lits: UnsafePointer<UInt64>) {
        unsafe self.pc = pc
        unsafe self.fp = fp
        unsafe self.sp = sp
        unsafe self.code = code
        unsafe self.hdr = hdr
        unsafe self.lits = lits
    }
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
    let cls = classIndexOf(om, rcv)
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
    // The method's state word once for all its fields (module 6: state
    // words are atomic loads the compiler does not merge; a method is
    // pinned for good, and one instruction may read one body anyway).
    let mb = om.stateWord(method)
    let prim = om.loadAtomic(bodyOffset: mb, MethodLayout.primitive)
    if prim != tagged(0) {
        return unsafe primitiveSend(s, r.pc, r.sp, r.fp, r.hdr, method, untagged(prim) &<< 8 | argc, length)
    }
    return unsafe activate(s, om, r, method, mb, argc, length)
}

/// Push a frame for `method` over the receiver and arguments on top of the
/// stack (SPEC-SHARED "Frames"; Frame in Stack.swift).
@_transparent
func activate(_ s: StatePointer, _ om: ObjectMemory, _ r: Regs, _ method: UInt64, _ argc: Int, _ length: Int) -> Regs {
    unsafe activate(s, om, r, method, om.stateWord(method), argc, length)
}

/// The same with the method's state word `mb` already loaded.
@_transparent
func activate(_ s: StatePointer, _ om: ObjectMemory, _ r: Regs, _ method: UInt64, _ mb: UInt64, _ argc: Int,
              _ length: Int) -> Regs {
    let temps = untagged(om.loadAtomic(bodyOffset: mb, MethodLayout.temps))
    let maxStack = untagged(om.loadAtomic(bodyOffset: mb, MethodLayout.maxStack))
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
    unsafe hdr[Frame.context] = Frame.emptyContext
    let code = unsafe om.bytesBase(Oop(raw: om.loadAtomic(bodyOffset: mb, MethodLayout.bytecodes)))
    let lits = unsafe om.slotsBase(Oop(raw: om.loadAtomic(bodyOffset: mb, MethodLayout.literals)))
    return unsafe Regs(pc: code, sp: hdr + (Frame.headerWords &- 1), fp: r.sp - argc, hdr: hdr, code: code, lits: lits)
}

/// The class index of any word that may sit in a slot: the header's for a
/// reference, SmallInteger, SmallFloat or Character for an immediate (the
/// full pattern, module 8; the spare patterns never reach here).
@_transparent
func classIndexOf(_ om: ObjectMemory, _ v: UInt64) -> UInt64 {
    if v & 1 != 0 { return WellKnown.smallInteger }
    if v & Oop.objectTagMask == 0 { return om.headerWord(v) & Header.classMask }
    return v & 2 != 0 ? WellKnown.smallFloat : WellKnown.character
}

/// Return `v` to the caller: it replaces the receiver, sp drops to it, the
/// caller's bases are re-derived from its method. A frame whose context
/// word is not nil (a materialized Context to detach, or a return marker)
/// returns out of line (module 8).
@_transparent
func doReturn(_ s: StatePointer, _ om: ObjectMemory, _ r: Regs, _ v: UInt64) -> Regs {
    if _slowPath(unsafe r.hdr[Frame.context] != Frame.emptyContext) {
        return unsafe returnSlow(s, r.pc, r.sp, r.fp, r.hdr, v)
    }
    return unsafe plainReturn(s, om, r, v)
}

/// The return itself, the context word already dealt with.
@_transparent
func plainReturn(_ s: StatePointer, _ om: ObjectMemory, _ r: Regs, _ v: UInt64) -> Regs {
    let callerFP = unsafe r.hdr[Frame.callerFP]
    if callerFP == Frame.hostFP { return unsafe bottomReturn(s, r.sp, r.fp, r.hdr, v) }
    let base = unsafe s.pointee.stackBase
    let fp = unsafe base + untagged(callerFP)
    let hdr = unsafe base + untagged(r.hdr[Frame.callerHdr])
    unsafe r.fp.pointee = v
    let mb = unsafe om.stateWord(hdr[Frame.method])
    let code = unsafe om.bytesBase(Oop(raw: om.loadAtomic(bodyOffset: mb, MethodLayout.bytecodes)))
    let lits = unsafe om.slotsBase(Oop(raw: om.loadAtomic(bodyOffset: mb, MethodLayout.literals)))
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

/// A special-send bytecode whose inline fast path did not apply: module
/// 8's out-of-line tier first (SmallInteger overflow into a LargeInteger,
/// exact `/`, floor `//` and `\\`, SmallFloat and boxed Float arithmetic
/// and comparison, mixed with SmallIntegers; `at:put:`, `at:` and `size`
/// on Arrays and byte objects; closure activation for `value`), else a
/// real send of its selector, which leaves the stack as a plain send would.
/// `special` is the selector's index shifted left 8, or'ed with its argc.
@inline(never)
func specialSend(_ s: StatePointer, _ pc: UnsafePointer<UInt8>, _ sp: UnsafeMutablePointer<UInt64>,
                 _ fp: UnsafeMutablePointer<UInt64>, _ hdr: UnsafeMutablePointer<UInt64>, _ special: Int) -> Regs {
    let index = special &>> 8, argc = special & 0xFF
    if let r = unsafe specialFastPath(s, pc, sp, fp, hdr, index, argc) { return r }
    unsafe s.pointee.counters.specialSendFallbacks &+= 1
    let om = unsafe s.pointee.om
    let r = unsafe regsAt(s, pc, sp, fp, hdr)
    return unsafe send(s, om, r, s.pointee.specialSelectors[index], argc, 1, poll: true)
}

/// Registers for a frame from the scalars, the bases derived from its
/// method (or the host's at the bottom).
@inline(__always)
func regsAt(_ s: StatePointer, _ pc: UnsafePointer<UInt8>, _ sp: UnsafeMutablePointer<UInt64>,
            _ fp: UnsafeMutablePointer<UInt64>, _ hdr: UnsafeMutablePointer<UInt64>) -> Regs {
    let om = unsafe s.pointee.om
    let base = unsafe s.pointee.stackBase
    if unsafe hdr == base {
        return unsafe Regs(pc: pc, sp: sp, fp: fp, hdr: hdr, code: pc, lits: UnsafePointer(base))
    }
    let method = unsafe Oop(raw: hdr.pointee)
    return unsafe Regs(pc: pc, sp: sp, fp: fp, hdr: hdr, code: om.bytesBase(om.load(method, MethodLayout.bytecodes)),
                       lits: om.slotsBase(om.load(method, MethodLayout.literals)))
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
    if prim >= ActivationPrimitive.first && prim <= ActivationPrimitive.last {
        // Module 8: closure `value`s and the `perform:` family activate a
        // frame instead of answering a value.
        return unsafe activationPrimitive(s, pc, sp, fp, hdr, method, prim, argc, length)
    }
    unsafe save(s, pc, sp, fp, hdr)
    unsafe s.pointee.counters.primitiveCalls &+= 1
    unsafe s.pointee.sendLength = length
    let m = unsafe Machine(state: s)
    let call = unsafe PrimitiveCall(receiver: Oop(raw: (sp - argc).pointee), argc: argc,
                                    arg0: argc > 0 ? Oop(raw: (sp - argc + 1).pointee) : .none,
                                    arg1: argc > 1 ? Oop(raw: (sp - argc + 2).pointee) : .none)
    unsafe s.pointee.readOnlyFailure = .none
    let result = primitive(prim, m, call)
    if unsafe s.pointee.exit == .suspended { return unsafe leavingWithoutStack(s) }
    if _slowPath(unsafe s.pointee.readOnlyFailure != .none) && result == .none && !m.failed {
        // Module 8: a store primitive refused a read-only object; send
        // attemptToModify:at:value: in place of its answer.
        return unsafe attemptToModifyFromPrimitive(s, argc, length)
    }
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

/// No room for the next frame: grow the Process's stack (module 8) and
/// activate again, or the error. A closure's activation grows through
/// `closureStackOverflow`.
@inline(never)
func stackOverflow(_ s: StatePointer, _ pc: UnsafePointer<UInt8>, _ sp: UnsafeMutablePointer<UInt64>,
                   _ fp: UnsafeMutablePointer<UInt64>, _ hdr: UnsafeMutablePointer<UInt64>,
                   _ method: UInt64, _ length: Int) -> Regs {
    let om = unsafe s.pointee.om
    if let r = unsafe grown(s, pc, sp, fp, hdr, method) {
        let argc = untagged(om.load(Oop(raw: method), MethodLayout.argc).raw)
        if methodFlags(om, method) & MethodFlags.block != 0, let c = unsafe activateClosure(s, om, r, argc, length) { return c }
        return unsafe activate(s, om, r, method, argc, length)
    }
    let argc = untagged(om.load(Oop(raw: method), MethodLayout.argc).raw)
    return unsafe failAt(s, pc, sp, fp, hdr, length, .stackOverflow, om.load(Oop(raw: method), MethodLayout.selector).raw,
                         (sp - argc).pointee)
}

/// The registers on a stack grown to fit `method`'s frame, or nil.
@inline(__always)
func grown(_ s: StatePointer, _ pc: UnsafePointer<UInt8>, _ sp: UnsafeMutablePointer<UInt64>,
           _ fp: UnsafeMutablePointer<UInt64>, _ hdr: UnsafeMutablePointer<UInt64>, _ method: UInt64) -> Regs? {
    let om = unsafe s.pointee.om
    let mb = om.stateWord(method)
    let need = untagged(om.loadAtomic(bodyOffset: mb, MethodLayout.temps)) &+ Frame.headerWords
        &+ untagged(om.loadAtomic(bodyOffset: mb, MethodLayout.maxStack)) &+ 2
    unsafe save(s, pc, sp, fp, hdr)
    guard unsafe growStack(s, needed: need) else { return nil }
    return unsafe restore(s)
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
