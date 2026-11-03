// The VM side of the one String (ADR 0009 section 8, kernel.md "String"):
// a String is a byte object of valid UTF-8, a Symbol an interned one.
// Positions are 1-based byte offsets valid only at scalar boundaries;
// there is no `at:put:` on a String or a Symbol (primitive 2 refuses them),
// so a String stays valid from its creation (validated or built from valid
// pieces) on. The primitives: byte comparison and equality, hashing,
// concatenation, decoding the scalar at an offset, boundary checks,
// counting scalars, copying a boundary-aligned range, encoding a
// Character into a byte buffer (a WriteStream's), interning, building a
// String from bytes (validating, or repairing with U+FFFD), byte access
// for the `utf8` view, substring search.

/// UTF-8 decoding of one scalar from `byte(i)`, `n` bytes in all. nil when
/// `i` is not the start of a well-formed scalar.
@inline(__always)
func decodeScalar(_ n: Int, _ i: Int, _ byte: (Int) -> UInt8) -> (scalar: UInt32, length: Int)? {
    guard i >= 0, i < n else { return nil }
    let b0 = byte(i)
    if b0 < 0x80 { return (UInt32(b0), 1) }
    let len: Int, min: UInt32
    var v: UInt32
    switch b0 {
    case 0xC2...0xDF: len = 2; v = UInt32(b0 & 0x1F); min = 0x80
    case 0xE0...0xEF: len = 3; v = UInt32(b0 & 0x0F); min = 0x800
    case 0xF0...0xF4: len = 4; v = UInt32(b0 & 0x07); min = 0x10000
    default: return nil
    }
    guard i + len <= n else { return nil }
    for k in 1..<len {
        let b = byte(i + k)
        guard b & 0xC0 == 0x80 else { return nil }
        v = v << 6 | UInt32(b & 0x3F)
    }
    guard v >= min, Oop.isScalar(UInt64(v)) else { return nil }
    return (v, len)
}

func encodeScalar(_ v: UInt32) -> [UInt8] {
    switch v {
    case 0..<0x80: return [UInt8(v)]
    case 0x80..<0x800: return [UInt8(0xC0 | v >> 6), UInt8(0x80 | v & 0x3F)]
    case 0x800..<0x10000: return [UInt8(0xE0 | v >> 12), UInt8(0x80 | v >> 6 & 0x3F), UInt8(0x80 | v & 0x3F)]
    default: return [UInt8(0xF0 | v >> 18), UInt8(0x80 | v >> 12 & 0x3F), UInt8(0x80 | v >> 6 & 0x3F), UInt8(0x80 | v & 0x3F)]
    }
}

/// The bytes are well-formed UTF-8.
func isValidUTF8(_ b: [UInt8]) -> Bool {
    var i = 0
    while i < b.count {
        guard let (_, len) = decodeScalar(b.count, i, { b[$0] }) else { return false }
        i += len
    }
    return true
}

/// Each ill-formed sequence replaced by U+FFFD (the maximal-subpart rule,
/// as Swift's `String(decoding:as:)`).
func repairedUTF8(_ b: [UInt8]) -> [UInt8] {
    String(decoding: b, as: UTF8.self).utf8.map { $0 }
}

extension Machine {
    func isText(_ o: Oop) -> Bool {
        guard o.isObject else { return false }
        let c = om.classIndex(of: o)
        return (c == WellKnown.string || c == WellKnown.symbol) && om.isBytes(o)
    }

    /// A new String holding `bytes` (which the caller has made valid).
    func newString(_ bytes: [UInt8]) -> Oop {
        guard bytes.count <= Header.maxBytes else { return .none }
        let o = allocateBytes(WellKnown.string, count: bytes.count)
        if o == .none { return .none }
        for (i, b) in bytes.enumerated() { om.storeByte(o, i, b) }
        return o
    }

    /// 0-based offset `i` is a scalar boundary of text `o` (the end counts).
    func isBoundary(_ o: Oop, _ i: Int) -> Bool {
        let n = Int(om.count(of: o))
        guard i >= 0, i <= n else { return false }
        if om.config.testSwitches.noBoundaryCheck { return true }
        return i == n || om.loadByte(o, i) & 0xC0 != 0x80
    }

