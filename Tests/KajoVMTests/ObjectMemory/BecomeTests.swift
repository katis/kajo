import Testing
@testable import KajoVM

private func object(_ w: World, _ cls: UInt64, _ vals: [Int64]) -> Oop {
    let o = w.new(cls, vals.count)
    for (i, v) in vals.enumerated() { w.om.store(o, i, int(v)) }
    return o
}

private func array(_ w: World, _ elems: [Oop]) -> Oop {
    let a = w.new(4, elems.count)
    for (i, e) in elems.enumerated() { w.om.store(a, i, e) }
    return a
}

/// Ported from object-representation (B): the identities stay, the
/// entries swap.
@Test func twoWayBecomeSwapsIdentities() throws {
    let om = try makeMemory()
    defer { om.destroy() }
    let w = World(om)
    let a = object(w, 2, [1, 2])
    let b = object(w, 3, [7, 8, 9])
    let holder = array(w, [a, b, a])
    _ = om.addRoot(holder)
    try om.becomeExchange(a, b)
    let x = om.load(holder, 0), y = om.load(holder, 1)
    #expect(x == a && y == b)                 // the identity stayed; the entry changed
    #expect(om.classIndex(of: x) == 3 && om.load(x, 2) == int(9))
    #expect(om.classIndex(of: y) == 2 && om.load(y, 0) == int(1))
    #expect(om.load(holder, 2) == x)
    #expect(om.counters.becomes == 1)
    om.retireAllContexts()
    #expect(om.verifyHeap() == [])            // back references follow the bodies
    om.collect()
    #expect(om.load(a, 2) == int(9) && om.load(b, 1) == int(2))
}

@Test func pinsFollowTheBodyAcrossAnExchange() throws {
    let om = try makeMemory()
    defer { om.destroy() }
    let w = World(om)
    let a = object(w, 2, [1]), b = object(w, 2, [2])
    om.pinForFrame(a)
    let body = om.bodyOffset(a)
    try om.becomeExchange(a, b)
    #expect(om.bodyOffset(b) == body && om.isPinned(b) && !om.isPinned(a))
}

@Test func becomeRefusesWhatIsNotAnObject() throws {
    let om = try makeMemory()
    defer { om.destroy() }
    let w = World(om)
    let a = object(w, 2, [1])
    #expect(throws: BecomeError.notAnObject) { try om.becomeExchange(a, int(3)) }
    #expect(throws: BecomeError.notAnObject) { try om.becomeForward([int(1)], to: [a]) }
    try om.becomeExchange(a, a) // a no-op
    #expect(om.load(a, 0) == int(1))
}

/// Ported from object-representation (B): one full scan rewrites every
/// reference, in slots, the registry, the class table and the caller's
/// roots; the sources' entries are freed.
@Test func bulkForwardRedirectsEveryReference() throws {
    let om = try makeMemory()
    defer { om.destroy() }
    let w = World(om)
    var froms: [Oop] = [], tos: [Oop] = []
    for i in 0..<10 {
        froms.append(object(w, 2, [Int64(i), 0]))
        tos.append(object(w, 2, [Int64(100 + i), 0]))
    }
    om.store(tos[3], 1, froms[4])             // a target refers to a source
    let holder = array(w, froms + tos)
    _ = om.addRoot(holder)
    let r = om.addRoot(froms[0])
    let cls = om.registerClass(froms[1])
    var extra = [froms[2], int(7)]
    try om.becomeForward(froms, to: tos, extraRoots: &extra)
    for i in 0..<10 {
        #expect(om.load(holder, i) == om.load(holder, 10 + i))
        #expect(om.load(om.load(holder, i), 0) == int(Int64(100 + i)))
        #expect(!om.isUsedReference(froms[i]))
    }
    #expect(om.load(tos[3], 1) == tos[4])
    #expect(om.root(r) == tos[0] && om.classOop(cls) == tos[1] && extra == [tos[2], int(7)])
    #expect(om.counters.forwardedObjects == 10)
    #expect(om.counters.referencesForwarded == 10 + 1 + 1 + 1 + 1)
    om.retireAllContexts()
    #expect(om.verifyHeap() == [] && om.verifyFreeLists() == [])
}

@Test func bulkForwardRejectsAmbiguousPairs() throws {
    let om = try makeMemory()
    defer { om.destroy() }
    let w = World(om)
    let a = object(w, 2, []), b = object(w, 2, []), c = object(w, 2, [])
    #expect(throws: BecomeError.lengthMismatch) { try om.becomeForward([a, b], to: [c]) }
    #expect(throws: BecomeError.duplicateSource) { try om.becomeForward([a, a], to: [b, c]) }
    #expect(throws: BecomeError.sourceIsATarget) { try om.becomeForward([a, b], to: [b, c]) }
    #expect(throws: BecomeError.sourceIsATarget) { try om.becomeForward([a], to: [a]) }
    #expect(om.isUsedReference(a) && om.isUsedReference(b) && om.isUsedReference(c))
}
