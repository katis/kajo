import Testing
@testable import KajoVM

/// A list of `n` nodes (class 2: value, next) with a garbage array between
/// every two nodes, rooted at the returned handle.
private func listWithGarbage(_ w: World, _ n: Int, garbageSlots: Int = 5) -> RootHandle {
    let r = w.om.addRoot(w.nilObj)
    for i in 0..<n {
        _ = w.new(4, garbageSlots)
        let node = w.new(2, 2)
        w.om.store(node, 0, int(Int64(i)))
        w.om.store(node, 1, w.om.root(r))
        w.om.setRoot(r, node)
    }
    return r
}

private func sum(_ w: World, _ r: RootHandle) -> Int64 {
    var p = w.om.root(r), s: Int64 = 0
    while p != w.nilObj { s += w.om.load(p, 0).smallIntegerValue; p = w.om.load(p, 1) }
    return s
}

/// Every slot word of every object reachable from `r`, by oop.
private func slotWords(_ w: World, _ r: RootHandle) -> [Oop: [UInt64]] {
    var out: [Oop: [UInt64]] = [:]
    var p = w.om.root(r)
    while p != w.nilObj {
        out[p] = (0..<2).map { w.om.load(p, $0).raw }
        p = w.om.load(p, 1)
    }
    return out
}

/// Ported: the "moves bodies, rewrites no slots" half of
/// compactionMovesMethodsUnderLiveFrames (object-representation B).
@Test func compactionMovesBodiesAndRewritesNoSlots() throws {
    let om = try makeMemory(heapBlocks: 64)
    defer { om.destroy() }
    let w = World(om)
    for _ in 0..<5000 { _ = w.new(4, 10) } // garbage below the list
    let r = listWithGarbage(w, 1000)
    let before = slotWords(w, r)
    let offsets = before.keys.map { ($0, om.bodyOffset($0)) }
    om.retireAllContexts()
    let blocksBefore = (0..<om.heap.blockCount).filter { om.heap.isInUse($0) }.count
    om.compact()
    #expect(om.counters.compactions == 1)
    #expect(om.counters.objectsMoved >= 1000)
    #expect(om.counters.bytesMoved >= 1000 * 24)
    #expect(slotWords(w, r) == before)      // same oops, same slot words
    #expect(offsets.filter { om.bodyOffset($0.0) != $0.1 }.count == 1000) // every body moved
    #expect(sum(w, r) == 499_500)
    let blocksAfter = (0..<om.heap.blockCount).filter { om.heap.isInUse($0) }
    #expect(blocksAfter.count < blocksBefore && blocksAfter.count <= 2)
    #expect(blocksAfter == Array(0..<blocksAfter.count)) // packed at the bottom
    #expect(om.counters.verifierFailures == 0)
}

@Test func compactionLeavesTheLastBlocksTailToAllocateFrom() throws {
    let om = try makeMemory(heapBlocks: 8)
    defer { om.destroy() }
    let w = World(om)
    let r = listWithGarbage(w, 100)
    om.compact()
    let last = (0..<om.heap.blockCount).last { om.heap.isInUse($0) }!
    #expect(last == 0)
    let n = w.new(2, 2)
    #expect(om.blockIndex(of: n) == 0) // allocation continues in the tail
    #expect(sum(w, r) == 4950)
}

@Test(arguments: [Header.pinnedForGoodBit, Header.framePinBit])
func aPinnedObjectIsNotMovedByCompaction(_ pin: UInt64) throws {
    let om = try makeMemory(heapBlocks: 16)
    defer { om.destroy() }
    let w = World(om)
    for _ in 0..<2000 { _ = w.new(4, 10) } // garbage blocks below
    let r = listWithGarbage(w, 1000)
    let a = om.root(r)
    if pin == Header.pinnedForGoodBit { om.pinForGood(a) } else { om.pinForFrame(a) }
    let before = om.bodyOffset(a)
    om.compact()
    #expect(om.bodyOffset(a) == before)
    #expect(om.counters.pinsHonoured >= 1)
    #expect(om.counters.objectsMoved > 0)   // the rest of the heap still moved
    #expect(sum(w, r) == 499_500)
    if pin == Header.framePinBit {
        om.unpinFrame(a)
        om.compact()
        #expect(om.bodyOffset(a) != before)
        #expect(sum(w, r) == 499_500)
    }
}

/// Ported from concurrent-relocation's withoutThePinRuleTheFrameObjectIsMoved:
/// the test-only switch turns the rule off and the pinned body moves.
@Test func withoutThePinRuleThePinnedObjectMoves() throws {
    var c = ObjectMemoryConfig()
    c.heapBytes = 16 * BlockHeap.blockBytes
    c.entryCapacity = 1 << 16
    c.testSwitches.ignorePins = true
    let om = try ObjectMemory(c)
    defer { om.destroy() }
    let w = World(om)
    for _ in 0..<2000 { _ = w.new(4, 10) }
    let r = listWithGarbage(w, 200)
    let a = om.root(r)
    om.pinForFrame(a)
    let before = om.bodyOffset(a)
    om.compact()
    #expect(om.bodyOffset(a) != before)
}

@Test func theOneBlockHeapAllocatesAgainAfterCompaction() throws {
    let om = try makeMemory(stress: .oneBlockHeap)
    defer { om.destroy() }
    #expect(om.heap.blockCount == 1)
    let w = World(om)
    let r = listWithGarbage(w, 500, garbageSlots: 20)
    #expect(om.counters.compactions > 0)
    #expect(sum(w, r) == 124_750)
}

// MARK: - compaction verifier

enum CompactionCorruption: CaseIterable, Sendable {
    case entryNotUpdated, slotRewritten, unplannedMove, movedToTheWrongPlace

    var needle: String {
        switch self {
        case .entryNotUpdated, .movedToTheWrongPlace: "not where the plan put it"
        case .slotRewritten: "contents changed"
        case .unplannedMove: "moved without a plan"
        }
    }
}

@Test(arguments: CompactionCorruption.allCases)
func theCompactionVerifierCatches(_ c: CompactionCorruption) throws {
    let om = try makeMemory(heapBlocks: 16, onFailure: .record)
    defer { om.destroy() }
    let w = World(om)
    for _ in 0..<2000 { _ = w.new(4, 10) }
    let r = listWithGarbage(w, 1000)
    let pinned = om.root(r)
    om.pinForFrame(pinned)
    om.retireAllContexts()
    om.mark(extraRoots: [])
    let before = om.compactionSnapshot()
    let plan = om.planCompaction()
    #expect(plan.moves.count > 100)
    om.executeCompaction(plan)
    #expect(om.verifyCompaction(plan, before) == [])
    let m = plan.moves[plan.moves.count / 2]
    let moved = Oop(raw: m.entry)
    switch c {
    case .entryNotUpdated: om.setStateWord(moved.raw, m.from)
    case .slotRewritten: om.heap.setWord(atOffset: m.to + 8, int(-1).raw)
    case .unplannedMove:
        // A pinned body that moved anyway (copied 16 bytes higher in its own block).
        let off = om.bodyOffset(pinned)
        om.setStateWord(pinned.raw, off + 64)
    case .movedToTheWrongPlace: om.setStateWord(moved.raw, m.to + 8)
    }
    let issues = om.verifyCompaction(plan, before)
    #expect(issues.contains { $0.contains(c.needle) }, "\(issues)")
}
