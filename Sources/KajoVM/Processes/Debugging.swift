import Darwin

// Module 9b: what the debugger and `Process>>terminate` need from the VM
// (docs/modules/development-protocol.md, ADR 0011 and ADR 0012).
//
//   155  Process primInterrupt: kind: another Process (ready, waiting or
//        running on another worker) runs `terminateUnwinding` the next time
//        it is resumed, as a send from where it stands with the discard
//        marker: its ensure: and ifCurtailed: blocks run in it, then it
//        ends. A waiting Process is taken off its Semaphore and made ready;
//        a running one leaves its worker at its next poll. Answers false
//        (nothing asked) for the active Process, a terminated one, and one
//        that has not started (no frame to unwind). Kind 1 is that
//        unwinding; kind 2 runs `stopForDebugger` instead (the protocol's
//        process.suspend): the Process stops for the debugger where it
//        stands.
//   156  Context primResend: anArray: the receiver is the caller of the
//        running frame and its pc is just after a send. The running frame
//        goes, the receiver runs again from that send instruction with
//        anArray's elements (the send's receiver, then its arguments) as
//        its operands: a frame restart (the method looked up again, its
//        current version) and the retry of a send after
//        doesNotUnderstand:. The kernel unwinds the frames above first
//        (`Context>>restartSendWith:`).
//   157  Context primSendBeforePc: {selector. argc} of the send instruction
//        that ends at the receiver's pc, or nil.
//   162  ProcessorScheduler class primAllProcesses: an Array of every live
//        Process (the record table's), padded with nil; the protocol's
//        process.list.
//   158  Process primStep: mode frame: aContext: the active Process steps
//        (mode 1 into, 2 over, 3 out, 0 off) relative to aContext, a live
//        frame of its own. Its countdown is kept at 1, so every send and
//        backward jump takes the poll's slow path, where `stepPoll` decides
//        whether it stops; the frame is marked (`FrameMarker.step`) so its
//        return stops the Process in its caller. A stop is the interrupt
//        `stopForDebugger`, run at the next resume of a Process requeued at
//        the poll (or at the return): the interpreter loop and the send and
//        return fast paths check nothing new.

enum InterruptKind {
    static let terminate = 1
    static let debugStop = 2
}

enum StepMode {
    static let off = 0
    static let into = 1
    static let over = 2
    static let out = 3
}

enum DebuggingPrimitives {
    static let table: [(number: Int, selector: String, argc: Int)] = [
        (155, "Process primInterrupt:", 1), (156, "Context primResend:", 1),
        (157, "Context primSendBeforePc", 0), (158, "Process primStep:frame:", 2),
        (162, "ProcessorScheduler class primAllProcesses", 0),
    ]
}

