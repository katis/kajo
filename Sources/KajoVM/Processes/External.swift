import Darwin
import Dispatch
import Synchronization

// External signals (docs/modules/workers.md "External signals and pending
// roots"): an MPSC Treiber stack of malloc'ed nodes that any thread pushes
// to without a lock and without touching the heap; a worker inside the VM
// takes the whole list with one exchange, reverses it to FIFO and signals
// each Semaphore. The pending-root table keeps a Semaphore alive while an
// operation that will signal it is outstanding.

/// The VM's end as the threads it does not join see it
/// (docs/modules/delay-outlives-vm.md): a small reference-counted cell with
/// its own lock, allocated apart from the VM state, so that a holder can
/// still consult it after `VM.destroy` has freed that state. Every way into
/// the VM from such a thread (`VMRef`, each Delay's timer) holds it and
/// touches the VM only inside `whileLive`, under the lock; `end` sets
/// `ended` under the same lock before `destroy` frees anything, so a signal
/// either finished before the end or does nothing and is counted. Lock
/// order: this lock, then the scheduler and pending-root mutexes (never the
/// other way: no VM thread takes it while holding those). The host's
/// `wakeMain` hook runs under it, so a hook may not signal the VM
/// synchronously (the shells' hooks only schedule a turn).
@safe final class VMLife: Sendable {
    struct State: Sendable {
        var ended = false
        /// Delay timers armed and not yet fired.
        var timersPending = 0
        /// Signals and roots refused because the VM had ended (a timer's
        /// included).
        var lateSignals: UInt64 = 0
        /// The known faults, part 1 (docs/modules/known-faults.md): how late
        /// each Delay's timer fired, fired minus due, both on the uptime
        /// clock, taken where the timer's block began (not where the lock
        /// was got). Kept under the cell's lock, which the timer takes
        /// anyway; read after `destroy` too.
        var lateness = DelayLateness()
    }
    private let state = Mutex(State())
    /// The broken variant (`TestSwitches.lateSignalsIgnoreEnd`), copied at
    /// the VM's making because the VM's config dies with it: the check is
    /// skipped and a late signal touches the freed VM. Run by hand only.
    let ignoresEnd: Bool

    init(ignoresEnd: Bool = false) { self.ignoresEnd = ignoresEnd }

    /// Run `body` (which touches the VM) if the VM has not ended, holding
    /// the lock so the end waits for it. False, counted, when it had ended.
    @discardableResult
    func whileLive(_ body: () -> Void) -> Bool {
        state.withLock { s in
            if s.ended && !ignoresEnd {
                s.lateSignals &+= 1
                return false
            }
            body()
            return true
        }
    }

    /// A Delay's timer was armed (on a VM thread: the VM lives).
    func armTimer() { state.withLock { $0.timersPending += 1 } }

    /// A Delay's timer fired at `firedNs` and was due at `dueNs` (uptime
    /// nanoseconds): `body` signals, if the VM still lives.
    func timerFired(firedNs: UInt64, dueNs: UInt64, _ body: () -> Void) {
        state.withLock { s in
            s.timersPending -= 1
            s.lateness.note(firedNs > dueNs ? firedNs - dueNs : 0)
            if s.ended && !ignoresEnd {
                s.lateSignals &+= 1
                return
            }
            body()
        }
    }

    /// The VM ends: from here every signal is refused. Answers the timers
    /// still pending, each of which will fire into nothing.
    func end() -> Int {
        state.withLock { s in
            s.ended = true
            return s.timersPending
        }
    }

    var snapshot: State { state.withLock { $0 } }
}

/// A handle to a VM that any thread may hold: for `signalFromOutside`
/// from completion handlers and the shell. It may outlive the VM: after
/// `VM.destroy` its calls do nothing but count (`VM.lateSignals`), decided
/// under `VMLife`'s lock, which the end takes before freeing the VM.
@safe struct VMRef: @unchecked Sendable {
    let vm: VMPointer
    let life: VMLife

    /// Root `sem` in the pending-root table from any thread, for a signal
    /// whose drain frees it (`signalFromOutside`'s handle); -1 when the
    /// table is full or the VM has ended. The caller must know `sem` rooted
    /// while it asks.
    func rootPending(_ sem: Oop) -> Int {
        var h = -1
        life.whileLive { h = unsafe registerPending(vm, sem) }
        return h
    }

