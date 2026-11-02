import Darwin
import Synchronization

// The nursery's state (docs/modules/nursery.md "Layouts"). One allocation
// per writer: a worker's allocation state (its own thread inside the VM;
// the stopper and one sweep task in a scavenge), a participant's scavenge
// state (that participant during the parallel phase, the stopper outside
// it), and the VM-wide state (the stopper; atomics during the phase).
// Writing different fields of one struct from two threads is a Swift
// exclusivity race to ThreadSanitizer (AGENTS.md), so nothing here is
// shared that way.

/// A worker's young allocation state, in its own 128-byte aligned lines.
/// The allocation fast path reads the first fields only.
@unsafe struct NurseryAlloc {
    /// Eden bump region: heap offsets.
    var top: UInt64
    var end: UInt64
    /// Bodies above this many bytes take the slow path (old allocation);
    /// 0 sends every allocation to the slow path (stress flags).
    var fastLimit: UInt64
    /// Young header bits of this nursery: young | index << 52.
    let youngMark: UInt64
    /// Free entries for young objects; `[0, next)` were handed out since
    /// the last scavenge (the entry sweep's input).
    var stash: EntryStash
    /// Holders this worker's barrier remembered (old objects naming a young
    /// one), and the holders a scavenge carried to it.
    var rem: RawArray<UInt64>
    /// Entries of the survivors in this nursery's survivor-from.
    var survLog: RawArray<UInt32>
    let index: Int
    let edenStart: UInt64
    /// Survivor halves: `survivorStart[survTo]` is survivor-to (empty
    /// between scavenges), the other is survivor-from, filled to
    /// `survFromTop`.
    let survivorStart: (UInt64, UInt64)
    var survTo: Int
    var survFromTop: UInt64
    /// The barrier site the test switch turns off (0: none).
    let skipSite: UInt8
    var barrierSlowCalls: UInt64 = 0
    /// Slow-path calls whose holder was young (never remembered).
    var barrierYoungHolders: UInt64 = 0
    var largeAllocations: UInt64 = 0
    /// Young allocations and bytes of finished cycles (the current cycle's
    /// are `stash.next` and `top - edenStart`).
    var youngAllocations: UInt64 = 0
    var youngBytes: UInt64 = 0
    var stashRefills: UInt64 = 0

    var survFromStart: UInt64 { unsafe survTo == 0 ? survivorStart.1 : survivorStart.0 }
    var survToStart: UInt64 { unsafe survTo == 0 ? survivorStart.0 : survivorStart.1 }
}

/// A scavenge participant's state (participant `index` is worker `index`).
@unsafe struct ScavengeWorker {
    /// Survivor-to bump of the participant's own nursery.
    var survCur: UInt64 = 0
    var survEnd: UInt64 = 0
    /// Copied objects whose slots are still to scan.
    var stack = RawArray<UInt64>()
    /// Holders this participant scanned that still name a young object.
    var nextRem = RawArray<UInt64>()
    /// Entries of the survivors it copied (into its survivor-to).
    var survLog = RawArray<UInt32>()
    /// Weak objects it scanned (their weak slots wait for the sweep).
    var weak = RawArray<UInt64>()
    var stats = ParticipantStats()
}

/// One participant's share of a scavenge.
struct ParticipantStats: Sendable {
    var promotedObjects: UInt64 = 0
    var promotedBytes: UInt64 = 0
    var survivedObjects: UInt64 = 0
    var survivedBytes: UInt64 = 0
    var overflowObjects: UInt64 = 0
    var overflowBytes: UInt64 = 0
    var remHolders: UInt64 = 0
    var remSlots: UInt64 = 0
    var entriesSwept: UInt64 = 0
    var entriesFreed: UInt64 = 0
    var packetsExported: UInt64 = 0
    var rootsNs: UInt64 = 0
    var remNs: UInt64 = 0
    var copyNs: UInt64 = 0
    var waitNs: UInt64 = 0
    var sweepNs: UInt64 = 0

    var copiedBytes: UInt64 { promotedBytes &+ survivedBytes }
    var busyNs: UInt64 { rootsNs &+ remNs &+ copyNs }
}

/// A copy task: root words, or a slice of remembered holders.
@unsafe struct ScavengeTask {
    var words: UnsafeMutablePointer<UInt64>
    var count: Int
    var remembered: Bool
}