@inline(never)
func debuggingPrimitive(_ n: Int, _ m: Machine, _ c: PrimitiveCall) -> Oop {
    let w = unsafe workerOf(m.state)
    guard let vm = unsafe w.pointee.vm, unsafe w.pointee.current != .none else { return .none }
    switch n {
    case 155:
        guard c.argc == 1, c.receiver.isObject, m.classIndex(of: c.receiver) == WellKnown.process,
              c.arg0 == Oop(smallInteger: 1) || c.arg0 == Oop(smallInteger: 2) else { return .none }
        return m.boolean(unsafe interrupt(vm, w, c.receiver, kind: Int(c.arg0.smallIntegerValue)))
    case 162:
        guard c.argc == 0 else { return .none }
        unsafe schedLock(vm)
        let n = unsafe vm.pointee.sched.pointee.recordHighWater
        unsafe schedUnlock(vm)
        let a = m.allocate(WellKnown.array, slots: n)
        if a == .none { return .none }
        unsafe schedLock(vm)
        var k = 0
        for i in 0..<min(n, unsafe vm.pointee.sched.pointee.recordHighWater) {
            let r = unsafe records(vm, i)
            if unsafe r.pointee.base != nil && r.pointee.process != .none {
                m.store(a, k, unsafe r.pointee.process, .atPut)
                k += 1
            }
        }
        unsafe schedUnlock(vm)
        return a
    case 156:
        guard c.argc == 1 else { return .none }
        return resend(m, c.receiver, m.argument(0, of: c))
    case 157:
        guard c.argc == 0, let h = unsafe liveFrame(m.state, c.receiver) else { return .none }
        let pc = m.framePC(h)
        guard let send = sendEnding(m, method: Oop(raw: unsafe m.state.pointee.stackBase[h]), at: pc) else { return m.nilObject }
        let a = m.allocate(WellKnown.array, slots: 2, keeping: send.selector)
        if a == .none { return .none }
        m.store(a, 0, send.selector, .atPut)
        m.store(a, 1, Oop(smallInteger: Int64(send.argc)), .atPut)
        return a
    case 158:
        guard c.argc == 2, unsafe c.receiver == w.pointee.current, c.arg0.isSmallInteger,
              (0...7).contains(c.arg0.smallIntegerValue) else { return .none }
        // Bit 4: the frame goes on after a send that completed (a stop on
        // an error), so its first poll is not the stopped send run again.
        let mode = Int(c.arg0.smallIntegerValue) & 3
        let fresh = c.arg0.smallIntegerValue & 4 == 0
        let rec = unsafe records(vm, w.pointee.record)
        if mode == StepMode.off {
            unsafe rec.pointee.stepMode = StepMode.off
            return c.receiver
        }
        guard let f = unsafe liveFrame(m.state, c.arg1) else { return .none }
        unsafe rec.pointee.stepMode = mode
        unsafe rec.pointee.stepFrame = f
        unsafe rec.pointee.stepFresh = fresh
        unsafe m.state.pointee.countdown = 1
        // The frame's return stops the Process, unless the frame already
        // carries another marker (then the polls below it decide).
        let base = unsafe m.state.pointee.stackBase
        let cw = unsafe base[f + Frame.context]
        if cw == Frame.emptyContext {
            unsafe base[f + Frame.context] = tagged(Int(FrameMarker.step))
        } else if cw & Oop.objectTagMask == 0, m.om.load(Oop(raw: cw), ContextLayout.marker) == Oop(smallInteger: 0) {
            unsafe checkedStore(m.state, Oop(raw: cw), ContextLayout.marker, Oop(smallInteger: FrameMarker.step))
        }
        return c.receiver
    default:
        return .none
    }
}

/// Primitive 155's work: ask `p` to run the interrupt `kind` when next
/// resumed. Answers whether it was asked (or already was).
func interrupt(_ vm: VMPointer, _ w: WorkerPointer, _ p: Oop, kind: Int) -> Bool {
    let om = unsafe vm.pointee.om
    guard unsafe p != w.pointee.current else { return false }
    unsafe schedLock(vm)
    let state = intSlot(om, p, ProcessLayout.state)
    guard state != Int(ProcessState.terminated.rawValue), intSlot(om, p, ProcessLayout.pc) >= 0 else {
        unsafe schedUnlock(vm)
        return false
    }
    let ri = intSlot(om, p, ProcessLayout.record)
    let r = unsafe records(vm, ri)
    if unsafe r.pointee.interrupt != 0 || r.pointee.terminateRequested {
        unsafe schedUnlock(vm)
        return true
    }
    unsafe r.pointee.interrupt = kind
    var needMain = false
    if unsafe r.pointee.runningOn >= 0 || state == Int(ProcessState.running.rawValue) {
        // It leaves its worker at its next poll (`pollSlow`).
        if unsafe r.pointee.runningOn >= 0 {
            unsafe vm.shared(r.pointee.runningOn).pointee.attention.store(ri + 1, ordering: .relaxed)
        }
    } else if state == Int(ProcessState.waiting.rawValue) {
        unsafe unlinkLocked(vm, w, p)
        unsafe clearingStore(w, p, ProcessLayout.waitingOn, vm.pointee.nilObject)  // a deletion: the SATB barrier sees it
        needMain = unsafe makeReadyLocked(vm, w, p, fromBlocked: true)
    }
    unsafe schedUnlock(vm)
    unsafe vm.count(.interruptsAsked)
    unsafe wake(vm, w, needMain)
    return true
}

