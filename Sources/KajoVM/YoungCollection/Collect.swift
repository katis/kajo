import Darwin
import Synchronization

// One collection of one nursery without stopping the world
// (docs/modules/young-collection.md "The collection"; experiments/
// concurrent-young SPEC "Part 1" steps 1 to 6; the model's steps `opens
// nursery k's collection` to `collection done`). A collection is a
// concurrent mark of Y_k whose action on a marked object is the copy:
// claim with a header compare-and-swap that writes the decision, then
// module 6's copy protocol through the entry's state word.

// MARK: - opening

/// Owner `w` of nursery `k`, inside the VM at its allocation slow path
/// (registers flushed): open collection `k`. Waits (servicing rounds,
/// parking) while a stop is wanted or requested. `offload`: the full eden
/// half and its stash go to the collection, the owner flips to the other
/// half (its pause is this flip).
func openYoungCollection(_ vm: VMPointer, _ y: YoungPointer, _ w: WorkerPointer, offload: Bool) {
    let sp = unsafe vm.pointee.safepoint
    let k = unsafe w.pointee.index
    let n = unsafe y.pointee.nursery
    let a = unsafe n.alloc(k)
    let v = unsafe n.survivors(k)
    let h = unsafe y.handshake(k)
    unsafe pthread_mutex_lock(vm.pointee.safepointLock)
    let tw = nanoseconds()
    unsafe waitServicing(vm, w) { unsafe sp.pointee.stwWanted > 0 || sp.pointee.requested }
    unsafe y.counters(k).pointee.stopWaitNs &+= nanoseconds() &- tw
    // This eden's allocations so far (module 4's counters).
    unsafe a.pointee.youngAllocations &+= UInt64(a.pointee.stash.next)
    unsafe a.pointee.youngBytes &+= a.pointee.top &- a.pointee.edenStart
    // Y: the eden part and survivor-from.
    let r = unsafe y.range(k)
    unsafe r[0].store(a.pointee.edenStart, ordering: .relaxed)
    unsafe r[1].store(a.pointee.top, ordering: .relaxed)
    unsafe r[2].store(v.pointee.survFromStart, ordering: .relaxed)
    unsafe r[3].store(v.pointee.survFromTop, ordering: .relaxed)
    var rec = YoungRecord()
    rec.nursery = k
    rec.offloaded = offload
    rec.openNs = nanoseconds()
    rec.youngBytes = unsafe (a.pointee.top &- a.pointee.edenStart) &+ (v.pointee.survFromTop &- v.pointee.survFromStart)
    unsafe y.pointee.inFlight[k] = rec
    if offload {
        // The collection takes this half's stash (its young log); the owner
        // takes the one the last collection of the other half swept.
        unsafe swap(&a.pointee.stash, &v.pointee.stash2)
        unsafe a.pointee.half = 1 &- a.pointee.half
        unsafe a.pointee.edenStart = a.pointee.edenBase &+ UInt64(a.pointee.half) &* a.pointee.halfBytes
        unsafe a.pointee.top = a.pointee.edenStart
        unsafe a.pointee.end = a.pointee.edenStart &+ a.pointee.halfBytes
    }
    unsafe y.pointee.seq[k].wrappingAdd(1, ordering: .relaxed)
    unsafe y.pointee.done[k].store(false, ordering: .relaxed)
    unsafe y.pointee.collecting[k].store(true, ordering: .releasing)
    unsafe barrierWord(vm.pointee.flag).pointee.wrappingAdd(2, ordering: .releasing)
    unsafe sp.pointee.ycActive += 1
    unsafe h.pointee.active = true
    unsafe h.pointee.need = 0
    unsafe h.pointee.offloaded = offload
    unsafe h.pointee.newHalfLo = 0
    unsafe h.pointee.newHalfHi = 0
    if unsafe offload && y.pointee.thread.pointee.started {
        unsafe h.pointee.queued = true
        unsafe y.pointee.queue.pointee.append(k)
        unsafe pthread_cond_signal(y.pointee.collectorCond)
        unsafe pthread_cond_broadcast(vm.pointee.safepointCond)
    }
    unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
}

// MARK: - the collection

