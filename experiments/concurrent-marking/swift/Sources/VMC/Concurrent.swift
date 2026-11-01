// Concurrent marking of old space with a snapshot-at-the-beginning barrier,
// and lazy sweeping by the marker in the background (SPEC.md "Side tables",
// "SATB buffer protocol", "Grey set and markers", "Phases", "Triggers and
// fallback", "Verifier").
//
// Ownership: `CMShared` holds only pointers and is never written after
// creation. The phase and cycle are atomics written with the world stopped
// (sweeping -> swept by the sweeper). The queue is guarded by `cm.lock`.
// A `Marker` is written by its own thread while inside the VM, and by a
// stopper only while that marker is parked or outside the VM. Cycle records
// are written by stoppers under the safepoint mutex.

import Darwin
import Synchronization

public let satbCap = 512
let greyPacketWords = 256

public enum CMPhase {
    public static let idle = 0
    public static let marking = 1
    public static let sweeping = 2
    public static let swept = 3
}

/// Set before any VM thread starts (SPEC.md "Package shape").
public struct CMConfig {
    /// `KAJO_GC=cm`: concurrent marking; false: ADR 0005's stop-the-world full collections.
    public var concurrent = true
    /// Fraction of the soft limit that starts a cycle.
    public var threshold = 0.60
    public var markers = 1
    /// Marker thread QoS: `QOS_CLASS_UTILITY` (default; usually efficiency
    /// cores) or `QOS_CLASS_USER_INITIATED` (`KAJO_CM_QOS=high`).
    public var markerQoS = QOS_CLASS_UTILITY
    /// Marking flag never cleared; a cycle starts at every scavenge while idle.
    public var force = false
    /// Compare mark sets at every final mark.
    public var verify = false
    // --- test-only switches (SPEC.md "Test-only protocol switches")
    public var satb = true
    public var literal = false
    public var literalGrey = true
    public var manual = false
    public init() {}
}

/// A queued unit of marking work: an SATB buffer (candidates) or a grey
/// packet (already marked, to be scanned).
struct CMItem {
    var ptr: UnsafeMutablePointer<Oop>
    var count: Int
    var grey: Bool
}

/// Guarded by `cm.lock`.
struct CMQueue {
    var items = RawBuf<CMItem>(capacity: 256)
    var free = RawBuf<UnsafeMutablePointer<Oop>>(capacity: 64)
    var idle = [Bool](repeating: false, count: 4)
    var idleCount = 0
    var waiting = 0
    var greyItems = 0
}

/// One marker thread (or the test thread acting as one). 128-byte aligned.
public struct Marker {
    public var id: Int
    public var w: WorkerRef
    var stack = WordStack(capacity: 1 << 14)
    /// Cumulative over the run (deltas are taken per cycle).
    public var markedObjects: UInt64 = 0
    public var markedBytes: UInt64 = 0
    public var markCpuNs: UInt64 = 0
    public var sweepCpuNs: UInt64 = 0
    public var exported: UInt64 = 0
    /// Sweep results of the current cycle (marker 0), read by the apply.
    var freedChunks = RawBuf<UInt32>(capacity: 256)
    var sweepCycle: UInt64 = 0
    var sweepFreed: UInt64 = 0
    var sweepFreedBytes: UInt64 = 0
    var sweepLiveBytes: UInt64 = 0
    var sweepSnapEntries: UInt64 = 0
    var sweepCpu: UInt64 = 0
    var sweepStart: UInt64 = 0
    var sweepEnd: UInt64 = 0
}

public typealias MarkerRef = UnsafeMutablePointer<Marker>

/// One concurrent cycle (written by stoppers).
public struct CMCycle {
    public var cycle: UInt64 = 0
    public var startNs: UInt64 = 0
    public var finalNs: UInt64 = 0
    public var appliedNs: UInt64 = 0
    public var oldBlocksStart = 0
    public var oldBlocksFinal = 0
    public var oldBlocksAfter = 0
    public var markedObjects: UInt64 = 0
    public var markedBytes: UInt64 = 0
    public var drainedObjects: UInt64 = 0
    public var markCpuNs: UInt64 = 0
    public var promotedBytes: UInt64 = 0
    public var scavenges = 0
    public var satbEntries: UInt64 = 0
    public var satbBuffers: UInt64 = 0
    public var sweepCpuNs: UInt64 = 0
    public var sweepWallNs: UInt64 = 0
    public var snapEntries: UInt64 = 0
    public var freedEntries: UInt64 = 0
    public var freedBytes: UInt64 = 0
    public var liveBytes: UInt64 = 0
    public var freedBlocks = 0
    public var aborted = false
    public var floatingBytes: UInt64 = 0
    public var missed: UInt64 = 0
    // starting values for deltas
    var satb0: UInt64 = 0
    var satbBuf0: UInt64 = 0
    var marked0: UInt64 = 0
    var markedBytes0: UInt64 = 0
    var markCpu0: UInt64 = 0
}

public struct CMLog {
    public var recs: UnsafeMutablePointer<CMCycle> = .allocate(capacity: 1 << 14)
    public var count = 0
    public var records: [CMCycle] { Array(UnsafeBufferPointer(start: recs, count: count)) }
    var current: UnsafeMutablePointer<CMCycle>? { count > 0 ? recs + (count - 1) : nil }
}

