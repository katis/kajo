import Darwin
import Synchronization

// The handshake (docs/modules/young-collection.md "Rounds";
// docs/models/young-collection.md, steps `opens H0 / H1 / drain`,
// `acknowledges`, `waits`, `wakes`, `leaveVM`, `enterVM`, `blockingBegin`).
// The attention word is module 3's safepoint flag: bit 0 a stop is
// requested, bits 1.. twice the rounds open. The poll is unchanged (one
// load); its slow path parks for a stop and services rounds. Everything
// a round hands over moves under the safepoint mutex.

/// Rounds are open (bits 1.. of the attention word).
@inline(__always)
func roundsOpen(_ vm: VMPointer) -> Bool { unsafe vm.pointee.flag.pointee.load(ordering: .relaxed) > 1 }

/// Values of `[p, p + n)` naming a young object of nursery `k` in the part
/// being collected (Y_k), appended to `out`. Relaxed atomic loads.
@inline(__always)
func scanWords(_ vm: VMPointer, _ y: YoungPointer, _ k: Int, _ p: UnsafeMutablePointer<UInt64>, _ n: Int,
               _ out: inout RawArray<UInt64>) {
    let words = unsafe UnsafeMutableRawPointer(p).assumingMemoryBound(to: Atomic<UInt64>.self)
    var i = 0
    while i < n {
        let v = unsafe words[i].load(ordering: .relaxed)
        if unsafe inY(y, k, v) { out.append(v) }
        i &+= 1
    }
}

/// Is `v` a young object of nursery `k` whose body lies in the part being
/// collected: the eden (or eden half) handed to the collection, or
/// survivor-from (two range compares on the state word).
@inline(__always)
func inY(_ y: YoungPointer, _ k: Int, _ v: UInt64) -> Bool {
    if v & Oop.objectTagMask != 0 || v == 0 { return false }
    let om = unsafe y.pointee.om
    let h = om.headerWord(v)
    if h & (Header.youngNurseryMask | Header.deferredBit) != Header.youngBit | UInt64(k) &<< Header.nurseryShift { return false }
    let off = om.stateWord(v) & ~EntryState.relocatingBit
    let r = unsafe y.range(k)
    return unsafe (off >= r[0].load(ordering: .relaxed) && off < r[1].load(ordering: .relaxed))
        || (off >= r[2].load(ordering: .relaxed) && off < r[3].load(ordering: .relaxed))
}

// MARK: - round work

/// Hand participant `i`'s remembered and deletion buffers for nursery `k`
/// to the collection.
private func publish(_ n: NurseryPointer, _ i: Int, _ k: Int, _ pubs: inout RawArray<PublishedBuffer>) {
    let r = unsafe n.remBuffer(i, k)
    if unsafe r.pointee.count > 0 {
        unsafe pubs.append(PublishedBuffer(list: r.pointee, remembered: true))
        unsafe r.pointee = RawArray()
    }
    let d = unsafe n.delBuffer(i, k)
    if unsafe d.pointee.count > 0 {
        unsafe pubs.append(PublishedBuffer(list: d.pointee, remembered: false))
        unsafe d.pointee = RawArray()
    }
}

/// Participant `w`'s roots for nursery `k`: its current Process's stack
/// from its base to the flushed sp, the `current`, receiver and method
/// registers, and the oop its allocation slow path holds (not `result`:
/// concurrent-young amendment 8). Then its Process counts as scanned for
/// this collection. The host worker's roots are module 1's registry.
func scanOwnStack(_ vm: VMPointer, _ y: YoungPointer, _ w: WorkerPointer, _ k: Int, _ out: inout RawArray<UInt64>) {
    let rule = unsafe y.pointee.config.testSwitches.handshakeStackScan
    if rule {
        if unsafe w.pointee.current != .none {
            let sp = unsafe w.pointee.interp.regs.sp
            unsafe scanWords(vm, y, k, w.pointee.interp.stackBase, sp &+ 1, &out)
            for v in unsafe [w.pointee.current.raw, w.pointee.interp.regs.receiver.raw, w.pointee.interp.regs.method.raw]
                where unsafe inY(y, k, v) { out.append(v) }
        }
        let held = unsafe w.pointee.youngHeld
        if unsafe inY(y, k, held) { out.append(held) }
        if unsafe w.pointee.index == vm.pointee.workerCount &- 1 { unsafe scanRegistry(vm, y, k, &out) }
    }
    let ri = unsafe w.pointee.record
    if ri >= 0 { unsafe y.scanWord(k, ri).pointee.store(y.pointee.seq[k].load(ordering: .relaxed), ordering: .releasing) }
}

