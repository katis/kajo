// Object memory for variant L: B's object table with the entries moved into
// the blocks of their bodies (SPEC.md "Variant L layout"). Derived from
// ../../object-representation/swift/Sources/VMB/Memory.swift; the oop
// encoding, entry and body formats, mark bit, become and forward are B's.
// What changed: entries are bump-allocated down from the top of the
// allocating worker's 16 KiB block (no free-entry runs, no high-water mark,
// no table mapping); the table scans walk the entry areas of the in-use
// blocks; compaction slides bodies into the body areas below each block's
// lowest live entry and leaves entries in place; large bodies (> 4 KiB)
// live in a separate non-moving arena with their entry in a small block.

import Darwin
import Synchronization

public let variantName = "L"
/// Shift applied to selector oops for cache and method-dict hashing (oops
/// are multiples of 16, as in B).
let selShift: UInt64 = 4

/// Size of the sparse entry index space for a 1 GiB small arena (entry
/// index = block * 1024 + slot). Informational; nothing is allocated by it.
public let tableEntries = (1 << 30) / 16
let entriesPerBlock = blockSize / 16

// MARK: - oop -> entry -> body

/// The accessor view loaded once per interpreter run. B's two fields, both
/// the heap base here (the entries live in the heap), so every accessor
/// compiles to B's instructions.
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

/// L's object-memory state beyond the heap: the large-TLAB epoch (bumped
/// whenever large blocks may be freed, so stale large TLABs are dropped),
/// the operation TLAB for large bodies, and counters.
public struct Space {
    var epoch: UnsafeMutablePointer<UInt64>
    var opLarge: UnsafeMutablePointer<Tlab>
    /// [0] bodies moved by the last compaction to a block other than their
    /// entry's, [1] live objects at that compaction.
    var counters: UnsafeMutablePointer<UInt64>
}

/// Per-worker: the large-object TLAB and counters.
public struct WorkerSpace {
    var ltlab = Tlab()
    var lepoch: UInt64 = 0
    var refills: UInt64 = 0
    var largeAllocs: UInt64 = 0
}

func makeSpace(_ heap: Heap) -> (OM, Space) {
    let ep = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
    ep.initialize(to: 1)
    let op = UnsafeMutablePointer<Tlab>.allocate(capacity: 1)
    op.initialize(to: Tlab())
    let c = UnsafeMutablePointer<UInt64>.allocate(capacity: 4)
    c.initialize(repeating: 0, count: 4)
    return (OM(table: heap.baseAddr, heap: heap.baseAddr), Space(epoch: ep, opLarge: op, counters: c))
}

func entryRefills(_ w: WorkerRef) -> UInt64 { w.pointee.ws.refills }

// MARK: - allocation

/// Allocate an object; may stop the world. `w`'s sp/pc/hdr must be flushed.
/// Fast path: entry from the top of the TLAB's block, body from the bottom.
@inline(__always)
public func alloc(_ vm: VMRef, _ w: WorkerRef, _ cls: UInt32, _ slots: Int, _ bytes: Bool) -> Oop {
    let size = sizeFor(slots, bytes)
    let cur = w.pointee.tlab.cur
    let end = w.pointee.tlab.end
    if size <= largeThreshold && end &- cur >= UInt(size &+ 16) {
        w.pointee.tlab.cur = cur &+ UInt(size)
        w.pointee.tlab.end = end &- 16
        return initObject(vm.pointee.om, end &- 16, cur, cls, slots, bytes, size, vm.pointee.nilObj)
    }
    return allocSlow(vm, w, cls, slots, bytes)
}