/// Pointers only; never written after `make`.
public struct CMShared {
    public var phase: UnsafeMutablePointer<Atomic<Int>>
    public var cycle: UnsafeMutablePointer<Atomic<UInt64>>
    var shutdown: UnsafeMutablePointer<Atomic<Bool>>
    /// An idle marker exists (export hint for two markers).
    var idleHint: UnsafeMutablePointer<Atomic<Int>>
    /// Pending full collection is a fallback (counted as such).
    var fallbackPending: UnsafeMutablePointer<Atomic<Bool>>
    public var mark: UnsafeMutablePointer<Atomic<UInt8>>
    public var snap: UnsafeMutablePointer<UInt64>
    var snapWords: UnsafeMutablePointer<Int>
    var snapBlocks: UnsafeMutablePointer<UInt8>
    var sweepLive: UnsafeMutablePointer<UInt8>
    var lock: UnsafeMutablePointer<pthread_mutex_t>
    var cond: UnsafeMutablePointer<pthread_cond_t>
    var q: UnsafeMutablePointer<CMQueue>
    /// Marker records, `markerCount[0]` of them.
    var markers: UnsafeMutablePointer<MarkerRef>
    var markerCount: UnsafeMutablePointer<Int>
    /// Stopper's drain stack (final mark, verifier).
    var drain: UnsafeMutablePointer<WordStack>
    public var log: UnsafeMutablePointer<CMLog>

    static func make(nblocks: Int) -> CMShared {
        func zmap(_ bytes: Int) -> UnsafeMutableRawPointer {
            guard let p = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), p != MAP_FAILED else {
                fatal("mmap failed")
            }
            return p
        }
        let lock = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
        pthread_mutex_init(lock, nil)
        let cond = UnsafeMutablePointer<pthread_cond_t>.allocate(capacity: 1)
        pthread_cond_init(cond, nil)
        let ms = UnsafeMutablePointer<MarkerRef>.allocate(capacity: 4)
        func atom<T: AtomicRepresentable>(_ v: T) -> UnsafeMutablePointer<Atomic<T>> {
            let p = UnsafeMutablePointer<Atomic<T>>.allocate(capacity: 1)
            p.initialize(to: Atomic(v))
            return p
        }
        return CMShared(phase: atom(CMPhase.idle), cycle: atom(UInt64(0)),
                        shutdown: atom(false), idleHint: atom(0),
                        fallbackPending: atom(false),
                        mark: zmap(tableEntries).bindMemory(to: Atomic<UInt8>.self, capacity: tableEntries),
                        snap: zmap(tableEntries / 8).bindMemory(to: UInt64.self, capacity: tableEntries / 64),
                        snapWords: boxed(0),
                        snapBlocks: zmap(nblocks).bindMemory(to: UInt8.self, capacity: nblocks),
                        sweepLive: zmap(nblocks).bindMemory(to: UInt8.self, capacity: nblocks),
                        lock: lock, cond: cond, q: boxed(CMQueue()), markers: ms, markerCount: boxed(0),
                        drain: boxed(WordStack(capacity: 1 << 16)), log: boxed(CMLog()))
    }

    @inline(__always) func inSnap(_ v: Oop) -> Bool {
        let idx = Int(truncatingIfNeeded: v &>> 4)
        return snap[idx &>> 6] & (UInt64(1) &<< UInt64(idx & 63)) != 0
    }
    /// True if this call marked `v`.
    @inline(__always) func tryMark(_ v: Oop) -> Bool {
        let m = mark + Int(truncatingIfNeeded: v &>> 4)
        return m.pointee.load(ordering: .relaxed) == 0 && m.pointee.exchange(1, ordering: .relaxed) == 0
    }
    @inline(__always) func isMarked(_ v: Oop) -> Bool {
        mark[Int(truncatingIfNeeded: v &>> 4)].load(ordering: .relaxed) != 0
    }
}

@inline(__always) func cmPhase(_ vm: VMRef) -> Int { vm.pointee.cm.phase.pointee.load(ordering: .acquiring) }

/// Register a marker record (Runtime, or a test acting as the marker).
public func makeMarker(_ vm: VMRef, id: Int) -> MarkerRef {
    let w = Worker.create(id: 1000 + id, nilObj: vm.pointee.nilObj, marker: true)
    let bytes = (MemoryLayout<Marker>.stride + 127) & ~127
    let m = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 128).bindMemory(to: Marker.self, capacity: 1)
    m.initialize(to: Marker(id: id, w: w))
    let cm = vm.pointee.cm
    cm.markers[cm.markerCount.pointee] = m
    cm.markerCount.pointee += 1
    return m
}

// MARK: - SATB handover (mutator side)

@inline(never)
func satbHandover(_ vm: VMRef, _ w: WorkerRef) {
    let cm = vm.pointee.cm
    pthread_mutex_lock(cm.lock)
    let q = cm.q
    q.pointee.items.push(CMItem(ptr: w.pointee.satbBuf, count: w.pointee.satbCount, grey: false))
    if let b = q.pointee.free.popLast() { w.pointee.satbBuf = b } else { w.pointee.satbBuf = .allocate(capacity: satbCap) }
    if q.pointee.waiting > 0 { pthread_cond_signal(cm.cond) }
    pthread_mutex_unlock(cm.lock)
    w.pointee.satbCount = 0
    w.pointee.satbHandovers &+= 1
}

