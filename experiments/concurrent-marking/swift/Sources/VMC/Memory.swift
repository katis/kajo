// Object memory: variant B's object table (oop = byte offset of a 16-byte
// entry holding the header and the body's heap offset; the body starts with a
// back reference), with entries allocated from chunk bitmaps, bodies from a
// per-worker nursery or old blocks, the write barrier, and the full
// mark-sweep (../generational-gc/SPEC.md "Entry allocation", "Write
// barrier", "Full collection"). The scavenge is in Scavenge.swift.
// This experiment adds the SATB barrier in front of every pointer store,
// makes slot stores relaxed atomics (a marker reads them concurrently), and
// takes bitmap words with an atomic exchange (the lazy sweeper clears bits
// concurrently) (SPEC.md "SATB barrier", "Lazy sweep").
// Everything that knows how an oop reaches its object lives in these files.

import Darwin
import Synchronization

public let variantName = "B"
/// Shift applied to selector oops for cache and method-dict hashing (oops
/// are multiples of 16 here, so shifting by 3 would waste half the buckets).
let selShift: UInt64 = 4

public let tableEntries = 16 << 20
/// Entries per chunk; one bitmap word covers 64 of them.
public let chunkEntries = 4096
let wordsPerChunk = chunkEntries / 64
public let maxChunks = tableEntries / chunkEntries

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
    /// Raw slot store: no barrier. A relaxed atomic store (a plain `str` on
    /// arm64), because a marker may be reading the slot (SPEC.md "SATB
    /// barrier"). VM code storing an oop over a pointer, or storing one that
    /// may be young, uses `store`.
    @inline(__always) public func setSlot(_ o: Oop, _ i: Int, _ v: Oop) {
        atomicWord(body(o) + (1 &+ i)).pointee.store(v, ordering: .relaxed)
    }
    /// Relaxed atomic slot load, for readers that run beside mutators (markers).
    @inline(__always) func slotLoad(_ o: Oop, _ i: Int) -> Oop {
        atomicWord(body(o) + (1 &+ i)).pointee.load(ordering: .relaxed)
    }
    @inline(__always) func slotsPtr(_ o: Oop) -> UnsafeMutablePointer<UInt64> { body(o) + 1 }
    @inline(__always) func bytesPtr(_ o: Oop) -> UnsafeMutablePointer<UInt8> {
        UnsafeMutableRawPointer(body(o) + 1).assumingMemoryBound(to: UInt8.self)
    }
    @inline(__always) public func classIndexOf(_ v: Oop) -> UInt64 {
        isInt(v) ? UInt64(ciSmallInt) : hdrClass(header(v))
    }
    @inline(__always) public func isYoung(_ v: Oop) -> Bool { !isInt(v) && v != 0 && hdrYoung(header(v)) }
}

/// The header word as an atomic, for the scavenge only (SPEC.md "Scavenge":
/// every scavenge-time header access is atomic). Mutators never write a
/// published header, so their plain loads do not race with each other.
@inline(__always) func atomicHeader(_ ent: UnsafeMutablePointer<UInt64>) -> UnsafeMutablePointer<Atomic<UInt64>> {
    UnsafeMutableRawPointer(ent).assumingMemoryBound(to: Atomic<UInt64>.self)
}

/// Any word as an atomic (slots, bitmap words).
@inline(__always) func atomicWord(_ p: UnsafeMutablePointer<UInt64>) -> UnsafeMutablePointer<Atomic<UInt64>> {
    UnsafeMutableRawPointer(p).assumingMemoryBound(to: Atomic<UInt64>.self)
}

@inline(__always) func backref(_ index: UInt64, _ size: Int) -> UInt64 {
    (UInt64(size / 8) &<< 32) | index
}

