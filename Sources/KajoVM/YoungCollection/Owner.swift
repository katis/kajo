import Darwin
import Synchronization

// Who collects a nursery, and what follows a collection (docs/modules/
// young-collection.md "Policy"): the owner collects locally, or flips its
// eden halves and hands the full one to the young collector thread
// (offload); after a collection, the triggers (a full collection when old
// space is past its soft limit, an initial mark when a cycle is due).

/// Owner `w`'s eden is full (allocation slow path, registers flushed,
/// `held` the oop the slow path keeps): collect its nursery locally, or
/// flip (offload). Answers after the eden has room again.
func collectOwnNursery(_ vm: VMPointer, _ y: YoungPointer, _ w: WorkerPointer, held: Oop) {
    let k = unsafe w.pointee.index
    let c = unsafe y.counters(k)
    let a = unsafe y.pointee.nursery.alloc(k)
    unsafe w.pointee.youngHeld = held.raw
    defer { unsafe w.pointee.youngHeld = 0 }
    if unsafe y.isOffloaded(k) {
        // The previous collection of this nursery must be over: it frees
        // the half the owner is about to reuse, after its epoch.
        if unsafe !y.pointee.done[k].load(ordering: .acquiring) {
            let tw = nanoseconds()
            unsafe pthread_mutex_lock(vm.pointee.safepointLock)
            unsafe waitServicing(vm, w) { unsafe !y.pointee.done[k].load(ordering: .acquiring) }
            unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
            let dt = nanoseconds() &- tw
            unsafe c.pointee.collectorWaits &+= 1
            unsafe c.pointee.collectorWaitNs &+= dt
            if unsafe dt > c.pointee.collectorWaitMaxNs { unsafe c.pointee.collectorWaitMaxNs = dt }
        }
        let t0 = nanoseconds()
        unsafe openYoungCollection(vm, y, w, offload: true)
        let dt = nanoseconds() &- t0
        unsafe c.pointee.flips &+= 1
        unsafe c.pointee.flipNs &+= dt
        if unsafe dt > c.pointee.flipMaxNs { unsafe c.pointee.flipMaxNs = dt }
        if unsafe !y.pointee.thread.pointee.started {
            // No collector thread (a VM driven from the test thread): the
            // owner runs the offloaded collection itself, its new half
            // already active.
            unsafe collectYoung(vm, y, w, k)
            unsafe pthread_mutex_lock(vm.pointee.safepointLock)
            unsafe y.pointee.log.pointee.offloadedInline &+= 1
            unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
            unsafe afterYoungCollection(vm, y, w)
        }
        return
    }
    let t0 = nanoseconds()
    unsafe openYoungCollection(vm, y, w, offload: false)
    let rec = unsafe collectYoung(vm, y, w, k)
    // The epoch rule passed inside the collection: the old eden is reused.
    unsafe a.pointee.top = a.pointee.edenStart
    let dt = nanoseconds() &- t0
    unsafe c.pointee.ownCollections &+= 1
    unsafe c.pointee.ownNs &+= dt
    if unsafe dt > c.pointee.ownMaxNs { unsafe c.pointee.ownMaxNs = dt }
    let ew = rec.epochWaitNs
    unsafe c.pointee.edenWaits &+= 1
    unsafe c.pointee.edenWaitNs &+= ew
    if unsafe ew > c.pointee.edenWaitMaxNs { unsafe c.pointee.edenWaitMaxNs = ew }
    unsafe afterYoungCollection(vm, y, w)
}

// MARK: - the young collector thread (offload)

/// Mutex held, the collector thread inside the VM and not collecting:
/// run every queued collection (a stop waits for every opened collection,
/// and only this thread runs them: amendment 11).
func drainQueueLocked(_ vm: VMPointer, _ y: YoungPointer, _ c: WorkerPointer) {
    while let k = unsafe takeQueuedLocked(y) {
        unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
        unsafe collectYoung(vm, y, c, k)
        unsafe pthread_mutex_lock(vm.pointee.safepointLock)
    }
}

/// Mutex held: the oldest queued nursery, or nil.
private func takeQueuedLocked(_ y: YoungPointer) -> Int? {
    let q = unsafe y.pointee.queue
    guard unsafe q.pointee.count > 0 else { return nil }
    let k = unsafe q.pointee[0]
    unsafe q.pointee.removeFirst()
    unsafe y.handshake(k).pointee.queued = false
    return k
}

