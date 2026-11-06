// Module 8's primitives (ADR 0009). Numbering:
//
//   40 to 57   integers (SmallInteger and LargeInteger, any mix): + - * /
//              // \\ quo: rem: < > <= >= = ~= bitAnd: bitOr: bitXor:
//              bitShift:; results normalized
//   58, 59     integer negated, asFloat
//   60 to 69   floats (SmallFloat and Float, a SmallInteger argument
//              coerced): + - * / < > <= >= = ~=
//   70 to 74   truncated, fractionPart, exponent, timesTwoPower:, sqrt
//   76, 77     Character value, Character value: (any receiver)
//   80 to 89   activation: closure value...valueWithArguments:, perform:
//              family (Interpreter/Special.swift)
//   90 to 98   respondsTo:, instVarAt:, instVarAt:put:, setReadOnly:,
//              isReadOnly, basicSize, shallowCopy, addSelector:withMethod:,
//              removeSelector: (97 and 98 refused in a release image and
//              for a sealed class since module 8d, ObjectModel/LiveMethods.swift)
//   100 to 116 Context and BlockClosure (Frames.swift)
//   120 to 136 Strings, Symbols, bytes (Strings.swift)
//
// Each checks every type, bound and its argument count itself and answers
// `.none` to fail; the method's bytecodes then run. A store refused for a
// read-only object records it (`Machine.refuseReadOnly`) and
// `primitiveSend` sends `modificationForbiddenAt:value:` instead.

enum ObjectModelPrimitives {
    static let table: [(number: Int, selector: String, argc: Int)] = [
        (40, "Integer +", 1), (41, "Integer -", 1), (42, "Integer *", 1), (43, "Integer /", 1), (44, "Integer //", 1),
        (45, "Integer \\\\", 1), (46, "quo:", 1), (47, "rem:", 1), (48, "Integer <", 1), (49, "Integer >", 1),
        (50, "Integer <=", 1), (51, "Integer >=", 1), (52, "Integer =", 1), (53, "Integer ~=", 1), (54, "bitAnd:", 1),
        (55, "bitOr:", 1), (56, "bitXor:", 1), (57, "bitShift:", 1), (58, "Integer negated", 0), (59, "Integer asFloat", 0),
        (60, "Float +", 1), (61, "Float -", 1), (62, "Float *", 1), (63, "Float /", 1), (64, "Float <", 1),
        (65, "Float >", 1), (66, "Float <=", 1), (67, "Float >=", 1), (68, "Float =", 1), (69, "Float ~=", 1),
        (70, "truncated", 0), (71, "fractionPart", 0), (72, "exponent", 0), (73, "timesTwoPower:", 1), (74, "sqrt", 0),
        (76, "Character value", 0), (77, "Character value: / asCharacter", 1),
        (80, "value", 0), (81, "value:", 1), (82, "value:value:", 2), (83, "value:value:value:", 3),
        (84, "valueWithArguments:", 1), (85, "CompiledMethod valueWithReceiver:arguments:", 2), (86, "perform:", 1), (87, "perform:with:", 2), (88, "perform:with:with:", 3),
        (89, "perform:withArguments:", 2),
        (90, "respondsTo:", 1), (91, "instVarAt:", 1), (92, "instVarAt:put:", 2), (93, "setReadOnly:", 1),
        (94, "isReadOnly", 0), (95, "basicSize", 0), (96, "shallowCopy", 0), (97, "addSelector:withMethod:", 2),
        (98, "removeSelector:", 1),
        (100, "Context sender", 0), (101, "Context tempAt:", 1), (102, "Context tempAt:put:", 2), (103, "Context pc", 0),
        (104, "Context method", 0), (105, "Context receiver", 0), (106, "Context closure", 0), (107, "Context isDead", 0),
        (108, "Context terminateTo:", 1), (109, "Context findNextUnwindContextUpTo:", 1),
        (110, "Context findNextHandlerContextStarting", 0), (111, "Context size", 0), (112, "BlockClosure numArgs", 0),
        (113, "BlockClosure receiver", 0), (114, "BlockClosure method", 0), (115, "BlockClosure home", 0),
        (116, "BlockClosure copiedValueAt:", 1),
        (120, "compare:", 1), (121, "sameBytesAs:", 1), (122, "hash", 0), (123, ",", 1), (124, "scalarAt:", 1),
        (125, "isBoundary:", 1), (126, "scalarCount", 0), (127, "copyFrom:to:", 2), (128, "encode:at:", 2),
        (129, "asSymbol", 0), (130, "asStringValidating", 0), (131, "asStringRepairing", 0), (132, "byteAt:", 1),
        (133, "byteSize", 0), (134, "indexOfSubstring:startingAt:", 2), (135, "Symbol lookup:", 1), (136, "scalarSizeAt:", 1),
    ]
}

