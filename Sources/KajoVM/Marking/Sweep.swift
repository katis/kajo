import Darwin
import Synchronization

// The lazy sweep, the apply and the ways a cycle ends early (docs/modules/
// concurrent-marking.md "Lazy sweep", "Fallback"). The sweep runs on the
// marker thread after the final mark: snapshot entries left unmarked are
// freed into pending runs (free in the table, owned by the pending list),
// marks of the live ones cleared, the snapshot map cleared word by word.
// Nothing reaches allocators until a pause applies it: the runs are
// published and blocks with no live body freed. A background allocation
// that needs them stalls for the collector (docs/modules/allocation-
// stalls.md); the main worker's promotion uses module 4's reserve.

/// Sweep the current cycle's snapshot from the cursor to the end, polling
/// between chunks of 64 words (4096 entries) unless `inPause`. Answers true
/// when it reached the end (phase swept). `maxWords` (the sweep stop's
/// bound, and the tests' stepped sweep): stop after that many words, in
/// chunks of at most 64, leaving the cursor where the next sweep continues.
func sweepCycle(_ vm: VMPointer, _ mk: MarkingPointer, inPause: Bool, maxWords: Int = .max) -> Bool {
    let om = unsafe mk.pointee.om
    let m = unsafe mk.pointee.marker
    let snap = unsafe mk.pointee.snapshot
    let old = om.oldMap
    let cycle = unsafe mk.cycleNow
    let words = unsafe m.pointee.sweepWords
    let chunk = UInt64(om.config.entryChunk)
    let t0 = nanoseconds(), c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    defer {
        unsafe m.pointee.sweepNs &+= nanoseconds() &- t0
        unsafe m.pointee.sweepCpuNs &+= clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- c0
    }
    var budget = maxWords
    while unsafe m.pointee.sweepCursor < words {
        if budget <= 0 { return false }
        let start = unsafe m.pointee.sweepCursor
        let end = Swift.min(start &+ Swift.min(64, budget), words)
        budget &-= end &- start
        var freed: UInt64 = 0, bytes: UInt64 = 0, visited: UInt64 = 0
        for w in start..<end {
            let s = snap.word(w)
            if s == 0 { continue }
            visited &+= UInt64(s.nonzeroBitCount)
            var bits = s
            var dead: UInt64 = 0
            var live: UInt64 = 0
            while bits != 0 {
                let b = UInt64(bits.trailingZeroBitCount)
                bits &= bits &- 1
                let e = UInt64(w) &<< 6 | b
                let raw = e &<< 4
                if om.markRelaxed(e) != 0 {
                    live |= 1 &<< b
                    unsafe m.pointee.sweepLive[BlockHeap.block(ofOffset: om.stateWord(raw))] = 1
                } else {
                    bytes &+= om.bodyWords(entry: raw) &<< 3  // large bytes: a long one's from its back reference
                    om.setHeaderWord(raw, 0)
                    unsafe om.setStateWord(raw, EntryState.free(next: m.pointee.runHead))
                    unsafe m.pointee.runHead = raw
                    unsafe m.pointee.runLength &+= 1
                    if unsafe m.pointee.runLength == chunk { unsafe flushRun(om, m) }
                    dead |= 1 &<< b
                    freed &+= 1
                }
            }
            // Nothing in this word is pending-dead any more: the dead are
            // free, the live are no longer snapshot entries.
            snap.setWord(w, 0)
            while live != 0 {
                let b = UInt64(live.trailingZeroBitCount)
                live &= live &- 1
                om.setMarkRelaxed(UInt64(w) &<< 6 | b, 0)
            }
            if dead != 0 { old.remove(word: w, bits: dead) }
        }
        unsafe flushRun(om, m)
        unsafe m.pointee.entriesFreed &+= freed
        unsafe m.pointee.bytesFreed &+= bytes
        unsafe m.pointee.entriesVisited &+= visited
        unsafe m.pointee.sweepCursor = end
        if !inPause, unsafe !markerPoll(vm, mk, cycle: cycle, phase: .sweeping) { return false }
        // Module 6: evacuated blocks whose epoch every worker passed.
        if !inPause, let r = unsafe vm.pointee.relocation { unsafe tryFreePending(vm, r, atPause: false) }
    }
    unsafe m.pointee.sweptCycle = cycle
    unsafe mk.setPhase(.swept)
    return true
}

