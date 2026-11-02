// The parallel scavenge, the full collection driver, pause records and the
// test-only verifier (SPEC.md "Scavenge", "Full collection", "Pause
// accounting", "Verification"). World stopped throughout; the stopper holds
// the safepoint mutex except while the parallel phase runs.

import Darwin
import Synchronization

/// A copy task: a range of root words, or a slice of remembered holders.
struct GCTask {
    var ptr: UnsafeMutablePointer<UInt64>
    var count: Int
    var remembered: Bool
}

/// A sweep task: a slice of one worker's young log.
struct SweepTask {
    var words: UnsafeMutablePointer<UInt32>
    var bits: UnsafeMutablePointer<UInt64>
    var count: Int
}

/// Shared state of one scavenge. Written by the stopper before the phase
/// opens (published by the mutex); during the phase only the atomics change.
struct GCShared {
    var tasks = RawBuf<GCTask>(capacity: 1024)
    var sweeps = RawBuf<SweepTask>(capacity: 1024)
    var taskNext: UnsafeMutablePointer<Atomic<Int>>
    var sweepNext: UnsafeMutablePointer<Atomic<Int>>
    var inCopy: UnsafeMutablePointer<Atomic<Int>>
    /// Ticks (ns) when the first participant passed the copy barrier.
    var copyEnd: UnsafeMutablePointer<Atomic<UInt64>>
    /// Worker id of each participant (index = join order). Written under the mutex.
    var parts: UnsafeMutablePointer<Int>
    /// Work sharing (SPEC.md "Load balance"): packets of up to
    /// `packetWords` oops exported by busy participants while one is idle.
    var packetLock: UnsafeMutablePointer<pthread_mutex_t>
    var packets: UnsafeMutablePointer<UInt64>
    var packetLen: UnsafeMutablePointer<Int>
    /// Indices of full packets (`full`), then of free ones (`free`).
    var fullList: UnsafeMutablePointer<Int>
    var freeList: UnsafeMutablePointer<Int>
    /// [0] full packets, [1] free packets. Guarded by `packetLock`; behind
    /// its own pointer because writing a field of `GCShared` itself would be
    /// a modifying access of the whole struct, which other participants read
    /// without the lock (ThreadSanitizer: Swift access race).
    var counts: UnsafeMutablePointer<Int>
    var poolCount: UnsafeMutablePointer<Atomic<Int>>
    var idle: UnsafeMutablePointer<Atomic<Int>>
    /// A scavenge left old space above its soft limit: the next stop (the
    /// stopper requests one right after resuming) is a full collection.
    var fullPending: UnsafeMutablePointer<Atomic<Bool>>
    /// Ticks after which a pending full collection is requested at a poll.
    var fullDue: UnsafeMutablePointer<Atomic<UInt64>>
    /// This scavenge pushes promoted objects grey (literal test mode only).
    var greyPromoted = false
    /// Scavenges so far, this scavenge's claim tag and age limit (SPEC.md
    /// "Header word", "Scavenge"). Written by the stopper before the phase.
    var scavNo: UInt64 = 0
    var claimTag: UInt64 = 1 << 62
    var ageN = 1
    /// The stop in progress: who requested it, how long it waited for young
    /// collections to drain first.
    var requester = -1
    var drainWaitNs: UInt64 = 0

    static func make() -> UnsafeMutablePointer<GCShared> {
        func counter() -> UnsafeMutablePointer<Atomic<Int>> {
            let p = UnsafeMutablePointer<Atomic<Int>>.allocate(capacity: 1)
            p.initialize(to: Atomic(0))
            return p
        }
        let ce = UnsafeMutablePointer<Atomic<UInt64>>.allocate(capacity: 1)
        ce.initialize(to: Atomic(0))
        let parts = UnsafeMutablePointer<Int>.allocate(capacity: 64)
        parts.initialize(repeating: -1, count: 64)
        let lock = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
        pthread_mutex_init(lock, nil)
        let packets = UnsafeMutablePointer<UInt64>.allocate(capacity: maxPackets * packetWords)
        let len = UnsafeMutablePointer<Int>.allocate(capacity: maxPackets)
        len.initialize(repeating: 0, count: maxPackets)
        let full = UnsafeMutablePointer<Int>.allocate(capacity: maxPackets)
        let free = UnsafeMutablePointer<Int>.allocate(capacity: maxPackets)
        for i in 0..<maxPackets { free[i] = i }
        let due = UnsafeMutablePointer<Atomic<UInt64>>.allocate(capacity: 1)
        due.initialize(to: Atomic(0))
        let fp = UnsafeMutablePointer<Atomic<Bool>>.allocate(capacity: 1)
        fp.initialize(to: Atomic(false))
        let counts = UnsafeMutablePointer<Int>.allocate(capacity: 2)
        counts[0] = 0
        counts[1] = maxPackets
        return boxed(GCShared(taskNext: counter(), sweepNext: counter(), inCopy: counter(), copyEnd: ce, parts: parts,
                              packetLock: lock, packets: packets, packetLen: len, fullList: full, freeList: free,
                              counts: counts, poolCount: counter(), idle: counter(), fullPending: fp, fullDue: due))
    }
}

/// One pause (SPEC.md "Pause accounting"). ns unless stated.
/// Pause kinds (SPEC.md "Phases", "Triggers and fallback").
public enum PauseKind {
    public static let scavenge: UInt8 = 0
    public static let full: UInt8 = 1
    public static let initial: UInt8 = 2
    public static let final: UInt8 = 3
    public static let fallback: UInt8 = 4
    public static let apply: UInt8 = 5
    public static let verify: UInt8 = 6
    public static func name(_ k: UInt8) -> String {
        ["scav", "full", "initial", "final", "fallback", "apply", "verify"][Int(k)]
    }
}

