import Darwin

// AOT 1 (docs/modules/aot.md): the interface native code calls the VM
// through, and the driver above both engines.
//
// Every wrapper is a C-callable function of scalars: the worker, the pc as
// a bytecode offset, the registers sp, fp and hdr as pointers, and the
// instruction's operands. It turns the pc into the bytecode pointer the
// VM's slow paths take (from the frame's method, read now), runs the very
// slow path the dispatch loop runs for that instruction, and answers where
// native code goes on (`nativeContinue`):
//
//   - nil: return to the driver. The state stopped running (the Process
//     left, returned or failed), or the next frame is not native (its
//     method has no binding, its pc is no resume point, its depth is not
//     the traced one there); then the registers are saved for the
//     interpreter.
//   - `nativeCont` (1): the same frame at the expected pc with the traced
//     depth: native code goes on inline, re-reading its operands from the
//     frame.
//   - a function: tail-call it with the frame, the top of its operands
//     and the pc in the worker's `native.out` (rule 6: native code takes
//     fp, hdr and the value from what the VM answered).
//
// Nothing here allocates a Swift object or retains one (`just arc-check`).

/// The answer "go on inline".
var nativeCont: UnsafeRawPointer {
    @inline(__always) get { unsafe UnsafeRawPointer(bitPattern: 1).unsafelyUnwrapped }
}

typealias NP = UnsafeMutablePointer<UInt64>
typealias NativeAnswer = UnsafeRawPointer?

@_transparent
func nState(_ w: UnsafeMutableRawPointer) -> StatePointer { unsafe w.assumingMemoryBound(to: InterpreterState.self) }

/// The running method's bytecodes base for a frame header.
@inline(__always)
func nCode(_ s: StatePointer, _ hdr: NP) -> UnsafePointer<UInt8> {
    let om = unsafe s.pointee.om
    return unsafe om.bytesBase(om.load(Oop(raw: hdr.pointee), MethodLayout.bytecodes))
}

// MARK: - where to go on

/// The resume function and pc for registers `r` of a frame, or nil when
/// native code cannot continue it: no binding, a pc that is not a resume
/// point of the method's group, an operand depth other than the traced
/// one. `entry` answers the pc the function takes.
@inline(__always)
func nativeResume(_ s: StatePointer, _ r: Regs) -> (fn: UnsafeRawPointer, pc: UInt64)? {
    let w = unsafe workerOf(s)
    guard let table = unsafe w.pointee.native.table, unsafe r.hdr != s.pointee.stackBase,
          unsafe r.pc != UnsafePointer(s.pointee.leaveCode) else { return nil }
    guard let g = unsafe nativeGroup(table, r.hdr.pointee) else { return nil }
    let pc = unsafe r.pc - r.code
    guard pc >= 0, unsafe pc < Int(g.load(fromByteOffset: GroupOffset.codeLen, as: UInt64.self)) else { return nil }
    let depths = unsafe g.load(fromByteOffset: GroupOffset.depth, as: UnsafePointer<Int16>.self)
    guard unsafe Int(depths[pc]) == r.sp - r.hdr - (Frame.headerWords - 1) else { return nil }
    let rx = unsafe g.load(fromByteOffset: GroupOffset.rx, as: UnsafePointer<Int32>.self)
    let i = unsafe rx[pc]
    if i >= 0 {
        let resume = unsafe w.pointee.native.module.unsafelyUnwrapped.load(fromByteOffset: ModuleOffset.resume, as: UnsafeRawPointer.self)
        let e = unsafe resume + Int(i) * 16
        return unsafe (e.load(as: UnsafeRawPointer.self), UInt64(e.load(fromByteOffset: 8, as: UInt32.self)))
    }
    return unsafe (g.load(fromByteOffset: GroupOffset.cold, as: UnsafeRawPointer.self), UInt64(pc))
}

