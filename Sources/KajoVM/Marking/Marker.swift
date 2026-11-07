import Darwin
import Synchronization

// The marker (docs/modules/concurrent-marking.md "The cycle"): one thread,
// a VM participant. It enters the VM to work, polls the safepoint flag
// every 128 traced objects and between queue items, parks without taking
// scavenge work, and leaves the VM to wait, untimed, when it has nothing
// to do. Only snapshot entries are ever marked or read: nothing young, no
// header a mutator may be writing.

/// Mark `v` grey if it is an unmarked snapshot entry: set its mark byte and
/// push it. One marker participant at a time writes mark bytes (the marker
/// between stops, the stopper in one), so a relaxed load and store do; the
/// barrier reads them relaxed.
@inline(__always)
func greyIfCandidate(_ mk: MarkingPointer, _ om: ObjectMemory, _ m: UnsafeMutablePointer<MarkerState>, _ v: UInt64) {
    if v & Oop.objectTagMask != 0 || v == 0 { return }
    let e = v &>> 4
    if unsafe !mk.pointee.snapshot.contains(e) { return }
    if om.markRelaxed(e) != 0 { return }
    om.setMarkRelaxed(e, 1)
    unsafe m.pointee.stack.append(v)
}

/// An ephemeron's key that leaves it unresolved: an unmarked snapshot
/// entry. A key that is not a snapshot entry is live by construction.
@inline(__always)
func isUnmarkedSnapshotEntry(_ mk: MarkingPointer, _ om: ObjectMemory, _ v: UInt64) -> Bool {
    if v & Oop.objectTagMask != 0 || v == 0 { return false }
    let e = v &>> 4
    return unsafe mk.pointee.snapshot.contains(e) && om.markRelaxed(e) == 0
}

/// Scan a marked snapshot object: every slot of an ordinary one (relaxed
/// atomic loads: mutators store concurrently), the named slots of a weak
/// one (listed for the final mark), an unfired ephemeron only once its key
/// is marked (else listed). Its header is stable: old, a snapshot entry.
///
/// Module 10: a large object's slots are scanned `traceChunkSlots` at a
/// time. The rest goes back on the stack as one item: the oop with the
/// next chunk's number in bits 40..63 (an oop, an entry offset, is below
/// 2^36), so the marker polls between chunks as between objects and a
/// 128 MiB Array costs a stop no more than any 128 objects do. SATB keeps
/// the split sound: a slot overwritten before its chunk is scanned is
/// recorded by the barrier, and a large object never moves.
/// Answers the work done in units of an ordinary object: a chunk counts
/// as `MarkChunk.weight`, so the marker's poll every 128 units comes after
/// at most four chunks.
@inline(__always) @discardableResult
func traceObject(_ mk: MarkingPointer, _ om: ObjectMemory, _ m: UnsafeMutablePointer<MarkerState>, _ item: UInt64) -> Int {
    let o = item & MarkChunk.oopMask
    let chunk = Int(truncatingIfNeeded: item &>> MarkChunk.shift)
    if _slowPath(chunk != 0) {
        unsafe traceChunk(mk, om, m, o, from: chunk &* MarkChunk.slots)
        return MarkChunk.weight
    }
    let h = om.headerWord(o)
    let s = om.stateWord(o)
    // Large bytes: a long byte object's size is in its back reference.
    let bytes = Header(raw: h).isLongBytes ? om.bodyWords(entry: o) &<< 3 : Header(raw: h).bodyBytes
    unsafe m.pointee.markedObjects &+= 1
    unsafe m.pointee.markedBytes &+= bytes
    // Module 6: live bytes per block, when a relocation is planned.
    if let live = unsafe m.pointee.blockLive {
        let b = BlockHeap.block(ofOffset: s)
        if unsafe b < m.pointee.blockLiveCount { unsafe live[b] &+= UInt32(truncatingIfNeeded: bytes) }
    }
    if h & Header.bytesBit != 0 { return 1 }
    var n = Int(truncatingIfNeeded: (h & Header.countMask) &>> Header.countShift)
    let f = om.classFormat(h & Header.classMask)
    if _slowPath(f.isSpecial) {
        if f.isWeak {
            unsafe m.pointee.weak.append(o)
            n = Swift.min(n, f.namedSlots)
        } else if h & Header.firedBit == 0 && n > 0 {
            if unsafe isUnmarkedSnapshotEntry(mk, om, om.loadAtomic(bodyOffset: s, 0)) {
                unsafe m.pointee.ephemerons.append(o)
                return 1
            }
        }
    }
    if _slowPath(n > MarkChunk.slots) {
        unsafe traceChunk(mk, om, m, o, from: 0)
        return MarkChunk.weight
    }
    var i = 0
    while i < n {
        unsafe greyIfCandidate(mk, om, m, om.loadAtomic(bodyOffset: s, i))
        i &+= 1
    }
    return 1
}