public struct GCRecord {
    public var kind: UInt8 = PauseKind.scavenge
    /// When the stop was requested (now() clock).
    public var atNs: UInt64 = 0
    /// The pause ran a mark-sweep (a full collection).
    public var full = false
    /// Concurrent marking parts (ns): applying a finished sweep, the
    /// snapshot copy and root scan of an initial mark, the drain, remembered
    /// filter and verifier of a final mark.
    public var applyNs: UInt64 = 0
    public var snapNs: UInt64 = 0
    public var cmRootsNs: UInt64 = 0
    public var cmRootWords: UInt64 = 0
    /// Initial mark: the survivor scan (part of cmRootsNs) and its words.
    public var survRootsNs: UInt64 = 0
    public var survRootWords: UInt64 = 0
    public var greyed: UInt64 = 0
    public var drainNs: UInt64 = 0
    public var drainEntries: UInt64 = 0
    public var drainObjects: UInt64 = 0
    public var filterNs: UInt64 = 0
    public var filtered: UInt64 = 0
    public var verifyNs: UInt64 = 0
    /// Final mark: relocation-set selection and frame pinning; any pause:
    /// pending blocks freed at its start and the relocation verifier.
    public var selectNs: UInt64 = 0
    public var pinNs: UInt64 = 0
    public var framePins: UInt64 = 0
    public var relocBlocks: UInt64 = 0
    public var pendingFreed: UInt64 = 0
    public var pendingFreeNs: UInt64 = 0
    public var relocVerifyNs: UInt64 = 0
    /// Scavenge part of the pause (initial marks).
    public var scavNs: UInt64 = 0
    public var totalNs: UInt64 = 0
    public var ttspNs: UInt64 = 0
    public var prepNs: UInt64 = 0
    public var copyWallNs: UInt64 = 0
    public var sweepWallNs: UInt64 = 0
    public var finishNs: UInt64 = 0
    public var markNs: UInt64 = 0
    public var msSweepNs: UInt64 = 0
    /// Critical participant (longest copy busy): its roots/remembered/copy split.
    public var critRootsNs: UInt64 = 0
    public var critRemNs: UInt64 = 0
    public var critCopyNs: UInt64 = 0
    /// Longest entry sweep of any participant.
    public var critSweepNs: UInt64 = 0
    public var meanBusyNs: UInt64 = 0
    public var coordNs: UInt64 = 0
    public var participants = 0
    public var youngBytes: UInt64 = 0
    public var promotedBytes: UInt64 = 0
    public var promotedObjects: UInt64 = 0
    public var survivedBytes: UInt64 = 0
    public var survivedObjects: UInt64 = 0
    public var overflowBytes: UInt64 = 0
    public var overflowObjects: UInt64 = 0
    public var remSet: UInt64 = 0
    public var remScanned: UInt64 = 0
    public var entriesAllocated: UInt64 = 0
    public var entriesFreed: UInt64 = 0
    public var oldBlocks = 0
    /// Work packets exported for sharing.
    public var packets: UInt64 = 0
    /// Worker that requested the stop; time it waited for young collections.
    public var requester = -1
    public var drainWaitNs: UInt64 = 0
}

public struct GCLog {
    public var recs: UnsafeMutablePointer<GCRecord> = .allocate(capacity: 1 << 16)
    public var count = 0
    public var records: [GCRecord] { Array(UnsafeBufferPointer(start: recs, count: count)) }
}

