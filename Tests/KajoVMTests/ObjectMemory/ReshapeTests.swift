import Testing
@testable import KajoVM

private func instances(_ w: World, _ cls: UInt64, _ n: Int, slots: Int = 2) -> (Oop, [Oop]) {
    var objs: [Oop] = []
    for i in 0..<n {
        let o = w.new(cls, slots)
        for s in 0..<slots { w.om.store(o, s, int(Int64((s + 1) * i))) }
        objs.append(o)
    }
    let holder = w.new(4, n)
    for (i, o) in objs.enumerated() { w.om.store(holder, i, o) }
    _ = w.om.addRoot(holder)
    return (holder, objs)
}

/// Ported from object-representation (B): same oops, new bodies.
@Test func reshapeAddsAnInstanceVariable() throws {
    let om = try makeMemory()
    defer { om.destroy() }
    let w = World(om)
    let (holder, objs) = instances(w, 5, 50)
    let offsets = objs.map { om.bodyOffset($0) }
    let n = try om.reshape(classIndex: 5, namedSlots: 2, layout: [0, 1, nil], fill: w.nilObj)
    #expect(n == 50 && om.counters.reshapedObjects == 50)
    for i in 0..<50 {
        let o = om.load(holder, i)
        #expect(o == objs[i])                       // same oop
        #expect(om.bodyOffset(o) != offsets[i])     // new body
        #expect(om.count(of: o) == 3 && om.classIndex(of: o) == 5)
        #expect(om.load(o, 0) == int(Int64(i)) && om.load(o, 1) == int(Int64(2 * i)))
        #expect(om.load(o, 2) == w.nilObj)
    }
    om.collect()
    #expect(om.load(objs[7], 1) == int(14) && om.counters.verifierFailures == 0)
}

@Test func reshapeRemovesAndReordersSlots() throws {
    let om = try makeMemory()
    defer { om.destroy() }
    let w = World(om)
    let (_, objs) = instances(w, 5, 10, slots: 3)
    try om.reshape(classIndex: 5, namedSlots: 3, layout: [2, 0], fill: w.nilObj)
    for (i, o) in objs.enumerated() {
        #expect(om.count(of: o) == 2)
        #expect(om.load(o, 0) == int(Int64(3 * i)) && om.load(o, 1) == int(Int64(i)))
    }
}

@Test func reshapeKeepsTheIndexedPart() throws {
    let om = try makeMemory()
    defer { om.destroy() }
    let w = World(om)
    let a = w.new(5, 2 + 3), b = w.new(5, 2)
    for i in 0..<5 { om.store(a, i, int(Int64(10 + i))) }
    _ = om.addRoot(w.new(4, 2))
    try om.reshape(classIndex: 5, namedSlots: 2, layout: [nil, 0, 1], fill: int(-1))
    #expect(om.count(of: a) == 6 && om.count(of: b) == 3)
    #expect((0..<6).map { om.load(a, $0) } == [int(-1), int(10), int(11), int(12), int(13), int(14)])
}

@Test func reshapeRefusesWhatItCannotDo() throws {
    let om = try makeMemory()
    defer { om.destroy() }
    let w = World(om)
    _ = w.bytes(4, cls: 6)
    let p = w.new(7, 1)
    om.pinForFrame(p)
    _ = w.new(8, 1)
    #expect(throws: ReshapeError.notRegistered) { try om.reshape(classIndex: 500, namedSlots: 0, layout: [], fill: w.nilObj) }
    #expect(throws: ReshapeError.byteObject) { try om.reshape(classIndex: 6, namedSlots: 0, layout: [], fill: w.nilObj) }
    #expect(throws: ReshapeError.pinnedInstance) { try om.reshape(classIndex: 7, namedSlots: 1, layout: [nil], fill: w.nilObj) }
    #expect(throws: ReshapeError.layoutOutOfRange) { try om.reshape(classIndex: 8, namedSlots: 1, layout: [1], fill: w.nilObj) }
    #expect(throws: ReshapeError.layoutOutOfRange) { try om.reshape(classIndex: 8, namedSlots: 2, layout: [0], fill: w.nilObj) }
    // Module 10: past one block is a large object; past the count field
    // is too large.
    #expect(throws: ReshapeError.tooLarge) {
        try om.reshape(classIndex: 8, namedSlots: 1, layout: Array(repeating: nil, count: Header.maxLargeCount + 1), fill: w.nilObj)
    }
}

@Test func reshapeIsAllOrNothingWhenTheHeapIsFull() throws {
    let om = try makeMemory(heapBlocks: 2, onFailure: .record)
    defer { om.destroy() }
    let w = World(om)
    let (_, objs) = instances(w, 5, 1000, slots: 4)  // about 40 KB live of 64
    #expect(throws: ReshapeError.heapFull) {
        try om.reshape(classIndex: 5, namedSlots: 4, layout: Array(0..<4) + Array(repeating: nil, count: 20), fill: w.nilObj)
    }
    for (i, o) in objs.enumerated() { #expect(om.count(of: o) == 4 && om.load(o, 3) == int(Int64(4 * i))) }
    om.collect()
    #expect(om.counters.verifierFailures == 0)
}

@Test func allInstancesFindsEveryInstanceOfAClass() throws {
    let om = try makeMemory()
    defer { om.destroy() }
    let w = World(om)
    let (_, objs) = instances(w, 5, 20)
    _ = instances(w, 6, 5)
    #expect(Set(om.allInstances(of: 5)) == Set(objs))
    #expect(om.allInstances(of: 6).count == 5 && om.allInstances(of: 7).isEmpty)
}
