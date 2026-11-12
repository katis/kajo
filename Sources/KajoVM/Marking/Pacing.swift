import Darwin
import Synchronization

// Allocation stalls (docs/modules/allocation-stalls.md): old space paced by
// the collector's progress. Part 1, the instrumentation: each cycle's record
// carries what the steady-state inequality needs (old space at the snapshot
// and at the end, what was promoted while the cycle ran, what it freed, the
// marker's time by phase and parked) and what waited on it.

/// Bytes promoted so far by every nursery, and by the main worker's alone:
/// module 4's scavenges (counters written in stops) and module 7's
/// collections (an atomic, and the young log under the safepoint mutex).
/// World stopped.
func promotedTotals(_ vm: VMPointer) -> (all: UInt64, main: UInt64) {
    var all: UInt64 = 0, main: UInt64 = 0
    if let n = unsafe vm.pointee.nursery {
        all &+= unsafe n.pointee.state.pointee.counters.promotedBytes
        main &+= unsafe n.pointee.state.pointee.counters.promotedMainBytes
    }
    if let y = unsafe vm.pointee.young {
        all &+= unsafe y.pointee.promotedBytes.pointee.load(ordering: .relaxed)
        main &+= unsafe y.pointee.log.pointee.promotedMainBytes
    }
    return (all, main)
}

/// Blocks module 6 has freed so far (by epoch and at pauses). World stopped.
private func relocationBlocksFreed(_ vm: VMPointer) -> UInt64 {
    guard let r = unsafe vm.pointee.relocation else { return 0 }
    let c = unsafe r.pointee.state.pointee.counters
    return c.freedByEpoch &+ c.freedAtPause
}

/// Stalls so far (under the waits lock).
private func waitsSoFar(_ mk: MarkingPointer) -> UInt64 {
    unsafe pthread_mutex_lock(mk.pointee.waitsLock)
    defer { unsafe pthread_mutex_unlock(mk.pointee.waitsLock) }
    return unsafe mk.pointee.stalls.pointee.all.count
}

/// A new cycle's record at its initial mark (world stopped).
func cycleRecordAtStart(_ vm: VMPointer, _ mk: MarkingPointer, _ r: inout CycleRecord) {
    let om = unsafe mk.pointee.om
    let p = unsafe promotedTotals(vm)
    r.blocksAtStart = om.blocksInUse
    r.promotedAtStart = p.all
    r.promotedMainAtStart = p.main
    r.relocFreedAtStart = unsafe relocationBlocksFreed(vm)
    r.waitsAtStart = unsafe waitsSoFar(mk)
    r.fallbacksAtStart = unsafe mk.pointee.log.pointee.counters.fallbacks
    let m = unsafe mk.pointee.marker
    unsafe m.pointee.parkMarkNs = 0
    unsafe m.pointee.parkRelocNs = 0
    unsafe m.pointee.parkSweepNs = 0
    unsafe m.pointee.relocWallNs = 0
    unsafe m.pointee.relocCpuNs = 0
}

/// The cycle's end (applied, or abandoned; world stopped).
func cycleRecordAtEnd(_ vm: VMPointer, _ mk: MarkingPointer, _ r: inout CycleRecord) {
    let om = unsafe mk.pointee.om
    let m = unsafe mk.pointee.marker
    let p = unsafe promotedTotals(vm)
    r.blocksAtEnd = om.blocksInUse
    r.oldEntriesAtEnd = unsafe mk.pointee.log.pointee.oldEntries
    r.promotedDuring = p.all &- r.promotedAtStart
    r.promotedMainDuring = p.main &- r.promotedMainAtStart
    r.relocBlocksFreed = unsafe relocationBlocksFreed(vm) &- r.relocFreedAtStart
    r.parkMarkNs = unsafe m.pointee.parkMarkNs
    r.parkRelocNs = unsafe m.pointee.parkRelocNs
    r.parkSweepNs = unsafe m.pointee.parkSweepNs
    r.relocWallNs = unsafe m.pointee.relocWallNs
    r.relocCpuNs = unsafe m.pointee.relocCpuNs
    r.waits = unsafe waitsSoFar(mk) &- r.waitsAtStart
    r.fallbacks = unsafe mk.pointee.log.pointee.counters.fallbacks &- r.fallbacksAtStart
}

