import Darwin

/// Run `p`, just dequeued for `w` (its record names `w`), until it leaves:
/// resume from its saved registers (re-deriving the cached bases from the
/// method, module 2's `restore`), or activate its bottom frame on its first
/// run. Terminates it when it returns, fails or is terminated.
func runSlice(_ vm: VMPointer, _ w: WorkerPointer, _ p: Oop) {
    let om = unsafe vm.pointee.om
    let s = unsafe w.pointer(to: \Worker.interp)!
    let ri = intSlot(om, p, ProcessLayout.record)
    precondition(unsafe ri >= 0 && records(vm, ri).pointee.process == p && records(vm, ri).pointee.base != nil,
                 "runSlice: Process \(p) state \(intSlot(om, p, ProcessLayout.state)) record \(ri)")
    let r = unsafe records(vm, ri)
    let base = unsafe r.pointee.base.unsafelyUnwrapped
    // Module 7: a parked stack is scanned for every young collection past
    // its H1 start that has not scanned it yet (SPEC "Processes").
    if let y = unsafe vm.pointee.young, unsafe barrierWord(vm.pointee.flag).pointee.load(ordering: .relaxed) > 1 {
        unsafe youngResumeCheck(vm, y, w, ri)
    }
    unsafe w.pointee.current = p
    unsafe w.pointee.record = ri
    unsafe s.pointee.stackBase = base
    unsafe s.pointee.stackEnd = r.pointee.end.unsafelyUnwrapped
    unsafe w.pointee.leave = .none
    unsafe s.pointee.exit = .running
    unsafe s.pointee.countdown = w.pointee.pollEvery
    unsafe w.pointee.freshSlice = true
    unsafe vm.count(.slices)
    let sp = intSlot(om, p, ProcessLayout.sp), pc = intSlot(om, p, ProcessLayout.pc)
    let start: Regs
    if pc < 0 {
        // First run: word 0 holds the method; activate it as the host would.
        let method = unsafe base[0]
        unsafe base[0] = vm.pointee.nilObject.raw
        unsafe s.pointee.regs = SavedRegisters(sp: sp)
        let leave = unsafe UnsafePointer(s.pointee.leaveCode)
        let host = unsafe Regs(pc: leave, sp: base + sp, fp: base, hdr: base, code: leave, lits: UnsafePointer(base))
        start = unsafe invoke(s, om, host, method, sp &- 1, 0)
    } else {
        let fp = intSlot(om, p, ProcessLayout.fp), hdr = intSlot(om, p, ProcessLayout.hdr)
        unsafe s.pointee.regs = SavedRegisters(pc: pc, sp: sp, fp: fp, hdr: hdr, receiver: Oop(raw: base[fp]),
                                               method: hdr > 0 ? Oop(raw: base[hdr]) : .none)
        start = unsafe restore(s)
    }
    unsafe interpret(s, start)
    switch unsafe s.pointee.exit {
    case .suspended:
        if unsafe w.pointee.leave == .terminated {
            // Module 8: the frames go away with the stack; their Contexts
            // are detached first (the registers were saved by the poll).
            unsafe detachAllContexts(s)
            unsafe terminateCurrent(vm, w, result: vm.pointee.nilObject)
        }
    case .returned:
        let result = unsafe s.pointee.regs.result
        // The result register is live only until the termination takes it
        // (concurrent-young amendment 8).
        if unsafe !vm.pointee.config.testSwitches.keepResultRegister { unsafe s.pointee.regs.result = .none }
        unsafe terminateCurrent(vm, w, result: result)
    case .running:
        // A primitive at the bottom of the Process answered: its result is
        // in the receiver's word.
        unsafe terminateCurrent(vm, w, result: Oop(raw: base[1]))
    case .error:
        unsafe recordError(vm, w)
        unsafe detachAllContexts(s)
        unsafe terminateCurrent(vm, w, result: vm.pointee.nilObject)
    }
}

/// A VMError ends the Process, never the VM: kept by Process id for the
/// host, counted. Cold.
@inline(never)
private func recordError(_ vm: VMPointer, _ w: WorkerPointer) {
    let s = unsafe w.pointee.interp
    let image = unsafe vm.pointee.image
    let e = unsafe s.error, r = unsafe s.regs
    let error = VMError(kind: e.kind, selector: e.selector == .none ? nil : image.symbolName(e.selector),
                        receiverClass: e.receiverClass == 0 ? nil : image.className(e.receiverClass),
                        method: r.method == .none ? nil : image.methodName(r.method), pc: r.pc, primitive: e.primitive)
    let id = unsafe vm.pointee.om.load(w.pointee.current, ProcessLayout.id).smallIntegerValue
    unsafe pthread_mutex_lock(vm.pointee.errorsLock)
    unsafe vm.pointee.errors.pointee.byProcess[id] = error
    unsafe pthread_mutex_unlock(vm.pointee.errorsLock)
    unsafe vm.count(.processErrors)
    if e.kind == .stackOverflow { unsafe vm.count(.stackOverflows) }
}

