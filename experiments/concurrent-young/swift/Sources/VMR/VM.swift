// VM state, workers, metrics, the stop-the-world protocol, and the
// enter/leave extension of it. Copied from ../generational-gc: parked
// workers join a parallel scavenge phase; workers carry a nursery, a
// remembered buffer and a young log. This experiment adds the per-worker
// marking flag and SATB buffer, marker participants that park without
// joining a scavenge, and enter/leave wait accounting that includes
// blocking on the safepoint mutex (SPEC.md "Scenarios").

import Darwin
import Synchronization

public let cacheSize = 1024
/// Words per Process stack segment: 64 KiB (SPEC.md "Stack segment").
public let stackWords = 8 * 1024
public let maxProcesses = 32 * 1024
public let priorities = 3
public let uiPriority = 2

public struct CacheEntry {
    var cls: UInt64 = 0
    var sel: UInt64 = 0
    var method: UInt64 = 0
}

/// Why a worker left `run` (`Worker.leave`).
public enum Leave {
    public static let none: UInt8 = 0
    public static let terminated: UInt8 = 1
    public static let preempted: UInt8 = 2
    public static let blocked: UInt8 = 3   // wait, yield, hop, detach: already queued
    public static let overflow: UInt8 = 4
    public static let killed: UInt8 = 5
}

/// Per-worker state. Owned by its thread while running; read by the stopping
/// worker only while the owner is parked. Lives in raw memory, padded.
public struct Worker {
    public var id: Int
    public var satbCount: Int = 0
    public var satbBuf: UnsafeMutablePointer<Oop>
    /// The VM, for the SATB slow path (one argument fewer at the call site).
    public var vm: UnsafeMutableRawPointer? = nil
    /// The running Process's stack segment (or a small dummy when idle).
    public var stack: UnsafeMutablePointer<UInt64>
    public var stackEnd: UnsafeMutablePointer<UInt64>
    public var sp: UnsafeMutablePointer<UInt64>
    /// Flushed at every park point (poll, primitive call).
    public var pc: UInt = 0
    public var hdr: UnsafeMutablePointer<UInt64>? = nil
    public var fp: UnsafeMutablePointer<UInt64>? = nil
    public var countdown: Int = 1024
    public var pollEvery: Int = 1024
    /// Budget deadline in mach ticks.
    public var deadline: UInt64 = .max
    public var leave: UInt8 = 0
    /// Bottom-frame return value when `leave == terminated`.
    public var result: Oop = 0
    public var isMain: Bool = false
    /// A marker thread's participant record: parks without joining a scavenge.
    public var isMarker: Bool = false
    /// Process being run, or 0; its native record index.
    public var current: Oop = 0
    public var rec: Int = -1
    /// Main worker: lowest priority this turn may run.
    public var minPriority: Int = 0
    /// Main worker: the event `nextEvent` last handed out (enqueue ticks).
    public var currentEventTicks: UInt64 = 0
    public var currentEventPosted: UInt64 = 0
    public var tlab = Tlab()
    public var ws = WorkerSpace()
    /// `youngBit` when this worker allocates in a nursery, else 0.
    public var youngMark: UInt64 = 0
    public var nurseryStart: UInt = 0
    /// End of eden: the allocation limit (the whole nursery when N = 1).
    public var nurseryEnd: UInt = 0
    /// Bump position while the TLAB is retired (SPEC.md "Spaces").
    public var nurseryTop: UInt = 0
    /// The whole eden and, in offload, the half in use (SPEC.md "Spaces per
    /// worker"). Survivor state lives in the nursery record (`Nur`).
    public var edenLo: UInt = 0
    public var edenHalfBytes: UInt = 0
    public var edenHalf = 0
    /// Per-nursery remembered and deletion buffers, and the stop-the-world
    /// scavenge's next remembered buffers (SPEC.md "Remembered sets").
    public var rem: UnsafeMutablePointer<RawBuf<Oop>>
    public var nextRem: UnsafeMutablePointer<RawBuf<Oop>>
    public var del: UnsafeMutablePointer<RawBuf<Oop>>
    /// Chunks with free entries left by this nursery's collections.
    public var recycle = RawBuf<UInt32>(capacity: 64)
    public var recycleNext = 0
    /// Pause attribution (SPEC.md "Scenarios"), ns and counts: rounds done
    /// for its own and for other nurseries' collections; own collection
    /// (local) or flip (offload) and the part of it spent opening; waits for
    /// the collector; waits for a pending stop before opening; resume scans;
    /// deletion records; collector CPU (collector thread record only).
    public var ackOwnNs: UInt64 = 0
    public var ackOwn: UInt64 = 0
    public var ackOtherNs: UInt64 = 0
    public var ackOther: UInt64 = 0
    public var ownPauses: UInt64 = 0
    public var ownPauseNs: UInt64 = 0
    public var ownPauseOpenNs: UInt64 = 0
    public var ownPauseMaxNs: UInt64 = 0
    public var pauseSamples: UnsafeMutablePointer<Samples>
    public var collWaits: UInt64 = 0
    public var collWaitNs: UInt64 = 0
    public var collWaitMaxNs: UInt64 = 0
    public var stwWaitNs: UInt64 = 0
    public var resumeScans: UInt64 = 0
    public var delPushed: UInt64 = 0
    /// Young holders remembered by the cross-nursery barrier.
    public var crossRem: UInt64 = 0
    /// Offload snoop records (same-nursery holders outside Y).
    public var snooped: UInt64 = 0
    /// Inside a young collection as its collector.
    public var ycBusy = false
    public var collectorCpuNs: UInt64 = 0
    /// Parked in stop-the-world scavenges another worker requested.
    public var parkedForOthersNs: UInt64 = 0
    /// Parked in stops, by pause kind: ns at [kind], count at [8 + kind].
    public var parkedByKind: UnsafeMutablePointer<UInt64>
    /// Hazard slots 0 and 1, then the epoch word, on their own cache line
    /// (SPEC.md "Hazard slots", "Freeing old blocks: epochs").
    public var hz: UnsafeMutablePointer<Atomic<UInt64>>
    /// Post-store check slow path: stores redone, spin episodes while
    /// RELOCATING, spin time (total, max), hazard waits.
    public var storeRedo: UInt64 = 0
    public var spinEpisodes: UInt64 = 0
    public var spinNs: UInt64 = 0
    public var spinMaxNs: UInt64 = 0
    public var hazardWaits: UInt64 = 0
    /// Promotion buffer for scavenges this worker takes part in.
    public var promo = Tlab()
    /// Young log: bitmap words taken this cycle and the bits taken.
    public var logWord = RawBuf<UInt32>(capacity: 4096)
    public var logBits = RawBuf<UInt64>(capacity: 4096)
    /// Chunks taken this cycle (generational mode).
    public var chunks = RawBuf<UInt32>(capacity: 256)
    var gcStack = WordStack(capacity: 1 << 14)
    public var barrierSlow: UInt64 = 0
    /// SATB slow-path calls, entries pushed, buffers handed over.
    public var satbSlow: UInt64 = 0
    public var satbPushed: UInt64 = 0
    public var satbHandovers: UInt64 = 0
    /// This worker's share of the current scavenge (SPEC.md "Pause accounting").
    public var gc = GCShare()
    public var cache: UnsafeMutablePointer<CacheEntry>
    public var misses: UInt64 = 0
    public var parkedNs: UInt64 = 0
    public var tlabRefills: UInt64 = 0
    public var preemptions: UInt64 = 0
    public var slices: UInt64 = 0
    public var idleNs: UInt64 = 0
    public var dummy: UnsafeMutablePointer<UInt64>

