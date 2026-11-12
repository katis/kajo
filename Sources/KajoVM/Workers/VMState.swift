import Darwin
import Synchronization

/// The VM: one struct reached through a pointer, holding pointers to the
/// object memory, the worker table and one separately allocated sub-state
/// per lock, each lock beside (never inside) what it guards (AGENTS.md).
/// No global mutable state.
@unsafe struct VMState {
    let om: ObjectMemory
    let image: Image
    let config: VMConfig
    let nilObject: Oop
    /// Workers: 0 is the main worker, 1...background the background
    /// workers, the last one the host's (used by host calls under
    /// `hostLock`; it never runs a Process).
    let workers: UnsafeMutablePointer<WorkerPointer>
    let workerCount: Int

    // Safepoints: the flag every poll reads, the state, its mutex and cond.
    let flag: UnsafeMutablePointer<Atomic<UInt32>>
    let safepoint: UnsafeMutablePointer<SafepointState>
    let safepointLock: UnsafeMutablePointer<pthread_mutex_t>
    let safepointCond: UnsafeMutablePointer<pthread_cond_t>

    // The scheduler: queues, records, Semaphore lists and Process states
    // are guarded by `schedLock`. Idle background workers wait on
    // `schedCond`; the host waits for the last termination on `doneCond`.
    let sched: UnsafeMutablePointer<SchedulerState>
    let queues: UnsafeMutablePointer<UInt64>
    let records: UnsafeMutablePointer<ProcessRecord>
    let schedLock: UnsafeMutablePointer<pthread_mutex_t>
    let schedCond: UnsafeMutablePointer<pthread_cond_t>
    let doneCond: UnsafeMutablePointer<pthread_cond_t>

    // External signals: the MPSC stack head (own cache line), the pending
    // roots and their mutex.
    let externalHead: UnsafeMutablePointer<Atomic<UInt>>
    let pending: UnsafeMutablePointer<PendingState>
    let pendingSlots: UnsafeMutablePointer<UInt64>
    let pendingNext: UnsafeMutablePointer<Int>
    /// The review fixes (item 2): 1 where the pending root is an object a
    /// polled primitive is still building (a long ByteArray being zeroed,
    /// a String being filled), which the instance walks skip. Under
    /// `pendingLock`, beside `pendingSlots`.
    let pendingBuilding: UnsafeMutablePointer<UInt8>
    let pendingLock: UnsafeMutablePointer<pthread_mutex_t>

    /// Host calls use the host worker one at a time.
    let hostLock: UnsafeMutablePointer<pthread_mutex_t>
    /// Per-worker words other threads read: terminate requests (the
    /// record index + 1 to terminate), the QoS a thread got, its Mach
    /// thread port. One 128-byte line per worker, then one for module 5's
    /// marker worker and one for module 7's young collector.
    let workerShared: UnsafeMutableRawPointer
    /// Errors that terminated Processes, by Process id (own mutex).
    let errors: UnsafeMutablePointer<ErrorLog>
    let errorsLock: UnsafeMutablePointer<pthread_mutex_t>

    let counters: UnsafeMutablePointer<Atomic<UInt64>>
    /// The finalization Semaphore (ADR 0009 section 1), rooted in the
    /// pending-root table. Under `pendingLock`.
    let finalization: UnsafeMutablePointer<FinalizationState>
    var hooks = unsafe VMHooks()
    /// Module 4: the nurseries, nil when they are off.
    var nursery: NurseryPointer? = nil
    /// Module 5: concurrent marking, nil when it is off (or no nursery).
    var marking: MarkingPointer? = nil
    /// Module 6: concurrent relocation, nil when it is off (or no marking).
    var relocation: RelocationPointer? = nil
    /// Modules 6 and 7: the global epoch E (incremented with seq_cst when
    /// memory waits for every participant to pass a safepoint), the count
    /// of hazard slots held in every worker, and the tests' enter-window
    /// hook. Each in its own line.
    let epoch: UnsafeMutablePointer<Atomic<UInt64>>
    let hazardsHeld: UnsafeMutablePointer<Atomic<Int>>
    let enterWindow: UnsafeMutablePointer<EnterWindowHook>
    /// Epoch words are kept (relocation or young collection without
    /// stopping the world is installed). Set before any thread starts.
    var epochsOn = false
    /// Module 7: young collection without stopping the world, nil in the
    /// stop-the-world configuration.
    var young: YoungPointer? = nil
    /// Module 8c: a save holds the scheduler (`SchedulerState.saveHold`,
    /// mirrored here for the poll slow path, which reads it without the
    /// lock); the slow polls counted for `VMConfig.snapshotAtPoll`; the
    /// images saved for the host. Each in its own line.
    let saveHold: UnsafeMutablePointer<Atomic<Bool>>
    let slowPolls: UnsafeMutablePointer<Atomic<Int>>
    let savedImages: SavedImages
    /// AOT 1: the bound native module (Native/NativeBinding.swift), nil
    /// when none is.
    var native: UnsafeMutablePointer<NativeBinding>? = nil
}

