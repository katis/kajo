import Darwin

// Ready queues, Process creation and termination, suspension and
// Semaphores (docs/modules/workers.md "Scheduler"). Everything that links a
// Process into a list, or reads or writes a Process's state, record or a
// Semaphore, holds the scheduler lock. Nothing allocates, parks, enters or
// leaves the VM while holding it.

typealias VMPointer = UnsafeMutablePointer<VMState>

// MARK: - locking

@inline(__always)
func schedLock(_ vm: VMPointer) {
    unsafe lockCounted(vm.pointee.schedLock, vm, contended: .schedContended, waitNs: .schedWaitNs)
    unsafe vm.count(.schedLocks)
}

@inline(__always)
func schedUnlock(_ vm: VMPointer) { unsafe pthread_mutex_unlock(vm.pointee.schedLock) }

// MARK: - slots

@inline(__always)
func intSlot(_ om: ObjectMemory, _ o: Oop, _ i: Int) -> Int { om.load(o, i).smallIntegerValue.asInt }

@inline(__always)
func setIntSlot(_ om: ObjectMemory, _ o: Oop, _ i: Int, _ v: Int) { om.store(o, i, Oop(smallInteger: Int64(v))) }

@inline(__always)
func queueIndex(main: Bool, priority: Int) -> Int { (main ? Priority.count : 0) &+ priority }

private let queueCount = Priority.count * Affinity.count

// MARK: - ready queues (scheduler lock held)

/// Put `p` at the back of its ready queue. Answers whether the main worker
/// must be woken; wakes an idle background worker for an "any" Process.
@discardableResult
func makeReadyLocked(_ vm: VMPointer, _ p: Oop, fromBlocked: Bool) -> Bool {
    let om = unsafe vm.pointee.om
    let nilObject = unsafe vm.pointee.nilObject
    let main = intSlot(om, p, ProcessLayout.affinity) == Affinity.main
    let q = queueIndex(main: main, priority: intSlot(om, p, ProcessLayout.priority))
    setIntSlot(om, p, ProcessLayout.state, Int(ProcessState.ready.rawValue))
    let r = unsafe records(vm, intSlot(om, p, ProcessLayout.record))
    if unsafe fromBlocked && r.pointee.runnableSince == 0 { unsafe r.pointee.runnableSince = ticks() }
    om.store(p, ProcessLayout.next, nilObject)
    let tail = unsafe Oop(raw: vm.pointee.queues[queueCount + q])
    if tail == .none {
        unsafe vm.pointee.queues[q] = p.raw
    } else {
        om.store(tail, ProcessLayout.next, p)
    }
    unsafe vm.pointee.queues[queueCount + q] = p.raw
    if main { return true }
    if unsafe vm.pointee.sched.pointee.idleWorkers > 0 { unsafe pthread_cond_signal(vm.pointee.schedCond) }
    return false
}

/// Take the highest-priority ready Process of one affinity at or above
/// `minPriority` and mark it running on `w`.
func dequeueLocked(_ vm: VMPointer, main: Bool, minPriority: Int, for w: WorkerPointer) -> Oop {
    let om = unsafe vm.pointee.om
    let nilObject = unsafe vm.pointee.nilObject
    var prio = Priority.count - 1
    while prio >= minPriority {
        let q = queueIndex(main: main, priority: prio)
        let head = unsafe Oop(raw: vm.pointee.queues[q])
        if head != .none {
            let next = om.load(head, ProcessLayout.next)
            unsafe vm.pointee.queues[q] = next == nilObject ? 0 : next.raw
            if next == nilObject { unsafe vm.pointee.queues[queueCount + q] = 0 }
            om.store(head, ProcessLayout.next, nilObject)
            setIntSlot(om, head, ProcessLayout.state, Int(ProcessState.running.rawValue))
            unsafe records(vm, intSlot(om, head, ProcessLayout.record)).pointee.runningOn = w.pointee.index
            return head
        }
        prio -= 1
    }
    return .none
}

func anyReadyLocked(_ vm: VMPointer, main: Bool) -> Bool {
    for prio in 0..<Priority.count where unsafe vm.pointee.queues[queueIndex(main: main, priority: prio)] != 0 {
        return true
    }
    return false
}

