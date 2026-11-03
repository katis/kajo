/// A booted object memory with its well-known objects, and the host-side
/// tables the loader keeps: class names and the methods of each class.
/// Symbols live in the heap (the symbol table), so names are read from the
/// heap and an image restored from a snapshot needs no host table. Cold
/// code; nothing here runs on the interpreter's hot path.
///
/// Every object the image creates is reachable from the class table or a
/// root before the next allocation, so a collection may run at any
/// allocation (the stress flag `collectAtEveryAllocation` checks it).
final class Image {
    let om: ObjectMemory
    let limits: LoaderLimits
    let context: AllocContext
    /// Module 6: methods, bytecodes, literal Arrays, classes, symbols, nil,
    /// true and false are pinned for good. Only tests of module 2's
    /// re-derivation after a compaction build an image without, and a VM
    /// over such an image does not relocate.
    let pinsForGood: Bool
    private(set) var nilObject = Oop.none
    private(set) var trueObject = Oop.none
    private(set) var falseObject = Oop.none
    /// The special-send selectors in opcode order, then the selectors the VM
    /// sends itself (`VMSelector`).
    private(set) var specialSelectors: [Oop] = []
    private(set) var doesNotUnderstand = Oop.none
    /// An Array of `globalCount` slots for `globalAt:` and `globalAt:put:`.
    private(set) var globals = Oop.none
    /// Module 8: the symbol table (`SymbolTable`), an Array of buckets.
    private(set) var symbolTable = Oop.none
    /// Module 8: the Array of the objects above (`SpecialObjects`), root 0:
    /// what an image snapshot names to the loader.
    private(set) var specialObjects = Oop.none

    static let globalCount = 64

    private var classesByName: [String: UInt64] = [:]
    private var instSizes: [UInt64: Int] = [:]
    /// Selector and method oops per class, in source order. Kept alive by
    /// the class's method dictionary.
    private var methods: [UInt64: [(selector: Oop, method: Oop)]] = [:]
    private var methodKeys: Set<String> = []
    private var methodNames: [Oop: String] = [:]
    /// Loads so far; an interpreter flushes its lookup cache when it changes.
    private(set) var loads = 0

    /// Boot: nil, true, false, the well-known classes and their metaclasses,
    /// the symbol table, the special selectors, the globals, the special
    /// objects (SPEC-SHARED "Boot / allocation order", steps 1 to 3, with
    /// module 8's metaclasses).
    init(memory: ObjectMemory, limits: LoaderLimits = LoaderLimits(), pinsForGood: Bool = true) throws(LoadError) {
        om = memory
        self.limits = limits
        self.pinsForGood = pinsForGood
        context = memory.makeContext()
        for _ in 0..<(2 * WellKnown.count) { om.registerClass(.none) }
        nilObject = try allocatePinned(WellKnown.undefinedObject, slots: 0, fill: Oop(smallInteger: 0))
        om.addRoot(nilObject)
        om.nilObject = nilObject
        trueObject = try allocatePinned(WellKnown.trueClass, slots: 0)
        om.addRoot(trueObject)
        falseObject = try allocatePinned(WellKnown.falseClass, slots: 0)
        om.addRoot(falseObject)
        symbolTable = try allocate(WellKnown.array, slots: SymbolTable.buckets)
        om.addRoot(symbolTable)
        for d in WellKnown.definitions {
            om.setClassFormat(d.index, d.format)
            om.setClassFormat(WellKnown.metaclass(of: d.index), WellKnown.metaclassFormat(classSlots: ClassLayout.size))
            om.setClassOop(WellKnown.metaclass(of: d.index), try allocatePinned(WellKnown.metaclass, slots: MetaclassLayout.size))
            om.setClassOop(d.index, try allocatePinned(WellKnown.metaclass(of: d.index), slots: ClassLayout.size))
            classesByName[d.name] = d.index
        }
        for d in WellKnown.definitions {
            try fillClass(d.index, meta: WellKnown.metaclass(of: d.index), name: d.name,
                          superclass: d.superclass.map { classesByName[$0]! }, format: d.format, metaSlots: 0)
        }
        specialSelectors = try specialSelectorsInOrder()
        doesNotUnderstand = try intern("doesNotUnderstand:")
        globals = try allocate(WellKnown.array, slots: Image.globalCount)
        om.addRoot(globals)
        specialObjects = try allocate(WellKnown.array, slots: SpecialObjects.size)
        om.addRoot(specialObjects)
        let sel = try allocate(WellKnown.array, slots: specialSelectors.count, roots: [specialObjects])
        for (i, s) in specialSelectors.enumerated() { om.store(sel, i, s) }
        for (i, v) in [nilObject, trueObject, falseObject, globals, symbolTable, sel, doesNotUnderstand].enumerated() {
            om.store(specialObjects, i, v)
        }
    }