extension RawBuf {
    mutating func popLast() -> T? {
        if count == 0 { return nil }
        count &-= 1
        return ptr[count]
    }
}

// MARK: - tracing

/// Scan one marked object; push the snapshot entries it names that this call
/// marks. Relaxed loads: mutators may be storing into the slots.
@inline(__always)
private func traceObject(_ om: OM, _ cm: CMShared, _ o: Oop, _ stack: inout WordStack) -> Int {
    let ent = om.entry(o)
    let h = atomicHeader(ent).pointee.load(ordering: .relaxed)
    if hdrIsBytes(h) { return objectBytes(h) }
    let n = hdrSlots(h)
    let s = wordPtr(om.heap &+ UInt(truncatingIfNeeded: ent[1])) + 1
    var i = 0
    while i < n {
        let v = atomicWord(s + i).pointee.load(ordering: .relaxed)
        if v & 1 == 0 && v != 0 && cm.inSnap(v) && cm.tryMark(v) { stack.push(v) }
        i &+= 1
    }
    return objectBytes(h)
}

/// An entry from an SATB buffer: grey it if it is an unmarked snapshot
/// entry. Tag 2 (literal test mode): a promoted object to scan regardless.
@inline(__always)
private func greyCandidate(_ cm: CMShared, _ v: Oop, _ stack: inout WordStack) {
    if v & 2 != 0 { stack.push(v & ~2); return }
    if cm.inSnap(v) && cm.tryMark(v) { stack.push(v) }
}

// MARK: - initial mark (stopper, world stopped, nothing young unless literal)

func initialMark(_ vm: VMRef, _ rec: inout GCRecord, literal: Bool) {
    let cm = vm.pointee.cm
    let heap = vm.pointee.heap
    let sp = vm.pointee.space
    let ta = now()
    // 1. Snapshot blocks are frozen: no promotion appends to them again.
    if let ws = vm.pointee.workers {
        for i in 0..<vm.pointee.workerCount { heap.retire(&ws[i].pointee.promo) }
    }
    // 2. Snapshot bitmap and block map.
    let words = chunkHwmNow(vm) * wordsPerChunk
    cm.snap.update(from: sp.used, count: words)
    cm.snap[0] &= ~1 // entry 0 is not an object
    if literal {
        // DESIGN.md's literal protocol: young objects exist; they are not
        // snapshot entries.
        for i in 0..<vm.pointee.workerCount {
            let x = worker(vm, i)
            for k in 0..<x.pointee.logWord.count {
                cm.snap[Int(x.pointee.logWord.ptr[k])] &= ~x.pointee.logBits.ptr[k]
            }
        }
    }
    cm.snapWords.pointee = words
    for b in 0..<heap.nblocks { cm.snapBlocks[b] = heap.inUse[b] ? 1 : 0 }
    let tb = now()
    // 3. Flip.
    let cyc = cm.cycle.pointee.load(ordering: .relaxed) &+ 1
    cm.cycle.pointee.store(cyc, ordering: .relaxed)
    var satb0: UInt64 = 0, satbBuf0: UInt64 = 0
    if let ws = vm.pointee.workers {
        for i in 0..<vm.pointee.workerCount {
            let x = ws[i]
            x.pointee.marking = 1
            x.pointee.satbCount = 0
            satb0 &+= x.pointee.satbPushed
            satbBuf0 &+= x.pointee.satbHandovers
        }
    }
    pthread_mutex_lock(cm.lock)
    let q = cm.q
    while let it = q.pointee.items.popLast() { q.pointee.free.push(it.ptr) }
    q.pointee.greyItems = 0
    for i in 0..<q.pointee.idle.count { q.pointee.idle[i] = false }
    q.pointee.idleCount = 0
    pthread_mutex_unlock(cm.lock)
    cm.idleHint.pointee.store(0, ordering: .relaxed)
    // 4. Roots: grey every snapshot entry a root word names.
    let ds = cm.drain
    ds.pointee.count = 0
    var rootWords = 0
    for (p, c) in rootRanges(vm) {
        rootWords &+= c
        var i = 0
        while i < c {
            let v = p[i]
            if v & 1 == 0 && v != 0 && cm.inSnap(v) && cm.tryMark(v) { ds.pointee.push(v) }
            i &+= 1
        }
    }
    let greyed = ds.pointee.count
    // 5. Queue as packets, wake the markers.
    pthread_mutex_lock(cm.lock)
    var off = 0
    while off < greyed {
        let n = min(greyPacketWords, greyed - off)
        let b = q.pointee.free.popLast() ?? .allocate(capacity: satbCap)
        b.update(from: ds.pointee.ptr + off, count: n)
        q.pointee.items.push(CMItem(ptr: b, count: n, grey: true))
        q.pointee.greyItems += 1
        off += n
    }
    ds.pointee.count = 0
    cm.phase.pointee.store(CMPhase.marking, ordering: .releasing)
    pthread_cond_broadcast(cm.cond)
    pthread_mutex_unlock(cm.lock)
    let tc = now()
    rec.snapNs = tb &- ta
    rec.cmRootsNs = tc &- tb
    rec.cmRootWords = UInt64(rootWords)
    rec.greyed = UInt64(greyed)
    // Cycle record.
    let log = vm.pointee.cm.log
    if log.pointee.count < 1 << 14 {
        var c = CMCycle()
        c.cycle = cyc
        c.startNs = now()
        c.oldBlocksStart = heap.blocksInUse()
        c.satb0 = satb0
        c.satbBuf0 = satbBuf0
        for k in 0..<cm.markerCount.pointee {
            let m = cm.markers[k]
            c.marked0 &+= m.pointee.markedObjects
            c.markedBytes0 &+= m.pointee.markedBytes
            c.markCpu0 &+= m.pointee.markCpuNs
        }
        log.pointee.recs[log.pointee.count] = c
        log.pointee.count += 1
    }
    vm.add(.cmCycles, 1)
}

