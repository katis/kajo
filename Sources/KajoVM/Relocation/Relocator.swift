import Darwin
import Synchronization

// Concurrent relocation of old space (docs/modules/relocation.md; ADR 0007;
// docs/models/relocation.md). The marker thread relocates between the
// final mark and the sweep: at the initial mark a relocation is planned
// (the marker counts live bytes per block while it traces); at the final
// mark, with the world stopped, sparse snapshot blocks are selected, taken
// out of the block pool, and every old object a running frame names gets
// a frame pin; in the sweeping phase, before sweeping, the marker moves
// every live unpinned object of the selected blocks, one at a time: to-
// space first, then the CAS to RELOCATING, the hazard check, the copy and
// the switch. A block whose objects all moved is pending until every
// worker's epoch has passed it (Epoch.swift), or the next pause. The pause
// that applies or aborts the cycle clears the frame pins.

// MARK: - the initial mark (world stopped)

/// Plan a relocation for `cycle` (count live bytes) unless the last cycle
/// found old space dense. Called by module 5's initial mark.
func relocationAtInitialMark(_ vm: VMPointer, _ mk: MarkingPointer, cycle: UInt64) {
    let m = unsafe mk.pointee.marker
    unsafe m.pointee.blockLive = nil
    guard let r = unsafe vm.pointee.relocation else { return }
    let st = unsafe r.pointee.state
    let config = unsafe r.pointee.config
    let plan = unsafe !config.stress.isEmpty || !st.pointee.haveDensity || st.pointee.lastDensity < config.planBelow
    guard plan else {
        unsafe st.pointee.plannedCycle = 0
        return
    }
    unsafe st.pointee.blockLive.update(repeating: 0, count: st.pointee.blockCount)
    unsafe st.pointee.plannedCycle = cycle
    unsafe m.pointee.blockLive = st.pointee.blockLive
    unsafe m.pointee.blockLiveCount = st.pointee.blockCount
    unsafe st.pointee.counters.cyclesPlanned &+= 1
}

// MARK: - the final mark (world stopped)

/// Select the relocation set and pin the running frames' objects. Called
/// by module 5's final mark after its verifier passed, before the sweep
/// may start.
func relocationAtFinalMark(_ vm: VMPointer, _ mk: MarkingPointer, cycle: UInt64) {
    let m = unsafe mk.pointee.marker
    unsafe m.pointee.blockLive = nil
    guard let r = unsafe vm.pointee.relocation else { return }
    let st = unsafe r.pointee.state
    let om = unsafe r.pointee.om
    let heap = om.heap
    let blockBytes = UInt64(BlockHeap.blockBytes)
    let inUse = om.blocksInUse
    // Density for the next cycle's plan: what the marker found live over
    // the bytes of the blocks in use.
    if inUse > 0 {
        unsafe st.pointee.lastDensity = Double(m.pointee.markedBytes) / Double(UInt64(inUse) &* blockBytes)
        unsafe st.pointee.haveDensity = true
    }
    guard unsafe st.pointee.plannedCycle == cycle else { return }
    let t0 = nanoseconds()
    let config = unsafe r.pointee.config
    let everyLive = config.stress.contains(.relocateEveryLiveBlock)
    let limit = UInt64(config.threshold * Double(blockBytes))
    let free = Swift.max(0, om.softLimitBlocks - inUse)
    let capBytes = UInt64(config.cap * Double(free)) &* blockBytes
    let stamp = UInt32(truncatingIfNeeded: cycle)
    var rec = RelocationCycleRecord()
    rec.cycle = cycle
    unsafe st.pointee.selected.removeAll()
    unsafe st.pointee.cursor = 0
    var planned: UInt64 = 0
    var chosen = RawArray<Bool>(repeating: false, count: heap.blockCount)
    defer { chosen.free() }
    for b in unsafe 0..<st.pointee.blockCount {
        let live = unsafe UInt64(st.pointee.blockLive[b])
        if live == 0 || !heap.isInUse(b) { continue }
        // Taken by an allocator since the snapshot: it holds bodies that
        // are not snapshot entries, and may be a context's current block.
        if om.blockStampAtPause(b) == stamp { continue }
        if !everyLive && live >= limit { continue }
        rec.candidates &+= 1
        if planned &+ live > capBytes {
            rec.capped &+= 1
            continue
        }
        planned &+= live
        unsafe st.pointee.selected.append(UInt32(b))
        chosen[b] = true
    }
    rec.blocksSelected = unsafe UInt64(st.pointee.selected.count)
    rec.bytesToMove = planned
    rec.expectedReclaimBytes = rec.blocksSelected &* blockBytes &- planned
    if rec.blocksSelected > 0 {
        om.withdrawFromPool { chosen[$0] }
        rec.framePins = unsafe UInt64(pinFrames(vm, r))
    }
    rec.selectNs = nanoseconds() &- t0
    unsafe st.pointee.current = rec
    unsafe st.pointee.hasCurrent = true
    unsafe st.pointee.verifyDue = true
    unsafe st.pointee.counters.candidates &+= rec.candidates
    unsafe st.pointee.counters.blocksSelected &+= rec.blocksSelected
    unsafe st.pointee.counters.capped &+= rec.capped
    unsafe st.pointee.counters.bytesToMove &+= rec.bytesToMove
    unsafe st.pointee.counters.expectedReclaimBytes &+= rec.expectedReclaimBytes
    unsafe st.pointee.counters.framePins &+= rec.framePins
    if rec.blocksSelected > 0 { unsafe st.pointee.counters.cyclesSelected &+= 1 }
}

