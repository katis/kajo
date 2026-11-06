import Darwin
import Synchronization

// When a cycle starts and how its snapshot is taken (docs/modules/
// concurrent-marking.md "Initial mark", "Triggers"). The initial mark
// rides on a stop-the-world scavenge of every nursery: at its end nothing
// is young but the survivors, which are scanned as roots (ADR 0007), so
// every old object reachable at the snapshot is reached from a root, a
// survivor or another snapshot object. Module 7 replaces `initialMark`'s
// caller (an initial-mark pause that scans every nursery instead of
// scavenging); everything below takes roots and nurseries as given.

/// Before module 4's scavenge in a stop: a finished sweep is applied (the
/// next pause publishes it), and in the textbook test mode the old map is
/// remembered so promotions can be greyed after.
func beforeScavenge(_ vm: VMPointer) -> RawArray<UInt64>? {
    guard let mk = unsafe vm.pointee.marking else { return nil }
    if unsafe mk.phaseNow == .swept && !mk.pointee.config.stress.contains(.sweepNeverApplies) { unsafe applyInStop(vm, mk) }
    let sw = unsafe mk.pointee.config.testSwitches
    guard sw.literal && sw.literalGrey, unsafe mk.phaseNow == .marking else { return nil }
    let om = unsafe mk.pointee.om
    let words = Int((om.highWater &+ 63) &>> 6)
    var before = RawArray<UInt64>(repeating: 0, count: words)
    for w in 0..<words { before[w] = om.oldMap.word(w) }
    return before
}

/// After module 4's scavenge in the same stop (world stopped, `roots` the
/// stop's): record the promotion sample, decide whether a cycle starts, and
/// if so take its snapshot. Nothing starts while a full collection is due.
func afterScavenge(_ vm: VMPointer, roots: [Oop], literalBefore: RawArray<UInt64>?) {
    guard let mk = unsafe vm.pointee.marking else { return }
    var before = literalBefore
    if before != nil {
        unsafe greyPromoted(mk, before: before!)
        before!.free()
    }
    let om = unsafe mk.pointee.om
    let log = unsafe mk.pointee.log
    let now = nanoseconds()
    let promoted = unsafe (vm.pointee.nursery?.pointee.state.pointee.counters.promotedBytes ?? 0) &+ om.allocationCounters.allocatedBytes
    unsafe log.pointee.samples.append((now, promoted))
    if unsafe log.pointee.samples.count > MarkingConfig.rateWindow { unsafe log.pointee.samples.removeFirst() }
    unsafe countOldEntries(vm, mk)
    unsafe updateWantedQoS(mk, oldEntries: nil)
    if unsafe mk.phaseNow != .idle || fullCollectionDue(vm) { return }
    guard let trigger = unsafe decideTrigger(mk) else { return }
    unsafe initialMark(vm, mk, roots: roots, trigger: trigger, literal: false)
}

/// Keep the old-entry estimate (world stopped). Module 7's initial-mark
/// pause calls it too.
func countOldEntriesAtPause(_ vm: VMPointer, _ mk: MarkingPointer) { unsafe countOldEntries(vm, mk) }

private func countOldEntries(_ vm: VMPointer, _ mk: MarkingPointer) {
    let om = unsafe mk.pointee.om
    let log = unsafe mk.pointee.log
    // Module 7: promotion by young collections counts too.
    let promoted = unsafe (vm.pointee.nursery?.pointee.state.pointee.counters.promotedObjects ?? 0)
        &+ (vm.pointee.young?.pointee.promotedObjects.pointee.load(ordering: .relaxed) ?? 0)
    let allocated = om.allocationCounters.allocations
    let collections = om.counters.collections
    if unsafe log.pointee.lastCollections != collections {
        // Module 1 collected (or this is the first sample): count.
        let words = Int((om.highWater &+ 63) &>> 6)
        var n: UInt64 = 0
        for w in 0..<words { n &+= UInt64(om.oldMap.word(w).nonzeroBitCount) }
        unsafe log.pointee.oldEntries = n
        unsafe log.pointee.lastCollections = collections
    } else {
        unsafe log.pointee.oldEntries &+= (promoted &- log.pointee.lastPromotedObjects) &+ (allocated &- log.pointee.lastOldAllocations)
    }
    unsafe log.pointee.lastPromotedObjects = promoted
    unsafe log.pointee.lastOldAllocations = allocated
}

