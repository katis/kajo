import Darwin
import Synchronization

// Young allocation (docs/modules/nursery.md "Allocation"): bump in the
// worker's eden, take the next entry of its stash. No load from the
// entry table; one out-of-line call when either runs out or the object is
// large (allocated old).

/// A pointer object in `a`'s eden, or `.none` (the slow path decides).
@inline(__always)
func tryAllocateYoung(_ a: UnsafeMutablePointer<NurseryAlloc>, _ om: ObjectMemory, classIndex: UInt64, slots: Int,
                      fill: Oop) -> Oop {
    precondition(UInt(bitPattern: slots) <= UInt(Header.maxSlots), "object larger than a block")
    let n = UInt64(truncatingIfNeeded: slots)
    return unsafe placeYoungIfRoom(a, om, header: classIndex | n &<< Header.countShift, bytes: n &<< 3 &+ 8, fill: fill.raw)
}

/// A byte object of `count` zero bytes in `a`'s eden, or `.none`.
@inline(__always)
func tryAllocateYoungBytes(_ a: UnsafeMutablePointer<NurseryAlloc>, _ om: ObjectMemory, classIndex: UInt64,
                           count: Int) -> Oop {
    precondition(UInt(bitPattern: count) <= UInt(Header.maxBytes), "object larger than a block")
    let n = UInt64(truncatingIfNeeded: count)
    return unsafe placeYoungIfRoom(a, om, header: classIndex | n &<< Header.countShift | Header.bytesBit,
                                   bytes: (n &+ 7) & ~7 &+ 8, fill: 0)
}

@inline(__always)
func placeYoungIfRoom(_ a: UnsafeMutablePointer<NurseryAlloc>, _ om: ObjectMemory, header: UInt64, bytes: UInt64,
                      fill: UInt64) -> Oop {
    let top = unsafe a.pointee.top
    let next = unsafe a.pointee.stash.next
    if unsafe _slowPath(bytes > a.pointee.fastLimit || top &+ bytes > a.pointee.end || next == a.pointee.stash.count) {
        return .none
    }
    return unsafe placeYoung(a, om, header: header, bytes: bytes, fill: fill)
}

/// Room and an entry are there.
@inline(__always)
func placeYoung(_ a: UnsafeMutablePointer<NurseryAlloc>, _ om: ObjectMemory, header: UInt64, bytes: UInt64,
                fill: UInt64) -> Oop {
    let top = unsafe a.pointee.top
    let next = unsafe a.pointee.stash.next
    let e = unsafe UInt64(a.pointee.stash.base.unsafelyUnwrapped[next]) &<< 4
    unsafe a.pointee.top = top &+ bytes
    unsafe a.pointee.stash.next = next &+ 1
    unsafe om.initializeObject(e, at: top, header: header | a.pointee.youngMark, bytes: bytes, fill: fill)
    return Oop(raw: e)
}

extension Machine {
    /// The young allocation's slow path: a large object goes old; an empty
    /// stash takes entry runs from the pool; a full eden (or a stress flag)
    /// stops the world for a scavenge, or for a full collection when the
    /// table is out of entries, a stress flag asks, or a scavenge requested
    /// one. Another worker's stop in progress is parked for, then the
    /// allocation tries again.
    func allocateYoungSlow(_ cls: UInt64, count: Int, bytes isBytes: Bool, keeping extra: Oop) -> Oop {
        let w = unsafe workerOf(state)
        guard let vm = unsafe w.pointee.vm, let n = unsafe vm.pointee.nursery, let a = unsafe state.pointee.young else {
            return allocateOld(cls, count: count, bytes: isBytes, keeping: extra)
        }
        precondition(count >= 0 && count <= (isBytes ? Header.maxBytes : Header.maxSlots), "object larger than a block")
        let c = UInt64(count)
        let size = isBytes ? (c &+ 7) & ~7 &+ 8 : c &<< 3 &+ 8
        if unsafe size > n.pointee.largeLimit {
            unsafe a.pointee.largeAllocations &+= 1
            return allocateOld(cls, count: count, bytes: isBytes, keeping: extra)
        }
        let header = cls | c &<< Header.countShift | (isBytes ? Header.bytesBit : 0)
        let fill = isBytes ? 0 : nilObject.raw
        let keep = extra == .none ? [nilObject] : [nilObject, extra]
        let stash = unsafe a.pointer(to: \NurseryAlloc.stash)!
        let fullStress = om.config.stress.contains(.collectAtEveryAllocation)
        var force = unsafe a.pointee.fastLimit == 0
        var fulls = 0
        while true {
            if !force {
                if unsafe a.pointee.stash.next == a.pointee.stash.count, unsafe om.refillStash(stash, atLeast: 1024) {
                    unsafe a.pointee.stashRefills &+= 1
                }
                if unsafe a.pointee.top &+ size <= a.pointee.end && a.pointee.stash.next < a.pointee.stash.count {
                    return unsafe placeYoung(a, om, header: header, bytes: size, fill: fill)
                }
            }
            let tableFull = unsafe !force && a.pointee.stash.next == a.pointee.stash.count
            if tableFull && fulls > 0 {
                fail(.outOfMemory)
                return .none
            }
            let full = tableFull || (force && fullStress)
            let before = pauseCount()
            let stopped = unsafe stopWorld(vm, w, retry: false, keeping: keep) { stop in
                if full && fullStress { unsafe om.gc.pointee.counters.stressCollections &+= 1 }
                unsafe youngPause(vm, w, stop, full: full)
            }
            if !stopped { continue }
            if full { fulls += 1 }
            force = false
            unsafe state.pointee.counters.collectionsTriggered &+= Swift.max(1, pauseCount() &- before)
        }
    }
}

