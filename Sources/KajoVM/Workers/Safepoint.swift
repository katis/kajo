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
    // Module 7: inside, owing no round already open.
    unsafe youngEnterLocked(vm, w)
    let epoch = unsafe sp.pointee.epoch
    unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
    // Module 6: 0, then the relocation epoch, before any heap access.
    unsafe epochEnter(vm, w)
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
    // Module 6: no body pointer from here on.
    unsafe epochQuiesce(vm, w)
    unsafe lockCounted(vm.pointee.safepointLock, vm, contended: .safepointContended)
    // Module 7: the rounds it owes are done by proxy, then it is outside.
    unsafe youngLeaveLocked(vm, w)
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
    // Module 6: the relocator never parks between its CAS and its switch.
    if unsafe w.pointee.inRelocation { unsafe parkWhileRelocating(vm) }
    unsafe epochAdvance(vm, w)
    unsafe perturb(vm, w)
    unsafe lockCounted(vm.pointee.safepointLock, vm, contended: .safepointContended)
    unsafe parkLocked(vm, w)
    unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
}

/// Mutex held: wait out the current stop, if any. `via`: where the parker
/// was (the stop's record names the last one's).
func parkLocked(_ vm: UnsafeMutablePointer<VMState>, _ w: WorkerPointer, via: ParkVia = .poll) {
    let sp = unsafe vm.pointee.safepoint
    guard unsafe sp.pointee.requested else { return }
    let t0 = nanoseconds()
    let epoch = unsafe sp.pointee.epoch
    unsafe sp.pointee.parked += 1
    unsafe sp.pointee.lastParker = w.pointee.index
    unsafe sp.pointee.lastParkerVia = via
    if via == .wait { unsafe sp.pointee.parkedFromWaits += 1 }
    unsafe pthread_cond_broadcast(vm.pointee.safepointCond)
    var seen = unsafe sp.pointee.phaseSeq
    while unsafe sp.pointee.epoch == epoch {
        // Module 4: join the stop's parallel phase (a scavenge) while it is
        // open. Still parked: the stop verifier counts returns, not this.
        // Module 5's marker (outside the worker table) never joins.
        if unsafe sp.pointee.phaseOpen && sp.pointee.phaseSeq != seen && w.pointee.index < vm.pointee.workerCount {
            seen = unsafe sp.pointee.phaseSeq
            unsafe sp.pointee.parts[sp.pointee.joined] = w.pointee.index
            unsafe sp.pointee.joined += 1
            unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
            let g0 = nanoseconds()
            unsafe participateInScavenge(vm, w)
            unsafe w.pointee.collectorNs &+= nanoseconds() &- g0
            unsafe pthread_mutex_lock(vm.pointee.safepointLock)
            unsafe sp.pointee.done += 1
            unsafe pthread_cond_broadcast(vm.pointee.safepointCond)
            continue
        }
        unsafe pthread_cond_wait(vm.pointee.safepointCond, vm.pointee.safepointLock)
    }
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
    /// From the request to the last park (`StopRecord`).
    var timeToSafepointNs: UInt64 = 0
    /// The final mark on the devices: the stopper's wait before its
    /// request and the collections open when it began, the last parker and
    /// how it came, and when the stop's work began (uptime ns).
    var beforeRequestNs: UInt64 = 0
    var collectionsOpen = 0
    var slowest = -1
    var slowestVia = ParkVia.poll
    var parkedFromWaits = 0
    var workStartNs: UInt64 = 0

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
    // Module 7 settles module 6's open item: a stopper outside the worker
    // table (module 5's marker at utility, the young collector) runs the
    // stop at user-initiated at least, so the world never waits for a
    // starved stopper; its own QoS comes back after the release.
    let raised = unsafe raiseStopperQoS(vm, w)
    defer { if let q = raised { pthread_set_qos_class_self_np(q, 0) } }
    unsafe lockCounted(vm.pointee.safepointLock, vm, contended: .safepointContended)
    let collectionsOpen = unsafe sp.pointee.ycActive
    while true {
        while unsafe sp.pointee.requested {
            unsafe parkLocked(vm, w, via: .stopper)
            if !retry {
                unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
                return false
            }
        }
        // Module 7: stops and young collections never interleave.
        if unsafe waitForCollectionsLocked(vm, w) { break }
    }
    let tr = nanoseconds()
    unsafe sp.pointee.requested = true
    unsafe sp.pointee.stopper = w.pointee.index
    unsafe sp.pointee.lastParker = -1
    unsafe sp.pointee.lastParkerVia = .poll
    unsafe sp.pointee.parkedFromWaits = 0
    unsafe sp.pointee.mainOpenedWhileWanted = false
    unsafe vm.pointee.flag.pointee.bitwiseOr(1, ordering: .relaxed)
    // Module 7: participants blocked in a wait inside the VM (`waitServicing`:
    // an opener waiting for `stwWanted`, a collector, an eden wait) must wake
    // to park, or the stop waits for them forever.
    unsafe pthread_cond_broadcast(vm.pointee.safepointCond)
    while unsafe sp.pointee.parked + 1 < sp.pointee.active {
        unsafe pthread_cond_wait(vm.pointee.safepointCond, vm.pointee.safepointLock)
    }
    let t1 = nanoseconds()
    let wakeups = unsafe sp.pointee.wakeups
    let slowest = unsafe sp.pointee.lastParker
    let slowestVia = unsafe sp.pointee.lastParkerVia
    let fromWaits = unsafe sp.pointee.parkedFromWaits
    unsafe pthread_mutex_unlock(vm.pointee.safepointLock)

    // The world is stopped. Module 6: pending blocks are freed first, the
    // relocation verifier runs after the work.
    unsafe relocationAtPauseStart(vm)
    work(unsafe StopContext(vm: vm, keeping: keeping, timeToSafepointNs: t1 &- tr, beforeRequestNs: tr &- t0,
                            collectionsOpen: collectionsOpen, slowest: slowest, slowestVia: slowestVia,
                            parkedFromWaits: fromWaits, workStartNs: nanoseconds()))
    unsafe relocationAtPauseEnd(vm)
    if unsafe vm.pointee.config.verifyStops { unsafe verifySchedule(vm) }
    // A full collection fired ephemerons: signal the finalization
    // Semaphore through the external queue (module 4, ADR 0009 section 1).
    if unsafe vm.pointee.om.takeFinalizationSignal() { unsafe signalFinalization(vm) }

    unsafe lockCounted(vm.pointee.safepointLock, vm, contended: .safepointContended)
    if unsafe vm.pointee.config.verifyStops && sp.pointee.wakeups != wakeups {
        unsafe verifierFailed(vm, .stopVerifierFailures, "a parked worker left its park while the stop's work ran")
    }
    if unsafe vm.pointee.config.verifyStops { unsafe verifyBarrierWordLocked(vm) }
    // Module 4: a full collection a scavenge requested keeps every poll on
    // its slow path until a worker runs it in a stop of its own.
    // Module 8c: so does a save's hold on the scheduler (every running
    // Process leaves at its next poll).
    if unsafe fullCollectionDue(vm) || vm.pointee.saveHold.pointee.load(ordering: .relaxed) {
        unsafe vm.pointee.flag.pointee.bitwiseOr(1, ordering: .relaxed)
    } else {
        unsafe vm.pointee.flag.pointee.bitwiseAnd(~1, ordering: .relaxed)
    }
    unsafe sp.pointee.requested = false
    unsafe sp.pointee.stopper = -1
    unsafe sp.pointee.epoch &+= 1
    if unsafe !vm.pointee.config.testSwitches.countReleasedAsParked { unsafe sp.pointee.parked = 0 }
    let t2 = nanoseconds()
    let i = unsafe sp.pointee.stopCount
    unsafe sp.pointee.stops[i & (SafepointState.stopLog - 1)] = StopRecord(
        timeToSafepointNs: t1 &- tr, pauseNs: t2 &- tr, slowest: slowest, requester: w.pointee.index, kind: sp.pointee.kind,
        atNs: tr, beforeRequestNs: tr &- t0, collectionsOpen: collectionsOpen, slowestVia: slowestVia,
        parkedFromWaits: fromWaits, words: sp.pointee.words)
    unsafe sp.pointee.kind = .other
    unsafe sp.pointee.words = 0
    unsafe sp.pointee.stopCount = i &+ 1
    let epoch = unsafe sp.pointee.epoch
    unsafe pthread_cond_broadcast(vm.pointee.safepointCond)
    unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
    unsafe noteEpoch(w, epoch)
    // The stopper's own time includes its wait before the request; the
    // counters are the world's (from the request).
    unsafe w.pointee.stopNs &+= t2 &- t0
    unsafe vm.count(.stops)
    unsafe vm.count(.stopNs, t2 &- tr)
    unsafe vm.count(.timeToSafepointNs, t1 &- tr)
    unsafe vm.count(.stopRequestWaitNs, tr &- t0)
    return true
}

