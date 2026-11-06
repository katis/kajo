import Darwin
import Synchronization

// Installing young collection in a VM, and the host's view of it (tests,
// `kajo run`). Host calls enter the VM like any host call; the manual
// entry points (`collectYoung(worker:)`, `flipYoung(worker:)`) make the
// calling thread act as a worker that has no thread of its own.

private func atoms<T: AtomicRepresentable>(_ n: Int, _ v: T) -> UnsafeMutablePointer<Atomic<T>> {
    let p = UnsafeMutablePointer<Atomic<T>>.allocate(capacity: n)
    for i in 0..<n { unsafe (p + i).initialize(to: Atomic(v)) }
    return unsafe p
}

extension YoungShared {
    /// Give `vm` young collection without stopping the world (after its
    /// nurseries, before any thread starts). No-op in the stop-the-world
    /// mode, without a nursery, or when the nursery region is not mapped
    /// twice (then the mode is `stw`).
    static func install(_ vm: VMPointer) {
        let config = unsafe vm.pointee.config.young
        guard config.mode != .stw, let n = unsafe vm.pointee.nursery, unsafe vm.pointee.om.nurseryRegionAliased else { return }
        let count = unsafe n.pointee.count
        let workers = unsafe vm.pointee.workerCount
        let participants = workers + 2
        let hs = UnsafeMutablePointer<UnsafeMutablePointer<Handshake>>.allocate(capacity: count)
        for k in 0..<count {
            let acked = UnsafeMutablePointer<UInt64>.allocate(capacity: participants)
            unsafe acked.initialize(repeating: 0, count: participants)
            unsafe hs[k] = lined(Handshake(acked: acked))
        }
        let records = unsafe vm.pointee.config.recordCapacity
        let scanBytes = (count * records * 8 + 16383) & ~16383
        let scanRaw: UnsafeMutableRawPointer
        do { unsafe scanRaw = try unsafe VirtualMemory.reserve(scanBytes) } catch { preconditionFailure("young: \(error)") }
        let work = UnsafeMutablePointer<UnsafeMutablePointer<CollectorWork>>.allocate(capacity: participants)
        let counters = UnsafeMutablePointer<UnsafeMutablePointer<YoungWorkerCounters>>.allocate(capacity: participants)
        for i in 0..<participants {
            unsafe work[i] = lined(CollectorWork())
            unsafe counters[i] = lined(YoungWorkerCounters())
        }
        let inFlight = UnsafeMutablePointer<YoungRecord>.allocate(capacity: count)
        unsafe inFlight.initialize(repeating: YoungRecord(), count: count)
        let collector = unsafe Worker.make(image: vm.pointee.image, vm: vm, index: workers + 1, isMain: false,
                                           flag: vm.pointee.flag, pollEvery: vm.pointee.config.pollEvery,
                                           seed: (vm.pointee.config.perturb?.seed ?? 0xC011) &* 0x9E37_79B9 | 1)
        let y = unsafe lined(YoungShared(
            config: config, mode: config.mode, om: vm.pointee.om, nursery: n, count: count, participants: participants,
            collectorIndex: workers + 1, hs: hs, roundSerial: lined(Atomic<UInt64>(0)), collecting: atoms(count, false), afterH1: atoms(count, false),
            afterT1: atoms(count, false), done: atoms(count, true), seq: atoms(count, UInt64(0)),
            ranges: atoms(count * 4, UInt64(0)),
            scanWords: scanRaw.bindMemory(to: Atomic<UInt64>.self, capacity: count * records), scanWordsBytes: scanBytes,
            recordCapacity: records, inFlight: inFlight, work: work, counters: counters, queue: lined(RawArray<Int>()),
            collectorCond: makeCond(), thread: lined(YoungThread()), collectorWorker: collector,
            shutdown: lined(Atomic<Bool>(false)), collectorWaits: lined(Atomic<UInt64>(0)),
            collectorMachThread: lined(Atomic<UInt32>(0)), log: lined(YoungLog()),
            promotedBytes: lined(Atomic<UInt64>(0)), promotedObjects: lined(Atomic<UInt64>(0)),
            sampler: lined(YoungSampler()), samplerLock: makeMutex(), peekGate: lined(Atomic<Int>(0)),
            peekHeld: lined(Atomic<Int>(0)), copyWindow: lined(EnterWindowHook())))
        unsafe vm.pointee.young = y
        if config.stress.contains(.barrierAlwaysOn) { unsafe barrierWord(vm.pointee.flag).pointee.wrappingAdd(2, ordering: .relaxed) }
    }

