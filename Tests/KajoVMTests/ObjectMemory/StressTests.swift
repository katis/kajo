import Foundation
import Testing
@testable import KajoVM

/// The suite's allocation-heavy scenarios, each runnable under any stress
/// flag (docs/VERIFICATION.md, layer 3). Sizes shrink under
/// collect-at-every-allocation, where every allocation is a full,
/// verified collection.
private func scenarios(_ stress: StressFlags) throws {
    let scale = stress.contains(.collectAtEveryAllocation) ? 1 : 10
    let om = try makeMemory(heapBlocks: 16, chunk: 64, stress: stress)
    defer { om.destroy() }
    let w = World(om)

    // A rooted list among garbage (gcKeepsSurvivors).
    let r = om.addRoot(w.nilObj)
    for i in 0..<(30 * scale) {
        _ = w.new(4, 12)
        let n = w.new(2, 2)
        om.store(n, 0, om.root(r))
        om.store(n, 1, int(Int64(i)))
        om.setRoot(r, n)
    }
    func sum() -> Int64 {
        var p = om.root(r), s: Int64 = 0
        while p != w.nilObj { s += om.load(p, 1).smallIntegerValue; p = om.load(p, 0) }
        return s
    }
    let n = Int64(30 * scale)
    #expect(sum() == n * (n - 1) / 2)

    // Byte objects survive with their contents.
    let b = w.bytes(37)
    for i in 0..<37 { om.storeByte(b, i, UInt8(i)) }
    let rb = om.addRoot(b)
    for _ in 0..<(20 * scale) { _ = w.bytes(200) }
    #expect((0..<37).allSatisfy { om.loadByte(om.root(rb), $0) == UInt8($0) })

    // Compaction, become, reshape, then more allocation.
    om.compact()
    let a = om.root(r), c = om.load(a, 0)
    try om.becomeExchange(a, c)
    try om.becomeExchange(a, c)
    try om.reshape(classIndex: 2, namedSlots: 2, layout: [0, 1, nil], fill: w.nilObj)
    for _ in 0..<(20 * scale) { _ = w.new(4, 3) }
    #expect(sum() == n * (n - 1) / 2)
    #expect(om.count(of: om.root(r)) == 3)

    // Snapshot round trip.
    var c2 = om.config
    c2.heapBytes = 16 * BlockHeap.blockBytes
    let loaded = try ObjectMemory.load(snapshot: om.snapshot(), config: c2)
    defer { loaded.destroy() }
    loaded.collect()
    #expect(loaded.load(loaded.root(r), 1) == int(n - 1))

    om.collect()
    #expect(om.counters.verifierFailures == 0)
    if stress.contains(.collectAtEveryAllocation) {
        #expect(om.counters.stressCollections == om.counters.allocations - 1) // all but nil
    }
    if stress.contains(.tinyEntryChunks) { #expect(om.config.entryChunk == 2) }
    if stress.contains(.oneBlockHeap) {
        // Allocation compacts on its own unless every allocation collects first.
        #expect(om.heap.blockCount == 1 && om.counters.compactions > (stress.contains(.collectAtEveryAllocation) ? 0 : 1))
    }
}

@Test(arguments: [StressFlags(), .collectAtEveryAllocation, .oneBlockHeap, .tinyEntryChunks, .all])
func allocationHeavyScenariosUnderStress(_ stress: StressFlags) throws {
    try scenarios(stress)
}

@Test func stressFlagsParseFromTheEnvironmentForm() {
    #expect(StressFlags(parsing: "every,tiny") == [.collectAtEveryAllocation, .tinyEntryChunks])
    #expect(StressFlags(parsing: "all") == .all)
    #expect(StressFlags(parsing: "oneblock,bogus") == .oneBlockHeap)
    #expect(StressFlags(parsing: "") == [])
}

// MARK: - several threads (run under ThreadSanitizer too)

/// Allocation contexts on several threads at once, sharing the block pool,
/// the entry runs and the table's high water mark; then a collection from
/// the main thread keeps exactly what each thread rooted.
@Test func contextsAllocateFromSeveralThreadsAtOnce() throws {
    let threads = 8, perThread = 20_000
    let om = try makeMemory(heapBlocks: 512, entries: 1 << 20, chunk: 64)
    defer { om.destroy() }
    let w = World(om)
    om.retireAllContexts()
    let contexts = (0..<threads).map { _ in om.makeContext() }
    let fill = w.nilObj
    let heads = Heads(threads)
    DispatchQueue.concurrentPerform(iterations: threads) { t in
        let ctx = contexts[t]
        var head = fill
        for i in 0..<perThread {
            _ = om.tryAllocate(ctx, classIndex: 4, slots: 3, fill: fill) // garbage
            let n = om.tryAllocate(ctx, classIndex: 2, slots: 2, fill: fill)
            precondition(n.isObject, "heap sized for the test")
            om.store(n, 0, head)
            om.store(n, 1, int(Int64(i)))
            head = n
        }
        heads.set(t, head)
    }
    let roots = (0..<threads).map { heads.get($0) }
    om.collect(extraRoots: roots)
    for t in 0..<threads {
        var p = roots[t], count = 0
        while p != fill { count += 1; p = om.load(p, 0) }
        #expect(count == perThread)
    }
    #expect(om.counters.entriesSwept == UInt64(threads * perThread))
    #expect(om.counters.allocations >= UInt64(2 * threads * perThread))
    #expect(om.counters.verifierFailures == 0)
}

/// Threads race for the last blocks and entries; every object handed out
/// is distinct and the pools stay consistent.
@Test func contextsExhaustTheHeapTogether() throws {
    let threads = 6
    let om = try makeMemory(heapBlocks: 12, entries: 1 << 16, chunk: 16)
    defer { om.destroy() }
    let w = World(om)
    om.retireAllContexts()
    let contexts = (0..<threads).map { _ in om.makeContext() }
    let counts = Heads(threads)
    let fill = w.nilObj
    DispatchQueue.concurrentPerform(iterations: threads) { t in
        var n: UInt64 = 0
        while om.tryAllocate(contexts[t], classIndex: 2, slots: 6, fill: fill).isObject { n += 1 }
        counts.set(t, Oop(raw: n))
    }
    let total = (0..<threads).reduce(0) { $0 + counts.get($1).raw }
    #expect(total > 12 * 32 * 1024 / 56 - 6 * 600) // all but the tails of the last blocks
    om.retireAllContexts()
    #expect(om.verifyHeap() == [] && om.verifyFreeLists() == [])
    #expect(UInt64(om.allInstances(of: 2).count) == total)
}

/// Per-thread results, written once by each thread and read after the join.
final class Heads: @unchecked Sendable {
    private var values: [Oop]
    private let lock = NSLock()
    init(_ n: Int) { values = Array(repeating: .none, count: n) }
    func set(_ i: Int, _ v: Oop) { lock.lock(); values[i] = v; lock.unlock() }
    func get(_ i: Int) -> Oop { lock.lock(); defer { lock.unlock() }; return values[i] }
}
