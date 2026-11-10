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
/// A SmallInteger into a Process or Semaphore slot: no barrier, but the
/// object may be old and relocating (module 6's post-store check).
func setIntSlot(_ w: WorkerPointer, _ o: Oop, _ i: Int, _ v: Int) {
    unsafe checkedStore(w.pointer(to: \Worker.interp)!, o, i, Oop(smallInteger: Int64(v)))
}

@inline(__always)
func queueIndex(main: Bool, priority: Int) -> Int { (main ? Priority.count : 0) &+ priority }

private let queueCount = Priority.count * Affinity.count

// MARK: - ready queues (scheduler lock held)

/// Put `p` at the back of its ready queue. Answers whether the main worker
/// must be woken; wakes an idle background worker for an "any" Process.
@discardableResult
func makeReadyLocked(_ vm: VMPointer, _ w: WorkerPointer, _ p: Oop, fromBlocked: Bool) -> Bool {
    let om = unsafe vm.pointee.om
    let nilObject = unsafe vm.pointee.nilObject
    let main = intSlot(om, p, ProcessLayout.affinity) == Affinity.main
    let q = queueIndex(main: main, priority: intSlot(om, p, ProcessLayout.priority))
    unsafe setIntSlot(w, p, ProcessLayout.state, Int(ProcessState.ready.rawValue))
    let r = unsafe records(vm, intSlot(om, p, ProcessLayout.record))
    if unsafe fromBlocked && r.pointee.runnableSince == 0 { unsafe r.pointee.runnableSince = ticks() }
    unsafe clearingStore(w, p, ProcessLayout.next, nilObject)  // a deletion: the SATB barrier sees it
    let tail = unsafe Oop(raw: vm.pointee.queues[queueCount + q])
    if tail == .none {
        unsafe vm.pointee.queues[q] = p.raw
    } else {
        unsafe barrierStore(w, tail, ProcessLayout.next, p, .readyQueueLink)
    }
    unsafe vm.pointee.queues[queueCount + q] = p.raw
    if main { return true }
    if unsafe vm.pointee.sched.pointee.idleWorkers > 0 { unsafe pthread_cond_signal(vm.pointee.schedCond) }
    return false
}

