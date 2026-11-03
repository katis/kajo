import Darwin
import Synchronization

// The stop-the-world scavenge (docs/modules/nursery.md "The scavenge";
// experiments/generational-gc SPEC "Scavenge" and concurrent-relocation
// SPEC "Part 1"). Every nursery is collected; the stopper and every worker
// parked at the stop take part. Roots are values (oops never change), so
// nothing but entries and the copied bodies is written: no root, no slot.
//
// Phases: prep (stopper), copy (parallel: root and remembered-holder
// tasks, then each participant drains its own stack, sharing packets),
// the copy barrier, the entry sweep (parallel, one task per nursery), the
// join, then weak slots, the flip and the verifiers (stopper).

/// The stopper's part: world stopped, safepoint mutex not held. `roots`
/// are the stop's roots (module 3); module 1's own roots are added here.
func scavenge(_ vm: VMPointer, _ w: WorkerPointer, roots: [Oop], promoteAll: Bool, timeToSafepointNs: UInt64 = 0) {
    guard let n = unsafe vm.pointee.nursery else { return }
    let t0 = nanoseconds()
    let om = unsafe n.pointee.om
    let config = unsafe n.pointee.config
    let ph = unsafe n.pointee.phase
    let log = unsafe n.pointee.state
    let count = unsafe n.pointee.count

    // --- prep
    let number = unsafe log.pointee.counters.scavenges &+ 1
    unsafe ph.pointee.number = number
    unsafe ph.pointee.tag = claimTag(scavenge: number, sameTag: config.testSwitches.sameClaimTag)
    unsafe ph.pointee.ageLimit = UInt64(config.age)
    unsafe ph.pointee.promoteAll = promoteAll || config.stress.contains(.promoteAll)
    unsafe ph.pointee.dropCarried = config.testSwitches.dropCarriedHolders
    unsafe ph.pointee.forgetPromoted = config.testSwitches.forgetPromotedHolders
    unsafe ph.pointee.formats = om.gc.pointee.classFormats.baseAddress
    unsafe ph.pointee.classCount = om.classCount
    unsafe ph.pointee.roots.removeAll()
    for v in roots where v.isObject { unsafe ph.pointee.roots.append(v.raw) }
    om.forEachRoot(extraRoots: []) { v in if v.isObject { unsafe ph.pointee.roots.append(v.raw) } }
    unsafe ph.pointee.tasks.removeAll()
    let rootCount = unsafe ph.pointee.roots.count
    if let rbase = unsafe ph.pointee.roots.baseAddress {
        var off = 0
        while off < rootCount {
            unsafe ph.pointee.tasks.append(ScavengeTask(words: rbase + off, count: Swift.min(NurseryShared.rootTaskWords, rootCount - off),
                                                        remembered: false))
            unsafe off += NurseryShared.rootTaskWords
        }
    }
    var youngBytes: UInt64 = 0
    var listed = 0
    for k in 0..<count {
        let a = unsafe n.alloc(k)
        let v = unsafe n.survivors(k)
        let used = unsafe a.pointee.top &- a.pointee.edenStart
        youngBytes &+= used &+ (unsafe v.pointee.survFromTop &- v.pointee.survFromStart)
        unsafe a.pointee.youngAllocations &+= UInt64(a.pointee.stash.next)
        unsafe a.pointee.youngBytes &+= used
        listed &+= unsafe v.pointee.carried.count
    }
    for i in unsafe 0..<n.pointee.bufferOwners {
        // Participants: a stopper outside the worker table (module 5's
        // marker, module 7's young collector thread) has no nursery and no
        // survivor-to: it promotes everything it copies (amendment 15).
        let s = unsafe n.scav(i)
        let v: UnsafeMutablePointer<NurserySurvivors>? = i < count ? unsafe n.survivors(i) : nil
        unsafe s.pointee.survCur = v?.pointee.survToStart ?? 0
        unsafe s.pointee.survEnd = v.map { unsafe $0.pointee.survToStart &+ n.pointee.survivorBytes } ?? 0
        unsafe s.pointee.stack.removeAll()
        unsafe s.pointee.nextRem.removeAll()
        unsafe s.pointee.survLog.removeAll()
        unsafe s.pointee.weak.removeAll()
        unsafe s.pointee.stats = ParticipantStats()
        for k in 0..<count { listed &+= unsafe n.remBuffer(i, k).pointee.count }
    }
    // Nothing young and nothing remembered (a promote-all right after a
    // scavenge, or a stress flag's stop): no scavenge at all.
    if youngBytes == 0 && listed == 0 {
        unsafe releaseDeferred(n)
        return
    }
    var expect: ScavengeExpectation? = nil
    if om.config.verify { expect = unsafe verifyBeforeScavenge(n, roots: ph.pointee.roots) }
    // Remembered holders: every owner's buffer for every nursery and every
    // carried list, each holder once (its word is cleared as it is taken).
    // Young holders are dropped (module 7, concurrent-young amendment 12):
    // another participant may promote one while it is scanned; they are
    // traced if reachable and the copy remembers them again.
    unsafe ph.pointee.holders.removeAll()
    unsafe ph.pointee.rememberYoung = n.alloc(0).pointee.rememberYoungHolders
    var dropped: UInt64 = 0
    func takeHolders(_ list: UnsafeMutablePointer<RawArray<UInt64>>) {
        for i in unsafe 0..<list.pointee.count {
            let o = unsafe list.pointee[i]
            let r = unsafe n.remMarker(o)
            if unsafe r.pointee.load(ordering: .relaxed) == 0 { continue }
            unsafe r.pointee.store(0, ordering: .relaxed)
            if om.headerWord(o) & Header.youngBit != 0 {
                dropped &+= 1
                continue
            }
            unsafe ph.pointee.holders.append(o)
        }
        unsafe list.pointee.removeAll()
    }
    for i in unsafe 0..<n.pointee.bufferOwners {
        for k in 0..<count {
            unsafe takeHolders(n.remBuffer(i, k))
            unsafe n.delBuffer(i, k).pointee.removeAll()
        }
    }
    for k in 0..<count { unsafe takeHolders(n.survivors(k).pointer(to: \NurserySurvivors.carried)!) }
    let remHolders = unsafe UInt64(ph.pointee.holders.count)
    if let rb = unsafe ph.pointee.holders.baseAddress {
        let rc = unsafe ph.pointee.holders.count
        var off = 0
        while off < rc {
            unsafe ph.pointee.tasks.append(ScavengeTask(words: rb + off, count: Swift.min(NurseryShared.remTaskHolders, rc - off),
                                                        remembered: true))
            unsafe off += NurseryShared.remTaskHolders
        }
    }
    unsafe log.pointee.counters.youngHoldersDropped &+= dropped
    unsafe n.pointee.taskNext.pointee.store(0, ordering: .relaxed)
    unsafe n.pointee.sweepNext.pointee.store(0, ordering: .relaxed)
    unsafe n.pointee.inCopy.pointee.store(0, ordering: .relaxed)
    unsafe n.pointee.idle.pointee.store(0, ordering: .relaxed)
    unsafe n.pointee.copyEnd.pointee.store(0, ordering: .relaxed)
    unsafe n.pointee.poolCount.pointee.store(0, ordering: .relaxed)
    let tp = nanoseconds()

    // --- parallel phase
    // A small scavenge is the stopper's alone: waking every parked worker
    // costs more than the copying (docs/modules/nursery.md "Deviations").
    let parts: [Int]
    if unsafe youngBytes < NurseryShared.soloYoungBytes && remHolders < UInt64(NurseryShared.remTaskHolders) {
        unsafe participateInScavenge(vm, w)
        parts = unsafe [w.pointee.index]
    } else {
        parts = unsafe runParallelPhase(vm, w)
    }
    let tj = nanoseconds()

    // --- finish
    let niled = unsafe processWeakSlots(n, parts: parts)
    var rec = ScavengeRecord()
    rec.number = number
    rec.promoteAll = unsafe ph.pointee.promoteAll
    rec.participants = parts.count
    rec.timeToSafepointNs = timeToSafepointNs
    rec.youngBytes = youngBytes
    rec.remHolders = remHolders
    for p in parts {
        let st = unsafe n.scav(p).pointee.stats
        rec.promotedBytes &+= st.promotedBytes
        rec.survivedBytes &+= st.survivedBytes
        rec.overflowBytes &+= st.overflowBytes
        rec.remSlots &+= st.remSlots
        rec.entriesFreed &+= st.entriesFreed
        rec.packets &+= st.packetsExported
        rec.copiedBytesPerParticipant.append(st.copiedBytes)
        rec.busyNsPerParticipant.append(st.busyNs)
        if st.busyNs >= rec.critCopyBusyNs {
            rec.critCopyBusyNs = st.busyNs
            rec.critRootsNs = st.rootsNs
            rec.critRemNs = st.remNs
            rec.slowestParticipant = p
        }
        rec.maxSweepNs = Swift.max(rec.maxSweepNs, st.sweepNs)
        unsafe log.pointee.counters.promotedObjects &+= st.promotedObjects
        unsafe log.pointee.counters.promotedBytes &+= st.promotedBytes
        unsafe log.pointee.counters.survivedObjects &+= st.survivedObjects
        unsafe log.pointee.counters.survivedBytes &+= st.survivedBytes
        unsafe log.pointee.counters.overflowObjects &+= st.overflowObjects
        unsafe log.pointee.counters.overflowBytes &+= st.overflowBytes
        unsafe log.pointee.counters.rememberedSlots &+= st.remSlots
        unsafe log.pointee.counters.entriesSwept &+= st.entriesSwept
        unsafe log.pointee.counters.entriesFreed &+= st.entriesFreed
    }
    var copied: UInt64 = 0
    for p in parts { copied &+= unsafe n.scav(p).pointee.stats.promotedObjects &+ n.scav(p).pointee.stats.survivedObjects }
    for k in 0..<count {
        let a = unsafe n.alloc(k)
        let s = unsafe n.scav(k)
        let v = unsafe n.survivors(k)
        unsafe a.pointee.top = a.pointee.edenStart
        // The survivors' entries carry over to the next scavenge.
        unsafe swap(&v.pointee.survLog, &s.pointee.survLog)
        unsafe s.pointee.survLog.removeAll()
        // Flip: survivor-to becomes survivor-from.
        unsafe v.pointee.survFromTop = s.pointee.survCur
        unsafe v.pointee.survTo = 1 &- v.pointee.survTo
    }
    // The holders that still name young objects go to the carried list of
    // every nursery whose bit they have (each holder is in one participant's
    // list: the first `fetch_or` that turned its word from 0 listed it).
    for p in parts {
        let s = unsafe n.scav(p)
        for i in unsafe 0..<s.pointee.nextRem.count {
            let o = unsafe s.pointee.nextRem[i]
            var bits = unsafe n.remMarker(o).pointee.load(ordering: .relaxed) & 0xFFFF
            while bits != 0 {
                let k = bits.trailingZeroBitCount
                bits &= bits &- 1
                unsafe n.survivors(k).pointee.carried.append(o)
            }
        }
        unsafe s.pointee.nextRem.removeAll()
    }
    // Module 7: every deferred entry free is released (the world is stopped
    // and every remembered list was taken above: nothing names one).
    unsafe releaseDeferred(n)
    unsafe log.pointee.counters.scavenges = number
    if unsafe ph.pointee.promoteAll { unsafe log.pointee.counters.promoteAllScavenges &+= 1 }
    unsafe log.pointee.counters.youngBytesScavenged &+= youngBytes
    unsafe log.pointee.counters.rememberedHolders &+= remHolders
    unsafe log.pointee.counters.weakSlotsNiled &+= niled
    let tf = nanoseconds()
    if let e = expect {
        unsafe log.pointee.counters.verifierRuns &+= 1
        unsafe verifyAfterScavenge(n, roots: ph.pointee.roots, expected: e, copied: copied)
    }
    let tv = nanoseconds()
    // Old space past its soft limit: a full collection in its own pause, at
    // the next poll or instead of the next scavenge (never in this stop).
    if om.isOverSoftLimit, unsafe !n.pointee.fullRequested.pointee.exchange(true, ordering: .relaxed) {
        unsafe log.pointee.counters.fullCollectionsRequested &+= 1
    }
    let ce = unsafe n.pointee.copyEnd.pointee.load(ordering: .relaxed)
    rec.prepNs = tp &- t0
    rec.copyWallNs = ce > tp ? ce &- tp : tj &- tp
    rec.sweepWallNs = ce > tp ? tj &- ce : 0
    rec.finishNs = tf &- tj
    rec.verifyNs = tv &- tf
    rec.workNs = tv &- t0
    unsafe log.pointee.counters.scavengeNs &+= tv &- t0
    unsafe log.pointee.records.append(rec)
}