/// Module 10: where a large object's scan is split (`traceObject`).
enum MarkChunk {
    static let slots = 4096
    /// A chunk's share of the marker's poll interval (128 units).
    static let weight = 32
    static let shift: UInt64 = 40
    static let oopMask: UInt64 = (1 << 40) - 1
}

/// One chunk of a large object's slots, from slot `from`; the next chunk
/// goes back on the stack first (its children are traced before it).
@inline(never)
func traceChunk(_ mk: MarkingPointer, _ om: ObjectMemory, _ m: UnsafeMutablePointer<MarkerState>, _ o: UInt64, from: Int) {
    let h = om.headerWord(o)
    let s = om.stateWord(o)
    let n = Int(truncatingIfNeeded: (h & Header.countMask) &>> Header.countShift)
    let end = Swift.min(n, from &+ MarkChunk.slots)
    if end < n {
        unsafe m.pointee.stack.append(o | UInt64(truncatingIfNeeded: end / MarkChunk.slots) &<< MarkChunk.shift)
        unsafe m.pointee.chunksSplit &+= 1
    }
    var i = from
    while i < end {
        unsafe greyIfCandidate(mk, om, m, om.loadAtomic(bodyOffset: s, i))
        i &+= 1
    }
}

/// Every slot of `o`, strongly (a fired ephemeron's, a survivor's at the
/// initial mark).
@inline(__always)
func greySlots(_ mk: MarkingPointer, _ om: ObjectMemory, _ m: UnsafeMutablePointer<MarkerState>, _ o: UInt64) {
    let h = om.headerWord(o)
    if h & Header.bytesBit != 0 { return }
    let s = om.stateWord(o)
    let n = Int(truncatingIfNeeded: (h & Header.countMask) &>> Header.countShift)
    var i = 0
    while i < n {
        unsafe greyIfCandidate(mk, om, m, om.loadAtomic(bodyOffset: s, i))
        i &+= 1
    }
}

/// Trace until the stack is empty, with no poll (the final mark, world
/// stopped), or until `units` reaches `bound` (each object traced counts
/// what `traceObject` answers): false when the stack is not empty then.
func drainStack(_ mk: MarkingPointer, _ om: ObjectMemory, _ m: UnsafeMutablePointer<MarkerState>,
                units: inout Int, bound: Int) -> Bool {
    while units < bound, let o = unsafe m.pointee.stack.popLast() { units &+= unsafe traceObject(mk, om, m, o) }
    return unsafe m.pointee.stack.count == 0
}

/// The marker's queue holds an item (marking lock).
func queueHasItems(_ mk: MarkingPointer) -> Bool {
    unsafe pthread_mutex_lock(mk.pointee.lock)
    defer { unsafe pthread_mutex_unlock(mk.pointee.lock) }
    return unsafe mk.pointee.queue.pointee.items.count > 0
}

