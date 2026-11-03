// The image format (module 8): module 1's snapshot plus what the loader
// needs to trust it before anything runs. Module 1's loader trusts a
// snapshot for heap structure only (every entry, block, slot and root
// valid); this loader adds the object model's rules and verifies every
// method with the bytecode verifier. Loading is all or nothing: any rule
// broken, and nothing is kept.
//
//     word 0   magic "KAJOIMG\0"
//     word 1   version (1)
//     word 2   the special-objects Array (`SpecialObjects`), a root
//     word 3   method count M
//     word 4   snapshot length L in bytes
//     M words  the method table: every CompiledMethod in the heap
//     L bytes  module 1's snapshot (version 3)
//
// Rules checked after module 1's (`verifyImage`):
//  - the special objects: nil, true, false of their classes; the globals
//    and the symbol table Arrays of their sizes; the selectors Array holding
//    the special-send and VM selectors with those bytes;
//  - the symbol table: every bucket nil or an Array of Symbols filled from
//    slot 0, each in the bucket its bytes hash to, no two with the same
//    bytes;
//  - the classes: every registered index's class object a behavior naming
//    that index, its format valid, its metaclass a sealed behaviors format
//    whose Metaclass instance names the class back; class objects as large
//    as their metaclass says; superclass chains acyclic and ending in nil;
//    method dictionaries of Symbols and Methods compiled for that class;
//    the well-known classes with their names and formats;
//  - every object admitted by its class's format (pointers or bytes, fixed
//    or variable, whole elements); no Process (a Process cannot be saved
//    in 8a), no live Context (only detached ones), every closure the shape
//    of its block method;
//  - the method table equal to the set of CompiledMethods in the heap, and
//    every method passing `verifyHeapMethod` for its class, pinned for good
//    with its bytecodes and literal Array (the interpreter caches pointers
//    into them), its bytecodes and literals read-only.

enum ImageError: Error, Equatable, CustomStringConvertible {
    case badMagic
    case unsupportedVersion(UInt64)
    case malformed(String)
    case snapshot(SnapshotError)
    case rule(String)

    var description: String {
        switch self {
        case .badMagic: "not a Kajo image (bad magic)"
        case .unsupportedVersion(let v): "unsupported image version \(v)"
        case .malformed(let s): "malformed image: \(s)"
        case .snapshot(let e): "image snapshot: \(e)"
        case .rule(let s): "image rejected: \(s)"
        }
    }
}

enum ImageFile {
    static let magic: UInt64 = 0x0047_4D49_4F4A_414B  // "KAJOIMG\0"
    static let version: UInt64 = 1
    static let headerWords = 5
}

extension Image {
    /// The image as bytes: the method table and module 1's snapshot (which
    /// promotes, retires the contexts and drops frame pins). No VM may run
    /// over the image meanwhile.
    func saveImage() -> [UInt8] {
        // A collection first: garbage stays out of the image, and the free
        // entries of destroyed allocation contexts (interpreters that ran on
        // this image) return to the pool's runs.
        om.collect()
        let snap = om.snapshot()
        let methods = om.allInstances(of: WellKnown.method)
        var out: [UInt8] = []
        out.reserveCapacity(8 * (ImageFile.headerWords + methods.count) + snap.count)
        func word(_ v: UInt64) { for k in 0..<8 { out.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(k)))) } }
        word(ImageFile.magic)
        word(ImageFile.version)
        word(specialObjects.raw)
        word(UInt64(methods.count))
        word(UInt64(snap.count))
        for m in methods { word(m.raw) }
        out += snap
        return out
    }

    /// Load an image: parse, module 1's snapshot loader, the object-model
    /// rules and every method's verification, all before anything runs.
    /// Throws, keeping nothing, on any failure.
    static func load(image b: [UInt8], config: ObjectMemoryConfig = .init(), limits: LoaderLimits = LoaderLimits())
        throws(ImageError) -> Image {
        func word(_ i: Int) -> UInt64 {
            var v: UInt64 = 0
            for k in 0..<8 { v |= UInt64(b[8 * i + k]) << (8 * UInt64(k)) }
            return v
        }
        guard b.count >= 8 * ImageFile.headerWords else { throw .malformed("shorter than its header") }
        guard word(0) == ImageFile.magic else { throw .badMagic }
        guard word(1) == ImageFile.version else { throw .unsupportedVersion(word(1)) }
        let special = Oop(raw: word(2))
        let m = word(3), l = word(4)
        guard m <= UInt64(b.count / 8), l <= UInt64(b.count) else { throw .malformed("counts larger than the image") }
        let tableEnd = 8 * (ImageFile.headerWords + Int(m))
        guard tableEnd + Int(l) == b.count else { throw .malformed("length \(b.count), header says \(tableEnd + Int(l))") }
        let table = (0..<Int(m)).map { Oop(raw: word(ImageFile.headerWords + $0)) }
        let om: ObjectMemory
        do {
            om = try ObjectMemory.load(snapshot: Array(b[tableEnd...]), config: config)
        } catch {
            throw .snapshot(error)
        }
        do {
            try verifyImage(om, special: special, methodTable: table, limits: limits)
            return try Image(restoring: om, special: special, limits: limits)
        } catch {
            om.destroy()
            throw error
        }
    }
}

