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
/// The allocation fast path reads the first fields only. Written by its
/// worker inside the VM (and by the stopper with the world stopped).
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
    /// the last collection of this eden (the entry sweep's input).
    var stash: EntryStash
    /// This worker's remembered buffers (`[0, 16)`, one per nursery) and
    /// deletion buffers (`[16, 32)`, module 7): written only by its own
    /// barrier, handed over at round acknowledgements under the safepoint
    /// mutex (module 7) or taken by the stopper.
    let buffers: UnsafeMutablePointer<RawArray<UInt64>>
    let index: Int
    /// The eden being allocated in: the whole eden, or (module 7, an
    /// offloaded nursery) the current half.
    var edenStart: UInt64
    /// The whole eden.
    let edenBase: UInt64
    let edenBytes: UInt64
    /// Module 7: the eden is two halves (an offloaded nursery); `half` is
    /// the one being allocated in, `halfBytes` its size.
    let halves: Bool
    var half: Int
    let halfBytes: UInt64
    /// Module 7: the barrier remembers a young holder of another nursery
    /// too (young collection without stopping the world); off in the
    /// stop-the-world configuration (module 4's rule: old holders only).
    let rememberYoungHolders: Bool
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
}

/// A nursery's survivor spaces and remembered lists (module 7 moved them
/// out of `NurseryAlloc`): written by whoever collects the nursery (its
/// owner, the young collector thread, one at a time) or by the stopper
/// with the world stopped. Never by the allocating worker.
@unsafe struct NurserySurvivors {
    /// Survivor halves: `survivorStart[survTo]` is survivor-to (empty
    /// between collections), the other is survivor-from, filled to
    /// `survFromTop`.
    let survivorStart: (UInt64, UInt64)
    var survTo: Int
    var survFromTop: UInt64
    /// Entries of the survivors in this nursery's survivor-from.
    var survLog = RawArray<UInt32>()
    /// Holders kept in this nursery's remembered set by its last
    /// collection (and every remembered holder after a stop-the-world
    /// scavenge).
    var carried = RawArray<UInt64>()
    /// Module 7: dead young entries whose free waits (amendments 10, 17).
    var deferred = RawArray<UInt64>()
    /// Module 7: the stash of the eden half being collected (offload): the
    /// owner swaps it with its own at a flip.
    var stash2 = unsafe EntryStash()
    /// Module 7: the collection in flight: survivor-to bump, the entries of
    /// the survivors it copied, the holders it keeps.
    var survCur: UInt64 = 0
    var nextLog = RawArray<UInt32>()
    var nextCarried = RawArray<UInt64>()

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
    /// Holders this participant scanned that still name a young object
    /// (their remembered bits set; carried to their nurseries at the end).
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
    /// The remembered holders of every nursery, once each (the tasks'
    /// storage for remembered holders).
    var holders = RawArray<UInt64>()
    /// Module 7: copied young objects are remembered for the other
    /// nurseries they name (young collection without stopping the world).
    var rememberYoung = false
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
    /// Module 7: young holders taken out of the remembered lists before a
    /// scavenge (amendment 12), and deferred entry frees a scavenge
    /// released.
    var youngHoldersDropped: UInt64 = 0
    var deferredReleased: UInt64 = 0
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
    /// Per buffer owner: a stopper outside the worker table takes part too.
    let scav: UnsafeMutablePointer<UnsafeMutablePointer<ScavengeWorker>>
    /// Per nursery (module 7).
    let surv: UnsafeMutablePointer<UnsafeMutablePointer<NurserySurvivors>>
    /// Every buffer owner's remembered and deletion buffers (32 per owner,
    /// `NurseryAlloc.buffers`): the workers, then the marker's slot (never
    /// used) and module 7's young collector thread.
    let buffers: UnsafeMutablePointer<UnsafeMutablePointer<RawArray<UInt64>>>
    let bufferOwners: Int
    /// Module 7: young collection without stopping the world is installed:
    /// young holders of other nurseries are in the remembered sets, and a
    /// stop-the-world scavenge remembers the survivors it copies for the
    /// other nurseries they name.
    let concurrent: Bool
    /// Module 7's test switch (on outside tests): a pause that releases
    /// deferred entry frees takes them from their nursery's list.
    let deferredOwnership: Bool
    /// The remembered word: 32 bits per entry beside the table. Bit n: the
    /// holder is in nursery n's remembered set (some owner's buffer n, or
    /// nursery n's carried list) because it names a young object of
    /// nursery n. Bit 16 + n (module 7, amendment 9): kept for nursery n's
    /// next collection, set only during n's collection and folded into
    /// bit n at its end.
    let rem: UnsafeMutablePointer<Atomic<UInt32>>
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
    func survivors(_ k: Int) -> UnsafeMutablePointer<NurserySurvivors> { unsafe pointee.surv[k] }
    @inline(__always)
    func remMarker(_ o: UInt64) -> UnsafeMutablePointer<Atomic<UInt32>> {
        unsafe pointee.rem + Int(truncatingIfNeeded: o &>> 4)
    }
    /// Owner `i`'s remembered buffer for nursery `n`.
    @inline(__always)
    func remBuffer(_ i: Int, _ n: Int) -> UnsafeMutablePointer<RawArray<UInt64>> { unsafe pointee.buffers[i] + n }
    /// Owner `i`'s deletion buffer for nursery `n` (module 7).
    @inline(__always)
    func delBuffer(_ i: Int, _ n: Int) -> UnsafeMutablePointer<RawArray<UInt64>> { unsafe pointee.buffers[i] + (16 &+ n) }
}