/// Take the highest-priority ready Process of one affinity at or above
/// `minPriority` and mark it running on `w`.
func dequeueLocked(_ vm: VMPointer, main: Bool, minPriority: Int, for w: WorkerPointer) -> Oop {
    // Module 8c: a save holds the scheduler.
    if unsafe vm.pointee.sched.pointee.saveHold { return .none }
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
            unsafe clearingStore(w, head, ProcessLayout.next, nilObject)  // a deletion: the SATB barrier sees it
            unsafe setIntSlot(w, head, ProcessLayout.state, Int(ProcessState.running.rawValue))
            let ri = intSlot(om, head, ProcessLayout.record)
            let r = unsafe records(vm, ri)
            unsafe r.pointee.runningOn = w.pointee.index
            // The review fixes (item 14, kernel.F12): a Process resumed after a
            // wait that a signal completed (it took the signal) and asked to
            // terminate meanwhile runs on to its next poll, where the
            // terminate is taken as for a running Process: the instructions
            // right after `wait` (critical:'s `caught := true`, no send and no
            // poll between) run first, so the ensure block knows it holds the
            // Semaphore. A Process unlinked from its wait by the interrupt
            // itself has no wait length any more (`interrupt`) and runs it at
            // once, as every other resumed Process does.
            let afterWait = unsafe r.pointee.waitSendLength > 0
            unsafe r.pointee.waitSendLength = 0
            if unsafe afterWait && r.pointee.interrupt == InterruptKind.terminate {
                unsafe w.pointee.interrupt = 0
                unsafe vm.shared(w.pointee.index).pointee.attention.store(ri + 1, ordering: .relaxed)
                return head
            }
            // Module 9b: an interrupt goes with the Process to its worker.
            unsafe w.pointee.interrupt = r.pointee.interrupt
            unsafe r.pointee.interrupt = 0
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
private func unlinkLocked(_ vm: VMPointer, _ w: WorkerPointer, head: inout Oop, tail: inout Oop, _ p: Oop) {
    let om = unsafe vm.pointee.om
    let nilObject = unsafe vm.pointee.nilObject
    var prev = Oop.none
    var cur = head
    while cur != .none && cur != nilObject {
        let next = om.load(cur, ProcessLayout.next)
        if cur == p {
            if prev == .none { head = next } else { unsafe barrierStore(w, prev, ProcessLayout.next, next, .unlinkLink) }
            if tail == p { tail = prev == .none ? nilObject : prev }
            unsafe clearingStore(w, p, ProcessLayout.next, nilObject)  // a deletion: the SATB barrier sees it
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
    unsafe setIntSlot(w, p, ProcessLayout.priority, max(0, min(Priority.count - 1, priority)))
    unsafe setIntSlot(w, p, ProcessLayout.affinity, main ? Affinity.main : Affinity.any)
    unsafe setIntSlot(w, p, ProcessLayout.sp, 1 + args.count)
    unsafe setIntSlot(w, p, ProcessLayout.pc, -1)
    unsafe setIntSlot(w, p, ProcessLayout.fp, 0)
    unsafe setIntSlot(w, p, ProcessLayout.hdr, 0)
    // p was allocated above with no safepoint since: young (or old with
    // nothing young, without a nursery); the barrier is kept anyway.
    unsafe barrierStore(w, p, ProcessLayout.exitSemaphore, exit == .none ? nilObject : exit, .exitSemaphore)
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
    unsafe youngNewRecordLocked(vm, ri)
    unsafe setIntSlot(w, p, ProcessLayout.record, ri)
    let id = unsafe vm.pointee.sched.pointee.nextId
    unsafe vm.pointee.sched.pointee.nextId += 1
    om.store(p, ProcessLayout.id, Oop(smallInteger: id))
    unsafe vm.pointee.sched.pointee.liveProcesses += 1
    let needMain = unsafe makeReadyLocked(vm, w, p, fromBlocked: true)
    unsafe schedUnlock(vm)
    unsafe vm.count(.forks)
    unsafe wake(vm, w, needMain)
    return p
}

// MARK: - termination

/// Terminate `p`, which is in no list and runs nowhere. Answers its stack
/// (to free after unlocking) and whether main must be woken.
private func finishLocked(_ vm: VMPointer, _ w: WorkerPointer, _ p: Oop, _ result: Oop) -> (UnsafeMutablePointer<UInt64>?, Bool) {
    let om = unsafe vm.pointee.om
    let nilObject = unsafe vm.pointee.nilObject
    let ri = intSlot(om, p, ProcessLayout.record)
    let base = unsafe records(vm, ri).pointee.base
    unsafe barrierStore(w, p, ProcessLayout.result, result, .processResult)
    unsafe setIntSlot(w, p, ProcessLayout.state, Int(ProcessState.terminated.rawValue))
    unsafe setIntSlot(w, p, ProcessLayout.record, -1)
    unsafe clearingStore(w, p, ProcessLayout.waitingOn, nilObject)  // a deletion: the SATB barrier sees it
    unsafe records(vm, ri).pointee = ProcessRecord(nextFree: vm.pointee.sched.pointee.recordFree)
    unsafe vm.pointee.sched.pointee.recordFree = ri
    unsafe vm.pointee.sched.pointee.liveProcesses -= 1
    // Module 8b: the host may wait for this one Process (`waitUntilTerminated`).
    let watched = unsafe vm.pointee.sched.pointee.watchedId >= 0
        && om.load(p, ProcessLayout.id) == Oop(smallInteger: vm.pointee.sched.pointee.watchedId)
    if watched { unsafe vm.pointee.sched.pointee.watchedDone = true }
    if unsafe vm.pointee.sched.pointee.liveProcesses == 0 || watched { unsafe pthread_cond_broadcast(vm.pointee.doneCond) }
    let sem = om.load(p, ProcessLayout.exitSemaphore)
    let needMain = unsafe sem != nilObject ? signalLocked(vm, w, sem) : false
    return unsafe (base, needMain)
}

/// The Process `w` runs has ended (returned, failed, or terminated): it
/// leaves the worker and terminates.
func terminateCurrent(_ vm: VMPointer, _ w: WorkerPointer, result: Oop) {
    let p = unsafe w.pointee.current
    unsafe schedLock(vm)
    unsafe detachLocked(vm, w)
    let (base, needMain) = unsafe finishLocked(vm, w, p, result)
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
    unsafe unlinkLocked(vm, w, p)
    let (base, needMain) = unsafe finishLocked(vm, w, p, vm.pointee.nilObject)
    unsafe schedUnlock(vm)
    unsafe base?.deallocate()
    unsafe vm.count(.terminations)
    unsafe wake(vm, w, needMain)
}

/// Unlink a ready or waiting Process from its list.
func unlinkLocked(_ vm: VMPointer, _ w: WorkerPointer, _ p: Oop) {
    let om = unsafe vm.pointee.om
    let nilObject = unsafe vm.pointee.nilObject
    if intSlot(om, p, ProcessLayout.state) == Int(ProcessState.waiting.rawValue) {
        let sem = om.load(p, ProcessLayout.waitingOn)
        var head = om.load(sem, SemaphoreLayout.firstWaiter), tail = om.load(sem, SemaphoreLayout.lastWaiter)
        unsafe unlinkLocked(vm, w, head: &head, tail: &tail, p)
        unsafe barrierStore(w, sem, SemaphoreLayout.firstWaiter, head, .unlinkFirstWaiter)
        unsafe barrierStore(w, sem, SemaphoreLayout.lastWaiter, head == nilObject ? nilObject : tail, .unlinkLastWaiter)
    } else {
        let q = queueIndex(main: intSlot(om, p, ProcessLayout.affinity) == Affinity.main,
                           priority: intSlot(om, p, ProcessLayout.priority))
        var head = unsafe Oop(raw: vm.pointee.queues[q]), tail = unsafe Oop(raw: vm.pointee.queues[queueCount + q])
        if head == .none { head = nilObject }
        unsafe unlinkLocked(vm, w, head: &head, tail: &tail, p)
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
    let p = unsafe w.pointee.current
    let r = unsafe w.pointee.interp.regs
    unsafe setIntSlot(w, p, ProcessLayout.sp, sp)
    unsafe setIntSlot(w, p, ProcessLayout.pc, pc)
    unsafe setIntSlot(w, p, ProcessLayout.fp, r.fp)
    unsafe setIntSlot(w, p, ProcessLayout.hdr, r.hdr)
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
func signalLocked(_ vm: VMPointer, _ w: WorkerPointer, _ sem: Oop) -> Bool {
    let om = unsafe vm.pointee.om
    let nilObject = unsafe vm.pointee.nilObject
    let first = om.load(sem, SemaphoreLayout.firstWaiter)
    if first == nilObject {
        unsafe setIntSlot(w, sem, SemaphoreLayout.excessSignals, intSlot(om, sem, SemaphoreLayout.excessSignals) &+ 1)
        return false
    }
    let next = om.load(first, ProcessLayout.next)
    unsafe barrierStore(w, sem, SemaphoreLayout.firstWaiter, next, .firstWaiterOnSignal)
    if next == nilObject { unsafe clearingStore(w, sem, SemaphoreLayout.lastWaiter, nilObject) }  // a deletion: the SATB barrier sees it
    unsafe clearingStore(w, first, ProcessLayout.next, nilObject)  // a deletion: the SATB barrier sees it
    unsafe clearingStore(w, first, ProcessLayout.waitingOn, nilObject)  // a deletion: the SATB barrier sees it
    return unsafe makeReadyLocked(vm, w, first, fromBlocked: true)
}

func signalSemaphore(_ vm: VMPointer, _ w: WorkerPointer, _ sem: Oop) {
    unsafe perturb(vm, w)
    unsafe schedLock(vm)
    let needMain = unsafe signalLocked(vm, w, sem)
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
        unsafe setIntSlot(w, sem, SemaphoreLayout.excessSignals, excess - 1)
        unsafe schedUnlock(vm)
        return false
    }
    if unsafe terminatePendingLocked(vm, w) {
        unsafe schedUnlock(vm)
        return true
    }
    // Module 9b: an interrupt is pending (it was asked while the Process
    // ran elsewhere and its poll did not see it): it does not wait, it is
    // requeued and runs the interrupt when resumed.
    if unsafe records(vm, w.pointee.record).pointee.interrupt != 0 {
        unsafe schedUnlock(vm)
        let r = unsafe w.pointee.interp.regs
        unsafe requeueCurrent(vm, w, sp: r.sp, pc: r.pc &- w.pointee.interp.sendLength, reason: .suspended)
        return true
    }
    let p = unsafe w.pointee.current
    unsafe records(vm, w.pointee.record).pointee.runnableSince = 0
    unsafe records(vm, w.pointee.record).pointee.waitSendLength = argc == 0 ? w.pointee.interp.sendLength : 0
    unsafe suspendAfterPrimitiveLocked(vm, w, argc: argc, result: sem)
    unsafe setIntSlot(w, p, ProcessLayout.state, Int(ProcessState.waiting.rawValue))
    unsafe barrierStore(w, p, ProcessLayout.waitingOn, sem, .waitingOn)
    unsafe clearingStore(w, p, ProcessLayout.next, nilObject)  // a deletion: the SATB barrier sees it
    let last = om.load(sem, SemaphoreLayout.lastWaiter)
    if last == nilObject {
        unsafe barrierStore(w, sem, SemaphoreLayout.firstWaiter, p, .firstWaiterOnWait)
    } else {
        unsafe barrierStore(w, last, ProcessLayout.next, p, .waiterLink)
    }
    unsafe barrierStore(w, sem, SemaphoreLayout.lastWaiter, p, .lastWaiterOnWait)
    unsafe schedUnlock(vm)
    unsafe finishSuspend(vm, w, .suspended)
    unsafe vm.count(.waits)
    return true
}

/// Re-queue the running Process (yield, preemption, hop, detach): its
/// registers as given, at the back of its (possibly new) queue.
func requeueCurrent(_ vm: VMPointer, _ w: WorkerPointer, sp: Int, pc: Int, affinity: Int? = nil,
                    result: (argc: Int, value: Oop)? = nil, reason: LeaveReason, hop: Bool = false) {
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
    if let affinity { unsafe setIntSlot(w, p, ProcessLayout.affinity, affinity) }
    let needMain = unsafe makeReadyLocked(vm, w, p, fromBlocked: false)
    unsafe schedUnlock(vm)
    unsafe finishSuspend(vm, w, reason)
    unsafe wake(vm, w, needMain)
}
