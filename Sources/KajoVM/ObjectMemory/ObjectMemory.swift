import Darwin
import Synchronization

/// The object memory: oops, entries, the block heap, allocation, and the
/// stop-the-world operations on them (docs/modules/object-memory.md).
///
/// A small value holding the two bases the hot paths need (so they stay in
/// registers) and a pointer to the shared state. Copies are cheap and all
/// refer to the same memory; `destroy()` releases it once.
///
/// Thread rules: allocation through distinct contexts may run on any
/// threads at once. Everything else (load and store of one object aside)
/// runs with the world stopped: no context allocating, no other thread
/// inside the object memory. Module 3's safepoints provide that; in this
/// module the caller does.
@safe struct ObjectMemory {
    let table: UnsafeMutableRawPointer
    let heapBase: UnsafeMutableRawPointer
    let shared: UnsafeMutablePointer<MemoryShared>

    init(_ requested: ObjectMemoryConfig) throws(ObjectMemoryError) {
        let config = requested.effective
        guard config.heapBytes > 0, config.heapBytes % BlockHeap.blockBytes == 0,
              config.reserveBytes >= 0, config.reserveBytes % BlockHeap.blockBytes == 0,
              config.nurseryRegionBytes >= 0, config.nurseryRegionBytes % BlockHeap.blockBytes == 0,
              (config.endGrowthBytes ?? 0) >= 0, (config.endGrowthBytes ?? 0) % BlockHeap.blockBytes == 0,
              UInt64(config.heapBytes + config.reserveBytes + config.nurseryRegionBytes) <= VirtualMemory.aliasDistance else {
            throw .invalidConfig("heapBytes, reserveBytes, endGrowthBytes and nurseryRegionBytes must be multiples of \(BlockHeap.blockBytes), at most 4 GiB together")
        }
        // Module 10: the final collection's growth, address space only
        // until the VM's end takes it; clamped to what 4 GiB leaves.
        let room = Int(VirtualMemory.aliasDistance) - config.heapBytes - config.reserveBytes - config.nurseryRegionBytes
        let growth = Swift.min(config.endGrowthBytes ?? config.reserveBytes, room) / BlockHeap.blockBytes * BlockHeap.blockBytes
        guard config.entryCapacity >= 2, UInt64(config.entryCapacity) <= 1 << 32 else {
            throw .invalidConfig("entryCapacity must be in 2...2^32")
        }
        guard config.entryChunk >= 1 else { throw .invalidConfig("entryChunk must be positive") }
        let heap = try BlockHeap(bytes: config.heapBytes + config.reserveBytes + growth, extraBytes: config.nurseryRegionBytes)
        let tableBytes = config.entryCapacity * 16
        let table: UnsafeMutableRawPointer
        let marks: UnsafeMutableRawPointer
        let oldMap: EntryBitmap
        do {
            unsafe table = try VirtualMemory.reserve(tableBytes)
            unsafe marks = try VirtualMemory.reserve(config.entryCapacity)
            oldMap = try EntryBitmap(entries: UInt64(config.entryCapacity))
        } catch {
            heap.release()
            throw error
        }
        let poolLock = os_unfair_lock_t.allocate(capacity: 1)
        unsafe poolLock.initialize(to: os_unfair_lock())
        let pools = UnsafeMutablePointer<Pools>.allocate(capacity: 1)
        unsafe pools.initialize(to: Pools(blockCount: heap.blockCount, softLimit: config.heapBytes / BlockHeap.blockBytes,
                                          hardLimit: (config.heapBytes + config.reserveBytes) / BlockHeap.blockBytes))
        let gc = UnsafeMutablePointer<CollectorState>.allocate(capacity: 1)
        unsafe gc.initialize(to: CollectorState())
        let fin = UnsafeMutablePointer<RawArray<UInt64>>.allocate(capacity: 1)
        unsafe fin.initialize(to: RawArray())
        let shared = UnsafeMutablePointer<MemoryShared>.allocate(capacity: 1)
        unsafe shared.initialize(to: MemoryShared(
            config: config, heap: heap, entryCapacity: UInt64(config.entryCapacity), tableBytes: tableBytes,
            marks: marks.bindMemory(to: UInt8.self, capacity: config.entryCapacity), oldMap: oldMap, poolLock: poolLock,
            pools: pools, gc: gc, finalization: fin))
        unsafe self.table = table
        unsafe self.heapBase = heap.base
        unsafe self.shared = shared
        unsafe gc.pointee.collectorContext = makeContext()
    }