    public static func create(id: Int, nilObj: Oop, main: Bool = false, marker: Bool = false) -> UnsafeMutablePointer<Worker> {
        let dummy = UnsafeMutablePointer<UInt64>.allocate(capacity: 16)
        dummy.initialize(repeating: nilObj, count: 16)
        let cache = UnsafeMutablePointer<CacheEntry>.allocate(capacity: cacheSize)
        cache.initialize(repeating: CacheEntry(), count: cacheSize)
        // Each worker on its own 128-byte cache lines (AGENTS.md).
        let bytes = (MemoryLayout<Worker>.stride + 127) & ~127
        let w = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 128).bindMemory(to: Worker.self, capacity: 1)
        let satb = UnsafeMutablePointer<Oop>.allocate(capacity: satbCap)
        let hz = UnsafeMutableRawPointer.allocate(byteCount: 128, alignment: 128).bindMemory(to: Atomic<UInt64>.self, capacity: 4)
        for i in 0..<4 { (hz + i).initialize(to: Atomic(i == hzEpoch ? quiescent : 0)) }
        func bufs() -> UnsafeMutablePointer<RawBuf<Oop>> {
            let b = UnsafeMutablePointer<RawBuf<Oop>>.allocate(capacity: maxNurseries)
            for i in 0..<maxNurseries { (b + i).initialize(to: RawBuf<Oop>(capacity: 64)) }
            return b
        }
        let pk = UnsafeMutablePointer<UInt64>.allocate(capacity: 16)
        pk.initialize(repeating: 0, count: 16)
        w.initialize(to: Worker(id: id, satbBuf: satb, stack: dummy, stackEnd: dummy + 16, sp: dummy, isMain: main,
                                isMarker: marker, rem: bufs(), nextRem: bufs(), del: bufs(),
                                pauseSamples: Samples.make(1 << 16), parkedByKind: pk,
                                hz: hz, cache: cache, dummy: dummy))
        return w
    }
}

/// Index of the epoch word in `Worker.hz`; its value while outside the VM.
public let hzEpoch = 2
public let quiescent = UInt64.max

/// Minimal growable buffer of words in raw memory (roots, mark stack).
public struct WordStack {
    public var ptr: UnsafeMutablePointer<UInt64>
    public var count = 0
    var cap: Int

    init(capacity: Int) {
        ptr = .allocate(capacity: capacity)
        cap = capacity
    }

    @inline(__always) mutating func push(_ v: UInt64) {
        if count == cap { grow() }
        ptr[count] = v
        count &+= 1
    }

    @inline(never) mutating func grow() {
        let n = UnsafeMutablePointer<UInt64>.allocate(capacity: cap * 2)
        n.moveInitialize(from: ptr, count: count)
        ptr.deallocate()
        ptr = n
        cap *= 2
    }

    @inline(__always) mutating func pop() -> UInt64? {
        if count == 0 { return nil }
        count &-= 1
        return ptr[count]
    }
}

/// Growable buffer of trivial values in raw memory. One writer at a time.
public struct RawBuf<T> {
    public var ptr: UnsafeMutablePointer<T>
    public var count = 0
    var cap: Int

    init(capacity: Int) {
        ptr = .allocate(capacity: capacity)
        cap = capacity
    }

