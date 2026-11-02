// The chase microbenchmark of Part 1 without the VM (SPEC.md "Part 1"):
// entry-locality's `chase` mode (one random cyclic permutation over
// 64-byte nodes, word 0 = address of the next node), rebuilt here so the
// energy sample brackets the hops only (entry-locality's runChase samples
// around the build too). Single thread: the calling thread.

import Darwin

public struct ChaseResult: Sendable {
    public var nodes: Int
    public var hops: Int
    public var buildNs: UInt64
    public var hopNs: UInt64
    public var sink: UInt
    public var usage: UsageDelta
    public var nsPerHop: Double { Double(hopNs) / Double(hops) }
}

@inline(never)
public func chaseHops(_ start: UInt, _ hops: Int) -> UInt {
    var p = start
    var i = hops
    while i > 0 {
        p = UnsafePointer<UInt>(bitPattern: p).unsafelyUnwrapped.pointee
        i &-= 1
    }
    return p
}

/// Build a random cycle over `sizeMB` MiB of 64-byte nodes (Sattolo's
/// algorithm, xorshift seed), warm up with one lap's worth of hops capped at
/// 2^22, then time `hops` hops with a ProcUsage sample on each side.
public func runChase(sizeMB: Int, hops: Int, seed: UInt64 = 0x9E37_79B9_7F4A_7C15) -> ChaseResult {
    let n = max(2, (sizeMB << 20) / 64)
    let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    let mem = UnsafeMutableRawPointer.allocate(byteCount: n * 64, alignment: 16384)
    let base = UInt(bitPattern: mem)
    var perm = [UInt32](repeating: 0, count: n)
    for i in 0..<n { perm[i] = UInt32(i) }
    var s = seed
    func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
    var i = n - 1
    while i > 0 {
        let j = Int(next() % UInt64(i))
        perm.swapAt(i, j)
        i -= 1
    }
    // perm is a single cycle (Sattolo): node perm[k] -> perm[k+1].
    for k in 0..<n {
        let from = Int(perm[k]), to = Int(perm[(k + 1) % n])
        mem.storeBytes(of: base &+ UInt(to * 64), toByteOffset: from * 64, as: UInt.self)
    }
    let buildNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- t0
    var p = chaseHops(base, min(n, 1 << 22))
    let u0 = ProcUsage.now()
    let h0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    p = chaseHops(p, hops)
    let h1 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    let u1 = ProcUsage.now()
    mem.deallocate()
    return ChaseResult(nodes: n, hops: hops, buildNs: buildNs, hopNs: h1 &- h0, sink: p, usage: UsageDelta(u0, u1))
}
