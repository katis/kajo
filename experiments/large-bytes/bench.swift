// Large bytes, the representation experiment (docs/modules/large-bytes.md,
// part 1): the bounds check and `size` of a byte object's fast path under
// the two candidates the brief names, on headers laid out as the VM lays
// them out (count in header bits 22..45, byte bit 47).
//
//   A, sentinel: the count field is exact below S = 2^24 - 8; at or past S
//      it holds S | (n & 7) and the true length comes from the back
//      reference's words. The fast check is today's `i < count`; only its
//      failure (and `size` on a byte object at or past S) asks for more.
//   B, words: the count field of a byte object is its body words and three
//      header bits (two free, one moved from another field) hold the
//      padding; every byte object's length is (words << 3) - pad, small
//      ones included. Modelled here with the pad in bits 51..53.
//
// swiftc -O bench.swift -o bench && ./bench          (timings)
// swiftc -O -S bench.swift | <the awk in RESULTS.md>  (instructions)
import Foundation

enum K {
    static let countShift: UInt64 = 22
    static let countMask: UInt64 = ((1 << 24) - 1) << 22
    static let bytesBit: UInt64 = 1 << 47
    static let padShift: UInt64 = 51
    static let padMask: UInt64 = 7 << 51
    static let S: UInt64 = (1 << 24) - 8
}

@inline(never) func checkA(_ h: UInt64, _ i: UInt64) -> Bool { i < (h & K.countMask) &>> K.countShift }
@inline(never) func checkB(_ h: UInt64, _ i: UInt64) -> Bool {
    i < (((h & K.countMask) &>> K.countShift) &<< 3) &- ((h & K.padMask) &>> K.padShift)
}
@inline(never) func sizeToday(_ h: UInt64) -> UInt64 { (h & K.countMask) &>> K.countShift }
@inline(never) func sizeA(_ h: UInt64, _ body: UnsafePointer<UInt64>) -> UInt64 {
    let c = (h & K.countMask) &>> K.countShift
    if h & K.bytesBit != 0 && c >= K.S { return sizeLong(c, body) }
    return c
}
@inline(never) func sizeLong(_ c: UInt64, _ body: UnsafePointer<UInt64>) -> UInt64 {
    let full = ((body[0] &>> 32) &- 1) &<< 3
    let odd = c & 7
    return odd == 0 ? full : full &- 8 &+ odd
}
@inline(never) func sizeB(_ h: UInt64) -> UInt64 {
    (((h & K.countMask) &>> K.countShift) &<< 3) &- ((h & K.padMask) &>> K.padShift)
}

func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

// 4096 small ByteArrays of 1..4000 bytes, as both candidates encode them.
var rng = SystemRandomNumberGenerator()
let n = 4096
var hA = [UInt64](repeating: 0, count: n), hB = hA, len = hA
for k in 0..<n {
    let b = UInt64.random(in: 1...4000, using: &rng)
    len[k] = b
    hA[k] = K.bytesBit | b << K.countShift | 7
    let words = (b + 7) >> 3
    hB[k] = K.bytesBit | words << K.countShift | (words * 8 - b) << K.padShift | 7
}
let body = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
body[0] = 1 << 32
var sink: UInt64 = 0
func run(_ name: String, _ f: () -> UInt64) {
    var best = UInt64.max
    for _ in 0..<7 {
        let t0 = now()
        sink &+= f()
        best = min(best, now() - t0)
    }
    print("\(name): \(String(format: "%.3f", Double(best) / Double(n * 2000))) ns per call")
}
run("check, A sentinel (today's)") { var c: UInt64 = 0; for r in 0..<2000 { for k in 0..<n where checkA(hA[k], UInt64(r)) { c &+= 1 } }; return c }
run("check, B words            ") { var c: UInt64 = 0; for r in 0..<2000 { for k in 0..<n where checkB(hB[k], UInt64(r)) { c &+= 1 } }; return c }
run("size, today               ") { var c: UInt64 = 0; for _ in 0..<2000 { for k in 0..<n { c &+= sizeToday(hA[k]) } }; return c }
run("size, A sentinel          ") { var c: UInt64 = 0; for _ in 0..<2000 { for k in 0..<n { c &+= sizeA(hA[k], body) } }; return c }
run("size, B words             ") { var c: UInt64 = 0; for _ in 0..<2000 { for k in 0..<n { c &+= sizeB(hB[k]) } }; return c }
print("disagreements: \((0..<n).filter { sizeA(hA[$0], body) != sizeB(hB[$0]) || sizeB(hB[$0]) != len[$0] }.count)")
// A long one under A: 1 GiB + 3 bytes.
let big: UInt64 = (1 << 30) + 3
body[0] = ((big + 7) / 8 + 1) << 32
let hBig = K.bytesBit | (K.S | (big & 7)) << K.countShift
print("A long: size \(sizeA(hBig, body)) (want \(big)); fast check of \(K.S - 1): \(checkA(hBig, K.S - 1)); of \(K.S + 3): \(checkA(hBig, K.S + 3)) (the slow path decides)")
print("sink \(sink % 10)")
