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
    /// The sweep stop, part 3: at the observed rate of entry consumption
    /// the table would fill within `safetyFactor` cycles (the last one's
    /// duration).
    case entryRate
    /// Allocation stalls: a background worker stalled with no cycle
    /// running and started one (docs/modules/allocation-stalls.md).
    case stall
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
    /// Module 10: chunks of large objects put back on the stack.
    var chunksSplit: UInt64 = 0
    var markCpuNs: UInt64 = 0
    var markWallNs: UInt64 = 0
    var markStartNs: UInt64 = 0
    var sweepNs: UInt64 = 0
    var sweepCpuNs: UInt64 = 0
    var entriesFreed: UInt64 = 0
    var bytesFreed: UInt64 = 0
    /// The sweep stop (docs/modules/sweep-stop.md): the snapshot entries
    /// this cycle's sweep has visited (live and dead), and the entries
    /// freed so far that a partial apply already handed to the allocators
    /// (taken off the old-entry estimate then, not again at the apply).
    var entriesVisited: UInt64 = 0
    var entriesPublished: UInt64 = 0
    /// Allocation stalls, part 1: this cycle's time parked in stops by
    /// phase (marking, the relocation pass, sweeping), and the relocation
    /// pass's wall and CPU time; `inRelocation` while the pass runs.
    var parkMarkNs: UInt64 = 0
    var parkRelocNs: UInt64 = 0
    var parkSweepNs: UInt64 = 0
    var relocWallNs: UInt64 = 0
    var relocCpuNs: UInt64 = 0
    var inRelocation = false
    /// Part 5's slowed marker: the thread CPU time at the last poll, and
    /// the polls that spun and their spun CPU time.
    var slowLastCpuNs: UInt64 = 0
    var slowSpins: UInt64 = 0
    var slowSpinNs: UInt64 = 0
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
    /// The sweep stop, part 3: entries consumed per second at the trigger
    /// (the sampler's rate) and the old-entry estimate then.
    var entryRate: Double = 0
    var oldEntriesAtStart: UInt64 = 0
    /// The final mark's pause (from its request: the time to safepoint and
    /// the work to the verifier's end) and its split.
    var finalPauseNs: UInt64 = 0
    var finalTtspNs: UInt64 = 0
    var drainNs: UInt64 = 0
    var drainedEntries: UInt64 = 0
    var filterNs: UInt64 = 0
    var ephemeronNs: UInt64 = 0
    var weakNs: UInt64 = 0
    var verifyNs: UInt64 = 0
    var ephemeronItems: UInt64 = 0
    /// The final mark on the devices: the units of tracing work the
    /// successful final mark's stop did (`finalWorkUnits`), the most any of
    /// this cycle's attempts did, and the attempts that gave up at the
    /// bound (`MarkingConfig.finalMarkWork`), for work or for an owed
    /// young-root scan.
    var finalWorkUnits: UInt64 = 0
    var finalWorkUnitsMax: UInt64 = 0
    var finalGiveUps: UInt64 = 0
    /// The final mark on the devices (docs/modules/final-mark.md): the
    /// stopper's wait before its request (module 7's open young
    /// collections, the world running) and the collections open then; the
    /// last parker and how it came, and how many came from a wait.
    var finalBeforeRequestNs: UInt64 = 0
    var finalCollectionsOpen = 0
    var finalSlowest = -1
    var finalSlowestVia = ParkVia.poll
    var finalParkedFromWaits = 0
    /// The stop's work from its start to the phase change, and the two
    /// parts after the verifier: module 6's selection and pins, and the
    /// sweep's setup.
    var finalWorkNs: UInt64 = 0
    var relocationAtFinalNs: UInt64 = 0
    var sweepSetupNs: UInt64 = 0
    /// The stopper: its QoS before the stop raised it, the thermal state,
    /// and its CPU by core type from just before the request to the end of
    /// the work (`CoreTime`; cycles over CPU time is its clock).
    var finalStopperQoS: UInt32 = 0
    var finalThermal: UInt8 = 0
    var finalStopperCore = CoreTime()
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
    /// Allocation stalls, part 1 (docs/modules/allocation-stalls.md): old
    /// space in blocks at the snapshot and when the cycle ended (applied or
    /// abandoned), the old-entry estimate then; bytes promoted while it ran
    /// (every nursery, and the main worker's alone); blocks the relocation
    /// freed; the marker's parked time by phase and its relocation pass;
    /// allocations that waited (or stalled) while it ran, and fallbacks.
    var blocksAtStart = 0
    var blocksAtEnd = 0
    var oldEntriesAtEnd: UInt64 = 0
    var promotedAtStart: UInt64 = 0
    var promotedMainAtStart: UInt64 = 0
    var promotedDuring: UInt64 = 0
    var promotedMainDuring: UInt64 = 0
    var relocFreedAtStart: UInt64 = 0
    var relocBlocksFreed: UInt64 = 0
    var parkMarkNs: UInt64 = 0
    var parkRelocNs: UInt64 = 0
    var parkSweepNs: UInt64 = 0
    var relocWallNs: UInt64 = 0
    var relocCpuNs: UInt64 = 0
    var waitsAtStart: UInt64 = 0
    var waits: UInt64 = 0
    var fallbacksAtStart: UInt64 = 0
    var fallbacks: UInt64 = 0
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
    /// Module 10: chunks of large objects the marker put back on its stack
    /// (a large object's scan split at `MarkChunk.slots`).
    var chunksSplit: UInt64 = 0
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
    /// Part 5's slowed marker: polls that spun and the CPU they spun.
    var markerSlowSpins: UInt64 = 0
    var markerSlowSpinNs: UInt64 = 0
    var qosEscalations: UInt64 = 0
    var qosLowerings: UInt64 = 0
    /// Returns from the marker's untimed wait, and the waits.
    var markerWaits: UInt64 = 0
    /// At the last trigger decision: promotion rate and predicted time to
    /// fill.
    var lastPromotionBytesPerSecond: Double = 0
    var lastPredictedFillNs: UInt64 = 0
    /// Large bytes, part 2: fallbacks by what ran out (the young allocation
    /// found the entry table empty; a collection left old space past its
    /// soft limit; an old allocation found no room under the limit or no
    /// run of its length).
    var fallbacksEntries: UInt64 = 0
    var fallbacksOldAllocation: UInt64 = 0
    /// Allocation stalls (docs/modules/allocation-stalls.md): fallbacks
    /// for a background worker's promotion after a justified stall, for
    /// promotion that found no block (the reserve's fallback: objects kept
    /// in place), and for a failed final-mark verifier; and the fallbacks
    /// by who asked: the main worker, a background worker whose stall a
    /// cycle justified, an operation in a stop or the host, a VM with no
    /// marker thread to wait for, and none of these (`unjustified`: 0 in
    /// every test and row, a verifier failure in checked builds).
    var fallbacksPromotion: UInt64 = 0
    /// Soft-limit crossings that asked for a full collection: only with no
    /// collector to wait for (no marker thread, `noStalls`).
    var fallbacksSoftLimit: UInt64 = 0
    var fallbacksReserve: UInt64 = 0
    var fallbacksByMain: UInt64 = 0
    var fallbacksByStall: UInt64 = 0
    var fallbacksInStop: UInt64 = 0
    var fallbacksNoMarker: UInt64 = 0
    var unjustifiedFallbacks: UInt64 = 0
    /// Justified stalls whose fallback found the resource there in its stop
    /// (another worker's had run): no full collection.
    var fallbacksAvoided: UInt64 = 0
    /// Large bytes, part 2: stops in which the young allocation found the
    /// entry table empty, or an old allocation found no room, while a cycle
    /// swept, and the sweep was finished and applied there instead of a
    /// full collection; the time of both kinds.
    var sweepsFinishedForEntries: UInt64 = 0
    var sweepsFinishedForOld: UInt64 = 0
    var sweepsFinishedForEntriesNs: UInt64 = 0
    /// The final mark on the devices: final marks that gave up at the work
    /// bound (or found a young-root scan owed) and released the world with
    /// marking still on, and those that finished past the bound because a
    /// cycle had given up `finalMarkGiveUps` times already.
    var finalGiveUps: UInt64 = 0
    var finalOverruns: UInt64 = 0
    /// The sweep stop (docs/modules/sweep-stop.md): stops that finished a
    /// sweep for entries or old space (`sweepsFinishedForEntries` and
    /// `ForOld` count them as before), by outcome: the sweep reached its end
    /// inside the bound and was applied whole; it was bounded and only what
    /// was swept was handed over (a partial apply); it ran to its end past
    /// any bound (the old behaviour: the test switch, the main worker's old
    /// allocation, a background worker whose wait for the sweep ran out).
    /// Relocation passes the bounded stop cut off, and old allocations that
    /// stalled for the collector are in `StallLog` (allocation stalls).
    var sweepStops: UInt64 = 0
    var sweepStopsWhole: UInt64 = 0
    var sweepStopsPartial: UInt64 = 0
    var sweepStopsUnbounded: UInt64 = 0
    var sweepStopRelocCutOffs: UInt64 = 0
    /// Part 3: cycles the entry-rate rule started (`byEntryRate`; also in
    /// `cycles`). Its raises are a VM counter (`entryRateRaises`): they
    /// are decided between stops.
    var cyclesByEntryRate: UInt64 = 0
    /// Allocation stalls: cycles a stalled worker started (none running).
    var cyclesByStall: UInt64 = 0
}

