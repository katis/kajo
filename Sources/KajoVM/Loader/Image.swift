/// A booted object memory with its well-known objects, and the host-side
/// tables the loader keeps: class names and the methods of each class.
/// Symbols live in the heap (the symbol table), so names are read from the
/// heap and an image restored from a snapshot needs no host table. Cold
/// code; nothing here runs on the interpreter's hot path.
///
/// Every object the image creates is reachable from the class table or a
/// root before the next allocation, so a collection may run at any
/// allocation (the stress flag `collectAtEveryAllocation` checks it).
package final class Image {
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
    /// Boot: the special selectors held until the special objects hold them.
    private var selectorRoots: [RootHandle] = []
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
        selectorRoots.append(om.addRoot(doesNotUnderstand))
        globals = try allocate(WellKnown.array, slots: Image.globalCount)
        om.addRoot(globals)
        specialObjects = try allocate(WellKnown.array, slots: SpecialObjects.size)
        om.addRoot(specialObjects)
        let sel = try allocate(WellKnown.array, slots: specialSelectors.count, roots: [specialObjects])
        for (i, s) in specialSelectors.enumerated() { om.store(sel, i, s) }
        for h in selectorRoots { om.removeRoot(h) }
        selectorRoots = []
        for (i, v) in [nilObject, trueObject, falseObject, globals, symbolTable, sel, doesNotUnderstand].enumerated() {
            om.store(specialObjects, i, v)
        }
    }

    /// An image restored from a verified snapshot (`Image.load(image:)`):
    /// the well-known objects from the special-objects Array, the host
    /// tables rebuilt from the class table and the method dictionaries.
    init(memory: ObjectMemory, limits: LoaderLimits, restoring special: Oop) throws(ImageError) {
        om = memory
        self.limits = limits
        pinsForGood = true
        context = memory.makeContext()
        specialObjects = special
        nilObject = om.load(special, SpecialObjects.nilObject)
        trueObject = om.load(special, SpecialObjects.trueObject)
        falseObject = om.load(special, SpecialObjects.falseObject)
        globals = om.load(special, SpecialObjects.globals)
        symbolTable = om.load(special, SpecialObjects.symbolTable)
        doesNotUnderstand = om.load(special, SpecialObjects.doesNotUnderstand)
        let sels = om.load(special, SpecialObjects.selectors)
        specialSelectors = (0..<Int(om.count(of: sels))).map { om.load(sels, $0) }
        for i in 1..<UInt64(om.classCount) {
            let c = om.classOop(i)
            instSizes[i] = om.classFormat(i).namedSlots
            if om.classIndex(of: c) != WellKnown.metaclass, let n = symbolName(om.load(c, ClassLayout.name)) {
                classesByName[n] = i
            }
            let d = om.load(c, ClassLayout.methodDict)
            if d == nilObject { continue }
            for k in 0..<Int(om.count(of: d) / 2) {
                let key = om.load(d, 2 * k)
                if key == nilObject { continue }
                methods[i, default: []].append((key, om.load(d, 2 * k + 1)))
                if let n = symbolName(key) { methodKeys.insert("\(i) \(n)") }
            }
        }
    }

    /// Module 8b: the table is weak, so each Symbol is rooted until the
    /// special-objects Array holds it.
    private func specialSelectorsInOrder() throws(LoadError) -> [Oop] {
        var r: [Oop] = []
        for s in specialSelectorNames + VMSelector.names {
            let sym = try intern(s)
            selectorRoots.append(om.addRoot(sym))
            r.append(sym)
        }
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
        let nb = try allocate(WellKnown.weakArray, slots: size, roots: [s, old])
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
                temporaryRoots.append(om.addRoot(sel))  // the table is weak
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
        case .byteArray(let b): return try readOnlyBytes(WellKnown.byteArray, b)
        case .array(let elements):
            // Elements first, each held by a root until the Array holds it.
            var handles: [RootHandle] = []
            defer { for h in handles { om.removeRoot(h) } }
            var values: [Oop] = []
            for e in elements {
                let v = try literalValue(e)
                if v.isObject { handles.append(om.addRoot(v)) }
                values.append(v)
            }
            let a = try allocatePinned(WellKnown.array, slots: values.count)
            for (i, v) in values.enumerated() { om.store(a, i, v) }
            om.setReadOnly(a, true)
            return a
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
    static let names = ["modificationForbiddenAt:value:", "cannotReturn:", "aboutToReturn:through:"]
    static let modificationForbidden = specialSelectorNames.count
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
    /// Module 8b: the object `kajo run` and `kajo test` start at (nil in a
    /// kasm image).
    static let entryPoint = 7
    /// Module 8c: the saved scheduler state (`SavedScheduler`) of an image
    /// with saved Processes, nil otherwise (and once a VM resumed them).
    static let scheduler = 8
    static let size = 9
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

// MARK: - module 8b: the kernel image build

/// A class of the kernel as the bootstrap compiler read it from its Tonel
/// file: the instance size includes the inherited slots.
package struct KernelClassDefinition: Sendable {
    package let name: String
    /// nil only for Object.
    package let superclass: String?
    package let instSize: Int
    /// `fixed`, `variable`, `bytes`, `words16`, `words32`, `words64`,
    /// `weak` or `ephemeron`.
    package let kind: String
    /// Class-side instance variables, inherited included.
    package let metaSlots: Int
    package let file: String
    package let line: Int

    package init(name: String, superclass: String?, instSize: Int, kind: String, metaSlots: Int, file: String, line: Int) {
        self.name = name
        self.superclass = superclass
        self.instSize = instSize
        self.kind = kind
        self.metaSlots = metaSlots
        self.file = file
        self.line = line
    }

    var format: ClassFormat? {
        switch kind {
        case "fixed": ClassFormat(namedSlots: instSize, kind: .fixed)
        case "variable": ClassFormat(namedSlots: instSize, kind: .variable)
        case "bytes": instSize == 0 ? ClassFormat(namedSlots: 0, kind: .bytes) : nil
        case "words16": instSize == 0 ? ClassFormat(namedSlots: 0, kind: .words16) : nil
        case "words32": instSize == 0 ? ClassFormat(namedSlots: 0, kind: .words32) : nil
        case "words64": instSize == 0 ? ClassFormat(namedSlots: 0, kind: .words64) : nil
        case "weak": ClassFormat(namedSlots: instSize, kind: .variable, weak: true)
        case "ephemeron": instSize >= 1 ? ClassFormat(namedSlots: instSize, kind: .fixed, ephemeron: true) : nil
        default: nil
        }
    }
}

extension Image {
    /// The number of slots of a class object before its class-side
    /// instance variables.
    package static let classLayoutSize = ClassLayout.size

    /// A fresh image for the kernel build: the well-known classes and
    /// nothing else, in an object memory of `heapMiB`.
    package static func bootForKernel(heapMiB: Int = 512) throws(LoadError) -> Image {
        var config = ObjectMemoryConfig()
        config.heapBytes = heapMiB << 20
        let om: ObjectMemory
        do { om = try ObjectMemory(config) } catch { throw LoadError(.heapFull, "the object memory: \(error)") }
        return try Image(memory: om)
    }

    /// The well-known classes by name, with their instance size and format
    /// kind (the kernel's class files must agree with them).
    package static var wellKnownClasses: [(name: String, instSize: Int, kind: String)] {
        WellKnown.definitions.map { d in
            let f = d.format
            let kinds: [ClassFormat.Kind: String] = [.fixed: "fixed", .variable: "variable", .bytes: "bytes", .words16: "words16",
                                                     .words32: "words32", .words64: "words64"]
            let k = f.isWeak ? "weak" : f.isEphemeron ? "ephemeron" : kinds[f.kind]!
            return (d.name, f.namedSlots, k)
        }
    }

    /// Define the kernel's classes, superclasses first. A well-known class
    /// keeps its index, format and metaclass and takes the superclass its
    /// file names (SmallInteger under Integer, String under
    /// ArrayedCollection); every other class gets two new indices. Checked
    /// as the kasm loader checks classes: no subclass of a sealed class
    /// other than the well-known ones, no pointers under bytes, at least
    /// the superclass's instance variables on both sides, no duplicate.
    package func defineKernelClasses(_ defs: [KernelClassDefinition]) throws(LoadError) {
        var seen = Set<String>()
        for d in defs {
            func fail(_ m: String) -> LoadError { LoadError(.badClass, m, file: d.file, line: d.line) }
            if !seen.insert(d.name).inserted { throw LoadError(.duplicateClass, "class \(d.name) defined twice", file: d.file, line: d.line) }
            guard let format = d.format else { throw fail("\(d.name): format \(d.kind) with \(d.instSize) named slots") }
            var sup: UInt64? = nil
            if let s = d.superclass {
                guard let si = classesByName[s], seen.contains(s) || WellKnown.definitions.contains(where: { $0.name == s }) else {
                    throw LoadError(.unknownClass, "\(d.name): superclass \(s) not defined before it", file: d.file, line: d.line)
                }
                sup = si
                if (instSizes[si] ?? 0) > d.instSize { throw fail("\(d.name) has fewer instance variables than \(s)") }
                if (instSizes[metaclassIndex(of: si)] ?? 0) > ClassLayout.size + d.metaSlots {
                    throw fail("\(d.name) has fewer class-side instance variables than \(s)")
                }
            } else if d.name != "Object" {
                throw fail("only Object has no superclass")
            }
            if let wk = WellKnown.definitions.first(where: { $0.name == d.name }) {
                let f = wk.format
                guard f.namedSlots == format.namedSlots, f.kind == format.kind, f.isWeak == format.isWeak,
                      f.isEphemeron == format.isEphemeron else {
                    throw fail("\(d.name) is well known with \(f.namedSlots) named slots of kind \(f.kind), its file says \(d.instSize) \(d.kind)")
                }
                guard d.metaSlots == 0 else { throw fail("\(d.name) is well known: no class-side instance variables") }
                guard (d.superclass == nil) == (wk.superclass == nil) else { throw fail("\(d.name)'s superclass") }
                if let si = sup {
                    // A cycle through a well-known class is refused here: the
                    // superclass must not have this class in its chain.
                    var s = si, steps = om.classCount
                    while steps > 0 {
                        if s == wk.index { throw fail("superclass cycle through \(d.name)") }
                        let o = om.load(om.classOop(s), ClassLayout.superclass)
                        if o == nilObject { break }
                        s = UInt64(om.load(o, ClassLayout.classIndex).smallIntegerValue)
                        steps -= 1
                    }
                    om.store(om.classOop(wk.index), ClassLayout.superclass, om.classOop(si))
                    om.store(om.classOop(WellKnown.metaclass(of: wk.index)), ClassLayout.superclass, om.classOop(metaclassIndex(of: si)))
                }
                continue
            }
            guard let si = sup else { throw fail("only Object has no superclass") }
            let sf = om.classFormat(si)
            if sf.isSealed { throw fail("\(d.name) cannot subclass the sealed \(d.superclass!)") }
            if !sf.kind.isPointers && format.kind.isPointers { throw fail("\(d.name) cannot be pointers under \(d.superclass!)") }
            if UInt64(om.classCount) + 2 > UInt64(limits.maxClassIndex) {
                throw LoadError(.tooManyClasses, "more than \(limits.maxClassIndex) classes", file: d.file, line: d.line)
            }
            let index = om.registerClass(.none)
            let meta = om.registerClass(.none)
            om.setClassFormat(meta, WellKnown.metaclassFormat(classSlots: ClassLayout.size + d.metaSlots))
            om.setClassOop(meta, try allocatePinned(WellKnown.metaclass, slots: MetaclassLayout.size))
            om.setClassOop(index, try allocatePinned(meta, slots: ClassLayout.size + d.metaSlots))
            try fillClass(index, meta: meta, name: d.name, superclass: si, format: format, metaSlots: d.metaSlots)
        }
        loads += 1
    }

    /// Install compiled methods (the bootstrap compiler's, verified by the
    /// assembler): the instance-variable rules and duplicate checks of the
    /// kasm loader, then the methods and new method dictionaries.
    package func installKernelMethods(_ ms: [AssembledMethod]) throws(LoadError) {
        var keys = methodKeys
        var counts: [UInt64: Int] = methods.mapValues(\.count)
        var planned: [(UInt64, AssembledMethod)] = []
        for m in ms {
            guard var cls = classesByName[m.className] else {
                throw LoadError(.unknownClass, "unknown class \(m.className)", file: m.file, line: m.line)
            }
            if m.classSide { cls = metaclassIndex(of: cls) }
            if m.maxIvar >= 0 {
                let f = om.classFormat(cls)
                let isMeta = m.classSide || f.instancesAreBehaviors
                let lowest = isMeta ? ClassLayout.size : 0
                let allowed = f.isSealed && !isMeta ? false : m.minIvar >= lowest
                if !allowed || m.maxIvar >= f.namedSlots {
                    throw LoadError(.badClass, "\(m.className)>>\(m.selector) names instance variable \(m.maxIvar), outside the class",
                                    file: m.file, line: m.line)
                }
            }
            func classRefs(_ l: Literal) -> [String] {
                switch l {
                case .classRef(let c): return [c]
                case .array(let xs): return xs.flatMap(classRefs)
                default: return []
                }
            }
            for c in (m.literals + m.blocks.flatMap(\.literals) + m.pragmas.flatMap(\.arguments)).flatMap(classRefs)
                where classesByName[c] == nil {
                throw LoadError(.unknownClass, "unknown class \(c)", file: m.file, line: m.line)
            }
            if !keys.insert("\(cls) \(m.selector)").inserted {
                throw LoadError(.duplicateMethod, "\(m.className)\(m.classSide ? " class" : "")>>\(m.selector) defined twice",
                                file: m.file, line: m.line)
            }
            counts[cls, default: 0] += 1
            if counts[cls]! > limits.maxMethodsPerClass {
                throw LoadError(.tooManyMethods, "\(m.className) has more than \(limits.maxMethodsPerClass) methods", file: m.file, line: m.line)
            }
            planned.append((cls, m))
        }
        var temporaryRoots: [RootHandle] = []
        defer { for h in temporaryRoots { om.removeRoot(h) } }
        var touched: [UInt64] = []
        for (cls, m) in planned {
            let sel = try intern(m.selector)
            temporaryRoots.append(om.addRoot(sel))  // the table is weak
            let meth = try makeMethod(m, selector: sel, methodClass: om.classOop(cls))
            temporaryRoots.append(om.addRoot(meth))
            methods[cls, default: []].append((sel, meth))
            methodKeys.insert("\(cls) \(m.selector)")
            methodNames[meth] = "\(m.className)\(m.classSide ? " class" : "")>>\(m.selector)"
            if !touched.contains(cls) { touched.append(cls) }
        }
        for cls in touched.sorted() { try installMethodDictionary(cls) }
        loads += 1
    }

    /// Name the entry point: the class `kajo run` and `kajo test` send
    /// `run:of:`, `setup:` and `test:` to (special object 7).
    package func setEntryPoint(className: String) throws(LoadError) {
        guard let i = classesByName[className] else { throw LoadError(.unknownClass, "no class \(className) for the entry point") }
        om.store(specialObjects, SpecialObjects.entryPoint, om.classOop(i))
    }

    /// The entry point (special object 7), nil if none.
    var entryPoint: Oop { om.load(specialObjects, SpecialObjects.entryPoint) }

    /// Module 8c: the saved scheduler state (special object 8), nil when the
    /// image holds no saved Process (or a VM has resumed them).
    var savedScheduler: Oop {
        om.count(of: specialObjects) > UInt64(SpecialObjects.scheduler) ? om.load(specialObjects, SpecialObjects.scheduler) : nilObject
    }

    /// Whether the image carries saved Processes to resume.
    package var hasSavedProcesses: Bool { savedScheduler != nilObject }

    /// The image as bytes (module 8a's format).
    package func imageBytes() -> [UInt8] { saveImage() }

    /// Whether `name` is a class of the image.
    package func hasClass(_ name: String) -> Bool { classesByName[name] != nil }

    package func destroyImage() { destroy() }
}