    static func uninstall(_ vm: VMPointer) {
        guard let y = unsafe vm.pointee.young else { return }
        let s = unsafe y.pointee
        if unsafe s.config.stress.contains(.barrierAlwaysOn) { unsafe barrierWord(vm.pointee.flag).pointee.wrappingSubtract(2, ordering: .relaxed) }
        for k in unsafe 0..<s.count {
            let h = unsafe s.hs[k]
            unsafe h.pointee.acked.deallocate()
            unsafe h.pointee.roots.free()
            for i in unsafe 0..<h.pointee.pubs.count { unsafe h.pointee.pubs[i].list.free() }
            unsafe h.pointee.pubs.free()
            unsafe unlined(h)
        }
        unsafe s.hs.deallocate()
        unsafe unlined(s.roundSerial)
        for i in unsafe 0..<s.participants {
            let w = unsafe s.work[i]
            unsafe w.pointee.grey.free()
            unsafe w.pointee.roots.free()
            for j in unsafe 0..<w.pointee.pubs.count { unsafe w.pointee.pubs[j].list.free() }
            unsafe w.pointee.pubs.free()
            unsafe w.pointee.claimed.free()
            unsafe unlined(w)
            unsafe unlined(s.counters[i])
        }
        unsafe s.work.deallocate()
        unsafe s.counters.deallocate()
        for unsafe p in unsafe [s.collecting, s.afterH1, s.afterT1, s.done] { unsafe p.deinitialize(count: s.count); unsafe p.deallocate() }
        unsafe s.seq.deinitialize(count: s.count)
        unsafe s.seq.deallocate()
        unsafe s.ranges.deinitialize(count: s.count * 4)
        unsafe s.ranges.deallocate()
        unsafe VirtualMemory.release(UnsafeMutableRawPointer(s.scanWords), s.scanWordsBytes)
        unsafe s.inFlight.deallocate()
        unsafe s.queue.pointee.free()
        unsafe unlined(s.queue)
        unsafe freeCond(s.collectorCond)
        unsafe unlined(s.thread)
        unsafe Worker.destroy(s.collectorWorker)
        unsafe unlined(s.shutdown)
        unsafe unlined(s.collectorWaits)
        unsafe unlined(s.collectorMachThread)
        unsafe unlined(s.log)
        unsafe unlined(s.promotedBytes)
        unsafe unlined(s.promotedObjects)
        unsafe unlined(s.sampler)
        unsafe freeMutex(s.samplerLock)
        unsafe unlined(s.peekGate)
        unsafe unlined(s.peekHeld)
        unsafe unlined(s.copyWindow)
        unsafe unlined(y)
        unsafe vm.pointee.young = nil
    }
}

/// Module 5's initial mark ran the young-root scan (world stopped).
func noteYoungRootScan(_ y: YoungPointer, _ ns: UInt64, _ words: UInt64) {
    unsafe y.pointee.log.pointee.initialMarks &+= 1
    unsafe y.pointee.log.pointee.youngRootScanNs &+= ns
    unsafe y.pointee.log.pointee.youngRootWords &+= words
    if unsafe ns > y.pointee.log.pointee.youngRootScanMaxNs { unsafe y.pointee.log.pointee.youngRootScanMaxNs = ns }
}

/// The initial mark's snapshot (world stopped): deferred entry frees are
/// not in it (amendment 17; the snapshot is the old map, which never holds
/// a young entry). Counted. The test switch `deferredOwnership` off puts
/// them in, as the experiment's snapshot (used entries minus the young
/// logs) did.
func snapshotDeferred(_ vm: VMPointer, _ y: YoungPointer, _ mk: MarkingPointer) {
    let n = unsafe y.pointee.nursery
    let own = unsafe y.pointee.config.testSwitches.deferredOwnership
    for k in unsafe 0..<n.pointee.count {
        let d = unsafe n.survivors(k).pointee.deferred
        unsafe y.pointee.log.pointee.snapshotExclusions &+= UInt64(d.count)
        if !own { for i in 0..<d.count { unsafe mk.pointee.snapshot.insert(d[i] &>> 4) } }
    }
}