/// Module 1's root registry (the host's roots), scanned in the host
/// worker's H1 work: only host calls change it, inside the VM on the host
/// worker, one at a time.
func scanRegistry(_ vm: VMPointer, _ y: YoungPointer, _ k: Int, _ out: inout RawArray<UInt64>) {
    let om = unsafe vm.pointee.om
    om.forEachRegisteredRoot { v in if unsafe inY(y, k, v.raw) { out.append(v.raw) } }
}

/// One round's work for participant `i` (by itself, or by proxy with the
/// mutex held: `scan` is then whether it is in a blocking region).
private func roundWork(_ vm: VMPointer, _ y: YoungPointer, _ i: Int, _ k: Int, _ kind: RoundKind, scan: Bool,
                       _ roots: inout RawArray<UInt64>, _ pubs: inout RawArray<PublishedBuffer>) {
    let n = unsafe y.pointee.nursery
    switch kind {
    case .h0:
        // Records from an earlier collection of k may name freed entries.
        unsafe n.delBuffer(i, k).pointee.removeAll()
    case .h1:
        if scan { unsafe scanOwnStack(vm, y, vm.worker(i), k, &roots) }
        unsafe publish(n, i, k, &pubs)
        // Offload: the owner's new half allocated before this
        // acknowledgement is scanned at T1 (amendment 7a).
        if unsafe i == k && y.isOffloaded(k) {
            let a = unsafe n.alloc(k)
            let h = unsafe y.handshake(k)
            unsafe h.pointee.newHalfLo = a.pointee.edenStart
            unsafe h.pointee.newHalfHi = a.pointee.top
        }
    case .drain:
        unsafe publish(n, i, k, &pubs)
    }
}

/// Mutex held: the first round participant `i` owes, or nil.
@inline(__always)
private func owedLocked(_ y: YoungPointer, _ i: Int) -> (k: Int, round: UInt64, kind: RoundKind)? {
    for k in unsafe 0..<y.pointee.count {
        let h = unsafe y.handshake(k)
        if unsafe h.pointee.active && h.pointee.need > 0 && h.pointee.acked[i] != h.pointee.round {
            return unsafe (k, h.pointee.round, h.pointee.kind)
        }
    }
    return nil
}

/// Mutex held: does `w` owe a round?
func owesRoundLocked(_ vm: VMPointer, _ w: WorkerPointer) -> Bool {
    guard let y = unsafe vm.pointee.young, unsafe isRoundParticipant(vm, w) else { return false }
    return unsafe owedLocked(y, w.pointee.index) != nil
}

/// Mutex held: participant `i` has acknowledged nursery `k`'s round.
private func acknowledgedLocked(_ vm: VMPointer, _ y: YoungPointer, _ k: Int, _ i: Int, _ round: UInt64,
                                _ roots: inout RawArray<UInt64>, _ pubs: inout RawArray<PublishedBuffer>) {
    let h = unsafe y.handshake(k)
    for j in 0..<roots.count { unsafe h.pointee.roots.append(roots[j]) }
    for j in unsafe 0..<pubs.count { unsafe h.pointee.pubs.append(pubs[j]) }
    roots.removeAll()
    unsafe pubs.removeAll()
    unsafe h.pointee.acked[i] = round
    unsafe h.pointee.need -= 1
    if unsafe h.pointee.need == 0 {
        unsafe h.pointee.lastAcker = i
        unsafe vm.pointee.flag.pointee.wrappingSubtract(2, ordering: .releasing)
        unsafe pthread_cond_broadcast(vm.pointee.safepointCond)
    }
}

/// At a safepoint, mutex not held, registers flushed: do every round `w`
/// owes, one at a time, then advance its epoch word (it holds no body
/// pointer). Counted for its own nursery's collections and for others'.
@inline(never)
func serviceRounds(_ vm: VMPointer, _ w: WorkerPointer) {
    guard let y = unsafe vm.pointee.young, unsafe isRoundParticipant(vm, w) else { return }
    let i = unsafe w.pointee.index
    let work = unsafe y.work(i)
    let serial = unsafe y.pointee.roundSerial.pointee.load(ordering: .acquiring)
    if unsafe serial == work.pointee.seenSerial { return }
    let t0 = nanoseconds()
    var own = false, any = false
    var roots = RawArray<UInt64>()
    var pubs = unsafe RawArray<PublishedBuffer>()
    while true {
        unsafe pthread_mutex_lock(vm.pointee.safepointLock)
        guard let (k, round, kind) = unsafe owedLocked(y, i) else {
            unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
            break
        }
        unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
        any = true
        if k == i { own = true }
        unsafe perturb(vm, w)
        unsafe roundWork(vm, y, i, k, kind, scan: true, &roots, &pubs)
        unsafe pthread_mutex_lock(vm.pointee.safepointLock)
        unsafe acknowledgedLocked(vm, y, k, i, round, &roots, &pubs)
        unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
    }
    roots.free()
    unsafe pubs.free()
    unsafe work.pointee.seenSerial = serial
    let c = unsafe y.counters(i)
    guard any else {
        // Nothing owed (its rounds were done by proxy, or by itself at an
        // earlier poll): the mutex still cost this participant.
        unsafe c.pointee.serviceNs &+= nanoseconds() &- t0
        return
    }
    unsafe epochAdvance(vm, w)
    let dt = nanoseconds() &- t0
    if own {
        unsafe c.pointee.acksOwn &+= 1
        unsafe c.pointee.acksOwnNs &+= dt
    } else {
        unsafe c.pointee.acksOther &+= 1
        unsafe c.pointee.acksOtherNs &+= dt
    }
    if unsafe dt > c.pointee.ackMaxNs { unsafe c.pointee.ackMaxNs = dt }
}

