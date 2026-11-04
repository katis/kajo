import Darwin

// Module 8e: classes from Smalltalk.
//
//   145  Smalltalk primDefineClass: anArray: a new class and its metaclass
//        from a specification the kernel builds (below, `ClassSpec`), the
//        class answered, or a String saying why not
//   146  Smalltalk primRedefine: anArray: a live class's shape changed
//        (every instance of it and of its subclasses reshaped, every
//        method of theirs replaced by one made from the kernel's recompile)
//        and its class pool replaced; nil when done, a String when refused
//   147  Smalltalk primRemoveClass: aClass as: anObsoleteName: the class
//        unbound, renamed, emptied; nil, or a String
//   148  Smalltalk primWriteFile: aPath contents: aString
//   149  Smalltalk primReadFile: aPath
//
// Every one fails in a release image (the kernel signals InstallForbidden,
// as for 8d's primitives); 145 to 147 run in one stop of the world (the
// install stop of 8a and 8d: every other worker parked, every lookup cache
// flushed when its worker sees the stop) and re-check, with the image
// build's code (`ClassRules`), whatever the kernel already checked. The
// primitive is the trust boundary, not the kernel.
//
// The running-frame rule (146 and 147): a class is not reshaped, and not
// removed, while any frame of any Process runs one of its methods. The
// stop scans every word of every Process's stack (`[0, sp]`, as the
// collector's roots do) and the running registers for a CompiledMethod of
// a class the change touches; a hit refuses the change naming the Process
// and the method. A frame keeps its method in its header word, so the scan
// sees every frame; it also sees a method held in a temp or an operand,
// which it refuses as well (conservative). The reason: a frame runs its
// method's bytecodes with its receiver, and a reshaped receiver under old
// code reads the wrong slots or slots that are gone, and the methods a
// redefinition replaces are forwarded to their recompiled versions, which a
// frame's saved pc does not fit. A developer tries again once the Process
// has left the method.

enum LiveClassPrimitives {
    static let table: [(number: Int, selector: String, argc: Int)] = [
        (145, "Smalltalk primDefineClass:", 1), (146, "Smalltalk primRedefine:", 1),
        (147, "Smalltalk primRemoveClass:as:", 2), (148, "Smalltalk primWriteFile:contents:", 2),
        (149, "Smalltalk primReadFile:", 1), (163, "Smalltalk primFreeObsoleteClasses", 0),
    ]
}

@inline(never)
func liveClassPrimitive(_ n: Int, _ m: Machine, _ c: PrimitiveCall) -> Oop {
    guard !m.om.isReleaseImage else { return .none }
    switch n {
    case 145:
        guard c.argc == 1 else { return .none }
        return answer(m, inStop(m, keeping: [c.arg0]) { roots in defineClass(m, spec: c.arg0, roots: roots) }) { o in
            unsafe m.state.pointee.counters.classesDefined &+= 1
            return o
        }
    case 146:
        guard c.argc == 1 else { return .none }
        return answer(m, inStop(m, keeping: [c.arg0]) { roots in redefine(m, spec: c.arg0, roots: roots) }) { _ in
            unsafe m.state.pointee.counters.classesRedefined &+= 1
            return m.nilObject
        }
    case 147:
        guard c.argc == 2 else { return .none }
        return answer(m, inStop(m, keeping: [c.arg0, c.arg1]) { roots in removeClass(m, c.arg0, obsoleteName: c.arg1, roots: roots) }) { _ in
            unsafe m.state.pointee.counters.classesRemoved &+= 1
            return m.nilObject
        }
    case 148, 149: return filePrimitive(n, m, c)
    case 163:
        guard c.argc == 0 else { return .none }
        let freed = inStop(m, keeping: []) { roots in freeObsoleteClasses(m, roots: roots) }
        return Oop(smallInteger: Int64(freed))
    default: return .none
    }
}

/// A primitive's answer: the success's value, or the refusal as a String.
private func answer(_ m: Machine, _ r: Result<Oop, Refusal>, _ success: (Oop) -> Oop) -> Oop {
    switch r {
    case .success(let o): return success(o)
    case .failure(let why):
        unsafe m.state.pointee.counters.classChangesRefused &+= 1
        return m.newString(Array(why.message.utf8))
    }
}

struct Refusal: Error {
    let message: String
    init(_ m: String) { message = m }
}

/// Run `work` with every other worker parked (or, outside a VM, with this
/// interpreter's roots), then flush this worker's lookup cache: the others
/// flush theirs when they see the stop. `work` gets the roots a collection
/// in the stop must keep (every stack, the registers, the queues, what the
/// primitive holds).
private func inStop<T>(_ m: Machine, keeping: [Oop], _ work: (_ roots: () -> [Oop]) -> T) -> T {
    var out: T? = nil
    if let vm = unsafe workerOf(m.state).pointee.vm {
        unsafe stopWorld(vm, workerOf(m.state), retry: true, keeping: keeping) { stop in out = work { stop.roots() } }
        unsafe workerOf(m.state).pointee.seenEpoch = vm.pointee.safepoint.pointee.epoch
    } else {
        out = work { m.rootsForPause() + keeping }
    }
    m.flushCache()
    return unsafe out.unsafelyUnwrapped
}

// MARK: - reading what Smalltalk handed over

extension Machine {
    /// The text of a Symbol (or String).
    fileprivate func symbolText(_ o: Oop) -> String? {
        guard o.isObject, om.isBytes(o), classIndex(of: o) == WellKnown.symbol || classIndex(of: o) == WellKnown.string else { return nil }
        return String(validating: om.bytes(of: o), as: UTF8.self)
    }

    /// The elements of an Array, nil for anything else.
    fileprivate func arrayElements(_ o: Oop) -> [Oop]? {
        guard o.isObject, !om.isBytes(o), classIndex(of: o) == WellKnown.array else { return nil }
        return (0..<Int(om.count(of: o))).map { om.load(o, $0) }
    }