/// What a sweep stop found and did.
enum SweepStopOutcome: UInt8, Sendable {
    /// No sweep was pending: the caller falls back.
    case none
    /// The sweep reached its end (or had) and was applied whole.
    case whole
    /// Bounded: what was swept was handed to the allocators; the rest is
    /// swept with the world running.
    case partial
    /// Swept to the end past the bound, and applied.
    case unbounded
}

/// The sweep stop (docs/modules/sweep-stop.md, part 1): the circumstances
/// of one stop that finished or bounded a lazy sweep because the entry
/// table was empty or an old allocation found no room. ns.
struct SweepStopRecord: Sendable {
    var cause = FullCause.entries
    var phase = MarkingPhase.sweeping
    var outcome = SweepStopOutcome.none
    /// The requester's worker index (0 the main worker; -1 outside the table).
    var requester = -1
    /// How far the sweep had got when the stop began: snapshot words
    /// swept of all, entries visited and freed (by the marker and any
    /// earlier stop), entries already handed over, runs pending, and the
    /// snapshot's entries (so the entries still to visit follow).
    var cursorWords = 0
    var totalWords = 0
    var entriesVisited: UInt64 = 0
    var entriesFreed: UInt64 = 0
    var entriesPublished: UInt64 = 0
    var pendingRuns = 0
    var snapshotEntries: UInt64 = 0
    /// Since the sweep could start (its final mark's end), and the marker's
    /// QoS and the policy's wish then.
    var sinceSweepStartNs: UInt64 = 0
    var markerQoS: UInt32 = 0
    var wantUserInitiated = false
    /// The table and old space when the stop began.
    var entryCapacity: UInt64 = 0
    var highWater: UInt64 = 0
    var oldEntries: UInt64 = 0
    var blocksInUse = 0
    var softLimitBlocks = 0
    /// The stop's work: words swept and entries freed inside it, its
    /// sweeping, and its apply (whole) or hand-over (partial); entries handed
    /// to the allocators by it; whether it cut a relocation pass off.
    var wordsInStop = 0
    var entriesFreedInStop: UInt64 = 0
    var sweepNs: UInt64 = 0
    var applyNs: UInt64 = 0
    var entriesHanded: UInt64 = 0
    var relocationCutOff = false
}

