import Darwin
import Synchronization

// Concurrent marking's state (docs/modules/concurrent-marking.md
// "Layouts"). One allocation per writer, each lock beside what it guards
// (AGENTS.md): a worker's SATB buffer (its own thread inside the VM; the
// stopper at a final mark), the marker's state (the marker participant
// inside the VM; the stopper with the world stopped), the queue (the
// marking lock, a leaf lock), the cycle's log (the stopper, world stopped)
// and a few atomics read outside stops.

/// Where a cycle is. Changes only with the world stopped, except
/// sweeping -> swept, which the sweeper stores when it is done.
enum MarkingPhase: UInt8, Sendable {
    case idle
    case marking
    case sweeping
    case swept
}

/// Why a cycle started.
enum CycleTrigger: UInt8, Sendable {
    /// Old space in use reached `floor` of the soft limit.
    case floor
    /// Old entries reached `floor` of the entry table.
    case entries
    /// The predicted time to fill the headroom was under `safetyFactor`
    /// cycles.
    case predictor
    /// `cycleAtEveryScavenge`, or the host (`VM.startCycle`).
    case forced
}

/// A worker's SATB buffer, in its own 128-byte lines. Written by its
/// worker's barrier only (and by the stopper with the world stopped).
@unsafe struct SATBBuffer {
    var words: UnsafeMutablePointer<UInt64>
    var count = 0
    var pushed: UInt64 = 0
    var handed: UInt64 = 0
    var slowCalls: UInt64 = 0
    var keepAlive: UInt64 = 0

    static let capacity = 512
}

/// One item of the marker's queue: an SATB buffer (candidates, not yet
/// marked) or a grey packet (marked, to scan).
@unsafe struct MarkItem {
    var words: UnsafeMutablePointer<UInt64>
    var count: Int
    var grey: Bool
}

/// Under `MarkingShared.lock`.
@unsafe struct MarkQueue {
    var items = unsafe RawArray<MarkItem>()
    var free = unsafe RawArray<UnsafeMutablePointer<UInt64>>()
    /// The marker is waiting on `cond`.
    var waiting = 0
    var shutdown = false
    /// Buffers ever allocated (all are freed at destroy).
    var allocated = unsafe RawArray<UnsafeMutablePointer<UInt64>>()
}

/// The marker participant's state: its grey stack, the weak holders and
/// unresolved ephemerons it met, the sweep's cursor and runs. Written by
/// the marker inside the VM, and by the stopper with the world stopped.
@unsafe struct MarkerState {
    var stack = RawArray<UInt64>()
    var weak = RawArray<UInt64>()
    var ephemerons = RawArray<UInt64>()
    /// The last cycle whose marking this marker finished (its final mark ran).
    var markedCycle: UInt64 = 0
    var sweptCycle: UInt64 = 0
    var sweepCursor = 0
    var sweepWords = 0
    var sweepStamp: UInt32 = 0
    var sweepLive = RawArray<UInt8>()
    var runHead: UInt64 = 0
    var runLength: UInt64 = 0
    /// This cycle's work so far.
    var markedObjects: UInt64 = 0
    var markedBytes: UInt64 = 0
    var markCpuNs: UInt64 = 0
    var markWallNs: UInt64 = 0
    var markStartNs: UInt64 = 0
    var sweepNs: UInt64 = 0
    var sweepCpuNs: UInt64 = 0
    var entriesFreed: UInt64 = 0
    var bytesFreed: UInt64 = 0
    var qos: UInt32 = 0
    var escalations: UInt64 = 0
    var lowerings: UInt64 = 0
    /// Module 6: live bytes per block, counted while tracing when a
    /// relocation is planned for this cycle (nil otherwise).
    var blockLive: UnsafeMutablePointer<UInt32>? = nil
    var blockLiveCount = 0
}