/// The promotion rate over the last scavenges (bytes per second; 0 with
/// fewer than two samples).
func promotionRate(_ mk: MarkingPointer) -> Double {
    let s = unsafe mk.pointee.log.pointee.samples
    guard s.count >= 2, let a = s.first, let b = s.last, b.ns > a.ns else { return 0 }
    return Double(b.promoted &- a.promoted) / (Double(b.ns &- a.ns) / 1e9)
}

/// Decide at the end of a scavenge. Records the rate and the prediction
/// either way.
func decideTrigger(_ mk: MarkingPointer) -> CycleTrigger? {
    unsafe decideTrigger(mk, rate: promotionRate(mk), oldEntries: nil, record: true)
}

/// The decision on a given promotion rate (module 7 samples between
/// stops). `record`: world stopped, the rate and the prediction are kept
/// in the log; module 7 decides outside stops and only reads the log.
func decideTrigger(_ mk: MarkingPointer, rate: Double, oldEntries: UInt64?, record: Bool) -> CycleTrigger? {
    let c = unsafe mk.pointee.config
    let om = unsafe mk.pointee.om
    let log = unsafe mk.pointee.log
    let inUse = Double(om.blocksInUse * BlockHeap.blockBytes)
    let soft = Double(om.softLimitBlocks * BlockHeap.blockBytes)
    var fillNs: UInt64 = 0
    var predicted = false
    if c.safetyFactor > 0 && rate > 0 && inUse >= MarkingConfig.predictorFrom * soft {
        let fill = Swift.max(0, soft - inUse) / rate * 1e9
        fillNs = UInt64(Swift.min(fill, 1e18))
        let last = unsafe log.pointee.lastCycleNs
        let cycleNs = last > 0 ? Double(last) : inUse / MarkingConfig.assumedMarkBytesPerSecond * 1e9
        predicted = fill < c.safetyFactor * cycleNs
    }
    if record {
        unsafe log.pointee.counters.lastPromotionBytesPerSecond = rate
        unsafe log.pointee.counters.lastPredictedFillNs = fillNs
    }
    if c.stress.contains(.cycleAtEveryScavenge) { return .forced }
    if inUse >= c.floor * soft { return .floor }
    if unsafe Double(oldEntries ?? log.pointee.oldEntries) >= c.floor * Double(om.entryCapacity) { return .entries }
    return predicted ? .predictor : nil
}

/// The policy's QoS: user-initiated while the headroom of old space (free
/// fraction of the soft limit) or of the entry table (free fraction of its
/// capacity, the old entries `oldEntries` or the log's estimate taken as
/// used) is below the threshold. The marker takes it at its next poll.
/// World stopped, or (module 7, large bytes part 2) any participant: it
/// reads the pools under their lock and stores one atomic.
func updateWantedQoS(_ mk: MarkingPointer, oldEntries: UInt64?) {
    if unsafe mk.pointee.config.testSwitches.qosOnBlocksOnly && oldEntries != nil { return }
    let low = unsafe wantsRaise(mk, oldEntries: oldEntries ?? mk.pointee.log.pointee.oldEntries,
                                blocksOnly: mk.pointee.config.testSwitches.qosOnBlocksOnly)
    // Raised as soon as headroom is low; lowered only when a cycle ends
    // with headroom above the threshold (`applyInStop`).
    if low { unsafe mk.pointee.wantUserInitiated.pointee.store(true, ordering: .relaxed) }
}

/// Either resource's headroom is below the threshold.
func wantsRaise(_ mk: MarkingPointer, oldEntries: UInt64, blocksOnly: Bool) -> Bool {
    let om = unsafe mk.pointee.om
    let soft = om.softLimitBlocks
    let headroom = Double(Swift.max(0, soft - om.blocksInUse)) / Double(Swift.max(1, soft))
    let cap = Double(Swift.max(1, om.entryCapacity))
    let entryHeadroom = Swift.max(0, 1 - Double(oldEntries) / cap)
    let threshold = unsafe mk.pointee.config.escalateBelow
    return headroom < threshold || (!blocksOnly && entryHeadroom < threshold)
}

