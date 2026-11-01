// The parallel scavenge, the full collection driver, pause records and the
// test-only verifier (SPEC.md "Scavenge", "Full collection", "Pause
// accounting", "Verification"). World stopped throughout; the stopper holds
// the safepoint mutex except while the parallel phase runs.

import Darwin
import Synchronization

/// A copy task: a range of root words, or a slice of remembered holders.
struct GCTask {
    var ptr: UnsafeMutablePointer<UInt64>
    var count: Int
    var remembered: Bool
}

/// A sweep task: a slice of one worker's young log.
struct SweepTask {
    var words: UnsafeMutablePointer<UInt32>
    var bits: UnsafeMutablePointer<UInt64>
    var count: Int
}

/// Shared state of one scavenge. Written by the stopper before the phase
/// opens (published by the mutex); during the phase only the atomics change.
struct GCShared {
    var tasks = RawBuf<GCTask>(capacity: 1024)
    var sweeps = RawBuf<SweepTask>(capacity: 1024)
    var taskNext: UnsafeMutablePointer<Atomic<Int>>
    var sweepNext: UnsafeMutablePointer<Atomic<Int>>
    var inCopy: UnsafeMutablePointer<Atomic<Int>>
    /// Ticks (ns) when the first participant passed the copy barrier.
    var copyEnd: UnsafeMutablePointer<Atomic<UInt64>>
    /// Worker id of each participant (index = join order). Written under the mutex.
    var parts: UnsafeMutablePointer<Int>
    /// Work sharing (SPEC.md "Load balance"): packets of up to
    /// `packetWords` oops exported by busy participants while one is idle.
    var packetLock: UnsafeMutablePointer<pthread_mutex_t>
    var packets: UnsafeMutablePointer<UInt64>
    var packetLen: UnsafeMutablePointer<Int>
    /// Indices of full packets (`full`), then of free ones (`free`).
    var fullList: UnsafeMutablePointer<Int>
    var freeList: UnsafeMutablePointer<Int>
    /// [0] full packets, [1] free packets. Guarded by `packetLock`; behind
    /// its own pointer because writing a field of `GCShared` itself would be
    /// a modifying access of the whole struct, which other participants read
    /// without the lock (ThreadSanitizer: Swift access race).
    var counts: UnsafeMutablePointer<Int>
    var poolCount: UnsafeMutablePointer<Atomic<Int>>
    var idle: UnsafeMutablePointer<Atomic<Int>>

    static func make() -> UnsafeMutablePointer<GCShared> {
        func counter() -> UnsafeMutablePointer<Atomic<Int>> {
            let p = UnsafeMutablePointer<Atomic<Int>>.allocate(capacity: 1)
            p.initialize(to: Atomic(0))
            return p
        }
        let ce = UnsafeMutablePointer<Atomic<UInt64>>.allocate(capacity: 1)
        ce.initialize(to: Atomic(0))
        let parts = UnsafeMutablePointer<Int>.allocate(capacity: 64)
        parts.initialize(repeating: -1, count: 64)
        let lock = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
        pthread_mutex_init(lock, nil)
        let packets = UnsafeMutablePointer<UInt64>.allocate(capacity: maxPackets * packetWords)
        let len = UnsafeMutablePointer<Int>.allocate(capacity: maxPackets)
        len.initialize(repeating: 0, count: maxPackets)
        let full = UnsafeMutablePointer<Int>.allocate(capacity: maxPackets)
        let free = UnsafeMutablePointer<Int>.allocate(capacity: maxPackets)
        for i in 0..<maxPackets { free[i] = i }
        let counts = UnsafeMutablePointer<Int>.allocate(capacity: 2)
        counts[0] = 0
        counts[1] = maxPackets
        return boxed(GCShared(taskNext: counter(), sweepNext: counter(), inCopy: counter(), copyEnd: ce, parts: parts,
                              packetLock: lock, packets: packets, packetLen: len, fullList: full, freeList: free,
                              counts: counts, poolCount: counter(), idle: counter()))
    }
}