/// Collector `c` (the owner, or the young collector thread inside the VM)
/// runs collection `k`, opened by `openYoungCollection`: H0, H1, T1, drain
/// rounds until one copies nothing, the finish, the carried set, the entry
/// sweep, the survivor flip, the epoch rule, the deferred frees. Answers
/// its record.
@discardableResult
func collectYoung(_ vm: VMPointer, _ y: YoungPointer, _ c: WorkerPointer, _ k: Int) -> YoungRecord {
    let sw = unsafe y.pointee.config.testSwitches
    let n = unsafe y.pointee.nursery
    let v = unsafe n.survivors(k)
    let h = unsafe y.handshake(k)
    let work = unsafe y.work(c.pointee.index)
    let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    var st = unsafe y.pointee.inFlight[k]
    st.startNs = nanoseconds()
    st.collector = unsafe c.pointee.index
    unsafe work.pointee.busy = true
    unsafe v.pointee.survCur = v.pointee.survToStart
    unsafe v.pointee.nextLog.removeAll()
    unsafe v.pointee.nextCarried.removeAll()
    unsafe work.pointee.grey.removeAll()
    var col = unsafe Collector(vm: vm, y: y, c: c, k: k, ctx: c.pointee.interp.context)

    // H0, H1.
    if let hk = unsafe sw.hook { unsafe hk(sw.hookContext, k, 0) }
    unsafe runRound(vm, y, c, k, .h0)
    let t1 = nanoseconds()
    st.h0Ns = t1 &- st.startNs
    unsafe y.pointee.afterH1[k].store(true, ordering: .releasing)
    unsafe runRound(vm, y, c, k, .h1)
    let t2 = nanoseconds()
    st.h1Ns = t2 &- t1
    if let hk = unsafe sw.hook { unsafe hk(sw.hookContext, k, 1) }

    // T1: parked Processes, global roots, the new half, carried holders,
    // everything handed.
    unsafe col.claimAndScanParked(&st)
    unsafe col.globalRoots()
    unsafe col.visitRoots()
    if unsafe h.pointee.offloaded && sw.newHalfScan { unsafe col.scanNewHalf(&st) }
    var carried = RawArray<UInt64>()
    unsafe swap(&carried, &v.pointee.carried)
    if sw.carryHolders {
        for i in 0..<carried.count {
            unsafe col.scanHolder(carried[i])
            if i & 255 == 255 { unsafe col.servicePoint() }
        }
    } else {
        // Test switch: the holders kept by the last collection are forgotten.
        for i in 0..<carried.count { unsafe n.remMarker(carried[i]).pointee.bitwiseAnd(~remBit(k), ordering: .relaxed) }
    }
    carried.free()
    unsafe col.processHanded()
    unsafe col.drainGrey()
    if let hk = unsafe sw.hook { unsafe hk(sw.hookContext, k, 3) }
    let t3 = nanoseconds()
    st.t1Ns = t3 &- t2
    st.rounds = 2
    // Drain rounds until the first that copied nothing (SPEC point 3; the
    // model's `chain` configuration: one drain round is not enough).
    while sw.secondHandshake {
        let before = unsafe col.st.copiedObjects
        let td = nanoseconds()
        unsafe runRound(vm, y, c, k, .drain)
        st.drainRoundsNs &+= nanoseconds() &- td
        st.rounds += 1
        unsafe col.processHanded()
        unsafe col.drainGrey()
        if unsafe col.st.copiedObjects == before { break }
    }
    let t4 = nanoseconds()
    st.traceNs = t4 &- t2

    // Finish: the barrier off for this nursery.
    unsafe pthread_mutex_lock(vm.pointee.safepointLock)
    unsafe y.pointee.collecting[k].store(false, ordering: .releasing)
    unsafe y.pointee.afterH1[k].store(false, ordering: .relaxed)
    unsafe y.pointee.afterT1[k].store(false, ordering: .relaxed)
    unsafe barrierWord(vm.pointee.flag).pointee.wrappingSubtract(2, ordering: .releasing)
    unsafe h.pointee.active = false
    for i in unsafe 0..<h.pointee.pubs.count { unsafe h.pointee.pubs[i].list.free() }
    unsafe h.pointee.pubs.removeAll()
    unsafe h.pointee.roots.removeAll()
    unsafe pthread_mutex_unlock(vm.pointee.safepointLock)

    // Carried set (amendment 9), entry sweep, survivor flip.
    unsafe col.foldCarried()
    let stash = unsafe h.pointee.offloaded ? v.pointer(to: \NurserySurvivors.stash2)! : n.alloc(k).pointer(to: \NurseryAlloc.stash)!
    unsafe col.sweep(stash, &st)
    unsafe swap(&v.pointee.survLog, &v.pointee.nextLog)
    unsafe v.pointee.nextLog.removeAll()
    unsafe v.pointee.survFromTop = v.pointee.survCur
    unsafe v.pointee.survTo = 1 &- v.pointee.survTo
    for i in unsafe 0..<v.pointee.nextCarried.count { unsafe v.pointee.carried.append(v.pointee.nextCarried[i]) }
    st.carried = unsafe UInt64(v.pointee.carried.count)
    unsafe v.pointee.nextCarried.removeAll()
    let t5 = nanoseconds()
    st.sweepNs = t5 &- t4

    // The epoch rule (step 6): the old eden and survivor-from are reused,
    // and deferred entries freed, only after every participant passed a
    // safepoint after the last switch.
    if let hk = unsafe sw.hook { unsafe hk(sw.hookContext, k, 2) }
    let s = unsafe vm.pointee.epoch.pointee.wrappingAdd(1, ordering: .sequentiallyConsistent).oldValue
    if sw.epochRule { unsafe waitEpoch(vm, y, c, s) }
    unsafe col.freeDeferred(stash, &st)
    let t6 = nanoseconds()
    st.epochWaitNs = t6 &- t5
    st.totalNs = t6 &- st.startNs
    st.cpuNs = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- cpu0
    st.copiedObjects = unsafe col.st.copiedObjects
    st.survivedObjects = unsafe col.st.survivedObjects
    st.survivedBytes = unsafe col.st.survivedBytes
    st.promotedObjects = unsafe col.st.promotedObjects
    st.promotedBytes = unsafe col.st.promotedBytes
    st.overflowObjects = unsafe col.st.overflowObjects
    st.overflowBytes = unsafe col.st.overflowBytes
    st.holders = unsafe col.st.holders
    st.deletionRecords = unsafe col.st.deletionRecords
    st.stackRoots = unsafe col.st.stackRoots
    st.crossRemembered = unsafe col.st.crossRemembered
    st.hazardRetries = unsafe col.st.hazardRetries
    st.newHalfWords = unsafe col.st.newHalfWords
    st.claimFailures = unsafe col.st.claimFailures
    unsafe y.pointee.promotedBytes.pointee.wrappingAdd(st.promotedBytes, ordering: .relaxed)
    unsafe y.pointee.promotedObjects.pointee.wrappingAdd(st.promotedObjects, ordering: .relaxed)
    unsafe work.pointee.busy = false

    unsafe pthread_mutex_lock(vm.pointee.safepointLock)
    unsafe vm.pointee.safepoint.pointee.ycActive -= 1
    unsafe y.pointee.done[k].store(true, ordering: .releasing)
    if unsafe h.pointee.offloaded { unsafe y.pointee.log.pointee.collectionsOffloaded &+= 1 }
    else { unsafe y.pointee.log.pointee.collectionsLocal &+= 1 }
    unsafe y.pointee.log.pointee.records.append(st)
    unsafe pthread_cond_broadcast(vm.pointee.safepointCond)
    unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
    return st
}

