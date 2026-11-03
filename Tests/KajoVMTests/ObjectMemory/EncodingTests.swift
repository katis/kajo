import Testing
@testable import KajoVM

// Ported: oopsAreTaggedAndNonZero (encoding half; the "nil is an entry
// offset" half is in AllocationTests), headerPackingAndSizes.

@Test func smallIntegersAreTaggedWithTheLowBit() {
    for v: Int64 in [0, 1, -1, 42, Oop.smallIntegerMax, Oop.smallIntegerMin] {
        let o = Oop(smallInteger: v)
        #expect(o.isSmallInteger && !o.isObject && o.raw & 1 == 1)
        #expect(o.smallIntegerValue == v)
    }
    #expect(Oop.smallIntegerMax == (1 << 62) - 1 && Oop.smallIntegerMin == -(1 << 62))
    #expect(Oop.fitsSmallInteger(Oop.smallIntegerMax) && !Oop.fitsSmallInteger(Oop.smallIntegerMax + 1))
    #expect(!Oop.fitsSmallInteger(Oop.smallIntegerMin - 1))
}

@Test func oopsAreTaggedAndNonZero() {
    let o = Oop(entryIndex: 1)
    #expect(o.isObject && !o.isSmallInteger && o.raw == 16 && o.entryIndex == 1)
    #expect(!Oop.none.isObject && !Oop.none.isSmallInteger && Oop.none.raw == 0)
    // Module 8: `..10` is a SmallFloat and `0100` a Character; `1000` and
    // `1100` stay spare, and so does a Character that is not a scalar.
    for low: UInt64 in [2, 6, 10, 14] {
        let r = Oop(raw: 0x100 | low)
        #expect(!r.isObject && !r.isSmallInteger && r.isSmallFloat && r.isImmediate && !r.isReserved)
    }
    #expect(Oop(raw: 0x104).isCharacter && !Oop(raw: 0x104).isReserved)
    for low: UInt64 in [8, 12] {
        let r = Oop(raw: 0x100 | low)
        #expect(!r.isObject && !r.isSmallInteger && r.isReserved)
    }
    #expect(Oop(raw: 0xD800 << 4 | 4).isReserved && Oop(raw: 0x110000 << 4 | 4).isReserved)
    #expect(!Oop(raw: 0x100).isReserved && !Oop(smallInteger: 3).isReserved)
}

@Test func headerPackingAndSizes() {
    let h = Header(classIndex: 7, count: 3, isBytes: true)
    #expect(h.classIndex == 7 && h.count == 3 && h.isBytes)
    #expect(!h.isPinnedForGood && !h.isFramePinned && h.reservedBits == 0)
    #expect(Header(classIndex: 1, count: 2, isBytes: false).bodyBytes == 24)
    #expect(Header(classIndex: 1, count: 9, isBytes: true).bodyBytes == 24)
    #expect(Header(classIndex: 1, count: 0, isBytes: true).bodyBytes == 8)
    let full = Header(classIndex: Header.maxClassIndex, count: Header.maxCount, isBytes: false)
    #expect(full.classIndex == Header.maxClassIndex && full.count == Header.maxCount && !full.isBytes)
}

@Test func headerBitsAreWhereTheLaterModulesExpectThem() {
    // The layout of experiments/concurrent-young SPEC "Header word".
    #expect(Header(classIndex: 1, count: 0, isBytes: false).raw == 1)
    #expect(Header(classIndex: 0, count: 1, isBytes: false).raw == 1 << 22)
    #expect(Header(classIndex: 0, count: 0, isBytes: true).raw == 1 << 47)
    #expect(Header.markBit == 1 << 46 && Header.youngBit == 1 << 56)
    #expect(Header.pinnedForGoodBit == 1 << 60 && Header.framePinBit == 1 << 61)
    #expect(Header.nurseryShift == 52 && Header.ageShift == 57 && Header.claimShift == 62)
    var h = Header(classIndex: 3, count: 4, isBytes: false)
    h.isPinnedForGood = true
    h.isFramePinned = true
    #expect(h.raw == 3 | 4 << 22 | 1 << 60 | 1 << 61 && h.reservedBits == 0)
    h.isFramePinned = false
    #expect(h.isPinnedForGood && !h.isFramePinned)
    // Every bit this module does not use is reserved and visible as such.
    // (module 4 uses bits 48 and 52 to 63: young, nursery, age, claim tag,
    // fired ephemeron; module 7 bit 49, a deferred entry free).
    #expect(Header(raw: Header.youngBit | 1).reservedBits == 0)
    #expect(Header(raw: Header.markBit).reservedBits == Header.markBit)
    #expect(Header(raw: 1 << 51).reservedBits == 1 << 51)
    #expect(Header.reservedMask == Header.markBit | 1 << 51)
}

@Test func bodyWordCountsCoverTheBlockLimit() {
    #expect(Header.maxSlots == 4095)
    #expect(Header.maxBytes == 4095 * 8)
    #expect(Header(classIndex: 1, count: UInt64(Header.maxSlots), isBytes: false).bodyBytes == 32 * 1024)
}
