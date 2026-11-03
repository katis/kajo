// Numbers (ADR 0009 sections 2 and 7): SmallInteger, LargePositiveInteger
// and LargeNegativeInteger (byte objects holding the magnitude
// little-endian, normalized: no leading zero byte, and never a value that
// fits a SmallInteger), SmallFloat (immediate) and Float (8 bytes, a boxed
// double for what SmallFloat cannot hold). Every result is normalized: an
// integer that fits is a SmallInteger, a double that fits is a SmallFloat.
//
// The special-send bytecodes keep their SmallInteger fast path inline in
// the dispatch loop; this file is the out-of-line tier behind it (and the
// arithmetic primitives 40 to 75 the kernel's methods name): overflow into
// LargeIntegers, floats, and mixes. Printing, parsing, gcd: and Fraction
// are Smalltalk (8b).

/// An integer as sign and magnitude, 32-bit limbs little-endian. Cold:
/// LargeInteger arithmetic allocates Swift arrays (ARC is fine off the hot
/// paths, which never reach here for SmallIntegers that do not overflow).
struct BigInt: Equatable {
    var negative: Bool
    var limbs: [UInt32]  // no trailing zero limb; empty is zero

    init(negative: Bool, limbs: [UInt32]) {
        var l = limbs
        while l.last == 0 { l.removeLast() }
        self.negative = l.isEmpty ? false : negative
        self.limbs = l
    }

    init(_ v: Int64) {
        let m = v.magnitude
        self.init(negative: v < 0, limbs: [UInt32(truncatingIfNeeded: m), UInt32(truncatingIfNeeded: m >> 32)])
    }

    init(negative: Bool, bytes: [UInt8]) {
        var l = [UInt32](repeating: 0, count: (bytes.count + 3) / 4)
        for (i, b) in bytes.enumerated() { l[i / 4] |= UInt32(b) << (8 * UInt32(i % 4)) }
        self.init(negative: negative, limbs: l)
    }

    var isZero: Bool { limbs.isEmpty }

    var bytes: [UInt8] {
        var out: [UInt8] = []
        for l in limbs { for k in 0..<4 { out.append(UInt8(truncatingIfNeeded: l >> (8 * UInt32(k)))) } }
        while out.last == 0 { out.removeLast() }
        return out
    }

    /// The value as an Int64 if it fits.
    var int64: Int64? {
        if limbs.count > 2 { return nil }
        let m = UInt64(limbs.count > 0 ? limbs[0] : 0) | UInt64(limbs.count > 1 ? limbs[1] : 0) << 32
        if negative { return m <= UInt64(Int64.max) + 1 ? Int64(truncatingIfNeeded: 0 &- m) : nil }
        return m <= UInt64(Int64.max) ? Int64(m) : nil
    }

    var double: Double {
        var d = 0.0
        for l in limbs.reversed() { d = d * 4294967296.0 + Double(l) }
        return negative ? -d : d
    }

    static func compareMagnitude(_ a: [UInt32], _ b: [UInt32]) -> Int {
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        for i in stride(from: a.count - 1, through: 0, by: -1) where a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
        return 0
    }

