// The bytecode interpreter and primitives (SPEC-SHARED.md "Bytecodes", "Frames").

/// Interpreter registers. Passed by value into always-inline helpers so they
/// stay in machine registers.
struct Regs {
    var pc: UnsafePointer<UInt8>
    var sp: UnsafeMutablePointer<UInt64>
    var fp: UnsafeMutablePointer<UInt64>
    var hdr: UnsafeMutablePointer<UInt64>
    var lits: UnsafePointer<UInt64>
}

let hostFP: UInt64 = 1 // mkInt(0)

@inline(__always)
private func activate(_ vm: VMRef, _ w: WorkerRef, _ r: Regs, _ method: Oop, _ argc: Int) -> Regs {
    let fp = r.sp - argc
    let nt = Int(truncatingIfNeeded: intVal(slot(method, mNTemps)))
    let maxStack = Int(truncatingIfNeeded: intVal(slot(method, mMaxStack)))
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
    return Regs(pc: UnsafePointer(bytesPtr(slot(method, mBytecodes))),
                sp: hdr + 3, fp: fp, hdr: hdr,
                lits: UnsafePointer(slotsPtr(slot(method, mLiterals))))
}

@inline(__always)
private func doReturn(_ r: Regs, _ v: Oop) -> Regs {
    let fp = untagPtr(r.hdr[2], UInt64.self)
    let hdr = untagPtr(r.hdr[3], UInt64.self)
    r.fp.pointee = v
    return Regs(pc: UnsafePointer(untagPtr(r.hdr[1], UInt8.self)), sp: r.fp, fp: fp, hdr: hdr,
                lits: UnsafePointer(slotsPtr(slot(hdr[0], mLiterals))))
}

@inline(__always)
private func poll(_ vm: VMRef, _ w: WorkerRef, _ sp: UnsafeMutablePointer<UInt64>) {
    if vm.pointee.gcRequested.load(ordering: .relaxed) {
        w.pointee.sp = sp
        safepoint(vm, w)
    }
}

@inline(__always)
private func send(_ vm: VMRef, _ w: WorkerRef, _ r: Regs, _ sel: Oop, _ argc: Int) -> Regs {
    poll(vm, w, r.sp)
    let recv = (r.sp - argc).pointee
    let cls = classIndexOf(recv)
    let e = w.pointee.cache + (Int(truncatingIfNeeded: (sel &>> 3) ^ cls) & (cacheSize - 1))
    let method: Oop
    if e.pointee.cls == cls && e.pointee.sel == sel {
        method = e.pointee.method
    } else {
        method = lookupMiss(vm, w, cls, sel)
        e.pointee.cls = cls
        e.pointee.sel = sel
        e.pointee.method = method
    }
    let prim = slot(method, mPrim)
    if prim != mkInt(0) {
        w.pointee.sp = r.sp
        let res = primitive(vm, w, intVal(prim), r.sp, argc)
        var out = r
        out.sp = r.sp - argc
        out.sp.pointee = res
        return out
    }
    return activate(vm, w, r, method, argc)
}

@inline(never)
private func sendSlow(_ vm: VMRef, _ w: WorkerRef, _ r: Regs, _ sel: Oop, _ argc: Int) -> Regs {
    send(vm, w, r, sel, argc)
}

@inline(never)
private func lookupMiss(_ vm: VMRef, _ w: WorkerRef, _ cls: UInt64, _ sel: Oop) -> Oop {
    w.pointee.misses &+= 1
    let m = lookup(vm, cls, sel)
    if m == 0 { fatal("doesNotUnderstand") }
    return m
}