/// What the participants read during the parallel phase: written by the
/// stopper before it opens (the safepoint mutex publishes it).
@unsafe struct ScavengePhase {
    var number: UInt64 = 0
    /// This scavenge's claim tag and the other one.
    var tag: UInt64 = 0
    var ageLimit: UInt64 = 2
    var promoteAll = false
    var tasks = unsafe RawArray<ScavengeTask>()
    /// Root values of this scavenge, the tasks' storage for roots.
    var roots = RawArray<UInt64>()
    /// Class formats (the class table does not change in a stop).
    var formats: UnsafeMutablePointer<UInt64>? = nil
    var classCount = 0
    var dropCarried = false
    var forgetPromoted = false
}

/// Counters of every scavenge so far (the stopper writes them).
struct NurseryCounters: Sendable {
    var scavenges: UInt64 = 0
    var promoteAllScavenges: UInt64 = 0
    var promotedObjects: UInt64 = 0
    var promotedBytes: UInt64 = 0
    var survivedObjects: UInt64 = 0
    var survivedBytes: UInt64 = 0
    var overflowObjects: UInt64 = 0
    var overflowBytes: UInt64 = 0
    var youngBytesScavenged: UInt64 = 0
    var rememberedHolders: UInt64 = 0
    var rememberedSlots: UInt64 = 0
    var entriesSwept: UInt64 = 0
    var entriesFreed: UInt64 = 0
    var weakSlotsNiled: UInt64 = 0
    var fullCollectionsRequested: UInt64 = 0
    var fullCollectionsRun: UInt64 = 0
    var verifierRuns: UInt64 = 0
    var scavengeNs: UInt64 = 0
    /// Summed per worker on read.
    var youngAllocations: UInt64 = 0
    var youngAllocatedBytes: UInt64 = 0
    var largeAllocations: UInt64 = 0
    var barrierSlowCalls: UInt64 = 0
    var barrierYoungHolders: UInt64 = 0
    var stashRefills: UInt64 = 0
}

/// One scavenge (docs/modules/nursery.md "Counters"). ns.
struct ScavengeRecord: Sendable {
    var number: UInt64 = 0
    var promoteAll = false
    var participants = 0
    var prepNs: UInt64 = 0
    var copyWallNs: UInt64 = 0
    var sweepWallNs: UInt64 = 0
    var finishNs: UInt64 = 0
    var verifyNs: UInt64 = 0
    /// From the stop's request to the end of the scavenge's work (the stop
    /// adds its release).
    var workNs: UInt64 = 0
    var timeToSafepointNs: UInt64 = 0
    var youngBytes: UInt64 = 0
    var promotedBytes: UInt64 = 0
    var survivedBytes: UInt64 = 0
    var overflowBytes: UInt64 = 0
    var remHolders: UInt64 = 0
    var remSlots: UInt64 = 0
    var entriesFreed: UInt64 = 0
    /// The critical participant: longest copy busy time, its split, and the
    /// longest entry sweep.
    var slowestParticipant = -1
    var critCopyBusyNs: UInt64 = 0
    var critRootsNs: UInt64 = 0
    var critRemNs: UInt64 = 0
    var maxSweepNs: UInt64 = 0
    /// Bytes copied and busy time of each participant (the copy rate per
    /// participant is their quotient).
    var copiedBytesPerParticipant: [UInt64] = []
    var busyNsPerParticipant: [UInt64] = []
    var packets: UInt64 = 0
}