/// One participant (the stopper or a parked worker): copy, then sweep.
/// Safepoint mutex not held.
func participateInScavenge(_ vm: VMPointer, _ w: WorkerPointer) {
    guard let n = unsafe vm.pointee.nursery else { return }
    let me = unsafe w.pointee.index
    let sw = unsafe n.scav(me)
    let ph = unsafe n.pointee.phase.pointee
    var sc = unsafe Scavenger(n: n, om: n.pointee.om, ctx: w.pointee.interp.context, me: me, tag: ph.tag, ageLimit: ph.ageLimit,
                              promoteAll: ph.promoteAll, dropCarried: ph.dropCarried, forgetPromoted: ph.forgetPromoted,
                              formats: ph.formats.unsafelyUnwrapped, rem: n.pointee.rem, nilRaw: n.pointee.om.nilObject.raw,
                              rememberYoung: ph.rememberYoung, w: sw.pointee)
    unsafe n.pointee.inCopy.pointee.wrappingAdd(1, ordering: .acquiringAndReleasing)
    let ntasks = unsafe ph.tasks.count
    while true {
        let i = unsafe n.pointee.taskNext.pointee.wrappingAdd(1, ordering: .relaxed).oldValue
        if i >= ntasks { break }
        let t = unsafe ph.tasks[i]
        let a = nanoseconds()
        if unsafe t.remembered {
            unsafe sc.scanRemembered(t.words, t.count)
            unsafe sc.w.stats.remNs &+= nanoseconds() &- a
        } else {
            var k = 0
            while unsafe k < t.count {
                _ = unsafe sc.scanWord(t.words[k])
                k &+= 1
            }
            unsafe sc.w.stats.rootsNs &+= nanoseconds() &- a
        }
        let b = nanoseconds()
        unsafe sc.drain()
        unsafe sc.w.stats.copyNs &+= nanoseconds() &- b
    }
    // Tasks are exhausted: help with exported packets until no participant
    // is copying. Packets are pushed only by a counted (`inCopy`)
    // participant; a participant stops being counted only after finding the
    // pool empty; a taker is counted before it pops; nobody re-counts itself
    // once `inCopy` reached 0. So `inCopy == 0` means no packet is left and
    // no copy is in flight: the copy barrier.
    let b = nanoseconds()
    while unsafe sc.takePacket() { unsafe sc.drain() }
    unsafe sc.w.stats.copyNs &+= nanoseconds() &- b
    unsafe n.pointee.inCopy.pointee.wrappingSubtract(1, ordering: .sequentiallyConsistent)
    let wa = nanoseconds()
    var spins = 0
    unsafe n.pointee.idle.pointee.wrappingAdd(1, ordering: .sequentiallyConsistent)
    while true {
        var c = unsafe n.pointee.inCopy.pointee.load(ordering: .sequentiallyConsistent)
        if c == 0 { break }
        if unsafe n.pointee.poolCount.pointee.load(ordering: .sequentiallyConsistent) > 0 {
            var counted = false
            while c > 0 {
                let (ok, cur) = unsafe n.pointee.inCopy.pointee.compareExchange(expected: c, desired: c &+ 1,
                                                                                ordering: .sequentiallyConsistent)
                if ok { counted = true; break }
                c = cur
            }
            if counted {
                unsafe n.pointee.idle.pointee.wrappingSubtract(1, ordering: .sequentiallyConsistent)
                let t = nanoseconds()
                while unsafe sc.takePacket() { unsafe sc.drain() }
                unsafe sc.w.stats.copyNs &+= nanoseconds() &- t
                unsafe n.pointee.inCopy.pointee.wrappingSubtract(1, ordering: .sequentiallyConsistent)
                unsafe n.pointee.idle.pointee.wrappingAdd(1, ordering: .sequentiallyConsistent)
                continue
            }
        }
        spins &+= 1
        if spins & 63 == 0 { sched_yield() }
    }
    unsafe n.pointee.idle.pointee.wrappingSubtract(1, ordering: .sequentiallyConsistent)
    let ce = nanoseconds()
    _ = unsafe n.pointee.copyEnd.pointee.compareExchange(expected: 0, desired: ce, ordering: .relaxed)
    unsafe sc.w.stats.waitNs = ce &- wa
    // Entry sweep: one task per nursery.
    let count = unsafe n.pointee.count
    while true {
        let k = unsafe n.pointee.sweepNext.pointee.wrappingAdd(1, ordering: .relaxed).oldValue
        if k >= count { break }
        unsafe sc.sweepNursery(k)
    }
    unsafe sc.w.stats.sweepNs = nanoseconds() &- ce
    unsafe sw.pointee = sc.w
}