/// Mutex held. Wait on the safepoint condition while `cond()` holds,
/// servicing the rounds `w` owes, running the collector thread's queue
/// (amendment 11: a stop waits for every opened collection, and only that
/// thread runs them; never inside a collection of its own), and parking in
/// a requested stop. A waiting participant holds no body pointer: its
/// epoch word is quiescent while it blocks (amendment 14), and the wake
/// stores 0, then the global epoch, as `enterVM` does (the model's finding
/// 3).
func waitServicing(_ vm: VMPointer, _ w: WorkerPointer, _ cond: () -> Bool) {
    let sp = unsafe vm.pointee.safepoint
    let i = unsafe w.pointee.index
    let y = unsafe vm.pointee.young
    let participant = unsafe isRoundParticipant(vm, w)
    while cond() {
        if participant, let y, unsafe owedLocked(y, i) != nil {
            unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
            unsafe serviceRounds(vm, w)
            unsafe pthread_mutex_lock(vm.pointee.safepointLock)
            continue
        }
        if let y, unsafe i == y.pointee.collectorIndex && !y.work(i).pointee.busy && y.pointee.queue.pointee.count > 0 {
            unsafe drainQueueLocked(vm, y, w)
            continue
        }
        if unsafe sp.pointee.requested && sp.pointee.inside[i] && sp.pointee.stopper != i {
            unsafe parkLocked(vm, w)
            continue
        }
        unsafe epochQuiesce(vm, w)
        unsafe pthread_cond_wait(vm.pointee.safepointCond, vm.pointee.safepointLock)
        unsafe epochWake(vm, w, zero: y?.pointee.config.testSwitches.quiescentWakeZero ?? true)
    }
}

/// Collector `c` opens a round of kind `kind` for nursery `k` and waits
/// until every participant has done it: those inside the VM (itself
/// included) acknowledge at their safepoints; those outside are
/// acknowledged by proxy (they hold no reference), those in a blocking
/// region by proxy with their flushed stack scanned. Records its latency
/// and the last acknowledger.
func runRound(_ vm: VMPointer, _ y: YoungPointer, _ c: WorkerPointer, _ k: Int, _ kind: RoundKind) {
    let sp = unsafe vm.pointee.safepoint
    let h = unsafe y.handshake(k)
    var roots = RawArray<UInt64>()
    var pubs = unsafe RawArray<PublishedBuffer>()
    unsafe pthread_mutex_lock(vm.pointee.safepointLock)
    let t0 = nanoseconds()
    unsafe h.pointee.round &+= 1
    let round = unsafe h.pointee.round
    unsafe h.pointee.kind = kind
    unsafe h.pointee.openedAt = t0
    unsafe h.pointee.lastAcker = -1
    var need = 0
    for i in unsafe 0..<y.pointee.participants {
        if unsafe i == vm.pointee.workerCount { continue }  // the marker's slot
        if unsafe sp.pointee.inside[i] && !sp.pointee.blocking[i] {
            need += 1
        } else {
            unsafe roundWork(vm, y, i, k, kind, scan: sp.pointee.blocking[i], &roots, &pubs)
            for j in 0..<roots.count { unsafe h.pointee.roots.append(roots[j]) }
            for j in unsafe 0..<pubs.count { unsafe h.pointee.pubs.append(pubs[j]) }
            roots.removeAll()
            unsafe pubs.removeAll()
            unsafe h.pointee.acked[i] = round
        }
    }
    unsafe h.pointee.need = need
    if need > 0 {
        unsafe y.pointee.roundSerial.pointee.wrappingAdd(1, ordering: .releasing)
        unsafe vm.pointee.flag.pointee.wrappingAdd(2, ordering: .releasing)
        unsafe pthread_cond_broadcast(vm.pointee.safepointCond)
        unsafe waitServicing(vm, c) { unsafe h.pointee.need > 0 }
    }
    let dt = nanoseconds() &- t0
    unsafe y.pointee.log.pointee.rounds.append(RoundRecord(nursery: k, kind: kind, latencyNs: dt, slowest: h.pointee.lastAcker))
    unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
    roots.free()
    unsafe pubs.free()
}

