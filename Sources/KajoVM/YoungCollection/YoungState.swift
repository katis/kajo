import Darwin
import Synchronization

// Young collection's state (docs/modules/young-collection.md "Layouts").
// One allocation per writer, each lock beside what it guards (AGENTS.md):
// per nursery the handshake (the safepoint mutex) and the flags and Y range
// other threads read (atomics); per participant its collector work (that
// thread only) and its counters (that thread, read after it stopped); the
// collector thread's queue (the safepoint mutex); the log (the safepoint
// mutex); the trigger sampler (its own lock).

/// The kinds of round (SPEC "Handshakes").
enum RoundKind: UInt8, Sendable {
    /// Barrier on: clear the participant's own deletion records for the
    /// nursery, nothing else.
    case h0
    /// Roots: scan the participant's stack, mark its Process scanned,
    /// publish its remembered and deletion buffers for the nursery.
    case h1
    /// Publish the buffers again.
    case drain
}

/// A buffer handed to a collection at an acknowledgement: remembered
/// holders or deletion records. Owned by the collection from then on.
@unsafe struct PublishedBuffer {
    var list: RawArray<UInt64>
    var remembered: Bool
}

/// One nursery's handshake. Guarded by the safepoint mutex.
@unsafe struct Handshake {
    /// A collection of this nursery is open (from its opening to its end).
    var active = false
    /// The current round, its kind and the participants that still owe it.
    var round: UInt64 = 0
    var kind = RoundKind.h0
    var need = 0
    /// Per participant: the last round it acknowledged.
    let acked: UnsafeMutablePointer<UInt64>
    /// What acknowledgements handed over: stack roots, buffers.
    var roots = RawArray<UInt64>()
    var pubs = unsafe RawArray<PublishedBuffer>()
    /// The current round's opening time and its last acknowledger (-1: the
    /// opener acknowledged everyone by proxy).
    var openedAt: UInt64 = 0
    var lastAcker = -1
    /// Offload: the owner's new eden half allocated before its H1
    /// acknowledgement (amendment 7a).
    var newHalfLo: UInt64 = 0
    var newHalfHi: UInt64 = 0
    /// Queued for the young collector thread, not yet taken.
    var queued = false
    /// Who collects it: the owner, or the collector thread.
    var offloaded = false
}

/// A collector's working state while it collects: its grey stack, the
/// held-for-a-copy flag, the busy flag (no collection nested inside its
/// own: amendment 11). Written by that thread only.
@unsafe struct CollectorWork {
    var grey = RawArray<UInt64>()
    var roots = RawArray<UInt64>()
    var pubs = unsafe RawArray<PublishedBuffer>()
    var claimed = RawArray<Int>()
    /// Between an object's offset CAS and its switch or revert: no poll, no
    /// park, no round (the relocation model's finding 4).
    var inCopy = false
    var busy = false
    /// Objects copied since the last service point.
    var sinceService = 0
    /// The round serial when this participant last serviced its rounds:
    /// the poll slow path takes the mutex only when a round opened since
    /// (rounds stay open until the slowest participant acknowledges, and
    /// every poll of the others meanwhile reaches the slow path).
    var seenSerial: UInt64 = 0
}

/// One collection (docs/modules/young-collection.md "Counters"). ns.
struct YoungRecord: Sendable {
    var nursery = 0
    /// Promotion blocks promised at the opening, released at the end.
    var reservedBlocks = 0
    var offloaded = false
    /// The participant that collected (the owner, or the collector thread).
    var collector = -1
    var openNs: UInt64 = 0
    var startNs: UInt64 = 0
    var h0Ns: UInt64 = 0
    var h1Ns: UInt64 = 0
    var t1Ns: UInt64 = 0
    var traceNs: UInt64 = 0
    var drainRoundsNs: UInt64 = 0
    var sweepNs: UInt64 = 0
    var epochWaitNs: UInt64 = 0
    var totalNs: UInt64 = 0
    var cpuNs: UInt64 = 0
    var rounds = 0
    var stackRoots: UInt64 = 0
    var processScans: UInt64 = 0
    var holders: UInt64 = 0
    var deletionRecords: UInt64 = 0
    var youngBytes: UInt64 = 0
    var copiedObjects: UInt64 = 0
    var survivedObjects: UInt64 = 0
    var survivedBytes: UInt64 = 0
    var promotedObjects: UInt64 = 0
    var promotedBytes: UInt64 = 0
    var overflowObjects: UInt64 = 0
    var overflowBytes: UInt64 = 0
    var carried: UInt64 = 0
    var crossRemembered: UInt64 = 0
    var entriesFreed: UInt64 = 0
    var deferred: UInt64 = 0
    var deferredFrees: UInt64 = 0
    var deferredKept: UInt64 = 0
    var hazardRetries: UInt64 = 0
    var newHalfWords: UInt64 = 0
    var claimFailures: UInt64 = 0
}