/// Take the snapshot and grey the roots (world stopped). `literal`: the
/// textbook protocol of the tests, in a pause of its own with young objects
/// alive and unscanned.
func initialMark(_ vm: VMPointer, _ mk: MarkingPointer, roots: [Oop], trigger: CycleTrigger, literal: Bool) {
    precondition(unsafe mk.phaseNow == .idle, "an initial mark while a cycle runs")
    let t0 = nanoseconds()
    let om = unsafe mk.pointee.om
    let log = unsafe mk.pointee.log
    let m = unsafe mk.pointee.marker
    let snap = unsafe mk.pointee.snapshot
    // No context continues a pre-snapshot block: one that does must refill,
    // and the refill stamps the block with this cycle.
    om.retireAllContexts()
    let cycle = unsafe mk.cycleNow &+ 1
    om.setBlockStamp(UInt32(truncatingIfNeeded: cycle))
    let hw = om.highWater
    let words = Int((hw &+ 63) &>> 6)
    let old = om.oldMap
    var entries: UInt64 = 0
    for w in 0..<words {
        let v = old.word(w)
        snap.setWord(w, v)
        entries &+= UInt64(v.nonzeroBitCount)
    }
    unsafe log.pointee.snapshotWords = words
    let t1 = nanoseconds()

    unsafe resetBuffersAndQueue(mk)
    unsafe dropMarkerWork(mk)
    unsafe m.pointee.markedObjects = 0
    unsafe m.pointee.markedBytes = 0
    unsafe m.pointee.chunksSplit = 0
    unsafe m.pointee.markCpuNs = 0
    unsafe m.pointee.markWallNs = 0
    unsafe m.pointee.sweepNs = 0
    unsafe m.pointee.sweepCpuNs = 0
    unsafe m.pointee.entriesFreed = 0
    unsafe m.pointee.bytesFreed = 0
    om.setMarkingActive(true)
    // Module 6: a relocation planned for this cycle counts live bytes.
    unsafe relocationAtInitialMark(vm, mk, cycle: cycle)
    // Roots: module 3's and module 1's full root set. Every word naming a
    // snapshot entry is marked and queued in grey packets.
    unsafe greyRoots(mk, roots)
    om.forEachRoot(extraRoots: []) { unsafe greyIfCandidate(mk, om, m, $0.raw) }
    let t2 = nanoseconds()
    if let y = unsafe vm.pointee.young {
        // Module 7: no scavenge before this snapshot. Every nursery's young
        // bodies are roots (the young-root scan, concurrent-young Part 3);
        // the snapshot is the old map, which never holds a young entry or a
        // deferred entry free (amendment 17), except under the test switch
        // that brings the experiment's bug back.
        if unsafe !literal && y.pointee.config.testSwitches.youngRoots {
            let ts = nanoseconds()
            let words = unsafe youngRootScan(vm, mk)
            unsafe noteYoungRootScan(y, nanoseconds() &- ts, words)
        }
        unsafe snapshotDeferred(vm, y, mk)
    } else if unsafe !literal && !mk.pointee.config.testSwitches.noSurvivorRoots, let n = unsafe vm.pointee.nursery {
        // Survivors are roots (ADR 0007): every slot, weak and ephemeron
        // slots included (their referents survive this cycle).
        for k in unsafe 0..<n.pointee.count {
            let surv = unsafe n.survivors(k).pointee.survLog
            for i in 0..<surv.count { unsafe greySlots(mk, om, m, UInt64(surv[i]) &<< 4) }
        }
    }
    let t3 = nanoseconds()
    unsafe queueGreyStack(mk)
    let soft = om.softLimitBlocks * BlockHeap.blockBytes
    var rec = CycleRecord()
    rec.number = cycle
    rec.trigger = trigger
    rec.inUseBytes = UInt64(om.blocksInUse * BlockHeap.blockBytes)
    rec.softLimitBytes = UInt64(soft)
    rec.promotionBytesPerSecond = unsafe log.pointee.counters.lastPromotionBytesPerSecond
    rec.predictedFillNs = unsafe log.pointee.counters.lastPredictedFillNs
    rec.snapshotNs = t1 &- t0
    rec.rootsNs = t2 &- t1
    rec.survivorsNs = t3 &- t2
    rec.snapshotEntries = entries
    unsafe log.pointee.begin(rec)
    unsafe log.pointee.startNs = t0
    unsafe log.pointee.counters.cycles &+= 1
    switch trigger {
    case .floor: unsafe log.pointee.counters.cyclesByFloor &+= 1
    case .predictor: unsafe log.pointee.counters.cyclesByPredictor &+= 1
    case .entries: unsafe log.pointee.counters.cyclesByEntries &+= 1
    case .forced: unsafe log.pointee.counters.cyclesForced &+= 1
    }
    unsafe log.pointee.counters.initialMarkNs &+= t3 &- t0
    // The barrier is on before any mutator runs again (the stop's release
    // orders it); then the marker is woken. Bit 0 only: bits 1 and up are
    // module 7's count (collectors review, finding 4).
    unsafe markingBarrierOn(mk)
    unsafe pthread_mutex_lock(mk.pointee.lock)
    unsafe mk.pointee.cycle.pointee.store(cycle, ordering: .releasing)
    unsafe mk.setPhase(.marking)
    unsafe pthread_cond_broadcast(mk.pointee.cond)
    unsafe pthread_mutex_unlock(mk.pointee.lock)
}