/// Run a stop-the-world operation. Mutex held; every worker parked or
/// outside the VM; TLABs retired and entry reservations released.
func performOp(_ vm: VMRef, _ w: WorkerRef, _ op: SafeOp, requested t0: UInt64, stopped t1: UInt64) {
    let generational = vm.pointee.heap.nurseryBytes > 0
    let cmOn = vm.pointee.cmConfig.concurrent && generational
    let cm = vm.pointee.cm
    let g = vm.pointee.gc
    var applyNs: UInt64 = 0
    // Every pause frees the evacuated blocks still waiting for epochs: every
    // active worker is parked at a safepoint (SPEC.md "Freeing old blocks").
    let tpf = now()
    let pendingFreed = cm.pendingCount.pointee.load(ordering: .relaxed) > 0 ? tryFreePending(vm, atPause: true) : 0
    let pendingFreeNs = now() &- tpf
    // A finished lazy sweep is published by whichever stop comes first
    // (SPEC.md "Lazy sweep").
    if cmOn && cm.phase.pointee.load(ordering: .acquiring) == CMPhase.swept { applyNs = applySweep(vm) }
    var rec = GCRecord()
    rec.pendingFreed = UInt64(pendingFreed)
    rec.pendingFreeNs = pendingFreeNs
    switch op {
    case .apply, .verify:
        if case .verify = op { youngVerify(vm) }
        rec.kind = { if case .verify = op { return PauseKind.verify } else { return PauseKind.apply } }()
        rec.applyNs = applyNs
        finishRecord(vm, &rec, t0, t1, work: applyNs)
        return
    case .initialMark:
        // local/offload (SPEC.md "Part 3"): (a) no scavenge, young-root scan;
        // (b) the stop-the-world scavenge first, then the survivor scan.
        if cmOn && cm.phase.pointee.load(ordering: .relaxed) == CMPhase.idle {
            var scav: UInt64 = 0
            if !vm.pointee.ycConfig.imYoung {
                rec = scavenge(vm, w, t0, t1)
                scav = now() &- t1
                rec.scavNs = scav
            }
            rec.pendingFreed = UInt64(pendingFreed)
            rec.pendingFreeNs = pendingFreeNs
            initialMark(vm, &rec, literal: false, youngScan: vm.pointee.ycConfig.imYoung)
            rec.kind = PauseKind.initial
            rec.applyNs = applyNs
            let work = rec.critRootsNs &+ rec.critRemNs &+ rec.critCopyNs &+ rec.critSweepNs
            finishRecord(vm, &rec, t0, t1, work: work &+ rec.snapNs &+ rec.cmRootsNs &+ applyNs)
        } else {
            rec.kind = PauseKind.apply
            rec.applyNs = applyNs
            finishRecord(vm, &rec, t0, t1, work: applyNs)
        }
        return
    default: break
    }
    if case .finalMark = op {
        if cmOn && cm.phase.pointee.load(ordering: .relaxed) == CMPhase.marking {
            finalMark(vm, &rec)
            rec.kind = PauseKind.final
        } else if applyNs == 0 {
            return // the cycle ended (fallback) before this stop
        }
        rec.applyNs = applyNs
        finishRecord(vm, &rec, t0, t1, work: rec.drainNs &+ rec.filterNs &+ rec.verifyNs &+ applyNs)
        return
    }
    var doScavenge = generational
    if case .startCycle(let sc) = op, !sc { doScavenge = false }
    var isFull = false
    if case .full = op { isFull = true }
    // A full collection in concurrent mode is a fallback: the cycle is
    // abandoned first.
    if isFull && cmOn { abortCycle(vm) }
    let marking = cmOn && cm.phase.pointee.load(ordering: .relaxed) == CMPhase.marking
    g.pointee.greyPromoted = marking && vm.pointee.cmConfig.literal && vm.pointee.cmConfig.literalGrey
    if doScavenge {
        rec = scavenge(vm, w, t0, t1, promoteAll: isFull)
        rec.scavNs = now() &- t1
        rec.pendingFreed = UInt64(pendingFreed)
        rec.pendingFreeNs = pendingFreeNs
    } else if case .scavenge = op {
        return // non-generational: nothing to do
    }
    if marking, let c = cm.log.pointee.current {
        c.pointee.promotedBytes &+= rec.promotedBytes
        c.pointee.scavenges += 1
    }
    rec.applyNs = applyNs
    var needFull = false
    let heap = vm.pointee.heap
    let soft = heap.softBlocks
    let inUse = heap.blocksInUse()
    // Far above the limit (a quarter of the promotion reserve) the full
    // collection runs in this pause, so the next scavenge cannot exhaust the
    // reserve.
    let farAbove = inUse > soft + (heap.nblocks - soft) / 4
    var cmWork: UInt64 = 0
    if isFull {
        needFull = true
    } else if cmOn {
        let ph = cm.phase.pointee.load(ordering: .relaxed)
        if inUse > soft {
            // Old space filled before the cycle finished (or a single
            // scavenge jumped past threshold and limit): fall back to a
            // stop-the-world full collection (SPEC.md "Triggers and fallback").
            if farAbove {
                needFull = true
            } else if !g.pointee.fullPending.pointee.load(ordering: .relaxed) {
                g.pointee.fullDue.pointee.store(ticks() &+ nsToTicks(fullDelayNs), ordering: .relaxed)
                g.pointee.fullPending.pointee.store(true, ordering: .relaxed)
            }
            if !cm.fallbackPending.pointee.load(ordering: .relaxed) {
                cm.fallbackPending.pointee.store(true, ordering: .relaxed)
                FileHandleStderr.write("kajo: FALLBACK to a stop-the-world full collection: old space \(inUse) blocks > \(soft) with the cycle \(["idle", "marking", "sweeping", "swept"][ph])\n")
            }
        } else if ph == CMPhase.idle && !g.pointee.fullPending.pointee.load(ordering: .relaxed) {
            var start = vm.pointee.cmConfig.force || Double(inUse) >= vm.pointee.cmConfig.threshold * Double(soft)
            if case .startCycle = op { start = true }
            if start {
                initialMark(vm, &rec, literal: !doScavenge)
                rec.kind = PauseKind.initial
                cmWork = rec.snapNs &+ rec.cmRootsNs
            }
        }
    } else if inUse > soft + (heap.nblocks - soft) / 4 {
        needFull = true
    } else if generational {
        // ADR 0005: requested one scavenge early, when another scavenge
        // promoting as much as this one would cross the soft limit.
        let expect = Int(rec.promotedBytes) / blockSize + rec.participants
        if inUse + expect > soft {
            g.pointee.fullDue.pointee.store(ticks() &+ nsToTicks(fullDelayNs), ordering: .relaxed)
            g.pointee.fullPending.pointee.store(true, ordering: .relaxed)
        }
    }
    var fallback = false
    if needFull {
        fallback = cmOn
        g.pointee.fullPending.pointee.store(false, ordering: .relaxed)
        cm.fallbackPending.pointee.store(false, ordering: .relaxed)
        if cmOn { abortCycle(vm) }
    }
    var msNs: UInt64 = 0
    if needFull && doScavenge && !isFull && vm.pointee.cmConfig.ageN > 1 {
        // The mark-sweep needs nothing young: promote the survivors first
        // (SPEC.md "Scavenge": full collections promote everything).
        let r2 = scavenge(vm, w, t0, t1, promoteAll: true)
        rec.promotedBytes &+= r2.promotedBytes
        rec.promotedObjects &+= r2.promotedObjects
        rec.critCopyNs &+= r2.critRootsNs &+ r2.critRemNs &+ r2.critCopyNs &+ r2.critSweepNs
    }
    if needFull {
        if let ws = vm.pointee.workers {
            for i in 0..<vm.pointee.workerCount { vm.pointee.heap.retire(&ws[i].pointee.promo) }
        }
        let (mark, sweep) = markSweep(vm, w)
        rec.full = true
        rec.kind = fallback ? PauseKind.fallback : PauseKind.full
        rec.markNs = mark
        rec.msSweepNs = sweep
        msNs = mark &+ sweep
        if fallback {
            vm.add(.cmFallbacks, 1)
            FileHandleStderr.write("kajo: FALLBACK full collection: \(fixedMs(mark &+ sweep)) ms of mark-sweep\n")
        }
        if vm.pointee.verify { postVerify(vm, expected: nil, copied: 0) }
    }
    let work = generational ? rec.critRootsNs &+ rec.critRemNs &+ rec.critCopyNs &+ rec.critSweepNs : 0
    finishRecord(vm, &rec, t0, t1, work: work &+ msNs &+ cmWork &+ applyNs)
    if rec.full {
        vm.add(.fullGCs, 1)
        vm.add(.fullNs, rec.totalNs)
        vm.add(.gcCount, 1)
        vm.add(.gcNs, rec.totalNs)
        vm.add(.markNs, rec.markNs)
        vm.add(.sweepNs, rec.msSweepNs)
    }
}

private func fixedMs(_ ns: UInt64) -> String { fixed(Double(ns) / 1e6, 3) }

/// Total, ttsp, coordination (total minus `work`), the log, the verbose line.
func finishRecord(_ vm: VMRef, _ rec: inout GCRecord, _ t0: UInt64, _ t1: UInt64, work: UInt64) {
    rec.requester = vm.pointee.gc.pointee.requester
    rec.drainWaitNs = vm.pointee.gc.pointee.drainWaitNs
    vm.pointee.sync.pointee.stopKind = rec.kind
    if vm.pointee.cmConfig.verify {
        let tv = now()
        relocVerify(vm)
        rec.relocVerifyNs = now() &- tv
    }
    let t2 = now()
    rec.totalNs = t2 &- t0
    rec.atNs = t0
    rec.ttspNs = t1 &- t0
    rec.oldBlocks = vm.pointee.heap.blocksInUse()
    rec.coordNs = rec.totalNs > work ? rec.totalNs &- work : 0
    let log = vm.pointee.gcLog
    if log.pointee.count < 1 << 16 {
        log.pointee.recs[log.pointee.count] = rec
        log.pointee.count += 1
    }
    if vm.pointee.verboseGC {
        FileHandleStderr.write("gc: \(PauseKind.name(rec.kind)) \(Double(rec.totalNs) / 1e6) ms, promoted \(rec.promotedBytes) B, old blocks \(rec.oldBlocks)\n")
    }
}