/// A participant's working state during the phase: the constants it reads
/// and its own `ScavengeWorker`, kept in registers and written back once.
/// Plain values and pointers only: no ARC in the copy loop.
@unsafe struct Scavenger {
    let n: NurseryPointer
    let om: ObjectMemory
    let ctx: AllocContext
    let me: Int
    let tag: UInt64
    let ageLimit: UInt64
    let promoteAll: Bool
    let dropCarried: Bool
    let forgetPromoted: Bool
    let formats: UnsafeMutablePointer<UInt64>
    let rem: UnsafeMutablePointer<Atomic<UInt32>>
    let nilRaw: UInt64
    let rememberYoung: Bool
    var w: ScavengeWorker

    @inline(__always)
    func headerAtomic(_ v: UInt64) -> UnsafeMutablePointer<Atomic<UInt64>> {
        unsafe (om.table + Int(truncatingIfNeeded: v &+ 8)).assumingMemoryBound(to: Atomic<UInt64>.self)
    }

    /// Scan one word: copy the young object it names if this participant
    /// claims it first. Answers the nursery bit of the object if it is
    /// young after this scavenge (its holder must then be remembered), else 0.
    @inline(__always)
    mutating func scanWord(_ v: UInt64) -> UInt32 {
        if v & Oop.objectTagMask != 0 || v == 0 { return 0 }
        let h = unsafe headerAtomic(v).pointee.load(ordering: .relaxed)
        if h & Header.youngBit == 0 { return 0 }
        if unsafe h & tag != 0 { return UInt32(truncatingIfNeeded: 1 &<< ((h & Header.nurseryMask) &>> Header.nurseryShift)) }
        return unsafe evacuate(v, h)
    }