/// Unlink `p` from the list with the given head and tail words.
private func unlinkLocked(_ vm: VMPointer, head: inout Oop, tail: inout Oop, _ p: Oop) {
    let om = unsafe vm.pointee.om
    let nilObject = unsafe vm.pointee.nilObject
    var prev = Oop.none
    var cur = head
    while cur != .none && cur != nilObject {
        let next = om.load(cur, ProcessLayout.next)
        if cur == p {
            if prev == .none { head = next } else { om.store(prev, ProcessLayout.next, next) }
            if tail == p { tail = prev == .none ? nilObject : prev }
            om.store(p, ProcessLayout.next, nilObject)
            return
        }
        prev = cur
        cur = next
    }
}

/// A main-affine Process became ready somewhere other than on the main
/// worker: ask the shell for a turn.
@inline(__always)
func wake(_ vm: VMPointer, _ w: WorkerPointer, _ needMain: Bool) {
    if unsafe needMain && !w.pointee.isMain, let h = unsafe vm.pointee.hooks.wakeMain { unsafe h(vm.pointee.hooks.context) }
}

// MARK: - creation

/// A new ready Process running `receiver method` with `args` (as many as
/// the method takes; Smalltalk's fork passes at most one). Allocates the Process and its stack before
/// taking the lock; `receiver`, `args` and `exit` must be rooted by the
/// caller (a stack or the host's roots). `.none` when the record table is
/// full or the heap is (the error is then recorded on `w`).
func createProcess(_ vm: VMPointer, _ w: WorkerPointer, receiver: Oop, method: Oop, args: [Oop], priority: Int,
                   main: Bool, exit: Oop) -> Oop {
    let om = unsafe vm.pointee.om
    let nilObject = unsafe vm.pointee.nilObject
    unsafe perturb(vm, w)
    let m = unsafe Machine(state: w.pointer(to: \Worker.interp)!)
    let p = m.allocate(WellKnown.process, slots: ProcessLayout.size)
    if p == .none { return .none }
    let words = unsafe vm.pointee.config.stackWords
    let base = UnsafeMutablePointer<UInt64>.allocate(capacity: words)  // only [0, sp] is ever read
    // Not started: word 0 holds the method until the first run activates it.
    unsafe base[0] = method.raw
    unsafe base[1] = receiver.raw
    for (i, a) in args.enumerated() { unsafe base[2 + i] = a.raw }
    setIntSlot(om, p, ProcessLayout.priority, max(0, min(Priority.count - 1, priority)))
    setIntSlot(om, p, ProcessLayout.affinity, main ? Affinity.main : Affinity.any)
    setIntSlot(om, p, ProcessLayout.sp, 1 + args.count)
    setIntSlot(om, p, ProcessLayout.pc, -1)
    setIntSlot(om, p, ProcessLayout.fp, 0)
    setIntSlot(om, p, ProcessLayout.hdr, 0)
    om.store(p, ProcessLayout.exitSemaphore, exit == .none ? nilObject : exit)
    unsafe schedLock(vm)
    var ri = unsafe vm.pointee.sched.pointee.recordFree
    if ri >= 0 {
        unsafe vm.pointee.sched.pointee.recordFree = records(vm, ri).pointee.nextFree
    } else if unsafe vm.pointee.sched.pointee.recordHighWater < vm.pointee.config.recordCapacity {
        ri = unsafe vm.pointee.sched.pointee.recordHighWater
        unsafe vm.pointee.sched.pointee.recordHighWater += 1
    } else {
        unsafe schedUnlock(vm)
        unsafe base.deallocate()
        return .none
    }
    unsafe records(vm, ri).pointee = ProcessRecord(process: p, base: base, end: base + words)
    setIntSlot(om, p, ProcessLayout.record, ri)
    let id = unsafe vm.pointee.sched.pointee.nextId
    unsafe vm.pointee.sched.pointee.nextId += 1
    om.store(p, ProcessLayout.id, Oop(smallInteger: id))
    unsafe vm.pointee.sched.pointee.liveProcesses += 1
    let needMain = unsafe makeReadyLocked(vm, p, fromBlocked: true)
    unsafe schedUnlock(vm)
    unsafe vm.count(.forks)
    unsafe wake(vm, w, needMain)
    return p
}

// MARK: - termination