// MARK: - the scavenge

private let rootTaskWords = 4096
let packetWords = 256
/// Mutator time between a scavenge and the full collection it asked for
/// (`KAJO_FULL_DELAY_US`, default 1000), so a main-thread turn can run
/// between the two pauses.
let fullDelayNs: UInt64 = UInt64(envInt("KAJO_FULL_DELAY_US") ?? 1000) * 1000
let maxPackets = 1024
private let remTaskHolders = 256
private let sweepTaskWords = 1024

/// `promoteAll`: ignore the age (the scavenge in front of a mark-sweep).
private func scavenge(_ vm: VMRef, _ w: WorkerRef, _ t0: UInt64, _ t1: UInt64, promoteAll: Bool = false) -> GCRecord {
    var rec = GCRecord()
    let g = vm.pointee.gc
    let n = vm.pointee.workerCount
    let ws = vm.pointee.workers.unsafelyUnwrapped
    // --- prep
    var young: UInt64 = 0
    var remSet: UInt64 = 0
    for i in 0..<n {
        let x = ws[i]
        let nur = nurOf(vm, i)
        young &+= UInt64(x.pointee.nurseryTop &- x.pointee.nurseryStart)
        if nur.pointee.survBytes > 0 {
            young &+= UInt64(nur.pointee.survFromTop &- nur.pointee.survStart(1 &- nur.pointee.survTo))
        }
        nur.pointee.survCur = nur.pointee.survStart(nur.pointee.survTo)
        nur.pointee.nextLogWord.count = 0
        nur.pointee.nextLogBits.count = 0
        for k in 0..<maxNurseries {
            x.pointee.nextRem[k].count = 0
            remSet &+= UInt64(x.pointee.rem[k].count)
        }
        remSet &+= UInt64(nur.pointee.carried.count)
        x.pointee.gc = GCShare()
    }
    // Claim tag of this scavenge (SPEC.md "Header word"), age limit.
    g.pointee.scavNo &+= 1
    g.pointee.claimTag = UInt64(1) &<< (62 &+ (g.pointee.scavNo & 1))
    g.pointee.ageN = promoteAll ? 1 : vm.pointee.cmConfig.ageN
    var expected: Int? = nil
    if vm.pointee.verify { expected = preVerify(vm) }
    g.pointee.tasks.count = 0
    for (p, c) in rootRanges(vm) {
        var off = 0
        while off < c {
            g.pointee.tasks.push(GCTask(ptr: p + off, count: min(rootTaskWords, c - off), remembered: false))
            off += rootTaskWords
        }
    }
    g.pointee.sweeps.count = 0
    func remTasks(_ bp: UnsafeMutablePointer<RawBuf<Oop>>) {
        // Young holders (cross-nursery) leave the lists here, while headers
        // are stable: in the parallel phase another participant may promote
        // one, and its new body is not copied yet. They are traced if
        // reachable and re-remembered by the copy (`drain`).
        let rem = vm.pointee.space.rem
        var j = 0
        for i in 0..<bp.pointee.count {
            let o = bp.pointee.ptr[i]
            if vm.pointee.om.header(o) & youngBit != 0 {
                rem[Int(truncatingIfNeeded: o &>> 4)].store(0, ordering: .relaxed)
            } else {
                bp.pointee.ptr[j] = o
                j += 1
            }
        }
        bp.pointee.count = j
        let b = bp.pointee
        var off = 0
        while off < b.count {
            g.pointee.tasks.push(GCTask(ptr: b.ptr + off, count: min(remTaskHolders, b.count - off), remembered: true))
            off += remTaskHolders
        }
    }
    func sweepTasks(_ words: RawBuf<UInt32>, _ bits: RawBuf<UInt64>) {
        var off = 0
        while off < words.count {
            g.pointee.sweeps.push(SweepTask(words: words.ptr + off, bits: bits.ptr + off,
                                            count: min(sweepTaskWords, words.count - off)))
            off += sweepTaskWords
        }
    }
    for i in 0..<n {
        let x = ws[i]
        let nur = nurOf(vm, i)
        for k in 0..<maxNurseries { remTasks(x.pointee.rem + k) }
        withUnsafeMutablePointer(to: &nur.pointee.carried) { remTasks($0) }
        sweepTasks(x.pointee.logWord, x.pointee.logBits)
        sweepTasks(nur.pointee.survLogWord, nur.pointee.survLogBits)
    }
    g.pointee.taskNext.pointee.store(0, ordering: .relaxed)
    g.pointee.sweepNext.pointee.store(0, ordering: .relaxed)
    g.pointee.inCopy.pointee.store(0, ordering: .relaxed)
    g.pointee.copyEnd.pointee.store(0, ordering: .relaxed)
    g.pointee.idle.pointee.store(0, ordering: .relaxed)
    let tp = now()
    // --- parallel phase
    let parts = runParallelPhase(vm, w)
    let tj = now()
    // --- finish
    var crit = GCShare()
    var critSweep: UInt64 = 0
    var busy: UInt64 = 0
    for k in 0..<parts {
        let s = worker(vm, g.pointee.parts[k]).pointee.gc
        if s.copyBusy >= crit.copyBusy { crit = s }
        critSweep = max(critSweep, s.sweepNs)
        busy &+= s.copyBusy &+ s.sweepNs
        rec.promotedBytes &+= s.promotedBytes
        rec.promotedObjects &+= s.promotedObjects
        rec.survivedBytes &+= s.survivedBytes
        rec.survivedObjects &+= s.survivedObjects
        rec.overflowBytes &+= s.overflowBytes
        rec.overflowObjects &+= s.overflowObjects
        rec.entriesAllocated &+= s.entriesAllocated
        rec.entriesFreed &+= s.entriesFreed
        rec.remScanned &+= s.remScanned
        rec.packets &+= s.exported
    }
    for i in 0..<n {
        let x = ws[i]
        let nur = nurOf(vm, i)
        x.pointee.nurseryTop = x.pointee.nurseryStart
        // The holders that still name young objects, per nursery, and the
        // survivors' entries carry over (SPEC.md "Stop-the-world scavenge").
        for k in 0..<maxNurseries {
            swap(&x.pointee.rem[k], &x.pointee.nextRem[k])
            x.pointee.nextRem[k].count = 0
        }
        nur.pointee.carried.count = 0
        x.pointee.logWord.count = 0
        x.pointee.logBits.count = 0
        swap(&nur.pointee.survLogWord, &nur.pointee.nextLogWord)
        swap(&nur.pointee.survLogBits, &nur.pointee.nextLogBits)
        nur.pointee.nextLogWord.count = 0
        nur.pointee.nextLogBits.count = 0
        // Flip: survivor-to becomes survivor-from.
        nur.pointee.survFromTop = nur.pointee.survCur
        nur.pointee.survTo = 1 &- nur.pointee.survTo
    }
    rebuildChunkPool(vm)
    if vm.pointee.verify { postVerify(vm, expected: expected, copied: rec.promotedObjects &+ rec.survivedObjects) }
    let tf = now()
    let ce = g.pointee.copyEnd.pointee.load(ordering: .relaxed)
    rec.prepNs = tp &- t1
    rec.copyWallNs = ce > tp ? ce &- tp : tj &- tp
    rec.sweepWallNs = ce > tp ? tj &- ce : 0
    rec.finishNs = tf &- tj
    rec.critRootsNs = crit.rootsNs
    rec.critRemNs = crit.remNs
    rec.critCopyNs = crit.copyNs
    rec.critSweepNs = critSweep
    rec.meanBusyNs = busy / UInt64(max(parts, 1))
    rec.participants = parts
    rec.youngBytes = young
    rec.remSet = remSet
    vm.add(.scavenges, 1)
    vm.add(.scavengeNs, tf &- t0)
    vm.add(.promotedBytes, rec.promotedBytes)
    vm.add(.promotedObjects, rec.promotedObjects)
    vm.add(.survivedBytes, rec.survivedBytes)
    vm.add(.overflowBytes, rec.overflowBytes)
    vm.add(.overflowObjects, rec.overflowObjects)
    vm.add(.youngBytes, young)
    vm.add(.remSetTotal, remSet)
    vm.add(.entriesAllocated, rec.entriesAllocated)
    vm.add(.entriesFreed, rec.entriesFreed)
    vm.add(.entrySweepNs, critSweep)
    return rec
}