@inline(never)
func objectModelPrimitive(_ n: Int, _ m: Machine, _ c: PrimitiveCall) -> Oop {
    switch n {
    case 40...57:
        guard c.argc == 1, c.receiver.isSmallInteger || m.bigInt(c.receiver) != nil else { return .none }
        return m.integerArith(integerOp(n), c.receiver, c.arg0)
    case 58:
        guard c.argc == 0, let b = m.bigInt(c.receiver) else { return .none }
        return m.integer(-b)
    case 59:
        guard c.argc == 0, let b = m.bigInt(c.receiver) else { return .none }
        return m.float(b.double)
    case 60...69:
        guard c.argc == 1, m.double(c.receiver) != nil else { return .none }
        return m.floatArith(floatOp(n), c.receiver, c.arg0)
    case 70...74:
        guard let d = m.double(c.receiver) else { return .none }
        switch n {
        case 70:
            guard c.argc == 0, d.isFinite else { return .none }
            let t = d.rounded(.towardZero)
            if t.magnitude < 9.0e18 { return m.integer(BigInt(Int64(t))) }
            // A large magnitude: exact from the bits.
            let e = Int(t.exponent) - 52
            let mant = BigInt(Int64(t.significandBitPattern | 1 << 52))
            return m.integer(t < 0 ? -mant.shifted(e) : mant.shifted(e))
        case 71: return c.argc == 0 ? m.float(d - d.rounded(.towardZero)) : .none
        case 72: return c.argc == 0 && d.isFinite && d != 0 ? Oop(smallInteger: Int64(d.exponent)) : .none
        case 73:
            guard c.argc == 1, c.arg0.isSmallInteger, c.arg0.smallIntegerValue.magnitude < 4096 else { return .none }
            return m.float(Double(sign: d.sign, exponent: Int(c.arg0.smallIntegerValue), significand: d.magnitude))
        default: return c.argc == 0 && d >= 0 ? m.float(d.squareRoot()) : .none
        }
    case 76: return c.argc == 0 && c.receiver.isCharacter ? Oop(smallInteger: Int64(c.receiver.characterValue)) : .none
    case 77:
        // `Character value: n` (any receiver), or `n asCharacter`
        let v = c.argc == 1 ? c.arg0 : c.receiver
        guard c.argc <= 1, v.isSmallInteger, v.smallIntegerValue >= 0, Oop.isScalar(UInt64(v.smallIntegerValue)) else {
            return .none
        }
        return Oop(character: UInt32(v.smallIntegerValue))
    case 90:
        guard c.argc == 1, c.arg0.isObject, m.om.classIndex(of: c.arg0) == WellKnown.symbol else { return .none }
        let found = lookupMethod(m.om, nilObject: m.nilObject, classIndex: m.classIndex(of: c.receiver), selector: c.arg0)
        return m.boolean(found != .none)
    case 91, 92: return primInstVarAt(m, c, put: n == 92)
    case 93:
        guard c.argc == 1, c.receiver.isObject, c.arg0 == m.trueObject || c.arg0 == m.falseObject,
              !m.om.isSealed(m.classIndex(of: c.receiver)) else { return .none }
        let was = m.om.isReadOnly(c.receiver)
        m.om.setReadOnly(c.receiver, c.arg0 == m.trueObject)
        return m.boolean(was)
    case 94: return c.argc == 0 ? m.boolean(m.om.isReadOnly(c.receiver)) : .none
    case 95:
        guard c.argc == 0, c.receiver.isObject else { return c.argc == 0 ? Oop(smallInteger: 0) : .none }
        let f = m.om.classFormat(m.classIndex(of: c.receiver))
        let count = Int64(m.om.count(of: c.receiver))
        return Oop(smallInteger: f.kind.isPointers ? count - Int64(f.namedSlots) : count / Int64(f.kind.elementBytes))
    case 96: return primShallowCopy(m, c)
    case 97, 98: return primInstallMethod(m, c, remove: n == 98)
    case 100...116: return contextPrimitive(n, m, c)
    case 120...136: return stringPrimitive(n, m, c)
    default: return .none
    }
}