    /// The index of a registered behavior whose table entry is this object.
    fileprivate func behaviorIndex(_ o: Oop) -> UInt64? {
        guard om.isBehavior(o), om.count(of: o) >= UInt64(ClassLayout.size) else { return nil }
        let ci = om.load(o, ClassLayout.classIndex)
        guard ci.isSmallInteger, ci.smallIntegerValue > 0, ci.smallIntegerValue < Int64(om.classCount),
              om.classOop(UInt64(ci.smallIntegerValue)) == o else { return nil }
        return UInt64(ci.smallIntegerValue)
    }

    fileprivate func isMetaclass(_ o: Oop) -> Bool { o.isObject && classIndex(of: o) == WellKnown.metaclass }

    /// A class's name, `Foo class` for a metaclass.
    fileprivate func behaviorName(_ o: Oop) -> String {
        if isMetaclass(o) { return behaviorName(om.load(o, MetaclassLayout.thisClass)) + " class" }
        return symbolText(om.load(o, ClassLayout.name)) ?? "a class"
    }

    fileprivate func isObsolete(_ cls: Oop) -> Bool {
        symbolText(om.load(cls, ClassLayout.name))?.hasPrefix(ClassRules.obsoletePrefix) ?? false
    }

    /// `Foo>>bar` of a method (`Foo>>bar[]` for a block method).
    fileprivate func methodLabel(_ meth: Oop) -> String {
        let cls = om.load(meth, MethodLayout.methodClass)
        let sel = om.load(meth, MethodLayout.selector)
        return "\(om.isBehavior(cls) ? behaviorName(cls) : "?")>>\(symbolText(sel) ?? "[]")"
    }

    fileprivate func isMethodObject(_ o: Oop) -> Bool {
        o.isObject && om.isUsedReference(o) && classIndex(of: o) == WellKnown.method && !om.isBytes(o)
            && om.count(of: o) == UInt64(MethodLayout.size)
    }

    /// The class variables a class's superclasses declare, by name, with
    /// the declaring class's name (each pool's Bindings' keys).
    fileprivate func inheritedClassVariables(_ superclass: Oop) -> [String: String] {
        var out: [String: String] = [:]
        var c = superclass
        var steps = om.classCount
        while c != nilObject && om.isBehavior(c) && steps > 0 {
            let meta = om.classOop(classIndex(of: c))
            let pool = om.load(meta, MetaclassLayout.classPool)
            if let bs = arrayElements(pool) {
                for b in bs where b.isObject && !om.isBytes(b) && om.count(of: b) >= UInt64(BindingLayout.size) {
                    if let k = symbolText(om.load(b, BindingLayout.key)), out[k] == nil { out[k] = behaviorName(c) }
                }
            }
            c = om.load(c, ClassLayout.superclass)
            steps -= 1
        }
        return out
    }
}

/// The class-format kinds the kernel names (Tonel's `#type` resolved, as
/// `KernelClassDefinition.kind`).
private let kindNames: Set<String> = ["fixed", "variable", "bytes", "words16", "words32", "words64", "weak", "ephemeron"]

// MARK: - 145: define a class