/// Read by other threads: atomics only, one line per worker.
struct WorkerShared: ~Copyable {
    /// Record index + 1 of a Process to terminate at the next budget check.
    let attention = Atomic<Int>(0)
    let qos = Atomic<UInt32>(0)
    let machThread = Atomic<UInt32>(0)
    let started = Atomic<Bool>(false)
    /// Module 6: the two hazard slots (an oop a primitive holds a body
    /// pointer of, 0 when free) and the epoch word (the global epoch as
    /// this worker last saw it at a point where it held no body pointer;
    /// 0 while entering the VM; `quiescentEpoch` outside it).
    let hazard0 = Atomic<UInt64>(0)
    let hazard1 = Atomic<UInt64>(0)
    let epoch = Atomic<UInt64>(quiescentEpoch)
}

/// Guarded by the safepoint mutex.
@unsafe struct SafepointState {
    /// Workers inside the VM.
    var active = 0
    /// Active workers waiting at a safepoint for the current stop.
    var parked = 0
    var requested = false
    /// Bumped when a stop releases the world.
    var epoch: UInt64 = 0
    /// Allocation stalls: the collector's progress, bumped (with a
    /// broadcast of the safepoint condition) whenever a stop releases the
    /// world and whenever blocks are freed outside a stop (module 6's
    /// epoch frees). A stalled worker waits for it to change.
    var progress: UInt64 = 0
    /// Returns from a park: the stop verifier checks none happens while a
    /// stop's work runs.
    var wakeups: UInt64 = 0
    /// The worker that parked last: the slowest participant of a stop.
    var lastParker = -1
    /// One line per stop.
    var stops: UnsafeMutablePointer<StopRecord>
    var stopCount = 0
    static let stopLog = 1 << 16
    /// Module 4: a parallel phase of the current stop's work (a scavenge).
    /// Parked workers join while it is open: `parts[0..<joined]` are the
    /// participants (the stopper first), `done` counts the ones finished.
    var phaseOpen = false
    var phaseSeq: UInt64 = 0
    var joined = 0
    var done = 0
    var parts: UnsafeMutablePointer<Int>
    /// The worker running the current stop's work (-1 outside a stop).
    var stopper = -1
    /// What the current stop does (`StopKind`), for its record.
    var kind = StopKind.other
    /// Module 7: per participant (the workers, then the marker's and the
    /// young collector's slots): inside the VM, and inside a blocking
    /// region (acknowledged by proxy, its stack scanned by the opener).
    var inside: UnsafeMutablePointer<Bool>
    var blocking: UnsafeMutablePointer<Bool>
    /// Module 7: stop requesters waiting for every young collection to end
    /// (no collection opens while nonzero), and the collections open.
    var stwWanted = 0
    var ycActive = 0
    /// The final mark on the devices: the main worker opened a collection
    /// while a stop was wanted (it may open one; cleared at the request).
    var mainOpenedWhileWanted = false
    /// The final mark on the devices: how the last parker reached its park
    /// (`ParkVia`), and how many of the current stop's parkers came from a
    /// wait inside the VM rather than a poll.
    var lastParkerVia = ParkVia.poll
    var parkedFromWaits = 0
    /// The `pointersTo:` follow-up: slots the current stop's walk compared
    /// (primitives 169 and 170), for its record.
    var words: UInt64 = 0
}