/// One cycle (docs/modules/concurrent-marking.md "Counters"). ns.
struct CycleRecord: Sendable {
    var number: UInt64 = 0
    var trigger = CycleTrigger.forced
    /// Old space at the trigger: bytes in use, the soft limit, the promotion
    /// rate (bytes per second) and the predicted time to fill (ns, 0: no
    /// prediction).
    var inUseBytes: UInt64 = 0
    var softLimitBytes: UInt64 = 0
    var promotionBytesPerSecond: Double = 0
    var predictedFillNs: UInt64 = 0
    /// The initial mark, added to the scavenge's pause: snapshot copy, root
    /// scan, survivor scan.
    var snapshotNs: UInt64 = 0
    var rootsNs: UInt64 = 0
    var survivorsNs: UInt64 = 0
    var snapshotEntries: UInt64 = 0
    /// The final mark's pause and its split.
    var finalPauseNs: UInt64 = 0
    var finalTtspNs: UInt64 = 0
    var drainNs: UInt64 = 0
    var drainedEntries: UInt64 = 0
    var filterNs: UInt64 = 0
    var ephemeronNs: UInt64 = 0
    var weakNs: UInt64 = 0
    var verifyNs: UInt64 = 0
    var ephemeronItems: UInt64 = 0
    /// Marking: marker CPU and wall time, what it marked.
    var markCpuNs: UInt64 = 0
    var markWallNs: UInt64 = 0
    var markedObjects: UInt64 = 0
    var markedBytes: UInt64 = 0
    var satbPushed: UInt64 = 0
    var satbBuffers: UInt64 = 0
    /// The QoS the marker ran at when it requested the final mark.
    var markerQoS: UInt32 = 0
    /// Lazy sweep and apply.
    var sweepNs: UInt64 = 0
    var sweepCpuNs: UInt64 = 0
    var entriesFreed: UInt64 = 0
    var bytesFreed: UInt64 = 0
    var blocksFreed: UInt64 = 0
    var applyNs: UInt64 = 0
    /// From the initial mark to the apply.
    var durationNs: UInt64 = 0
    var floatingObjects: UInt64 = 0
    var floatingBytes: UInt64 = 0
    var aborted = false
    var completed = false
}

/// Counters of every cycle so far.
struct MarkingCounters: Sendable {
    var cycles: UInt64 = 0
    var cyclesCompleted: UInt64 = 0
    var cyclesByFloor: UInt64 = 0
    var cyclesByPredictor: UInt64 = 0
    var cyclesByEntries: UInt64 = 0
    var cyclesForced: UInt64 = 0
    var initialMarkNs: UInt64 = 0
    var finalMarkNs: UInt64 = 0
    var applies: UInt64 = 0
    var applyNs: UInt64 = 0
    var markedObjects: UInt64 = 0
    var markedBytes: UInt64 = 0
    var markerCpuNs: UInt64 = 0
    var sweepNs: UInt64 = 0
    var entriesFreed: UInt64 = 0
    var blocksFreed: UInt64 = 0
    /// Summed over the workers' buffers on read.
    var satbPushed: UInt64 = 0
    var satbBuffers: UInt64 = 0
    var barrierSlowCalls: UInt64 = 0
    var weakKeepAlive: UInt64 = 0
    /// Full collections while marking was configured: old space past its
    /// soft limit after a scavenge (by the phase it found), the table out
    /// of entries, or a verifier failure.
    var fallbacks: UInt64 = 0
    var fallbacksIdle: UInt64 = 0
    var fallbacksMarking: UInt64 = 0
    var fallbacksSweeping: UInt64 = 0
    var fallbacksVerifier: UInt64 = 0
    /// Cycles abandoned (marking discarded): by a fallback, a module 1
    /// operation, or the verifier.
    var aborts: UInt64 = 0
    /// Sweeps a module 1 operation finished in its pause.
    var sweepsFinishedInPause: UInt64 = 0
    var remFiltered: UInt64 = 0
    var weakSlotsNiled: UInt64 = 0
    var ephemeronsQueued: UInt64 = 0
    var verifierRuns: UInt64 = 0
    var missed: UInt64 = 0
    var floatingBytes: UInt64 = 0
    var qosEscalations: UInt64 = 0
    var qosLowerings: UInt64 = 0
    /// Returns from the marker's untimed wait, and the waits.
    var markerWaits: UInt64 = 0
    /// At the last trigger decision: promotion rate and predicted time to
    /// fill.
    var lastPromotionBytesPerSecond: Double = 0
    var lastPredictedFillNs: UInt64 = 0
}

/// Written with the world stopped only.
struct MarkingLog {
    var counters = MarkingCounters()
    var records: [CycleRecord] = []
    /// The current cycle's record (index in `records`), -1 when none.
    var current = -1
    var startNs: UInt64 = 0
    /// Promotion over the last scavenges: (time, cumulative promoted bytes).
    var samples: [(ns: UInt64, promoted: UInt64)] = []
    var lastCycleNs: UInt64 = 0
    /// Old entries, estimated: promoted objects and old allocations since
    /// the last scavenge added, a sweep's frees taken off, recounted from
    /// the old map after module 1 collected. With the module 1 collection
    /// count and the cumulative counts at the last sample.
    var oldEntries: UInt64 = 0
    var lastCollections: UInt64 = .max
    var lastPromotedObjects: UInt64 = 0
    var lastOldAllocations: UInt64 = 0
    /// Words of the snapshot map that may have bits (high water at the
    /// snapshot, rounded up).
    var snapshotWords = 0
}