    /// Signal `sem` from any thread, VM or not. `handle` is the pending-root
    /// slot to free when the signal is drained (nil: `sem` is rooted some
    /// other way). Nothing when the VM has ended.
    func signalFromOutside(_ sem: Oop, handle: Int?) {
        life.whileLive { unsafe pushExternal(vm, sem, handle: handle) }
    }

    /// A Delay's timer fired (`startDelay`) at `firedNs`, due at `dueNs`.
    func timerFired(_ sem: Oop, handle: Int?, firedNs: UInt64, dueNs: UInt64) {
        life.timerFired(firedNs: firedNs, dueNs: dueNs) { unsafe pushExternal(vm, sem, handle: handle) }
    }
}

/// How late the Delays' timers fired (the known faults, part 1: the
/// owner's counter before the Delay queue): a sum and a maximum of fired
/// minus due, and how many were at least 10 ms and 100 ms late.
struct DelayLateness: Sendable, Equatable {
    var fired: UInt64 = 0
    var sumNs: UInt64 = 0
    var maxNs: UInt64 = 0
    var late10ms: UInt64 = 0
    var late100ms: UInt64 = 0

    mutating func note(_ ns: UInt64) {
        fired &+= 1
        sumNs &+= ns
        if ns > maxNs { maxNs = ns }
        if ns >= 10_000_000 { late10ms &+= 1 }
        if ns >= 100_000_000 { late100ms &+= 1 }
    }

    var meanMs: Double { fired == 0 ? 0 : Double(sumNs) / Double(fired) / 1e6 }
    var maxMs: Double { Double(maxNs) / 1e6 }
}

/// Push a signal of `sem` onto the external queue and wake a worker to
/// drain it. Any thread while the VM lives: its own threads call it
/// directly, any other through `VMRef`. `handle` as `signalFromOutside`'s.
/// Takes no lock for the push; waking an idle worker takes the scheduler
/// mutex, so the untimed idle wait cannot miss it.
func pushExternal(_ vm: VMPointer, _ sem: Oop, handle: Int?) {
    let node = UnsafeMutablePointer<ExternalNode>.allocate(capacity: 1)
    unsafe node.initialize(to: ExternalNode(sem: sem, handle: handle ?? -1, next: 0))
    let head = unsafe vm.pointee.externalHead
    var old = unsafe head.pointee.load(ordering: .relaxed)
    while true {
        unsafe node.pointee.next = old
        let (done, cur) = unsafe head.pointee.compareExchange(
            expected: old, desired: UInt(bitPattern: node), successOrdering: .releasing, failureOrdering: .relaxed)
        if done { break }
        old = cur
    }
    unsafe pthread_mutex_lock(vm.pointee.schedLock)
    let idle = unsafe vm.pointee.sched.pointee.idleWorkers > 0
    if idle { unsafe pthread_cond_signal(vm.pointee.schedCond) }
    unsafe pthread_mutex_unlock(vm.pointee.schedLock)
    // With no background worker to drain it, the main worker must.
    if unsafe !idle && vm.pointee.config.backgroundWorkers == 0, let h = unsafe vm.pointee.hooks.wakeMain {
        unsafe h(vm.pointee.hooks.context)
    }
}

struct ExternalNode {
    var sem: Oop
    var handle: Int
    var next: UInt
}

// MARK: - pending roots

/// Root `sem` until its operation completes. -1 when the table is full.
/// `building`: `sem` is an object a polled primitive is still building
/// (nothing else may name it until it is whole), which the instance walks
/// of primitives 167 to 170 skip (the review fixes, item 2).
func registerPending(_ vm: VMPointer, _ sem: Oop, building: Bool = false) -> Int {
    unsafe lockCounted(vm.pointee.pendingLock, vm, contended: .pendingContended)
    defer { unsafe pthread_mutex_unlock(vm.pointee.pendingLock) }
    let st = unsafe vm.pointee.pending
    var h = unsafe st.pointee.free
    if h >= 0 {
        unsafe st.pointee.free = vm.pointee.pendingNext[h]
    } else if unsafe st.pointee.highWater < vm.pointee.config.pendingCapacity {
        h = unsafe st.pointee.highWater
        unsafe st.pointee.highWater += 1
    } else {
        return -1
    }
    unsafe vm.pointee.pendingSlots[h] = sem.raw
    unsafe vm.pointee.pendingBuilding[h] = building ? 1 : 0
    unsafe st.pointee.count += 1
    return h
}

