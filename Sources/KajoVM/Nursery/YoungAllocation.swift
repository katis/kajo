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
        precondition(count >= 0 && count <= Header.maxLargeCount, "object larger than the count field")
        let c = UInt64(count)
        let size = isBytes ? (c &+ 7) & ~7 &+ 8 : c &<< 3 &+ 8
        // Large for eden (module 4's `largeLimit`), or past a block (module
        // 10's runs): allocated old.
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
        // Collections after which the eden still had no room: only objects
        // the reserve's fallback kept can fill it. The second such one was
        // the full collection the first requested, so old space cannot take
        // them: out of memory, a failure the program sees.
        var collected = false
        var noRoom = 0
        while true {
            if !force {
                if unsafe a.pointee.stash.next == a.pointee.stash.count, unsafe om.refillStash(stash, atLeast: 1024) {
                    unsafe a.pointee.stashRefills &+= 1
                }
                if unsafe a.pointee.top &+ size <= a.pointee.end && a.pointee.stash.next < a.pointee.stash.count {
                    return unsafe placeYoung(a, om, header: header, bytes: size, fill: fill)
                }
                if unsafe collected && a.pointee.keptEnd != 0 && a.pointee.top == a.pointee.keptEnd
                    && a.pointee.top &+ size > a.pointee.end {
                    noRoom += 1
                    if noRoom >= 2 {
                        fail(.outOfMemory)
                        return .none
                    }
                }
            }
            collected = true
            let tableFull = unsafe !force && a.pointee.stash.next == a.pointee.stash.count
            if tableFull && fulls > 0 {
                fail(.outOfMemory)
                return .none
            }
            // Module 7: a full eden is collected without stopping the world
            // (locally, or flipped to the young collector thread).
            if !tableFull && !force, let y = unsafe vm.pointee.young {
                unsafe collectOwnNursery(vm, y, w, held: extra)
                unsafe state.pointee.counters.collectionsTriggered &+= 1
                continue
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
    if full {
        unsafe noteFullCollection(vm, vm.pointee.om.config.stress.contains(.collectAtEveryAllocation) ? .other : .entries)
        unsafe fullCollection(vm, stop)
    } else if unsafe n.pointee.fullRequested.pointee.exchange(false, ordering: .relaxed) {
        unsafe noteFullCollection(vm, .softLimit)
        unsafe fullCollection(vm, stop)
    } else {
        unsafe markStop(vm, .scavenge)
        let roots = stop.roots()
        // Module 5: a finished sweep is applied first; at the end a marking
        // cycle may start (its initial mark rides on this scavenge).
        let before = unsafe beforeScavenge(vm)
        unsafe scavenge(vm, w, roots: roots, promoteAll: false, timeToSafepointNs: stop.timeToSafepointNs)
        unsafe afterScavenge(vm, roots: roots, literalBefore: before)
    }
}

/// A full collection in a stop: module 1's mark-sweep, which first has the
/// hook promote everything. A pending request is satisfied. A mark-sweep
/// frees whole blocks only, so an old space whose blocks each keep a few
/// live objects (the shells' ring) stays past its soft limit, and every
/// scavenge after it promotes into the reserve until the reserve is gone:
/// then the full collection compacts too (docs/modules/reserve-and-depth.md).
func fullCollection(_ vm: VMPointer, _ stop: StopContext) {
    unsafe markStop(vm, .full)
    let om = unsafe vm.pointee.om
    let n = unsafe vm.pointee.nursery
    if let n = unsafe n {
        unsafe n.pointee.fullRequested.pointee.store(false, ordering: .relaxed)
        unsafe n.pointee.state.pointee.counters.fullCollectionsRun &+= 1
    }
    let roots = stop.roots()
    om.collect(extraRoots: roots)
    if om.isOverSoftLimit {
        if let n = unsafe n { unsafe n.pointee.state.pointee.counters.fullCompactions &+= 1 }
        om.compact(extraRoots: roots)
    }
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
        unsafe noteFullCollection(vm, .softLimit)
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
        // Module 7: young collection without stopping the world needs the
        // nursery region mapped twice (a RELOCATING young body is read
        // through the alias); otherwise the stop-the-world scavenge only.
        let young = unsafe vm.pointee.config.young
        let concurrent = young.mode != .stw && om.heap.extraBytes >= config.stride * count
        let half = young.stress.contains(.collectAtEveryHalf) ? 64 << 10 : 0
        let n = unsafe NurseryShared.make(config, om: om, workers: count, offloaded: concurrent && young.mode == .offload,
                                          youngHolders: concurrent && young.testSwitches.crossNurseryBarrier,
                                          concurrent: concurrent, deferredOwnership: young.testSwitches.deferredOwnership,
                                          halfBytes: half)
        unsafe vm.pointee.nursery = n
        for i in 0..<count { unsafe vm.worker(i).pointee.interp.young = n.alloc(i) }
        let needed = config.testSwitches.promotionReserveBlocks ?? config.reserveBytes(workers: count) / BlockHeap.blockBytes
        // Module 10: the blocks past the hard limit are the final
        // collection's growth, not old space a nursery may count on.
        let blocks = om.hardLimitBlocks
        let soft = config.testSwitches.promotionReserveBlocks != nil ? blocks - needed
            : Swift.min(om.config.heapBytes / BlockHeap.blockBytes, blocks - needed)
        precondition(soft >= 1, "nursery: a heap of \(blocks) blocks cannot keep a promotion reserve of \(needed); "
                     + "set ObjectMemoryConfig.reserveBytes to NurseryConfig.reserveBytes(workers:)")
        unsafe n.pointee.softLimitBefore = om.softLimitBlocks
        om.softLimitBlocks = soft
        om.setBeforeOldSpaceOperation { extra in unsafe promoteAllForOldSpace(vm, extra) }
        om.setAfterOldSpaceSweep { unsafe dropFreedHolders(n) }
    }

    static func uninstall(_ vm: VMPointer) {
        guard let n = unsafe vm.pointee.nursery else { return }
        unsafe vm.pointee.om.setBeforeOldSpaceOperation(nil)
        unsafe vm.pointee.om.setAfterOldSpaceSweep(nil)
        for i in unsafe 0..<vm.pointee.workerCount { unsafe vm.worker(i).pointee.interp.young = nil }
        unsafe vm.pointee.om.softLimitBlocks = n.pointee.softLimitBefore
        unsafe NurseryShared.destroy(n)
        unsafe vm.pointee.nursery = nil
    }
}