/// One participant (stopper or a parked worker), mutex not held.
func participate(_ vm: VMRef, _ w: WorkerRef) {
    let g = vm.pointee.gc
    let om = vm.pointee.om
    w.pointee.gc = GCShare()
    g.pointee.inCopy.pointee.wrappingAdd(1, ordering: .acquiringAndReleasing)
    let ntasks = g.pointee.tasks.count
    while true {
        let i = g.pointee.taskNext.pointee.wrappingAdd(1, ordering: .relaxed).oldValue
        if i >= ntasks { break }
        let t = g.pointee.tasks.ptr[i]
        let a = now()
        if t.remembered {
            let rem = vm.pointee.space.rem
            for k in 0..<t.count {
                let holder = t.ptr[k]
                // A holder is in one list per nursery: the first participant
                // to take its bits scans it.
                let r = rem + Int(truncatingIfNeeded: holder &>> 4)
                if r.pointee.exchange(0, ordering: .relaxed) == 0 { continue }
                let h = atomicHeader(om.entry(holder)).pointee.load(ordering: .relaxed)
                // Young holders are traced if reachable.
                if h & youngBit != 0 || hdrIsBytes(h) { continue }
                var mask: UInt32 = 0
                let ns = hdrSlots(h)
                let s = om.slotsPtr(holder)
                var j = 0
                while j < ns {
                    let nn = scavWord(vm, w, om, s[j])
                    if nn != 0 { mask |= UInt32(1) &<< UInt32(nn &- 1) }
                    j &+= 1
                }
                w.pointee.gc.remScanned &+= UInt64(ns)
                // Still names young objects: stays remembered per nursery.
                if mask != 0 { rememberMask(w, r, holder, mask) }
            }
            w.pointee.gc.remNs &+= now() &- a
        } else {
            var k = 0
            while k < t.count { _ = scavWord(vm, w, om, atomicWord(t.ptr + k).pointee.load(ordering: .relaxed)); k &+= 1 }
            w.pointee.gc.rootsNs &+= now() &- a
        }
        let b = now()
        drain(vm, w, om)
        w.pointee.gc.copyNs &+= now() &- b
    }
    // Tasks are exhausted: help with exported packets until no participant
    // is copying. Invariants: packets are pushed only by a counted
    // (`inCopy`) participant; a participant stops being counted only after
    // finding the pool empty; a taker is counted before it pops; and nobody
    // re-counts itself once `inCopy` reached 0. So `inCopy == 0` means no
    // packet is left and no copy is in flight: the copy barrier.
    let b = now()
    while takePacket(g, w) { drain(vm, w, om) }
    w.pointee.gc.copyNs &+= now() &- b
    g.pointee.inCopy.pointee.wrappingSubtract(1, ordering: .sequentiallyConsistent)
    let wa = now()
    var spins = 0
    g.pointee.idle.pointee.wrappingAdd(1, ordering: .sequentiallyConsistent)
    while true {
        var c = g.pointee.inCopy.pointee.load(ordering: .sequentiallyConsistent)
        if c == 0 { break }
        if g.pointee.poolCount.pointee.load(ordering: .sequentiallyConsistent) > 0 {
            var counted = false
            while c > 0 {
                let (ok, cur) = g.pointee.inCopy.pointee.compareExchange(expected: c, desired: c + 1, ordering: .sequentiallyConsistent)
                if ok { counted = true; break }
                c = cur
            }
            if counted {
                g.pointee.idle.pointee.wrappingSubtract(1, ordering: .sequentiallyConsistent)
                let t = now()
                while takePacket(g, w) { drain(vm, w, om) }
                w.pointee.gc.copyNs &+= now() &- t
                g.pointee.inCopy.pointee.wrappingSubtract(1, ordering: .sequentiallyConsistent)
                g.pointee.idle.pointee.wrappingAdd(1, ordering: .sequentiallyConsistent)
                continue
            }
        }
        spins &+= 1
        if spins & 63 == 0 { sched_yield() }
    }
    g.pointee.idle.pointee.wrappingSubtract(1, ordering: .sequentiallyConsistent)
    let ce = now()
    _ = g.pointee.copyEnd.pointee.compareExchange(expected: 0, desired: ce, ordering: .relaxed)
    w.pointee.gc.waitNs = ce &- wa
    // Entry sweep (SPEC.md "Scavenge": per bit, a word may be in two log
    // records, a survivor's bit and a later take of the same word).
    let sp = vm.pointee.space
    let nsweeps = g.pointee.sweeps.count
    var alloc: UInt64 = 0, freed: UInt64 = 0
    while true {
        let i = g.pointee.sweepNext.pointee.wrappingAdd(1, ordering: .relaxed).oldValue
        if i >= nsweeps { break }
        let t = g.pointee.sweeps.ptr[i]
        for k in 0..<t.count {
            let gw = Int(t.words[k])
            let bits = t.bits[k]
            let alive = sp.surv[gw].bitwiseAnd(~bits, ordering: .relaxed).oldValue & bits
            let dead = bits & ~alive
            if dead != 0 { atomicWord(sp.used + gw).pointee.bitwiseAnd(~dead, ordering: .relaxed) }
            alloc &+= UInt64(bits.nonzeroBitCount)
            freed &+= UInt64(dead.nonzeroBitCount)
        }
    }
    w.pointee.gc.entriesAllocated = alloc
    w.pointee.gc.entriesFreed = freed
    w.pointee.gc.sweepNs = now() &- ce
}