// MARK: - background workers

/// A background worker's thread: run "any" Processes until shutdown; with
/// nothing ready, leave the VM and wait untimed on the scheduler condition.
/// Every transition that makes work for it signals that condition under
/// the scheduler mutex: a Process made ready (`makeReadyLocked`), an
/// external signal (`signalFromOutside`), shutdown.
func backgroundLoop(_ vm: VMPointer, _ w: WorkerPointer) {
    let line = unsafe vm.shared(w.pointee.index)
    unsafe line.pointee.qos.store(qos_class_self().rawValue, ordering: .relaxed)
    unsafe line.pointee.machThread.store(pthread_mach_thread_np(pthread_self()), ordering: .relaxed)
    unsafe line.pointee.started.store(true, ordering: .releasing)
    unsafe enterVM(vm, w)
    while true {
        if unsafe externalPending(vm) { unsafe drainExternal(vm, w) }
        unsafe schedLock(vm)
        let p = unsafe dequeueLocked(vm, main: false, minPriority: 0, for: w)
        if p != .none {
            unsafe schedUnlock(vm)
            let slice = unsafe vm.pointee.config.sliceNs
            unsafe w.pointee.deadline = slice == 0 ? .max : ticks() &+ nsToTicks(slice)
            unsafe runSlice(vm, w, p)
            continue
        }
        if unsafe vm.pointee.sched.pointee.shutdown {
            unsafe schedUnlock(vm)
            break
        }
        unsafe vm.pointee.sched.pointee.idleWorkers += 1
        unsafe schedUnlock(vm)
        unsafe leaveVM(vm, w)
        let t0 = nanoseconds()
        unsafe schedLock(vm)
        while unsafe !vm.pointee.sched.pointee.shutdown && !anyReadyLocked(vm, main: false) && !externalPending(vm) {
            unsafe vm.count(.idleWaits)
            unsafe pthread_cond_wait(vm.pointee.schedCond, vm.pointee.schedLock)
            unsafe vm.count(.idleWakeups)
        }
        unsafe vm.pointee.sched.pointee.idleWorkers -= 1
        unsafe schedUnlock(vm)
        unsafe vm.count(.idleNs, nanoseconds() &- t0)
        unsafe enterVM(vm, w)
    }
    unsafe leaveVM(vm, w)
}

// MARK: - the main worker

/// What one main-thread turn cost, with the time spent waiting on stops
/// kept apart (AGENTS.md).
struct TurnStats: Sendable {
    var ns: UInt64 = 0
    /// The calling thread's CPU time in the turn: wall time minus the time
    /// the OS had it descheduled (and minus blocked waits).
    var cpuNs: UInt64 = 0
    var enterWaitNs: UInt64 = 0
    var leaveWaitNs: UInt64 = 0
    /// Parked in another worker's stop.
    var parkNs: UInt64 = 0
    /// Stopping the world itself (an allocation that collected).
    var stopNs: UInt64 = 0
    /// Module 4: of `parkNs`, the time this worker spent copying and
    /// sweeping in a scavenge's parallel phase (CPU work, not waiting).
    var collectorNs: UInt64 = 0
    /// Module 7: young collection on this worker in the turn: round
    /// acknowledgements, flips or its own collections, waits for the
    /// collector, for a pending stop or for collections before a stop.
    var youngNs: UInt64 = 0
    var acks: UInt64 = 0
    var slices = 0
    var preempted = false

    /// Everything that was not this turn's Smalltalk.
    var pausedNs: UInt64 { enterWaitNs &+ leaveWaitNs &+ parkNs &+ stopNs }
}