/// The VM's marking state.
@unsafe struct MarkingShared {
    let config: MarkingConfig
    let om: ObjectMemory
    let workerCount: Int
    /// One bit per entry: an old object at the snapshot. Read-only during
    /// marking, cleared word by word by the sweep; zero outside a cycle.
    let snapshot: EntryBitmap
    let satb: UnsafeMutablePointer<UnsafeMutablePointer<SATBBuffer>>
    let queue: UnsafeMutablePointer<MarkQueue>
    let lock: UnsafeMutablePointer<pthread_mutex_t>
    let cond: UnsafeMutablePointer<pthread_cond_t>
    let marker: UnsafeMutablePointer<MarkerState>
    /// The marker participant: a worker outside the worker table (no
    /// nursery, never a scavenge participant, never runs a Process).
    let markerWorker: WorkerPointer
    let log: UnsafeMutablePointer<MarkingLog>
    /// Read outside stops: the phase, the cycle number (bumped at an
    /// initial mark and at an abort), the QoS the policy wants.
    let phase: UnsafeMutablePointer<Atomic<UInt8>>
    let cycle: UnsafeMutablePointer<Atomic<UInt64>>
    let wantUserInitiated: UnsafeMutablePointer<Atomic<Bool>>
    let markerWaits: UnsafeMutablePointer<Atomic<UInt64>>
    /// The VM is shutting down: the marker abandons its work at its next poll.
    let stopping: UnsafeMutablePointer<Atomic<Bool>>
    /// The marker thread (the host starts and joins it) and its Mach port.
    let thread: UnsafeMutablePointer<MarkerThread>
    let machThread: UnsafeMutablePointer<Atomic<UInt32>>
    /// The VM-wide barrier word (module 3's flag line, word 2).
    let barrier: UnsafeMutablePointer<Atomic<UInt32>>
}

/// Host side: written by `start` and `shutdown` only.
@unsafe struct MarkerThread {
    var thread: pthread_t? = nil
}

typealias MarkingPointer = UnsafeMutablePointer<MarkingShared>

extension UnsafeMutablePointer where Pointee == MarkingShared {
    @inline(__always)
    var phaseNow: MarkingPhase { unsafe MarkingPhase(rawValue: pointee.phase.pointee.load(ordering: .acquiring)).unsafelyUnwrapped }

    @inline(__always)
    func setPhase(_ p: MarkingPhase) { unsafe pointee.phase.pointee.store(p.rawValue, ordering: .releasing) }

    @inline(__always)
    var cycleNow: UInt64 { unsafe pointee.cycle.pointee.load(ordering: .acquiring) }

    @inline(__always)
    func buffer(_ i: Int) -> UnsafeMutablePointer<SATBBuffer> { unsafe pointee.satb[i] }
}

// MARK: - the flag word

/// The barrier flag word: word 2 of module 3's safepoint flag line, so the
/// interpreter reaches it through the pointer it already holds. Bit 0:
/// old-space marking (the SATB barrier and the weak keep-alive). Module 7
/// adds its bits; the fast path tests the whole word.
@_transparent
func barrierWord(_ flag: UnsafeMutablePointer<Atomic<UInt32>>) -> UnsafeMutablePointer<Atomic<UInt32>> {
    unsafe flag + 2
}

enum BarrierBits {
    static let marking: UInt32 = 1
}

/// The flag line: the safepoint flag (word 0) and the barrier word (word
/// 2), in one 128-byte line both are read from.
func makeFlagLine() -> UnsafeMutablePointer<Atomic<UInt32>> {
    let raw = UnsafeMutableRawPointer.allocate(byteCount: 128, alignment: 128)
    let p = unsafe raw.bindMemory(to: Atomic<UInt32>.self, capacity: 32)
    for i in 0..<32 { unsafe (p + i).initialize(to: Atomic(0)) }
    return unsafe p
}

func freeFlagLine(_ p: UnsafeMutablePointer<Atomic<UInt32>>) {
    unsafe p.deinitialize(count: 32)
    unsafe UnsafeMutableRawPointer(p).deallocate()
}