/// Table bookkeeping (SPEC.md "Entry allocation: chunks and bitmaps").
public struct Space {
    /// One bit per entry: in use or reserved. Written by the chunk's owner,
    /// or with the world stopped.
    var used: UnsafeMutablePointer<UInt64>
    /// One bit per entry: promoted by the current scavenge. Atomic.
    var surv: UnsafeMutablePointer<Atomic<UInt64>>
    /// One byte per entry: the holder sits in a remembered buffer. Atomic.
    var rem: UnsafeMutablePointer<Atomic<UInt8>>
    var chunkHwm: UnsafeMutablePointer<Atomic<Int>>
    var pool: UnsafeMutablePointer<UInt32>
    var poolScratch: UnsafeMutablePointer<UInt32>
    var poolCount: UnsafeMutablePointer<Atomic<Int>>
    var poolNext: UnsafeMutablePointer<Atomic<Int>>
    /// Scratch, one byte per chunk, zero between uses: deduplicates the pool.
    var inPool: UnsafeMutablePointer<UInt8>
}

/// Per-worker entry allocation state.
public struct WorkerSpace {
    /// Reserved free bits of the current bitmap word.
    var entFree: UInt64 = 0
    /// Oop of the entry for bit 0 of the current word.
    var entBase: UInt64 = 0
    var entWord = -1
    var chunk = -1
    var cursor = wordsPerChunk
    var wordTakes: UInt64 = 0
    var bitsTaken: UInt64 = 0
    var chunkTakes: UInt64 = 0
    var chunkFresh: UInt64 = 0
}

private func zeroMap(_ bytes: Int) -> UnsafeMutableRawPointer {
    guard let p = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), p != MAP_FAILED else {
        fatal("mmap failed")
    }
    return p
}

func makeSpace(_ heap: Heap) -> (OM, Space) {
    let t = zeroMap(tableEntries * 16)
    let used = zeroMap(tableEntries / 8).bindMemory(to: UInt64.self, capacity: tableEntries / 64)
    used[0] = 1 // entry 0 is never handed out: oop 0 means "none"
    let surv = zeroMap(tableEntries / 8).bindMemory(to: Atomic<UInt64>.self, capacity: tableEntries / 64)
    let rem = zeroMap(tableEntries).bindMemory(to: Atomic<UInt8>.self, capacity: tableEntries)
    func counter() -> UnsafeMutablePointer<Atomic<Int>> {
        let p = UnsafeMutablePointer<Atomic<Int>>.allocate(capacity: 1)
        p.initialize(to: Atomic(0))
        return p
    }
    let pool = UnsafeMutablePointer<UInt32>.allocate(capacity: maxChunks)
    let scratch = UnsafeMutablePointer<UInt32>.allocate(capacity: maxChunks)
    return (OM(table: UInt(bitPattern: t), heap: heap.baseAddr),
            Space(used: used, surv: surv, rem: rem, chunkHwm: counter(), pool: pool, poolScratch: scratch,
                  poolCount: counter(), poolNext: counter(),
                  inPool: zeroMap(maxChunks).bindMemory(to: UInt8.self, capacity: maxChunks)))
}

@inline(__always) func chunkHwmNow(_ vm: VMRef) -> Int {
    min(vm.pointee.space.chunkHwm.pointee.load(ordering: .relaxed), maxChunks)
}

// MARK: - allocation

/// Allocate an object; may stop the world. `w`'s sp/pc/hdr must be flushed.
@inline(__always)
public func alloc(_ vm: VMRef, _ w: WorkerRef, _ cls: UInt32, _ slots: Int, _ bytes: Bool) -> Oop {
    let size = sizeFor(slots, bytes)
    let free = w.pointee.ws.entFree
    let cur = w.pointee.tlab.cur
    if free != 0 && w.pointee.tlab.end &- cur >= UInt(size) {
        return initObject(vm.pointee.om, w, free, cur, cls, slots, bytes, size, vm.pointee.nilObj)
    }
    return allocSlow(vm, w, cls, slots, bytes)
}

