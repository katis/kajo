import Synchronization

// Frames, Contexts, returns and unwinding (ADR 0009 sections 3 to 5).
//
// A frame's context word (`hdr[Frame.context]`, module 3's reserved slot)
// is nil, a materialized Context, or a SmallInteger return marker
// (`FrameMarker`). Returns test it against nil (one load and compare, in
// `doReturn`); anything else returns out of line here: a Context is
// detached (its frame gone: `frame` nil, the args and temps copied into its
// indexed slots, the last pc kept), and a marker changes what the caller
// does with the value. Every way a frame disappears detaches its Context:
// a return, a non-local return or `terminateTo:` cutting it, the Process
// ending (`detachAllContexts`).
//
// A Context is live when its `frame` names a header on the current
// Process's stack whose context word is that Context; every primitive
// checks this (`liveFrame`), so a stale index can never be followed.
// Contexts of other Processes are answered as dead: walking a stack another
// worker may be running is not done in 8a.

/// SmallInteger values a frame's context word may hold instead of a
/// Context: what the caller does with the frame's result.
enum FrameMarker {
    /// The frame was sent by a store that found its object read-only
    /// (`attemptToModify:at:value:` from a popping store bytecode): the
    /// result is dropped.
    static let discard: Int64 = 1
    /// The frame was sent by a non-local return that could not proceed
    /// (`cannotReturn:`, `aboutToReturn:through:`): the result is returned
    /// from the caller (the block) as well.
    static let cascade: Int64 = 2
}

/// A frame's receiver index from its header index: the header follows the
/// arguments and temps (`MethodLayout.temps` counts a block's copied values
/// and closure word).
@inline(__always)
func frameFP(_ om: ObjectMemory, _ base: UnsafeMutablePointer<UInt64>, _ hdr: Int) -> Int {
    let mb = om.stateWord(unsafe base[hdr])
    let argc = untagged(om.loadAtomic(bodyOffset: mb, MethodLayout.argc))
    let temps = untagged(om.loadAtomic(bodyOffset: mb, MethodLayout.temps))
    return hdr &- 1 &- argc &- temps
}

@inline(__always)
func methodFlags(_ om: ObjectMemory, _ method: UInt64) -> Int64 {
    Int64(untagged(om.loadAtomic(bodyOffset: om.stateWord(method), MethodLayout.flags)))
}

/// The Process the interpreter runs (nil oop for module 2's standalone
/// interpreter): what a Context's `process` must name to be live here.
@inline(__always)
func currentProcess(_ s: StatePointer) -> Oop {
    let p = unsafe workerOf(s).pointee.current
    return p == .none ? unsafe s.pointee.nilObject : p
}

/// The frame header index a live Context names on this interpreter's
/// current stack, or nil when it is detached, of another Process, or stale.
func liveFrame(_ s: StatePointer, _ ctx: Oop) -> Int? {
    let om = unsafe s.pointee.om
    guard ctx.isObject, om.classIndex(of: ctx) == WellKnown.context else { return nil }
    let f = om.load(ctx, ContextLayout.frame)
    guard f.isSmallInteger, unsafe om.load(ctx, ContextLayout.process) == currentProcess(s) else { return nil }
    let h = Int(f.smallIntegerValue)
    let sp = unsafe s.pointee.regs.sp
    guard h > 0, h + Frame.context <= sp else { return nil }
    return unsafe s.pointee.stackBase[h + Frame.context] == ctx.raw ? h : nil
}

/// The caller of the frame at header `hdr`, or nil at the bottom.
@inline(__always)
func callerHeader(_ base: UnsafeMutablePointer<UInt64>, _ hdr: Int) -> Int? {
    if unsafe base[hdr + Frame.callerFP] == Frame.hostFP { return nil }
    return unsafe untagged(base[hdr + Frame.callerHdr])
}