/// One pause (SPEC.md "Pause accounting"). ns unless stated.
public struct GCRecord {
    /// The pause ran a mark-sweep (a full collection).
    public var full = false
    public var totalNs: UInt64 = 0
    public var ttspNs: UInt64 = 0
    public var prepNs: UInt64 = 0
    public var copyWallNs: UInt64 = 0
    public var sweepWallNs: UInt64 = 0
    public var finishNs: UInt64 = 0
    public var markNs: UInt64 = 0
    public var msSweepNs: UInt64 = 0
    /// Critical participant (longest copy busy): its roots/remembered/copy split.
    public var critRootsNs: UInt64 = 0
    public var critRemNs: UInt64 = 0
    public var critCopyNs: UInt64 = 0
    /// Longest entry sweep of any participant.
    public var critSweepNs: UInt64 = 0
    public var meanBusyNs: UInt64 = 0
    public var coordNs: UInt64 = 0
    public var participants = 0
    public var youngBytes: UInt64 = 0
    public var promotedBytes: UInt64 = 0
    public var promotedObjects: UInt64 = 0
    public var remSet: UInt64 = 0
    public var remScanned: UInt64 = 0
    public var entriesAllocated: UInt64 = 0
    public var entriesFreed: UInt64 = 0
    public var oldBlocks = 0
    /// Work packets exported for sharing.
    public var packets: UInt64 = 0
}

public struct GCLog {
    public var recs: UnsafeMutablePointer<GCRecord> = .allocate(capacity: 1 << 16)
    public var count = 0
    public var records: [GCRecord] { Array(UnsafeBufferPointer(start: recs, count: count)) }
}

/// Run a stop-the-world operation. Mutex held; every worker parked or
/// outside the VM; TLABs retired and entry reservations released.
func performOp(_ vm: VMRef, _ w: WorkerRef, _ op: SafeOp, requested t0: UInt64, stopped t1: UInt64) {
    let generational = vm.pointee.heap.nurseryBytes > 0
    var rec = GCRecord()
    if generational {
        rec = scavenge(vm, w, t0, t1)
    } else if case .scavenge = op {
        return // non-generational: nothing to do
    }
    let needFull: Bool
    if case .full = op { needFull = true } else { needFull = vm.pointee.heap.blocksInUse() > vm.pointee.heap.softBlocks }
    var msNs: UInt64 = 0
    if needFull {
        if let ws = vm.pointee.workers {
            for i in 0..<vm.pointee.workerCount { vm.pointee.heap.retire(&ws[i].pointee.promo) }
        }
        let (mark, sweep) = markSweep(vm, w)
        rec.full = true
        rec.markNs = mark
        rec.msSweepNs = sweep
        msNs = mark &+ sweep
        if vm.pointee.verify { postVerify(vm, expected: nil, promoted: 0) }
    }
    let t2 = now()
    rec.totalNs = t2 &- t0
    rec.ttspNs = t1 &- t0
    rec.oldBlocks = vm.pointee.heap.blocksInUse()
    if !generational { rec.coordNs = rec.totalNs &- msNs }
    else {
        let work = rec.critRootsNs &+ rec.critRemNs &+ rec.critCopyNs &+ rec.critSweepNs &+ msNs
        rec.coordNs = rec.totalNs > work ? rec.totalNs &- work : 0
    }
    if rec.full {
        vm.add(.fullGCs, 1)
        vm.add(.fullNs, rec.totalNs)
        vm.add(.gcCount, 1)
        vm.add(.gcNs, rec.totalNs)
        vm.add(.markNs, rec.markNs)
        vm.add(.sweepNs, rec.msSweepNs)
    }
    let log = vm.pointee.gcLog
    if log.pointee.count < 1 << 16 {
        log.pointee.recs[log.pointee.count] = rec
        log.pointee.count += 1
    }
    if vm.pointee.verboseGC {
        FileHandleStderr.write("gc: \(rec.full ? "full" : "scavenge") \(Double(rec.totalNs) / 1e6) ms, promoted \(rec.promotedBytes) B, old blocks \(rec.oldBlocks)\n")
    }
}

// MARK: - the scavenge

private let rootTaskWords = 4096
let packetWords = 256
let maxPackets = 1024
private let remTaskHolders = 256
private let sweepTaskWords = 1024

