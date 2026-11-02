import Darwin
import Synchronization

// The safepoint protocol (docs/modules/workers.md "Safepoint protocol").
// Two counts under the safepoint mutex: `active` (workers inside the VM)
// and `parked` (active workers waiting at a safepoint). A stopper sets the
// flag the polls read, waits until `parked + 1 == active`, works, clears
// the flag, zeroes `parked`, bumps the epoch and broadcasts. A parker waits
// for the epoch to change and does not decrement `parked`: the stopper
// zeroed it (experiments/generational-gc, `backToBackStops...`).

/// The worker starts executing Smalltalk: waits while a stop is in
/// progress, then counts as active. Answers the nanoseconds it waited.
@discardableResult
func enterVM(_ vm: UnsafeMutablePointer<VMState>, _ w: WorkerPointer) -> UInt64 {
    let sp = unsafe vm.pointee.safepoint
    unsafe lockCounted(vm.pointee.safepointLock, vm, contended: .safepointContended)
    var waited: UInt64 = 0
    if unsafe sp.pointee.requested {
        let t0 = nanoseconds()
        while unsafe sp.pointee.requested { unsafe pthread_cond_wait(vm.pointee.safepointCond, vm.pointee.safepointLock) }
        waited = nanoseconds() &- t0
    }
    unsafe sp.pointee.active += 1
    let epoch = unsafe sp.pointee.epoch
    unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
    unsafe noteEpoch(w, epoch)
    unsafe w.pointee.enterWaitNs &+= waited
    unsafe vm.count(.enterWaitNs, waited)
    return waited
}

/// The worker stops executing Smalltalk (idle, or the main thread back in
/// the shell). It holds no Process and no heap reference afterwards, and
/// writes nothing of its own struct until it enters again.
@discardableResult
func leaveVM(_ vm: UnsafeMutablePointer<VMState>, _ w: WorkerPointer) -> UInt64 {
    let t0 = nanoseconds()
    unsafe lockCounted(vm.pointee.safepointLock, vm, contended: .safepointContended)
    unsafe vm.pointee.safepoint.pointee.active -= 1
    unsafe pthread_cond_broadcast(vm.pointee.safepointCond)
    unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
    let waited = nanoseconds() &- t0
    unsafe w.pointee.leaveWaitNs &+= waited
    unsafe vm.count(.leaveWaitNs, waited)
    return waited
}

/// At a poll that found the flag set. The registers are saved.
@inline(never)
func park(_ vm: UnsafeMutablePointer<VMState>, _ w: WorkerPointer) {
    unsafe perturb(vm, w)
    unsafe lockCounted(vm.pointee.safepointLock, vm, contended: .safepointContended)
    unsafe parkLocked(vm, w)
    unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
}

/// Mutex held: wait out the current stop, if any.
private func parkLocked(_ vm: UnsafeMutablePointer<VMState>, _ w: WorkerPointer) {
    let sp = unsafe vm.pointee.safepoint
    guard unsafe sp.pointee.requested else { return }
    let t0 = nanoseconds()
    let epoch = unsafe sp.pointee.epoch
    unsafe sp.pointee.parked += 1
    unsafe sp.pointee.lastParker = w.pointee.index
    unsafe pthread_cond_broadcast(vm.pointee.safepointCond)
    while unsafe sp.pointee.epoch == epoch { unsafe pthread_cond_wait(vm.pointee.safepointCond, vm.pointee.safepointLock) }
    // Not `parked -= 1`: the stopper zeroed the count when it released
    // the world. Decrementing here, whenever this thread gets to run, let a
    // stop requested right after the previous one count a released worker
    // as parked and work while it ran.
    if unsafe vm.pointee.config.testSwitches.countReleasedAsParked { unsafe sp.pointee.parked -= 1 }
    unsafe sp.pointee.wakeups &+= 1
    let dt = nanoseconds() &- t0
    unsafe w.pointee.parkNs &+= dt
    unsafe vm.count(.parkNs, dt)
    unsafe noteEpoch(w, sp.pointee.epoch)
}

