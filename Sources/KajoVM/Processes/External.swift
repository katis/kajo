import Darwin
import Dispatch
import Synchronization

// External signals (docs/modules/workers.md "External signals and pending
// roots"): an MPSC Treiber stack of malloc'ed nodes that any thread pushes
// to without a lock and without touching the heap; a worker inside the VM
// takes the whole list with one exchange, reverses it to FIFO and signals
// each Semaphore. The pending-root table keeps a Semaphore alive while an
// operation that will signal it is outstanding.

/// A handle to a VM that any thread may hold: for `signalFromOutside`
/// from completion handlers and the shell. Valid until the VM is destroyed.
@safe struct VMRef: @unchecked Sendable {
    let vm: VMPointer

    /// Signal `sem` from any thread, VM or not. `handle` is the pending-root
    /// slot to free when the signal is drained (nil: `sem` is rooted some
    /// other way). Takes no lock for the push; waking an idle worker takes
    /// the scheduler mutex, so the untimed idle wait cannot miss it.
    func signalFromOutside(_ sem: Oop, handle: Int?) {
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
}

struct ExternalNode {
    var sem: Oop
    var handle: Int
    var next: UInt
}

// MARK: - pending roots

/// Root `sem` until its operation completes. -1 when the table is full.
func registerPending(_ vm: VMPointer, _ sem: Oop) -> Int {
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
    unsafe st.pointee.count += 1
    return h
}

private func unregisterPending(_ vm: VMPointer, _ h: Int) {
    if h < 0 { return }
    unsafe lockCounted(vm.pointee.pendingLock, vm, contended: .pendingContended)
    unsafe vm.pointee.pendingSlots[h] = 0
    unsafe vm.pointee.pendingNext[h] = vm.pointee.pending.pointee.free
    unsafe vm.pointee.pending.pointee.free = h
    unsafe vm.pointee.pending.pointee.count -= 1
    unsafe pthread_mutex_unlock(vm.pointee.pendingLock)
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
/// outside after `ms`. Not a VM wakeup: no VM thread waits on a timer.
func startDelay(_ vm: VMPointer, ms: Int, sem: Oop) -> Bool {
    let h = unsafe vm.pointee.config.testSwitches.noPendingRoots ? -1 : registerPending(vm, sem)
    let unrooted = unsafe vm.pointee.config.testSwitches.noPendingRoots
    if h < 0 && !unrooted { return false }
    let ref = unsafe VMRef(vm: vm)
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(ms)) {
        ref.signalFromOutside(sem, handle: h < 0 ? nil : h)
    }
    return true
}
