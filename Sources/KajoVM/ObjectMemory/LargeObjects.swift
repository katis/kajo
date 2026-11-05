import Synchronization

// Module 10: large objects (docs/modules/large-objects.md). An object whose
// body does not fit one block (more than 4095 slots or 32 760 bytes) gets a
// run of contiguous blocks that it owns alone: the head block, where the
// body starts, and continuations. It is old at birth, never young, never
// relocated or compacted; its entry, header and back reference are an
// ordinary object's, so everything that reaches it through its entry
// (loads, stores, the barriers, marking, become) is unchanged. What changes
// is every reader of the blocks: the side table (`BlockHeap.kind`) says
// what a block is, a head's `used` is the body's bytes and a continuation's
// is 0, and the verifier, the sweeps, the pool, compaction, the relocator's
// selection and the snapshot walk a run as one body.
//
// Allocation is a slow path under the pools lock: first fit over the block
// table for a run of free blocks, counted against the soft limit like any
// mutator block. The fill (nil or zero, one relaxed store per word) runs on
// the allocating thread outside the lock.

extension ObjectMemory {
    /// The body bytes of an object of `count` slots, or bytes when `isBytes`.
    @inline(__always)
    static func bodyBytes(count: Int, isBytes: Bool) -> UInt64 {
        let n = UInt64(truncatingIfNeeded: count)
        return isBytes ? (n &+ 7) & ~7 &+ 8 : n &<< 3 &+ 8
    }

    /// An object of any size the count field holds: the ordinary path for
    /// one that fits a block, a run otherwise. `.none` when there is no
    /// room (a collection must run first) or no entry. Never collects.
    /// Out of line: the large path is a slow path and never inlined into
    /// a hot one.
    @inline(never)
    func tryAllocateAny(_ ctx: AllocContext, classIndex: UInt64, count: Int, isBytes: Bool, fill: Oop) -> Oop {
        precondition(count >= 0 && count <= Header.maxLargeCount, "object larger than the count field")
        if count <= (isBytes ? Header.maxBytes : Header.maxSlots) {
            return isBytes ? tryAllocateBytes(ctx, classIndex: classIndex, count: count)
                           : tryAllocate(ctx, classIndex: classIndex, slots: count, fill: fill)
        }
        return tryAllocateLarge(ctx, classIndex: classIndex, count: count, isBytes: isBytes, fill: fill)
    }

    /// A large object: a run of blocks, an entry from `ctx`'s list, the body
    /// filled with `fill` (pointer objects) or zeros. Old at birth: the old
    /// map has it from the start, and a marking cycle in progress never
    /// sweeps it (it is not in that cycle's snapshot, and its blocks carry
    /// the cycle's stamp).
    func tryAllocateLarge(_ ctx: AllocContext, classIndex: UInt64, count: Int, isBytes: Bool, fill: Oop) -> Oop {
        precondition(count >= 0 && count <= Header.maxLargeCount, "object larger than the count field")
        assert(classIndex != 0 && classIndex <= Header.maxClassIndex)
        let c = unsafe ctx.state
        if unsafe c.pointee.freeEntry == 0, !refillEntries(ctx) {
            unsafe c.pointee.counters.allocationFailures &+= 1
            return .none
        }
        let bytes = ObjectMemory.bodyBytes(count: count, isBytes: isBytes)
        guard let off = takeRun(bytes: bytes) else {
            unsafe c.pointee.counters.allocationFailures &+= 1
            return .none
        }
        let e = unsafe c.pointee.freeEntry
        unsafe c.pointee.freeEntry = stateWord(e) & EntryState.nextMask
        let n = UInt64(truncatingIfNeeded: count)
        let header = classIndex | n &<< Header.countShift | (isBytes ? Header.bytesBit : 0)
        initializeObject(e, at: off, header: header, bytes: bytes, fill: isBytes ? 0 : fill.raw)
        oldMap.insert(e &>> 4)
        unsafe c.pointee.counters.allocations &+= 1
        unsafe c.pointee.counters.allocatedBytes &+= bytes
        return Oop(raw: e)
    }

    /// Take a run of free blocks for a body of `bytes` (more than a block):
    /// first fit from the lowest block, counted against the soft limit
    /// (`reserve`: the promotion reserve's limit, for an operation in a
    /// stop that must not fail where a promotion would not). Answers the
    /// head's offset; the back reference is the caller's to write. Under
    /// the pools lock; any thread.
    func takeRun(bytes: UInt64, reserve: Bool = false) -> UInt64? {
        precondition(bytes > UInt64(BlockHeap.blockBytes), "a run is for a body larger than a block")
        let k = BlockHeap.runBlocks(bytes: bytes)
        let h = heap
        lockPools()
        defer { unlockPools() }
        let p = unsafe pools
        let limit = unsafe p.pointee.endGrowth ? h.blockCount
            : reserve ? p.pointee.hardLimitBlocks : p.pointee.softLimitBlocks
        if unsafe p.pointee.blocksInUse &+ k > limit {
            unsafe p.pointee.largeFailures &+= 1
            return nil
        }
        // A free block (not in use) is always in the pool (the free-list
        // verifier's rule), so a stretch of them is a run to take.
        var start = 0, length = 0, found = -1
        var b = 0
        while b < h.blockCount {
            if h.isInUse(b) {
                length = 0
            } else {
                if length == 0 { start = b }
                length += 1
                if length == k {
                    found = start
                    break
                }
            }
            b += 1
        }
        if found < 0 {
            unsafe p.pointee.largeFailures &+= 1
            return nil
        }
        // Out of the pool; then the side table, head last.
        var j = 0
        let n = unsafe p.pointee.freeBlocks.count
        for i in 0..<n {
            let fb = unsafe Int(p.pointee.freeBlocks[i])
            if fb >= found && fb < found &+ k { continue }
            unsafe p.pointee.freeBlocks[j] = UInt32(fb)
            j += 1
        }
        unsafe p.pointee.freeBlocks.truncate(j)
        let stamp = unsafe p.pointee.stampNow
        for r in found..<(found &+ k) {
            h.setInUse(r, true)
            h.setUsed(r, 0)
            h.setKind(r, BlockKind.continuation)
            unsafe p.pointee.blockStamps[r] = stamp
        }
        h.setKind(found, BlockKind.head)
        h.setUsed(found, bytes)
        unsafe p.pointee.blocksInUse &+= k
        unsafe p.pointee.largeAllocations &+= 1
        unsafe p.pointee.largeBytes &+= bytes
        return BlockHeap.start(ofBlock: found)
    }

