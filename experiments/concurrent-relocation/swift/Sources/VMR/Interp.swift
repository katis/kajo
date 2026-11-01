// The bytecode interpreter and primitives. Copied from
// ../object-representation (variant B) and changed for Processes
// (SPEC.md "Leaving the interpreter", "Budget and preemption"):
// - polls decrement a per-worker countdown; the slow path checks the budget;
// - any path that suspends the Process hands `run` registers pointing at the
//   one-byte `leave` code, so `run` returns to the worker's scheduler loop;
// - the bottom frame's return terminates the Process;
// - the GC is non-moving, so variant B's `moved`/resync check is gone.
// Copied from ../ui-thread-scheduling; adds the write barrier to store_ivar
// and at:put: and the scavenge/fullGC primitives (SPEC.md "Write barrier").
// This experiment puts the SATB barrier in front of both stores.
// Young bodies move at a scavenge, but only through their entries: the
// interpreter re-derives every body address from the entry, and the raw
// pointers it keeps (pc, literals) point into methods, which are always old.

/// Interpreter registers. Passed by value into always-inline helpers so they
/// stay in machine registers.
struct Regs {
    var pc: UnsafePointer<UInt8>
    var sp: UnsafeMutablePointer<UInt64>
    var fp: UnsafeMutablePointer<UInt64>
    var hdr: UnsafeMutablePointer<UInt64>
    var lits: UnsafePointer<UInt64>
}

/// Registers that make `run` execute the `leave` opcode and return.
@inline(__always)
private func exitRegs(_ vm: VMRef, _ r: Regs) -> Regs {
    Regs(pc: UnsafePointer(vm.pointee.exitCode), sp: r.sp, fp: r.fp, hdr: r.hdr, lits: r.lits)
}

@inline(__always)
private func activate(_ vm: VMRef, _ w: WorkerRef, _ om: OM, _ r: Regs, _ method: Oop, _ argc: Int) -> Regs {
    let fp = r.sp - argc
    let nt = Int(truncatingIfNeeded: intVal(om.slot(method, mNTemps)))
    let maxStack = Int(truncatingIfNeeded: intVal(om.slot(method, mMaxStack)))
    var sp = r.sp
    if sp + (nt &+ 4 &+ maxStack) >= w.pointee.stackEnd { return stackOverflow(vm, w, r) }
    let nilObj = vm.pointee.nilObj
    var i = 0
    while i < nt {
        sp += 1
        sp.pointee = nilObj
        i &+= 1
    }
    let hdr = sp + 1
    hdr[0] = method
    hdr[1] = tagAddr(r.pc)
    hdr[2] = tagAddr(UnsafePointer(r.fp))
    hdr[3] = tagAddr(UnsafePointer(r.hdr))
    return Regs(pc: UnsafePointer(om.bytesPtr(om.slot(method, mBytecodes))), // RAW
                sp: hdr + 3, fp: fp, hdr: hdr,
                lits: UnsafePointer(om.slotsPtr(om.slot(method, mLiterals)))) // RAW
}

/// No room for the next frame: the Process is terminated (SPEC.md "Stack
/// overflow").
@inline(never)
private func stackOverflow(_ vm: VMRef, _ w: WorkerRef, _ r: Regs) -> Regs {
    w.pointee.leave = Leave.overflow
    return exitRegs(vm, r)
}

@inline(__always)
private func doReturn(_ om: OM, _ r: Regs, _ v: Oop) -> Regs {
    let fp = untagPtr(r.hdr[2], UInt64.self)
    let hdr = untagPtr(r.hdr[3], UInt64.self)
    r.fp.pointee = v
    return Regs(pc: UnsafePointer(untagPtr(r.hdr[1], UInt8.self)), sp: r.fp, fp: fp, hdr: hdr,
                lits: UnsafePointer(om.slotsPtr(om.slot(hdr[0], mLiterals)))) // RAW
}

