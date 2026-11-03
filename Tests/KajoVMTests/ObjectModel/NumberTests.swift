// SmallFloat and Character immediates, boxed Float, LargeIntegers and
// normalization (ADR 0009 sections 2 and 7).

import Testing
@testable import KajoVM

/// ADR 0009's open question: SmallFloat round-trips every double it holds
/// exactly, and holds exactly those with a biased exponent in 768...1279
/// (zero included, plus or minus 2^-255 boxed).
@Test func smallFloatRoundTripsExactlyAgainstDouble() {
    var g = SplitMix(seed: 7)
    var encoded = 0
    for i in 0..<200_000 {
        let bits = i < 100_000 ? g.next() : (g.next() & ~(0x7FF << 52)) | (UInt64(768 + Int(g.next() % 512)) << 52)
        let d = Double(bitPattern: bits)
        let e = Int((bits >> 52) & 0x7FF)
        let mant = bits & ((1 << 52) - 1)
        let zero = e == 0 && mant == 0
        let fits = zero || ((768...1279).contains(e) && !(e == 768 && mant == 0))
        if let o = Oop(smallFloat: d) {
            #expect(fits, "encoded \(d)")
            #expect(o.isSmallFloat && !o.isObject && !o.isSmallInteger && o.isValidImmediate)
            #expect(o.smallFloatValue.bitPattern == bits)
            encoded += 1
        } else {
            #expect(!fits, "boxed \(d) (exponent \(e))")
        }
    }
    #expect(encoded > 100_000)
    for d in [0.0, -0.0, 1.0, -1.5, 1e77, 1e-76, 3.14159] {
        #expect(Oop(smallFloat: d)?.smallFloatValue.bitPattern == d.bitPattern)
    }
    for d in [Double.nan, .infinity, -.infinity, 1e300, 1e-300, Double.leastNonzeroMagnitude, 0x1p-255, -0x1p-255] {
        #expect(Oop(smallFloat: d) == nil)
    }
}

@Test func charactersAreUnicodeScalars() {
    for v: UInt32 in [0, 65, 0xE9, 0x20AC, 0xFFFD, 0x1F600, 0x10FFFF] {
        let c = Oop(character: v)
        #expect(c.isCharacter && c.characterValue == v && c.isValidImmediate && !c.isSmallFloat)
    }
    #expect(!Oop(raw: UInt64(0xD800) << 4 | 4).isValidImmediate)
}

@Test func floatArithmeticOnTheSpecialSends() throws {
    let h = try omHarness("""
    method UndefinedObject f temps=0
      push_lit 1.5
      push_lit 2.25
      add
      push_int 2
      mul
      return_top
    end
    method UndefinedObject big temps=0
      push_lit 1e70
      push_lit 1e70
      mul
      return_top
    end
    method UndefinedObject back temps=0
      push_lit 1e70
      push_lit 1e70
      mul
      push_lit 1e70
      div
      return_top
    end
    method UndefinedObject cmp temps=0
      push_lit 2.5
      push_int 3
      lt
      return_top
    end
    method UndefinedObject trunc temps=0
      push_lit -7.75
      send truncated 0
      return_top
    end
    """ + runOf(" push_int 0\n return_top"))
    defer { h.destroy() }
    let m = h.interpreter.machine
    let f = try h.run("f", []).get()
    #expect(f.isSmallFloat && f.smallFloatValue == 7.5)
    let big = try h.run("big", []).get()
    #expect(big.isObject && h.om.classIndex(of: big) == WellKnown.float && m.double(big) == 1e140)
    // a boxed Float times back into SmallFloat range: normalized
    let back = try h.run("back", []).get()
    #expect(back.isSmallFloat && back.smallFloatValue == (1e70 * 1e70) / 1e70)  // IEEE, as Swift computes it
    #expect(try h.run("cmp", []).get() == h.image.trueObject)
    #expect(try h.value("trunc", []) == -7)
    #expect(h.interpreter.counters.floatsBoxed == 2)
}

