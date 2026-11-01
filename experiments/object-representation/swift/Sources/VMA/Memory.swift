// Object memory for variant A: oop = pointer to the header word, become via
// forwarders (SPEC.md "Oop encodings", "Forwarders"). Compiled with
// OOP_OFFSET this file is variant C: oop = offset from the heap base (+8).
// Everything that knows how an oop reaches its object lives in this file.

import Darwin

#if OOP_OFFSET
public let variantName = "C"
#else
public let variantName = "A"
#endif
/// Shift applied to selector oops for cache and method-dict hashing (objects
/// are 8-byte aligned here).
let selShift: UInt64 = 3

// MARK: - oop <-> address

/// The accessor view loaded once per interpreter run. Empty in A; in C it
/// holds `heapBase - 8`.
public struct OM {
    #if OOP_OFFSET
    var base: UInt
    #endif

    @inline(__always) func addr(_ o: Oop) -> UInt {
        #if OOP_OFFSET
        base &+ UInt(truncatingIfNeeded: o)
        #else
        UInt(truncatingIfNeeded: o)
        #endif
    }
    @inline(__always) func oop(_ a: UInt) -> Oop {
        #if OOP_OFFSET
        Oop(a &- base)
        #else
        Oop(a)
        #endif
    }
    @inline(__always) func ptr(_ o: Oop) -> UnsafeMutablePointer<UInt64> { wordPtr(addr(o)) }
    @inline(__always) public func header(_ o: Oop) -> UInt64 { ptr(o).pointee }
    @inline(__always) func setHeader(_ o: Oop, _ h: UInt64) { ptr(o).pointee = h }
    @inline(__always) public func slot(_ o: Oop, _ i: Int) -> Oop { ptr(o)[1 &+ i] }
    @inline(__always) public func setSlot(_ o: Oop, _ i: Int, _ v: Oop) { ptr(o)[1 &+ i] = v }
    @inline(__always) func slotsPtr(_ o: Oop) -> UnsafeMutablePointer<UInt64> { ptr(o) + 1 }
    @inline(__always) func bytesPtr(_ o: Oop) -> UnsafeMutablePointer<UInt8> {
        UnsafeMutableRawPointer(ptr(o) + 1).assumingMemoryBound(to: UInt8.self)
    }
    @inline(__always) public func classIndexOf(_ v: Oop) -> UInt64 {
        isInt(v) ? UInt64(ciSmallInt) : hdrClass(header(v))
    }
}

/// Variant state beyond the block heap: none in A.
public struct Space {}
public struct WorkerSpace {}

func makeSpace(_ heap: Heap) -> (OM, Space) {
    #if OOP_OFFSET
    return (OM(base: heap.baseAddr &- 8), Space())
    #else
    return (OM(), Space())
    #endif
}

func entryRefills(_ w: WorkerRef) -> UInt64 { 0 }

// MARK: - allocation

@inline(__always)
func tlabAlloc(_ t: inout Tlab, _ om: OM, _ cls: UInt32, _ slots: Int, _ bytes: Bool, _ fill: Oop) -> Oop {
    let size = sizeFor(slots, bytes)
    if t.end &- t.cur < UInt(size) { return 0 }
    let p = wordPtr(t.cur)
    let o = om.oop(t.cur)
    t.cur &+= UInt(size)
    p.pointee = makeHeader(cls, slots, bytes)
    let n = (size &- 8) / 8
    let f = bytes ? 0 : fill
    var i = 1
    while i <= n { p[i] = f; i &+= 1 }
    return o
}

/// Allocate an object; may stop the world. `w`'s sp/pc/hdr must be flushed.
@inline(__always)
public func alloc(_ vm: VMRef, _ w: WorkerRef, _ cls: UInt32, _ slots: Int, _ bytes: Bool) -> Oop {
    let o = tlabAlloc(&w.pointee.tlab, vm.pointee.om, cls, slots, bytes, vm.pointee.nilObj)
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
    w.pointee.tlabRefills &+= 1
    return tlabAlloc(&w.pointee.tlab, vm.pointee.om, cls, slots, bytes, vm.pointee.nilObj)
}