    /// Release every reservation and context. No copy of this value may be
    /// used afterwards.
    func destroy() {
        let s = unsafe shared.pointee
        unsafe s.pools.pointee.destroyContexts()
        unsafe s.pools.pointee.free()
        unsafe s.pools.deinitialize(count: 1)
        unsafe s.pools.deallocate()
        unsafe s.poolLock.deallocate()
        unsafe s.gc.pointee.free()
        unsafe s.gc.deinitialize(count: 1)
        unsafe s.gc.deallocate()
        unsafe s.finalization.pointee.free()
        unsafe s.finalization.deinitialize(count: 1)
        unsafe s.finalization.deallocate()
        s.heap.release()
        unsafe VirtualMemory.release(table, s.tableBytes)
        unsafe VirtualMemory.release(UnsafeMutableRawPointer(s.marks), Int(s.entryCapacity))
        s.oldMap.release()
        unsafe shared.deinitialize(count: 1)
        unsafe shared.deallocate()
    }

    var config: ObjectMemoryConfig { unsafe shared.pointee.config }
    var heap: BlockHeap { unsafe shared.pointee.heap }
    var entryCapacity: UInt64 { unsafe shared.pointee.entryCapacity }
    var pools: UnsafeMutablePointer<Pools> { unsafe shared.pointee.pools }
    var gc: UnsafeMutablePointer<CollectorState> { unsafe shared.pointee.gc }

    // MARK: - entries

    /// A relaxed atomic load (a plain `ldr` on arm64): module 6's relocator
    /// switches a used entry's state word between stops, and a mutator's
    /// body address is always computed from the value just loaded, never
    /// from a cached or compared one (docs/models/relocation.md, finding 6).
    @inline(__always)
    func stateWord(_ raw: UInt64) -> UInt64 {
        unsafe stateWordAtomic(raw).pointee.load(ordering: .relaxed)
    }

    /// The state word as an atomic (module 6: the CAS to RELOCATING, the
    /// switch, the post-store check's reloads).
    @inline(__always)
    func stateWordAtomic(_ raw: UInt64) -> UnsafeMutablePointer<Atomic<UInt64>> {
        unsafe (table + Int(truncatingIfNeeded: raw)).assumingMemoryBound(to: Atomic<UInt64>.self)
    }

    @inline(__always)
    func setStateWord(_ raw: UInt64, _ v: UInt64) {
        unsafe table.storeBytes(of: v, toByteOffset: Int(truncatingIfNeeded: raw), as: UInt64.self)
    }

    /// A relaxed atomic load (a plain `ldr` on arm64): module 7's young
    /// collectors decide a young object's header (age, promotion) with a
    /// compare-and-swap while mutators read its class and count.
    @inline(__always)
    func headerWord(_ raw: UInt64) -> UInt64 {
        unsafe headerAtomic(raw).pointee.load(ordering: .relaxed)
    }

    /// The header word as an atomic (module 7's claim).
    @inline(__always)
    func headerAtomic(_ raw: UInt64) -> UnsafeMutablePointer<Atomic<UInt64>> {
        unsafe (table + Int(truncatingIfNeeded: raw &+ 8)).assumingMemoryBound(to: Atomic<UInt64>.self)
    }

    @inline(__always)
    func setHeaderWord(_ raw: UInt64, _ v: UInt64) {
        unsafe table.storeBytes(of: v, toByteOffset: Int(truncatingIfNeeded: raw &+ 8), as: UInt64.self)
    }

    @inline(__always)
    func header(_ o: Oop) -> Header { Header(raw: headerWord(o.raw)) }

    /// Header writes happen with the world stopped only.
    func setHeader(_ o: Oop, _ h: Header) { setHeaderWord(o.raw, h.raw) }

    @inline(__always)
    func bodyOffset(_ o: Oop) -> UInt64 { stateWord(o.raw) }

    func blockIndex(of o: Oop) -> Int { BlockHeap.block(ofOffset: bodyOffset(o)) }

    // MARK: - object access (the single load and store paths)

    @inline(__always)
    func classIndex(of o: Oop) -> UInt64 {
        assert(isUsedReference(o))
        return header(o).classIndex
    }

    /// Slots, or bytes for a byte object.
    @inline(__always)
    func count(of o: Oop) -> UInt64 {
        assert(isUsedReference(o))
        return header(o).count
    }

