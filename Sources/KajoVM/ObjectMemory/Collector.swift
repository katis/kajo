import Darwin

/// The stop-the-world collector: mark from the roots into the side mark
/// map, then sweep the entry table and the blocks eagerly. Kept as the
/// oracle for every later collector (docs/VERIFICATION.md, layer 2).
extension ObjectMemory {
    /// A full mark-sweep. World stopped. `extraRoots` are marked but not
    /// rewritten (oops never change, ADR 0003).
    func collect(extraRoots: [Oop] = []) {
        let young = prepareOldSpaceOperation(extraRoots)
        collectOldSpace(extraRoots: young.isEmpty ? extraRoots : extraRoots + young)
    }

    /// The mark-sweep without the hook: what `collect` runs once nothing
    /// is young, and what module 4 runs around young objects its
    /// promote-all kept (given as roots; the sweep leaves young entries to
    /// their nursery). World stopped.
    func collectOldSpace(extraRoots: [Oop]) {
        retireAllContexts()
        verifyAtPause("before collection", phase: .idle)
        mark(extraRoots: extraRoots)
        verifyAtPause("after mark", phase: .marked(extraRoots: extraRoots))
        sweep()
        unsafe gc.pointee.counters.collections &+= 1
        verifyAtPause("after sweep", phase: .idle)
    }

    /// Allocate, collecting when the context finds no room: mark-sweep
    /// first, then compaction. `nil` when the heap is full of live objects.
    /// Only for a caller that is the only thread in the object memory;
    /// module 3 replaces the collection here with a safepoint request.
    ///
    /// Module 10: an object larger than a block takes a run of blocks
    /// (`tryAllocateAny`), under the same policy: the full collection, then
    /// compaction (which consolidates the ordinary blocks around runs),
    /// then nil.
    func allocate(_ ctx: AllocContext, classIndex: UInt64, slots: Int, fill: Oop, extraRoots: [Oop] = []) -> Oop? {
        if config.stress.contains(.collectAtEveryAllocation) {
            unsafe gc.pointee.counters.stressCollections &+= 1
            collect(extraRoots: extraRoots + [fill])
        }
        var o = tryAllocateAny(ctx, classIndex: classIndex, count: slots, isBytes: false, fill: fill)
        if o == .none {
            collect(extraRoots: extraRoots + [fill])
            o = tryAllocateAny(ctx, classIndex: classIndex, count: slots, isBytes: false, fill: fill)
        }
        if o == .none {
            compact(extraRoots: extraRoots + [fill])
            o = tryAllocateAny(ctx, classIndex: classIndex, count: slots, isBytes: false, fill: fill)
        }
        return o == .none ? nil : o
    }

    /// As `allocate`, for a byte object.
    func allocateBytes(_ ctx: AllocContext, classIndex: UInt64, count: Int, extraRoots: [Oop] = []) -> Oop? {
        if config.stress.contains(.collectAtEveryAllocation) {
            unsafe gc.pointee.counters.stressCollections &+= 1
            collect(extraRoots: extraRoots)
        }
        var o = tryAllocateAny(ctx, classIndex: classIndex, count: count, isBytes: true, fill: Oop(raw: 0))
        if o == .none {
            collect(extraRoots: extraRoots)
            o = tryAllocateAny(ctx, classIndex: classIndex, count: count, isBytes: true, fill: Oop(raw: 0))
        }
        if o == .none {
            compact(extraRoots: extraRoots)
            o = tryAllocateAny(ctx, classIndex: classIndex, count: count, isBytes: true, fill: Oop(raw: 0))
        }
        return o == .none ? nil : o
    }

    // MARK: - mark

    @inline(__always)
    func markByte(_ index: UInt64) -> UInt8 { unsafe shared.pointee.marks[Int(truncatingIfNeeded: index)] }

    @inline(__always)
    func isMarked(_ o: Oop) -> Bool { markByte(o.entryIndex) != 0 }

    @inline(__always)
    func setMark(_ index: UInt64, _ v: UInt8) {
        unsafe shared.pointee.marks[Int(truncatingIfNeeded: index)] = v
    }