/// The stopper, world stopped, mutex not held: open a parallel phase (a
/// scavenge's copy and sweep), take part, close it and wait for every
/// worker that joined. Answers the participants, the stopper first.
func runParallelPhase(_ vm: UnsafeMutablePointer<VMState>, _ w: WorkerPointer) -> [Int] {
    let sp = unsafe vm.pointee.safepoint
    unsafe pthread_mutex_lock(vm.pointee.safepointLock)
    unsafe sp.pointee.phaseSeq &+= 1
    unsafe sp.pointee.phaseOpen = true
    unsafe sp.pointee.parts[0] = w.pointee.index
    unsafe sp.pointee.joined = 1
    unsafe sp.pointee.done = 0
    unsafe pthread_cond_broadcast(vm.pointee.safepointCond)
    unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
    unsafe participateInScavenge(vm, w)
    unsafe pthread_mutex_lock(vm.pointee.safepointLock)
    unsafe sp.pointee.phaseOpen = false
    while unsafe sp.pointee.done < sp.pointee.joined - 1 {
        unsafe pthread_cond_wait(vm.pointee.safepointCond, vm.pointee.safepointLock)
    }
    let parts = unsafe (0..<sp.pointee.joined).map { unsafe sp.pointee.parts[$0] }
    unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
    return parts
}