/// The VM's nursery state.
@unsafe struct NurseryShared {
    let config: NurseryConfig
    let om: ObjectMemory
    let count: Int
    let regionStart: UInt64
    let stride: UInt64
    let edenBytes: UInt64
    let survivorBytes: UInt64
    let largeLimit: UInt64
    /// Per worker.
    let alloc: UnsafeMutablePointer<UnsafeMutablePointer<NurseryAlloc>>
    let scav: UnsafeMutablePointer<UnsafeMutablePointer<ScavengeWorker>>
    /// The remembered set's marker: 16 bits per entry beside the table,
    /// bit n = the holder names a young object of nursery n. Nonzero
    /// exactly while the holder is in one remembered buffer.
    let rem: UnsafeMutablePointer<Atomic<UInt16>>
    let remBytes: Int
    let phase: UnsafeMutablePointer<ScavengePhase>
    // Parallel-phase atomics, each in its own line.
    let taskNext: UnsafeMutablePointer<Atomic<Int>>
    let sweepNext: UnsafeMutablePointer<Atomic<Int>>
    let inCopy: UnsafeMutablePointer<Atomic<Int>>
    let idle: UnsafeMutablePointer<Atomic<Int>>
    let copyEnd: UnsafeMutablePointer<Atomic<UInt64>>
    let packets: UnsafeMutablePointer<PacketPool>
    let packetLock: UnsafeMutablePointer<pthread_mutex_t>
    let poolCount: UnsafeMutablePointer<Atomic<Int>>
    /// The stopper's: counters and the log.
    let state: UnsafeMutablePointer<NurseryLog>
    /// A scavenge left old space past its soft limit: the next poll, or the
    /// next scavenge request, runs a full collection instead.
    let fullRequested: UnsafeMutablePointer<Atomic<Bool>>

    static let rootTaskWords = 4096
    static let remTaskHolders = 256
    /// Below this many young bytes (and one remembered task) the stopper
    /// scavenges alone.
    static let soloYoungBytes: UInt64 = 64 << 10
}

/// Written by the stopper (with the world stopped) only.
struct NurseryLog {
    var counters = NurseryCounters()
    var records: [ScavengeRecord] = []
}

/// Exported work: packets of up to `words` oops, under `packetLock`.
@unsafe struct PacketPool {
    static let words = 256
    static let capacity = 64
    let storage: UnsafeMutablePointer<UInt64>
    let length: UnsafeMutablePointer<Int>
    var full = RawArray<Int32>()
    var free = RawArray<Int32>()
}

typealias NurseryPointer = UnsafeMutablePointer<NurseryShared>

extension UnsafeMutablePointer where Pointee == NurseryShared {
    @inline(__always)
    func alloc(_ i: Int) -> UnsafeMutablePointer<NurseryAlloc> { unsafe pointee.alloc[i] }
    @inline(__always)
    func scav(_ i: Int) -> UnsafeMutablePointer<ScavengeWorker> { unsafe pointee.scav[i] }
    @inline(__always)
    func remMarker(_ o: UInt64) -> UnsafeMutablePointer<Atomic<UInt16>> {
        unsafe pointee.rem + Int(truncatingIfNeeded: o &>> 4)
    }
}

// MARK: - creation

/// A value in its own 128-byte aligned allocation.
private func lined<T>(_ v: T) -> UnsafeMutablePointer<T> {
    let raw = UnsafeMutableRawPointer.allocate(byteCount: (MemoryLayout<T>.stride + 127) & ~127, alignment: 128)
    let p = unsafe raw.bindMemory(to: T.self, capacity: 1)
    unsafe p.initialize(to: v)
    return unsafe p
}

private func unlined<T: ~Copyable>(_ p: UnsafeMutablePointer<T>) {
    unsafe p.deinitialize(count: 1)
    unsafe UnsafeMutableRawPointer(p).deallocate()
}

private func atomicLine<T: AtomicRepresentable>(_ v: T) -> UnsafeMutablePointer<Atomic<T>> {
    let raw = UnsafeMutableRawPointer.allocate(byteCount: 128, alignment: 128)
    let p = unsafe raw.bindMemory(to: Atomic<T>.self, capacity: 1)
    unsafe p.initialize(to: Atomic(v))
    return unsafe p
}

