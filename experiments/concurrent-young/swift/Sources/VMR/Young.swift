// Young collection without stopping the world (SPEC.md "Part 1", "Part 2",
// "Handshakes", "Processes", "Part 3", "Young verifier").
//
// Ownership: `Nur` (one per nursery) is written only by whoever collects that
// nursery, or with the world stopped. `HS` (one per nursery) is guarded by
// the safepoint mutex. Everything else shared is an atomic behind a pointer
// in `YShared`, which is never written after `make`.

import Darwin
import Synchronization

public enum YoungMode {
    public static let stw = 0
    public static let local = 1
    public static let offload = 2
    public static func name(_ m: Int) -> String { ["stw", "local", "offload"][m] }
}

/// Round kinds (SPEC.md "Handshakes").
enum Round {
    static let h0: UInt8 = 0
    static let h1: UInt8 = 1
    static let drain: UInt8 = 2
}

public typealias YCHook = @convention(c) (UnsafeMutableRawPointer?, Int, Int) -> Void

/// Set before any VM thread starts.
public struct YCConfig {
    public var mode = YoungMode.stw
    /// Part 3: (a) young-root scan at the initial mark; false: (b) forced
    /// global scavenge.
    public var imYoung = true
    public var collectorQoS = QOS_CLASS_USER_INITIATED
    /// Young verifier at a forced pause after every local collection.
    public var verifyYoung = false
    /// Verify after every n-th collection (threaded tests use 4: the
    /// from-scratch walk dominates them under ThreadSanitizer).
    public var verifyEvery = 1
    // --- test-only switches (SPEC.md "Test-only switches")
    public var youngDeletion = true
    public var crossNursery = true
    public var stackScan = true
    public var epochRule = true
    public var secondHandshake = true
    public var youngRoots = true
    public var carryRem = true
    /// Offload: remember same-nursery holders outside Y of a value in Y.
    public var snoop = true
    /// Offload: scan the owner's new-half objects allocated before its H1
    /// acknowledgement at T1.
    public var newHalfScan = true
    /// Called by a collector with (ctx, nursery, point); point 1: H1 done,
    /// before T1.
    public var hook: YCHook? = nil
    public var hookCtx: UnsafeMutableRawPointer? = nil
    public init() {}
}

/// Per-nursery collector-owned state.
struct Nur {
    var survBase: UInt = 0
    var survBytes: UInt = 0
    var survTo = 1
    var survCur: UInt = 0
    var survFromTop: UInt = 0
    /// Young log of the survivors in survivor-from, and of those being copied.
    var survLogWord = RawBuf<UInt32>(capacity: 256)
    var survLogBits = RawBuf<UInt64>(capacity: 256)
    var nextLogWord = RawBuf<UInt32>(capacity: 256)
    var nextLogBits = RawBuf<UInt64>(capacity: 256)
    /// Holders kept in this nursery's remembered set by its last collection.
    var carried = RawBuf<Oop>(capacity: 64)
    var nextCarried = RawBuf<Oop>(capacity: 64)
    /// The collection in flight: its young log and chunks, chunks with free
    /// entries afterwards (the owner's recycle list), deferred entry frees.
    var colLogWord = RawBuf<UInt32>(capacity: 1024)
    var colLogBits = RawBuf<UInt64>(capacity: 1024)
    var colChunks = RawBuf<UInt32>(capacity: 64)
    var recycleOut = RawBuf<UInt32>(capacity: 64)
    var deferred = RawBuf<Oop>(capacity: 64)
    var stats = YCRecord()
    @inline(__always) func survStart(_ i: Int) -> UInt { survBase &+ UInt(i) &* survBytes }
}

/// A published remembered or deletion buffer, owned by the collector.
struct PubBuf {
    var ptr: UnsafeMutablePointer<Oop>
    var count: Int
    var rem: Bool
}

/// Handshake state of one nursery's collection. Guarded by the safepoint mutex.
struct HS {
    var active = false
    var round: UInt64 = 0
    var kind: UInt8 = 0
    var need = 0
    var acked: UnsafeMutablePointer<UInt64>
    var roots = RawBuf<Oop>(capacity: 256)
    var pubs = RawBuf<PubBuf>(capacity: 64)
    var openedAt: UInt64 = 0
    var lastAcker = -1
    var lastAckerProxyOnly = false
}

/// One local collection (SPEC.md "Scenarios", "Headless matrix"). ns.
public struct YCRecord {
    public var nursery = 0
    public var offloaded = false
    public var openAt: UInt64 = 0
    public var startAt: UInt64 = 0
    public var h0Ns: UInt64 = 0
    public var h1Ns: UInt64 = 0
    public var t1Ns: UInt64 = 0
    public var traceNs: UInt64 = 0
    public var drainRoundsNs: UInt64 = 0
    public var sweepNs: UInt64 = 0
    public var epochWaitNs: UInt64 = 0
    public var totalNs: UInt64 = 0
    public var rounds = 0
    public var stackRoots: UInt64 = 0
    public var procScans: UInt64 = 0
    public var holders: UInt64 = 0
    public var delRecords: UInt64 = 0
    public var youngBytes: UInt64 = 0
    public var copiedObjects: UInt64 = 0
    public var survivedBytes: UInt64 = 0
    public var promotedBytes: UInt64 = 0
    public var overflowBytes: UInt64 = 0
    public var carried: UInt64 = 0
    public var crossRemembered: UInt64 = 0
    public var entriesFreed: UInt64 = 0
    public var deferredFrees: UInt64 = 0
    public var hazardRetries: UInt64 = 0
    public var newHalfWords: UInt64 = 0
}

public struct YCLog {
    public var recs: UnsafeMutablePointer<YCRecord> = .allocate(capacity: 1 << 18)
    public var count = 0
    public var records: [YCRecord] { Array(UnsafeBufferPointer(start: recs, count: count)) }
}

/// Pointers only; never written after `make`.
public struct YShared {
    var nur: UnsafeMutablePointer<UnsafeMutablePointer<Nur>>
    var hs: UnsafeMutablePointer<UnsafeMutablePointer<HS>>
    var collecting: UnsafeMutablePointer<Atomic<Bool>>
    var afterH1: UnsafeMutablePointer<Atomic<Bool>>
    var afterT1: UnsafeMutablePointer<Atomic<Bool>>
    var done: UnsafeMutablePointer<Atomic<Bool>>
    var seq: UnsafeMutablePointer<Atomic<UInt64>>
    /// Y range per nursery: eden lo, hi, survivor-from lo, hi (heap offsets).
    var range: UnsafeMutablePointer<Atomic<UInt64>>
    /// Process scan words, nursery-major (SPEC.md "Processes").
    var recScan: UnsafeMutablePointer<Atomic<UInt64>>
    /// Offload queue of nurseries, guarded by the safepoint mutex.
    var queue: UnsafeMutablePointer<RawBuf<Int>>
    var queueHead: UnsafeMutablePointer<Int>
    var cond: UnsafeMutablePointer<pthread_cond_t>
    var shutdown: UnsafeMutablePointer<Atomic<Bool>>
    /// The collector thread's record (offload), else nil.
    var collector: UnsafeMutablePointer<WorkerRef?>
    /// Collection records and handshake latencies; guarded by the mutex.
    public var log: UnsafeMutablePointer<YCLog>
    public var hsLatency: UnsafeMutablePointer<Samples>
    /// Worst handshake: latency, last acknowledging worker, round kind.
    public var hsWorst: UnsafeMutablePointer<(UInt64, Int, UInt8)>

    static func make() -> YShared {
        func atoms<T: AtomicRepresentable>(_ n: Int, _ v: T) -> UnsafeMutablePointer<Atomic<T>> {
            let p = UnsafeMutablePointer<Atomic<T>>.allocate(capacity: n)
            for i in 0..<n { (p + i).initialize(to: Atomic(v)) }
            return p
        }
        let nur = UnsafeMutablePointer<UnsafeMutablePointer<Nur>>.allocate(capacity: maxNurseries)
        let hs = UnsafeMutablePointer<UnsafeMutablePointer<HS>>.allocate(capacity: maxNurseries)
        for i in 0..<maxNurseries {
            nur[i] = boxed(Nur())
            let acked = UnsafeMutablePointer<UInt64>.allocate(capacity: maxNurseries)
            acked.initialize(repeating: 0, count: maxNurseries)
            hs[i] = boxed(HS(acked: acked))
        }
        let rs = maxNurseries * maxProcesses
        guard let m = mmap(nil, rs * 8, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), m != MAP_FAILED else { fatal("mmap") }
        let cond = UnsafeMutablePointer<pthread_cond_t>.allocate(capacity: 1)
        pthread_cond_init(cond, nil)
        return YShared(nur: nur, hs: hs, collecting: atoms(maxNurseries, false), afterH1: atoms(maxNurseries, false),
                       afterT1: atoms(maxNurseries, false), done: atoms(maxNurseries, true),
                       seq: atoms(maxNurseries, UInt64(0)), range: atoms(maxNurseries * 6, UInt64(0)),
                       recScan: m.bindMemory(to: Atomic<UInt64>.self, capacity: rs),
                       queue: boxed(RawBuf<Int>(capacity: 64)), queueHead: boxed(0), cond: cond,
                       shutdown: atoms(1, false), collector: boxed(nil), log: boxed(YCLog()),
                       hsLatency: Samples.make(1 << 18), hsWorst: boxed((0, -1, 0)))
    }
}