/// Rule 11: a Process that steps runs interpreted (an interrupt is run by
/// `runSlice` before the driver starts, and delivered at polls).
@inline(__always)
func nativeStepping(_ s: StatePointer) -> Bool {
    let w = unsafe workerOf(s)
    guard let vm = unsafe w.pointee.vm, unsafe w.pointee.record >= 0 else { return false }
    return unsafe records(vm, w.pointee.record).pointee.stepMode != 0
}

/// Where native code goes on after a slow path answered `r`, from a frame
/// whose header index was `h0` and whose next instruction was at
/// `expected`. Marks a frame the slow path activated directly above the
/// native one (its return then resumes the caller natively, as a native
/// send's frame does).
@inline(never)
func nativeContinue(_ s: StatePointer, _ r: Regs, _ h0: Int, _ expected: UInt64) -> NativeAnswer {
    if unsafe s.pointee.exit != .running { return nil }
    let w = unsafe workerOf(s)
    unsafe w.pointee.native.counters.slowCalls &+= 1
    if unsafe r.pc == UnsafePointer(s.pointee.leaveCode) { return nil }  // saved by whoever left
    let base = unsafe s.pointee.stackBase
    if unsafe nativeStepping(s) {
        unsafe save(s, r.pc, r.sp, r.fp, r.hdr)
        unsafe w.pointee.native.counters.toInterpreterStepping &+= 1
        return nil
    }
    guard let (fn, pc) = unsafe nativeResume(s, r) else {
        unsafe save(s, r.pc, r.sp, r.fp, r.hdr)
        unsafe w.pointee.native.counters.toInterpreterUnbound &+= 1
        return nil
    }
    if unsafe r.hdr - base == h0 && UInt64(r.pc - r.code) == expected { return unsafe nativeCont }
    unsafe markCaller(s, r, h0)
    unsafe w.pointee.native.out = NativeOut(fp: r.fp, hdr: r.hdr, v: r.sp.pointee, pc: pc)
    unsafe w.pointee.native.counters.resumes &+= 1
    return unsafe fn
}

/// A frame the VM activated with an empty context word directly above the
/// native frame at header `h0`, for a method with no native code, gets the
/// native marker of its caller's resume point (when the caller's group has
/// one there and the caller's depth after the return will be the traced
/// one): its return in the interpreter then leaves for the driver
/// (`returnSlow`), which resumes the caller natively. A native callee needs
/// none: a native return finds its caller's resume function by lookup.
@inline(__always)
func markCaller(_ s: StatePointer, _ r: Regs, _ h0: Int) {
    let base = unsafe s.pointee.stackBase
    guard unsafe r.hdr - base > h0, unsafe r.hdr[Frame.context] == Frame.emptyContext,
          unsafe r.hdr[Frame.callerHdr] == tagged(h0), h0 > 0,
          let table = unsafe workerOf(s).pointee.native.table,
          unsafe nativeGroup(table, r.hdr[Frame.method]) == nil,
          let g = unsafe nativeGroup(table, base[h0]) else { return }
    let pc = unsafe untagged(r.hdr[Frame.callerPC])
    guard pc >= 0, unsafe pc < Int(g.load(fromByteOffset: GroupOffset.codeLen, as: UInt64.self)) else { return }
    let i = unsafe g.load(fromByteOffset: GroupOffset.rx, as: UnsafePointer<Int32>.self)[pc]
    let d = unsafe g.load(fromByteOffset: GroupOffset.depth, as: UnsafePointer<Int16>.self)[pc]
    guard i >= 0, unsafe Int(d) == (r.fp - base) - h0 - (Frame.headerWords - 1) else { return }
    unsafe r.hdr[Frame.context] = tagged(nativeMarkerBase &+ Int(i))
    unsafe workerOf(s).pointee.native.counters.markersSet &+= 1
}

// MARK: - the wrappers