@inline(__always)
private func integerOp(_ n: Int) -> ArithOp {
    switch n {
    case 40: .add
    case 41: .sub
    case 42: .mul
    case 43: .div
    case 44: .intDiv
    case 45: .mod
    case 46: .quo
    case 47: .rem
    case 48: .lt
    case 49: .gt
    case 50: .le
    case 51: .ge
    case 52: .eq
    case 53: .ne
    case 54: .bitAnd
    case 55: .bitOr
    case 56: .bitXor
    default: .bitShift
    }
}

@inline(__always)
private func floatOp(_ n: Int) -> ArithOp {
    switch n {
    case 60: .add
    case 61: .sub
    case 62: .mul
    case 63: .div
    case 64: .lt
    case 65: .gt
    case 66: .le
    case 67: .ge
    case 68: .eq
    default: .ne
    }
}

/// `instVarAt: i` and `instVarAt: i put: v`: named and indexed pointer
/// slots, 1-based; not on sealed classes or byte objects. The store is
/// refused for a read-only receiver.
private func primInstVarAt(_ m: Machine, _ c: PrimitiveCall, put: Bool) -> Oop {
    guard c.argc == (put ? 2 : 1), c.receiver.isObject, c.arg0.isSmallInteger,
          !m.om.isSealed(m.classIndex(of: c.receiver)), !m.om.isBytes(c.receiver) else { return .none }
    let i = c.arg0.smallIntegerValue
    guard i >= 1, i <= Int64(m.om.count(of: c.receiver)) else { return .none }
    if !put {
        let v = m.om.load(c.receiver, Int(i - 1))
        // A weak slot's referent is kept alive while marking (as `at:`).
        unsafe keepAliveRead(m.state, c.receiver, Int(i - 1), v)
        return v
    }
    if m.om.isReadOnly(c.receiver) { return m.refuseReadOnly(c.receiver, at: c.arg0, value: c.arg1) }
    m.store(c.receiver, Int(i - 1), c.arg1, .instVarAtPut)
    return c.arg1
}

/// A copy of the receiver's slots or bytes (not read-only, not pinned).
private func primShallowCopy(_ m: Machine, _ c: PrimitiveCall) -> Oop {
    guard c.argc == 0 else { return .none }
    guard c.receiver.isObject else { return c.receiver }
    let ci = m.classIndex(of: c.receiver)
    guard !m.om.isSealed(ci) else { return .none }
    let n = Int(m.om.count(of: c.receiver))
    if m.om.isBytes(c.receiver) {
        let o = m.allocateAny(ci, count: n, bytes: true, keeping: c.receiver)
        if o == .none { return .none }
        // Large bytes: past a chunk, polled with the copy a pending root.
        guard m.fillFresh(o, 0, from: c.receiver, 0, n) else { return .none }
        return o
    }
    // Module 10: a large receiver's copy is large too (old at birth).
    let o = m.allocateAny(ci, count: n, bytes: false, keeping: c.receiver)
    if o == .none { return .none }
    // A weak receiver's copy is weak and new, so the final mark never nils
    // its slots: a referent read here must be kept alive while marking.
    let weak = m.om.classFormat(ci).isWeak
    for i in 0..<n {
        let v = m.om.load(c.receiver, i)
        if weak { unsafe keepAliveRead(m.state, c.receiver, i, v) }
        m.store(o, i, v, .instVarAtPut)
    }
    return o
}