/// The specification `Smalltalk primDefineClass:` takes, an Array:
///   1 the name, a Symbol
///   2 the superclass
///   3 every instance variable name, inherited first (Symbols)
///   4 every class-side instance variable name, inherited first
///   5 the class variables it declares (Symbols)
///   6 the format kind, a Symbol (`fixed`, `variable`, `bytes`, `words16`,
///     `words32`, `words64`, `weak`, `ephemeron`)
///   7 the class of the pool's Bindings (nil without class variables)
///   8 how many of 3 are the superclass's, and 9 how many of 4
private func defineClass(_ m: Machine, spec: Oop, roots: () -> [Oop]) -> Result<Oop, Refusal> {
    let om = m.om
    guard let s = m.arrayElements(spec), s.count == 9 else { return .failure(Refusal("the specification is not an Array of 9")) }
    guard let name = m.symbolText(s[0]), m.classIndex(of: s[0]) == WellKnown.symbol else { return .failure(Refusal("the name is not a Symbol")) }
    if let problem = ClassRules.classNameProblem(name) { return .failure(Refusal(problem)) }
    for i in 1..<UInt64(om.classCount) where om.classOop(i) != .none {
        let c = om.classOop(i)
        if !m.isMetaclass(c) && om.load(c, ClassLayout.name) == s[0] { return .failure(Refusal("a class named \(name) exists")) }
    }
    guard let si = m.behaviorIndex(s[1]), !m.isMetaclass(s[1]), !m.isObsolete(s[1]) else {
        return .failure(Refusal("\(name): the superclass is not a class"))
    }
    func names(_ o: Oop) -> [String]? {
        guard let xs = m.arrayElements(o) else { return nil }
        var out: [String] = []
        for x in xs {
            guard m.classIndex(of: x) == WellKnown.symbol, let t = m.symbolText(x) else { return nil }
            out.append(t)
        }
        return out
    }
    guard let ivars = names(s[2]), let civars = names(s[3]), let cvars = names(s[4]) else {
        return .failure(Refusal("\(name): the variable names are not Arrays of Symbols"))
    }
    guard let kind = m.symbolText(s[5]), kindNames.contains(kind) else { return .failure(Refusal("\(name): no format kind \(m.symbolText(s[5]) ?? "?")")) }
    guard s[7].isSmallInteger, s[8].isSmallInteger, s[7].smallIntegerValue >= 0, s[8].smallIntegerValue >= 0,
          Int(s[7].smallIntegerValue) <= ivars.count, Int(s[8].smallIntegerValue) <= civars.count else {
        return .failure(Refusal("\(name): the inherited counts"))
    }
    let superName = m.behaviorName(s[1])
    let sf = om.classFormat(si)
    let superMeta = om.classFormat(m.classIndex(of: s[1])).namedSlots - ClassLayout.size
    // What the superclass has, the kernel cannot claim otherwise: its named
    // slots and class-side instance variables are the inherited prefix.
    guard Int(s[7].smallIntegerValue) == sf.namedSlots, Int(s[8].smallIntegerValue) == superMeta else {
        return .failure(Refusal("\(name): \(superName) has \(sf.namedSlots) instance variables and \(superMeta) class-side ones"))
    }
    let def = KernelClassDefinition(name: name, superclass: superName, instSize: ivars.count, kind: kind, metaSlots: civars.count,
                                    classVariables: cvars, file: "", line: 0)
    guard let format = def.format, format.isValid, ivars.count <= Int(ClassFormat.namedMask),
          ClassLayout.size + civars.count <= Int(ClassFormat.namedMask) else {
        return .failure(Refusal("\(name): format \(kind) with \(ivars.count) named slots"))
    }
    if let problem = ClassRules.sizeProblem(name: name, superName: superName, superNamedSlots: sf.namedSlots, superMetaSlots: superMeta,
                                            namedSlots: ivars.count, metaSlots: civars.count)
        ?? ClassRules.subclassProblem(name: name, superName: superName, superFormat: sf, format: format)
        ?? ClassRules.namesProblem(className: name, instanceVariables: ivars, classInstanceVariables: civars,
                                   ownInstanceVariables: Array(ivars[Int(s[7].smallIntegerValue)...]),
                                   ownClassInstanceVariables: Array(civars[Int(s[8].smallIntegerValue)...]),
                                   classVariables: cvars, inherited: m.inheritedClassVariables(s[1])) {
        return .failure(Refusal(problem))
    }
    var bindingClass: UInt64 = 0
    if !cvars.isEmpty {
        guard let bi = m.behaviorIndex(s[6]), !m.isMetaclass(s[6]) else { return .failure(Refusal("\(name): no class for the Bindings")) }
        let bf = om.classFormat(bi)
        guard bf.kind == .fixed, !bf.isSealed, bf.namedSlots >= BindingLayout.size else {
            return .failure(Refusal("\(name): the Bindings' class is not a fixed class of at least \(BindingLayout.size) slots"))
        }
        bindingClass = bi
    }
    // Module 9b: a freed obsolete class's pair of indices is taken first.
    let reuse = om.freedClassPair()
    if reuse == nil && UInt64(om.classCount) + 2 > UInt64(LoaderLimits().maxClassIndex) {
        return .failure(Refusal("more than \(LoaderLimits().maxClassIndex) classes"))
    }

    // Everything allocated before the class table changes, so a full heap
    // leaves the table as it was.
    var keep = roots() + [spec]
    let ctx = unsafe m.state.pointee.context
    func alloc(_ cls: UInt64, _ n: Int) -> Oop? {
        guard let o = om.allocate(ctx, classIndex: cls, slots: n, fill: m.nilObject, extraRoots: keep) else { return nil }
        keep.append(o)
        return o
    }
    var pool = m.nilObject
    if !cvars.isEmpty {
        guard let p = alloc(WellKnown.array, cvars.count) else { return .failure(Refusal("the heap is full")) }
        pool = p
        for (i, key) in m.arrayElements(s[4])!.enumerated() {
            guard let b = alloc(bindingClass, om.classFormat(bindingClass).namedSlots) else { return .failure(Refusal("the heap is full")) }
            om.store(b, BindingLayout.key, key)
            om.store(pool, i, b)
        }
        om.setReadOnly(pool, true)
    }
    guard let metaObject = alloc(WellKnown.metaclass, MetaclassLayout.size) else { return .failure(Refusal("the heap is full")) }
    let index = reuse ?? om.registerClass(.none)
    let meta = reuse.map { $0 + 1 } ?? om.registerClass(.none)
    om.setClassFormat(meta, WellKnown.metaclassFormat(classSlots: ClassLayout.size + civars.count))
    om.setClassOop(meta, metaObject)
    guard let classObject = alloc(meta, ClassLayout.size + civars.count) else {
        if reuse != nil {
            om.makeClassHole(index)
            om.makeClassHole(meta)
        } else {
            om.unregisterLastClasses(2)
        }
        return .failure(Refusal("the heap is full"))
    }
    om.setClassOop(index, classObject)
    om.setClassFormat(index, format)
    om.pinForGood(metaObject)
    om.pinForGood(classObject)
    let c = classObject, mc = metaObject
    om.store(c, ClassLayout.superclass, s[1])
    om.store(c, ClassLayout.methodDict, m.nilObject)
    om.store(c, ClassLayout.name, s[0])
    om.store(c, ClassLayout.instSize, Oop(smallInteger: Int64(format.namedSlots)))
    om.store(c, ClassLayout.classIndex, Oop(smallInteger: Int64(index)))
    om.store(mc, ClassLayout.superclass, om.classOop(m.classIndex(of: s[1])))
    om.store(mc, ClassLayout.methodDict, m.nilObject)
    om.store(mc, ClassLayout.name, m.nilObject)
    om.store(mc, ClassLayout.instSize, Oop(smallInteger: Int64(ClassLayout.size + civars.count)))
    om.store(mc, ClassLayout.classIndex, Oop(smallInteger: Int64(meta)))
    om.store(mc, MetaclassLayout.thisClass, c)
    om.store(mc, MetaclassLayout.classPool, pool)
    return .success(c)
}

// MARK: - the running-frame rule

/// The first stack word, or running register, of any Process that is a
/// CompiledMethod `touched` answers true for: the Process (its id) and the
/// method. World stopped (or no VM: this interpreter's stack).
private func runningMethod(_ m: Machine, skipping: Oop = .none, _ touched: (Oop) -> Bool) -> (process: String, method: Oop)? {
    let om = m.om
    func check(_ v: Oop) -> Bool { v != skipping && m.isMethodObject(v) && touched(v) }
    guard let vm = unsafe workerOf(m.state).pointee.vm else {
        for v in m.rootsForPause() where check(v) { return ("this Process", v) }
        return nil
    }
    unsafe schedLock(vm)
    defer { unsafe schedUnlock(vm) }
    for i in unsafe 0..<vm.pointee.sched.pointee.recordHighWater {
        let r = unsafe records(vm, i)
        let p = unsafe r.pointee.process
        if p == .none { continue }
        guard let base = unsafe r.pointee.base else { continue }
        var words: [Oop] = []
        let top: Int
        if unsafe r.pointee.runningOn >= 0 {
            let wr = unsafe vm.worker(r.pointee.runningOn)
            top = unsafe wr.pointee.interp.regs.sp
            words = unsafe [wr.pointee.interp.regs.method, wr.pointee.interp.regs.receiver]
        } else {
            top = om.load(p, ProcessLayout.sp).smallIntegerValue.asInt
        }
        if top >= 0 { for k in 0...top { unsafe words.append(Oop(raw: base[k])) } }
        for v in words where check(v) {
            let id = om.load(p, ProcessLayout.id)
            return ("the Process \(id.isSmallInteger ? "\(id.smallIntegerValue)" : "?")", v)
        }
    }
    return nil
}

