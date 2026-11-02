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
                    bytes &+= Header(raw: om.headerWord(raw)).bodyBytes
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
    let ri = unsafe log.pointee.current
    if ri >= 0 {
        unsafe log.pointee.records[ri].sweepNs = m.pointee.sweepNs
        unsafe log.pointee.records[ri].sweepCpuNs = m.pointee.sweepCpuNs
        unsafe log.pointee.records[ri].entriesFreed = m.pointee.entriesFreed
        unsafe log.pointee.records[ri].bytesFreed = m.pointee.bytesFreed
        unsafe log.pointee.records[ri].blocksFreed = UInt64(blocks)
        unsafe log.pointee.records[ri].applyNs = t1 &- t0
        unsafe log.pointee.records[ri].durationNs = t1 &- log.pointee.startNs
        unsafe log.pointee.records[ri].completed = true
    }
    unsafe log.pointee.lastCycleNs = t1 &- log.pointee.startNs
    unsafe log.pointee.current = -1
    unsafe log.pointee.counters.cyclesCompleted &+= 1
    unsafe log.pointee.counters.applies &+= 1
    unsafe log.pointee.counters.applyNs &+= t1 &- t0
    unsafe log.pointee.counters.sweepNs &+= m.pointee.sweepNs
    unsafe log.pointee.counters.entriesFreed &+= m.pointee.entriesFreed
    unsafe log.pointee.oldEntries &-= Swift.min(log.pointee.oldEntries, m.pointee.entriesFreed)
    unsafe log.pointee.counters.blocksFreed &+= UInt64(blocks)
    // The policy lowers the marker only when a cycle ends with headroom
    // above the threshold.
    let soft = om.softLimitBlocks
    let headroom = Double(Swift.max(0, soft - om.blocksInUse)) / Double(Swift.max(1, soft))
    if unsafe headroom >= mk.pointee.config.escalateBelow {
        unsafe mk.pointee.wantUserInitiated.pointee.store(false, ordering: .relaxed)
    }
}

/// Abandon a marking cycle (world stopped): barrier off, marks and snapshot
/// cleared, buffers and queue discarded; the marker drops its work at its
/// next poll (the cycle number changed). Nothing was freed.
func abortCycle(_ vm: VMPointer, _ mk: MarkingPointer) {
    let om = unsafe mk.pointee.om
    let log = unsafe mk.pointee.log
    if unsafe !mk.pointee.config.stress.contains(.markingAlwaysOn) { unsafe mk.pointee.barrier.pointee.store(0, ordering: .relaxed) }
    om.clearMarks()
    let snap = unsafe mk.pointee.snapshot
    for w in unsafe 0..<log.pointee.snapshotWords { snap.setWord(w, 0) }
    unsafe resetBuffersAndQueue(mk)
    unsafe dropMarkerWork(mk)
    om.setPendingDead(nil)
    om.setMarkingActive(false)
    unsafe relocationAtCycleEnd(vm, completed: false)
    let ri = unsafe log.pointee.current
    if ri >= 0 { unsafe log.pointee.records[ri].aborted = true }
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

/// Why module 4 ran a full collection.
enum FullCause {
    /// A scavenge left old space past its soft limit.
    case softLimit
    /// The entry table was full.
    case entries
    /// A stress flag or the host.
    case other
}

/// A full collection is about to run in this stop. With concurrent marking
/// configured, one forced by space is a fallback: a provisioning failure,
/// counted by the phase it found, never hidden.
func noteFullCollection(_ vm: VMPointer, _ cause: FullCause) {
    guard let mk = unsafe vm.pointee.marking, cause != .other else { return }
    let log = unsafe mk.pointee.log
    unsafe log.pointee.counters.fallbacks &+= 1
    switch unsafe mk.phaseNow {
    case .idle: unsafe log.pointee.counters.fallbacksIdle &+= 1
    case .marking: unsafe log.pointee.counters.fallbacksMarking &+= 1
    case .sweeping, .swept: unsafe log.pointee.counters.fallbacksSweeping &+= 1
    }
}