    static func addMagnitude(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: max(a.count, b.count) + 1)
        var carry: UInt64 = 0
        for i in 0..<out.count {
            let x = UInt64(i < a.count ? a[i] : 0) + UInt64(i < b.count ? b[i] : 0) + carry
            out[i] = UInt32(truncatingIfNeeded: x)
            carry = x >> 32
        }
        return out
    }

    /// a - b with |a| >= |b|.
    static func subMagnitude(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var out = a
        var borrow: Int64 = 0
        for i in 0..<out.count {
            var x = Int64(a[i]) - Int64(i < b.count ? b[i] : 0) - borrow
            borrow = 0
            if x < 0 { x += 1 << 32; borrow = 1 }
            out[i] = UInt32(x)
        }
        return out
    }

    static func + (a: BigInt, b: BigInt) -> BigInt {
        if a.negative == b.negative { return BigInt(negative: a.negative, limbs: addMagnitude(a.limbs, b.limbs)) }
        let c = compareMagnitude(a.limbs, b.limbs)
        if c == 0 { return BigInt(0) }
        return c > 0 ? BigInt(negative: a.negative, limbs: subMagnitude(a.limbs, b.limbs))
                     : BigInt(negative: b.negative, limbs: subMagnitude(b.limbs, a.limbs))
    }

    static prefix func - (a: BigInt) -> BigInt { BigInt(negative: !a.negative, limbs: a.limbs) }

    static func - (a: BigInt, b: BigInt) -> BigInt { a + -b }

    static func * (a: BigInt, b: BigInt) -> BigInt {
        if a.isZero || b.isZero { return BigInt(0) }
        var out = [UInt32](repeating: 0, count: a.limbs.count + b.limbs.count)
        for i in 0..<a.limbs.count {
            var carry: UInt64 = 0
            for j in 0..<b.limbs.count {
                let x = UInt64(a.limbs[i]) * UInt64(b.limbs[j]) + UInt64(out[i + j]) + carry
                out[i + j] = UInt32(truncatingIfNeeded: x)
                carry = x >> 32
            }
            var k = i + b.limbs.count
            while carry > 0 {
                let x = UInt64(out[k]) + carry
                out[k] = UInt32(truncatingIfNeeded: x)
                carry = x >> 32
                k += 1
            }
        }
        return BigInt(negative: a.negative != b.negative, limbs: out)
    }

    /// Truncated quotient and remainder of the magnitudes (binary long
    /// division; b nonzero).
    static func divModMagnitude(_ a: [UInt32], _ b: [UInt32]) -> ([UInt32], [UInt32]) {
        if compareMagnitude(a, b) < 0 { return ([], a) }
        if b.count == 1 {
            var q = [UInt32](repeating: 0, count: a.count)
            var r: UInt64 = 0
            let d = UInt64(b[0])
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                let x = r << 32 | UInt64(a[i])
                q[i] = UInt32(x / d)
                r = x % d
            }
            return (q, [UInt32(r)])
        }
        var q = [UInt32](repeating: 0, count: a.count)
        var r: [UInt32] = []
        for i in stride(from: a.count * 32 - 1, through: 0, by: -1) {
            // r = r << 1 | bit i of a
            var carry = (a[i / 32] >> UInt32(i % 32)) & 1
            for k in 0..<r.count {
                let nc = r[k] >> 31
                r[k] = r[k] << 1 | carry
                carry = nc
            }
            if carry != 0 { r.append(carry) }
            while r.last == 0 { r.removeLast() }
            if compareMagnitude(r, b) >= 0 {
                r = subMagnitude(r, b)
                while r.last == 0 { r.removeLast() }
                q[i / 32] |= 1 << UInt32(i % 32)
            }
        }
        return (q, r)
    }

    /// Truncated division (`quo:` and `rem:`).
    func quoRem(_ b: BigInt) -> (BigInt, BigInt) {
        let (q, r) = BigInt.divModMagnitude(limbs, b.limbs)
        return (BigInt(negative: negative != b.negative, limbs: q), BigInt(negative: negative, limbs: r))
    }

    /// Floor division (`//` and `\\`).
    func floorDivMod(_ b: BigInt) -> (BigInt, BigInt) {
        var (q, r) = quoRem(b)
        if !r.isZero && r.negative != b.negative {
            q = q - BigInt(1)
            r = r + b
        }
        return (q, r)
    }

    static func compare(_ a: BigInt, _ b: BigInt) -> Int {
        if a.negative != b.negative { return a.negative ? -1 : 1 }
        let c = compareMagnitude(a.limbs, b.limbs)
        return a.negative ? -c : c
    }

    /// Two's complement limbs over `n` limbs (infinite sign extension).
    func twosComplement(_ n: Int) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: n)
        for i in 0..<min(n, limbs.count) { out[i] = limbs[i] }
        if negative {
            var carry: UInt64 = 1
            for i in 0..<n {
                let x = UInt64(~out[i]) + carry
                out[i] = UInt32(truncatingIfNeeded: x)
                carry = x >> 32
            }
        }
        return out
    }

    static func fromTwosComplement(_ l: [UInt32]) -> BigInt {
        guard let top = l.last, top & 0x8000_0000 != 0 else { return BigInt(negative: false, limbs: l) }
        var m = l
        var carry: UInt64 = 1
        for i in 0..<m.count {
            let x = UInt64(~m[i]) + carry
            m[i] = UInt32(truncatingIfNeeded: x)
            carry = x >> 32
        }
        return BigInt(negative: true, limbs: m)
    }

    static func bitwise(_ a: BigInt, _ b: BigInt, _ f: (UInt32, UInt32) -> UInt32) -> BigInt {
        let n = max(a.limbs.count, b.limbs.count) + 1
        let x = a.twosComplement(n), y = b.twosComplement(n)
        return fromTwosComplement((0..<n).map { f(x[$0], y[$0]) })
    }

    /// Shift left (positive) or arithmetic right (negative: floor).
    func shifted(_ k: Int) -> BigInt {
        if isZero || k == 0 { return self }
        if k > 0 {
            let words = k / 32, bits = UInt32(k % 32)
            var out = [UInt32](repeating: 0, count: limbs.count + words + 1)
            for (i, l) in limbs.enumerated() {
                out[i + words] |= l << bits
                if bits > 0 { out[i + words + 1] |= l >> (32 - bits) }
            }
            return BigInt(negative: negative, limbs: out)
        }
        // floor(self / 2^-k)
        let d = BigInt(negative: false, limbs: [1]).shifted(-k)
        return floorDivMod(d).0
    }
}