/// One queue item onto the stack: a grey packet's oops as they are, an
/// SATB buffer's entries marked first.
func takeItem(_ mk: MarkingPointer, _ om: ObjectMemory, _ m: UnsafeMutablePointer<MarkerState>, _ it: MarkItem) {
    var k = 0
    while unsafe k < it.count {
        let v = unsafe it.words[k]
        if unsafe it.grey { unsafe m.pointee.stack.append(v) } else { unsafe greyIfCandidate(mk, om, m, v) }
        k &+= 1
    }
}

/// Pop one queue item (marking lock), or nil.
func popItem(_ mk: MarkingPointer) -> MarkItem? {
    unsafe pthread_mutex_lock(mk.pointee.lock)
    defer { unsafe pthread_mutex_unlock(mk.pointee.lock) }
    return unsafe mk.pointee.queue.pointee.items.popLast()
}

func returnBuffer(_ mk: MarkingPointer, _ words: UnsafeMutablePointer<UInt64>) {
    unsafe pthread_mutex_lock(mk.pointee.lock)
    unsafe mk.pointee.queue.pointee.free.append(words)
    unsafe pthread_mutex_unlock(mk.pointee.lock)
}

enum MarkOutcome {
    /// The stack and the queue are empty.
    case done
    /// The limit was reached (manual mode).
    case limit
    /// The cycle was abandoned while the marker was parked.
    case abandoned
}

/// The marker's poll: park for a requested stop (never joining a
/// scavenge), take the QoS the policy asks for. False when the cycle
/// `cycle` is no longer the one marking, or the VM is shutting down.
@inline(never)
func markerPoll(_ vm: VMPointer, _ mk: MarkingPointer, cycle: UInt64, phase: MarkingPhase) -> Bool {
    let mw = unsafe mk.pointee.markerWorker
    // Bit 0 only: module 7's rounds (bits 1..) are not the marker's.
    if unsafe vm.pointee.flag.pointee.load(ordering: .relaxed) & 1 != 0 { unsafe park(vm, mw) }
    unsafe applyWantedQoS(mk)
    return unsafe mk.cycleNow == cycle && mk.phaseNow == phase && !mk.pointee.stopping.pointee.load(ordering: .relaxed)
}

/// Trace up to `limit` objects of the current cycle, inside the VM as the
/// marker worker.
func markSome(_ vm: VMPointer, _ mk: MarkingPointer, limit: Int) -> MarkOutcome {
    let om = unsafe mk.pointee.om
    let m = unsafe mk.pointee.marker
    let mw = unsafe mk.pointee.markerWorker
    let cycle = unsafe mk.cycleNow
    if unsafe mk.phaseNow != .marking { return .done }
    var n = 0
    // Module 10: work since the last poll, in objects; a large object's
    // chunk counts 32 (`MarkChunk.weight`).
    var work = 0
    while true {
        if let o = unsafe m.pointee.stack.popLast() {
            work &+= unsafe traceObject(mk, om, m, o)
            n &+= 1
            if work >= 128 {
                work = 0
                if unsafe !markerPoll(vm, mk, cycle: cycle, phase: .marking) {
                    unsafe dropMarkerWork(mk)
                    return .abandoned
                }
            }
            if n >= limit { return .limit }
            continue
        }
        unsafe perturb(vm, mw)  // between queue items
        if unsafe !markerPoll(vm, mk, cycle: cycle, phase: .marking) {
            unsafe dropMarkerWork(mk)
            return .abandoned
        }
        guard let it = unsafe popItem(mk) else { return .done }
        unsafe takeItem(mk, om, m, it)
        unsafe returnBuffer(mk, it.words)
    }
}

/// The marker's own lists, after an abandoned cycle.
func dropMarkerWork(_ mk: MarkingPointer) {
    let m = unsafe mk.pointee.marker
    unsafe m.pointee.stack.removeAll()
    unsafe m.pointee.weak.removeAll()
    unsafe m.pointee.ephemerons.removeAll()
}