extension NurseryShared {
    /// Nurseries for `workers` workers in a region reserved from `om`.
    static func make(_ requested: NurseryConfig, om: ObjectMemory, workers: Int) -> NurseryPointer {
        let config = requested.effective
        if let problem = config.validate(workers: workers) { preconditionFailure("nursery: \(problem)") }
        let stride = UInt64(config.stride)
        let eden = UInt64(config.edenBytes)
        let surv = UInt64(config.survivorHalf)
        let start = om.reserveNurseryRegion(bytes: Int(stride) * workers)
        let large = Swift.min(UInt64(config.largeObjectBytes), eden / 2)
        let alloc = UnsafeMutablePointer<UnsafeMutablePointer<NurseryAlloc>>.allocate(capacity: workers)
        let scav = UnsafeMutablePointer<UnsafeMutablePointer<ScavengeWorker>>.allocate(capacity: workers)
        let fastLimit = config.stress.contains(.scavengeAtEveryAllocation) || om.config.stress.contains(.collectAtEveryAllocation)
            ? 0 : large
        for i in 0..<workers {
            let base = start &+ UInt64(i) &* stride
            unsafe alloc[i] = lined(NurseryAlloc(
                top: base, end: base &+ eden, fastLimit: fastLimit,
                youngMark: Header.youngBit | UInt64(i) &<< Header.nurseryShift, stash: EntryStash(),
                rem: RawArray(), survLog: RawArray(), index: i, edenStart: base,
                survivorStart: (base &+ eden, base &+ eden &+ surv), survTo: 0, survFromTop: base &+ eden &+ surv,
                skipSite: config.testSwitches.skipBarrierAt?.rawValue ?? 0))
            unsafe om.registerStash(alloc[i].pointer(to: \NurseryAlloc.stash)!)
            unsafe scav[i] = lined(ScavengeWorker())
        }
        let remBytes = (Int(om.entryCapacity) * 2 + 16383) & ~16383
        let remRaw: UnsafeMutableRawPointer
        do { unsafe remRaw = try unsafe VirtualMemory.reserve(remBytes) } catch { preconditionFailure("nursery: \(error)") }
        // Zero-filled pages: every marker starts as Atomic(0).
        let rem = unsafe remRaw.bindMemory(to: Atomic<UInt16>.self, capacity: Int(om.entryCapacity))
        let storage = unsafe UnsafeMutablePointer<UInt64>.allocate(capacity: PacketPool.words * PacketPool.capacity)
        let length = unsafe UnsafeMutablePointer<Int>.allocate(capacity: PacketPool.capacity)
        unsafe length.initialize(repeating: 0, count: PacketPool.capacity)
        var pool = unsafe PacketPool(storage: storage, length: length)
        for i in unsafe 0..<PacketPool.capacity { unsafe pool.free.append(Int32(i)) }
        let s = unsafe lined(NurseryShared(
            config: config, om: om, count: workers, regionStart: start, stride: stride, edenBytes: eden,
            survivorBytes: surv, largeLimit: large, alloc: alloc, scav: scav, rem: rem, remBytes: remBytes,
            phase: lined(ScavengePhase()), taskNext: atomicLine(0), sweepNext: atomicLine(0), inCopy: atomicLine(0),
            idle: atomicLine(0), copyEnd: atomicLine(UInt64(0)), packets: lined(pool), packetLock: makeMutex(),
            poolCount: atomicLine(0), state: lined(NurseryLog()), fullRequested: atomicLine(false)))
        return unsafe s
    }

    static func destroy(_ n: NurseryPointer) {
        let s = unsafe n.pointee
        for i in unsafe 0..<s.count {
            let a = unsafe s.alloc[i]
            unsafe s.om.unregisterStash(a.pointer(to: \NurseryAlloc.stash)!)
            unsafe a.pointee.stash.free()
            unsafe a.pointee.rem.free()
            unsafe a.pointee.survLog.free()
            unsafe unlined(a)
            let w = unsafe s.scav[i]
            unsafe w.pointee.stack.free()
            unsafe w.pointee.nextRem.free()
            unsafe w.pointee.survLog.free()
            unsafe w.pointee.weak.free()
            unsafe unlined(w)
        }
        unsafe s.om.releaseNurseryPages(s.regionStart, Int(s.stride) * s.count)
        unsafe s.alloc.deallocate()
        unsafe s.scav.deallocate()
        unsafe VirtualMemory.release(UnsafeMutableRawPointer(s.rem), s.remBytes)
        unsafe s.phase.pointee.tasks.free()
        unsafe s.phase.pointee.roots.free()
        unsafe unlined(s.phase)
        unsafe s.packets.pointee.storage.deallocate()
        unsafe s.packets.pointee.length.deallocate()
        unsafe s.packets.pointee.full.free()
        unsafe s.packets.pointee.free.free()
        unsafe unlined(s.packets)
        unsafe freeMutex(s.packetLock)
        for unsafe p in unsafe [s.taskNext, s.sweepNext, s.inCopy, s.idle, s.poolCount] { unsafe unlined(p) }
        unsafe unlined(s.copyEnd)
        unsafe unlined(s.fullRequested)
        unsafe unlined(s.state)
        unsafe unlined(n)
    }
}