// MARK: - the VM's end

/// What the final collection at the VM's end did (`VM.destroy`).
struct VMEndReport: Sendable {
    /// The VM had nurseries: the final collection ran.
    var ran = false
    /// Young objects (and their bytes) the final collection promoted.
    var promotedObjects: UInt64 = 0
    var promotedBytes: UInt64 = 0
    /// The stop: from its request to its release, and the promote-all's own
    /// work (the hook: marking settled, the scavenge, any reclaim around
    /// kept objects).
    var stopNs: UInt64 = 0
    var workNs: UInt64 = 0
    /// Module 10: blocks old space grew past the promotion reserve's limit
    /// into the final collection's growth (`ObjectMemoryConfig.endGrowthBytes`).
    var grownBlocks = 0
}

/// The VM's end (docs/modules/vm-teardown.md): every thread has joined;
/// one stop runs module 1's promote-all hook with the stop's roots, so a
/// marking cycle is abandoned or its sweep finished and applied, pending
/// blocks are freed, deferred entry frees released, and every live young
/// object is promoted. Module 10 (vm-teardown's first follow-up, the
/// owner's answer): old space grows for this collection: the promotion may
/// take the blocks past the reserve (`endGrowthBytes`, reserved with the
/// heap, as large as the promotion reserve unless configured), so a full
/// old space no longer traps. Only a growth too small for the young
/// objects still traps (the image could not be whole). `NurseryShared.destroy`
/// then hands every stash's entries back. No-op without a nursery.
func endYoungGeneration(_ vm: VMPointer, _ w: WorkerPointer) -> VMEndReport {
    guard let n = unsafe vm.pointee.nursery else { return VMEndReport() }
    var r = VMEndReport()
    r.ran = true
    var left = 0
    let t0 = nanoseconds()
    unsafe stopWorld(vm, w, retry: true) { _ in
        let before = unsafe n.pointee.state.pointee.counters
        let om = unsafe vm.pointee.om
        let t1 = nanoseconds()
        om.setEndGrowth(true)
        left = om.prepareOldSpaceOperation(nil).count
        om.setEndGrowth(false)
        r.workNs = nanoseconds() &- t1
        r.grownBlocks = Swift.max(0, om.blocksInUse - om.hardLimitBlocks)
        let after = unsafe n.pointee.state.pointee.counters
        r.promotedObjects = after.promotedObjects &- before.promotedObjects
        r.promotedBytes = after.promotedBytes &- before.promotedBytes
    }
    r.stopNs = nanoseconds() &- t0
    precondition(left == 0, "kajo: \(left) young objects found no room in old space at the VM's end, its growth included "
                 + "(ObjectMemoryConfig.endGrowthBytes); the image is not whole")
    return r
}