    @inline(__always) mutating func push(_ v: T) {
        if count == cap { grow() }
        ptr[count] = v
        count &+= 1
    }

    @inline(never) mutating func grow() {
        let n = UnsafeMutablePointer<T>.allocate(capacity: cap * 2)
        n.moveInitialize(from: ptr, count: count)
        ptr.deallocate()
        ptr = n
        cap *= 2
    }
}

/// One participant's share of a scavenge (ns and counts).
public struct GCShare {
    public var rootsNs: UInt64 = 0
    public var remNs: UInt64 = 0
    public var copyNs: UInt64 = 0
    public var sweepNs: UInt64 = 0
    public var waitNs: UInt64 = 0
    public var promotedBytes: UInt64 = 0
    public var promotedObjects: UInt64 = 0
    public var survivedBytes: UInt64 = 0
    public var survivedObjects: UInt64 = 0
    public var overflowBytes: UInt64 = 0
    public var overflowObjects: UInt64 = 0
    public var entriesAllocated: UInt64 = 0
    public var entriesFreed: UInt64 = 0
    public var remScanned: UInt64 = 0
    public var exported: UInt64 = 0
    public var copyBusy: UInt64 { rootsNs &+ remNs &+ copyNs }
}

/// A fixed-capacity sample buffer (ns values). One writer at a time.
public struct Samples {
    public var ptr: UnsafeMutablePointer<UInt64>
    public var count = 0
    public var cap: Int
    init(_ cap: Int) { ptr = .allocate(capacity: cap); self.cap = cap }
    static func make(_ cap: Int) -> UnsafeMutablePointer<Samples> {
        let p = UnsafeMutablePointer<Samples>.allocate(capacity: 1)
        p.initialize(to: Samples(cap))
        return p
    }
    @inline(__always) mutating func add(_ v: UInt64) {
        if count < cap { ptr[count] = v; count &+= 1 }
    }
    public mutating func reset() { count = 0 }
    public func values() -> [UInt64] { Array(UnsafeBufferPointer(start: ptr, count: count)) }
}

/// Counters and timings (atomic: several workers add to them).
public enum Metric: Int, CaseIterable {
    case gcCount, gcNs, markNs, sweepNs, liveBytes
    case stwCount, stwNs, ttspNs, parkedNs
    case entryRefills, tlabRefills
    case forks, terminations, overflows, preemptions, yields, waits, signals
    case extSignals, extDrains, hops, detaches, uiPrims
    case schedLocks, schedContended, schedWaitNs, idleNs, idleWaits
    case stuckReports, mainEnterWaitNs, mainEnters, kills
    case scavenges, scavengeNs, fullGCs, fullNs, promotedBytes, promotedObjects, youngBytes
    case survivedBytes, overflowBytes, overflowObjects
    case remSetTotal, entriesAllocated, entriesFreed, entrySweepNs, fullEntriesFreed
    case barrierSlow, verifyFailures, verifyRuns
    case cmCycles, cmFallbacks, cmAborts, cmVerifyRuns, cmMissed, cmFloatingBytes
    // relocation (SPEC.md "Part 2"); the first six are per-cycle deltas too
    case relocMovedBytes, relocMovedObjects, relocSkipPinned, relocSkipHazard, relocNoSpace, relocEvacuated
    case relocCasFail, relocFreedEpoch, relocFreedPause, relocFreeDelayNs, relocFreeDelayMaxNs, relocPins
    case relocVerifyRuns
    case ycCollections, youngVerifyRuns
    /// oldheap: latest end of a build phase (`nil ohBuilt`, now() clock) and the kernel start.
    case buildDoneAt, kernelStartAt
}

public enum SafeOp {
    /// Young collection (generational mode; a no-op otherwise).
    case scavenge
    /// Scavenge (generational mode) then mark-sweep of old space.
    case full
    /// Concurrent marking: the final-mark pause (SPEC.md "Phases" 4).
    case finalMark
    /// Tests and host: a scavenge whose pause always starts a cycle
    /// (`scavenge: false` only in the literal test mode).
    case startCycle(scavenge: Bool)
    /// local/offload: the initial-mark pause without a scavenge ((a)) or
    /// with one ((b)) (SPEC.md "Part 3").
    case initialMark
    /// Publish a finished lazy sweep (SPEC.md "Part 3", "Apply").
    case apply
    /// The young verifier after a local collection.
    case verify
}

public typealias WakeHook = @convention(c) (UnsafeMutableRawPointer?) -> Void
/// (ctx, primitive kind 0 setLabel 1 appendLine 2 sliderValue, value) -> answer
public typealias UIHook = @convention(c) (UnsafeMutableRawPointer?, Int, Int64) -> Int64
/// (ctx, process id, selector name C string, age ms)
public typealias StuckHook = @convention(c) (UnsafeMutableRawPointer?, Int64, UnsafePointer<CChar>, Double) -> Void

/// Native side of a Process (SPEC.md "Native record").
public struct ProcRec {
    public var process: Oop = 0
    public var base: UnsafeMutablePointer<UInt64>? = nil
    public var end: UnsafeMutablePointer<UInt64>? = nil
    public var runningOn = -1
    public var nextFree = -1
    public var hopStart: UInt64 = 0
    public var mainStart: UInt64 = 0
    public var runnableSince: UInt64 = 0
    public var stuckReported = false
}

/// External-signal node (SPEC.md "External signals").
struct ExtNode {
    var sem: Oop
    var handle: Int
    var next: UInt
}

