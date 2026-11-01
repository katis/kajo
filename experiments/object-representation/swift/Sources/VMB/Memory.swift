// Object memory for variant B: oop = byte offset of a 16-byte entry in an
// object table; the entry holds the header and the body's heap offset; the
// body starts with a back reference (SPEC.md "Oop encodings").
// Everything that knows how an oop reaches its object lives in this file.

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
        if gcs > 3 { fatal("out of memory") }
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

/// A body allocated inside a stop-the-world operation (never collects).
/// Returns its address; the caller writes the backref and slots.
private func opBody(_ vm: VMRef, _ size: Int) -> UInt {
    var t = vm.pointee.opTlab
    if t.end &- t.cur < UInt(size) {
        if !vm.pointee.heap.refill(&t) { fatal("out of memory inside a safepoint operation") }
    }
    let p = t.cur
    t.cur &+= UInt(size)
    vm.pointee.opTlab = t
    return p
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

func performOp(_ vm: VMRef, _ w: WorkerRef, _ op: SafeOp) -> Oop {
    switch op {
    case .gc(let tag): timedCollect(vm, tag: tag)
    case .become(let a, let b): becomeTwoWay(vm, a, b)
    case .forward(let f, let t): forwardBulk(vm, f, t)
    case .reshape(let c): reshape(vm, c)
    case .compact: compact(vm)
    case .snapshot: saveSnapshot(vm, vm.pointee.snapshotPath)
    }
    return 0
}

/// Same refusal rule as A (SPEC.md "Forwarders"); B has no size minimum.
private func checkBecomable(_ vm: VMRef, _ o: Oop) {
    if isInt(o) || o == vm.pointee.nilObj || o == vm.pointee.trueObj || o == vm.pointee.falseObj {
        fatal("become: on an immediate or a constant")
    }
    switch UInt32(hdrClass(vm.pointee.om.header(o))) {
    case ciClass, ciMethod, ciMethodDict, ciSymbol, ciByteArray: fatal("become: on a protected class")
    default: break
    }
}

/// Swap the two entries and the two bodies' back references.
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

/// A transient forwarding entry during a bulk forward: class 0, one "slot",
/// word 1 = target. Never visible outside the operation.
private let forwardingHeader = makeHeader(ciForwarder, 1, false)

/// One-way become of every pair, then one scan over every live object and
/// every root to rewrite references (SPEC.md "Deviation").
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
    let hwm = hwmNow(vm)
    for idx in 1..<hwm {
        let e = om.entry(UInt64(idx) &<< 4)
        let h = e[0]
        if h == 0 || h == forwardingHeader || hdrIsBytes(h) { continue }
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
    for k in 0..<froms.count { om.entry(froms.ptr[k])[0] = 0 } // freed; pooled by the next sweep
    vm.add(.forwardPairs, UInt64(froms.count))
    vm.add(.forwardScanSlots, scanned)
    froms.ptr.deallocate()
}

/// Add one instance variable to `cls`: table scan, new bodies, entries
/// repointed. No forwarders; the old bodies are garbage.
func reshape(_ vm: VMRef, _ cls: Oop) {
    let om = vm.pointee.om
    let idx = UInt64(intVal(om.slot(cls, cIndex)))
    let nilObj = vm.pointee.nilObj
    let hwm = hwmNow(vm)
    var list = WordStack(capacity: 1 << 16)
    for i in 1..<hwm {
        let h = om.entry(UInt64(i) &<< 4)[0]
        if h != 0 && hdrClass(h) == idx && !hdrIsBytes(h) { list.push(UInt64(i) &<< 4) }
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

// MARK: - compaction (one pass, entries repointed through back references)

func compact(_ vm: VMRef) {
    let om = vm.pointee.om
    let heap = vm.pointee.heap
    let t0 = now()
    markAll(vm)
    let t1 = now()
    let pcs = pcsToOffsets(vm)
    var db = 0
    var dcur = heap.blockStart(0)
    var dend = dcur &+ UInt(blockSize)
    var liveBytes = 0, bytesMoved = 0, objsMoved = 0
    var destUsed = [Int](repeating: 0, count: heap.nblocks)
    for b in 0..<heap.nblocks where heap.isInUse(b) {
        var p = heap.blockStart(b)
        let end = p &+ UInt(heap.usedBytes(b))
        while p < end {
            let w0 = wordPtr(p).pointee
            let size = backrefSize(w0)
            let e = om.entry(backrefIndex(w0) &<< 4)
            if hdrMarked(e[0]) && e[1] == UInt64(p &- om.heap) {
                if dcur &+ UInt(size) > dend {
                    destUsed[db] = Int(dcur &- heap.blockStart(db))
                    db += 1
                    dcur = heap.blockStart(db)
                    dend = dcur &+ UInt(blockSize)
                }
                if dcur != p {
                    memmove(UnsafeMutableRawPointer(bitPattern: dcur), UnsafeRawPointer(bitPattern: p), size)
                    bytesMoved &+= size
                    objsMoved &+= 1
                }
                e[1] = UInt64(dcur &- om.heap)
                liveBytes &+= size
                dcur &+= UInt(size)
            }
            p &+= UInt(size)
        }
    }
    destUsed[db] = Int(dcur &- heap.blockStart(db))
    for i in 0...db { heap.setDestination(i, bytes: destUsed[i]) }
    _ = heap.rebuildPool()
    let t2 = now()
    _ = sweepTable(vm, blocks: false)
    let t3 = now()
    pcsFromOffsets(vm)
    vm.set(.compactMarkNs, t1 &- t0)
    vm.set(.compactMoveNs, t2 &- t1)
    vm.set(.compactSweepNs, t3 &- t2)
    vm.set(.compactBytesMoved, UInt64(bytesMoved))
    vm.set(.compactObjectsMoved, UInt64(objsMoved))
    vm.set(.compactLiveBytes, UInt64(liveBytes))
    vm.set(.compactPcsFixed, UInt64(pcs))
    vm.set(.liveBytes, UInt64(liveBytes))
}

// MARK: - snapshot

private let snapMagic: UInt64 = 0x4B414A4F_534E4150 // "KAJOSNAP"

private func writeAll(_ f: UnsafeMutablePointer<FILE>, _ p: UnsafeRawPointer, _ n: Int) {
    if fwrite(p, 1, n, f) != n { fatal("snapshot write failed") }
}

private func readAll(_ f: UnsafeMutablePointer<FILE>, _ p: UnsafeMutableRawPointer, _ n: Int) {
    if fread(p, 1, n, f) != n { fatal("snapshot read failed") }
}

/// Raw dump: header, block metadata, heap, table, symbol names.
func saveSnapshot(_ vm: VMRef, _ path: String) {
    let t0 = now()
    let heap = vm.pointee.heap
    guard let f = fopen(path, "wb") else { fatal("cannot write \(path)") }
    let last = heap.lastInUse()
    let hwm = hwmNow(vm)
    var hdr: [UInt64] = [snapMagic, UInt64(variantName.utf8.first!), UInt64(heap.baseAddr),
                         UInt64(heap.nblocks), UInt64(last + 1),
                         vm.pointee.nilObj, vm.pointee.trueObj, vm.pointee.falseObj,
                         UInt64(vm.pointee.classCount), UInt64(vm.pointee.roots.count), UInt64(hwm)]
    for i in 0..<9 { hdr.append(vm.pointee.special[i]) }
    for i in 0..<globalCount { hdr.append(vm.pointee.globals[i]) }
    for i in 0..<vm.pointee.classCount { hdr.append(vm.pointee.classTable[i]) }
    for i in 0..<vm.pointee.roots.count { hdr.append(vm.pointee.roots.ptr[i]) }
    hdr.withUnsafeBytes { writeAll(f, $0.baseAddress!, $0.count) }
    var used = [UInt32](repeating: .max, count: last + 1)
    for b in 0...last where heap.isInUse(b) { used[b] = UInt32(heap.usedBytes(b)) }
    used.withUnsafeBytes { writeAll(f, $0.baseAddress!, $0.count) }
    writeAll(f, heap.base, (last + 1) * blockSize)
    writeAll(f, UnsafeRawPointer(bitPattern: vm.pointee.om.table)!, hwm * 16)
    let names = Array(vm.pointee.symbolNames.joined(separator: "\n").utf8)
    var nlen = UInt64(names.count)
    writeAll(f, &nlen, 8)
    names.withUnsafeBytes { writeAll(f, $0.baseAddress!, $0.count) }
    let bytes = ftell(f)
    fclose(f)
    vm.set(.snapSaveNs, now() &- t0)
    vm.set(.snapBytes, UInt64(bytes))
}

private func heapOffsetInFile(_ f: UnsafeMutablePointer<FILE>) -> (Int, Int, Int) {
    var fixed = [UInt64](repeating: 0, count: 11)
    fixed.withUnsafeMutableBytes { readAll(f, $0.baseAddress!, $0.count) }
    let nsaved = Int(fixed[4]), classCount = Int(fixed[8]), nroots = Int(fixed[9]), hwm = Int(fixed[10])
    return (8 * (11 + 9 + globalCount + classCount + nroots) + 4 * nsaved, nsaved, hwm)
}

/// Load into a fresh VM (new heap and new table at new addresses). No slot
/// or entry is rewritten; only the free-entry pool is rebuilt.
public func loadSnapshot(_ path: String) throws -> Image {
    guard let f = fopen(path, "rb") else { fatal("cannot read \(path)") }
    defer { fclose(f) }
    var fixed = [UInt64](repeating: 0, count: 11)
    fixed.withUnsafeMutableBytes { readAll(f, $0.baseAddress!, $0.count) }
    if fixed[0] != snapMagic || fixed[1] != UInt64(variantName.utf8.first!) { fatal("not a \(variantName) snapshot") }
    let nblocks = Int(fixed[3]), nsaved = Int(fixed[4])
    let classCount = Int(fixed[8]), nroots = Int(fixed[9]), hwm = Int(fixed[10])
    var rest = [UInt64](repeating: 0, count: 9 + globalCount + classCount + nroots)
    rest.withUnsafeMutableBytes { readAll(f, $0.baseAddress!, $0.count) }
    var used = [UInt32](repeating: 0, count: nsaved)
    used.withUnsafeMutableBytes { readAll(f, $0.baseAddress!, $0.count) }
    let vm = VMCore.create(heapSize: nblocks * blockSize)
    readAll(f, vm.pointee.heap.base, nsaved * blockSize)
    readAll(f, UnsafeMutableRawPointer(bitPattern: vm.pointee.om.table)!, hwm * 16)
    var nlen: UInt64 = 0
    readAll(f, &nlen, 8)
    var names = [UInt8](repeating: 0, count: Int(nlen))
    names.withUnsafeMutableBytes { if nlen > 0 { readAll(f, $0.baseAddress!, $0.count) } }
    vm.pointee.heap.restore(used: used)
    vm.pointee.nilObj = fixed[5]; vm.pointee.trueObj = fixed[6]; vm.pointee.falseObj = fixed[7]
    vm.pointee.classCount = classCount
    var k = 0
    for i in 0..<9 { vm.pointee.special[i] = rest[k]; k += 1 }
    for i in 0..<globalCount { vm.pointee.globals[i] = rest[k]; k += 1 }
    for i in 0..<classCount { vm.pointee.classTable[i] = rest[k]; k += 1 }
    for _ in 0..<nroots { vm.pointee.roots.push(rest[k]); k += 1 }
    vm.pointee.symbolNames = nlen == 0 ? [] : String(decoding: names, as: UTF8.self).split(separator: "\n").map(String.init)
    let t0 = now()
    vm.pointee.space.hwm.pointee.store(hwm, ordering: .relaxed)
    // Rebuild the free-entry pool (free entries have header 0). Touches only
    // the table's free entries' link words, no slot and no live entry.
    let om = vm.pointee.om
    let sp = vm.pointee.space
    var head: UInt64 = 0, len = 0, runs = 0
    for idx in 1..<max(hwm, 1) where om.entry(UInt64(idx) &<< 4)[0] == 0 {
        let o = UInt64(idx) &<< 4
        om.entry(o)[1] = head
        head = o
        len += 1
        if len == runLength { sp.runs[runs] = head; runs += 1; head = 0; len = 0 }
    }
    if len > 0 { sp.runs[runs] = head; runs += 1 }
    sp.runCount.pointee.store(runs, ordering: .relaxed)
    sp.runNext.pointee.store(0, ordering: .relaxed)
    vm.set(.snapEntriesScanned, UInt64(max(hwm - 1, 0)))
    vm.set(.snapRelocSlots, 0)
    vm.set(.snapRelocNs, now() &- t0)
    return Image(loaded: vm)
}

/// Heap words that differ between the file and the loaded heap (not timed).
public func countChangedWords(_ vm: VMRef, _ path: String) -> Int {
    guard let f = fopen(path, "rb") else { return -1 }
    defer { fclose(f) }
    let (off, nsaved, _) = heapOffsetInFile(f)
    fseek(f, off, SEEK_SET)
    let n = nsaved * blockSize / 8
    let buf = UnsafeMutablePointer<UInt64>.allocate(capacity: n)
    defer { buf.deallocate() }
    readAll(f, buf, n * 8)
    let h = vm.pointee.heap.base.assumingMemoryBound(to: UInt64.self)
    var c = 0
    for i in 0..<n where buf[i] != h[i] { c += 1 }
    return c
}