/// Wait until every participant's epoch word passed `s` (step 6). Waiting
/// workers are quiescent (amendment 14); a participant collector keeps its
/// own word current and services rounds meanwhile, or two collectors
/// waiting for each other's epochs would stall. A spin with yields: it
/// runs only inside a collection, never while idle.
func waitEpoch(_ vm: VMPointer, _ y: YoungPointer, _ c: WorkerPointer, _ s: UInt64) {
    unsafe epochAdvance(vm, c)
    var spins = 0
    while unsafe minParticipantEpoch(vm) <= s {
        if unsafe roundsOpen(vm) { unsafe serviceRounds(vm, c) }
        unsafe epochAdvance(vm, c)
        spins &+= 1
        if spins & 63 == 0 { usleep(20) } else { sched_yield() }
    }
}

// MARK: - the collector's work

/// What a collection counts as it goes (copied into its record).
struct CollectionTally {
    var copiedObjects: UInt64 = 0
    var survivedObjects: UInt64 = 0
    var survivedBytes: UInt64 = 0
    var promotedObjects: UInt64 = 0
    var promotedBytes: UInt64 = 0
    var overflowObjects: UInt64 = 0
    var overflowBytes: UInt64 = 0
    var holders: UInt64 = 0
    var deletionRecords: UInt64 = 0
    var stackRoots: UInt64 = 0
    var crossRemembered: UInt64 = 0
    var hazardRetries: UInt64 = 0
    var newHalfWords: UInt64 = 0
    var claimFailures: UInt64 = 0
}

