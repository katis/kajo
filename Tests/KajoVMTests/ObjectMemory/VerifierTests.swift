import Testing
@testable import KajoVM

/// A heap with a rooted holder -> (a -> b, bytes), garbage collected so
/// free entries sit in several runs, and free blocks in the pool.
private struct Scene {
    let om: ObjectMemory
    let w: World
    let holder: Oop, a: Oop, b: Oop, bytes: Oop, garbage: Oop
    let rootHandle: RootHandle

    init() throws {
        om = try makeMemory(heapBlocks: 8, chunk: 4, onFailure: .record)
        w = World(om)
        holder = w.new(2, 3)
        a = w.new(2, 2)
        b = w.new(2, 1)
        bytes = w.bytes(12)
        om.store(holder, 0, a)
        om.store(holder, 1, int(5))
        om.store(holder, 2, bytes)
        om.store(a, 0, int(1))
        om.store(a, 1, b)
        rootHandle = om.addRoot(holder)
        var g = Oop.none
        for _ in 0..<20 { g = w.new(4, 3) }
        garbage = g
        om.collect()
        om.retireAllContexts()
    }

    var freeBlock: Int { (0..<om.heap.blockCount).last { !om.heap.isInUse($0) }! }

    func setSlotRaw(_ o: Oop, _ i: Int, _ raw: UInt64) {
        om.heap.setWord(atOffset: om.bodyOffset(o) + 8 + UInt64(i) * 8, raw)
    }

    func check(_ issues: [String], _ needle: String) {
        #expect(!issues.isEmpty)
        #expect(issues.contains { $0.contains(needle) }, "\(issues)")
    }
}

@Test func aCleanHeapPassesEveryVerifier() throws {
    let s = try Scene()
    defer { s.om.destroy() }
    #expect(s.om.verifyHeap() == [])
    #expect(s.om.verifyFreeLists() == [])
    s.om.mark(extraRoots: [])
    #expect(s.om.verifyMarks(extraRoots: []) == [])
    s.om.sweep()
    #expect(s.om.counters.verifierFailures == 0)
}

enum HeapCorruption: CaseIterable, Sendable {
    case referenceBeyondHighWater, referenceToFreeEntry, reservedTagInSlot, noneInSlot
    case misalignedOffset, offsetInFreeBlock, offsetBeyondUsed, offsetPastHeap
    case backReferenceNamesAnotherEntry, sizeDisagreesWithHeader, relocatingState
    case reservedHeaderBit, unregisteredClass, freeEntryWithHeader, twoEntriesOneBody, offsetIntoAnotherBody
    case markLeftSet, usedEndsMidBody, usedNotAligned, freeBlockWithUsedBytes, badRoot, badClassTableEntry
    case youngOutsideNursery, youngOnlyBitsInOld

    var needle: String {
        switch self {
        case .referenceBeyondHighWater, .referenceToFreeEntry, .reservedTagInSlot, .noneInSlot: "slot"
        case .misalignedOffset: "aligned"
        case .offsetInFreeBlock: "not in use"
        case .offsetBeyondUsed, .offsetPastHeap: "outside"
        case .backReferenceNamesAnotherEntry: "back reference"
        case .sizeDisagreesWithHeader: "size"
        case .relocatingState: "RELOCATING"
        case .reservedHeaderBit: "reserved"
        case .unregisteredClass: "class"
        case .freeEntryWithHeader: "free entry"
        case .twoEntriesOneBody: "back reference"
        case .offsetIntoAnotherBody: "start of a body"
        case .markLeftSet: "mark"
        case .usedEndsMidBody: "walk"
        case .usedNotAligned: "invalid used count"
        case .freeBlockWithUsedBytes: "free block"
        case .badRoot: "root"
        case .badClassTableEntry: "class table"
        case .youngOutsideNursery: "nursery region"
        case .youngOnlyBitsInOld: "young-only"
        }
    }
}