/// A pause happened since this worker last looked: its lookup cache lines
/// are oops, so flush them and have the loop re-derive its bases (module 2).
@inline(__always)
private func noteEpoch(_ w: WorkerPointer, _ epoch: UInt64) {
    if unsafe w.pointee.seenEpoch != epoch {
        unsafe w.pointee.seenEpoch = epoch
        unsafe Machine(state: w.pointer(to: \Worker.interp)!).flushCache()
        unsafe w.pointee.interp.pauses &+= 1
    }
}

/// What a stop's work gets: the roots, gathered on demand.
@safe struct StopContext {
    let vm: UnsafeMutablePointer<VMState>
    let keeping: [Oop]

    /// Every root outside the object memory's own: live records' Processes
    /// and stacks, the workers' oop registers, ready queues, pending roots,
    /// and what the stopper keeps.
    func roots() -> [Oop] { unsafe gatherRoots(vm, keeping) }
}

/// Stop the world and run `work`. `w` is active and its registers are
/// saved. If another worker is stopping the world, park for that stop;
/// then answer false (`retry: false`, an allocation that tries again
/// first) or stop the world in turn.
@discardableResult
func stopWorld(_ vm: UnsafeMutablePointer<VMState>, _ w: WorkerPointer, retry: Bool, keeping: [Oop] = [],
               _ work: (StopContext) -> Void) -> Bool {
    let sp = unsafe vm.pointee.safepoint
    let t0 = nanoseconds()
    unsafe lockCounted(vm.pointee.safepointLock, vm, contended: .safepointContended)
    while unsafe sp.pointee.requested {
        unsafe parkLocked(vm, w)
        if !retry {
            unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
            return false
        }
    }
    unsafe sp.pointee.requested = true
    unsafe sp.pointee.lastParker = -1
    unsafe vm.pointee.flag.pointee.store(1, ordering: .relaxed)
    while unsafe sp.pointee.parked + 1 < sp.pointee.active {
        unsafe pthread_cond_wait(vm.pointee.safepointCond, vm.pointee.safepointLock)
    }
    let t1 = nanoseconds()
    let wakeups = unsafe sp.pointee.wakeups
    let slowest = unsafe sp.pointee.lastParker
    unsafe pthread_mutex_unlock(vm.pointee.safepointLock)

    // The world is stopped.
    work(unsafe StopContext(vm: vm, keeping: keeping))
    if unsafe vm.pointee.config.verifyStops { unsafe verifySchedule(vm) }

    unsafe lockCounted(vm.pointee.safepointLock, vm, contended: .safepointContended)
    if unsafe vm.pointee.config.verifyStops && sp.pointee.wakeups != wakeups {
        unsafe verifierFailed(vm, .stopVerifierFailures, "a parked worker left its park while the stop's work ran")
    }
    unsafe vm.pointee.flag.pointee.store(0, ordering: .relaxed)
    unsafe sp.pointee.requested = false
    unsafe sp.pointee.epoch &+= 1
    if unsafe !vm.pointee.config.testSwitches.countReleasedAsParked { unsafe sp.pointee.parked = 0 }
    let t2 = nanoseconds()
    let i = unsafe sp.pointee.stopCount
    unsafe sp.pointee.stops[i & (SafepointState.stopLog - 1)] = StopRecord(
        timeToSafepointNs: t1 &- t0, pauseNs: t2 &- t0, slowest: slowest, requester: w.pointee.index)
    unsafe sp.pointee.stopCount = i &+ 1
    let epoch = unsafe sp.pointee.epoch
    unsafe pthread_cond_broadcast(vm.pointee.safepointCond)
    unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
    unsafe noteEpoch(w, epoch)
    unsafe w.pointee.stopNs &+= t2 &- t0
    unsafe vm.count(.stops)
    unsafe vm.count(.stopNs, t2 &- t0)
    unsafe vm.count(.timeToSafepointNs, t1 &- t0)
    return true
}