func unregisterPending(_ vm: VMPointer, _ h: Int) {
    if h < 0 { return }
    unsafe lockCounted(vm.pointee.pendingLock, vm, contended: .pendingContended)
    unsafe vm.pointee.pendingSlots[h] = 0
    unsafe vm.pointee.pendingBuilding[h] = 0
    unsafe vm.pointee.pendingNext[h] = vm.pointee.pending.pointee.free
    unsafe vm.pointee.pending.pointee.free = h
    unsafe vm.pointee.pending.pointee.count -= 1
    unsafe pthread_mutex_unlock(vm.pointee.pendingLock)
}

/// The pending roots that polled primitives are still building (world
/// stopped, or any time: under `pendingLock`).
func pendingBuildingObjects(_ vm: VMPointer) -> Set<UInt64> {
    var out = Set<UInt64>()
    unsafe pthread_mutex_lock(vm.pointee.pendingLock)
    for i in unsafe 0..<vm.pointee.pending.pointee.highWater where unsafe vm.pointee.pendingBuilding[i] != 0 {
        unsafe out.insert(vm.pointee.pendingSlots[i])
    }
    unsafe pthread_mutex_unlock(vm.pointee.pendingLock)
    return out
}

// MARK: - draining

@inline(__always)
func externalPending(_ vm: VMPointer) -> Bool {
    unsafe vm.pointee.externalHead.pointee.load(ordering: .relaxed) != 0
}

/// Take every pending signal and signal its Semaphore, in the order they
/// were pushed. A worker inside the VM.
@inline(never)
func drainExternal(_ vm: VMPointer, _ w: WorkerPointer) {
    var list = unsafe vm.pointee.externalHead.pointee.exchange(0, ordering: .acquiring)
    if list == 0 { return }
    var fifo: UInt = 0
    while list != 0 {
        let n = unsafe UnsafeMutablePointer<ExternalNode>(bitPattern: list).unsafelyUnwrapped
        list = unsafe n.pointee.next
        unsafe n.pointee.next = fifo
        fifo = UInt(bitPattern: n)
    }
    let om = unsafe vm.pointee.om
    var count: UInt64 = 0
    while fifo != 0 {
        let n = unsafe UnsafeMutablePointer<ExternalNode>(bitPattern: fifo).unsafelyUnwrapped
        fifo = unsafe n.pointee.next
        let sem = unsafe n.pointee.sem
        // Defensive: a Semaphore whose root was lost is counted, not
        // signalled (it would write into whatever reused the entry).
        if om.isUsedReference(sem) && om.classIndex(of: sem) == WellKnown.semaphore {
            unsafe signalSemaphore(vm, w, sem)
        } else {
            unsafe vm.count(.staleExternalSignals)
        }
        unsafe unregisterPending(vm, n.pointee.handle)
        unsafe n.deallocate()
        count &+= 1
    }
    unsafe vm.count(.externalSignals, count)
    unsafe vm.count(.externalDrains)
}

/// `nil delay: ms signal: sem`: a one-shot GCD timer signals `sem` from
/// outside after `ms`. Not a VM wakeup: no VM thread waits on a timer. The
/// timer holds the VM's life cell, not only its pointer: if the VM has
/// ended when it fires, it does nothing (docs/modules/delay-outlives-vm.md;
/// `VMEndReport.timersPending` counts the timers pending at the end). Out
/// of line: the closure and the cell's retain stay off the primitive path.
@inline(never)
func startDelay(_ vm: VMPointer, ms: Int, sem: Oop) -> Bool {
    let h = unsafe vm.pointee.config.testSwitches.noPendingRoots ? -1 : registerPending(vm, sem)
    let unrooted = unsafe vm.pointee.config.testSwitches.noPendingRoots
    if h < 0 && !unrooted { return false }
    let ref = unsafe VMRef(vm: vm, life: vm.pointee.life)
    ref.life.armTimer()
    let armed = DispatchTime.now()
    let due = armed.uptimeNanoseconds &+ UInt64(max(ms, 0)) &* 1_000_000
    DispatchQueue.global().asyncAfter(deadline: armed + .milliseconds(ms)) {
        let fired = DispatchTime.now().uptimeNanoseconds
        ref.timerFired(sem, handle: h < 0 ? nil : h, firedNs: fired, dueNs: due)
    }
    return true
}