extension Machine {
    /// The integer an oop holds: a SmallInteger or a normalized-or-not
    /// LargeInteger byte object.
    func bigInt(_ v: Oop) -> BigInt? {
        if v.isSmallInteger { return BigInt(v.smallIntegerValue) }
        guard v.isObject else { return nil }
        let c = om.classIndex(of: v)
        guard c == WellKnown.largePositiveInteger || c == WellKnown.largeNegativeInteger, om.isBytes(v) else { return nil }
        return BigInt(negative: c == WellKnown.largeNegativeInteger, bytes: om.bytes(of: v))
    }

    /// A normalized integer: a SmallInteger when it fits, else a new
    /// LargeInteger. `.none` when the heap is full (the error recorded).
    func integer(_ b: BigInt) -> Oop {
        if let v = b.int64, Oop.fitsSmallInteger(v) { return Oop(smallInteger: v) }
        let bytes = b.bytes
        guard bytes.count <= Header.maxBytes else { return .none }
        let o = allocateBytes(b.negative ? WellKnown.largeNegativeInteger : WellKnown.largePositiveInteger, count: bytes.count)
        if o == .none { return .none }
        for (i, x) in bytes.enumerated() { om.storeByte(o, i, x) }
        unsafe state.pointee.counters.largeIntegersMade &+= 1
        return o
    }

    /// The double an oop holds: a SmallFloat or a boxed Float.
    func double(_ v: Oop) -> Double? {
        if v.isSmallFloat { return v.smallFloatValue }
        guard v.isObject, om.classIndex(of: v) == WellKnown.float, om.isBytes(v), om.count(of: v) == 8 else { return nil }
        var bits: UInt64 = 0
        for i in 0..<8 { bits |= UInt64(om.loadByte(v, i)) << (8 * UInt64(i)) }
        return Double(bitPattern: bits)
    }

    /// A float, normalized: a SmallFloat when it fits, else a new boxed
    /// Float (the out-of-line case).
    func float(_ d: Double) -> Oop {
        if let f = Oop(smallFloat: d) { return f }
        return boxFloat(d)
    }

    @inline(never)
    func boxFloat(_ d: Double) -> Oop {
        let o = allocateBytes(WellKnown.float, count: 8)
        if o == .none { return .none }
        let bits = d.bitPattern
        for i in 0..<8 { om.storeByte(o, i, UInt8(truncatingIfNeeded: bits >> (8 * UInt64(i)))) }
        unsafe state.pointee.counters.floatsBoxed &+= 1
        return o
    }

    /// A number as a double for mixed arithmetic: floats, SmallIntegers.
    func doubleOrInteger(_ v: Oop) -> Double? {
        if v.isSmallInteger { return Double(v.smallIntegerValue) }
        return double(v)
    }

    func boolean(_ b: Bool) -> Oop { b ? trueObject : falseObject }
}

/// The arithmetic and comparison operations of the special sends and the
/// number primitives.
enum ArithOp: Int {
    case add, sub, mul, lt, gt, le, ge, eq, div, intDiv, mod, ne, quo, rem, bitAnd, bitOr, bitXor, bitShift

    /// The operation of special selector `index` (Opcode.specialIndex), if
    /// it is one.
    static func special(_ index: Int) -> ArithOp? {
        switch index {
        case 0: .add
        case 1: .sub
        case 2: .mul
        case 3: .lt
        case 4: .gt
        case 5: .le
        case 6: .ge
        case 7: .eq
        case 9: .div
        case 10: .intDiv
        case 11: .mod
        case 12: .ne
        default: nil
        }
    }
}