/// The final mark on the devices: where a parker was when the stop found it.
enum ParkVia: UInt8, Sendable {
    /// At a poll (it was running Smalltalk or a long primitive).
    case poll
    /// In a wait inside the VM (`waitServicing`: an eden wait, an opener's
    /// wait, a round's wait): it had to be woken and scheduled to park.
    case wait
    /// Another stopper that found this stop requested first.
    case stopper
}

/// What a stop did, in its record.
enum StopKind: UInt8, Sendable {
    case other
    case scavenge
    case full
    /// Module 5: a final mark, and a sweep's apply in a stop of its own.
    case finalMark
    case apply
    /// Module 7: an initial mark without a scavenge, the young verifier.
    case initialMark
    case verify
    /// The sweep stop (docs/modules/sweep-stop.md): an allocation found the
    /// entry table empty, or an old allocation found no room, while a
    /// cycle swept; the sweep is bounded or finished and applied here.
    case sweep
    /// The discoverability follow-up: primitives 167 and 168 walk old space
    /// for instances (ObjectModel/InstancePrimitives.swift).
    case instances
}

struct StopRecord: Sendable {
    /// From the request to every active worker parked.
    var timeToSafepointNs: UInt64
    /// From the request to the release: what the world stands still for.
    var pauseNs: UInt64
    /// The worker that parked last (-1: none had to).
    var slowest: Int
    var requester: Int
    var kind = StopKind.other
    /// Module 8b: when the stop was requested (uptime ns), for the `gc` events.
    var atNs: UInt64 = 0
    /// The final mark on the devices (docs/modules/final-mark.md): the
    /// stopper's wait before its request (other stops it parked for, and
    /// module 7's wait for every open young collection, during which the
    /// world runs and no collection opens), with the collections open when
    /// it began. Before this follow-up `timeToSafepointNs` and `pauseNs`
    /// counted from the start of that wait.
    var beforeRequestNs: UInt64 = 0
    var collectionsOpen = 0
    /// How the last parker came, and how many came from a wait.
    var slowestVia = ParkVia.poll
    var parkedFromWaits = 0
    /// The `pointersTo:` follow-up: the slots a pointer walk compared in
    /// this stop (0 for every other stop).
    var words: UInt64 = 0
}

/// Guarded by the scheduler lock.
struct SchedulerState {
    var idleWorkers = 0
    var shutdown = false
    var liveProcesses = 0
    var nextId: Int64 = 1
    var recordFree = -1
    var recordHighWater = 0
    /// The last `VMConfig.logCapacity` hops' latencies to the main worker.
    var hopLatencies = RecordRing<UInt64>(capacity: 1 << 16)
    /// Module 8b: the id of the Process the host waits for, and whether it
    /// has terminated.
    var watchedId: Int64 = -1
    var watchedDone = false
    /// Module 8c: a save is in progress: no Process is dequeued, and a
    /// running one leaves its worker at its next poll.
    var saveHold = false
}

/// A Process's native record (fixed table, free list under the scheduler
/// lock). The Process oop is a root while the record is live.
@unsafe struct ProcessRecord {
    var process = Oop.none
    var base: UnsafeMutablePointer<UInt64>? = nil
    var end: UnsafeMutablePointer<UInt64>? = nil
    /// The worker running it, -1 when none.
    var runningOn = -1
    /// Mach ticks when it became ready from a wait or creation; 0 when it
    /// waits. The stuck check reads it.
    var runnableSince: UInt64 = 0
    /// Mach ticks when it hopped to main; 0 otherwise.
    var hopStart: UInt64 = 0
    var stuckReported = false
    var terminateRequested = false
    var nextFree = -1
    /// Module 9b: an interrupt to run when the Process is next resumed
    /// (`InterruptKind`), 0 for none. Written under the scheduler lock; the
    /// dequeue hands it to the worker that resumes the Process.
    var interrupt = 0
    /// Module 9b: stepping (`StepMode`), and the header index of the frame
    /// it steps; read and written only by the worker running the Process
    /// (the Process itself sets it, primitive 158, and its polls read it).
    var stepMode = 0
    var stepFrame = 0
    var stepFresh = false
    /// The review fixes (item 3): the length of the `wait` send a waiting
    /// Process is suspended after (its saved pc ends it), so a debug stop
    /// asked while it waits rewinds to the send and proceeding waits
    /// again. Written under the scheduler lock when it starts waiting.
    var waitSendLength = 0
}

