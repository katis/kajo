/// An allocation context: a caller's private block (bump allocation) and
/// private free-entry list (experiments/object-representation SPEC, B).
/// Module 3 gives one to each worker. A context is used by one thread at a
/// time.
@safe struct AllocContext: Equatable, @unchecked Sendable {
    let state: UnsafeMutablePointer<ContextState>

    /// Written out: the synthesized one compares unsafe pointers unmarked.
    static func == (a: AllocContext, b: AllocContext) -> Bool { unsafe a.state == b.state }
}

/// One context's state, in its own 128-byte aligned allocation so contexts
/// on different threads never share a cache line (AGENTS.md).
struct ContextState {
    /// Heap offsets of the bump region; both 0 when no block is held.
    var top: UInt64 = 0
    var end: UInt64 = 0
    /// Oop of the first entry of the private free list, 0 when empty.
    var freeEntry: UInt64 = 0
    var counters = AllocationCounters()
}

extension ObjectMemory {
    static let contextBytes = 128

    func makeContext() -> AllocContext {
        precondition(MemoryLayout<ContextState>.size <= ObjectMemory.contextBytes)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: ObjectMemory.contextBytes,
                                                   alignment: ObjectMemory.contextBytes)
        let p = unsafe raw.bindMemory(to: ContextState.self, capacity: 1)
        unsafe p.initialize(to: ContextState())
        lockPools()
        unsafe pools.pointee.contexts.append(p)
        unlockPools()
        return unsafe AllocContext(state: p)
    }

    /// Retire and forget a context. Its counters are kept.
    func destroyContext(_ ctx: AllocContext) {
        retire(ctx)
        lockPools()
        defer { unlockPools() }
        let n = unsafe pools.pointee.contexts.count
        for i in 0..<n where unsafe pools.pointee.contexts[i] == ctx.state {
            unsafe pools.pointee.contexts[i] = pools.pointee.contexts[n - 1]
            _ = unsafe pools.pointee.contexts.popLast()
            unsafe pools.pointee.retiredCounters.add(ctx.state.pointee.counters)
            unsafe ctx.state.deinitialize(count: 1)
            unsafe UnsafeMutableRawPointer(ctx.state).deallocate()
            return
        }
        preconditionFailure("not a context of this object memory")
    }

    /// Give back the context's block: record how much of it is used. Its
    /// free entries stay with it until the next sweep.
    func retire(_ ctx: AllocContext) {
        let c = unsafe ctx.state
        let end = unsafe c.pointee.end
        if end == 0 { return }
        let b = BlockHeap.block(ofOffset: end &- 1)
        unsafe heap.setUsed(b, c.pointee.top &- BlockHeap.start(ofBlock: b))
        unsafe c.pointee.top = 0
        unsafe c.pointee.end = 0
    }

    /// Retire every context: every block's `used` is then exact.
    func retireAllContexts() {
        lockPools()
        let n = unsafe pools.pointee.contexts.count
        var cs: [AllocContext] = []
        for i in 0..<n { unsafe cs.append(AllocContext(state: pools.pointee.contexts[i])) }
        unlockPools()
        for c in cs { retire(c) }
    }

    // MARK: - allocation

    /// A pointer object with every slot set to `fill`, or `.none` when the
    /// context found no block or no entry: a collection must run before the
    /// caller tries again. Never collects.
    @inline(__always)
    func tryAllocate(_ ctx: AllocContext, classIndex: UInt64, slots: Int, fill: Oop) -> Oop {
        precondition(UInt(bitPattern: slots) <= UInt(Header.maxSlots), "object larger than a block")
        assert(classIndex != 0 && classIndex <= Header.maxClassIndex)
        let n = UInt64(truncatingIfNeeded: slots)
        return allocate(ctx, header: Header(raw: classIndex | n &<< Header.countShift),
                        bytes: n &<< 3 &+ 8, fill: fill)
    }

    /// A byte object of `count` bytes, all zero, or `.none` as `tryAllocate`.
    @inline(__always)
    func tryAllocateBytes(_ ctx: AllocContext, classIndex: UInt64, count: Int) -> Oop {
        precondition(UInt(bitPattern: count) <= UInt(Header.maxBytes), "object larger than a block")
        assert(classIndex != 0 && classIndex <= Header.maxClassIndex)
        let n = UInt64(truncatingIfNeeded: count)
        return allocate(ctx, header: Header(raw: classIndex | n &<< Header.countShift | Header.bytesBit),
                        bytes: (n &+ 7) & ~7 &+ 8, fill: Oop(raw: 0))
    }

    @inline(__always)
    func allocate(_ ctx: AllocContext, header: Header, bytes: UInt64, fill: Oop) -> Oop {
        let c = unsafe ctx.state
        if _slowPath(unsafe c.pointee.top &+ bytes > c.pointee.end || c.pointee.freeEntry == 0) {
            return allocateSlow(ctx, header: header, bytes: bytes, fill: fill)
        }
        return place(ctx, header: header, bytes: bytes, fill: fill)
    }

    /// Bump the body, pop the entry, initialise both. The caller made sure
    /// there is room and an entry.
    @inline(__always)
    func place(_ ctx: AllocContext, header: Header, bytes: UInt64, fill: Oop) -> Oop {
        let c = unsafe ctx.state
        let off = unsafe c.pointee.top
        let e = unsafe c.pointee.freeEntry
        unsafe c.pointee.top = off &+ bytes
        unsafe c.pointee.freeEntry = stateWord(e) & EntryState.nextMask
        let words = bytes &>> 3
        let body = Int(truncatingIfNeeded: off)
        unsafe heapBase.storeBytes(of: BackRef.make(entryIndex: e &>> 4, words: words), toByteOffset: body, as: UInt64.self)
        var i = 1
        let n = Int(truncatingIfNeeded: words)
        while i < n {
            unsafe heapBase.storeBytes(of: fill.raw, toByteOffset: body &+ i &<< 3, as: UInt64.self)
            i &+= 1
        }
        setHeaderWord(e, header.raw)
        setStateWord(e, off)
        unsafe c.pointee.counters.allocations &+= 1
        unsafe c.pointee.counters.allocatedBytes &+= bytes
        return Oop(raw: e)
    }

    /// The one out-of-line call of the allocation path: refill the block or
    /// the entry list, then place the object.
    @inline(never)
    func allocateSlow(_ ctx: AllocContext, header: Header, bytes: UInt64, fill: Oop) -> Oop {
        let c = unsafe ctx.state
        if unsafe c.pointee.top &+ bytes > c.pointee.end, !refillBlock(ctx, bytes: bytes) {
            unsafe c.pointee.counters.allocationFailures &+= 1
            return .none
        }
        if unsafe c.pointee.freeEntry == 0, !refillEntries(ctx) {
            unsafe c.pointee.counters.allocationFailures &+= 1
            return .none
        }
        return place(ctx, header: header, bytes: bytes, fill: fill)
    }

    /// A body of `bytes` with no entry, for an operation that repoints an
    /// existing entry (reshape). The back reference is the caller's to write.
    /// `nil` when no block has room.
    func allocateBody(_ ctx: AllocContext, bytes: UInt64) -> UInt64? {
        let c = unsafe ctx.state
        if unsafe c.pointee.top &+ bytes > c.pointee.end, !refillBlock(ctx, bytes: bytes) {
            unsafe c.pointee.counters.allocationFailures &+= 1
            return nil
        }
        let off = unsafe c.pointee.top
        unsafe c.pointee.top = off &+ bytes
        unsafe c.pointee.counters.allocatedBytes &+= bytes
        return off
    }

    private func refillBlock(_ ctx: AllocContext, bytes: UInt64) -> Bool {
        retire(ctx)
        let c = unsafe ctx.state
        lockPools()
        defer { unlockPools() }
        while let b32 = unsafe pools.pointee.freeBlocks.popLast() {
            let b = Int(b32)
            let start = BlockHeap.start(ofBlock: b)
            let used = heap.usedBytes(b)
            heap.setInUse(b, true)
            if used &+ bytes <= UInt64(BlockHeap.blockBytes) {
                unsafe c.pointee.top = start &+ used
                unsafe c.pointee.end = start &+ UInt64(BlockHeap.blockBytes)
                unsafe c.pointee.counters.blockRefills &+= 1
                return true
            }
            // A compaction tail too short for this body stays in use as is.
        }
        return false
    }

    private func refillEntries(_ ctx: AllocContext) -> Bool {
        let c = unsafe ctx.state
        lockPools()
        defer { unlockPools() }
        if let head = unsafe pools.pointee.entryRuns.popLast() {
            unsafe c.pointee.freeEntry = head
            unsafe c.pointee.counters.entryRefills &+= 1
            return true
        }
        let hw = unsafe pools.pointee.highWater
        let n = Swift.min(UInt64(config.entryChunk), entryCapacity - hw)
        if n == 0 { return false }
        for i in 0..<n {
            let e = (hw + i) << 4
            setStateWord(e, EntryState.free(next: i + 1 < n ? e + 16 : 0))
            setHeaderWord(e, 0)
        }
        unsafe pools.pointee.highWater = hw + n
        unsafe c.pointee.freeEntry = hw << 4
        unsafe c.pointee.counters.entryRefills &+= 1
        return true
    }
}