// MARK: - 146: redefine (reshape, recompile, pool)

/// One behavior whose instances change shape: its index, its object, its
/// named slots now and to be, and where each new slot comes from.
private struct ShapeChange {
    let index: UInt64
    let behavior: Oop
    let oldSlots: Int
    let layout: [Int?]
    var newSlots: Int { layout.count }
}

/// The specification `Smalltalk primRedefine:` takes, an Array of three
/// Arrays and a Symbol:
///   1 shapes: each {behavior. new named slots. layout}, the layout an
///     Array of the new slot count, each element the old slot (1-based)
///     the new slot takes, or 0 for nil. A metaclass's shape is its class
///     object's (the class layout's slots first, unchanged).
///   2 methods: each {behavior. Array of CompiledCode}: the behavior's
///     complete new method dictionary, made here against its new shape.
///     Every behavior of 1 is here (its methods are compiled for the old
///     slots); an old method that has a new one of its selector is
///     forwarded to it (become, one way: closures and Pragmas follow), and
///     its block methods to theirs.
///   3 pools: each {class. Array of Bindings}: the class's new pool.
///   4 a unary selector: what an old method of a reshaped class that no
///     new method replaces (a removed one, or an earlier version still
///     referenced) sends to its receiver once forwarded to a stub
///     (`makeStub`); nil refuses a change that finds such a method.
/// All checked, every method made and verified, every object allocated,
/// before anything changes; then, without a failure possible: forwarding,
/// the reshape, the formats, the dictionaries, the pools.
private func redefine(_ m: Machine, spec: Oop, roots: () -> [Oop]) -> Result<Oop, Refusal> {
    let om = m.om
    guard let parts = m.arrayElements(spec), parts.count == 3 || parts.count == 4, let shapeSpecs = m.arrayElements(parts[0]),
          let methodSpecs = m.arrayElements(parts[1]), let poolSpecs = m.arrayElements(parts[2]) else {
        return .failure(Refusal("the specification is not an Array of three Arrays"))
    }
    // --- shapes
    var shapes: [ShapeChange] = []
    for sp in shapeSpecs {
        guard let e = m.arrayElements(sp), e.count == 3, let ci = m.behaviorIndex(e[0]), installTarget(m, e[0]) != nil,
              e[1].isSmallInteger, let lay = m.arrayElements(e[2]), lay.count == Int(e[1].smallIntegerValue) else {
            return .failure(Refusal("a shape is not {an open behavior. its slots. its layout}"))
        }
        let name = m.behaviorName(e[0])
        if shapes.contains(where: { $0.index == ci }) { return .failure(Refusal("\(name): two shapes")) }
        let f = om.classFormat(ci)
        guard f.kind.isPointers, lay.count <= Int(ClassFormat.namedMask), lay.count <= Header.maxSlots else {
            return .failure(Refusal("\(name): its instances cannot have \(lay.count) named slots"))
        }
        var layout: [Int?] = []
        var used = Set<Int>()
        for x in lay {
            guard x.isSmallInteger, x.smallIntegerValue >= 0, x.smallIntegerValue <= Int64(f.namedSlots) else {
                return .failure(Refusal("\(name): a layout names no old slot"))
            }
            let v = Int(x.smallIntegerValue)
            if v == 0 { layout.append(nil); continue }
            if !used.insert(v).inserted { return .failure(Refusal("\(name): a layout takes an old slot twice")) }
            layout.append(v - 1)
        }
        if m.isMetaclass(e[0]) {
            // The class layout's slots are the VM's: they stay where they are.
            guard layout.count >= ClassLayout.size, (0..<ClassLayout.size).allSatisfy({ layout[$0] == $0 }) else {
                return .failure(Refusal("\(name): the class layout's slots move"))
            }
        }
        shapes.append(ShapeChange(index: ci, behavior: e[0], oldSlots: f.namedSlots, layout: layout))
    }
    // Every class's slots against its superclass's, with the changes made:
    // a method of a class runs on the instances of its subclasses, so they
    // must have at least its slots (the verifier's bound).
    func slotsAfter(_ i: UInt64) -> Int { shapes.first { $0.index == i }?.newSlots ?? om.classFormat(i).namedSlots }
    for i in 1..<UInt64(om.classCount) where om.classOop(i) != .none {
        let c = om.classOop(i)
        let sup = om.load(c, ClassLayout.superclass)
        guard sup != m.nilObject, let si = m.behaviorIndex(sup) else { continue }
        if slotsAfter(si) > slotsAfter(i) {
            return .failure(Refusal("\(m.behaviorName(c)) would have fewer named slots than \(m.behaviorName(sup))"))
        }
        // A subclass of a class whose slots change is reshaped with it (its
        // inherited slots are the prefix).
        if shapes.contains(where: { $0.index == si && $0.newSlots != $0.oldSlots }) && !shapes.contains(where: { $0.index == i }) {
            return .failure(Refusal("\(m.behaviorName(c)) is not reshaped with \(m.behaviorName(sup))"))
        }
    }
    let shaped = Set(shapes.map(\.index))
    // Nothing young and no sweep pending before the heap is scanned
    // (module 4's hook, as every module 1 operation).
    if !om.prepareOldSpaceOperation(roots() + [spec]).isEmpty { return .failure(Refusal("the heap is full")) }
    // --- the running-frame rule
    if let (process, meth) = runningMethod(m, { meth in
        let mc = om.load(meth, MethodLayout.methodClass)
        return m.behaviorIndex(mc).map { shaped.contains($0) } ?? false
    }) {
        return .failure(Refusal("\(process) runs \(m.methodLabel(meth)), a method of a class being reshaped: try again when it has left"))
    }
    // --- methods: make every one against its class's shape to be
    var keep = roots() + [spec]
    var newDicts: [(behavior: Oop, index: UInt64, methods: [(Oop, Oop)])] = []
    var forwardFrom: [Oop] = [], forwardTo: [Oop] = []
    for ms in methodSpecs {
        guard let e = m.arrayElements(ms), e.count == 2, let ci = m.behaviorIndex(e[0]), installTarget(m, e[0]) != nil,
              let codes = m.arrayElements(e[1]) else { return .failure(Refusal("a method set is not {an open behavior. CompiledCodes}")) }
        let name = m.behaviorName(e[0])
        if newDicts.contains(where: { $0.index == ci }) { return .failure(Refusal("\(name): two method sets")) }
        var format = om.classFormat(ci)
        if let sc = shapes.first(where: { $0.index == ci }) {
            format = ClassFormat(raw: format.raw & ~ClassFormat.namedMask | UInt64(sc.newSlots))
        }
        var made: [(Oop, Oop)] = []
        var blocksOf: [Oop: [Int: Oop]] = [:]
        for code in codes {
            switch makeMethod(m, code: code, methodClass: e[0], classIndex: ci, roots: keep, format: format,
                              onMade: { meth, blocks in blocksOf[meth] = blocks }) {
            case .refused(let why):
                let sel = code.isObject && !om.isBytes(code) && om.count(of: code) > 0 ? m.symbolText(om.load(code, 0)) ?? "?" : "?"
                return .failure(Refusal("\(name)>>\(sel): \(why)"))
            case .made(let meth):
                let sel = om.load(meth, MethodLayout.selector)
                if made.contains(where: { $0.0 == sel }) { return .failure(Refusal("\(name)>>\(m.symbolText(sel) ?? "?") twice")) }
                made.append((sel, meth))
                keep.append(meth)
                keep += (blocksOf[meth] ?? [:]).values
            }
        }
        if shaped.contains(ci) {
            // Pair each old method with its replacement, and their block
            // methods in literal order, when they have the same shape.
            let d = om.load(e[0], ClassLayout.methodDict)
            if d != m.nilObject {
                for k in 0..<(Int(om.count(of: d)) / 2) {
                    let key = om.load(d, 2 * k)
                    if key == m.nilObject { continue }
                    guard let new = made.first(where: { $0.0 == key })?.1 else { continue }
                    pairMethods(m, old: om.load(d, 2 * k + 1), new: new, &forwardFrom, &forwardTo)
                }
            }
        }
        newDicts.append((e[0], ci, made))
    }
    for sc in shapes where !newDicts.contains(where: { $0.index == sc.index }) {
        let d = om.load(sc.behavior, ClassLayout.methodDict)
        if d != m.nilObject && (0..<(Int(om.count(of: d)) / 2)).contains(where: { om.load(d, 2 * $0) != m.nilObject }) {
            return .failure(Refusal("\(m.behaviorName(sc.behavior)): its methods are not recompiled"))
        }
    }
    // --- every other method of a reshaped class (removed, or replaced
    // earlier and still referenced, or garbage not yet swept) is forwarded
    // to a stub that sends the kernel's selector to its receiver: its slot
    // indices are the old layout's, so running it would read the wrong
    // slots or slots that are gone, and the image loader's rule (every
    // method in the heap fits its class) holds after the change.
    let forwarded = Set(forwardFrom)
    let fresh = Set(keep)
    let stubSelector = parts.count > 3 ? parts[3] : m.nilObject
    for meth in om.allInstances(of: WellKnown.method) where !forwarded.contains(meth) && !fresh.contains(meth) {
        let mc = om.load(meth, MethodLayout.methodClass)
        guard let ci = m.behaviorIndex(mc), shaped.contains(ci) else { continue }
        guard m.classIndex(of: stubSelector) == WellKnown.symbol, let st = m.symbolText(stubSelector), isSelector(st), arity(of: st) == 0 else {
            return .failure(Refusal("\(m.methodLabel(meth)), an earlier version, is not recompiled and no stub selector was given"))
        }
        guard let stub = makeStub(m, for: meth, sending: stubSelector, roots: keep) else { return .failure(Refusal("the heap is full")) }
        keep.append(stub)
        forwardFrom.append(meth)
        forwardTo.append(stub)
    }
    // --- pools
    var newPools: [(meta: Oop, bindings: [Oop])] = []
    for ps in poolSpecs {
        guard let e = m.arrayElements(ps), e.count == 2, let ci = m.behaviorIndex(e[0]), !m.isMetaclass(e[0]),
              installTarget(m, e[0]) != nil, let bs = m.arrayElements(e[1]) else {
            return .failure(Refusal("a pool is not {an open class. Bindings}"))
        }
        let meta = om.classOop(m.classIndex(of: e[0]))
        var keys: [String] = []
        for b in bs {
            guard b.isObject, !om.isBytes(b), !om.isSealed(m.classIndex(of: b)), om.classFormat(m.classIndex(of: b)).kind == .fixed,
                  om.count(of: b) >= UInt64(BindingLayout.size), m.classIndex(of: om.load(b, BindingLayout.key)) == WellKnown.symbol,
                  let k = m.symbolText(om.load(b, BindingLayout.key)) else {
                return .failure(Refusal("\(m.behaviorName(e[0])): a pool element is not a Binding"))
            }
            keys.append(k)
        }
        // The pool's names among themselves and against the superclasses'
        // (instance variable names live in the kernel, which checks them).
        _ = ci
        if let problem = ClassRules.namesProblem(className: m.behaviorName(e[0]), instanceVariables: [], classInstanceVariables: [],
                                                 ownInstanceVariables: [], ownClassInstanceVariables: [], classVariables: keys,
                                                 inherited: m.inheritedClassVariables(om.load(e[0], ClassLayout.superclass))) {
            return .failure(Refusal(problem))
        }
        if newPools.contains(where: { $0.meta == meta }) { return .failure(Refusal("\(m.behaviorName(e[0])): two pools")) }
        newPools.append((meta, bs))
    }
    // --- allocate: dictionaries, pools, then the bodies
    let ctx = unsafe m.state.pointee.context
    var dictObjects: [Oop] = []
    for nd in newDicts {
        let cap = MethodDictionary.capacity(for: nd.methods.count)
        guard 2 * cap <= Header.maxSlots,
              let d = om.allocate(ctx, classIndex: WellKnown.methodDict, slots: 2 * cap, fill: m.nilObject, extraRoots: keep) else {
            return .failure(Refusal("the heap is full"))
        }
        keep.append(d)
        for (k, v) in nd.methods {
            var i = MethodDictionary.hash(k) & (cap - 1)
            while om.load(d, 2 * i) != m.nilObject { i = (i + 1) & (cap - 1) }
            om.store(d, 2 * i, k)
            om.store(d, 2 * i + 1, v)
        }
        dictObjects.append(d)
    }
    var poolObjects: [Oop] = []
    for p in newPools {
        guard let a = om.allocate(ctx, classIndex: WellKnown.array, slots: p.bindings.count, fill: m.nilObject, extraRoots: keep) else {
            return .failure(Refusal("the heap is full"))
        }
        keep.append(a)
        for (i, b) in p.bindings.enumerated() { om.store(a, i, b) }
        om.setReadOnly(a, true)
        poolObjects.append(a)
    }
    var plan: ReshapePlan
    do {
        plan = try om.prepareReshape(shapes.map { ReshapeRequest(classIndex: $0.index, namedSlots: $0.oldSlots, layout: $0.layout) },
                                     fill: m.nilObject, allowPinned: true)
    } catch {
        return .failure(Refusal(error == .readOnlyInstance ? "an instance is read-only"
                                : error == .heapFull ? "the heap is full" : "the instances cannot be reshaped (\(error))"))
    }
    defer { plan.free() }
    // --- commit: nothing below can fail
    if !forwardFrom.isEmpty {
        do { try om.becomeForward(forwardFrom, to: forwardTo, extraRoots: &keep) } catch {
            preconditionFailure("redefine: forwarding the replaced methods failed after every check: \(error)")
        }
    }
    om.commitReshape(&plan)
    for sc in shapes {
        om.store(sc.behavior, ClassLayout.instSize, Oop(smallInteger: Int64(sc.newSlots)))
    }
    for (k, nd) in newDicts.enumerated() { m.store(nd.behavior, ClassLayout.methodDict, dictObjects[k], .installMethod) }
    for (k, p) in newPools.enumerated() { m.store(p.meta, MetaclassLayout.classPool, poolObjects[k], .installMethod) }
    om.verifyAtPause("after redefine", phase: .idle)
    return .success(m.nilObject)
}