private func scavenge(_ vm: VMRef, _ w: WorkerRef, _ t0: UInt64, _ t1: UInt64) -> GCRecord {
    var rec = GCRecord()
    let g = vm.pointee.gc
    let n = vm.pointee.workerCount
    let ws = vm.pointee.workers.unsafelyUnwrapped
    // --- prep
    var young: UInt64 = 0
    var remSet: UInt64 = 0
    for i in 0..<n {
        let x = ws[i]
        young &+= UInt64(x.pointee.nurseryTop &- x.pointee.nurseryStart)
        remSet &+= UInt64(x.pointee.remBuf.count)
        x.pointee.gc = GCShare()
    }
    var expected: Int? = nil
    if vm.pointee.verify { expected = preVerify(vm) }
    g.pointee.tasks.count = 0
    for (p, c) in rootRanges(vm) {
        var off = 0
        while off < c {
            g.pointee.tasks.push(GCTask(ptr: p + off, count: min(rootTaskWords, c - off), remembered: false))
            off += rootTaskWords
        }
    }
    g.pointee.sweeps.count = 0
    for i in 0..<n {
        let x = ws[i]
        var off = 0
        while off < x.pointee.remBuf.count {
            g.pointee.tasks.push(GCTask(ptr: x.pointee.remBuf.ptr + off, count: min(remTaskHolders, x.pointee.remBuf.count - off), remembered: true))
            off += remTaskHolders
        }
        off = 0
        while off < x.pointee.logWord.count {
            g.pointee.sweeps.push(SweepTask(words: x.pointee.logWord.ptr + off, bits: x.pointee.logBits.ptr + off,
                                            count: min(sweepTaskWords, x.pointee.logWord.count - off)))
            off += sweepTaskWords
        }
    }
    g.pointee.taskNext.pointee.store(0, ordering: .relaxed)
    g.pointee.sweepNext.pointee.store(0, ordering: .relaxed)
    g.pointee.inCopy.pointee.store(0, ordering: .relaxed)
    g.pointee.copyEnd.pointee.store(0, ordering: .relaxed)
    g.pointee.idle.pointee.store(0, ordering: .relaxed)
    let tp = now()
    // --- parallel phase
    let parts = runParallelPhase(vm, w)
    let tj = now()
    // --- finish
    var crit = GCShare()
    var critSweep: UInt64 = 0
    var busy: UInt64 = 0
    for k in 0..<parts {
        let s = worker(vm, g.pointee.parts[k]).pointee.gc
        if s.copyBusy >= crit.copyBusy { crit = s }
        critSweep = max(critSweep, s.sweepNs)
        busy &+= s.copyBusy &+ s.sweepNs
        rec.promotedBytes &+= s.promotedBytes
        rec.promotedObjects &+= s.promotedObjects
        rec.entriesAllocated &+= s.entriesAllocated
        rec.entriesFreed &+= s.entriesFreed
        rec.remScanned &+= s.remScanned
        rec.packets &+= s.exported
    }
    for i in 0..<n {
        let x = ws[i]
        x.pointee.nurseryTop = x.pointee.nurseryStart
        x.pointee.remBuf.count = 0
        x.pointee.logWord.count = 0
        x.pointee.logBits.count = 0
    }
    rebuildChunkPool(vm)
    if vm.pointee.verify { postVerify(vm, expected: expected, promoted: rec.promotedObjects) }
    let tf = now()
    let ce = g.pointee.copyEnd.pointee.load(ordering: .relaxed)
    rec.prepNs = tp &- t1
    rec.copyWallNs = ce > tp ? ce &- tp : tj &- tp
    rec.sweepWallNs = ce > tp ? tj &- ce : 0
    rec.finishNs = tf &- tj
    rec.critRootsNs = crit.rootsNs
    rec.critRemNs = crit.remNs
    rec.critCopyNs = crit.copyNs
    rec.critSweepNs = critSweep
    rec.meanBusyNs = busy / UInt64(max(parts, 1))
    rec.participants = parts
    rec.youngBytes = young
    rec.remSet = remSet
    vm.add(.scavenges, 1)
    vm.add(.scavengeNs, tf &- t0)
    vm.add(.promotedBytes, rec.promotedBytes)
    vm.add(.promotedObjects, rec.promotedObjects)
    vm.add(.youngBytes, young)
    vm.add(.remSetTotal, remSet)
    vm.add(.entriesAllocated, rec.entriesAllocated)
    vm.add(.entriesFreed, rec.entriesFreed)
    vm.add(.entrySweepNs, critSweep)
    return rec
}

