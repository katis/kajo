import Synchronization

/// The dispatch loop: one case per opcode, a `switch` over `Opcode?` that
/// compiles to one jump table (docs/modules/interpreter.md has the check).
/// Fast paths are inline; everything else is one out-of-line call that
/// takes the registers as scalars and answers the next registers. A slow
/// path that stops the loop answers registers whose pc is the leave code,
/// which decodes as no opcode.
func interpret(_ s: StatePointer, _ start: Regs) {
    var r = start
    let om = unsafe s.pointee.om
    let trueObject = unsafe s.pointee.trueObject.raw
    let falseObject = unsafe s.pointee.falseObject.raw
    let flag = unsafe s.pointee.safepointFlag
    while true {
        let byte = unsafe r.pc.pointee
        #if KAJO_COUNT_OPCODES
        unsafe countOpcode(byte, r.pc)
        #endif
        unsafe r.pc += 1
        switch Opcode.decode(byte) {
        case .pushTemp?:
            let n = unsafe Int(r.pc.pointee)
            unsafe r.pc += 1
            unsafe push(&r, r.fp[1 &+ n])
        case .pushLiteral?:
            let n = unsafe Int(r.pc.pointee)
            unsafe r.pc += 1
            unsafe push(&r, r.lits[n])
        case .pushSelf?:
            unsafe push(&r, r.fp.pointee)
        case .pushIvar?:
            let n = unsafe Int(r.pc.pointee)
            unsafe r.pc += 1
            let rcv = unsafe r.fp.pointee
            if _slowPath(!hasSlot(om, rcv, n)) {
                r = unsafe failAt(s, r.pc, r.sp, r.fp, r.hdr, 2, .invalidSlotAccess, 0, rcv)
                continue
            }
            push(&r, om.load(Oop(raw: rcv), n).raw)
        case .storeTemp?:
            let n = unsafe Int(r.pc.pointee)
            unsafe r.pc += 1
            unsafe r.fp[1 &+ n] = r.sp.pointee
            unsafe r.sp -= 1
        case .storeIvar?:
            let n = unsafe Int(r.pc.pointee)
            unsafe r.pc += 1
            let rcv = unsafe r.fp.pointee
            // The slot check's header load also covers the read-only bit
            // (module 8): one mask, no extra instruction.
            if _slowPath(!canStore(om, rcv, n)) {
                r = unsafe storeRefused(s, r.pc, r.sp, r.fp, r.hdr, rcv, n, 2, .storeIvar)
                continue
            }
            unsafe storeWithBarrier(s, flag, om, Oop(raw: rcv), n, Oop(raw: r.sp.pointee), .storeIvar)
            unsafe r.sp -= 1
        case .pop?:
            unsafe r.sp -= 1
        case .dup?:
            unsafe push(&r, r.sp.pointee)
        case .pushNil?:
            // Loaded where used: a register for nil cost the store path
            // its heap and table bases (module 8).
            push(&r, unsafe s.pointee.nilObject.raw)
        case .pushTrue?:
            push(&r, trueObject)
        case .pushFalse?:
            push(&r, falseObject)
        case .pushInt?:
            let v = unsafe OperandDecoding.int8(r.pc.pointee)
            unsafe r.pc += 1
            push(&r, tagged(Int(v)))
        case .send?:
            let lit = unsafe Int(r.pc[0])
            let argc = unsafe Int(r.pc[1])
            unsafe r.pc += 2
            r = unsafe send(s, om, r, r.lits[lit], argc, 3, poll: true)
        case .returnTop?:
            r = unsafe doReturn(s, om, r, r.sp.pointee)
        case .returnSelf?:
            r = unsafe doReturn(s, om, r, r.fp.pointee)
        case .jump?:
            let off = unsafe OperandDecoding.jumpOffset(r.pc[0], r.pc[1])
            unsafe r.pc += 2 &+ off
            if off < 0, unsafe pollDue(s, flag) {
                r = unsafe pollAtJump(s, r.pc, r.sp, r.fp, r.hdr)
            }
        case .jumpIfTrue?:
            let off = unsafe OperandDecoding.jumpOffset(r.pc[0], r.pc[1])
            unsafe r.pc += 2
            let v = unsafe r.sp.pointee
            unsafe r.sp -= 1
            if v == trueObject {
                unsafe r.pc += off
                if off < 0, unsafe pollDue(s, flag) {
                    r = unsafe pollAtJump(s, r.pc, r.sp, r.fp, r.hdr)
                }
            } else if _slowPath(v != falseObject) {
                r = unsafe failAt(s, r.pc, r.sp + 1, r.fp, r.hdr, 3, .mustBeBoolean, 0, v)
            }
        case .jumpIfFalse?:
            let off = unsafe OperandDecoding.jumpOffset(r.pc[0], r.pc[1])
            unsafe r.pc += 2
            let v = unsafe r.sp.pointee
            unsafe r.sp -= 1
            if v == falseObject {
                unsafe r.pc += off
                if off < 0, unsafe pollDue(s, flag) {
                    r = unsafe pollAtJump(s, r.pc, r.sp, r.fp, r.hdr)
                }
            } else if _slowPath(v != trueObject) {
                r = unsafe failAt(s, r.pc, r.sp + 1, r.fp, r.hdr, 3, .mustBeBoolean, 0, v)
            }
        case .add?:
            let b = unsafe r.sp.pointee, a = unsafe (r.sp - 1).pointee
            if a & b & 1 != 0 {
                let (v, o) = Int64(bitPattern: a).addingReportingOverflow(Int64(bitPattern: b) &- 1)
                if !o { binaryResult(&r, UInt64(bitPattern: v)); continue }
            }
            r = unsafe specialSend(s, r.pc, r.sp, r.fp, r.hdr, 0 &<< 8 | 1)
        case .sub?:
            let b = unsafe r.sp.pointee, a = unsafe (r.sp - 1).pointee
            if a & b & 1 != 0 {
                let (v, o) = Int64(bitPattern: a).subtractingReportingOverflow(Int64(bitPattern: b) &- 1)
                if !o { binaryResult(&r, UInt64(bitPattern: v)); continue }
            }
            r = unsafe specialSend(s, r.pc, r.sp, r.fp, r.hdr, 1 &<< 8 | 1)
        case .mul?:
            let b = unsafe r.sp.pointee, a = unsafe (r.sp - 1).pointee
            if a & b & 1 != 0 {
                let (v, o) = (Int64(bitPattern: a) &>> 1).multipliedReportingOverflow(by: Int64(bitPattern: b) &- 1)
                if !o { binaryResult(&r, UInt64(bitPattern: v) | 1); continue }
            }
            r = unsafe specialSend(s, r.pc, r.sp, r.fp, r.hdr, 2 &<< 8 | 1)
        case .lt?:
            let b = unsafe r.sp.pointee, a = unsafe (r.sp - 1).pointee
            if a & b & 1 != 0 {
                binaryResult(&r, Int64(bitPattern: a) < Int64(bitPattern: b) ? trueObject : falseObject)
            } else {
                r = unsafe specialSend(s, r.pc, r.sp, r.fp, r.hdr, 3 &<< 8 | 1)
            }
        case .gt?:
            let b = unsafe r.sp.pointee, a = unsafe (r.sp - 1).pointee
            if a & b & 1 != 0 {
                binaryResult(&r, Int64(bitPattern: a) > Int64(bitPattern: b) ? trueObject : falseObject)
            } else {
                r = unsafe specialSend(s, r.pc, r.sp, r.fp, r.hdr, 4 &<< 8 | 1)
            }
        case .le?:
            let b = unsafe r.sp.pointee, a = unsafe (r.sp - 1).pointee
            if a & b & 1 != 0 {
                binaryResult(&r, Int64(bitPattern: a) <= Int64(bitPattern: b) ? trueObject : falseObject)
            } else {
                r = unsafe specialSend(s, r.pc, r.sp, r.fp, r.hdr, 5 &<< 8 | 1)
            }
        case .ge?:
            let b = unsafe r.sp.pointee, a = unsafe (r.sp - 1).pointee
            if a & b & 1 != 0 {
                binaryResult(&r, Int64(bitPattern: a) >= Int64(bitPattern: b) ? trueObject : falseObject)
            } else {
                r = unsafe specialSend(s, r.pc, r.sp, r.fp, r.hdr, 6 &<< 8 | 1)
            }
        case .eq?:
            let b = unsafe r.sp.pointee, a = unsafe (r.sp - 1).pointee
            if a & b & 1 != 0 {
                binaryResult(&r, a == b ? trueObject : falseObject)
            } else {
                r = unsafe specialSend(s, r.pc, r.sp, r.fp, r.hdr, 7 &<< 8 | 1)
            }
        case .identical?:
            let b = unsafe r.sp.pointee, a = unsafe (r.sp - 1).pointee
            binaryResult(&r, a == b ? trueObject : falseObject)
        // Bytecode set v1 (module 8).
        case .div?:
            r = unsafe specialSend(s, r.pc, r.sp, r.fp, r.hdr, 9 &<< 8 | 1)
        case .intDiv?:
            r = unsafe specialSend(s, r.pc, r.sp, r.fp, r.hdr, 10 &<< 8 | 1)
        case .mod?:
            r = unsafe specialSend(s, r.pc, r.sp, r.fp, r.hdr, 11 &<< 8 | 1)
        case .ne?:
            r = unsafe v1Instruction(s, r.pc, r.sp, r.fp, r.hdr)
        case .notIdentical?:
            r = unsafe v1Instruction(s, r.pc, r.sp, r.fp, r.hdr)
        case .at?:
            r = unsafe v1Instruction(s, r.pc, r.sp, r.fp, r.hdr)
        case .atPut?:
            r = unsafe specialSend(s, r.pc, r.sp, r.fp, r.hdr, 15 &<< 8 | 2)
        case .size?:
            r = unsafe v1Instruction(s, r.pc, r.sp, r.fp, r.hdr)
        case .classOf?:
            r = unsafe v1Instruction(s, r.pc, r.sp, r.fp, r.hdr)
        case .value?:
            r = unsafe specialSend(s, r.pc, r.sp, r.fp, r.hdr, 18 &<< 8 | 0)
        case .value1?:
            r = unsafe specialSend(s, r.pc, r.sp, r.fp, r.hdr, 19 &<< 8 | 1)
        case .value2?:
            r = unsafe specialSend(s, r.pc, r.sp, r.fp, r.hdr, 20 &<< 8 | 2)
        case .isNil?:
            r = unsafe v1Instruction(s, r.pc, r.sp, r.fp, r.hdr)
        case .notNil?:
            r = unsafe v1Instruction(s, r.pc, r.sp, r.fp, r.hdr)
        case .sendSuper?:
            let lit = unsafe Int(r.pc[0])
            let argc = unsafe Int(r.pc[1])
            r = unsafe superSend(s, r.pc + 2, r.sp, r.fp, r.hdr, lit, argc, 3)
        case .pushClosure?:
            let lit = unsafe Int(r.pc[0])
            let copied = unsafe Int(r.pc[1])
            r = unsafe pushClosure(s, r.pc + 2, r.sp, r.fp, r.hdr, lit, copied)
        case .pushNewArray?:
            let n = unsafe Int(r.pc.pointee)
            r = unsafe pushNewArray(s, r.pc + 1, r.sp, r.fp, r.hdr, n)
        case .pushTempVectorSlot?:
            r = unsafe v1Instruction(s, r.pc, r.sp, r.fp, r.hdr)
        case .storeTempVectorSlot?:
            r = unsafe v1Instruction(s, r.pc, r.sp, r.fp, r.hdr)
        case .pushThisContext?:
            r = unsafe v1Instruction(s, r.pc, r.sp, r.fp, r.hdr)
        case .blockReturn?:
            r = unsafe doReturn(s, om, r, r.sp.pointee)
        case .nonlocalReturn?:
            r = unsafe nonLocalReturn(s, r.pc, r.sp, r.fp, r.hdr)
        case .ext?:
            r = unsafe extendedInstruction(s, r.pc, r.sp, r.fp, r.hdr)
        // Interpreter speed: fused instructions. `pc` is past the fused
        // opcode, at the first part's operands; the second part's operands
        // follow at fixed offsets (the verifier checked it is there). When
        // a fast path does not apply, the first part runs alone exactly as
        // its plain case would and the loop goes on at the second part.
        case .pushTempPushTemp?:
            let a = unsafe Int(r.pc[0]), b = unsafe Int(r.pc[2])
            unsafe r.pc += 3
            unsafe push(&r, r.fp[1 &+ a])
            unsafe push(&r, r.fp[1 &+ b])
        case .pushTempPushInt?:
            let a = unsafe Int(r.pc[0])
            let k = unsafe OperandDecoding.int8(r.pc[2])
            unsafe r.pc += 3
            unsafe push(&r, r.fp[1 &+ a])
            push(&r, tagged(Int(k)))
        case .pushSelfPushTemp?:
            let b = unsafe Int(r.pc[1])
            unsafe r.pc += 2
            unsafe push(&r, r.fp.pointee)
            unsafe push(&r, r.fp[1 &+ b])
        case .pushSelfPushInt?:
            let k = unsafe OperandDecoding.int8(r.pc[1])
            unsafe r.pc += 2
            unsafe push(&r, r.fp.pointee)
            push(&r, tagged(Int(k)))
        case .pushIntAdd?:
            let k = unsafe OperandDecoding.int8(r.pc[0])
            let a = unsafe r.sp.pointee
            if a & 1 != 0 {
                let (v, o) = Int64(bitPattern: a).addingReportingOverflow(k &<< 1)
                if !o {
                    unsafe r.sp.pointee = UInt64(bitPattern: v)
                    unsafe r.pc += 2
                    continue
                }
            }
            unsafe r.pc += 1
            push(&r, tagged(Int(k)))
        case .pushIntSub?:
            let k = unsafe OperandDecoding.int8(r.pc[0])
            let a = unsafe r.sp.pointee
            if a & 1 != 0 {
                let (v, o) = Int64(bitPattern: a).subtractingReportingOverflow(k &<< 1)
                if !o {
                    unsafe r.sp.pointee = UInt64(bitPattern: v)
                    unsafe r.pc += 2
                    continue
                }
            }
            unsafe r.pc += 1
            push(&r, tagged(Int(k)))
        case .addStoreTemp?:
            let b = unsafe r.sp.pointee, a = unsafe (r.sp - 1).pointee
            if a & b & 1 != 0 {
                let (v, o) = Int64(bitPattern: a).addingReportingOverflow(Int64(bitPattern: b) &- 1)
                if !o {
                    let n = unsafe Int(r.pc[1])
                    unsafe r.fp[1 &+ n] = UInt64(bitPattern: v)
                    unsafe r.sp -= 2
                    unsafe r.pc += 2
                    continue
                }
            }
            r = unsafe specialSend(s, r.pc, r.sp, r.fp, r.hdr, 0 &<< 8 | 1)
        case .subStoreTemp?:
            let b = unsafe r.sp.pointee, a = unsafe (r.sp - 1).pointee
            if a & b & 1 != 0 {
                let (v, o) = Int64(bitPattern: a).subtractingReportingOverflow(Int64(bitPattern: b) &- 1)
                if !o {
                    let n = unsafe Int(r.pc[1])
                    unsafe r.fp[1 &+ n] = UInt64(bitPattern: v)
                    unsafe r.sp -= 2
                    unsafe r.pc += 2
                    continue
                }
            }
            r = unsafe specialSend(s, r.pc, r.sp, r.fp, r.hdr, 1 &<< 8 | 1)
        case .storeTempJump?:
            let n = unsafe Int(r.pc[0])
            unsafe r.fp[1 &+ n] = r.sp.pointee
            unsafe r.sp -= 1
            let off = unsafe OperandDecoding.jumpOffset(r.pc[2], r.pc[3])
            unsafe r.pc += 4 &+ off
            if off < 0, unsafe pollDue(s, flag) {
                r = unsafe pollAtJump(s, r.pc, r.sp, r.fp, r.hdr)
            }
        case .dupStoreTemp?:
            let n = unsafe Int(r.pc[1])
            unsafe r.fp[1 &+ n] = r.sp.pointee
            unsafe r.pc += 2
        case .popPushTemp?:
            let n = unsafe Int(r.pc[1])
            unsafe r.sp.pointee = r.fp[1 &+ n]
            unsafe r.pc += 2
        case .ltJumpIfFalse?:
            let b = unsafe r.sp.pointee, a = unsafe (r.sp - 1).pointee
            if a & b & 1 != 0 {
                r = unsafe compareAndJump(s, flag, r, Int64(bitPattern: a) < Int64(bitPattern: b))
            } else {
                r = unsafe specialSend(s, r.pc, r.sp, r.fp, r.hdr, 3 &<< 8 | 1)
            }
        case .gtJumpIfFalse?:
            let b = unsafe r.sp.pointee, a = unsafe (r.sp - 1).pointee
            if a & b & 1 != 0 {
                r = unsafe compareAndJump(s, flag, r, Int64(bitPattern: a) > Int64(bitPattern: b))
            } else {
                r = unsafe specialSend(s, r.pc, r.sp, r.fp, r.hdr, 4 &<< 8 | 1)
            }
        case .leJumpIfFalse?:
            let b = unsafe r.sp.pointee, a = unsafe (r.sp - 1).pointee
            if a & b & 1 != 0 {
                r = unsafe compareAndJump(s, flag, r, Int64(bitPattern: a) <= Int64(bitPattern: b))
            } else {
                r = unsafe specialSend(s, r.pc, r.sp, r.fp, r.hdr, 5 &<< 8 | 1)
            }
        case .geJumpIfFalse?:
            let b = unsafe r.sp.pointee, a = unsafe (r.sp - 1).pointee
            if a & b & 1 != 0 {
                r = unsafe compareAndJump(s, flag, r, Int64(bitPattern: a) >= Int64(bitPattern: b))
            } else {
                r = unsafe specialSend(s, r.pc, r.sp, r.fp, r.hdr, 6 &<< 8 | 1)
            }
        case .eqJumpIfFalse?:
            let b = unsafe r.sp.pointee, a = unsafe (r.sp - 1).pointee
            if a & b & 1 != 0 {
                r = unsafe compareAndJump(s, flag, r, a == b)
            } else {
                r = unsafe specialSend(s, r.pc, r.sp, r.fp, r.hdr, 7 &<< 8 | 1)
            }
        case .identicalJumpIfFalse?:
            let b = unsafe r.sp.pointee, a = unsafe (r.sp - 1).pointee
            r = unsafe compareAndJump(s, flag, r, a == b)
        case nil:
            // The leave code, or a byte outside the set.
            if unsafe s.pointee.exit != .running { return }
            if unsafe r.pc == UnsafePointer(s.pointee.leaveCode) + 1 { return }
            r = unsafe failAt(s, r.pc, r.sp, r.fp, r.hdr, 1, .invalidBytecode, 0, r.fp.pointee)
        }
    }
}