extension Machine {
    /// `a op b` for integers (any mix of SmallInteger and LargeInteger):
    /// `.none` when it does not apply (not integers, a zero divisor, an
    /// inexact `/`, which is Fraction's in the kernel). May allocate.
    func integerArith(_ op: ArithOp, _ a: Oop, _ b: Oop) -> Oop {
        if a.isSmallInteger && b.isSmallInteger {
            let x = a.smallIntegerValue, y = b.smallIntegerValue
            switch op {
            case .add: return Oop.fitsSmallInteger(x + y) ? Oop(smallInteger: x + y) : integer(BigInt(x + y))
            case .sub: return Oop.fitsSmallInteger(x - y) ? Oop(smallInteger: x - y) : integer(BigInt(x - y))
            case .mul:
                let (p, o) = x.multipliedReportingOverflow(by: y)
                if !o && Oop.fitsSmallInteger(p) { return Oop(smallInteger: p) }
                return integer(BigInt(x) * BigInt(y))
            case .lt: return boolean(x < y)
            case .gt: return boolean(x > y)
            case .le: return boolean(x <= y)
            case .ge: return boolean(x >= y)
            case .eq: return boolean(x == y)
            case .ne: return boolean(x != y)
            case .div:
                guard y != 0, x % y == 0 else { return .none }
                return Oop.fitsSmallInteger(x / y) ? Oop(smallInteger: x / y) : integer(BigInt(x / y))
            case .intDiv, .mod:
                guard y != 0 else { return .none }
                var q = x / y
                if x % y != 0 && (x < 0) != (y < 0) { q -= 1 }
                let r = x - q * y
                let v = op == .intDiv ? q : r
                return Oop.fitsSmallInteger(v) ? Oop(smallInteger: v) : integer(BigInt(v))
            case .quo, .rem:
                guard y != 0 else { return .none }
                let v = op == .quo ? x / y : x % y
                return Oop.fitsSmallInteger(v) ? Oop(smallInteger: v) : integer(BigInt(v))
            case .bitAnd: return Oop(smallInteger: x & y)
            case .bitOr: return Oop(smallInteger: x | y)
            case .bitXor: return Oop(smallInteger: x ^ y)
            case .bitShift:
                if y <= 0 { return Oop(smallInteger: y <= -63 ? (x < 0 ? -1 : 0) : x >> -y) }
                if y < 62 {
                    let v = x << y
                    if v >> y == x && Oop.fitsSmallInteger(v) { return Oop(smallInteger: v) }
                }
                guard y <= 1 << 16 else { return .none }
                return integer(BigInt(x).shifted(Int(y)))
            }
        }
        guard let x = bigInt(a), let y = bigInt(b) else { return .none }
        let c = BigInt.compare(x, y)
        switch op {
        case .add: return integer(x + y)
        case .sub: return integer(x - y)
        case .mul:
            guard x.limbs.count + y.limbs.count <= Header.maxBytes / 4 else { return .none }
            return integer(x * y)
        case .lt: return boolean(c < 0)
        case .gt: return boolean(c > 0)
        case .le: return boolean(c <= 0)
        case .ge: return boolean(c >= 0)
        case .eq: return boolean(c == 0)
        case .ne: return boolean(c != 0)
        case .div:
            guard !y.isZero else { return .none }
            let (q, r) = x.quoRem(y)
            return r.isZero ? integer(q) : .none
        case .intDiv, .mod:
            guard !y.isZero else { return .none }
            let (q, r) = x.floorDivMod(y)
            return integer(op == .intDiv ? q : r)
        case .quo, .rem:
            guard !y.isZero else { return .none }
            let (q, r) = x.quoRem(y)
            return integer(op == .quo ? q : r)
        case .bitAnd: return integer(BigInt.bitwise(x, y, &))
        case .bitOr: return integer(BigInt.bitwise(x, y, |))
        case .bitXor: return integer(BigInt.bitwise(x, y, ^))
        case .bitShift:
            guard b.isSmallInteger, b.smallIntegerValue.magnitude <= 1 << 16 else { return .none }
            return integer(x.shifted(Int(b.smallIntegerValue)))
        }
    }

    /// `a op b` with a float on either side (SmallFloat or Float, the other
    /// a float or a SmallInteger): IEEE double arithmetic, the result
    /// normalized. `.none` when it does not apply (no float, a zero
    /// divisor, `//` and `\\` and the bit operations, which are the
    /// kernel's). May allocate (a boxed result).
    func floatArith(_ op: ArithOp, _ a: Oop, _ b: Oop) -> Oop {
        guard a.isSmallFloat || b.isSmallFloat || isBoxedFloat(a) || isBoxedFloat(b),
              let x = doubleOrInteger(a), let y = doubleOrInteger(b) else { return .none }
        switch op {
        case .add: return float(x + y)
        case .sub: return float(x - y)
        case .mul: return float(x * y)
        case .div: return y == 0 ? .none : float(x / y)
        case .lt: return boolean(x < y)
        case .gt: return boolean(x > y)
        case .le: return boolean(x <= y)
        case .ge: return boolean(x >= y)
        case .eq: return boolean(x == y)
        case .ne: return boolean(x != y)
        default: return .none
        }
    }

    func isBoxedFloat(_ v: Oop) -> Bool { v.isObject && om.classIndex(of: v) == WellKnown.float }

    /// The special sends' arithmetic tier: integers, then floats.
    func arith(_ op: ArithOp, _ a: Oop, _ b: Oop) -> Oop {
        let r = integerArith(op, a, b)
        if r != .none || failed { return r }
        return floatArith(op, a, b)
    }
}