    /// Claim and copy a young object (docs/modules/nursery.md "Claiming").
    @inline(never)
    mutating func evacuate(_ v: UInt64, _ h0: UInt64) -> UInt32 {
        let hp = unsafe headerAtomic(v)
        var h = h0
        let size = Header(raw: h0).bodyBytes
        var decision = ClaimDecision.promote
        while true {
            if h & Header.youngBit == 0 { return 0 }  // promoted by another participant
            if unsafe h & tag != 0 { return UInt32(truncatingIfNeeded: 1 &<< ((h & Header.nurseryMask) &>> Header.nurseryShift)) }
            let room = unsafe w.survCur &+ size <= w.survEnd
            let (nh, d) = unsafe claimedHeader(h, tag: tag, ageLimit: ageLimit, participant: me, promoteAll: promoteAll, hasRoom: room)
            let (won, cur) = unsafe hp.pointee.compareExchange(expected: h, desired: nh, ordering: .relaxed)
            if won {
                h = nh
                decision = d
                break
            }
            h = cur
        }
        let dst: UInt64
        if decision == .survive {
            dst = unsafe w.survCur
            unsafe w.survCur = dst &+ size
        } else {
            guard let d = unsafe om.bumpPromotion(ctx, bytes: size) else {
                preconditionFailure("kajo: promotion found no block: the promotion reserve is exhausted (counted in reserveExhaustions)")
            }
            dst = d
        }
        let src = unsafe om.bodyOffset(Oop(raw: v))
        if size <= 128 {
            // Most bodies are a few words: a word loop beats a memmove call.
            let s = unsafe (om.heapBase + Int(truncatingIfNeeded: src)).assumingMemoryBound(to: UInt64.self)
            let d = unsafe (om.heapBase + Int(truncatingIfNeeded: dst)).assumingMemoryBound(to: UInt64.self)
            let words = Int(truncatingIfNeeded: size &>> 3)
            var i = 0
            while i < words {
                unsafe d[i] = s[i]
                i &+= 1
            }
        } else {
            unsafe memcpy(om.heapBase + Int(truncatingIfNeeded: dst), om.heapBase + Int(truncatingIfNeeded: src),
                          Int(truncatingIfNeeded: size))
        }
        unsafe om.setStateWord(v, dst)
        if decision == .survive {
            unsafe w.stats.survivedBytes &+= size
            unsafe w.stats.survivedObjects &+= 1
            unsafe w.survLog.append(UInt32(truncatingIfNeeded: v &>> 4))
        } else {
            unsafe w.stats.promotedBytes &+= size
            unsafe w.stats.promotedObjects &+= 1
            if decision == .promoteOverflow {
                unsafe w.stats.overflowBytes &+= size
                unsafe w.stats.overflowObjects &+= 1
            }
        }
        if h & Header.bytesBit == 0 { unsafe w.stack.append(v) }
        return unsafe decision == .survive ? UInt32(truncatingIfNeeded: 1 &<< me) : 0
    }