let scanningBit: UInt64 = 1 << 63

@inline(__always) func nurOf(_ vm: VMRef, _ k: Int) -> UnsafeMutablePointer<Nur> { vm.pointee.yc.nur[k] }
@inline(__always) func hsOf(_ vm: VMRef, _ k: Int) -> UnsafeMutablePointer<HS> { vm.pointee.yc.hs[k] }
@inline(__always) func youngMode(_ vm: VMRef) -> Int { vm.pointee.ycConfig.mode }

// MARK: - attention word (SPEC.md "Handshakes")

@inline(__always) func stwRequested(_ vm: VMRef) -> Bool { vm.pointee.attention.load(ordering: .acquiring) & 1 != 0 }
@inline(__always) func roundsOpen(_ vm: VMRef) -> Bool { vm.pointee.attention.load(ordering: .relaxed) > 1 }

// MARK: - Y membership

/// True if `v` is a young object of nursery `k` in the part being collected.
@inline(__always)
func inY(_ vm: VMRef, _ k: Int, _ v: Oop) -> Bool {
    if v & 1 != 0 || v == 0 { return false }
    let om = vm.pointee.om
    let h = om.header(v)
    if h & youngNurseryMask != youngBit | (UInt64(k) &<< nurseryShift) { return false }
    let off = om.offsetWord(v).pointee.load(ordering: .relaxed) & ~relocBit
    let r = vm.pointee.yc.range + (k &* 4)
    return (off >= r[0].load(ordering: .relaxed) && off < r[1].load(ordering: .relaxed))
        || (off >= r[2].load(ordering: .relaxed) && off < r[3].load(ordering: .relaxed))
}

/// Append every word of `[p, p + n)` that names a Y_k object.
func scanWords(_ vm: VMRef, _ k: Int, _ p: UnsafeMutablePointer<UInt64>, _ n: Int, _ out: inout RawBuf<Oop>) {
    var i = 0
    while i < n {
        let v = atomicWord(p + i).pointee.load(ordering: .relaxed)
        if inY(vm, k, v) { out.push(v) }
        i &+= 1
    }
}

// MARK: - round work (SPEC.md "Handshakes")

/// Hand over `x`'s remembered and deletion buffers for nursery `k`.
private func publish(_ x: WorkerRef, _ k: Int, _ pubs: inout RawBuf<PubBuf>) {
    let r = x.pointee.rem + k
    if r.pointee.count > 0 {
        pubs.push(PubBuf(ptr: r.pointee.ptr, count: r.pointee.count, rem: true))
        r.pointee = RawBuf<Oop>(capacity: 64)
    }
    let d = x.pointee.del + k
    if d.pointee.count > 0 {
        pubs.push(PubBuf(ptr: d.pointee.ptr, count: d.pointee.count, rem: false))
        d.pointee = RawBuf<Oop>(capacity: 64)
    }
}

/// The worker's stack, registers and current Process's scan word for k.
private func scanOwnStack(_ vm: VMRef, _ x: WorkerRef, _ k: Int, _ out: inout RawBuf<Oop>) {
    if vm.pointee.ycConfig.stackScan {
        if x.pointee.current != 0 {
            let base = x.pointee.stack
            scanWords(vm, k, base, x.pointee.sp - base + 1, &out)
        }
        // `result` is not scanned: it is live only between a bottom-frame
        // return and the termination that consumes it, with no safepoint
        // in between; a stale one would keep a dead object alive.
        if inY(vm, k, x.pointee.current) { out.push(x.pointee.current) }
        if x.pointee.id == vm.pointee.workerCount - 1 { scanWords(vm, k, vm.pointee.hostRoots, 4, &out) }
    }
    if x.pointee.rec >= 0 {
        let w = vm.pointee.yc.recScan + (k &* maxProcesses &+ x.pointee.rec)
        w.pointee.store(vm.pointee.yc.seq[k].load(ordering: .relaxed), ordering: .releasing)
    }
}

/// One round's work for worker `x` (by `x`, or by proxy with the mutex held).
private func roundWork(_ vm: VMRef, _ x: WorkerRef, _ k: Int, _ kind: UInt8, scan: Bool,
                       _ roots: inout RawBuf<Oop>, _ pubs: inout RawBuf<PubBuf>) {
    switch kind {
    case Round.h0:
        x.pointee.del[k].count = 0
    case Round.h1:
        if scan { scanOwnStack(vm, x, k, &roots) }
        publish(x, k, &pubs)
        if x.pointee.id == k && youngMode(vm) == YoungMode.offload {
            // The owner's objects in its new eden half allocated before this
            // acknowledgement are scanned at T1 (SPEC.md "Part 2"); later
            // ones are covered by the snoop.
            retireTlab(vm, x)
            let r = vm.pointee.yc.range + (maxNurseries &* 4 &+ k &* 2)
            r[0].store(UInt64(x.pointee.nurseryStart &- vm.pointee.om.heap), ordering: .relaxed)
            r[1].store(UInt64(x.pointee.nurseryTop &- vm.pointee.om.heap), ordering: .relaxed)
        }
    default:
        publish(x, k, &pubs)
    }
}

/// Mutex held: does `w` owe a round?
func owesRound(_ vm: VMRef, _ w: WorkerRef) -> Bool {
    let id = w.pointee.id
    if w.pointee.isMarker || id >= vm.pointee.workerCount || !roundsOpen(vm) { return false }
    for k in 0..<vm.pointee.workerCount {
        let hs = hsOf(vm, k)
        if hs.pointee.active && hs.pointee.need > 0 && hs.pointee.acked[id] != hs.pointee.round { return true }
    }
    return false
}

/// At a safepoint, mutex not held: do every round `w` owes.
@inline(never)
func serviceHandshakes(_ vm: VMRef, _ w: WorkerRef) {
    let id = w.pointee.id
    if w.pointee.isMarker || id >= vm.pointee.workerCount { return }
    let t0 = now()
    var todo: (Int, UInt64, UInt8)
    var any = false
    var own = false
    // At most one round per collection at a time; take them one by one.
    while true {
        pthread_mutex_lock(vm.pointee.mutex)
        todo = (-1, 0, 0)
        for k in 0..<vm.pointee.workerCount {
            let hs = hsOf(vm, k)
            if hs.pointee.active && hs.pointee.need > 0 && hs.pointee.acked[id] != hs.pointee.round {
                todo = (k, hs.pointee.round, hs.pointee.kind)
                break
            }
        }
        pthread_mutex_unlock(vm.pointee.mutex)
        let k = todo.0
        if k < 0 { break }
        any = true
        if k == id { own = true }
        var roots = RawBuf<Oop>(capacity: 16)
        var pubs = RawBuf<PubBuf>(capacity: 4)
        roundWork(vm, w, k, todo.2, scan: true, &roots, &pubs)
        pthread_mutex_lock(vm.pointee.mutex)
        let hs = hsOf(vm, k)
        for i in 0..<roots.count { hs.pointee.roots.push(roots.ptr[i]) }
        for i in 0..<pubs.count { hs.pointee.pubs.push(pubs.ptr[i]) }
        hs.pointee.acked[id] = todo.1
        hs.pointee.need -= 1
        if hs.pointee.need == 0 {
            hs.pointee.lastAcker = id
            vm.pointee.attention.wrappingSubtract(2, ordering: .releasing)
            pthread_cond_broadcast(vm.pointee.cond)
        }
        pthread_mutex_unlock(vm.pointee.mutex)
        roots.ptr.deallocate()
        pubs.ptr.deallocate()
    }
    if any {
        advanceEpoch(vm, w)
        let dt = now() &- t0
        if own { w.pointee.ackOwnNs &+= dt; w.pointee.ackOwn &+= 1 } else { w.pointee.ackOtherNs &+= dt; w.pointee.ackOther &+= 1 }
    }
}