/// The work of a stop the young allocation asked for (world stopped): a
/// scavenge, or a full collection when `full` or when a scavenge requested
/// one (the request is taken here, so it runs once).
func youngPause(_ vm: VMPointer, _ w: WorkerPointer, _ stop: StopContext, full: Bool) {
    guard let n = unsafe vm.pointee.nursery else { return }
    if unsafe full || n.pointee.fullRequested.pointee.exchange(false, ordering: .relaxed) {
        unsafe fullCollection(vm, stop)
    } else {
        unsafe markStop(vm, .scavenge)
        unsafe scavenge(vm, w, roots: stop.roots(), promoteAll: false, timeToSafepointNs: stop.timeToSafepointNs)
    }
}

/// A full collection in a stop: module 1's mark-sweep, which first has the
/// hook promote everything. A pending request is satisfied.
func fullCollection(_ vm: VMPointer, _ stop: StopContext) {
    unsafe markStop(vm, .full)
    if let n = unsafe vm.pointee.nursery {
        unsafe n.pointee.fullRequested.pointee.store(false, ordering: .relaxed)
        unsafe n.pointee.state.pointee.counters.fullCollectionsRun &+= 1
    }
    unsafe vm.pointee.om.collect(extraRoots: stop.roots())
}

/// A scavenge left old space past its soft limit and no full collection
/// has run since.
@inline(__always)
func fullCollectionDue(_ vm: VMPointer) -> Bool {
    guard let n = unsafe vm.pointee.nursery else { return false }
    return unsafe n.pointee.fullRequested.pointee.load(ordering: .relaxed)
}

/// At a poll: run the full collection a scavenge requested, in a stop of
/// its own. Registers saved. Whoever stops first takes the request.
@inline(never)
func runDueFullCollection(_ vm: VMPointer, _ w: WorkerPointer) {
    unsafe stopWorld(vm, w, retry: true) { stop in
        guard let n = unsafe vm.pointee.nursery,
              unsafe n.pointee.fullRequested.pointee.exchange(false, ordering: .relaxed) else { return }
        unsafe fullCollection(vm, stop)
    }
    unsafe w.pointee.interp.counters.collectionsTriggered &+= 1
}

/// A scavenge in a stop of its own (the `scavenge` primitive, the host).
func scavengeNow(_ vm: VMPointer, _ w: WorkerPointer) {
    unsafe stopWorld(vm, w, retry: true) { stop in unsafe youngPause(vm, w, stop, full: false) }
}

// MARK: - the VM's nursery

extension NurseryShared {
    /// Give `vm` its nurseries: one per worker, the soft limit below the
    /// promotion reserve, and the hook that promotes everything before
    /// module 1's old-space operations.
    static func install(_ vm: VMPointer) {
        let config = unsafe vm.pointee.config.nursery
        guard config.enabled else { return }
        let om = unsafe vm.pointee.om
        let count = unsafe vm.pointee.workerCount
        let n = unsafe NurseryShared.make(config, om: om, workers: count)
        unsafe vm.pointee.nursery = n
        for i in 0..<count { unsafe vm.worker(i).pointee.interp.young = n.alloc(i) }
        let needed = config.reserveBytes(workers: count) / BlockHeap.blockBytes
        let blocks = om.heap.blockCount
        let soft = Swift.min(om.config.heapBytes / BlockHeap.blockBytes, blocks - needed)
        precondition(soft >= 1, "nursery: a heap of \(blocks) blocks cannot keep a promotion reserve of \(needed); "
                     + "set ObjectMemoryConfig.reserveBytes to NurseryConfig.reserveBytes(workers:)")
        om.softLimitBlocks = soft
        om.setBeforeOldSpaceOperation { extra in unsafe promoteAllForOldSpace(vm, extra) }
    }

    static func uninstall(_ vm: VMPointer) {
        guard let n = unsafe vm.pointee.nursery else { return }
        unsafe vm.pointee.om.setBeforeOldSpaceOperation(nil)
        for i in unsafe 0..<vm.pointee.workerCount { unsafe vm.worker(i).pointee.interp.young = nil }
        unsafe NurseryShared.destroy(n)
        unsafe vm.pointee.nursery = nil
    }
}

/// The hook: module 1 is about to collect, compact, become, forward,
/// reshape or snapshot, which need nothing young. The world is stopped by
/// the worker that runs the operation; promote everything with its roots
/// (the operation's, or the stop's when it was given none).
private func promoteAllForOldSpace(_ vm: VMPointer, _ extra: [Oop]?) {
    let sp = unsafe vm.pointee.safepoint
    unsafe pthread_mutex_lock(vm.pointee.safepointLock)
    let requested = unsafe sp.pointee.requested
    let stopper = unsafe sp.pointee.stopper
    unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
    precondition(requested && stopper >= 0, "kajo: an old-space operation outside a stop")
    let roots = unsafe extra ?? gatherRoots(vm, [])
    unsafe scavenge(vm, vm.worker(stopper), roots: roots, promoteAll: true)
}