/// A participant's index as a worker pointer: the table's workers, module
/// 5's marker worker, module 7's young collector.
func participantWorker(_ vm: VMPointer, _ i: Int) -> WorkerPointer {
    let n = unsafe vm.pointee.workerCount
    if i < n { return unsafe vm.worker(i) }
    if i == n, let mk = unsafe vm.pointee.marking { return unsafe mk.pointee.markerWorker }
    if let y = unsafe vm.pointee.young, unsafe i == y.pointee.collectorIndex { return unsafe y.pointee.collectorWorker }
    preconditionFailure("no participant \(i)")
}

/// Young collection's counters, summed (docs/modules/young-collection.md
/// "Counters").
struct YoungCounters: Sendable {
    var mode = YoungMode.stw
    var collectionsLocal: UInt64 = 0
    var collectionsOffloaded: UInt64 = 0
    var offloadedInline: UInt64 = 0
    var fallbacks: [UInt64] = []
    var verifierRuns: UInt64 = 0
    var snapshotExclusions: UInt64 = 0
    var initialMarks: UInt64 = 0
    var youngRootScanNs: UInt64 = 0
    var youngRootScanMaxNs: UInt64 = 0
    var youngRootWords: UInt64 = 0
    var collectorCpuNs: UInt64 = 0
    var collectorQoS: UInt32 = 0
    var collectorWakeups: UInt64 = 0
    var promotedBytes: UInt64 = 0
    var promotedObjects: UInt64 = 0
}

extension VM {
    var hasYoungCollection: Bool { unsafe state.pointee.young != nil }
    var youngMode: YoungMode { unsafe state.pointee.young?.pointee.mode ?? .stw }

    var youngCounters: YoungCounters {
        guard let y = unsafe state.pointee.young else { return YoungCounters() }
        unsafe pthread_mutex_lock(state.pointee.safepointLock)
        defer { unsafe pthread_mutex_unlock(state.pointee.safepointLock) }
        let l = unsafe y.pointee.log.pointee
        return unsafe YoungCounters(
            mode: y.pointee.mode, collectionsLocal: l.collectionsLocal, collectionsOffloaded: l.collectionsOffloaded,
            offloadedInline: l.offloadedInline, fallbacks: l.fallbacks, verifierRuns: l.verifierRuns,
            snapshotExclusions: l.snapshotExclusions, initialMarks: l.initialMarks, youngRootScanNs: l.youngRootScanNs,
            youngRootScanMaxNs: l.youngRootScanMaxNs, youngRootWords: l.youngRootWords, collectorCpuNs: l.collectorCpuNs,
            collectorQoS: l.collectorQoS, collectorWakeups: y.pointee.collectorWaits.pointee.load(ordering: .relaxed),
            promotedBytes: y.pointee.promotedBytes.pointee.load(ordering: .relaxed),
            promotedObjects: y.pointee.promotedObjects.pointee.load(ordering: .relaxed))
    }

    /// Every collection so far, and every round.
    var youngLog: [YoungRecord] {
        guard let y = unsafe state.pointee.young else { return [] }
        unsafe pthread_mutex_lock(state.pointee.safepointLock)
        defer { unsafe pthread_mutex_unlock(state.pointee.safepointLock) }
        return unsafe y.pointee.log.pointee.records
    }

    var roundLog: [RoundRecord] {
        guard let y = unsafe state.pointee.young else { return [] }
        unsafe pthread_mutex_lock(state.pointee.safepointLock)
        defer { unsafe pthread_mutex_unlock(state.pointee.safepointLock) }
        return unsafe y.pointee.log.pointee.rounds
    }

    /// Participant `i`'s counters (read after the threads stopped, or for a
    /// worker the test drives).
    /// The barrier word (tests: bit 0 marking, bits 1 and up module 7's
    /// count), read in a stop.
    var barrierWordValue: UInt32 {
        inspect { _ in unsafe barrierWord(state.pointee.flag).pointee.load(ordering: .relaxed) }
    }

    func youngWorkerCounters(_ i: Int) -> YoungWorkerCounters {
        guard let y = unsafe state.pointee.young else { return YoungWorkerCounters() }
        return unsafe y.counters(i).pointee
    }