/// Mutex held. Wait on the safepoint condition, servicing rounds and parking
/// in a stop, while `cond()` holds.
func waitServicing(_ vm: VMRef, _ w: WorkerRef, _ cond: () -> Bool) {
    while cond() {
        if owesRound(vm, w) {
            pthread_mutex_unlock(vm.pointee.mutex)
            serviceHandshakes(vm, w)
            pthread_mutex_lock(vm.pointee.mutex)
            continue
        }
        // The collector thread: whoever we wait for may be waiting for the
        // collections queued for us (SPEC.md "Stops and collections").
        if w == vm.pointee.yc.collector.pointee && !w.pointee.ycBusy
            && vm.pointee.yc.queueHead.pointee < vm.pointee.yc.queue.pointee.count {
            drainQueueLocked(vm, w)
            continue
        }
        if stwRequested(vm) && !w.pointee.isMarker && vm.pointee.sync.pointee.inside[w.pointee.id] {
            parkLocked(vm, w)
            continue
        }
        // At a safepoint while waiting: holds no body pointer (epoch rule).
        quiesce(w)
        pthread_cond_wait(vm.pointee.cond, vm.pointee.mutex)
        advanceEpoch(vm, w)
    }
}

/// Collector: open a round of kind `kind` for nursery k and wait until every
/// participant has done it. Records its latency.
func runRound(_ vm: VMRef, _ c: WorkerRef, _ k: Int, _ kind: UInt8) {
    pthread_mutex_lock(vm.pointee.mutex)
    let hs = hsOf(vm, k)
    let t0 = now()
    hs.pointee.round &+= 1
    hs.pointee.kind = kind
    hs.pointee.openedAt = t0
    var need = 0
    let sync = vm.pointee.sync
    for i in 0..<vm.pointee.workerCount {
        let x = worker(vm, i)
        if sync.pointee.inside[i] && !sync.pointee.blocking[i] {
            need += 1
        } else {
            // Outside the VM (holds nothing) or in a blocking region: by proxy.
            var roots = RawBuf<Oop>(capacity: 16)
            var pubs = RawBuf<PubBuf>(capacity: 4)
            roundWork(vm, x, k, kind, scan: sync.pointee.blocking[i], &roots, &pubs)
            for j in 0..<roots.count { hs.pointee.roots.push(roots.ptr[j]) }
            for j in 0..<pubs.count { hs.pointee.pubs.push(pubs.ptr[j]) }
            roots.ptr.deallocate()
            pubs.ptr.deallocate()
            hs.pointee.acked[i] = hs.pointee.round
        }
    }
    hs.pointee.need = need
    hs.pointee.lastAcker = -1
    if need > 0 {
        vm.pointee.attention.wrappingAdd(2, ordering: .releasing)
        pthread_cond_broadcast(vm.pointee.cond)
        waitServicing(vm, c) { hs.pointee.need > 0 }
    }
    let dt = now() &- t0
    vm.pointee.yc.hsLatency.pointee.add(dt)
    if dt > vm.pointee.yc.hsWorst.pointee.0 { vm.pointee.yc.hsWorst.pointee = (dt, hs.pointee.lastAcker, kind) }
    pthread_mutex_unlock(vm.pointee.mutex)
}

/// Take everything stack scans and rounds handed to collection k.
private func takeHanded(_ vm: VMRef, _ k: Int, _ roots: inout RawBuf<Oop>, _ pubs: inout RawBuf<PubBuf>) {
    pthread_mutex_lock(vm.pointee.mutex)
    let hs = hsOf(vm, k)
    swap(&roots, &hs.pointee.roots)
    swap(&pubs, &hs.pointee.pubs)
    pthread_mutex_unlock(vm.pointee.mutex)
}

// MARK: - blocking regions

/// A primitive that may block without touching the heap. The worker is
/// acknowledged by proxy meanwhile; its epoch word is kept.
func blockingBegin(_ vm: VMRef, _ w: WorkerRef) {
    if !isParticipant(vm, w) { return }
    pthread_mutex_lock(vm.pointee.mutex)
    while owesRound(vm, w) {
        pthread_mutex_unlock(vm.pointee.mutex)
        serviceHandshakes(vm, w)
        pthread_mutex_lock(vm.pointee.mutex)
    }
    vm.pointee.sync.pointee.blocking[w.pointee.id] = true
    pthread_mutex_unlock(vm.pointee.mutex)
}

func blockingEnd(_ vm: VMRef, _ w: WorkerRef) {
    if !isParticipant(vm, w) { return }
    pthread_mutex_lock(vm.pointee.mutex)
    vm.pointee.sync.pointee.blocking[w.pointee.id] = false
    pthread_mutex_unlock(vm.pointee.mutex)
}

// MARK: - opening a collection (SPEC.md "Part 1" step 1, "Part 2")

/// Worker W (nursery k = its id), at a safepoint inside the VM, TLAB retired:
/// open collection k. In offload, also switch W to the other eden half.
@discardableResult
private func ycOpen(_ vm: VMRef, _ w: WorkerRef, offload: Bool) -> UInt64 {
    let k = w.pointee.id
    let yc = vm.pointee.yc
    let nur = nurOf(vm, k)
    // Give back the reserved entries: the sweep would free them.
    releaseEntriesAtomic(vm, w)
    pthread_mutex_lock(vm.pointee.mutex)
    let tw = now()
    waitServicing(vm, w) { vm.pointee.sync.pointee.stwWanted || stwRequested(vm) }
    let stwWait = now() &- tw
    w.pointee.stwWaitNs &+= stwWait
    // The collection's young log: survivors, then what W allocated.
    nur.pointee.colLogWord.count = 0
    nur.pointee.colLogBits.count = 0
    for i in 0..<nur.pointee.survLogWord.count {
        nur.pointee.colLogWord.push(nur.pointee.survLogWord.ptr[i])
        nur.pointee.colLogBits.push(nur.pointee.survLogBits.ptr[i])
    }
    nur.pointee.survLogWord.count = 0
    nur.pointee.survLogBits.count = 0
    for i in 0..<w.pointee.logWord.count {
        nur.pointee.colLogWord.push(w.pointee.logWord.ptr[i])
        nur.pointee.colLogBits.push(w.pointee.logBits.ptr[i])
    }
    w.pointee.logWord.count = 0
    w.pointee.logBits.count = 0
    nur.pointee.colChunks.count = 0
    for i in 0..<w.pointee.chunks.count { nur.pointee.colChunks.push(w.pointee.chunks.ptr[i]) }
    w.pointee.chunks.count = 0
    // Y range.
    let heap = vm.pointee.om.heap
    let r = yc.range + (k &* 4)
    r[0].store(UInt64(w.pointee.nurseryStart &- heap), ordering: .relaxed)
    r[1].store(UInt64(w.pointee.nurseryTop &- heap), ordering: .relaxed)
    let sf = nur.pointee.survStart(1 &- nur.pointee.survTo)
    r[2].store(UInt64(sf &- heap), ordering: .relaxed)
    r[3].store(UInt64(nur.pointee.survFromTop &- heap), ordering: .relaxed)
    var st = YCRecord()
    st.nursery = k
    st.offloaded = offload
    st.openAt = now()
    st.youngBytes = UInt64(w.pointee.nurseryTop &- w.pointee.nurseryStart) &+ UInt64(nur.pointee.survFromTop &- sf)
    nur.pointee.stats = st
    if offload {
        // Flip to the other half (SPEC.md "Part 2").
        w.pointee.edenHalf = 1 &- w.pointee.edenHalf
        w.pointee.nurseryStart = w.pointee.edenLo &+ UInt(w.pointee.edenHalf) &* w.pointee.edenHalfBytes
        w.pointee.nurseryEnd = w.pointee.nurseryStart &+ w.pointee.edenHalfBytes
    }
    w.pointee.nurseryTop = w.pointee.nurseryStart
    yc.seq[k].wrappingAdd(1, ordering: .relaxed)
    yc.done[k].store(false, ordering: .relaxed)
    yc.collecting[k].store(true, ordering: .releasing)
    vm.pointee.barrierWord.wrappingAdd(2, ordering: .releasing)
    vm.pointee.sync.pointee.ycActive += 1
    let hs = hsOf(vm, k)
    hs.pointee.active = true
    hs.pointee.need = 0
    hs.pointee.roots.count = 0
    hs.pointee.pubs.count = 0
    if offload {
        yc.queue.pointee.push(k)
        pthread_cond_signal(yc.cond)
    }
    pthread_mutex_unlock(vm.pointee.mutex)
    return stwWait
}

/// World running: return the reserved entries of `w`'s current word.
func releaseEntriesAtomic(_ vm: VMRef, _ w: WorkerRef) {
    let free = w.pointee.ws.entFree
    if free != 0 {
        let gw = w.pointee.ws.entWord
        atomicWord(vm.pointee.space.used + gw).pointee.bitwiseAnd(~free, ordering: .releasing)
        let n = w.pointee.logWord.count
        if n > 0 && Int(w.pointee.logWord.ptr[n - 1]) == gw { w.pointee.logBits.ptr[n - 1] &= ~free }
    }
    w.pointee.ws.entFree = 0
}

