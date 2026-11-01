// VM state, workers, metrics, and the stop-the-world protocol (SPEC.md
// "Safepoint operations"). Shared by every variant; the variant supplies `OM`
// (accessor view), `Space` (its object-memory state), `WorkerSpace`,
// `collect`, `performOp` and `alloc` in Memory.swift.

import Darwin
import Synchronization

public let cacheSize = 1024
public let stackWords = 64 * 1024

public struct CacheEntry {
    var cls: UInt64 = 0
    var sel: UInt64 = 0
    var method: UInt64 = 0
}

/// Per-worker state. Owned by its thread while running; read by the stopping
/// worker only while the owner is parked. Lives in raw memory.
public struct Worker {
    public var id: Int
    public var stack: UnsafeMutablePointer<UInt64>
    public var stackEnd: UnsafeMutablePointer<UInt64>
    public var sp: UnsafeMutablePointer<UInt64>
    /// Flushed at every park point (poll, primitive call). `hdr == nil`: the
    /// worker is not inside the interpreter.
    public var pc: UInt = 0
    public var hdr: UnsafeMutablePointer<UInt64>? = nil
    /// Set by a moving operation: re-derive pc and lits on resume.
    public var moved = false
    public var tlab = Tlab()
    public var ws = WorkerSpace()
    public var cache: UnsafeMutablePointer<CacheEntry>
    public var misses: UInt64 = 0
    public var parkedNs: UInt64 = 0
    public var tlabRefills: UInt64 = 0

    public static func create(id: Int, nilObj: Oop) -> UnsafeMutablePointer<Worker> {
        let stack = UnsafeMutablePointer<UInt64>.allocate(capacity: stackWords)
        stack.initialize(repeating: nilObj, count: stackWords)
        let cache = UnsafeMutablePointer<CacheEntry>.allocate(capacity: cacheSize)
        cache.initialize(repeating: CacheEntry(), count: cacheSize)
        // Each worker on its own 128-byte cache lines (M2 line size): workers
        // write their struct on every primitive call, and adjacent mallocs
        // falsely shared lines (found by the 8-worker sends numbers).
        let bytes = (MemoryLayout<Worker>.stride + 127) & ~127
        let w = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 128).bindMemory(to: Worker.self, capacity: 1)
        w.initialize(to: Worker(id: id, stack: stack, stackEnd: stack + stackWords, sp: stack, cache: cache))
        return w
    }
}

/// Minimal growable buffer of words in raw memory (roots, mark stack).
public struct WordStack {
    public var ptr: UnsafeMutablePointer<UInt64>
    public var count = 0
    var cap: Int

    init(capacity: Int) {
        ptr = .allocate(capacity: capacity)
        cap = capacity
    }

    @inline(__always) mutating func push(_ v: UInt64) {
        if count == cap { grow() }
        ptr[count] = v
        count &+= 1
    }

    @inline(never) mutating func grow() {
        let n = UnsafeMutablePointer<UInt64>.allocate(capacity: cap * 2)
        n.moveInitialize(from: ptr, count: count)
        ptr.deallocate()
        ptr = n
        cap *= 2
    }

    @inline(__always) mutating func pop() -> UInt64? {
        if count == 0 { return nil }
        count &-= 1
        return ptr[count]
    }
}

/// Counters and timings, printed as key=value by the bench.
public enum Metric: Int, CaseIterable {
    case gcCount, gcNs, markNs, sweepNs, liveBytes
    case gc1Ns, gc1MarkNs, gc1SweepNs, gc2Ns, gc2MarkNs, gc2SweepNs, gc3Ns, gc3MarkNs, gc3SweepNs
    case stwCount, stwNs, ttspNs, parkedNs
    case becomeCount, becomeSwapPath, becomeFwdPath, becomeOpNs, becomeStwNs, becomeWallNs
    case forwardPairs, forwardOpNs, forwardStwNs, forwardWallNs, forwardScanSlots
    case reshapeCount, reshapeOpNs, reshapeStwNs, reshapeWallNs
    case compactMarkNs, compactPlanNs, compactUpdateNs, compactMoveNs, compactSweepNs, compactOpNs, compactStwNs
    case compactBytesMoved, compactObjectsMoved, compactLiveBytes, compactSlotsUpdated, compactPcsFixed
    case snapSaveNs, snapSaveStwNs, snapBytes
    case snapLoadNs, snapRelocNs, snapRelocSlots, snapRelocRoots, snapWordsChanged, snapEntriesScanned
    case entryRefills, tlabRefills
}

public enum SafeOp {
    case gc(Int)
    case become(Oop, Oop)
    case forward(Oop, Oop)
    case reshape(Oop)
    case compact(Int)
    case snapshot
}

