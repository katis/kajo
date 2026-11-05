import Foundation
import Testing
@testable import KajoVM

// Module 10: large objects in the object memory (docs/modules/large-
// objects.md). Every reader of a body that knows runs has a test here and a
// broken variant (`TestSwitches.runBlind`) that makes the test fail.

/// A memory with `blocks` blocks, recording verifier failures, with one
/// reader's run rule switched off when `blind` is given.
private func largeMemory(blocks: Int = 256, blind: RunReader? = nil, reserveBlocks: Int = 0) throws -> ObjectMemory {
    var c = ObjectMemoryConfig()
    c.heapBytes = blocks * BlockHeap.blockBytes
    c.reserveBytes = reserveBlocks * BlockHeap.blockBytes
    c.entryCapacity = 1 << 16
    c.entryChunk = 256
    c.verify = true
    c.onVerifyFailure = .record
    c.testSwitches.runBlind = blind
    return try ObjectMemory(c)
}

private func large(_ w: World, _ slots: Int, cls: UInt64 = 2) -> Oop {
    guard let o = w.om.allocate(w.ctx, classIndex: cls, slots: slots, fill: w.nilObj) else { fatalError("heap full") }
    return o
}

private func runBlocks(_ om: ObjectMemory) -> [Int] {
    (0..<om.heap.blockCount).filter { om.heap.isInUse($0) && om.heap.isRun($0) }
}

@Test func aLargeObjectIsARunOfBlocksOldAtBirth() throws {
    let om = try largeMemory()
    defer { om.destroy() }
    let w = World(om)
    let a = large(w, 10_000)
    let h = om.heap
    let head = om.blockIndex(of: a)
    #expect(om.count(of: a) == 10_000)
    #expect(om.header(a).isLarge && !om.header(a).isYoung)
    #expect(om.bodyOffset(a) == BlockHeap.start(ofBlock: head))
    #expect(h.kind(head) == BlockKind.head)
    #expect(h.usedBytes(head) == 80_008)
    #expect(h.runLength(head: head) == 3)
    #expect(h.kind(head + 1) == BlockKind.continuation && h.kind(head + 2) == BlockKind.continuation)
    #expect(h.usedBytes(head + 1) == 0)
    #expect(om.oldMap.contains(a.entryIndex))
    // Every slot reads the fill; the last one, two blocks on, stores.
    #expect(om.load(a, 9_999) == w.nilObj)
    om.store(a, 9_999, int(42))
    om.store(a, 4_096, int(7))
    #expect(om.load(a, 9_999) == int(42) && om.load(a, 4_096) == int(7))
    // Bytes too: zero-filled even in blocks that held something before.
    let b = w.bytes(100_000)
    #expect(om.count(of: b) == 100_000 && om.loadByte(b, 99_999) == 0)
    om.storeByte(b, 99_999, 9)
    #expect(om.loadByte(b, 99_999) == 9)
    om.retireAllContexts()
    #expect(om.verifyHeap().isEmpty)
    #expect(om.verifyFreeLists().isEmpty)
    #expect(om.largeObjectCounters.allocations == 2)
    // Never in the pool.
    #expect(om.poolBlocks.allSatisfy { !h.isRun($0) })
}

@Test func aLargeObjectAtTheCountFieldsLimit() throws {
    // 16 MiB - 1 bytes: the largest byte object.
    let om = try largeMemory(blocks: 1024)
    defer { om.destroy() }
    let w = World(om)
    let b = w.bytes(Header.maxLargeCount)
    #expect(om.count(of: b) == UInt64(Header.maxLargeCount))
    om.storeByte(b, Header.maxLargeCount - 1, 255)
    #expect(om.loadByte(b, Header.maxLargeCount - 1) == 255)
    #expect(om.heap.runLength(head: om.blockIndex(of: b)) == 513)
    om.retireAllContexts()
    #expect(om.verifyHeap().isEmpty)
}

@Test func aRunThatDoesNotFitTheSoftLimitIsRefusedNotTrapped() throws {
    let om = try largeMemory(blocks: 8)
    defer { om.destroy() }
    let w = World(om)
    // 9 blocks' worth in a heap of 8: the policy collects, compacts, fails.
    #expect(om.allocate(w.ctx, classIndex: 2, slots: 9 * 4096, fill: w.nilObj) == nil)
    #expect(om.largeObjectCounters.failures >= 1)
    #expect(om.verifierReports.isEmpty)
}

// MARK: - the sweep