    private func specialSelectorsInOrder() throws(LoadError) -> [Oop] {
        var r: [Oop] = []
        for s in specialSelectorNames + VMSelector.names { r.append(try intern(s)) }
        return r
    }

    /// Release the object memory.
    func destroy() { om.destroy() }

    // MARK: - queries

    /// The Symbol with this name, if it was interned.
    func symbol(_ name: String) -> Oop? {
        let b = Array(name.utf8)
        let s = om.symbolLookup(symbolTable, hash: utf8Hash(b)) { om.sameBytes($0, b) }
        return s == .none ? nil : s
    }

    /// A Symbol's (or String's) text, read from the heap.
    func symbolName(_ s: Oop) -> String? {
        guard s.isObject, om.isUsedReference(s), om.isBytes(s) else { return nil }
        let c = om.classIndex(of: s)
        guard c == WellKnown.symbol || c == WellKnown.string else { return nil }
        return String(decoding: om.bytes(of: s), as: UTF8.self)
    }

    func classIndex(named name: String) -> UInt64? { classesByName[name] }

    /// A class's name from its class object (`Foo class` for a metaclass).
    func className(_ index: UInt64) -> String? {
        guard index > 0, index < UInt64(om.classCount) else { return nil }
        let c = om.classOop(index)
        guard c.isObject else { return nil }
        if om.classIndex(of: c) == WellKnown.metaclass {
            let this = om.load(c, MetaclassLayout.thisClass)
            guard this.isObject, let n = symbolName(om.load(this, ClassLayout.name)) else { return nil }
            return n + " class"
        }
        return symbolName(om.load(c, ClassLayout.name))
    }

    /// `Class>>selector` of a loaded method (`Class>>selector[block]` for a
    /// block method).
    func methodName(_ method: Oop) -> String? {
        if let n = methodNames[method] { return n }
        guard method.isObject, om.isUsedReference(method), om.classIndex(of: method) == WellKnown.method else { return nil }
        let cls = om.load(method, MethodLayout.methodClass)
        guard cls.isObject, let ci = Optional(om.load(cls, ClassLayout.classIndex)), ci.isSmallInteger,
              let cn = className(UInt64(ci.smallIntegerValue)) else { return nil }
        return "\(cn)>>\(symbolName(om.load(method, MethodLayout.selector)) ?? "[]")"
    }

    /// The method `selector` finds from instances of class `index`, through
    /// the superclass chain; nil when there is none.
    func lookup(_ index: UInt64, _ selector: Oop) -> Oop? {
        let m = lookupMethod(om, nilObject: nilObject, classIndex: index, selector: selector)
        return m == .none ? nil : m
    }

    /// The metaclass index of class `index`.
    func metaclassIndex(of index: UInt64) -> UInt64 { om.classIndex(of: om.classOop(index)) }

    // MARK: - allocation

    private func allocate(_ cls: UInt64, slots: Int, fill: Oop? = nil, roots: [Oop] = []) throws(LoadError) -> Oop {
        guard let o = om.allocate(context, classIndex: cls, slots: slots, fill: fill ?? nilObject, extraRoots: roots) else {
            throw LoadError(.heapFull, "the heap has no room for the image")
        }
        return o
    }

    /// Module 6: an object pinned for good (header bit 60): never moved by
    /// a relocation or a compaction. Every method, its bytecodes and its
    /// literal Array (the interpreter caches raw pointers into the last
    /// two), every class, every symbol, nil, true and false. The image is
    /// built before any VM exists, so the header write races nothing.
    private func allocatePinned(_ cls: UInt64, slots: Int, fill: Oop? = nil, roots: [Oop] = []) throws(LoadError) -> Oop {
        let o = try allocate(cls, slots: slots, fill: fill, roots: roots)
        if pinsForGood { om.pinForGood(o) }
        return o
    }

    private func allocateBytes(_ cls: UInt64 = WellKnown.byteArray, _ bytes: [UInt8], roots: [Oop]) throws(LoadError) -> Oop {
        guard let o = om.allocateBytes(context, classIndex: cls, count: bytes.count, extraRoots: roots) else {
            throw LoadError(.heapFull, "the heap has no room for the image")
        }
        for (i, b) in bytes.enumerated() { om.storeByte(o, i, b) }
        return o
    }