/// The remembered word's bits for nursery `n`: membership and pending.
@inline(__always)
func remBit(_ n: Int) -> UInt32 { 1 &<< UInt32(truncatingIfNeeded: n) }
@inline(__always)
func pendingBit(_ n: Int) -> UInt32 { 1 &<< UInt32(truncatingIfNeeded: 16 &+ n) }

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
    /// `offloaded`: nursery 0's eden is two halves (module 7); `youngHolders`:
    /// the barrier remembers young holders of other nurseries too.
    static func make(_ requested: NurseryConfig, om: ObjectMemory, workers: Int, offloaded: Bool = false,
                     youngHolders: Bool = false, concurrent: Bool = false, deferredOwnership: Bool = true,
                     halfBytes: Int = 0) -> NurseryPointer {
        let config = requested.effective
        if let problem = config.validate(workers: workers) { preconditionFailure("nursery: \(problem)") }
        let stride = UInt64(config.stride)
        let eden = UInt64(config.edenBytes)
        let surv = UInt64(config.survivorHalf)
        let start = om.reserveNurseryRegion(bytes: Int(stride) * workers)
        let large = Swift.min(UInt64(config.largeObjectBytes), eden / 2)
        let alloc = UnsafeMutablePointer<UnsafeMutablePointer<NurseryAlloc>>.allocate(capacity: workers)
        let survs = UnsafeMutablePointer<UnsafeMutablePointer<NurserySurvivors>>.allocate(capacity: workers)
        let owners = workers + 2
        let scav = UnsafeMutablePointer<UnsafeMutablePointer<ScavengeWorker>>.allocate(capacity: owners)
        for i in workers..<owners { unsafe scav[i] = lined(ScavengeWorker()) }
        let buffers = UnsafeMutablePointer<UnsafeMutablePointer<RawArray<UInt64>>>.allocate(capacity: owners)
        for i in 0..<owners {
            let raw = UnsafeMutableRawPointer.allocate(byteCount: (MemoryLayout<RawArray<UInt64>>.stride * 32 + 127) & ~127,
                                                       alignment: 128)
            let b = unsafe raw.bindMemory(to: RawArray<UInt64>.self, capacity: 32)
            unsafe b.initialize(repeating: RawArray(), count: 32)
            unsafe buffers[i] = b
        }
        let fastLimit = config.stress.contains(.scavengeAtEveryAllocation) || om.config.stress.contains(.collectAtEveryAllocation)
            ? 0 : large
        for i in 0..<workers {
            let base = start &+ UInt64(i) &* stride
            let halves = offloaded && i == 0
            let half = halves ? Swift.min(eden / 2, halfBytes > 0 ? UInt64(halfBytes) : eden / 2) & ~127 : eden
            unsafe alloc[i] = lined(NurseryAlloc(
                top: base, end: base &+ half, fastLimit: fastLimit,
                youngMark: Header.youngBit | UInt64(i) &<< Header.nurseryShift, stash: EntryStash(),
                buffers: buffers[i], index: i, edenStart: base, edenBase: base, edenBytes: eden,
                halves: halves, half: 0, halfBytes: half, rememberYoungHolders: youngHolders,
                skipSite: config.testSwitches.skipBarrierAt?.rawValue ?? 0))
            unsafe om.registerStash(alloc[i].pointer(to: \NurseryAlloc.stash)!)
            unsafe scav[i] = lined(ScavengeWorker())
            unsafe survs[i] = lined(NurserySurvivors(survivorStart: (base &+ eden, base &+ eden &+ surv), survTo: 0,
                                                     survFromTop: base &+ eden &+ surv))
            unsafe om.registerStash(survs[i].pointer(to: \NurserySurvivors.stash2)!)
        }
        let remBytes = (Int(om.entryCapacity) * 4 + 16383) & ~16383
        let remRaw: UnsafeMutableRawPointer
        do { unsafe remRaw = try unsafe VirtualMemory.reserve(remBytes) } catch { preconditionFailure("nursery: \(error)") }
        // Zero-filled pages: every remembered word starts as Atomic(0).
        let rem = unsafe remRaw.bindMemory(to: Atomic<UInt32>.self, capacity: Int(om.entryCapacity))
        let storage = unsafe UnsafeMutablePointer<UInt64>.allocate(capacity: PacketPool.words * PacketPool.capacity)
        let length = unsafe UnsafeMutablePointer<Int>.allocate(capacity: PacketPool.capacity)
        unsafe length.initialize(repeating: 0, count: PacketPool.capacity)
        var pool = unsafe PacketPool(storage: storage, length: length)
        for i in unsafe 0..<PacketPool.capacity { unsafe pool.free.append(Int32(i)) }
        let s = unsafe lined(NurseryShared(
            config: config, om: om, count: workers, regionStart: start, stride: stride, edenBytes: eden,
            survivorBytes: surv, largeLimit: large, alloc: alloc, scav: scav, surv: survs, buffers: buffers,
            bufferOwners: owners, concurrent: concurrent, deferredOwnership: deferredOwnership, rem: rem, remBytes: remBytes,
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
            unsafe unlined(a)
            let v = unsafe s.surv[i]
            unsafe s.om.unregisterStash(v.pointer(to: \NurserySurvivors.stash2)!)
            unsafe v.pointee.stash2.free()
            unsafe v.pointee.survLog.free()
            unsafe v.pointee.carried.free()
            unsafe v.pointee.deferred.free()
            unsafe v.pointee.nextLog.free()
            unsafe v.pointee.nextCarried.free()
            unsafe unlined(v)
        }
        for i in unsafe 0..<s.bufferOwners {
            let w = unsafe s.scav[i]
            unsafe w.pointee.stack.free()
            unsafe w.pointee.nextRem.free()
            unsafe w.pointee.survLog.free()
            unsafe w.pointee.weak.free()
            unsafe unlined(w)
        }
        for i in unsafe 0..<s.bufferOwners {
            for j in 0..<32 { unsafe s.buffers[i][j].free() }
            unsafe UnsafeMutableRawPointer(s.buffers[i]).deallocate()
        }
        unsafe s.buffers.deallocate()
        unsafe s.om.releaseNurseryPages(s.regionStart, Int(s.stride) * s.count)
        unsafe s.alloc.deallocate()
        unsafe s.scav.deallocate()
        unsafe s.surv.deallocate()
        unsafe VirtualMemory.release(UnsafeMutableRawPointer(s.rem), s.remBytes)
        unsafe s.phase.pointee.tasks.free()
        unsafe s.phase.pointee.roots.free()
        unsafe s.phase.pointee.holders.free()
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
