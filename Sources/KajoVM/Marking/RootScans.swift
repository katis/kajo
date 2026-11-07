import Darwin
import Synchronization

// The final mark on the devices (docs/modules/final-mark.md): the young-root
// scan out of the initial mark's stop. Module 7's initial-mark pause walked
// every nursery's young bodies in the stop (2.5 to 5.5 ms on the devices
// under the storm, growing with workers and eden fill). Now the stop only
// records each nursery's ranges and marks its scan owed; the scan runs
// outside any stop, by whoever comes first:
//
// - the marker, at the start of its cycle (the main worker's nursery
//   first), greying onto its own stack and polling every 256 bodies;
// - the collector of the nursery, at the start of its collection and
//   before anything of it moves, handing its candidates to the marker's
//   queue (it is not the marker participant and never sets a mark);
// - the stopper of a stop that moves young objects (module 4's scavenge),
//   or of a final mark that may not give up, in the stop (counted).
//
// Until a nursery's scan is done, the SATB barrier records the overwritten
// value of a store into any young holder of that nursery (`satbRecord`,
// `copySlots`): a slot the scan has not read yet loses no snapshot edge.
// The scan's end is a release store of `none`; the barrier's acquire load
// that reads it orders the store after the scan's read of that slot.
// Nothing of a nursery moves while its scan is owed or under way: only its
// own collection and module 4's scavenge move young objects, and both
// finish the scan first. No model covers this: the young-collection model
// takes the marker's result as given (docs/models/young-collection.md, "O").

/// A nursery's young-root scan for the current cycle.
enum RootScanState {
    /// None owed (no cycle, nothing young at the snapshot, or done).
    static let none: UInt8 = 0
    static let owed: UInt8 = 1
    /// A walker has it (the marker, or the nursery's collector).
    static let claimed: UInt8 = 2
}

/// Indices of `MarkingShared.rootScanStats`.
enum RootScanStat {
    static let byMarker = 0
    static let byCollector = 1
    static let inStop = 2
    /// The marker's claims a stop finished under it (a scavenge).
    static let voided = 3
    static let ns = 4
    static let maxNs = 5
    static let words = 6
    /// Collections that waited for the marker's scan of their nursery.
    static let waits = 7
    static let waitNs = 8
    static let count = 9
}

extension UnsafeMutablePointer where Pointee == MarkingShared {
    @inline(__always)
    func rootScan(_ k: Int) -> UnsafeMutablePointer<Atomic<UInt8>> { unsafe pointee.rootScans + k }

    @inline(__always)
    func rootScanStat(_ i: Int) -> UnsafeMutablePointer<Atomic<UInt64>> { unsafe pointee.rootScanStats + i }
}

/// The SATB barrier's question for a young holder with header `h`: is its
/// nursery's young-root scan owed or under way? An acquire load: reading
/// `none` orders the coming store after the scan's read of the slot.
@inline(__always)
func youngHolderScanOwed(_ mk: MarkingPointer, _ h: UInt64) -> Bool {
    if unsafe mk.pointee.config.testSwitches.noOwedScanBarrier { return false }
    let k = Int(truncatingIfNeeded: (h & Header.nurseryMask) &>> Header.nurseryShift)
    if unsafe k >= mk.pointee.rootScanCount { return false }
    return unsafe mk.rootScan(k).pointee.load(ordering: .acquiring) != RootScanState.none
}

/// Any nursery's scan owed or under way.
func rootScansPending(_ mk: MarkingPointer) -> Bool {
    for k in unsafe 0..<mk.pointee.rootScanCount where unsafe mk.rootScan(k).pointee.load(ordering: .acquiring) != RootScanState.none {
        return true
    }
    return false
}

/// Any nursery's scan claimed by a walker.
private func rootScansClaimed(_ mk: MarkingPointer) -> Bool {
    for k in unsafe 0..<mk.pointee.rootScanCount where unsafe mk.rootScan(k).pointee.load(ordering: .acquiring) == RootScanState.claimed {
        return true
    }
    return false
}