/// The partial run becomes a pending run: at every poll each free entry is
/// in exactly one list.
private func flushRun(_ om: ObjectMemory, _ m: UnsafeMutablePointer<MarkerState>) {
    if unsafe m.pointee.runHead == 0 { return }
    unsafe om.addPendingRun(m.pointee.runHead)
    unsafe m.pointee.runHead = 0
    unsafe m.pointee.runLength = 0
}

/// Publish a finished sweep (world stopped): free the snapshot blocks with
/// no live body that no allocator took since the snapshot, rebuild the
/// block pool, hand the pending runs to the allocators. The cycle is over;
/// its QoS decision for the next one is made here.
func applyInStop(_ vm: VMPointer, _ mk: MarkingPointer) {
    guard unsafe mk.phaseNow == .swept else { return }
    let t0 = nanoseconds()
    let om = unsafe mk.pointee.om
    let m = unsafe mk.pointee.marker
    let log = unsafe mk.pointee.log
    om.retireAllContexts()
    let blocks = unsafe om.freeDeadBlocks(live: m.pointee.sweepLive, stamp: m.pointee.sweepStamp)
    om.rebuildBlockPool()
    _ = om.publishPendingRuns()
    om.setPendingDead(nil)
    om.setMarkingActive(false)
    unsafe relocationAtCycleEnd(vm, completed: true)
    unsafe mk.setPhase(.idle)
    let t1 = nanoseconds()
    if var r = unsafe log.pointee.currentRecord {
        r.sweepNs = unsafe m.pointee.sweepNs
        r.sweepCpuNs = unsafe m.pointee.sweepCpuNs
        r.entriesFreed = unsafe m.pointee.entriesFreed
        r.bytesFreed = unsafe m.pointee.bytesFreed
        r.blocksFreed = UInt64(blocks)
        r.applyNs = t1 &- t0
        r.durationNs = unsafe t1 &- log.pointee.startNs
        r.completed = true
        unsafe cycleRecordAtEnd(vm, mk, &r)
        unsafe log.pointee.complete(r)
    }
    unsafe log.pointee.lastCycleNs = t1 &- log.pointee.startNs
    if unsafe log.pointee.sweepStartNs != 0 { unsafe log.pointee.lastSweepNs = t1 &- log.pointee.sweepStartNs }
    unsafe log.pointee.lastApplyAtNs = t1
    unsafe log.pointee.lastAppliedCycle = unsafe mk.cycleNow
    unsafe log.pointee.current = -1
    unsafe log.pointee.counters.cyclesCompleted &+= 1
    unsafe log.pointee.counters.applies &+= 1
    unsafe log.pointee.counters.applyNs &+= t1 &- t0
    unsafe log.pointee.counters.sweepNs &+= m.pointee.sweepNs
    unsafe log.pointee.counters.entriesFreed &+= m.pointee.entriesFreed
    // The sweep stop: what a partial apply handed over left the estimate then.
    let unpublished = unsafe m.pointee.entriesFreed &- Swift.min(m.pointee.entriesFreed, m.pointee.entriesPublished)
    unsafe m.pointee.entriesPublished = m.pointee.entriesFreed
    unsafe log.pointee.oldEntries &-= Swift.min(log.pointee.oldEntries, unpublished)
    unsafe log.pointee.counters.blocksFreed &+= UInt64(blocks)
    // The policy lowers the marker only when a cycle ends with the headroom
    // of both old space and the entry table above the threshold.
    if unsafe !wantsRaise(mk, oldEntries: log.pointee.oldEntries, blocksOnly: mk.pointee.config.testSwitches.qosOnBlocksOnly) {
        unsafe mk.pointee.wantUserInitiated.pointee.store(false, ordering: .relaxed)
    }
}

