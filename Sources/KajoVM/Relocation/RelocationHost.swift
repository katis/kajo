import Darwin
import Synchronization

// The host's view of relocation (tests, `kajo run`). Reads enter the VM
// like any host call; the manual entry points (`relocate`, the step
// functions, `freePendingNow`) make the calling thread the marker
// participant and exist for the tests' exact interleavings (marking's
// `markerThread` off).

/// One object held between the steps of the copy protocol (tests).
struct RelocStep: Sendable {
    let object: Oop
    let from: UInt64
    let to: UInt64
    let bytes: UInt64
}

extension VM {
    var hasRelocation: Bool { unsafe state.pointee.relocation != nil }

    var relocationCounters: RelocationCounters {
        guard let r = unsafe state.pointee.relocation else { return RelocationCounters() }
        return inspect { _ in
            var c = unsafe r.pointee.state.pointee.counters
            for k in unsafe 0..<state.pointee.workerCount {
                let m = unsafe state.worker(k).pointee.relocation
                c.storesRedone &+= m.storesRedone
                c.spinEpisodes &+= m.spinEpisodes
                c.spinNs &+= m.spinNs
                c.spinMaxNs = Swift.max(c.spinMaxNs, m.spinMaxNs)
                c.hazardsTaken &+= m.hazardsTaken
                c.hazardWaits &+= m.hazardWaits
                if k == 0 {
                    c.mainSpinEpisodes = m.spinEpisodes
                    c.mainSpinNs = m.spinNs
                    c.mainSpinMaxNs = m.spinMaxNs
                }
            }
            return c
        }
    }

    /// One worker's post-store and hazard counters.
    func mutatorRelocationCounters(_ worker: Int) -> RelocationMutatorCounters {
        inspect { _ in unsafe state.worker(worker).pointee.relocation }
    }

    /// The last finished cycles (`VMConfig.logCapacity` of them) and the
    /// current one, oldest first.
    var relocationLog: [RelocationCycleRecord] {
        guard let r = unsafe state.pointee.relocation else { return [] }
        return inspect { _ in
            unsafe r.pointee.state.pointee.records.records + (r.pointee.state.pointee.hasCurrent ? [r.pointee.state.pointee.current] : [])
        }
    }

    /// Cycles that selected a block (every finished one and the current
    /// one), and the finished cycles' records the log dropped.
    var relocationTotals: (selecting: UInt64, dropped: UInt64) {
        guard let r = unsafe state.pointee.relocation else { return (0, 0) }
        return inspect { _ in
            let st = unsafe r.pointee.state.pointee
            return unsafe (st.selecting &+ (st.hasCurrent && st.current.blocksSelected > 0 ? 1 : 0), st.records.dropped)
        }
    }

    /// The current relocation set, block indices in order.
    var relocationSet: [Int] {
        guard let r = unsafe state.pointee.relocation else { return [] }
        return inspect { _ in
            unsafe (0..<r.pointee.state.pointee.selected.count).map { unsafe Int(r.pointee.state.pointee.selected[$0]) }
        }
    }

    /// Evacuated blocks waiting for the workers' epochs.
    var pendingBlocks: [Int] {
        guard let r = unsafe state.pointee.relocation else { return [] }
        return inspect { _ in
            unsafe (0..<r.pointee.state.pointee.pendingBlocks.count).map { unsafe Int(r.pointee.state.pointee.pendingBlocks[$0]) }
        }
    }

    /// `o`'s state word as it is now (an atomic read: no stop).
    func stateWord(of o: Oop) -> UInt64 { image.om.stateWord(o.raw) }

    /// The block `o`'s body is in (RELOCATING or not).
    func block(of o: Oop) -> Int { BlockHeap.block(ofOffset: stateWord(of: o) & ~EntryState.relocatingBit) }

    func isBlockInUse(_ b: Int) -> Bool { inspect { $0.heap.isInUse(b) } }

    /// The same without a stop (under the pool lock): for tests in which a
    /// worker is inside the VM on the test's own thread and would never
    /// park.
    func isBlockInUseNow(_ b: Int) -> Bool {
        let om = image.om
        om.lockPools()
        defer { om.unlockPools() }
        return om.heap.isInUse(b)
    }

    /// The relocator's counters and pending list without a stop: manual
    /// mode only, read on the thread that is the relocator.
    var relocationCountersNow: RelocationCounters {
        guard let r = unsafe state.pointee.relocation else { return RelocationCounters() }
        return unsafe r.pointee.state.pointee.counters
    }

    var pendingBlocksNow: [Int] {
        guard let r = unsafe state.pointee.relocation else { return [] }
        return unsafe (0..<r.pointee.state.pointee.pendingBlocks.count).map { unsafe Int(r.pointee.state.pointee.pendingBlocks[$0]) }
    }