/// Poll at a send (`pc` after it, `len` its length): the countdown ran out
/// or the flag is set. `nativeCont`: go on with the send, unpolled.
func nativePollSend(_ w: UnsafeMutableRawPointer, _ pc: UInt64, _ sp: NP, _ fp: NP, _ hdr: NP, _ len: UInt64) -> NativeAnswer {
    let s = unsafe nState(w)
    let h0 = unsafe hdr - s.pointee.stackBase
    unsafe flushForPoll(s, nCode(s, hdr) + Int(pc), sp, fp, hdr)
    if unsafe pollSlow(s, rewind: Int(len)) { return nil }
    if unsafe nativeStepping(s) {
        // Rule 11: the interpreter runs the send again, polled.
        unsafe s.pointee.regs.pc &-= Int(len)
        unsafe workerOf(s).pointee.native.counters.toInterpreterStepping &+= 1
        return nil
    }
    // The frame stays as it was (a poll moves no frame): the send goes on.
    // Its registers here are the send's own (the pc after it, its operands
    // still on the stack), which no resume point has: never resolved.
    _ = h0
    return unsafe nativeCont
}

/// Poll at a backward jump (`pc` its target).
func nativePollJump(_ w: UnsafeMutableRawPointer, _ pc: UInt64, _ sp: NP, _ fp: NP, _ hdr: NP) -> NativeAnswer {
    let s = unsafe nState(w)
    let h0 = unsafe hdr - s.pointee.stackBase
    unsafe flushForPoll(s, nCode(s, hdr) + Int(pc), sp, fp, hdr)
    if unsafe pollSlow(s, rewind: 0) { return nil }
    if unsafe nativeStepping(s) {
        unsafe workerOf(s).pointee.native.counters.toInterpreterStepping &+= 1
        return nil
    }
    _ = h0
    return unsafe nativeCont
}

/// A lookup cache miss: the full lookup, the line filled; 0 when nothing
/// understands the selector. No pause.
func nativeLookup(_ w: UnsafeMutableRawPointer, _ cls: UInt64, _ sel: UInt64) -> UInt64 {
    unsafe lookupMiss(nState(w), cls, sel)
}

/// `doesNotUnderstand:` for the send that ended at `pc`.
func nativeDNU(_ w: UnsafeMutableRawPointer, _ pc: UInt64, _ sp: NP, _ fp: NP, _ hdr: NP, _ sel: UInt64,
               _ argcLen: UInt64) -> NativeAnswer {
    let s = unsafe nState(w)
    let h0 = unsafe hdr - s.pointee.stackBase
    let r = unsafe doesNotUnderstand(s, nCode(s, hdr) + Int(pc), sp, fp, hdr, sel, Int(argcLen & 0xFF), Int(argcLen >> 8))
    return unsafe nativeContinue(s, r, h0, pc)
}

/// A send found `method` with no native code, or a primitive: the VM's
/// own invoke (primitive, activation primitive, or an interpreted frame).
func nativeInvoke(_ w: UnsafeMutableRawPointer, _ pc: UInt64, _ sp: NP, _ fp: NP, _ hdr: NP, _ method: UInt64,
                  _ argcLen: UInt64) -> NativeAnswer {
    let s = unsafe nState(w)
    let h0 = unsafe hdr - s.pointee.stackBase
    let r = unsafe invoke(s, s.pointee.om, regsAt(s, nCode(s, hdr) + Int(pc), sp, fp, hdr), method, Int(argcLen & 0xFF),
                          Int(argcLen >> 8))
    return unsafe nativeContinue(s, r, h0, pc)
}

/// A native send that found no line in the lookup cache, or a method with
/// no native code or a primitive (`method` 0 when nothing understands it): the
/// VM's own send from the instruction that ended at `pc` (the count and
/// the poll done): the lookup, `doesNotUnderstand:`, the invoke. Never
/// answers `nativeCont`: the continuation at `pc` is the resume function
/// after the send.
func nativeSendSlow(_ w: UnsafeMutableRawPointer, _ pc: UInt64, _ sp: NP, _ fp: NP, _ hdr: NP, _ sel: UInt64,
                    _ argcLen: UInt64, _ method: UInt64) -> NativeAnswer {
    let s = unsafe nState(w)
    let h0 = unsafe hdr - s.pointee.stackBase
    let argc = Int(argcLen & 0xFF), length = Int(argcLen >> 8)
    let code = unsafe nCode(s, hdr) + Int(pc)
    var m = method
    if m == 0 {
        let om = unsafe s.pointee.om
        m = unsafe lookupMiss(s, classIndexOf(om, (sp - argc).pointee), sel)
        if m == 0 {
            return unsafe nativeContinue(s, doesNotUnderstand(s, code, sp, fp, hdr, sel, argc, length), h0, UInt64.max)
        }
    }
    let r = unsafe invoke(s, s.pointee.om, regsAt(s, code, sp, fp, hdr), m, argc, length)
    return unsafe nativeContinue(s, r, h0, UInt64.max)
}

