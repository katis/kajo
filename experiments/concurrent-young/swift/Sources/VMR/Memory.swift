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
    /// The entry's offset word as an atomic (SPEC.md "Entry state encoding").
    @inline(__always) func offsetWord(_ o: Oop) -> UnsafeMutablePointer<Atomic<UInt64>> { atomicWord(entry(o) + 1) }
    /// The body, through the entry's offset word (a relaxed atomic load, a
    /// plain `ldr`: the relocator switches it concurrently). While the entry
    /// is RELOCATING the offset carries `relocBit` and the address lands in
    /// the heap's alias mapping, at the old body (SPEC.md "Entry state
    /// encoding"): no read barrier.
    @inline(__always) func body(_ o: Oop) -> UnsafeMutablePointer<UInt64> {
        wordPtr(heap &+ UInt(truncatingIfNeeded: offsetWord(o).pointee.load(ordering: .relaxed)))
    }
    /// Relaxed atomic load (a plain `ldr`): local collections write young
    /// headers while mutators read them (SPEC.md "Header word").
    @inline(__always) public func header(_ o: Oop) -> UInt64 { atomicHeader(entry(o)).pointee.load(ordering: .relaxed) }
    @inline(__always) func setHeader(_ o: Oop, _ h: UInt64) { entry(o).pointee = h }
    /// Relaxed atomic slot load (a plain `ldr`): the relocator writes new
    /// bodies with relaxed atomic stores.
    @inline(__always) public func slot(_ o: Oop, _ i: Int) -> Oop {
        atomicWord(body(o) + (1 &+ i)).pointee.load(ordering: .relaxed)
    }
    /// Raw slot store: no barrier and no post-store check. A relaxed atomic
    /// store (a plain `str`). Only for objects nobody else can see yet (image
    /// boot) and in tests as "a store without the post-store check". Every
    /// other store uses `setSlot(w, ...)` or `store`.
    @inline(__always) public func setSlotRaw(_ o: Oop, _ i: Int, _ v: Oop) {
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
    /// 16 bits per entry: bit n, the holder is in nursery n's remembered
    /// set (SPEC.md "Remembered sets: per nursery"). Atomic.
    var rem: UnsafeMutablePointer<Atomic<UInt32>>
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
    let rem = zeroMap(tableEntries * 4).bindMemory(to: Atomic<UInt32>.self, capacity: tableEntries)
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
    // Relaxed atomic stores (plain `str`): a young collector may read a
    // fresh object it finds through a published slot (SPEC.md "Header word").
    atomicHeader(ent).pointee.store(makeHeader(cls, slots, bytes) | w.pointee.youngMark, ordering: .relaxed)
    om.offsetWord(e).pointee.store(UInt64(cur &- om.heap), ordering: .relaxed)
    let p = wordPtr(cur)
    atomicWord(p).pointee.store(backref(e &>> 4, size), ordering: .relaxed)
    let n = (size &- 8) / 8
    let f = bytes ? 0 : fill
    var i = 1
    while i <= n { atomicWord(p + i).pointee.store(f, ordering: .relaxed); i &+= 1 }
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
                if w.pointee.youngMark == 0 {
                    requestGC(vm, w, .full)
                } else {
                    // SPEC.md "Part 1", "Part 2"; stw: ADR 0007's scavenge.
                    switch youngMode(vm) {
                    case YoungMode.local: ycLocal(vm, w)
                    case YoungMode.offload: ycFlip(vm, w)
                    default: requestGC(vm, w, .scavenge)
                    }
                }
                gcs += 1; continue
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
        var next: Int
        if w.pointee.recycleNext < w.pointee.recycle.count {
            // Chunks this nursery's collections left free entries in.
            next = Int(w.pointee.recycle.ptr[w.pointee.recycleNext])
            w.pointee.recycleNext &+= 1
            w.pointee.ws.chunk = next
            w.pointee.ws.cursor = 0
            w.pointee.ws.chunkTakes &+= 1
            if w.pointee.youngMark != 0 { w.pointee.chunks.push(UInt32(next)) }
            continue
        }
        let i = sp.poolNext.pointee.wrappingAdd(1, ordering: .relaxed).oldValue
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

/// Store `v` into slot `i` of `o` with every barrier. The VM-internal sites
/// call this; the interpreter's store_ivar and at:put: inline the same test.
@_transparent
func store(_ vm: VMRef, _ w: WorkerRef, _ o: Oop, _ i: Int, _ v: Oop) {
    preStore(vm, w, o, i, v)
    let om = vm.pointee.om
    setSlot(w, om, o, i, v)
    barrier(vm, w, om, o, v)
}

// MARK: - post-store check (SPEC.md "Copy protocol")

/// Store `v` into slot `i` of `o`, then check that the object did not start
/// relocating or move meanwhile; if it did, redo the store into the current
/// body. Every store into a heap object goes through here (SmallIntegers
/// included); `NO_POST_STORE` compiles the check out.
@_transparent
func setSlot(_ w: WorkerRef, _ om: OM, _ o: Oop, _ i: Int, _ v: Oop) {
    #if NO_POST_STORE
    om.setSlotRaw(o, i, v)
    #else
    let ow = om.offsetWord(o)
    let e1 = ow.pointee.load(ordering: .relaxed)
    atomicWord(wordPtr(om.heap &+ UInt(truncatingIfNeeded: e1)) + (1 &+ i)).pointee.store(v, ordering: .sequentiallyConsistent)
    let e2 = ow.pointee.load(ordering: .sequentiallyConsistent)
    if e2 != e1 || e1 & relocBit != 0 { postStoreSlow(w, o, i, v) }
    #endif
}

/// The interpreter's store: post-store check, then the generational
/// barrier. When the check fails, one out-of-line call does the redo and the
/// barrier, so nothing of the instruction is live after a call (a separate
/// slow-path call before the inline barrier spilled the table and heap bases
/// for the whole loop, as the SATB call did in the previous experiment).
@_transparent
func setSlotAndBarrier(_ vm: VMRef, _ w: WorkerRef, _ om: OM, _ o: Oop, _ i: Int, _ v: Oop) {
    #if NO_POST_STORE
    om.setSlotRaw(o, i, v)
    barrier(vm, w, om, o, v)
    #else
    let ow = om.offsetWord(o)
    let e1 = ow.pointee.load(ordering: .relaxed)
    atomicWord(wordPtr(om.heap &+ UInt(truncatingIfNeeded: e1)) + (1 &+ i)).pointee.store(v, ordering: .sequentiallyConsistent)
    let e2 = ow.pointee.load(ordering: .sequentiallyConsistent)
    if e2 != e1 || e1 & relocBit != 0 {
        storeConflict(w, o, i, v)
    } else {
        barrier(vm, w, om, o, v)
    }
    #endif
}

/// Redo after a failed post-store check, then the generational barrier.
@inline(never)
func storeConflict(_ w: WorkerRef, _ o: Oop, _ i: Int, _ v: Oop) {
    let vm = w.pointee.vm.unsafelyUnwrapped.assumingMemoryBound(to: VMCore.self)
    postStoreSlow(w, o, i, v)
    barrier(vm, w, vm.pointee.om, o, v)
}

/// The object was RELOCATING or moved: wait for the switch (or revert),
/// store into the current body, repeat until the offset is stable. Counted
/// per worker (SPEC.md "Copy protocol").
@inline(never)
func postStoreSlow(_ w: WorkerRef, _ o: Oop, _ i: Int, _ v: Oop) {
    let vm = w.pointee.vm.unsafelyUnwrapped.assumingMemoryBound(to: VMCore.self)
    let om = vm.pointee.om
    let ow = om.offsetWord(o)
    w.pointee.storeRedo &+= 1
    var spins = 0
    var t0: UInt64 = 0
    while true {
        var e = ow.pointee.load(ordering: .acquiring)
        while e & relocBit != 0 {
            if spins == 0 { t0 = now() }
            spins &+= 1
            if spins & 63 == 0 { sched_yield() }
            e = ow.pointee.load(ordering: .acquiring)
        }
        atomicWord(wordPtr(om.heap &+ UInt(truncatingIfNeeded: e)) + (1 &+ i)).pointee.store(v, ordering: .sequentiallyConsistent)
        if ow.pointee.load(ordering: .sequentiallyConsistent) == e { break }
    }
    if spins > 0 {
        let dt = now() &- t0
        w.pointee.spinEpisodes &+= 1
        w.pointee.spinNs &+= dt
        if dt > w.pointee.spinMaxNs { w.pointee.spinMaxNs = dt }
    }
}

// MARK: - hazard slots (SPEC.md "Hazard slots")

/// Publish `o` in hazard slot `k`, then wait until it is not RELOCATING;
/// answers its body, valid until `hazardRelease`.
@inline(never)
func hazardAcquire(_ w: WorkerRef, _ om: OM, _ k: Int, _ o: Oop) -> UnsafeMutablePointer<UInt64> {
    // Counted first (seq_cst): a young collector that reads 0 after its
    // RELOCATING CAS skips scanning the slots, and then this thread's offset
    // load below sees RELOCATING (same Dekker argument as the slots).
    let vm = w.pointee.vm.unsafelyUnwrapped.assumingMemoryBound(to: VMCore.self)
    vm.pointee.hazardsHeld.wrappingAdd(1, ordering: .sequentiallyConsistent)
    w.pointee.hz[k].store(o, ordering: .sequentiallyConsistent)
    var e = om.offsetWord(o).pointee.load(ordering: .sequentiallyConsistent)
    if e & relocBit != 0 {
        w.pointee.hazardWaits &+= 1
        var spins = 0
        while e & relocBit != 0 {
            spins &+= 1
            if spins & 63 == 0 { sched_yield() }
            e = om.offsetWord(o).pointee.load(ordering: .sequentiallyConsistent)
        }
    }
    return wordPtr(om.heap &+ UInt(truncatingIfNeeded: e))
}

@inline(__always)
func hazardRelease(_ w: WorkerRef, _ k: Int) {
    w.pointee.hz[k].store(0, ordering: .releasing)
    w.pointee.vm.unsafelyUnwrapped.assumingMemoryBound(to: VMCore.self).pointee.hazardsHeld.wrappingSubtract(1, ordering: .releasing)
}

// MARK: - deletion barriers (SPEC.md "Barriers")

/// Before a store into slot `i` of `o`: one load of the flag word; nonzero
/// (old-space marking, or a young collection running) takes the slow path.
@_transparent
func preStore(_ vm: VMRef, _ w: WorkerRef, _ o: Oop, _ i: Int, _ v: Oop) {
    #if !NO_MARK_BARRIER
    if vm.pointee.barrierWord.load(ordering: .relaxed) != 0 { preStoreSlow(w, o, i, v) }
    #endif
}

/// store_ivar with a barrier on: deletion records, store, insertion barrier.
@inline(never)
func storeWithBarriers(_ w: WorkerRef, _ o: Oop, _ i: Int, _ v: Oop) {
    let vm = w.pointee.vm.unsafelyUnwrapped.assumingMemoryBound(to: VMCore.self)
    preStoreSlow(w, o, i, v)
    setSlotAndBarrier(vm, w, vm.pointee.om, o, i, v)
}

/// Two scalars and the worker: the VM is reached through the worker, so the
/// interpreter loop keeps fewer values live across this call.
@inline(never)
func preStoreSlow(_ w: WorkerRef, _ o: Oop, _ i: Int, _ v: Oop) {
    let vm = w.pointee.vm.unsafelyUnwrapped.assumingMemoryBound(to: VMCore.self)
    let bw = vm.pointee.barrierWord.load(ordering: .relaxed)
    let om = vm.pointee.om
    #if !NO_YOUNG_BARRIER
    if bw > 1 && vm.pointee.ycConfig.youngDeletion {
        // Young deletion barrier: the overwritten value is young in a
        // nursery being collected.
        let old = om.slotLoad(o, i)
        if old & 1 == 0 && old != 0 {
            let h = om.header(old)
            if h & youngBit != 0 {
                let n = hdrNursery(h)
                if vm.pointee.yc.collecting[n].load(ordering: .acquiring) {
                    w.pointee.del[n].push(old)
                    w.pointee.delPushed &+= 1
                }
            }
        }
        // Offload snoop: a young object of a nursery being collected stored
        // into a young holder of the same nursery outside Y (the eden half
        // the worker allocates in during its own collection) remembers the
        // holder (SPEC.md "Part 2").
        if v & 1 == 0 && v != 0 && youngMode(vm) == YoungMode.offload {
            let hv = om.header(v)
            if hv & youngBit != 0 && (om.header(o) ^ hv) & youngNurseryMask == 0 {
                let n = hdrNursery(hv)
                if vm.pointee.yc.collecting[n].load(ordering: .acquiring) && vm.pointee.ycConfig.snoop
                    && inY(vm, n, v) && !inY(vm, n, o) {
                    w.pointee.snooped &+= 1
                    remember(vm, w, o, hv)
                }
            }
        }
    }
    #endif
    if bw & 1 == 0 { return }
    w.pointee.satbSlow &+= 1
    if !vm.pointee.cmConfig.satb { return } // test switch
    // A young holder: everything it named at the snapshot is grey (SPEC.md
    // "Part 3"). Not so in the literal test mode.
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

// MARK: - insertion barrier (SPEC.md "Barriers")

/// After a pointer store: remember `o` in the remembered set of `v`'s
/// nursery if `v` is young and `o` is not young in the same nursery.
@_transparent
func barrier(_ vm: VMRef, _ w: WorkerRef, _ om: OM, _ o: Oop, _ v: Oop) {
    #if !NO_BARRIER
    #if NO_YOUNG_BARRIER
    if v & 1 == 0 && om.header(o) & youngBit == 0 {
        let hv = om.header(v)
        if hv & youngBit != 0 { remember(vm, w, o, hv) }
    }
    #else
    if v & 1 == 0 {
        let hv = om.header(v)
        if hv & youngBit != 0 && (om.header(o) ^ hv) & youngNurseryMask != 0 { remember(vm, w, o, hv) }
    }
    #endif
    #endif
}

/// Record the holder once per nursery: seq_cst load of its bits, `fetch_or`
/// (SPEC.md "Ordering and soundness" 2).
@inline(never)
func remember(_ vm: VMRef, _ w: WorkerRef, _ o: Oop, _ hv: UInt64) {
    w.pointee.barrierSlow &+= 1
    let ho = vm.pointee.om.header(o)
    if ho & youngBit != 0 && (ho ^ hv) & youngNurseryMask != 0 {
        if !vm.pointee.ycConfig.crossNursery { return } // test switch
        w.pointee.crossRem &+= 1
    }
    let n = hdrNursery(hv)
    let bit = UInt32(1) &<< UInt32(n)
    let r = vm.pointee.space.rem + Int(truncatingIfNeeded: o &>> 4)
    if r.pointee.load(ordering: .sequentiallyConsistent) & bit != 0 { return }
    if r.pointee.bitwiseOr(bit, ordering: .sequentiallyConsistent).oldValue & bit != 0 { return }
    w.pointee.rem[n].push(o)
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