    /// A Symbol: UTF-8 bytes, pinned, read-only, in the symbol table (a
    /// root), found by its bytes.
    @discardableResult
    func intern(_ name: String) throws(LoadError) -> Oop {
        let b = Array(name.utf8)
        let h = utf8Hash(b)
        let found = om.symbolLookup(symbolTable, hash: h) { om.sameBytes($0, b) }
        if found != .none { return found }
        let s = try allocateBytes(WellKnown.symbol, b, roots: [])
        if pinsForGood { om.pinForGood(s) }
        om.setReadOnly(s, true)
        try insertSymbol(s, hash: h)
        return s
    }

    /// Put a new Symbol into its bucket, replacing a full bucket by a larger
    /// one (the host before any VM; `primIntern` does the same in a stop).
    private func insertSymbol(_ s: Oop, hash h: Int64) throws(LoadError) {
        let j = Int(truncatingIfNeeded: h) & (SymbolTable.buckets - 1)
        if let (b, i) = om.symbolSlot(symbolTable, hash: h) {
            om.store(b, i, s)
            return
        }
        let old = om.load(symbolTable, j)
        let n = old == nilObject ? 0 : Int(om.count(of: old))
        guard let size = SymbolTable.grownBucketSize(n) else { throw LoadError(.heapFull, "a symbol table bucket is full") }
        let nb = try allocate(WellKnown.array, slots: size, roots: [s, old])
        for i in 0..<n { om.store(nb, i, om.load(old, i)) }
        om.store(nb, n, s)
        om.store(symbolTable, j, nb)
    }

    /// Fill a class object and its metaclass object (both allocated).
    private func fillClass(_ index: UInt64, meta: UInt64, name: String, superclass: UInt64?, format: ClassFormat,
                           metaSlots: Int) throws(LoadError) {
        om.setClassFormat(index, format)
        om.setClassFormat(meta, WellKnown.metaclassFormat(classSlots: ClassLayout.size + metaSlots))
        let nameSym = try intern(name)
        let c = om.classOop(index), mc = om.classOop(meta)
        om.store(c, ClassLayout.superclass, superclass.map { om.classOop($0) } ?? nilObject)
        om.store(c, ClassLayout.methodDict, nilObject)
        om.store(c, ClassLayout.name, nameSym)
        om.store(c, ClassLayout.instSize, Oop(smallInteger: Int64(format.namedSlots)))
        om.store(c, ClassLayout.classIndex, Oop(smallInteger: Int64(index)))
        // `Foo class superclass` is `Foo superclass class`; `Object class
        // superclass` is Class.
        let metaSuper = superclass.map { om.classOop(metaclassIndex(of: $0)) } ?? om.classOop(WellKnown.classClass)
        om.store(mc, ClassLayout.superclass, metaSuper)
        om.store(mc, ClassLayout.methodDict, nilObject)
        om.store(mc, ClassLayout.name, nilObject)
        om.store(mc, ClassLayout.instSize, Oop(smallInteger: Int64(ClassLayout.size + metaSlots)))
        om.store(mc, ClassLayout.classIndex, Oop(smallInteger: Int64(meta)))
        om.store(mc, MetaclassLayout.thisClass, c)
        classesByName[name] = index
        instSizes[index] = format.namedSlots
        instSizes[meta] = ClassLayout.size + metaSlots
    }

    // MARK: - loading

