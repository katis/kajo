// Concurrent relocation of old space (SPEC.md "Part 2"): selecting sparse
// blocks at the final mark, frame pins, the relocator (marker 0, before the
// sweep), the copy protocol on the entry's offset word, the epoch-based
// freeing of evacuated blocks, and the relocation verifier. The mutator side
// (post-store check, hazard slots) is in Memory.swift.

import Darwin
import Synchronization

// MARK: - selection and pins (final mark, world stopped)

/// Snapshot blocks with `0 < live < threshold` (or any live, `all`), in block
/// order, until the bytes to move reach the cap.
func selectRelocation(_ vm: VMRef) {
    let cm = vm.pointee.cm
    let heap = vm.pointee.heap
    let cfg = vm.pointee.cmConfig
    let list = cm.relocList
    list.pointee.count = 0
    let limit = cfg.relocThreshold > 100 ? Int.max : cfg.relocThreshold * blockSize / 100
    let cap = Int(cfg.relocCap * Double(heap.freeBlocks())) * blockSize
    var planned = 0, candidates = 0, capped = 0
    for b in 0..<heap.nblocks where cm.snapBlocks[b] != 0 && heap.inUse[b] {
        let live = Int(cm.blockLive[b].load(ordering: .relaxed))
        if live == 0 || (limit != Int.max && live >= limit) { continue }
        candidates += 1
        if planned + live > cap { capped += 1; continue }
        planned += live
        list.pointee.push(UInt32(b))
    }
    if let c = cm.log.pointee.current {
        c.pointee.relocCandidates = candidates
        c.pointee.relocBlocks = list.pointee.count
        c.pointee.relocCapped = capped
        c.pointee.relocPlannedBytes = UInt64(planned)
        c.pointee.reloc0 = relocCounters(vm)
        c.pointee.relocSelected = true
    }
}

/// Every old object named by the current frame of each running worker
/// (receiver to the flushed sp, method included) gets the frame pin.
/// Answers the number of objects pinned.
func pinFrames(_ vm: VMRef) -> Int {
    let om = vm.pointee.om
    let pins = vm.pointee.cm.pinList
    var n = 0
    for i in 0..<vm.pointee.workerCount {
        let x = worker(vm, i)
        if x.pointee.current == 0 { continue }
        guard let fp = x.pointee.fp else { continue }
        var p = fp
        while p <= x.pointee.sp {
            let v = p.pointee
            p += 1
            if v & 1 != 0 || v == 0 { continue }
            let h = om.header(v)
            if h & (youngBit | pinBit | framePinBit) != 0 { continue }
            om.setHeader(v, h | framePinBit)
            pins.pointee.push(v)
            n += 1
        }
    }
    vm.add(.relocPins, UInt64(n))
    if let c = vm.pointee.cm.log.pointee.current { c.pointee.framePins = n }
    return n
}

/// World stopped (apply or abort): clear frame pins, forget the set.
func endRelocation(_ vm: VMRef) {
    let om = vm.pointee.om
    let cm = vm.pointee.cm
    for i in 0..<cm.pinList.pointee.count {
        let v = cm.pinList.pointee.ptr[i]
        om.setHeader(v, om.header(v) & ~framePinBit)
    }
    cm.pinList.pointee.count = 0
    cm.relocList.pointee.count = 0
}

/// The per-cycle relocation counters, in the order the cycle record uses.
func relocCounters(_ vm: VMRef) -> (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64) {
    (vm.metric(.relocMovedBytes), vm.metric(.relocMovedObjects), vm.metric(.relocSkipPinned),
     vm.metric(.relocSkipHazard), vm.metric(.relocNoSpace), vm.metric(.relocEvacuated))
}

// MARK: - the relocator (marker 0, inside the VM)

public enum RelocResult { case moved, hazard, noSpace, casFailed }