    /// Mark everything reachable from the class table, the root registry,
    /// the finalization queue and `extraRoots`. Contexts must be retired.
    ///
    /// Weak slots (the indexed slots of a weak class) are not traced; once
    /// marking is complete each one whose referent is unmarked becomes nil.
    /// An ephemeron (not yet fired) whose key is not marked is deferred;
    /// when its key gets marked it is traced like any object. Ephemerons
    /// whose keys are still unmarked when nothing else is left are fired:
    /// queued for finalization, then traced, so key and value survive this
    /// one collection (ADR 0009 section 1).
    func mark(extraRoots: [Oop]) {
        let hw = highWater
        unsafe memset(shared.pointee.marks, 0, Int(hw))
        var stack = unsafe gc.pointee.markStack
        var weak = unsafe gc.pointee.weakObjects
        var ephs = unsafe gc.pointee.ephemerons
        stack.removeAll()
        weak.removeAll()
        ephs.removeAll()
        forEachRoot(extraRoots: extraRoots) { markAndPush($0, &stack) }
        drainMarks(&stack, &weak, &ephs)
        var queued: UInt64 = 0
        while !ephs.isEmpty {
            // Ephemerons whose key got marked are ordinary objects now.
            var progressed = false
            var i = 0
            while i < ephs.count {
                let e = Oop(raw: ephs[i])
                let key = load(e, 0)
                if !key.isObject || isMarked(key) {
                    pushSlots(e, from: 0, &stack)
                    ephs[i] = ephs[ephs.count - 1]
                    _ = ephs.popLast()
                    progressed = true
                } else {
                    i += 1
                }
            }
            if progressed {
                drainMarks(&stack, &weak, &ephs)
                continue
            }
            // Only ephemerons hold their keys: fire them all.
            let fin = unsafe shared.pointee.finalization
            while let raw = ephs.popLast() {
                let e = Oop(raw: raw)
                var h = header(e)
                h.isFiredEphemeron = true
                setHeader(e, h)
                lockPools()
                unsafe fin.pointee.append(raw)
                unlockPools()
                queued &+= 1
                pushSlots(e, from: 0, &stack)
            }
            drainMarks(&stack, &weak, &ephs)
        }
        var niled: UInt64 = 0
        let nilObj = unsafe gc.pointee.nilObject
        for k in 0..<weak.count {
            let o = Oop(raw: weak[k])
            let h = header(o)
            let base = Int(truncatingIfNeeded: bodyOffset(o)) &+ 8
            var i = classFormat(h.classIndex).namedSlots
            let n = Int(truncatingIfNeeded: h.count)
            while i < n {
                let v = unsafe Oop(raw: heapBase.load(fromByteOffset: base &+ i &<< 3, as: UInt64.self))
                if v.isObject && !isMarked(v) {
                    unsafe heapBase.storeBytes(of: nilObj.raw, toByteOffset: base &+ i &<< 3, as: UInt64.self)
                    niled &+= 1
                }
                i &+= 1
            }
        }
        unsafe gc.pointee.markStack = stack
        unsafe gc.pointee.weakObjects = weak
        unsafe gc.pointee.ephemerons = ephs
        unsafe gc.pointee.counters.weakSlotsNiled &+= niled
        unsafe gc.pointee.counters.ephemeronsQueued &+= queued
        if queued > 0 { unsafe gc.pointee.finalizationSignal = true }
    }

    /// Scan marked objects until the stack is empty: weak objects' strong
    /// part only (and remember them), unfired ephemerons only once their key
    /// is marked (else defer them).
    private func drainMarks(_ stack: inout RawArray<UInt64>, _ weak: inout RawArray<UInt64>,
                            _ ephs: inout RawArray<UInt64>) {
        while let raw = stack.popLast() {
            let o = Oop(raw: raw)
            let h = header(o)
            if h.isBytes { continue }
            let f = classFormat(h.classIndex)
            if _slowPath(f.isSpecial) {
                if f.isWeak {
                    weak.append(raw)
                    pushSlots(o, from: 0, upTo: f.namedSlots, &stack)
                    continue
                }
                if !h.isFiredEphemeron && h.count > 0 {
                    let key = load(o, 0)
                    if key.isObject && !isMarked(key) {
                        ephs.append(raw)
                        continue
                    }
                }
            }
            pushSlots(o, from: 0, &stack)
        }
    }

    @inline(__always)
    private func pushSlots(_ o: Oop, from: Int, upTo limit: Int = .max, _ stack: inout RawArray<UInt64>) {
        let h = header(o)
        let base = Int(truncatingIfNeeded: bodyOffset(o)) &+ 8
        let n = Swift.min(Int(truncatingIfNeeded: h.count), limit)
        var i = from
        while i < n {
            let v = unsafe Oop(raw: heapBase.load(fromByteOffset: base &+ i &<< 3, as: UInt64.self))
            markAndPush(v, &stack)
            i &+= 1
        }
    }