/// The collector of nursery `k`: the constants it reads and its tally,
/// plain values and pointers (no ARC in the copy loop).
@unsafe struct Collector {
    let vm: VMPointer
    let y: YoungPointer
    let c: WorkerPointer
    let k: Int
    let ctx: AllocContext
    let om: ObjectMemory
    let n: NurseryPointer
    let v: UnsafeMutablePointer<NurserySurvivors>
    let work: UnsafeMutablePointer<CollectorWork>
    let ageLimit: UInt64
    let promoteAll: Bool
    let survToEnd: UInt64
    let participant: Bool
    let roundEvery: Int
    var st = CollectionTally()

    init(vm: VMPointer, y: YoungPointer, c: WorkerPointer, k: Int, ctx: AllocContext) {
        unsafe self.vm = vm
        unsafe self.y = y
        unsafe self.c = c
        unsafe self.k = k
        unsafe self.ctx = ctx
        unsafe om = y.pointee.om
        unsafe n = y.pointee.nursery
        unsafe v = n.survivors(k)
        unsafe work = y.work(c.pointee.index)
        unsafe ageLimit = UInt64(n.pointee.config.age)
        unsafe promoteAll = n.pointee.config.stress.contains(.promoteAll)
        unsafe survToEnd = v.pointee.survToStart &+ n.pointee.survivorBytes
        unsafe participant = isRoundParticipant(vm, c)
        unsafe roundEvery = y.pointee.config.stress.contains(.roundAtEveryPoll) ? 16 : 0
    }

    /// Between objects the collector holds no body pointer: advance its
    /// epoch word and service other collections' rounds (every 256 copied
    /// objects and between published buffers), so their eden-reuse waits
    /// and rounds do not wait for this loop. With `roundAtEveryPoll` it also
    /// opens a drain round of its own every 16 objects.
    @inline(__always)
    mutating func servicePoint() {
        unsafe perturb(vm, c)
        unsafe epochAdvance(vm, c)
        if unsafe participant && roundsOpen(vm) { unsafe serviceRounds(vm, c) }
    }

    /// Classify `v` for this collection, copying it if it is in Y_k and not
    /// yet copied: 0 not young after the collection, 1 young in nursery k,
    /// 2 + j young in another nursery j.
    @inline(__always)
    mutating func classify(_ v: UInt64) -> Int {
        if v & Oop.objectTagMask != 0 || v == 0 { return 0 }
        let h = unsafe om.headerWord(v)
        if h & Header.youngBit == 0 || h & Header.deferredBit != 0 { return 0 }
        let j = Int(truncatingIfNeeded: (h & Header.nurseryMask) &>> Header.nurseryShift)
        if unsafe j != k { return 2 &+ j }
        let off = unsafe om.stateWord(v) & ~EntryState.relocatingBit
        let r = unsafe y.range(k)
        let inY = unsafe (off >= r[0].load(ordering: .relaxed) && off < r[1].load(ordering: .relaxed))
            || (off >= r[2].load(ordering: .relaxed) && off < r[3].load(ordering: .relaxed))
        if !inY { return 1 }
        return unsafe evacuate(v, h) ? 1 : 0
    }