@inline(__always)
private func initObject(_ om: OM, _ w: WorkerRef, _ free: UInt64, _ cur: UInt, _ cls: UInt32, _ slots: Int,
                        _ bytes: Bool, _ size: Int, _ fill: Oop) -> Oop {
    let bit = UInt64(truncatingIfNeeded: free.trailingZeroBitCount)
    w.pointee.ws.entFree = free & (free &- 1)
    let e = w.pointee.ws.entBase &+ (bit &<< 4)
    let ent = om.entry(e)
    w.pointee.tlab.cur = cur &+ UInt(size)
    ent[0] = makeHeader(cls, slots, bytes) | w.pointee.youngMark
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
        // Other workers' collections count too (each resets this worker's
        // nursery, so one is normally enough).
        if gcs > 32 { fatal("out of memory (worker \(w.pointee.id), \(vm.pointee.heap.freeBlocks()) free blocks)") }
        if w.pointee.ws.entFree == 0 && !refillEntries(vm, w) {
            requestGC(vm, w, .full); gcs += 1; continue
        }
        if w.pointee.tlab.end &- w.pointee.tlab.cur < UInt(size) {
            if !refillTlab(vm, w, size) {
                requestGC(vm, w, w.pointee.youngMark != 0 ? .scavenge : .full); gcs += 1; continue
            }
        }
        if w.pointee.ws.entFree == 0 { continue } // a GC in between released the reservation
        return initObject(vm.pointee.om, w, w.pointee.ws.entFree, w.pointee.tlab.cur, cls, slots, bytes, size, vm.pointee.nilObj)
    }
}

/// Generational worker: the TLAB is the rest of its nursery (resumed at
/// `nurseryTop` after a park retired it); false when the nursery is full.
/// Otherwise a fresh old block under the soft limit.
private func refillTlab(_ vm: VMRef, _ w: WorkerRef, _ size: Int) -> Bool {
    if w.pointee.youngMark != 0 {
        if w.pointee.tlab.end == 0 {
            w.pointee.tlab.cur = w.pointee.nurseryTop
            w.pointee.tlab.end = w.pointee.nurseryEnd
        }
        return w.pointee.tlab.end &- w.pointee.tlab.cur >= UInt(size)
    }
    if !vm.pointee.heap.refill(&w.pointee.tlab) { return false }
    w.pointee.tlabRefills &+= 1
    return true
}

/// Retire the worker's allocation buffer (at a park or a stop): a nursery
/// buffer keeps its bump position in `nurseryTop`.
func retireTlab(_ vm: VMRef, _ w: WorkerRef) {
    if w.pointee.tlab.block == noBlock {
        if w.pointee.tlab.end != 0 { w.pointee.nurseryTop = w.pointee.tlab.cur }
        w.pointee.tlab = Tlab()
    } else {
        vm.pointee.heap.retire(&w.pointee.tlab)
    }
}

/// Take the next bitmap word with a free bit from the current chunk, or a
/// new chunk (pool, else fresh at the high-water mark). Lock-free. False
/// when the table is full.
private func refillEntries(_ vm: VMRef, _ w: WorkerRef) -> Bool {
    let sp = vm.pointee.space
    while true {
        let c = w.pointee.ws.chunk
        if c >= 0 {
            while w.pointee.ws.cursor < wordsPerChunk {
                let gw = c &* wordsPerChunk &+ w.pointee.ws.cursor
                w.pointee.ws.cursor &+= 1
                // Atomic: the lazy sweeper may be clearing bits of this word
                // (SPEC.md "Lazy sweep").
                let aw = atomicWord(sp.used + gw)
                if aw.pointee.load(ordering: .relaxed) != ~0 {
                    let free = ~aw.pointee.exchange(~0, ordering: .acquiring)
                    if free == 0 { continue }
                    w.pointee.ws.entFree = free
                    w.pointee.ws.entBase = UInt64(gw) &<< 10 // 64 entries x 16 bytes
                    w.pointee.ws.entWord = gw
                    w.pointee.ws.wordTakes &+= 1
                    w.pointee.ws.bitsTaken &+= UInt64(free.nonzeroBitCount)
                    if w.pointee.youngMark != 0 { logYoungWord(w, gw, free) }
                    return true
                }
            }
        }
        let i = sp.poolNext.pointee.wrappingAdd(1, ordering: .relaxed).oldValue
        var next: Int
        if i < sp.poolCount.pointee.load(ordering: .relaxed) {
            next = Int(sp.pool[i])
        } else {
            next = sp.chunkHwm.pointee.wrappingAdd(1, ordering: .relaxed).oldValue
            if next >= maxChunks { return false }
            w.pointee.ws.chunkFresh &+= 1
        }
        w.pointee.ws.chunk = next
        w.pointee.ws.cursor = 0
        w.pointee.ws.chunkTakes &+= 1
        if w.pointee.youngMark != 0 { w.pointee.chunks.push(UInt32(next)) }
    }
}