    @inline(__always)
    func isBytes(_ o: Oop) -> Bool {
        assert(isUsedReference(o))
        return header(o).isBytes
    }

    /// A relaxed atomic load of the slot (a plain `ldr`): module 6's
    /// relocator writes new bodies with relaxed atomic stores, and the
    /// address depends on the state word just loaded (the RCU argument).
    @inline(__always)
    func load(_ o: Oop, _ i: Int) -> Oop {
        assert(isUsedReference(o) && !header(o).isBytes && UInt64(i) < header(o).count)
        let off = Int(truncatingIfNeeded: stateWord(o.raw)) &+ 8 &+ i &<< 3
        return Oop(raw: unsafe (heapBase + off).assumingMemoryBound(to: Atomic<UInt64>.self).pointee.load(ordering: .relaxed))
    }

    /// The raw store: no post-store check. A relaxed atomic store (a plain
    /// `str` on arm64): module 5's marker reads slots of old objects with
    /// relaxed atomic loads while mutators store. Only for stores that no
    /// relocation can race: fresh objects being initialised, collectors in
    /// a pause, the image loader, and module 6's tests (the "raw store"
    /// that shows the check is needed). Every mutator store into an object
    /// that may be old goes through `storeChecked` (module 6).
    @inline(__always)
    func store(_ o: Oop, _ i: Int, _ v: Oop) {
        assert(isUsedReference(o) && !header(o).isBytes && UInt64(i) < header(o).count)
        assert(v.isValidImmediate || isUsedReference(v))
        let off = Int(truncatingIfNeeded: stateWord(o.raw)) &+ 8 &+ i &<< 3
        unsafe (heapBase + off).assumingMemoryBound(to: Atomic<UInt64>.self).pointee.store(v.raw, ordering: .relaxed)
    }

    /// Module 6's post-store check (ADR 0007; docs/models/relocation.md,
    /// steps `M store`): load the state word (relaxed), store the slot
    /// through it (seq_cst), reload the state word (seq_cst). True when the
    /// store certainly landed in the body the entry leads to: the reload
    /// equals the first load and that had no RELOCATING bit. False: the
    /// caller makes one out-of-line call (`postStoreSlow`) that waits out
    /// the copy and stores again. Both halves are seq_cst, each on its own
    /// (the model shows either weakened loses the store). On arm64: `ldr`,
    /// `stlr`, `ldar`, `cmp`, `b.ne`, `tbnz`.
    ///
    /// Built with `-DKAJO_NO_POST_STORE` (benchmarks only, never shipped):
    /// the raw store, answering true, to measure the check's own cost.
    @inline(__always)
    func storeChecked(_ o: Oop, _ i: Int, _ v: Oop) -> Bool {
        assert(isUsedReference(o) && !header(o).isBytes && UInt64(i) < header(o).count)
        assert(v.isValidImmediate || isUsedReference(v))
        #if KAJO_NO_POST_STORE
        store(o, i, v)
        return true
        #else
        let sw = unsafe stateWordAtomic(o.raw)
        let e1 = unsafe sw.pointee.load(ordering: .relaxed)
        let off = Int(truncatingIfNeeded: e1) &+ 8 &+ i &<< 3
        unsafe (heapBase + off).assumingMemoryBound(to: Atomic<UInt64>.self).pointee.store(v.raw, ordering: .sequentiallyConsistent)
        let e2 = unsafe sw.pointee.load(ordering: .sequentiallyConsistent)
        return e2 == e1 && e1 & EntryState.relocatingBit == 0
        #endif
    }

    /// The same for one byte of a byte object (`at:put:` on a ByteArray).
    @inline(__always)
    func storeByteChecked(_ o: Oop, _ i: Int, _ v: UInt8) -> Bool {
        assert(isUsedReference(o) && header(o).isBytes && UInt64(i) < header(o).count)
        let sw = unsafe stateWordAtomic(o.raw)
        let e1 = unsafe sw.pointee.load(ordering: .relaxed)
        let off = Int(truncatingIfNeeded: e1) &+ 8 &+ i
        unsafe (heapBase + off).assumingMemoryBound(to: Atomic<UInt8>.self).pointee.store(v, ordering: .sequentiallyConsistent)
        let e2 = unsafe sw.pointee.load(ordering: .sequentiallyConsistent)
        return e2 == e1 && e1 & EntryState.relocatingBit == 0
    }