/// A special send whose inline fast path did not apply (`pc` after it).
func nativeSpecial(_ w: UnsafeMutableRawPointer, _ pc: UInt64, _ sp: NP, _ fp: NP, _ hdr: NP, _ special: UInt64) -> NativeAnswer {
    let s = unsafe nState(w)
    let h0 = unsafe hdr - s.pointee.stackBase
    let r = unsafe specialSend(s, nCode(s, hdr) + Int(pc), sp, fp, hdr, Int(special))
    return unsafe nativeContinue(s, r, h0, pc)
}

/// The instruction that starts at `pc`, run by the VM's own out-of-line
/// code for it, exactly as the dispatch loop calls it.
func nativeExec(_ w: UnsafeMutableRawPointer, _ pc: UInt64, _ sp: NP, _ fp: NP, _ hdr: NP) -> NativeAnswer {
    let s = unsafe nState(w)
    let h0 = unsafe hdr - s.pointee.stackBase
    let p = unsafe nCode(s, hdr) + Int(pc)
    let r: Regs
    var length = 1
    switch unsafe Opcode.decode(p.pointee)?.base {
    case .ext?:
        let next = unsafe Opcode.decode(p[2])?.base
        length = 2 &+ (next?.length ?? 0)
        r = unsafe extendedInstruction(s, p + 1, sp, fp, hdr)
    case .sendSuper?:
        length = 3
        r = unsafe superSend(s, p + 3, sp, fp, hdr, Int(p[1]), Int(p[2]), 3)
    case .pushClosure?:
        length = 3
        r = unsafe pushClosure(s, p + 3, sp, fp, hdr, Int(p[1]), Int(p[2]))
    case .pushNewArray?:
        length = 2
        r = unsafe pushNewArray(s, p + 2, sp, fp, hdr, Int(p[1]))
    case .nonlocalReturn?:
        r = unsafe nonLocalReturn(s, p + 1, sp, fp, hdr)
    case .storeIvar?:
        length = 2
        let n = unsafe Int(p[1])
        let rcv = unsafe fp.pointee
        let om = unsafe s.pointee.om
        if !canStore(om, rcv, n) {
            r = unsafe storeRefused(s, p + 2, sp, fp, hdr, rcv, n, 2, .storeIvar)
        } else {
            unsafe storeWithBarrier(s, om, Oop(raw: rcv), n, Oop(raw: sp.pointee), .storeIvar)
            return unsafe nativeCont
        }
    case .pushTempVectorSlot?, .storeTempVectorSlot?:
        length = 3
        r = unsafe v1Instruction(s, p + 1, sp, fp, hdr)
    case .ne?, .notIdentical?, .at?, .size?, .classOf?, .isNil?, .notNil?, .pushThisContext?:
        r = unsafe v1Instruction(s, p + 1, sp, fp, hdr)
    case let op? where op.rawValue >= Opcode.add.rawValue && op.rawValue <= Opcode.notNil.rawValue:
        // The special sends are contiguous from `add`, in selector order.
        r = unsafe specialSend(s, p + 1, sp, fp, hdr, Int(op.rawValue &- Opcode.add.rawValue) &<< 8 | op.specialArgc)
    case _?:
        r = unsafe failAt(s, p + 1, sp, fp, hdr, 1, .invalidBytecode, 0, fp.pointee)
    case nil:
        r = unsafe failAt(s, p + 1, sp, fp, hdr, 1, .invalidBytecode, 0, fp.pointee)
    }
    return unsafe nativeContinue(s, r, h0, pc &+ UInt64(length))
}