@inline(__always) private func logYoungWord(_ w: WorkerRef, _ gw: Int, _ bits: UInt64) {
    w.pointee.logWord.push(UInt32(truncatingIfNeeded: gw))
    w.pointee.logBits.push(bits)
}

/// World stopped: give back the worker's reserved entries and its chunk.
func releaseEntries(_ vm: VMRef, _ w: WorkerRef) {
    let free = w.pointee.ws.entFree
    if free != 0 {
        let gw = w.pointee.ws.entWord
        vm.pointee.space.used[gw] &= ~free
        let n = w.pointee.logWord.count
        if n > 0 && Int(w.pointee.logWord.ptr[n - 1]) == gw { w.pointee.logBits.ptr[n - 1] &= ~free }
    }
    w.pointee.ws.entFree = 0
    w.pointee.ws.entWord = -1
    w.pointee.ws.chunk = -1
    w.pointee.ws.cursor = wordsPerChunk
}

func retireBoot(_ vm: VMRef, _ w: WorkerRef) {
    vm.pointee.heap.retire(&w.pointee.tlab)
    releaseEntries(vm, w)
}

// MARK: - write barrier

/// Store `v` into slot `i` of `o` with the write barrier (SPEC.md "Write
/// barrier"). The VM-internal sites call this; the interpreter's store_ivar
/// and at:put: inline the same test.
@_transparent
func store(_ vm: VMRef, _ w: WorkerRef, _ o: Oop, _ i: Int, _ v: Oop) {
    satbPre(vm, w, o, i)
    let om = vm.pointee.om
    om.setSlot(o, i, v)
    barrier(vm, w, om, o, v)
}

// MARK: - SATB barrier (SPEC.md "SATB barrier")

/// Before a store into slot `i` of `o`: while marking, record the value
/// about to be overwritten. Fast path: one byte test.
@_transparent
func satbPre(_ vm: VMRef, _ w: WorkerRef, _ o: Oop, _ i: Int) {
    #if !NO_MARK_BARRIER
    if w.pointee.marking != 0 { satbSlow(w, o, i) }
    #endif
}

/// store_ivar while marking: SATB record, store, generational barrier.
@inline(never)
func storeWhileMarking(_ w: WorkerRef, _ o: Oop, _ i: Int, _ v: Oop) {
    let vm = w.pointee.vm.unsafelyUnwrapped.assumingMemoryBound(to: VMCore.self)
    satbSlow(w, o, i)
    let om = vm.pointee.om
    om.setSlot(o, i, v)
    barrier(vm, w, om, o, v)
}

/// Two scalars and the worker: the VM is reached through the worker, so the
/// interpreter loop keeps fewer values live across this call.
@inline(never)
func satbSlow(_ w: WorkerRef, _ o: Oop, _ i: Int) {
    let vm = w.pointee.vm.unsafelyUnwrapped.assumingMemoryBound(to: VMCore.self)
    w.pointee.satbSlow &+= 1
    if !vm.pointee.cmConfig.satb { return } // test switch
    let om = vm.pointee.om
    // A young holder was created after the snapshot (nothing is young at
    // the snapshot), so its old values are not snapshot edges. Not so in the
    // literal test mode.
    if om.header(o) & youngBit != 0 && !vm.pointee.cmConfig.literal { return }
    let old = om.slotLoad(o, i)
    if old & 1 != 0 || old == 0 { return }
    let cm = vm.pointee.cm
    let idx = Int(truncatingIfNeeded: old &>> 4)
    if cm.snap[idx &>> 6] & (UInt64(1) &<< UInt64(idx & 63)) == 0 { return } // allocated after the snapshot
    if cm.mark[idx].load(ordering: .relaxed) != 0 { return }
    satbPush(vm, w, old)
}

