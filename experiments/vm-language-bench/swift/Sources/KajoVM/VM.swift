// VM state, workers, allocation slow path, safepoints and GC driver.

import Darwin
import Synchronization

public let cacheSize = 1024
public let stackWords = 64 * 1024

public struct CacheEntry {
    var cls: UInt64 = 0
    var sel: UInt64 = 0
    var method: UInt64 = 0
}

/// Per-worker state. Owned by its thread while running; the GC reads `stack`
/// and `sp` only while the owner is parked. Lives in raw memory.
public struct Worker {
    public var id: Int
    public var stack: UnsafeMutablePointer<UInt64>
    public var stackEnd: UnsafeMutablePointer<UInt64>
    public var sp: UnsafeMutablePointer<UInt64>
    public var tlab = Tlab()
    public var cache: UnsafeMutablePointer<CacheEntry>
    public var misses: UInt64 = 0

    public static func create(id: Int, nilObj: Oop) -> UnsafeMutablePointer<Worker> {
        let stack = UnsafeMutablePointer<UInt64>.allocate(capacity: stackWords)
        stack.initialize(repeating: nilObj, count: stackWords)
        let cache = UnsafeMutablePointer<CacheEntry>.allocate(capacity: cacheSize)
        cache.initialize(repeating: CacheEntry(), count: cacheSize)
        let w = UnsafeMutablePointer<Worker>.allocate(capacity: 1)
        w.initialize(to: Worker(id: id, stack: stack, stackEnd: stack + stackWords, sp: stack, cache: cache))
        return w
    }