/// Large bytes, part 2: the circumstances of one fallback, taken in its
/// stop before the full collection runs.
struct FallbackRecord: Sendable {
    var cause = FullCause.other
    var phase = MarkingPhase.idle
    /// The current cycle's trigger and how long ago it started (ns; 0 when
    /// no cycle runs).
    var trigger: CycleTrigger? = nil
    var sinceCycleStartNs: UInt64 = 0
    /// Since the last cycle's apply (0: none yet), and cycles started.
    var sinceLastApplyNs: UInt64 = 0
    var cyclesStarted: UInt64 = 0
    /// The sweep's progress over the snapshot's words (0 to 1; 0 before it
    /// starts), and the objects marked so far.
    var sweptFraction = 0.0
    var markedObjects: UInt64 = 0
    /// Entries: the table's capacity and high water, free runs in the pool
    /// and runs the sweep holds pending, the old-entry estimate.
    var entryCapacity: UInt64 = 0
    var highWater: UInt64 = 0
    var poolRuns = 0
    var pendingRuns = 0
    var oldEntries: UInt64 = 0
    /// Old space: blocks in use and the soft limit.
    var blocksInUse = 0
    var softLimitBlocks = 0
    /// The marker's QoS class now and whether the policy wants it raised.
    var markerQoS: UInt32 = 0
    var wantUserInitiated = false
    /// An old allocation's failure: 1 the limit, 2 no run of its length.
    var largeFailure: UInt8 = 0
    /// Allocation stalls: who asked (and the worker, -1 for none), the
    /// cycle that justified a background worker's fallback (its number;
    /// 0 none) and how long that worker had stalled.
    var requester = FallbackRequester.inStop
    var worker = -1
    var justifyingCycle: UInt64 = 0
    var stalledNs: UInt64 = 0
    /// The justifying cycle's marked (live) bytes: against the blocks in
    /// use they tell a full heap from a fragmented one.
    var justifyingMarkedBytes: UInt64 = 0
    /// What justified it (a requester `stall`).
    var justifiedBy = StallJustification.none
}

