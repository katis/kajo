// Part 1: dependent-load chase over the memory hierarchy, no VM
// (SPEC.md "Part 1"). One configuration per call; one result line.
//
//   chase   one array of 64-byte nodes, word 0 = address of the next node
//   dsep    16-byte entries in one region, 64-byte nodes in another; the
//           hop is B's: entry -> body offset -> body -> next entry offset
//   dlocal  as dsep, but each 16 KiB page holds 204 nodes (bottom) and
//           their entries (top): L's layout
//   dhalf   as dsep with 32-byte nodes
//   spread  as chase, one node per 16 KiB page at a random line offset;
//           `sizeMB` is then the page footprint
//   order=lcg  (chase, dsep, dlocal) node i links to (1664525 i + 1013904223)
//           mod N instead of a random cycle: the walk kernel's order (full
//           period for power-of-two N). Added after the device runs.
//   work=K  (any mode) K multiply-adds per hop on a register the chain does
//           not depend on, so the core has work to overlap with each miss,
//           like an interpreter between two loads (added after the first
//           device run; see RESULTS.md)
//
// Each thread builds its own arrays (first touch by that thread), waits at
// a barrier, warms up, then times its hops.

import Darwin
import Synchronization

public let pageBytes = 16384

@inline(__always) private func load(_ a: UInt) -> UInt {
    UnsafePointer<UInt>(bitPattern: a).unsafelyUnwrapped.pointee
}
@inline(__always) private func store(_ a: UInt, _ v: UInt) {
    UnsafeMutablePointer<UInt>(bitPattern: a).unsafelyUnwrapped.pointee = v
}

/// Single chase: `hops` dependent loads from `p`.
@inline(never)
public func chase(_ start: UInt, _ hops: Int) -> UInt {
    var p = start
    var i = hops
    while i > 0 {
        p = load(p)
        i &-= 1
    }
    return p
}

/// Single chase with `work` independent multiply-adds per hop.
@inline(never)
public func chaseWork(_ start: UInt, _ hops: Int, _ work: Int) -> UInt {
    var p = start
    var acc: UInt = 1
    var i = hops
    while i > 0 {
        p = load(p)
        var k = work
        while k > 0 { acc = acc &* 6364136223846793005 &+ 1442695040888963407; k &-= 1 }
        i &-= 1
    }
    return p &+ (acc & 1)
}

/// Double chase with `work` independent multiply-adds per hop.
@inline(never)
public func dchaseWork(_ ebase: UInt, _ nbase: UInt, _ start: UInt, _ hops: Int, _ work: Int) -> UInt {
    var cur = start
    var acc: UInt = 1
    var i = hops
    while i > 0 {
        let b = nbase &+ load(ebase &+ cur &+ 8)
        cur = load(b)
        var k = work
        while k > 0 { acc = acc &* 6364136223846793005 &+ 1442695040888963407; k &-= 1 }
        i &-= 1
    }
    return cur &+ (acc & 1)
}

/// Double chase, B's hop: entry at ebase+cur, body at nbase+entry[1],
/// next entry offset in body word 0.
@inline(never)
public func dchase(_ ebase: UInt, _ nbase: UInt, _ start: UInt, _ hops: Int) -> UInt {
    var cur = start
    var i = hops
    while i > 0 {
        let b = nbase &+ load(ebase &+ cur &+ 8)
        cur = load(b)
        i &-= 1
    }
    return cur
}

struct Rng {
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z &>> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z &>> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z &>> 31)
    }
    mutating func below(_ n: Int) -> Int { Int(truncatingIfNeeded: next() % UInt64(n)) }
}

/// Sattolo: a random cyclic permutation; next[i] is the successor of i.
func cycle(_ n: Int, _ rng: inout Rng) -> UnsafeMutablePointer<UInt32> {
    let a = UnsafeMutablePointer<UInt32>.allocate(capacity: n)
    for i in 0..<n { a[i] = UInt32(i) }
    var i = n - 1
    while i > 0 {
        let j = rng.below(i)
        let t = a[i]; a[i] = a[j]; a[j] = t
        i -= 1
    }
    // a is now a random order; turn it into successor form: a[k] -> a[k+1].
    let next = UnsafeMutablePointer<UInt32>.allocate(capacity: n)
    for k in 0..<n { next[Int(a[k])] = a[(k + 1) % n] }
    a.deallocate()
    return next
}

