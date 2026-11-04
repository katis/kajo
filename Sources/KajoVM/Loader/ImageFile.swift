// The image format (module 8): module 1's snapshot plus what the loader
// needs to trust it before anything runs. Module 1's loader trusts a
// snapshot for heap structure only (every entry, block, slot and root
// valid); this loader adds the object model's rules and verifies every
// method with the bytecode verifier. Loading is all or nothing: any rule
// broken, and nothing is kept.
//
//     word 0   magic "KAJOIMG\0"
//     word 1   version (4, module 9b: two more VM selectors, holes in
//              the class table, the source-map method flag; 3 since 8d:
//              the Metaclass layout gained the class pool and the header
//              the flags word; versions 1 to 3 are refused, images are
//              rebuilt from their sources)
//     word 2   the special-objects Array (`SpecialObjects`), a root
//     word 3   method count M
//     word 4   snapshot length L in bytes
//     word 5   flags: bit 0 a release image (module 8d), every other bit 0
//     M words  the method table: every CompiledMethod in the heap
//     L bytes  module 1's snapshot (version 3)
//
// Rules checked after module 1's (`verifyImage`):
//  - the special objects: nil, true, false of their classes; the globals
//    and the symbol table Arrays of their sizes; the selectors Array holding
//    the special-send and VM selectors with those bytes;
//  - the symbol table: every bucket nil or a WeakArray of Symbols and
//    nils (module 8b: the table is weak), each Symbol in the bucket its
//    bytes hash to, no two with the same bytes;
//  - module 9b: a hole in the class table (no class object, format 0) is
//    allowed past the well-known classes; no object's class index is one;
//  - the classes: every registered index's class object a behavior naming
//    that index, its format valid, its metaclass a sealed behaviors format
//    whose Metaclass instance names the class back; class objects as large
//    as their metaclass says; superclass chains acyclic and ending in nil;
//    method dictionaries of Symbols and Methods compiled for that class;
//    the well-known classes with their names and formats;
//  - every object admitted by its class's format (pointers or bytes, fixed
//    or variable, whole elements); every closure the shape of its block
//    method;
//  - the method table equal to the set of CompiledMethods in the heap, and
//    every method passing `verifyHeapMethod` for its class, pinned for good
//    with its bytecodes and literal Array (the interpreter caches pointers
//    into them), its bytecodes and literals read-only;
//  - module 8c: the saved Processes and the scheduler state (special object
//    8; `SavedProcessRules.swift`): every Process in the heap saved (ready
//    or waiting, its stack's frames checked against their methods and the
//    traced depths) or terminated; every list acyclic and consistent; every
//    live Context named by a saved frame (or of a terminated Process).

enum ImageError: Error, Equatable, CustomStringConvertible {
    case badMagic
    case unsupportedVersion(UInt64)
    case malformed(String)
    case snapshot(SnapshotError)
    case rule(String)

    var description: String {
        switch self {
        case .badMagic: "not a Kajo image (bad magic)"
        case .unsupportedVersion(let v): "unsupported image version \(v)" + (v < ImageFile.version ? " (made before module 9b's: rebuild it from its sources)" : "")
        case .malformed(let s): "malformed image: \(s)"
        case .snapshot(let e): "image snapshot: \(e)"
        case .rule(let s): "image rejected: \(s)"
        }
    }
}