/// Allocation stalls: who a fallback is for. Every value but `background`
/// is justified (docs/modules/allocation-stalls.md "The fallback stays").
enum FallbackRequester: UInt8, Sendable {
    /// The main worker, exempt from stalls (the owner, 2026-11-09).
    case main
    /// A background worker whose stall a cycle begun after it justified.
    case stall
    /// An operation in a stop, the host, a stress flag, the marker's
    /// failed verifier.
    case inStop
    /// No marker thread to wait for (tests that drive marking by hand).
    case noMarker
    /// A background worker with no justifying cycle: the bug the counter
    /// `unjustifiedFallbacks` exists for.
    case background
}

/// Allocation stalls: the resource a background worker stalled for.
enum StallResource: UInt8, Sendable {
    /// Blocks for a young collection's promotion (module 7's promise, or
    /// module 4's scavenge under `young=stw`).
    case promotion
    /// Entries: the worker's stash is empty and the table has none.
    case entries
    /// Room under the soft limit, or a run of blocks, for an old (large)
    /// allocation.
    case old
}

/// Allocation stalls: what justified a stall's fallback.
enum StallJustification: UInt8, Sendable {
    case none
    /// A cycle begun after the stall began completed and was applied.
    case cycle
    /// A full collection ran meanwhile (another's fallback or request, an
    /// old-space operation): it abandoned the cycle and collected all there
    /// was; the resource is still missing (a full heap).
    case fullCollection
    /// The stop-the-world young mode: no cycle could start, its scavenge
    /// having no room for one young generation below the hard limit.
    case noCycleCanStart
    /// The stop-the-world young mode: the scavenge that starts a cycle for
    /// the stall kept objects (the reserve's fallback).
    case cycleStart
}

/// Allocation stalls: how a stall ended.
enum StallOutcome: UInt8, Sendable {
    /// The collector's progress made the resource available.
    case available
    /// A cycle whose snapshot was taken after the stall began completed and
    /// was applied, and the resource is still not there: the caller falls
    /// back (justified).
    case justified
}

/// One stall: the worker, the resource, how it ended, its time, the cycles
/// applied while it waited, and whether it had to start one.
struct StallRecord: Sendable {
    var worker = 0
    var resource = StallResource.promotion
    var outcome = StallOutcome.available
    var ns: UInt64 = 0
    var applies: UInt64 = 0
    var startedCycles = 0
}

/// Allocation stalls: one resource's tally.
struct StallTally: Sendable {
    var count: UInt64 = 0
    var ns: UInt64 = 0
    var maxNs: UInt64 = 0
    var justified: UInt64 = 0
}

/// Allocation stalls: every stall so far (under the waits lock): the tally
/// by resource, per worker, the last records for percentiles, the stalls
/// in progress, the cycles stalls started, the marker's QoS overrides.
struct StallLog {
    var promotion = StallTally()
    var entries = StallTally()
    var old = StallTally()
    var records: RecordRing<StallRecord>
    var byWorkerCount: [UInt64]
    var byWorkerNs: [UInt64]
    /// Each worker's last stall's time (the fallback record's).
    var lastNs: [UInt64]
    /// The cycle each worker's justified stall began in (its `cycleNow`
    /// then; `.max`: a justification that names no cycle, a cycle-start
    /// scavenge's or one with no cycle able to start). A fallback for that
    /// worker is justified only by a cycle numbered above it.
    var beganAt: [UInt64]
    /// What justified each worker's stall (`StallJustification`).
    var justifiedBy: [StallJustification]
    /// A background worker whose stall was justified, until its
    /// allocation ends: its fallbacks are justified.
    var justified: [Bool]
    var stalledNow = 0
    var cyclesStarted: UInt64 = 0
    var markerOverrides: UInt64 = 0