/// Abandon a marking cycle (world stopped): barrier off, marks and snapshot
/// cleared, buffers and queue discarded; the marker drops its work at its
/// next poll (the cycle number changed). Nothing was freed.
func abortCycle(_ vm: VMPointer, _ mk: MarkingPointer) {
    let om = unsafe mk.pointee.om
    let log = unsafe mk.pointee.log
    if unsafe !mk.pointee.config.stress.contains(.markingAlwaysOn) { unsafe markingBarrierOff(mk) }
    om.clearMarks()
    let snap = unsafe mk.pointee.snapshot
    for w in unsafe 0..<log.pointee.snapshotWords { snap.setWord(w, 0) }
    unsafe resetBuffersAndQueue(mk)
    unsafe dropMarkerWork(mk)
    unsafe clearRootScans(mk)
    om.setPendingDead(nil)
    om.setMarkingActive(false)
    unsafe relocationAtCycleEnd(vm, completed: false)
    if var r = unsafe log.pointee.currentRecord {
        r.aborted = true
        unsafe cycleRecordAtEnd(vm, mk, &r)
        unsafe log.pointee.currentRecord = r
    }
    unsafe log.pointee.current = -1
    unsafe log.pointee.counters.aborts &+= 1
    unsafe pthread_mutex_lock(mk.pointee.lock)
    unsafe mk.pointee.cycle.pointee.store(mk.cycleNow &+ 1, ordering: .releasing)
    unsafe mk.setPhase(.idle)
    unsafe pthread_mutex_unlock(mk.pointee.lock)
}

/// Module 1 is about to collect, compact, become, forward or reshape
/// (world stopped): a marking cycle is abandoned (the operation moves or
/// frees what the snapshot names, or swaps bodies under the marker); a
/// sweep is finished in this pause and applied, so that no entry is freed
/// twice and every free entry has one owner.
func markingBeforeOldSpaceOperation(_ vm: VMPointer) {
    guard let mk = unsafe vm.pointee.marking else { return }
    switch unsafe mk.phaseNow {
    case .idle:
        return
    case .marking:
        unsafe abortCycle(vm, mk)
    case .sweeping:
        _ = unsafe sweepCycle(vm, mk, inPause: true)
        unsafe mk.pointee.log.pointee.counters.sweepsFinishedInPause &+= 1
        unsafe applyInStop(vm, mk)
    case .swept:
        unsafe applyInStop(vm, mk)
    }
}