    /// Claim, decide, copy (SPEC step 3): the header compare-and-swap
    /// writes the decision (survive with age + 1 into this nursery's
    /// survivor-to, or promote), then module 6's protocol on the state
    /// word: CAS to RELOCATING (seq_cst), a seq_cst fence, the hazard count
    /// and slots, the word copy, the switch (release). The header is decided
    /// before the CAS so a mutator whose post-store check fails reads the
    /// decided header in its slow path. Answers whether it survived young.
    @inline(never)
    mutating func evacuate(_ o: UInt64, _ h0: UInt64) -> Bool {
        let size = Header(raw: h0).bodyBytes
        let age = ((h0 & Header.ageMask) &>> Header.ageShift) &+ 1
        let wantSurvive = unsafe !promoteAll && age < ageLimit
        let survive = unsafe wantSurvive && v.pointee.survCur &+ size <= survToEnd
        let dst: UInt64
        let nh: UInt64
        if survive {
            dst = unsafe v.pointee.survCur
            unsafe v.pointee.survCur = dst &+ size
            nh = (h0 & ~(Header.ageMask | Header.claimMask)) | age &<< Header.ageShift
        } else {
            guard let d = unsafe om.bumpPromotion(ctx, bytes: size) else {
                preconditionFailure("kajo: promotion found no block: the promotion reserve is exhausted (counted in reserveExhaustions)")
            }
            dst = d
            nh = h0 & ~(Header.youngOnlyMask | Header.youngBit)
        }
        let hp = unsafe om.headerAtomic(o)
        if unsafe !hp.pointee.compareExchange(expected: h0, desired: nh, ordering: .relaxed).exchanged {
            // Only this collector writes Y_k's headers: a failure is a bug.
            unsafe st.claimFailures &+= 1
            unsafe hp.pointee.store(nh, ordering: .relaxed)
        }
        let sw = unsafe om.stateWordAtomic(o)
        var off = unsafe sw.pointee.load(ordering: .relaxed)
        unsafe work.pointee.inCopy = true
        while true {
            let (ok, cur) = unsafe sw.pointee.compareExchange(expected: off, desired: off | EntryState.relocatingBit,
                                                              ordering: .sequentiallyConsistent)
            if !ok {
                off = cur & ~EntryState.relocatingBit
                continue
            }
            atomicMemoryFence(ordering: .sequentiallyConsistent)
            if unsafe isHazarded(vm, o) {
                // A primitive holds the body: revert, wait until it lets go,
                // retry (its stores are bounded and never wait for us).
                unsafe sw.pointee.store(off, ordering: .releasing)
                unsafe work.pointee.inCopy = false
                unsafe st.hazardRetries &+= 1
                var spins = 0
                while unsafe isHazarded(vm, o) {
                    spins &+= 1
                    if spins & 63 == 0 { sched_yield() }
                }
                unsafe work.pointee.inCopy = true
                continue
            }
            break
        }
        unsafe copyBody(om, from: off, to: dst, bytes: size)
        unsafe sw.pointee.store(dst, ordering: .releasing)
        unsafe work.pointee.inCopy = false
        unsafe st.copiedObjects &+= 1
        if survive {
            unsafe st.survivedObjects &+= 1
            unsafe st.survivedBytes &+= size
            unsafe v.pointee.nextLog.append(UInt32(truncatingIfNeeded: o &>> 4))
        } else {
            unsafe st.promotedObjects &+= 1
            unsafe st.promotedBytes &+= size
            if wantSurvive {
                unsafe st.overflowObjects &+= 1
                unsafe st.overflowBytes &+= size
            }
        }
        if h0 & Header.bytesBit == 0 { unsafe work.pointee.grey.append(o) }
        if unsafe roundEvery > 0 && st.copiedObjects % UInt64(roundEvery) == 0 && participant {
            unsafe work.pointee.sinceService = 255
        }
        return survive
    }

    /// A remembered holder of nursery k (step 3, Changes 5, amendments 9
    /// and 10): clear bit k first (seq_cst), scan, keep it for the next
    /// collection (pending bit) if it still names a young object of k.
    mutating func scanHolder(_ hld: UInt64) {
        let bit = unsafe remBit(k)
        let r = unsafe n.remMarker(hld)
        if unsafe r.pointee.bitwiseAnd(~bit, ordering: .sequentiallyConsistent).oldValue & bit == 0 { return }
        unsafe st.holders &+= 1
        let h = unsafe om.headerWord(hld)
        if h & (Header.bytesBit | Header.deferredBit) != 0 { return }
        // Young in k: in Y (traced if reachable) or already a survivor.
        if unsafe h & Header.youngNurseryMask == Header.youngBit | UInt64(k) &<< Header.nurseryShift { return }
        let s = unsafe om.stateWord(hld)
        let count = Int(truncatingIfNeeded: (h & Header.countMask) &>> Header.countShift)
        var namesK = false
        var i = 0
        while i < count {
            if unsafe classify(om.loadAtomic(bodyOffset: s, i)) == 1 { namesK = true }
            i &+= 1
        }
        if namesK { unsafe keepForNext(hld) }
    }

    /// `o` stays in nursery k's set: during the pass only its pending bit
    /// is set (amendment 9), folded into the membership bit at the end.
    @inline(__always)
    mutating func keepForNext(_ o: UInt64) {
        let pend = unsafe pendingBit(k)
        if unsafe n.remMarker(o).pointee.bitwiseOr(pend, ordering: .sequentiallyConsistent).oldValue & pend == 0 {
            unsafe v.pointee.nextCarried.append(o)
        }
    }