enum ImageFile {
    static let magic: UInt64 = 0x0047_4D49_4F4A_414B  // "KAJOIMG\0"
    /// Module 8d: 3 (Metaclass objects hold the class pool; the header
    /// has the flags word). Module 8c's 2 and 8b's 1 are refused.
    static let version: UInt64 = 4
    static let headerWords = 6
    /// Flags word bits.
    static let releaseFlag: UInt64 = 1
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
        return encodedImage(snapshot: om.snapshot())
    }

    /// Module 1's snapshot bytes with the image header and method table
    /// around them (a stop or no VM: the heap does not change meanwhile).
    func encodedImage(snapshot snap: [UInt8]) -> [UInt8] {
        let methods = om.allInstances(of: WellKnown.method)
        var out: [UInt8] = []
        out.reserveCapacity(8 * (ImageFile.headerWords + methods.count) + snap.count)
        func word(_ v: UInt64) { for k in 0..<8 { out.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(k)))) } }
        word(ImageFile.magic)
        word(ImageFile.version)
        word(specialObjects.raw)
        word(UInt64(methods.count))
        word(UInt64(snap.count))
        word(om.isReleaseImage ? ImageFile.releaseFlag : 0)
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
        guard word(5) & ~ImageFile.releaseFlag == 0 else { throw .malformed("unknown flags \(word(5))") }
        let release = word(5) & ImageFile.releaseFlag != 0
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
            om.isReleaseImage = release
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
    /// A pointer object with at least `n` slots (before any slot is read).
    func slots(_ o: Oop, _ n: Int) -> Bool { o.isObject && used(o) && !om.isBytes(o) && om.count(of: o) >= UInt64(n) }
    func isMethod(_ o: Oop) -> Bool { isA(o, WellKnown.method) && slots(o, MethodLayout.size) }
    // Registered classes first (everything below indexes formats by class).
    let classCount = om.classCount
    guard classCount > Int(2 * WellKnown.count) else { throw fail("fewer classes than the well-known ones") }
    for i in 1..<UInt64(classCount) where !om.classFormat(i).isValid {
        throw fail("class \(i) has an invalid format")
    }
    // Special objects.
    let specialCount = SpecialObjects.size
    guard isA(special, WellKnown.array), om.count(of: special) == UInt64(specialCount) else {
        throw fail("the special objects are not an Array of \(specialCount)")
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
        // Module 8b: a weak bucket; nil marks a slot never used or a
        // collected Symbol's tombstone, anywhere in the bucket.
        guard isA(bucket, WellKnown.weakArray) else { throw fail("symbol bucket \(j)") }
        for i in 0..<Int(om.count(of: bucket)) {
            let s = om.load(bucket, i)
            if s == nilObj { continue }
            guard isA(s, WellKnown.symbol), om.isBytes(s) else { throw fail("symbol bucket \(j) slot \(i)") }
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
        // Module 9b: a freed obsolete class's index.
        if om.classOop(i) == .none {
            guard i >= WellKnown.firstUserClass, om.isClassHole(i) else { throw fail("class \(i) has no object") }
            continue
        }
        let c = om.classOop(i)
        guard slots(c, ClassLayout.size), om.isBehavior(c),
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
            guard isA(mc, WellKnown.metaclass), slots(mc, MetaclassLayout.size), om.load(mc, MetaclassLayout.thisClass) == c else {
                throw fail("class \(i)'s metaclass does not name it")
            }
        } else {
            guard slots(c, MetaclassLayout.size) else { throw fail("metaclass \(i)'s object") }
            let this = om.load(c, MetaclassLayout.thisClass)
            guard this.isObject, used(this), om.classIndex(of: this) == i else { throw fail("metaclass \(i)'s class") }
            // Module 8d: the class pool, nil or a read-only Array (of the
            // kernel's Bindings; the VM reads none of it).
            let pool = om.load(c, MetaclassLayout.classPool)
            guard pool == nilObj || isA(pool, WellKnown.array) && om.isReadOnly(pool) else {
                throw fail("metaclass \(i)'s class pool")
            }
        }
        // Superclass chain.
        var s = om.load(c, ClassLayout.superclass)
        var steps = 0
        while s != nilObj {
            guard slots(s, ClassLayout.size), om.isBehavior(s), steps < classCount else { throw fail("class \(i)'s superclass chain") }
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
                guard isA(key, WellKnown.symbol), isMethod(meth), om.load(meth, MethodLayout.methodClass) == c,
                      om.load(meth, MethodLayout.selector) == key else { throw fail("class \(i)'s method dictionary entry \(k)") }
            }
        }
    }
    for d in WellKnown.definitions {
        let name = om.load(om.classOop(d.index), ClassLayout.name)
        guard om.classFormat(d.index) == d.format, isA(name, WellKnown.symbol),
              om.bytes(of: name) == Array(d.name.utf8) else {
            throw fail("well-known class \(d.name)")
        }
    }
    // Every object.
    var methods = Set<Oop>()
    var processObjects = HeapProcessObjects()
    var e: UInt64 = 1
    while e < hw {
        let o = Oop(raw: e &<< 4)
        e &+= 1
        if !used(o) { continue }
        let h = om.header(o)
        let ci = h.classIndex
        guard !om.isClassHole(ci) else { throw fail("object \(o)'s class index \(ci) is a hole") }
        guard om.classFormat(ci).admits(isBytes: h.isBytes, count: h.count) else {
            throw fail("object \(o) does not fit class \(ci)'s format")
        }
        switch ci {
        // Module 8c: Processes, Semaphores and live Contexts are checked
        // against the saved Processes below.
        case WellKnown.process: processObjects.processes.append(o)
        case WellKnown.semaphore: processObjects.semaphores.append(o)
        case WellKnown.context:
            guard !h.isBytes, h.count >= UInt64(ContextLayout.size) else { throw fail("Context \(o)'s shape") }
            if om.load(o, ContextLayout.frame) != nilObj { processObjects.liveContexts.append(o) }
        case WellKnown.blockClosure:
            let bm = om.load(o, ClosureLayout.method)
            guard isMethod(bm), om.load(bm, MethodLayout.flags).isSmallInteger,
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
        guard isMethod(meth) else { throw fail("method \(meth) is not a CompiledMethod") }
        let mc = om.load(meth, MethodLayout.methodClass)
        guard slots(mc, ClassLayout.size), om.isBehavior(mc), om.load(mc, ClassLayout.classIndex).isSmallInteger else {
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
    try verifySavedProcesses(om, special: special, nilObj: nilObj, trueObj: om.load(special, SpecialObjects.trueObject),
                             methods: methods, heap: processObjects, limits: limits)
}

extension Image {
    /// An Image over a verified object memory: the well-known objects from
    /// the special-objects Array, the host tables from the classes and
    /// their method dictionaries.
    convenience init(restoring om: ObjectMemory, special: Oop, limits: LoaderLimits) throws(ImageError) {
        try self.init(memory: om, limits: limits, restoring: special)
    }
}
