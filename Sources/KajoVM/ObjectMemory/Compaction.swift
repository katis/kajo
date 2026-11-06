import Darwin

/// One body to move: the entry's oop and the old and new body offsets.
struct CompactionMove {
    let entry: UInt64
    let from: UInt64
    let to: UInt64
}

/// Where every live body goes. Sliding, block-respecting: live bodies
/// slide to the lowest free address in block order and never span a
/// block. A block holding a pinned live body is neither a source nor a
/// destination: everything in it stays; so are the blocks of a live run
/// (module 10: large objects never move).
struct CompactionPlan {
    var moves = RawArray<CompactionMove>()
    /// Per block: used bytes after the compaction, for every block that is
    /// not pinned (0: the block ends free).
    var newUsed: RawArray<UInt32>
    var pinnedBlocks: RawArray<Bool>
    var pinnedObjects: UInt64 = 0
    /// Module 10: live runs left where they are.
    var runsKept: UInt64 = 0
    var bytesMoved: UInt64 = 0

    init(blockCount: Int) {
        newUsed = RawArray(repeating: 0, count: blockCount)
        pinnedBlocks = RawArray(repeating: false, count: blockCount)
    }

    mutating func free() {
        moves.free()
        newUsed.free()
        pinnedBlocks.free()
    }
}

/// What the compaction verifier compares against: every live entry's body
/// offset and a fingerprint of its header and body.
struct CompactionSnapshot {
    var offsets: RawArray<UInt64>
    var prints: RawArray<UInt64>

    mutating func free() {
        offsets.free()
        prints.free()
    }
}

extension ObjectMemory {
    /// Mark, then slide live bodies down and rewrite only their entries
    /// (ADR 0003); no slot anywhere is rewritten. Pinned objects stay.
    /// World stopped.
    func compact(extraRoots: [Oop] = []) {
        let young = prepareOldSpaceOperation(extraRoots)
        compactOldSpace(extraRoots: young.isEmpty ? extraRoots : extraRoots + young)
    }

    /// The compaction without the hook (as `collectOldSpace`): young
    /// objects given as roots stay where they are.
    func compactOldSpace(extraRoots: [Oop]) {
        retireAllContexts()
        verifyAtPause("before compaction", phase: .idle)
        mark(extraRoots: extraRoots)
        verifyAtPause("after compaction mark", phase: .marked(extraRoots: extraRoots))
        var before = config.verify ? compactionSnapshot() : nil
        var plan = planCompaction()
        executeCompaction(plan)
        if var b = before {
            record("after compaction moves", verifyCompaction(plan, b))
            b.free()
            before = nil
        }
        var live = sweepEntries()
        live.free()
        rebuildBlockPool()
        if let h = unsafe gc.pointee.afterOldSpaceSweep { h() }
        unsafe gc.pointee.counters.compactions &+= 1
        unsafe gc.pointee.counters.collections &+= 1
        unsafe gc.pointee.counters.objectsMoved &+= UInt64(plan.moves.count)
        unsafe gc.pointee.counters.bytesMoved &+= plan.bytesMoved
        unsafe gc.pointee.counters.pinsHonoured &+= plan.pinnedObjects
        plan.free()
        verifyAtPause("after compaction", phase: .idle)
    }

    @inline(__always)
    private func isLiveBody(_ backRef: UInt64, at off: UInt64, highWater hw: UInt64) -> Bool {
        let idx = BackRef.entryIndex(backRef)
        return idx != 0 && idx < hw && markByte(idx) != 0
            && stateWord(idx &<< 4) == off
    }

    /// Decide every move. Marks set, contexts retired.
    func planCompaction() -> CompactionPlan {
        let h = heap
        let hw = highWater
        var plan = CompactionPlan(blockCount: h.blockCount)
        if !config.testSwitches.ignorePins {
            var e: UInt64 = 1
            while e < hw {
                if markByte(e) != 0, Header(raw: headerWord(e &<< 4)).isPinned, !Header(raw: headerWord(e &<< 4)).isYoung {
                    plan.pinnedBlocks[BlockHeap.block(ofOffset: stateWord(e &<< 4))] = true
                    plan.pinnedObjects &+= 1
                }
                e &+= 1
            }
        }
        // Module 10: a live run stays whole, never a source or a
        // destination (large objects are never moved); a dead run's blocks
        // are ordinary free space to the plan.
        if !isRunBlind(.compaction) {
            var b = 0
            while b < h.blockCount {
                if h.isInUse(b) && h.kind(b) == BlockKind.head {
                    let k = h.runLength(head: b)
                    let br = h.word(atOffset: BlockHeap.start(ofBlock: b))
                    if isLiveBody(br, at: BlockHeap.start(ofBlock: b), highWater: hw) {
                        for r in b..<Swift.min(b &+ k, h.blockCount) { plan.pinnedBlocks[r] = true }
                        plan.runsKept &+= 1
                    }
                    b &+= k
                    continue
                }
                b &+= 1
            }
        }
        let blockBytes = UInt64(BlockHeap.blockBytes)
        var db = -1                 // destination block, -1 before the first
        var dtop: UInt64 = 0        // offset within it
        func nextDestination() {
            db += 1
            while plan.pinnedBlocks[db] { db += 1 }
            dtop = 0
        }
        for b in 0..<h.blockCount where h.isInUse(b) && !plan.pinnedBlocks[b] {
            let start = BlockHeap.start(ofBlock: b)
            let end = start &+ h.usedBytes(b)
            var off = start
            while off < end {
                let w = h.word(atOffset: off)
                let size = BackRef.words(w) &<< 3
                if isLiveBody(w, at: off, highWater: hw) {
                    if db < 0 || dtop &+ size > blockBytes { nextDestination() }
                    let to = BlockHeap.start(ofBlock: db) &+ dtop
                    if to != off {
                        plan.moves.append(CompactionMove(entry: BackRef.entryIndex(w) &<< 4, from: off, to: to))
                        plan.bytesMoved &+= size
                    }
                    dtop &+= size
                    plan.newUsed[db] = UInt32(dtop)
                }
                off &+= size
            }
        }
        return plan
    }