/// Integer arithmetic against Swift's Int128 over random operands near and
/// beyond the SmallInteger range: every result normalized (a SmallInteger
/// whenever it fits, else a LargeInteger with no leading zero byte).
@Test func largeIntegerArithmeticAgainstInt128() throws {
    let h = try omHarness(runOf(" push_int 0\n return_top"))
    defer { h.destroy() }
    let m = h.interpreter.machine
    func oop(_ v: Int128) -> Oop { m.integer(BigInt(negative: v < 0, bytes: magnitudeLE(v.magnitude))) }
    func value(_ o: Oop) -> Int128? {
        guard let b = m.bigInt(o) else { return nil }
        var v: Int128 = 0
        for l in b.limbs.reversed() { v = v << 32 | Int128(l) }
        return b.negative ? -v : v
    }
    func normalized(_ o: Oop) -> Bool {
        if o.isSmallInteger { return true }
        let b = h.om.bytes(of: o)
        guard b.last != 0, let v = value(o) else { return false }
        return !(v >= Int128(Oop.smallIntegerMin) && v <= Int128(Oop.smallIntegerMax))
    }
    var g = SplitMix(seed: 3)
    for _ in 0..<3000 {
        let a = Int128(Int64(bitPattern: g.next())) >> Int(g.next() % 64)
        let b = Int128(Int64(bitPattern: g.next())) >> Int(g.next() % 64)
        let x = oop(a), y = oop(b)
        #expect(normalized(x) && normalized(y))
        let ops: [(ArithOp, Int128?)] = [
            (.add, a + b), (.sub, a - b), (.mul, a.multipliedReportingOverflow(by: b).overflow ? nil : a * b),
            (.quo, b == 0 ? nil : a / b), (.rem, b == 0 ? nil : a % b),
            (.intDiv, b == 0 ? nil : floorDiv(a, b)), (.mod, b == 0 ? nil : a - floorDiv(a, b) * b),
            (.bitAnd, a & b), (.bitOr, a | b), (.bitXor, a ^ b),
        ]
        for (op, want) in ops {
            guard let want else { continue }
            let r = m.integerArith(op, x, y)
            #expect(value(r) == want && normalized(r), "\(a) \(op) \(b)")
        }
        #expect((m.integerArith(.lt, x, y) == h.image.trueObject) == (a < b))
        let k = Int64(g.next() % 60) - 30
        let shifted = m.integerArith(.bitShift, x, Oop(smallInteger: k))
        if a.magnitude < (1 << 90) { #expect(value(shifted) == (k >= 0 ? a << k : a >> -k)) }
    }
}

private func floorDiv(_ a: Int128, _ b: Int128) -> Int128 {
    let q = a / b
    return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
}

private func magnitudeLE(_ v: UInt128) -> [UInt8] {
    var out: [UInt8] = []
    var x = v
    while x != 0 { out.append(UInt8(truncatingIfNeeded: x)); x >>= 8 }
    return out
}

/// The rule: a LargeInteger result that fits is a SmallInteger.
/// (2^62 + 5) - 10 is a SmallInteger; with normalization off (test switch)
/// it stays a LargePositiveInteger, and `==` with the SmallInteger fails.
@Test(arguments: [false, true])
func largeIntegerResultsAreNormalized(_ broken: Bool) throws {
    var sw = TestSwitches()
    sw.noNormalization = broken
    let h = try omHarness(runOf("""
      push_lit 4611686018427387909
      push_int 10
      sub
      push_lit 4611686018427387899
      identical
      jump_if_false no
      push_int 1
      return_top
    no:
      push_int 0
      return_top
    """), switches: sw)
    defer { h.destroy() }
    #expect(try h.value() == (broken ? 0 : 1))
}

@Test func largeIntegerLiteralsAreReadOnlyAndExact() throws {
    let h = try omHarness(runOf("""
      push_lit 123456789012345678901234567890
      push_lit -123456789012345678901234567890
      add
      return_top
    """))
    defer { h.destroy() }
    #expect(try h.value() == 0)
    let m = try #require(h.image.lookup(WellKnown.undefinedObject, h.image.symbol("run:of:")!))
    let lit = h.om.load(h.om.load(m, MethodLayout.literals), 0)
    #expect(h.om.classIndex(of: lit) == WellKnown.largePositiveInteger && h.om.isReadOnly(lit))
}