/// Large bytes, part 2, bounded by the sweep stop (docs/modules/
/// sweep-stop.md; world stopped, in a stop of kind `sweep`): the entry
/// table is empty, or an old allocation found no room, while a cycle
/// sweeps or has swept. A swept cycle is applied (no sweeping: the apply's
/// own cost). A sweeping one is swept here for at most
/// `MarkingConfig.sweepStopWords` words, and if that does not reach the
/// end, what is swept so far (the marker's pending runs and this stop's)
/// is handed to the allocators and the rest is left to the marker: a
/// partial apply (`publishSwept`, whose one-owner argument is in the
/// module doc). Blocks are freed only by the whole apply, so an old
/// allocation that the hand-over does not serve stalls for the collector
/// outside the stop (a background worker, `stallForCollector`); with
/// `bounded` false (the main worker's old allocation, a justified stall's,
/// the test switch `sweepStopUnbounded`) the sweep is finished here
/// whatever its length, as before. Answers `.none` when no sweep was
/// pending (the caller falls back) or under `noSweepForEntries`.
func finishSweepInStop(_ vm: VMPointer, for cause: FullCause, bounded: Bool = true) -> SweepStopOutcome {
    guard let mk = unsafe vm.pointee.marking, unsafe !mk.pointee.config.testSwitches.noSweepForEntries else { return .none }
    let phase = unsafe mk.phaseNow
    guard phase == .sweeping || phase == .swept else { return .none }
    unsafe markStop(vm, .sweep)
    let t0 = nanoseconds()
    let log = unsafe mk.pointee.log
    let m = unsafe mk.pointee.marker
    let sw = unsafe mk.pointee.config.testSwitches
    var r = unsafe sweepStopRecord(vm, mk, cause: cause, phase: phase)
    var outcome = SweepStopOutcome.whole
    let freed0 = unsafe m.pointee.entriesFreed, cursor0 = unsafe m.pointee.sweepCursor
    var t1 = t0
    if phase == .sweeping {
        // What the marker has swept and the allocators do not have yet is
        // handed over first; the stop sweeps (up to the bound) only when
        // that is too little to be worth a stop of its own.
        let pending = unsafe m.pointee.entriesFreed &- Swift.min(m.pointee.entriesFreed, m.pointee.entriesPublished)
        let unbounded = !bounded || sw.sweepStopUnbounded
        let bound = unsafe unbounded ? Int.max
            : pending >= UInt64(mk.pointee.config.sweepStopEnoughEntries) ? 0 : mk.pointee.config.sweepStopWords
        // A bounded sweep must not run ahead of this cycle's relocation
        // pass: the relocator moves only snapshot entries and would take a
        // swept live object for a dead one, and evacuate its block with
        // the body in it. The pass is cut off at the poll it is parked at,
        // exactly as an apply ends it; blocks it did not evacuate go back
        // to the pool at the apply's rebuild.
        if bound != .max && bound > 0 { r.relocationCutOff = unsafe relocationCutOffForSweep(vm, cycle: mk.cycleNow) }
        let done = unsafe bound > 0 && sweepCycle(vm, mk, inPause: true, maxWords: bound)
        t1 = nanoseconds()
        if done {
            outcome = bound == .max ? .unbounded : .whole
            unsafe log.pointee.counters.sweepsFinishedInPause &+= 1
        } else {
            outcome = .partial
        }
    }
    r.wordsInStop = unsafe m.pointee.sweepCursor &- cursor0
    r.entriesFreedInStop = unsafe m.pointee.entriesFreed &- freed0
    r.sweepNs = t1 &- t0
    if outcome == .partial {
        if sw.applyAheadOfSweep { unsafe applyAheadOfCursor(mk) }
        r.entriesHanded = unsafe publishSwept(mk)
    } else {
        r.entriesHanded = unsafe m.pointee.entriesFreed &- Swift.min(m.pointee.entriesFreed, m.pointee.entriesPublished)
        unsafe applyInStop(vm, mk)
    }
    let t2 = nanoseconds()
    r.applyNs = t2 &- t1
    r.outcome = outcome
    // Checked builds and the tests: the heap and the free lists after the
    // hand-over or the apply, with the pending-dead skip rule and the
    // one-owner check (no free entry is still a snapshot entry).
    let om = unsafe mk.pointee.om
    if om.config.verify {
        om.retireAllContexts()  // the verifier reads blocks' used bytes
        om.verifyAtPause(outcome == .partial ? "after a sweep stop's hand-over" : "after a sweep stop", phase: .idle)
    }
    if cause == .entries {
        unsafe log.pointee.counters.sweepsFinishedForEntries &+= 1
    } else {
        unsafe log.pointee.counters.sweepsFinishedForOld &+= 1
    }
    unsafe log.pointee.counters.sweepsFinishedForEntriesNs &+= t2 &- t0
    unsafe log.pointee.counters.sweepStops &+= 1
    switch outcome {
    case .whole: unsafe log.pointee.counters.sweepStopsWhole &+= 1
    case .partial: unsafe log.pointee.counters.sweepStopsPartial &+= 1
    case .unbounded: unsafe log.pointee.counters.sweepStopsUnbounded &+= 1
    case .none: break
    }
    if r.relocationCutOff { unsafe log.pointee.counters.sweepStopRelocCutOffs &+= 1 }
    unsafe log.pointee.sweepStopRecords.append(r)
    return outcome
}