    /// Free the run whose head is `b`: every block free and ordinary.
    /// Answers its blocks. The caller rebuilds the pool (`rebuildBlockPool`)
    /// before any allocator runs and counts the run (`noteRunsFreed`).
    /// World stopped; takes no lock.
    @discardableResult
    func freeRun(head b: Int) -> Int {
        let h = heap
        precondition(h.kind(b) == BlockKind.head, "block \(b) is not the head of a run")
        let k = h.runLength(head: b)
        for r in b..<Swift.min(b &+ k, h.blockCount) {
            h.setInUse(r, false)
            h.setUsed(r, 0)
            h.setKind(r, BlockKind.ordinary)
        }
        return k
    }

    /// Free block `b` when no live body is in it: a run's head frees the
    /// whole run (`runs` counts it), a continuation is left to its head
    /// (live or freed with it), an ordinary block is freed alone. Answers
    /// the blocks freed. World stopped; takes no lock; the caller rebuilds
    /// the pool.
    func freeBlockWithoutLiveBody(_ b: Int, blind: Bool, runs: inout UInt64) -> Int {
        let h = heap
        if !blind {
            let kd = h.kind(b)
            if kd == BlockKind.continuation { return 0 }
            if kd == BlockKind.head {
                runs &+= 1
                return freeRun(head: b)
            }
        }
        h.setInUse(b, false)
        h.setUsed(b, 0)
        return 1
    }

    /// Count runs a sweep freed. Takes the pools lock.
    func noteRunsFreed(_ n: UInt64) {
        if n == 0 { return }
        lockPools()
        unsafe pools.pointee.runsFreed &+= n
        unlockPools()
    }

    /// A test switch turned the run rule of `reader` off.
    @inline(__always)
    func isRunBlind(_ reader: RunReader) -> Bool { config.testSwitches.runBlind == reader }

    /// Module 10's counters: large objects allocated, their bytes, runs
    /// freed, large requests that found no run.
    var largeObjectCounters: (allocations: UInt64, bytes: UInt64, runsFreed: UInt64, failures: UInt64) {
        lockPools()
        defer { unlockPools() }
        let p = unsafe pools.pointee
        return (p.largeAllocations, p.largeBytes, p.runsFreed, p.largeFailures)
    }

    /// Blocks in runs (heads and continuations). World stopped.
    var runBlocksInUse: Int {
        let h = heap
        var n = 0
        for b in 0..<h.blockCount where h.inUseRun(b) { n += 1 }
        return n
    }
}

extension BlockHeap {
    func inUseRun(_ b: Int) -> Bool { isInUse(b) && isRun(b) }
}

/// Module 10: a large allocation fills old space without a scavenge, and
/// module 5's trigger is decided at the end of young collections only; a
/// Process that allocates nothing but large objects would fill old space to
/// its soft limit and fall back to a full collection with no cycle ever
/// started (AGENTS.md: a trigger must watch every resource a fallback can
/// exhaust). So after a large allocation the trigger is decided again, and
/// when it fires a cycle starts at once: module 7's initial-mark pause (any
/// stop: its young-root scan covers the nurseries), or, under the
/// stop-the-world scavenge, a scavenge whose end takes the snapshot. The
/// new object is kept as a root of that stop: it is old, so it is a
/// snapshot entry, and nothing else holds it yet.
func startCycleAfterLargeAllocation(_ vm: VMPointer, _ w: WorkerPointer, _ o: Oop) {
    guard let mk = unsafe vm.pointee.marking, unsafe mk.phaseNow == .idle,
          let trigger = unsafe decideTrigger(mk, rate: 0, oldEntries: nil, record: false) else { return }
    if let y = unsafe vm.pointee.young {
        unsafe stopWorld(vm, w, retry: true, keeping: [o]) { stop in
            guard unsafe mk.phaseNow == .idle else { return }
            unsafe mk.pointee.log.pointee.counters.cyclesAfterLarge &+= 1
            unsafe initialMarkPause(vm, y, mk, stop, trigger: trigger)
        }
    } else if unsafe vm.pointee.nursery != nil {
        unsafe stopWorld(vm, w, retry: true, keeping: [o]) { stop in
            guard unsafe mk.phaseNow == .idle else { return }
            unsafe mk.pointee.log.pointee.counters.cyclesAfterLarge &+= 1
            unsafe youngPause(vm, w, stop, full: false)
        }
    }
}
