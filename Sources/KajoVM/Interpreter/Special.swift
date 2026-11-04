// The out-of-line tier of the special sends, the activation primitives
// (closure `value`s and the `perform:` family), `send_super`, and the
// extension prefix (module 8, bytecode set v1). Each is one out-of-line
// call from the dispatch loop with the registers as scalars.

/// Special selector indices (`Opcode.specialIndex`) the tier handles
/// beyond arithmetic.
enum SpecialIndex {
    static let at = 14
    static let atPut = 15
    static let size = 16
    static let value = 18
    static let value1 = 19
    static let value2 = 20
}

/// The tier between a special send's inline fast path and a full send.
/// nil: send. The arithmetic needs no lookup because the kernel's methods
/// for these selectors on numbers are the same primitives (and a class may
/// not redefine SmallInteger, Float or LargeInteger arithmetic in 8a).
@inline(__always)
func specialFastPath(_ s: StatePointer, _ pc: UnsafePointer<UInt8>, _ sp: UnsafeMutablePointer<UInt64>,
                     _ fp: UnsafeMutablePointer<UInt64>, _ hdr: UnsafeMutablePointer<UInt64>, _ index: Int,
                     _ argc: Int) -> Regs? {
    let om = unsafe s.pointee.om
    if let op = ArithOp.special(index) {
        let a = Oop(raw: unsafe (sp - 1).pointee), b = Oop(raw: unsafe sp.pointee)
        // Numbers only: an immediate (SmallInteger or SmallFloat) or a
        // Float or LargeInteger object on either side.
        func numeric(_ v: Oop) -> Bool {
            if v.isSmallInteger || v.isSmallFloat { return true }
            guard v.isObject else { return false }
            let c = om.classIndex(of: v)
            return c == WellKnown.float || c == WellKnown.largePositiveInteger || c == WellKnown.largeNegativeInteger
        }
        guard numeric(a), numeric(b) else { return nil }
        unsafe save(s, pc, sp, fp, hdr)
        let m = unsafe Machine(state: s)
        let v = m.arith(op, a, b)
        if m.failed { return unsafe restoreLeaving(s) }
        if v == .none { return nil }
        unsafe s.pointee.counters.specialSendTier &+= 1
        let top = unsafe s.pointee.regs.sp - 1
        unsafe s.pointee.stackBase[top] = v.raw
        unsafe s.pointee.regs.sp = top
        return unsafe restore(s)
    }
    switch index {
    case SpecialIndex.at, SpecialIndex.atPut, SpecialIndex.size:
        let rcv = unsafe (sp - argc).pointee
        guard rcv & Oop.objectTagMask == 0 else { return nil }
        let h = om.headerWord(rcv)
        let cls = h & Header.classMask
        guard cls == WellKnown.array || cls == WellKnown.byteArray else { return nil }
        let count = (h & Header.countMask) &>> Header.countShift
        if index == SpecialIndex.size {
            unsafe sp.pointee = tagged(Int(count))
            return unsafe regsAt(s, pc, sp, fp, hdr)
        }
        let i = unsafe (sp - argc + 1).pointee
        guard i & 1 != 0, untagged(i) >= 1, UInt64(untagged(i)) <= count else { return nil }
        let k = untagged(i) &- 1
        let o = Oop(raw: rcv)
        if index == SpecialIndex.at {
            let v = cls == WellKnown.array ? om.load(o, k).raw : tagged(Int(om.loadByte(o, k)))
            unsafe (sp - 1).pointee = v
            return unsafe regsAt(s, pc, sp - 1, fp, hdr)
        }
        if h & Header.readOnlyBit != 0 { return nil }  // the send's primitive refuses it
        let v = unsafe sp.pointee
        if cls == WellKnown.array {
            unsafe storeWithBarrier(s, om, o, k, Oop(raw: v), .atPut)
        } else {
            guard v & 1 != 0, untagged(v) >= 0, untagged(v) <= 255 else { return nil }
            unsafe checkedStoreByte(s, o, k, UInt8(untagged(v)))
        }
        unsafe (sp - 2).pointee = v
        return unsafe regsAt(s, pc, sp - 2, fp, hdr)
    case SpecialIndex.value, SpecialIndex.value1, SpecialIndex.value2:
        return unsafe activateClosure(s, om, regsAt(s, pc, sp, fp, hdr), argc, 1)
    default:
        return nil
    }
}