/// An old method and its replacement, and their block methods pairwise in
/// the order of their literal frames, when each pair has the same shape
/// (arguments, copied values, the home flag): what a closure of the old
/// block method needs of the new one. A pair that differs is left out; the
/// old method then has to fit the new shape or be garbage (above).
private func pairMethods(_ m: Machine, old: Oop, new: Oop, _ from: inout [Oop], _ to: inout [Oop]) {
    let om = m.om
    guard m.isMethodObject(old), m.isMethodObject(new), old != new, !from.contains(old) else { return }
    func same(_ i: Int) -> Bool { om.load(old, i) == om.load(new, i) }
    guard same(MethodLayout.argc), same(MethodLayout.copied) else { return }
    let fo = om.load(old, MethodLayout.flags), fn = om.load(new, MethodLayout.flags)
    guard fo.isSmallInteger, fn.isSmallInteger,
          fo.smallIntegerValue & (MethodFlags.block | MethodFlags.needsHome) == fn.smallIntegerValue & (MethodFlags.block | MethodFlags.needsHome)
    else { return }
    from.append(old)
    to.append(new)
    func blocks(_ meth: Oop) -> [Oop] {
        let lits = om.load(meth, MethodLayout.literals)
        return (0..<Int(om.count(of: lits))).map { om.load(lits, $0) }.filter { l in
            guard m.isMethodObject(l) else { return false }
            let f = om.load(l, MethodLayout.flags)
            return f.isSmallInteger && f.smallIntegerValue & MethodFlags.block != 0
        }
    }
    let ob = blocks(old), nb = blocks(new)
    guard ob.count == nb.count else { return }
    for (a, b) in zip(ob, nb) { pairMethods(m, old: a, new: b, &from, &to) }
}

