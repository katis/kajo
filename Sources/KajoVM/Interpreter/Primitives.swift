/// Primitive numbers are 1 ..< primitiveTableSize; 0 means none.
let primitiveTableSize = 256

/// What a primitive gets: the receiver and up to two arguments, copied out
/// of the stack (where they stay, as roots, until the primitive returns).
/// A primitive sees oops and the `Machine`, never a raw address.
struct PrimitiveCall {
    let receiver: Oop
    let argc: Int
    let arg0: Oop
    let arg1: Oop
}

/// The v0 primitives (numbering of experiments/vm-language-bench and
/// object-representation; 18 and 19 are new here).
enum Primitives {
    static let table: [(number: Int, selector: String, argc: Int)] = [
        (1, "at:", 1), (2, "at:put:", 2), (3, "basicNew: / new:", 1), (4, "basicNew", 0), (5, "class", 0),
        (6, "//", 1), (7, "\\\\", 1), (8, "become:", 1), (11, "collect (gc:)", -1), (12, "compact (compact:)", -1),
        (14, "globalAt:", 1), (15, "globalAt:put:", 2), (18, "==", 1), (19, "identityHash", 0),
        (38, "replaceFrom:to:with:startingAt:", 4),
    ]
}

/// Run primitive `n`. The result, or `.none` for failure: a primitive checks
/// every type, bound and argument count itself and trusts no oop it did
/// not check. Failure runs the method's bytecodes, if it has any.
func primitive(_ n: Int, _ m: Machine, _ c: PrimitiveCall) -> Oop {
    switch n {
    case 1: return primAt(m, c)
    case 2: return primAtPut(m, c)
    case 3: return c.argc == 1 ? primBasicNew(m, c.receiver, size: c.arg0) : .none
    case 4: return c.argc == 0 ? primBasicNew(m, c.receiver, size: Oop(smallInteger: 0)) : .none
    case 5: return c.argc == 0 ? m.om.classOop(m.classIndex(of: c.receiver)) : .none
    case 6: return primDivide(c, modulo: false)
    case 7: return primDivide(c, modulo: true)
    case 8: return c.argc == 1 && m.become(c.receiver, c.arg0) ? c.receiver : .none
    case 11:
        m.collect()
        return c.receiver
    case 12:
        m.compact()
        return c.receiver
    case 14: return primGlobal(m, c, put: false)
    case 15: return primGlobal(m, c, put: true)
    case 18: return c.argc == 1 ? (c.receiver == c.arg0 ? m.trueObject : m.falseObject) : .none
    case 19: return c.argc == 0 ? primIdentityHash(c.receiver) : .none
    case 20...34: return processPrimitive(n, m, c)  // module 3, Processes/ProcessPrimitives.swift
    case 35...37: return nurseryPrimitive(n, m, c)  // module 4, Nursery/Finalization.swift
    case 38: return primReplace(m, c)  // module 6, Relocation/Hazard.swift
    case 39: return primSlowPeek(m, c)  // module 7, YoungCollection/Mutator.swift (tests)
    case 75, 78, 117...119, 140, 141: return kernelPrimitive(n, m, c)  // module 8b, ObjectModel/KernelPrimitives.swift
    case 142: return savePrimitive(m, c)  // module 8c, Processes/SavedProcesses.swift
    case 143, 144: return liveMethodPrimitive(n, m, c)  // module 8d, ObjectModel/LiveMethods.swift
    case 150...154: return shellPrimitive(n, m, c)  // module 9a, Shell/ShellPrimitives.swift
    case 40...79, 90...136: return objectModelPrimitive(n, m, c)  // module 8, ObjectModel/
    default: return .none
    }
}

/// An object primitives may index: not a SmallInteger, not structural.
private func indexable(_ m: Machine, _ o: Oop) -> Bool {
    o.isObject && !m.om.isSealed(m.classIndex(of: o))
}

/// A 1-based index into `o`'s slots or bytes, or nil.
private func slotIndex(_ m: Machine, _ o: Oop, _ i: Oop) -> Int? {
    guard i.isSmallInteger else { return nil }
    let v = i.smallIntegerValue
    guard v >= 1, UInt64(v) <= m.om.count(of: o) else { return nil }
    return Int(v - 1)
}