    public static func destroy(_ w: UnsafeMutablePointer<Worker>) {
        w.pointee.stack.deallocate()
        w.pointee.cache.deallocate()
        w.deinitialize(count: 1)
        w.deallocate()
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

/// Everything the interpreter and GC touch. A plain struct of trivial fields
/// in raw memory, so no ARC traffic and no exclusivity checks reach the hot path.
public struct VMCore: ~Copyable {
    public var heap: Heap
    public var classTable: UnsafeMutablePointer<Oop>
    public var classCount = 0
    public var nilObj: Oop = 0
    public var trueObj: Oop = 0
    public var falseObj: Oop = 0
    public var special: UnsafeMutablePointer<Oop>
    public var roots: WordStack
    var markStack: WordStack
    public let gcRequested: Atomic<Bool>
    var mutex: UnsafeMutablePointer<pthread_mutex_t>
    var cond: UnsafeMutablePointer<pthread_cond_t>
    var active = 0
    var parked = 0
    var epoch: UInt64 = 0
    var workers: UnsafeMutablePointer<UnsafeMutablePointer<Worker>>?
    var workerCount = 0
    public var gcCount: UInt64 = 0
    public var gcNanos: UInt64 = 0
    public var verboseGC = false

    public static func create(heapSize: Int) -> UnsafeMutablePointer<VMCore> {
        let ct = UnsafeMutablePointer<Oop>.allocate(capacity: classTableSize)
        ct.initialize(repeating: 0, count: classTableSize)
        let special = UnsafeMutablePointer<Oop>.allocate(capacity: 9)
        special.initialize(repeating: 0, count: 9)
        let m = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
        pthread_mutex_init(m, nil)
        let c = UnsafeMutablePointer<pthread_cond_t>.allocate(capacity: 1)
        pthread_cond_init(c, nil)
        let vm = UnsafeMutablePointer<VMCore>.allocate(capacity: 1)
        vm.initialize(to: VMCore(heap: Heap(size: heapSize), classTable: ct, special: special,
                                 roots: WordStack(capacity: 256), markStack: WordStack(capacity: 1 << 16),
                                 gcRequested: Atomic(false), mutex: m, cond: c))
        return vm
    }
}

public typealias VMRef = UnsafeMutablePointer<VMCore>
public typealias WorkerRef = UnsafeMutablePointer<Worker>

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

/// Allocate an object; may stop the world. `w.sp` must be flushed.
@inline(__always)
public func alloc(_ vm: VMRef, _ w: WorkerRef, _ cls: UInt32, _ slots: Int, _ bytes: Bool) -> Oop {
    let o = tlabAlloc(&w.pointee.tlab, cls, slots, bytes, vm.pointee.nilObj)
    if o != 0 { return o }
    return allocSlow(vm, w, cls, slots, bytes)
}

@inline(never)
func allocSlow(_ vm: VMRef, _ w: WorkerRef, _ cls: UInt32, _ slots: Int, _ bytes: Bool) -> Oop {
    if sizeFor(slots, bytes) > blockSize { fatal("object larger than a block") }
    if !vm.pointee.heap.refill(&w.pointee.tlab) {
        requestGC(vm, w)
        if !vm.pointee.heap.refill(&w.pointee.tlab) { fatal("out of memory") }
    }
    return tlabAlloc(&w.pointee.tlab, cls, slots, bytes, vm.pointee.nilObj)
}

/// Called at a safepoint when `gcRequested` was seen set.
@inline(never)
func safepoint(_ vm: VMRef, _ w: WorkerRef) {
    vm.pointee.heap.retire(&w.pointee.tlab)
    pthread_mutex_lock(vm.pointee.mutex)
    park(vm)
    pthread_mutex_unlock(vm.pointee.mutex)
}

/// Mutex held.
private func park(_ vm: VMRef) {
    if !vm.pointee.gcRequested.load(ordering: .acquiring) { return }
    let epoch = vm.pointee.epoch
    vm.pointee.parked += 1
    pthread_cond_broadcast(vm.pointee.cond)
    while vm.pointee.epoch == epoch {
        pthread_cond_wait(vm.pointee.cond, vm.pointee.mutex)
    }
    vm.pointee.parked -= 1
}

/// Stop the world and collect (or park if someone else is collecting).
public func requestGC(_ vm: VMRef, _ w: WorkerRef) {
    vm.pointee.heap.retire(&w.pointee.tlab)
    pthread_mutex_lock(vm.pointee.mutex)
    defer { pthread_mutex_unlock(vm.pointee.mutex) }
    if vm.pointee.gcRequested.load(ordering: .acquiring) {
        park(vm)
        return
    }
    vm.pointee.gcRequested.store(true, ordering: .releasing)
    while vm.pointee.parked + 1 < vm.pointee.active {
        pthread_cond_wait(vm.pointee.cond, vm.pointee.mutex)
    }
    collect(vm)
    vm.pointee.gcRequested.store(false, ordering: .releasing)
    vm.pointee.epoch += 1
    pthread_cond_broadcast(vm.pointee.cond)
}

/// A worker leaves the VM (its thread is done running Smalltalk).
public func workerFinished(_ vm: VMRef, _ w: WorkerRef) {
    vm.pointee.heap.retire(&w.pointee.tlab)
    pthread_mutex_lock(vm.pointee.mutex)
    vm.pointee.active -= 1
    pthread_cond_broadcast(vm.pointee.cond)
    pthread_mutex_unlock(vm.pointee.mutex)
}

@inline(__always)
private func markValue(_ v: Oop, _ stack: inout WordStack) {
    if v & 1 == 0 {
        let p = objPtr(v)
        let h = p.pointee
        if !hdrMarked(h) {
            p.pointee = h | markBit
            if !hdrIsBytes(h) { stack.push(v) }
        }
    }
}

private func markRoots(_ roots: UnsafeMutablePointer<Oop>, _ n: Int, _ stack: inout WordStack) {
    for i in 0..<n { markValue(roots[i], &stack) }
    while let o = stack.pop() {
        let n = hdrSlots(header(o))
        let s = slotsPtr(o)
        var i = 0
        while i < n { markValue(s[i], &stack); i &+= 1 }
    }
}

/// Full mark-sweep. World must be stopped and all TLABs retired.
public func collect(_ vm: VMRef) {
    let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    markRoots(vm.pointee.roots.ptr, vm.pointee.roots.count, &vm.pointee.markStack)
    markRoots(vm.pointee.classTable + 1, max(0, vm.pointee.classCount - 1), &vm.pointee.markStack)
    if let ws = vm.pointee.workers {
        for i in 0..<vm.pointee.workerCount {
            let w = ws[i]
            markRoots(w.pointee.stack, (w.pointee.sp - w.pointee.stack) + 1, &vm.pointee.markStack)
        }
    }
    let (free, live) = vm.pointee.heap.sweep()
    let ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0
    vm.pointee.gcCount += 1
    vm.pointee.gcNanos += ns
    if vm.pointee.verboseGC {
        FileHandleStderr.write("gc: \(free) free blocks, \(live) live bytes, \(Double(ns) / 1e6) ms\n")
    }
}