/// One participant (stopper or a parked worker), mutex not held.
func participate(_ vm: VMRef, _ w: WorkerRef) {
    let g = vm.pointee.gc
    let om = vm.pointee.om
    w.pointee.gc = GCShare()
    g.pointee.inCopy.pointee.wrappingAdd(1, ordering: .acquiringAndReleasing)
    let ntasks = g.pointee.tasks.count
    while true {
        let i = g.pointee.taskNext.pointee.wrappingAdd(1, ordering: .relaxed).oldValue
        if i >= ntasks { break }
        let t = g.pointee.tasks.ptr[i]
        let a = now()
        if t.remembered {
            let rem = vm.pointee.space.rem
            for k in 0..<t.count {
                let holder = t.ptr[k]
                let h = om.header(holder) // old: never written during a scavenge
                if !hdrIsBytes(h) {
                    let ns = hdrSlots(h)
                    let s = om.slotsPtr(holder)
                    var j = 0
                    while j < ns { scavWord(vm, w, om, s[j]); j &+= 1 }
                    w.pointee.gc.remScanned &+= UInt64(ns)
                }
                rem[Int(truncatingIfNeeded: holder &>> 4)].store(0, ordering: .relaxed)
            }
            w.pointee.gc.remNs &+= now() &- a
        } else {
            var k = 0
            while k < t.count { scavWord(vm, w, om, t.ptr[k]); k &+= 1 }
            w.pointee.gc.rootsNs &+= now() &- a
        }
        let b = now()
        drain(vm, w, om)
        w.pointee.gc.copyNs &+= now() &- b
    }
    // Tasks are exhausted: help with exported packets until no participant
    // is copying. Invariants: packets are pushed only by a counted
    // (`inCopy`) participant; a participant stops being counted only after
    // finding the pool empty; a taker is counted before it pops; and nobody
    // re-counts itself once `inCopy` reached 0. So `inCopy == 0` means no
    // packet is left and no copy is in flight: the copy barrier.
    let b = now()
    while takePacket(g, w) { drain(vm, w, om) }
    w.pointee.gc.copyNs &+= now() &- b
    g.pointee.inCopy.pointee.wrappingSubtract(1, ordering: .sequentiallyConsistent)
    let wa = now()
    var spins = 0
    g.pointee.idle.pointee.wrappingAdd(1, ordering: .sequentiallyConsistent)
    while true {
        var c = g.pointee.inCopy.pointee.load(ordering: .sequentiallyConsistent)
        if c == 0 { break }
        if g.pointee.poolCount.pointee.load(ordering: .sequentiallyConsistent) > 0 {
            var counted = false
            while c > 0 {
                let (ok, cur) = g.pointee.inCopy.pointee.compareExchange(expected: c, desired: c + 1, ordering: .sequentiallyConsistent)
                if ok { counted = true; break }
                c = cur
            }
            if counted {
                g.pointee.idle.pointee.wrappingSubtract(1, ordering: .sequentiallyConsistent)
                let t = now()
                while takePacket(g, w) { drain(vm, w, om) }
                w.pointee.gc.copyNs &+= now() &- t
                g.pointee.inCopy.pointee.wrappingSubtract(1, ordering: .sequentiallyConsistent)
                g.pointee.idle.pointee.wrappingAdd(1, ordering: .sequentiallyConsistent)
                continue
            }
        }
        spins &+= 1
        if spins & 63 == 0 { sched_yield() }
    }
    g.pointee.idle.pointee.wrappingSubtract(1, ordering: .sequentiallyConsistent)
    let ce = now()
    _ = g.pointee.copyEnd.pointee.compareExchange(expected: 0, desired: ce, ordering: .relaxed)
    w.pointee.gc.waitNs = ce &- wa
    // Entry sweep (SPEC.md "Entry allocation": young-log words only).
    let sp = vm.pointee.space
    let nsweeps = g.pointee.sweeps.count
    var alloc: UInt64 = 0, freed: UInt64 = 0
    while true {
        let i = g.pointee.sweepNext.pointee.wrappingAdd(1, ordering: .relaxed).oldValue
        if i >= nsweeps { break }
        let t = g.pointee.sweeps.ptr[i]
        for k in 0..<t.count {
            let gw = Int(t.words[k])
            let bits = t.bits[k]
            let alive = sp.surv[gw].exchange(0, ordering: .relaxed)
            let dead = bits & ~alive
            sp.used[gw] &= ~dead
            alloc &+= UInt64(bits.nonzeroBitCount)
            freed &+= UInt64(dead.nonzeroBitCount)
        }
    }
    w.pointee.gc.entriesAllocated = alloc
    w.pointee.gc.entriesFreed = freed
    w.pointee.gc.sweepNs = now() &- ce
}