/// A return whose context word is not a native marker (`pc` after the
/// return instruction): the VM's return, `returnSlow` included.
func nativeReturn(_ w: UnsafeMutableRawPointer, _ pc: UInt64, _ sp: NP, _ fp: NP, _ hdr: NP, _ v: UInt64) -> NativeAnswer {
    let s = unsafe nState(w)
    let h0 = unsafe hdr - s.pointee.stackBase
    let r = unsafe doReturn(s, s.pointee.om, regsAt(s, nCode(s, hdr) + Int(pc), sp, fp, hdr), v)
    return unsafe nativeContinue(s, r, h0, UInt64.max)
}

/// An error at the instruction of `kindLen & 0xFF` bytes that ended at
/// `pc`: kind 0 an invalid slot access, 1 a non-Boolean jump.
func nativeFail(_ w: UnsafeMutableRawPointer, _ pc: UInt64, _ sp: NP, _ fp: NP, _ hdr: NP, _ kindLen: UInt64,
                _ value: UInt64) -> NativeAnswer {
    let s = unsafe nState(w)
    let kind: VMError.Kind = kindLen >> 8 == 1 ? .mustBeBoolean : .invalidSlotAccess
    _ = unsafe failAt(s, nCode(s, hdr) + Int(pc), sp, fp, hdr, Int(kindLen & 0xFF), kind, 0, value)
    return nil
}

/// A native activation found no room for the frame (`pc`, `sp`, `fp` and
/// `hdr` the caller's after its send): the VM's own stack overflow, which
/// grows the stack and activates the method interpreted-style, or fails.
func nativeOverflow(_ w: UnsafeMutableRawPointer, _ pc: UInt64, _ sp: NP, _ fp: NP, _ hdr: NP, _ method: UInt64,
                    _ len: UInt64) -> NativeAnswer {
    let s = unsafe nState(w)
    let h0 = unsafe hdr - s.pointee.stackBase
    let r = unsafe stackOverflow(s, nCode(s, hdr) + Int(pc), sp, fp, hdr, method, Int(len))
    return unsafe nativeContinue(s, r, h0, pc)
}

/// The interface table the generated code calls through, in the order its
/// prelude declares (`KVT`).
func makeNativeInterface() -> UnsafeMutablePointer<UnsafeRawPointer?> {
    typealias Fn6 = @convention(c) (UnsafeMutableRawPointer, UInt64, NP, NP, NP, UInt64) -> NativeAnswer
    typealias Fn5 = @convention(c) (UnsafeMutableRawPointer, UInt64, NP, NP, NP) -> NativeAnswer
    typealias Fn7 = @convention(c) (UnsafeMutableRawPointer, UInt64, NP, NP, NP, UInt64, UInt64) -> NativeAnswer
    typealias Lookup = @convention(c) (UnsafeMutableRawPointer, UInt64, UInt64) -> UInt64
    typealias Fn8 = @convention(c) (UnsafeMutableRawPointer, UInt64, NP, NP, NP, UInt64, UInt64, UInt64) -> NativeAnswer
    let t = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: 16)
    unsafe t.initialize(repeating: nil, count: 16)
    unsafe t[0] = unsafeBitCast(nativePollSend as Fn6, to: UnsafeRawPointer.self)
    unsafe t[1] = unsafeBitCast(nativePollJump as Fn5, to: UnsafeRawPointer.self)
    unsafe t[2] = unsafeBitCast(nativeLookup as Lookup, to: UnsafeRawPointer.self)
    unsafe t[3] = unsafeBitCast(nativeDNU as Fn7, to: UnsafeRawPointer.self)
    unsafe t[4] = unsafeBitCast(nativeInvoke as Fn7, to: UnsafeRawPointer.self)
    unsafe t[5] = unsafeBitCast(nativeSpecial as Fn6, to: UnsafeRawPointer.self)
    unsafe t[6] = unsafeBitCast(nativeExec as Fn5, to: UnsafeRawPointer.self)
    unsafe t[7] = unsafeBitCast(nativeReturn as Fn6, to: UnsafeRawPointer.self)
    unsafe t[8] = unsafeBitCast(nativeFail as Fn7, to: UnsafeRawPointer.self)
    unsafe t[9] = unsafeBitCast(nativeOverflow as Fn7, to: UnsafeRawPointer.self)
    unsafe t[10] = unsafeBitCast(nativeSendSlow as Fn8, to: UnsafeRawPointer.self)
    return unsafe t
}