/// A live run, a dead run, small objects between them; one collection.
private func sweepScenario(_ blind: RunReader?) throws -> (reports: [String], liveSurvived: Bool, deadRunFreed: Bool) {
    let om = try largeMemory(blind: blind)
    defer { om.destroy() }
    let w = World(om)
    let live = large(w, 20_000)
    _ = om.addRoot(live)
    om.store(live, 19_999, int(5))
    let dead = large(w, 20_000)
    let deadHead = om.blockIndex(of: dead)
    _ = w.new(2, 4)
    om.collect()
    let survived = om.load(live, 19_999) == int(5) && om.heap.kind(om.blockIndex(of: live)) == BlockKind.head
    return (om.verifierReports, survived, !om.heap.isInUse(deadHead))
}

@Test func theSweepFreesADeadRunWholeAndKeepsALiveOne() throws {
    let r = try sweepScenario(nil)
    #expect(r.reports.isEmpty)
    #expect(r.liveSurvived && r.deadRunFreed)
}

@Test func withoutTheRunRuleTheSweepFreesALiveRunsContinuations() throws {
    let r = try sweepScenario(.sweep)
    #expect(r.reports.contains { $0.contains("run at block") || $0.contains("free block") })
}

// MARK: - compaction and fragmentation

/// Alternating large and small live objects, the small ones dropped, then a
/// compaction: the runs stay where they were, their contents unchanged.
private func compactionScenario(_ blind: RunReader?) throws -> (reports: [String], runsStayed: Bool, contentsKept: Bool) {
    let om = try largeMemory(blind: blind)
    defer { om.destroy() }
    let w = World(om)
    var larges: [Oop] = []
    var smalls: [RootHandle] = []
    for i in 0..<8 {
        let a = large(w, 5_000)
        om.store(a, 4_999, int(Int64(i)))
        _ = om.addRoot(a)
        larges.append(a)
        for _ in 0..<200 { smalls.append(om.addRoot(w.new(2, 20))) }
    }
    let offsets = larges.map { om.bodyOffset($0) }
    for h in smalls { om.removeRoot(h) }
    om.compact()
    let stayed = larges.map { om.bodyOffset($0) } == offsets
    let kept = larges.enumerated().allSatisfy { om.load($0.element, 4_999) == int(Int64($0.offset)) }
    return (om.verifierReports, stayed, kept)
}

@Test func compactionLeavesRunsWhereTheyAre() throws {
    let r = try compactionScenario(nil)
    #expect(r.reports.isEmpty)
    #expect(r.runsStayed && r.contentsKept)
}

@Test func withoutTheRunRuleCompactionMovesALargeBody() throws {
    let r = try compactionScenario(.compaction)
    #expect(!r.reports.isEmpty || !r.runsStayed)
}

@Test func compactionConsolidatesOrdinaryBlocksSoARunFits() throws {
    // Each block holds a live small object, so no free blocks are adjacent;
    // a run of 3 fits only after compaction packs the small ones.
    let om = try largeMemory(blocks: 40)
    defer { om.destroy() }
    let w = World(om)
    var keep: [Oop] = []
    // Fill every block with 4 KiB objects, keeping one per block.
    var i = 0
    while true {
        let o = om.tryAllocate(w.ctx, classIndex: 2, slots: 500, fill: w.nilObj)
        if o == .none { break }
        if i % 8 == 0 { keep.append(o); _ = om.addRoot(o) }
        i += 1
    }
    om.collect()
    om.retireAllContexts()
    let before = om.counters.compactions
    let a = om.allocate(w.ctx, classIndex: 2, slots: 3 * 4096, fill: w.nilObj)
    #expect(a != nil)
    #expect(om.counters.compactions > before)
    #expect(om.verifierReports.isEmpty)
}

// MARK: - the verifier

enum RunCorruption: CaseIterable, Sendable {
    case entryIntoContinuation, continuationOfNoRun, freeBlockWithKind, headUsedTooSmall, continuationNotInUse, largeInOrdinaryBlock

    var needle: String {
        switch self {
        case .entryIntoContinuation: "continuation of a run"
        case .continuationOfNoRun: "continuation of no run"
        case .freeBlockWithKind: "has kind"
        case .headUsedTooSmall: "invalid used count"
        case .continuationNotInUse: "not a continuation in use"
        case .largeInOrdinaryBlock: "in a block of kind"
        }
    }
}