    /// Load kasm files in order (SPEC-SHARED "Boot / allocation order",
    /// steps 4 and 5). Everything is parsed, assembled and checked before
    /// the heap changes, so a rejected load leaves the image as it was;
    /// only `heapFull` can stop a load part way.
    func load(_ files: [(file: String, text: String)]) throws(LoadError) {
        let plan = try check(files)
        var temporaryRoots: [RootHandle] = []
        defer { for h in temporaryRoots { om.removeRoot(h) } }
        var touched: [UInt64] = []
        for f in plan {
            for (k, c) in f.classes.enumerated() {
                let index = om.registerClass(.none)
                let meta = om.registerClass(.none)
                precondition(index == f.firstIndex + 2 * UInt64(k) && meta == index + 1)
                om.setClassFormat(meta, WellKnown.metaclassFormat(classSlots: ClassLayout.size + c.metaSlots))
                om.setClassOop(meta, try allocatePinned(WellKnown.metaclass, slots: MetaclassLayout.size))
                om.setClassOop(index, try allocatePinned(meta, slots: ClassLayout.size + c.metaSlots))
                classesByName[c.name] = index
            }
            for c in f.classes {
                let index = classesByName[c.name]!
                try fillClass(index, meta: index + 1, name: c.name, superclass: classesByName[c.superclass]!, format: c.format,
                              metaSlots: c.metaSlots)
            }
            for m in f.methods {
                var cls = classesByName[m.className]!
                if m.classSide { cls = metaclassIndex(of: cls) }
                let sel = try intern(m.selector)
                let meth = try makeMethod(m, selector: sel, methodClass: om.classOop(cls))
                temporaryRoots.append(om.addRoot(meth))
                methods[cls, default: []].append((sel, meth))
                methodKeys.insert("\(cls) \(m.selector)")
                methodNames[meth] = "\(m.className)\(m.classSide ? " class" : "")>>\(m.selector)"
                if !touched.contains(cls) { touched.append(cls) }
            }
        }
        for cls in touched.sorted() { try installMethodDictionary(cls) }
        loads += 1
    }

    /// A Method (and its blocks, literals and pragmas) in the heap: pinned
    /// for good, its literals read-only. The new objects are kept reachable
    /// through a temporary root until the method holds them.
    private func makeMethod(_ m: AssembledMethod, selector: Oop, methodClass: Oop) throws(LoadError) -> Oop {
        var made: [Int: Oop] = [:]
        var handles: [RootHandle] = []
        defer { for h in handles { om.removeRoot(h) } }
        func keep(_ o: Oop) { handles.append(om.addRoot(o)) }
        func build(_ a: AssembledMethod, selector: Oop) throws(LoadError) -> Oop {
            var lits: [Oop] = []
            for l in a.literals {
                let v: Oop
                switch l {
                case .block(let k):
                    if let b = made[k] { v = b } else {
                        v = try build(m.blocks[k], selector: nilObject)
                        made[k] = v
                    }
                case .pragma: v = nilObject  // filled once the method exists
                default: v = try literalValue(l)
                }
                if v.isObject { keep(v) }
                lits.append(v)
            }
            for (k, l) in a.literals.enumerated() {
                if case .pragma(let p) = l {
                    let pr = m.pragmas[p]
                    let args = try allocate(WellKnown.array, slots: pr.arguments.count)
                    keep(args)
                    for (i, x) in pr.arguments.enumerated() {
                        let v = try literalValue(x)
                        om.store(args, i, v)
                    }
                    om.setReadOnly(args, true)
                    let po = try allocate(WellKnown.pragma, slots: PragmaLayout.size)
                    keep(po)
                    om.store(po, PragmaLayout.selector, try intern(pr.selector))
                    om.store(po, PragmaLayout.arguments, args)
                    lits[k] = po
                }
            }
            let bytes = try allocateBytes(WellKnown.byteArray, a.bytecodes, roots: [])
            if pinsForGood { om.pinForGood(bytes) }
            om.setReadOnly(bytes, true)
            keep(bytes)
            let litArray = try allocatePinned(WellKnown.array, slots: lits.count)
            for (i, v) in lits.enumerated() { om.store(litArray, i, v) }
            om.setReadOnly(litArray, true)
            keep(litArray)
            let meth = try allocatePinned(WellKnown.method, slots: MethodLayout.size)
            om.store(meth, MethodLayout.bytecodes, bytes)
            om.store(meth, MethodLayout.literals, litArray)
            om.store(meth, MethodLayout.argc, Oop(smallInteger: Int64(a.argc)))
            om.store(meth, MethodLayout.temps, Oop(smallInteger: Int64(a.temps)))
            om.store(meth, MethodLayout.maxStack, Oop(smallInteger: Int64(a.maxStack)))
            om.store(meth, MethodLayout.selector, selector)
            om.store(meth, MethodLayout.primitive, Oop(smallInteger: Int64(a.primitive)))
            om.store(meth, MethodLayout.flags, Oop(smallInteger: a.flags))
            om.store(meth, MethodLayout.methodClass, methodClass)
            om.store(meth, MethodLayout.copied, Oop(smallInteger: Int64(a.copied)))
            for v in lits where v.isObject && om.classIndex(of: v) == WellKnown.pragma {
                om.store(v, PragmaLayout.method, meth)
                om.setReadOnly(v, true)
            }
            if a.isBlock { methodNames[meth] = "\(a.className)\(a.classSide ? " class" : "")>>\(m.selector)[\(a.selector)]" }
            return meth
        }
        return try build(m, selector: selector)
    }