public struct Event {
    public var kind: Int64
    public var value: Int64
    /// When the event happened (due time for synthetic events).
    public var ticks: UInt64
    /// When the shell enqueued it.
    public var posted: UInt64
}

/// Everything the interpreter and GC touch. A plain struct of trivial fields
/// in raw memory, so no ARC traffic reaches the hot path.
public struct VMCore: ~Copyable {
    public var heap: Heap
    public var om: OM
    public var space: Space
    public var opTlab = Tlab()
    public var classTable: UnsafeMutablePointer<Oop>
    public var classCount = 0
    public var nilObj: Oop = 0
    public var trueObj: Oop = 0
    public var falseObj: Oop = 0
    public var special: UnsafeMutablePointer<Oop>
    public var globals: UnsafeMutablePointer<Oop>
    public var roots: WordStack
    var markStack: WordStack
    /// Bit 0: a stop is requested; bits 1..: 2 x open handshake rounds
    /// (SPEC.md "Handshakes"). The poll's one load.
    public let attention: Atomic<UInt64>
    /// Bit 0: old-space marking (SATB); bits 1..: 2 x nurseries being
    /// collected (young deletion barrier) (SPEC.md "Barriers").
    public let barrierWord: Atomic<UInt64>
    /// Hazard slots in use, all workers (young collectors skip the scan of
    /// every slot when 0).
    public let hazardsHeld: Atomic<Int>
    var mutex: UnsafeMutablePointer<pthread_mutex_t>
    var cond: UnsafeMutablePointer<pthread_cond_t>
    /// Mutable state lives behind its own pointers, one per guarding lock:
    /// `vm.pointee.x += 1` is a modifying access of the whole VMCore, and two
    /// of those under different locks are an exclusivity race (TSan).
    var sync: UnsafeMutablePointer<SyncState>
    var workers: UnsafeMutablePointer<UnsafeMutablePointer<Worker>>?
    var workerCount = 0
    public var metrics: UnsafeMutablePointer<Atomic<UInt64>>
    /// Host-side symbol names in intern order; symbol i is roots[3 + i].
    public var symbolNames: [String] = []
    public var verboseGC = false
    /// Tests: check the remembered-set invariant and the scavenge's result
    /// inside every pause (SPEC.md "Verification").
    public var verify = false
    /// Parallel scavenge bookkeeping (Scavenge.swift).
    var gc: UnsafeMutablePointer<GCShared>
    /// Concurrent marking: configuration (set before any thread starts) and
    /// shared state, all behind pointers (Concurrent.swift).
    public var cmConfig = CMConfig()
    public var cm: CMShared
    /// Young collection without stopping the world (Young.swift).
    public var ycConfig = YCConfig()
    public var yc = YShared.make()
    /// One record per pause, written by the stopper under `mutex`.
    public var gcLog: UnsafeMutablePointer<GCLog>

    // --- scheduler (SPEC.md "Scheduler"); guarded by schedLock
    var schedLock: UnsafeMutablePointer<pthread_mutex_t>
    var schedCond: UnsafeMutablePointer<pthread_cond_t>
    /// [affinity * priorities + priority] heads, then tails at +2*priorities.
    var ready: UnsafeMutablePointer<Oop>
    var sched: UnsafeMutablePointer<SchedState>
    var recs: UnsafeMutablePointer<ProcRec>
    /// One-byte code array holding the `leave` opcode.
    var exitCode: UnsafeMutablePointer<UInt8>
    public var sliceNs: UInt64 = 5_000_000
    public var pollEvery = 1024
    public var mainBudgetEnabled = true

    // --- external signals
    var extHead: UnsafeMutablePointer<Atomic<UInt>>
    var pendingLock: UnsafeMutablePointer<pthread_mutex_t>
    var pending: UnsafeMutablePointer<Oop>
    var pendingNext: UnsafeMutablePointer<Int>
    var pend: UnsafeMutablePointer<PendingState>
    var ioLock: UnsafeMutablePointer<pthread_mutex_t>
    var io: UnsafeMutablePointer<IOState>

    // --- events (native ring)
    var eventLock: UnsafeMutablePointer<pthread_mutex_t>
    var events: UnsafeMutablePointer<Event>
    var evq: UnsafeMutablePointer<EventQueueState>
    /// Host temporaries (spawn's receiver and argument), scanned as roots.
    var hostRoots: UnsafeMutablePointer<Oop>

    // --- shell hooks
    public var hookCtx: UnsafeMutableRawPointer? = nil
    public var wakeMain: WakeHook? = nil
    public var uiHook: UIHook? = nil
    public var stuckHook: StuckHook? = nil
    /// Per worker id: record index + 1 of a Process to terminate at that
    /// worker's next budget check (0 = none).
    var interrupts: UnsafeMutablePointer<Atomic<Int>>
    var doneCond: UnsafeMutablePointer<pthread_cond_t>
    /// Result oop of each terminated Process, by id (host reads SmallIntegers).
    public var results: UnsafeMutablePointer<Oop>
    /// Main worker's current Process start (ticks, 0 = none) and id, for an
    /// off-main watchdog.
    public let mainBusySince: Atomic<UInt64>
    public let mainBusyId: Atomic<Int64>
    public let mainBusyRec: Atomic<Int>