// MARK: - activation primitives

/// Primitives that activate a frame rather than answer: 80 to 84 closure
/// `value`, `value:`, `value:value:`, `value:value:value:`,
/// `valueWithArguments:`; 85 (module 8d) `CompiledMethod
/// valueWithReceiver:arguments:`; 86 to 89 `perform:`, `perform:with:`,
/// `perform:with:with:`, `perform:withArguments:`.
enum ActivationPrimitive {
    static let first = 80
    static let last = 89
    static let valueWithArguments = 84
    static let valueWithReceiver = 85
    static let perform = 86
    static let performWithArguments = 89
}

/// The most arguments `valueWithArguments:` and `perform:withArguments:`
/// spread on the stack.
let maxSpreadArguments = 64

@inline(never)
func activationPrimitive(_ s: StatePointer, _ pc: UnsafePointer<UInt8>, _ sp: UnsafeMutablePointer<UInt64>,
                         _ fp: UnsafeMutablePointer<UInt64>, _ hdr: UnsafeMutablePointer<UInt64>, _ method: UInt64,
                         _ prim: Int, _ argc: Int, _ length: Int) -> Regs {
    let om = unsafe s.pointee.om
    unsafe s.pointee.counters.primitiveCalls &+= 1
    let r = unsafe regsAt(s, pc, sp, fp, hdr)
    switch prim {
    case 80...83:
        if prim - 80 == argc, let out = unsafe activateClosure(s, om, r, argc, length) { return out }
    case ActivationPrimitive.valueWithArguments:
        if argc == 1, let n = unsafe spreadArray(s, sp, extra: 0) {
            if let out = unsafe activateClosure(s, om, Regs(pc: r.pc, sp: sp + n - 1, fp: fp, hdr: hdr, code: r.code, lits: r.lits),
                                                n, length) { return out }
            unsafe unspread(s, sp, n)
        }
    case ActivationPrimitive.valueWithReceiver:
        // method receiver array  ->  receiver a1 ... an, the method activated
        // as if a send had found it (module 8d: running a method once
        // without installing it, `Compiler evaluate:`).
        if argc == 2, unsafe runsOnce(s, (sp - 2).pointee, (sp - 1).pointee, sp.pointee), let k = unsafe spreadArray(s, sp, extra: 0) {
            let meth = unsafe (sp - 2).pointee
            unsafe (sp - 2).pointee = (sp - 1).pointee
            var i = 0
            while i < k {
                unsafe (sp - 1 + i).pointee = (sp + i).pointee
                i &+= 1
            }
            return unsafe activate(s, om, Regs(pc: r.pc, sp: sp + k - 2, fp: fp, hdr: hdr, code: r.code, lits: r.lits), meth, k, length)
        }
    case ActivationPrimitive.perform...(ActivationPrimitive.performWithArguments - 1):
        // receiver selector a1 ... an  ->  receiver a1 ... an, send selector
        let n = prim - ActivationPrimitive.perform
        if argc == n + 1 {
            let sel = unsafe (sp - n).pointee
            if unsafe isSelectorOf(s, sel, arity: n, receiver: (sp - n - 1).pointee) {
                var i = 0
                while i < n {
                    unsafe (sp - n + i).pointee = (sp - n + i + 1).pointee
                    i &+= 1
                }
                unsafe s.pointee.counters.performs &+= 1
                return unsafe send(s, om, Regs(pc: r.pc, sp: sp - 1, fp: fp, hdr: hdr, code: r.code, lits: r.lits), sel, n,
                                   length, poll: false)
            }
        }
    case ActivationPrimitive.performWithArguments:
        // receiver selector array  ->  receiver a1 ... an
        let sel = unsafe (sp - 1).pointee
        if argc == 2, let arr = Optional(unsafe sp.pointee), isArray(om, arr) {
            let n = Int(om.count(of: Oop(raw: arr)))
            if unsafe isSelectorOf(s, sel, arity: n, receiver: (sp - 2).pointee), let k = unsafe spreadArray(s, sp, extra: 0) {
                // Shift the spread arguments down over the selector.
                var i = 0
                while i < k {
                    unsafe (sp - 1 + i).pointee = (sp + i).pointee
                    i &+= 1
                }
                unsafe s.pointee.counters.performs &+= 1
                return unsafe send(s, om, Regs(pc: r.pc, sp: sp + k - 2, fp: fp, hdr: hdr, code: r.code, lits: r.lits), sel, k,
                                   length, poll: false)
            }
        }
    default:
        break
    }
    return unsafe primitiveFailure(s, pc, sp, fp, hdr, method, prim, argc, length)
}

