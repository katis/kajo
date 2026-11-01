// The bytecode interpreter and primitives (SPEC-SHARED.md "Bytecodes",
// "Frames"). One source for every variant: objects are reached only through
// `om` (the variant's accessor view). Lines that exist because of a
// variant's mechanism are marked `LEAK(A)`; lines that cache a raw pointer
// into a movable body are marked `RAW` (needed by any moving collector).

/// Interpreter registers. Passed by value into always-inline helpers so they
/// stay in machine registers.
struct Regs {
    var pc: UnsafePointer<UInt8>
    var sp: UnsafeMutablePointer<UInt64>
    var fp: UnsafeMutablePointer<UInt64>
    var hdr: UnsafeMutablePointer<UInt64>
    var lits: UnsafePointer<UInt64>
}

@inline(__always)
private func activate(_ vm: VMRef, _ w: WorkerRef, _ om: OM, _ r: Regs, _ method: Oop, _ argc: Int) -> Regs {
    let fp = r.sp - argc
    let nt = Int(truncatingIfNeeded: intVal(om.slot(method, mNTemps)))
    let maxStack = Int(truncatingIfNeeded: intVal(om.slot(method, mMaxStack)))
    var sp = r.sp
    if sp + (nt &+ 4 &+ maxStack) >= w.pointee.stackEnd { fatal("stack overflow") }
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

@inline(__always)
private func doReturn(_ om: OM, _ r: Regs, _ v: Oop) -> Regs {
    let fp = untagPtr(r.hdr[2], UInt64.self)
    let hdr = untagPtr(r.hdr[3], UInt64.self)
    r.fp.pointee = v
    return Regs(pc: UnsafePointer(untagPtr(r.hdr[1], UInt8.self)), sp: r.fp, fp: fp, hdr: hdr,
                lits: UnsafePointer(om.slotsPtr(om.slot(hdr[0], mLiterals)))) // RAW
}

/// After a park point: if a moving operation ran, re-derive pc and lits.
@inline(__always)
private func resync(_ vm: VMRef, _ w: WorkerRef, _ r: Regs) -> Regs {
    if !w.pointee.moved { return r }
    return resyncSlow(vm, w, r)
}

@inline(never)
private func resyncSlow(_ vm: VMRef, _ w: WorkerRef, _ r: Regs) -> Regs {
    w.pointee.moved = false
    let om = vm.pointee.om
    var o = r
    o.pc = UnsafePointer(bitPattern: w.pointee.pc).unsafelyUnwrapped // RAW
    o.lits = UnsafePointer(om.slotsPtr(om.slot(r.hdr[0], mLiterals))) // RAW
    return o
}

@inline(__always)
private func flush(_ w: WorkerRef, _ r: Regs) {
    w.pointee.sp = r.sp
    w.pointee.pc = UInt(bitPattern: r.pc)
    w.pointee.hdr = r.hdr
}

@inline(__always)
private func poll(_ vm: VMRef, _ w: WorkerRef, _ r: inout Regs) {
    if vm.pointee.gcRequested.load(ordering: .relaxed) {
        r = pollSlow(vm, w, r)
    }
}

@inline(never)
private func pollSlow(_ vm: VMRef, _ w: WorkerRef, _ r: Regs) -> Regs {
    flush(w, r)
    safepoint(vm, w)
    return resync(vm, w, r)
}

@inline(__always)
private func send(_ vm: VMRef, _ w: WorkerRef, _ om: OM, _ r0: Regs, _ sel: Oop, _ argc: Int) -> Regs {
    var r = r0
    poll(vm, w, &r)
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
        var out = resync(vm, w, r)
        out.sp = r.sp - argc
        out.sp.pointee = res
        return out
    }
    return activate(vm, w, om, r, method, argc)
}

@inline(never)
private func sendSlow(_ vm: VMRef, _ w: WorkerRef, _ r: Regs, _ sel: Oop, _ argc: Int) -> Regs {
    send(vm, w, vm.pointee.om, r, sel, argc)
}