/// Scan one word: promote the young object it names, if this participant
/// claims it first (SPEC.md "Claiming protocol").
@inline(__always)
private func scavWord(_ vm: VMRef, _ w: WorkerRef, _ om: OM, _ v: Oop) {
    if v & 1 != 0 || v == 0 { return }
    let ent = om.entry(v)
    let h = atomicHeader(ent).pointee.load(ordering: .relaxed)
    if h & youngBit == 0 { return }
    promote(vm, w, om, v, ent, h)
}

@inline(never)
private func promote(_ vm: VMRef, _ w: WorkerRef, _ om: OM, _ v: Oop, _ ent: UnsafeMutablePointer<UInt64>, _ h: UInt64) {
    let (won, _) = atomicHeader(ent).pointee.compareExchange(expected: h, desired: h & ~youngBit, ordering: .relaxed)
    if !won { return }
    let size = objectBytes(h)
    if w.pointee.promo.end &- w.pointee.promo.cur < UInt(size) {
        if !vm.pointee.heap.refill(&w.pointee.promo, soft: false) { fatal("promotion failed: old space and reserve exhausted") }
    }
    let dst = w.pointee.promo.cur
    w.pointee.promo.cur = dst &+ UInt(size)
    let src = om.heap &+ UInt(ent[1])
    if size <= 128 {
        // Most bodies are a few words: a word loop beats a memmove call.
        let d = wordPtr(dst), s = wordPtr(src)
        var i = 0
        let n = size &>> 3
        while i < n { d[i] = s[i]; i &+= 1 }
    } else {
        UnsafeMutableRawPointer(bitPattern: dst).unsafelyUnwrapped
            .copyMemory(from: UnsafeRawPointer(bitPattern: src).unsafelyUnwrapped, byteCount: size)
    }
    ent[1] = UInt64(dst &- om.heap)
    let idx = Int(truncatingIfNeeded: v &>> 4)
    vm.pointee.space.surv[idx &>> 6].bitwiseOr(UInt64(1) &<< UInt64(idx & 63), ordering: .relaxed)
    w.pointee.gc.promotedBytes &+= UInt64(size)
    w.pointee.gc.promotedObjects &+= 1
    if !hdrIsBytes(h) { w.pointee.gcStack.push(v) }
}

/// Scan promoted objects (their new bodies) until the local stack is empty.
/// Every 32 objects, if a participant is idle and the pool is empty, export
/// the bottom half of the stack (the shallowest, usually largest, subtrees).
private func drain(_ vm: VMRef, _ w: WorkerRef, _ om: OM) {
    let g = vm.pointee.gc
    var k = 0
    while let o = w.pointee.gcStack.pop() {
        let h = om.header(o) // claimed by this participant; others only load it
        let n = hdrSlots(h)
        let s = om.slotsPtr(o)
        var i = 0
        while i < n { scavWord(vm, w, om, s[i]); i &+= 1 }
        k &+= 1
        if k & 1023 == 0 && w.pointee.gcStack.count >= 8
            && g.pointee.idle.pointee.load(ordering: .relaxed) > 0
            && g.pointee.poolCount.pointee.load(ordering: .relaxed) == 0 {
            exportPacket(g, w)
        }
    }
}