@inline(never)
private func primitive(_ vm: VMRef, _ w: WorkerRef, _ prim: Int64, _ sp: UnsafeMutablePointer<UInt64>, _ argc: Int) -> Oop {
    let base = sp - argc
    let recv = base.pointee
    func arg(_ i: Int) -> Oop { base[1 + i] }
    switch prim {
    case 1, 2:
        let idx = arg(0)
        if isInt(recv) || !isInt(idx) { fatal("at: bad receiver or index") }
        let h = header(recv)
        let i = intVal(idx)
        if i < 1 || i > Int64(hdrSlots(h)) { fatal("at: index out of bounds") }
        let j = Int(i) - 1
        if hdrIsBytes(h) {
            if prim == 2 { fatal("at:put: on bytes") }
            return mkInt(Int64(bytesPtr(recv)[j]))
        } else if prim == 1 {
            return slot(recv, j)
        } else {
            setSlot(recv, j, arg(1))
            return arg(1)
        }
    case 3, 4:
        if isInt(recv) || hdrClass(header(recv)) != UInt64(ciClass) { fatal("basicNew on non-class") }
        var extra = 0
        if prim == 3 {
            let n = arg(0)
            if !isInt(n) || intVal(n) < 0 { fatal("basicNew: bad size") }
            extra = Int(intVal(n))
        }
        let n = Int(intVal(slot(recv, cInstSize))) + extra
        let cls = UInt32(intVal(slot(recv, cIndex)))
        return alloc(vm, w, cls, n, false)
    case 5:
        return classAt(vm, classIndexOf(recv))
    case 6, 7:
        let bv = arg(0)
        if !isInt(recv) || !isInt(bv) || intVal(bv) == 0 { fatal("// or \\\\ failed") }
        let a = intVal(recv), b = intVal(bv)
        let q = a / b
        let fq = (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q
        if !fitsInt(fq) { fatal("// overflow") }
        return mkInt(prim == 6 ? fq : a - fq * b)
    default:
        fatal("unknown primitive")
    }
}

/// Send `sel` to `recv` with `args` on worker `w` and run to completion.
public func execute(_ vm: VMRef, _ w: WorkerRef, _ recv: Oop, _ sel: Oop, _ args: [Oop]) -> Oop {
    var sp = w.pointee.sp
    sp += 1
    sp.pointee = recv
    for a in args {
        sp += 1
        sp.pointee = a
    }
    let method = lookup(vm, classIndexOf(recv), sel)
    if method == 0 || slot(method, mPrim) != mkInt(0) { fatal("entry method missing or primitive") }
    let host = Regs(pc: UnsafePointer(bytesPtr(slot(method, mBytecodes))), sp: sp, fp: sp, hdr: sp,
                    lits: UnsafePointer(sp))
    let r = activate(vm, w, host, method, args.count)
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
            push(&r, slot(r.fp.pointee, n))
        case 0x04: // store_temp
            let n = Int(byte(&r))
            r.fp[1 &+ n] = r.sp.pointee
            r.sp -= 1
        case 0x05: // store_ivar
            let n = Int(byte(&r))
            setSlot(r.fp.pointee, n, r.sp.pointee)
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
            r = send(vm, w, r, sel, argc)
        case 0x0D: // return_top
            let v = r.sp.pointee
            if r.hdr[2] == hostFP {
                w.pointee.sp = r.fp - 1
                return v
            }
            r = doReturn(r, v)
        case 0x0E: // return_self
            let v = r.fp.pointee
            if r.hdr[2] == hostFP {
                w.pointee.sp = r.fp - 1
                return v
            }
            r = doReturn(r, v)
        case 0x0F: // jump
            let off = offset(&r)
            r.pc += off
            if off < 0 { poll(vm, w, r.sp) }
        case 0x10: // jump_if_true
            let off = offset(&r)
            let v = r.sp.pointee
            r.sp -= 1
            if v == t {
                r.pc += off
                if off < 0 { poll(vm, w, r.sp) }
            } else if v != f {
                fatal("mustBeBoolean")
            }
        case 0x11: // jump_if_false
            let off = offset(&r)
            let v = r.sp.pointee
            r.sp -= 1
            if v == f {
                r.pc += off
                if off < 0 { poll(vm, w, r.sp) }
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
            r.sp.pointee = r.sp.pointee == b ? t : f
        default:
            fatal("bad opcode")
        }
    }
}
