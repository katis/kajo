import Testing
@testable import KajoVM

/// Ported from object-representation (B): a rooted list survives 200 000
/// garbage allocations in a small heap; entries come back through the pool.
@Test(arguments: [StressFlags(), .tinyEntryChunks])
func gcKeepsSurvivorsAndReclaimsGarbage(_ stress: StressFlags) throws {
    let om = try makeMemory(heapBlocks: 16, stress: stress)
    defer { om.destroy() }
    let w = World(om)
    let r = om.addRoot(w.nilObj)
    for i in 0..<1000 {
        let n = w.new(2, 2)
        om.store(n, 0, om.root(r))
        om.store(n, 1, int(Int64(i)))
        om.setRoot(r, n)
    }
    let garbage = stress.contains(.oneBlockHeap) ? 20_000 : 200_000
    for _ in 0..<garbage { _ = w.new(4, 20) }
    #expect(om.counters.collections > 3)
    var p = om.root(r)
    var i: Int64 = 999
    while p != w.nilObj {
        #expect(om.load(p, 1) == int(i))
        i -= 1
        p = om.load(p, 0)
    }
    #expect(i == -1)
    #expect(om.counters.entryRefills > 3) // entries came back through the pool
    #expect(om.highWater < 30_000)        // and were reused, not carved anew
    #expect(om.counters.verifierFailures == 0)
}

@Test func garbageEntriesAndBlocksAreReclaimed() throws {
    let om = try makeMemory(heapBlocks: 32)
    defer { om.destroy() }
    let w = World(om)
    let kept = w.new(2, 1)
    let r = om.addRoot(kept)
    for _ in 0..<500 { _ = w.new(2, 100) } // about 400 KB: several blocks
    let before = om.counters
    om.collect()
    let after = om.counters
    #expect(after.collections == before.collections + 1)
    #expect(after.entriesSwept - before.entriesSwept == 500)
    #expect(after.blocksFreed - before.blocksFreed >= 10)
    #expect(om.isUsedReference(om.root(r)) && om.classIndex(of: kept) == 2)
}

@Test func classTableRootsAndExtraRootsKeepObjectsAlive() throws {
    let om = try makeMemory()
    defer { om.destroy() }
    let w = World(om)
    let viaClass = w.new(2, 0)
    let cls = om.registerClass(viaClass)
    let viaRoot = w.new(2, 1), viaExtra = w.new(2, 0), viaSlot = w.new(2, 0)
    om.store(viaRoot, 0, viaSlot)
    let r = om.addRoot(viaRoot)
    let dropped = w.new(2, 0)
    let r2 = om.addRoot(dropped)
    om.removeRoot(r2)
    om.collect(extraRoots: [viaExtra])
    for o in [viaClass, viaRoot, viaExtra, viaSlot] { #expect(om.isUsedReference(o)) }
    #expect(!om.isUsedReference(dropped))
    #expect(om.classOop(cls) == viaClass && om.root(r) == viaRoot)
    om.collect()
    #expect(!om.isUsedReference(viaExtra))
}

@Test func cyclesAreReclaimed() throws {
    let om = try makeMemory()
    defer { om.destroy() }
    let w = World(om)
    let a = w.new(2, 1), b = w.new(2, 1)
    om.store(a, 0, b)
    om.store(b, 0, a)
    om.collect()
    #expect(!om.isUsedReference(a) && !om.isUsedReference(b))
}

@Test func marksLiveInTheSideMapAndAreClearAfterACollection() throws {
    let om = try makeMemory()
    defer { om.destroy() }
    let w = World(om)
    let a = w.new(2, 1)
    let r = om.addRoot(a)
    om.retireAllContexts()
    om.mark(extraRoots: [])
    #expect(om.isMarked(a) && om.isMarked(w.nilObj))
    #expect(om.header(a).reservedBits == 0) // never in the header
    om.sweep()
    #expect(!om.isMarked(a) && !om.isMarked(om.root(r)))
}

@Test func removedRootSlotsAreReused() throws {
    let om = try makeMemory()
    defer { om.destroy() }
    let w = World(om)
    let r1 = om.addRoot(w.nilObj)
    om.removeRoot(r1)
    let r2 = om.addRoot(int(3))
    #expect(r1 == r2 && om.root(r2) == int(3))
}