/// Primitive 85's checks: `meth` a CompiledMethod (not a block method,
/// no primitive: its bytecodes are what runs) taking as many arguments as
/// the Array `arr` holds, and `rcv` an instance of its class or a
/// subclass, so its instance variables are the ones the verifier allowed.
/// Every CompiledMethod in the heap was verified (the loader, the image
/// build, the make primitive; nothing else can make one).
@inline(never)
func runsOnce(_ s: StatePointer, _ meth: UInt64, _ rcv: UInt64, _ arr: UInt64) -> Bool {
    let om = unsafe s.pointee.om
    guard meth & Oop.objectTagMask == 0, meth != 0, om.headerWord(meth) & Header.classMask == WellKnown.method,
          isArray(om, arr) else { return false }
    let m = Oop(raw: meth)
    guard methodFlags(om, meth) & MethodFlags.block == 0, om.load(m, MethodLayout.primitive) == Oop(smallInteger: 0),
          om.load(m, MethodLayout.argc) == Oop(smallInteger: Int64(om.count(of: Oop(raw: arr)))) else { return false }
    let mc = om.load(m, MethodLayout.methodClass)
    var cls = om.classOop(classIndexOf(om, rcv))
    var steps = om.classCount
    let nilObject = unsafe s.pointee.nilObject
    while cls != nilObject && steps > 0 {
        if cls == mc { return true }
        cls = om.load(cls, ClassLayout.superclass)
        steps &-= 1
    }
    return false
}

@inline(__always)
func isArray(_ om: ObjectMemory, _ v: UInt64) -> Bool {
    v & Oop.objectTagMask == 0 && om.headerWord(v) & Header.classMask == WellKnown.array
}

/// `sel` is a Symbol and the method a receiver of class `cls` finds for it
/// takes `n` arguments (or there is none: `doesNotUnderstand:` builds its
/// Message from `n`). The arity is the method's, so a Symbol that is not a
/// selector, or one whose method takes another count, fails.
func isSelectorOf(_ s: StatePointer, _ sel: UInt64, arity n: Int, receiver rcv: UInt64) -> Bool {
    let om = unsafe s.pointee.om
    guard sel & Oop.objectTagMask == 0, sel != 0, om.headerWord(sel) & Header.classMask == WellKnown.symbol else { return false }
    let method = unsafe lookupMiss(s, classIndexOf(om, rcv), sel)
    if method != 0 { return untagged(om.load(Oop(raw: method), MethodLayout.argc).raw) == n }
    // No method: the arity as the bytes spell it (binary 1, else colons).
    let o = Oop(raw: sel)
    let count = Int(om.count(of: o))
    if count == 0 { return false }
    let first = om.loadByte(o, 0)
    let word = first >= 0x80 || first == 95 || (first | 0x20) >= 97 && (first | 0x20) <= 122
    if !word { return n == 1 }
    var colons = 0
    for i in 0..<count where om.loadByte(o, i) == 58 { colons &+= 1 }
    return colons == n
}

/// Replace the Array on top of the stack by its elements. nil when it is
/// not an Array, too large, or does not fit the stack.
func spreadArray(_ s: StatePointer, _ sp: UnsafeMutablePointer<UInt64>, extra: Int) -> Int? {
    let om = unsafe s.pointee.om
    let arr = unsafe sp.pointee
    guard isArray(om, arr) else { return nil }
    let n = Int(om.count(of: Oop(raw: arr)))
    guard n <= maxSpreadArguments, unsafe sp + n + 8 < s.pointee.stackEnd else { return nil }
    for i in 0..<n { unsafe (sp + i).pointee = om.load(Oop(raw: arr), i).raw }
    if n == 0 { unsafe sp.pointee = arr }  // nothing spread: keep the word valid
    unsafe (sp + n).pointee = arr  // kept above, so the Array stays a root if the activation fails
    return n
}