    /// The young collector thread's CPU time so far (0 without one).
    var youngCollectorCPUNanoseconds: UInt64 {
        guard let y = unsafe state.pointee.young else { return 0 }
        return threadCPU(unsafe y.pointee.collectorMachThread.pointee.load(ordering: .relaxed))
    }

    var youngCollectorQoS: qos_class_t {
        guard let y = unsafe state.pointee.young else { return QOS_CLASS_UNSPECIFIED }
        return qos_class_t(rawValue: unsafe state.shared(y.pointee.collectorIndex).pointee.qos.load(ordering: .relaxed))
    }

    /// Test: the calling thread acts as worker `i` (no thread of its own,
    /// no Process) and collects its nursery now: locally, or (offloaded)
    /// flips and waits until the collection is done.
    func collectYoung(worker i: Int) {
        guard let y = unsafe state.pointee.young else { return }
        let w = unsafe state.worker(i)
        precondition(unsafe w.pointee.thread == nil, "worker \(i) has a thread")
        unsafe enterVM(state, w)
        unsafe collectOwnNursery(state, y, w, held: .none)
        if unsafe y.isOffloaded(i) {
            unsafe pthread_mutex_lock(state.pointee.safepointLock)
            unsafe waitServicing(state, w) { unsafe !y.pointee.done[i].load(ordering: .acquiring) }
            unsafe pthread_mutex_unlock(state.pointee.safepointLock)
        }
        unsafe leaveVM(state, w)
    }

    /// Test (offload): the calling thread acts as worker `i` and flips
    /// without waiting for the collection.
    func flipYoung(worker i: Int) {
        guard let y = unsafe state.pointee.young else { return }
        let w = unsafe state.worker(i)
        unsafe enterVM(state, w)
        unsafe collectOwnNursery(state, y, w, held: .none)
        unsafe leaveVM(state, w)
    }

    /// Test: wait (polling) until nursery `k`'s collection is done.
    func waitYoungDone(_ k: Int, seconds: Double = 30) -> Bool {
        guard let y = unsafe state.pointee.young else { return true }
        let end = nanoseconds() + UInt64(seconds * 1e9)
        while unsafe !y.pointee.done[k].load(ordering: .acquiring) {
            if nanoseconds() > end { return false }
            usleep(200)
        }
        return true
    }

    /// Test: the young verifier now, in a stop from the host worker.
    func verifyYoung() {
        guard let y = unsafe state.pointee.young else { return }
        _ = unsafe host { w in unsafe stopWorld(state, w, retry: true) { stop in unsafe verifyYoungInStop(state, y, stop) } }
    }

    /// Test: stop requesters waiting for every young collection to end.
    var stopsWanted: Int {
        unsafe pthread_mutex_lock(state.pointee.safepointLock)
        defer { unsafe pthread_mutex_unlock(state.pointee.safepointLock) }
        return unsafe state.pointee.safepoint.pointee.stwWanted
    }

    /// Test: is worker `i` inside the VM?
    func isInside(worker i: Int) -> Bool {
        unsafe pthread_mutex_lock(state.pointee.safepointLock)
        defer { unsafe pthread_mutex_unlock(state.pointee.safepointLock) }
        return unsafe state.pointee.safepoint.pointee.inside[i]
    }

    /// Test: entries whose free is deferred, per nursery (world stopped).
    func deferredEntries() -> [Oop] {
        guard let n = unsafe state.pointee.nursery else { return [] }
        return inspect { _ in
            var r: [Oop] = []
            for k in unsafe 0..<n.pointee.count {
                let d = unsafe n.survivors(k).pointee.deferred
                for i in 0..<d.count { r.append(Oop(raw: d[i])) }
            }
            return r
        }
    }

    /// Test: is entry `o` in use (not free)?
    func isEntryUsed(_ o: Oop) -> Bool { inspect { om in !EntryState.isFree(om.stateWord(o.raw)) } }

    /// Test: set or clear bits of `o`'s remembered word (world stopped).
    func orRememberedWord(_ o: Oop, _ bits: UInt32) {
        guard let n = unsafe state.pointee.nursery else { return }
        withWorldStopped { unsafe n.remMarker(o.raw).pointee.bitwiseOr(bits, ordering: .sequentiallyConsistent) }
    }

