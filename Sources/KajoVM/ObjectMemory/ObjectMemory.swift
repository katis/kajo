import Darwin

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
              UInt64(config.heapBytes) <= VirtualMemory.aliasDistance else {
            throw .invalidConfig("heapBytes must be a positive multiple of \(BlockHeap.blockBytes), at most 4 GiB")
        }
        guard config.entryCapacity >= 2, UInt64(config.entryCapacity) <= 1 << 32 else {
            throw .invalidConfig("entryCapacity must be in 2...2^32")
        }
        guard config.entryChunk >= 1 else { throw .invalidConfig("entryChunk must be positive") }
        let heap = try BlockHeap(bytes: config.heapBytes)
        let tableBytes = config.entryCapacity * 16
        let table: UnsafeMutableRawPointer
        let marks: UnsafeMutableRawPointer
        do {
            unsafe table = try VirtualMemory.reserve(tableBytes)
            unsafe marks = try VirtualMemory.reserve(config.entryCapacity)
        } catch {
            heap.release()
            throw error
        }
        let poolLock = os_unfair_lock_t.allocate(capacity: 1)
        unsafe poolLock.initialize(to: os_unfair_lock())
        let pools = UnsafeMutablePointer<Pools>.allocate(capacity: 1)
        unsafe pools.initialize(to: Pools(blockCount: heap.blockCount))
        let gc = UnsafeMutablePointer<CollectorState>.allocate(capacity: 1)
        unsafe gc.initialize(to: CollectorState())
        let shared = UnsafeMutablePointer<MemoryShared>.allocate(capacity: 1)
        unsafe shared.initialize(to: MemoryShared(
            config: config, heap: heap, entryCapacity: UInt64(config.entryCapacity), tableBytes: tableBytes,
            marks: marks.bindMemory(to: UInt8.self, capacity: config.entryCapacity), poolLock: poolLock,
            pools: pools, gc: gc))
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
        s.heap.release()
        unsafe VirtualMemory.release(table, s.tableBytes)
        unsafe VirtualMemory.release(UnsafeMutableRawPointer(s.marks), Int(s.entryCapacity))
        unsafe shared.deinitialize(count: 1)
        unsafe shared.deallocate()
    }

    var config: ObjectMemoryConfig { unsafe shared.pointee.config }
    var heap: BlockHeap { unsafe shared.pointee.heap }
    var entryCapacity: UInt64 { unsafe shared.pointee.entryCapacity }
    var pools: UnsafeMutablePointer<Pools> { unsafe shared.pointee.pools }
    var gc: UnsafeMutablePointer<CollectorState> { unsafe shared.pointee.gc }

    // MARK: - entries

    @inline(__always)
    func stateWord(_ raw: UInt64) -> UInt64 {
        unsafe table.load(fromByteOffset: Int(truncatingIfNeeded: raw), as: UInt64.self)
    }

    @inline(__always)
    func setStateWord(_ raw: UInt64, _ v: UInt64) {
        unsafe table.storeBytes(of: v, toByteOffset: Int(truncatingIfNeeded: raw), as: UInt64.self)
    }

    @inline(__always)
    func headerWord(_ raw: UInt64) -> UInt64 {
        unsafe table.load(fromByteOffset: Int(truncatingIfNeeded: raw &+ 8), as: UInt64.self)
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

    @inline(__always)
    func load(_ o: Oop, _ i: Int) -> Oop {
        assert(isUsedReference(o) && !header(o).isBytes && UInt64(i) < header(o).count)
        let off = Int(truncatingIfNeeded: stateWord(o.raw)) &+ 8 &+ i &<< 3
        return Oop(raw: unsafe heapBase.load(fromByteOffset: off, as: UInt64.self))
    }

    /// Every store into a slot goes through here: module 4's barrier and
    /// module 6's post-store check hook in at this one place.
    @inline(__always)
    func store(_ o: Oop, _ i: Int, _ v: Oop) {
        assert(isUsedReference(o) && !header(o).isBytes && UInt64(i) < header(o).count)
        assert(v.isSmallInteger || isUsedReference(v))
        let off = Int(truncatingIfNeeded: stateWord(o.raw)) &+ 8 &+ i &<< 3
        unsafe heapBase.storeBytes(of: v.raw, toByteOffset: off, as: UInt64.self)
    }

    @inline(__always)
    func loadByte(_ o: Oop, _ i: Int) -> UInt8 {
        assert(isUsedReference(o) && header(o).isBytes && UInt64(i) < header(o).count)
        let off = Int(truncatingIfNeeded: stateWord(o.raw)) &+ 8 &+ i
        return unsafe heapBase.load(fromByteOffset: off, as: UInt8.self)
    }

    @inline(__always)
    func storeByte(_ o: Oop, _ i: Int, _ v: UInt8) {
        assert(isUsedReference(o) && header(o).isBytes && UInt64(i) < header(o).count)
        let off = Int(truncatingIfNeeded: stateWord(o.raw)) &+ 8 &+ i
        unsafe heapBase.storeBytes(of: v, toByteOffset: off, as: UInt8.self)
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
    let marks: UnsafeMutablePointer<UInt8>
    let poolLock: os_unfair_lock_t
    /// Guarded by `poolLock`.
    let pools: UnsafeMutablePointer<Pools>
    /// Written with the world stopped only.
    let gc: UnsafeMutablePointer<CollectorState>
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
    /// Counters of destroyed contexts.
    var retiredCounters = AllocationCounters()

    init(blockCount: Int) {
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
        unsafe contexts.free()
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
    var markStack = RawArray<UInt64>()

    mutating func free() {
        roots.free()
        freeRootSlots.free()
        classTable.free()
        markStack.free()
    }
}