// MARK: - the driver

/// The driver (rule 5): above both engines, it runs the registers `start`
/// until the state stops running. With no module bound it is `interpret`.
/// Native code runs while the frame it continues is a resume point of a
/// bound method; the interpreter runs everything else, and leaves for
/// native code at a `pollSlow` or a `returnSlow` into a marked frame
/// (`native.switchToNative`). Neither engine calls the other.
@inline(never)
func drive(_ s: StatePointer, _ start: Regs) {
    let w = unsafe workerOf(s)
    guard unsafe w.pointee.native.table != nil else {
        unsafe interpret(s, start)
        return
    }
    var r = start
    unsafe w.pointee.native.switchToNative = false
    while unsafe s.pointee.exit == .running {
        if unsafe !nativeStepping(s), let (fn, pc) = unsafe nativeResume(s, r) {
            let enter = unsafe unsafeBitCast(w.pointee.native.module.unsafelyUnwrapped.load(fromByteOffset: ModuleOffset.enter,
                                                                                              as: UnsafeRawPointer.self),
                                             to: NativeEnter.self)
            unsafe w.pointee.native.counters.entries &+= 1
            unsafe w.pointee.native.inNative = 1
            unsafe enter(UnsafeMutableRawPointer(s), fn, r.fp, r.hdr, r.sp.pointee, pc)
            unsafe w.pointee.native.inNative = 0
            if unsafe s.pointee.exit != .running { return }
            r = unsafe restore(s)
            continue
        }
        unsafe interpret(s, r)
        if unsafe s.pointee.exit == .running && w.pointee.native.switchToNative {
            unsafe w.pointee.native.switchToNative = false
            r = unsafe restore(s)
            continue
        }
        return
    }
}

/// `pollSlow`'s switch (rule 8, decided where a slow path already runs):
/// the interpreter, at a budget check, leaves for native code when the
/// frame's method is bound and the rewound pc is a resume point. The
/// registers are saved. Answers true when it left (the callers leave the
/// loop as for a Process that left).
@inline(never)
func interpreterLeavesForNative(_ s: StatePointer, rewind: Int) -> Bool {
    let w = unsafe workerOf(s)
    guard unsafe w.pointee.native.table != nil, unsafe w.pointee.native.inNative == 0, unsafe !nativeStepping(s),
          unsafe s.pointee.regs.hdr > 0 else { return false }
    var r = unsafe restore(s)
    unsafe r.pc -= rewind
    guard unsafe nativeResume(s, r) != nil else { return false }
    unsafe s.pointee.regs.pc &-= rewind
    unsafe w.pointee.native.switchToNative = true
    unsafe w.pointee.native.counters.toNativeAtPoll &+= 1
    return true
}

/// `returnSlow`'s switch: a frame a native caller marked returned in the
/// interpreter (`r` the caller's registers, the value pushed). With native
/// code running (a wrapper's return) the answer is the caller's registers;
/// in the interpreter they are saved and the loop leaves for the driver.
@inline(never)
func interpreterReturnsToNative(_ s: StatePointer, _ r: Regs) -> Regs {
    let w = unsafe workerOf(s)
    guard unsafe w.pointee.native.table != nil, unsafe w.pointee.native.inNative == 0 else { return r }
    unsafe save(s, r.pc, r.sp, r.fp, r.hdr)
    unsafe w.pointee.native.switchToNative = true
    unsafe w.pointee.native.counters.toNativeAtReturn &+= 1
    return unsafe leaving(s, r)
}