    /// Scan the slots of copied objects until the stack is empty. A promoted
    /// object that names a young one joins the remembered set. Every 1024
    /// objects, if a participant is idle and the pool is empty, export the
    /// bottom half of the stack.
    mutating func drain() {
        var k = 0
        while let o = unsafe w.stack.popLast() {
            // Claimed by this participant. An atomic load: losers' failed
            // compare-and-swaps on this header are atomic accesses to
            // ThreadSanitizer, so a plain load would be reported.
            let h = unsafe headerAtomic(o).pointee.load(ordering: .relaxed)
            var bits = unsafe scanSlots(o, h)
            // A survivor (young in this participant's nursery) is remembered
            // for the other nurseries it names (module 7 only).
            if h & Header.youngBit != 0 { bits = unsafe rememberYoung ? bits & ~(1 &<< UInt32(truncatingIfNeeded: me)) : 0 }
            if unsafe bits != 0 && !(h & Header.youngBit == 0 && forgetPromoted) { unsafe note(o, bits) }
            k &+= 1
            if unsafe k & 1023 == 0 && w.stack.count >= 8
                && n.pointee.idle.pointee.load(ordering: .relaxed) > 0
                && n.pointee.poolCount.pointee.load(ordering: .relaxed) == 0 {
                unsafe exportPacket()
            }
        }
    }