/// Relocate every live, unpinned object of the selected blocks. Answers
/// false if the cycle was aborted (a fallback) meanwhile.
@discardableResult
func relocPass(_ vm: VMRef, _ m: MarkerRef, _ cyc: UInt64) -> Bool {
    let cm = vm.pointee.cm
    let om = vm.pointee.om
    let heap = vm.pointee.heap
    let pinRule = vm.pointee.cmConfig.pinRule
    let cpu0 = threadCpuNs()
    m.pointee.relocStart = now()
    var aborted = false
    var noSpace = false
    let list = cm.relocList
    var bi = 0
    outer: while bi < list.pointee.count {
        let b = Int(list.pointee.ptr[bi])
        bi += 1
        var skipped = false
        var addr = heap.blockStart(b)
        let end = addr &+ UInt(heap.used[b])
        while addr < end {
            if vm.pointee.gcRequested.load(ordering: .relaxed) {
                heap.retire(&m.pointee.tlab)
                markerSafepoint(vm, m)
                if cm.phase.pointee.load(ordering: .acquiring) != CMPhase.sweeping
                    || cm.cycle.pointee.load(ordering: .relaxed) != cyc {
                    aborted = true
                    break outer
                }
            }
            let br = atomicWord(wordPtr(addr)).pointee.load(ordering: .relaxed)
            let size = Int(truncatingIfNeeded: br &>> 32) &* 8
            if size == 0 { break }
            let here = addr
            addr &+= UInt(size)
            let o = (br & 0xFFFF_FFFF) &<< 4
            if !cm.inSnap(o) || !cm.isMarked(o) { continue }
            let off = UInt64(here &- om.heap)
            if om.offsetWord(o).pointee.load(ordering: .relaxed) != off { continue } // stale copy
            let h = atomicHeader(om.entry(o)).pointee.load(ordering: .relaxed)
            if pinRule && h & (pinBit | framePinBit) != 0 {
                skipped = true
                vm.add(.relocSkipPinned, 1)
                continue
            }
            switch relocateOne(vm, m, o, off, size) {
            case .moved: break
            case .hazard: skipped = true
            case .casFailed: skipped = true
            case .noSpace:
                noSpace = true
                break outer
            }
        }
        if !skipped {
            addPending(vm, b)
            vm.add(.relocEvacuated, 1)
        }
        tryFreePending(vm, atPause: false)
    }
    heap.retire(&m.pointee.tlab)
    if noSpace { vm.add(.relocNoSpace, 1) }
    m.pointee.relocEnd = now()
    m.pointee.relocCpu = threadCpuNs() &- cpu0
    if !aborted { tryFreePending(vm, atPause: false) }
    return !aborted
}

/// One object, offset `off`, `size` bytes: steps 3 to 7 of the copy protocol.
@inline(__always)
func relocateOne(_ vm: VMRef, _ m: MarkerRef, _ o: Oop, _ off: UInt64, _ size: Int) -> RelocResult {
    guard let dst = relocAllocate(vm, m, size) else { return .noSpace }
    if !relocBegin(vm, o, off) { vm.add(.relocCasFail, 1); return .casFailed }
    if vm.pointee.cmConfig.hazardRule && hazarded(vm, o) {
        relocRevert(vm, o, off)
        vm.add(.relocSkipHazard, 1)
        return .hazard
    }
    m.pointee.tlab.cur = dst &+ UInt(size)
    relocCopy(vm, off, dst, size)
    relocSwitch(vm, o, dst)
    vm.add(.relocMovedBytes, UInt64(size))
    vm.add(.relocMovedObjects, 1)
    return .moved
}

/// To-space: the relocator's TLAB (fresh blocks under the soft limit). Does
/// not bump; nil when no block is left.
func relocAllocate(_ vm: VMRef, _ m: MarkerRef, _ size: Int) -> UInt? {
    if m.pointee.tlab.end &- m.pointee.tlab.cur < UInt(size) {
        if !vm.pointee.heap.refill(&m.pointee.tlab, soft: true) { return nil }
    }
    return m.pointee.tlab.cur
}