    // --- samples (ns)
    public let eventLatency = Samples.make(1 << 20)     // main only, from event time
    public let eventLatencyPost = Samples.make(1 << 20) // main only, from enqueue
    public let hopLatency = Samples.make(1 << 20)       // main only
    public let mainPerHop = Samples.make(1 << 20)       // main only
    public let gcTtsp = Samples.make(1 << 16)           // under mutex
    public let gcStw = Samples.make(1 << 16)            // under mutex
    public let mainEnterWait = Samples.make(1 << 20)    // main only

    public static func create(heapSize: Int, nurseryBytes: Int) -> UnsafeMutablePointer<VMCore> {
        let ct = UnsafeMutablePointer<Oop>.allocate(capacity: classTableSize)
        ct.initialize(repeating: 0, count: classTableSize)
        let special = UnsafeMutablePointer<Oop>.allocate(capacity: 9)
        special.initialize(repeating: 0, count: 9)
        let globals = UnsafeMutablePointer<Oop>.allocate(capacity: globalCount)
        globals.initialize(repeating: 0, count: globalCount)
        let metrics = UnsafeMutablePointer<Atomic<UInt64>>.allocate(capacity: Metric.allCases.count)
        for i in 0..<Metric.allCases.count { (metrics + i).initialize(to: Atomic(0)) }
        func mutex() -> UnsafeMutablePointer<pthread_mutex_t> {
            let m = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
            pthread_mutex_init(m, nil)
            return m
        }
        func condvar() -> UnsafeMutablePointer<pthread_cond_t> {
            let c = UnsafeMutablePointer<pthread_cond_t>.allocate(capacity: 1)
            pthread_cond_init(c, nil)
            return c
        }
        let ready = UnsafeMutablePointer<Oop>.allocate(capacity: 4 * priorities)
        ready.initialize(repeating: 0, count: 4 * priorities)
        let recs = UnsafeMutablePointer<ProcRec>.allocate(capacity: maxProcesses)
        recs.initialize(repeating: ProcRec(), count: maxProcesses)
        let exitCode = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
        exitCode.initialize(repeating: 0x1B, count: 4)
        let extHead = UnsafeMutablePointer<Atomic<UInt>>.allocate(capacity: 1)
        extHead.initialize(to: Atomic(0))
        let pendingCap = 1 << 16
        let pending = UnsafeMutablePointer<Oop>.allocate(capacity: pendingCap)
        pending.initialize(repeating: 0, count: pendingCap)
        let pendingNext = UnsafeMutablePointer<Int>.allocate(capacity: pendingCap)
        pendingNext.initialize(repeating: -1, count: pendingCap)
        let events = UnsafeMutablePointer<Event>.allocate(capacity: eventCapacity)
        let interrupts = UnsafeMutablePointer<Atomic<Int>>.allocate(capacity: 64)
        for i in 0..<64 { (interrupts + i).initialize(to: Atomic(0)) }
        let results = UnsafeMutablePointer<Oop>.allocate(capacity: resultCapacity)
        results.initialize(repeating: 0, count: resultCapacity)
        let hostRoots = UnsafeMutablePointer<Oop>.allocate(capacity: 4)
        hostRoots.initialize(repeating: 0, count: 4)
        let heap = Heap(size: heapSize, nurseryBytes: nurseryBytes)
        let (om, space) = makeSpace(heap)
        let vm = UnsafeMutablePointer<VMCore>.allocate(capacity: 1)
        vm.initialize(to: VMCore(heap: heap, om: om, space: space, classTable: ct, special: special,
                                 globals: globals, roots: WordStack(capacity: 256),
                                 markStack: WordStack(capacity: 1 << 16),
                                 attention: Atomic(0), barrierWord: Atomic(0), hazardsHeld: Atomic(0),
                                 mutex: mutex(), cond: condvar(), sync: boxed(SyncState()), metrics: metrics,
                                 gc: GCShared.make(), cm: CMShared.make(nblocks: heap.nblocks), gcLog: boxed(GCLog()),
                                 schedLock: mutex(), schedCond: condvar(), ready: ready,
                                 sched: boxed(SchedState()), recs: recs,
                                 exitCode: exitCode, extHead: extHead, pendingLock: mutex(),
                                 pending: pending, pendingNext: pendingNext, pend: boxed(PendingState()),
                                 ioLock: mutex(), io: boxed(IOState()),
                                 eventLock: mutex(), events: events, evq: boxed(EventQueueState()),
                                 hostRoots: hostRoots,
                                 interrupts: interrupts, doneCond: condvar(), results: results, mainBusySince: Atomic(0), mainBusyId: Atomic(0),
                                 mainBusyRec: Atomic(-1)))
        return vm
    }
}

public let eventCapacity = 1 << 16

/// Safepoint bookkeeping, guarded by `mutex`.
struct SyncState {
    var active = 0
    var parked = 0
    var epoch: UInt64 = 0
    /// A scavenge's parallel phase is open to parked workers.
    var scavOpen = false
    var scavSeq: UInt64 = 0
    var joined = 0
    var done = 0
    /// Per worker id: inside the VM; inside a blocking region.
    var inside = [Bool](repeating: false, count: 64)
    var blocking = [Bool](repeating: false, count: 64)
    /// A stopper waits for collections to drain; collections in progress.
    var stwWanted = false
    var ycActive = 0
    /// Kind and requester of the stop in progress (park attribution).
    var stopKind: UInt8 = 0
    var stopRequester = -1
}

/// Scheduler bookkeeping, guarded by `schedLock`.
public struct SchedState {
    var idleWorkers = 0
    public var shutdown = false
    var recFree = -1
    var recHwm = 0
    public var liveProcesses = 0
    var nextProcessId: Int64 = 1
}

