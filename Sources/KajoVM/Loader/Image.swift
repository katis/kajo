/// A booted object memory with its well-known objects, and the host-side
/// tables the loader keeps: symbol names, class names, the methods of each
/// class. Cold code; nothing here runs on the interpreter's hot path.
///
/// Every object the image creates is reachable from the class table or a
/// root before the next allocation, so a collection may run at any
/// allocation (the stress flag `collectAtEveryAllocation` checks it).
final class Image {
    let om: ObjectMemory
    let limits: LoaderLimits
    let context: AllocContext
    private(set) var nilObject = Oop.none
    private(set) var trueObject = Oop.none
    private(set) var falseObject = Oop.none
    /// `+ - * < > <= >= = ==`, in that order.
    private(set) var specialSelectors: [Oop] = []
    private(set) var doesNotUnderstand = Oop.none
    /// An Array of `globalCount` slots for `globalAt:` and `globalAt:put:`.
    private(set) var globals = Oop.none

    static let globalCount = 64

    private var symbols: [String: Oop] = [:]
    private var symbolNames: [Oop: String] = [:]
    private var classesByName: [String: UInt64] = [:]
    private var classNames: [UInt64: String] = [:]
    private var instSizes: [UInt64: Int] = [:]
    /// Selector and method oops per class, in source order. Kept alive by
    /// the class's method dictionary.
    private var methods: [UInt64: [(selector: Oop, method: Oop)]] = [:]
    private var methodKeys: Set<String> = []
    private var methodNames: [Oop: String] = [:]
    /// Loads so far; an interpreter flushes its lookup cache when it changes.
    private(set) var loads = 0

    /// Boot: nil, true, false, the well-known classes, the special selectors,
    /// the globals (SPEC-SHARED "Boot / allocation order", steps 1 to 3).
    init(memory: ObjectMemory, limits: LoaderLimits = LoaderLimits()) throws(LoadError) {
        om = memory
        self.limits = limits
        context = memory.makeContext()
        for _ in WellKnown.classes { om.registerClass(.none) }
        nilObject = try allocate(WellKnown.undefinedObject, slots: 0, fill: Oop(smallInteger: 0))
        om.addRoot(nilObject)
        trueObject = try allocate(WellKnown.trueClass, slots: 0)
        om.addRoot(trueObject)
        falseObject = try allocate(WellKnown.falseClass, slots: 0)
        om.addRoot(falseObject)
        for (_, index) in WellKnown.classes {
            om.setClassOop(index, try allocate(WellKnown.classClass, slots: ClassLayout.size))
        }
        for (name, index) in WellKnown.classes {
            let sup = index == WellKnown.object ? nilObject : om.classOop(WellKnown.object)
            try fillClass(index, name: name, superclass: sup, instSize: WellKnown.instSize(index))
        }
        specialSelectors = try specialSelectorsInOrder()
        doesNotUnderstand = try intern("doesNotUnderstand:")
        globals = try allocate(WellKnown.array, slots: Image.globalCount)
        om.addRoot(globals)
    }

    private func specialSelectorsInOrder() throws(LoadError) -> [Oop] {
        var r: [Oop] = []
        for s in specialSelectorNames { r.append(try intern(s)) }
        return r
    }

    /// Release the object memory.
    func destroy() { om.destroy() }

    // MARK: - queries

    func symbol(_ name: String) -> Oop? { symbols[name] }
    func symbolName(_ s: Oop) -> String? { symbolNames[s] }
    func classIndex(named name: String) -> UInt64? { classesByName[name] }
    func className(_ index: UInt64) -> String? { classNames[index] }
    /// `Class>>selector` of a loaded method.
    func methodName(_ method: Oop) -> String? { methodNames[method] }

    /// The method `selector` finds from instances of class `index`, through
    /// the superclass chain; nil when there is none.
    func lookup(_ index: UInt64, _ selector: Oop) -> Oop? {
        let m = lookupMethod(om, nilObject: nilObject, classIndex: index, selector: selector)
        return m == .none ? nil : m
    }

    // MARK: - allocation

    private func allocate(_ cls: UInt64, slots: Int, fill: Oop? = nil, roots: [Oop] = []) throws(LoadError) -> Oop {
        guard let o = om.allocate(context, classIndex: cls, slots: slots, fill: fill ?? nilObject, extraRoots: roots) else {
            throw LoadError(.heapFull, "the heap has no room for the image")
        }
        return o
    }

    private func allocateBytes(_ count: Int, roots: [Oop]) throws(LoadError) -> Oop {
        guard let o = om.allocateBytes(context, classIndex: WellKnown.byteArray, count: count, extraRoots: roots) else {
            throw LoadError(.heapFull, "the heap has no room for the image")
        }
        return o
    }

    /// A Symbol (one slot: its id, in intern order), rooted for good.
    @discardableResult
    func intern(_ name: String) throws(LoadError) -> Oop {
        if let s = symbols[name] { return s }
        let s = try allocate(WellKnown.symbol, slots: 1)
        om.store(s, 0, Oop(smallInteger: Int64(symbols.count)))
        om.addRoot(s)
        symbols[name] = s
        symbolNames[s] = name
        return s
    }

