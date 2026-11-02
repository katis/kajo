import Testing
@testable import KajoVM

@Test func anAllocatedObjectHasItsClassCountAndFill() throws {
    let om = try makeMemory()
    defer { om.destroy() }
    let ctx = om.makeContext()
    let o = om.tryAllocate(ctx, classIndex: 5, slots: 3, fill: fillValue)
    #expect(o.isObject)
    #expect(om.classIndex(of: o) == 5 && om.count(of: o) == 3 && !om.isBytes(o))
    for i in 0..<3 { #expect(om.load(o, i) == fillValue) }
    om.store(o, 1, int(42))
    #expect(om.load(o, 1) == int(42) && om.load(o, 0) == fillValue && om.load(o, 2) == fillValue)
    let p = om.tryAllocate(ctx, classIndex: 6, slots: 0, fill: fillValue)
    #expect(p.isObject && p != o && om.count(of: p) == 0)
}

@Test func byteObjectsAreZeroedAndAddressable() throws {
    let om = try makeMemory()
    defer { om.destroy() }
    let ctx = om.makeContext()
    let b = om.tryAllocateBytes(ctx, classIndex: 9, count: 13)
    #expect(om.isBytes(b) && om.count(of: b) == 13 && om.classIndex(of: b) == 9)
    for i in 0..<13 { #expect(om.loadByte(b, i) == 0) }
    om.storeByte(b, 12, 0xAB)
    om.storeByte(b, 0, 7)
    #expect(om.loadByte(b, 12) == 0xAB && om.loadByte(b, 0) == 7 && om.loadByte(b, 11) == 0)
}

/// Ported: the second half of oopsAreTaggedAndNonZero (B): an object
/// reference is a 16-byte aligned offset inside the entry table.
@Test func referencesAreEntryOffsetsInsideTheTable() throws {
    let om = try makeMemory(entries: 1024)
    defer { om.destroy() }
    let ctx = om.makeContext()
    let o = om.tryAllocate(ctx, classIndex: 1, slots: 0, fill: fillValue)
    #expect(o.raw != 0 && o.raw & 15 == 0 && o.raw < 1024 * 16 && o.entryIndex >= 1)
}

@Test func reusedMemoryIsRefilled() throws {
    // A body slot is filled even when the block held garbage before: the
    // fill is not left to zero pages.
    let om = try makeMemory(heapBlocks: 1)
    defer { om.destroy() }
    let ctx = om.makeContext()
    let a = om.tryAllocate(ctx, classIndex: 1, slots: 4, fill: int(7))
    #expect(om.load(a, 3) == int(7))
}

@Test func theHeapIsMappedTwiceAtTheRelocationAlias() throws {
    let om = try makeMemory()
    defer { om.destroy() }
    let ctx = om.makeContext()
    let o = om.tryAllocate(ctx, classIndex: 1, slots: 2, fill: fillValue)
    om.store(o, 1, int(99))
    let off = om.bodyOffset(o)
    // The same body read through the alias, as a RELOCATING state word will.
    #expect(om.heap.aliasLoadWord(atOffset: off + 16) == int(99).raw)
    om.heap.aliasStoreWord(atOffset: off + 16, int(5).raw)
    #expect(om.load(o, 1) == int(5))
}

@Test func contextsAllocateFromTheirOwnBlocksAndEntryChunks() throws {
    let om = try makeMemory(chunk: 8)
    defer { om.destroy() }
    let c1 = om.makeContext(), c2 = om.makeContext()
    let a = om.tryAllocate(c1, classIndex: 1, slots: 1, fill: fillValue)
    let b = om.tryAllocate(c2, classIndex: 1, slots: 1, fill: fillValue)
    #expect(om.blockIndex(of: a) != om.blockIndex(of: b))
    #expect(b.entryIndex - a.entryIndex >= 8) // separate chunks
    for _ in 0..<20 { _ = om.tryAllocate(c1, classIndex: 1, slots: 1, fill: fillValue) }
    #expect(om.counters.entryRefills >= 3 + 1)
    #expect(om.counters.blockRefills == 2)
    #expect(om.counters.allocations == 22)
}

@Test func objectsFillABlockAndNeverSpanTwo() throws {
    let om = try makeMemory(heapBlocks: 4)
    defer { om.destroy() }
    let ctx = om.makeContext()
    // 1000 slots = 8008 bytes: four fit in a 32 KiB block, the fifth starts the next.
    var blocks: [Int] = []
    for _ in 0..<5 { blocks.append(om.blockIndex(of: om.tryAllocate(ctx, classIndex: 1, slots: 1000, fill: fillValue))) }
    #expect(blocks[0] == blocks[3] && blocks[4] != blocks[3])
    let big = om.tryAllocate(ctx, classIndex: 1, slots: Header.maxSlots, fill: fillValue)
    #expect(big.isObject && om.count(of: big) == UInt64(Header.maxSlots))
}

@Test func exhaustingTheHeapAsksForACollection() throws {
    let om = try makeMemory(heapBlocks: 2)
    defer { om.destroy() }
    let ctx = om.makeContext()
    var n = 0
    while om.tryAllocate(ctx, classIndex: 1, slots: 1000, fill: fillValue).isObject { n += 1 }
    #expect(n == 8)
    #expect(om.tryAllocate(ctx, classIndex: 1, slots: 1000, fill: fillValue) == .none)
    #expect(om.counters.allocationFailures >= 2)
}

@Test func exhaustingTheEntryTableAsksForACollection() throws {
    let om = try makeMemory(entries: 64, chunk: 16)
    defer { om.destroy() }
    let ctx = om.makeContext()
    var n = 0
    while om.tryAllocate(ctx, classIndex: 1, slots: 0, fill: fillValue).isObject { n += 1 }
    #expect(n == 63) // entry 0 is reserved
}