/// The interrupt `kind` of the Process being resumed (`runSlice`): the
/// Process itself is pushed and sent `terminateUnwinding` or
/// `stopForDebugger` from where it stands, the new frame marked discard,
/// so whatever it answers is dropped and the Process goes on as it was.
func runInterrupt(_ s: StatePointer, _ p: Oop, _ kind: Int) -> Regs {
    let base = unsafe s.pointee.stackBase
    // Every frame reserves one word past its operands (`activate`).
    let top = unsafe s.pointee.regs.sp + 1
    unsafe base[top] = p.raw
    unsafe s.pointee.regs.sp = top
    if let vm = unsafe workerOf(s).pointee.vm { unsafe vm.count(.interrupts) }
    let sel = kind == InterruptKind.terminate ? VMSelector.terminateUnwinding : VMSelector.stopForDebugger
    return unsafe markedSend(s, s.pointee.specialSelectors[sel], 0, FrameMarker.discard)
}

/// A stepped Process's poll (registers saved, pc after the instruction
/// that polled; `rewind` takes it back to the send that polled). Answers
/// true when the Process stopped (it left the worker).
func stepPoll(_ vm: VMPointer, _ w: WorkerPointer, _ s: StatePointer, rewind: Int) -> Bool {
    let rec = unsafe records(vm, w.pointee.record)
    let hdr = unsafe s.pointee.regs.hdr
    let f = unsafe rec.pointee.stepFrame
    var stop = false
    switch unsafe rec.pointee.stepMode {
    case StepMode.into:
        // While fresh, the polls above the frame are the debugger's own
        // (on the way back to the frame) and the first poll in it is the
        // send the Process stopped at, run again; the next poll stops.
        if unsafe rec.pointee.stepFresh {
            if hdr == f { unsafe rec.pointee.stepFresh = false }
            stop = hdr < f
        } else {
            stop = true
        }
    case StepMode.over:
        if hdr > f {
            stop = false
        } else if unsafe hdr == f && rec.pointee.stepFresh {
            unsafe rec.pointee.stepFresh = false
        } else {
            stop = true
        }
    default:
        stop = hdr < f
    }
    if !stop {
        unsafe s.pointee.countdown = 1
        return false
    }
    let r = unsafe s.pointee.regs
    unsafe stepStop(vm, w, sp: r.sp, pc: r.pc &- rewind)
    return true
}

/// The stepped Process stops: requeued with the debugger's interrupt.
private func stepStop(_ vm: VMPointer, _ w: WorkerPointer, sp: Int, pc: Int) {
    let ri = unsafe w.pointee.record
    unsafe records(vm, ri).pointee.stepMode = StepMode.off
    unsafe schedLock(vm)
    unsafe records(vm, ri).pointee.interrupt = InterruptKind.debugStop
    unsafe schedUnlock(vm)
    unsafe requeueCurrent(vm, w, sp: sp, pc: pc, reason: .suspended)
    unsafe vm.count(.stepStops)
}

/// A frame marked `FrameMarker.step` returned (`returnSlow`, `r` the
/// caller's registers with the value pushed): if its Process still steps
/// that frame, it stops in the caller after the send.
func stepAfterReturn(_ s: StatePointer, _ r: Regs, returning: Int) -> Regs {
    let w = unsafe workerOf(s)
    guard let vm = unsafe w.pointee.vm, unsafe w.pointee.record >= 0, unsafe r.hdr != s.pointee.stackBase else { return r }
    let rec = unsafe records(vm, w.pointee.record)
    guard unsafe rec.pointee.stepMode != StepMode.off && rec.pointee.stepFrame == returning else { return r }
    unsafe save(s, r.pc, r.sp, r.fp, r.hdr)
    let saved = unsafe s.pointee.regs
    unsafe stepStop(vm, w, sp: saved.sp, pc: saved.pc)
    return unsafe leavingWithoutStack(s)
}