private func primAt(_ m: Machine, _ c: PrimitiveCall) -> Oop {
    guard c.argc == 1, indexable(m, c.receiver), let i = slotIndex(m, c.receiver, c.arg0) else { return .none }
    if m.om.isBytes(c.receiver) { return Oop(smallInteger: Int64(m.om.loadByte(c.receiver, i))) }
    let v = m.om.load(c.receiver, i)
    // Module 5: while marking, a weak slot's referent is recorded (the
    // keep-alive read barrier; the slow path checks the format).
    if unsafe barrierWord(m.state.pointee.safepointFlag).pointee.load(ordering: .relaxed) != 0 {
        unsafe weakReadBarrier(m.state, c.receiver, i, v)
    }
    return v
}

private func primAtPut(_ m: Machine, _ c: PrimitiveCall) -> Oop {
    guard c.argc == 2, indexable(m, c.receiver), let i = slotIndex(m, c.receiver, c.arg0) else { return .none }
    // Module 8: no at:put: on a String or Symbol (UTF-8 stays valid), and
    // a read-only receiver is refused (modificationForbiddenAt:value:).
    let ci = m.classIndex(of: c.receiver)
    if ci == WellKnown.string || ci == WellKnown.symbol { return .none }
    if m.om.isReadOnly(c.receiver) { return m.refuseReadOnly(c.receiver, at: c.arg0, value: c.arg1) }
    if m.om.isBytes(c.receiver) {
        guard c.arg1.isSmallInteger, c.arg1.smallIntegerValue >= 0, c.arg1.smallIntegerValue <= 255 else { return .none }
        unsafe checkedStoreByte(m.state, c.receiver, i, UInt8(c.arg1.smallIntegerValue))
    } else {
        m.store(c.receiver, i, c.arg1, .atPut)
    }
    return c.arg1
}

/// `aClass basicNew: n`: an instance with the class's named slots plus `n`
/// indexed ones, or `n` elements of a byte or word class (module 8: the
/// class format's kind; a fixed class takes no indexed slots). Refused for
/// the immediate classes and sealed ones.
private func primBasicNew(_ m: Machine, _ cls: Oop, size: Oop) -> Oop {
    guard m.om.isBehavior(cls), size.isSmallInteger else { return .none }
    let index = m.om.load(cls, ClassLayout.classIndex)
    guard index.isSmallInteger, index.smallIntegerValue > 0, index.smallIntegerValue < Int64(m.om.classCount) else { return .none }
    let ci = UInt64(index.smallIntegerValue)
    guard ci != WellKnown.smallInteger, ci != WellKnown.smallFloat, ci != WellKnown.character, !m.om.isSealed(ci),
          m.om.classOop(ci) == cls else { return .none }
    let f = m.om.classFormat(ci)
    let n = size.smallIntegerValue
    guard n >= 0 else { return .none }
    switch f.kind {
    case .fixed:
        guard n == 0 else { return .none }
        return m.allocate(ci, slots: f.namedSlots)
    case .variable:
        let total = Int64(f.namedSlots) + n
        guard total <= Int64(Header.maxSlots) else { return .none }
        return m.allocate(ci, slots: Int(total))
    default:
        let bytes = n * Int64(f.kind.elementBytes)
        guard n <= Int64(Header.maxBytes), bytes <= Int64(Header.maxBytes) else { return .none }
        return m.allocateBytes(ci, count: Int(bytes))
    }
}

/// `//` and `\\` with floor semantics.
private func primDivide(_ c: PrimitiveCall, modulo: Bool) -> Oop {
    guard c.argc == 1, c.receiver.isSmallInteger, c.arg0.isSmallInteger else { return .none }
    let a = c.receiver.smallIntegerValue, b = c.arg0.smallIntegerValue
    guard b != 0 else { return .none }
    var q = a / b  // no overflow: |a| < 2^62
    if a % b != 0 && (a < 0) != (b < 0) { q -= 1 }
    let r = modulo ? a - q * b : q
    return Oop.fitsSmallInteger(r) ? Oop(smallInteger: r) : .none
}

private func primGlobal(_ m: Machine, _ c: PrimitiveCall, put: Bool) -> Oop {
    guard c.argc == (put ? 2 : 1), c.arg0.isSmallInteger else { return .none }
    let i = c.arg0.smallIntegerValue
    guard i >= 1, i <= Int64(Image.globalCount) else { return .none }
    if put {
        if m.om.isReadOnly(m.globals) { return m.refuseReadOnly(m.globals, at: c.arg0, value: c.arg1) }
        m.store(m.globals, Int(i - 1), c.arg1, .globalAtPut)
        return c.arg1
    }
    return m.om.load(m.globals, Int(i - 1))
}

/// Oops never change (ADR 0003), so the entry index is a stable hash.
private func primIdentityHash(_ o: Oop) -> Oop {
    o.isSmallInteger ? o : Oop(smallInteger: Int64(o.entryIndex))
}