/// A method of `old`'s class, selector, arguments, temps, copied values
/// and block and home flags whose body sends `selector` (unary) to its
/// receiver and answers that: what an old method that no longer fits its
/// class is forwarded to. Verified like any made method.
private func makeStub(_ m: Machine, for old: Oop, sending selector: Oop, roots: [Oop]) -> Oop? {
    let om = m.om
    func int(_ i: Int) -> Int { Int(om.load(old, i).smallIntegerValue) }
    let flags = Int64(int(MethodLayout.flags)) & (MethodFlags.block | MethodFlags.needsHome)
    let isBlock = flags & MethodFlags.block != 0
    let parts = MethodParts(bytecodes: [Opcode.pushSelf.rawValue, Opcode.send.rawValue, 0, 0,
                                        (isBlock ? Opcode.blockReturn : Opcode.returnTop).rawValue],
                            literals: [.object(selector)], argc: int(MethodLayout.argc), temps: int(MethodLayout.temps),
                            maxStack: 2, primitive: 0, flags: flags, copied: int(MethodLayout.copied))
    var heap = LiveMethodHeap(m: m, roots: roots + [old, selector])
    let mc = om.load(old, MethodLayout.methodClass)
    guard let made = try? makeMethodObjects(parts, blocks: [], selector: isBlock ? m.nilObject : om.load(old, MethodLayout.selector),
                                            methodClass: mc, heap: &heap),
          let ci = m.behaviorIndex(mc), verifyHeapMethod(om, made.method, classIndex: ci, nilObject: m.nilObject) == nil else { return nil }
    return made.method
}