/// Scan one word: copy the young object it names if this participant claims
/// it first (SPEC.md "Claim tag"). Answers 1 + the nursery of the object if
/// it is young after this scavenge (a holder of it must stay remembered for
/// that nursery), else 0.
@inline(__always)
private func scavWord(_ vm: VMRef, _ w: WorkerRef, _ om: OM, _ v: Oop) -> Int {
    if v & 1 != 0 || v == 0 { return 0 }
    let ent = om.entry(v)
    let h = atomicHeader(ent).pointee.load(ordering: .relaxed)
    if h & youngBit == 0 { return 0 }
    return evacuate(vm, w, om, v, ent, h)
}

/// Set `mask` in a holder's bits and put it on the participant's next
/// remembered buffers of the nurseries newly set.
@inline(never)
private func rememberMask(_ w: WorkerRef, _ r: UnsafeMutablePointer<Atomic<UInt32>>, _ o: Oop, _ mask: UInt32) {
    let old = r.pointee.bitwiseOr(mask, ordering: .relaxed).oldValue
    var m = mask & ~old
    while m != 0 {
        let n = m.trailingZeroBitCount
        m &= m &- 1
        w.pointee.nextRem[n].push(o)
    }
}

/// Claim and copy a young object: into this participant's survivor-to with
/// age + 1, or into its promotion buffer (SPEC.md "Scavenge"). The decision
/// is written with the claim, so a loser reads it from the header.
@inline(never)
private func evacuate(_ vm: VMRef, _ w: WorkerRef, _ om: OM, _ v: Oop, _ ent: UnsafeMutablePointer<UInt64>, _ h0: UInt64) -> Int {
    let g = vm.pointee.gc
    let tag = g.pointee.claimTag
    let nur = nurOf(vm, w.pointee.id)
    var h = h0
    var survive = false, overflow = false
    let size = objectBytes(h0)
    while true {
        if h & youngBit == 0 { return 0 }                // promoted by another participant
        if h & tag != 0 { return 1 &+ hdrNursery(h) }    // claimed this scavenge, stays young
        let age = hdrAge(h) &+ 1
        survive = false
        overflow = false
        if age < g.pointee.ageN {
            if nur.pointee.survCur &+ UInt(size) <= nur.pointee.survStart(nur.pointee.survTo) &+ nur.pointee.survBytes {
                survive = true
            } else {
                overflow = true
            }
        }
        // A survivor moves to the participant's nursery (SPEC.md "Header word").
        let base = h & ~(claimMask | ageMask | nurseryMask)
        let nh = survive ? base | (UInt64(age) &<< ageShift) | tag | (UInt64(w.pointee.id) &<< nurseryShift) : base & ~youngBit
        let (won, cur) = atomicHeader(ent).pointee.compareExchange(expected: h, desired: nh, ordering: .relaxed)
        if won { break }
        h = cur
    }
    let dst: UInt
    if survive {
        dst = nur.pointee.survCur
        nur.pointee.survCur = dst &+ UInt(size)
    } else {
        if w.pointee.promo.end &- w.pointee.promo.cur < UInt(size) {
            if !vm.pointee.heap.refill(&w.pointee.promo, soft: false) { fatal("promotion failed: old space and reserve exhausted") }
        }
        dst = w.pointee.promo.cur
        w.pointee.promo.cur = dst &+ UInt(size)
    }
    let src = om.heap &+ UInt(truncatingIfNeeded: om.offsetWord(v).pointee.load(ordering: .relaxed))
    if size <= 128 {
        // Most bodies are a few words: a word loop beats a memmove call.
        let d = wordPtr(dst), s = wordPtr(src)
        var i = 0
        let n = size &>> 3
        while i < n { d[i] = s[i]; i &+= 1 }
    } else {
        UnsafeMutableRawPointer(bitPattern: dst).unsafelyUnwrapped
            .copyMemory(from: UnsafeRawPointer(bitPattern: src).unsafelyUnwrapped, byteCount: size)
    }
    om.offsetWord(v).pointee.store(UInt64(dst &- om.heap), ordering: .relaxed)
    let idx = Int(truncatingIfNeeded: v &>> 4)
    let bit = UInt64(1) &<< UInt64(idx & 63)
    vm.pointee.space.surv[idx &>> 6].bitwiseOr(bit, ordering: .relaxed)
    if survive {
        w.pointee.gc.survivedBytes &+= UInt64(size)
        w.pointee.gc.survivedObjects &+= 1
        nur.pointee.nextLogWord.push(UInt32(truncatingIfNeeded: idx &>> 6))
        nur.pointee.nextLogBits.push(bit)
    } else {
        w.pointee.gc.promotedBytes &+= UInt64(size)
        w.pointee.gc.promotedObjects &+= 1
        if overflow {
            w.pointee.gc.overflowBytes &+= UInt64(size)
            w.pointee.gc.overflowObjects &+= 1
        }
    }
    if !hdrIsBytes(h) {
        w.pointee.gcStack.push(v)
        // DESIGN.md's literal rule (test mode only): promoted while marking
        // means grey. Tag 2 makes a marker scan it although it is not a
        // snapshot entry.
        if !survive && vm.pointee.gc.pointee.greyPromoted { satbPush(vm, w, v | 2) }
    }
    return survive ? 1 &+ w.pointee.id : 0
}