/// Undo `spreadArray` (the activation did not happen).
func unspread(_ s: StatePointer, _ sp: UnsafeMutablePointer<UInt64>, _ n: Int) {
    unsafe sp.pointee = (sp + n).pointee
}

/// A failed primitive: its method's bytecodes run as an ordinary
/// activation, or with none, the error `primitiveFailed`.
func primitiveFailure(_ s: StatePointer, _ pc: UnsafePointer<UInt8>, _ sp: UnsafeMutablePointer<UInt64>,
                      _ fp: UnsafeMutablePointer<UInt64>, _ hdr: UnsafeMutablePointer<UInt64>, _ method: UInt64,
                      _ prim: Int, _ argc: Int, _ length: Int) -> Regs {
    let om = unsafe s.pointee.om
    unsafe s.pointee.counters.primitiveFailures &+= 1
    unsafe save(s, pc, sp, fp, hdr)
    let r = unsafe restore(s)
    if om.count(of: om.load(Oop(raw: method), MethodLayout.bytecodes)) == 0 {
        let m = unsafe Machine(state: s)
        unsafe s.pointee.regs.pc &-= length
        m.fail(.primitiveFailed, selector: om.load(Oop(raw: method), MethodLayout.selector),
               receiverClass: m.classIndex(of: Oop(raw: unsafe (sp - argc).pointee)), primitive: prim)
        return unsafe leaving(s, r)
    }
    return unsafe activate(s, om, r, method, argc, length)
}

// MARK: - send_super

/// `send_super lit argc`: look the selector up from the superclass of the
/// running method's class (`MethodLayout.methodClass`), through the same
/// lookup cache: a line keyed by the superclass's index answers what a
/// receiver of that class would get. Polls like a send.
@inline(never)
func superSend(_ s: StatePointer, _ pc: UnsafePointer<UInt8>, _ sp: UnsafeMutablePointer<UInt64>,
               _ fp: UnsafeMutablePointer<UInt64>, _ hdr: UnsafeMutablePointer<UInt64>, _ lit: Int, _ argc: Int,
               _ length: Int) -> Regs {
    var r = unsafe regsAt(s, pc, sp, fp, hdr)
    unsafe s.pointee.countdown &-= 1
    if unsafe s.pointee.countdown == 0 || s.pointee.safepointFlag.pointee.load(ordering: .relaxed) != 0 {
        unsafe flushForPoll(s, pc, sp, fp, hdr)
        if unsafe pollSlow(s, rewind: length) { return unsafe leavingWithoutStack(s) }
        r = unsafe restore(s)
    }
    let om = unsafe s.pointee.om
    unsafe s.pointee.counters.sends &+= 1
    unsafe s.pointee.counters.superSends &+= 1
    let sel = unsafe r.lits[lit]
    var mc = om.load(Oop(raw: unsafe r.hdr[Frame.method]), MethodLayout.methodClass)
    if _slowPath(om.config.testSwitches.superFromReceiverClass) {
        mc = om.classOop(classIndexOf(om, unsafe (r.sp - argc).pointee))
    }
    let sup = om.load(mc, ClassLayout.superclass)
    let rcv = unsafe (r.sp - argc).pointee
    if unsafe sup == s.pointee.nilObject {
        return unsafe doesNotUnderstand(s, r.pc, r.sp, r.fp, r.hdr, sel, argc, length)
    }
    let cls = UInt64(untagged(om.load(sup, ClassLayout.classIndex).raw))
    let e = unsafe s.pointee.cache + (Int(truncatingIfNeeded: (sel &>> 4) ^ cls) & (InterpreterState.cacheEntries &- 1))
    var method: UInt64
    if unsafe e.pointee.classIndex == cls && e.pointee.selector == sel {
        method = unsafe e.pointee.method
    } else {
        method = unsafe lookupMiss(s, cls, sel)
        if method == 0 {
            _ = rcv
            return unsafe doesNotUnderstand(s, r.pc, r.sp, r.fp, r.hdr, sel, argc, length)
        }
    }
    return unsafe invoke(s, om, r, method, argc, length)
}

// MARK: - the extension prefix