/// The young collector thread: wait (untimed) for a queued collection, run
/// it inside the VM, then the triggers; leave the VM between collections
/// (outside it is acknowledged by proxy and quiescent).
func youngCollectorLoop(_ vm: VMPointer, _ y: YoungPointer) {
    let c = unsafe y.pointee.collectorWorker
    unsafe y.pointee.collectorMachThread.pointee.store(pthread_mach_thread_np(pthread_self()), ordering: .relaxed)
    unsafe vm.shared(c.pointee.index).pointee.qos.store(qos_class_self().rawValue, ordering: .relaxed)
    unsafe pthread_mutex_lock(vm.pointee.safepointLock)
    unsafe y.pointee.log.pointee.collectorQoS = qos_class_self().rawValue
    while true {
        if unsafe y.pointee.queue.pointee.count == 0 {
            if unsafe y.pointee.shutdown.pointee.load(ordering: .relaxed) { break }
            unsafe pthread_cond_wait(y.pointee.collectorCond, vm.pointee.safepointLock)
            unsafe y.pointee.collectorWaits.pointee.wrappingAdd(1, ordering: .relaxed)
            continue
        }
        unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
        unsafe enterVM(vm, c)
        let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        unsafe pthread_mutex_lock(vm.pointee.safepointLock)
        unsafe drainQueueLocked(vm, y, c)
        unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
        unsafe afterYoungCollection(vm, y, c)
        let dt = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- cpu0
        unsafe leaveVM(vm, c)
        unsafe pthread_mutex_lock(vm.pointee.safepointLock)
        unsafe y.pointee.log.pointee.collectorCpuNs &+= dt
    }
    unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
}

/// Start the young collector thread at its QoS (`VM.start`): offload only.
func startYoungCollector(_ vm: VMPointer) {
    guard let y = unsafe vm.pointee.young, unsafe y.pointee.mode == .offload && y.pointee.config.collectorThread else { return }
    var attr = pthread_attr_t()
    unsafe pthread_attr_init(&attr)
    unsafe pthread_attr_set_qos_class_np(&attr, y.pointee.config.collectorQoS, 0)
    var t: pthread_t? = nil
    unsafe pthread_mutex_lock(vm.pointee.safepointLock)
    unsafe y.pointee.thread.pointee.started = true
    unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
    let rc = unsafe pthread_create(&t, &attr, { arg in
        let vm = unsafe arg.assumingMemoryBound(to: VMState.self)
        unsafe youngCollectorLoop(vm, vm.pointee.young.unsafelyUnwrapped)
        return nil
    }, UnsafeMutableRawPointer(vm))
    precondition(rc == 0, "pthread_create failed: \(rc)")
    unsafe y.pointee.thread.pointee.thread = t
    unsafe pthread_attr_destroy(&attr)
}

/// Stop and join the young collector thread (`VM.shutdown`, after the
/// workers): it runs what is queued first.
func stopYoungCollector(_ vm: VMPointer) {
    guard let y = unsafe vm.pointee.young, let t = unsafe y.pointee.thread.pointee.thread else { return }
    unsafe pthread_mutex_lock(vm.pointee.safepointLock)
    unsafe y.pointee.shutdown.pointee.store(true, ordering: .relaxed)
    unsafe pthread_cond_broadcast(y.pointee.collectorCond)
    unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
    unsafe pthread_join(t, nil)
    unsafe pthread_mutex_lock(vm.pointee.safepointLock)
    unsafe y.pointee.thread.pointee.thread = nil
    unsafe y.pointee.thread.pointee.started = false
    unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
}

// MARK: - after a collection (SPEC step 7)

/// After a collection, its collector inside the VM at a safepoint (no
/// lock): old space past its soft limit requests a full collection (module
/// 4's fallback, run at the next poll in a stop of its own); with marking
/// idle, the trigger is decided on this module's promotion samples and an
/// initial-mark pause requested; the young verifier when due.
func afterYoungCollection(_ vm: VMPointer, _ y: YoungPointer, _ c: WorkerPointer) {
    let om = unsafe vm.pointee.om
    let n = unsafe y.pointee.nursery
    if om.isOverSoftLimit, unsafe !n.pointee.fullRequested.pointee.exchange(true, ordering: .relaxed) {
        unsafe vm.pointee.flag.pointee.bitwiseOr(1, ordering: .releasing)
        unsafe pthread_mutex_lock(vm.pointee.safepointLock)
        unsafe y.pointee.log.pointee.fallbacks[YoungFallback.softLimit.rawValue] &+= 1
        unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
    }
    if let mk = unsafe vm.pointee.marking {
        unsafe sampleForTrigger(vm, y, mk)
        if unsafe mk.phaseNow == .idle && !fullCollectionDue(vm), let trigger = unsafe youngTrigger(vm, y, mk) {
            unsafe stopWorld(vm, c, retry: false) { stop in unsafe initialMarkPause(vm, y, mk, stop, trigger: trigger) }
        }
    }
    let config = unsafe y.pointee.config
    if config.verify {
        unsafe pthread_mutex_lock(vm.pointee.safepointLock)
        let total = unsafe y.pointee.log.pointee.collectionsLocal &+ y.pointee.log.pointee.collectionsOffloaded
        let due = unsafe total > y.pointee.log.pointee.verifierRuns &* UInt64(Swift.max(1, config.verifyEvery))
        unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
        if due { unsafe stopWorld(vm, c, retry: true) { stop in unsafe verifyYoungInStop(vm, y, stop) } }
    }
}