@Test(arguments: HeapCorruption.allCases)
func theHeapVerifierCatches(_ c: HeapCorruption) throws {
    let s = try Scene()
    defer { s.om.destroy() }
    let om = s.om
    let hw = om.highWater
    switch c {
    case .referenceBeyondHighWater: s.setSlotRaw(s.holder, 1, Oop(entryIndex: hw + 10).raw)
    case .referenceToFreeEntry: s.setSlotRaw(s.holder, 1, s.garbage.raw)
    case .reservedTagInSlot: s.setSlotRaw(s.holder, 1, 0x108)
    case .noneInSlot: s.setSlotRaw(s.holder, 1, 0)
    case .misalignedOffset: om.setStateWord(s.a.raw, om.bodyOffset(s.a) + 4)
    case .offsetInFreeBlock: om.setStateWord(s.a.raw, BlockHeap.start(ofBlock: s.freeBlock))
    case .offsetBeyondUsed:
        let b = om.blockIndex(of: s.a)
        om.setStateWord(s.a.raw, BlockHeap.start(ofBlock: b) + om.heap.usedBytes(b))
    case .offsetPastHeap: om.setStateWord(s.a.raw, UInt64(om.heap.bytes) + 8)
    case .backReferenceNamesAnotherEntry:
        om.heap.setWord(atOffset: om.bodyOffset(s.a), BackRef.make(entryIndex: s.b.entryIndex, words: 3))
    case .sizeDisagreesWithHeader:
        om.setHeader(s.a, Header(classIndex: 2, count: 1, isBytes: false))
    case .relocatingState: om.setStateWord(s.a.raw, om.bodyOffset(s.a) | EntryState.relocatingBit)
    case .reservedHeaderBit: om.setHeaderWord(s.a.raw, om.header(s.a).raw | 1 << 51)
    case .unregisteredClass: om.setHeader(s.b, Header(classIndex: 999, count: 1, isBytes: false))
    case .freeEntryWithHeader: om.setHeaderWord(s.garbage.raw, Header(classIndex: 2, count: 0, isBytes: false).raw)
    case .twoEntriesOneBody:
        om.setStateWord(s.b.raw, om.bodyOffset(s.a))
        om.setHeader(s.b, om.header(s.a))
    case .offsetIntoAnotherBody:
        // A fake body inside a byte object: right back reference, right size.
        om.heap.setWord(atOffset: om.bodyOffset(s.bytes) + 8, BackRef.make(entryIndex: s.b.entryIndex, words: 2))
        om.setStateWord(s.b.raw, om.bodyOffset(s.bytes) + 8)
    case .markLeftSet: om.setMark(s.a.entryIndex, 1)
    case .usedEndsMidBody:
        let b = om.blockIndex(of: s.holder)
        om.heap.setUsed(b, om.heap.usedBytes(b) - 8)
    case .usedNotAligned:
        let b = om.blockIndex(of: s.holder)
        om.heap.setUsed(b, om.heap.usedBytes(b) + 4)
    case .freeBlockWithUsedBytes: om.heap.setUsed(s.freeBlock, 64)
    case .badRoot: om.setRoot(s.rootHandle, Oop(entryIndex: hw + 3))
    case .badClassTableEntry: om.setClassOop(3, s.garbage)
    case .youngOutsideNursery: om.setHeader(s.a, om.header(s.a).youngIn(nursery: 0))
    case .youngOnlyBitsInOld: om.setHeaderWord(s.a.raw, om.header(s.a).raw | 2 << Header.ageShift)
    }
    s.check(om.verifyHeap(), c.needle)
}

enum FreeListCorruption: CaseIterable, Sendable {
    case usedEntryInARun, entryInTwoLists, cycle, leakedFreeEntry, usedEntryInAContextList
    case blockInPoolTwice, fullBlockInPool, leakedFreeBlock, referenceOutsideTable, blockBeyondTheHeap

    var needle: String {
        switch self {
        case .usedEntryInARun, .usedEntryInAContextList: "used entry"
        case .entryInTwoLists, .cycle: "twice"
        case .leakedFreeEntry: "in no free list"
        case .blockInPoolTwice: "twice in the pool"
        case .fullBlockInPool: "no tail"
        case .leakedFreeBlock: "not in the pool"
        case .referenceOutsideTable: "outside"
        case .blockBeyondTheHeap: "beyond the heap"
        }
    }
}