/// Part 1: W collects its own nursery (allocation slow path, flushed).
func ycLocal(_ vm: VMRef, _ w: WorkerRef) {
    let t0 = now()
    retireTlab(vm, w)
    let sw = ycOpen(vm, w, offload: false)
    let t1 = now()
    ycCollect(vm, w, w.pointee.id)
    takeRecycle(vm, w)
    // A wait for another worker's stop is counted apart (stwWaitNs).
    let dt = now() &- t0 &- sw
    w.pointee.ownPauses &+= 1
    w.pointee.ownPauseNs &+= dt
    w.pointee.ownPauseOpenNs &+= t1 &- t0 &- sw
    if dt > w.pointee.ownPauseMaxNs { w.pointee.ownPauseMaxNs = dt }
    w.pointee.pauseSamples.pointee.add(dt)
    ycTriggers(vm, w)
}

/// Part 2: W flips to the other eden half and hands the full one to the
/// collector thread. Waits first if the previous collection of its nursery
/// has not finished.
func ycFlip(_ vm: VMRef, _ w: WorkerRef) {
    let k = w.pointee.id
    let yc = vm.pointee.yc
    retireTlab(vm, w)
    if !yc.done[k].load(ordering: .acquiring) {
        let tw = now()
        pthread_mutex_lock(vm.pointee.mutex)
        waitServicing(vm, w) { !yc.done[k].load(ordering: .acquiring) }
        pthread_mutex_unlock(vm.pointee.mutex)
        let d = now() &- tw
        w.pointee.collWaits &+= 1
        w.pointee.collWaitNs &+= d
        if d > w.pointee.collWaitMaxNs { w.pointee.collWaitMaxNs = d }
    }
    takeRecycle(vm, w)
    let t0 = now()
    let sw = ycOpen(vm, w, offload: true)
    let dt = now() &- t0 &- sw
    w.pointee.ownPauses &+= 1
    w.pointee.ownPauseNs &+= dt
    if dt > w.pointee.ownPauseMaxNs { w.pointee.ownPauseMaxNs = dt }
    w.pointee.pauseSamples.pointee.add(dt)
}

/// The owner takes the chunks with free entries its last collection left.
private func takeRecycle(_ vm: VMRef, _ w: WorkerRef) {
    let nur = nurOf(vm, w.pointee.id)
    // Unconsumed recycled chunks stay; the new ones are appended.
    var j = 0
    for i in w.pointee.recycleNext..<w.pointee.recycle.count { w.pointee.recycle.ptr[j] = w.pointee.recycle.ptr[i]; j += 1 }
    w.pointee.recycle.count = j
    w.pointee.recycleNext = 0
    for i in 0..<nur.pointee.recycleOut.count { w.pointee.recycle.push(nur.pointee.recycleOut.ptr[i]) }
    nur.pointee.recycleOut.count = 0
}

// MARK: - the collection (SPEC.md "Part 1" steps 2 to 6)

/// Collector `c` (W itself, or the collector thread inside the VM) runs
/// collection k, opened by `ycOpen`.
func ycCollect(_ vm: VMRef, _ c: WorkerRef, _ k: Int, verify: Bool = true) {
    let yc = vm.pointee.yc
    let nur = nurOf(vm, k)
    let cfg = vm.pointee.ycConfig
    var st = nur.pointee.stats
    st.startAt = now()
    c.pointee.ycBusy = true // no nested collection in this collector's waits
    nur.pointee.survCur = nur.pointee.survStart(nur.pointee.survTo)
    nur.pointee.nextLogWord.count = 0
    nur.pointee.nextLogBits.count = 0
    nur.pointee.nextCarried.count = 0
    c.pointee.gcStack.count = 0
    // H0, H1.
    if let h = cfg.hook { h(cfg.hookCtx, k, 0) }
    runRound(vm, c, k, Round.h0)
    let t1 = now()
    st.h0Ns = t1 &- st.startAt
    yc.afterH1[k].store(true, ordering: .releasing)
    runRound(vm, c, k, Round.h1)
    let t2 = now()
    st.h1Ns = t2 &- t1
    if let h = cfg.hook { h(cfg.hookCtx, k, 1) }
    // T1: Process records, global roots, carried holders, handed buffers.
    var claimed = RawBuf<Int>(capacity: 64)
    var roots = RawBuf<Oop>(capacity: 256)
    claimParked(vm, k, &claimed, &roots)
    let om = vm.pointee.om
    let s = yc.seq[k].load(ordering: .relaxed)
    for i in 0..<claimed.count {
        let ri = claimed.ptr[i]
        let rec = vm.pointee.recs + ri
        let p = rec.pointee.process
        let base = rec.pointee.base.unsafelyUnwrapped
        let sp = untagPtr(om.slot(p, pSp), UInt64.self)
        scanWords(vm, k, base, sp - base + 1, &roots)
        (yc.recScan + (k &* maxProcesses &+ ri)).pointee.store(s, ordering: .releasing)
    }
    st.procScans &+= UInt64(claimed.count)
    claimed.ptr.deallocate()
    globalRoots(vm, k, &roots)
    for i in 0..<roots.count { visit(vm, c, nur, k, roots.ptr[i], &st) }
    if youngMode(vm) == YoungMode.offload && cfg.newHalfScan { scanNewHalf(vm, c, nur, k, &st) }
    roots.count = 0
    if cfg.carryRem {
        let carried = nur.pointee.carried
        nur.pointee.carried = RawBuf<Oop>(capacity: 64)
        for i in 0..<carried.count { scanHolder(vm, c, nur, k, carried.ptr[i], &st) }
        carried.ptr.deallocate()
    } else {
        // Test switch: forget the holders kept by the last collection.
        for i in 0..<nur.pointee.carried.count {
            vm.pointee.space.rem[Int(truncatingIfNeeded: nur.pointee.carried.ptr[i] &>> 4)]
                .bitwiseAnd(~UInt32(1 << k), ordering: .relaxed)
        }
        nur.pointee.carried.count = 0
    }
    var pubs = RawBuf<PubBuf>(capacity: 64)
    processHanded(vm, c, nur, k, &roots, &pubs, &st)
    drain(vm, c, nur, k, &st)
    let t3 = now()
    st.t1Ns = t3 &- t2
    st.rounds = 1
    // Drain rounds until one copies nothing.
    while cfg.secondHandshake {
        let before = st.copiedObjects
        let td = now()
        runRound(vm, c, k, Round.drain)
        st.drainRoundsNs &+= now() &- td
        st.rounds += 1
        processHanded(vm, c, nur, k, &roots, &pubs, &st)
        drain(vm, c, nur, k, &st)
        if st.copiedObjects == before { break }
    }
    roots.ptr.deallocate()
    pubs.ptr.deallocate()
    let t4 = now()
    st.traceNs = t4 &- t2
    // Finish: barrier off.
    pthread_mutex_lock(vm.pointee.mutex)
    yc.collecting[k].store(false, ordering: .releasing)
    yc.afterH1[k].store(false, ordering: .relaxed)
    yc.afterT1[k].store(false, ordering: .relaxed)
    vm.pointee.barrierWord.wrappingSubtract(2, ordering: .releasing)
    let hs = hsOf(vm, k)
    hs.pointee.active = false
    for i in 0..<hs.pointee.pubs.count { hs.pointee.pubs.ptr[i].ptr.deallocate() }
    hs.pointee.pubs.count = 0
    hs.pointee.roots.count = 0
    pthread_mutex_unlock(vm.pointee.mutex)
    // Carried set, entry sweep, survivor flip, recycle list.
    foldCarried(vm, nur, k)
    sweepCollection(vm, nur, k, &st)
    swap(&nur.pointee.survLogWord, &nur.pointee.nextLogWord)
    swap(&nur.pointee.survLogBits, &nur.pointee.nextLogBits)
    nur.pointee.nextLogWord.count = 0
    nur.pointee.nextLogBits.count = 0
    nur.pointee.survFromTop = nur.pointee.survCur
    nur.pointee.survTo = 1 &- nur.pointee.survTo
    for i in 0..<nur.pointee.nextCarried.count { nur.pointee.carried.push(nur.pointee.nextCarried.ptr[i]) }
    st.carried = UInt64(nur.pointee.carried.count)
    nur.pointee.nextCarried.count = 0
    let t5 = now()
    st.sweepNs = t5 &- t4
    // Epoch rule (SPEC.md step 6).
    let s2 = vm.pointee.cm.epoch.pointee.wrappingAdd(1, ordering: .sequentiallyConsistent).oldValue
    if cfg.epochRule { epochWait(vm, c, s2) }
    // A dead holder that another collection re-armed meanwhile (pending or
    // membership bits) waits for this nursery's next collection.
    var kept = 0
    for i in 0..<nur.pointee.deferred.count {
        let o = nur.pointee.deferred.ptr[i]
        let idx = Int(truncatingIfNeeded: o &>> 4)
        let rw = vm.pointee.space.rem[idx].exchange(0, ordering: .sequentiallyConsistent) // DIAG
        if rw != 0 {
            diag(DiagEv.deferKept, k, UInt64(idx), UInt64(rw)) // DIAG
            nur.pointee.deferred.ptr[kept] = o
            kept += 1
            continue
        }
        diag(DiagEv.deferFree, k, UInt64(idx), UInt64(k)) // DIAG
        atomicWord(vm.pointee.space.used + (idx &>> 6)).pointee.bitwiseAnd(~(UInt64(1) &<< UInt64(idx & 63)), ordering: .releasing)
    }
    st.deferredFrees = UInt64(nur.pointee.deferred.count - kept)
    nur.pointee.deferred.count = kept
    let t6 = now()
    st.epochWaitNs = t6 &- t5
    st.totalNs = t6 &- st.startAt
    c.pointee.ycBusy = false
    pthread_mutex_lock(vm.pointee.mutex)
    vm.pointee.sync.pointee.ycActive -= 1
    yc.done[k].store(true, ordering: .releasing)
    let log = yc.log
    if log.pointee.count < 1 << 18 { log.pointee.recs[log.pointee.count] = st; log.pointee.count += 1 }
    pthread_cond_broadcast(vm.pointee.cond)
    pthread_mutex_unlock(vm.pointee.mutex)
    vm.add(.ycCollections, 1)
    vm.add(.promotedBytes, st.promotedBytes)
    vm.add(.survivedBytes, st.survivedBytes)
    vm.add(.overflowBytes, st.overflowBytes)
    vm.add(.youngBytes, st.youngBytes)
    vm.add(.entriesFreed, st.entriesFreed)
    if cfg.verifyYoung && verify && vm.metric(.ycCollections) % UInt64(max(cfg.verifyEvery, 1)) == 0 {
        // A forced pause after the collection (SPEC.md "Young verifier").
        stopWorld(vm, c, .verify, retry: true)
    }
}