@inline(__always)
private func initObject(_ om: OM, _ entryAddr: UInt, _ bodyAddr: UInt, _ cls: UInt32, _ slots: Int,
                        _ bytes: Bool, _ size: Int, _ fill: Oop) -> Oop {
    let e = UInt64(entryAddr &- om.table)
    let ent = wordPtr(entryAddr)
    ent[0] = makeHeader(cls, slots, bytes)
    ent[1] = UInt64(bodyAddr &- om.heap)
    let p = wordPtr(bodyAddr)
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
    if size > largeBlockSize { fatal("object larger than a block") }
    let large = size > largeThreshold
    let need = large ? 16 : size + 16
    var gcs = 0
    while true {
        if gcs > 3 { fatal("out of memory") }
        if w.pointee.tlab.end &- w.pointee.tlab.cur < UInt(need) {
            if !vm.pointee.heap.small.refill(&w.pointee.tlab) { requestGC(vm, w); gcs += 1; continue }
            w.pointee.tlabRefills &+= 1
            w.pointee.ws.refills &+= 1
            continue // a partially used block may still be too small
        }
        if !large {
            let cur = w.pointee.tlab.cur, end = w.pointee.tlab.end
            w.pointee.tlab.cur = cur &+ UInt(size)
            w.pointee.tlab.end = end &- 16
            return initObject(vm.pointee.om, end &- 16, cur, cls, slots, bytes, size, vm.pointee.nilObj)
        }
        let epoch = vm.pointee.space.epoch.pointee
        if w.pointee.ws.lepoch != epoch {
            w.pointee.ws.ltlab = Tlab() // its block may have been freed; never retire it
            w.pointee.ws.lepoch = epoch
        }
        if w.pointee.ws.ltlab.end &- w.pointee.ws.ltlab.cur < UInt(size) {
            if !vm.pointee.heap.large.refill(&w.pointee.ws.ltlab) { requestGC(vm, w); gcs += 1; continue }
            continue
        }
        let body = w.pointee.ws.ltlab.cur
        w.pointee.ws.ltlab.cur = body &+ UInt(size)
        let end = w.pointee.tlab.end
        w.pointee.tlab.end = end &- 16
        w.pointee.ws.largeAllocs &+= 1
        return initObject(vm.pointee.om, end &- 16, body, cls, slots, bytes, size, vm.pointee.nilObj)
    }
}

/// A body allocated inside a stop-the-world operation (never collects).
/// Returns its address; the caller writes the backref and slots. Its entry
/// is the object's existing one (reshape), so it is never local.
private func opBody(_ vm: VMRef, _ size: Int) -> UInt {
    if size > largeThreshold {
        var t = vm.pointee.space.opLarge.pointee
        if t.end &- t.cur < UInt(size) {
            if !vm.pointee.heap.large.refill(&t) { fatal("out of memory inside a safepoint operation") }
        }
        let p = t.cur
        t.cur &+= UInt(size)
        vm.pointee.space.opLarge.pointee = t
        return p
    }
    var t = vm.pointee.opTlab
    while t.end &- t.cur < UInt(size) {
        if !vm.pointee.heap.small.refill(&t) { fatal("out of memory inside a safepoint operation") }
    }
    let p = t.cur
    t.cur &+= UInt(size)
    vm.pointee.opTlab = t
    return p
}

func retireBoot(_ vm: VMRef, _ w: WorkerRef) {
    vm.pointee.heap.retire(&w.pointee.tlab)
    vm.pointee.heap.large.retire(&w.pointee.ws.ltlab)
}

// MARK: - entry areas

/// Call `f(oop, entry)` for every slot in the entry area of every in-use
/// small block (free slots have header 0). World stopped.
@inline(__always)
private func forEachEntrySlot(_ vm: VMRef, _ f: (Oop, UnsafeMutablePointer<UInt64>) -> Void) {
    let small = vm.pointee.heap.small
    let om = vm.pointee.om
    for b in 0..<small.nblocks where small.inUse[b] {
        let s = small.blockStart(b)
        var a = s &+ UInt(small.entryLow[b])
        let top = s &+ UInt(blockSize)
        while a < top {
            f(UInt64(a &- om.table), wordPtr(a))
            a &+= 16
        }
    }
}

/// Flag the block holding a body (small or large arena) live.
@inline(__always)
private func flagBody(_ heap: Heap, _ addr: UInt) {
    if heap.small.contains(addr) { heap.small.live[heap.small.blockOf(addr)] = true }
    else { heap.large.live[heap.large.blockOf(addr)] = true }
}

// MARK: - mark & sweep

