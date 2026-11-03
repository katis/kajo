import Darwin

// The finalization queue's VM side (ADR 0009 section 1 as v0 does it):
// module 1's full collection fires ephemerons into its queue; after the
// stop, the finalization Semaphore is signalled through module 3's
// external queue; a Process (the kernel's, here the tests' kasm) takes
// each ephemeron with `nextMourner` and sends it `mourn`. Finalizers never
// run on a collector thread.

/// After a stop whose collection fired ephemerons.
func signalFinalization(_ vm: VMPointer) {
    unsafe pthread_mutex_lock(vm.pointee.pendingLock)
    let sem = unsafe vm.pointee.finalization.pointee.semaphore
    unsafe pthread_mutex_unlock(vm.pointee.pendingLock)
    if sem != .none { unsafe VMRef(vm: vm).signalFromOutside(sem, handle: nil) }
}

/// Module 4's primitives: 35 `scavenge` (module 7: the caller's nursery
/// only, without stopping the world, unless the configuration is
/// stop-the-world), 36 `finalizationSemaphore:`, 37 `nextMourner`. Outside a
/// VM each fails.
enum NurseryPrimitives {
    static let table: [(number: Int, selector: String, argc: Int)] = [
        (35, "scavenge", 0), (36, "finalizationSemaphore:", 1), (37, "nextMourner", 0),
    ]
}

@inline(never)
func nurseryPrimitive(_ n: Int, _ m: Machine, _ c: PrimitiveCall) -> Oop {
    let w = unsafe workerOf(m.state)
    guard let vm = unsafe w.pointee.vm else { return .none }
    switch n {
    case 35:
        guard c.argc == 0 else { return .none }
        // Module 7: without stopping the world, the caller's own nursery is
        // collected (locally, or flipped to the young collector thread).
        if let y = unsafe vm.pointee.young, unsafe w.pointee.interp.young != nil {
            unsafe collectOwnNursery(vm, y, w, held: .none)
        } else {
            unsafe scavengeNow(vm, w)
        }
        unsafe m.state.pointee.counters.collectionsTriggered &+= 1
        return c.receiver
    case 36:
        // The Semaphore signalled when a collection queues ephemerons;
        // rooted in the pending-root table (replacing an earlier one).
        guard c.argc == 1, c.arg0.isObject, m.om.classIndex(of: c.arg0) == WellKnown.semaphore else { return .none }
        let h = unsafe registerPending(vm, c.arg0)
        if h < 0 { return .none }
        unsafe pthread_mutex_lock(vm.pointee.pendingLock)
        let old = unsafe vm.pointee.finalization.pointee.handle
        unsafe vm.pointee.finalization.pointee = FinalizationState(semaphore: c.arg0, handle: h)
        unsafe pthread_mutex_unlock(vm.pointee.pendingLock)
        if old >= 0 { unsafe unregisterPending(vm, old) }
        return c.receiver
    case 37:
        guard c.argc == 0 else { return .none }
        return m.om.takeFinalized() ?? m.nilObject
    default:
        return .none
    }
}