/// Wait until every participant's epoch word passed `s`.
private func epochWait(_ vm: VMRef, _ c: WorkerRef, _ s: UInt64) {
    if !c.pointee.isMarker { advanceEpoch(vm, c) }
    var spins = 0
    while true {
        var m = quiescent
        for i in 0..<vm.pointee.workerCount { m = min(m, worker(vm, i).pointee.hz[hzEpoch].load(ordering: .acquiring)) }
        if m > s { return }
        if !c.pointee.isMarker {
            // Waiting holds no body pointer: keep this worker's epoch current,
            // or two collectors waiting for each other's epochs stall until
            // some round opens.
            if roundsOpen(vm) { serviceHandshakes(vm, c) }
            advanceEpoch(vm, c)
        }
        spins &+= 1
        if spins & 15 == 0 { usleep(20) } else { sched_yield() }
    }
}

/// Under `schedLock`: from now on new Processes count as scanned; claim every
/// parked unscanned Process record; collect every live Process oop.
private func claimParked(_ vm: VMRef, _ k: Int, _ claimed: inout RawBuf<Int>, _ roots: inout RawBuf<Oop>) {
    let yc = vm.pointee.yc
    let s = yc.seq[k].load(ordering: .relaxed)
    schedLock(vm)
    yc.afterT1[k].store(true, ordering: .relaxed)
    for i in 0..<vm.pointee.sched.pointee.recHwm {
        let rec = vm.pointee.recs + i
        let p = rec.pointee.process
        if p == 0 { continue }
        if inY(vm, k, p) { roots.push(p) }
        if rec.pointee.runningOn >= 0 { continue }
        let w = yc.recScan + (k &* maxProcesses &+ i)
        let cur = w.pointee.load(ordering: .acquiring)
        if cur == s || cur == s | scanningBit { continue }
        if w.pointee.compareExchange(expected: cur, desired: s | scanningBit, ordering: .acquiringAndReleasing).exchanged {
            claimed.push(i)
        }
    }
    // Ready queues (they name live Processes only, all in records; scanned
    // for completeness under the lock that guards them).
    for i in 0..<(4 * priorities) where inY(vm, k, vm.pointee.ready[i]) { roots.push(vm.pointee.ready[i]) }
    schedUnlock(vm)
}

/// Globals (atomic words), special objects, class table, image roots,
/// pending Semaphores.
private func globalRoots(_ vm: VMRef, _ k: Int, _ roots: inout RawBuf<Oop>) {
    scanWords(vm, k, vm.pointee.globals, globalCount, &roots)
    scanWords(vm, k, vm.pointee.special, 9, &roots)
    scanWords(vm, k, vm.pointee.classTable + 1, max(0, vm.pointee.classCount - 1), &roots)
    scanWords(vm, k, vm.pointee.roots.ptr, vm.pointee.roots.count, &roots)
    pthread_mutex_lock(vm.pointee.pendingLock)
    scanWords(vm, k, vm.pointee.pending, vm.pointee.pend.pointee.hwm, &roots)
    pthread_mutex_unlock(vm.pointee.pendingLock)
}

/// Process everything handed to collection k so far: stack roots, published
/// remembered (holders) and deletion buffers.
private func processHanded(_ vm: VMRef, _ c: WorkerRef, _ nur: UnsafeMutablePointer<Nur>, _ k: Int,
                           _ roots: inout RawBuf<Oop>, _ pubs: inout RawBuf<PubBuf>, _ st: inout YCRecord) {
    roots.count = 0
    pubs.count = 0
    takeHanded(vm, k, &roots, &pubs)
    st.stackRoots &+= UInt64(roots.count)
    for i in 0..<roots.count { visit(vm, c, nur, k, roots.ptr[i], &st) }
    for i in 0..<pubs.count {
        let b = pubs.ptr[i]
        if !c.pointee.isMarker {
            advanceEpoch(vm, c)
            if roundsOpen(vm) { serviceHandshakes(vm, c) }
        }
        if b.rem {
            for j in 0..<b.count { scanHolder(vm, c, nur, k, b.ptr[j], &st) }
        } else {
            st.delRecords &+= UInt64(b.count)
            for j in 0..<b.count { visit(vm, c, nur, k, b.ptr[j], &st) }
        }
        b.ptr.deallocate()
    }
    roots.count = 0
    pubs.count = 0
}

/// Offload: every body the owner allocated in its new eden half before its
/// H1 acknowledgement, as roots.
private func scanNewHalf(_ vm: VMRef, _ c: WorkerRef, _ nur: UnsafeMutablePointer<Nur>, _ k: Int, _ st: inout YCRecord) {
    let om = vm.pointee.om
    let r = vm.pointee.yc.range + (maxNurseries &* 4 &+ k &* 2)
    var a = om.heap &+ UInt(r[0].load(ordering: .relaxed))
    let hi = om.heap &+ UInt(r[1].load(ordering: .relaxed))
    while a < hi {
        let br = atomicWord(wordPtr(a)).pointee.load(ordering: .relaxed)
        let size = Int(truncatingIfNeeded: br &>> 32) &* 8
        if size == 0 { break }
        let o = (br & 0xFFFF_FFFF) &<< 4
        if om.offsetWord(o).pointee.load(ordering: .relaxed) == UInt64(a &- om.heap) {
            let h = om.header(o)
            if !hdrIsBytes(h) {
                let n = hdrSlots(h)
                var j = 0
                while j < n {
                    _ = classify(vm, c, nur, k, atomicWord(wordPtr(a) + (1 &+ j)).pointee.load(ordering: .relaxed), &st)
                    j &+= 1
                }
                st.newHalfWords &+= UInt64(n)
            }
        }
        a &+= UInt(size)
    }
}

/// Classify `v` for collection k, evacuating it if it is in Y_k and not yet
/// copied: 0 not young after this collection, 1 young in nursery k, 2 + j
/// young in another nursery j.
@inline(__always)
private func classify(_ vm: VMRef, _ c: WorkerRef, _ nur: UnsafeMutablePointer<Nur>, _ k: Int, _ v: Oop,
                      _ st: inout YCRecord) -> Int {
    if v & 1 != 0 || v == 0 { return 0 }
    let om = vm.pointee.om
    let h = atomicHeader(om.entry(v)).pointee.load(ordering: .acquiring)
    if h & youngBit == 0 { return 0 }
    let j = hdrNursery(h)
    if j != k { return 2 &+ j }
    let idx = Int(truncatingIfNeeded: v &>> 4)
    if vm.pointee.space.surv[idx &>> 6].load(ordering: .relaxed) & (UInt64(1) &<< UInt64(idx & 63)) != 0 { return 1 }
    if !inY(vm, k, v) { return 1 }
    return evacuate(vm, c, nur, k, v, h, &st) ? 1 : 0
}