    /// The Symbol for the bytes of text `o`, interned if new: the lookup
    /// reads the table; a new Symbol is made and inserted with the world
    /// stopped (looked up again inside the stop), so two workers never
    /// intern the same bytes twice.
    func intern(_ o: Oop) -> Oop {
        if om.classIndex(of: o) == WellKnown.symbol { return o }
        let bytes = om.bytes(of: o)
        let h = utf8Hash(bytes)
        let table = unsafe state.pointee.symbolTable
        let found = om.symbolLookup(table, hash: h) { om.sameBytes($0, bytes) }
        if found != .none { return found }
        var result = Oop.none
        if let vm = unsafe workerOf(state).pointee.vm {
            unsafe stopWorld(vm, workerOf(state), retry: true, keeping: [o]) { stop in
                result = insertSymbol(bytes, hash: h, roots: stop.roots())
            }
        } else {
            result = insertSymbol(bytes, hash: h, roots: rootsForPause() + [o])
        }
        return result
    }

    /// World stopped (or no VM): look up again, else make the Symbol (old,
    /// pinned, read-only) and put it in its bucket, growing the bucket.
    private func insertSymbol(_ bytes: [UInt8], hash h: Int64, roots: [Oop]) -> Oop {
        let table = unsafe state.pointee.symbolTable
        let again = om.symbolLookup(table, hash: h) { om.sameBytes($0, bytes) }
        if again != .none { return again }
        let ctx = unsafe state.pointee.context
        guard let sym = om.allocateBytes(ctx, classIndex: WellKnown.symbol, count: bytes.count, extraRoots: roots) else {
            return .none
        }
        for (i, b) in bytes.enumerated() { om.storeByte(sym, i, b) }
        om.pinForGood(sym)
        om.setReadOnly(sym, true)
        if let (b, i) = om.symbolSlot(table, hash: h) {
            store(b, i, sym, .symbolTable)
        } else {
            let j = Int(truncatingIfNeeded: h) & (SymbolTable.buckets - 1)
            let old = om.load(table, j)
            let n = old == nilObject ? 0 : Int(om.count(of: old))
            guard let size = SymbolTable.grownBucketSize(n),
                  let nb = om.allocate(ctx, classIndex: WellKnown.array, slots: size, fill: nilObject, extraRoots: roots + [sym])
            else { return .none }
            for k in 0..<n { store(nb, k, om.load(old, k), .symbolTable) }
            store(nb, n, sym, .symbolTable)
            store(table, j, nb, .symbolTable)
        }
        unsafe state.pointee.counters.symbolsInterned &+= 1
        return sym
    }
}