// MARK: - the stall (part 2)

/// Allocation stalls, the rule (docs/modules/allocation-stalls.md "The
/// collector's turn"): background worker `w`, outside every stop, its
/// registers flushed, no lock held, no young collection open, nothing of
/// the current instruction live but `held` (a pending root while it
/// stalls), needs `resource` and `available` says it cannot have it
/// without crossing a limit. The worker raises the marker (the policy's
/// flag, and an override of the marker thread's QoS from this thread for
/// as long as it waits: a starved marker cannot raise itself), makes sure
/// a cycle is running (starting one in a stop of the mode's own kind when
/// none is), and waits, untimed, on the safepoint condition for the
/// collector's progress (`SafepointState.progress`, bumped under the
/// safepoint mutex by every stop's release and by every block freed
/// outside a stop), parking for stops, servicing module 7's rounds and
/// quiescent for epochs meanwhile (`waitServicing`). After each change it
/// asks `available` again (outside the mutex: it may take the pools'
/// lock). It ends when `available` answers true, or when a cycle whose
/// snapshot was taken after the stall began has completed and been
/// applied and the resource is still not there (`justified`: the caller
/// falls back, and its fallback is justified until `stallFallbackDone`).
/// Nothing else ends it, a clock least of all. A run due full collection
/// (the reserve's or a failed verifier's) is run here as a poll would.
/// nil: this worker does not stall (the main worker, the host worker, a VM
/// with no marker thread, no pending-root slot for `held`, the test switch
/// `noStalls`).
func stallForCollector(_ vm: VMPointer, _ w: WorkerPointer, _ resource: StallResource, held: Oop = .none,
                       available: () -> Bool) -> StallOutcome? {
    guard unsafe isBackgroundWorker(vm, w), unsafe stallsEnabled(vm), let mk = unsafe vm.pointee.marking else { return nil }
    let h = held == .none ? -1 : unsafe registerPending(vm, held)
    if held != .none && h < 0 { return nil }
    defer { if h >= 0 { unsafe unregisterPending(vm, h) } }
    let sp = unsafe vm.pointee.safepoint
    let log = unsafe mk.pointee.log
    let sw = unsafe mk.pointee.config.testSwitches
    let t0 = nanoseconds()
    unsafe pthread_mutex_lock(vm.pointee.safepointLock)
    let c0 = unsafe mk.cycleNow
    let applies0 = unsafe log.pointee.counters.applies
    let fulls0 = unsafe vm.pointee.om.gc.pointee.counters.collections
    unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
    unsafe pthread_mutex_lock(mk.pointee.waitsLock)
    unsafe mk.pointee.stalls.pointee.stalledNow += 1
    unsafe pthread_mutex_unlock(mk.pointee.waitsLock)
    unsafe mk.pointee.wantUserInitiated.pointee.store(true, ordering: .relaxed)
    let override = unsafe overrideMarkerQoS(mk)
    var outcome = StallOutcome.available
    var started = 0
    var applies: UInt64 = 0
    var sweepStopCycle = UInt64.max
    var why = StallJustification.none
    while true {
        unsafe pthread_mutex_lock(vm.pointee.safepointLock)
        let g = unsafe sp.pointee.progress
        // The broken variant `stallJustifiedByRunningCycle`: the cycle
        // that was already running when the stall began counts.
        let last = unsafe log.pointee.lastAppliedCycle
        let justified = sw.stallJustifiedByRunningCycle ? last >= c0 && last > 0 : last > c0
        applies = unsafe log.pointee.counters.applies &- applies0
        // A full collection ran meanwhile (another's fallback, a requested
        // one, an old-space operation): it abandoned any cycle the stall
        // waited for and left nothing more to collect; with the resource
        // still missing the heap is full, and module 4's out-of-memory
        // rule follows (justified, naming no cycle).
        let fulled = unsafe vm.pointee.om.gc.pointee.counters.collections != fulls0
        unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
        if available() { break }
        if justified || fulled {
            outcome = .justified
            why = justified ? .cycle : .fullCollection
            break
        }
        if unsafe fullCollectionDue(vm) {
            unsafe runDueFullCollection(vm, w)
            continue
        }
        // Entries and an old allocation: a sweep that has freed entries
        // not yet handed over is handed over in the bounded sweep stop (not
        // a fallback; docs/modules/sweep-stop.md), once per cycle; blocks
        // come only with the whole apply, which the marker asks for.
        let phase = unsafe mk.phaseNow
        if resource != .promotion && (phase == .sweeping || phase == .swept), unsafe sweepStopCycle != mk.cycleNow {
            sweepStopCycle = unsafe mk.cycleNow
            unsafe stopWorld(vm, w, retry: true, keeping: held == .none ? [] : [held]) { _ in
                _ = unsafe finishSweepInStop(vm, for: resource == .entries ? .entries : .oldAllocation)
            }
            continue
        }
        if unsafe mk.phaseNow == .idle {
            // The stop-the-world young mode starts a cycle with a scavenge,
            // whose promotion takes the reserve: with no room for one young
            // generation there, no cycle can start without a full
            // collection, which is then justified (no cycle can be waited
            // for; the record's justifying cycle is 0).
            if unsafe vm.pointee.young == nil, let n = unsafe vm.pointee.nursery,
               unsafe n.pointee.om.blocksCommitted + youngGenerationBlocks(n) > n.pointee.om.hardLimitBlocks {
                outcome = .justified
                why = .noCycleCanStart
                break
            }
            started += 1
            unsafe startCycleForStall(vm, w, mk, held: held)
            continue
        }
        unsafe pthread_mutex_lock(vm.pointee.safepointLock)
        unsafe waitServicing(vm, w) { unsafe sp.pointee.progress == g && mk.phaseNow != .idle }
        unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
    }
    if let o = unsafe override { unsafe pthread_override_qos_class_end_np(o) }
    let dt = nanoseconds() &- t0
    // Stall time is not the slice's: the deadline moves by it.
    if unsafe w.pointee.deadline != .max { unsafe w.pointee.deadline &+= nsToTicks(dt) }
    unsafe pthread_mutex_lock(mk.pointee.waitsLock)
    let st = unsafe mk.pointee.stalls
    unsafe st.pointee.stalledNow -= 1
    unsafe st.pointee.note(StallRecord(worker: w.pointee.index, resource: resource, outcome: outcome, ns: dt,
                                       applies: applies, startedCycles: started))
    unsafe st.pointee.cyclesStarted &+= UInt64(started)
    if outcome == .justified {
        unsafe st.pointee.justified[w.pointee.index] = true
        unsafe st.pointee.beganAt[w.pointee.index] = why == .cycle ? c0 : .max
        unsafe st.pointee.justifiedBy[w.pointee.index] = why
    }
    unsafe pthread_mutex_unlock(mk.pointee.waitsLock)
    return outcome
}

