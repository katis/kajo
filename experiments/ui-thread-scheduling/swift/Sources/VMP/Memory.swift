// Object memory, variant B of ../object-representation (copied): oop = byte
// offset of a 16-byte entry in an object table; the entry holds the header
// and the body's heap offset; the body starts with a back reference.
// Everything that knows how an oop reaches its object lives in this file.
// Non-moving: bodies never move, so frames may keep raw pcs across suspension.

import Darwin
import Synchronization

public let variantName = "B"
/// Shift applied to selector oops for cache and method-dict hashing (oops
/// are multiples of 16 here, so shifting by 3 would waste half the buckets).
let selShift: UInt64 = 4

public let tableEntries = 16 << 20
let runLength = 4096

// MARK: - oop -> entry -> body

/// The accessor view loaded once per interpreter run: the two bases.
public struct OM {
    var table: UInt
    var heap: UInt

    @inline(__always) func entry(_ o: Oop) -> UnsafeMutablePointer<UInt64> { wordPtr(table &+ UInt(truncatingIfNeeded: o)) }
    @inline(__always) func body(_ o: Oop) -> UnsafeMutablePointer<UInt64> { wordPtr(heap &+ UInt(truncatingIfNeeded: entry(o)[1])) }
    @inline(__always) public func header(_ o: Oop) -> UInt64 { entry(o).pointee }
    @inline(__always) func setHeader(_ o: Oop, _ h: UInt64) { entry(o).pointee = h }
    @inline(__always) public func slot(_ o: Oop, _ i: Int) -> Oop { body(o)[1 &+ i] }
    @inline(__always) public func setSlot(_ o: Oop, _ i: Int, _ v: Oop) { body(o)[1 &+ i] = v }
    @inline(__always) func slotsPtr(_ o: Oop) -> UnsafeMutablePointer<UInt64> { body(o) + 1 }
    @inline(__always) func bytesPtr(_ o: Oop) -> UnsafeMutablePointer<UInt8> {
        UnsafeMutableRawPointer(body(o) + 1).assumingMemoryBound(to: UInt8.self)
    }
    @inline(__always) public func classIndexOf(_ v: Oop) -> UInt64 {
        isInt(v) ? UInt64(ciSmallInt) : hdrClass(header(v))
    }
}

@inline(__always) func backref(_ index: UInt64, _ size: Int) -> UInt64 {
    (UInt64(size / 8) &<< 32) | index
}
@inline(__always) func backrefIndex(_ w: UInt64) -> UInt64 { w & 0xFFFF_FFFF }
@inline(__always) func backrefSize(_ w: UInt64) -> Int { Int(truncatingIfNeeded: w &>> 32) &* 8 }

/// Table bookkeeping: high-water mark and the pool of free-entry runs.
public struct Space {
    var hwm: UnsafeMutablePointer<Atomic<Int>>      // entry index, starts at 1
    var runs: UnsafeMutablePointer<UInt64>          // run heads (entry oops)
    var runCount: UnsafeMutablePointer<Atomic<Int>>
    var runNext: UnsafeMutablePointer<Atomic<Int>>
}

/// Per-worker free-entry list.
public struct WorkerSpace {
    var free: UInt64 = 0
    var refills: UInt64 = 0
}

func makeSpace(_ heap: Heap) -> (OM, Space) {
    guard let t = mmap(nil, tableEntries * 16, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), t != MAP_FAILED else {
        fatal("table mmap failed")
    }
    let hwm = UnsafeMutablePointer<Atomic<Int>>.allocate(capacity: 1)
    hwm.initialize(to: Atomic(1))
    let maxRuns = tableEntries / runLength + 2
    let runs = UnsafeMutablePointer<UInt64>.allocate(capacity: maxRuns * 2)
    let rc = UnsafeMutablePointer<Atomic<Int>>.allocate(capacity: 1)
    rc.initialize(to: Atomic(0))
    let rn = UnsafeMutablePointer<Atomic<Int>>.allocate(capacity: 1)
    rn.initialize(to: Atomic(0))
    return (OM(table: UInt(bitPattern: t), heap: heap.baseAddr), Space(hwm: hwm, runs: runs, runCount: rc, runNext: rn))
}