/// NORMAL -> RELOCATING (seq_cst CAS), then a seq_cst fence before the
/// hazard check and the copy loads (SPEC.md "Ordering argument").
@inline(__always)
func relocBegin(_ vm: VMRef, _ o: Oop, _ off: UInt64) -> Bool {
    let (ok, _) = vm.pointee.om.offsetWord(o).pointee.compareExchange(expected: off, desired: off | relocBit,
                                                                         ordering: .sequentiallyConsistent)
    atomicMemoryFence(ordering: .sequentiallyConsistent)
    return ok
}

@inline(__always)
func relocRevert(_ vm: VMRef, _ o: Oop, _ off: UInt64) {
    vm.pointee.om.offsetWord(o).pointee.store(off, ordering: .releasing)
}

/// Any worker's hazard slot names `o` (seq_cst loads).
func hazarded(_ vm: VMRef, _ o: Oop) -> Bool {
    for i in 0..<vm.pointee.workerCount {
        let hz = worker(vm, i).pointee.hz
        if hz[0].load(ordering: .sequentiallyConsistent) == o || hz[1].load(ordering: .sequentiallyConsistent) == o {
            return true
        }
    }
    return false
}

/// Word copy, relaxed atomic loads from the old body and relaxed atomic
/// stores into the new one.
@inline(__always)
func relocCopy(_ vm: VMRef, _ off: UInt64, _ dst: UInt, _ size: Int) {
    let src = wordPtr(vm.pointee.om.heap &+ UInt(truncatingIfNeeded: off))
    let d = wordPtr(dst)
    var k = 0
    let n = size &>> 3
    while k < n {
        atomicWord(d + k).pointee.store(atomicWord(src + k).pointee.load(ordering: .relaxed), ordering: .relaxed)
        k &+= 1
    }
}

/// The switch: one release store of the new offset.
@inline(__always)
func relocSwitch(_ vm: VMRef, _ o: Oop, _ dst: UInt) {
    vm.pointee.om.offsetWord(o).pointee.store(UInt64(dst &- vm.pointee.om.heap), ordering: .releasing)
}

// MARK: - epochs and freeing (SPEC.md "Freeing old blocks: epochs")

/// A worker passes a point where it holds no body pointer.
@inline(__always)
func advanceEpoch(_ vm: VMRef, _ w: WorkerRef) {
    w.pointee.hz[hzEpoch].store(vm.pointee.cm.epoch.pointee.load(ordering: .acquiring), ordering: .releasing)
}

@inline(__always)
func quiesce(_ w: WorkerRef) {
    w.pointee.hz[hzEpoch].store(quiescent, ordering: .releasing)
}

/// Relocator: block `b` is evacuated; its switches happened before this.
func addPending(_ vm: VMRef, _ b: Int) {
    let cm = vm.pointee.cm
    let s = cm.epoch.pointee.wrappingAdd(1, ordering: .sequentiallyConsistent).oldValue
    cm.pending.pointee.blocks.push(UInt32(b))
    cm.pending.pointee.epochs.push(s)
    cm.pending.pointee.times.push(now())
    cm.pendingCount.pointee.store(cm.pending.pointee.blocks.count, ordering: .relaxed)
}