    /// Store `v` into slot `i` of the body at state word `e` (no check):
    /// the post-store slow path's redo, the hazard primitive's stores
    /// through the body it holds. seq_cst (module 6; the young-collection
    /// model's finding for stores a barrier's load follows).
    @inline(__always)
    func storeSlot(atState e: UInt64, _ i: Int, _ v: UInt64) {
        let off = Int(truncatingIfNeeded: e) &+ 8 &+ i &<< 3
        unsafe (heapBase + off).assumingMemoryBound(to: Atomic<UInt64>.self).pointee.store(v, ordering: .sequentiallyConsistent)
    }

    @inline(__always)
    func storeByte(atState e: UInt64, _ i: Int, _ v: UInt8) {
        let off = Int(truncatingIfNeeded: e) &+ 8 &+ i
        unsafe (heapBase + off).assumingMemoryBound(to: Atomic<UInt8>.self).pointee.store(v, ordering: .sequentiallyConsistent)
    }

    /// A heap word as module 6's relocator reads and writes it (back
    /// references and body words): relaxed atomics.
    @inline(__always)
    func wordAtomic(atOffset off: UInt64) -> UInt64 {
        unsafe (heapBase + Int(truncatingIfNeeded: off)).assumingMemoryBound(to: Atomic<UInt64>.self).pointee.load(ordering: .relaxed)
    }

    @inline(__always)
    func setWordAtomic(atOffset off: UInt64, _ v: UInt64) {
        unsafe (heapBase + Int(truncatingIfNeeded: off)).assumingMemoryBound(to: Atomic<UInt64>.self).pointee.store(v, ordering: .relaxed)
    }

    /// A slot as the concurrent marker reads it: a relaxed atomic load.
    @inline(__always)
    func loadAtomic(bodyOffset s: UInt64, _ i: Int) -> UInt64 {
        let off = Int(truncatingIfNeeded: s) &+ 8 &+ i &<< 3
        return unsafe (heapBase + off).assumingMemoryBound(to: Atomic<UInt64>.self).pointee.load(ordering: .relaxed)
    }

    @inline(__always)
    func loadByte(_ o: Oop, _ i: Int) -> UInt8 {
        assert(isUsedReference(o) && header(o).isBytes && UInt64(i) < header(o).count)
        let off = Int(truncatingIfNeeded: stateWord(o.raw)) &+ 8 &+ i
        return unsafe (heapBase + off).assumingMemoryBound(to: Atomic<UInt8>.self).pointee.load(ordering: .relaxed)
    }

    /// The raw byte store (no post-store check): fresh objects and the
    /// image loader only. Mutators use `storeByteChecked`.
    @inline(__always)
    func storeByte(_ o: Oop, _ i: Int, _ v: UInt8) {
        assert(isUsedReference(o) && header(o).isBytes && UInt64(i) < header(o).count)
        let off = Int(truncatingIfNeeded: stateWord(o.raw)) &+ 8 &+ i
        unsafe (heapBase + off).assumingMemoryBound(to: Atomic<UInt8>.self).pointee.store(v, ordering: .relaxed)
    }

    // MARK: - body bases (the interpreter's two cached pointers)

    /// The address of a byte object's first byte. Only the interpreter may
    /// hold it, for the running method's bytecodes, and only until the next
    /// call that can pause: a compaction moves the body. Re-derive after.
    @inline(__always)
    func bytesBase(_ o: Oop) -> UnsafePointer<UInt8> {
        assert(isUsedReference(o) && header(o).isBytes)
        let off = Int(truncatingIfNeeded: stateWord(o.raw)) &+ 8
        return unsafe UnsafePointer(heapBase.advanced(by: off).assumingMemoryBound(to: UInt8.self))
    }

    /// The address of a pointer object's first slot, under the same rule as
    /// `bytesBase`: the running method's literal frame only.
    @inline(__always)
    func slotsBase(_ o: Oop) -> UnsafePointer<UInt64> {
        assert(isUsedReference(o) && !header(o).isBytes)
        let off = Int(truncatingIfNeeded: stateWord(o.raw)) &+ 8
        return unsafe UnsafePointer(heapBase.advanced(by: off).assumingMemoryBound(to: UInt64.self))
    }

    /// An object reference to an entry in use (bounds and state checked).
    func isUsedReference(_ o: Oop) -> Bool {
        o.isObject && o.entryIndex < highWater && !EntryState.isFree(stateWord(o.raw))
            && headerWord(o.raw) != 0
    }