/// Terminate `p`, which is in no list and runs nowhere. Answers its stack
/// (to free after unlocking) and whether main must be woken.
private func finishLocked(_ vm: VMPointer, _ p: Oop, _ result: Oop) -> (UnsafeMutablePointer<UInt64>?, Bool) {
    let om = unsafe vm.pointee.om
    let nilObject = unsafe vm.pointee.nilObject
    let ri = intSlot(om, p, ProcessLayout.record)
    let base = unsafe records(vm, ri).pointee.base
    om.store(p, ProcessLayout.result, result)
    setIntSlot(om, p, ProcessLayout.state, Int(ProcessState.terminated.rawValue))
    setIntSlot(om, p, ProcessLayout.record, -1)
    om.store(p, ProcessLayout.waitingOn, nilObject)
    unsafe records(vm, ri).pointee = ProcessRecord(nextFree: vm.pointee.sched.pointee.recordFree)
    unsafe vm.pointee.sched.pointee.recordFree = ri
    unsafe vm.pointee.sched.pointee.liveProcesses -= 1
    if unsafe vm.pointee.sched.pointee.liveProcesses == 0 { unsafe pthread_cond_broadcast(vm.pointee.doneCond) }
    let sem = om.load(p, ProcessLayout.exitSemaphore)
    let needMain = unsafe sem != nilObject ? signalLocked(vm, sem) : false
    return unsafe (base, needMain)
}

/// The Process `w` runs has ended (returned, failed, or terminated): it
/// leaves the worker and terminates.
func terminateCurrent(_ vm: VMPointer, _ w: WorkerPointer, result: Oop) {
    let p = unsafe w.pointee.current
    unsafe schedLock(vm)
    unsafe detachLocked(vm, w)
    let (base, needMain) = unsafe finishLocked(vm, p, result)
    unsafe schedUnlock(vm)
    unsafe base?.deallocate()
    unsafe vm.count(.terminations)
    unsafe wake(vm, w, needMain)
}

/// Terminate `p` from another Process or the host: now if it is ready or
/// waiting, at its next budget check if it runs on a worker, never twice.
func terminateProcess(_ vm: VMPointer, _ w: WorkerPointer, _ p: Oop) {
    let om = unsafe vm.pointee.om
    unsafe schedLock(vm)
    if intSlot(om, p, ProcessLayout.state) == Int(ProcessState.terminated.rawValue) {
        unsafe schedUnlock(vm)
        return
    }
    let ri = intSlot(om, p, ProcessLayout.record)
    let r = unsafe records(vm, ri)
    // By its state, not only `runningOn`: a running Process is never
    // unlinked and freed under the worker running it.
    if unsafe r.pointee.runningOn >= 0 || intSlot(om, p, ProcessLayout.state) == Int(ProcessState.running.rawValue) {
        unsafe r.pointee.terminateRequested = true
        if unsafe r.pointee.runningOn >= 0 {
            unsafe vm.shared(r.pointee.runningOn).pointee.attention.store(ri + 1, ordering: .relaxed)
        }
        unsafe schedUnlock(vm)
        unsafe vm.count(.terminateRequests)
        return
    }
    unsafe unlinkLocked(vm, p)
    let (base, needMain) = unsafe finishLocked(vm, p, vm.pointee.nilObject)
    unsafe schedUnlock(vm)
    unsafe base?.deallocate()
    unsafe vm.count(.terminations)
    unsafe wake(vm, w, needMain)
}

/// Unlink a ready or waiting Process from its list.
private func unlinkLocked(_ vm: VMPointer, _ p: Oop) {
    let om = unsafe vm.pointee.om
    let nilObject = unsafe vm.pointee.nilObject
    if intSlot(om, p, ProcessLayout.state) == Int(ProcessState.waiting.rawValue) {
        let sem = om.load(p, ProcessLayout.waitingOn)
        var head = om.load(sem, SemaphoreLayout.firstWaiter), tail = om.load(sem, SemaphoreLayout.lastWaiter)
        unsafe unlinkLocked(vm, head: &head, tail: &tail, p)
        om.store(sem, SemaphoreLayout.firstWaiter, head)
        om.store(sem, SemaphoreLayout.lastWaiter, head == nilObject ? nilObject : tail)
    } else {
        let q = queueIndex(main: intSlot(om, p, ProcessLayout.affinity) == Affinity.main,
                           priority: intSlot(om, p, ProcessLayout.priority))
        var head = unsafe Oop(raw: vm.pointee.queues[q]), tail = unsafe Oop(raw: vm.pointee.queues[queueCount + q])
        if head == .none { head = nilObject }
        unsafe unlinkLocked(vm, head: &head, tail: &tail, p)
        unsafe vm.pointee.queues[q] = head == nilObject ? 0 : head.raw
        unsafe vm.pointee.queues[queueCount + q] = head == nilObject ? 0 : tail.raw
    }
}