@Test(arguments: RunCorruption.allCases)
func theHeapVerifierCatchesABrokenRun(_ c: RunCorruption) throws {
    let om = try largeMemory()
    defer { om.destroy() }
    let w = World(om)
    let a = large(w, 10_000)
    _ = om.addRoot(a)
    let small = w.new(2, 2)
    _ = om.addRoot(small)
    om.retireAllContexts()
    #expect(om.verifyHeap().isEmpty)
    let h = om.heap
    let head = om.blockIndex(of: a)
    let free = (0..<h.blockCount).last { !h.isInUse($0) }!
    switch c {
    case .entryIntoContinuation: om.setStateWord(small.raw, BlockHeap.start(ofBlock: head + 1))
    case .continuationOfNoRun: h.setKind(head, BlockKind.continuation)
    case .freeBlockWithKind: h.setKind(free, BlockKind.head)
    case .headUsedTooSmall: h.setUsed(head, 4096)
    case .continuationNotInUse: h.setInUse(head + 2, false)
    case .largeInOrdinaryBlock:
        h.setKind(head, BlockKind.ordinary); h.setKind(head + 1, BlockKind.ordinary); h.setKind(head + 2, BlockKind.ordinary)
        h.setUsed(head, UInt64(BlockHeap.blockBytes))
    }
    let issues = om.verifyHeap()
    #expect(issues.contains { $0.contains(c.needle) }, "\(c): \(issues.prefix(3))")
}

@Test func withoutTheRunRuleTheVerifierRefusesAWholeHeap() throws {
    let om = try largeMemory(blind: .verifier)
    defer { om.destroy() }
    let w = World(om)
    _ = om.addRoot(large(w, 10_000))
    om.retireAllContexts()
    #expect(om.verifyHeap().contains { $0.contains("invalid used count") })
}

// MARK: - the pool

@Test func runBlocksNeverReachThePool() throws {
    let om = try largeMemory()
    defer { om.destroy() }
    let w = World(om)
    _ = om.addRoot(large(w, 10_000))
    om.collect()
    #expect(om.poolBlocks.allSatisfy { !om.heap.isRun($0) })
    #expect(om.verifyFreeLists().isEmpty)
}

@Test func withoutTheRunRuleThePoolOffersAContinuation() throws {
    let om = try largeMemory(blind: .pool)
    defer { om.destroy() }
    let w = World(om)
    _ = om.addRoot(large(w, 10_000))
    om.collect()
    #expect(om.verifierReports.contains { $0.contains("of a run is in the pool") })
}

// MARK: - become and reshape go through the entry

@Test func becomeAndReshapeOfLargeObjects() throws {
    let om = try largeMemory()
    defer { om.destroy() }
    let w = World(om)
    let a = large(w, 10_000)
    let b = w.new(2, 3)
    _ = om.addRoot(a)
    _ = om.addRoot(b)
    om.store(a, 9_999, int(1))
    om.store(b, 2, int(2))
    let headA = om.blockIndex(of: a)
    try om.becomeExchange(a, b)
    #expect(om.count(of: b) == 10_000 && om.load(b, 9_999) == int(1))
    #expect(om.count(of: a) == 3 && om.load(a, 2) == int(2))
    #expect(om.blockIndex(of: b) == headA) // no copy: the run stayed
    // Reshape class 2 by one more named slot: b (large) gets a new run, a a
    // new small body; the old run is freed by the next collection.
    let n = try om.reshape(classIndex: 2, namedSlots: 0, layout: [nil], fill: int(0))
    #expect(n == 2)
    #expect(om.count(of: b) == 10_001 && om.load(b, 10_000) == int(1) && om.load(b, 0) == int(0))
    om.collect()
    #expect(!om.heap.isInUse(headA) || om.blockIndex(of: b) == headA)
    // Forward the large one to a small one: its run dies.
    let c = w.new(2, 1)
    _ = om.addRoot(c)
    let headB = om.blockIndex(of: b)
    try om.becomeForward([b], to: [c])
    om.collect()
    #expect(!om.heap.isInUse(headB) || om.heap.kind(headB) != BlockKind.head || om.blockIndex(of: c) == headB)
    #expect(om.verifierReports.isEmpty)
}

// MARK: - the snapshot