extension Machine {
    /// The Context of the frame at header index `hdr` (the registers saved),
    /// materialized if it has none. `.none` when the heap is full (the
    /// error is recorded). May pause: allocation.
    func materialize(_ hdr: Int) -> Oop {
        var base = unsafe state.pointee.stackBase
        let w = unsafe base[hdr + Frame.context]
        if w & Oop.objectTagMask == 0 && w != nilObject.raw { return Oop(raw: w) }
        let fp = frameFP(om, base, hdr)
        let n = hdr - fp - 1
        let ctx = allocate(WellKnown.context, slots: ContextLayout.size + n)
        if ctx == .none { return .none }
        base = unsafe state.pointee.stackBase
        let method = unsafe base[hdr]
        let isBlock = methodFlags(om, method) & MethodFlags.block != 0
        om.store(ctx, ContextLayout.frame, Oop(smallInteger: Int64(hdr)))
        store(ctx, ContextLayout.process, unsafe currentProcess(state), .contextSlot)
        om.store(ctx, ContextLayout.method, Oop(raw: method))  // methods are old and pinned
        store(ctx, ContextLayout.receiver, Oop(raw: unsafe base[fp]), .contextSlot)
        store(ctx, ContextLayout.closure, isBlock ? Oop(raw: unsafe base[hdr - 1]) : nilObject, .contextSlot)
        om.store(ctx, ContextLayout.marker, Oop(smallInteger: w & 1 != 0 ? Int64(untagged(w)) : 0))
        unsafe base[hdr + Frame.context] = ctx.raw
        return ctx
    }

    /// Detach a live Context: its frame is going away. The args and temps
    /// are copied into the indexed slots, `pc` keeps `pc`, `frame` becomes
    /// nil. Answers the frame's marker. No allocation.
    @discardableResult
    func detach(_ ctx: Oop, fp: Int, hdr: Int, pc: Int) -> Int64 {
        let base = unsafe state.pointee.stackBase
        let n = min(hdr - fp - 1, Int(om.count(of: ctx)) - ContextLayout.size)
        for i in 0..<max(0, n) {
            store(ctx, ContextLayout.size + i, Oop(raw: unsafe base[fp + 1 + i]), .contextSlot)
        }
        // The Context may be old (and relocating): checked stores.
        unsafe checkedStore(state, ctx, ContextLayout.frame, nilObject)
        unsafe checkedStore(state, ctx, ContextLayout.pc, Oop(smallInteger: Int64(pc)))
        let mk = om.load(ctx, ContextLayout.marker)
        unsafe checkedStore(state, ctx, ContextLayout.marker, Oop(smallInteger: 0))
        unsafe base[hdr + Frame.context] = nilObject.raw
        return mk.isSmallInteger ? mk.smallIntegerValue : 0
    }

    /// Detach the Contexts of every frame from header `top` down to, not
    /// including, header `stop` (0: the whole stack); markers are dropped.
    func detachFrames(from top: Int, downTo stop: Int) {
        let base = unsafe state.pointee.stackBase
        var h = top
        while h > 0 && h != stop {
            let w = unsafe base[h + Frame.context]
            let fp = frameFP(om, base, h)
            if w & Oop.objectTagMask == 0 && w != nilObject.raw {
                detach(Oop(raw: w), fp: fp, hdr: h, pc: framePC(h))
            } else {
                unsafe base[h + Frame.context] = nilObject.raw
            }
            guard let c = callerHeader(base, h) else { break }
            h = c
        }
    }

    /// The pc of the frame at header `h`: the saved pc for the current
    /// frame, else the pc its callee will return to.
    func framePC(_ h: Int) -> Int {
        let base = unsafe state.pointee.stackBase
        let r = unsafe state.pointee.regs
        if h == r.hdr { return r.pc }
        // The callee of h: walk down from the current frame.
        var k = r.hdr
        while k > 0 {
            guard let c = callerHeader(base, k) else { break }
            if c == h { return unsafe untagged(base[k + Frame.callerPC]) }
            k = c
        }
        return 0
    }
}

/// Module 3's termination and errors: a Process's stack is going away;
/// every materialized Context on it is detached. The registers are saved.
func detachAllContexts(_ s: StatePointer) {
    let m = unsafe Machine(state: s)
    let r = unsafe s.pointee.regs
    if r.hdr > 0 { m.detachFrames(from: r.hdr, downTo: 0) }
}

// MARK: - the out-of-line return