/// Record a promotion sample (between stops: this module's own sampler).
private func sampleForTrigger(_ vm: VMPointer, _ y: YoungPointer, _ mk: MarkingPointer) {
    // Promotion by young collections, and by the stop-the-world scavenges
    // (their counters are written in stops only, before this participant
    // last took the safepoint mutex). Old allocations of large objects are
    // not sampled: they show in occupancy, which the floor watches.
    let promoted = unsafe y.pointee.promotedBytes.pointee.load(ordering: .relaxed)
        &+ (unsafe vm.pointee.nursery?.pointee.state.pointee.counters.promotedBytes ?? 0)
    unsafe pthread_mutex_lock(y.pointee.samplerLock)
    let s = unsafe y.pointee.sampler
    unsafe s.pointee.samples.append((nanoseconds(), promoted))
    if unsafe s.pointee.samples.count > MarkingConfig.rateWindow { unsafe s.pointee.samples.removeFirst() }
    unsafe pthread_mutex_unlock(y.pointee.samplerLock)
}

/// The trigger on this module's samples (module 5's rule: floor,
/// predictor, forced).
private func youngTrigger(_ vm: VMPointer, _ y: YoungPointer, _ mk: MarkingPointer) -> CycleTrigger? {
    unsafe pthread_mutex_lock(y.pointee.samplerLock)
    let samples = unsafe y.pointee.sampler.pointee.samples
    unsafe pthread_mutex_unlock(y.pointee.samplerLock)
    var rate = 0.0
    if samples.count >= 2, let a = samples.first, let b = samples.last, b.ns > a.ns {
        rate = Double(b.promoted &- a.promoted) / (Double(b.ns &- a.ns) / 1e9)
    }
    return unsafe decideTrigger(mk, rate: rate, oldEntries: nil, record: false)
}

/// The initial-mark pause of young collection without stopping the world
/// (concurrent-young Part 3 (a)): no scavenge; module 5's bookkeeping,
/// then its initial mark, whose young-root scan walks every nursery.
func initialMarkPause(_ vm: VMPointer, _ y: YoungPointer, _ mk: MarkingPointer, _ stop: StopContext, trigger: CycleTrigger) {
    unsafe markStop(vm, .initialMark)
    if unsafe mk.phaseNow == .swept && !mk.pointee.config.stress.contains(.sweepNeverApplies) { unsafe applyInStop(vm, mk) }
    guard unsafe mk.phaseNow == .idle, unsafe !fullCollectionDue(vm) else { return }
    unsafe countOldEntriesAtPause(vm, mk)
    unsafe updateWantedQoS(mk)
    unsafe initialMark(vm, mk, roots: stop.roots(), trigger: trigger, literal: false)
}

// MARK: - the young-root scan (Part 3 (a))

/// World stopped, no collection open: every nursery's young bodies (its
/// eden or current eden half from its start to its top, and its
/// survivor-from) are walked linearly; a body whose entry leads to it has
/// every slot greyed (snapshot entries only). Replaces module 5's survivor
/// scan behind `initialMark`. Answers the words scanned.
func youngRootScan(_ vm: VMPointer, _ mk: MarkingPointer) -> UInt64 {
    guard let n = unsafe vm.pointee.nursery else { return 0 }
    let om = unsafe mk.pointee.om
    let m = unsafe mk.pointee.marker
    var words: UInt64 = 0
    func walk(_ lo: UInt64, _ hi: UInt64) {
        var a = lo
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
                        unsafe greyIfCandidate(mk, om, m, om.loadAtomic(bodyOffset: a, j))
                        j &+= 1
                    }
                }
            }
            a &+= size &<< 3
        }
    }
    for k in unsafe 0..<n.pointee.count {
        let a = unsafe n.alloc(k).pointee
        let v = unsafe n.survivors(k).pointee
        unsafe walk(a.edenStart, a.top)
        unsafe walk(v.survFromStart, v.survFromTop)
    }
    return words
}