@Test func aSnapshotCarriesRunsAndLoadsThemBack() throws {
    let om = try largeMemory()
    defer { om.destroy() }
    let w = World(om)
    let a = large(w, 20_000)
    for i in stride(from: 0, to: 20_000, by: 997) { om.store(a, i, int(Int64(i))) }
    let r = om.addRoot(a)
    let bytes = w.bytes(70_000)
    om.storeByte(bytes, 69_999, 77)
    om.store(a, 1, bytes)
    let snap = om.snapshot()
    let L = try SnapshotLayout(parsing: snap)
    #expect(L.kinds.contains(BlockKind.head) && L.kinds.contains(BlockKind.continuation))
    var c = ObjectMemoryConfig()
    c.heapBytes = 256 * BlockHeap.blockBytes
    c.entryCapacity = 1 << 16
    c.onVerifyFailure = .record
    let loaded = try ObjectMemory.load(snapshot: snap, config: c)
    defer { loaded.destroy() }
    let a2 = loaded.root(r)
    #expect(loaded.count(of: a2) == 20_000)
    for i in stride(from: 0, to: 20_000, by: 997) where i != 1 { #expect(loaded.load(a2, i) == int(Int64(i))) }
    #expect(loaded.loadByte(loaded.load(a2, 1), 69_999) == 77)
    #expect(loaded.heap.kind(loaded.blockIndex(of: a2)) == BlockKind.head)
    #expect(loaded.verifyHeap().isEmpty && loaded.verifyFreeLists().isEmpty)
    #expect(loaded.poolBlocks.allSatisfy { !loaded.heap.isRun($0) })
}

enum SnapshotRunCorruption: CaseIterable, Sendable {
    case continuationOfNoRun, headUsedTooSmall, runCutShort, unknownKind, entryIntoContinuation, continuationWithBytes

    var needle: String {
        switch self {
        case .continuationOfNoRun, .continuationWithBytes: "continuation of no run"
        case .headUsedTooSmall: "run at block"
        case .runCutShort: "not a continuation"
        case .unknownKind: "kind"
        case .entryIntoContinuation: "continuation of a run"
        }
    }
}

@Test(arguments: SnapshotRunCorruption.allCases)
func theLoaderRejectsABrokenRun(_ c: SnapshotRunCorruption) throws {
    let om = try largeMemory()
    defer { om.destroy() }
    let w = World(om)
    let a = large(w, 10_000)
    _ = om.addRoot(a)
    let small = w.new(2, 2)
    _ = om.addRoot(small)
    let good = om.snapshot()
    let L = try SnapshotLayout(parsing: good)
    let head = L.kinds.firstIndex(of: BlockKind.head)!
    var b = good
    func put(_ at: Int, _ v: UInt64) { for k in 0..<8 { b[at + k] = UInt8(truncatingIfNeeded: v >> (8 * UInt64(k))) } }
    let usedWord = { (i: Int) in L.usedAt + i * 8 }
    switch c {
    case .continuationOfNoRun: put(usedWord(head), UInt64(BlockKind.continuation) << 56)
    case .headUsedTooSmall: put(usedWord(head), 4096 | UInt64(BlockKind.head) << 56)
    case .runCutShort: put(usedWord(head + 2), 0)
    case .unknownKind: put(usedWord(head + 1), 7 << 56)
    case .entryIntoContinuation: put(L.tableAt + Int(small.entryIndex) * 16, BlockHeap.start(ofBlock: head + 1))
    case .continuationWithBytes: put(usedWord(head + 1), 8 | UInt64(BlockKind.continuation) << 56)
    }
    #expect { try ObjectMemory.load(snapshot: b, config: { var c = ObjectMemoryConfig(); c.heapBytes = 256 * BlockHeap.blockBytes; c.entryCapacity = 1 << 16; return c }()) } throws: { e in
        let text = "\(e)"
        if !text.contains(c.needle) { Issue.record("\(c): \(text.prefix(300))") }
        return true
    }
}

@Test func withoutTheRunRuleTheSnapshotDoesNotLoad() throws {
    let om = try largeMemory(blind: .snapshot)
    defer { om.destroy() }
    let w = World(om)
    _ = om.addRoot(large(w, 10_000))
    let snap = om.snapshot()
    #expect(throws: SnapshotError.self) { try ObjectMemory.load(snapshot: snap, config: { var c = ObjectMemoryConfig(); c.heapBytes = 256 * BlockHeap.blockBytes; c.entryCapacity = 1 << 16; return c }()) }
}

// MARK: - the final collection's growth

@Test func theReservationKeepsGrowthPastTheReserve() throws {
    let om = try largeMemory(blocks: 16, reserveBlocks: 8)
    defer { om.destroy() }
    #expect(om.heap.blockCount == 32)
    #expect(om.hardLimitBlocks == 24)
    // A promotion refill stops at the hard limit until the end grows.
    let ctx = om.makeContext()
    var taken = 0
    while om.refillBlock(ctx, bytes: 32_000, reserve: true) { taken += 1 }
    #expect(taken == 24 && om.blocksInUse == 24)
    om.setEndGrowth(true)
    #expect(om.refillBlock(ctx, bytes: 32_000, reserve: true))
    #expect(om.blocksInUse == 25)
}

// MARK: - measurements (KAJO_MEASURE_LARGE=1, in a release build)