/// A frame whose context word is not nil returns: detach its Context, take
/// its marker, return, then apply the marker to the caller (drop the value,
/// or return it from the caller as well).
@inline(never)
func returnSlow(_ s: StatePointer, _ pc: UnsafePointer<UInt8>, _ sp: UnsafeMutablePointer<UInt64>,
                _ fp: UnsafeMutablePointer<UInt64>, _ hdr: UnsafeMutablePointer<UInt64>, _ v: UInt64) -> Regs {
    let om = unsafe s.pointee.om
    let base = unsafe s.pointee.stackBase
    let w = unsafe hdr[Frame.context]
    var marker: Int64 = 0
    if w & 1 != 0 {
        marker = Int64(untagged(w))
    } else if w & Oop.objectTagMask == 0 {
        // The detach stores into the Context (barriers, no allocation): no
        // pause, so the registers stay as they are.
        unsafe save(s, pc, sp, fp, hdr)
        let m = unsafe Machine(state: s)
        marker = m.detach(Oop(raw: w), fp: fp - base, hdr: hdr - base, pc: unsafe s.pointee.regs.pc &- 1)
    }
    unsafe hdr[Frame.context] = s.pointee.nilObject.raw
    let r = unsafe plainReturn(s, om, regsAt(s, pc, sp, fp, hdr), v)
    if unsafe marker == 0 || s.pointee.exit != .running { return r }
    if marker == FrameMarker.discard {
        var out = r
        unsafe out.sp -= 1
        return out
    }
    // cascade: the caller returns the value too.
    return unsafe doReturn(s, om, r, v)
}

// MARK: - sends the VM makes with a marker

/// Send `sel` (argc arguments on the stack, the receiver below them) from
/// the current frame and mark the new frame: `discard` or `cascade`. The
/// method's body is activated even when it has a primitive (a primitive
/// answering in place would leave the marker unapplied; the kernel's
/// handlers are Smalltalk). The registers are saved; answers the next
/// registers.
func markedSend(_ s: StatePointer, _ sel: UInt64, _ argc: Int, _ marker: Int64) -> Regs {
    let om = unsafe s.pointee.om
    let r = unsafe restore(s)
    let rcv = unsafe (r.sp - argc).pointee
    let cls = classIndexOf(om, rcv)
    var method = unsafe lookupMiss(s, cls, sel)
    var n = argc
    var out: Regs
    if method == 0 {
        // doesNotUnderstand: — the Message replaces the arguments.
        let handler = unsafe lookupMiss(s, cls, s.pointee.doesNotUnderstand.raw)
        if handler == 0 {
            return unsafe failAt(s, r.pc, r.sp, r.fp, r.hdr, 0, .doesNotUnderstand, sel, rcv)
        }
        let m = unsafe Machine(state: s)
        let args = m.allocate(WellKnown.array, slots: argc)
        if args == .none { return unsafe failedAllocation(s, sel, rcv, 0) }
        let b = unsafe s.pointee.stackBase
        let top = unsafe s.pointee.regs.sp
        for i in 0..<argc { unsafe m.store(args, i, Oop(raw: b[top - argc + 1 + i]), .messageArgument) }
        let message = m.allocate(WellKnown.message, slots: MessageLayout.size, keeping: args)
        if message == .none { return unsafe failedAllocation(s, sel, rcv, 0) }
        m.store(message, MessageLayout.selector, Oop(raw: sel), .messageSelector)
        m.store(message, MessageLayout.arguments, args, .messageArguments)
        unsafe b[top - argc + 1] = message.raw
        unsafe s.pointee.regs.sp = top - argc + 1
        method = handler
        n = 1
        out = unsafe activate(s, om, restore(s), method, n, 0)
    } else {
        if om.count(of: om.load(Oop(raw: method), MethodLayout.bytecodes)) == 0 {
            let m = unsafe Machine(state: s)
            m.fail(.primitiveFailed, selector: Oop(raw: sel), receiverClass: cls)
            return unsafe restoreLeaving(s)
        }
        out = unsafe activate(s, om, r, method, n, 0)
    }
    if unsafe s.pointee.exit == .running && out.hdr > r.sp {
        unsafe out.hdr[Frame.context] = tagged(Int(marker))
    }
    return out
}

// MARK: - non-local return