/// Cache miss: full lookup and cache fill. The lookup cache never holds class
/// index 0, so in A a forwarded receiver always arrives here.
@inline(never)
private func lookupMiss(_ vm: VMRef, _ w: WorkerRef, _ cls0: UInt64, _ sel: Oop, _ recvSlot: UnsafeMutablePointer<Oop>) -> Oop {
    var cls = cls0
    #if FORWARDERS
    if cls == UInt64(ciForwarder) { // LEAK(A): forwarded receiver, follow and patch the stack slot
        let om = vm.pointee.om
        let target = follow(om, recvSlot.pointee)
        recvSlot.pointee = target
        cls = om.classIndexOf(target)
    }
    #endif
    let e = w.pointee.cache + (Int(truncatingIfNeeded: (sel &>> selShift) ^ cls) & (cacheSize - 1))
    if e.pointee.cls == cls && e.pointee.sel == sel { return e.pointee.method }
    w.pointee.misses &+= 1
    let m = lookup(vm, cls, sel)
    if m == 0 { fatal("doesNotUnderstand") }
    e.pointee.cls = cls
    e.pointee.sel = sel
    e.pointee.method = m
    return m
}

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
            om.setSlot(recv, j, arg(1))
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
    case 8: // become:
        stopWorld(vm, w, .become(recv, arg(0)), retry: true)
        return recv
    case 9: // forward:to:
        stopWorld(vm, w, .forward(arg(0), arg(1)), retry: true)
        return recv
    case 10: // Class>>addInstVar
        stopWorld(vm, w, .reshape(recv), retry: true)
        return recv
    case 11: // gc:
        stopWorld(vm, w, .gc(Int(intVal(arg(0)))), retry: true)
        return recv
    case 12: // compact:
        stopWorld(vm, w, .compact(Int(intVal(arg(0)))), retry: true)
        return recv
    case 13: // snapshot
        stopWorld(vm, w, .snapshot, retry: true)
        return recv
    case 14, 15: // globalAt: / globalAt:put:
        let i = arg(0)
        if !isInt(i) || intVal(i) < 1 || intVal(i) > Int64(globalCount) { fatal("bad global index") }
        if prim == 14 { return vm.pointee.globals[Int(intVal(i)) - 1] }
        vm.pointee.globals[Int(intVal(i)) - 1] = arg(1)
        return arg(1)
    case 16:
        return vm.pointee.stopFlag.load(ordering: .relaxed) ? vm.pointee.trueObj : vm.pointee.falseObj
    case 17:
        vm.pointee.stopFlag.store(true, ordering: .relaxed)
        return recv
    default:
        fatal("unknown primitive")
    }
}

/// Send `sel` to `recv` with `args` on worker `w` and run to completion.
public func execute(_ vm: VMRef, _ w: WorkerRef, _ recv: Oop, _ sel: Oop, _ args: [Oop]) -> Oop {
    let om = vm.pointee.om
    var sp = w.pointee.sp
    sp += 1
    sp.pointee = recv
    for a in args {
        sp += 1
        sp.pointee = a
    }
    let method = lookup(vm, om.classIndexOf(recv), sel)
    if method == 0 || om.slot(method, mPrim) != mkInt(0) { fatal("entry method missing or primitive") }
    let host = Regs(pc: UnsafePointer(om.bytesPtr(om.slot(method, mBytecodes))), sp: sp, fp: sp, hdr: sp,
                    lits: UnsafePointer(sp))
    let r = activate(vm, w, om, host, method, args.count)
    r.hdr[1] = mkInt(0)
    r.hdr[2] = hostFP
    r.hdr[3] = mkInt(0)
    return run(vm, w, r)
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

private func run(_ vm: VMRef, _ w: WorkerRef, _ start: Regs) -> Oop {
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
        case 0x05: // store_ivar
            let n = Int(byte(&r))
            om.setSlot(r.fp.pointee, n, r.sp.pointee)
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
            r = send(vm, w, om, r, sel, argc)
        case 0x0D: // return_top
            let v = r.sp.pointee
            if r.hdr[2] == hostFP {
                w.pointee.sp = r.fp - 1
                w.pointee.hdr = nil
                return v
            }
            r = doReturn(om, r, v)
        case 0x0E: // return_self
            let v = r.fp.pointee
            if r.hdr[2] == hostFP {
                w.pointee.sp = r.fp - 1
                w.pointee.hdr = nil
                return v
            }
            r = doReturn(om, r, v)
        case 0x0F: // jump
            let off = offset(&r)
            r.pc += off
            if off < 0 { poll(vm, w, &r) }
        case 0x10: // jump_if_true
            let off = offset(&r)
            let v = r.sp.pointee
            r.sp -= 1
            if v == t {
                r.pc += off
                if off < 0 { poll(vm, w, &r) }
            } else if v != f {
                fatal("mustBeBoolean")
            }
        case 0x11: // jump_if_false
            let off = offset(&r)
            let v = r.sp.pointee
            r.sp -= 1
            if v == f {
                r.pc += off
                if off < 0 { poll(vm, w, &r) }
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
            #if FORWARDERS
            r.sp.pointee = (a == b || maybeForwardedIdentical(om, a, b)) ? t : f // LEAK(A): == must compare followed oops
            #else
            r.sp.pointee = a == b ? t : f
            #endif
        default:
            fatal("bad opcode")
        }
    }
}