/// The send instruction of `method` that ends exactly at `pc`: its
/// selector (a special send's from the special selectors) and argc.
func sendEnding(_ m: Machine, method: Oop, at pc: Int) -> (selector: Oop, argc: Int)? {
    let om = m.om
    guard method.isObject, om.classIndex(of: method) == WellKnown.method else { return nil }
    let bytes = om.bytes(of: om.load(method, MethodLayout.bytecodes))
    var at = 0
    while at < pc {
        guard let i = decodeInstruction(bytes, at: at) else { return nil }
        if at + i.length == pc {
            switch i.op {
            case .send, .sendSuper:
                let lits = om.load(method, MethodLayout.literals)
                guard i.a < Int(om.count(of: lits)) else { return nil }
                return (om.load(lits, i.a), i.b)
            default:
                guard i.op.specialSelector != nil else { return nil }
                return (Oop(raw: unsafe m.state.pointee.specialSelectors[i.op.specialIndex]), i.op.specialArgc)
            }
        }
        at += i.length
    }
    return nil
}

/// Primitive 156: `S primResend: operands` from the running frame R, whose
/// caller is S. Fails (nothing changed) unless S is live and R's caller, S's
/// pc ends a send of operands' size less one arguments, and the stack has
/// room.
private func resend(_ m: Machine, _ target: Oop, _ operands: Oop) -> Oop {
    let s = unsafe m.state
    let om = m.om
    let regs = unsafe s.pointee.regs
    let base = unsafe s.pointee.stackBase
    let rh = regs.hdr
    guard rh > 0, let sh = unsafe liveFrame(s, target), unsafe callerHeader(base, rh) == sh,
          operands.isObject, m.classIndex(of: operands) == WellKnown.array else { return .none }
    let returnPC = unsafe untagged(base[rh + Frame.callerPC])
    let method = unsafe Oop(raw: base[sh])
    guard let send = sendEnding(m, method: method, at: returnPC),
          Int(om.count(of: operands)) == send.argc + 1 else { return .none }
    let bytes = om.bytes(of: om.load(method, MethodLayout.bytecodes))
    // The send's start: decode from the beginning again.
    var at = 0, start = -1
    while at < returnPC, let i = decodeInstruction(bytes, at: at) {
        if at + i.length == returnPC { start = at }
        at += i.length
    }
    guard start >= 0 else { return .none }
    let rfp = unsafe frameFP(om, base, rh)
    let n = send.argc + 1
    guard unsafe base + rfp + n + 2 < s.pointee.stackEnd else { return .none }
    // R goes: its Context (if any) is detached first.
    let cw = unsafe base[rh + Frame.context]
    if cw & Oop.objectTagMask == 0 { m.detach(Oop(raw: cw), fp: rfp, hdr: rh, pc: regs.pc) }
    unsafe base[rh + Frame.context] = Frame.emptyContext
    for k in 0..<(n - 1) { unsafe base[rfp + k] = om.load(operands, k).raw }  // the stack is a root: no barrier
    let sfp = unsafe frameFP(om, base, sh)
    // primitiveSend pushes the answer (the last operand) at sp - 1.
    unsafe s.pointee.regs.sp = rfp + n
    unsafe s.pointee.regs.fp = sfp
    unsafe s.pointee.regs.hdr = sh
    unsafe s.pointee.regs.pc = start
    unsafe s.pointee.regs.method = method
    unsafe s.pointee.regs.receiver = Oop(raw: base[sfp])
    if let vm = unsafe workerOf(s).pointee.vm { unsafe vm.count(.resends) }
    return om.load(operands, n - 1)
}