/// The object-model rules (above) on a loaded snapshot.
func verifyImage(_ om: ObjectMemory, special: Oop, methodTable: [Oop], limits: LoaderLimits) throws(ImageError) {
    func fail(_ s: String) -> ImageError { .rule(s) }
    let hw = om.highWater
    func used(_ o: Oop) -> Bool { om.isUsedReference(o) }
    func isA(_ o: Oop, _ c: UInt64) -> Bool { o.isObject && used(o) && om.classIndex(of: o) == c }
    // Registered classes first (everything below indexes formats by class).
    let classCount = om.classCount
    guard classCount > Int(2 * WellKnown.count) else { throw fail("fewer classes than the well-known ones") }
    for i in 1..<UInt64(classCount) where !om.classFormat(i).isValid {
        throw fail("class \(i) has an invalid format")
    }
    // Special objects.
    guard isA(special, WellKnown.array), om.count(of: special) == UInt64(SpecialObjects.size) else {
        throw fail("the special objects are not an Array of \(SpecialObjects.size)")
    }
    var isRoot = false
    om.forEachRegisteredRoot { if $0 == special { isRoot = true } }
    guard isRoot else { throw fail("the special objects are not a root") }
    let nilObj = om.load(special, SpecialObjects.nilObject)
    guard isA(nilObj, WellKnown.undefinedObject), om.nilObject == nilObj,
          isA(om.load(special, SpecialObjects.trueObject), WellKnown.trueClass),
          isA(om.load(special, SpecialObjects.falseObject), WellKnown.falseClass) else { throw fail("nil, true or false") }
    let globals = om.load(special, SpecialObjects.globals), symbols = om.load(special, SpecialObjects.symbolTable)
    guard isA(globals, WellKnown.array), om.count(of: globals) == UInt64(Image.globalCount),
          isA(symbols, WellKnown.array), om.count(of: symbols) == UInt64(SymbolTable.buckets) else {
        throw fail("the globals or the symbol table")
    }
    // The symbol table.
    var seen = Set<[UInt8]>()
    for j in 0..<SymbolTable.buckets {
        let bucket = om.load(symbols, j)
        if bucket == nilObj { continue }
        guard isA(bucket, WellKnown.array) else { throw fail("symbol bucket \(j)") }
        var ended = false
        for i in 0..<Int(om.count(of: bucket)) {
            let s = om.load(bucket, i)
            if s == nilObj { ended = true; continue }
            guard !ended, isA(s, WellKnown.symbol), om.isBytes(s) else { throw fail("symbol bucket \(j) slot \(i)") }
            let bytes = om.bytes(of: s)
            guard isValidUTF8(bytes), Int(truncatingIfNeeded: utf8Hash(bytes)) & (SymbolTable.buckets - 1) == j,
                  seen.insert(bytes).inserted else { throw fail("symbol bucket \(j): a misplaced or duplicate Symbol") }
        }
    }
    let sels = om.load(special, SpecialObjects.selectors)
    let names = specialSelectorNames + VMSelector.names
    guard isA(sels, WellKnown.array), om.count(of: sels) == UInt64(names.count) else { throw fail("the selectors") }
    for (i, n) in names.enumerated() {
        let s = om.load(sels, i)
        guard isA(s, WellKnown.symbol), om.bytes(of: s) == Array(n.utf8) else { throw fail("selector \(n)") }
    }
    let dnu = om.load(special, SpecialObjects.doesNotUnderstand)
    guard isA(dnu, WellKnown.symbol), om.bytes(of: dnu) == Array("doesNotUnderstand:".utf8) else { throw fail("doesNotUnderstand:") }
    // Classes and metaclasses.
    for i in 1..<UInt64(classCount) {
        let c = om.classOop(i)
        guard c.isObject, used(c), om.isBehavior(c), !om.isBytes(c),
              om.load(c, ClassLayout.classIndex) == Oop(smallInteger: Int64(i)) else { throw fail("class \(i)'s object") }
        let mi = om.classIndex(of: c)
        let mf = om.classFormat(mi)
        guard mf.isSealed, mf.instancesAreBehaviors, om.count(of: c) == UInt64(mf.namedSlots),
              mf.namedSlots >= ClassLayout.size else { throw fail("class \(i)'s metaclass format") }
        let f = om.classFormat(i)
        guard om.load(c, ClassLayout.instSize) == Oop(smallInteger: Int64(f.namedSlots)) else {
            throw fail("class \(i)'s instSize and format disagree")
        }
        if mi != WellKnown.metaclass {
            // c is a class: its metaclass is a Metaclass naming it back.
            let mc = om.classOop(mi)
            guard isA(mc, WellKnown.metaclass), om.load(mc, MetaclassLayout.thisClass) == c else {
                throw fail("class \(i)'s metaclass does not name it")
            }
        } else {
            let this = om.load(c, MetaclassLayout.thisClass)
            guard this.isObject, used(this), om.classIndex(of: this) == i else { throw fail("metaclass \(i)'s class") }
        }
        // Superclass chain.
        var s = om.load(c, ClassLayout.superclass)
        var steps = 0
        while s != nilObj {
            guard s.isObject, used(s), om.isBehavior(s), steps < classCount else { throw fail("class \(i)'s superclass chain") }
            s = om.load(s, ClassLayout.superclass)
            steps += 1
        }
        // Method dictionary.
        let d = om.load(c, ClassLayout.methodDict)
        if d != nilObj {
            guard isA(d, WellKnown.methodDict), om.count(of: d) % 2 == 0, om.count(of: d) >= 2,
                  (om.count(of: d) / 2) & (om.count(of: d) / 2 - 1) == 0 else { throw fail("class \(i)'s method dictionary") }
            for k in 0..<Int(om.count(of: d) / 2) {
                let key = om.load(d, 2 * k), meth = om.load(d, 2 * k + 1)
                if key == nilObj { continue }
                guard isA(key, WellKnown.symbol), isA(meth, WellKnown.method), om.load(meth, MethodLayout.methodClass) == c,
                      om.load(meth, MethodLayout.selector) == key else { throw fail("class \(i)'s method dictionary entry \(k)") }
            }
        }
    }
    for d in WellKnown.definitions {
        let c = om.classOop(d.index)
        guard om.classFormat(d.index) == d.format, om.bytes(of: om.load(c, ClassLayout.name)) == Array(d.name.utf8) else {
            throw fail("well-known class \(d.name)")
        }
    }
    // Every object.
    var methods = Set<Oop>()
    var e: UInt64 = 1
    while e < hw {
        let o = Oop(raw: e &<< 4)
        e &+= 1
        if !used(o) { continue }
        let h = om.header(o)
        let ci = h.classIndex
        guard om.classFormat(ci).admits(isBytes: h.isBytes, count: h.count) else {
            throw fail("object \(o) does not fit class \(ci)'s format")
        }
        switch ci {
        case WellKnown.process: throw fail("a Process: Processes are not saved in an image")
        case WellKnown.context:
            guard om.load(o, ContextLayout.frame) == nilObj else { throw fail("a live Context") }
        case WellKnown.blockClosure:
            let bm = om.load(o, ClosureLayout.method)
            guard isA(bm, WellKnown.method), om.load(bm, MethodLayout.flags).isSmallInteger,
                  om.load(bm, MethodLayout.flags).smallIntegerValue & MethodFlags.block != 0,
                  om.load(bm, MethodLayout.copied) == Oop(smallInteger: Int64(h.count) - Int64(ClosureLayout.size)) else {
                throw fail("closure \(o) does not fit its block method")
            }
            let home = om.load(o, ClosureLayout.home)
            guard home == nilObj || isA(home, WellKnown.context) else { throw fail("closure \(o)'s home") }
        case WellKnown.method:
            methods.insert(o)
        default:
            break
        }
    }
    guard Set(methodTable) == methods, methodTable.count == methods.count else {
        throw fail("the method table names \(methodTable.count) methods, the heap holds \(methods.count)")
    }
    for meth in methodTable {
        let mc = om.load(meth, MethodLayout.methodClass)
        guard mc.isObject, used(mc), om.isBehavior(mc), om.load(mc, ClassLayout.classIndex).isSmallInteger else {
            throw fail("method \(meth)'s class")
        }
        let ci = UInt64(om.load(mc, ClassLayout.classIndex).smallIntegerValue)
        if let issue = verifyHeapMethod(om, meth, classIndex: ci, nilObject: nilObj, limits: limits) {
            throw fail("method \(meth): \(issue)")
        }
        let bc = om.load(meth, MethodLayout.bytecodes), lits = om.load(meth, MethodLayout.literals)
        guard om.header(meth).isPinnedForGood, om.header(bc).isPinnedForGood, om.header(lits).isPinnedForGood,
              om.isReadOnly(bc), om.isReadOnly(lits) else { throw fail("method \(meth) is not pinned and read-only") }
    }
}

extension Image {
    /// An Image over a verified object memory: the well-known objects from
    /// the special-objects Array, the host tables from the classes and
    /// their method dictionaries.
    convenience init(restoring om: ObjectMemory, special: Oop, limits: LoaderLimits) throws(ImageError) {
        try self.init(memory: om, limits: limits, restoring: special)
    }
}