/// Guarded by the pending-root mutex.
struct FinalizationState {
    var semaphore = Oop.none
    var handle = -1
}

/// Guarded by the pending-root mutex.
struct PendingState {
    var free = -1
    var highWater = 0
    var count = 0
}

/// Guarded by its own mutex.
struct ErrorLog {
    var byProcess: [Int64: VMError] = [:]
}

/// VM-wide counters, relaxed atomics (none is on the hot path).
enum Counter: Int, CaseIterable {
    case forks, terminations, yields, waits, signals, preemptions, hops, detaches
    case externalSignals, staleExternalSignals, externalDrains, stackOverflows, processErrors
    case stops, stopNs, timeToSafepointNs, parkNs, enterWaitNs, leaveWaitNs
    /// The final mark on the devices: stoppers' waits before their request
    /// (for another stop, for module 7's open young collections).
    case stopRequestWaitNs
    case schedLocks, schedContended, schedWaitNs, pendingContended, safepointContended
    case idleWaits, idleWakeups, idleNs, slices, stuckReports, terminateRequests
    case stopVerifierFailures, scheduleVerifierFailures, perturbations
    /// Module 7: stops whose stopper (outside the worker table) was raised
    /// to user-initiated for the stop.
    case stopperQoSRaises
    /// Allocation stalls: fallbacks no rule justified (a verifier failure
    /// in checked builds; docs/modules/allocation-stalls.md).
    case unjustifiedFallbacks
    /// Module 8: Process stacks copied into a segment twice the size.
    case stackGrowths
    /// Module 8b: events emitted by primitive 140.
    case events
    /// Module 8c: images saved with their Processes, saves refused (another
    /// in progress, or the heap full), stops that found a Process still
    /// running and tried again, the time of the saves' work in their stops,
    /// Processes that left a worker at a poll because a save held the
    /// scheduler, and Processes resumed from an image.
    case snapshots, snapshotsRefused, snapshotRetries, snapshotNs, holdPreemptions, processesResumed
    /// Module 9a: view primitives that reached the view host on main, that
    /// hopped there, shell events taken by the kernel's event loop, handle
    /// releases.
    case viewCalls, viewHops, shellEvents, viewReleases
    /// Module 9b: interrupts asked (primitive 155) and run, step stops,
    /// sends re-executed (primitive 156), protocol requests taken and
    /// replies emitted.
    case interruptsAsked, interrupts, stepStops, resends, protocolRequests, protocolReplies
    /// Module 9c: calls of the protocol client's transport (primitive 164).
    case clientCalls
    /// Large bytes, part 2: a young collection decided that a marking cycle
    /// starts and no initial mark followed (its stop parked for another,
    /// or the pause found a cycle running or a full collection due); a
    /// large allocation decided it and found the pending table full.
    case triggersNotStarted, largeTriggersUnrooted
    /// The sweep stop, part 3: young collections at which the entry-rate
    /// rule asked for the marker to be raised (the table would empty at
    /// the observed rate before the running cycle ends).
    case entryRateRaises
    /// The review fixes (item 2): a long ByteArray's zeroing that found its
    /// object's length or body changed after a poll and stopped.
    case zeroingCutOff
    /// The review fixes (item 24): saves refused because a Process had an
    /// interrupt or a terminate request still to run.
    case snapshotsRefusedPending
}

/// A snapshot of the counters.
struct VMCounters: Sendable {
    private let values: [UInt64]
    init(_ values: [UInt64]) { self.values = values }
    subscript(_ c: Counter) -> UInt64 { values[c.rawValue] }