@inline(__always)
func satbPush(_ vm: VMRef, _ w: WorkerRef, _ v: Oop) {
    if w.pointee.satbCount == satbCap { satbHandover(vm, w) }
    w.pointee.satbBuf[w.pointee.satbCount] = v
    w.pointee.satbCount &+= 1
    w.pointee.satbPushed &+= 1
}

@_transparent
func barrier(_ vm: VMRef, _ w: WorkerRef, _ om: OM, _ o: Oop, _ v: Oop) {
    #if !NO_BARRIER
    if v & 1 == 0 && om.header(o) & youngBit == 0 && om.header(v) & youngBit != 0 {
        remember(vm, w, o)
    }
    #endif
}

/// Old holder, young value: record the holder once.
@inline(never)
func remember(_ vm: VMRef, _ w: WorkerRef, _ o: Oop) {
    w.pointee.barrierSlow &+= 1
    let r = vm.pointee.space.rem + Int(truncatingIfNeeded: o &>> 4)
    if r.pointee.load(ordering: .relaxed) != 0 { return }
    if r.pointee.exchange(1, ordering: .relaxed) != 0 { return }
    w.pointee.remBuf.push(o)
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

func markAll(_ vm: VMRef, _ stack: inout WordStack) {
    let om = vm.pointee.om
    for (p, c) in rootRanges(vm) {
        for i in 0..<c { markSlot(om, p[i], &stack) }
        while let o = stack.pop() {
            let n = hdrSlots(om.header(o))
            let s = om.slotsPtr(o)
            var i = 0
            while i < n { markSlot(om, s[i], &stack); i &+= 1 }
        }
    }
}

/// Bitmap sweep of every chunk below the high-water mark: unmark live
/// entries (and flag their body's block), free dead ones, rebuild the chunk
/// pool. Every reservation must have been released. Returns (live bytes,
/// entries freed).
private func sweepTable(_ vm: VMRef) -> (Int, Int) {
    let om = vm.pointee.om
    let sp = vm.pointee.space
    let heap = vm.pointee.heap
    let chunks = chunkHwmNow(vm)
    var live = 0
    var freed = 0
    var pooled = 0
    for c in 0..<chunks {
        var hasFree = false
        for k in 0..<wordsPerChunk {
            let gw = c &* wordsPerChunk &+ k
            var bits = sp.used[gw]
            var keep = bits
            while bits != 0 {
                let b = bits.trailingZeroBitCount
                bits &= bits &- 1
                let idx = gw &* 64 &+ b
                if idx == 0 { continue }
                let e = om.entry(UInt64(idx) &<< 4)
                let h = e[0]
                if hdrMarked(h) {
                    e[0] = h & ~markBit
                    live &+= objectBytes(h)
                    let addr = om.heap &+ UInt(e[1])
                    if heap.inNurseries(addr) { fatal("full sweep: live body in a nursery") }
                    heap.live[heap.blockOf(addr)] = true
                } else {
                    keep &= ~(UInt64(1) &<< UInt64(b))
                    freed &+= 1
                }
            }
            sp.used[gw] = keep
            if keep != ~0 { hasFree = true }
        }
        if hasFree { sp.pool[pooled] = UInt32(c); pooled &+= 1 }
    }
    sp.poolCount.pointee.store(pooled, ordering: .relaxed)
    sp.poolNext.pointee.store(0, ordering: .relaxed)
    return (live, freed)
}

/// Full non-moving mark-sweep of old space (the nursery is empty: in
/// generational mode a scavenge ran first). Returns (mark ns, sweep ns).
func markSweep(_ vm: VMRef, _ w: WorkerRef) -> (UInt64, UInt64) {
    let t0 = now()
    markAll(vm, &w.pointee.gcStack)
    let t1 = now()
    let (live, freed) = sweepTable(vm)
    _ = vm.pointee.heap.rebuildPool()
    let t2 = now()
    vm.set(.liveBytes, UInt64(live))
    vm.add(.fullEntriesFreed, UInt64(freed))
    return (t1 &- t0, t2 &- t1)
}