func entryRefills(_ w: WorkerRef) -> UInt64 { w.pointee.ws.refills }

// MARK: - allocation

/// Allocate an object; may stop the world. `w`'s sp/pc/hdr must be flushed.
@inline(__always)
public func alloc(_ vm: VMRef, _ w: WorkerRef, _ cls: UInt32, _ slots: Int, _ bytes: Bool) -> Oop {
    let size = sizeFor(slots, bytes)
    let e = w.pointee.ws.free
    let cur = w.pointee.tlab.cur
    if e != 0 && w.pointee.tlab.end &- cur >= UInt(size) {
        return initObject(vm.pointee.om, w, e, cur, cls, slots, bytes, size, vm.pointee.nilObj)
    }
    return allocSlow(vm, w, cls, slots, bytes)
}

@inline(__always)
private func initObject(_ om: OM, _ w: WorkerRef, _ e: Oop, _ cur: UInt, _ cls: UInt32, _ slots: Int,
                        _ bytes: Bool, _ size: Int, _ fill: Oop) -> Oop {
    let ent = om.entry(e)
    w.pointee.ws.free = ent[1]
    w.pointee.tlab.cur = cur &+ UInt(size)
    ent[0] = makeHeader(cls, slots, bytes)
    ent[1] = UInt64(cur &- om.heap)
    let p = wordPtr(cur)
    p[0] = backref(e &>> 4, size)
    let n = (size &- 8) / 8
    let f = bytes ? 0 : fill
    var i = 1
    while i <= n { p[i] = f; i &+= 1 }
    return e
}

@inline(never)
func allocSlow(_ vm: VMRef, _ w: WorkerRef, _ cls: UInt32, _ slots: Int, _ bytes: Bool) -> Oop {
    let size = sizeFor(slots, bytes)
    if size > blockSize { fatal("object larger than a block") }
    var gcs = 0
    while true {
        // Other workers' collections count too, and with several workers
        // contending for freed blocks one GC may not be enough (found by the
        // tests on a 2 MiB heap); variant B gave up after 3.
        if gcs > 32 { fatal("out of memory (worker \(w.pointee.id), \(vm.pointee.heap.freeBlocks()) free blocks, entries \(w.pointee.ws.free))") }
        if w.pointee.ws.free == 0 && !refillEntries(vm, w) {
            requestGC(vm, w); gcs += 1; continue
        }
        if w.pointee.tlab.end &- w.pointee.tlab.cur < UInt(size) {
            if !vm.pointee.heap.refill(&w.pointee.tlab) { requestGC(vm, w); gcs += 1; continue }
            w.pointee.tlabRefills &+= 1
        }
        if w.pointee.ws.free == 0 { continue } // a GC in between emptied the list
        return initObject(vm.pointee.om, w, w.pointee.ws.free, w.pointee.tlab.cur, cls, slots, bytes, size, vm.pointee.nilObj)
    }
}

/// Give the worker a run of free entries: from the pool, else fresh ones at
/// the high-water mark. Lock-free. False when the table is full.
private func refillEntries(_ vm: VMRef, _ w: WorkerRef) -> Bool {
    let sp = vm.pointee.space
    let om = vm.pointee.om
    let i = sp.runNext.pointee.wrappingAdd(1, ordering: .relaxed).oldValue
    if i < sp.runCount.pointee.load(ordering: .relaxed) {
        w.pointee.ws.free = sp.runs[i]
        w.pointee.ws.refills &+= 1
        return true
    }
    let start = sp.hwm.pointee.wrappingAdd(runLength, ordering: .relaxed).oldValue
    if start + runLength > tableEntries { return false }
    for k in start..<(start + runLength) {
        let e = om.entry(UInt64(k) &<< 4)
        e[0] = 0
        e[1] = k + 1 < start + runLength ? UInt64(k + 1) &<< 4 : 0
    }
    w.pointee.ws.free = UInt64(start) &<< 4
    w.pointee.ws.refills &+= 1
    return true
}