// MARK: - marker threads

private struct MarkerCtx {
    var vm: VMRef
    var m: MarkerRef
}

private func markerThreadMain(_ arg: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
    let ctx = arg.assumingMemoryBound(to: MarkerCtx.self)
    markerLoop(ctx.pointee.vm, ctx.pointee.m)
    return nil
}

/// Start `n` marker threads at QoS utility (SPEC.md "Grey set and markers").
func startMarkers(_ vm: VMRef, _ n: Int) -> [pthread_t] {
    var ts: [pthread_t] = []
    for i in 0..<n {
        let m = makeMarker(vm, id: i)
        let ctx = UnsafeMutablePointer<MarkerCtx>.allocate(capacity: 1)
        ctx.initialize(to: MarkerCtx(vm: vm, m: m))
        var attr = pthread_attr_t()
        pthread_attr_init(&attr)
        pthread_attr_set_qos_class_np(&attr, vm.pointee.cmConfig.markerQoS, 0)
        var tid: pthread_t? = nil
        if pthread_create(&tid, &attr, markerThreadMain, UnsafeMutableRawPointer(ctx)) != 0 { fatal("pthread_create marker") }
        pthread_attr_destroy(&attr)
        ts.append(tid!)
    }
    return ts
}

func stopMarkers(_ vm: VMRef, _ ts: [pthread_t]) {
    let cm = vm.pointee.cm
    pthread_mutex_lock(cm.lock)
    cm.shutdown.pointee.store(true, ordering: .releasing)
    pthread_cond_broadcast(cm.cond)
    pthread_mutex_unlock(cm.lock)
    for t in ts { pthread_join(t, nil) }
}

@inline(__always) func threadCpuNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

private func markerLoop(_ vm: VMRef, _ m: MarkerRef) {
    let cm = vm.pointee.cm
    var sweptCycle: UInt64 = 0
    var lastCycle: UInt64 = 0
    while true {
        // Outside the VM: wait for something to do.
        pthread_mutex_lock(cm.lock)
        var work = 0 // 1 mark, 2 sweep
        while !cm.shutdown.pointee.load(ordering: .relaxed) {
            let ph = cm.phase.pointee.load(ordering: .acquiring)
            let cyc = cm.cycle.pointee.load(ordering: .relaxed)
            if ph == CMPhase.marking && (cm.q.pointee.items.count > 0 || cyc != lastCycle) { work = 1; break }
            if ph == CMPhase.sweeping && m.pointee.id == 0 && cyc != sweptCycle { work = 2; break }
            cm.q.pointee.waiting += 1
            var ts = timespec(tv_sec: 0, tv_nsec: 1_000_000)
            pthread_cond_timedwait_relative_np(cm.cond, cm.lock, &ts)
            cm.q.pointee.waiting -= 1
        }
        pthread_mutex_unlock(cm.lock)
        if work == 0 { break }
        enterVM(vm, m.pointee.w)
        let cyc = cm.cycle.pointee.load(ordering: .relaxed)
        if work == 1 && cmPhase(vm) == CMPhase.marking {
            lastCycle = cyc
            markWork(vm, m, cyc, limit: .max)
        } else if work == 2 && cmPhase(vm) == CMPhase.sweeping {
            sweptCycle = cyc
            sweepWork(vm, m, cyc)
        }
        leaveVM(vm, m.pointee.w)
    }
}

/// Mutex not held. Park through a stop like a worker, without joining it.
private func markerSafepoint(_ vm: VMRef, _ m: MarkerRef) {
    pthread_mutex_lock(vm.pointee.mutex)
    if vm.pointee.gcRequested.load(ordering: .acquiring) {
        let sync = vm.pointee.sync
        let epoch = sync.pointee.epoch
        sync.pointee.parked += 1
        pthread_cond_broadcast(vm.pointee.cond)
        while sync.pointee.epoch == epoch { pthread_cond_wait(vm.pointee.cond, vm.pointee.mutex) }
    }
    pthread_mutex_unlock(vm.pointee.mutex)
}