    init(workers: Int, capacity: Int) {
        records = RecordRing(capacity: capacity)
        byWorkerCount = Array(repeating: 0, count: workers)
        byWorkerNs = Array(repeating: 0, count: workers)
        lastNs = Array(repeating: 0, count: workers)
        beganAt = Array(repeating: 0, count: workers)
        justifiedBy = Array(repeating: .none, count: workers)
        justified = Array(repeating: false, count: workers)
    }

    var all: StallTally {
        var t = StallTally()
        for x in [promotion, entries, old] {
            t.count &+= x.count
            t.ns &+= x.ns
            t.maxNs = Swift.max(t.maxNs, x.maxNs)
            t.justified &+= x.justified
        }
        return t
    }

    mutating func note(_ r: StallRecord) {
        func add(_ t: inout StallTally) {
            t.count &+= 1
            t.ns &+= r.ns
            t.maxNs = Swift.max(t.maxNs, r.ns)
            if r.outcome == .justified { t.justified &+= 1 }
        }
        switch r.resource {
        case .promotion: add(&promotion)
        case .entries: add(&entries)
        case .old: add(&old)
        }
        if r.worker >= 0 && r.worker < byWorkerCount.count {
            byWorkerCount[r.worker] &+= 1
            byWorkerNs[r.worker] &+= r.ns
            lastNs[r.worker] = r.ns
        }
        records.append(r)
    }
}

/// What module 5's report sums, averages or takes the maximum of over
/// every cycle (the ring keeps the last ones only).
struct CycleTotals: Sendable {
    var cycles: UInt64 = 0
    var completed: UInt64 = 0
    var markCpuNs: UInt64 = 0
    var markWallNs: UInt64 = 0
    var sweepNs: UInt64 = 0
    var durationNs: UInt64 = 0
    var markedBytes: UInt64 = 0
    var bytesFreed: UInt64 = 0
    /// The initial mark's addition to its scavenge, the longest.
    var imAddMaxNs: UInt64 = 0
    var dropped: UInt64 = 0
}

/// Written with the world stopped only.
struct MarkingLog {
    var counters = MarkingCounters()
    /// The last `VMConfig.logCapacity` cycles, the current one last.
    var records: RecordRing<CycleRecord>
    var totals = CycleTotals()
    /// The current cycle's record (its sequence number in `records`), -1
    /// when none.
    var current = -1
    var startNs: UInt64 = 0
    /// Promotion over the last scavenges: (time, cumulative promoted bytes).
    var samples: [(ns: UInt64, promoted: UInt64)] = []
    /// The sweep stop, part 3: entries consumed (objects promoted and old
    /// allocations, cumulative) at the same scavenges.
    var entrySamples: [(ns: UInt64, entries: UInt64)] = []
    var lastCycleNs: UInt64 = 0
    /// The last completed cycle's sweep, from its final mark's end to its
    /// apply (ns, 0: none yet).
    var lastSweepNs: UInt64 = 0
    /// When the current cycle's sweep could start (its final mark's end; 0
    /// before). In the log, not the marker's state: participants read it
    /// between stops (the entry-rate rule).
    var sweepStartNs: UInt64 = 0
    /// Old entries, estimated: promoted objects and old allocations since
    /// the last scavenge added, a sweep's frees taken off, recounted from
    /// the old map after module 1 collected. With the module 1 collection
    /// count and the cumulative counts at the last sample.
    var oldEntries: UInt64 = 0
    var lastCollections: UInt64 = .max
    var lastPromotedObjects: UInt64 = 0

    init(logCapacity: Int) { records = RecordRing(capacity: logCapacity) }

    /// A cycle starts (its initial mark): its record is the current one.
    mutating func begin(_ r: CycleRecord) {
        records.append(r)
        current = Int(truncatingIfNeeded: records.total &- 1)
        totals.cycles &+= 1
        totals.imAddMaxNs = Swift.max(totals.imAddMaxNs, r.snapshotNs &+ r.rootsNs &+ r.survivorsNs)
        totals.dropped = records.dropped
    }