/// `nonlocal_return` in a block frame: return the top from the home
/// method's frame. The home must be live on this stack, or the closure is
/// sent `cannotReturn:` (marker cascade). With no unwind mark between the
/// block and its home, the frames above the home are cut (their Contexts
/// detached) and the home returns at once; otherwise the home Context is
/// sent `aboutToReturn:through:` with the first unwind Context (marker
/// cascade), and the kernel unwinds in Smalltalk (`resume:through:` with
/// `terminateTo:`, running each `ensure:` block).
@inline(never)
func nonLocalReturn(_ s: StatePointer, _ pc: UnsafePointer<UInt8>, _ sp: UnsafeMutablePointer<UInt64>,
                    _ fp: UnsafeMutablePointer<UInt64>, _ hdr: UnsafeMutablePointer<UInt64>) -> Regs {
    unsafe save(s, pc, sp, fp, hdr)
    let om = unsafe s.pointee.om
    let m = unsafe Machine(state: s)
    let base = unsafe s.pointee.stackBase
    let v = unsafe sp.pointee
    let closure = Oop(raw: unsafe (hdr - 1).pointee)
    let home = om.load(closure, ClosureLayout.home)
    guard let h = unsafe liveFrame(s, home) else {
        unsafe s.pointee.counters.cannotReturns &+= 1
        // [v] -> [closure v]: send cannotReturn: v to the closure.
        let top = unsafe s.pointee.regs.sp
        unsafe base[top] = closure.raw
        unsafe base[top + 1] = v
        unsafe s.pointee.regs.sp = top + 1
        return unsafe markedSend(s, s.pointee.specialSelectors[VMSelector.cannotReturn], 1, FrameMarker.cascade)
    }
    // The first unwind-marked frame between the block's caller and the home.
    var k = unsafe hdr - base
    var unwind = 0
    while let c = callerHeader(base, k), c != h, !om.config.testSwitches.skipUnwindMarks {
        if methodFlags(om, unsafe base[c]) & MethodFlags.unwind != 0 {
            unwind = c
            break
        }
        k = c
    }
    if unwind == 0 {
        unsafe s.pointee.counters.nonLocalReturns &+= 1
        let hpc = m.framePC(h)
        m.detachFrames(from: unsafe hdr - base, downTo: h)
        let hfp = frameFP(om, base, h)
        let code = om.bytesBase(om.load(Oop(raw: unsafe base[h]), MethodLayout.bytecodes))
        let r = unsafe regsAt(s, code + hpc, base + h + Frame.context, base + hfp, base + h)
        return unsafe doReturn(s, om, r, v)
    }
    unsafe s.pointee.counters.unwindingReturns &+= 1
    let u = m.materialize(unwind)
    if u == .none { return unsafe restoreLeaving(s) }
    // [v] -> [home v u]
    let top = unsafe s.pointee.regs.sp
    unsafe base[top] = home.raw
    unsafe base[top + 1] = v
    unsafe base[top + 2] = u.raw
    unsafe s.pointee.regs.sp = top + 2
    return unsafe markedSend(s, s.pointee.specialSelectors[VMSelector.aboutToReturn], 2, FrameMarker.cascade)
}

// MARK: - read-only stores in bytecodes

/// `store_ivar` or `store_tv_slot` found its object read-only: [v] becomes
/// [obj obj index v] and `attemptToModify:at:value:` is sent to the object
/// with the discard marker (the store popped its value; so does the send's
/// answer). `index` is 1-based. `length` is the instruction's.
@inline(never)
func attemptToModifyFromStore(_ s: StatePointer, _ pc: UnsafePointer<UInt8>, _ sp: UnsafeMutablePointer<UInt64>,
                              _ fp: UnsafeMutablePointer<UInt64>, _ hdr: UnsafeMutablePointer<UInt64>,
                              _ object: UInt64, _ index: Int) -> Regs {
    unsafe save(s, pc, sp, fp, hdr)
    unsafe s.pointee.counters.readOnlyRefusals &+= 1
    let base = unsafe s.pointee.stackBase
    let top = unsafe s.pointee.regs.sp
    let v = unsafe base[top]
    unsafe base[top] = object
    unsafe base[top + 1] = object
    unsafe base[top + 2] = tagged(index)
    unsafe base[top + 3] = v
    unsafe s.pointee.regs.sp = top + 3
    return unsafe markedSend(s, s.pointee.specialSelectors[VMSelector.attemptToModify], 3, FrameMarker.discard)
}

/// A store primitive refused a read-only object: the receiver and its
/// arguments become [obj obj index value] and `attemptToModify:at:value:`
/// is sent; its answer is the primitive send's. The registers are saved.
func attemptToModifyFromPrimitive(_ s: StatePointer, _ argc: Int, _ length: Int) -> Regs {
    unsafe s.pointee.counters.readOnlyRefusals &+= 1
    let base = unsafe s.pointee.stackBase
    let fp0 = unsafe s.pointee.regs.sp - argc
    let o = unsafe s.pointee.readOnlyFailure
    unsafe base[fp0] = o.raw
    unsafe base[fp0 + 1] = o.raw
    unsafe base[fp0 + 2] = s.pointee.readOnlyIndex.raw
    unsafe base[fp0 + 3] = s.pointee.readOnlyValue.raw
    unsafe s.pointee.regs.sp = fp0 + 3
    unsafe s.pointee.readOnlyFailure = .none
    unsafe s.pointee.readOnlyIndex = .none
    unsafe s.pointee.readOnlyValue = .none
    let r = unsafe restore(s)
    return unsafe send(s, s.pointee.om, r, s.pointee.specialSelectors[VMSelector.attemptToModify], 3, length, poll: false)
}

