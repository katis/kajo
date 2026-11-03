// Closures and temp vectors (ADR 0009 section 4). A `BlockClosure` holds
// its block method, the receiver of its home, the home Context when the
// block can return non-locally, and its copied values. Activation puts the
// receiver in the frame's receiver word, the arguments above it, then the
// copied values, nil temps and the closure itself as the last word before
// the header (`hdr[-1]`, where non-local return and materialization find
// it). Temps written after capture live in a temp vector, an Array made
// by `push_new_array` and reached with `push_tv_slot`/`store_tv_slot`.

/// `push_closure lit copied`: pop the copied values into a new closure on
/// the block method in literal `lit`. A block that returns non-locally gets
/// its home: this frame's Context (materialized now) in a method, the
/// enclosing closure's home in a block. Allocates.
@inline(never)
func pushClosure(_ s: StatePointer, _ pc: UnsafePointer<UInt8>, _ sp: UnsafeMutablePointer<UInt64>,
                 _ fp: UnsafeMutablePointer<UInt64>, _ hdr: UnsafeMutablePointer<UInt64>, _ lit: Int, _ copied: Int) -> Regs {
    unsafe save(s, pc, sp, fp, hdr)
    let om = unsafe s.pointee.om
    let m = unsafe Machine(state: s)
    let h = unsafe s.pointee.regs.hdr
    var base = unsafe s.pointee.stackBase
    let block = om.load(om.load(Oop(raw: unsafe base[h]), MethodLayout.literals), lit)
    var home = m.nilObject
    if methodFlags(om, block.raw) & MethodFlags.needsHome != 0 {
        if methodFlags(om, unsafe base[h]) & MethodFlags.block != 0 {
            home = om.load(Oop(raw: unsafe base[h - 1]), ClosureLayout.home)
        } else {
            home = m.materialize(h)
            if home == .none { return unsafe restoreLeaving(s) }
        }
    }
    let c = m.allocate(WellKnown.blockClosure, slots: ClosureLayout.size + copied, keeping: home)
    if c == .none { return unsafe restoreLeaving(s) }
    unsafe base = s.pointee.stackBase
    let top = unsafe s.pointee.regs.sp
    let f = unsafe s.pointee.regs.fp
    m.store(c, ClosureLayout.method, block, .closureSlot)
    m.store(c, ClosureLayout.receiver, Oop(raw: unsafe base[f]), .closureSlot)
    m.store(c, ClosureLayout.home, home, .closureSlot)
    for i in 0..<copied {
        m.store(c, ClosureLayout.size + i, Oop(raw: unsafe base[top - copied + 1 + i]), .closureSlot)
    }
    unsafe base[top - copied + 1] = c.raw
    unsafe s.pointee.regs.sp = top - copied + 1
    unsafe s.pointee.counters.closuresCreated &+= 1
    return unsafe restore(s)
}

/// `push_new_array n`: an Array of n nils (a temp vector). Allocates.
@inline(never)
func pushNewArray(_ s: StatePointer, _ pc: UnsafePointer<UInt8>, _ sp: UnsafeMutablePointer<UInt64>,
                  _ fp: UnsafeMutablePointer<UInt64>, _ hdr: UnsafeMutablePointer<UInt64>, _ n: Int) -> Regs {
    unsafe save(s, pc, sp, fp, hdr)
    let m = unsafe Machine(state: s)
    let a = m.allocate(WellKnown.array, slots: n)
    if a == .none { return unsafe restoreLeaving(s) }
    let top = unsafe s.pointee.regs.sp + 1
    unsafe s.pointee.stackBase[top] = a.raw
    unsafe s.pointee.regs.sp = top
    return unsafe restore(s)
}

/// Activate the closure under `argc` arguments on top of the stack, or nil
/// when the receiver is not a closure taking `argc` arguments (the caller
/// sends instead). The frame: receiver := the closure's receiver, then the
/// arguments, copied values, nil temps, the closure, the header.
@inline(__always)
func activateClosure(_ s: StatePointer, _ om: ObjectMemory, _ r: Regs, _ argc: Int, _ length: Int) -> Regs? {
    let rcv = unsafe (r.sp - argc).pointee
    guard rcv & Oop.objectTagMask == 0, om.headerWord(rcv) & Header.classMask == WellKnown.blockClosure else { return nil }
    let cb = om.stateWord(rcv)
    let method = om.loadAtomic(bodyOffset: cb, ClosureLayout.method)
    let mb = om.stateWord(method)
    guard untagged(om.loadAtomic(bodyOffset: mb, MethodLayout.argc)) == argc else { return nil }
    let temps = untagged(om.loadAtomic(bodyOffset: mb, MethodLayout.temps))
    let copied = untagged(om.loadAtomic(bodyOffset: mb, MethodLayout.copied))
    let maxStack = untagged(om.loadAtomic(bodyOffset: mb, MethodLayout.maxStack))
    var sp = unsafe r.sp
    if unsafe sp + (temps &+ Frame.headerWords &+ maxStack &+ 1) >= s.pointee.stackEnd {
        return unsafe stackOverflow(s, r.pc, r.sp, r.fp, r.hdr, method, length)
    }
    let fp = unsafe r.sp - argc
    unsafe fp.pointee = om.loadAtomic(bodyOffset: cb, ClosureLayout.receiver)
    var i = 0
    while i < copied {
        unsafe sp += 1
        unsafe sp.pointee = om.loadAtomic(bodyOffset: cb, ClosureLayout.size &+ i)
        i &+= 1
    }
    let nilObject = unsafe s.pointee.nilObject.raw
    while i < temps &- 1 {
        unsafe sp += 1
        unsafe sp.pointee = nilObject
        i &+= 1
    }
    unsafe sp += 1
    unsafe sp.pointee = rcv
    let base = unsafe s.pointee.stackBase
    let hdr = unsafe sp + 1
    unsafe hdr[Frame.method] = method
    unsafe hdr[Frame.callerPC] = tagged(r.pc - r.code)
    unsafe hdr[Frame.callerFP] = tagged(r.fp - base)
    unsafe hdr[Frame.callerHdr] = tagged(r.hdr - base)
    unsafe hdr[Frame.context] = nilObject
    let code = unsafe om.bytesBase(Oop(raw: om.loadAtomic(bodyOffset: mb, MethodLayout.bytecodes)))
    let lits = unsafe om.slotsBase(Oop(raw: om.loadAtomic(bodyOffset: mb, MethodLayout.literals)))
    unsafe s.pointee.counters.closureActivations &+= 1
    return unsafe Regs(pc: code, sp: hdr + (Frame.headerWords &- 1), fp: fp, hdr: hdr, code: code, lits: lits)
}