/// The initial mark (world stopped): record every nursery's eden (or
/// current half) from its start to its top and its survivor-from, and
/// mark the scan owed where either is not empty.
func recordYoungRoots(_ vm: VMPointer, _ mk: MarkingPointer) {
    guard let n = unsafe vm.pointee.nursery else { return }
    for k in unsafe 0..<Swift.min(n.pointee.count, mk.pointee.rootScanCount) {
        let a = unsafe n.alloc(k).pointee
        let v = unsafe n.survivors(k).pointee
        let r = unsafe mk.pointee.rootScanRanges + 4 &* k
        unsafe r[0] = a.edenStart
        unsafe r[1] = a.top
        unsafe r[2] = v.survFromStart
        unsafe r[3] = v.survFromTop
        let owed = unsafe r[0] < r[1] || r[2] < r[3]
        unsafe mk.rootScan(k).pointee.store(owed ? RootScanState.owed : RootScanState.none, ordering: .relaxed)
    }
}

/// Every scan none (an abort, world stopped).
func clearRootScans(_ mk: MarkingPointer) {
    for k in unsafe 0..<mk.pointee.rootScanCount { unsafe mk.rootScan(k).pointee.store(RootScanState.none, ordering: .relaxed) }
}

/// Walk nursery `k`'s recorded ranges by back references: every slot of a
/// body whose entry leads to it (not bytes, not a deferred free) goes to
/// `visit`. `poll` runs every 256 bodies; false abandons the walk (answered
/// false). `words` counts the slots visited. The bodies below the recorded
/// tops were allocated before the snapshot and stay where they are until
/// the scan is done (nothing of the nursery moves meanwhile).
@inline(__always)
private func walkYoungRoots(_ mk: MarkingPointer, _ om: ObjectMemory, _ k: Int, _ words: inout UInt64,
                            _ visit: (UInt64) -> Void, _ poll: () -> Bool) -> Bool {
    let r = unsafe mk.pointee.rootScanRanges + 4 &* k
    var bodies = 0
    for part in 0..<2 {
        var a = unsafe r[2 &* part]
        let hi = unsafe r[2 &* part &+ 1]
        while a < hi {
            let br = om.wordAtomic(atOffset: a)
            let size = BackRef.words(br)
            if size == 0 { break }
            let o = BackRef.entryIndex(br) &<< 4
            if o != 0 && om.stateWord(o) == a {
                let h = om.headerWord(o)
                if h & (Header.bytesBit | Header.deferredBit) == 0 {
                    let count = Int(truncatingIfNeeded: (h & Header.countMask) &>> Header.countShift)
                    words &+= UInt64(count)
                    var j = 0
                    while j < count {
                        visit(om.loadAtomic(bodyOffset: a, j))
                        j &+= 1
                    }
                }
            }
            a &+= size &<< 3
            bodies &+= 1
            if bodies & 255 == 0 && !poll() { return false }
        }
    }
    return true
}

/// A scan finished by `who` (a `RootScanStat` index): `none` released, its
/// counters, and the safepoint condition broadcast under its mutex (a
/// collection may be waiting for it in `waitServicing`).
private func finishRootScan(_ vm: VMPointer, _ mk: MarkingPointer, _ k: Int, _ who: Int, ns: UInt64, words: UInt64,
                            broadcast: Bool) {
    unsafe mk.rootScan(k).pointee.store(RootScanState.none, ordering: .releasing)
    unsafe mk.rootScanStat(who).pointee.wrappingAdd(1, ordering: .relaxed)
    unsafe mk.rootScanStat(RootScanStat.ns).pointee.wrappingAdd(ns, ordering: .relaxed)
    unsafe mk.rootScanStat(RootScanStat.words).pointee.wrappingAdd(words, ordering: .relaxed)
    var m = unsafe mk.rootScanStat(RootScanStat.maxNs).pointee.load(ordering: .relaxed)
    while ns > m {
        let (done, now) = unsafe mk.rootScanStat(RootScanStat.maxNs).pointee.compareExchange(expected: m, desired: ns, ordering: .relaxed)
        if done { break }
        m = now
    }
    if broadcast {
        unsafe pthread_mutex_lock(vm.pointee.safepointLock)
        unsafe pthread_cond_broadcast(vm.pointee.safepointCond)
        unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
    }
}