    var highWater: UInt64 {
        lockPools()
        defer { unlockPools() }
        return unsafe pools.pointee.highWater
    }

    // MARK: - counters

    var counters: Counters {
        var c = unsafe gc.pointee.counters
        let a = allocationCounters
        c.allocations = a.allocations
        c.allocatedBytes = a.allocatedBytes
        c.allocationFailures = a.allocationFailures
        c.entryRefills = a.entryRefills
        c.blockRefills = a.blockRefills
        return c
    }

    var allocationCounters: AllocationCounters {
        lockPools()
        defer { unlockPools() }
        var a = unsafe pools.pointee.retiredCounters
        let n = unsafe pools.pointee.contexts.count
        for i in 0..<n { unsafe a.add(pools.pointee.contexts[i].pointee.counters) }
        return a
    }

    /// The lock is outside `Pools`: reading it through `pools.pointee` would
    /// be an access to the whole struct, racing with writes made under the
    /// lock (a Swift exclusivity race to ThreadSanitizer, AGENTS.md).
    func lockPools() { unsafe os_unfair_lock_lock(shared.pointee.poolLock) }
    func unlockPools() { unsafe os_unfair_lock_unlock(shared.pointee.poolLock) }
}

/// Copies are handed to other threads by design: allocation through
/// distinct contexts runs concurrently (the pools take a lock), everything
/// else runs with the world stopped. The checker cannot see that rule;
/// tests under ThreadSanitizer do.
extension ObjectMemory: @unchecked Sendable {}

/// What every copy of an `ObjectMemory` shares. Immutable after creation
/// except through the sub-state pointers, one per lock (AGENTS.md).
@safe struct MemoryShared {
    let config: ObjectMemoryConfig
    let heap: BlockHeap
    let entryCapacity: UInt64
    let tableBytes: Int
    /// Mark bytes, one per entry, beside the table. Never set in headers.
    /// Module 1's collector at a stop and module 5's marker between stops
    /// use the same map, one at a time; outside a collection every byte is
    /// zero.
    let marks: UnsafeMutablePointer<UInt8>
    /// One bit per entry: set while it holds an old object (OldMap.swift).
    let oldMap: EntryBitmap
    let poolLock: os_unfair_lock_t
    /// Guarded by `poolLock`.
    let pools: UnsafeMutablePointer<Pools>
    /// Written with the world stopped only.
    let gc: UnsafeMutablePointer<CollectorState>
    /// Ephemerons whose key was found unreachable, oldest first, until the
    /// finalization Process takes them. A root. Under `poolLock` (a worker
    /// takes from it while the world runs); appended with the world stopped.
    let finalization: UnsafeMutablePointer<RawArray<UInt64>>
}

/// Free blocks, free entry runs, the table's high water mark and the
/// registered contexts. Guarded by `MemoryShared.poolLock`; a pause takes
/// it too.
@safe struct Pools {
    /// Blocks to hand out, lowest index on top. A block here is either free
    /// (used 0, not in use) or the partly filled last destination of a
    /// compaction (in use, used < block size).
    var freeBlocks = RawArray<UInt32>()
    /// Heads of free-entry runs of up to `entryChunk` entries.
    var entryRuns = RawArray<UInt64>()
    /// Next never-used entry index. Entry 0 is reserved.
    var highWater: UInt64 = 1
    var contexts = unsafe RawArray<UnsafeMutablePointer<ContextState>>()
    /// Entry stashes (module 4's nurseries): array-held free entries, each
    /// owned by one stash.
    var stashes = unsafe RawArray<UnsafeMutablePointer<EntryStash>>()
    /// Counters of destroyed contexts.
    var retiredCounters = AllocationCounters()
    /// Blocks in use, and how many a mutator may hold: blocks past the soft
    /// limit are the promotion reserve (module 4).
    var blocksInUse = 0
    var softLimitBlocks: Int
    /// Promotion refills that found no block (the reserve was too small).
    var reserveExhausted: UInt64 = 0
    /// Module 10: blocks a promotion may hold (the soft limit and the
    /// promotion reserve); the rest of the reservation is the final
    /// collection's growth, taken only while `endGrowth` is set.
    var hardLimitBlocks: Int
    /// Module 10: the VM's final collection runs: promotion may take every
    /// block of the reservation.
    var endGrowth = false
    /// Module 10: large objects (runs) allocated and their bytes, runs
    /// freed, and large requests that found no run.
    var largeAllocations: UInt64 = 0
    var largeBytes: UInt64 = 0
    var runsFreed: UInt64 = 0
    var largeFailures: UInt64 = 0
    /// Module 7 under the reserve's rule: blocks promised to young
    /// collections in flight (`reservePromotion`).
    var promotionReserved = 0
    /// Module 5: free-entry runs a lazy sweep produced, published at the
    /// next pause; the stamp of each block's last refill and the stamp
    /// given now (the current marking cycle's).
    var pendingRuns = RawArray<UInt64>()
    var blockStamps: UnsafeMutablePointer<UInt32>
    var stampNow: UInt32 = 0