/// Mark the current cycle to the end and request its final mark (the
/// marker is the stopper). Inside the VM as the marker worker. The final
/// mark on the devices: first the young-root scans the initial mark left
/// owed; the final mark is requested only with every scan done, the stack
/// and the queue empty (a collector's scan hands its candidates to the
/// queue before it is done, so the queue is read after the scans). A final
/// mark that gave up at its work bound leaves the cycle marking, and the
/// marker loop comes back here.
func markCycle(_ vm: VMPointer, _ mk: MarkingPointer) {
    let m = unsafe mk.pointee.marker
    let mw = unsafe mk.pointee.markerWorker
    let cycle = unsafe mk.cycleNow
    let w0 = nanoseconds(), c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    var outcome = MarkOutcome.done
    while true {
        if unsafe !markerScansYoungRoots(vm, mk, cycle: cycle) { outcome = .abandoned; break }
        let pending = unsafe rootScansPending(mk)
        outcome = unsafe markSome(vm, mk, limit: .max)
        if unsafe outcome != .done || !pending || mk.pointee.config.testSwitches.markerSkipsRootScans { break }
        if unsafe !markerWaitsForRootScans(vm, mk, cycle: cycle) { outcome = .abandoned; break }
    }
    unsafe m.pointee.markCpuNs &+= clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- c0
    unsafe m.pointee.markWallNs &+= nanoseconds() &- w0
    if outcome != .done { return }
    unsafe perturb(vm, mw)  // before the final-mark request
    unsafe m.pointee.qos = qos_class_self().rawValue
    unsafe mk.pointee.qosNow.pointee.store(m.pointee.qos, ordering: .relaxed)
    let context = FinalMarkContext.take()
    unsafe stopWorld(vm, mw, retry: true) { stop in unsafe runFinalMark(vm, mk, stop, cycle: cycle, context: context) }
}

// MARK: - QoS

/// Set the marker thread's QoS to what the policy asks for (utility, or
/// user-initiated while headroom is low). Only on the marker thread.
func applyWantedQoS(_ mk: MarkingPointer) {
    // Every marker-participant path runs on the marker thread when there
    // is one (the manual entry points refuse to run otherwise).
    guard unsafe mk.pointee.config.markerThread else { return }
    let m = unsafe mk.pointee.marker
    let want = unsafe mk.pointee.wantUserInitiated.pointee.load(ordering: .relaxed)
    let target = want ? QOS_CLASS_USER_INITIATED : QOS_CLASS_UTILITY
    if unsafe m.pointee.qos == target.rawValue { return }
    pthread_set_qos_class_self_np(target, 0)
    unsafe m.pointee.qos = qos_class_self().rawValue
    unsafe mk.pointee.qosNow.pointee.store(m.pointee.qos, ordering: .relaxed)
    if want { unsafe m.pointee.escalations &+= 1 } else { unsafe m.pointee.lowerings &+= 1 }
}

// MARK: - the thread