/// The hook: module 1 is about to collect, compact, become, forward,
/// reshape or snapshot, which need nothing young. The world is stopped by
/// the worker that runs the operation; promote everything with its roots
/// (the operation's, or the stop's when it was given none).
private func promoteAllForOldSpace(_ vm: VMPointer, _ extra: [Oop]?) -> [Oop] {
    let sp = unsafe vm.pointee.safepoint
    unsafe pthread_mutex_lock(vm.pointee.safepointLock)
    let requested = unsafe sp.pointee.requested
    let stopper = unsafe sp.pointee.stopper
    unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
    precondition(requested && stopper >= 0, "kajo: an old-space operation outside a stop")
    // Module 5: a marking cycle is abandoned, a sweep finished and applied.
    unsafe markingBeforeOldSpaceOperation(vm)
    let roots = unsafe extra ?? gatherRoots(vm, [])
    // The stopper may be outside the worker table (module 7's young
    // collector, module 5's marker): it promotes everything it copies.
    let p = unsafe participantWorker(vm, stopper)
    unsafe scavenge(vm, p, roots: roots, promoteAll: true)
    let kept = unsafe youngLeft(vm)
    if kept.isEmpty { return [] }
    // The reserve's fallback kept objects young: old space had no block
    // for them. Collect old space around them (roots; the sweep leaves
    // young entries to their nursery), compact when that leaves it past
    // its soft limit, and promote again. What is still young then does not
    // fit old space: the caller collects around it or refuses.
    let om = unsafe vm.pointee.om
    if let n = unsafe vm.pointee.nursery { unsafe n.pointee.state.pointee.counters.reclaimsAroundYoung &+= 1 }
    om.collectOldSpace(extraRoots: roots + kept)
    if om.isOverSoftLimit { om.compactOldSpace(extraRoots: roots + kept) }
    unsafe scavenge(vm, p, roots: roots, promoteAll: true)
    return unsafe youngLeft(vm)
}

/// Every young object (world stopped, right after a scavenge: each is in
/// its nursery's survivor log, survivors and kept ones alike).
private func youngLeft(_ vm: VMPointer) -> [Oop] {
    guard let n = unsafe vm.pointee.nursery else { return [] }
    var out: [Oop] = []
    for k in unsafe 0..<n.pointee.count {
        let log = unsafe n.survivors(k).pointee.survLog
        for i in 0..<log.count { out.append(Oop(raw: UInt64(log[i]) &<< 4)) }
    }
    return out
}

/// After a sweep of old space (world stopped): a holder the sweep freed
/// leaves the carried lists and its remembered word is cleared, before its
/// entry can be reused (only young objects kept in place leave holders
/// listed across a full collection).
private func dropFreedHolders(_ n: NurseryPointer) {
    let om = unsafe n.pointee.om
    for k in unsafe 0..<n.pointee.count {
        let c = unsafe n.survivors(k).pointer(to: \NurserySurvivors.carried)!
        var j = 0
        for i in unsafe 0..<c.pointee.count {
            let o = unsafe c.pointee[i]
            if EntryState.isFree(om.stateWord(o)) {
                unsafe n.remMarker(o).pointee.store(0, ordering: .relaxed)
                continue
            }
            unsafe c.pointee[j] = o
            j += 1
        }
        unsafe c.pointee.truncate(j)
    }
}