    /// Scan the slots of `o` (header `h`): every slot of an ordinary or an
    /// ephemeron object (the scavenge treats ephemerons as strong, the v0
    /// rule), only the named slots of a weak one (then remembered for the
    /// weak pass). Answers the nursery bits of the young objects it names.
    @inline(__always)
    mutating func scanSlots(_ o: UInt64, _ h: UInt64) -> UInt32 {
        var count = Int(truncatingIfNeeded: (h & Header.countMask) &>> Header.countShift)
        let f = unsafe formats[Int(truncatingIfNeeded: h & Header.classMask)]
        if _slowPath(f & ClassFormat.weakBit != 0) {
            let named = Int(truncatingIfNeeded: f & ClassFormat.namedMask)
            if count > named {
                unsafe w.weak.append(o)
                count = named
            }
        }
        let base = unsafe (om.heapBase + Int(truncatingIfNeeded: om.bodyOffset(Oop(raw: o))) + 8)
            .assumingMemoryBound(to: UInt64.self)
        var bits: UInt32 = 0
        var i = 0
        while i < count {
            bits |= unsafe scanWord(base[i])
            i &+= 1
        }
        return bits
    }

    /// Remembered holders (old): scan, then keep the ones that still name a
    /// young object (carried to the next scavenge), drop the rest.
    mutating func scanRemembered(_ holders: UnsafeMutablePointer<UInt64>, _ count: Int) {
        var k = 0
        while k < count {
            let o = unsafe holders[k]
            let h = unsafe om.headerWord(o)  // old: never written during a scavenge
            var bits: UInt32 = 0
            if h & Header.bytesBit == 0 {
                bits = unsafe scanSlots(o, h)
                unsafe w.stats.remSlots &+= (h & Header.countMask) &>> Header.countShift
            }
            if unsafe bits != 0 && !dropCarried { unsafe note(o, bits) }
            k &+= 1
        }
        unsafe w.stats.remHolders &+= UInt64(count)
    }

    /// `o` names young objects of the nurseries in `bits` after this
    /// scavenge: set its remembered bits; the call that turned its word
    /// from 0 lists it (the words of every holder were cleared in prep).
    @inline(__always)
    mutating func note(_ o: UInt64, _ bits: UInt32) {
        if unsafe rem[Int(truncatingIfNeeded: o &>> 4)].bitwiseOr(bits, ordering: .relaxed).oldValue == 0 {
            unsafe w.nextRem.append(o)
        }
    }