/// Allocation inside a stop-the-world operation (never collects).
func opAlloc(_ vm: VMRef, _ cls: UInt32, _ slots: Int, _ bytes: Bool) -> Oop {
    let om = vm.pointee.om
    var o = tlabAlloc(&vm.pointee.opTlab, om, cls, slots, bytes, vm.pointee.nilObj)
    if o == 0 {
        if !vm.pointee.heap.refill(&vm.pointee.opTlab) { fatal("out of memory inside a safepoint operation") }
        o = tlabAlloc(&vm.pointee.opTlab, om, cls, slots, bytes, vm.pointee.nilObj)
    }
    return o
}

func retireBoot(_ vm: VMRef, _ w: WorkerRef) {
    vm.pointee.heap.retire(&w.pointee.tlab)
}

// MARK: - forwarders

@inline(__always) func isForwarder(_ om: OM, _ o: Oop) -> Bool {
    hdrClass(om.header(o)) == UInt64(ciForwarder)
}

/// Follow a forwarder chain to the real object (identity for non-forwarders).
func follow(_ om: OM, _ v: Oop) -> Oop {
    var o = v
    while !isInt(o) && isForwarder(om, o) { o = om.slot(o, 0) }
    return o
}

/// `a != b` already. True if they are the same object behind forwarders.
@inline(__always)
func maybeForwardedIdentical(_ om: OM, _ a: Oop, _ b: Oop) -> Bool {
    if (a | b) & 1 != 0 { return false }
    if !isForwarder(om, a) && !isForwarder(om, b) { return false }
    return identicalSlow(om, a, b)
}

@inline(never)
func identicalSlow(_ om: OM, _ a: Oop, _ b: Oop) -> Bool { follow(om, a) == follow(om, b) }

/// Turn `o` into a forwarder to `target`. Keeps size and format so the heap
/// stays walkable.
func makeForwarder(_ om: OM, _ o: Oop, _ target: Oop) {
    let h = om.header(o)
    om.setHeader(o, h & ~(classMask | markBit) | UInt64(ciForwarder))
    om.setSlot(o, 0, target)
}

/// Replace forwarder references in every root (worker stacks included).
func fixRootForwarders(_ vm: VMRef) -> Int {
    let om = vm.pointee.om
    var n = 0
    for (p, c) in rootRanges(vm) {
        for i in 0..<c {
            let v = p[i]
            if !isInt(v) && isForwarder(om, v) { p[i] = follow(om, v); n += 1 }
        }
    }
    return n
}

// MARK: - heap walk

/// Calls `body(address, headerWord)` for every object in every in-use block,
/// in address order. World stopped, TLABs retired.
@inline(__always)
func walkHeap(_ vm: VMRef, _ body: (UInt, UInt64) -> Void) {
    let heap = vm.pointee.heap
    for b in 0..<heap.nblocks where heap.isInUse(b) {
        var p = heap.blockStart(b)
        let end = p &+ UInt(heap.usedBytes(b))
        while p < end {
            let h = wordPtr(p).pointee
            body(p, h)
            p &+= UInt(objectBytes(h))
        }
    }
}

// MARK: - mark & sweep

/// Mark the object a slot refers to. A slot that refers to a forwarder is
/// first rewritten to the final target.
@inline(__always)
private func markSlot(_ om: OM, _ s: UnsafeMutablePointer<Oop>, _ stack: inout WordStack) {
    var v = s.pointee
    if v & 1 != 0 { return }
    var p = om.ptr(v)
    var h = p.pointee
    if hdrClass(h) == UInt64(ciForwarder) {
        repeat {
            v = p[1]
            if v & 1 != 0 { s.pointee = v; return }
            p = om.ptr(v)
            h = p.pointee
        } while hdrClass(h) == UInt64(ciForwarder)
        s.pointee = v
    }
    if !hdrMarked(h) {
        p.pointee = h | markBit
        if !hdrIsBytes(h) { stack.push(v) }
    }
}

