import Testing
@testable import KajoVM

func makeImage(heapBlocks: Int = 256, entries: Int = 1 << 18, stress: StressFlags = [],
               limits: LoaderLimits = LoaderLimits(), verify: Bool = true, pinsForGood: Bool = true,
               switches: TestSwitches = TestSwitches()) throws -> Image {
    var c = ObjectMemoryConfig()
    c.testSwitches = switches
    c.heapBytes = heapBlocks * BlockHeap.blockBytes
    c.entryCapacity = entries
    c.entryChunk = 256
    c.stress = stress
    c.onVerifyFailure = .trap
    c.verify = verify
    return try Image(memory: ObjectMemory(c), limits: limits, pinsForGood: pinsForGood)
}

private func loadError(_ img: Image, _ files: [(String, String)]) -> LoadError.Kind? {
    do {
        try img.load(files.map { (file: $0.0, text: $0.1) })
        return nil
    } catch {
        return error.kind
    }
}

@Test func bootCreatesTheWellKnownObjects() throws {
    let img = try makeImage()
    defer { img.destroy() }
    let om = img.om
    #expect(om.classIndex(of: img.nilObject) == WellKnown.undefinedObject)
    #expect(om.classIndex(of: img.trueObject) == WellKnown.trueClass)
    #expect(om.classIndex(of: img.falseObject) == WellKnown.falseClass)
    #expect(img.classIndex(named: "Object") == WellKnown.object)
    #expect(img.classIndex(named: "Message") == WellKnown.message)
    for d in WellKnown.definitions {
        let cls = om.classOop(d.index)
        // Module 8: every class is the sole instance of its metaclass.
        let meta = WellKnown.metaclass(of: d.index)
        #expect(om.classIndex(of: cls) == meta && om.classIndex(of: om.classOop(meta)) == WellKnown.metaclass)
        #expect(om.load(om.classOop(meta), MetaclassLayout.thisClass) == cls)
        #expect(om.load(cls, ClassLayout.classIndex) == Oop(smallInteger: Int64(d.index)))
        #expect(img.symbolName(om.load(cls, ClassLayout.name)) == d.name)
        #expect(img.className(meta) == d.name + " class")
        let sup = om.load(cls, ClassLayout.superclass)
        #expect(sup == (d.superclass.map { om.classOop(img.classIndex(named: $0)!) } ?? img.nilObject))
        // `Foo class superclass` is `Foo superclass class`; Object class's is Class.
        let metaSup = om.load(om.classOop(meta), ClassLayout.superclass)
        #expect(metaSup == (sup == img.nilObject ? om.classOop(WellKnown.classClass) : om.classOop(om.classIndex(of: sup))))
        #expect(om.classFormat(d.index) == d.format && om.classFormat(meta).isSealed && om.classFormat(meta).instancesAreBehaviors)
    }
    #expect(om.load(om.classOop(WellKnown.classClass), ClassLayout.instSize) == Oop(smallInteger: 5))
    #expect(om.load(om.classOop(WellKnown.method), ClassLayout.instSize) == Oop(smallInteger: Int64(MethodLayout.size)))
    // special selectors interned in order, right after boot
    for (i, s) in specialSelectorNames.enumerated() { #expect(img.symbol(s) == img.specialSelectors[i]) }
    #expect(verified(om) == [])
}

@Test func loadingInstallsClassesMethodsAndLiterals() throws {
    let img = try makeImage()
    defer { img.destroy() }
    try img.load([("a.kasm", """
    class Point Object 2
    class Point3 Point 3
    method Point x temps=0
      push_ivar 0
      return_top
    end
    method Point3 z: temps=1
      push_lit #x
      push_lit @Point
      push_lit 123456
      push_temp 0
      store_ivar 2
      push_lit true
      return_top
    end
    method Object at: temps=0 prim=1
    end
    """)])
    let om = img.om
    let p = try #require(img.classIndex(named: "Point")), p3 = try #require(img.classIndex(named: "Point3"))
    #expect(p == WellKnown.firstUserClass && p3 == p + 2)  // a class and its metaclass each
    #expect(om.load(om.classOop(p3), ClassLayout.superclass) == om.classOop(p))
    #expect(om.load(om.classOop(p3), ClassLayout.instSize) == Oop(smallInteger: 3))

    let z = try #require(img.lookup(p3, img.symbol("z:")!))
    #expect(om.load(z, MethodLayout.argc) == Oop(smallInteger: 1))
    #expect(om.load(z, MethodLayout.temps) == Oop(smallInteger: 1))
    #expect(om.load(z, MethodLayout.maxStack) == Oop(smallInteger: 7))  // store_ivar's read-only send: 4 + 3
    #expect(om.load(z, MethodLayout.primitive) == Oop(smallInteger: 0))
    #expect(om.load(z, MethodLayout.selector) == img.symbol("z:"))
    let lits = om.load(z, MethodLayout.literals)
    #expect(om.count(of: lits) == 4)
    #expect(om.load(lits, 0) == img.symbol("x"))
    #expect(om.load(lits, 1) == om.classOop(p))
    #expect(om.load(lits, 2) == Oop(smallInteger: 123_456))
    #expect(om.load(lits, 3) == img.trueObject)
    let bc = om.load(z, MethodLayout.bytecodes)
    #expect(om.isBytes(bc) && om.count(of: bc) == 13)
    #expect(om.loadByte(bc, 0) == Opcode.pushLiteral.rawValue)

    // inherited through the superclass chain; primitives are on Object
    #expect(img.lookup(p3, img.symbol("x")!) == img.lookup(p, img.symbol("x")!))
    let at = try #require(img.lookup(p3, img.symbol("at:")!))
    #expect(om.load(at, MethodLayout.primitive) == Oop(smallInteger: 1))
    #expect(om.count(of: om.load(at, MethodLayout.bytecodes)) == 0)
    #expect(img.lookup(p, img.symbol("z:")!) == nil)
    #expect(verified(om) == [])
}

@Test func symbolsAreInternedAcrossFiles() throws {
    let img = try makeImage()
    defer { img.destroy() }
    try img.load([("a.kasm", "method Object foo temps=0\n push_lit #bar\n return_top\nend\n")])
    try img.load([("b.kasm", "method Object bar temps=0\n push_lit #foo\n return_top\nend\n")])
    let om = img.om
    let foo = try #require(img.lookup(WellKnown.object, img.symbol("foo")!))
    let bar = try #require(img.lookup(WellKnown.object, img.symbol("bar")!))
    #expect(om.load(om.load(foo, MethodLayout.literals), 0) == om.load(bar, MethodLayout.selector))
    #expect(om.load(om.load(bar, MethodLayout.literals), 0) == om.load(foo, MethodLayout.selector))
}

@Test func theFixtureKernelsLoad() throws {
    for k in goldenKernels {
        let img = try makeImage()
        defer { img.destroy() }
        try img.load(kernelSources(k.name))
        #expect(img.lookup(WellKnown.undefinedObject, img.symbol("run:of:")!) != nil)
        #expect(verified(img.om) == [])
    }
}

@Test(arguments: [
    ([("a", "method Nope foo temps=0\n return_self\nend\n")], LoadError.Kind.unknownClass),
    ([("a", "class A Nope 0\n")], .unknownClass),
    ([("a", "method Object foo temps=0\n push_lit @Nope\n return_top\nend\n")], .unknownClass),
    ([("a", "class A Object 0\nclass A Object 0\n")], .duplicateClass),
    ([("a", "class Array Object 0\n")], .duplicateClass),
    ([("a", "class A Object 0\n"), ("b", "class A Object 0\n")], .duplicateClass),
    ([("a", "method Object foo temps=0\n return_self\nend\nmethod Object foo temps=0\n return_self\nend\n")], .duplicateMethod),
    ([("a", "method Object foo temps=0\n return_self\nend\n"), ("b", "method Object foo temps=0\n return_self\nend\n")], .duplicateMethod),
    ([("a", "class A B 0\nclass B A 0\n")], .badClass),
    ([("a", "class A Object 3\nclass B A 2\n")], .badClass),
    ([("a", "class A Object 2\nmethod A foo temps=0\n push_ivar 2\n return_top\nend\n")], .badClass),
    ([("a", "method Array foo temps=0\n push_int 1\n store_ivar 0\n return_self\nend\n")], .badClass),
    ([("a", "method Object foo temps=0\n push_ivar 0\n return_top\nend\n")], .badClass),
    ([("a", "class A Object 0\n"), ("b", "method A foo temps=0\n push_lit @C\n return_top\nend\nclass C Object 0\n")], nil),
] as [([(String, String)], LoadError.Kind?)])
func theLoaderRejects(_ files: [(String, String)], _ kind: LoadError.Kind?) throws {
    let img = try makeImage()
    defer { img.destroy() }
    #expect(loadError(img, files) == kind)
}

@Test func tooManyClassesAndMethodsAreRejected() throws {
    var limits = LoaderLimits()
    limits.maxClassIndex = 68
    limits.maxMethodsPerClass = 4
    let img = try makeImage(limits: limits)
    defer { img.destroy() }
    let classes = (0..<8).map { "class C\($0) Object 0\n" }.joined()
    #expect(loadError(img, [("a", classes)]) == nil)                          // 53 + 2 x 8 = 69 indices: 0...68
    #expect(loadError(img, [("b", "class D Object 0\n")]) == .tooManyClasses)
    let methods = (0..<4).map { "method C0 m\($0) temps=0\n return_self\nend\n" }.joined()
    #expect(loadError(img, [("c", methods)]) == nil)
    #expect(loadError(img, [("d", "method C0 m4 temps=0\n return_self\nend\n")]) == .tooManyMethods)
}

@Test func aRejectedLoadChangesNothing() throws {
    let img = try makeImage()
    defer { img.destroy() }
    let classes = img.om.classCount
    let src = "class A Object 0\nmethod A foo temps=0\n return_self\nend\nmethod A bar temps=0\n frob\nend\n"
    #expect(loadError(img, [("a", src)]) == .unknownOpcode)
    #expect(img.om.classCount == classes && img.classIndex(named: "A") == nil && img.symbol("foo") == nil)
    #expect(loadError(img, [("a", "class A Object 0\nmethod A foo temps=0\n return_self\nend\n")]) == nil)
}

@Test func loadingSurvivesACollectionAtEveryAllocation() throws {
    let img = try makeImage(stress: .collectAtEveryAllocation)
    defer { img.destroy() }
    try img.load(kernelSources("sends"))
    let om = img.om
    #expect(om.counters.stressCollections > 100)
    #expect(verified(om) == [])
    let m = try #require(img.lookup(img.classIndex(named: "Leaf")!, img.symbol("step:")!))
    #expect(om.load(m, MethodLayout.selector) == img.symbol("step:"))
}

@Test func methodDictionariesGrowWhenALaterLoadAddsMethods() throws {
    let img = try makeImage()
    defer { img.destroy() }
    for i in 0..<40 {
        try img.load([("f\(i)", "method Object m\(i) temps=0\n push_int \(i)\n return_top\nend\n")])
    }
    for i in 0..<40 {
        let m = try #require(img.lookup(WellKnown.object, img.symbol("m\(i)")!))
        #expect(img.om.loadByte(img.om.load(m, MethodLayout.bytecodes), 1) == UInt8(i))
    }
}

/// The heap and free-list verifiers' reports, with every context retired.
func verified(_ om: ObjectMemory) -> [String] {
    om.retireAllContexts()
    return om.verifyHeap() + om.verifyFreeLists()
}