/// `store_ivar` or `store_tv_slot` could not store: the object is
/// read-only (send `modificationForbiddenAt:value:`), or it has no such slot
/// (the error). One call, out of line.
@inline(never)
func storeRefused(_ s: StatePointer, _ pc: UnsafePointer<UInt8>, _ sp: UnsafeMutablePointer<UInt64>,
                  _ fp: UnsafeMutablePointer<UInt64>, _ hdr: UnsafeMutablePointer<UInt64>, _ o: UInt64, _ n: Int,
                  _ length: Int, _ site: BarrierSite) -> Regs {
    let om = unsafe s.pointee.om
    if isReadOnlySlot(om, o, n) { return unsafe modificationForbiddenFromStore(s, pc, sp, fp, hdr, o, n + 1) }
    return unsafe failAt(s, pc, sp, fp, hdr, length, .invalidSlotAccess, 0, o)
}

/// A fused compare and `jump_if_false` whose compare had its answer
/// without a send: the two operands go, and the jump is taken when the
/// answer is false. `r.pc` is past the fused opcode (the jump's offset is
/// at 1 and 2).
@_transparent
func compareAndJump(_ s: StatePointer, _ flag: UnsafeMutablePointer<Atomic<UInt32>>, _ r: Regs, _ answer: Bool) -> Regs {
    var r = r
    let off = unsafe OperandDecoding.jumpOffset(r.pc[1], r.pc[2])
    unsafe r.sp -= 2
    unsafe r.pc += 3
    if !answer {
        unsafe r.pc += off
        if off < 0, unsafe pollDue(s, flag) {
            return unsafe pollAtJump(s, r.pc, r.sp, r.fp, r.hdr)
        }
    }
    return r
}