/// The marker thread: wait (untimed) until a cycle needs marking or
/// sweeping, then do it inside the VM. Every transition the wait depends on
/// changes under the marking lock and broadcasts its condition: the initial
/// mark (phase marking, a new cycle), the final mark (phase sweeping), and
/// shutdown. Everything else (aborts, the sweep's end, the apply) only
/// makes the conditions false. The audit is in the module doc.
func markerLoop(_ vm: VMPointer, _ mk: MarkingPointer) {
    let m = unsafe mk.pointee.marker
    let mw = unsafe mk.pointee.markerWorker
    unsafe mk.pointee.machThread.pointee.store(pthread_mach_thread_np(pthread_self()), ordering: .relaxed)
    unsafe m.pointee.qos = qos_class_self().rawValue
    unsafe mk.pointee.qosNow.pointee.store(m.pointee.qos, ordering: .relaxed)
    unsafe pthread_mutex_lock(mk.pointee.lock)
    while true {
        let q = unsafe mk.pointee.queue
        if unsafe q.pointee.shutdown { break }
        let phase = unsafe mk.phaseNow, cycle = unsafe mk.cycleNow
        let mark = unsafe phase == .marking && m.pointee.markedCycle != cycle
        let sweep = unsafe phase == .sweeping && m.pointee.sweptCycle != cycle
        if !mark && !sweep {
            unsafe q.pointee.waiting += 1
            unsafe pthread_cond_wait(mk.pointee.cond, mk.pointee.lock)
            unsafe q.pointee.waiting -= 1
            unsafe mk.pointee.markerWaits.pointee.wrappingAdd(1, ordering: .relaxed)
            continue
        }
        unsafe pthread_mutex_unlock(mk.pointee.lock)
        unsafe enterVM(vm, mw)
        unsafe applyWantedQoS(mk)
        if mark { unsafe markCycle(vm, mk) }
        if unsafe mk.phaseNow == .sweeping && m.pointee.sweptCycle != mk.cycleNow {
            // Module 6: relocate before sweeping (the sweep then sees the
            // new offsets, and evacuated blocks hold no live body).
            if let r = unsafe vm.pointee.relocation, unsafe !r.pointee.config.testSwitches.manualRelocation {
                _ = unsafe relocatePass(vm, mk, cycle: mk.cycleNow)
            }
        }
        if unsafe mk.phaseNow == .sweeping && m.pointee.sweptCycle != mk.cycleNow {
            if unsafe sweepCycle(vm, mk, inPause: false) && !mk.pointee.config.stress.contains(.sweepNeverApplies) {
                unsafe stopWorld(vm, mw, retry: true) { _ in
                    unsafe markStop(vm, .apply)
                    unsafe applyInStop(vm, mk)
                }
            }
        }
        unsafe applyWantedQoS(mk)
        unsafe leaveVM(vm, mw)
        unsafe pthread_mutex_lock(mk.pointee.lock)
    }
    unsafe pthread_mutex_unlock(mk.pointee.lock)
}

/// Start the marker thread at utility QoS (VM.start).
func startMarkerThread(_ vm: VMPointer) {
    guard let mk = unsafe vm.pointee.marking, unsafe mk.pointee.config.markerThread else { return }
    var attr = pthread_attr_t()
    unsafe pthread_attr_init(&attr)
    unsafe pthread_attr_set_qos_class_np(&attr, QOS_CLASS_UTILITY, 0)
    var t: pthread_t? = nil
    let rc = unsafe pthread_create(&t, &attr, { arg in
        let vm = unsafe arg.assumingMemoryBound(to: VMState.self)
        unsafe markerLoop(vm, vm.pointee.marking.unsafelyUnwrapped)
        return nil
    }, UnsafeMutableRawPointer(vm))
    precondition(rc == 0, "pthread_create failed: \(rc)")
    unsafe mk.pointee.thread.pointee.thread = t
    unsafe pthread_attr_destroy(&attr)
}

/// Stop and join the marker thread (VM.shutdown, after the workers). A
/// cycle in progress is left where the marker's next poll finds it.
func stopMarkerThread(_ vm: VMPointer) {
    guard let mk = unsafe vm.pointee.marking, let t = unsafe mk.pointee.thread.pointee.thread else { return }
    unsafe mk.pointee.stopping.pointee.store(true, ordering: .relaxed)
    unsafe pthread_mutex_lock(mk.pointee.lock)
    unsafe mk.pointee.queue.pointee.shutdown = true
    unsafe pthread_cond_broadcast(mk.pointee.cond)
    unsafe pthread_mutex_unlock(mk.pointee.lock)
    unsafe pthread_join(t, nil)
    unsafe mk.pointee.thread.pointee.thread = nil
}
