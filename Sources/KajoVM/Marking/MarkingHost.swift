import Darwin
import Synchronization

// Installing concurrent marking in a VM, and the host's view of it (tests,
// `kajo run`). Host calls enter the VM like any host call; the manual
// entry points (`markStep`, `finalMark`, `sweep`) make the calling thread
// the marker participant and exist for the tests' exact interleavings.

extension MarkingShared {
    /// Give `vm` concurrent marking (after its nurseries: the snapshot is
    /// taken at the end of a scavenge). No-op when off or without a nursery.
    static func install(_ vm: VMPointer) {
        let config = unsafe vm.pointee.config.marking
        guard config.enabled, unsafe vm.pointee.nursery != nil else { return }
        let om = unsafe vm.pointee.om
        let count = unsafe vm.pointee.workerCount
        let snapshot: EntryBitmap
        do { snapshot = try EntryBitmap(entries: om.entryCapacity) } catch { preconditionFailure("marking: \(error)") }
        // Buffers move between workers and the queue: every one is in
        // `allocated` and freed from there only.
        var queue = unsafe MarkQueue()
        let satb = UnsafeMutablePointer<UnsafeMutablePointer<SATBBuffer>>.allocate(capacity: count)
        for k in 0..<count {
            let words = unsafe UnsafeMutablePointer<UInt64>.allocate(capacity: SATBBuffer.capacity)
            unsafe queue.allocated.append(words)
            unsafe satb[k] = lined(SATBBuffer(words: words))
        }
        let markerWorker = unsafe Worker.make(image: vm.pointee.image, vm: vm, index: count, isMain: false,
                                              flag: vm.pointee.flag, pollEvery: vm.pointee.config.pollEvery,
                                              seed: (vm.pointee.config.perturb?.seed ?? 0x5EED) &* 0x9E37_79B9 | 1)
        let mk = unsafe lined(MarkingShared(
            config: config, om: om, workerCount: count, snapshot: snapshot, satb: satb, queue: lined(queue),
            lock: makeMutex(), cond: makeCond(), marker: lined(MarkerState()), markerWorker: markerWorker,
            log: lined(MarkingLog(logCapacity: vm.pointee.config.logCapacity)), phase: lined(Atomic<UInt8>(0)), cycle: lined(Atomic<UInt64>(0)),
            wantUserInitiated: lined(Atomic<Bool>(false)), markerWaits: lined(Atomic<UInt64>(0)),
            stopping: lined(Atomic<Bool>(false)), thread: lined(MarkerThread()), machThread: lined(Atomic<UInt32>(0)),
            barrier: barrierWord(vm.pointee.flag)))
        if config.stress.contains(.markingAlwaysOn) { unsafe markingBarrierOn(mk) }
        unsafe vm.pointee.marking = mk
    }

    static func uninstall(_ vm: VMPointer) {
        guard let mk = unsafe vm.pointee.marking else { return }
        let s = unsafe mk.pointee
        unsafe markingBarrierOff(mk)
        for k in unsafe 0..<s.workerCount { unsafe unlined(s.satb[k]) }
        unsafe s.satb.deallocate()
        while let p = unsafe s.queue.pointee.allocated.popLast() { unsafe p.deallocate() }
        unsafe s.queue.pointee.items.free()
        unsafe s.queue.pointee.free.free()
        unsafe s.queue.pointee.allocated.free()
        unsafe unlined(s.queue)
        unsafe s.marker.pointee.stack.free()
        unsafe s.marker.pointee.weak.free()
        unsafe s.marker.pointee.ephemerons.free()
        unsafe s.marker.pointee.sweepLive.free()
        unsafe unlined(s.marker)
        unsafe Worker.destroy(s.markerWorker)
        unsafe unlined(s.log)
        unsafe unlined(s.phase)
        unsafe unlined(s.cycle)
        unsafe unlined(s.wantUserInitiated)
        unsafe unlined(s.markerWaits)
        unsafe unlined(s.stopping)
        unsafe unlined(s.thread)
        unsafe unlined(s.machThread)
        unsafe freeMutex(s.lock)
        unsafe freeCond(s.cond)
        unsafe s.snapshot.release()
        unsafe unlined(mk)
        unsafe vm.pointee.marking = nil
    }
}

/// `VM.startCycle`'s stop: a scavenge (unless the textbook mode asks for
/// none) and the initial mark.
private func startCycleInStop(_ vm: VMPointer, _ mk: MarkingPointer, _ w: WorkerPointer, _ stop: StopContext, scavenge doScavenge: Bool) {
    let roots = stop.roots()
    if doScavenge {
        unsafe markStop(vm, .scavenge)
        let before = unsafe beforeScavenge(vm)
        unsafe scavenge(vm, w, roots: roots, promoteAll: false, timeToSafepointNs: stop.timeToSafepointNs)
        if var b = before { b.free() }
    } else if unsafe mk.phaseNow == .swept {
        unsafe applyInStop(vm, mk)
    }
    guard unsafe mk.phaseNow == .idle, unsafe !fullCollectionDue(vm) else { return }
    unsafe updateWantedQoS(mk)
    unsafe initialMark(vm, mk, roots: roots, trigger: .forced, literal: !doScavenge)
}

extension VM {
    var hasMarking: Bool { unsafe state.pointee.marking != nil }
    var hasMarkerThread: Bool { unsafe state.pointee.marking?.pointee.thread.pointee.thread != nil }

    /// The phase now (an atomic read: no stop, so no apply either).
    var markingPhase: MarkingPhase { unsafe state.pointee.marking?.phaseNow ?? .idle }