// MARK: - suspension

/// The worker lets go of its Process: `current`, the record's `runningOn`
/// and the stack bounds. Lock held. Done before the Process is published
/// to any list, so no stop scans its stack through this worker's stale sp
/// and no other worker's `runningOn` is overwritten.
func detachLocked(_ vm: VMPointer, _ w: WorkerPointer, unconditionally: Bool = false) {
    let ri = unsafe w.pointee.record
    // Only while it still names this worker: a defence on top of the rule
    // (the broken order of the test switch clears it unconditionally, as
    // the experiment's code did).
    if unsafe ri >= 0 && (unconditionally || records(vm, ri).pointee.runningOn == w.pointee.index) {
        unsafe records(vm, ri).pointee.runningOn = -1
    }
    unsafe w.pointee.current = .none
    unsafe w.pointee.record = -1
    unsafe w.pointee.interp.stackBase = w.pointee.dummy
    unsafe w.pointee.interp.stackEnd = w.pointee.dummy + 16
}

/// Write the running Process's saved registers (`sp` and `pc` as given,
/// `fp` and `hdr` as the worker saved them) and detach it, unless the
/// broken order is switched on (then `finishSuspend` detaches). Lock held.
func suspendLocked(_ vm: VMPointer, _ w: WorkerPointer, sp: Int, pc: Int) {
    let om = unsafe vm.pointee.om
    let p = unsafe w.pointee.current
    let r = unsafe w.pointee.interp.regs
    setIntSlot(om, p, ProcessLayout.sp, sp)
    setIntSlot(om, p, ProcessLayout.pc, pc)
    setIntSlot(om, p, ProcessLayout.fp, r.fp)
    setIntSlot(om, p, ProcessLayout.hdr, r.hdr)
    if unsafe !vm.pointee.config.testSwitches.publishBeforeClearing { unsafe detachLocked(vm, w) }
}

/// After the lock is released: the loop leaves without touching the
/// stack again.
func finishSuspend(_ vm: VMPointer, _ w: WorkerPointer, _ reason: LeaveReason) {
    if unsafe vm.pointee.config.testSwitches.publishBeforeClearing {
        unsafe perturbWindow(vm, w)
        unsafe schedLock(vm)
        unsafe detachLocked(vm, w, unconditionally: true)
        unsafe schedUnlock(vm)
    }
    unsafe w.pointee.leave = reason
    unsafe w.pointee.interp.exit = .suspended
}

/// A terminate request is pending for the running Process: it terminates
/// instead of suspending (lock held). Answers true then.
func terminatePendingLocked(_ vm: VMPointer, _ w: WorkerPointer) -> Bool {
    let ri = unsafe w.pointee.record
    guard ri >= 0, unsafe records(vm, ri).pointee.terminateRequested else { return false }
    unsafe w.pointee.leave = .terminated
    unsafe w.pointee.interp.exit = .suspended
    return true
}

/// A completing primitive suspends its Process after the send: the
/// arguments are popped and `result` is pushed. Lock held.
func suspendAfterPrimitiveLocked(_ vm: VMPointer, _ w: WorkerPointer, argc: Int, result: Oop) {
    let top = unsafe w.pointee.interp.regs.sp &- argc
    unsafe w.pointee.interp.stackBase[top] = result.raw
    unsafe suspendLocked(vm, w, sp: top, pc: w.pointee.interp.regs.pc)
}

// MARK: - Semaphores