/// Pending-root table bookkeeping, guarded by `pendingLock`.
public struct PendingState {
    var free = -1
    var hwm = 0
    public var count = 0
}

/// Completed IO, guarded by `ioLock`.
struct IOState {
    var results: [Int: [UInt8]] = [:]
    var nextHandle = 1
}

/// Event ring indices, guarded by `eventLock`.
struct EventQueueState {
    var head = 0
    var tail = 0
}

func boxed<T>(_ v: T) -> UnsafeMutablePointer<T> {
    let p = UnsafeMutablePointer<T>.allocate(capacity: 1)
    p.initialize(to: v)
    return p
}
public let resultCapacity = 1 << 20

public typealias VMRef = UnsafeMutablePointer<VMCore>
public typealias WorkerRef = UnsafeMutablePointer<Worker>

extension UnsafeMutablePointer where Pointee == VMCore {
    @inline(__always) func add(_ m: Metric, _ v: UInt64) {
        pointee.metrics[m.rawValue].wrappingAdd(v, ordering: .relaxed)
    }
    @inline(__always) func set(_ m: Metric, _ v: UInt64) { pointee.metrics[m.rawValue].store(v, ordering: .relaxed) }
    public func metric(_ m: Metric) -> UInt64 { pointee.metrics[m.rawValue].load(ordering: .relaxed) }
}

@inline(__always) func classAt(_ vm: VMRef, _ idx: UInt64) -> Oop {
    vm.pointee.classTable[Int(truncatingIfNeeded: idx)]
}

/// Register workers (index = worker id; worker 0 is the main worker). None
/// is active until it enters. Call before starting threads.
public func setWorkers(_ vm: VMRef, _ ws: [WorkerRef]) {
    let p = UnsafeMutablePointer<WorkerRef>.allocate(capacity: max(ws.count, 1))
    let nb = vm.pointee.heap.nurseryBytes
    for (i, w) in ws.enumerated() {
        precondition(w.pointee.id == i)
        p[i] = w
        w.pointee.vm = UnsafeMutableRawPointer(vm)
        w.pointee.pollEvery = vm.pointee.pollEvery
        w.pointee.countdown = vm.pointee.pollEvery
        if nb > 0 {
            // Nursery slot = worker id (SPEC.md "Spaces").
            if i >= maxNurseries { fatal("more than \(maxNurseries) workers with nurseries") }
            w.pointee.nurseryStart = vm.pointee.heap.nurseryStart(i)
            // Eden, then two survivor halves when N > 1 (SPEC.md "Layout per worker").
            let sb = vm.pointee.cmConfig.ageN > 1 ? UInt(survivorBytes(vm, nb)) : 0
            let eden = UInt(nb) &- 2 &* sb
            w.pointee.edenLo = w.pointee.nurseryStart
            // offload: two halves of the eden (SPEC.md "Spaces per worker").
            let offload = vm.pointee.ycConfig.mode == YoungMode.offload
            w.pointee.edenHalfBytes = offload ? (eden / 2) & ~7 : eden
            w.pointee.edenHalf = 0
            w.pointee.nurseryEnd = w.pointee.nurseryStart &+ w.pointee.edenHalfBytes
            let nur = nurOf(vm, i)
            nur.pointee.survBase = w.pointee.edenLo &+ eden
            nur.pointee.survBytes = sb
            nur.pointee.survTo = 1
            nur.pointee.survFromTop = nur.pointee.survBase
            w.pointee.nurseryTop = w.pointee.nurseryStart
            w.pointee.youngMark = youngBit | (UInt64(i) &<< nurseryShift)
        }
    }
    vm.pointee.workers = p
    vm.pointee.workerCount = ws.count
    if vm.pointee.cmConfig.force && vm.pointee.cmConfig.concurrent { vm.pointee.barrierWord.store(1, ordering: .relaxed) }
    pthread_mutex_lock(vm.pointee.mutex)
    vm.pointee.sync.pointee.active = 0
    vm.pointee.sync.pointee.parked = 0
    pthread_mutex_unlock(vm.pointee.mutex)
}

public func worker(_ vm: VMRef, _ i: Int) -> WorkerRef { vm.pointee.workers.unsafelyUnwrapped[i] }

/// One survivor half: `KAJO_SURVIVOR_KB`-derived config, else nursery / 8,
/// rounded down to 8 bytes.
func survivorBytes(_ vm: VMRef, _ nursery: Int) -> Int {
    let s = vm.pointee.cmConfig.survivorBytes > 0 ? vm.pointee.cmConfig.survivorBytes : nursery / 8
    if 2 * s >= nursery { fatal("survivor spaces leave no eden") }
    return s & ~7
}