/// World stopped. See `StopContext.roots`.
func gatherRoots(_ vm: UnsafeMutablePointer<VMState>, _ keeping: [Oop]) -> [Oop] {
    var roots = keeping
    let om = unsafe vm.pointee.om
    unsafe pthread_mutex_lock(vm.pointee.schedLock)
    for q in 0..<(2 * Priority.count * Affinity.count) {
        let v = unsafe Oop(raw: vm.pointee.queues[q])
        if v != .none { roots.append(v) }
    }
    let hw = unsafe vm.pointee.sched.pointee.recordHighWater
    for i in 0..<hw {
        let r = unsafe vm.pointee.records + i
        let p = unsafe r.pointee.process
        if p == .none { continue }
        roots.append(p)
        guard let base = unsafe r.pointee.base else { preconditionFailure("gatherRoots: record \(i) of \(p) has no stack") }
        // A running Process's stack through its worker's saved sp, a
        // suspended one's through the sp saved in it: never both, never
        // a stale one (the worker clears `runningOn` before publishing).
        let top: Int
        if unsafe r.pointee.runningOn >= 0 {
            let wr = unsafe vm.worker(r.pointee.runningOn)
            top = unsafe wr.pointee.interp.regs.sp
            for v in unsafe [wr.pointee.interp.regs.receiver, wr.pointee.interp.regs.method] where v != .none {
                roots.append(v)
            }
        } else {
            top = om.load(p, ProcessLayout.sp).smallIntegerValue.asInt
        }
        for k in 0...top { unsafe roots.append(Oop(raw: base[k])) }
    }
    unsafe pthread_mutex_unlock(vm.pointee.schedLock)
    // The result register, live between a bottom return and the
    // termination that consumes it (and never at a stop, unless the rule
    // that clears it is broken).
    for k in unsafe 0..<vm.pointee.workerCount {
        let v = unsafe vm.worker(k).pointee.interp.regs.result
        if v != .none { roots.append(v) }
    }
    unsafe pthread_mutex_lock(vm.pointee.pendingLock)
    for i in unsafe 0..<vm.pointee.pending.pointee.highWater {
        let v = unsafe Oop(raw: vm.pointee.pendingSlots[i])
        if v != .none { roots.append(v) }
    }
    unsafe pthread_mutex_unlock(vm.pointee.pendingLock)
    return roots
}

/// The schedule verifier: every worker's `current` and every record's
/// `runningOn` name each other. World stopped.
func verifySchedule(_ vm: UnsafeMutablePointer<VMState>) {
    var problems: [String] = []
    unsafe pthread_mutex_lock(vm.pointee.schedLock)
    for k in unsafe 0..<vm.pointee.workerCount {
        let w = unsafe vm.worker(k)
        let cur = unsafe w.pointee.current
        if cur == .none { continue }
        let ri = unsafe w.pointee.record
        if unsafe ri < 0 || records(vm, ri).pointee.process != cur || records(vm, ri).pointee.runningOn != k {
            problems.append("worker \(k) runs a Process whose record does not name it")
        }
    }
    for i in unsafe 0..<vm.pointee.sched.pointee.recordHighWater {
        let r = unsafe records(vm, i)
        let on = unsafe r.pointee.runningOn
        if unsafe r.pointee.process == .none || on < 0 { continue }
        if unsafe vm.worker(on).pointee.current != r.pointee.process {
            problems.append("record \(i) names worker \(on), which runs another Process")
        }
    }
    unsafe pthread_mutex_unlock(vm.pointee.schedLock)
    for p in problems { unsafe verifierFailed(vm, .scheduleVerifierFailures, p) }
}

@inline(__always)
func records(_ vm: UnsafeMutablePointer<VMState>, _ i: Int) -> UnsafeMutablePointer<ProcessRecord> {
    unsafe vm.pointee.records + i
}

/// Count a verifier failure; trap in a checked build that traps (module
/// 1's policy).
func verifierFailed(_ vm: UnsafeMutablePointer<VMState>, _ c: Counter, _ report: String) {
    unsafe vm.count(c)
    if unsafe vm.pointee.om.config.onVerifyFailure == .trap { preconditionFailure("kajo verify: \(report)") }
}

extension Int64 {
    var asInt: Int { Int(truncatingIfNeeded: self) }
}