/// Inside the VM. Trace until the cycle has no work left (then request the
/// final mark if every marker is idle), the cycle changes, or `limit`
/// objects were traced (tests). Answers objects traced.
@discardableResult
func markWork(_ vm: VMRef, _ m: MarkerRef, _ cyc: UInt64, limit: Int) -> Int {
    let cm = vm.pointee.cm
    let om = vm.pointee.om
    let nm = cm.markerCount.pointee
    var traced = 0
    var objs: UInt64 = 0, bytes: UInt64 = 0
    var cpu0 = threadCpuNs()
    // Counters and CPU time reach the Marker record before every point where
    // a stopper may read it.
    func flush() {
        m.pointee.markedObjects &+= objs; objs = 0
        m.pointee.markedBytes &+= bytes; bytes = 0
        let c = threadCpuNs()
        m.pointee.markCpuNs &+= c &- cpu0
        cpu0 = c
    }
    defer { flush() }
    while traced < limit {
        if vm.pointee.gcRequested.load(ordering: .relaxed) {
            flush()
            markerSafepoint(vm, m)
            cpu0 = threadCpuNs()
            if cm.phase.pointee.load(ordering: .acquiring) != CMPhase.marking
                || cm.cycle.pointee.load(ordering: .relaxed) != cyc {
                m.pointee.stack.count = 0
                return traced
            }
        }
        var k = 0
        while k < 128 && traced < limit, let o = m.pointee.stack.pop() {
            bytes &+= UInt64(traceObject(om, cm, o, &m.pointee.stack))
            objs &+= 1
            k &+= 1
            traced &+= 1
        }
        if k > 0 {
            if nm > 1 && m.pointee.stack.count >= 64 && cm.idleHint.pointee.load(ordering: .relaxed) > 0 {
                exportPacket(cm, m)
            }
            continue
        }
        // Local stack empty: take queued work.
        pthread_mutex_lock(cm.lock)
        let q = cm.q
        if let it = q.pointee.items.popLast() {
            if it.grey { q.pointee.greyItems -= 1 }
            if q.pointee.idle[m.pointee.id] {
                q.pointee.idle[m.pointee.id] = false
                q.pointee.idleCount -= 1
                cm.idleHint.pointee.store(q.pointee.idleCount, ordering: .relaxed)
            }
            pthread_mutex_unlock(cm.lock)
            if it.grey {
                for i in 0..<it.count { m.pointee.stack.push(it.ptr[i]) }
            } else {
                for i in 0..<it.count { greyCandidate(cm, it.ptr[i], &m.pointee.stack) }
            }
            pthread_mutex_lock(cm.lock)
            q.pointee.free.push(it.ptr)
            pthread_mutex_unlock(cm.lock)
            continue
        }
        if !q.pointee.idle[m.pointee.id] {
            q.pointee.idle[m.pointee.id] = true
            q.pointee.idleCount += 1
            cm.idleHint.pointee.store(q.pointee.idleCount, ordering: .relaxed)
        }
        let all = q.pointee.idleCount >= nm
        pthread_mutex_unlock(cm.lock)
        if all && limit == .max {
            flush()
            stopWorld(vm, m.pointee.w, .finalMark, retry: true)
            cpu0 = threadCpuNs()
        }
        return traced
    }
    return traced
}

private func exportPacket(_ cm: CMShared, _ m: MarkerRef) {
    pthread_mutex_lock(cm.lock)
    let q = cm.q
    if q.pointee.greyItems > 0 { pthread_mutex_unlock(cm.lock); return }
    let n = min(m.pointee.stack.count / 2, greyPacketWords)
    let b = q.pointee.free.popLast() ?? .allocate(capacity: satbCap)
    let st = m.pointee.stack.ptr
    b.update(from: st, count: n)
    st.update(from: st + n, count: m.pointee.stack.count - n)
    m.pointee.stack.count -= n
    q.pointee.items.push(CMItem(ptr: b, count: n, grey: true))
    q.pointee.greyItems += 1
    if q.pointee.waiting > 0 { pthread_cond_broadcast(cm.cond) }
    pthread_mutex_unlock(cm.lock)
    m.pointee.exported &+= 1
}

// MARK: - final mark (stopper, world stopped)