@inline(__always)
private func flush(_ w: WorkerRef, _ r: Regs) {
    w.pointee.sp = r.sp
    w.pointee.pc = UInt(bitPattern: r.pc)
    w.pointee.hdr = r.hdr
    w.pointee.fp = r.fp
}

/// The safepoint poll at sends and backward jumps. True: the Process was
/// suspended (or must end) and `run` must leave. `rewind` bytes take pc back
/// to the start of the instruction that polled, so a resumed Process
/// re-executes it.
@_transparent
private func poll(_ vm: VMRef, _ w: WorkerRef, _ r: Regs, _ rewind: Int) -> Bool {
    #if NO_BUDGET
    if vm.pointee.gcRequested.load(ordering: .relaxed) {
        return pollSlow(vm, w, r.sp, r.pc - rewind, r.fp, r.hdr)
    }
    #else
    let c = w.pointee.countdown &- 1
    w.pointee.countdown = c
    if c == 0 || vm.pointee.gcRequested.load(ordering: .relaxed) {
        return pollSlow(vm, w, r.sp, r.pc - rewind, r.fp, r.hdr)
    }
    #endif
    return false
}

/// Takes scalars so the hot path never materialises `Regs` in memory.
@inline(never)
private func pollSlow(_ vm: VMRef, _ w: WorkerRef, _ sp: UnsafeMutablePointer<UInt64>, _ pc: UnsafePointer<UInt8>,
                      _ fp: UnsafeMutablePointer<UInt64>, _ hdr: UnsafeMutablePointer<UInt64>) -> Bool {
    w.pointee.sp = sp
    w.pointee.pc = UInt(bitPattern: pc)
    w.pointee.hdr = hdr
    w.pointee.fp = fp
    if vm.pointee.gcRequested.load(ordering: .relaxed) { safepoint(vm, w) }
    if w.pointee.countdown <= 0 {
        advanceEpoch(vm, w) // every pollEvery polls (SPEC.md "Freeing old blocks")
        pendingFull(vm, w)
        w.pointee.countdown = w.pointee.pollEvery
        return budgetCheck(vm, w)
    }
    return false
}

@_transparent
private func send(_ vm: VMRef, _ w: WorkerRef, _ om: OM, _ r: Regs, _ sel: Oop, _ argc: Int, _ rewind: Int) -> Regs {
    if poll(vm, w, r, rewind) { return exitRegs(vm, r) }
    let recvSlot = r.sp - argc
    let cls = om.classIndexOf(recvSlot.pointee)
    let e = w.pointee.cache + (Int(truncatingIfNeeded: (sel &>> selShift) ^ cls) & (cacheSize - 1))
    let method: Oop
    if e.pointee.cls == cls && e.pointee.sel == sel {
        method = e.pointee.method
    } else {
        method = lookupMiss(vm, w, cls, sel, recvSlot)
    }
    let prim = om.slot(method, mPrim)
    if prim != mkInt(0) {
        flush(w, r)
        let res = primitive(vm, w, intVal(prim), r.sp, argc)
        if w.pointee.leave != 0 { return exitRegs(vm, r) }
        var out = r
        out.sp = r.sp - argc
        out.sp.pointee = res
        return out
    }
    return activate(vm, w, om, r, method, argc)
}

/// Arithmetic and comparison fallbacks: the special bytecode is one byte.
@inline(never)
private func sendSlow(_ vm: VMRef, _ w: WorkerRef, _ r: Regs, _ sel: Oop, _ argc: Int) -> Regs {
    send(vm, w, vm.pointee.om, r, sel, argc, 1)
}

/// Cache miss: full lookup and cache fill.
@inline(never)
private func lookupMiss(_ vm: VMRef, _ w: WorkerRef, _ cls: UInt64, _ sel: Oop, _ recvSlot: UnsafeMutablePointer<Oop>) -> Oop {
    let e = w.pointee.cache + (Int(truncatingIfNeeded: (sel &>> selShift) ^ cls) & (cacheSize - 1))
    if e.pointee.cls == cls && e.pointee.sel == sel { return e.pointee.method }
    w.pointee.misses &+= 1
    let m = lookup(vm, cls, sel)
    if m == 0 { fatal("doesNotUnderstand \(symbolName(vm, sel))") }
    e.pointee.cls = cls
    e.pointee.sel = sel
    e.pointee.method = m
    return m
}