/// Every word of each running Process's current frame (receiver to the
/// flushed sp, the method among them), for each worker that runs one. The
/// one walk the frame pins go through: module 8's Context materialization
/// changes what a frame is here, and nowhere else. World stopped.
func forEachRunningFrameWord(_ vm: VMPointer, _ body: (UInt64) -> Void) {
    for k in unsafe 0..<vm.pointee.workerCount {
        let w = unsafe vm.worker(k)
        if unsafe w.pointee.current == .none { continue }
        let regs = unsafe w.pointee.interp.regs
        let base = unsafe w.pointee.interp.stackBase
        if regs.sp < regs.fp { continue }
        for i in regs.fp...regs.sp { unsafe body(base[i]) }
    }
}

/// Frame pins (header bit 61) on every old object a running frame names
/// that is not pinned already; listed for the end of the cycle. World
/// stopped. Answers the objects pinned.
func pinFrames(_ vm: VMPointer, _ r: RelocationPointer) -> Int {
    let om = unsafe r.pointee.om
    let st = unsafe r.pointee.state
    var n = 0
    unsafe forEachRunningFrameWord(vm) { v in
        if v & Oop.objectTagMask != 0 || v == 0 { return }
        let h = om.headerWord(v)
        if h & (Header.youngBit | Header.pinnedForGoodBit | Header.framePinBit) != 0 { return }
        om.setHeaderWord(v, h | Header.framePinBit)
        unsafe st.pointee.framePins.append(v)
        n += 1
    }
    return n
}

// MARK: - the end of a cycle (world stopped)

/// The pause that applies or aborts the cycle: frame pins cleared, the
/// set forgotten (blocks left in it go back to the pool with the apply's
/// rebuild), the record closed.
func relocationAtCycleEnd(_ vm: VMPointer, completed: Bool) {
    if let mk = unsafe vm.pointee.marking { unsafe mk.pointee.marker.pointee.blockLive = nil }
    guard let r = unsafe vm.pointee.relocation else { return }
    let st = unsafe r.pointee.state
    let om = unsafe r.pointee.om
    for i in unsafe 0..<st.pointee.framePins.count {
        let v = unsafe st.pointee.framePins[i]
        om.setHeaderWord(v, om.headerWord(v) & ~Header.framePinBit)
    }
    unsafe st.pointee.framePins.removeAll()
    unsafe st.pointee.selected.removeAll()
    unsafe st.pointee.cursor = 0
    unsafe st.pointee.plannedCycle = 0
    if unsafe st.pointee.hasCurrent {
        unsafe st.pointee.current.completed = completed
        unsafe st.pointee.records.append(st.pointee.current)
        unsafe st.pointee.hasCurrent = false
        unsafe st.pointee.verifyDue = true
    }
}