    /// A copied object names a young object of nursery j: remembered for j
    /// as the barrier would, in this collector's own buffer (published at
    /// j's rounds).
    mutating func rememberFor(_ o: UInt64, _ j: Int) {
        let bit = remBit(j)
        let r = unsafe n.remMarker(o)
        if unsafe r.pointee.load(ordering: .sequentiallyConsistent) & bit != 0 { return }
        if unsafe r.pointee.bitwiseOr(bit, ordering: .sequentiallyConsistent).oldValue & bit != 0 { return }
        unsafe st.crossRemembered &+= 1
        unsafe n.remBuffer(c.pointee.index, j).pointee.append(o)
    }

    /// Scan copied objects' new bodies until the grey stack is empty. A
    /// promoted object naming a survivor of k is kept for the next
    /// collection; any copy naming a young object of another nursery is
    /// remembered for it. Weak and ephemeron slots are strong here (v0).
    mutating func drainGrey() {
        while let o = unsafe work.pointee.grey.popLast() {
            let h = unsafe om.headerWord(o)
            let promoted = h & Header.youngBit == 0
            let s = unsafe om.stateWord(o)
            let count = Int(truncatingIfNeeded: (h & Header.countMask) &>> Header.countShift)
            var namesK = false
            var i = 0
            while i < count {
                let r = unsafe classify(om.loadAtomic(bodyOffset: s, i))
                if r == 1 { namesK = true } else if r >= 2 { unsafe rememberFor(o, r &- 2) }
                i &+= 1
            }
            if namesK && promoted { unsafe keepForNext(o) }
            unsafe work.pointee.sinceService &+= 1
            if unsafe work.pointee.sinceService >= 256 {
                unsafe work.pointee.sinceService = 0
                unsafe servicePoint()
                if unsafe roundEvery > 0 {
                    unsafe runRound(vm, y, c, k, .drain)
                    unsafe processHanded()
                }
            }
        }
    }

    mutating func visitRoots() {
        let roots = unsafe work.pointee.roots
        unsafe st.stackRoots &+= UInt64(roots.count)
        for i in 0..<roots.count {
            _ = unsafe classify(roots[i])
            if i & 255 == 255 { unsafe servicePoint() }
        }
        unsafe work.pointee.roots.removeAll()
    }

    /// Everything handed to the collection so far: stack roots, published
    /// remembered buffers (holders) and deletion buffers (records).
    mutating func processHanded() {
        unsafe pthread_mutex_lock(vm.pointee.safepointLock)
        let h = unsafe y.handshake(k)
        for i in unsafe 0..<h.pointee.roots.count { unsafe work.pointee.roots.append(h.pointee.roots[i]) }
        unsafe h.pointee.roots.removeAll()
        unsafe swap(&work.pointee.pubs, &h.pointee.pubs)
        unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
        unsafe visitRoots()
        for i in unsafe 0..<work.pointee.pubs.count {
            unsafe servicePoint()
            let b = unsafe work.pointee.pubs[i]
            if unsafe b.remembered {
                for j in unsafe 0..<b.list.count {
                    unsafe scanHolder(b.list[j])
                    if j & 255 == 255 { unsafe servicePoint() }
                }
            } else {
                unsafe st.deletionRecords &+= UInt64(b.list.count)
                for j in unsafe 0..<b.list.count {
                    _ = unsafe classify(b.list[j])
                    if j & 255 == 255 { unsafe servicePoint() }
                }
            }
            var l = unsafe b.list
            l.free()
        }
        unsafe work.pointee.pubs.removeAll()
    }

    /// Under the scheduler lock: from now on new Processes count as scanned
    /// (`afterT1`); claim every parked live record not yet scanned for this
    /// collection; the live Processes and the ready queues' words as roots.
    /// Then scan the claimed stacks (parked: stable; a resumer waits).
    mutating func claimAndScanParked(_ rec: inout YoungRecord) {
        let s = unsafe y.pointee.seq[k].load(ordering: .relaxed)
        let om = unsafe self.om
        unsafe work.pointee.claimed.removeAll()
        unsafe schedLock(vm)
        unsafe y.pointee.afterT1[k].store(true, ordering: .relaxed)
        for i in unsafe 0..<vm.pointee.sched.pointee.recordHighWater {
            let r = unsafe records(vm, i)
            let p = unsafe r.pointee.process
            if p == .none { continue }
            if unsafe inY(y, k, p.raw) { unsafe work.pointee.roots.append(p.raw) }
            if unsafe r.pointee.runningOn >= 0 { continue }
            let word = unsafe y.scanWord(k, i)
            let cur = unsafe word.pointee.load(ordering: .acquiring)
            if cur == s || cur == s | scanningBit { continue }
            if unsafe word.pointee.compareExchange(expected: cur, desired: s | scanningBit, ordering: .acquiringAndReleasing).exchanged {
                unsafe work.pointee.claimed.append(i)
            }
        }
        for q in 0..<(2 * Priority.count * Affinity.count) {
            let v = unsafe vm.pointee.queues[q]
            if unsafe inY(y, k, v) { unsafe work.pointee.roots.append(v) }
        }
        unsafe schedUnlock(vm)
        let rule = unsafe y.pointee.config.testSwitches.handshakeStackScan
        for j in unsafe 0..<work.pointee.claimed.count {
            let i = unsafe work.pointee.claimed[j]
            let r = unsafe records(vm, i)
            if rule, let base = unsafe r.pointee.base {
                let sp = Int(truncatingIfNeeded: om.load(unsafe r.pointee.process, ProcessLayout.sp).smallIntegerValue)
                unsafe scanWords(vm, y, k, base, sp &+ 1, &work.pointee.roots)
            }
            unsafe y.scanWord(k, i).pointee.store(s, ordering: .releasing)
        }
        rec.processScans &+= unsafe UInt64(work.pointee.claimed.count)
    }