// MARK: - method installation

/// `aBehavior addSelector: aSymbol withMethod: aMethod` and `removeSelector:`
/// (ADR 0009 section 11). The method must have been compiled for the
/// receiver under that selector (its method class is the receiver, so
/// `super` and the instance-variable checks hold) and passes the bytecode verifier against
/// the receiver's shape. The new method dictionary is built and stored in a
/// stop: every worker is parked, and each flushes its lookup cache when it
/// sees the stop (module 3's epoch) before it runs again, so no worker can
/// find the old method once the primitive answers. The install is ordered
/// after the flush. Outside a VM the interpreter's own cache is flushed.
private func primInstallMethod(_ m: Machine, _ c: PrimitiveCall, remove: Bool) -> Oop {
    let om = m.om
    // Module 8d: never in a release image, never into a sealed class
    // (`installTarget`); module 9b: an extension of a sealed class when the
    // method can do nothing a method of any other class could not
    // (`sealedExtensionProblem`), the refusal a String naming why.
    guard c.argc == (remove ? 1 : 2), c.arg0.isObject, om.classIndex(of: c.arg0) == WellKnown.symbol else { return .none }
    var target = installTarget(m, c.receiver)
    if target == nil, let ci = sealedTarget(m, c.receiver) {
        let subject = remove ? lookupInDictionary(m, c.receiver, c.arg0) : c.arg1
        guard let subject else { return .none }
        if let why = sealedExtensionProblem(om, subject) {
            unsafe m.state.pointee.counters.methodsRefused &+= 1
            return m.newString(Array("\(remove ? "removing" : "installing") \(m.text(c.arg0) ?? "?") \(remove ? "from" : "into") a sealed class: \(why)".utf8))
        }
        target = ci
    }
    guard let ci = target else { return .none }
    if !remove {
        guard c.arg1.isObject, om.classIndex(of: c.arg1) == WellKnown.method,
              om.load(c.arg1, MethodLayout.methodClass) == c.receiver, om.load(c.arg1, MethodLayout.selector) == c.arg0,
              methodFlags(om, c.arg1.raw) & MethodFlags.block == 0,
              verifyHeapMethod(om, c.arg1, classIndex: ci, nilObject: m.nilObject) == nil else { return .none }
    }
    var ok = false
    let work = {
        ok = installInDictionary(m, c.receiver, c.arg0, remove ? nil : c.arg1)
    }
    if let vm = unsafe workerOf(m.state).pointee.vm {
        unsafe stopWorld(vm, workerOf(m.state), retry: true, keeping: [c.receiver, c.arg0, c.arg1].filter { $0 != .none }) { _ in work() }
        unsafe workerOf(m.state).pointee.seenEpoch = vm.pointee.safepoint.pointee.epoch
    } else {
        work()
    }
    m.flushCache()
    unsafe m.state.pointee.counters.methodsInstalled &+= 1
    return ok ? c.receiver : .none
}

/// The method `sel` names in `cls`'s own dictionary, or nil.
private func lookupInDictionary(_ m: Machine, _ cls: Oop, _ sel: Oop) -> Oop? {
    let om = m.om
    let d = om.load(cls, ClassLayout.methodDict)
    guard d != m.nilObject, d.isObject else { return nil }
    for i in 0..<(Int(om.count(of: d)) / 2) where om.load(d, 2 * i) == sel { return om.load(d, 2 * i + 1) }
    return nil
}