/// Every root word, as (pointer, count) ranges. World stopped.
func rootRanges(_ vm: VMRef) -> [(UnsafeMutablePointer<Oop>, Int)] {
    var r: [(UnsafeMutablePointer<Oop>, Int)] = [
        (vm.pointee.roots.ptr, vm.pointee.roots.count),
        (vm.pointee.globals, globalCount),
        (vm.pointee.special, 9),
        (vm.pointee.classTable + 1, max(0, vm.pointee.classCount - 1)),
        (vm.pointee.ready, 4 * priorities),
        (vm.pointee.pending, vm.pointee.pend.pointee.hwm),
        (vm.pointee.hostRoots, 4),
    ]
    let om = vm.pointee.om
    for i in 0..<vm.pointee.sched.pointee.recHwm {
        let rec = vm.pointee.recs + i
        if rec.pointee.process == 0 { continue }
        let procSlot = (UnsafeMutableRawPointer(rec) + MemoryLayout<ProcRec>.offset(of: \ProcRec.process)!)
            .assumingMemoryBound(to: Oop.self)
        r.append((procSlot, 1))
        let base = rec.pointee.base.unsafelyUnwrapped
        let sp: UnsafeMutablePointer<UInt64>
        if rec.pointee.runningOn >= 0 {
            sp = worker(vm, rec.pointee.runningOn).pointee.sp
        } else {
            sp = untagPtr(om.slot(rec.pointee.process, pSp), UInt64.self)
        }
        r.append((base, (sp - base) + 1))
    }
    return r
}

/// Called at a poll when a stop was seen requested. Regs already flushed.
@inline(never)
func safepoint(_ vm: VMRef, _ w: WorkerRef) {
    advanceEpoch(vm, w)
    retireTlab(vm, w)
    pthread_mutex_lock(vm.pointee.mutex)
    parkLocked(vm, w)
    pthread_mutex_unlock(vm.pointee.mutex)
}

/// The poll slow path's view of the attention word: park for a stop,
/// service handshake rounds (SPEC.md "Handshakes").
@inline(__always)
func attend(_ vm: VMRef, _ w: WorkerRef) {
    let a = vm.pointee.attention.load(ordering: .acquiring)
    if a & 1 != 0 { safepoint(vm, w) }
    if a > 1 { serviceHandshakes(vm, w) }
}

/// Mutex held. While parked, join the scavenge's parallel phase if the
/// stopper opens one (SPEC.md "Scavenge", phase 3).
func parkLocked(_ vm: VMRef, _ w: WorkerRef) {
    if !stwRequested(vm) { return }
    let t0 = now()
    let sync = vm.pointee.sync
    let epoch = sync.pointee.epoch
    var seen = sync.pointee.scavSeq
    sync.pointee.parked += 1
    pthread_cond_broadcast(vm.pointee.cond)
    while sync.pointee.epoch == epoch {
        if sync.pointee.scavOpen && sync.pointee.scavSeq != seen && !w.pointee.isMarker {
            seen = sync.pointee.scavSeq
            vm.pointee.gc.pointee.parts[sync.pointee.joined] = w.pointee.id
            sync.pointee.joined += 1
            pthread_mutex_unlock(vm.pointee.mutex)
            participate(vm, w)
            pthread_mutex_lock(vm.pointee.mutex)
            sync.pointee.done += 1
            pthread_cond_broadcast(vm.pointee.cond)
            continue
        }
        pthread_cond_wait(vm.pointee.cond, vm.pointee.mutex)
    }
    // Not `parked -= 1`: the stopper zeroed the count when it released the
    // world (a released worker must not count as parked for the next stop).
    let dt = now() &- t0
    w.pointee.parkedNs &+= dt
    let kind = Int(sync.pointee.stopKind)
    if kind < 8 {
        w.pointee.parkedByKind[kind] &+= dt
        w.pointee.parkedByKind[8 + kind] &+= 1
    }
    if sync.pointee.stopRequester != w.pointee.id && kind == Int(PauseKind.scavenge) {
        w.pointee.parkedForOthersNs &+= dt
    }
    vm.add(.parkedNs, dt)
}

/// Stopper, mutex held: open the parallel phase, take part, wait for every
/// participant that joined (SPEC.md "Scavenge", phases 3 to 6). Answers the
/// number of participants.
func runParallelPhase(_ vm: VMRef, _ w: WorkerRef) -> Int {
    let sync = vm.pointee.sync
    sync.pointee.scavSeq &+= 1
    sync.pointee.scavOpen = true
    vm.pointee.gc.pointee.parts[0] = w.pointee.id
    sync.pointee.joined = 1
    sync.pointee.done = 0
    pthread_cond_broadcast(vm.pointee.cond)
    pthread_mutex_unlock(vm.pointee.mutex)
    participate(vm, w)
    pthread_mutex_lock(vm.pointee.mutex)
    sync.pointee.scavOpen = false
    while sync.pointee.done < sync.pointee.joined - 1 {
        pthread_cond_wait(vm.pointee.cond, vm.pointee.mutex)
    }
    return sync.pointee.joined
}