    @inline(__always)
    private func markAndPush(_ v: Oop, _ stack: inout RawArray<UInt64>) {
        if !v.isObject || isMarked(v) { return }
        assert(isUsedReference(v), "marking a reference to a free entry: \(v)")
        setMark(v.entryIndex, 1)
        stack.append(v.raw)
    }

    /// Every root word: the class table, the registry, then `extraRoots`.
    func forEachRoot(extraRoots: [Oop], _ body: (Oop) -> Void) {
        let ct = unsafe gc.pointee.classTable
        for i in 0..<ct.count { body(Oop(raw: ct[i])) }
        let rs = unsafe gc.pointee.roots
        for i in 0..<rs.count { body(Oop(raw: rs[i])) }
        forEachFinalized(body)
        for v in extraRoots { body(v) }
    }

    // MARK: - sweep

    /// Free every used, unmarked entry; clear the marks; free every block
    /// without a live body; rebuild the entry runs and the block pool.
    /// Contexts' private entry lists are discarded (their entries are still
    /// free in the table and land in the new runs). Module 10: a run is
    /// freed whole when its head has no live body, and its continuations
    /// (where no body starts) only with it.
    func sweep() {
        let h = heap
        var live = sweepEntries()
        defer { live.free() }
        var freed: UInt64 = 0
        let blind = isRunBlind(.sweep)
        var runs: UInt64 = 0
        for b in 0..<h.blockCount where h.isInUse(b) && !live[b] {
            freed &+= UInt64(freeBlockWithoutLiveBody(b, blind: blind, runs: &runs))
        }
        noteRunsFreed(runs)
        rebuildBlockPool()
        unsafe gc.pointee.counters.blocksFreed &+= freed
        if let h = unsafe gc.pointee.afterOldSpaceSweep { h() }
    }

    /// Free unmarked used entries, unmark the rest, rebuild the entry runs
    /// from every free entry. Answers, per block, whether a live body is in
    /// it. Contexts' private lists are discarded.
    func sweepEntries() -> RawArray<Bool> {
        let hw = highWater
        lockPools()
        let nc = unsafe pools.pointee.contexts.count
        for i in 0..<nc { unsafe pools.pointee.contexts[i].pointee.freeEntry = 0 }
        // Stashes too: their entries are free in the table and land in the
        // new runs.
        let ns = unsafe pools.pointee.stashes.count
        for i in 0..<ns {
            unsafe pools.pointee.stashes[i].pointee.next = 0
            unsafe pools.pointee.stashes[i].pointee.count = 0
        }
        unsafe pools.pointee.entryRuns.removeAll()
        // A lazy sweep's pending runs too (module 5): free in the table.
        unsafe pools.pointee.pendingRuns.removeAll()
        unlockPools()
        var live = RawArray<Bool>(repeating: false, count: heap.blockCount)
        var runs = RunBuilder(chunk: UInt64(config.entryChunk))
        var swept: UInt64 = 0
        // The old map is rebuilt on the way: the live old entries (young
        // ones are left to their nursery).
        let old = oldMap
        var bits: UInt64 = 0
        var e: UInt64 = 1
        while e < hw {
            let raw = e &<< 4
            let s = stateWord(raw)
            if EntryState.isFree(s) {
                runs.add(raw, self)
            } else if headerWord(raw) & Header.youngBit != 0 {
                // Young (kept in place by the reserve's fallback): its
                // nursery owns the entry and the body.
                setMark(e, 0)
            } else if markByte(e) != 0 {
                setMark(e, 0)
                live[BlockHeap.block(ofOffset: s)] = true
                if headerWord(raw) & Header.youngBit == 0 { bits |= 1 &<< (e & 63) }
            } else {
                setHeaderWord(raw, 0)
                runs.add(raw, self)
                swept &+= 1
            }
            if e & 63 == 63 {
                old.setWord(Int(truncatingIfNeeded: e &>> 6), bits)
                bits = 0
            }
            e &+= 1
        }
        if hw & 63 != 0 { old.setWord(Int(truncatingIfNeeded: hw &>> 6), bits) }
        lockPools()
        unsafe runs.finish(into: &pools.pointee.entryRuns)
        unlockPools()
        unsafe gc.pointee.counters.entriesSwept &+= swept
        return live
    }