/// A new method dictionary with `sel` mapped to `method` (or removed),
/// stored into the class. World stopped (or no VM). Old allocation.
private func installInDictionary(_ m: Machine, _ cls: Oop, _ sel: Oop, _ method: Oop?) -> Bool {
    let om = m.om
    let d = om.load(cls, ClassLayout.methodDict)
    var entries: [(Oop, Oop)] = []
    if d != m.nilObject {
        for i in 0..<(Int(om.count(of: d)) / 2) {
            let k = om.load(d, 2 * i)
            if k != m.nilObject && k != sel { entries.append((k, om.load(d, 2 * i + 1))) }
        }
    }
    if let method { entries.append((sel, method)) }
    let cap = MethodDictionary.capacity(for: entries.count)
    guard 2 * cap <= Header.maxSlots else { return false }
    let ctx = unsafe m.state.pointee.context
    guard let nd = om.allocate(ctx, classIndex: WellKnown.methodDict, slots: 2 * cap, fill: m.nilObject,
                               extraRoots: [cls, sel] + (method.map { [$0] } ?? [])) else { return false }
    for (k, v) in entries {
        var i = MethodDictionary.hash(k) & (cap - 1)
        while om.load(nd, 2 * i) != m.nilObject { i = (i + 1) & (cap - 1) }
        om.store(nd, 2 * i, k)
        om.store(nd, 2 * i + 1, v)
    }
    m.store(cls, ClassLayout.methodDict, nd, .installMethod)
    return true
}