/// The circumstances of a sweep stop as it begins (world stopped).
private func sweepStopRecord(_ vm: VMPointer, _ mk: MarkingPointer, cause: FullCause, phase: MarkingPhase) -> SweepStopRecord {
    let log = unsafe mk.pointee.log
    let m = unsafe mk.pointee.marker
    let om = unsafe mk.pointee.om
    var r = SweepStopRecord()
    r.cause = cause
    r.phase = phase
    unsafe pthread_mutex_lock(vm.pointee.safepointLock)
    r.requester = unsafe vm.pointee.safepoint.pointee.stopper
    unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
    r.cursorWords = unsafe m.pointee.sweepCursor
    r.totalWords = unsafe m.pointee.sweepWords
    r.entriesVisited = unsafe m.pointee.entriesVisited
    r.entriesFreed = unsafe m.pointee.entriesFreed
    r.entriesPublished = unsafe m.pointee.entriesPublished
    r.snapshotEntries = unsafe log.pointee.currentRecord?.snapshotEntries ?? 0
    if unsafe log.pointee.sweepStartNs != 0 { r.sinceSweepStartNs = unsafe nanoseconds() &- log.pointee.sweepStartNs }
    r.markerQoS = unsafe mk.pointee.qosNow.pointee.load(ordering: .relaxed)
    r.wantUserInitiated = unsafe mk.pointee.wantUserInitiated.pointee.load(ordering: .relaxed)
    r.entryCapacity = om.entryCapacity
    r.oldEntries = unsafe log.pointee.oldEntries
    let f = om.fallbackSnapshot
    r.highWater = f.highWater
    r.pendingRuns = f.pendingRuns
    r.blocksInUse = f.blocksInUse
    r.softLimitBlocks = f.softLimitBlocks
    return r
}

/// The partial apply (world stopped, phase sweeping, the marker parked at
/// a poll, where its run is flushed): every pending run, all of it below
/// the sweep's cursor and none of it in the snapshot any more, goes to the
/// allocators; the entries leave the old-entry estimate. Blocks, the
/// pending-dead set, the marking flag and the relocation stay with the
/// whole apply. Answers the entries handed over.
func publishSwept(_ mk: MarkingPointer) -> UInt64 {
    let om = unsafe mk.pointee.om
    let m = unsafe mk.pointee.marker
    let log = unsafe mk.pointee.log
    _ = om.publishPendingRuns()
    let newly = unsafe m.pointee.entriesFreed &- Swift.min(m.pointee.entriesFreed, m.pointee.entriesPublished)
    unsafe m.pointee.entriesPublished = m.pointee.entriesFreed
    unsafe log.pointee.oldEntries &-= Swift.min(log.pointee.oldEntries, newly)
    return newly
}

/// The broken variant `applyAheadOfSweep` (tests only): the dead entries
/// of the first snapshot word past the cursor that has any are freed and
/// handed over while the snapshot still names them and the cursor has not
/// passed them; the sweep will free them again.
private func applyAheadOfCursor(_ mk: MarkingPointer) {
    let om = unsafe mk.pointee.om
    let m = unsafe mk.pointee.marker
    let snap = unsafe mk.pointee.snapshot
    var w = unsafe m.pointee.sweepCursor
    while unsafe w < m.pointee.sweepWords {
        var bits = snap.word(w)
        var head: UInt64 = 0
        while bits != 0 {
            let b = UInt64(bits.trailingZeroBitCount)
            bits &= bits &- 1
            let e = UInt64(w) &<< 6 | b
            if om.markRelaxed(e) != 0 { continue }
            let raw = e &<< 4
            om.setHeaderWord(raw, 0)
            om.setStateWord(raw, EntryState.free(next: head))
            head = raw
            om.oldMap.remove(word: w, bits: 1 &<< b)
        }
        if head != 0 {
            om.addPendingRun(head)
            return
        }
        w &+= 1
    }
}