private func greyRoots(_ mk: MarkingPointer, _ roots: [Oop]) {
    let om = unsafe mk.pointee.om
    let m = unsafe mk.pointee.marker
    for r in roots { unsafe greyIfCandidate(mk, om, m, r.raw) }
}

/// The stopper's grey stack becomes grey packets in the queue.
private func queueGreyStack(_ mk: MarkingPointer) {
    let m = unsafe mk.pointee.marker
    let q = unsafe mk.pointee.queue
    unsafe pthread_mutex_lock(mk.pointee.lock)
    while unsafe m.pointee.stack.count > 0 {
        let p = unsafe takeBufferLocked(q)
        var n = 0
        while unsafe n < SATBBuffer.capacity, let v = unsafe m.pointee.stack.popLast() {
            unsafe p[n] = v
            n &+= 1
        }
        unsafe q.pointee.items.append(MarkItem(words: p, count: n, grey: true))
    }
    unsafe pthread_mutex_unlock(mk.pointee.lock)
}

/// Every worker's SATB buffer emptied and every queued item discarded
/// (world stopped): with `markingAlwaysOn` the barrier runs between cycles,
/// and what it recorded then means nothing.
func resetBuffersAndQueue(_ mk: MarkingPointer) {
    for k in unsafe 0..<mk.pointee.workerCount { unsafe mk.buffer(k).pointee.count = 0 }
    let q = unsafe mk.pointee.queue
    unsafe pthread_mutex_lock(mk.pointee.lock)
    while let it = unsafe q.pointee.items.popLast() { unsafe q.pointee.free.append(it.words) }
    unsafe pthread_mutex_unlock(mk.pointee.lock)
}

/// The textbook rule (test mode): objects promoted by this scavenge join
/// the snapshot marked and grey, so the marker scans them.
private func greyPromoted(_ mk: MarkingPointer, before: RawArray<UInt64>) {
    let om = unsafe mk.pointee.om
    let m = unsafe mk.pointee.marker
    let snap = unsafe mk.pointee.snapshot
    for w in 0..<before.count {
        var bits = om.oldMap.word(w) & ~before[w]
        while bits != 0 {
            let b = UInt64(bits.trailingZeroBitCount)
            bits &= bits &- 1
            let e = UInt64(w) &<< 6 | b
            snap.insert(e)
            unsafe greyIfCandidate(mk, om, m, e &<< 4)
        }
    }
    unsafe queueGreyStack(mk)
}