@inline(__always)
private func visit(_ vm: VMRef, _ c: WorkerRef, _ nur: UnsafeMutablePointer<Nur>, _ k: Int, _ v: Oop, _ st: inout YCRecord) {
    _ = classify(vm, c, nur, k, v, &st)
}

/// A remembered holder of nursery k (SPEC.md step 3): clear bit k first
/// (seq_cst), scan, re-arm if it still names a young object of k.
private func scanHolder(_ vm: VMRef, _ c: WorkerRef, _ nur: UnsafeMutablePointer<Nur>, _ k: Int, _ hld: Oop, _ st: inout YCRecord) {
    let bit = UInt32(1) &<< UInt32(k)
    let r = vm.pointee.space.rem + Int(truncatingIfNeeded: hld &>> 4)
    let old = r.pointee.bitwiseAnd(~bit, ordering: .sequentiallyConsistent).oldValue
    if old & bit == 0 { return }
    atomicMemoryFence(ordering: .sequentiallyConsistent)
    st.holders &+= 1
    let om = vm.pointee.om
    let h = om.header(hld)
    if hdrIsBytes(h) { return }
    if inY(vm, k, hld) { return } // traced if reachable
    let n = hdrSlots(h)
    var namesK = false
    var i = 0
    while i < n {
        if classify(vm, c, nur, k, om.slotLoad(hld, i), &st) == 1 { namesK = true }
        i &+= 1
    }
    if namesK { keepForNext(nur, r, hld, k) }
}

/// A holder stays in nursery k's set: during the pass only its pending bit
/// (16 + k) is set, so a second copy of it in the lists still finds its
/// membership bit clear and is skipped; the end of the collection folds
/// pending into membership (`foldCarried`).
@inline(__always)
private func keepForNext(_ nur: UnsafeMutablePointer<Nur>, _ r: UnsafeMutablePointer<Atomic<UInt32>>, _ o: Oop, _ k: Int) {
    let pend = UInt32(1) &<< UInt32(16 &+ k)
    if r.pointee.bitwiseOr(pend, ordering: .sequentiallyConsistent).oldValue & pend == 0 { nur.pointee.nextCarried.push(o) }
}

private func foldCarried(_ vm: VMRef, _ nur: UnsafeMutablePointer<Nur>, _ k: Int) {
    let bit = UInt32(1) &<< UInt32(k), pend = UInt32(1) &<< UInt32(16 &+ k)
    for i in 0..<nur.pointee.nextCarried.count {
        let r = vm.pointee.space.rem + Int(truncatingIfNeeded: nur.pointee.nextCarried.ptr[i] &>> 4)
        r.pointee.bitwiseOr(bit, ordering: .sequentiallyConsistent)
        r.pointee.bitwiseAnd(~pend, ordering: .relaxed)
    }
}

/// Holder `o` (just copied by a collector) names a young object of nursery
/// j: remember it for j, as the insertion barrier would.
private func rememberFor(_ vm: VMRef, _ c: WorkerRef, _ o: Oop, _ j: Int, _ st: inout YCRecord) {
    let bit = UInt32(1) &<< UInt32(j)
    let r = vm.pointee.space.rem + Int(truncatingIfNeeded: o &>> 4)
    if r.pointee.load(ordering: .sequentiallyConsistent) & bit != 0 { return }
    if r.pointee.bitwiseOr(bit, ordering: .sequentiallyConsistent).oldValue & bit != 0 { return }
    st.crossRemembered &+= 1
    if c.pointee.isMarker {
        nurOf(vm, j).pointee.carried.push(o) // the collector thread owns every Nur
    } else {
        c.pointee.rem[j].push(o)
    }
}

/// Claim, decide, copy with the relocation protocol (SPEC.md step 3).
@inline(never)
private func evacuate(_ vm: VMRef, _ c: WorkerRef, _ nur: UnsafeMutablePointer<Nur>, _ k: Int, _ v: Oop, _ h0: UInt64,
                      _ st: inout YCRecord) -> Bool {
    let om = vm.pointee.om
    let size = objectBytes(h0)
    let age = hdrAge(h0) &+ 1
    let ageN = vm.pointee.cmConfig.ageN
    let toEnd = nur.pointee.survStart(nur.pointee.survTo) &+ nur.pointee.survBytes
    let survive = age < ageN && nur.pointee.survCur &+ UInt(size) <= toEnd
    let overflow = age < ageN && !survive
    let dst: UInt
    let nh: UInt64
    if survive {
        dst = nur.pointee.survCur
        nur.pointee.survCur = dst &+ UInt(size)
        nh = (h0 & ~(ageMask | claimMask)) | (UInt64(age) &<< ageShift)
    } else {
        if c.pointee.promo.end &- c.pointee.promo.cur < UInt(size) {
            if !vm.pointee.heap.refill(&c.pointee.promo, soft: false) { fatal("promotion failed: old space and reserve exhausted") }
        }
        dst = c.pointee.promo.cur
        c.pointee.promo.cur = dst &+ UInt(size)
        nh = h0 & ~(youngNurseryMask | ageMask | claimMask)
    }
    // The decision is in the header before the offset word says RELOCATING
    // (SPEC.md "Ordering and soundness" 5).
    atomicHeader(om.entry(v)).pointee.store(nh, ordering: .releasing)
    let idx = Int(truncatingIfNeeded: v &>> 4)
    let bit = UInt64(1) &<< UInt64(idx & 63)
    vm.pointee.space.surv[idx &>> 6].bitwiseOr(bit, ordering: .relaxed)
    let ow = om.offsetWord(v)
    var off = ow.pointee.load(ordering: .relaxed)
    while true {
        let (ok, cur) = ow.pointee.compareExchange(expected: off, desired: off | relocBit, ordering: .sequentiallyConsistent)
        if !ok { off = cur & ~relocBit; continue }
        atomicMemoryFence(ordering: .sequentiallyConsistent)
        if vm.pointee.cmConfig.hazardRule && vm.pointee.hazardsHeld.load(ordering: .sequentiallyConsistent) != 0 && hazarded(vm, v) {
            // A primitive holds the body: revert, wait until it lets go, retry.
            ow.pointee.store(off, ordering: .releasing)
            st.hazardRetries &+= 1
            var spins = 0
            while hazarded(vm, v) {
                spins &+= 1
                if spins & 63 == 0 { sched_yield() }
            }
            continue
        }
        break
    }
    let src = wordPtr(om.heap &+ UInt(truncatingIfNeeded: off))
    let d = wordPtr(dst)
    let n = size &>> 3
    var i = 0
    while i < n {
        atomicWord(d + i).pointee.store(atomicWord(src + i).pointee.load(ordering: .relaxed), ordering: .relaxed)
        i &+= 1
    }
    ow.pointee.store(UInt64(dst &- om.heap), ordering: .releasing)
    st.copiedObjects &+= 1
    if survive {
        st.survivedBytes &+= UInt64(size)
        nur.pointee.nextLogWord.push(UInt32(truncatingIfNeeded: idx &>> 6))
        nur.pointee.nextLogBits.push(bit)
    } else {
        st.promotedBytes &+= UInt64(size)
        if overflow { st.overflowBytes &+= UInt64(size) }
    }
    if !hdrIsBytes(h0) { c.pointee.gcStack.push(v) }
    return survive
}

/// Scan copied objects' new bodies until the stack is empty.
private func drain(_ vm: VMRef, _ c: WorkerRef, _ nur: UnsafeMutablePointer<Nur>, _ k: Int, _ st: inout YCRecord) {
    let om = vm.pointee.om
    var count = 0
    while let o = c.pointee.gcStack.pop() {
        let h = atomicHeader(om.entry(o)).pointee.load(ordering: .relaxed)
        let promoted = h & youngBit == 0
        let n = hdrSlots(h)
        var namesK = false
        var i = 0
        while i < n {
            let r = classify(vm, c, nur, k, om.slotLoad(o, i), &st)
            if r == 1 { namesK = true } else if r >= 2 { rememberFor(vm, c, o, r &- 2, &st) }
            i &+= 1
        }
        if namesK && promoted { keepForNext(nur, vm.pointee.space.rem + Int(truncatingIfNeeded: o &>> 4), o, k) }
        count &+= 1
        if count & 255 == 0 && !c.pointee.isMarker {
            // Between objects the collector holds no body pointer: other
            // collections' epoch waits must not wait for this loop.
            advanceEpoch(vm, c)
            if roundsOpen(vm) { serviceHandshakes(vm, c) }
        }
    }
}