    /// The current cycle's record (nil when none, or dropped).
    var currentRecord: CycleRecord? {
        get { current < 0 ? nil : records.record(UInt64(current)) }
        set {
            guard let v = newValue, current >= 0 else { return }
            records.update(UInt64(current)) { $0 = v }
        }
    }

    /// The current cycle completed (its apply): its record, and the totals.
    mutating func complete(_ r: CycleRecord) {
        currentRecord = r
        totals.completed &+= 1
        totals.markCpuNs &+= r.markCpuNs
        totals.markWallNs &+= r.markWallNs
        totals.sweepNs &+= r.sweepNs
        totals.durationNs &+= r.durationNs
        totals.markedBytes &+= r.markedBytes
        totals.bytesFreed &+= r.bytesFreed
    }
    var lastOldAllocations: UInt64 = 0
    /// Large bytes, part 2: when the last apply ended (ns, 0: none yet).
    var lastApplyAtNs: UInt64 = 0
    /// Allocation stalls: the number of the last cycle applied (0: none),
    /// written in the apply's stop; a stall begun at cycle c is justified
    /// once this passes c.
    var lastAppliedCycle: UInt64 = 0
    /// Large bytes, part 2: the last fallbacks' circumstances.
    var fallbackRecords = RecordRing<FallbackRecord>(capacity: 16)
    /// The sweep stop: the last sweep stops' records.
    var sweepStopRecords = RecordRing<SweepStopRecord>(capacity: 64)
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
    /// Allocation stalls: every stall (docs/modules/allocation-stalls.md),
    /// under its own lock beside it (the large-bytes follow-up's bounded
    /// waits, which it replaces, kept their tally under the same lock).
    let stalls: UnsafeMutablePointer<StallLog>
    let waitsLock: UnsafeMutablePointer<pthread_mutex_t>
    /// Large bytes: the marker thread's QoS as it last set it, for readers
    /// on other threads (the fallback record); the marker's own `qos` is
    /// written outside stops.
    let qosNow: UnsafeMutablePointer<Atomic<UInt32>>
    /// The VM is shutting down: the marker abandons its work at its next poll.
    let stopping: UnsafeMutablePointer<Atomic<Bool>>
    /// The marker thread (the host starts and joins it) and its Mach port.
    let thread: UnsafeMutablePointer<MarkerThread>
    let machThread: UnsafeMutablePointer<Atomic<UInt32>>
    /// The VM-wide barrier word (module 3's flag line, word 2).
    let barrier: UnsafeMutablePointer<Atomic<UInt32>>
    /// The final mark on the devices: each nursery's young-root scan for
    /// the current cycle (`RootScanState`), the ranges the initial mark
    /// recorded for it (four words: eden start and top, survivor-from start
    /// and top), and the scans' counters (`RootScanStat`), all read and
    /// written outside stops. `rootScanCount` nurseries (0 without module 7).
    let rootScans: UnsafeMutablePointer<Atomic<UInt8>>
    let rootScanRanges: UnsafeMutablePointer<UInt64>
    let rootScanCount: Int
    let rootScanStats: UnsafeMutablePointer<Atomic<UInt64>>
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
/// old-space marking (the SATB barrier and the weak keep-alive). Bits 1 and
/// up: module 7's count, 2 per open young collection and 2 for the VM
/// under the young stress flag `barrierAlwaysOn`. The fast path tests the
/// whole word. Marking sets and clears bit 0 only, with an atomic or and
/// and (it used to store the whole word, erasing the count: collectors
/// review, finding 4); module 7 adds and subtracts 2. The stop verifier
/// checks both halves at every stop (`verifyBarrierWordLocked`).
@_transparent
func barrierWord(_ flag: UnsafeMutablePointer<Atomic<UInt32>>) -> UnsafeMutablePointer<Atomic<UInt32>> {
    unsafe flag + 2
}

enum BarrierBits {
    static let marking: UInt32 = 1
}

/// Marking's bit of the barrier word on (a stop, or the VM's install).
@inline(__always)
func markingBarrierOn(_ mk: MarkingPointer) {
    unsafe mk.pointee.barrier.pointee.bitwiseOr(BarrierBits.marking, ordering: .relaxed)
}

/// Marking's bit of the barrier word off (a stop, or the VM's end).
@inline(__always)
func markingBarrierOff(_ mk: MarkingPointer) {
    unsafe mk.pointee.barrier.pointee.bitwiseAnd(~BarrierBits.marking, ordering: .relaxed)
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