// MARK: - the pass (the marker inside the VM, phase sweeping)

enum RelocateOutcome {
    case moved
    case hazard
    case casFailed
    case noSpace
}

/// Relocate every live unpinned object of the selected blocks of `cycle`,
/// polling between objects only. Answers false when the cycle was aborted
/// or applied meanwhile (the marker then does nothing more for it).
func relocatePass(_ vm: VMPointer, _ mk: MarkingPointer, cycle: UInt64) -> Bool {
    guard let r = unsafe vm.pointee.relocation else { return true }
    let st = unsafe r.pointee.state
    guard unsafe st.pointee.plannedCycle == cycle && st.pointee.relocatedCycle != cycle else { return true }
    let om = unsafe r.pointee.om
    let heap = om.heap
    let mw = unsafe mk.pointee.markerWorker
    let snap = unsafe mk.pointee.snapshot
    // Without the frame-pin rule (a test switch) objects pinned for good
    // still stay: moving the running method's bytecodes lets the worker
    // execute a freed block's next contents (ThreadSanitizer showed it).
    let pins = unsafe r.pointee.config.testSwitches.pinRule ? Header.pinnedForGoodBit | Header.framePinBit : Header.pinnedForGoodBit
    let w0 = nanoseconds(), c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    var aborted = false, noSpace = false
    var moved: UInt64 = 0, movedBytes: UInt64 = 0, pinned: UInt64 = 0, hazards: UInt64 = 0, cas: UInt64 = 0
    var evacuated: UInt64 = 0
    var n = 0
    var sincePoll: UInt64 = 0
    outer: while unsafe st.pointee.cursor < st.pointee.selected.count {
        let b = unsafe Int(st.pointee.selected[st.pointee.cursor])
        var skipped = false
        var off = BlockHeap.start(ofBlock: b)
        let end = off &+ heap.usedBytes(b)
        while off < end {
            // Between objects: the only place the relocator yields or polls.
            // A poll every 64 objects or 16 KiB copied, whichever comes
            // first, as the marker polls every 128 traced objects: the
            // time to safepoint stays bounded, and a stop storm still
            // leaves the pass a batch of objects per stop.
            unsafe perturb(vm, mw)
            n &+= 1
            if n & 63 == 0 || sincePoll >= 16384 {
                sincePoll = 0
                if unsafe !markerPoll(vm, mk, cycle: cycle, phase: .sweeping) {
                    aborted = true
                    break outer
                }
            }
            let br = om.wordAtomic(atOffset: off)
            let words = BackRef.words(br)
            if words == 0 { break }
            let here = off
            off &+= words &<< 3
            let e = BackRef.entryIndex(br)
            // A live snapshot entry whose body this is (not a dead one, not
            // a stale copy of a moved one). The mark first: an unmarked
            // entry may be free and reallocated meanwhile.
            if e == 0 || !snap.contains(e) || om.markRelaxed(e) == 0 { continue }
            let o = e &<< 4
            if om.stateWord(o) != here { continue }
            if om.headerWord(o) & pins != 0 {
                skipped = true
                pinned &+= 1
                continue
            }
            switch unsafe relocateOne(vm, r, mw, o, here, words &<< 3) {
            case .moved:
                moved &+= 1
                movedBytes &+= words &<< 3
                sincePoll &+= words &<< 3
            case .hazard:
                skipped = true
                hazards &+= 1
            case .casFailed:
                skipped = true
                cas &+= 1
            case .noSpace:
                noSpace = true
                break outer
            }
        }
        unsafe st.pointee.cursor &+= 1
        if !skipped {
            unsafe addPending(r, b)
            evacuated &+= 1
        }
        unsafe tryFreePending(vm, r, atPause: false)
    }
    // To-space's used bytes exact: the sweep and the verifiers read them.
    unsafe om.retire(st.pointee.context)
    if !aborted {
        unsafe st.pointee.relocatedCycle = cycle
        unsafe tryFreePending(vm, r, atPause: false)
    }
    let wall = nanoseconds() &- w0, cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- c0
    unsafe st.pointee.counters.objectsMoved &+= moved
    unsafe st.pointee.counters.bytesMoved &+= movedBytes
    unsafe st.pointee.counters.skippedPinned &+= pinned
    unsafe st.pointee.counters.skippedHazard &+= hazards
    unsafe st.pointee.counters.casFailures &+= cas
    unsafe st.pointee.counters.blocksEvacuated &+= evacuated
    unsafe st.pointee.counters.passWallNs &+= wall
    unsafe st.pointee.counters.passCpuNs &+= cpu
    if noSpace { unsafe st.pointee.counters.noSpace &+= 1 }
    if aborted { unsafe st.pointee.counters.passesAborted &+= 1 }
    if unsafe st.pointee.hasCurrent {
        unsafe st.pointee.current.objectsMoved &+= moved
        unsafe st.pointee.current.bytesMoved &+= movedBytes
        unsafe st.pointee.current.skippedPinned &+= pinned
        unsafe st.pointee.current.skippedHazard &+= hazards
        unsafe st.pointee.current.blocksEvacuated &+= evacuated
        unsafe st.pointee.current.passWallNs &+= wall
        unsafe st.pointee.current.passCpuNs &+= cpu
        if noSpace { unsafe st.pointee.current.noSpace = true }
        if aborted { unsafe st.pointee.current.aborted = true }
    }
    return !aborted
}