/// One round's latency: request to last acknowledgement. ns.
struct RoundRecord: Sendable {
    var nursery: Int
    var kind: RoundKind
    var latencyNs: UInt64
    /// The last participant to acknowledge (-1: all by proxy).
    var slowest: Int
}

/// Why a young allocation fell back to a stop-the-world collection.
enum YoungFallback: Int, Sendable, CaseIterable {
    /// The eden filled while a stop was wanted: a scavenge rides as a stop.
    case stopWanted
    /// The entry table was full: a full collection.
    case entries
    /// A collection left old space past its soft limit: a full collection.
    case softLimit
    /// A stress flag.
    case stress
    /// The promotion room a collection needs could not be promised (the
    /// reserve's rule, docs/modules/reserve-and-depth.md): a
    /// stop-the-world scavenge, whose fallback keeps objects in place.
    case reserve
}

/// Guarded by the safepoint mutex.
struct YoungLog {
    var records: [YoungRecord] = []
    var rounds: [RoundRecord] = []
    var collectionsLocal: UInt64 = 0
    var collectionsOffloaded: UInt64 = 0
    var fallbacks = [UInt64](repeating: 0, count: YoungFallback.allCases.count)
    var verifierRuns: UInt64 = 0
    /// Deferred entries the snapshot left out at initial marks (amendment 17).
    var snapshotExclusions: UInt64 = 0
    var initialMarks: UInt64 = 0
    var youngRootScanNs: UInt64 = 0
    var youngRootScanMaxNs: UInt64 = 0
    var youngRootWords: UInt64 = 0
    /// The collector thread's CPU and the QoS it ran at.
    var collectorCpuNs: UInt64 = 0
    var collectorQoS: UInt32 = 0
    /// Collections an offloaded nursery's owner ran itself (no collector thread).
    var offloadedInline: UInt64 = 0
}

/// One participant's young-collection counters. Written by its own thread
/// only; read with the world stopped or after the threads stopped.
struct YoungWorkerCounters: Sendable {
    /// Rounds acknowledged for its own nursery's collections and for
    /// others', and their time (work plus the mutex).
    var acksOwn: UInt64 = 0
    var acksOwnNs: UInt64 = 0
    var acksOther: UInt64 = 0
    var acksOtherNs: UInt64 = 0
    var ackMaxNs: UInt64 = 0
    /// Poll slow paths that took the mutex and found no round owed.
    var serviceNs: UInt64 = 0
    /// Its own collections (local: the whole collection; offload: the flip).
    var ownCollections: UInt64 = 0
    var ownNs: UInt64 = 0
    var ownMaxNs: UInt64 = 0
    var flips: UInt64 = 0
    var flipNs: UInt64 = 0
    var flipMaxNs: UInt64 = 0
    /// Offload: waits for the previous collection of its nursery.
    var collectorWaits: UInt64 = 0
    var collectorWaitNs: UInt64 = 0
    var collectorWaitMaxNs: UInt64 = 0
    /// The epoch rule before the old eden is reused (local).
    var edenWaits: UInt64 = 0
    var edenWaitNs: UInt64 = 0
    var edenWaitMaxNs: UInt64 = 0
    /// Waits for a pending stop before opening a collection, and for every
    /// collection to end before a stop (stwWanted).
    var stopWaitNs: UInt64 = 0
    var drainWaitNs: UInt64 = 0
    var deletionRecords: UInt64 = 0
    var resumeScans: UInt64 = 0
    var blockingRegions: UInt64 = 0
    /// Stores that took the young deletion barrier's slow path (the
    /// barrier word's count nonzero; collectors review, finding 4).
    var deletionBarrierCalls: UInt64 = 0
}

/// The trigger sampler of young collection without stopping the world:
/// promotion samples between stops (module 5's are taken at scavenges).
/// Under its own lock.
struct YoungSampler {
    var samples: [(ns: UInt64, promoted: UInt64)] = []
    var oldEntries: UInt64 = 0
    var lastPromotedObjects: UInt64 = 0
    var lastOldAllocations: UInt64 = 0
    var lastCollections: UInt64 = .max
}

/// The young collector thread's host-side state.
@unsafe struct YoungThread {
    var thread: pthread_t? = nil
    var started = false
}