func mapRegion(_ bytes: Int) -> UInt {
    let size = (bytes + pageBytes - 1) / pageBytes * pageBytes
    guard let p = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), p != MAP_FAILED else {
        fatalError("mmap \(size) failed")
    }
    return UInt(bitPattern: p)
}

public struct ChaseSpec: Sendable {
    public var mode: String
    public var sizeMB: Int
    public var threads: Int
    public var work: Int
    public var lcg: Bool
    public init(mode: String, sizeMB: Int, threads: Int, work: Int = 0, lcg: Bool = false) {
        self.mode = mode; self.sizeMB = sizeMB; self.threads = threads; self.work = work; self.lcg = lcg
    }

    /// Objects per thread.
    public var nodes: Int {
        mode == "spread" ? (sizeMB << 20) / pageBytes : (sizeMB << 20) / 64
    }
    public var hops: Int { min(1 << 25, max(1 << 22, 2 * nodes)) }
    var nodeBytes: Int { mode == "dhalf" ? 32 : 64 }
    /// Objects per page in dlocal.
    var perPage: Int { pageBytes / (nodeBytes + 16) }

    /// Bytes of data touched per thread.
    public var workingSet: Int {
        switch mode {
        case "chase", "spread": return nodes * 64
        default: return nodes * (nodeBytes + 16)
        }
    }
    /// Pages touched per thread.
    public var pages: Int {
        switch mode {
        case "spread": return nodes
        case "dlocal": return (nodes + perPage - 1) / perPage
        case "chase": return (nodes * 64 + pageBytes - 1) / pageBytes
        default: return (nodes * 16 + pageBytes - 1) / pageBytes + (nodes * nodeBytes + pageBytes - 1) / pageBytes
        }
    }
}

/// One thread's arrays: what the hop loop needs.
struct Prepared {
    var ebase: UInt = 0
    var nbase: UInt = 0
    var start: UInt = 0
    var double = false
}

func prepare(_ spec: ChaseSpec, seed: UInt64) -> Prepared {
    var rng = Rng(s: seed)
    let n = spec.nodes
    let next: UnsafeMutablePointer<UInt32>
    if spec.lcg {
        precondition(n & (n - 1) == 0, "lcg order needs a power-of-two node count")
        next = .allocate(capacity: n)
        for i in 0..<n { next[i] = UInt32(truncatingIfNeeded: (1664525 &* UInt64(i) &+ 1013904223) & UInt64(n - 1)) }
    } else {
        next = cycle(n, &rng)
    }
    defer { next.deallocate() }
    var p = Prepared()
    switch spec.mode {
    case "chase":
        let base = mapRegion(n * 64)
        for i in 0..<n { store(base &+ UInt(i * 64), base &+ UInt(Int(next[i]) * 64)) }
        p.start = base
    case "spread":
        let base = mapRegion(n * pageBytes)
        let off = UnsafeMutablePointer<Int>.allocate(capacity: n)
        defer { off.deallocate() }
        for i in 0..<n { off[i] = i * pageBytes + rng.below(pageBytes / 64) * 64 }
        for i in 0..<n { store(base &+ UInt(off[i]), base &+ UInt(off[Int(next[i])])) }
        p.start = base &+ UInt(off[0])
    case "dsep", "dhalf":
        let nb = spec.nodeBytes
        let e = mapRegion(n * 16)
        let b = mapRegion(n * nb)
        for i in 0..<n {
            store(e &+ UInt(i * 16), 0x5A5A)                 // header
            store(e &+ UInt(i * 16 + 8), UInt(i * nb))       // body offset
            store(b &+ UInt(i * nb), UInt(Int(next[i]) * 16)) // next entry offset
        }
        p.ebase = e; p.nbase = b; p.start = 0; p.double = true
    case "dlocal":
        let k = spec.perPage
        let nb = spec.nodeBytes
        let pages = (n + k - 1) / k
        let base = mapRegion(pages * pageBytes)
        @inline(__always) func entryOff(_ i: Int) -> Int { (i / k) * pageBytes + pageBytes - (i % k + 1) * 16 }
        @inline(__always) func nodeOff(_ i: Int) -> Int { (i / k) * pageBytes + (i % k) * nb }
        for i in 0..<n {
            store(base &+ UInt(entryOff(i)), 0x5A5A)
            store(base &+ UInt(entryOff(i) + 8), UInt(nodeOff(i)))
            store(base &+ UInt(nodeOff(i)), UInt(entryOff(Int(next[i]))))
        }
        p.ebase = base; p.nbase = base; p.start = UInt(entryOff(0)); p.double = true
    default:
        fatalError("unknown mode \(spec.mode)")
    }
    return p
}