/// Free every pending block whose switch epoch every worker has passed (all
/// of them at a pause). Inside the VM (relocator) or world stopped.
@discardableResult
func tryFreePending(_ vm: VMRef, atPause: Bool) -> Int {
    let cm = vm.pointee.cm
    let pend = cm.pending
    let n = pend.pointee.blocks.count
    if n == 0 { return 0 }
    var minEpoch = quiescent
    if !atPause && vm.pointee.cmConfig.epochRule {
        for i in 0..<vm.pointee.workerCount {
            minEpoch = min(minEpoch, worker(vm, i).pointee.hz[hzEpoch].load(ordering: .acquiring))
        }
    }
    let heap = vm.pointee.heap
    var kept = 0, freed = 0
    let t = now()
    for i in 0..<n {
        let b = Int(pend.pointee.blocks.ptr[i])
        let s = pend.pointee.epochs.ptr[i]
        let ok = atPause || minEpoch > s || !vm.pointee.cmConfig.epochRule
        var done = false
        if ok {
            if atPause { heap.freeAtPause(b); done = true } else { done = heap.appendFree(b) }
        }
        if done {
            cm.snapBlocks[b] = 0
            freed += 1
            let d = t &- pend.pointee.times.ptr[i]
            vm.add(atPause ? .relocFreedPause : .relocFreedEpoch, 1)
            vm.add(.relocFreeDelayNs, d)
            var cur = vm.metric(.relocFreeDelayMaxNs)
            while cur < d {
                let (won, v) = vm.pointee.metrics[Metric.relocFreeDelayMaxNs.rawValue].compareExchange(expected: cur, desired: d, ordering: .relaxed)
                if won { break }
                cur = v
            }
        } else {
            pend.pointee.blocks.ptr[kept] = pend.pointee.blocks.ptr[i]
            pend.pointee.epochs.ptr[kept] = s
            pend.pointee.times.ptr[kept] = pend.pointee.times.ptr[i]
            kept += 1
        }
    }
    pend.pointee.blocks.count = kept
    pend.pointee.epochs.count = kept
    pend.pointee.times.count = kept
    cm.pendingCount.pointee.store(kept, ordering: .relaxed)
    return freed
}

// MARK: - verifier (SPEC.md "Verifier"), world stopped

func relocVerify(_ vm: VMRef) {
    vm.add(.relocVerifyRuns, 1)
    let om = vm.pointee.om
    let heap = vm.pointee.heap
    let cm = vm.pointee.cm
    func failure(_ msg: String) {
        let n = vm.metric(.verifyFailures)
        vm.add(.verifyFailures, 1)
        if n < 10 { FileHandleStderr.write("verify: \(msg)\n") }
    }
    // Where each block's bodies end: `used`, or an open buffer's cursor.
    var end = [Int](repeating: 0, count: heap.nblocks)
    for b in 0..<heap.nblocks { end[b] = Int(heap.used[b]) }
    func open(_ t: Tlab) {
        if t.block != noBlock { end[Int(t.block)] = max(end[Int(t.block)], Int(t.cur &- heap.blockStart(Int(t.block)))) }
    }
    for i in 0..<vm.pointee.workerCount { open(worker(vm, i).pointee.promo); open(worker(vm, i).pointee.tlab) }
    for k in 0..<cm.markerCount.pointee { open(cm.markers[k].pointee.tlab) }
    var inFree = [UInt8](repeating: 0, count: heap.nblocks)
    let lo = min(heap.freeNext.pointee.load(ordering: .relaxed), heap.freeCount.pointee.load(ordering: .relaxed))
    for i in lo..<heap.freeCount.pointee.load(ordering: .relaxed) {
        let b = Int(heap.freeList[i])
        if inFree[b] != 0 { failure("block \(b) twice in the free list") }
        inFree[b] = 1
        if heap.inUse[b] { failure("block \(b) in use and in the free list") }
    }
    for i in 0..<cm.pending.pointee.blocks.count {
        let b = Int(cm.pending.pointee.blocks.ptr[i])
        if inFree[b] != 0 { failure("pending block \(b) in the free list") }
    }
    let sp = vm.pointee.space
    for gw in 0..<(chunkHwmNow(vm) * wordsPerChunk) {
        var bits = sp.used[gw]
        while bits != 0 {
            let idx = gw * 64 + bits.trailingZeroBitCount
            bits &= bits - 1
            if idx == 0 || pendingDead(vm, idx) { continue }
            let o = UInt64(idx) << 4
            let off = om.offsetWord(o).pointee.load(ordering: .relaxed)
            if off & relocBit != 0 { failure("entry \(idx) RELOCATING at a pause"); continue }
            let addr = om.heap &+ UInt(off)
            let h = om.header(o)
            if !heap.inNurseries(addr) {
                let b = heap.blockOf(addr)
                if b < 0 || b >= heap.nblocks { failure("entry \(idx) body outside the heap"); continue }
                if !heap.inUse[b] { failure("entry \(idx) body in free block \(b)") }
                if inFree[b] != 0 { failure("entry \(idx) body in block \(b) of the free list") }
                if Int(addr &- heap.blockStart(b)) + objectBytes(h) > end[b] { failure("entry \(idx) body beyond the used part of block \(b)") }
            }
            if wordPtr(addr).pointee & 0xFFFF_FFFF != UInt64(idx) { failure("entry \(idx) body's back reference names another entry") }
        }
    }
}