func finalMark(_ vm: VMRef, _ rec: inout GCRecord) {
    let cm = vm.pointee.cm
    let om = vm.pointee.om
    let force = vm.pointee.cmConfig.force
    let ta = now()
    let ds = cm.drain
    ds.pointee.count = 0
    var entries: UInt64 = 0
    var satbNow: UInt64 = 0, satbBufNow: UInt64 = 0
    // 1-2. Marking off; every partial buffer, queued item and marker stack.
    if let ws = vm.pointee.workers {
        for i in 0..<vm.pointee.workerCount {
            let x = ws[i]
            x.pointee.marking = force ? 1 : 0
            for k in 0..<x.pointee.satbCount { greyCandidate(cm, x.pointee.satbBuf[k], &ds.pointee) }
            entries &+= UInt64(x.pointee.satbCount)
            x.pointee.satbCount = 0
            satbNow &+= x.pointee.satbPushed
            satbBufNow &+= x.pointee.satbHandovers
        }
    }
    pthread_mutex_lock(cm.lock)
    let q = cm.q
    while let it = q.pointee.items.popLast() {
        if it.grey { for i in 0..<it.count { ds.pointee.push(it.ptr[i]) } }
        else { for i in 0..<it.count { greyCandidate(cm, it.ptr[i], &ds.pointee) } }
        entries &+= UInt64(it.count)
        q.pointee.free.push(it.ptr)
    }
    q.pointee.greyItems = 0
    pthread_mutex_unlock(cm.lock)
    for k in 0..<cm.markerCount.pointee {
        let m = cm.markers[k]
        while let o = m.pointee.stack.pop() { ds.pointee.push(o) }
    }
    var objs: UInt64 = 0, bytes: UInt64 = 0
    while let o = ds.pointee.pop() {
        bytes &+= UInt64(traceObject(om, cm, o, &ds.pointee))
        objs &+= 1
    }
    let tb = now()
    // 3. Dead remembered holders leave the remembered set.
    var filtered = 0
    if let ws = vm.pointee.workers {
        let rem = vm.pointee.space.rem
        for i in 0..<vm.pointee.workerCount {
            let x = ws[i]
            var j = 0
            for k in 0..<x.pointee.remBuf.count {
                let h = x.pointee.remBuf.ptr[k]
                if cm.inSnap(h) && !cm.isMarked(h) {
                    rem[Int(truncatingIfNeeded: h &>> 4)].store(0, ordering: .relaxed)
                    filtered += 1
                } else {
                    x.pointee.remBuf.ptr[j] = h
                    j += 1
                }
            }
            x.pointee.remBuf.count = j
        }
    }
    let tc = now()
    // 4. Verifier.
    var floating: UInt64 = 0, missed: UInt64 = 0
    if vm.pointee.cmConfig.verify { (missed, floating) = verifyMarks(vm) }
    let td = now()
    rec.drainNs = tb &- ta
    rec.drainEntries = entries
    rec.drainObjects = objs
    rec.filterNs = tc &- tb
    rec.verifyNs = td &- tc
    rec.filtered = UInt64(filtered)
    if let c = cm.log.pointee.current, c.pointee.finalNs == 0 && !c.pointee.aborted {
        c.pointee.finalNs = now()
        c.pointee.oldBlocksFinal = vm.pointee.heap.blocksInUse()
        var mo: UInt64 = 0, mb: UInt64 = 0, cpu: UInt64 = 0
        for k in 0..<cm.markerCount.pointee {
            let m = cm.markers[k]
            mo &+= m.pointee.markedObjects
            mb &+= m.pointee.markedBytes
            cpu &+= m.pointee.markCpuNs
        }
        c.pointee.markedObjects = mo &- c.pointee.marked0 &+ objs
        c.pointee.markedBytes = mb &- c.pointee.markedBytes0 &+ bytes
        c.pointee.drainedObjects = objs
        c.pointee.markCpuNs = cpu &- c.pointee.markCpu0
        c.pointee.satbEntries = satbNow &- c.pointee.satb0
        c.pointee.satbBuffers = satbBufNow &- c.pointee.satbBuf0
        c.pointee.floatingBytes = floating
        c.pointee.missed = missed
    }
    // 5. Sweep.
    pthread_mutex_lock(cm.lock)
    cm.phase.pointee.store(CMPhase.sweeping, ordering: .releasing)
    pthread_cond_broadcast(cm.cond)
    pthread_mutex_unlock(cm.lock)
}

// MARK: - lazy sweep (marker 0, inside the VM)

/// Answers false if the cycle was aborted while sweeping.
@discardableResult
func sweepWork(_ vm: VMRef, _ m: MarkerRef, _ cyc: UInt64) -> Bool {
    let cm = vm.pointee.cm
    let om = vm.pointee.om
    let heap = vm.pointee.heap
    let used = vm.pointee.space.used
    let t0 = threadCpuNs()
    m.pointee.sweepStart = now()
    m.pointee.sweepCycle = cyc
    m.pointee.freedChunks.count = 0
    var freed: UInt64 = 0, freedBytes: UInt64 = 0, live: UInt64 = 0, snapN: UInt64 = 0
    let words = cm.snapWords.pointee
    var c = 0
    while c * wordsPerChunk < words {
        if vm.pointee.gcRequested.load(ordering: .relaxed) {
            markerSafepoint(vm, m)
            if cm.phase.pointee.load(ordering: .acquiring) != CMPhase.sweeping
                || cm.cycle.pointee.load(ordering: .relaxed) != cyc {
                m.pointee.sweepCpuNs &+= threadCpuNs() &- t0
                return false
            }
        }
        var chunkFreed = false
        for k in 0..<wordsPerChunk {
            let gw = c &* wordsPerChunk &+ k
            let s = cm.snap[gw]
            if s == 0 { continue }
            var bits = s
            var dead: UInt64 = 0
            while bits != 0 {
                let b = bits.trailingZeroBitCount
                bits &= bits &- 1
                let idx = gw &* 64 &+ b
                let e = om.entry(UInt64(idx) &<< 4)
                let h = e[0]
                snapN &+= 1
                if cm.mark[idx].load(ordering: .relaxed) != 0 {
                    cm.mark[idx].store(0, ordering: .relaxed)
                    live &+= UInt64(objectBytes(h))
                    cm.sweepLive[heap.blockOf(om.heap &+ UInt(e[1]))] = 1
                } else {
                    dead |= UInt64(1) &<< UInt64(b)
                    freedBytes &+= UInt64(objectBytes(h))
                }
            }
            if dead != 0 {
                // Releasing: a worker that takes a freed bit (acquiring
                // exchange) and rewrites the entry must not race with the
                // reads of it above (ThreadSanitizer found this as relaxed).
                atomicWord(used + gw).pointee.bitwiseAnd(~dead, ordering: .releasing)
                freed &+= UInt64(dead.nonzeroBitCount)
                chunkFreed = true
            }
        }
        if chunkFreed { m.pointee.freedChunks.push(UInt32(c)) }
        c &+= 1
    }
    let dt = threadCpuNs() &- t0
    m.pointee.sweepCpuNs &+= dt
    m.pointee.sweepCpu = dt
    m.pointee.sweepFreed = freed
    m.pointee.sweepFreedBytes = freedBytes
    m.pointee.sweepLiveBytes = live
    m.pointee.sweepSnapEntries = snapN
    m.pointee.sweepEnd = now()
    cm.phase.pointee.store(CMPhase.swept, ordering: .releasing)
    return true
}