    var markingCounters: MarkingCounters {
        guard let mk = unsafe state.pointee.marking else { return MarkingCounters() }
        return inspect { _ in
            var c = unsafe mk.pointee.log.pointee.counters
            for k in unsafe 0..<mk.pointee.workerCount {
                let b = unsafe mk.buffer(k).pointee
                c.satbPushed &+= unsafe b.pushed
                c.satbBuffers &+= unsafe b.handed
                c.barrierSlowCalls &+= unsafe b.slowCalls
                c.weakKeepAlive &+= unsafe b.keepAlive
            }
            c.qosEscalations = unsafe mk.pointee.marker.pointee.escalations
            c.qosLowerings = unsafe mk.pointee.marker.pointee.lowerings
            c.markerWaits = unsafe mk.pointee.markerWaits.pointee.load(ordering: .relaxed)
            return c
        }
    }

    /// The last cycles (`VMConfig.logCapacity` of them), oldest first.
    var cycleLog: [CycleRecord] {
        guard let mk = unsafe state.pointee.marking else { return [] }
        return inspect { _ in unsafe mk.pointee.log.pointee.records.records }
    }

    /// Large bytes, part 2: the last fallbacks' circumstances, oldest first.
    var fallbackLog: [FallbackRecord] {
        guard let mk = unsafe state.pointee.marking else { return [] }
        return inspect { _ in unsafe mk.pointee.log.pointee.fallbackRecords.records }
    }

    /// Sums and maxima over every cycle, and the records the log dropped.
    var cycleTotals: CycleTotals {
        guard let mk = unsafe state.pointee.marking else { return CycleTotals() }
        return inspect { _ in unsafe mk.pointee.log.pointee.totals }
    }

    /// Start a cycle now: a scavenge and the initial mark in one stop (a
    /// finished sweep is applied first). With `scavenge: false` the
    /// textbook protocol's initial mark in a pause of its own (tests). No-op
    /// while a cycle runs.
    func startCycle(scavenge doScavenge: Bool = true) {
        guard let mk = unsafe state.pointee.marking else { return }
        _ = unsafe host { w in
            unsafe stopWorld(state, w, retry: true) { stop in unsafe startCycleInStop(state, mk, w, stop, scavenge: doScavenge) }
        }
    }

    private func manualMarker() -> MarkingPointer {
        guard let mk = unsafe state.pointee.marking else { preconditionFailure("no concurrent marking") }
        precondition(unsafe !mk.pointee.config.markerThread || mk.pointee.thread.pointee.thread == nil,
                     "the manual marker entry points need markerThread off")
        return unsafe mk
    }

    /// Manual mode: trace up to `objects` objects on this thread as the
    /// marker. Answers how many were traced.
    @discardableResult
    func markStep(_ objects: Int) -> Int {
        let mk = unsafe manualMarker()
        let mw = unsafe mk.pointee.markerWorker
        unsafe enterVM(state, mw)
        let m = unsafe mk.pointee.marker
        let before = unsafe m.pointee.markedObjects
        _ = unsafe markSome(state, mk, limit: objects)
        let n = unsafe Int(m.pointee.markedObjects &- before)
        unsafe leaveVM(state, mw)
        return n
    }

    /// Manual mode: trace up to `objects` items (objects, or chunks of a
    /// large one) on this thread as the marker; true when the marker's work
    /// ran out (module 10's measurement).
    func markStepDone(_ objects: Int) -> Bool {
        let mk = unsafe manualMarker()
        let mw = unsafe mk.pointee.markerWorker
        unsafe enterVM(state, mw)
        let outcome = unsafe markSome(state, mk, limit: objects)
        unsafe leaveVM(state, mw)
        return outcome == .done
    }

    /// Manual mode: the final mark, requested as the marker would.
    func finalMark() {
        let mk = unsafe manualMarker()
        let mw = unsafe mk.pointee.markerWorker
        unsafe enterVM(state, mw)
        let cycle = unsafe mk.cycleNow
        unsafe stopWorld(state, mw, retry: true) { stop in unsafe runFinalMark(state, mk, stop, cycle: cycle) }
        unsafe leaveVM(state, mw)
    }

    /// Manual mode: the lazy sweep to its end (phase swept; the next pause
    /// applies it).
    func sweep() {
        let mk = unsafe manualMarker()
        let mw = unsafe mk.pointee.markerWorker
        unsafe enterVM(state, mw)
        // Module 6: relocate first, as the marker thread does.
        if let r = unsafe state.pointee.relocation, unsafe !r.pointee.config.testSwitches.manualRelocation,
           unsafe mk.phaseNow == .sweeping {
            _ = unsafe relocatePass(state, mk, cycle: mk.cycleNow)
        }
        if unsafe mk.phaseNow == .sweeping { _ = unsafe sweepCycle(state, mk, inPause: false) }
        unsafe leaveVM(state, mw)
    }

    /// `o` was an old object at the current snapshot.
    func isSnapshotEntry(_ o: Oop) -> Bool {
        guard let mk = unsafe state.pointee.marking else { return false }
        return inspect { _ in unsafe mk.pointee.snapshot.contains(o.entryIndex) }
    }

    /// Test corruption: set `o`'s mark byte by hand.
    func corruptMark(_ o: Oop) {
        guard unsafe state.pointee.marking != nil else { return }
        withWorldStopped { image.om.setMarkRelaxed(o.entryIndex, 1) }
    }

    /// The marker thread's CPU time so far (0 without one).
    var markerCPUNanoseconds: UInt64 {
        guard let mk = unsafe state.pointee.marking else { return 0 }
        let port = unsafe mk.pointee.machThread.pointee.load(ordering: .relaxed)
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
}