    /// Every free block, and every in-use block with at least a minimum
    /// tail, lowest index on top. Contexts must be retired. Module 10: a
    /// run's blocks are never offered (a continuation's `used` is 0, a
    /// head's is past the block).
    func rebuildBlockPool() {
        let h = heap
        let blind = isRunBlind(.pool)
        lockPools()
        defer { unlockPools() }
        unsafe pools.pointee.freeBlocks.removeAll()
        var inUse = 0
        var b = h.blockCount - 1
        while b >= 0 {
            if h.isInUse(b) { inUse += 1 }
            if h.isInUse(b) && h.isRun(b) && !blind {
                b -= 1
                continue
            }
            if !h.isInUse(b) || UInt64(BlockHeap.blockBytes) &- h.usedBytes(b) >= ObjectMemory.minimumTail {
                unsafe pools.pointee.freeBlocks.append(UInt32(b))
            }
            b -= 1
        }
        unsafe pools.pointee.blocksInUse = inUse
    }

    /// The smallest free tail of an in-use block worth handing out.
    static let minimumTail: UInt64 = 4096

    // MARK: - module 6: evacuated blocks

    /// Module 6: take `blocks` (an in-use block selected for relocation)
    /// out of the pool, so no allocator puts a new body in it before the
    /// relocator has evacuated it. The next `rebuildBlockPool` puts any
    /// left in use back. World stopped.
    func withdrawFromPool(_ isSelected: (Int) -> Bool) {
        lockPools()
        defer { unlockPools() }
        var j = 0
        let n = unsafe pools.pointee.freeBlocks.count
        for i in 0..<n {
            let b = unsafe pools.pointee.freeBlocks[i]
            if isSelected(Int(b)) { continue }
            unsafe pools.pointee.freeBlocks[j] = b
            j += 1
        }
        unsafe pools.pointee.freeBlocks.truncate(j)
    }

    /// Module 6: block `b` was evacuated and no worker can hold a pointer
    /// into it any more: free it and hand it to the allocators at once (on
    /// top of the pool). Any thread inside the VM, or world stopped.
    func releaseEvacuatedBlock(_ b: Int) {
        lockPools()
        defer { unlockPools() }
        precondition(heap.isInUse(b), "an evacuated block is in use until it is freed")
        heap.setInUse(b, false)
        heap.setUsed(b, 0)
        unsafe pools.pointee.blocksInUse -= 1
        unsafe pools.pointee.freeBlocks.append(UInt32(b))
    }

    /// The stamp of block `b`'s last refill (module 5's cycle number).
    /// World stopped: no refill runs, so no lock is needed.
    func blockStampAtPause(_ b: Int) -> UInt32 { unsafe pools.pointee.blockStamps[b] }

    /// The pool's blocks, top last (the verifiers). World stopped.
    var poolBlocks: [Int] {
        lockPools()
        defer { unlockPools() }
        return unsafe (0..<pools.pointee.freeBlocks.count).map { unsafe Int(pools.pointee.freeBlocks[$0]) }
    }

    /// Per block, the end of its bodies: `used`, or, for the block an
    /// allocation context holds, the context's bump pointer (the
    /// verifiers, world stopped, contexts not retired).
    func bodyEnds() -> [UInt64] {
        let h = heap
        var ends = (0..<h.blockCount).map { h.usedBytes($0) }
        lockPools()
        defer { unlockPools() }
        for i in unsafe 0..<pools.pointee.contexts.count {
            let c = unsafe pools.pointee.contexts[i]
            let end = unsafe c.pointee.end
            if end == 0 { continue }
            let b = BlockHeap.block(ofOffset: end &- 1)
            ends[b] = unsafe Swift.max(ends[b], c.pointee.top &- BlockHeap.start(ofBlock: b))
        }
        return ends
    }
}

/// Threads free entries into runs of `chunk` for the pool.
struct RunBuilder {
    let chunk: UInt64
    var head: UInt64 = 0
    var length: UInt64 = 0
    var heads = RawArray<UInt64>()

    init(chunk: UInt64) { self.chunk = chunk }

    mutating func add(_ raw: UInt64, _ om: ObjectMemory) {
        om.setStateWord(raw, EntryState.free(next: head))
        head = raw
        length &+= 1
        if length == chunk {
            heads.append(head)
            head = 0
            length = 0
        }
    }

    mutating func finish(into runs: inout RawArray<UInt64>) {
        if length > 0 { heads.append(head) }
        for i in 0..<heads.count { runs.append(heads[i]) }
        heads.free()
    }
}