/// Everything the interpreter and GC touch. A plain struct of trivial fields
/// in raw memory, so no ARC traffic reaches the hot path.
public struct VMCore: ~Copyable {
    public var heap: Heap
    public var om: OM
    public var space: Space
    public var opTlab = Tlab()
    public var classTable: UnsafeMutablePointer<Oop>
    public var classCount = 0
    public var nilObj: Oop = 0
    public var trueObj: Oop = 0
    public var falseObj: Oop = 0
    public var special: UnsafeMutablePointer<Oop>
    public var globals: UnsafeMutablePointer<Oop>
    public var roots: WordStack
    var markStack: WordStack
    public let gcRequested: Atomic<Bool>
    public let stopFlag: Atomic<Bool>
    var mutex: UnsafeMutablePointer<pthread_mutex_t>
    var cond: UnsafeMutablePointer<pthread_cond_t>
    var active = 0
    var parked = 0
    var epoch: UInt64 = 0
    var workers: UnsafeMutablePointer<UnsafeMutablePointer<Worker>>?
    var workerCount = 0
    public var metrics: UnsafeMutablePointer<UInt64>
    public var snapshotPath: String = ""
    /// Host-side symbol names in intern order; symbol i is roots[3 + i].
    public var symbolNames: [String] = []
    public var verboseGC = false

    public static func create(heapSize: Int) -> UnsafeMutablePointer<VMCore> {
        let ct = UnsafeMutablePointer<Oop>.allocate(capacity: classTableSize)
        ct.initialize(repeating: 0, count: classTableSize)
        let special = UnsafeMutablePointer<Oop>.allocate(capacity: 9)
        special.initialize(repeating: 0, count: 9)
        let globals = UnsafeMutablePointer<Oop>.allocate(capacity: globalCount)
        globals.initialize(repeating: 0, count: globalCount)
        let metrics = UnsafeMutablePointer<UInt64>.allocate(capacity: Metric.allCases.count)
        metrics.initialize(repeating: 0, count: Metric.allCases.count)
        let m = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
        pthread_mutex_init(m, nil)
        let c = UnsafeMutablePointer<pthread_cond_t>.allocate(capacity: 1)
        pthread_cond_init(c, nil)
        let heap = Heap(size: heapSize)
        let (om, space) = makeSpace(heap)
        let vm = UnsafeMutablePointer<VMCore>.allocate(capacity: 1)
        vm.initialize(to: VMCore(heap: heap, om: om, space: space, classTable: ct, special: special,
                                 globals: globals, roots: WordStack(capacity: 256),
                                 markStack: WordStack(capacity: 1 << 16),
                                 gcRequested: Atomic(false), stopFlag: Atomic(false),
                                 mutex: m, cond: c, metrics: metrics))
        return vm
    }
}

public typealias VMRef = UnsafeMutablePointer<VMCore>
public typealias WorkerRef = UnsafeMutablePointer<Worker>

extension UnsafeMutablePointer where Pointee == VMCore {
    @inline(__always) func add(_ m: Metric, _ v: UInt64) { pointee.metrics[m.rawValue] &+= v }
    @inline(__always) func set(_ m: Metric, _ v: UInt64) { pointee.metrics[m.rawValue] = v }
    public func metric(_ m: Metric) -> UInt64 { pointee.metrics[m.rawValue] }
}

@inline(__always) func classAt(_ vm: VMRef, _ idx: UInt64) -> Oop {
    vm.pointee.classTable[Int(truncatingIfNeeded: idx)]
}

/// Register workers and set the active count. Call before starting threads.
public func setWorkers(_ vm: VMRef, _ ws: [WorkerRef]) {
    let p = UnsafeMutablePointer<WorkerRef>.allocate(capacity: max(ws.count, 1))
    for (i, w) in ws.enumerated() { p[i] = w }
    vm.pointee.workers = p
    vm.pointee.workerCount = ws.count
    pthread_mutex_lock(vm.pointee.mutex)
    vm.pointee.active = ws.count
    vm.pointee.parked = 0
    pthread_mutex_unlock(vm.pointee.mutex)
}

/// Every root word, as (pointer, count) ranges. World stopped.
func rootRanges(_ vm: VMRef) -> [(UnsafeMutablePointer<Oop>, Int)] {
    var r: [(UnsafeMutablePointer<Oop>, Int)] = [
        (vm.pointee.roots.ptr, vm.pointee.roots.count),
        (vm.pointee.globals, globalCount),
        (vm.pointee.special, 9),
        (vm.pointee.classTable + 1, max(0, vm.pointee.classCount - 1)),
    ]
    if let ws = vm.pointee.workers {
        for i in 0..<vm.pointee.workerCount {
            let w = ws[i]
            r.append((w.pointee.stack, (w.pointee.sp - w.pointee.stack) + 1))
        }
    }
    return r
}

/// Empty every worker's lookup cache (its keys and values are oops).
func flushMethodCaches(_ vm: VMRef) {
    guard let ws = vm.pointee.workers else { return }
    for i in 0..<vm.pointee.workerCount {
        ws[i].pointee.cache.update(repeating: CacheEntry(), count: cacheSize)
    }
}