/// `w.sp/pc/hdr/fp` are flushed. A primitive that suspends the Process sets
/// `w.leave` after saving it (Process.swift).
@inline(never)
private func primitive(_ vm: VMRef, _ w: WorkerRef, _ prim: Int64, _ sp: UnsafeMutablePointer<UInt64>, _ argc: Int) -> Oop {
    let om = vm.pointee.om
    let base = sp - argc
    let recv = base.pointee
    func arg(_ i: Int) -> Oop { base[1 + i] }
    switch prim {
    case 1, 2:
        let idx = arg(0)
        if isInt(recv) || !isInt(idx) { fatal("at: bad receiver or index") }
        let h = om.header(recv)
        let i = intVal(idx)
        if i < 1 || i > Int64(hdrSlots(h)) { fatal("at: index out of bounds") }
        let j = Int(i) - 1
        if hdrIsBytes(h) {
            if prim == 2 { fatal("at:put: on bytes") }
            return mkInt(Int64(om.bytesPtr(recv)[j]))
        } else if prim == 1 {
            return om.slot(recv, j)
        } else {
            satbPre(vm, w, recv, j) // barrier site: at:put: (SATB)
            setSlotAndBarrier(vm, w, om, recv, j, arg(1)) // post-store check, barrier site: at:put:
            return arg(1)
        }
    case 3, 4:
        if isInt(recv) || hdrClass(om.header(recv)) != UInt64(ciClass) { fatal("basicNew on non-class") }
        var extra = 0
        if prim == 3 {
            let n = arg(0)
            if !isInt(n) || intVal(n) < 0 { fatal("basicNew: bad size") }
            extra = Int(intVal(n))
        }
        let n = Int(intVal(om.slot(recv, cInstSize))) + extra
        let cls = UInt32(intVal(om.slot(recv, cIndex)))
        return alloc(vm, w, cls, n, false)
    case 5:
        return classAt(vm, om.classIndexOf(recv))
    case 6, 7:
        let bv = arg(0)
        if !isInt(recv) || !isInt(bv) || intVal(bv) == 0 { fatal("// or \\\\ failed") }
        let a = intVal(recv), b = intVal(bv)
        let q = a / b
        let fq = (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q
        if !fitsInt(fq) { fatal("// overflow") }
        return mkInt(prim == 6 ? fq : a - fq * b)
    case 14, 15: // globalAt: / globalAt:put:
        let i = arg(0)
        if !isInt(i) || intVal(i) < 1 || intVal(i) > Int64(globalCount) { fatal("bad global index") }
        if prim == 14 { return vm.pointee.globals[Int(intVal(i)) - 1] }
        vm.pointee.globals[Int(intVal(i)) - 1] = arg(1)
        return arg(1)
    case 20: // fork:with:priority:main:exit:
        let prio = isInt(arg(2)) ? Int(intVal(arg(2))) : currentPriority(vm, w)
        return createProcess(vm, w, recv, arg(0), arg(1), priority: prio,
                             main: arg(3) == vm.pointee.trueObj, exitSem: arg(4))
    case 21: return primYield(vm, w, argc)
    case 22: return primWait(vm, w, recv, argc)
    case 23: semaphoreSignal(vm, w, recv); return recv
    case 24: return primTerminate(vm, w, recv, argc)
    case 25: return primDelay(vm, w, arg(0), arg(1))
    case 26: return primReadFile(vm, w, arg(0), arg(1))
    case 27: return primIoResult(vm, w, arg(0))
    case 28: return primNextEvent(vm, w)
    case 29, 30, 31: return primUI(vm, w, Int(prim - 29), argc == 1 ? arg(0) : mkInt(0), argc)
    case 32: return primDetach(vm, w, argc)
    case 33: return w.pointee.current
    case 34: return mkInt(Int64(w.pointee.id))
    case 35: stopWorld(vm, w, .scavenge, retry: true); return vm.pointee.nilObj
    case 36: stopWorld(vm, w, .full, retry: true); return vm.pointee.nilObj
    case 38: // replaceFrom:to:with:startingAt: (pointer slots), hazard slots 0 and 1
        return primArrayCopy(vm, w, recv, arg(0), arg(1), arg(2), arg(3))
    case 37: // ohBuilt: record when a build phase ended (latest wins)
        let t = now()
        var cur = vm.metric(.buildDoneAt)
        while cur < t {
            let (ok, v) = vm.pointee.metrics[Metric.buildDoneAt.rawValue].compareExchange(expected: cur, desired: t, ordering: .relaxed)
            if ok { break }
            cur = v
        }
        return vm.pointee.nilObj
    default:
        fatal("unknown primitive \(prim)")
    }
}

/// Run the worker's current Process from its saved registers until it
/// leaves (`w.leave` says why).
func resumeCurrent(_ vm: VMRef, _ w: WorkerRef) {
    let om = vm.pointee.om
    let p = w.pointee.current
    let hdr = untagPtr(om.slot(p, pHdr), UInt64.self)
    let r = Regs(pc: UnsafePointer(untagPtr(om.slot(p, pPc), UInt8.self)),
                 sp: untagPtr(om.slot(p, pSp), UInt64.self),
                 fp: untagPtr(om.slot(p, pFp), UInt64.self),
                 hdr: hdr,
                 lits: UnsafePointer(om.slotsPtr(om.slot(hdr[0], mLiterals)))) // RAW
    run(vm, w, r)
}

/// Build a Process's bottom frame `recv sel: arg` on its fresh stack and
/// save it as the Process's registers. `base[0]` is an unused nil word.
func buildBottomFrame(_ vm: VMRef, _ w: WorkerRef, _ p: Oop, _ base: UnsafeMutablePointer<UInt64>, _ recv: Oop, _ method: Oop, _ args: [Oop]) {
    let om = vm.pointee.om
    let nilObj = vm.pointee.nilObj
    base[0] = nilObj
    var sp = base + 1
    sp.pointee = recv
    let fp = sp
    for a in args { sp += 1; sp.pointee = a }
    let nt = Int(intVal(om.slot(method, mNTemps)))
    for _ in 0..<nt { sp += 1; sp.pointee = nilObj }
    let hdr = sp + 1
    hdr[0] = method
    hdr[1] = mkInt(0)
    hdr[2] = hostFP
    hdr[3] = mkInt(0)
    sp = hdr + 3
    setSlot(w, om, p, pSp, tagAddr(UnsafePointer(sp)))
    setSlot(w, om, p, pPc, tagAddr(UnsafePointer(om.bytesPtr(om.slot(method, mBytecodes))))) // RAW: bytecodes are pinned
    setSlot(w, om, p, pFp, tagAddr(UnsafePointer(fp)))
    setSlot(w, om, p, pHdr, tagAddr(UnsafePointer(hdr)))
}

let hostFP: UInt64 = 1 // mkInt(0)

@inline(never)
private func bottomReturn(_ w: WorkerRef, _ r: Regs, _ v: Oop) {
    w.pointee.sp = r.fp - 1
    w.pointee.hdr = nil
    w.pointee.fp = nil
    w.pointee.leave = Leave.terminated
    w.pointee.result = v
}

@inline(__always)
private func push(_ r: inout Regs, _ v: Oop) {
    r.sp += 1
    r.sp.pointee = v
}

@inline(__always)
private func byte(_ r: inout Regs) -> UInt8 {
    let b = r.pc.pointee
    r.pc += 1
    return b
}

@inline(__always)
private func offset(_ r: inout Regs) -> Int {
    let o = Int16(bitPattern: UInt16(r.pc[0]) | (UInt16(r.pc[1]) &<< 8))
    r.pc += 2
    return Int(o)
}

@inline(__always)
private func compare(_ vm: VMRef, _ w: WorkerRef, _ r: inout Regs, _ idx: Int, _ op: (Int64, Int64) -> Bool) {
    let b = r.sp.pointee
    let a = (r.sp - 1).pointee
    if a & b & 1 != 0 {
        r.sp -= 1
        r.sp.pointee = op(Int64(bitPattern: a), Int64(bitPattern: b)) ? vm.pointee.trueObj : vm.pointee.falseObj
    } else {
        r = sendSlow(vm, w, r, vm.pointee.special[idx], 1)
    }
}

private func run(_ vm: VMRef, _ w: WorkerRef, _ start: Regs) {
    var r = start
    let om = vm.pointee.om
    let nilObj = vm.pointee.nilObj, t = vm.pointee.trueObj, f = vm.pointee.falseObj
    let special = vm.pointee.special
    while true {
        let op = byte(&r)
        switch op {
        case 0x00: // push_temp
            let n = Int(byte(&r))
            push(&r, r.fp[1 &+ n])
        case 0x01: // push_lit
            let n = Int(byte(&r))
            push(&r, r.lits[n])
        case 0x02: // push_self
            push(&r, r.fp.pointee)
        case 0x03: // push_ivar
            let n = Int(byte(&r))
            push(&r, om.slot(r.fp.pointee, n))
        case 0x04: // store_temp
            let n = Int(byte(&r))
            r.fp[1 &+ n] = r.sp.pointee
            r.sp -= 1
        case 0x05: // store_ivar (barrier site)
            let n = Int(byte(&r))
            let o = r.fp.pointee, v = r.sp.pointee
            #if !NO_MARK_BARRIER
            // While marking, one out-of-line call does the SATB record, the
            // store and the generational barrier, so nothing of this
            // instruction is live across a call (keeping the SATB call
            // separate spilled the table and heap bases out of registers
            // for the whole loop: +20 percent on ivars).
            if w.pointee.marking != 0 {
                storeWhileMarking(w, o, n, v)
            } else {
                setSlotAndBarrier(vm, w, om, o, n, v) // post-store check, barrier site
            }
            #else
            setSlotAndBarrier(vm, w, om, o, n, v) // post-store check, barrier site
            #endif
            r.sp -= 1
        case 0x06: // pop
            r.sp -= 1
        case 0x07: // dup
            push(&r, r.sp.pointee)
        case 0x08: push(&r, nilObj)
        case 0x09: push(&r, t)
        case 0x0A: push(&r, f)
        case 0x0B: // push_int
            let b = Int8(bitPattern: byte(&r))
            push(&r, mkInt(Int64(b)))
        case 0x0C: // send
            let lit = Int(byte(&r))
            let argc = Int(byte(&r))
            let sel = r.lits[lit]
            r = send(vm, w, om, r, sel, argc, 3)
        case 0x0D: // return_top
            let v = r.sp.pointee
            if r.hdr[2] == hostFP {
                bottomReturn(w, r, v)
                return
            }
            r = doReturn(om, r, v)
        case 0x0E: // return_self
            let v = r.fp.pointee
            if r.hdr[2] == hostFP {
                bottomReturn(w, r, v)
                return
            }
            r = doReturn(om, r, v)
        case 0x0F: // jump
            let off = offset(&r)
            r.pc += off
            if off < 0 && poll(vm, w, r, 0) { r = exitRegs(vm, r) }
        case 0x10: // jump_if_true
            let off = offset(&r)
            let v = r.sp.pointee
            r.sp -= 1
            if v == t {
                r.pc += off
                if off < 0 && poll(vm, w, r, 0) { r = exitRegs(vm, r) }
            } else if v != f {
                fatal("mustBeBoolean")
            }
        case 0x11: // jump_if_false
            let off = offset(&r)
            let v = r.sp.pointee
            r.sp -= 1
            if v == f {
                r.pc += off
                if off < 0 && poll(vm, w, r, 0) { r = exitRegs(vm, r) }
            } else if v != t {
                fatal("mustBeBoolean")
            }
        case 0x12: // add
            let b = r.sp.pointee, a = (r.sp - 1).pointee
            if a & b & 1 != 0 {
                let (s, o) = Int64(bitPattern: a).addingReportingOverflow(Int64(bitPattern: b) &- 1)
                if !o { r.sp -= 1; r.sp.pointee = UInt64(bitPattern: s); continue }
            }
            r = sendSlow(vm, w, r, special[0], 1)
        case 0x13: // sub
            let b = r.sp.pointee, a = (r.sp - 1).pointee
            if a & b & 1 != 0 {
                let (s, o) = Int64(bitPattern: a).subtractingReportingOverflow(Int64(bitPattern: b) &- 1)
                if !o { r.sp -= 1; r.sp.pointee = UInt64(bitPattern: s); continue }
            }
            r = sendSlow(vm, w, r, special[1], 1)
        case 0x14: // mul
            let b = r.sp.pointee, a = (r.sp - 1).pointee
            if a & b & 1 != 0 {
                let (s, o) = (Int64(bitPattern: a) &>> 1).multipliedReportingOverflow(by: Int64(bitPattern: b) &- 1)
                if !o { r.sp -= 1; r.sp.pointee = UInt64(bitPattern: s | 1); continue }
            }
            r = sendSlow(vm, w, r, special[2], 1)
        case 0x15: compare(vm, w, &r, 3, <)
        case 0x16: compare(vm, w, &r, 4, >)
        case 0x17: compare(vm, w, &r, 5, <=)
        case 0x18: compare(vm, w, &r, 6, >=)
        case 0x19: compare(vm, w, &r, 7, ==)
        case 0x1A: // identical
            let b = r.sp.pointee
            r.sp -= 1
            let a = r.sp.pointee
            r.sp.pointee = a == b ? t : f
        case 0x1B: // leave: the Process was saved (or ended); back to the scheduler
            return
        default:
            fatal("bad opcode")
        }
    }
}

/// `dst replaceFrom: a to: b with: src startingAt: c`. Keeps raw pointers to
/// both bodies across the loop, so both are published in hazard slots first
/// (SPEC.md "Hazard slots"); the stores then need no post-store check. The
/// SATB and generational barriers run per slot as for `at:put:`.
@inline(never)
func primArrayCopy(_ vm: VMRef, _ w: WorkerRef, _ dst: Oop, _ a: Oop, _ b: Oop, _ src: Oop, _ c: Oop) -> Oop {
    let om = vm.pointee.om
    if isInt(dst) || isInt(src) || !isInt(a) || !isInt(b) || !isInt(c) { fatal("replaceFrom: bad arguments") }
    let hd = om.header(dst), hs = om.header(src)
    if hdrIsBytes(hd) || hdrIsBytes(hs) { fatal("replaceFrom: bytes") }
    let start = Int(intVal(a)) - 1, stop = Int(intVal(b)) - 1, from = Int(intVal(c)) - 1
    let n = stop - start + 1
    if n <= 0 { return dst }
    if start < 0 || stop >= hdrSlots(hd) || from < 0 || from + n > hdrSlots(hs) { fatal("replaceFrom: out of bounds") }
    let dp = hazardAcquire(w, om, 0, dst) + 1
    let sp = hazardAcquire(w, om, 1, src) + 1
    let backwards = dst == src && start > from
    var k = 0
    while k < n {
        let j = backwards ? n - 1 - k : k
        let v = atomicWord(sp + from + j).pointee.load(ordering: .relaxed)
        satbPre(vm, w, dst, start + j)
        atomicWord(dp + start + j).pointee.store(v, ordering: .relaxed)
        barrier(vm, w, om, dst, v)
        k += 1
    }
    hazardRelease(w, 1)
    hazardRelease(w, 0)
    return dst
}