    /// A literal's object: immediates as they are, the rest allocated
    /// read-only (and pinned, so a literal never moves under a method).
    private func literalValue(_ l: Literal) throws(LoadError) -> Oop {
        switch l {
        case .integer(let v): return Oop(smallInteger: v)
        case .symbol(let s): return try intern(s)
        case .classRef(let c): return om.classOop(classesByName[c]!)
        case .nilObject: return nilObject
        case .trueObject: return trueObject
        case .falseObject: return falseObject
        case .character(let c): return Oop(character: c)
        case .float(let bits):
            if let f = Oop(smallFloat: Double(bitPattern: bits)) { return f }
            return try readOnlyBytes(WellKnown.float, (0..<8).map { UInt8(truncatingIfNeeded: bits >> (8 * UInt64($0))) })
        case .string(let b): return try readOnlyBytes(WellKnown.string, b)
        case .largeInteger(let negative, let mag):
            return try readOnlyBytes(negative ? WellKnown.largeNegativeInteger : WellKnown.largePositiveInteger, mag)
        case .block, .pragma: preconditionFailure("made by makeMethod")
        }
    }

    private func readOnlyBytes(_ cls: UInt64, _ b: [UInt8]) throws(LoadError) -> Oop {
        let o = try allocateBytes(cls, b, roots: [])
        if pinsForGood { om.pinForGood(o) }
        om.setReadOnly(o, true)
        return o
    }

    private func installMethodDictionary(_ cls: UInt64) throws(LoadError) {
        let entries = methods[cls] ?? []
        let cap = MethodDictionary.capacity(for: entries.count)
        let d = try allocate(WellKnown.methodDict, slots: 2 * cap)
        for (sel, meth) in entries {
            var i = MethodDictionary.hash(sel) & (cap - 1)
            while om.load(d, 2 * i) != nilObject { i = (i + 1) & (cap - 1) }
            om.store(d, 2 * i, sel)
            om.store(d, 2 * i + 1, meth)
        }
        om.store(om.classOop(cls), ClassLayout.methodDict, d)
    }

    // MARK: - checking (no heap changes)

    private struct PlannedFile {
        var firstIndex: UInt64
        var classes: [KasmClass]
        var methods: [AssembledMethod]
    }