/// `ext hi` then an extensible instruction: its first operand is
/// `hi << 8 | operand`. Rare (more than 256 literals, slots or temps), so
/// the whole extended instruction runs here.
@inline(never)
func extendedInstruction(_ s: StatePointer, _ pc: UnsafePointer<UInt8>, _ sp: UnsafeMutablePointer<UInt64>,
                         _ fp: UnsafeMutablePointer<UInt64>, _ hdr: UnsafeMutablePointer<UInt64>) -> Regs {
    let om = unsafe s.pointee.om
    let hi = unsafe Int(pc[0])
    guard let op = unsafe Opcode.decode(pc[1]) else {
        return unsafe failAt(s, pc + 1, sp, fp, hdr, 2, .invalidBytecode, 0, fp.pointee)
    }
    let a = unsafe hi &<< 8 | Int(pc[2])
    let b = unsafe op.length > 2 ? Int(pc[3]) : 0
    let next = unsafe pc + 1 + op.length
    let length = 2 + op.length
    var r = unsafe regsAt(s, next, sp, fp, hdr)
    switch op {
    case .pushTemp:
        unsafe push(&r, r.fp[1 &+ a])
    case .storeTemp:
        unsafe r.fp[1 &+ a] = r.sp.pointee
        unsafe r.sp -= 1
    case .pushLiteral:
        unsafe push(&r, r.lits[a])
    case .pushIvar:
        let rcv = unsafe r.fp.pointee
        if !hasSlot(om, rcv, a) { return unsafe failAt(s, next, sp, fp, hdr, length, .invalidSlotAccess, 0, rcv) }
        push(&r, om.load(Oop(raw: rcv), a).raw)
    case .storeIvar:
        let rcv = unsafe r.fp.pointee
        if !canStore(om, rcv, a) { return unsafe storeRefused(s, next, sp, fp, hdr, rcv, a, length, .storeIvar) }
        unsafe storeWithBarrier(s, om, Oop(raw: rcv), a, Oop(raw: r.sp.pointee), .storeIvar)
        unsafe r.sp -= 1
    case .send:
        return unsafe send(s, om, r, r.lits[a], b, length, poll: true)
    case .sendSuper:
        return unsafe superSend(s, next, sp, fp, hdr, a, b, length)
    case .pushClosure:
        return unsafe pushClosure(s, next, sp, fp, hdr, a, b)
    case .pushNewArray:
        return unsafe pushNewArray(s, next, sp, fp, hdr, a)
    case .pushTempVectorSlot:
        let tv = unsafe r.fp[1 &+ b]
        if !hasSlot(om, tv, a) { return unsafe failAt(s, next, sp, fp, hdr, length, .invalidSlotAccess, 0, tv) }
        push(&r, om.load(Oop(raw: tv), a).raw)
    case .storeTempVectorSlot:
        let tv = unsafe r.fp[1 &+ b]
        if !canStore(om, tv, a) { return unsafe storeRefused(s, next, sp, fp, hdr, tv, a, length, .storeTempVector) }
        unsafe storeWithBarrier(s, om, Oop(raw: tv), a, Oop(raw: r.sp.pointee), .storeTempVector)
        unsafe r.sp -= 1
    default:
        return unsafe failAt(s, next, sp, fp, hdr, length, .invalidBytecode, 0, fp.pointee)
    }
    return r
}

/// The receiver has pointer slot `n` and is not read-only: two single-bit
/// tests (bits 47 and 50 together are not a logical immediate, and a mask
/// built in a register cost a register in the dispatch loop).
@_transparent
func canStore(_ om: ObjectMemory, _ rcv: UInt64, _ n: Int) -> Bool {
    if rcv & Oop.objectTagMask != 0 { return false }
    let h = om.headerWord(rcv)
    return h & Header.bytesBit == 0 && h & Header.readOnlyBit == 0
        && UInt64(truncatingIfNeeded: n) < (h & Header.countMask) &>> Header.countShift
}

/// `canStore` failed only because the object is read-only.
func isReadOnlySlot(_ om: ObjectMemory, _ rcv: UInt64, _ n: Int) -> Bool {
    if rcv & Oop.objectTagMask != 0 || rcv == 0 { return false }
    let h = om.headerWord(rcv)
    return h & Header.readOnlyBit != 0 && h & Header.bytesBit == 0
        && UInt64(truncatingIfNeeded: n) < (h & Header.countMask) &>> Header.countShift
}

// MARK: - the v1 instructions run out of line

