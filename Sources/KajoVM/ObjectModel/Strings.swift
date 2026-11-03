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

func encodeScalarBytes(_ v: UInt32) -> [UInt8] {
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

    /// A new String of `n` bytes, zeroed (the caller fills it with valid
    /// UTF-8 before anything else can see it).
    @inline(__always)
    func newString(count n: Int) -> Oop {
        guard n <= Header.maxBytes else { return .none }
        return allocateBytes(WellKnown.string, count: n)
    }

    /// Copy `n` bytes of `src` from `i` into the fresh `dst` at `j`.
    @inline(__always)
    func copyBytes(_ src: Oop, _ i: Int, into dst: Oop, _ j: Int, _ n: Int) {
        var k = 0
        while k < n {
            om.storeByte(dst, j &+ k, om.loadByte(src, i &+ k))
            k &+= 1
        }
    }

    /// 0-based offset `i` is a scalar boundary of text `o` (the end counts).
    func isBoundary(_ o: Oop, _ i: Int) -> Bool {
        let n = Int(om.count(of: o))
        guard i >= 0, i <= n else { return false }
        if om.config.testSwitches.noBoundaryCheck { return true }
        return i == n || om.loadByte(o, i) & 0xC0 != 0x80
    }

    /// The bytes of `o` are well-formed UTF-8 (read in place).
    func isValidUTF8(_ o: Oop) -> Bool {
        let n = Int(om.count(of: o))
        var i = 0
        while i < n {
            guard let (_, len) = decodeScalar(n, i, { om.loadByte(o, $0) }) else { return false }
            i &+= len
        }
        return true
    }

    /// The Symbol with the bytes of text `o`, interned if new: the lookup
    /// reads the table and compares bytes in place; a new Symbol is made
    /// and inserted with the world stopped (looked up again inside the
    /// stop), so two workers never intern the same bytes twice.
    func intern(_ o: Oop) -> Oop {
        if om.classIndex(of: o) == WellKnown.symbol { return o }
        let h = om.byteObjectHash(o)
        let found = om.symbolLookupSlot(unsafe state.pointee.symbolTable, hash: h) { om.sameBytes($0, o) }
        if found.symbol != .none {
            unsafe weakReadBarrier(state, found.bucket, found.slot, found.symbol)
            return found.symbol
        }
        return internSlow(o, h)
    }

    @inline(never)
    private func internSlow(_ o: Oop, _ h: Int64) -> Oop {
        var result = Oop.none
        if let vm = unsafe workerOf(state).pointee.vm {
            unsafe stopWorld(vm, workerOf(state), retry: true, keeping: [o]) { stop in
                result = insertSymbol(o, hash: h, roots: stop.roots() + [o])
            }
        } else {
            result = insertSymbol(o, hash: h, roots: rootsForPause() + [o])
        }
        return result
    }

    /// World stopped (or no VM): look up again, else make the Symbol (old,
    /// pinned, read-only) and put it in its bucket, growing the bucket.
    private func insertSymbol(_ o: Oop, hash h: Int64, roots: [Oop]) -> Oop {
        let table = unsafe state.pointee.symbolTable
        let again = om.symbolLookup(table, hash: h) { om.sameBytes($0, o) }
        if again != .none { return again }
        let ctx = unsafe state.pointee.context
        let n = Int(om.count(of: o))
        guard let sym = om.allocateBytes(ctx, classIndex: WellKnown.symbol, count: n, extraRoots: roots) else {
            return .none
        }
        copyBytes(o, 0, into: sym, 0, n)
        om.pinForGood(sym)
        om.setReadOnly(sym, true)
        if let (b, i) = om.symbolSlot(table, hash: h) {
            store(b, i, sym, .symbolTable)
        } else {
            let j = Int(truncatingIfNeeded: h) & (SymbolTable.buckets - 1)
            let old = om.load(table, j)
            let k = old == nilObject ? 0 : Int(om.count(of: old))
            guard let size = SymbolTable.grownBucketSize(k),
                  let nb = om.allocate(ctx, classIndex: WellKnown.weakArray, slots: size, fill: nilObject, extraRoots: roots + [sym])
            else { return .none }
            // the bucket is full (no hole), so every slot holds a Symbol
            for x in 0..<k { store(nb, x, om.load(old, x), .symbolTable) }
            store(nb, k, sym, .symbolTable)
            store(table, j, nb, .symbolTable)
        }
        unsafe state.pointee.counters.symbolsInterned &+= 1
        return sym
    }

    /// A String of the bytes of `o` with each ill-formed sequence replaced by
    /// U+FFFD. Cold: through a Swift String.
    @inline(never)
    func repairedString(_ o: Oop) -> Oop {
        let fixed = repairedUTF8(om.bytes(of: o))
        let r = newString(count: fixed.count)
        if r == .none { return .none }
        for (i, b) in fixed.enumerated() { om.storeByte(r, i, b) }
        return r
    }
}

/// UTF-8 of scalar `v` into the bytes of `o` from 0-based `i` (room checked
/// by the caller): the byte count.
@inline(__always)
func encodeScalar(_ v: UInt32, into store: (Int, UInt8) -> Void) -> Int {
    switch v {
    case 0..<0x80:
        store(0, UInt8(v))
        return 1
    case 0x80..<0x800:
        store(0, UInt8(0xC0 | v >> 6)); store(1, UInt8(0x80 | v & 0x3F))
        return 2
    case 0x800..<0x10000:
        store(0, UInt8(0xE0 | v >> 12)); store(1, UInt8(0x80 | v >> 6 & 0x3F)); store(2, UInt8(0x80 | v & 0x3F))
        return 3
    default:
        store(0, UInt8(0xF0 | v >> 18)); store(1, UInt8(0x80 | v >> 12 & 0x3F)); store(2, UInt8(0x80 | v >> 6 & 0x3F))
        store(3, UInt8(0x80 | v & 0x3F))
        return 4
    }
}