    private func check(_ files: [(file: String, text: String)]) throws(LoadError) -> [PlannedFile] {
        var plan: [PlannedFile] = []
        var next = UInt64(om.classCount)
        var known = classesByName                  // name -> index, existing and planned
        var sizes = instSizes
        var sealed = Set<UInt64>((1..<UInt64(om.classCount)).filter { om.isSealed($0) })
        var metaOf: [UInt64: UInt64] = [:]
        func meta(_ i: UInt64) -> UInt64 { metaOf[i] ?? metaclassIndex(of: i) }
        var keys = methodKeys
        var counts: [UInt64: Int] = methods.mapValues(\.count)
        for (file, text) in files {
            let parsed = try parseKasm(text, file: file, limits: limits)
            var pf = PlannedFile(firstIndex: next, classes: parsed.classes, methods: [])
            // classes: names first, so superclasses may come later in the file
            for c in parsed.classes {
                if known[c.name] != nil { throw LoadError(.duplicateClass, "class \(c.name) already exists", file: file, line: c.line) }
                if next + 1 > UInt64(limits.maxClassIndex) {
                    throw LoadError(.tooManyClasses, "more than \(limits.maxClassIndex) classes", file: file, line: c.line)
                }
                known[c.name] = next
                sizes[next] = c.instSize
                sizes[next + 1] = ClassLayout.size + c.metaSlots
                metaOf[next] = next + 1
                sealed.insert(next + 1)
                next += 2
            }
            for c in parsed.classes {
                guard let sup = known[c.superclass] else {
                    throw LoadError(.unknownClass, "unknown superclass \(c.superclass)", file: file, line: c.line)
                }
                if sizes[sup]! > c.instSize {
                    throw LoadError(.badClass, "\(c.name) has fewer instance variables than \(c.superclass)", file: file, line: c.line)
                }
                if sizes[meta(sup)]! > ClassLayout.size + c.metaSlots {
                    throw LoadError(.badClass, "\(c.name) has fewer class-side instance variables than \(c.superclass)",
                                    file: file, line: c.line)
                }
                let sf = sup < UInt64(om.classCount) ? om.classFormat(sup) : nil
                if let sf, sf.isSealed || !sf.kind.isPointers && c.kind.isPointers {
                    throw LoadError(.badClass, "\(c.name) cannot subclass \(c.superclass)", file: file, line: c.line)
                }
                // a chain through this file's classes must reach an existing class
                var name = c.superclass, steps = 0
                while let s = parsed.classes.first(where: { $0.name == name }) {
                    steps += 1
                    if s.name == c.name || steps > parsed.classes.count {
                        throw LoadError(.badClass, "superclass cycle through \(c.name)", file: file, line: c.line)
                    }
                    name = s.superclass
                }
            }
            for pm in parsed.methods {
                let m = try assemble(pm, limits: limits)
                guard var cls = known[m.className] else {
                    throw LoadError(.unknownClass, "unknown class \(m.className)", file: file, line: m.line)
                }
                if m.classSide { cls = meta(cls) }
                if m.maxIvar >= 0 {
                    // Sealed classes: no instance variable access, except a
                    // metaclass's class-side instance variables (past the
                    // class layout).
                    let isMeta = m.classSide || (cls < UInt64(om.classCount) && om.classFormat(cls).instancesAreBehaviors)
                    let lowest = isMeta ? ClassLayout.size : 0
                    let allowed = sealed.contains(cls) && !isMeta ? false : m.minIvar >= lowest
                    if !allowed || m.maxIvar >= sizes[cls]! {
                        throw LoadError(.badClass, "\(m.className)>>\(m.selector) names instance variable \(m.maxIvar), outside the class",
                                        file: file, line: m.line)
                    }
                }
                for case .classRef(let c) in m.literals + m.blocks.flatMap(\.literals) + m.pragmas.flatMap(\.arguments)
                    where known[c] == nil {
                    throw LoadError(.unknownClass, "unknown class \(c)", file: file, line: m.line)
                }
                if !keys.insert("\(cls) \(m.selector)").inserted {
                    throw LoadError(.duplicateMethod, "\(m.className)>>\(m.selector) defined twice", file: file, line: m.line)
                }
                counts[cls, default: 0] += 1
                if counts[cls]! > limits.maxMethodsPerClass {
                    throw LoadError(.tooManyMethods, "\(m.className) has more than \(limits.maxMethodsPerClass) methods",
                                    file: file, line: m.line)
                }
                pf.methods.append(m)
            }
            plan.append(pf)
        }
        return plan
    }
}

/// The selectors the VM sends itself, after the special-send selectors in
/// `Image.specialSelectors` (and the interpreter's `specialSelectors`).
enum VMSelector {
    static let names = ["attemptToModify:at:value:", "cannotReturn:", "aboutToReturn:through:"]
    static let attemptToModify = specialSelectorNames.count
    static let cannotReturn = specialSelectorNames.count + 1
    static let aboutToReturn = specialSelectorNames.count + 2
}

/// Slots of the special-objects Array (root 0 of an image).
enum SpecialObjects {
    static let nilObject = 0
    static let trueObject = 1
    static let falseObject = 2
    static let globals = 3
    static let symbolTable = 4
    static let selectors = 5
    static let doesNotUnderstand = 6
    static let size = 8
}

/// Lookup through the superclass chain's method dictionaries; `.none` when
/// no class in the chain has the selector. Cold: the lookup cache is in
/// front of it. The walk is bounded by the class count, so a cycle cannot
/// hang it.
func lookupMethod(_ om: ObjectMemory, nilObject: Oop, classIndex: UInt64, selector: Oop) -> Oop {
    var cls = om.classOop(classIndex)
    var steps = om.classCount
    while cls != nilObject && steps > 0 {
        let d = om.load(cls, ClassLayout.methodDict)
        if d != nilObject {
            let cap = Int(truncatingIfNeeded: om.count(of: d) &>> 1)
            var i = MethodDictionary.hash(selector) & (cap &- 1)
            var probes = cap
            while probes > 0 {
                let k = om.load(d, i &<< 1)
                if k == selector { return om.load(d, i &<< 1 &+ 1) }
                if k == nilObject { break }
                i = (i &+ 1) & (cap &- 1)
                probes &-= 1
            }
        }
        cls = om.load(cls, ClassLayout.superclass)
        steps &-= 1
    }
    return .none
}