/// The poll at a backward jump: count down; due when the budget check is
/// or a stop is requested.
@_transparent
func pollDue(_ s: StatePointer, _ flag: UnsafeMutablePointer<Atomic<UInt32>>) -> Bool {
    unsafe s.pointee.countdown &-= 1
    return unsafe s.pointee.countdown == 0 || flag.pointee.load(ordering: .relaxed) != 0
}

@_transparent
func push(_ r: inout Regs, _ v: UInt64) {
    unsafe r.sp += 1
    unsafe r.sp.pointee = v
}

/// Pop two, push one.
@_transparent
func binaryResult(_ r: inout Regs, _ v: UInt64) {
    unsafe r.sp -= 1
    unsafe r.sp.pointee = v
}

/// The receiver has pointer slot `n`: an object, not bytes, and `n` below
/// its count. The loader checked `n` against the class; become: can change
/// the receiver under a running method, so the header decides.
@_transparent
func hasSlot(_ om: ObjectMemory, _ rcv: UInt64, _ n: Int) -> Bool {
    if rcv & Oop.objectTagMask != 0 { return false }
    let h = om.headerWord(rcv)
    return h & Header.bytesBit == 0 && UInt64(truncatingIfNeeded: n) < (h & Header.countMask) &>> Header.countShift
}