    /// Global roots other than the host's registry (scanned in the host
    /// worker's H1 work): the pending roots (Delays' Semaphores) and the
    /// finalization queue. The class table and the image's objects are old.
    mutating func globalRoots() {
        unsafe pthread_mutex_lock(vm.pointee.pendingLock)
        unsafe scanWords(vm, y, k, vm.pointee.pendingSlots, vm.pointee.pending.pointee.highWater, &work.pointee.roots)
        unsafe pthread_mutex_unlock(vm.pointee.pendingLock)
        let om = unsafe self.om
        let yy = unsafe y, kk = unsafe k
        var extra = RawArray<UInt64>()
        om.forEachFinalizedLocked { v in if unsafe inY(yy, kk, v.raw) { extra.append(v.raw) } }
        for i in 0..<extra.count { unsafe work.pointee.roots.append(extra[i]) }
        extra.free()
    }

    /// Offload: every body the owner allocated in its new eden half before
    /// its H1 acknowledgement, its slots as roots (amendment 7a; the model's
    /// finding 2: the snoop of 7b is not needed).
    mutating func scanNewHalf(_ rec: inout YoungRecord) {
        unsafe pthread_mutex_lock(vm.pointee.safepointLock)
        let h = unsafe y.handshake(k)
        var a = unsafe h.pointee.newHalfLo
        let hi = unsafe h.pointee.newHalfHi
        unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
        while a < hi {
            let br = unsafe om.wordAtomic(atOffset: a)
            let words = BackRef.words(br)
            if words == 0 { break }
            let o = BackRef.entryIndex(br) &<< 4
            if unsafe om.stateWord(o) == a {
                let hd = unsafe om.headerWord(o)
                if hd & Header.bytesBit == 0 {
                    let count = Int(truncatingIfNeeded: (hd & Header.countMask) &>> Header.countShift)
                    var j = 0
                    while j < count {
                        _ = unsafe classify(om.loadAtomic(bodyOffset: a, j))
                        j &+= 1
                    }
                    rec.newHalfWords &+= UInt64(count)
                }
            }
            a &+= words &<< 3
        }
    }

    /// Fold pending bits into membership (amendment 9).
    mutating func foldCarried() {
        let bit = unsafe remBit(k), pend = unsafe pendingBit(k)
        for i in unsafe 0..<v.pointee.nextCarried.count {
            let r = unsafe n.remMarker(v.pointee.nextCarried[i])
            unsafe r.pointee.bitwiseOr(bit, ordering: .sequentiallyConsistent)
            unsafe r.pointee.bitwiseAnd(~pend, ordering: .relaxed)
        }
    }