    // MARK: work sharing

    mutating func exportPacket() {
        let pool = unsafe n.pointee.packets
        let words = unsafe Swift.min(w.stack.count / 2, PacketPool.words)
        if words == 0 { return }
        unsafe pthread_mutex_lock(n.pointee.packetLock)
        guard let slot = unsafe pool.pointee.free.popLast() else {
            unsafe pthread_mutex_unlock(n.pointee.packetLock)
            return
        }
        let st = unsafe w.stack.baseAddress.unsafelyUnwrapped
        let dst = unsafe pool.pointee.storage + Int(slot) * PacketPool.words
        unsafe dst.update(from: st, count: words)
        unsafe st.update(from: st + words, count: w.stack.count - words)
        unsafe w.stack.truncate(w.stack.count - words)
        unsafe pool.pointee.length[Int(slot)] = words
        unsafe pool.pointee.full.append(slot)
        unsafe n.pointee.poolCount.pointee.wrappingAdd(1, ordering: .sequentiallyConsistent)
        unsafe pthread_mutex_unlock(n.pointee.packetLock)
        unsafe w.stats.packetsExported &+= 1
    }

    /// Move one exported packet onto this participant's stack. The caller is
    /// counted in `inCopy`.
    mutating func takePacket() -> Bool {
        if unsafe n.pointee.poolCount.pointee.load(ordering: .sequentiallyConsistent) == 0 { return false }
        let pool = unsafe n.pointee.packets
        unsafe pthread_mutex_lock(n.pointee.packetLock)
        guard let slot = unsafe pool.pointee.full.popLast() else {
            unsafe pthread_mutex_unlock(n.pointee.packetLock)
            return false
        }
        let len = unsafe pool.pointee.length[Int(slot)]
        let src = unsafe pool.pointee.storage + Int(slot) * PacketPool.words
        for i in 0..<len { unsafe w.stack.append(src[i]) }
        unsafe pool.pointee.free.append(slot)
        unsafe n.pointee.poolCount.pointee.wrappingSubtract(1, ordering: .sequentiallyConsistent)
        unsafe pthread_mutex_unlock(n.pointee.packetLock)
        return true
    }

    // MARK: entry sweep

    /// Accumulate promoted entry `e` into the old map's word being built;
    /// flush the previous word when `e` is in another.
    @inline(__always)
    func noteOld(_ e: UInt64, _ word: inout Int, _ bits: inout UInt64) {
        let w = Int(truncatingIfNeeded: e &>> 6)
        if w != word {
            if word >= 0 { unsafe om.oldMap.insert(word: word, bits: bits) }
            word = w
            bits = 0
        }
        bits |= 1 &<< (e & 63)
    }

