import Darwin

/// The poll slow path (docs/modules/workers.md "Budget and preemption"),
/// reached when the countdown runs out or the safepoint flag is set. The
/// registers are saved. Parks for a requested stop; every `pollEvery`
/// polls (the budget check) resets the countdown, drains external signals,
/// honours a terminate request, and preempts the Process when its deadline
/// has passed. Answers true when the Process left this worker (its pc
/// rewound by `rewind`, so a poll at a send re-executes the send).
@inline(never)
func pollSlow(_ s: StatePointer, rewind: Int) -> Bool {
    let w = unsafe workerOf(s)
    let flagged = unsafe s.pointee.safepointFlag.pointee.load(ordering: .relaxed) != 0
    guard let vm = unsafe w.pointee.vm else {
        // Module 2's standalone interpreter: the flag is a test switch
        // that collects at every poll.
        if unsafe s.pointee.countdown == 0 { unsafe s.pointee.countdown = w.pointee.pollEvery }
        if flagged {
            unsafe s.pointee.counters.safepointPolls &+= 1
            unsafe Machine(state: s).collect()
        }
        return false
    }
    if flagged {
        unsafe s.pointee.counters.safepointPolls &+= 1
        unsafe park(vm, w)
        // Module 4: a scavenge left old space past its soft limit.
        if unsafe fullCollectionDue(vm) { unsafe runDueFullCollection(vm, w) }
    }
    if unsafe s.pointee.countdown != 0 { return false }
    unsafe s.pointee.countdown = w.pointee.pollEvery
    unsafe perturb(vm, w)
    if unsafe externalPending(vm) { unsafe drainExternal(vm, w) }
    if unsafe !vm.pointee.config.testSwitches.flushAfterStop { unsafe stopIfStressed(vm, w) }
    if unsafe w.pointee.current == .none { return false }
    let line = unsafe vm.shared(w.pointee.index)
    if unsafe line.pointee.attention.load(ordering: .relaxed) != 0 {
        let ri = unsafe line.pointee.attention.exchange(0, ordering: .acquiring) &- 1
        if unsafe ri == w.pointee.record {
            unsafe schedLock(vm)
            let kill = unsafe terminatePendingLocked(vm, w)
            unsafe schedUnlock(vm)
            if kill { return true }
        }
    }
    let fresh = unsafe w.pointee.freshSlice
    unsafe w.pointee.freshSlice = false
    if unsafe ticks() >= w.pointee.deadline || (!fresh && vm.pointee.config.stress.contains(.preemptEveryPoll)) {
        let r = unsafe s.pointee.regs
        unsafe requeueCurrent(vm, w, sp: r.sp, pc: r.pc &- rewind, reason: .preempted)
        unsafe vm.count(.preemptions)
        return true
    }
    return false
}

/// `stopEveryPoll`: every poll slow path stops the world and collects.
func stopIfStressed(_ vm: VMPointer, _ w: WorkerPointer) {
    guard unsafe vm.pointee.config.stress.contains(.stopEveryPoll) else { return }
    let om = unsafe vm.pointee.om
    unsafe stopWorld(vm, w, retry: true) { om.collect(extraRoots: $0.roots()) }
    unsafe w.pointee.interp.counters.collectionsTriggered &+= 1
}

// MARK: - perturbation

@inline(__always)
private func nextRandom(_ w: WorkerPointer) -> UInt64 {
    var x = unsafe w.pointee.rng
    x ^= x &<< 13
    x ^= x &>> 7
    x ^= x &<< 17
    unsafe w.pointee.rng = x
    return x
}

/// At a perturbation site: with the configured probability, yield the CPU
/// or sleep a little (docs/VERIFICATION.md layer 5).
@inline(__always)
func perturb(_ vm: VMPointer, _ w: WorkerPointer) {
    guard let p = unsafe vm.pointee.config.perturb else { return }
    unsafe perturbSlow(vm, w, p)
}

@inline(never)
private func perturbSlow(_ vm: VMPointer, _ w: WorkerPointer, _ p: Perturbation) {
    let x = unsafe nextRandom(w)
    if Double(x >> 11) / Double(1 << 53) >= p.probability { return }
    unsafe vm.count(.perturbations)
    if x & 1 == 0 || p.maxSleepUs == 0 {
        sched_yield()
    } else {
        usleep(UInt32(truncatingIfNeeded: (x >> 1) % UInt64(p.maxSleepUs)) + 1)
    }
}

/// The window a broken rule leaves open (publish before clear): always
/// widened when perturbation is on.
func perturbWindow(_ vm: VMPointer, _ w: WorkerPointer) {
    guard let p = unsafe vm.pointee.config.perturb else { return }
    let x = unsafe nextRandom(w)
    usleep(UInt32(truncatingIfNeeded: x % UInt64(max(p.maxSleepUs, 1))) + 1)
}