/// Entry sweep of the collection's young log (per bit, as ADR 0007). Dead
/// entries that are remembered holders are freed after the epoch.
private func sweepCollection(_ vm: VMRef, _ nur: UnsafeMutablePointer<Nur>, _ k: Int, _ st: inout YCRecord) {
    let sp = vm.pointee.space
    var freed: UInt64 = 0
    for i in 0..<nur.pointee.colLogWord.count {
        let gw = Int(nur.pointee.colLogWord.ptr[i])
        let bits = nur.pointee.colLogBits.ptr[i]
        let alive = sp.surv[gw].bitwiseAnd(~bits, ordering: .relaxed).oldValue & bits
        var dead = bits & ~alive
        var d = dead
        while d != 0 {
            let b = d.trailingZeroBitCount
            d &= d &- 1
            let idx = gw &* 64 &+ b
            if sp.rem[idx].load(ordering: .relaxed) != 0 {
                // A dead remembered holder: stale lists may still name it, and
                // another collection may re-arm it before it is freed. With a
                // slot count of 0 a later scan of it reads no body (its old
                // body is reused once the epoch passes).
                let ent = atomicHeader(vm.pointee.om.entry(UInt64(idx) &<< 4))
                ent.pointee.store(ent.pointee.load(ordering: .relaxed) & ~(slotsMask &<< slotsShift), ordering: .releasing)
                sp.rem[idx].store(0, ordering: .sequentiallyConsistent)
                nur.pointee.deferred.push(UInt64(idx) &<< 4)
                diag(DiagEv.deferPush, k, UInt64(idx), UInt64(k)) // DIAG
                dead &= ~(UInt64(1) &<< UInt64(b))
            }
        }
        if dead != 0 && cmPhase(vm) == CMPhase.marking && gw < vm.pointee.cm.snapWords.pointee && vm.pointee.cm.snap[gw] & dead != 0 { // DIAG
            var d2 = vm.pointee.cm.snap[gw] & dead
            while d2 != 0 { let b = d2.trailingZeroBitCount; d2 &= d2 &- 1; diag(DiagEv.ycFreeSnap, k, UInt64(gw &* 64 &+ b), UInt64(k)) }
        }
        if dead != 0 { atomicWord(sp.used + gw).pointee.bitwiseAnd(~dead, ordering: .releasing) }
        freed &+= UInt64(dead.nonzeroBitCount)
    }
    st.entriesFreed = freed
    nur.pointee.colLogWord.count = 0
    nur.pointee.colLogBits.count = 0
    nur.pointee.recycleOut.count = 0
    for i in 0..<nur.pointee.colChunks.count {
        let c = Int(nur.pointee.colChunks.ptr[i])
        for j in 0..<wordsPerChunk where atomicWord(sp.used + (c &* wordsPerChunk &+ j)).pointee.load(ordering: .relaxed) != ~0 {
            nur.pointee.recycleOut.push(UInt32(c))
            break
        }
    }
    nur.pointee.colChunks.count = 0
}

// MARK: - resume check (SPEC.md "Processes")

/// Before running Process record `ri` (stack parked): scan it for every
/// collection past its H1 start that has not scanned it.
@inline(never)
func ycResumeCheck(_ vm: VMRef, _ w: WorkerRef, _ ri: Int) {
    let yc = vm.pointee.yc
    let om = vm.pointee.om
    for k in 0..<vm.pointee.workerCount {
        if !yc.collecting[k].load(ordering: .acquiring) || !yc.afterH1[k].load(ordering: .acquiring) { continue }
        let s = yc.seq[k].load(ordering: .relaxed)
        let word = yc.recScan + (k &* maxProcesses &+ ri)
        while true {
            let cur = word.pointee.load(ordering: .acquiring)
            if cur == s { break }
            if cur == s | scanningBit { sched_yield(); continue }
            if word.pointee.compareExchange(expected: cur, desired: s | scanningBit, ordering: .acquiringAndReleasing).exchanged {
                var roots = RawBuf<Oop>(capacity: 16)
                let rec = vm.pointee.recs + ri
                let base = rec.pointee.base.unsafelyUnwrapped
                let sp = untagPtr(om.slot(rec.pointee.process, pSp), UInt64.self)
                if vm.pointee.ycConfig.stackScan { scanWords(vm, k, base, sp - base + 1, &roots) }
                pthread_mutex_lock(vm.pointee.mutex)
                let hs = hsOf(vm, k)
                for i in 0..<roots.count { hs.pointee.roots.push(roots.ptr[i]) }
                pthread_mutex_unlock(vm.pointee.mutex)
                roots.ptr.deallocate()
                word.pointee.store(s, ordering: .releasing)
                w.pointee.resumeScans &+= 1
                break
            }
        }
    }
}

/// Under `schedLock`, a new Process record: scanned for k iff k is past T1.
func ycNewRecord(_ vm: VMRef, _ ri: Int) {
    let yc = vm.pointee.yc
    for k in 0..<maxNurseries {
        let v: UInt64 = yc.afterT1[k].load(ordering: .relaxed) ? yc.seq[k].load(ordering: .relaxed) : 0
        (yc.recScan + (k &* maxProcesses &+ ri)).pointee.store(v, ordering: .relaxed)
    }
}

// MARK: - deletion records outside slots

/// A root word (a global) is overwritten while collections run.
@inline(never)
func recordDeletedRoot(_ vm: VMRef, _ w: WorkerRef, _ old: Oop) {
    #if !NO_YOUNG_BARRIER
    if !vm.pointee.ycConfig.youngDeletion || old & 1 != 0 || old == 0 { return }
    let h = vm.pointee.om.header(old)
    if h & youngBit == 0 { return }
    let n = hdrNursery(h)
    if vm.pointee.yc.collecting[n].load(ordering: .acquiring) {
        w.pointee.del[n].push(old)
        w.pointee.delPushed &+= 1
    }
    #endif
}

// MARK: - triggers (SPEC.md step 7)

/// After a collection, inside the VM at a safepoint: fall back, or start a
/// marking cycle with the initial-mark pause.
func ycTriggers(_ vm: VMRef, _ w: WorkerRef) {
    let heap = vm.pointee.heap
    let cfg = vm.pointee.cmConfig
    let inUse = heap.blocksInUse()
    let soft = heap.softBlocks
    if inUse > soft {
        stopWorld(vm, w, .full, retry: false)
        return
    }
    if cfg.concurrent && cmPhase(vm) == CMPhase.idle
        && (cfg.force || Double(inUse) >= cfg.threshold * Double(soft)) {
        stopWorld(vm, w, .initialMark, retry: false)
    }
}

// MARK: - the collector thread (Part 2)

private struct YCCtx {
    var vm: VMRef
    var c: WorkerRef
}

private func collectorMain(_ arg: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
    let ctx = arg.assumingMemoryBound(to: YCCtx.self)
    collectorLoop(ctx.pointee.vm, ctx.pointee.c)
    return nil
}

func startCollector(_ vm: VMRef) -> pthread_t {
    let c = Worker.create(id: 2000, nilObj: vm.pointee.nilObj, marker: true)
    c.pointee.vm = UnsafeMutableRawPointer(vm)
    vm.pointee.yc.collector.pointee = c
    let ctx = UnsafeMutablePointer<YCCtx>.allocate(capacity: 1)
    ctx.initialize(to: YCCtx(vm: vm, c: c))
    var attr = pthread_attr_t()
    pthread_attr_init(&attr)
    pthread_attr_set_qos_class_np(&attr, vm.pointee.ycConfig.collectorQoS, 0)
    var tid: pthread_t? = nil
    if pthread_create(&tid, &attr, collectorMain, UnsafeMutableRawPointer(ctx)) != 0 { fatal("pthread_create collector") }
    pthread_attr_destroy(&attr)
    return tid!
}

func stopCollector(_ vm: VMRef, _ t: pthread_t) {
    pthread_mutex_lock(vm.pointee.mutex)
    vm.pointee.yc.shutdown.pointee.store(true, ordering: .relaxed)
    pthread_cond_broadcast(vm.pointee.yc.cond)
    pthread_mutex_unlock(vm.pointee.mutex)
    pthread_join(t, nil)
}