    private func fillClass(_ index: UInt64, name: String, superclass: Oop, instSize: Int) throws(LoadError) {
        let nameSym = try intern(name)
        let c = om.classOop(index)
        om.store(c, ClassLayout.superclass, superclass)
        om.store(c, ClassLayout.methodDict, nilObject)
        om.store(c, ClassLayout.name, nameSym)
        om.store(c, ClassLayout.instSize, Oop(smallInteger: Int64(instSize)))
        om.store(c, ClassLayout.classIndex, Oop(smallInteger: Int64(index)))
        classesByName[name] = index
        classNames[index] = name
        instSizes[index] = instSize
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
                precondition(index == f.firstIndex + UInt64(k))
                om.setClassOop(index, try allocate(WellKnown.classClass, slots: ClassLayout.size))
                classesByName[c.name] = index
            }
            for c in f.classes {
                let sup = om.classOop(classesByName[c.superclass]!)
                try fillClass(classesByName[c.name]!, name: c.name, superclass: sup, instSize: c.instSize)
            }
            for m in f.methods {
                let cls = classesByName[m.className]!
                let sel = try intern(m.selector)
                for case .symbol(let s) in m.literals { try intern(s) }
                let bytes = try allocateBytes(m.bytecodes.count, roots: [])
                for (i, b) in m.bytecodes.enumerated() { om.storeByte(bytes, i, b) }
                let lits = try allocate(WellKnown.array, slots: m.literals.count, roots: [bytes])
                for (i, l) in m.literals.enumerated() { om.store(lits, i, literalValue(l)) }
                let meth = try allocate(WellKnown.method, slots: MethodLayout.size, roots: [bytes, lits])
                om.store(meth, MethodLayout.bytecodes, bytes)
                om.store(meth, MethodLayout.literals, lits)
                om.store(meth, MethodLayout.argc, Oop(smallInteger: Int64(m.argc)))
                om.store(meth, MethodLayout.temps, Oop(smallInteger: Int64(m.temps)))
                om.store(meth, MethodLayout.maxStack, Oop(smallInteger: Int64(m.maxStack)))
                om.store(meth, MethodLayout.selector, sel)
                om.store(meth, MethodLayout.primitive, Oop(smallInteger: Int64(m.primitive)))
                temporaryRoots.append(om.addRoot(meth))
                methods[cls, default: []].append((sel, meth))
                methodKeys.insert("\(cls) \(m.selector)")
                methodNames[meth] = "\(m.className)>>\(m.selector)"
                if !touched.contains(cls) { touched.append(cls) }
            }
        }
        for cls in touched.sorted() { try installMethodDictionary(cls) }
        loads += 1
    }

    private func literalValue(_ l: Literal) -> Oop {
        switch l {
        case .integer(let v): Oop(smallInteger: v)
        case .symbol(let s): symbols[s]!
        case .classRef(let c): om.classOop(classesByName[c]!)
        case .nilObject: nilObject
        case .trueObject: trueObject
        case .falseObject: falseObject
        }
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
        var keys = methodKeys
        var counts: [UInt64: Int] = methods.mapValues(\.count)
        for (file, text) in files {
            let parsed = try parseKasm(text, file: file, limits: limits)
            var pf = PlannedFile(firstIndex: next, classes: parsed.classes, methods: [])
            // classes: names first, so superclasses may come later in the file
            for c in parsed.classes {
                if known[c.name] != nil { throw LoadError(.duplicateClass, "class \(c.name) already exists", file: file, line: c.line) }
                if next > UInt64(limits.maxClassIndex) {
                    throw LoadError(.tooManyClasses, "more than \(limits.maxClassIndex) classes", file: file, line: c.line)
                }
                known[c.name] = next
                sizes[next] = c.instSize
                next += 1
            }
            for c in parsed.classes {
                guard let sup = known[c.superclass] else {
                    throw LoadError(.unknownClass, "unknown superclass \(c.superclass)", file: file, line: c.line)
                }
                if sizes[sup]! > c.instSize {
                    throw LoadError(.badClass, "\(c.name) has fewer instance variables than \(c.superclass)", file: file, line: c.line)
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
                guard let cls = known[m.className] else {
                    throw LoadError(.unknownClass, "unknown class \(m.className)", file: file, line: m.line)
                }
                if m.maxIvar >= 0 && (Image.isStructural(cls) || m.maxIvar >= sizes[cls]!) {
                    throw LoadError(.badClass, "\(m.className)>>\(m.selector) names instance variable \(m.maxIvar), outside the class",
                                    file: file, line: m.line)
                }
                for case .classRef(let c) in m.literals where known[c] == nil {
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

    /// Class, Method and MethodDict: the objects the interpreter trusts the
    /// shape of. No primitive reads, writes, creates or exchanges their
    /// instances, and no method of theirs touches an instance variable.
    static func isStructural(_ cls: UInt64) -> Bool {
        cls == WellKnown.classClass || cls == WellKnown.method || cls == WellKnown.methodDict
    }
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