// MARK: - push_this_context

@inline(never)
func pushThisContext(_ s: StatePointer, _ pc: UnsafePointer<UInt8>, _ sp: UnsafeMutablePointer<UInt64>,
                     _ fp: UnsafeMutablePointer<UInt64>, _ hdr: UnsafeMutablePointer<UInt64>) -> Regs {
    unsafe save(s, pc, sp, fp, hdr)
    let m = unsafe Machine(state: s)
    let ctx = m.materialize(unsafe s.pointee.regs.hdr)
    if ctx == .none { return unsafe restoreLeaving(s) }
    unsafe s.pointee.counters.contextsMaterialized &+= 1
    let top = unsafe s.pointee.regs.sp + 1
    unsafe s.pointee.stackBase[top] = ctx.raw
    unsafe s.pointee.regs.sp = top
    return unsafe restore(s)
}

// MARK: - Context and BlockClosure primitives (100 to 116)

@inline(never)
func contextPrimitive(_ n: Int, _ m: Machine, _ c: PrimitiveCall) -> Oop {
    let om = m.om
    let s = m.state
    if n >= 112 {
        guard c.receiver.isObject, om.classIndex(of: c.receiver) == WellKnown.blockClosure else { return .none }
        switch n {
        case 112: return c.argc == 0 ? om.load(om.load(c.receiver, ClosureLayout.method), MethodLayout.argc) : .none
        case 113: return c.argc == 0 ? om.load(c.receiver, ClosureLayout.receiver) : .none
        case 114: return c.argc == 0 ? om.load(c.receiver, ClosureLayout.method) : .none
        case 115: return c.argc == 0 ? om.load(c.receiver, ClosureLayout.home) : .none
        default:
            guard c.argc == 1, c.arg0.isSmallInteger else { return .none }
            let i = c.arg0.smallIntegerValue
            guard i >= 1, i <= Int64(om.count(of: c.receiver)) - Int64(ClosureLayout.size) else { return .none }
            return om.load(c.receiver, ClosureLayout.size + Int(i - 1))
        }
    }
    guard c.receiver.isObject, om.classIndex(of: c.receiver) == WellKnown.context else { return .none }
    let ctx = c.receiver
    let live = unsafe liveFrame(s, ctx)
    let base = unsafe s.pointee.stackBase
    switch n {
    case 100:
        guard c.argc == 0 else { return .none }
        guard let h = live, let caller = callerHeader(base, h) else { return m.nilObject }
        return m.materialize(caller)
    case 101, 102:
        guard c.argc == (n == 102 ? 2 : 1), c.arg0.isSmallInteger else { return .none }
        let i = Int(c.arg0.smallIntegerValue)
        if let h = live {
            let fp = frameFP(om, base, h)
            let isBlock = methodFlags(om, unsafe base[h]) & MethodFlags.block != 0
            let count = h - fp - 1 - (isBlock ? 1 : 0)
            guard i >= 1, i <= count else { return .none }
            if n == 101 { return Oop(raw: unsafe base[fp + i]) }
            unsafe base[fp + i] = c.arg1.raw  // the stack is a root: no barrier
            return c.arg1
        }
        guard om.load(ctx, ContextLayout.frame) == m.nilObject else { return .none }  // another Process's frame
        let count = Int(om.count(of: ctx)) - ContextLayout.size
        guard i >= 1, i <= count else { return .none }
        if n == 101 { return om.load(ctx, ContextLayout.size + i - 1) }
        if om.isReadOnly(ctx) { return m.refuseReadOnly(ctx, at: c.arg0, value: c.arg1) }
        m.store(ctx, ContextLayout.size + i - 1, c.arg1, .contextSlot)
        return c.arg1
    case 103:
        guard c.argc == 0 else { return .none }
        if let h = live { return Oop(smallInteger: Int64(m.framePC(h))) }
        return om.load(ctx, ContextLayout.pc)
    case 104: return c.argc == 0 ? om.load(ctx, ContextLayout.method) : .none
    case 105: return c.argc == 0 ? om.load(ctx, ContextLayout.receiver) : .none
    case 106: return c.argc == 0 ? om.load(ctx, ContextLayout.closure) : .none
    case 107:
        // Dead: detached, or its Process has ended (a Process ended from
        // outside never ran its frames' detachment).
        guard c.argc == 0 else { return .none }
        let p = om.load(ctx, ContextLayout.process)
        let ended = p.isObject && om.classIndex(of: p) == WellKnown.process
            && om.load(p, ProcessLayout.state) == Oop(smallInteger: Int64(ProcessState.terminated.rawValue))
        return m.boolean(om.load(ctx, ContextLayout.frame) == m.nilObject || ended)
    case 108:
        guard c.argc == 1, let h = live else { return .none }
        return terminateTo(m, ctx, h, c.arg0)
    case 109:
        guard c.argc == 1, let h = live else { return .none }
        let stop = c.arg0 == m.nilObject ? 0 : unsafe liveFrame(s, c.arg0)
        guard let stop else { return .none }
        var k = h
        while let caller = callerHeader(base, k), caller != stop {
            if methodFlags(om, unsafe base[caller]) & MethodFlags.unwind != 0 { return m.materialize(caller) }
            k = caller
        }
        return m.nilObject
    case 110:
        guard c.argc == 0, let h = live else { return .none }
        var k: Int? = h
        while let f = k {
            if methodFlags(om, unsafe base[f]) & MethodFlags.handler != 0 { return m.materialize(f) }
            k = callerHeader(base, f)
        }
        return m.nilObject
    case 111:
        guard c.argc == 0 else { return .none }
        if let h = live {
            let fp = frameFP(om, base, h)
            return Oop(smallInteger: Int64(h - fp - 1 - (methodFlags(om, unsafe base[h]) & MethodFlags.block != 0 ? 1 : 0)))
        }
        return Oop(smallInteger: Int64(om.count(of: ctx)) - Int64(ContextLayout.size))
    default:
        return .none
    }
}