func markAll(_ vm: VMRef) {
    let om = vm.pointee.om
    for (p, c) in rootRanges(vm) {
        for i in 0..<c { markSlot(om, p + i, &vm.pointee.markStack) }
        while let o = vm.pointee.markStack.pop() {
            let n = hdrSlots(om.header(o))
            let s = om.slotsPtr(o)
            var i = 0
            while i < n { markSlot(om, s + i, &vm.pointee.markStack); i &+= 1 }
        }
    }
}

/// Sweep: clear marks, return blocks without marked objects to the pool.
private func sweep(_ vm: VMRef) -> Int {
    let heap = vm.pointee.heap
    var liveBytes = 0
    for b in 0..<heap.nblocks where heap.isInUse(b) {
        var p = heap.blockStart(b)
        let end = p &+ UInt(heap.usedBytes(b))
        var live = false
        while p < end {
            let hp = wordPtr(p)
            let h = hp.pointee
            let size = objectBytes(h)
            if hdrMarked(h) {
                hp.pointee = h & ~markBit
                live = true
                liveBytes &+= size
            }
            p &+= UInt(size)
        }
        if live { heap.live[b] = true }
    }
    _ = heap.rebuildPool()
    return liveBytes
}

/// Full non-moving mark-sweep. World stopped, TLABs retired. Returns (mark ns, sweep ns).
func collect(_ vm: VMRef) -> (UInt64, UInt64) {
    let t0 = now()
    markAll(vm)
    let t1 = now()
    let live = sweep(vm)
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

/// Same refusal rule in every variant (SPEC.md "Forwarders"), plus A's
/// minimum body size for a forwarder.
private func checkBecomable(_ vm: VMRef, _ o: Oop) {
    let om = vm.pointee.om
    if isInt(o) || o == vm.pointee.nilObj || o == vm.pointee.trueObj || o == vm.pointee.falseObj {
        fatal("become: on an immediate or a constant")
    }
    let h = om.header(o)
    switch UInt32(hdrClass(h)) {
    case ciClass, ciMethod, ciMethodDict, ciSymbol, ciByteArray: fatal("become: on a protected class")
    default: break
    }
    if objectBytes(h) < 16 { fatal("become: object too small to forward") }
}

private func cloneObject(_ vm: VMRef, _ o: Oop) -> Oop {
    let om = vm.pointee.om
    let h = om.header(o)
    let c = opAlloc(vm, UInt32(hdrClass(h)), hdrSlots(h), hdrIsBytes(h))
    om.slotsPtr(c).update(from: om.slotsPtr(o), count: (objectBytes(h) - 8) / 8)
    return c
}

func becomeTwoWay(_ vm: VMRef, _ a0: Oop, _ b0: Oop) {
    let om = vm.pointee.om
    let a = follow(om, a0), b = follow(om, b0)
    if a == b { return }
    checkBecomable(vm, a)
    checkBecomable(vm, b)
    let ha = om.header(a), hb = om.header(b)
    if objectBytes(ha) == objectBytes(hb) {
        // Spur's shortcut: same size, swap contents in place, no forwarder.
        let pa = om.ptr(a), pb = om.ptr(b)
        for i in 0..<(objectBytes(ha) / 8) { let t = pa[i]; pa[i] = pb[i]; pb[i] = t }
        vm.add(.becomeSwapPath, 1)
        return
    }
    let ca = cloneObject(vm, a), cb = cloneObject(vm, b)
    makeForwarder(om, a, cb)
    makeForwarder(om, b, ca)
    _ = fixRootForwarders(vm)
    vm.add(.becomeFwdPath, 1)
}

/// Pairs from two Arrays of Arrays, element by element.
func forwardBulk(_ vm: VMRef, _ fromArrs: Oop, _ toArrs: Oop) {
    let om = vm.pointee.om
    let fa = follow(om, fromArrs), ta = follow(om, toArrs)
    let n = hdrSlots(om.header(fa))
    var pairs: UInt64 = 0
    for i in 0..<n {
        let fc = follow(om, om.slot(fa, i)), tc = follow(om, om.slot(ta, i))
        let m = hdrSlots(om.header(fc))
        for j in 0..<m {
            let f = follow(om, om.slot(fc, j)), t = follow(om, om.slot(tc, j))
            if f == t { continue }
            checkBecomable(vm, f)
            makeForwarder(om, f, t)
            pairs += 1
        }
    }
    _ = fixRootForwarders(vm)
    vm.add(.forwardPairs, pairs)
}

/// Add one instance variable to `cls`: every instance gets a new body, the
/// old one forwards to it (SPEC.md "Reshape").
func reshape(_ vm: VMRef, _ cls0: Oop) {
    let om = vm.pointee.om
    let cls = follow(om, cls0)
    let idx = UInt64(intVal(om.slot(cls, cIndex)))
    var list = WordStack(capacity: 1 << 16)
    walkHeap(vm) { p, h in
        if hdrClass(h) == idx && !hdrIsBytes(h) { list.push(om.oop(p)) }
    }
    let nilObj = vm.pointee.nilObj
    for k in 0..<list.count {
        let o = list.ptr[k]
        let h = om.header(o)
        let n = hdrSlots(h)
        if n == 0 { fatal("reshape: cannot forward a 0-slot instance") }
        let nb = opAlloc(vm, UInt32(idx), n + 1, false)
        om.slotsPtr(nb).update(from: om.slotsPtr(o), count: n)
        om.setSlot(nb, n, nilObj)
        makeForwarder(om, o, nb)
    }
    om.setSlot(cls, cInstSize, mkInt(intVal(om.slot(cls, cInstSize)) + 1))
    _ = fixRootForwarders(vm)
    vm.add(.reshapeCount, UInt64(list.count))
    list.ptr.deallocate()
}

// MARK: - compaction (Lisp-2, displaced headers)

/// Slide every live object down in block order. World stopped.
func compact(_ vm: VMRef) {
    let om = vm.pointee.om
    let heap = vm.pointee.heap
    let t0 = now()
    markAll(vm)
    let t1 = now()
    let pcs = pcsToOffsets(vm)
    // Plan: new address per live object, stored in its header word with the
    // mark bit; the real header goes to `side`, in walk order.
    var side = WordStack(capacity: 1 << 16)
    var destUsed = [Int](repeating: 0, count: heap.nblocks)
    var db = 0
    var dcur = heap.blockStart(0)
    var dend = dcur &+ UInt(blockSize)
    var liveBytes = 0
    var bytesMoved = 0
    var objsMoved = 0
    for b in 0..<heap.nblocks where heap.isInUse(b) {
        var p = heap.blockStart(b)
        let end = p &+ UInt(heap.usedBytes(b))
        while p < end {
            let hp = wordPtr(p)
            let h = hp.pointee
            let size = objectBytes(h)
            if hdrMarked(h) {
                if dcur &+ UInt(size) > dend {
                    destUsed[db] = Int(dcur &- heap.blockStart(db))
                    db += 1
                    dcur = heap.blockStart(db)
                    dend = dcur &+ UInt(blockSize)
                }
                side.push(h & ~markBit)
                hp.pointee = om.oop(dcur) | markBit
                if dcur != p { bytesMoved &+= size; objsMoved &+= 1 }
                liveBytes &+= size
                dcur &+= UInt(size)
            }
            p &+= UInt(size)
        }
    }
    destUsed[db] = Int(dcur &- heap.blockStart(db))
    let t2 = now()
    // Update: every pointer slot of every live object, then every root.
    var slots = 0
    var k = 0
    for b in 0..<heap.nblocks where heap.isInUse(b) {
        var p = heap.blockStart(b)
        let end = p &+ UInt(heap.usedBytes(b))
        while p < end {
            let w0 = wordPtr(p).pointee
            if w0 & markBit != 0 {
                let h = side.ptr[k]
                k &+= 1
                if !hdrIsBytes(h) {
                    let s = wordPtr(p) + 1
                    let n = hdrSlots(h)
                    var i = 0
                    while i < n {
                        let v = s[i]
                        if v & 1 == 0 { s[i] = om.ptr(v).pointee & ~markBit; slots &+= 1 }
                        i &+= 1
                    }
                }
                p &+= UInt(objectBytes(h))
            } else {
                p &+= UInt(objectBytes(w0))
            }
        }
    }
    for (rp, c) in rootRanges(vm) {
        for i in 0..<c {
            let v = rp[i]
            if v & 1 == 0 { rp[i] = om.ptr(v).pointee & ~markBit; slots &+= 1 }
        }
    }
    let t3 = now()
    // Move: slide each live object to its new address and restore its header.
    k = 0
    for b in 0..<heap.nblocks where heap.isInUse(b) {
        var p = heap.blockStart(b)
        let end = p &+ UInt(heap.usedBytes(b))
        while p < end {
            let w0 = wordPtr(p).pointee
            if w0 & markBit != 0 {
                let h = side.ptr[k]
                k &+= 1
                let size = objectBytes(h)
                let dest = om.addr(w0 & ~markBit)
                if dest != p {
                    memmove(UnsafeMutableRawPointer(bitPattern: dest), UnsafeRawPointer(bitPattern: p), size)
                }
                wordPtr(dest).pointee = h
                p &+= UInt(size)
            } else {
                p &+= UInt(objectBytes(w0))
            }
        }
    }
    for i in 0...db { heap.setDestination(i, bytes: destUsed[i]) }
    _ = heap.rebuildPool()
    let t4 = now()
    side.ptr.deallocate()
    pcsFromOffsets(vm)
    flushMethodCaches(vm) // LEAK(A): cache keys (selectors) and values (methods) are addresses that just moved
    // nil/true/false are the first three objects of block 0 and never move;
    // the interpreter keeps them in registers.
    if vm.pointee.roots.ptr[0] != vm.pointee.nilObj || vm.pointee.roots.ptr[2] != vm.pointee.falseObj {
        fatal("compaction moved a constant")
    }
    vm.set(.compactMarkNs, t1 &- t0)
    vm.set(.compactPlanNs, t2 &- t1)
    vm.set(.compactUpdateNs, t3 &- t2)
    vm.set(.compactMoveNs, t4 &- t3)
    vm.set(.compactBytesMoved, UInt64(bytesMoved))
    vm.set(.compactObjectsMoved, UInt64(objsMoved))
    vm.set(.compactLiveBytes, UInt64(liveBytes))
    vm.set(.compactSlotsUpdated, UInt64(slots))
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

/// Raw dump (SPEC.md "Snapshot"). World stopped, TLABs retired.
func saveSnapshot(_ vm: VMRef, _ path: String) {
    let t0 = now()
    let heap = vm.pointee.heap
    guard let f = fopen(path, "wb") else { fatal("cannot write \(path)") }
    let last = heap.lastInUse()
    var hdr: [UInt64] = [snapMagic, UInt64(variantName.utf8.first!), UInt64(heap.baseAddr),
                         UInt64(heap.nblocks), UInt64(last + 1),
                         vm.pointee.nilObj, vm.pointee.trueObj, vm.pointee.falseObj,
                         UInt64(vm.pointee.classCount), UInt64(vm.pointee.roots.count)]
    for i in 0..<9 { hdr.append(vm.pointee.special[i]) }
    for i in 0..<globalCount { hdr.append(vm.pointee.globals[i]) }
    for i in 0..<vm.pointee.classCount { hdr.append(vm.pointee.classTable[i]) }
    for i in 0..<vm.pointee.roots.count { hdr.append(vm.pointee.roots.ptr[i]) }
    hdr.withUnsafeBytes { writeAll(f, $0.baseAddress!, $0.count) }
    var used = [UInt32](repeating: .max, count: last + 1)
    for b in 0...last where heap.isInUse(b) { used[b] = UInt32(heap.usedBytes(b)) }
    used.withUnsafeBytes { writeAll(f, $0.baseAddress!, $0.count) }
    let heapBytes = (last + 1) * blockSize
    writeAll(f, heap.base, heapBytes)
    let names = Array(vm.pointee.symbolNames.joined(separator: "\n").utf8)
    var nlen = UInt64(names.count)
    writeAll(f, &nlen, 8)
    names.withUnsafeBytes { writeAll(f, $0.baseAddress!, $0.count) }
    let bytes = ftell(f)
    fclose(f)
    vm.set(.snapSaveNs, now() &- t0)
    vm.set(.snapBytes, UInt64(bytes))
}

/// Offset of the heap bytes in a snapshot file, from its header.
private func heapOffsetInFile(_ f: UnsafeMutablePointer<FILE>) -> Int {
    var fixed = [UInt64](repeating: 0, count: 10)
    fixed.withUnsafeMutableBytes { readAll(f, $0.baseAddress!, $0.count) }
    let nsaved = Int(fixed[4]), classCount = Int(fixed[8]), nroots = Int(fixed[9])
    return 8 * (10 + 9 + globalCount + classCount + nroots) + 4 * nsaved
}

/// Load into a fresh VM at a new base address.
public func loadSnapshot(_ path: String) throws -> Image {
    guard let f = fopen(path, "rb") else { fatal("cannot read \(path)") }
    defer { fclose(f) }
    var fixed = [UInt64](repeating: 0, count: 10)
    fixed.withUnsafeMutableBytes { readAll(f, $0.baseAddress!, $0.count) }
    if fixed[0] != snapMagic || fixed[1] != UInt64(variantName.utf8.first!) { fatal("not a \(variantName) snapshot") }
    let oldBase = UInt(fixed[2]), nblocks = Int(fixed[3]), nsaved = Int(fixed[4])
    let classCount = Int(fixed[8]), nroots = Int(fixed[9])
    var rest = [UInt64](repeating: 0, count: 9 + globalCount + classCount + nroots)
    rest.withUnsafeMutableBytes { readAll(f, $0.baseAddress!, $0.count) }
    var used = [UInt32](repeating: 0, count: nsaved)
    used.withUnsafeMutableBytes { readAll(f, $0.baseAddress!, $0.count) }
    let vm = VMCore.create(heapSize: nblocks * blockSize)
    readAll(f, vm.pointee.heap.base, nsaved * blockSize)
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
    #if !OOP_OFFSET
    // A: every pointer slot and every root word holds an absolute address.
    let delta = UInt64(vm.pointee.heap.baseAddr) &- UInt64(oldBase)
    var slots: UInt64 = 0
    if delta != 0 {
        walkHeap(vm) { p, h in
            if hdrIsBytes(h) { return }
            let s = wordPtr(p) + 1
            let n = hdrSlots(h)
            var i = 0
            while i < n {
                if s[i] & 1 == 0 { s[i] &+= delta; slots &+= 1 }
                i &+= 1
            }
        }
        var roots: UInt64 = 0
        for (p, c) in rootRanges(vm) {
            for i in 0..<c where p[i] & 1 == 0 && p[i] != 0 { p[i] &+= delta; roots += 1 }
        }
        vm.pointee.nilObj &+= delta; vm.pointee.trueObj &+= delta; vm.pointee.falseObj &+= delta
        vm.set(.snapRelocRoots, roots + 3)
    }
    vm.set(.snapRelocSlots, slots)
    #else
    _ = oldBase
    #endif
    vm.set(.snapRelocNs, now() &- t0)
    return Image(loaded: vm)
}

/// Heap words that differ between the file and the loaded heap (measured
/// confirmation of the relocation work; not timed).
public func countChangedWords(_ vm: VMRef, _ path: String) -> Int {
    guard let f = fopen(path, "rb") else { return -1 }
    defer { fclose(f) }
    let off = heapOffsetInFile(f)
    fseek(f, off, SEEK_SET)
    let n = (vm.pointee.heap.lastInUse() + 1) * blockSize / 8
    let buf = UnsafeMutablePointer<UInt64>.allocate(capacity: n)
    defer { buf.deallocate() }
    readAll(f, buf, n * 8)
    let h = vm.pointee.heap.base.assumingMemoryBound(to: UInt64.self)
    var c = 0
    for i in 0..<n where buf[i] != h[i] { c += 1 }
    return c
}