    init(blockCount: Int, softLimit: Int, hardLimit: Int) {
        unsafe blockStamps = .allocate(capacity: blockCount)
        unsafe blockStamps.initialize(repeating: 0, count: blockCount)
        softLimitBlocks = Swift.min(softLimit, blockCount)
        hardLimitBlocks = Swift.min(Swift.max(hardLimit, softLimitBlocks), blockCount)
        var b = blockCount - 1
        while b >= 0 { freeBlocks.append(UInt32(b)); b -= 1 }
    }

    mutating func destroyContexts() {
        while let c = unsafe contexts.popLast() {
            unsafe c.deinitialize(count: 1)
            unsafe UnsafeMutableRawPointer(c).deallocate()
        }
    }

    mutating func free() {
        freeBlocks.free()
        entryRuns.free()
        pendingRuns.free()
        unsafe blockStamps.deallocate()
        unsafe contexts.free()
        unsafe stashes.free()
    }
}

/// State written only with the world stopped.
@safe struct CollectorState {
    var counters = Counters()
    /// Reports of verifier failures under `.record`, newest last.
    var failures: [String] = []
    /// The object memory's own context, for bodies allocated inside an
    /// operation (reshape).
    var collectorContext: AllocContext?
    /// Root registry slots; `Oop.none` marks a removed slot.
    var roots = RawArray<UInt64>()
    var freeRootSlots = RawArray<Int32>()
    /// Class index -> class oop. Index 0 is never a class.
    var classTable = RawArray<UInt64>(repeating: 0, count: 1)
    /// Class index -> format word (ADR 0009 section 6), beside the table.
    var classFormats = RawArray<UInt64>(repeating: 0, count: 1)
    var markStack = RawArray<UInt64>()
    /// Marked weak objects and deferred ephemerons of the current mark.
    var weakObjects = RawArray<UInt64>()
    var ephemerons = RawArray<UInt64>()
    /// What a weak slot becomes when its referent dies (the image's nil;
    /// `.none` until set: then no class may be weak).
    var nilObject = Oop.none
    /// Module 8d: the image is a release image (its header's flag): the
    /// make, install and remove primitives fail. Set by the image loader or
    /// `Image.seal` before any VM runs over the memory, never afterwards,
    /// and by no primitive.
    var releaseImage = false
    /// A mark fired ephemerons since the last `takeFinalizationSignal`.
    var finalizationSignal = false
    /// Heap offsets of the nursery region (module 4), where young bodies
    /// lie; empty when there is none.
    var nurseryStart: UInt64 = 0
    var nurseryEnd: UInt64 = 0
    /// Module 7: the region lies in the heap's doubly mapped memory.
    var nurseryAliased = false
    /// Run before every operation that needs nothing young (collect,
    /// compact, become, forward, reshape, snapshot): module 4 promotes
    /// everything. The argument is the operation's extra roots, or nil when
    /// it was given none (the hook gathers the stop's roots itself). It
    /// answers the young objects it could not promote (the promotion
    /// reserve's fallback kept them in place; usually none).
    var beforeOldSpaceOperation: (([Oop]?) -> [Oop])? = nil
    /// Run after every sweep of old space (module 4: remembered lists drop
    /// holders the sweep freed, which only kept young objects can leave).
    var afterOldSpaceSweep: (() -> Void)? = nil
    /// Module 5: the snapshot of a pending lazy sweep (OldMap.swift).
    var pendingDead: EntryBitmap? = nil
    /// Module 5: a concurrent marking cycle owns the mark map (marks are set
    /// between stops; the heap verifier allows them).
    var markingActive = false

    mutating func free() {
        roots.free()
        freeRootSlots.free()
        classTable.free()
        classFormats.free()
        markStack.free()
        weakObjects.free()
        ephemerons.free()
    }
}
