import Darwin
import Synchronization

// The final mark (docs/modules/concurrent-marking.md "Final mark"): a stop
// the marker requests when its stack and the queue are empty. With the
// world stopped: drain every worker's partial SATB buffer, every queued
// item and the marker's stack; resolve ephemerons; filter dead holders out
// of the remembered set; nil weak slots; verify; then the sweep may run.
//
// The final mark on the devices (docs/modules/final-mark.md): the tracing
// the stop does is bounded in work (`MarkingConfig.finalMarkWork` units:
// an SATB entry taken, an object traced, a large object's chunk as
// `MarkChunk.weight`). Past the bound, or with a young-root scan still
// owed, the stop gives up before anything is decided: the marking bit stays
// on, what it took stays on the marker's stack, the world is released and
// the marker drains concurrently and asks again. After
// `finalMarkGiveUps` give-ups in a cycle the final mark finishes whatever
// it costs (counted, `finalOverruns`). Firing ephemerons is past the
// commit point and not bounded (counted in the units).

/// The final mark of cycle `cycle` (world stopped; the stopper is the
/// marker participant). Nothing happens if that cycle is no longer marking.
func runFinalMark(_ vm: VMPointer, _ mk: MarkingPointer, _ stop: StopContext, cycle: UInt64,
                  context: FinalMarkContext = FinalMarkContext()) {
    guard unsafe mk.phaseNow == .marking && mk.cycleNow == cycle else { return }
    unsafe markStop(vm, .finalMark)
    let t0 = stop.workStartNs == 0 ? nanoseconds() : stop.workStartNs
    let om = unsafe mk.pointee.om
    let m = unsafe mk.pointee.marker
    let log = unsafe mk.pointee.log
    let config = unsafe mk.pointee.config
    let giveUps = unsafe log.pointee.currentRecord?.finalGiveUps ?? 0
    let mayGiveUp = !config.testSwitches.unboundedFinalMark && giveUps < UInt64(config.finalMarkGiveUps)
    let bound = mayGiveUp ? config.finalMarkWork : Int.max
    var units = 0

    /// Give up: nothing decided yet; the marking bit is still on.
    func giveUp() {
        if var r = unsafe log.pointee.currentRecord {
            r.finalGiveUps &+= 1
            r.finalWorkUnitsMax = Swift.max(r.finalWorkUnitsMax, UInt64(units))
            unsafe log.pointee.currentRecord = r
        }
        unsafe log.pointee.counters.finalGiveUps &+= 1
    }

    // 0. Young roots: the marker scans every owed nursery before it asks;
    // one still owed (a manual final mark, a skipped scan) is work for
    // outside the stop.
    if unsafe rootScansPending(mk) {
        if mayGiveUp { giveUp(); return }
        units &+= Int(truncatingIfNeeded: unsafe finishRootScansInStop(vm, mk))
    }

    // 1. Drain: partial buffers, queued items, the stack, within the bound.
    var drained: UInt64 = 0
    var pushed: UInt64 = 0, handed: UInt64 = 0
    for k in unsafe 0..<mk.pointee.workerCount {
        let b = unsafe mk.buffer(k)
        unsafe takeItem(mk, om, m, MarkItem(words: b.pointee.words, count: b.pointee.count, grey: false))
        drained &+= unsafe UInt64(b.pointee.count)
        units &+= unsafe b.pointee.count
        unsafe b.pointee.count = 0
        pushed &+= unsafe b.pointee.pushed
        handed &+= unsafe b.pointee.handed
    }
    while units < bound, let it = unsafe popItem(mk) {
        unsafe takeItem(mk, om, m, it)
        drained &+= unsafe UInt64(it.count)
        units &+= unsafe it.count
        unsafe returnBuffer(mk, it.words)
    }
    drained &+= unsafe UInt64(m.pointee.stack.count)
    if unsafe !drainStack(mk, om, m, units: &units, bound: bound) || (units >= bound && queueHasItems(mk)) {
        giveUp()
        return
    }
    let t1 = nanoseconds()

    // 2. Ephemerons: those whose key got marked are traced, to a fixpoint
    // (tracing can mark another key), within the bound; the rest are
    // queued for finalization and traced, key included, so key and value
    // survive this cycle. Queueing is the commit point: from there on the
    // stop finishes.
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
                units &+= 1
            } else {
                i &+= 1
            }
        }
        if progressed {
            if unsafe !drainStack(mk, om, m, units: &units, bound: bound) {
                giveUp()
                return
            }
            continue
        }
        while let e = unsafe m.pointee.ephemerons.popLast() {
            om.queueForFinalization(Oop(raw: e))
            queued &+= 1
            unsafe greySlots(mk, om, m, e)
            units &+= 1
        }
        _ = unsafe drainStack(mk, om, m, units: &units, bound: .max)
    }
    if giveUps >= UInt64(config.finalMarkGiveUps) && !config.testSwitches.unboundedFinalMark {
        unsafe log.pointee.counters.finalOverruns &+= 1
    }
    let t2 = nanoseconds()
    if !config.stress.contains(.markingAlwaysOn) { unsafe markingBarrierOff(mk) }

    // 3. Filter the remembered set: a holder that is a snapshot entry and
    // unmarked is dead and about to be freed; the next scavenge must not
    // scan it. After the ephemerons, whose tracing marks objects too (a
    // holder reachable only through an ephemeron's value was filtered
    // before this follow-up and its young referents went unscanned).
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

    if var r = unsafe log.pointee.currentRecord {
        r.finalTtspNs = stop.timeToSafepointNs
        r.drainNs = t1 &- t0
        r.drainedEntries = drained
        r.ephemeronNs = t2 &- t1
        r.filterNs = t3 &- t2
        r.finalWorkUnits = UInt64(units)
        r.finalWorkUnitsMax = Swift.max(r.finalWorkUnitsMax, UInt64(units))
        r.ephemeronItems = items
        r.weakNs = t4 &- t3
        r.verifyNs = t5 &- t4
        r.finalPauseNs = stop.timeToSafepointNs &+ (t5 &- t0)
        r.markCpuNs = unsafe m.pointee.markCpuNs
        r.markWallNs = unsafe m.pointee.markWallNs
        r.markedObjects = unsafe m.pointee.markedObjects
        r.markedBytes = unsafe m.pointee.markedBytes
        r.satbPushed = pushed
        r.satbBuffers = handed
        r.markerQoS = unsafe m.pointee.qos
        r.floatingObjects = verdict.floatingObjects
        r.floatingBytes = verdict.floatingBytes
        r.finalBeforeRequestNs = stop.beforeRequestNs
        r.finalCollectionsOpen = stop.collectionsOpen
        r.finalSlowest = stop.slowest
        r.finalSlowestVia = stop.slowestVia
        r.finalParkedFromWaits = stop.parkedFromWaits
        r.finalStopperQoS = context.qos
        r.finalThermal = context.thermal
        unsafe log.pointee.currentRecord = r
    }
    unsafe log.pointee.counters.finalMarkNs &+= t5 &- t0
    unsafe log.pointee.counters.markedObjects &+= m.pointee.markedObjects
    unsafe log.pointee.counters.markedBytes &+= m.pointee.markedBytes
    unsafe log.pointee.counters.chunksSplit &+= m.pointee.chunksSplit
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
        if let n = unsafe vm.pointee.nursery {
            unsafe n.pointee.fullRequestInfo.pointee.store(encodeFullRequest(.verifier, .inStop, worker: -1), ordering: .relaxed)
            unsafe n.pointee.fullRequested.pointee.store(true, ordering: .relaxed)
        }
        return
    }
    // Module 6: the relocation set and the frame pins.
    unsafe relocationAtFinalMark(vm, mk, cycle: cycle)
    let t6 = nanoseconds()
    // The sweep may start: pending-dead entries are skipped by the
    // verifiers until it has passed them.
    om.setPendingDead(unsafe mk.pointee.snapshot)
    unsafe m.pointee.sweepCursor = 0
    unsafe m.pointee.sweepWords = log.pointee.snapshotWords
    unsafe log.pointee.sweepStartNs = nanoseconds()
    unsafe m.pointee.sweepStamp = UInt32(truncatingIfNeeded: cycle)
    let blocks = om.heap.blockCount
    if unsafe m.pointee.sweepLive.count != blocks {
        unsafe m.pointee.sweepLive.free()
        unsafe m.pointee.sweepLive = RawArray(repeating: 0, count: blocks)
    } else if let base = unsafe m.pointee.sweepLive.baseAddress {
        unsafe base.update(repeating: 0, count: blocks)
    }
    let t7 = nanoseconds()
    if var r = unsafe log.pointee.currentRecord {
        r.relocationAtFinalNs = t6 &- t5
        r.sweepSetupNs = t7 &- t6
        r.finalWorkNs = t7 &- t0
        if context.core.ok { r.finalStopperCore = CoreTime.now().since(context.core) }
        unsafe log.pointee.currentRecord = r
    }
    unsafe pthread_mutex_lock(mk.pointee.lock)
    unsafe mk.setPhase(.sweeping)
    unsafe pthread_cond_broadcast(mk.pointee.cond)
    unsafe pthread_mutex_unlock(mk.pointee.lock)
}