@inline(never)
func stringPrimitive(_ n: Int, _ m: Machine, _ c: PrimitiveCall) -> Oop {
    let om = m.om
    let r = c.receiver
    switch n {
    case 120, 121:
        guard c.argc == 1, m.isText(r), m.isText(c.arg0) else { return .none }
        if n == 121 { return m.boolean(om.sameBytes(r, c.arg0)) }
        let a = om.bytes(of: r), b = om.bytes(of: c.arg0)
        return Oop(smallInteger: a.lexicographicallyPrecedes(b) ? -1 : a == b ? 0 : 1)
    case 122:
        guard c.argc == 0, m.isText(r) else { return .none }
        return Oop(smallInteger: om.byteObjectHash(r))
    case 123:
        guard c.argc == 1, m.isText(r), m.isText(c.arg0) else { return .none }
        return m.newString(om.bytes(of: r) + om.bytes(of: c.arg0))
    case 124, 136:
        guard c.argc == 1, m.isText(r), c.arg0.isSmallInteger else { return .none }
        let i = Int(c.arg0.smallIntegerValue) - 1
        let count = Int(om.count(of: r))
        guard let (v, len) = decodeScalar(count, i, { om.loadByte(r, $0) }) else {
            // Broken variant: an offset inside a scalar answers its
            // continuation byte as a Character.
            if om.config.testSwitches.noBoundaryCheck && i >= 0 && i < count {
                return n == 124 ? Oop(character: UInt32(om.loadByte(r, i))) : Oop(smallInteger: 1)
            }
            return .none
        }
        return n == 124 ? Oop(character: v) : Oop(smallInteger: Int64(len))
    case 125:
        guard c.argc == 1, m.isText(r), c.arg0.isSmallInteger else { return .none }
        return m.boolean(m.isBoundary(r, Int(c.arg0.smallIntegerValue) - 1))
    case 126:
        guard c.argc == 0, m.isText(r) else { return .none }
        var k = 0
        for i in 0..<Int(om.count(of: r)) where om.loadByte(r, i) & 0xC0 != 0x80 { k += 1 }
        return Oop(smallInteger: Int64(k))
    case 127:
        guard c.argc == 2, m.isText(r), c.arg0.isSmallInteger, c.arg1.isSmallInteger else { return .none }
        let a = Int(c.arg0.smallIntegerValue) - 1, b = Int(c.arg1.smallIntegerValue)  // [a, b) 0-based
        guard a >= 0, b >= a, b <= Int(om.count(of: r)), m.isBoundary(r, a), m.isBoundary(r, b) else { return .none }
        return m.newString(Array(om.bytes(of: r)[a..<b]))
    case 128:
        // aByteArray encode: aCharacter at: offset -> bytes written
        guard c.argc == 2, r.isObject, om.classIndex(of: r) == WellKnown.byteArray, c.arg0.isCharacter, c.arg1.isSmallInteger
        else { return .none }
        let bytes = encodeScalar(c.arg0.characterValue)
        let i = Int(c.arg1.smallIntegerValue) - 1
        guard i >= 0, i + bytes.count <= Int(om.count(of: r)) else { return .none }
        if om.isReadOnly(r) { return m.refuseReadOnly(r, at: c.arg1, value: c.arg0) }
        for (k, b) in bytes.enumerated() { unsafe checkedStoreByte(m.state, r, i + k, b) }
        return Oop(smallInteger: Int64(bytes.count))
    case 129:
        guard c.argc == 0, m.isText(r) else { return .none }
        return m.intern(r)
    case 130, 131:
        guard c.argc == 0, r.isObject, om.isBytes(r) else { return .none }
        let b = om.bytes(of: r)
        if isValidUTF8(b) { return m.newString(b) }
        return n == 131 ? m.newString(repairedUTF8(b)) : .none
    case 132:
        guard c.argc == 1, r.isObject, om.isBytes(r), c.arg0.isSmallInteger else { return .none }
        let i = c.arg0.smallIntegerValue
        guard i >= 1, i <= Int64(om.count(of: r)) else { return .none }
        return Oop(smallInteger: Int64(om.loadByte(r, Int(i - 1))))
    case 133:
        guard c.argc == 0, r.isObject, om.isBytes(r) else { return .none }
        return Oop(smallInteger: Int64(om.count(of: r)))
    case 134:
        guard c.argc == 2, m.isText(r), m.isText(c.arg0), c.arg1.isSmallInteger else { return .none }
        let start = Int(c.arg1.smallIntegerValue) - 1
        guard m.isBoundary(r, start) else { return .none }
        let hay = om.bytes(of: r), needle = om.bytes(of: c.arg0)
        if needle.isEmpty { return Oop(smallInteger: Int64(start + 1)) }
        var i = start
        while i + needle.count <= hay.count {
            if hay[i] == needle[0] && Array(hay[i..<(i + needle.count)]) == needle { return Oop(smallInteger: Int64(i + 1)) }
            i += 1
        }
        return Oop(smallInteger: 0)
    case 135:
        guard c.argc == 1, m.isText(c.arg0) else { return .none }
        let bytes = om.bytes(of: c.arg0)
        let s = om.symbolLookup(unsafe m.state.pointee.symbolTable, hash: utf8Hash(bytes)) { om.sameBytes($0, bytes) }
        return s == .none ? m.nilObject : s
    default:
        return .none
    }
}