/// The v1 instructions whose fast paths run out of line, one call each from
/// their own case: `ne`, `not_identical`, `at`, `size`, `class_of`,
/// `is_nil`, `not_nil`, `push_tv_slot`, `store_tv_slot`,
/// `push_this_context`. Inline in the loop they cost the v0 kernels 4 to
/// 16 percent through register pressure (docs/modules/object-model.md,
/// "Measurements"). `pc` is past the opcode.
@inline(never)
func v1Instruction(_ s: StatePointer, _ pc: UnsafePointer<UInt8>, _ sp: UnsafeMutablePointer<UInt64>,
                   _ fp: UnsafeMutablePointer<UInt64>, _ hdr: UnsafeMutablePointer<UInt64>) -> Regs {
    let om = unsafe s.pointee.om
    let nilObject = unsafe s.pointee.nilObject.raw
    let trueObject = unsafe s.pointee.trueObject.raw, falseObject = unsafe s.pointee.falseObject.raw
    var r = unsafe regsAt(s, pc, sp, fp, hdr)
    switch unsafe Opcode.decode((pc - 1).pointee) {
    case .ne?:
        let b = unsafe r.sp.pointee, a = unsafe (r.sp - 1).pointee
        if a & b & 1 != 0 {
            binaryResult(&r, a != b ? trueObject : falseObject)
            return r
        }
        return unsafe specialSend(s, r.pc, r.sp, r.fp, r.hdr, 12 &<< 8 | 1)
    case .notIdentical?:
        let b = unsafe r.sp.pointee, a = unsafe (r.sp - 1).pointee
        binaryResult(&r, a != b ? trueObject : falseObject)
        return r
    case .at?:
        let i = unsafe r.sp.pointee, a = unsafe (r.sp - 1).pointee
        if a & Oop.objectTagMask == 0 && i & 1 != 0 {
            let h = om.headerWord(a)
            let k = UInt64(bitPattern: Int64(bitPattern: i) &>> 1) &- 1
            if h & Header.classMask == WellKnown.array && k < (h & Header.countMask) &>> Header.countShift {
                binaryResult(&r, om.load(Oop(raw: a), Int(truncatingIfNeeded: k)).raw)
                return r
            }
        }
        return unsafe specialSend(s, r.pc, r.sp, r.fp, r.hdr, 14 &<< 8 | 1)
    case .size?:
        return unsafe specialSend(s, r.pc, r.sp, r.fp, r.hdr, 16 &<< 8 | 0)
    case .classOf?:
        unsafe r.sp.pointee = om.classOop(classIndexOf(om, r.sp.pointee)).raw
        return r
    case .isNil?:
        unsafe r.sp.pointee = r.sp.pointee == nilObject ? trueObject : falseObject
        return r
    case .notNil?:
        unsafe r.sp.pointee = r.sp.pointee == nilObject ? falseObject : trueObject
        return r
    case .pushTempVectorSlot?:
        let n = unsafe Int(r.pc[0])
        let tv = unsafe r.fp[1 &+ Int(r.pc[1])]
        unsafe r.pc += 2
        if !hasSlot(om, tv, n) { return unsafe failAt(s, r.pc, r.sp, r.fp, r.hdr, 3, .invalidSlotAccess, 0, tv) }
        push(&r, om.load(Oop(raw: tv), n).raw)
        return r
    case .storeTempVectorSlot?:
        let n = unsafe Int(r.pc[0])
        let tv = unsafe r.fp[1 &+ Int(r.pc[1])]
        unsafe r.pc += 2
        if !canStore(om, tv, n) { return unsafe storeRefused(s, r.pc, r.sp, r.fp, r.hdr, tv, n, 3, .storeTempVector) }
        unsafe storeWithBarrier(s, om, Oop(raw: tv), n, Oop(raw: r.sp.pointee), .storeTempVector)
        unsafe r.sp -= 1
        return r
    case .pushThisContext?:
        let c = unsafe r.hdr[Frame.context]
        if c & Oop.objectTagMask == 0 {
            push(&r, c)
            return r
        }
        return unsafe pushThisContext(s, r.pc, r.sp, r.fp, r.hdr)
    default:
        return unsafe failAt(s, r.pc, r.sp, r.fp, r.hdr, 1, .invalidBytecode, 0, r.fp.pointee)
    }
}