@inline(__always)
func scalarByteCount(_ v: UInt32) -> Int { v < 0x80 ? 1 : v < 0x800 ? 2 : v < 0x10000 ? 3 : 4 }

/// Strings and bytes (primitives 120 to 136). No Swift arrays: every byte
/// is read and written in the heap (`just arc-check` checks this function
/// has no retain or release), except repairing invalid input and making a
/// new Symbol, which are out of line.
@inline(never)
func stringPrimitive(_ n: Int, _ m: Machine, _ c: PrimitiveCall) -> Oop {
    let om = m.om
    let r = c.receiver
    switch n {
    case 120, 121:
        guard c.argc == 1, m.isText(r), m.isText(c.arg0) else { return .none }
        if n == 121 { return m.boolean(om.sameBytes(r, c.arg0)) }
        let a = Int(om.count(of: r)), b = Int(om.count(of: c.arg0))
        var i = 0
        while i < a && i < b {
            let x = om.loadByte(r, i), y = om.loadByte(c.arg0, i)
            if x != y { return Oop(smallInteger: x < y ? -1 : 1) }
            i &+= 1
        }
        return Oop(smallInteger: a < b ? -1 : a == b ? 0 : 1)
    case 122:
        guard c.argc == 0, m.isText(r) else { return .none }
        return Oop(smallInteger: om.byteObjectHash(r))
    case 123:
        guard c.argc == 1, m.isText(r), m.isText(c.arg0) else { return .none }
        let a = Int(om.count(of: r)), b = Int(om.count(of: c.arg0))
        let s = m.newString(count: a + b)
        if s == .none { return .none }
        m.copyBytes(r, 0, into: s, 0, a)
        m.copyBytes(c.arg0, 0, into: s, a, b)
        return s
    case 124, 136:
        guard c.argc == 1, m.isText(r), c.arg0.isSmallInteger else { return .none }
        let i = Int(truncatingIfNeeded: c.arg0.smallIntegerValue) &- 1
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
        return m.boolean(m.isBoundary(r, Int(truncatingIfNeeded: c.arg0.smallIntegerValue) &- 1))
    case 126:
        guard c.argc == 0, m.isText(r) else { return .none }
        var k: Int64 = 0
        for i in 0..<Int(om.count(of: r)) where om.loadByte(r, i) & 0xC0 != 0x80 { k &+= 1 }
        return Oop(smallInteger: k)
    case 127:
        guard c.argc == 2, m.isText(r), c.arg0.isSmallInteger, c.arg1.isSmallInteger else { return .none }
        // [a, b) 0-based
        let a = Int(truncatingIfNeeded: c.arg0.smallIntegerValue) &- 1, b = Int(truncatingIfNeeded: c.arg1.smallIntegerValue)
        guard a >= 0, b >= a, b <= Int(om.count(of: r)), m.isBoundary(r, a), m.isBoundary(r, b) else { return .none }
        let s = m.newString(count: b - a)
        if s == .none { return .none }
        m.copyBytes(r, a, into: s, 0, b - a)
        return s
    case 128:
        // aByteArray encode: aCharacter at: offset -> bytes written
        guard c.argc == 2, r.isObject, om.classIndex(of: r) == WellKnown.byteArray, c.arg0.isCharacter, c.arg1.isSmallInteger
        else { return .none }
        let v = c.arg0.characterValue
        let i = Int(truncatingIfNeeded: c.arg1.smallIntegerValue) &- 1
        guard i >= 0, i + scalarByteCount(v) <= Int(om.count(of: r)) else { return .none }
        if om.isReadOnly(r) { return m.refuseReadOnly(r, at: c.arg1, value: c.arg0) }
        let st = unsafe m.state
        let k = encodeScalar(v) { j, b in unsafe checkedStoreByte(st, r, i &+ j, b) }
        return Oop(smallInteger: Int64(k))
    case 129:
        guard c.argc == 0, m.isText(r) else { return .none }
        return m.intern(r)
    case 130, 131:
        guard c.argc == 0, r.isObject, om.isBytes(r) else { return .none }
        if m.isValidUTF8(r) {
            let count = Int(om.count(of: r))
            let s = m.newString(count: count)
            if s == .none { return .none }
            m.copyBytes(r, 0, into: s, 0, count)
            return s
        }
        return n == 131 ? m.repairedString(r) : .none
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
        let start = Int(truncatingIfNeeded: c.arg1.smallIntegerValue) &- 1
        guard m.isBoundary(r, start) else { return .none }
        let hay = Int(om.count(of: r)), k = Int(om.count(of: c.arg0))
        var i = start
        while i + k <= hay {
            var j = 0
            while j < k && om.loadByte(r, i &+ j) == om.loadByte(c.arg0, j) { j &+= 1 }
            if j == k { return Oop(smallInteger: Int64(i + 1)) }
            i &+= 1
        }
        return Oop(smallInteger: 0)
    case 135:
        guard c.argc == 1, m.isText(c.arg0) else { return .none }
        let t = c.arg0
        let f = om.symbolLookupSlot(unsafe m.state.pointee.symbolTable, hash: om.byteObjectHash(t)) { om.sameBytes($0, t) }
        if f.symbol == .none { return m.nilObject }
        unsafe weakReadBarrier(m.state, f.bucket, f.slot, f.symbol)
        return f.symbol
    default:
        return .none
    }
}