private func exportPacket(_ g: UnsafeMutablePointer<GCShared>, _ w: WorkerRef) {
    let n = min(w.pointee.gcStack.count / 2, packetWords)
    pthread_mutex_lock(g.pointee.packetLock)
    if g.pointee.counts[1] == 0 { pthread_mutex_unlock(g.pointee.packetLock); return }
    g.pointee.counts[1] -= 1
    let pk = g.pointee.freeList[g.pointee.counts[1]]
    let dst = g.pointee.packets + pk * packetWords
    let st = w.pointee.gcStack.ptr
    dst.update(from: st, count: n)
    (st).update(from: st + n, count: w.pointee.gcStack.count - n)
    w.pointee.gcStack.count -= n
    g.pointee.packetLen[pk] = n
    g.pointee.fullList[g.pointee.counts[0]] = pk
    g.pointee.counts[0] += 1
    g.pointee.poolCount.pointee.wrappingAdd(1, ordering: .sequentiallyConsistent)
    pthread_mutex_unlock(g.pointee.packetLock)
    w.pointee.gc.exported &+= 1
}

/// Move one exported packet onto this participant's stack. The caller is
/// counted in `inCopy`.
private func takePacket(_ g: UnsafeMutablePointer<GCShared>, _ w: WorkerRef) -> Bool {
    if g.pointee.poolCount.pointee.load(ordering: .sequentiallyConsistent) == 0 { return false }
    pthread_mutex_lock(g.pointee.packetLock)
    if g.pointee.counts[0] == 0 { pthread_mutex_unlock(g.pointee.packetLock); return false }
    g.pointee.counts[0] -= 1
    let pk = g.pointee.fullList[g.pointee.counts[0]]
    let n = g.pointee.packetLen[pk]
    let src = g.pointee.packets + pk * packetWords
    for i in 0..<n { w.pointee.gcStack.push(src[i]) }
    g.pointee.freeList[g.pointee.counts[1]] = pk
    g.pointee.counts[1] += 1
    g.pointee.poolCount.pointee.wrappingSubtract(1, ordering: .sequentiallyConsistent)
    pthread_mutex_unlock(g.pointee.packetLock)
    return true
}

/// Stopper, after the parallel phase: the pool's unconsumed chunks plus
/// every chunk taken this cycle that has a free bit.
private func rebuildChunkPool(_ vm: VMRef) {
    let sp = vm.pointee.space
    var n = 0
    for i in 0..<vm.pointee.workerCount {
        let x = worker(vm, i)
        for k in 0..<x.pointee.chunks.count {
            let c = Int(x.pointee.chunks.ptr[k])
            var free = false
            for j in 0..<wordsPerChunk where sp.used[c &* wordsPerChunk &+ j] != ~0 { free = true; break }
            if free { sp.poolScratch[n] = UInt32(c); n += 1 }
        }
        x.pointee.chunks.count = 0
    }
    let count = sp.poolCount.pointee.load(ordering: .relaxed)
    let next = min(sp.poolNext.pointee.load(ordering: .relaxed), count)
    for i in next..<count { sp.poolScratch[n] = sp.pool[i]; n += 1 }
    sp.pool.update(from: sp.poolScratch, count: n)
    sp.poolCount.pointee.store(n, ordering: .relaxed)
    sp.poolNext.pointee.store(0, ordering: .relaxed)
}

// MARK: - verification (tests)

@inline(__always) private func isUsed(_ sp: Space, _ o: Oop) -> Bool {
    let i = Int(truncatingIfNeeded: o &>> 4)
    return i < tableEntries && sp.used[i &>> 6] & (UInt64(1) &<< UInt64(i & 63)) != 0
}

private func failure(_ vm: VMRef, _ msg: String) {
    let n = vm.metric(.verifyFailures)
    vm.add(.verifyFailures, 1)
    if n < 10 { FileHandleStderr.write("verify: \(msg)\n") }
}

