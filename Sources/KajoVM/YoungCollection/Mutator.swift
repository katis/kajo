import Darwin
import Synchronization

// The mutator's side of young collection without stopping the world
// (docs/modules/young-collection.md "Barriers", "Processes"): the young
// deletion barrier in the flag word's slow path, the scan of a parked
// Process a worker resumes, a new Process's scan words, and the test
// primitive that holds a body pointer across a blocking region.

/// The young deletion barrier (SPEC "Barriers"): slot `i` of `o` is about
/// to be overwritten while a young collection runs. If the old value is a
/// young object whose nursery is being collected, it is recorded in this
/// worker's deletion buffer for that nursery (published at its rounds).
/// The holder may be anything, young holders included (unlike SATB).
@inline(__always)
func youngDeletionRecord(_ vm: VMPointer, _ y: YoungPointer, _ w: WorkerPointer, _ old: UInt64) {
    if old & Oop.objectTagMask != 0 || old == 0 { return }
    let om = unsafe vm.pointee.om
    let h = om.headerWord(old)
    if h & Header.youngBit == 0 || h & Header.deferredBit != 0 { return }
    let n = Int(truncatingIfNeeded: (h & Header.nurseryMask) &>> Header.nurseryShift)
    if unsafe !y.pointee.collecting[n].load(ordering: .acquiring) { return }
    guard let a = unsafe w.pointee.interp.young else { return }
    unsafe (a.pointee.buffers + (16 &+ n)).pointee.append(old)
    unsafe y.counters(w.pointee.index).pointee.deletionRecords &+= 1
}

/// The barrier slow path's young part: the value slot `i` of `o` holds
/// before the store (relaxed atomic load through the state word; a
/// RELOCATING one leads to the intact old body through the alias).
@inline(__always)
func youngDeletionBarrier(_ vm: VMPointer, _ w: WorkerPointer, _ o: UInt64, _ i: Int) {
    guard let y = unsafe vm.pointee.young, unsafe y.pointee.config.testSwitches.youngDeletionBarrier,
          unsafe barrierWord(vm.pointee.flag).pointee.load(ordering: .relaxed) > 1 else { return }
    // Counted, so a test sees the stress flag `barrierAlwaysOn` really take
    // this path after a marking cycle (collectors review, finding 4).
    unsafe y.counters(w.pointee.index).pointee.deletionBarrierCalls &+= 1
    let om = unsafe vm.pointee.om
    unsafe youngDeletionRecord(vm, y, w, om.loadAtomic(bodyOffset: om.stateWord(o), i))
}

// MARK: - Processes (SPEC "Processes")

/// Before worker `w` runs Process record `ri` (its stack parked, stable):
/// for every collection past its H1 start that has not scanned this
/// record, scan it (winning the scan word), or wait while the collector
/// holds it. The roots go to the collection.
@inline(never)
func youngResumeCheck(_ vm: VMPointer, _ y: YoungPointer, _ w: WorkerPointer, _ ri: Int) {
    let om = unsafe vm.pointee.om
    for k in unsafe 0..<y.pointee.count {
        if unsafe !y.pointee.collecting[k].load(ordering: .acquiring) || !y.pointee.afterH1[k].load(ordering: .acquiring) { continue }
        let s = unsafe y.pointee.seq[k].load(ordering: .relaxed)
        let word = unsafe y.scanWord(k, ri)
        var spins = 0
        while true {
            let cur = unsafe word.pointee.load(ordering: .acquiring)
            if cur == s { break }
            if cur == s | scanningBit {
                spins &+= 1
                if spins & 63 == 0 { sched_yield() }
                continue
            }
            if unsafe word.pointee.compareExchange(expected: cur, desired: s | scanningBit, ordering: .acquiringAndReleasing).exchanged {
                var roots = RawArray<UInt64>()
                let r = unsafe records(vm, ri)
                if unsafe y.pointee.config.testSwitches.handshakeStackScan, let base = unsafe r.pointee.base {
                    let sp = Int(truncatingIfNeeded: om.load(unsafe r.pointee.process, ProcessLayout.sp).smallIntegerValue)
                    unsafe scanWords(vm, y, k, base, sp &+ 1, &roots)
                }
                unsafe pthread_mutex_lock(vm.pointee.safepointLock)
                let h = unsafe y.handshake(k)
                for i in 0..<roots.count { unsafe h.pointee.roots.append(roots[i]) }
                unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
                roots.free()
                unsafe word.pointee.store(s, ordering: .releasing)
                unsafe y.counters(w.pointee.index).pointee.resumeScans &+= 1
                break
            }
        }
    }
}

/// Scheduler lock held, a new Process record: scanned for collection k
/// iff k is past T1 (it starts from values its creator held after the
/// creator's own H1 scan).
func youngNewRecordLocked(_ vm: VMPointer, _ ri: Int) {
    guard let y = unsafe vm.pointee.young else { return }
    for k in unsafe 0..<y.pointee.count {
        let v: UInt64 = unsafe y.pointee.afterT1[k].load(ordering: .relaxed) ? y.pointee.seq[k].load(ordering: .relaxed) : 0
        unsafe y.scanWord(k, ri).pointee.store(v, ordering: .relaxed)
    }
}

// MARK: - the test primitive

/// Primitive 39, `obj slowPeek: i` (tests): take slot i's address in `obj`'s
/// body with no hazard slot, enter a blocking region, wait while the
/// test's gate is closed, read through the address, leave the region. The
/// epoch rule is what keeps the body (the region keeps the epoch word).
func primSlowPeek(_ m: Machine, _ c: PrimitiveCall) -> Oop {
    guard c.argc == 1, c.receiver.isObject, c.arg0.isSmallInteger, !m.om.isBytes(c.receiver) else { return .none }
    let i = Int(c.arg0.smallIntegerValue) - 1
    guard i >= 0, UInt64(i) < m.om.count(of: c.receiver) else { return .none }
    let w = unsafe workerOf(m.state)
    let om = m.om
    let addr = unsafe (om.heapBase + Int(truncatingIfNeeded: om.stateWord(c.receiver.raw) &+ 8) + i &* 8)
        .assumingMemoryBound(to: Atomic<UInt64>.self)
    guard let vm = unsafe w.pointee.vm, let y = unsafe vm.pointee.young else {
        return Oop(raw: unsafe addr.pointee.load(ordering: .relaxed))
    }
    unsafe blockingBegin(vm, w)
    unsafe y.pointee.peekHeld.pointee.store(1, ordering: .releasing)
    while unsafe y.pointee.peekGate.pointee.load(ordering: .acquiring) != 0 { usleep(100) }
    let v = unsafe addr.pointee.load(ordering: .relaxed)
    unsafe blockingEnd(vm, w)
    return Oop(raw: v)
}