/// One turn of the main worker on the calling thread (the shell's main
/// thread): enter, drain, run main-affine Processes at or above
/// `minPriority` until none is ready or the budget is spent, leave.
func runMainTurn(_ vm: VMPointer, budgetNs: UInt64, minPriority: Int) -> TurnStats {
    let w = unsafe vm.worker(0)
    var st = TurnStats()
    let t0 = nanoseconds(), cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    let park0 = unsafe w.pointee.parkNs, stop0 = unsafe w.pointee.stopNs, gc0 = unsafe w.pointee.collectorNs
    let young0 = unsafe youngTurnNs(vm, 0)
    st.enterWaitNs = unsafe enterVM(vm, w)
    // The main worker runs at whatever QoS the shell's thread has: logged
    // per turn, as the background workers log theirs at start.
    unsafe vm.shared(0).pointee.qos.store(qos_class_self().rawValue, ordering: .relaxed)
    if unsafe externalPending(vm) { unsafe drainExternal(vm, w) }
    unsafe w.pointee.deadline = ticks() &+ nsToTicks(budgetNs)
    while unsafe ticks() < w.pointee.deadline {
        unsafe schedLock(vm)
        let p = unsafe dequeueLocked(vm, main: true, minPriority: minPriority, for: w)
        var hopStart: UInt64 = 0
        if p != .none {
            let r = unsafe records(vm, intSlot(vm.pointee.om, p, ProcessLayout.record))
            hopStart = unsafe r.pointee.hopStart
            unsafe r.pointee.hopStart = 0
            if hopStart != 0 { unsafe vm.pointee.sched.pointee.hopLatencies.append(ticksToNs(ticks() &- hopStart)) }
        }
        unsafe schedUnlock(vm)
        if p == .none { break }
        unsafe runSlice(vm, w, p)
        st.slices += 1
        if unsafe w.pointee.leave == .preempted {
            st.preempted = true
            break
        }
    }
    st.parkNs = unsafe w.pointee.parkNs &- park0
    st.collectorNs = unsafe w.pointee.collectorNs &- gc0
    st.stopNs = unsafe w.pointee.stopNs &- stop0
    let young1 = unsafe youngTurnNs(vm, 0)
    st.youngNs = young1.ns &- young0.ns
    st.acks = young1.acks &- young0.acks
    st.leaveWaitNs = unsafe leaveVM(vm, w)
    st.ns = nanoseconds() &- t0
    st.cpuNs = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- cpu0
    return st
}

/// Test hook: on the calling thread, run one "any" Process on worker `i`
/// (which has no thread of its own) for at most `budgetNs`. False if none
/// was ready.
func runOneSliceOn(_ vm: VMPointer, _ w: WorkerPointer, budgetNs: UInt64) -> Bool {
    unsafe enterVM(vm, w)
    if unsafe externalPending(vm) { unsafe drainExternal(vm, w) }
    unsafe schedLock(vm)
    let p = unsafe dequeueLocked(vm, main: w.pointee.isMain, minPriority: 0, for: w)
    unsafe schedUnlock(vm)
    if p != .none {
        unsafe w.pointee.deadline = budgetNs == .max ? .max : ticks() &+ nsToTicks(budgetNs)
        unsafe runSlice(vm, w, p)
    }
    unsafe leaveVM(vm, w)
    return p != .none
}

/// Every main-affine Process runnable for longer than `limitNs` gets one
/// report through the `stuck` hook. The shell calls it after a turn.
func checkStuckProcesses(_ vm: VMPointer, limitNs: UInt64) {
    let w = unsafe vm.worker(0)
    let om = unsafe vm.pointee.om, image = unsafe vm.pointee.image
    unsafe enterVM(vm, w)
    let now = ticks(), limit = nsToTicks(limitNs)
    var reports: [(Int64, String, Double)] = []
    unsafe schedLock(vm)
    for prio in 0..<Priority.count {
        var p = unsafe Oop(raw: vm.pointee.queues[queueIndex(main: true, priority: prio)])
        while unsafe p != .none && p != vm.pointee.nilObject {
            let r = unsafe records(vm, intSlot(om, p, ProcessLayout.record))
            if unsafe r.pointee.runnableSince != 0 && !r.pointee.stuckReported && now &- r.pointee.runnableSince > limit {
                unsafe r.pointee.stuckReported = true
                let hdr = intSlot(om, p, ProcessLayout.hdr)
                var name = "?"
                if hdr > 0, let base = unsafe r.pointee.base {
                    let method = unsafe Oop(raw: base[hdr + Frame.method])
                    name = image.symbolName(om.load(method, MethodLayout.selector)) ?? "?"
                }
                unsafe reports.append((om.load(p, ProcessLayout.id).smallIntegerValue, name,
                                Double(ticksToNs(now &- r.pointee.runnableSince)) / 1e6))
            }
            p = om.load(p, ProcessLayout.next)
        }
    }
    unsafe schedUnlock(vm)
    unsafe leaveVM(vm, w)
    for (id, name, ms) in reports {
        unsafe vm.count(.stuckReports)
        if let h = unsafe vm.pointee.hooks.stuck { name.withCString { unsafe h(vm.pointee.hooks.context, id, $0, ms) } }
    }
}