/// Stop the world and run `op`. If another worker is already stopping it,
/// park; then return nil (`retry == false`, the allocation GC case) or try
/// again. First waits until no young collection is in progress (SPEC.md
/// "Stops and collections are not interleaved"). `w`'s sp/pc/hdr must be
/// flushed.
@discardableResult
func stopWorld(_ vm: VMRef, _ w: WorkerRef, _ op: SafeOp, retry: Bool) -> Oop? {
    retireTlab(vm, w)
    pthread_mutex_lock(vm.pointee.mutex)
    let sync = vm.pointee.sync
    while true {
        if stwRequested(vm) {
            parkLocked(vm, w)
            if !retry {
                pthread_mutex_unlock(vm.pointee.mutex)
                return nil
            }
            continue
        }
        if sync.pointee.stwWanted {
            waitServicing(vm, w) { sync.pointee.stwWanted && !stwRequested(vm) }
            if !retry && !stwRequested(vm) {
                pthread_mutex_unlock(vm.pointee.mutex)
                return nil
            }
            continue
        }
        break
    }
    sync.pointee.stwWanted = true
    let td = now()
    waitServicing(vm, w) { sync.pointee.ycActive > 0 }
    let t0 = now()
    vm.pointee.gc.pointee.drainWaitNs = t0 &- td
    vm.pointee.attention.bitwiseOr(1, ordering: .releasing)
    pthread_cond_broadcast(vm.pointee.cond) // waiters in waitServicing park now
    while sync.pointee.parked + 1 < sync.pointee.active {
        pthread_cond_wait(vm.pointee.cond, vm.pointee.mutex)
    }
    let t1 = now()
    // Inactive workers (idle, or the main thread outside a turn) keep their
    // TLABs and entry reservations across leave/enter; retire and release
    // every one here, world stopped.
    if let ws = vm.pointee.workers {
        for i in 0..<vm.pointee.workerCount {
            retireTlab(vm, ws[i])
            releaseEntries(vm, ws[i])
        }
    }
    var op = op
    if case .scavenge = op, vm.pointee.gc.pointee.fullPending.pointee.load(ordering: .relaxed) { op = .full }
    sync.pointee.stopKind = 255
    sync.pointee.stopRequester = w.pointee.id
    vm.pointee.gc.pointee.requester = w.pointee.id
    performOp(vm, w, op, requested: t0, stopped: t1)
    let t2 = now()
    vm.pointee.attention.bitwiseAnd(~1, ordering: .releasing)
    sync.pointee.stwWanted = false
    sync.pointee.epoch += 1
    sync.pointee.parked = 0 // every parked worker is released
    vm.add(.stwCount, 1)
    vm.add(.stwNs, t2 &- t0)
    vm.add(.ttspNs, t1 &- t0)
    vm.pointee.gcTtsp.pointee.add(t1 &- t0)
    vm.pointee.gcStw.pointee.add(t2 &- t0)
    pthread_cond_broadcast(vm.pointee.cond)
    pthread_mutex_unlock(vm.pointee.mutex)
    return 0
}

/// Allocation found no room: collect, or park while someone else does.
func requestGC(_ vm: VMRef, _ w: WorkerRef, _ op: SafeOp) {
    stopWorld(vm, w, op, retry: false)
}

@inline(__always) func isParticipant(_ vm: VMRef, _ w: WorkerRef) -> Bool {
    !w.pointee.isMarker && w.pointee.id < vm.pointee.workerCount
}

/// The worker starts executing Smalltalk: waits while a stop is in
/// progress, then counts as active. Answers the ns spent waiting.
@discardableResult
public func enterVM(_ vm: VMRef, _ w: WorkerRef) -> UInt64 {
    // Waiting includes blocking on the mutex: a stopper holds it for most of
    // a pause.
    let t0 = now()
    var waited: UInt64 = 0
    if pthread_mutex_trylock(vm.pointee.mutex) != 0 {
        pthread_mutex_lock(vm.pointee.mutex)
        waited = now() &- t0
    }
    if stwRequested(vm) {
        while stwRequested(vm) {
            pthread_cond_wait(vm.pointee.cond, vm.pointee.mutex)
        }
        waited = now() &- t0
    }
    vm.pointee.sync.pointee.active += 1
    // Rounds open now count this worker as done (it held nothing).
    if isParticipant(vm, w) { vm.pointee.sync.pointee.inside[w.pointee.id] = true }
    pthread_mutex_unlock(vm.pointee.mutex)
    // Epoch (SPEC.md "Freeing old blocks: epochs"): first "busy, unknown"
    // (0, seq_cst), then the current epoch.
    w.pointee.hz[hzEpoch].store(0, ordering: .sequentiallyConsistent)
    w.pointee.hz[hzEpoch].store(vm.pointee.cm.epoch.pointee.load(ordering: .sequentiallyConsistent), ordering: .releasing)
    return waited
}

/// The worker stops executing Smalltalk (idle, or the main thread returning
/// to the shell). It holds no Process and no heap reference afterwards.
/// Rounds it owes are done first (SPEC.md "Handshakes").
///
/// The TLAB is kept: retiring it here pinned a fresh block per main-thread
/// turn or host call, because the sweep reuses only completely empty blocks.
/// A stop retires all TLABs instead.
@discardableResult
public func leaveVM(_ vm: VMRef, _ w: WorkerRef) -> UInt64 {
    var waited: UInt64 = 0
    if pthread_mutex_trylock(vm.pointee.mutex) != 0 {
        let t0 = now()
        pthread_mutex_lock(vm.pointee.mutex)
        waited = now() &- t0
    }
    while owesRound(vm, w) {
        pthread_mutex_unlock(vm.pointee.mutex)
        serviceHandshakes(vm, w)
        pthread_mutex_lock(vm.pointee.mutex)
    }
    quiesce(w) // holds no body pointer from here on
    if isParticipant(vm, w) { vm.pointee.sync.pointee.inside[w.pointee.id] = false }
    vm.pointee.sync.pointee.active -= 1
    pthread_cond_broadcast(vm.pointee.cond)
    pthread_mutex_unlock(vm.pointee.mutex)
    return waited
}

/// Poll slow path: request a pending full collection once its delay passed.
@inline(never)
func pendingFull(_ vm: VMRef, _ w: WorkerRef) {
    let g = vm.pointee.gc
    if g.pointee.fullPending.pointee.load(ordering: .relaxed) && ticks() >= g.pointee.fullDue.pointee.load(ordering: .relaxed) {
        stopWorld(vm, w, .full, retry: false)
    }
}