// MARK: - host and test API

/// Manual relocator: run the relocation pass of the current cycle on this
/// thread (inside the VM). Phase must be sweeping.
public func cmRelocate(_ vm: VMRef, _ m: MarkerRef) {
    enterVM(vm, m.pointee.w)
    if cmPhase(vm) == CMPhase.sweeping {
        relocPass(vm, m, vm.pointee.cm.cycle.pointee.load(ordering: .relaxed))
    }
    leaveVM(vm, m.pointee.w)
}

/// Blocks selected for the current cycle (tests).
public func relocSet(_ vm: VMRef) -> [Int] {
    (0..<vm.pointee.cm.relocList.pointee.count).map { Int(vm.pointee.cm.relocList.pointee.ptr[$0]) }
}

/// Block holding `o`'s body (tests).
public func blockOfObject(_ vm: VMRef, _ o: Oop) -> Int {
    Int(vm.pointee.om.offsetWord(o).pointee.load(ordering: .relaxed) & ~relocBit) / blockSize
}

public func offsetOf(_ vm: VMRef, _ o: Oop) -> UInt64 {
    vm.pointee.om.offsetWord(o).pointee.load(ordering: .relaxed)
}

/// Step API for one object (tests): allocate and begin, copy, switch.
public struct RelocStep {
    public var o: Oop
    public var off: UInt64
    public var dst: UInt
    public var size: Int
}

public func testRelocBegin(_ vm: VMRef, _ m: MarkerRef, _ o: Oop) -> RelocStep? {
    let off = offsetOf(vm, o)
    let size = objectBytes(vm.pointee.om.header(o))
    guard let dst = relocAllocate(vm, m, size) else { return nil }
    if !relocBegin(vm, o, off) { return nil }
    if vm.pointee.cmConfig.hazardRule && hazarded(vm, o) { relocRevert(vm, o, off); return nil }
    m.pointee.tlab.cur = dst &+ UInt(size)
    return RelocStep(o: o, off: off, dst: dst, size: size)
}

public func testRelocCopy(_ vm: VMRef, _ s: RelocStep) { relocCopy(vm, s.off, s.dst, s.size) }
public func testRelocSwitch(_ vm: VMRef, _ m: MarkerRef, _ s: RelocStep) {
    relocSwitch(vm, s.o, s.dst)
    vm.pointee.heap.retire(&m.pointee.tlab)
}

/// Free pending blocks whose epoch every worker passed (tests; the marker
/// thread does this every millisecond). Inside the VM on the marker record.
@discardableResult
public func cmTryFree(_ vm: VMRef, _ m: MarkerRef) -> Int {
    enterVM(vm, m.pointee.w)
    let n = tryFreePending(vm, atPause: false)
    leaveVM(vm, m.pointee.w)
    return n
}

public func pendingBlocks(_ vm: VMRef) -> [Int] {
    let p = vm.pointee.cm.pending
    return (0..<p.pointee.blocks.count).map { Int(p.pointee.blocks.ptr[$0]) }
}

/// Test: a worker passes a poll (its epoch advances).
public func testAdvanceEpoch(_ vm: VMRef, _ w: WorkerRef) { advanceEpoch(vm, w) }