    private func manualRelocator() -> (MarkingPointer, RelocationPointer) {
        guard let mk = unsafe state.pointee.marking, let r = unsafe state.pointee.relocation else {
            preconditionFailure("no concurrent relocation")
        }
        precondition(unsafe !mk.pointee.config.markerThread || mk.pointee.thread.pointee.thread == nil,
                     "the manual relocator entry points need markerThread off")
        return unsafe (mk, r)
    }

    /// Manual mode: the relocation pass of the current cycle, on this
    /// thread as the marker (phase sweeping).
    func relocate() {
        let (mk, _) = unsafe manualRelocator()
        let mw = unsafe mk.pointee.markerWorker
        unsafe enterVM(state, mw)
        if unsafe mk.phaseNow == .sweeping { _ = unsafe relocatePass(state, mk, cycle: mk.cycleNow) }
        unsafe leaveVM(state, mw)
    }

    /// Manual mode: free the pending blocks every worker's epoch passed.
    @discardableResult
    func freePendingNow() -> Int {
        let (mk, r) = unsafe manualRelocator()
        let mw = unsafe mk.pointee.markerWorker
        unsafe enterVM(state, mw)
        let n = unsafe tryFreePending(state, r, atPause: false)
        unsafe leaveVM(state, mw)
        return n
    }

    /// Step functions (tests): to-space and the CAS to RELOCATING, with the
    /// hazard check; nil if the CAS failed or a hazard slot names `o`. The
    /// calling thread is the marker participant inside the VM until
    /// `stepSwitch`: nothing may stop the world in between.
    func stepBegin(_ o: Oop) -> RelocStep? {
        let (mk, r) = unsafe manualRelocator()
        let mw = unsafe mk.pointee.markerWorker
        unsafe enterVM(state, mw)
        let om = image.om
        let off = om.stateWord(o.raw)
        let bytes = om.header(o).bodyBytes
        guard let dst = unsafe toSpace(r, bytes), unsafe relocBegin(state, r, mw, o.raw, off) else {
            unsafe leaveVM(state, mw)
            return nil
        }
        if unsafe r.pointee.config.testSwitches.hazardRule && isHazarded(state, o.raw) {
            unsafe relocRevert(r, mw, o.raw, off)
            unsafe leaveVM(state, mw)
            return nil
        }
        return RelocStep(object: o, from: off, to: dst, bytes: bytes)
    }

    func stepCopy(_ s: RelocStep) {
        let (_, r) = unsafe manualRelocator()
        unsafe copyBody(r.pointee.om, from: s.from, to: s.to, bytes: s.bytes)
    }

    func stepSwitch(_ s: RelocStep) {
        let (mk, r) = unsafe manualRelocator()
        let mw = unsafe mk.pointee.markerWorker
        unsafe relocSwitch(r, mw, s.object.raw, s.to, s.bytes)
        unsafe image.om.retire(r.pointee.state.pointee.context)
        unsafe leaveVM(state, mw)
    }

    /// Test: worker `i` passes a poll (its epoch word takes the epoch).
    func advanceEpoch(worker i: Int) { unsafe epochAdvance(state, state.worker(i)) }

    /// Test: worker `i`'s epoch word now.
    func epochWord(worker i: Int) -> UInt64 { unsafe state.shared(i).pointee.epoch.load(ordering: .relaxed) }

    /// Test: `hook(context, worker)` runs in `enterVM` between the load of
    /// the epoch and the store of it. Set before any worker runs.
    func setEnterWindow(_ hook: (@convention(c) (UnsafeMutableRawPointer?, Int) -> Void)?, context: UnsafeMutableRawPointer?) {
        unsafe state.pointee.enterWindow.pointee = EnterWindowHook(hook: hook, context: context)
    }

    /// Test: publish `o` in hazard slot `k` of worker `i` (which must be
    /// inside the VM on this thread) as a primitive does; answers the body
    /// offset the primitive would use.
    func hazardAcquireForTest(worker i: Int, slot k: Int, _ o: Oop) -> UInt64 {
        unsafe hazardAcquire(state, state.worker(i), k, o)
    }

    func hazardReleaseForTest(worker i: Int, slot k: Int) { unsafe hazardRelease(state, state.worker(i), k) }

    /// Test: free block `b` at a pause as if it were evacuated (the
    /// verifier must catch the bodies left in it).
    func freeBlockForTest(_ b: Int) {
        withWorldStopped {
            image.om.releaseEvacuatedBlock(b)
            if let r = unsafe state.pointee.relocation { unsafe r.pointee.state.pointee.verifyDue = true }
        }
    }

    /// Test: worker `i` enters or leaves the VM on this thread.
    func enter(worker i: Int) { unsafe enterVM(state, state.worker(i)) }
    func leave(worker i: Int) { unsafe leaveVM(state, state.worker(i)) }
}