    /// Move the bodies in plan order (every destination is at or below its
    /// source, so no move overwrites a body not yet moved), rewrite their
    /// entries, and set every unpinned block's used bytes.
    func executeCompaction(_ plan: CompactionPlan) {
        for i in 0..<plan.moves.count {
            let m = plan.moves[i]
            let words = BackRef.words(heap.word(atOffset: m.from))
            unsafe memmove(heapBase + Int(truncatingIfNeeded: m.to), heapBase + Int(truncatingIfNeeded: m.from),
                           Int(truncatingIfNeeded: words &<< 3))
            setStateWord(m.entry, m.to)
        }
        let h = heap
        let blind = isRunBlind(.compaction)
        for b in 0..<h.blockCount where !plan.pinnedBlocks[b] {
            let used = UInt64(plan.newUsed[b])
            h.setUsed(b, used)
            h.setInUse(b, used != 0)
            // Module 10: a dead run's blocks are ordinary again.
            if !blind { h.setKind(b, BlockKind.ordinary) }
        }
    }

    private func fingerprint(_ raw: UInt64) -> UInt64 {
        let hd = Header(raw: headerWord(raw))
        var f: UInt64 = 0xcbf2_9ce4_8422_2325 ^ hd.raw
        let off = stateWord(raw)
        for i in 0..<bodyWords(entry: raw) { f = (f ^ heap.word(atOffset: off &+ i &<< 3)) &* 0x100_0000_01b3 }
        return f
    }

    /// Body offset and fingerprint of every marked entry.
    func compactionSnapshot() -> CompactionSnapshot {
        let hw = highWater
        var s = CompactionSnapshot(offsets: RawArray(repeating: 0, count: Int(hw)),
                                   prints: RawArray(repeating: 0, count: Int(hw)))
        var e: UInt64 = 1
        while e < hw {
            if markByte(e) != 0 {
                s.offsets[Int(e)] = stateWord(e &<< 4)
                s.prints[Int(e)] = fingerprint(e &<< 4)
            }
            e &+= 1
        }
        return s
    }

    /// Every live body is where the plan put it (or where it was, if the
    /// plan did not move it) and its header and every word are unchanged:
    /// nothing was rewritten. Marks still set.
    func verifyCompaction(_ plan: CompactionPlan, _ before: CompactionSnapshot) -> [String] {
        var out = Issues()
        let hw = highWater
        var planned = RawArray<UInt64>(repeating: .max, count: Int(hw))
        defer { planned.free() }
        for i in 0..<plan.moves.count { planned[Int(plan.moves[i].entry &>> 4)] = plan.moves[i].to }
        var e: UInt64 = 1
        while e < hw {
            defer { e &+= 1 }
            if markByte(e) == 0 { continue }
            let now = stateWord(e &<< 4)
            let to = planned[Int(e)]
            if to != .max, now != to {
                out.fail("entry \(e) is at \(now), not where the plan put it (\(to))")
                continue
            }
            if to == .max, now != before.offsets[Int(e)] {
                out.fail("entry \(e) moved without a plan, \(before.offsets[Int(e)]) to \(now)")
                continue
            }
            if fingerprint(e &<< 4) != before.prints[Int(e)] { out.fail("entry \(e): contents changed during compaction") }
        }
        return out.list
    }

    // MARK: - pins (world stopped)

    /// Never moved again: objects the interpreter holds raw pointers into.
    func pinForGood(_ o: Oop) {
        var h = header(o)
        h.isPinnedForGood = true
        setHeader(o, h)
    }

    /// Not moved until `unpinFrame`: objects a running frame names
    /// (module 3 sets these at a pause and clears them at the next).
    func pinForFrame(_ o: Oop) {
        var h = header(o)
        h.isFramePinned = true
        setHeader(o, h)
    }

    func unpinFrame(_ o: Oop) {
        var h = header(o)
        h.isFramePinned = false
        setHeader(o, h)
    }

    func isPinned(_ o: Oop) -> Bool { header(o).isPinned }
}
