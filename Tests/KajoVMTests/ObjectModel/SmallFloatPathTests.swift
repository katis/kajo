// The third review's small fixes, part 2, item 2 (interpreter.M1): a
// special send or a float primitive (60 to 69) whose operands are a
// SmallFloat and a SmallFloat or a SmallInteger, and whose answer is a
// SmallFloat or a Boolean, is answered before any register save and builds
// no BigInt. The old path (the integer tier, then `floatArith`, behind a
// save) stays reachable through the test switch `noSmallFloatPath` and is
// the oracle: every answer must be the same.

import Foundation
import Testing
@testable import KajoVM

private let ops = ["add", "sub", "mul", "div", "lt", "gt", "le", "ge", "eq", "ne", "int_div", "mod"]

/// One method per special selector (`s_<op>:with:`) and one per float
/// primitive (`p<n>:with:`, sending `q<n>:` that SmallFloat answers with
/// primitive n).
private let pathSrc: String = {
    var s = ""
    for op in ops {
        s += "method UndefinedObject s_\(op):with: temps=0\n  push_temp 0\n  push_temp 1\n  \(op)\n  return_top\nend\n"
    }
    for n in 60...69 {
        s += "method Float q\(n): temps=0 prim=\(n)\nend\n"
        s += "method UndefinedObject p\(n):with: temps=0\n  push_temp 0\n  push_temp 1\n  send q\(n): 1\n  return_top\nend\n"
    }
    s += """
    ; t0 = n: n rounds of x := x * 0.999 + (i * 0.25), i < n (floats.kasm's step)
    method UndefinedObject floats: temps=2
      push_lit 1.0
      store_temp 1
      push_int 0
      store_temp 2
    loop:
      push_temp 2
      push_temp 0
      lt
      jump_if_false done
      push_temp 1
      push_lit 0.999
      mul
      push_temp 2
      push_lit 0.25
      mul
      add
      store_temp 1
      push_temp 2
      push_int 1
      add
      store_temp 2
      jump loop
    done:
      push_temp 1
      return_top
    end

    """
    return s + runOf(" push_int 0\n return_top")
}()

private func describe(_ h: Harness, _ r: Result<Oop, VMError>) -> String {
    switch r {
    case .failure(let e): return "error \(e.kind)"
    case .success(let v):
        if v.isSmallFloat { return "sf \(v.smallFloatValue.bitPattern)" }
        if v.isSmallInteger { return "int \(v.smallIntegerValue)" }
        if v == h.image.trueObject { return "true" }
        if v == h.image.falseObject { return "false" }
        if let d = h.interpreter.machine.double(v) { return "boxed \(d.bitPattern)" }
        return "other \(v)"
    }
}

@Test func theSmallFloatPathAnswersAsTheOldPath() throws {
    var off = TestSwitches()
    off.noSmallFloatPath = true
    let fast = try omHarness(pathSrc)
    let old = try omHarness(pathSrc, switches: off)
    defer { fast.destroy(); old.destroy() }
    var rng = FloatPathRandom(seed: 20261121)
    var doubles: [Double] = [0.0, -0.0, 1.5, -2.25, 3.0, 0.1, 1e-3, 123456.789, 1e30, -1e30, 1e150, 1e-150, 2.0, 0.5]
    for _ in 0..<12 { doubles.append(Double(Int64.random(in: -1_000_000...1_000_000, using: &rng)) / 64.0) }
    for _ in 0..<6 { doubles.append(Double(bitPattern: UInt64.random(in: 0...UInt64.max, using: &rng))) }
    var floats = doubles.compactMap { Oop(smallFloat: $0) }
    floats.append(contentsOf: [Double.nan, .infinity, -.infinity, 1e300, 1e-300].compactMap { Oop(smallFloat: $0) })
    var ints: [Int64] = [0, 1, -1, 3, -7, 1 << 53, (1 << 53) + 1, -(1 << 53) - 1, Oop.smallIntegerMax, Oop.smallIntegerMin]
    for _ in 0..<8 { ints.append(Int64.random(in: -(1 << 40)...(1 << 40), using: &rng)) }
    let intOops = ints.map { Oop(smallInteger: $0) }
    var pairs: [(Oop, Oop)] = []
    for a in floats { for b in floats { pairs.append((a, b)) } }
    for a in floats { for b in intOops { pairs.append((a, b)); pairs.append((b, a)) } }
    var compared = 0, differ: [String] = []
    for (a, b) in pairs {
        for sel in ops.map({ "s_\($0):with:" }) + (60...69).map({ "p\($0):with:" }) {
            let x = describe(fast, fast.interpreter.run(on: fast.stack, receiver: fast.image.nilObject, selector: sel, arguments: [a, b]))
            let y = describe(old, old.interpreter.run(on: old.stack, receiver: old.image.nilObject, selector: sel, arguments: [a, b]))
            compared += 1
            if x != y && differ.count < 20 { differ.append("\(sel) \(a) \(b): \(x) against \(y)") }
        }
    }
    let fastAnswers = fast.interpreter.floatPath.smallFloatAnswers, oldAnswers = old.interpreter.floatPath.smallFloatAnswers
    print("small-float path: \(compared) answers compared over \(pairs.count) pairs, \(differ.count) differ; smallFloatAnswers \(fastAnswers) and \(oldAnswers) with the switch")
    #expect(differ.isEmpty, "\(differ.joined(separator: "\n"))")
    #expect(fastAnswers > 0)
    #expect(oldAnswers == 0, "the switch does not switch")
}

/// The path builds nothing: the floats step (SmallInteger times SmallFloat,
/// SmallFloat times SmallFloat, an add, a compare) a hundred thousand times
/// allocates no heap object and never enters the LargeInteger tier, whose
/// `BigInt` is a Swift array; every special send of it is the path's.
@Test func theSmallFloatPathAllocatesNothing() throws {
    let h = try omHarness(pathSrc)
    defer { h.destroy() }
    let n: Int64 = 100_000
    let allocations = h.om.counters.allocations
    let v = try h.run("floats:", [n]).get()
    #expect(v.isSmallFloat)
    let c = h.interpreter.counters, f = h.interpreter.floatPath
    print("small-float path: allocations \(h.om.counters.allocations - allocations) largeArithCalls \(f.largeArithCalls) smallFloatAnswers \(f.smallFloatAnswers) floatsBoxed \(c.floatsBoxed)")
    #expect(h.om.counters.allocations == allocations)
    #expect(f.largeArithCalls == 0)
    #expect(c.floatsBoxed == 0)
    #expect(f.smallFloatAnswers == UInt64(3 * n))
}

/// A seeded generator (SplitMix64) for the operand table: the operands,
/// SmallFloats (signed zero, small and large magnitudes, random bit
/// patterns that encode) and SmallIntegers (zero, past 2^53, the extremes).
private struct FloatPathRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