/// One object `o` whose body of `bytes` is at `off`: the copy protocol's
/// steps 3 to 7. To-space is allocated first (a refill takes the pool
/// lock, never parks); from the CAS to the switch or the revert nothing
/// polls, parks or allocates (the model's liveness finding: a park there
/// deadlocks with a mutator spinning in `postStoreSlow` or a hazard wait).
@inline(__always)
func relocateOne(_ vm: VMPointer, _ r: RelocationPointer, _ mw: WorkerPointer, _ o: UInt64, _ off: UInt64,
                 _ bytes: UInt64) -> RelocateOutcome {
    guard let dst = unsafe toSpace(r, bytes) else { return .noSpace }
    guard unsafe relocBegin(vm, r, mw, o, off) else { return .casFailed }
    if unsafe r.pointee.config.testSwitches.hazardRule && isHazarded(vm, r, o) {
        unsafe relocRevert(r, mw, o, off)
        return .hazard
    }
    unsafe perturbInCopy(vm, r, mw)
    unsafe relocCopy(r, off, dst, bytes)
    unsafe perturbInCopy(vm, r, mw)  // before the switch
    unsafe relocSwitch(r, mw, o, dst, bytes)
    return .moved
}

/// To-space for `bytes`: the relocator's context, refilled from the pool
/// under the soft limit. Does not bump (the switch does); nil when no
/// block is left.
@inline(__always)
func toSpace(_ r: RelocationPointer, _ bytes: UInt64) -> UInt64? {
    let ctx = unsafe r.pointee.state.pointee.context
    if unsafe ctx.state.pointee.top &+ bytes > ctx.state.pointee.end {
        if unsafe !r.pointee.om.refillBlock(ctx, bytes: bytes) { return nil }
    }
    return unsafe ctx.state.pointee.top
}

/// NORMAL -> RELOCATING: CAS `off -> off + R` (seq_cst), then a seq_cst
/// fence before the hazard check and the copy's loads. From here until the
/// switch or the revert the relocator is "in relocation".
@inline(__always)
func relocBegin(_ vm: VMPointer, _ r: RelocationPointer, _ mw: WorkerPointer, _ o: UInt64, _ off: UInt64) -> Bool {
    unsafe mw.pointee.inRelocation = true
    let sw = unsafe r.pointee.om.stateWordAtomic(o)
    let ok = unsafe sw.pointee.compareExchange(expected: off, desired: off | EntryState.relocatingBit,
                                               ordering: .sequentiallyConsistent).exchanged
    atomicMemoryFence(ordering: .sequentiallyConsistent)
    if !ok { unsafe mw.pointee.inRelocation = false }
    return ok
}

/// A hazarded object: back to `off` (release), skipped until the next cycle.
@inline(__always)
func relocRevert(_ r: RelocationPointer, _ mw: WorkerPointer, _ o: UInt64, _ off: UInt64) {
    unsafe r.pointee.om.stateWordAtomic(o).pointee.store(off, ordering: .releasing)
    unsafe mw.pointee.inRelocation = false
    unsafe r.pointee.state.pointee.verifyDue = true
}