/// The marker (inside the VM, cycle `cycle` marking): claim every owed
/// scan, the main worker's nursery first, and walk it onto its own stack,
/// polling every 256 bodies. A claim a stop finished under it (module 4's
/// scavenge) is dropped. False when the cycle ended under it (its work is
/// dropped, as `markSome` does).
func markerScansYoungRoots(_ vm: VMPointer, _ mk: MarkingPointer, cycle: UInt64) -> Bool {
    if unsafe mk.pointee.config.testSwitches.markerSkipsRootScans { return true }
    let om = unsafe mk.pointee.om
    let m = unsafe mk.pointee.marker
    for k in unsafe 0..<mk.pointee.rootScanCount {
        let slot = unsafe mk.rootScan(k)
        guard unsafe slot.pointee.compareExchange(expected: RootScanState.owed, desired: RootScanState.claimed,
                                                  ordering: .acquiringAndReleasing).exchanged else { continue }
        let t0 = nanoseconds()
        var words: UInt64 = 0
        var ended = false, voided = false
        let done = unsafe walkYoungRoots(mk, om, k, &words, { v in unsafe greyIfCandidate(mk, om, m, v) }) {
            if unsafe !markerPoll(vm, mk, cycle: cycle, phase: .marking) { ended = true; return false }
            if unsafe slot.pointee.load(ordering: .acquiring) != RootScanState.claimed { voided = true; return false }
            return true
        }
        if ended {
            unsafe dropMarkerWork(mk)
            return false
        }
        if voided || !done {
            unsafe mk.rootScanStat(RootScanStat.voided).pointee.wrappingAdd(1, ordering: .relaxed)
            continue
        }
        unsafe finishRootScan(vm, mk, k, RootScanStat.byMarker, ns: nanoseconds() &- t0, words: words, broadcast: true)
    }
    return true
}

/// The marker, its stack and queue empty, while a collector holds a scan:
/// wait (inside the VM, parking for stops) until none is claimed. The
/// collector hands its candidates to the queue before it releases the
/// claim. False when the cycle ended meanwhile.
func markerWaitsForRootScans(_ vm: VMPointer, _ mk: MarkingPointer, cycle: UInt64) -> Bool {
    let mw = unsafe mk.pointee.markerWorker
    unsafe pthread_mutex_lock(vm.pointee.safepointLock)
    unsafe waitServicing(vm, mw) {
        unsafe rootScansClaimed(mk) && mk.cycleNow == cycle && !mk.pointee.stopping.pointee.load(ordering: .relaxed)
    }
    unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
    return unsafe mk.cycleNow == cycle && mk.phaseNow == .marking
}

/// Collector `c` of nursery `k`, its collection open and nothing of it
/// moved yet: the nursery's scan, if owed, is claimed and walked here, its
/// candidates handed to the marker's queue as SATB items (the collector
/// never sets a mark); other collections' rounds are serviced every 256
/// bodies (no stop can be requested while a collection is open, so the
/// walk never parks). If the marker holds it, the collection waits for it,
/// servicing rounds. The test switch `collectBeforeRootScan` skips this.
func collectorFinishesRootScan(_ vm: VMPointer, _ c: WorkerPointer, _ k: Int, servicePoint: () -> Void) {
    guard let mk = unsafe vm.pointee.marking, unsafe k < mk.pointee.rootScanCount else { return }
    if unsafe mk.pointee.config.testSwitches.collectBeforeRootScan { return }
    let slot = unsafe mk.rootScan(k)
    if unsafe slot.pointee.load(ordering: .acquiring) == RootScanState.none { return }
    if unsafe slot.pointee.compareExchange(expected: RootScanState.owed, desired: RootScanState.claimed,
                                           ordering: .acquiringAndReleasing).exchanged {
        let t0 = nanoseconds()
        let om = unsafe mk.pointee.om
        var words: UInt64 = 0
        var out = unsafe CandidateBuffer(mk)
        _ = unsafe walkYoungRoots(mk, om, k, &words, { v in unsafe out.add(om, v) }) {
            servicePoint()
            return true
        }
        unsafe out.flush(takeNew: false)
        unsafe finishRootScan(vm, mk, k, RootScanStat.byCollector, ns: nanoseconds() &- t0, words: words, broadcast: true)
        return
    }
    // The marker has it: wait for its release (it broadcasts under the mutex).
    let t0 = nanoseconds()
    unsafe pthread_mutex_lock(vm.pointee.safepointLock)
    unsafe waitServicing(vm, c) { unsafe slot.pointee.load(ordering: .acquiring) == RootScanState.claimed }
    unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
    unsafe mk.rootScanStat(RootScanStat.waits).pointee.wrappingAdd(1, ordering: .relaxed)
    unsafe mk.rootScanStat(RootScanStat.waitNs).pointee.wrappingAdd(nanoseconds() &- t0, ordering: .relaxed)
}