// MARK: - 147: remove a class

/// `Smalltalk primRemoveClass: aClass as: anObsoleteName`: refused for a
/// sealed or well-known class, one with a subclass, an instance (garbage
/// collected first if any is found), a method outside it that names it in
/// its literals, or a frame running one of its methods; another Process
/// holding the class itself on its stack refuses it too (it may be about
/// to make an instance). Then both method dictionaries and the pool are
/// emptied, the class is renamed `AnObsoleteFoo` and cut from the
/// hierarchy (superclass nil, its metaclass under Class), and it stays in
/// the class table: indices are never reused, and an image keeps it.
private func removeClass(_ m: Machine, _ cls: Oop, obsoleteName: Oop, roots: () -> [Oop]) -> Result<Oop, Refusal> {
    let om = m.om
    guard let ci = m.behaviorIndex(cls), !m.isMetaclass(cls), !m.isObsolete(cls) else { return .failure(Refusal("not a class")) }
    let name = m.behaviorName(cls)
    guard ci >= WellKnown.firstUserClass, installTarget(m, cls) != nil else { return .failure(Refusal("\(name) is sealed or well known")) }
    guard m.classIndex(of: obsoleteName) == WellKnown.symbol, m.symbolText(obsoleteName) == ClassRules.obsoletePrefix + name else {
        return .failure(Refusal("the obsolete name is not #\(ClassRules.obsoletePrefix)\(name)"))
    }
    let meta = m.classIndex(of: cls)
    for i in 1..<UInt64(om.classCount) where i != ci && i != meta && om.classOop(i) != .none {
        if om.load(om.classOop(i), ClassLayout.superclass) == cls { return .failure(Refusal("\(name) has the subclass \(m.behaviorName(om.classOop(i)))")) }
    }
    var keep = roots() + [cls, obsoleteName]
    if !om.prepareOldSpaceOperation(keep).isEmpty { return .failure(Refusal("the heap is full")) }
    func instancesAndReferences() -> String? {
        if !om.allInstances(of: ci).isEmpty { return "\(name) has instances" }
        for meth in om.allInstances(of: WellKnown.method) {
            let mc = om.load(meth, MethodLayout.methodClass)
            if mc == cls || mc == om.classOop(meta) { continue }
            if literalsName(m, meth, cls) { return "\(m.methodLabel(meth)) names \(name)" }
        }
        return nil
    }
    if instancesAndReferences() != nil {
        om.collect(extraRoots: keep)
        if let problem = instancesAndReferences() { return .failure(Refusal(problem)) }
    }
    let me = unsafe workerOf(m.state).pointee.current
    if let (process, meth) = runningMethod(m, { meth in
        let mc = om.load(meth, MethodLayout.methodClass)
        return mc == cls || mc == om.classOop(meta)
    }) {
        return .failure(Refusal("\(process) runs \(m.methodLabel(meth)): try again when it has left"))
    }
    if let vm = unsafe workerOf(m.state).pointee.vm {
        unsafe schedLock(vm)
        defer { unsafe schedUnlock(vm) }
        for i in unsafe 0..<vm.pointee.sched.pointee.recordHighWater {
            let r = unsafe records(vm, i)
            let p = unsafe r.pointee.process
            guard p != .none, p != me, let base = unsafe r.pointee.base else { continue }
            let top = unsafe r.pointee.runningOn >= 0 ? vm.worker(r.pointee.runningOn).pointee.interp.regs.sp
                : om.load(p, ProcessLayout.sp).smallIntegerValue.asInt
            if top >= 0, (0...top).contains(where: { unsafe base[$0] == cls.raw }) {
                return .failure(Refusal("another Process holds \(name) on its stack: try again when it has let go"))
            }
        }
    }
    keep.removeAll()
    m.store(cls, ClassLayout.methodDict, m.nilObject, .installMethod)
    m.store(om.classOop(meta), ClassLayout.methodDict, m.nilObject, .installMethod)
    m.store(om.classOop(meta), MetaclassLayout.classPool, m.nilObject, .installMethod)
    m.store(cls, ClassLayout.name, obsoleteName, .installMethod)
    m.store(cls, ClassLayout.superclass, m.nilObject, .installMethod)
    m.store(om.classOop(meta), ClassLayout.superclass, om.classOop(WellKnown.classClass), .installMethod)
    // Module 9b: an obsolete class makes no instance (the allocation
    // primitives refuse a sealed class) until its indices are freed.
    om.setClassFormat(ci, om.classFormat(ci).with(sealed: true))
    return .success(m.nilObject)
}

// MARK: - 163: free obsolete classes (module 9b)