// MARK: - apply (stopper, world stopped, phase swept)

func applySweep(_ vm: VMRef) -> UInt64 {
    let t0 = now()
    let cm = vm.pointee.cm
    let heap = vm.pointee.heap
    var freedBlocks = 0
    for b in 0..<heap.nblocks where cm.snapBlocks[b] != 0 {
        if cm.sweepLive[b] == 0 && heap.inUse[b] {
            heap.inUse[b] = false
            heap.used[b] = 0
            freedBlocks += 1
        }
        cm.snapBlocks[b] = 0
        cm.sweepLive[b] = 0
    }
    heap.rebuildFreeList()
    if cm.markerCount.pointee == 0 { fatal("apply without a sweeper") }
    let m0 = cm.markers[0]
    addChunksToPool(vm, m0.pointee.freedChunks.ptr, m0.pointee.freedChunks.count)
    m0.pointee.freedChunks.count = 0
    if let c = cm.log.pointee.current, !c.pointee.aborted {
        c.pointee.appliedNs = now()
        c.pointee.oldBlocksAfter = heap.blocksInUse()
        c.pointee.freedBlocks = freedBlocks
        c.pointee.freedEntries = m0.pointee.sweepFreed
        c.pointee.freedBytes = m0.pointee.sweepFreedBytes
        c.pointee.liveBytes = m0.pointee.sweepLiveBytes
        c.pointee.snapEntries = m0.pointee.sweepSnapEntries
        c.pointee.sweepCpuNs = m0.pointee.sweepCpu
        c.pointee.sweepWallNs = m0.pointee.sweepEnd &- m0.pointee.sweepStart
    }
    vm.set(.liveBytes, m0.pointee.sweepLiveBytes)
    cm.phase.pointee.store(CMPhase.idle, ordering: .releasing)
    return now() &- t0
}

/// World stopped: append chunks to the chunk pool's unconsumed part, skipping
/// those already in it.
func addChunksToPool(_ vm: VMRef, _ cs: UnsafeMutablePointer<UInt32>, _ n: Int) {
    if n == 0 { return }
    let sp = vm.pointee.space
    let count = sp.poolCount.pointee.load(ordering: .relaxed)
    let next = min(sp.poolNext.pointee.load(ordering: .relaxed), count)
    var k = 0
    for i in next..<count { sp.poolScratch[k] = sp.pool[i]; sp.inPool[Int(sp.pool[i])] = 1; k += 1 }
    for i in 0..<n where sp.inPool[Int(cs[i])] == 0 {
        sp.poolScratch[k] = cs[i]
        sp.inPool[Int(cs[i])] = 1
        k += 1
    }
    for i in 0..<k { sp.inPool[Int(sp.poolScratch[i])] = 0 }
    sp.pool.update(from: sp.poolScratch, count: k)
    sp.poolCount.pointee.store(k, ordering: .relaxed)
    sp.poolNext.pointee.store(0, ordering: .relaxed)
}

// MARK: - abort (fallback; stopper, world stopped)

func abortCycle(_ vm: VMRef) {
    let cm = vm.pointee.cm
    let ph = cm.phase.pointee.load(ordering: .relaxed)
    if ph == CMPhase.idle { return }
    let force = vm.pointee.cmConfig.force
    if let ws = vm.pointee.workers {
        for i in 0..<vm.pointee.workerCount {
            ws[i].pointee.marking = force ? 1 : 0
            ws[i].pointee.satbCount = 0
        }
    }
    pthread_mutex_lock(cm.lock)
    let q = cm.q
    while let it = q.pointee.items.popLast() { q.pointee.free.push(it.ptr) }
    q.pointee.greyItems = 0
    pthread_mutex_unlock(cm.lock)
    let entries = chunkHwmNow(vm) * chunkEntries
    UnsafeMutableRawPointer(cm.mark).initializeMemory(as: UInt8.self, repeating: 0, count: entries)
    let heap = vm.pointee.heap
    for b in 0..<heap.nblocks { cm.snapBlocks[b] = 0; cm.sweepLive[b] = 0 }
    for k in 0..<cm.markerCount.pointee { cm.markers[k].pointee.stack.count = 0 }
    if cm.markerCount.pointee > 0 { cm.markers[0].pointee.freedChunks.count = 0 }
    if let c = cm.log.pointee.current { c.pointee.aborted = true }
    cm.cycle.pointee.store(cm.cycle.pointee.load(ordering: .relaxed) &+ 1, ordering: .relaxed)
    cm.phase.pointee.store(CMPhase.idle, ordering: .releasing)
    vm.add(.cmAborts, 1)
}