@inline(never)
func hop(_ p: Prepared, _ hops: Int, _ work: Int) -> UInt {
    if work > 0 {
        return p.double ? dchaseWork(p.ebase, p.nbase, p.start, hops, work) : chaseWork(p.start, hops, work)
    }
    return p.double ? dchase(p.ebase, p.nbase, p.start, hops) : chase(p.start, hops)
}

/// Per-thread state, each on its own cache lines.
struct Slot {
    var spec: ChaseSpec
    var seed: UInt64
    var ns: UInt64 = 0
    var buildNs: UInt64 = 0
    var sink: UInt = 0
    var barrier: UnsafeMutablePointer<Atomic<Int>>
    var pad: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0, 0, 0, 0, 0)
}

@inline(__always) func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

private func threadBody(_ arg: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
    let s = arg.assumingMemoryBound(to: Slot.self)
    let spec = s.pointee.spec
    let t0 = nowNs()
    let p = prepare(spec, seed: s.pointee.seed)
    s.pointee.buildNs = nowNs() &- t0
    // barrier: everyone built before anyone chases
    s.pointee.barrier.pointee.wrappingAdd(1, ordering: .acquiringAndReleasing)
    while s.pointee.barrier.pointee.load(ordering: .acquiring) < spec.threads { sched_yield() }
    let m = spec.hops
    var sink = hop(p, m / 4, spec.work)
    let t1 = nowNs()
    sink &+= hop(p, m, spec.work)
    s.pointee.ns = nowNs() &- t1
    s.pointee.sink = sink
    return nil
}

/// Run one configuration; returns the result line (key=value pairs).
public func runChase(_ spec: ChaseSpec) -> String {
    let n = spec.threads
    let barrier = UnsafeMutablePointer<Atomic<Int>>.allocate(capacity: 1)
    barrier.initialize(to: Atomic(0))
    let slots = UnsafeMutableRawPointer.allocate(byteCount: 256 * n, alignment: 128)
    for i in 0..<n {
        (slots + 256 * i).bindMemory(to: Slot.self, capacity: 1)
            .initialize(to: Slot(spec: spec, seed: 0x1234_5678 &+ UInt64(i) &* 7919, barrier: barrier))
    }
    precondition(MemoryLayout<Slot>.stride <= 256)
    var attr = pthread_attr_t()
    pthread_attr_init(&attr)
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INITIATED, 0)
    var tids: [pthread_t] = []
    let t0 = nowNs()
    for i in 0..<n {
        var tid: pthread_t? = nil
        if pthread_create(&tid, &attr, threadBody, slots + 256 * i) != 0 { fatalError("pthread_create") }
        tids.append(tid!)
    }
    for t in tids { pthread_join(t, nil) }
    let wall = nowNs() &- t0
    var per: [Double] = []
    var build: UInt64 = 0
    for i in 0..<n {
        let s = (slots + 256 * i).assumingMemoryBound(to: Slot.self)
        per.append(Double(s.pointee.ns) / Double(spec.hops))
        build = max(build, s.pointee.buildNs)
    }
    per.sort()
    let med = per.count % 2 == 1 ? per[per.count / 2] : (per[per.count / 2 - 1] + per[per.count / 2]) / 2
    func f(_ x: Double) -> String {
        let r = (x * 100).rounded() / 100
        return "\(r)"
    }
    return "mode=\(spec.mode) size_mb=\(spec.sizeMB) threads=\(n) work=\(spec.work) order=\(spec.lcg ? "lcg" : "random") nodes=\(spec.nodes) hops=\(spec.hops)"
        + " ws_mb=\(f(Double(spec.workingSet) / 1048576)) pages=\(spec.pages)"
        + " ns_hop=\(f(med)) ns_hop_min=\(f(per.first!)) ns_hop_max=\(f(per.last!))"
        + " build_ms=\(f(Double(build) / 1e6)) wall_ms=\(f(Double(wall) / 1e6))"
}