/// Scan copied objects (their new bodies) until the local stack is empty. A
/// promoted object that names a survivor is remembered for the next
/// scavenge. Every 1024 objects, if a participant is idle and the pool is
/// empty, export the bottom half of the stack.
private func drain(_ vm: VMRef, _ w: WorkerRef, _ om: OM) {
    let g = vm.pointee.gc
    var k = 0
    while let o = w.pointee.gcStack.pop() {
        // Claimed by this participant. A relaxed atomic load (a plain ldr on
        // arm64): losers' failed CASes on this header are recorded by
        // ThreadSanitizer as atomic writes, so a plain load is reported.
        let h = atomicHeader(om.entry(o)).pointee.load(ordering: .relaxed)
        let n = hdrSlots(h)
        let s = om.slotsPtr(o)
        // The barrier's rule on the copy: young values of another nursery
        // than the holder's (or any, if the holder is now old).
        let own = h & youngBit != 0 ? 1 &+ hdrNursery(h) : 0
        var mask: UInt32 = 0
        var i = 0
        while i < n {
            let nn = scavWord(vm, w, om, s[i])
            if nn != 0 && nn != own { mask |= UInt32(1) &<< UInt32(nn &- 1) }
            i &+= 1
        }
        if mask != 0 { rememberMask(w, vm.pointee.space.rem + Int(truncatingIfNeeded: o &>> 4), o, mask) }
        k &+= 1
        if k & 1023 == 0 && w.pointee.gcStack.count >= 8
            && g.pointee.idle.pointee.load(ordering: .relaxed) > 0
            && g.pointee.poolCount.pointee.load(ordering: .relaxed) == 0 {
            exportPacket(g, w)
        }
    }
}


private func exportPacket(_ g: UnsafeMutablePointer<GCShared>, _ w: WorkerRef) {
    let n = min(w.pointee.gcStack.count / 2, packetWords)
    pthread_mutex_lock(g.pointee.packetLock)
    if g.pointee.counts[1] == 0 { pthread_mutex_unlock(g.pointee.packetLock); return }
    g.pointee.counts[1] -= 1
    let pk = g.pointee.freeList[g.pointee.counts[1]]
    let dst = g.pointee.packets + pk * packetWords
    let st = w.pointee.gcStack.ptr
    dst.update(from: st, count: n)
    (st).update(from: st + n, count: w.pointee.gcStack.count - n)
    w.pointee.gcStack.count -= n
    g.pointee.packetLen[pk] = n
    g.pointee.fullList[g.pointee.counts[0]] = pk
    g.pointee.counts[0] += 1
    g.pointee.poolCount.pointee.wrappingAdd(1, ordering: .sequentiallyConsistent)
    pthread_mutex_unlock(g.pointee.packetLock)
    w.pointee.gc.exported &+= 1
}

/// Move one exported packet onto this participant's stack. The caller is
/// counted in `inCopy`.
private func takePacket(_ g: UnsafeMutablePointer<GCShared>, _ w: WorkerRef) -> Bool {
    if g.pointee.poolCount.pointee.load(ordering: .sequentiallyConsistent) == 0 { return false }
    pthread_mutex_lock(g.pointee.packetLock)
    if g.pointee.counts[0] == 0 { pthread_mutex_unlock(g.pointee.packetLock); return false }
    g.pointee.counts[0] -= 1
    let pk = g.pointee.fullList[g.pointee.counts[0]]
    let n = g.pointee.packetLen[pk]
    let src = g.pointee.packets + pk * packetWords
    for i in 0..<n { w.pointee.gcStack.push(src[i]) }
    g.pointee.freeList[g.pointee.counts[1]] = pk
    g.pointee.counts[1] += 1
    g.pointee.poolCount.pointee.wrappingSubtract(1, ordering: .sequentiallyConsistent)
    pthread_mutex_unlock(g.pointee.packetLock)
    return true
}

/// Stopper, after the parallel phase: the pool's unconsumed chunks plus
/// every chunk taken this cycle that has a free bit.
private func rebuildChunkPool(_ vm: VMRef) {
    let sp = vm.pointee.space
    var n = 0
    // Deduplicated: the lazy sweep's apply may have pooled a chunk a worker
    // also took this cycle; a chunk in the pool twice would have two owners.
    let count = sp.poolCount.pointee.load(ordering: .relaxed)
    let next = min(sp.poolNext.pointee.load(ordering: .relaxed), count)
    for i in next..<count where sp.inPool[Int(sp.pool[i])] == 0 {
        sp.poolScratch[n] = sp.pool[i]; sp.inPool[Int(sp.pool[i])] = 1; n += 1
    }
    for i in 0..<vm.pointee.workerCount {
        let x = worker(vm, i)
        for k in 0..<x.pointee.chunks.count {
            let c = Int(x.pointee.chunks.ptr[k])
            if sp.inPool[c] != 0 { continue }
            var free = false
            for j in 0..<wordsPerChunk where sp.used[c &* wordsPerChunk &+ j] != ~0 { free = true; break }
            if free { sp.poolScratch[n] = UInt32(c); sp.inPool[c] = 1; n += 1 }
        }
        x.pointee.chunks.count = 0
    }
    for i in 0..<n { sp.inPool[Int(sp.poolScratch[i])] = 0 }
    sp.pool.update(from: sp.poolScratch, count: n)
    sp.poolCount.pointee.store(n, ordering: .relaxed)
    sp.poolNext.pointee.store(0, ordering: .relaxed)
}

// MARK: - verification (tests)

@inline(__always) private func isUsed(_ sp: Space, _ o: Oop) -> Bool {
    let i = Int(truncatingIfNeeded: o &>> 4)
    return i < tableEntries && sp.used[i &>> 6] & (UInt64(1) &<< UInt64(i & 63)) != 0
}

private func failure(_ vm: VMRef, _ msg: String) {
    let n = vm.metric(.verifyFailures)
    vm.add(.verifyFailures, 1)
    if n < 10 { FileHandleStderr.write("verify: \(msg)\n") }
}