/// The justified fallback a stall led to is over (taken or found
/// unnecessary): later fallbacks of this worker need a stall of their own.
func stallFallbackDone(_ vm: VMPointer, _ w: WorkerPointer) {
    guard let mk = unsafe vm.pointee.marking, unsafe w.pointee.index < vm.pointee.workerCount else { return }
    unsafe pthread_mutex_lock(mk.pointee.waitsLock)
    unsafe mk.pointee.stalls.pointee.justified[w.pointee.index] = false
    unsafe pthread_mutex_unlock(mk.pointee.waitsLock)
}

/// Raise the marker thread to user-initiated from the stalling thread for
/// as long as it waits (a QoS override; the marker's own policy still
/// applies when it ends). nil without a marker thread.
private func overrideMarkerQoS(_ mk: MarkingPointer) -> pthread_override_t? {
    // The marker thread from its Mach port (an atomic it stores itself as
    // it starts; the pthread_t is the host's, written without a lock).
    let port = unsafe mk.pointee.machThread.pointee.load(ordering: .relaxed)
    guard port != 0, let t = pthread_from_mach_thread_np(port) else { return nil }
    let o = unsafe pthread_override_qos_class_start_np(t, QOS_CLASS_USER_INITIATED, 0)
    unsafe pthread_mutex_lock(mk.pointee.waitsLock)
    unsafe mk.pointee.stalls.pointee.markerOverrides &+= 1
    unsafe pthread_mutex_unlock(mk.pointee.waitsLock)
    return unsafe o
}