    /// Free the entries of nursery `k`'s young objects that died: the ones
    /// handed out of its stash since the last scavenge and the survivors of
    /// the last one. A dead entry is young without this scavenge's tag; it
    /// goes back to the stash, which keeps its unused entries after them.
    /// Touches only what was allocated since the last scavenge, never the
    /// whole table.
    mutating func sweepNursery(_ k: Int) {
        let a = unsafe n.alloc(k)
        var st = unsafe a.pointee.stash
        var swept: UInt64 = 0, freed: UInt64 = 0
        // Module 5: promoted entries join the old map, one `fetch_or` per
        // word of them (entries come in runs), outside the copy loop.
        var oldWord = -1
        var oldBits: UInt64 = 0
        if let base = unsafe st.base {
            var j = 0
            let taken = unsafe st.next
            var i = 0
            while i < taken {
                let e = unsafe base[i]
                let raw = UInt64(e) &<< 4
                let h = unsafe om.headerWord(raw)
                if h & Header.youngBit == 0 {
                    unsafe noteOld(UInt64(e), &oldWord, &oldBits)
                } else if unsafe h & tag == 0 {
                    unsafe om.setStateWord(raw, EntryState.free(next: 0))
                    unsafe om.setHeaderWord(raw, 0)
                    unsafe base[j] = e
                    j &+= 1
                    freed &+= 1
                }
                i &+= 1
            }
            swept &+= UInt64(taken)
            let unused = unsafe st.count &- taken
            if unused > 0 && j < taken { unsafe (base + j).update(from: base + taken, count: unused) }
            unsafe st.next = 0
            unsafe st.count = j &+ unused
        }
        let sv = unsafe n.survivors(k)
        let log = unsafe sv.pointee.survLog
        for i in 0..<log.count {
            let e = log[i]
            let raw = UInt64(e) &<< 4
            let h = unsafe om.headerWord(raw)
            if h & Header.youngBit == 0 {
                unsafe noteOld(UInt64(e), &oldWord, &oldBits)
            } else if unsafe h & tag == 0 {
                unsafe om.setStateWord(raw, EntryState.free(next: 0))
                unsafe om.setHeaderWord(raw, 0)
                unsafe st.append(e)
                freed &+= 1
            }
        }
        if oldWord >= 0 { unsafe om.oldMap.insert(word: oldWord, bits: oldBits) }
        swept &+= UInt64(log.count)
        unsafe sv.pointee.survLog.removeAll()
        unsafe a.pointee.stash = st
        // A stash that grew past what an eden can use gives the rest back.
        let keep = Int(truncatingIfNeeded: unsafe n.pointee.edenBytes / 16) &+ 4096
        if unsafe st.count > keep { unsafe om.trimStash(a.pointer(to: \NurseryAlloc.stash)!, keep: keep) }
        unsafe w.stats.entriesSwept &+= swept
        unsafe w.stats.entriesFreed &+= freed
    }
}

/// Stopper, after the phase: every weak slot that named a young object
/// that died this scavenge (its entry is now free) becomes nil; a weak
/// holder that is old and still names a young object is remembered.
/// Answers the slots nil'ed.
private func processWeakSlots(_ n: NurseryPointer, parts: [Int]) -> UInt64 {
    let om = unsafe n.pointee.om
    let nilObj = om.nilObject
    let keep = unsafe n.pointee.config.testSwitches.keepDeadWeakSlots
    var niled: UInt64 = 0
    for p in parts {
        let s = unsafe n.scav(p)
        let weak = unsafe s.pointee.weak
        for i in 0..<weak.count {
            let o = Oop(raw: weak[i])
            let h = om.header(o)
            var bits: UInt32 = 0
            var j = om.classFormat(h.classIndex).namedSlots
            let count = Int(h.count)
            while j < count {
                let v = om.load(o, j)
                if v.isObject {
                    if EntryState.isFree(om.stateWord(v.raw)) {
                        if !keep {
                            om.store(o, j, nilObj)  // nil: never young
                            niled &+= 1
                        }
                    } else {
                        let hv = om.header(v)
                        if hv.isYoung { bits |= UInt32(truncatingIfNeeded: 1 &<< hv.nurseryIndex) }
                    }
                }
                j &+= 1
            }
            if h.isYoung { bits = unsafe n.pointee.phase.pointee.rememberYoung ? bits & ~remBit(h.nurseryIndex) : 0 }
            if bits != 0 {
                let r = unsafe n.remMarker(o.raw)
                if unsafe r.pointee.bitwiseOr(bits, ordering: .relaxed).oldValue == 0 { unsafe s.pointee.nextRem.append(o.raw) }
            }
        }
    }
    return niled
}

/// Module 7: release every deferred entry free of every nursery (world
/// stopped, every remembered list taken by the scavenge's prep, so nothing
/// names one: the nursery's own free, done at this pause instead of its
/// next collection). The entries go back to their nursery's stash.
func releaseDeferred(_ n: NurseryPointer) {
    let om = unsafe n.pointee.om
    var released: UInt64 = 0
    for k in unsafe 0..<n.pointee.count {
        let v = unsafe n.survivors(k)
        let a = unsafe n.alloc(k)
        for i in unsafe 0..<v.pointee.deferred.count {
            let raw = unsafe v.pointee.deferred[i]
            unsafe n.remMarker(raw).pointee.store(0, ordering: .relaxed)
            om.setStateWord(raw, EntryState.free(next: 0))
            om.setHeaderWord(raw, 0)
            unsafe a.pointee.stash.append(UInt32(truncatingIfNeeded: raw &>> 4))
            released &+= 1
        }
        unsafe v.pointee.deferred.removeAll()
    }
    unsafe n.pointee.state.pointee.counters.deferredReleased &+= released
}