@Test(arguments: FreeListCorruption.allCases)
func theFreeListVerifierCatches(_ c: FreeListCorruption) throws {
    let s = try Scene()
    defer { s.om.destroy() }
    let om = s.om
    let p = om.pools
    let runs = unsafe p.pointee.entryRuns
    #expect(runs.count >= 2)
    let head0 = runs[0], head1 = runs[1]
    switch c {
    case .usedEntryInARun: om.setStateWord(head0, EntryState.free(next: s.a.raw))
    case .entryInTwoLists:
        var e = head0
        while om.stateWord(e) & EntryState.nextMask != 0 { e = om.stateWord(e) & EntryState.nextMask }
        om.setStateWord(e, EntryState.free(next: head1))
    case .cycle: om.setStateWord(head0, EntryState.free(next: head0))
    case .leakedFreeEntry: unsafe p.pointee.entryRuns[0] = om.stateWord(head0) & EntryState.nextMask
    case .usedEntryInAContextList: unsafe s.w.ctx.state.pointee.freeEntry = s.b.raw
    case .blockInPoolTwice: unsafe p.pointee.freeBlocks.append(p.pointee.freeBlocks[0])
    case .fullBlockInPool:
        let b = om.blockIndex(of: s.holder)
        om.heap.setUsed(b, UInt64(BlockHeap.blockBytes))
        unsafe p.pointee.freeBlocks.append(UInt32(b))
    case .leakedFreeBlock:
        let fb = UInt32(s.freeBlock)
        let i = unsafe (0..<p.pointee.freeBlocks.count).first { p.pointee.freeBlocks[$0] == fb }!
        unsafe p.pointee.freeBlocks[i] = p.pointee.freeBlocks[p.pointee.freeBlocks.count - 1]
        _ = unsafe p.pointee.freeBlocks.popLast()
    case .referenceOutsideTable: om.setStateWord(head0, EntryState.free(next: (om.highWater + 5) << 4))
    case .blockBeyondTheHeap: unsafe p.pointee.freeBlocks.append(UInt32(om.heap.blockCount + 3))
    }
    s.check(om.verifyFreeLists(), c.needle)
}

@Test func theMarkVerifierCatchesAReachableObjectLeftUnmarked() throws {
    let s = try Scene()
    defer { s.om.destroy() }
    s.om.mark(extraRoots: [])
    s.om.setMark(s.b.entryIndex, 0)
    s.check(s.om.verifyMarks(extraRoots: []), "reachable but not marked")
}

@Test func theMarkVerifierCatchesAGarbageObjectMarked() throws {
    let s = try Scene()
    defer { s.om.destroy() }
    let g = s.w.new(4, 0)
    s.om.retireAllContexts()
    s.om.mark(extraRoots: [])
    s.om.setMark(g.entryIndex, 1)
    s.check(s.om.verifyMarks(extraRoots: []), "marked but not reachable")
}

@Test func theMarkVerifierCatchesAnInvalidReferenceItReaches() throws {
    let s = try Scene()
    defer { s.om.destroy() }
    s.om.mark(extraRoots: [])
    s.setSlotRaw(s.a, 0, s.garbage.raw)
    s.check(s.om.verifyMarks(extraRoots: []), "not a used entry")
}

@Test func theMarkVerifierSeesExtraRoots() throws {
    let s = try Scene()
    defer { s.om.destroy() }
    let g = s.w.new(4, 0)
    s.om.retireAllContexts()
    s.om.mark(extraRoots: [g])
    #expect(s.om.verifyMarks(extraRoots: [g]) == [])
}

@Test func verifiersRunAtEveryPauseWhenEnabled() throws {
    let s = try Scene()
    defer { s.om.destroy() }
    let runs = s.om.counters.verifierRuns
    s.om.collect()
    #expect(s.om.counters.verifierRuns == runs + 3)
}

@Test func verifiersAreOneFlagAway() throws {
    let om = try makeMemory(verify: false)
    defer { om.destroy() }
    let w = World(om)
    _ = w.new(2, 1)
    om.collect()
    #expect(om.counters.verifierRuns == 0)
}

@Test func aRecordedFailureIsCountedAndReported() throws {
    let s = try Scene()
    defer { s.om.destroy() }
    s.setSlotRaw(s.holder, 1, 0x108)
    s.om.collect()
    #expect(s.om.counters.verifierFailures >= 1)
    #expect(s.om.verifierReports.first?.contains("before collection") == true)
}

@Test func aFailureStopsTheVMUnderTrap() async {
    await #expect(processExitsWith: .failure) {
        let om = try makeMemory(onFailure: .trap)
        let w = World(om)
        let h = w.new(2, 1)
        _ = om.addRoot(h)
        om.retireAllContexts()
        om.heap.setWord(atOffset: om.bodyOffset(h) + 8, 0x108)
        om.collect()
    }
}
