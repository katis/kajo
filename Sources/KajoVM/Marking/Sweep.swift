import Darwin
import Synchronization

// The lazy sweep, the apply and the ways a cycle ends early (docs/modules/
// concurrent-marking.md "Lazy sweep", "Fallback"). The sweep runs on the
// marker thread after the final mark: snapshot entries left unmarked are
// freed into pending runs (free in the table, owned by the pending list),
// marks of the live ones cleared, the snapshot map cleared word by word.
// Nothing reaches allocators until a pause applies it: the runs are
// published and blocks with no live body freed. Allocation never waits for
// a sweep; promotion uses module 4's reserve.

/// Sweep the current cycle's snapshot from the cursor to the end, polling
/// between chunks of 64 words (4096 entries) unless `inPause`. Answers true
/// when it reached the end (phase swept).
func sweepCycle(_ vm: VMPointer, _ mk: MarkingPointer, inPause: Bool) -> Bool {
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
    while unsafe m.pointee.sweepCursor < words {
        let start = unsafe m.pointee.sweepCursor
        let end = Swift.min(start &+ 64, words)
        var freed: UInt64 = 0, bytes: UInt64 = 0
        for w in start..<end {
            let s = snap.word(w)
            if s == 0 { continue }
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
        unsafe log.pointee.complete(r)
    }
    unsafe log.pointee.lastCycleNs = t1 &- log.pointee.startNs
    unsafe log.pointee.lastApplyAtNs = t1
    unsafe log.pointee.current = -1
    unsafe log.pointee.counters.cyclesCompleted &+= 1
    unsafe log.pointee.counters.applies &+= 1
    unsafe log.pointee.counters.applyNs &+= t1 &- t0
    unsafe log.pointee.counters.sweepNs &+= m.pointee.sweepNs
    unsafe log.pointee.counters.entriesFreed &+= m.pointee.entriesFreed
    unsafe log.pointee.oldEntries &-= Swift.min(log.pointee.oldEntries, m.pointee.entriesFreed)
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
    om.setPendingDead(nil)
    om.setMarkingActive(false)
    unsafe relocationAtCycleEnd(vm, completed: false)
    if var r = unsafe log.pointee.currentRecord {
        r.aborted = true
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

/// Large bytes, part 2: an old allocation found no room while a cycle is
/// marking, so the cycle is behind: the policy raises the marker and this
/// worker waits for the final mark, at most `MarkingConfig.allocationWaitMs`,
/// polling for stops and module 7's rounds as a primitive's long loop does
/// (registers saved), never in a stop. The main worker does not wait (a
/// frame is shorter than the wait). Answers true when the cycle has left
/// marking (the caller tries again; a stop then finishes the sweep).
func waitForMarkingCycle(_ vm: VMPointer, _ w: WorkerPointer) -> Bool {
    guard let mk = unsafe vm.pointee.marking, unsafe mk.phaseNow == .marking, unsafe w.pointee.index != 0 else { return false }
    let bound = UInt64(unsafe mk.pointee.config.allocationWaitMs) &* 1_000_000
    if bound == 0 { return false }
    unsafe mk.pointee.wantUserInitiated.pointee.store(true, ordering: .relaxed)
    let cycle = unsafe mk.cycleNow
    let t0 = nanoseconds()
    let s = unsafe w.pointer(to: \Worker.interp)!
    var done = false
    while true {
        let a = unsafe s.pointee.safepointFlag.pointee.load(ordering: .relaxed)
        if a & 1 != 0 { unsafe park(vm, w) }
        if a > 1 { unsafe serviceRounds(vm, w) }
        if unsafe mk.phaseNow != .marking || mk.cycleNow != cycle { done = true; break }
        if nanoseconds() &- t0 >= bound { break }
        usleep(100)
    }
    let dt = nanoseconds() &- t0
    unsafe pthread_mutex_lock(mk.pointee.waitsLock)
    unsafe mk.pointee.waits.pointee.count &+= 1
    unsafe mk.pointee.waits.pointee.ns &+= dt
    if unsafe dt > mk.pointee.waits.pointee.maxNs { unsafe mk.pointee.waits.pointee.maxNs = dt }
    if !done { unsafe mk.pointee.waits.pointee.timeouts &+= 1 }
    unsafe pthread_mutex_unlock(mk.pointee.waitsLock)
    return done
}

/// Large bytes, part 2 (world stopped): the entry table is empty, or an
/// old allocation found no room, while a cycle sweeps or has swept; finish
/// the sweep in this pause and apply it, as module 1's operations do first
/// (`markingBeforeOldSpaceOperation`), so the entries and blocks it freed
/// reach the allocators without a full collection. Answers false when no
/// sweep was pending (the caller falls back) or under the test switch that
/// turns the rule off.
func finishSweepInStop(_ vm: VMPointer, for cause: FullCause) -> Bool {
    guard let mk = unsafe vm.pointee.marking, unsafe !mk.pointee.config.testSwitches.noSweepForEntries else { return false }
    let phase = unsafe mk.phaseNow
    guard phase == .sweeping || phase == .swept else { return false }
    let t0 = nanoseconds()
    let log = unsafe mk.pointee.log
    if phase == .sweeping {
        _ = unsafe sweepCycle(vm, mk, inPause: true)
        unsafe log.pointee.counters.sweepsFinishedInPause &+= 1
    }
    unsafe applyInStop(vm, mk)
    if cause == .entries {
        unsafe log.pointee.counters.sweepsFinishedForEntries &+= 1
    } else {
        unsafe log.pointee.counters.sweepsFinishedForOld &+= 1
    }
    unsafe log.pointee.counters.sweepsFinishedForEntriesNs &+= nanoseconds() &- t0
    return true
}

/// Why module 4 ran a full collection.
enum FullCause: UInt8, Sendable {
    /// A scavenge left old space past its soft limit.
    case softLimit
    /// The entry table was full.
    case entries
    /// A stress flag or the host.
    case other
    /// Large bytes, part 2: an old (large) allocation found no room under
    /// the soft limit or no run of its length.
    case oldAllocation
}

/// A full collection is about to run in this stop (or, for an old
/// allocation, ran: `record` was taken before it). With concurrent marking
/// configured, one forced by space is a fallback: a provisioning failure,
/// counted by the phase it found and by what ran out, never hidden. Its
/// circumstances are recorded (large bytes, part 2).
func noteFullCollection(_ vm: VMPointer, _ cause: FullCause, record: FallbackRecord? = nil) {
    guard let mk = unsafe vm.pointee.marking, cause != .other else { return }
    let log = unsafe mk.pointee.log
    let r = unsafe record ?? fallbackRecord(vm, cause)!
    unsafe log.pointee.counters.fallbacks &+= 1
    switch r.phase {
    case .idle: unsafe log.pointee.counters.fallbacksIdle &+= 1
    case .marking: unsafe log.pointee.counters.fallbacksMarking &+= 1
    case .sweeping, .swept: unsafe log.pointee.counters.fallbacksSweeping &+= 1
    }
    switch cause {
    case .entries: unsafe log.pointee.counters.fallbacksEntries &+= 1
    case .softLimit: unsafe log.pointee.counters.fallbacksSoftLimit &+= 1
    case .oldAllocation: unsafe log.pointee.counters.fallbacksOldAllocation &+= 1
    case .other: break
    }
    unsafe log.pointee.fallbackRecords.append(r)
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
    r.markerQoS = unsafe m.pointee.qos
    r.wantUserInitiated = unsafe mk.pointee.wantUserInitiated.pointee.load(ordering: .relaxed)
    return r
}