/// `thisContext terminateTo: aContext` (Smalltalk-80's, as Squeak's
/// `resume:through:` uses it): every frame between the running frame R
/// (the receiver's) and `aContext`'s frame U is cut, their Contexts
/// detached, and R moves down to where U's callee D began, with D's links,
/// so U is R's caller and R's return answers U's send. Frame links are
/// indices, so the move is one `memmove` and the moved frame's own links;
/// R's Context (if any) gets its new index, and R's return marker is
/// dropped (its caller changed). Fails unless the receiver is the running
/// frame's Context and `aContext` a live frame below it.
private func terminateTo(_ m: Machine, _ ctx: Oop, _ rh: Int, _ target: Oop) -> Oop {
    let om = m.om
    let s = m.state
    let base = unsafe s.pointee.stackBase
    let regs = unsafe s.pointee.regs
    guard rh == regs.hdr, let uh = unsafe liveFrame(s, target), uh < rh else { return .none }
    var d = rh
    while let c = callerHeader(base, d), c != uh { d = c }
    guard callerHeader(base, d) == uh else { return .none }
    if d == rh { return ctx }
    let fpD = frameFP(om, base, d)
    let links = unsafe (base[d + Frame.callerPC], base[d + Frame.callerFP], base[d + Frame.callerHdr])
    if let rc = callerHeader(base, rh) { m.detachFrames(from: rc, downTo: uh) }
    let delta = regs.fp - fpD
    let count = regs.sp - regs.fp + 1
    unsafe (base + fpD).update(from: base + regs.fp, count: count)
    let nh = rh - delta
    unsafe base[nh + Frame.callerPC] = links.0
    unsafe base[nh + Frame.callerFP] = links.1
    unsafe base[nh + Frame.callerHdr] = links.2
    let w = unsafe base[nh + Frame.context]
    if w & 1 != 0 {
        unsafe base[nh + Frame.context] = m.nilObject.raw
    } else if w == ctx.raw {
        unsafe checkedStore(s, ctx, ContextLayout.frame, Oop(smallInteger: Int64(nh)))
        unsafe checkedStore(s, ctx, ContextLayout.marker, Oop(smallInteger: 0))
    }
    unsafe s.pointee.regs.sp = regs.sp - delta
    unsafe s.pointee.regs.fp = fpD
    unsafe s.pointee.regs.hdr = nh
    unsafe s.pointee.counters.terminations &+= 1
    return ctx
}