// MARK: - verifier (SPEC.md "Verifier")

/// From-scratch traversal through every reachable object, young and old;
/// compares with the mark map. Answers (missed, floating garbage bytes).
func verifyMarks(_ vm: VMRef) -> (UInt64, UInt64) {
    vm.add(.cmVerifyRuns, 1)
    let cm = vm.pointee.cm
    let om = vm.pointee.om
    let words = chunkHwmNow(vm) * wordsPerChunk
    let seen = UnsafeMutablePointer<UInt64>.allocate(capacity: max(words, 1))
    seen.initialize(repeating: 0, count: max(words, 1))
    defer { seen.deallocate() }
    var stack = WordStack(capacity: 1 << 16)
    defer { stack.ptr.deallocate() }
    func visit(_ v: Oop) {
        if v & 1 != 0 || v == 0 { return }
        let idx = Int(truncatingIfNeeded: v &>> 4)
        let bit = UInt64(1) &<< UInt64(idx & 63)
        if seen[idx >> 6] & bit != 0 { return }
        seen[idx >> 6] |= bit
        if !hdrIsBytes(om.header(v)) { stack.push(v) }
    }
    for (p, c) in rootRanges(vm) {
        for i in 0..<c { visit(p[i]) }
        while let o = stack.pop() {
            let n = hdrSlots(om.header(o))
            for i in 0..<n { visit(om.slot(o, i)) }
        }
    }
    var missed: UInt64 = 0, floating: UInt64 = 0
    for gw in 0..<min(words, cm.snapWords.pointee) {
        var bits = cm.snap[gw]
        while bits != 0 {
            let b = bits.trailingZeroBitCount
            bits &= bits &- 1
            let idx = gw * 64 + b
            let reach = seen[gw] & (UInt64(1) << UInt64(b)) != 0
            let marked = cm.mark[idx].load(ordering: .relaxed) != 0
            if reach && !marked {
                missed += 1
                let o = UInt64(idx) << 4
                let n = vm.metric(.verifyFailures)
                vm.add(.verifyFailures, 1)
                if n < 10 { FileHandleStderr.write("verify: concurrent mark missed reachable entry \(o) (class \(hdrClass(om.header(o))))\n") }
            } else if marked && !reach {
                floating &+= UInt64(objectBytes(om.header(UInt64(idx) << 4)))
            }
        }
    }
    vm.add(.cmMissed, missed)
    vm.add(.cmFloatingBytes, floating)
    return (missed, floating)
}

/// For the inherited verifier: a snapshot entry that is unmarked while a
/// sweep is pending (sweeping or swept) is dead and may name freed entries.
func pendingDead(_ vm: VMRef, _ idx: Int) -> Bool {
    let cm = vm.pointee.cm
    let ph = cm.phase.pointee.load(ordering: .relaxed)
    if ph != CMPhase.sweeping && ph != CMPhase.swept { return false }
    if idx >= cm.snapWords.pointee * 64 { return false }
    if cm.snap[idx >> 6] & (UInt64(1) << UInt64(idx & 63)) == 0 { return false }
    return cm.mark[idx].load(ordering: .relaxed) == 0
}

// MARK: - host and test API (SPEC.md "Test-only protocol switches")

/// Start a cycle now: a stop whose scavenge (unless literal) is followed by
/// the initial mark. Host thread.
public func cmStart(_ vm: VMRef, scavenge: Bool = true) {
    let w = worker(vm, vm.pointee.workerCount - 1)
    enterVM(vm, w)
    stopWorld(vm, w, .startCycle(scavenge: scavenge), retry: true)
    leaveVM(vm, w)
}

/// Manual marker: trace up to `n` objects on this thread (inside the VM).
@discardableResult
public func cmMark(_ vm: VMRef, _ m: MarkerRef, _ n: Int) -> Int {
    enterVM(vm, m.pointee.w)
    let cyc = vm.pointee.cm.cycle.pointee.load(ordering: .relaxed)
    var done = 0
    if cmPhase(vm) == CMPhase.marking { done = markWork(vm, m, cyc, limit: n) }
    leaveVM(vm, m.pointee.w)
    return done
}

/// The final-mark pause, from the host thread.
public func cmFinal(_ vm: VMRef) {
    let w = worker(vm, vm.pointee.workerCount - 1)
    enterVM(vm, w)
    stopWorld(vm, w, .finalMark, retry: true)
    leaveVM(vm, w)
}

/// Manual sweeper: run the whole sweep on this thread.
public func cmSweep(_ vm: VMRef, _ m: MarkerRef) {
    enterVM(vm, m.pointee.w)
    if cmPhase(vm) == CMPhase.sweeping {
        sweepWork(vm, m, vm.pointee.cm.cycle.pointee.load(ordering: .relaxed))
    }
    leaveVM(vm, m.pointee.w)
}

public func cmPhaseNow(_ vm: VMRef) -> Int { cmPhase(vm) }