/// Every used entry (index, entry pointer), entry 0 excluded.
private func forEachUsed(_ vm: VMRef, _ body: (Int, UnsafeMutablePointer<UInt64>) -> Void) {
    let sp = vm.pointee.space
    let om = vm.pointee.om
    for gw in 0..<(chunkHwmNow(vm) * wordsPerChunk) {
        var bits = sp.used[gw]
        while bits != 0 {
            let idx = gw * 64 + bits.trailingZeroBitCount
            bits &= bits - 1
            if idx != 0 { body(idx, om.entry(UInt64(idx) << 4)) }
        }
    }
}

/// Before copying: every old object holding a young oop is remembered;
/// answers the number of young objects reachable from roots and remembered
/// holders (what the scavenge must promote, each exactly once).
private func preVerify(_ vm: VMRef) -> Int {
    vm.add(.verifyRuns, 1)
    let om = vm.pointee.om
    let rem = vm.pointee.space.rem
    forEachUsed(vm) { idx, e in
        let h = e[0]
        if h & youngBit != 0 || hdrIsBytes(h) { return }
        let o = UInt64(idx) << 4
        for i in 0..<hdrSlots(h) {
            let v = om.slot(o, i)
            if v & 1 == 0 && v != 0 && hdrYoung(om.header(v)) && rem[idx].load(ordering: .relaxed) == 0 {
                failure(vm, "old \(o) (class \(hdrClass(h))) slot \(i) holds young \(v) (class \(hdrClass(om.header(v)))) but is not remembered")
            }
        }
    }
    var seen = Set<Oop>()
    var stack: [Oop] = []
    func visit(_ v: Oop) {
        if v & 1 != 0 || v == 0 || !hdrYoung(om.header(v)) { return }
        if seen.insert(v).inserted && !hdrIsBytes(om.header(v)) { stack.append(v) }
    }
    func drainV() {
        while let o = stack.popLast() { for i in 0..<hdrSlots(om.header(o)) { visit(om.slot(o, i)) } }
    }
    for (p, c) in rootRanges(vm) { for i in 0..<c { visit(p[i]) }; drainV() }
    for k in 0..<vm.pointee.workerCount {
        let x = worker(vm, k)
        for j in 0..<x.pointee.remBuf.count {
            let holder = x.pointee.remBuf.ptr[j]
            let h = om.header(holder)
            if hdrYoung(h) { failure(vm, "remembered holder \(holder) is young") }
            if !hdrIsBytes(h) { for i in 0..<hdrSlots(h) { visit(om.slot(holder, i)) } }
            drainV()
        }
    }
    return seen.count
}

/// After a scavenge or full collection: nothing young, no body in a
/// nursery, no pointer to a free entry, each reachable young object
/// promoted exactly once.
private func postVerify(_ vm: VMRef, expected: Int?, promoted: UInt64) {
    let om = vm.pointee.om
    let sp = vm.pointee.space
    let heap = vm.pointee.heap
    if let e = expected, UInt64(e) != promoted {
        failure(vm, "promoted \(promoted) objects, \(e) were reachable")
    }
    forEachUsed(vm) { idx, e in
        let h = e[0]
        if h == 0 { failure(vm, "used entry \(idx) has no header"); return }
        if hdrYoung(h) { failure(vm, "entry \(idx) still young after a scavenge") }
        if heap.inNurseries(om.heap &+ UInt(e[1])) { failure(vm, "entry \(idx) body in a nursery") }
        if hdrIsBytes(h) { return }
        let o = UInt64(idx) << 4
        for i in 0..<hdrSlots(h) {
            let v = om.slot(o, i)
            if v & 1 == 0 && v != 0 && !isUsed(sp, v) {
                failure(vm, "entry \(idx) (class \(hdrClass(h))) slot \(i) names free entry \(v)")
            }
        }
    }
    for (p, c) in rootRanges(vm) {
        for i in 0..<c where p[i] & 1 == 0 && p[i] != 0 && !isUsed(sp, p[i]) {
            failure(vm, "root word names free entry \(p[i])")
        }
    }
    for k in 0..<vm.pointee.workerCount where worker(vm, k).pointee.remBuf.count != 0 {
        failure(vm, "worker \(k) remembered buffer not empty")
    }
}