/// Why module 4 ran a full collection.
enum FullCause: UInt8, Sendable {
    /// A promotion found no block (the reserve's fallback: objects kept in
    /// place). Before the allocation stalls this case was `softLimit`, a
    /// scavenge that left old space past its soft limit; crossing the soft
    /// limit no longer asks for a full collection.
    case reserve
    /// The entry table was full.
    case entries
    /// A stress flag or the host.
    case other
    /// Large bytes, part 2: an old (large) allocation found no room under
    /// the soft limit or no run of its length.
    case oldAllocation
    /// Allocation stalls: a background worker's promotion after a stall a
    /// cycle justified.
    case promotion
    /// The final mark's verifier failed (the cycle was abandoned).
    case verifier
    /// A collection left old space past its soft limit with no collector
    /// to wait for (no marker thread, the switch `noStalls`): module 4's
    /// rule before the allocation stalls, kept there.
    case softLimit
}

/// A full collection is about to run in this stop (or, for an old
/// allocation, ran: `record` was taken before it). With concurrent marking
/// configured, one forced by space is a fallback: a provisioning failure,
/// counted by the phase it found and by what ran out, never hidden. Its
/// circumstances are recorded (large bytes, part 2), with who asked
/// (allocation stalls): the main worker, a background worker whose stall a
/// cycle justified, an operation in a stop, a VM with no marker thread, or
/// none of these, which is `unjustifiedFallbacks` (a verifier failure in
/// checked builds).
func noteFullCollection(_ vm: VMPointer, _ cause: FullCause, requester: FallbackRequester, worker: Int = -1,
                        record: FallbackRecord? = nil) {
    guard let mk = unsafe vm.pointee.marking, cause != .other else { return }
    let log = unsafe mk.pointee.log
    var r = unsafe record ?? fallbackRecord(vm, cause)!
    var requester = requester
    r.worker = worker
    if requester == .stall {
        // The justification's own check: a cycle numbered above the one the
        // stall began in completed and was applied (the broken variant
        // `stallJustifiedByRunningCycle` lets the running one count, and
        // lands here as unjustified).
        let last = unsafe log.pointee.lastAppliedCycle
        r.justifyingCycle = last
        unsafe pthread_mutex_lock(mk.pointee.waitsLock)
        if unsafe worker >= 0 && worker < mk.pointee.stalls.pointee.lastNs.count {
            r.stalledNs = unsafe mk.pointee.stalls.pointee.lastNs[worker]
            let began = unsafe mk.pointee.stalls.pointee.beganAt[worker]
            r.justifiedBy = unsafe mk.pointee.stalls.pointee.justifiedBy[worker]
            if began != .max && !(last > began) { requester = .background }
            if began == .max { r.justifyingCycle = 0 }
        }
        unsafe pthread_mutex_unlock(mk.pointee.waitsLock)
        if r.justifyingCycle > 0, let c = unsafe log.pointee.records.records.last(where: { $0.number == r.justifyingCycle }) {
            r.justifyingMarkedBytes = c.markedBytes
        }
    }
    r.requester = requester
    unsafe log.pointee.counters.fallbacks &+= 1
    switch r.phase {
    case .idle: unsafe log.pointee.counters.fallbacksIdle &+= 1
    case .marking: unsafe log.pointee.counters.fallbacksMarking &+= 1
    case .sweeping, .swept: unsafe log.pointee.counters.fallbacksSweeping &+= 1
    }
    switch cause {
    case .entries: unsafe log.pointee.counters.fallbacksEntries &+= 1
    case .reserve: unsafe log.pointee.counters.fallbacksReserve &+= 1
    case .oldAllocation: unsafe log.pointee.counters.fallbacksOldAllocation &+= 1
    case .promotion: unsafe log.pointee.counters.fallbacksPromotion &+= 1
    case .softLimit: unsafe log.pointee.counters.fallbacksSoftLimit &+= 1
    case .verifier, .other: break
    }
    switch requester {
    case .main: unsafe log.pointee.counters.fallbacksByMain &+= 1
    case .stall: unsafe log.pointee.counters.fallbacksByStall &+= 1
    case .inStop: unsafe log.pointee.counters.fallbacksInStop &+= 1
    case .noMarker: unsafe log.pointee.counters.fallbacksNoMarker &+= 1
    case .background: unsafe log.pointee.counters.unjustifiedFallbacks &+= 1
    }
    unsafe log.pointee.fallbackRecords.append(r)
    if unsafe requester == .background && vm.pointee.om.config.verify {
        unsafe verifierFailed(vm, .unjustifiedFallbacks,
                              "an unjustified fallback: background worker \(worker), cause \(cause), phase \(r.phase)")
    }
}