/// `Smalltalk primFreeObsoleteClasses`, in a stop: after a full collection,
/// every removed class (`AnObsolete...`, cut from the hierarchy) with no
/// instance and whose metaclass has no instance but it is taken out of the
/// class table and a second full collection runs; a class object it freed
/// was named by nothing (no literal, Binding, frame, stack word, root), and
/// its two indices become holes the define primitive reuses; one it kept
/// goes back into the table. Answers how many classes were freed.
private func freeObsoleteClasses(_ m: Machine, roots: () -> [Oop]) -> Int {
    let om = m.om
    var candidates: [(index: UInt64, meta: UInt64, cls: Oop, metaObject: Oop)] = []
    for i in WellKnown.firstUserClass..<UInt64(om.classCount) {
        let c = om.classOop(i)
        guard c != .none, !m.isMetaclass(c), m.isObsolete(c), om.load(c, ClassLayout.superclass) == m.nilObject else { continue }
        candidates.append((i, m.classIndex(of: c), c, om.classOop(m.classIndex(of: c))))
    }
    if candidates.isEmpty { return 0 }
    let keep = roots()
    if !om.prepareOldSpaceOperation(keep).isEmpty { return 0 }
    om.collect(extraRoots: keep)
    candidates = candidates.filter { om.allInstances(of: $0.index).isEmpty && om.allInstances(of: $0.meta) == [$0.cls] }
    if candidates.isEmpty { return 0 }
    for k in candidates {
        om.setClassOop(k.index, .none)
        om.setClassOop(k.meta, .none)
    }
    om.collect(extraRoots: roots())
    var freed = 0
    for k in candidates {
        if om.isUsedReference(k.cls) {
            om.setClassOop(k.index, k.cls)
            om.setClassOop(k.meta, k.metaObject)
        } else {
            om.makeClassHole(k.index)
            om.makeClassHole(k.meta)
            freed += 1
        }
    }
    unsafe m.state.pointee.counters.classesFreed &+= UInt64(freed)
    return freed
}

/// Whether a method (or one of its block methods, a literal Array or a
/// Pragma's arguments in it) names `cls` in its literal frame.
private func literalsName(_ m: Machine, _ meth: Oop, _ cls: Oop) -> Bool {
    let om = m.om
    func scan(_ a: Oop, depth: Int) -> Bool {
        guard depth < 66, a.isObject, !om.isBytes(a) else { return false }
        let ci = m.classIndex(of: a)
        guard ci == WellKnown.array || ci == WellKnown.pragma || ci == WellKnown.method else { return false }
        if ci == WellKnown.method { return scan(om.load(a, MethodLayout.literals), depth: depth + 1) }
        if ci == WellKnown.pragma { return scan(om.load(a, PragmaLayout.arguments), depth: depth + 1) }
        for i in 0..<Int(om.count(of: a)) {
            let v = om.load(a, i)
            if v == cls || scan(v, depth: depth + 1) { return true }
        }
        return false
    }
    return scan(om.load(meth, MethodLayout.literals), depth: 0)
}

// MARK: - 148, 149: files under the directory the host opened

/// The path `relative` names under the VM's sources directory, or nil: no
/// directory (none was given, or there is no VM), an absolute path, an
/// empty, `.` or `..` component, a NUL, a parent directory that resolves
/// (through symbolic links) outside the directory, or an existing last
/// component (a file or a symbolic link) whose whole path resolves outside
/// it or does not resolve (a dangling link): no component leads out
/// (docs/modules/vm-teardown.md). `path` is the resolved parent and the
/// last component as named: a write renames over it, replacing a link
/// inside the directory rather than following it. `resolved` is the whole
/// path resolved when the last component exists: a read opens it with
/// `O_NOFOLLOW`.
func sourcesPath(_ m: Machine, _ relative: String) -> (path: String, resolved: String?)? {
    guard let vm = unsafe workerOf(m.state).pointee.vm, let root = unsafe vm.pointee.config.sourcesDirectory, !root.isEmpty else { return nil }
    guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\0") else { return nil }
    let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
    guard let realRoot = realPath(root) else { return nil }
    func inside(_ p: String) -> Bool { p == realRoot || p.hasPrefix(realRoot + "/") }
    let parent = ([root] + parts.dropLast().map(String.init)).joined(separator: "/")
    guard let realParent = realPath(parent), inside(realParent) else { return nil }
    let path = realParent + "/" + String(parts.last!)
    var st = stat()
    guard unsafe lstat(path, &st) == 0 else { return (path, nil) }
    guard let whole = realPath(path), inside(whole), whole != realRoot else { return nil }
    return (path, whole)
}

private func realPath(_ p: String) -> String? {
    guard let r = unsafe realpath(p, nil) else { return nil }
    defer { unsafe free(r) }
    return unsafe String(cString: r)
}

private func filePrimitive(_ n: Int, _ m: Machine, _ c: PrimitiveCall) -> Oop {
    guard let rel = m.symbolText(c.arg0), m.classIndex(of: c.arg0) == WellKnown.string, let named = sourcesPath(m, rel) else { return .none }
    let path = named.path
    if n == 148 {
        guard c.argc == 2, m.classIndex(of: c.arg1) == WellKnown.string, m.om.isBytes(c.arg1) else { return .none }
        // A refused path never reaches here; the file is replaced whole
        // (written beside it and renamed over it).
        let bytes = m.om.bytes(of: c.arg1)
        let tmp = path + ".kajo-tmp"
        guard writeFile(tmp, bytes), unsafe rename(tmp, path) == 0 else {
            _ = unsafe unlink(tmp)
            return .none
        }
        unsafe m.state.pointee.counters.filesWritten &+= 1
        return m.trueObject
    }
    guard c.argc == 1, let resolved = named.resolved, let bytes = readFile(resolved), bytes.count <= Header.maxBytes, String(validating: bytes, as: UTF8.self) != nil else {
        return .none
    }
    unsafe m.state.pointee.counters.filesRead &+= 1
    return m.newString(bytes)
}

/// Write `bytes` to a new file at `path`: a link or file already there is
/// removed first (the link itself, never what it names), and the open
/// creates exclusively without following a link, so a link planted in its
/// place between the two refuses the write instead of leading out.
private func writeFile(_ path: String, _ bytes: [UInt8]) -> Bool {
    _ = unsafe unlink(path)
    let fd = unsafe open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var off = 0
    while off < bytes.count {
        let k = bytes.withUnsafeBytes { unsafe write(fd, $0.baseAddress! + off, bytes.count - off) }
        if k <= 0 { return false }
        off += k
    }
    return true
}

private func readFile(_ path: String) -> [UInt8]? {
    let fd = unsafe open(path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var out: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let k = buf.withUnsafeMutableBytes { unsafe read(fd, $0.baseAddress!, 65536) }
        if k < 0 { return nil }
        if k == 0 { break }
        out += buf[0..<k]
        if out.count > Header.maxBytes { return nil }
    }
    return out
}