    var forks: UInt64 { self[.forks] }
    var terminations: UInt64 { self[.terminations] }
    var yields: UInt64 { self[.yields] }
    var waits: UInt64 { self[.waits] }
    var signals: UInt64 { self[.signals] }
    var preemptions: UInt64 { self[.preemptions] }
    var hops: UInt64 { self[.hops] }
    var detaches: UInt64 { self[.detaches] }
    var externalSignals: UInt64 { self[.externalSignals] }
    var staleExternalSignals: UInt64 { self[.staleExternalSignals] }
    var stackOverflows: UInt64 { self[.stackOverflows] }
    var stackGrowths: UInt64 { self[.stackGrowths] }
    var processErrors: UInt64 { self[.processErrors] }
    var stops: UInt64 { self[.stops] }
    var idleWakeups: UInt64 { self[.idleWakeups] }
    var stuckReports: UInt64 { self[.stuckReports] }
    var stopVerifierFailures: UInt64 { self[.stopVerifierFailures] }
    var scheduleVerifierFailures: UInt64 { self[.scheduleVerifierFailures] }

    var named: [(name: String, value: UInt64)] {
        Counter.allCases.map { ("\($0)", values[$0.rawValue]) }
    }
}

extension UnsafeMutablePointer where Pointee == VMState {
    @inline(__always)
    func count(_ c: Counter, _ n: UInt64 = 1) {
        unsafe pointee.counters[c.rawValue].wrappingAdd(n, ordering: .relaxed)
    }

    @inline(__always)
    func worker(_ i: Int) -> WorkerPointer { unsafe pointee.workers[i] }

    var hostWorker: WorkerPointer { unsafe pointee.workers[pointee.workerCount - 1] }

    /// Worker `i`'s shared line.
    @inline(__always)
    func shared(_ i: Int) -> UnsafeMutablePointer<WorkerShared> {
        unsafe (pointee.workerShared + i &* 128).assumingMemoryBound(to: WorkerShared.self)
    }
}

// MARK: - locks

/// Every lock acquisition tries first and counts the contended ones and
/// their wait (docs/modules/workers.md: nothing is optimised until a
/// counter says so).
@inline(__always)
func lockCounted(_ m: UnsafeMutablePointer<pthread_mutex_t>, _ vm: UnsafeMutablePointer<VMState>,
                 contended: Counter, waitNs: Counter? = nil) {
    if unsafe pthread_mutex_trylock(m) != 0 {
        let t0 = nanoseconds()
        unsafe pthread_mutex_lock(m)
        unsafe vm.count(contended)
        if let waitNs { unsafe vm.count(waitNs, nanoseconds() &- t0) }
    }
}

func makeMutex() -> UnsafeMutablePointer<pthread_mutex_t> {
    let m = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    unsafe pthread_mutex_init(m, nil)
    return unsafe m
}

func makeCond() -> UnsafeMutablePointer<pthread_cond_t> {
    let c = UnsafeMutablePointer<pthread_cond_t>.allocate(capacity: 1)
    unsafe pthread_cond_init(c, nil)
    return unsafe c
}

func freeMutex(_ m: UnsafeMutablePointer<pthread_mutex_t>) {
    unsafe pthread_mutex_destroy(m)
    unsafe m.deallocate()
}

func freeCond(_ c: UnsafeMutablePointer<pthread_cond_t>) {
    unsafe pthread_cond_destroy(c)
    unsafe c.deallocate()
}

/// One value in its own 128-byte aligned allocation, a whole number of
/// lines long, so nothing else shares its lines (AGENTS.md: per-worker and
/// per-lock state on lines of its own). The one pair of such helpers (the
/// collectors review: module 4, 5 and 6 each had a copy, and this one
/// rounded only up to one line, so a larger value shared its last line).
func lined<T: ~Copyable>(_ v: consuming T) -> UnsafeMutablePointer<T> {
    let raw = UnsafeMutableRawPointer.allocate(byteCount: (MemoryLayout<T>.stride + 127) & ~127, alignment: 128)
    let p = unsafe raw.bindMemory(to: T.self, capacity: 1)
    unsafe p.initialize(to: v)
    return unsafe p
}

/// Deinitialize and free what `lined` allocated.
func unlined<T: ~Copyable>(_ p: UnsafeMutablePointer<T>) {
    unsafe p.deinitialize(count: 1)
    unsafe UnsafeMutableRawPointer(p).deallocate()
}