/// The VM's young-collection state.
@unsafe struct YoungShared {
    let config: YoungConfig
    let mode: YoungMode
    let om: ObjectMemory
    let nursery: NurseryPointer
    /// Nurseries (the workers), and participant slots: the workers, the
    /// marker's (unused), the young collector's.
    let count: Int
    let participants: Int
    let collectorIndex: Int
    let hs: UnsafeMutablePointer<UnsafeMutablePointer<Handshake>>
    /// Incremented (under the mutex) by every round that some participant
    /// must acknowledge itself.
    let roundSerial: UnsafeMutablePointer<Atomic<UInt64>>
    /// Per nursery, read by any thread: a collection runs (the deletion
    /// barrier, resumers), H1 started, T1 started, its sequence number.
    let collecting: UnsafeMutablePointer<Atomic<Bool>>
    let afterH1: UnsafeMutablePointer<Atomic<Bool>>
    let afterT1: UnsafeMutablePointer<Atomic<Bool>>
    let done: UnsafeMutablePointer<Atomic<Bool>>
    let seq: UnsafeMutablePointer<Atomic<UInt64>>
    /// Y per nursery: eden lo, hi, survivor-from lo, hi (heap offsets).
    let ranges: UnsafeMutablePointer<Atomic<UInt64>>
    /// Process scan words, nursery-major: `seq` when the record's stack was
    /// scanned for that collection, `seq | scanningBit` while it is.
    let scanWords: UnsafeMutablePointer<Atomic<UInt64>>
    let scanWordsBytes: Int
    let recordCapacity: Int
    /// Per nursery: the record of the collection in flight (the opener
    /// writes it under the mutex, the collector reads it after).
    let inFlight: UnsafeMutablePointer<YoungRecord>
    /// Per participant: its collector work and its counters.
    let work: UnsafeMutablePointer<UnsafeMutablePointer<CollectorWork>>
    let counters: UnsafeMutablePointer<UnsafeMutablePointer<YoungWorkerCounters>>
    /// The collector thread's queue of nurseries (the safepoint mutex), its
    /// condition (waited on with the safepoint mutex), the thread.
    let queue: UnsafeMutablePointer<RawArray<Int>>
    let collectorCond: UnsafeMutablePointer<pthread_cond_t>
    let thread: UnsafeMutablePointer<YoungThread>
    let collectorWorker: WorkerPointer
    let shutdown: UnsafeMutablePointer<Atomic<Bool>>
    let collectorWaits: UnsafeMutablePointer<Atomic<UInt64>>
    let collectorMachThread: UnsafeMutablePointer<Atomic<UInt32>>
    /// The safepoint mutex.
    let log: UnsafeMutablePointer<YoungLog>
    /// Promotion by young collections (module 5's rate), relaxed atomics.
    let promotedBytes: UnsafeMutablePointer<Atomic<UInt64>>
    let promotedObjects: UnsafeMutablePointer<Atomic<UInt64>>
    let sampler: UnsafeMutablePointer<YoungSampler>
    let samplerLock: UnsafeMutablePointer<pthread_mutex_t>
    /// Test primitive 39 (`slowPeek:`): while the gate is nonzero the
    /// primitive waits inside its blocking region; it sets `peekHeld` once
    /// it holds its body pointer.
    let peekGate: UnsafeMutablePointer<Atomic<Int>>
    let peekHeld: UnsafeMutablePointer<Atomic<Int>>
    /// Test hook of the array copy's broken variant (`arrayCopyOrdering`
    /// off): called between the barrier's load and the delayed store.
    let copyWindow: UnsafeMutablePointer<EnterWindowHook>
}

typealias YoungPointer = UnsafeMutablePointer<YoungShared>

/// A scan word's bit while a stack is being scanned.
let scanningBit: UInt64 = 1 << 63

extension UnsafeMutablePointer where Pointee == YoungShared {
    @inline(__always)
    func handshake(_ k: Int) -> UnsafeMutablePointer<Handshake> { unsafe pointee.hs[k] }
    @inline(__always)
    func range(_ k: Int) -> UnsafeMutablePointer<Atomic<UInt64>> { unsafe pointee.ranges + k &* 4 }
    @inline(__always)
    func scanWord(_ k: Int, _ record: Int) -> UnsafeMutablePointer<Atomic<UInt64>> {
        unsafe pointee.scanWords + (k &* pointee.recordCapacity &+ record)
    }
    @inline(__always)
    func work(_ i: Int) -> UnsafeMutablePointer<CollectorWork> { unsafe pointee.work[i] }
    @inline(__always)
    func counters(_ i: Int) -> UnsafeMutablePointer<YoungWorkerCounters> { unsafe pointee.counters[i] }
    /// The nursery `k` collection is offloaded to the collector thread.
    @inline(__always)
    func isOffloaded(_ k: Int) -> Bool { unsafe pointee.mode == .offload && k == 0 }
}

/// Is `w` a round participant: a worker of the table, or the young
/// collector thread.
@inline(__always)
func isRoundParticipant(_ vm: VMPointer, _ w: WorkerPointer) -> Bool {
    guard unsafe vm.pointee.young != nil else { return false }
    let i = unsafe w.pointee.index
    let n = unsafe vm.pointee.workerCount
    return i < n || i == n &+ 1
}