/// Record what the current stop does (stopper, world stopped).
func markStop(_ vm: UnsafeMutablePointer<VMState>, _ kind: StopKind) {
    unsafe pthread_mutex_lock(vm.pointee.safepointLock)
    unsafe vm.pointee.safepoint.pointee.kind = kind
    unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
}

/// The `pointersTo:` follow-up: the slots the current stop's walk compared,
/// for its record (stopper, world stopped).
func noteStopWork(_ vm: UnsafeMutablePointer<VMState>, words: UInt64) {
    unsafe pthread_mutex_lock(vm.pointee.safepointLock)
    unsafe vm.pointee.safepoint.pointee.words &+= words
    unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
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

/// The barrier word's verifier (collectors review, finding 4), at the end
/// of every stop, mutex held: bits 1 and up count the open young
/// collections (none: stops never interleave one) plus the young stress
/// flag `barrierAlwaysOn`; bit 0 is set exactly while a cycle is marking
/// (or under `markingAlwaysOn`). Marking used to store the whole word and
/// erase module 7's count.
func verifyBarrierWordLocked(_ vm: UnsafeMutablePointer<VMState>) {
    let word = unsafe barrierWord(vm.pointee.flag).pointee.load(ordering: .relaxed)
    var count = unsafe UInt32(truncatingIfNeeded: vm.pointee.safepoint.pointee.ycActive)
    if let y = unsafe vm.pointee.young, unsafe y.pointee.config.stress.contains(.barrierAlwaysOn) { count &+= 1 }
    var marking = false
    if let mk = unsafe vm.pointee.marking {
        marking = unsafe mk.phaseNow == .marking || mk.pointee.config.stress.contains(.markingAlwaysOn)
    }
    if word &>> 1 != count || (word & BarrierBits.marking != 0) != marking {
        unsafe verifierFailed(vm, .stopVerifierFailures,
                              "the barrier word is \(word): \(count) young collections and stress, marking \(marking)")
    }
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

/// A stopper outside the worker table below user-initiated is raised to it
/// for its stop (counted). Answers the QoS to restore, or nil.
private func raiseStopperQoS(_ vm: UnsafeMutablePointer<VMState>, _ w: WorkerPointer) -> qos_class_t? {
    guard unsafe w.pointee.index >= vm.pointee.workerCount else { return nil }
    let cur = qos_class_self()
    guard cur.rawValue < QOS_CLASS_USER_INITIATED.rawValue else { return nil }
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0)
    unsafe vm.count(.stopperQoSRaises)
    return cur
}