/// Mutex held, collector thread inside the VM, a stop wanted: run every
/// queued collection (a stop waits for opened collections, and only this
/// thread runs them).
func drainQueueLocked(_ vm: VMRef, _ c: WorkerRef) {
    let yc = vm.pointee.yc
    while yc.queueHead.pointee < yc.queue.pointee.count {
        let k = yc.queue.pointee.ptr[yc.queueHead.pointee]
        yc.queueHead.pointee += 1
        if yc.queueHead.pointee == yc.queue.pointee.count { yc.queueHead.pointee = 0; yc.queue.pointee.count = 0 }
        pthread_mutex_unlock(vm.pointee.mutex)
        let cpu0 = threadCpuNs()
        ycCollect(vm, c, k, verify: false)
        c.pointee.collectorCpuNs &+= threadCpuNs() &- cpu0
        pthread_mutex_lock(vm.pointee.mutex)
    }
}

private func collectorLoop(_ vm: VMRef, _ c: WorkerRef) {
    let yc = vm.pointee.yc
    while true {
        pthread_mutex_lock(vm.pointee.mutex)
        while yc.queueHead.pointee == yc.queue.pointee.count && !yc.shutdown.pointee.load(ordering: .relaxed) {
            pthread_cond_wait(yc.cond, vm.pointee.mutex)
        }
        if yc.queueHead.pointee == yc.queue.pointee.count {
            pthread_mutex_unlock(vm.pointee.mutex)
            break
        }
        let k = yc.queue.pointee.ptr[yc.queueHead.pointee]
        yc.queueHead.pointee += 1
        if yc.queueHead.pointee == yc.queue.pointee.count { yc.queueHead.pointee = 0; yc.queue.pointee.count = 0 }
        pthread_mutex_unlock(vm.pointee.mutex)
        enterVM(vm, c)
        let cpu0 = threadCpuNs()
        ycCollect(vm, c, k)
        c.pointee.collectorCpuNs &+= threadCpuNs() &- cpu0
        ycTriggers(vm, c)
        leaveVM(vm, c)
    }
}

// MARK: - Part 3: young-root scan at the initial mark (world stopped)

/// Grey every unmarked snapshot entry named by a body in an active eden or
/// survivor-from. Answers words scanned.
func youngRootScan(_ vm: VMRef, _ ds: UnsafeMutablePointer<WordStack>) -> Int {
    let cm = vm.pointee.cm
    let om = vm.pointee.om
    var words = 0
    func walk(_ lo: UInt, _ hi: UInt) {
        var a = lo
        while a < hi {
            let br = wordPtr(a).pointee
            let size = Int(truncatingIfNeeded: br &>> 32) &* 8
            if size == 0 { break }
            let o = (br & 0xFFFF_FFFF) &<< 4
            if om.offsetWord(o).pointee.load(ordering: .relaxed) == UInt64(a &- om.heap) {
                let h = om.header(o)
                if !hdrIsBytes(h) {
                    let n = hdrSlots(h)
                    words &+= n
                    let s = wordPtr(a) + 1
                    var j = 0
                    while j < n {
                        let v = s[j]
                        if v & 1 == 0 && v != 0 && cm.inSnap(v) && cm.tryMark(v) { ds.pointee.push(v) }
                        j &+= 1
                    }
                }
            }
            a &+= UInt(size)
        }
    }
    for i in 0..<vm.pointee.workerCount {
        let x = worker(vm, i)
        if x.pointee.youngMark == 0 { continue }
        walk(x.pointee.nurseryStart, x.pointee.nurseryTop)
        let nur = nurOf(vm, i)
        walk(nur.pointee.survStart(1 &- nur.pointee.survTo), nur.pointee.survFromTop)
    }
    return words
}

// MARK: - young verifier (SPEC.md "Young verifier"), world stopped

func youngVerify(_ vm: VMRef) {
    vm.add(.youngVerifyRuns, 1)
    let om = vm.pointee.om
    let heap = vm.pointee.heap
    let sp = vm.pointee.space
    func failure(_ msg: String) {
        let n = vm.metric(.verifyFailures)
        vm.add(.verifyFailures, 1)
        if n < 10 { FileHandleStderr.write("verify young: \(msg)\n") }
    }
    let words = chunkHwmNow(vm) * wordsPerChunk
    var seen = [UInt64](repeating: 0, count: max(words, 1))
    var stack: [Oop] = []
    func visit(_ v: Oop) {
        if v & 1 != 0 || v == 0 { return }
        let idx = Int(truncatingIfNeeded: v &>> 4)
        if idx >= words * 64 { failure("oop \(v) beyond the table"); return }
        let bit = UInt64(1) &<< UInt64(idx & 63)
        if seen[idx >> 6] & bit != 0 { return }
        seen[idx >> 6] |= bit
        stack.append(v)
    }
    for (p, c) in rootRanges(vm) {
        for i in 0..<c { visit(p[i]) }
        while let o = stack.popLast() {
            let idx = Int(truncatingIfNeeded: o &>> 4)
            if sp.used[idx >> 6] & (UInt64(1) << UInt64(idx & 63)) == 0 { failure("reachable entry \(idx) is free"); continue }
            let h = om.header(o)
            let off = om.offsetWord(o).pointee.load(ordering: .relaxed)
            if off & relocBit != 0 { failure("entry \(idx) RELOCATING at a pause") }
            let addr = om.heap &+ UInt(off & ~relocBit)
            if hdrYoung(h) {
                let n = hdrNursery(h)
                if n >= vm.pointee.workerCount { failure("young entry \(idx) nursery \(n)"); continue }
                let x = worker(vm, n)
                let nur = nurOf(vm, n)
                let inEden = addr >= x.pointee.nurseryStart && addr < x.pointee.nurseryTop
                let sf = nur.pointee.survStart(1 &- nur.pointee.survTo)
                let inSurv = addr >= sf && addr < nur.pointee.survFromTop
                if !inEden && !inSurv { failure("young entry \(idx) (nursery \(n)) body outside its active eden and survivor-from") }
            } else if heap.inNurseries(addr) {
                failure("old entry \(idx) body in a nursery")
            }
            if hdrIsBytes(h) { continue }
            for i in 0..<hdrSlots(h) { visit(om.slot(o, i)) }
        }
    }
}

// MARK: - host and test API

/// Collect worker `w`'s nursery now from the calling thread, which acts as
/// `w` (it must have no thread of its own and no Process). local: the
/// collection runs here; offload: flip, then wait until the collector is done.
public func ycCollectNow(_ vm: VMRef, _ w: WorkerRef) {
    enterVM(vm, w)
    if youngMode(vm) == YoungMode.offload {
        ycFlip(vm, w)
        pthread_mutex_lock(vm.pointee.mutex)
        waitServicing(vm, w) { !vm.pointee.yc.done[w.pointee.id].load(ordering: .acquiring) }
        pthread_mutex_unlock(vm.pointee.mutex)
    } else {
        ycLocal(vm, w)
    }
    leaveVM(vm, w)
}

/// Is entry `o` in use (tests)?
public func entryUsed(_ vm: VMRef, _ o: Oop) -> Bool {
    let i = Int(truncatingIfNeeded: o &>> 4)
    return atomicWord(vm.pointee.space.used + (i &>> 6)).pointee.load(ordering: .relaxed) & (UInt64(1) &<< UInt64(i & 63)) != 0
}

/// Entries whose free waits for an epoch (dead remembered young holders):
/// dead, still marked used, their bodies may be reused (verifiers skip them).
func deferredDead(_ vm: VMRef) -> Set<Int> {
    var d = Set<Int>()
    for k in 0..<vm.pointee.workerCount {
        let nur = nurOf(vm, k)
        for i in 0..<nur.pointee.deferred.count { d.insert(Int(truncatingIfNeeded: nur.pointee.deferred.ptr[i] &>> 4)) }
    }
    return d
}

/// Offload, tests: the calling thread acts as `w` and flips (hands its eden
/// half to the collector) without waiting.
public func ycFlipNow(_ vm: VMRef, _ w: WorkerRef) {
    enterVM(vm, w)
    ycFlip(vm, w)
    leaveVM(vm, w)
}

public func ycWaitDone(_ vm: VMRef, _ k: Int) {
    while !vm.pointee.yc.done[k].load(ordering: .acquiring) { usleep(200) }
}

/// Is worker `i` inside the VM (tests)?
public func workerInside(_ vm: VMRef, _ i: Int) -> Bool {
    pthread_mutex_lock(vm.pointee.mutex)
    defer { pthread_mutex_unlock(vm.pointee.mutex) }
    return vm.pointee.sync.pointee.inside[i]
}

/// Run the young verifier now at a stop requested from the host worker (tests).
public func youngVerifyNow(_ vm: VMRef) {
    let w = worker(vm, vm.pointee.workerCount - 1)
    enterVM(vm, w)
    stopWorld(vm, w, .verify, retry: true)
    leaveVM(vm, w)
}