/// The requester of a full collection module 4 was asked for, kept beside
/// `fullRequested` (`NurseryShared.fullRequestInfo`): the cause, the
/// requester and the worker.
func encodeFullRequest(_ cause: FullCause, _ requester: FallbackRequester, worker: Int) -> UInt64 {
    UInt64(cause.rawValue) | UInt64(requester.rawValue) &<< 8 | UInt64(truncatingIfNeeded: worker &+ 1) &<< 16
}

func decodeFullRequest(_ v: UInt64) -> (cause: FullCause, requester: FallbackRequester, worker: Int) {
    (FullCause(rawValue: UInt8(truncatingIfNeeded: v)) ?? .reserve,
     FallbackRequester(rawValue: UInt8(truncatingIfNeeded: v &>> 8)) ?? .inStop,
     Int(truncatingIfNeeded: v &>> 16) &- 1)
}

/// The circumstances of a fallback now (world stopped); nil without
/// concurrent marking.
func fallbackRecord(_ vm: VMPointer, _ cause: FullCause) -> FallbackRecord? {
    guard let mk = unsafe vm.pointee.marking else { return nil }
    let log = unsafe mk.pointee.log
    let om = unsafe mk.pointee.om
    let m = unsafe mk.pointee.marker
    let phase = unsafe mk.phaseNow
    var r = FallbackRecord()
    r.cause = cause
    r.phase = phase
    let now = nanoseconds()
    if phase != .idle, let cur = unsafe log.pointee.currentRecord {
        r.trigger = cur.trigger
        r.sinceCycleStartNs = unsafe now &- log.pointee.startNs
    }
    if unsafe log.pointee.lastApplyAtNs != 0 { r.sinceLastApplyNs = unsafe now &- log.pointee.lastApplyAtNs }
    r.cyclesStarted = unsafe log.pointee.totals.cycles
    if phase == .sweeping, unsafe m.pointee.sweepWords > 0 {
        r.sweptFraction = unsafe Double(m.pointee.sweepCursor) / Double(m.pointee.sweepWords)
    } else if phase == .swept {
        r.sweptFraction = 1
    }
    r.markedObjects = unsafe m.pointee.markedObjects
    r.entryCapacity = om.entryCapacity
    r.oldEntries = unsafe log.pointee.oldEntries
    let f = om.fallbackSnapshot
    r.highWater = f.highWater
    r.poolRuns = f.poolRuns
    r.pendingRuns = f.pendingRuns
    r.blocksInUse = f.blocksInUse
    r.softLimitBlocks = f.softLimitBlocks
    r.largeFailure = f.lastLargeFailure
    r.markerQoS = unsafe mk.pointee.qosNow.pointee.load(ordering: .relaxed)
    r.wantUserInitiated = unsafe mk.pointee.wantUserInitiated.pointee.load(ordering: .relaxed)
    return r
}