/// Every used entry (index, entry pointer), entry 0 excluded.
private func forEachUsed(_ vm: VMRef, _ body: (Int, UnsafeMutablePointer<UInt64>) -> Void) {
    let sp = vm.pointee.space
    let om = vm.pointee.om
    for gw in 0..<(chunkHwmNow(vm) * wordsPerChunk) {
        var bits = sp.used[gw]
        while bits != 0 {
            let idx = gw * 64 + bits.trailingZeroBitCount
            bits &= bits - 1
            if idx != 0 { body(idx, om.entry(UInt64(idx) << 4)) }
        }
    }
}

/// Before copying: every old object holding a young oop is remembered;
/// answers the number of young objects reachable from roots and remembered
/// holders (what the scavenge must promote, each exactly once).
private func preVerify(_ vm: VMRef) -> Int {
    vm.add(.verifyRuns, 1)
    let om = vm.pointee.om
    let rem = vm.pointee.space.rem
    let young = youngMode(vm) != YoungMode.stw
    forEachUsed(vm) { idx, e in
        let h = om.header(UInt64(idx) << 4)
        // Old holders always; young holders of another nursery's objects in
        // local/offload (the cross-nursery barrier's invariant).
        if (h & youngBit != 0 && !young) || hdrIsBytes(h) || pendingDead(vm, idx) { return }
        let o = UInt64(idx) << 4
        for i in 0..<hdrSlots(h) {
            let v = om.slot(o, i)
            if v & 1 != 0 || v == 0 { continue }
            let hv = om.header(v)
            if !hdrYoung(hv) || (h ^ hv) & youngNurseryMask == 0 { continue }
            if rem[idx].load(ordering: .relaxed) & (UInt32(1) << UInt32(hdrNursery(hv))) == 0 {
                failure(vm, "holder \(o) (class \(hdrClass(h))) slot \(i) holds young \(v) of nursery \(hdrNursery(hv)) but is not remembered for it")
            }
        }
    }
    var seen = Set<Oop>()
    var stack: [Oop] = []
    func visit(_ v: Oop) {
        if v & 1 != 0 || v == 0 || !hdrYoung(om.header(v)) { return }
        if seen.insert(v).inserted && !hdrIsBytes(om.header(v)) { stack.append(v) }
    }
    func drainV() {
        while let o = stack.popLast() { for i in 0..<hdrSlots(om.header(o)) { visit(om.slot(o, i)) } }
    }
    for (p, c) in rootRanges(vm) { for i in 0..<c { visit(p[i]) }; drainV() }
    for k in 0..<vm.pointee.workerCount {
        let x = worker(vm, k)
        func holders(_ b: RawBuf<Oop>) {
            for j in 0..<b.count {
                let holder = b.ptr[j]
                let h = om.header(holder)
                if hdrYoung(h) { continue } // traced if reachable
                if !hdrIsBytes(h) { for i in 0..<hdrSlots(h) { visit(om.slot(holder, i)) } }
                drainV()
            }
        }
        for n in 0..<maxNurseries { holders(x.pointee.rem[n]) }
        holders(nurOf(vm, k).pointee.carried)
    }
    return seen.count
}

/// After a scavenge or full collection: young objects only in a survivor
/// space with an age below N and in a young log; no old body in a nursery;
/// every old holder of a young object remembered; no pointer to a free
/// entry; each reachable young object copied exactly once.
private func postVerify(_ vm: VMRef, expected: Int?, copied: UInt64) {
    let om = vm.pointee.om
    let sp = vm.pointee.space
    let heap = vm.pointee.heap
    let rem = sp.rem
    if let e = expected, UInt64(e) != copied {
        failure(vm, "copied \(copied) objects, \(e) were reachable")
    }
    var logged = Set<Int>()
    var ranges: [(UInt, UInt)] = []
    for k in 0..<vm.pointee.workerCount {
        let x = worker(vm, k)
        let nur = nurOf(vm, k)
        for j in 0..<nur.pointee.survLogWord.count {
            var b = nur.pointee.survLogBits.ptr[j]
            while b != 0 { logged.insert(Int(nur.pointee.survLogWord.ptr[j]) * 64 + b.trailingZeroBitCount); b &= b - 1 }
        }
        if nur.pointee.survBytes > 0 {
            ranges.append((nur.pointee.survStart(1 &- nur.pointee.survTo), nur.pointee.survFromTop))
        }
        for n in 0..<maxNurseries {
            for j in 0..<x.pointee.rem[n].count {
                let holder = x.pointee.rem[n].ptr[j]
                if rem[Int(holder >> 4)].load(ordering: .relaxed) & (UInt32(1) << UInt32(n)) == 0 { failure(vm, "remembered holder \(holder) has no bit for nursery \(n)") }
            }
        }
    }
    let ageN = vm.pointee.cmConfig.ageN
    forEachUsed(vm) { idx, e in
        let h = om.header(UInt64(idx) << 4)
        if h == 0 { failure(vm, "used entry \(idx) has no header"); return }
        let addr = om.heap &+ UInt(e[1])
        if hdrYoung(h) {
            if !ranges.contains(where: { addr >= $0.0 && addr < $0.1 }) { failure(vm, "young entry \(idx) not in a survivor space") }
            let a = hdrAge(h)
            if a < 1 || a >= ageN { failure(vm, "young entry \(idx) has age \(a) with N = \(ageN)") }
            if !logged.contains(idx) { failure(vm, "young entry \(idx) is in no young log") }
        } else if heap.inNurseries(addr) {
            failure(vm, "old entry \(idx) body in a nursery")
        }
        if hdrIsBytes(h) || pendingDead(vm, idx) { return }
        let o = UInt64(idx) << 4
        for i in 0..<hdrSlots(h) {
            let v = om.slot(o, i)
            if v & 1 == 0 && v != 0 && !isUsed(sp, v) {
                failure(vm, "entry \(idx) (class \(hdrClass(h))) slot \(i) names free entry \(v)")
            } else if v & 1 == 0 && v != 0 && !hdrYoung(h) && hdrYoung(om.header(v))
                        && rem[idx].load(ordering: .relaxed) & (UInt32(1) << UInt32(hdrNursery(om.header(v)))) == 0 {
                failure(vm, "old \(o) slot \(i) holds survivor \(v) but is not remembered")
            }
        }
    }
    for (p, c) in rootRanges(vm) {
        for i in 0..<c where p[i] & 1 == 0 && p[i] != 0 && !isUsed(sp, p[i]) {
            failure(vm, "root word names free entry \(p[i])")
        }
    }
}