private func ms(_ ns: UInt64) -> String { String(format: "%.3f", Double(ns) / 1e6) }

private func summary(_ xs: [UInt64]) -> String {
    let s = xs.sorted()
    return "p50 \(ms(s[s.count / 2])) ms, max \(ms(s.last!)) ms (n \(s.count))"
}

/// Allocation and free of 1 MiB and 16 MiB objects, and the fragmentation
/// case: printed, asserted only on the work (AGENTS.md).
@Test func largeObjectMeasurements() throws {
    guard ProcessInfo.processInfo.environment["KAJO_MEASURE_LARGE"] != nil else { return }
    let om = try largeMemory(blocks: 8192) // 256 MiB
    defer { om.destroy() }
    let w = World(om)
    for (label, count, bytes) in [("1 MiB Array (131 071 slots)", 131_071, false), ("16 MiB ByteArray", Header.maxLargeCount, true),
                                  ("1 MiB ByteArray", 1 << 20, true), ("16 MiB Array (2 097 151 slots)", 2_097_151, false)] {
        var alloc: [UInt64] = [], free: [UInt64] = [], baseline: [UInt64] = []
        for _ in 0..<20 {
            om.collect()
            var t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            om.collect()
            baseline.append(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t)
            t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let o = om.tryAllocateAny(w.ctx, classIndex: bytes ? 3 : 2, count: count, isBytes: bytes, fill: w.nilObj)
            alloc.append(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t)
            #expect(o != .none)
            t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            om.collect()  // the object is garbage: its run is freed
            free.append(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t)
        }
        print("large \(label): allocate \(summary(alloc)); collection freeing it \(summary(free)); collection without it \(summary(baseline))")
    }
    #expect(om.verifierReports.isEmpty)
}

@Test func largeObjectFragmentation() throws {
    guard ProcessInfo.processInfo.environment["KAJO_MEASURE_LARGE"] != nil else { return }
    let om = try largeMemory(blocks: 2048) // 64 MiB
    defer { om.destroy() }
    let w = World(om)
    // Alternating: a run of two blocks (5000 slots), then one block of
    // small objects (40 of 100 slots); until the heap is full.
    var smalls: [RootHandle] = []
    var larges = 0, largeBytes: UInt64 = 0
    outer: while true {
        let a = om.tryAllocateAny(w.ctx, classIndex: 2, count: 5_000, isBytes: false, fill: w.nilObj)
        if a == .none { break }
        _ = om.addRoot(a)
        larges += 1
        largeBytes += om.header(a).bodyBytes
        om.retire(w.ctx)  // the next small ones start a block of their own
        for _ in 0..<40 {
            let s = om.tryAllocate(w.ctx, classIndex: 2, slots: 100, fill: w.nilObj)
            if s == .none { break outer }
            smalls.append(om.addRoot(s))
        }
        om.retire(w.ctx)
    }
    func report(_ label: String) {
        om.retireAllContexts()
        let h = om.heap
        var longest = 0, cur = 0, free = 0
        for b in 0..<om.hardLimitBlocks { if h.isInUse(b) { cur = 0 } else { cur += 1; free += 1; longest = max(longest, cur) } }
        var live: UInt64 = 0
        var e: UInt64 = 1
        while e < om.highWater {
            if !EntryState.isFree(om.stateWord(e << 4)) { live += Header(raw: om.headerWord(e << 4)).bodyBytes }
            e += 1
        }
        print("fragmentation \(label): blocks in use \(om.blocksInUse) (\(om.blocksInUse * 32) KiB), live \(live / 1024) KiB, "
              + "footprint/live \(String(format: "%.2f", Double(om.blocksInUse * BlockHeap.blockBytes) / Double(live))), "
              + "free blocks \(free), longest free stretch \(longest) blocks")
    }
    report("full: \(larges) runs of 2 blocks (\(largeBytes / 1024) KiB), \(smalls.count) small objects")
    // Keep one small object in every fourth block of them, drop the rest.
    for (i, r) in smalls.enumerated() where i % 160 != 0 { om.removeRoot(r) }
    om.collect()
    report("after dropping all but one small object in four blocks, collected")
    om.compact()
    report("then compacted")
    for (i, r) in smalls.enumerated() where i % 160 == 0 { om.removeRoot(r) }
    om.collect()
    report("every small object dropped, collected")
    // A run of three blocks needs a stretch the runs of two left free.
    let big = om.allocate(w.ctx, classIndex: 2, slots: 3 * 4096, fill: w.nilObj)
    print("fragmentation: a run of 3 blocks \(big == nil ? "does not fit" : "fits")")
    #expect(om.verifierReports.isEmpty)
}