/// Called at a poll when `gcRequested` was seen set. Regs already flushed.
@inline(never)
func safepoint(_ vm: VMRef, _ w: WorkerRef) {
    vm.pointee.heap.retire(&w.pointee.tlab)
    pthread_mutex_lock(vm.pointee.mutex)
    park(vm, w)
    pthread_mutex_unlock(vm.pointee.mutex)
}

/// Mutex held.
private func park(_ vm: VMRef, _ w: WorkerRef) {
    if !vm.pointee.gcRequested.load(ordering: .acquiring) { return }
    let t0 = now()
    let epoch = vm.pointee.epoch
    vm.pointee.parked += 1
    pthread_cond_broadcast(vm.pointee.cond)
    while vm.pointee.epoch == epoch {
        pthread_cond_wait(vm.pointee.cond, vm.pointee.mutex)
    }
    vm.pointee.parked -= 1
    let dt = now() &- t0
    w.pointee.parkedNs &+= dt
    vm.add(.parkedNs, dt)
}

/// Stop the world and run `op`. If another worker is already stopping it,
/// park; then return nil (`retry == false`, the allocation GC case) or try
/// again. `w`'s sp/pc/hdr must be flushed.
@discardableResult
func stopWorld(_ vm: VMRef, _ w: WorkerRef, _ op: SafeOp, retry: Bool) -> Oop? {
    let tw = now()
    vm.pointee.heap.retire(&w.pointee.tlab)
    pthread_mutex_lock(vm.pointee.mutex)
    while vm.pointee.gcRequested.load(ordering: .acquiring) {
        park(vm, w)
        if !retry {
            pthread_mutex_unlock(vm.pointee.mutex)
            return nil
        }
    }
    let t0 = now()
    vm.pointee.gcRequested.store(true, ordering: .releasing)
    while vm.pointee.parked + 1 < vm.pointee.active {
        pthread_cond_wait(vm.pointee.cond, vm.pointee.mutex)
    }
    let t1 = now()
    let res = performOp(vm, w, op)
    vm.pointee.heap.retire(&vm.pointee.opTlab)
    let t2 = now()
    vm.pointee.gcRequested.store(false, ordering: .releasing)
    vm.pointee.epoch += 1
    pthread_cond_broadcast(vm.pointee.cond)
    pthread_mutex_unlock(vm.pointee.mutex)
    let t3 = now()
    vm.add(.stwCount, 1)
    vm.add(.stwNs, t2 &- t0)
    vm.add(.ttspNs, t1 &- t0)
    switch op {
    case .become:
        vm.add(.becomeCount, 1); vm.add(.becomeOpNs, t2 &- t1); vm.add(.becomeStwNs, t2 &- t0); vm.add(.becomeWallNs, t3 &- tw)
    case .forward:
        vm.add(.forwardOpNs, t2 &- t1); vm.add(.forwardStwNs, t2 &- t0); vm.add(.forwardWallNs, t3 &- tw)
    case .reshape:
        vm.add(.reshapeOpNs, t2 &- t1); vm.add(.reshapeStwNs, t2 &- t0); vm.add(.reshapeWallNs, t3 &- tw)
    case .compact:
        vm.add(.compactOpNs, t2 &- t1); vm.add(.compactStwNs, t2 &- t0)
    case .snapshot:
        vm.add(.snapSaveStwNs, t2 &- t0)
    case .gc:
        break
    }
    return res
}

/// Allocation found no free block: collect, or park while someone else does.
func requestGC(_ vm: VMRef, _ w: WorkerRef) {
    stopWorld(vm, w, .gc(0), retry: false)
}

/// A worker leaves the VM (its thread is done running Smalltalk).
public func workerFinished(_ vm: VMRef, _ w: WorkerRef) {
    vm.pointee.heap.retire(&w.pointee.tlab)
    w.pointee.hdr = nil
    pthread_mutex_lock(vm.pointee.mutex)
    vm.pointee.active -= 1
    pthread_cond_broadcast(vm.pointee.cond)
    pthread_mutex_unlock(vm.pointee.mutex)
}

/// Full non-moving collection with timing; `tag` 1..3 also records into gcN metrics.
func timedCollect(_ vm: VMRef, tag: Int) {
    let t0 = now()
    let (mark, sweep) = collect(vm)
    let ns = now() &- t0
    vm.add(.gcCount, 1)
    vm.add(.gcNs, ns)
    vm.add(.markNs, mark)
    vm.add(.sweepNs, sweep)
    switch tag {
    case 1: vm.set(.gc1Ns, ns); vm.set(.gc1MarkNs, mark); vm.set(.gc1SweepNs, sweep)
    case 2: vm.set(.gc2Ns, ns); vm.set(.gc2MarkNs, mark); vm.set(.gc2SweepNs, sweep)
    case 3: vm.set(.gc3Ns, ns); vm.set(.gc3MarkNs, mark); vm.set(.gc3SweepNs, sweep)
    default: break
    }
    if vm.pointee.verboseGC {
        FileHandleStderr.write("gc: \(vm.pointee.heap.freeBlocks()) free blocks, \(vm.metric(.liveBytes)) live bytes, \(Double(ns) / 1e6) ms\n")
    }
}
