import Darwin
import Synchronization

// The final mark (docs/modules/concurrent-marking.md "Final mark"): a stop
// the marker requests when its stack and the queue are empty. With the
// world stopped: drain every worker's partial SATB buffer, every queued
// item and the marker's stack; filter dead holders out of the remembered
// set; resolve ephemerons; nil weak slots; verify; then the sweep may run.

/// The final mark of cycle `cycle` (world stopped; the stopper is the
/// marker participant). Nothing happens if that cycle is no longer marking.
func runFinalMark(_ vm: VMPointer, _ mk: MarkingPointer, _ stop: StopContext, cycle: UInt64) {
    guard unsafe mk.phaseNow == .marking && mk.cycleNow == cycle else { return }
    unsafe markStop(vm, .finalMark)
    let t0 = nanoseconds()
    let om = unsafe mk.pointee.om
    let m = unsafe mk.pointee.marker
    let log = unsafe mk.pointee.log
    let config = unsafe mk.pointee.config
    if !config.stress.contains(.markingAlwaysOn) { unsafe mk.pointee.barrier.pointee.store(0, ordering: .relaxed) }

    // 1. Drain: partial buffers, queued items, the stack.
    var drained: UInt64 = 0
    var pushed: UInt64 = 0, handed: UInt64 = 0
    for k in unsafe 0..<mk.pointee.workerCount {
        let b = unsafe mk.buffer(k)
        unsafe takeItem(mk, om, m, MarkItem(words: b.pointee.words, count: b.pointee.count, grey: false))
        drained &+= unsafe UInt64(b.pointee.count)
        unsafe b.pointee.count = 0
        pushed &+= unsafe b.pointee.pushed
        handed &+= unsafe b.pointee.handed
    }
    while let it = unsafe popItem(mk) {
        unsafe takeItem(mk, om, m, it)
        drained &+= unsafe UInt64(it.count)
        unsafe returnBuffer(mk, it.words)
    }
    drained &+= unsafe UInt64(m.pointee.stack.count)
    unsafe drainStack(mk, om, m)
    let t1 = nanoseconds()

    // 2. Filter the remembered set: a holder that is a snapshot entry and
    // unmarked is dead and about to be freed; the next scavenge must not
    // scan it.
    var filtered: UInt64 = 0
    if !config.testSwitches.noRememberedFilter, let n = unsafe vm.pointee.nursery {
        func filter(_ list: UnsafeMutablePointer<RawArray<UInt64>>) {
            var j = 0
            let count = unsafe list.pointee.count
            for i in 0..<count {
                let o = unsafe list.pointee[i]
                if unsafe isUnmarkedSnapshotEntry(mk, om, o) {
                    unsafe n.remMarker(o).pointee.store(0, ordering: .relaxed)
                    filtered &+= 1
                } else {
                    unsafe list.pointee[j] = o
                    j &+= 1
                }
            }
            unsafe list.pointee.truncate(j)
        }
        // Every list of every nursery (module 7: per-nursery buffers and
        // carried lists; a holder may be in several, and leaves them all).
        for k in unsafe 0..<n.pointee.count {
            for i in unsafe 0..<n.pointee.bufferOwners { unsafe filter(n.remBuffer(i, k)) }
            unsafe filter(n.survivors(k).pointer(to: \NurserySurvivors.carried)!)
        }
    }
    let t2 = nanoseconds()

    // 3. Ephemerons: those whose key got marked are traced, to a fixpoint
    // (tracing can mark another key); the rest are queued for finalization
    // and traced, key included, so key and value survive this cycle.
    var queued: UInt64 = 0
    let items = unsafe UInt64(m.pointee.ephemerons.count)
    while unsafe m.pointee.ephemerons.count > 0 {
        var progressed = false
        var i = 0
        while unsafe i < m.pointee.ephemerons.count {
            let e = unsafe m.pointee.ephemerons[i]
            let key = om.loadAtomic(bodyOffset: om.stateWord(e), 0)
            if unsafe !isUnmarkedSnapshotEntry(mk, om, key) {
                unsafe greySlots(mk, om, m, e)
                unsafe m.pointee.ephemerons[i] = m.pointee.ephemerons[m.pointee.ephemerons.count - 1]
                _ = unsafe m.pointee.ephemerons.popLast()
                progressed = true
            } else {
                i &+= 1
            }
        }
        if progressed {
            unsafe drainStack(mk, om, m)
            continue
        }
        while let e = unsafe m.pointee.ephemerons.popLast() {
            om.queueForFinalization(Oop(raw: e))
            queued &+= 1
            unsafe greySlots(mk, om, m, e)
        }
        unsafe drainStack(mk, om, m)
    }
    let t3 = nanoseconds()

    // 4. Weak slots naming an unmarked snapshot entry become nil (the
    // referent is about to be freed). Stores of nil, marking is over.
    var niled: UInt64 = 0
    let nilObj = om.nilObject
    for k in unsafe 0..<m.pointee.weak.count {
        let o = unsafe m.pointee.weak[k]
        let h = Header(raw: om.headerWord(o))
        let s = om.stateWord(o)
        var i = om.classFormat(h.classIndex).namedSlots
        let n = Int(h.count)
        while i < n {
            if unsafe isUnmarkedSnapshotEntry(mk, om, om.loadAtomic(bodyOffset: s, i)) {
                om.store(Oop(raw: o), i, nilObj)
                niled &+= 1
            }
            i &+= 1
        }
    }
    unsafe m.pointee.weak.removeAll()
    let t4 = nanoseconds()

    // 5. The verifier: a from-scratch traversal against the mark set.
    var verdict = MarkVerdict()
    if om.config.verify {
        verdict = unsafe verifyFinalMark(vm, mk, stop)
        unsafe log.pointee.counters.verifierRuns &+= 1
    }
    let t5 = nanoseconds()

    let ri = unsafe log.pointee.current
    if ri >= 0 {
        unsafe log.pointee.records[ri].finalTtspNs = stop.timeToSafepointNs
        unsafe log.pointee.records[ri].drainNs = t1 &- t0
        unsafe log.pointee.records[ri].drainedEntries = drained
        unsafe log.pointee.records[ri].filterNs = t2 &- t1
        unsafe log.pointee.records[ri].ephemeronNs = t3 &- t2
        unsafe log.pointee.records[ri].ephemeronItems = items
        unsafe log.pointee.records[ri].weakNs = t4 &- t3
        unsafe log.pointee.records[ri].verifyNs = t5 &- t4
        unsafe log.pointee.records[ri].finalPauseNs = stop.timeToSafepointNs &+ (t5 &- t0)
        unsafe log.pointee.records[ri].markCpuNs = m.pointee.markCpuNs
        unsafe log.pointee.records[ri].markWallNs = m.pointee.markWallNs
        unsafe log.pointee.records[ri].markedObjects = m.pointee.markedObjects
        unsafe log.pointee.records[ri].markedBytes = m.pointee.markedBytes
        unsafe log.pointee.records[ri].satbPushed = pushed
        unsafe log.pointee.records[ri].satbBuffers = handed
        unsafe log.pointee.records[ri].markerQoS = m.pointee.qos
        unsafe log.pointee.records[ri].floatingObjects = verdict.floatingObjects
        unsafe log.pointee.records[ri].floatingBytes = verdict.floatingBytes
    }
    unsafe log.pointee.counters.finalMarkNs &+= t5 &- t0
    unsafe log.pointee.counters.markedObjects &+= m.pointee.markedObjects
    unsafe log.pointee.counters.markedBytes &+= m.pointee.markedBytes
    unsafe log.pointee.counters.markerCpuNs &+= m.pointee.markCpuNs
    unsafe log.pointee.counters.remFiltered &+= filtered
    unsafe log.pointee.counters.ephemeronsQueued &+= queued
    unsafe log.pointee.counters.weakSlotsNiled &+= niled
    unsafe log.pointee.counters.missed &+= verdict.missed
    unsafe log.pointee.counters.floatingBytes &+= verdict.floatingBytes
    unsafe m.pointee.markedCycle = cycle

    if verdict.failed {
        unsafe m.pointee.blockLive = nil
        // Checked builds trapped in `record`; here the cycle cannot be
        // trusted: nothing is freed, and a full collection falls back.
        unsafe abortCycle(vm, mk)
        unsafe log.pointee.counters.fallbacksVerifier &+= 1
        if let n = unsafe vm.pointee.nursery { unsafe n.pointee.fullRequested.pointee.store(true, ordering: .relaxed) }
        return
    }
    // Module 6: the relocation set and the frame pins.
    unsafe relocationAtFinalMark(vm, mk, cycle: cycle)
    // The sweep may start: pending-dead entries are skipped by the
    // verifiers until it has passed them.
    om.setPendingDead(unsafe mk.pointee.snapshot)
    unsafe m.pointee.sweepCursor = 0
    unsafe m.pointee.sweepWords = log.pointee.snapshotWords
    unsafe m.pointee.sweepStamp = UInt32(truncatingIfNeeded: cycle)
    let blocks = om.heap.blockCount
    if unsafe m.pointee.sweepLive.count != blocks {
        unsafe m.pointee.sweepLive.free()
        unsafe m.pointee.sweepLive = RawArray(repeating: 0, count: blocks)
    } else if let base = unsafe m.pointee.sweepLive.baseAddress {
        unsafe base.update(repeating: 0, count: blocks)
    }
    unsafe pthread_mutex_lock(mk.pointee.lock)
    unsafe mk.setPhase(.sweeping)
    unsafe pthread_cond_broadcast(mk.pointee.cond)
    unsafe pthread_mutex_unlock(mk.pointee.lock)
}
