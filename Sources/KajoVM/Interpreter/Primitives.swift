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
    default: return .none
    }
}

/// An object primitives may index: not a SmallInteger, not structural.
private func indexable(_ m: Machine, _ o: Oop) -> Bool {
    o.isObject && !Image.isStructural(m.classIndex(of: o))
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
    return m.om.load(c.receiver, i)
}

private func primAtPut(_ m: Machine, _ c: PrimitiveCall) -> Oop {
    guard c.argc == 2, indexable(m, c.receiver), let i = slotIndex(m, c.receiver, c.arg0) else { return .none }
    if m.om.isBytes(c.receiver) {
        guard c.arg1.isSmallInteger, c.arg1.smallIntegerValue >= 0, c.arg1.smallIntegerValue <= 255 else { return .none }
        m.om.storeByte(c.receiver, i, UInt8(c.arg1.smallIntegerValue))
    } else {
        m.om.store(c.receiver, i, c.arg1)
    }
    return c.arg1
}

/// `aClass basicNew: n`: an instance with the class's named slots plus `n`
/// indexed ones (bytes for ByteArray). Refused for SmallInteger and the
/// structural classes.
private func primBasicNew(_ m: Machine, _ cls: Oop, size: Oop) -> Oop {
    guard cls.isObject, m.classIndex(of: cls) == WellKnown.classClass, size.isSmallInteger else { return .none }
    let index = m.om.load(cls, ClassLayout.classIndex), named = m.om.load(cls, ClassLayout.instSize)
    guard index.isSmallInteger, named.isSmallInteger else { return .none }
    let ci = UInt64(index.smallIntegerValue)
    guard ci != WellKnown.smallInteger, !Image.isStructural(ci) else { return .none }
    let n = size.smallIntegerValue
    if ci == WellKnown.byteArray {
        guard n >= 0, n <= Int64(Header.maxBytes) else { return .none }
        return m.allocateBytes(ci, count: Int(n))
    }
    let total = named.smallIntegerValue + n
    guard n >= 0, total <= Int64(Header.maxSlots) else { return .none }
    return m.allocate(ci, slots: Int(total))
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
        m.om.store(m.globals, Int(i - 1), c.arg1)
        return c.arg1
    }
    return m.om.load(m.globals, Int(i - 1))
}

/// Oops never change (ADR 0003), so the entry index is a stable hash.
private func primIdentityHash(_ o: Oop) -> Oop {
    o.isSmallInteger ? o : Oop(smallInteger: Int64(o.entryIndex))
}