func retireBoot(_ vm: VMRef, _ w: WorkerRef) {
    vm.pointee.heap.retire(&w.pointee.tlab)
    w.pointee.ws.free = 0 // its entries are still free in the table; the next sweep pools them
}

@inline(__always) private func hwmNow(_ vm: VMRef) -> Int {
    min(vm.pointee.space.hwm.pointee.load(ordering: .relaxed), tableEntries)
}

// MARK: - mark & sweep

@inline(__always)
private func markSlot(_ om: OM, _ v: Oop, _ stack: inout WordStack) {
    if v & 1 != 0 || v == 0 { return } // 0: empty queue head or root slot
    let e = om.entry(v)
    let h = e.pointee
    if !hdrMarked(h) {
        e.pointee = h | markBit
        if !hdrIsBytes(h) { stack.push(v) }
    }
}

func markAll(_ vm: VMRef) {
    let om = vm.pointee.om
    for (p, c) in rootRanges(vm) {
        for i in 0..<c { markSlot(om, p[i], &vm.pointee.markStack) }
        while let o = vm.pointee.markStack.pop() {
            let n = hdrSlots(om.header(o))
            let s = om.slotsPtr(o)
            var i = 0
            while i < n { markSlot(om, s[i], &vm.pointee.markStack); i &+= 1 }
        }
    }
}

/// Table scan: unmark live entries (and flag their body's block when
/// `blocks`), free dead ones, rebuild the pool of free runs, drop every
/// worker's private list. Returns live bytes.
private func sweepTable(_ vm: VMRef, blocks: Bool) -> Int {
    let om = vm.pointee.om
    let sp = vm.pointee.space
    let heap = vm.pointee.heap
    let hwm = hwmNow(vm)
    var live = 0
    var head: UInt64 = 0
    var len = 0
    var runs = 0
    for idx in 1..<max(hwm, 1) {
        let o = UInt64(idx) &<< 4
        let e = om.entry(o)
        let h = e[0]
        if h != 0 && hdrMarked(h) {
            e[0] = h & ~markBit
            live &+= objectBytes(h)
            if blocks { heap.live[heap.blockOf(om.heap &+ UInt(e[1]))] = true }
            continue
        }
        e[0] = 0
        e[1] = head
        head = o
        len &+= 1
        if len == runLength { sp.runs[runs] = head; runs &+= 1; head = 0; len = 0 }
    }
    if len > 0 { sp.runs[runs] = head; runs &+= 1 }
    sp.runCount.pointee.store(runs, ordering: .relaxed)
    sp.runNext.pointee.store(0, ordering: .relaxed)
    if let ws = vm.pointee.workers {
        for i in 0..<vm.pointee.workerCount { ws[i].pointee.ws.free = 0 }
    }
    return live
}

/// Full non-moving mark-sweep. Returns (mark ns, sweep ns).
func collect(_ vm: VMRef) -> (UInt64, UInt64) {
    let t0 = now()
    markAll(vm)
    let t1 = now()
    let live = sweepTable(vm, blocks: true)
    _ = vm.pointee.heap.rebuildPool()
    let t2 = now()
    vm.set(.liveBytes, UInt64(live))
    return (t1 &- t0, t2 &- t1)
}

// MARK: - stop-the-world operations

/// Only the collector is left from variant B's operations (SPEC.md "Package
/// shape": become, reshape, compaction and snapshot are not needed here).
func performOp(_ vm: VMRef, _ w: WorkerRef, _ op: SafeOp) -> Oop {
    switch op {
    case .gc(let tag): timedCollect(vm, tag: tag)
    }
    return 0
}