// MARK: - entering, leaving, blocking

/// `enterVM`, mutex held: `w` is inside from now on and owes no round
/// already open (it holds nothing from before it).
func youngEnterLocked(_ vm: VMPointer, _ w: WorkerPointer) {
    let i = unsafe w.pointee.index
    unsafe vm.pointee.safepoint.pointee.inside[i] = true
    guard let y = unsafe vm.pointee.young, unsafe isRoundParticipant(vm, w) else { return }
    for k in unsafe 0..<y.pointee.count {
        let h = unsafe y.handshake(k)
        if unsafe h.pointee.active { unsafe h.pointee.acked[i] = h.pointee.round }
    }
}

/// `leaveVM`, mutex held: `w` holds no Process and no reference; every
/// round it owes is done by proxy (its buffers published, the owner's new
/// half recorded), then it is outside (the model's one-step `leaveVM`).
func youngLeaveLocked(_ vm: VMPointer, _ w: WorkerPointer) {
    let i = unsafe w.pointee.index
    if let y = unsafe vm.pointee.young, unsafe isRoundParticipant(vm, w) {
        var roots = RawArray<UInt64>()
        var pubs = unsafe RawArray<PublishedBuffer>()
        while let (k, round, kind) = unsafe owedLocked(y, i) {
            unsafe roundWork(vm, y, i, k, kind, scan: false, &roots, &pubs)
            unsafe acknowledgedLocked(vm, y, k, i, round, &roots, &pubs)
        }
        roots.free()
        unsafe pubs.free()
    }
    unsafe vm.pointee.safepoint.pointee.inside[i] = false
}

/// A primitive that may block for long without touching the heap (the
/// shell call, the test primitive) brackets itself: owed rounds first;
/// inside, the worker is acknowledged by proxy and its flushed stack is
/// scanned by the opener; its epoch word is kept (it may hold a body
/// pointer).
func blockingBegin(_ vm: VMPointer, _ w: WorkerPointer) {
    guard let y = unsafe vm.pointee.young, unsafe isRoundParticipant(vm, w) else { return }
    unsafe pthread_mutex_lock(vm.pointee.safepointLock)
    while unsafe owedLocked(y, w.pointee.index) != nil {
        unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
        unsafe serviceRounds(vm, w)
        unsafe pthread_mutex_lock(vm.pointee.safepointLock)
    }
    unsafe vm.pointee.safepoint.pointee.blocking[w.pointee.index] = true
    unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
    unsafe y.counters(w.pointee.index).pointee.blockingRegions &+= 1
}

/// The end of a blocking region. Rounds opened meanwhile were acknowledged
/// by proxy (the model's finding 5: nothing to service here).
func blockingEnd(_ vm: VMPointer, _ w: WorkerPointer) {
    guard unsafe vm.pointee.young != nil, unsafe isRoundParticipant(vm, w) else { return }
    unsafe pthread_mutex_lock(vm.pointee.safepointLock)
    unsafe vm.pointee.safepoint.pointee.blocking[w.pointee.index] = false
    unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
}

/// `stopWorld`, mutex held, before it requests the stop: no stop
/// interleaves a collection. The requester counts in `stwWanted` (no
/// collection opens) and waits, servicing rounds, until none is open.
/// Answers false when another stop was requested meanwhile (the caller
/// parks for it first).
func waitForCollectionsLocked(_ vm: VMPointer, _ w: WorkerPointer) -> Bool {
    let sp = unsafe vm.pointee.safepoint
    guard let y = unsafe vm.pointee.young, unsafe sp.pointee.ycActive > 0 else { return true }
    let t0 = nanoseconds()
    unsafe sp.pointee.stwWanted += 1
    unsafe waitServicing(vm, w) { unsafe sp.pointee.ycActive > 0 && !sp.pointee.requested }
    unsafe sp.pointee.stwWanted -= 1
    if unsafe isRoundParticipant(vm, w) { unsafe y.counters(w.pointee.index).pointee.drainWaitNs &+= nanoseconds() &- t0 }
    return unsafe !sp.pointee.requested
}