/// Signal with the lock held. Answers whether main must be woken.
func signalLocked(_ vm: VMPointer, _ sem: Oop) -> Bool {
    let om = unsafe vm.pointee.om
    let nilObject = unsafe vm.pointee.nilObject
    let first = om.load(sem, SemaphoreLayout.firstWaiter)
    if first == nilObject {
        setIntSlot(om, sem, SemaphoreLayout.excessSignals, intSlot(om, sem, SemaphoreLayout.excessSignals) &+ 1)
        return false
    }
    let next = om.load(first, ProcessLayout.next)
    om.store(sem, SemaphoreLayout.firstWaiter, next)
    if next == nilObject { om.store(sem, SemaphoreLayout.lastWaiter, nilObject) }
    om.store(first, ProcessLayout.next, nilObject)
    om.store(first, ProcessLayout.waitingOn, nilObject)
    return unsafe makeReadyLocked(vm, first, fromBlocked: true)
}

func signalSemaphore(_ vm: VMPointer, _ w: WorkerPointer, _ sem: Oop) {
    unsafe perturb(vm, w)
    unsafe schedLock(vm)
    let needMain = unsafe signalLocked(vm, sem)
    unsafe schedUnlock(vm)
    unsafe vm.count(.signals)
    unsafe wake(vm, w, needMain)
}

/// `sem wait` from the running Process: continue with an excess signal,
/// else suspend after the send at the end of the Semaphore's waiters.
/// Answers whether it suspended.
func waitSemaphore(_ vm: VMPointer, _ w: WorkerPointer, _ sem: Oop, argc: Int) -> Bool {
    let om = unsafe vm.pointee.om
    let nilObject = unsafe vm.pointee.nilObject
    unsafe perturb(vm, w)
    unsafe schedLock(vm)
    let excess = intSlot(om, sem, SemaphoreLayout.excessSignals)
    if excess > 0 {
        setIntSlot(om, sem, SemaphoreLayout.excessSignals, excess - 1)
        unsafe schedUnlock(vm)
        return false
    }
    if unsafe terminatePendingLocked(vm, w) {
        unsafe schedUnlock(vm)
        return true
    }
    let p = unsafe w.pointee.current
    unsafe records(vm, w.pointee.record).pointee.runnableSince = 0
    unsafe suspendAfterPrimitiveLocked(vm, w, argc: argc, result: sem)
    setIntSlot(om, p, ProcessLayout.state, Int(ProcessState.waiting.rawValue))
    om.store(p, ProcessLayout.waitingOn, sem)
    om.store(p, ProcessLayout.next, nilObject)
    let last = om.load(sem, SemaphoreLayout.lastWaiter)
    if last == nilObject { om.store(sem, SemaphoreLayout.firstWaiter, p) } else { om.store(last, ProcessLayout.next, p) }
    om.store(sem, SemaphoreLayout.lastWaiter, p)
    unsafe schedUnlock(vm)
    unsafe finishSuspend(vm, w, .suspended)
    unsafe vm.count(.waits)
    return true
}

/// Re-queue the running Process (yield, preemption, hop, detach): its
/// registers as given, at the back of its (possibly new) queue.
func requeueCurrent(_ vm: VMPointer, _ w: WorkerPointer, sp: Int, pc: Int, affinity: Int? = nil,
                    result: (argc: Int, value: Oop)? = nil, reason: LeaveReason, hop: Bool = false) {
    let om = unsafe vm.pointee.om
    unsafe schedLock(vm)
    if unsafe terminatePendingLocked(vm, w) {
        unsafe schedUnlock(vm)
        return
    }
    let p = unsafe w.pointee.current
    let r = unsafe records(vm, w.pointee.record)
    if hop {
        unsafe r.pointee.hopStart = ticks()
        unsafe r.pointee.runnableSince = r.pointee.hopStart
    }
    if affinity == Affinity.any { unsafe r.pointee.runnableSince = 0 }
    if let result {
        unsafe suspendAfterPrimitiveLocked(vm, w, argc: result.argc, result: result.value)
    } else {
        unsafe suspendLocked(vm, w, sp: sp, pc: pc)
    }
    if let affinity { setIntSlot(om, p, ProcessLayout.affinity, affinity) }
    let needMain = unsafe makeReadyLocked(vm, p, fromBlocked: false)
    unsafe schedUnlock(vm)
    unsafe finishSuspend(vm, w, reason)
    unsafe wake(vm, w, needMain)
}