/// The bytecode verifier and the method-shape rules on a Method in the
/// heap (the image loader's check, and the install primitive's): nil when
/// it may run as a method of class `classIndex`, else why not.
func verifyHeapMethod(_ om: ObjectMemory, _ method: Oop, classIndex: UInt64, nilObject: Oop,
                      limits: LoaderLimits = LoaderLimits(), depth: Int = 0, format: ClassFormat? = nil,
                      traced: ((VerifiedCode) -> Void)? = nil) -> String? {
    if depth > 64 { return "blocks nested deeper than 64 (or a cycle)" }
    guard method.isObject, om.isUsedReference(method), om.classIndex(of: method) == WellKnown.method, !om.isBytes(method),
          om.count(of: method) == UInt64(MethodLayout.size) else { return "not a CompiledMethod" }
    func int(_ i: Int) -> Int? {
        let v = om.load(method, i)
        return v.isSmallInteger && v.smallIntegerValue >= 0 && v.smallIntegerValue < 1 << 20 ? Int(v.smallIntegerValue) : nil
    }
    guard let argc = int(MethodLayout.argc), let temps = int(MethodLayout.temps), let maxStack = int(MethodLayout.maxStack),
          let prim = int(MethodLayout.primitive), let flagsI = int(MethodLayout.flags), let copied = int(MethodLayout.copied)
    else { return "a header slot is not a small non-negative integer" }
    let flags = Int64(flagsI)
    guard flags & ~MethodFlags.all == 0, prim < primitiveTableSize, maxStack <= limits.maxStack,
          argc + temps <= limits.maxTemps else { return "a header value out of range" }
    let isBlock = flags & MethodFlags.block != 0
    if isBlock && (prim != 0 || temps < copied + 1 || flags & (MethodFlags.unwind | MethodFlags.handler) != 0) {
        return "a block method's header"
    }
    if !isBlock && (copied != 0 || flags & MethodFlags.needsHome != 0) { return "a method's header" }
    let bc = om.load(method, MethodLayout.bytecodes), lits = om.load(method, MethodLayout.literals)
    guard bc.isObject, om.isUsedReference(bc), om.classIndex(of: bc) == WellKnown.byteArray, om.isBytes(bc) else {
        return "bytecodes not a ByteArray"
    }
    guard lits.isObject, om.isUsedReference(lits), om.classIndex(of: lits) == WellKnown.array, !om.isBytes(lits),
          om.count(of: lits) <= UInt64(limits.maxLiterals) else { return "literals not an Array" }
    let sel = om.load(method, MethodLayout.selector)
    if isBlock { if sel != nilObject { return "a block method with a selector" } }
    else {
        guard sel.isObject, om.isUsedReference(sel), om.classIndex(of: sel) == WellKnown.symbol, om.isBytes(sel),
              let name = String(validating: om.bytes(of: sel), as: UTF8.self), isSelector(name), arity(of: name) == argc
        else { return "the selector does not match the argument count" }
    }
    let mc = om.load(method, MethodLayout.methodClass)
    guard mc.isObject, om.isUsedReference(mc), om.isBehavior(mc), !om.isBytes(mc), om.count(of: mc) >= UInt64(ClassLayout.size),
          om.load(mc, ClassLayout.classIndex) == Oop(smallInteger: Int64(classIndex))
    else { return "the method class is not the class it is installed in" }
    let bytes = om.bytes(of: bc)
    if bytes.isEmpty && prim == 0 { return "no bytecodes and no primitive" }
    if bytes.isEmpty && isBlock { return "an empty block method" }
    let nLits = Int(om.count(of: lits))
    // Module 9b: a source map is the last literal, a ByteArray.
    if flags & MethodFlags.sourceMap != 0 {
        guard nLits > 0 else { return "a source map flag with no literal" }
        let map = om.load(lits, nLits - 1)
        guard map.isObject, om.isUsedReference(map), om.classIndex(of: map) == WellKnown.byteArray, om.isBytes(map) else {
            return "a source map flag but the last literal is not a ByteArray"
        }
    }
    // Module 8e: a redefinition verifies the methods it makes against the
    // class's format to be, before the class changes.
    let f = format ?? om.classFormat(classIndex)
    let instSize = f.namedSlots
    let ivars: Range<Int> = f.instancesAreBehaviors ? ClassLayout.size..<max(ClassLayout.size, instSize)
        : f.isSealed || !f.kind.isPointers ? 0..<0 : 0..<instSize
    let shape = CodeShape(argc: argc, addressableTemps: isBlock ? argc + temps - 1 : argc + temps, literalCount: nLits,
                          isBlock: isBlock, needsHome: flags & MethodFlags.needsHome != 0, ivarRange: ivars,
                          maxStackLimit: limits.maxStack)
    var blockIssue: String? = nil
    do {
        let v = try verifyBytecodes(bytes, shape) { k in
            let l = om.load(lits, k)
            guard l.isObject else { return .other }
            let lc = om.classIndex(of: l)
            if lc == WellKnown.symbol, om.isBytes(l), let name = String(validating: om.bytes(of: l), as: UTF8.self), isSelector(name) {
                return .selector(arity: arity(of: name))
            }
            if lc == WellKnown.method && !om.isBytes(l) && om.count(of: l) == UInt64(MethodLayout.size) {
                let fl = om.load(l, MethodLayout.flags), cp = om.load(l, MethodLayout.copied), a = om.load(l, MethodLayout.argc)
                if fl.isSmallInteger, cp.isSmallInteger, a.isSmallInteger, fl.smallIntegerValue & MethodFlags.block != 0 {
                    return .block(args: Int(a.smallIntegerValue), copied: Int(cp.smallIntegerValue),
                                  needsHome: fl.smallIntegerValue & MethodFlags.needsHome != 0)
                }
            }
            return .other
        }
        if v.maxStack > maxStack { return "maxStack \(maxStack) below the traced \(v.maxStack)" }
        // Module 8c: the traced depths, for the saved-frame rules.
        traced?(v)
        // Block methods in the literal frame are verified as blocks of the
        // same class.
        for k in Set(v.closures) {
            if let issue = verifyHeapMethod(om, om.load(lits, k), classIndex: classIndex, nilObject: nilObject, limits: limits,
                                            depth: depth + 1, format: format) {
                blockIssue = "block literal \(k): \(issue)"
                break
            }
        }
    } catch {
        return "pc \(error.offset): \(error.message)"
    }
    return blockIssue
}