/// World stopped, the stopper the marker participant: every scan still
/// owed or claimed is done here, onto the marker's stack. A claim of the
/// marker's parked walk is finished too (the walk drops it at its next
/// poll). Module 4's scavenge runs it before it moves anything young; a
/// final mark that may not give up runs it too. Answers the slots visited.
@discardableResult
func finishRootScansInStop(_ vm: VMPointer, _ mk: MarkingPointer) -> UInt64 {
    guard unsafe mk.phaseNow == .marking else { return 0 }
    let om = unsafe mk.pointee.om
    let m = unsafe mk.pointee.marker
    var all: UInt64 = 0
    for k in unsafe 0..<mk.pointee.rootScanCount where unsafe mk.rootScan(k).pointee.load(ordering: .acquiring) != RootScanState.none {
        let t0 = nanoseconds()
        var words: UInt64 = 0
        _ = unsafe walkYoungRoots(mk, om, k, &words, { v in unsafe greyIfCandidate(mk, om, m, v) }) { true }
        unsafe finishRootScan(vm, mk, k, RootScanStat.inStop, ns: nanoseconds() &- t0, words: words, broadcast: false)
        all &+= words
    }
    return all
}

/// A collector's candidates on their way to the marker's queue: unmarked
/// snapshot entries, in 512-word SATB items (marked by the marker when it
/// takes them, as a worker's barrier records are).
@unsafe private struct CandidateBuffer {
    let mk: MarkingPointer
    var words: UnsafeMutablePointer<UInt64>? = nil
    var count = 0

    init(_ mk: MarkingPointer) { unsafe self.mk = mk }

    @inline(__always)
    mutating func add(_ om: ObjectMemory, _ v: UInt64) {
        if v & Oop.objectTagMask != 0 || v == 0 { return }
        let e = v &>> 4
        if unsafe !mk.pointee.snapshot.contains(e) || om.markRelaxed(e) != 0 { return }
        if unsafe words == nil || count == SATBBuffer.capacity { unsafe flush(takeNew: true) }
        unsafe words.unsafelyUnwrapped[count] = v
        unsafe count &+= 1
    }

    /// Hand what is held to the queue (a full or final item) and, unless
    /// this is the last, take an empty buffer, under the marking lock; wake
    /// the marker if it waits.
    mutating func flush(takeNew: Bool) {
        unsafe pthread_mutex_lock(mk.pointee.lock)
        let q = unsafe mk.pointee.queue
        if let w = unsafe words, unsafe count > 0 {
            unsafe q.pointee.items.append(MarkItem(words: w, count: count, grey: false))
            unsafe words = nil
            if unsafe q.pointee.waiting > 0 { unsafe pthread_cond_signal(mk.pointee.cond) }
        }
        if let w = unsafe words { unsafe q.pointee.free.append(w) }
        unsafe words = takeNew ? takeBufferLocked(q) : nil
        unsafe count = 0
        unsafe pthread_mutex_unlock(mk.pointee.lock)
    }
}