    /// The entry sweep of the collection's young log: the entries the
    /// collected eden handed out (`stash[0, next)`) and survivor-from's.
    /// Promoted entries join the old map; survivors (bodies in
    /// survivor-to) stay; a dead entry with a nonzero remembered word
    /// (stale lists may name it, another collection may re-arm it) gets a
    /// slot count of 0 and the deferred bit, and its free waits (amendment
    /// 10); the other dead ones go back to the stash.
    mutating func sweep(_ stash: UnsafeMutablePointer<EntryStash>, _ rec: inout YoungRecord) {
        let lo = unsafe v.pointee.survToStart, hi = unsafe v.pointee.survCur
        var freed: UInt64 = 0, deferred: UInt64 = 0
        var oldWord = -1
        var oldBits: UInt64 = 0
        func noteOld(_ e: UInt64) {
            let w = Int(truncatingIfNeeded: e &>> 6)
            if w != oldWord {
                if oldWord >= 0 { unsafe om.oldMap.insert(word: oldWord, bits: oldBits) }
                oldWord = w
                oldBits = 0
            }
            oldBits |= 1 &<< (e & 63)
        }
        /// Answers true when the entry is free now.
        func sweepOne(_ e: UInt32) -> Bool {
            let raw = UInt64(e) &<< 4
            let h = unsafe om.headerWord(raw)
            if h & Header.youngBit == 0 {
                noteOld(UInt64(e))
                return false
            }
            let s = unsafe om.stateWord(raw)
            if s >= lo && s < hi { return false }
            let r = unsafe n.remMarker(raw)
            if unsafe r.pointee.load(ordering: .relaxed) != 0 {
                unsafe om.headerAtomic(raw).pointee.store(h & ~Header.countMask | Header.deferredBit, ordering: .releasing)
                unsafe r.pointee.store(0, ordering: .sequentiallyConsistent)
                unsafe v.pointee.deferred.append(raw)
                deferred &+= 1
                return false
            }
            unsafe om.stateWordAtomic(raw).pointee.store(EntryState.free(next: 0), ordering: .relaxed)
            unsafe om.headerAtomic(raw).pointee.store(0, ordering: .relaxed)
            freed &+= 1
            return true
        }
        var st2 = unsafe stash.pointee
        if let base = unsafe st2.base {
            var j = 0
            let taken = unsafe st2.next
            var i = 0
            while i < taken {
                let e = unsafe base[i]
                if sweepOne(e) {
                    unsafe base[j] = e
                    j &+= 1
                }
                i &+= 1
                // No body pointer is held here: other collections' rounds
                // and epoch waits do not wait for the whole sweep.
                if i & 4095 == 0 { unsafe servicePoint() }
            }
            let unused = unsafe st2.count &- taken
            if unused > 0 && j < taken { unsafe (base + j).update(from: base + taken, count: unused) }
            unsafe st2.next = 0
            unsafe st2.count = j &+ unused
        }
        let log = unsafe v.pointee.survLog
        for i in 0..<log.count where sweepOne(log[i]) { unsafe st2.append(log[i]) }
        if oldWord >= 0 { unsafe om.oldMap.insert(word: oldWord, bits: oldBits) }
        unsafe stash.pointee = st2
        let keep = unsafe Int(truncatingIfNeeded: n.pointee.edenBytes / 16) &+ 4096
        if unsafe st2.count > keep { unsafe om.trimStash(stash, keep: keep) }
        rec.entriesFreed = freed
        rec.deferred = deferred
    }

    /// After the epoch (step 6, amendments 10 and 17): a deferred entry
    /// whose remembered word was re-armed meanwhile waits for this
    /// nursery's next collection; the others are freed into the stash.
    mutating func freeDeferred(_ stash: UnsafeMutablePointer<EntryStash>, _ rec: inout YoungRecord) {
        var kept = 0
        var freed: UInt64 = 0
        let d = unsafe v.pointer(to: \NurserySurvivors.deferred)!
        for i in unsafe 0..<d.pointee.count {
            let raw = unsafe d.pointee[i]
            if unsafe n.remMarker(raw).pointee.exchange(0, ordering: .sequentiallyConsistent) != 0 {
                unsafe d.pointee[kept] = raw
                kept &+= 1
                continue
            }
            unsafe om.stateWordAtomic(raw).pointee.store(EntryState.free(next: 0), ordering: .relaxed)
            unsafe om.headerAtomic(raw).pointee.store(0, ordering: .relaxed)
            unsafe stash.pointee.pushNext(UInt32(truncatingIfNeeded: raw &>> 4))
            freed &+= 1
        }
        rec.deferredKept = UInt64(kept)
        rec.deferredFrees = freed
        unsafe d.pointee.truncate(kept)
    }
}

/// The body copy: word by word with relaxed atomic loads and stores (a
/// mutator may read the old body through the alias meanwhile).
@inline(never)
func copyBody(_ om: ObjectMemory, from off: UInt64, to dst: UInt64, bytes: UInt64) {
    var k: UInt64 = 0
    while k < bytes {
        om.setWordAtomic(atOffset: dst &+ k, om.wordAtomic(atOffset: off &+ k))
        k &+= 8
    }
}