/// No cycle runs and a worker stalls: start one in a stop, the mode's own
/// way. Module 7: the initial-mark pause (no scavenge). The stop-the-world
/// young mode: the initial mark rides a scavenge (nothing may be young at
/// the snapshot but survivors, which are roots), so the stop scavenges
/// first; its promotion goes to the reserve, once per cycle started, and
/// it empties the stalled worker's eden too.
private func startCycleForStall(_ vm: VMPointer, _ w: WorkerPointer, _ mk: MarkingPointer, held: Oop) {
    let keep = held == .none ? [] : [held]
    if let y = unsafe vm.pointee.young {
        unsafe stopWorld(vm, w, retry: true, keeping: keep) { stop in unsafe initialMarkPause(vm, y, mk, stop, trigger: .stall) }
    } else {
        // The scavenge is the collector's way to begin a cycle in this
        // mode: should its promotion find no block (the reserve's fallback),
        // the full collection that follows is this stall's, justified.
        unsafe setStallJustified(vm, mk, w, true)
        unsafe stopWorld(vm, w, retry: true, keeping: keep) { stop in
            unsafe startCycleInStop(vm, mk, w, stop, scavenge: true, trigger: .stall)
        }
        unsafe setStallJustified(vm, mk, w, false)
    }
}

private func setStallJustified(_ vm: VMPointer, _ mk: MarkingPointer, _ w: WorkerPointer, _ on: Bool) {
    unsafe pthread_mutex_lock(mk.pointee.waitsLock)
    unsafe mk.pointee.stalls.pointee.justified[w.pointee.index] = on
    if on {
        unsafe mk.pointee.stalls.pointee.beganAt[w.pointee.index] = .max
        unsafe mk.pointee.stalls.pointee.justifiedBy[w.pointee.index] = .cycleStart
    }
    unsafe pthread_mutex_unlock(mk.pointee.waitsLock)
}

/// Allocation stalls, part 4: a stalled worker waits on the current cycle:
/// one stalls now, or a stall began since its initial mark (world stopped).
func cycleWaitedOn(_ vm: VMPointer, _ mk: MarkingPointer) -> Bool {
    let since = unsafe mk.pointee.log.pointee.currentRecord?.waitsAtStart ?? 0
    unsafe pthread_mutex_lock(mk.pointee.waitsLock)
    defer { unsafe pthread_mutex_unlock(mk.pointee.waitsLock) }
    let s = unsafe mk.pointee.stalls.pointee
    return s.stalledNow > 0 || s.all.count > since
}

/// A background worker: not the main worker (0), not the host worker (the
/// last, entered by whatever thread calls into the VM, the shells' main
/// thread among them), not the marker or the young collector.
func isBackgroundWorker(_ vm: VMPointer, _ w: WorkerPointer) -> Bool {
    let i = unsafe w.pointee.index
    return unsafe i != 0 && i < vm.pointee.workerCount - 1
}

/// Background workers stall in this VM: a running marker thread to wait
/// for (or the tests' switch `stallsWithoutMarker`, where the test thread
/// is the marker), and the test switch `noStalls` off.
func stallsEnabled(_ vm: VMPointer) -> Bool {
    guard let mk = unsafe vm.pointee.marking else { return false }
    let c = unsafe mk.pointee.config
    // The marker thread must be running (a VM driven slice by slice from
    // the test thread, never started, has none: nothing would end a stall).
    let marker = unsafe c.markerThread && mk.pointee.machThread.pointee.load(ordering: .relaxed) != 0
    return (marker || c.testSwitches.stallsWithoutMarker) && !c.testSwitches.noStalls
}

/// Who a full collection about to run is for, from the worker that asks
/// (nil, the host worker, the marker or the young collector: an operation
/// in a stop or the host's, `inStop`).
func fallbackRequester(_ vm: VMPointer, _ w: WorkerPointer?) -> FallbackRequester {
    guard let w = unsafe w, unsafe w.pointee.index < vm.pointee.workerCount - 1 else { return .inStop }
    if unsafe w.pointee.index == 0 { return .main }
    guard unsafe stallsEnabled(vm), let mk = unsafe vm.pointee.marking else { return .noMarker }
    unsafe pthread_mutex_lock(mk.pointee.waitsLock)
    defer { unsafe pthread_mutex_unlock(mk.pointee.waitsLock) }
    return unsafe mk.pointee.stalls.pointee.justified[w.pointee.index] ? .stall : .background
}