@inline(__always)
private func markSlot(_ om: OM, _ v: Oop, _ stack: inout WordStack) {
    if v & 1 != 0 { return }
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

/// Entry-area scan: unmark live entries and flag their own block and their
/// body's block live; free dead ones. Returns live bytes.
private func sweepEntries(_ vm: VMRef) -> Int {
    let heap = vm.pointee.heap
    let om = vm.pointee.om
    var live = 0
    for b in 0..<heap.small.nblocks where heap.small.inUse[b] {
        let s = heap.small.blockStart(b)
        var a = s &+ UInt(heap.small.entryLow[b])
        let top = s &+ UInt(blockSize)
        var any = false
        while a < top {
            let e = wordPtr(a)
            let h = e[0]
            if h != 0 {
                if hdrMarked(h) {
                    e[0] = h & ~markBit
                    live &+= objectBytes(h)
                    any = true
                    flagBody(heap, om.heap &+ UInt(e[1]))
                } else {
                    e[0] = 0
                }
            }
            a &+= 16
        }
        if any { heap.small.live[b] = true }
    }
    return live
}

/// Full non-moving mark-sweep. Returns (mark ns, sweep ns).
func collect(_ vm: VMRef) -> (UInt64, UInt64) {
    let t0 = now()
    markAll(vm)
    let t1 = now()
    let live = sweepEntries(vm)
    vm.pointee.heap.small.rebuildPool()
    vm.pointee.heap.large.rebuildPool()
    vm.pointee.space.epoch.pointee &+= 1
    let t2 = now()
    vm.set(.liveBytes, UInt64(live))
    return (t1 &- t0, t2 &- t1)
}

// MARK: - stop-the-world operations

func performOp(_ vm: VMRef, _ w: WorkerRef, _ op: SafeOp) -> Oop {
    switch op {
    case .gc(let tag): timedCollect(vm, tag: tag)
    case .become(let a, let b): becomeTwoWay(vm, a, b)
    case .forward(let f, let t): forwardBulk(vm, f, t)
    case .reshape(let c): reshape(vm, c)
    case .compact: compact(vm)
    case .snapshot: saveSnapshot(vm, vm.pointee.snapshotPath)
    }
    vm.pointee.heap.large.retire(&vm.pointee.space.opLarge.pointee)
    return 0
}

/// Same refusal rule as A and B.
private func checkBecomable(_ vm: VMRef, _ o: Oop) {
    if isInt(o) || o == vm.pointee.nilObj || o == vm.pointee.trueObj || o == vm.pointee.falseObj {
        fatal("become: on an immediate or a constant")
    }
    switch UInt32(hdrClass(vm.pointee.om.header(o))) {
    case ciClass, ciMethod, ciMethodDict, ciSymbol, ciByteArray: fatal("become: on a protected class")
    default: break
    }
}

/// Swap the two entries and the two bodies' back references (as B). Both
/// bodies now live away from their entries.
func becomeTwoWay(_ vm: VMRef, _ a: Oop, _ b: Oop) {
    if a == b { return }
    checkBecomable(vm, a)
    checkBecomable(vm, b)
    let om = vm.pointee.om
    let ea = om.entry(a), eb = om.entry(b)
    let h = ea[0], off = ea[1]
    ea[0] = eb[0]; ea[1] = eb[1]
    eb[0] = h; eb[1] = off
    let ba = om.body(a), bb = om.body(b)
    ba[0] = (ba[0] & ~0xFFFF_FFFF) | (a &>> 4)
    bb[0] = (bb[0] & ~0xFFFF_FFFF) | (b &>> 4)
    vm.add(.becomeSwapPath, 1)
}

private let forwardingHeader = makeHeader(ciForwarder, 1, false)

/// One-way become of every pair, then one scan over every live object and
/// every root (as B; the table scan is an entry-area scan).
func forwardBulk(_ vm: VMRef, _ fromArrs: Oop, _ toArrs: Oop) {
    let om = vm.pointee.om
    let n = hdrSlots(om.header(fromArrs))
    var froms = WordStack(capacity: 1 << 16)
    for i in 0..<n {
        let fc = om.slot(fromArrs, i), tc = om.slot(toArrs, i)
        let m = hdrSlots(om.header(fc))
        for j in 0..<m {
            let f = om.slot(fc, j), t = om.slot(tc, j)
            if f == t { continue }
            checkBecomable(vm, f)
            let e = om.entry(f)
            e[0] = forwardingHeader
            e[1] = t
            froms.push(f)
        }
    }
    @inline(__always) func resolve(_ v: Oop) -> Oop {
        var o = v
        while true {
            let e = om.entry(o)
            if e[0] != forwardingHeader { return o }
            o = e[1]
        }
    }
    var scanned: UInt64 = 0
    forEachEntrySlot(vm) { _, e in
        let h = e[0]
        if h == 0 || h == forwardingHeader || hdrIsBytes(h) { return }
        let s = wordPtr(om.heap &+ UInt(e[1])) + 1
        let k = hdrSlots(h)
        var i = 0
        while i < k {
            let v = s[i]
            if v & 1 == 0 { s[i] = resolve(v); scanned &+= 1 }
            i &+= 1
        }
    }
    for (p, c) in rootRanges(vm) {
        for i in 0..<c where p[i] & 1 == 0 && p[i] != 0 { p[i] = resolve(p[i]) }
    }
    for k in 0..<froms.count { om.entry(froms.ptr[k])[0] = 0 } // free slots; the block reclaims them when empty
    vm.add(.forwardPairs, UInt64(froms.count))
    vm.add(.forwardScanSlots, scanned)
    froms.ptr.deallocate()
}

/// Add one instance variable to `cls`: entry-area scan, new bodies from the
/// operation TLAB, entries repointed (as B).
func reshape(_ vm: VMRef, _ cls: Oop) {
    let om = vm.pointee.om
    let idx = UInt64(intVal(om.slot(cls, cIndex)))
    let nilObj = vm.pointee.nilObj
    var list = WordStack(capacity: 1 << 16)
    forEachEntrySlot(vm) { o, e in
        let h = e[0]
        if h != 0 && hdrClass(h) == idx && !hdrIsBytes(h) { list.push(o) }
    }
    for k in 0..<list.count {
        let o = list.ptr[k]
        let e = om.entry(o)
        let h = e[0]
        let n = hdrSlots(h)
        let size = sizeFor(n + 1, false)
        let nb = opBody(vm, size)
        let p = wordPtr(nb)
        p[0] = backref(o &>> 4, size)
        (p + 1).update(from: om.slotsPtr(o), count: n)
        p[1 + n] = nilObj
        e[0] = makeHeader(UInt32(idx), n + 1, false) | (h & markBit)
        e[1] = UInt64(nb &- om.heap)
    }
    om.setSlot(cls, cInstSize, mkInt(intVal(om.slot(cls, cInstSize)) + 1))
    vm.add(.reshapeCount, UInt64(list.count))
    list.ptr.deallocate()
}

// MARK: - compaction

/// Mark; free dead entries and find each block's lowest live entry; slide
/// live small bodies in block order into `[start, liveLow)` of each block;
/// repoint entries (they stay where they are); unmark. Large bodies stay.
func compact(_ vm: VMRef) {
    let om = vm.pointee.om
    let heap = vm.pointee.heap
    let small = heap.small
    let t0 = now()
    markAll(vm)
    let t1 = now()
    let pcs = pcsToOffsets(vm)
    // 1. dead entries freed, liveLow per block
    var liveLow = [UInt32](repeating: UInt32(blockSize), count: small.nblocks)
    for b in 0..<small.nblocks where small.inUse[b] {
        let s = small.blockStart(b)
        var a = s &+ UInt(small.entryLow[b])
        let top = s &+ UInt(blockSize)
        while a < top {
            let e = wordPtr(a)
            if e[0] != 0 {
                if hdrMarked(e[0]) {
                    if liveLow[b] == UInt32(blockSize) { liveLow[b] = UInt32(a &- s) }
                } else {
                    e[0] = 0
                }
            }
            a &+= 16
        }
    }
    // 2. slide
    var db = 0
    var dcur = small.blockStart(0)
    var dend = dcur &+ UInt(liveLow[0])
    var liveBytes = 0, bytesMoved = 0, objsMoved = 0, nonLocal = 0, liveObjs = 0
    var destUsed = [Int](repeating: 0, count: small.nblocks)
    for b in 0..<small.nblocks where small.inUse[b] {
        var p = small.blockStart(b)
        let end = p &+ UInt(small.usedBytes(b))
        while p < end {
            let w0 = wordPtr(p).pointee
            let size = backrefSize(w0)
            let ea = om.table &+ UInt(backrefIndex(w0) &<< 4)
            // An entry below its block's lowest live entry is dead, and its
            // slot may already hold a moved body: do not read it.
            let eb = small.blockOf(ea)
            if ea &- small.blockStart(eb) >= UInt(liveLow[eb]) {
                let e = wordPtr(ea)
                if hdrMarked(e[0]) && e[1] == UInt64(p &- om.heap) {
                    while dcur &+ UInt(size) > dend {
                        destUsed[db] = Int(dcur &- small.blockStart(db))
                        db += 1
                        dcur = small.blockStart(db)
                        dend = dcur &+ UInt(liveLow[db])
                    }
                    if dcur != p {
                        memmove(UnsafeMutableRawPointer(bitPattern: dcur), UnsafeRawPointer(bitPattern: p), size)
                        bytesMoved &+= size
                        objsMoved &+= 1
                    }
                    if db != eb { nonLocal &+= 1 }
                    liveObjs &+= 1
                    e[1] = UInt64(dcur &- om.heap)
                    liveBytes &+= size
                    dcur &+= UInt(size)
                }
            }
            p &+= UInt(size)
        }
    }
    destUsed[db] = Int(dcur &- small.blockStart(db))
    // 3. block metadata: destinations hold bodies; any block with a live
    // entry stays in use; the rest are free.
    for b in 0..<small.nblocks {
        let u = b <= db ? destUsed[b] : 0
        let keep = u > 0 || liveLow[b] < UInt32(blockSize)
        small.used[b] = UInt32(u)
        small.entryLow[b] = liveLow[b]
        small.inUse[b] = keep
        small.live[b] = keep
    }
    let t2 = now()
    // 4. unmark, flag large blocks with live bodies, rebuild pools
    var live = 0
    forEachEntrySlot(vm) { _, e in
        let h = e[0]
        if h != 0 && hdrMarked(h) {
            e[0] = h & ~markBit
            live &+= objectBytes(h)
            let a = om.heap &+ UInt(e[1])
            if heap.large.contains(a) { heap.large.live[heap.large.blockOf(a)] = true }
        }
    }
    small.rebuildPool()
    heap.large.rebuildPool()
    vm.pointee.space.epoch.pointee &+= 1
    let t3 = now()
    pcsFromOffsets(vm)
    vm.pointee.space.counters[0] = UInt64(nonLocal)
    vm.pointee.space.counters[1] = UInt64(liveObjs)
    vm.set(.compactMarkNs, t1 &- t0)
    vm.set(.compactMoveNs, t2 &- t1)
    vm.set(.compactSweepNs, t3 &- t2)
    vm.set(.compactBytesMoved, UInt64(bytesMoved))
    vm.set(.compactObjectsMoved, UInt64(objsMoved))
    vm.set(.compactLiveBytes, UInt64(liveBytes))
    vm.set(.compactPcsFixed, UInt64(pcs))
    vm.set(.liveBytes, UInt64(live))
}

// MARK: - locality report (host side, not timed)

/// Fraction of in-use entries whose body is in the entry's own block, the
/// number of in-use entries, small and large blocks in use, and the last
/// compaction's counters. Reads the heap: call only with no worker running.
public func localityLine(_ vm: VMRef) -> String {
    let heap = vm.pointee.heap
    let om = vm.pointee.om
    var used = 0, local = 0, large = 0
    forEachEntrySlot(vm) { _, e in
        if e[0] == 0 { return }
        used += 1
        let a = om.heap &+ UInt(e[1])
        let ea = UInt(bitPattern: e)
        if heap.large.contains(a) { large += 1 }
        else if heap.small.blockOf(a) == heap.small.blockOf(ea) { local += 1 }
    }
    let frac = used > 0 ? Double(local) / Double(used) : 0
    return "entries_used=\(used) entries_local=\(local) local_frac=\((frac * 10000).rounded() / 10000) entries_large=\(large)"
        + " small_blocks=\(heap.small.inUseCount()) large_blocks=\(heap.large.inUseCount())"
        + " compact_nonlocal=\(vm.pointee.space.counters[0]) compact_live=\(vm.pointee.space.counters[1])"
}

/// For the tests: the entry and body addresses of an oop.
public func entryAndBody(_ vm: VMRef, _ o: Oop) -> (UInt, UInt) {
    let om = vm.pointee.om
    return (om.table &+ UInt(o), om.heap &+ UInt(om.entry(o)[1]))
}

// MARK: - snapshot

private let snapMagic: UInt64 = 0x4B414A4F_534E4150 // "KAJOSNAP"
private let fixedWords = 12

private func writeAll(_ f: UnsafeMutablePointer<FILE>, _ p: UnsafeRawPointer, _ n: Int) {
    if n > 0 && fwrite(p, 1, n, f) != n { fatal("snapshot write failed") }
}

private func readAll(_ f: UnsafeMutablePointer<FILE>, _ p: UnsafeMutableRawPointer, _ n: Int) {
    if n > 0 && fread(p, 1, n, f) != n { fatal("snapshot read failed") }
}

/// Raw dump: header, block metadata of both arenas, the small blocks
/// (entries and bodies together), the large blocks, symbol names.
func saveSnapshot(_ vm: VMRef, _ path: String) {
    let t0 = now()
    let heap = vm.pointee.heap
    guard let f = fopen(path, "wb") else { fatal("cannot write \(path)") }
    let last = heap.small.lastInUse(), llast = heap.large.lastInUse()
    var hdr: [UInt64] = [snapMagic, UInt64(variantName.utf8.first!), UInt64(heap.baseAddr),
                         UInt64(heap.small.nblocks), UInt64(last + 1), UInt64(llast + 1),
                         vm.pointee.nilObj, vm.pointee.trueObj, vm.pointee.falseObj,
                         UInt64(vm.pointee.classCount), UInt64(vm.pointee.roots.count), 0]
    for i in 0..<9 { hdr.append(vm.pointee.special[i]) }
    for i in 0..<globalCount { hdr.append(vm.pointee.globals[i]) }
    for i in 0..<vm.pointee.classCount { hdr.append(vm.pointee.classTable[i]) }
    for i in 0..<vm.pointee.roots.count { hdr.append(vm.pointee.roots.ptr[i]) }
    hdr.withUnsafeBytes { writeAll(f, $0.baseAddress!, $0.count) }
    var used = [UInt32](repeating: .max, count: last + 1)
    var low = [UInt32](repeating: UInt32(blockSize), count: last + 1)
    for b in 0..<(last + 1) where heap.small.isInUse(b) { used[b] = heap.small.used[b]; low[b] = heap.small.entryLow[b] }
    var lused = [UInt32](repeating: .max, count: llast + 1)
    for b in 0..<(llast + 1) where heap.large.isInUse(b) { lused[b] = heap.large.used[b] }
    used.withUnsafeBytes { writeAll(f, $0.baseAddress!, $0.count) }
    low.withUnsafeBytes { writeAll(f, $0.baseAddress!, $0.count) }
    lused.withUnsafeBytes { writeAll(f, $0.baseAddress!, $0.count) }
    writeAll(f, heap.base, (last + 1) * blockSize)
    writeAll(f, UnsafeRawPointer(bitPattern: heap.large.start)!, (llast + 1) * largeBlockSize)
    let names = Array(vm.pointee.symbolNames.joined(separator: "\n").utf8)
    var nlen = UInt64(names.count)
    writeAll(f, &nlen, 8)
    names.withUnsafeBytes { writeAll(f, $0.baseAddress!, $0.count) }
    let bytes = ftell(f)
    fclose(f)
    vm.set(.snapSaveNs, now() &- t0)
    vm.set(.snapBytes, UInt64(bytes))
}

/// Load into a fresh VM at a new base. Nothing is rewritten: entries hold
/// body offsets, oops are entry offsets, and there is no entry pool.
public func loadSnapshot(_ path: String) throws -> Image {
    guard let f = fopen(path, "rb") else { fatal("cannot read \(path)") }
    defer { fclose(f) }
    var fixed = [UInt64](repeating: 0, count: fixedWords)
    fixed.withUnsafeMutableBytes { readAll(f, $0.baseAddress!, $0.count) }
    if fixed[0] != snapMagic || fixed[1] != UInt64(variantName.utf8.first!) { fatal("not a \(variantName) snapshot") }
    let nblocks = Int(fixed[3]), nsaved = Int(fixed[4]), lsaved = Int(fixed[5])
    let classCount = Int(fixed[9]), nroots = Int(fixed[10])
    var rest = [UInt64](repeating: 0, count: 9 + globalCount + classCount + nroots)
    rest.withUnsafeMutableBytes { readAll(f, $0.baseAddress!, $0.count) }
    var used = [UInt32](repeating: 0, count: nsaved)
    var low = [UInt32](repeating: 0, count: nsaved)
    var lused = [UInt32](repeating: 0, count: lsaved)
    used.withUnsafeMutableBytes { readAll(f, $0.baseAddress!, $0.count) }
    low.withUnsafeMutableBytes { readAll(f, $0.baseAddress!, $0.count) }
    lused.withUnsafeMutableBytes { readAll(f, $0.baseAddress!, $0.count) }
    let vm = VMCore.create(heapSize: nblocks * blockSize)
    let t0 = now()
    readAll(f, vm.pointee.heap.base, nsaved * blockSize)
    readAll(f, UnsafeMutableRawPointer(bitPattern: vm.pointee.heap.large.start)!, lsaved * largeBlockSize)
    var nlen: UInt64 = 0
    readAll(f, &nlen, 8)
    var names = [UInt8](repeating: 0, count: Int(nlen))
    names.withUnsafeMutableBytes { if nlen > 0 { readAll(f, $0.baseAddress!, $0.count) } }
    vm.pointee.heap.small.restore(used: used, entryLow: low)
    vm.pointee.heap.large.restore(used: lused, entryLow: [UInt32](repeating: UInt32(largeBlockSize), count: lsaved))
    vm.pointee.nilObj = fixed[6]; vm.pointee.trueObj = fixed[7]; vm.pointee.falseObj = fixed[8]
    vm.pointee.classCount = classCount
    var k = 0
    for i in 0..<9 { vm.pointee.special[i] = rest[k]; k += 1 }
    for i in 0..<globalCount { vm.pointee.globals[i] = rest[k]; k += 1 }
    for i in 0..<classCount { vm.pointee.classTable[i] = rest[k]; k += 1 }
    for _ in 0..<nroots { vm.pointee.roots.push(rest[k]); k += 1 }
    vm.pointee.symbolNames = nlen == 0 ? [] : String(decoding: names, as: UTF8.self).split(separator: "\n").map(String.init)
    vm.set(.snapEntriesScanned, 0)
    vm.set(.snapRelocSlots, 0)
    vm.set(.snapRelocNs, now() &- t0)
    return Image(loaded: vm)
}

/// Heap words (small and large arenas) that differ between the file and
/// the loaded heap (not timed).
public func countChangedWords(_ vm: VMRef, _ path: String) -> Int {
    guard let f = fopen(path, "rb") else { return -1 }
    defer { fclose(f) }
    var fixed = [UInt64](repeating: 0, count: fixedWords)
    fixed.withUnsafeMutableBytes { readAll(f, $0.baseAddress!, $0.count) }
    let nsaved = Int(fixed[4]), lsaved = Int(fixed[5])
    let off = 8 * (fixedWords + 9 + globalCount + Int(fixed[9]) + Int(fixed[10])) + 4 * (2 * nsaved + lsaved)
    fseek(f, off, SEEK_SET)
    var c = 0
    for (addr, n) in [(vm.pointee.heap.baseAddr, nsaved * blockSize / 8),
                      (vm.pointee.heap.large.start, lsaved * largeBlockSize / 8)] where n > 0 {
        let buf = UnsafeMutablePointer<UInt64>.allocate(capacity: n)
        readAll(f, buf, n * 8)
        let h = wordPtr(addr)
        for i in 0..<n where buf[i] != h[i] { c += 1 }
        buf.deallocate()
    }
    return c
}