    /// Test primitive 39's gate: while set, `slowPeek:` waits in its
    /// blocking region holding its body pointer.
    func setPeekGate(_ closed: Bool) {
        guard let y = unsafe state.pointee.young else { return }
        unsafe y.pointee.peekGate.pointee.store(closed ? 1 : 0, ordering: .releasing)
        if closed { unsafe y.pointee.peekHeld.pointee.store(0, ordering: .releasing) }
    }

    var peekHeld: Bool { unsafe state.pointee.young.map { unsafe $0.pointee.peekHeld.pointee.load(ordering: .acquiring) != 0 } ?? false }

    /// Test: `hook(context, worker)` runs inside the array copy's broken
    /// variant between its remembered-word load and its delayed store.
    func setCopyWindow(_ hook: (@convention(c) (UnsafeMutableRawPointer?, Int) -> Void)?, context: UnsafeMutableRawPointer?) {
        guard let y = unsafe state.pointee.young else { return }
        unsafe y.pointee.copyWindow.pointee = EnterWindowHook(hook: hook, context: context)
    }
}

/// A Mach thread's CPU time (0 for none).
func threadCPU(_ port: UInt32) -> UInt64 {
    if port == 0 { return 0 }
    var info = thread_extended_info()
    var count = mach_msg_type_number_t(MemoryLayout<thread_extended_info>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        unsafe $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            unsafe thread_info(port, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &count)
        }
    }
    if kr != KERN_SUCCESS { return 0 }
    return info.pth_user_time &+ info.pth_system_time
}

/// Worker `i`'s young-collection time so far (acknowledgements, flips and
/// own collections, waits) and its acknowledgements: a turn's share.
func youngTurnNs(_ vm: VMPointer, _ i: Int) -> (ns: UInt64, acks: UInt64) {
    guard let y = unsafe vm.pointee.young else { return (0, 0) }
    let c = unsafe y.counters(i).pointee
    return (c.acksOwnNs &+ c.acksOtherNs &+ c.serviceNs &+ c.flipNs &+ c.ownNs &+ c.collectorWaitNs &+ c.stopWaitNs
                &+ c.drainWaitNs,
            c.acksOwn &+ c.acksOther)
}

extension VM {
    /// Test: start only the young collector thread (a VM whose workers the
    /// test drives, `start` not called).
    func startYoungCollectorOnly() { unsafe startYoungCollector(state) }

    /// Test: `fetch_or` bits into `o`'s remembered word now, with no stop
    /// (from a collector's hook, as another collection's fold would).
    func orRememberedWordNow(_ o: Oop, _ bits: UInt32) {
        guard let n = unsafe state.pointee.nursery else { return }
        unsafe n.remMarker(o.raw).pointee.bitwiseOr(bits, ordering: .sequentiallyConsistent)
    }

    /// Test: store a SmallInteger or nil into global `i` with no stop (a
    /// flag a spinning Process polls; never young, so no barrier).
    func setGlobalNow(_ i: Int, _ v: Oop) {
        precondition(!v.isObject || v == image.nilObject)
        image.om.store(image.globals, i - 1, v)
    }

    /// Test: global `i` read with no stop.
    func globalNow(_ i: Int) -> Oop { image.om.load(image.globals, i - 1) }

    /// Start a marking cycle with module 7's initial-mark pause (no
    /// scavenge, the young-root scan). No-op while a cycle runs.
    func startYoungCycle() {
        guard let mk = unsafe state.pointee.marking, let y = unsafe state.pointee.young else { return }
        _ = unsafe host { w in
            unsafe stopWorld(state, w, retry: true) { stop in unsafe initialMarkPause(state, y, mk, stop, trigger: .forced) }
        }
    }

    /// Test: worker `i`'s epoch word now, and what a collector's epoch
    /// check would see (the smallest participant word).
    var minimumEpoch: UInt64 { unsafe minParticipantEpoch(state) }
    var globalEpoch: UInt64 { unsafe state.pointee.epoch.pointee.load(ordering: .sequentiallyConsistent) }

    /// Test: worker `i` (inside the VM on this thread) waits as
    /// `waitServicing` does: quiescent, then the wake (with the enter
    /// window hook between its load of the epoch and its store).
    func quiesceAndWake(worker i: Int) {
        let w = unsafe state.worker(i)
        unsafe epochQuiesce(state, w)
        unsafe epochWake(state, w, zero: state.pointee.young?.pointee.config.testSwitches.quiescentWakeZero ?? true)
    }
}