/// The copy: the body word by word, back reference included (it names the
/// same entry and size), relaxed atomic loads from the old body and
/// relaxed atomic stores into the new one.
@inline(never)
func relocCopy(_ r: RelocationPointer, _ off: UInt64, _ dst: UInt64, _ bytes: UInt64) {
    let om = unsafe r.pointee.om
    var k: UInt64 = 0
    while k < bytes {
        om.setWordAtomic(atOffset: dst &+ k, om.wordAtomic(atOffset: off &+ k))
        k &+= 8
    }
}

/// The switch: one release store of the new offset; to-space bumped.
@inline(__always)
func relocSwitch(_ r: RelocationPointer, _ mw: WorkerPointer, _ o: UInt64, _ dst: UInt64, _ bytes: UInt64) {
    unsafe r.pointee.om.stateWordAtomic(o).pointee.store(dst, ordering: .releasing)
    unsafe mw.pointee.inRelocation = false
    let c = unsafe r.pointee.state.pointee.context.state
    unsafe c.pointee.top = dst &+ bytes
    unsafe r.pointee.state.pointee.verifyDue = true
}

/// A perturbation point inside an object's copy: a yield or a sleep, never
/// a poll (perturbation cannot place a park here; the assertion in `park`
/// and `theRelocatorNeverParksWhileRelocating` hold it to that).
@inline(__always)
func perturbInCopy(_ vm: VMPointer, _ r: RelocationPointer, _ mw: WorkerPointer) {
    guard unsafe vm.pointee.config.perturb != nil else { return }
    unsafe r.pointee.state.pointee.counters.perturbedCopies &+= 1
    unsafe perturb(vm, mw)
}

/// A park reached while the relocator is between a CAS and its switch or
/// revert: the model's deadlock. Counted; checked builds that trap stop.
func parkWhileRelocating(_ vm: VMPointer) {
    if let r = unsafe vm.pointee.relocation { unsafe r.pointee.state.pointee.counters.parksWhileRelocating &+= 1 }
    if unsafe vm.pointee.om.config.onVerifyFailure == .trap {
        preconditionFailure("kajo verify: the relocator parked between a CAS and its switch")
    }
}

// MARK: - pauses (world stopped)

/// At every pause, before its work: free every pending block (the world
/// stopped is every worker at a point where it holds no body pointer).
func relocationAtPauseStart(_ vm: VMPointer) {
    guard let r = unsafe vm.pointee.relocation else { return }
    let st = unsafe r.pointee.state
    if unsafe st.pointee.pendingBlocks.count > 0 { unsafe tryFreePending(vm, r, atPause: true) }
    let inUse = unsafe UInt64(r.pointee.om.blocksInUse)
    if unsafe inUse > st.pointee.counters.peakBlocksInUse { unsafe st.pointee.counters.peakBlocksInUse = inUse }
}

/// At the end of every pause that follows relocation work (a selection, a
/// moved or reverted object, a freed block, the end of a cycle) since the
/// last one that verified: the relocation verifier (when the object memory
/// verifies). Nothing it checks changes without such work (module 1's,
/// 4's and 5's verifiers keep checking the rest). An O(entries) walk at
/// every stop made a host that polls every 0.5 ms (module 5's marker-thread
/// tests) stop the world most of the time, and a utility-QoS marker under
/// load could not finish a cycle within their bounds.
func relocationAtPauseEnd(_ vm: VMPointer) {
    guard let r = unsafe vm.pointee.relocation, unsafe r.pointee.om.config.verify else { return }
    let st = unsafe r.pointee.state
    guard unsafe st.pointee.verifyDue else { return }
    unsafe st.pointee.verifyDue = false
    let issues = unsafe verifyRelocation(vm, r)
    unsafe r.pointee.state.pointee.counters.verifierRuns &+= 1
    unsafe r.pointee.state.pointee.counters.verifierFailures &+= UInt64(issues.count)
    unsafe r.pointee.om.record("relocation verifier", issues)
}
