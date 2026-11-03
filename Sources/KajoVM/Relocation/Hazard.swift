import Darwin
import Synchronization

// Hazard slots (docs/modules/relocation.md "Hazard slots"; docs/models/
// relocation.md, steps `M hazard`, `R relocate: hz[M]`). A primitive that
// keeps a body pointer across more than one access publishes the object in
// one of its worker's two slots (seq_cst), counts it in the VM-wide count
// of held slots (seq_cst), loads the state word (seq_cst) and spins while
// it is RELOCATING; the body is then valid until the slot is cleared
// (release). The relocator, after its CAS and a seq_cst fence, reads the
// count and, when nonzero, every slot (seq_cst): a hazarded object is
// reverted and skipped. Dekker: either the relocator sees the slot, or the
// primitive sees RELOCATING (or the switch) and uses the current body.

/// Publish `o` in hazard slot `k` (0 or 1) of `w` and wait until it is not
/// RELOCATING. Answers its state word: the body offset, valid until
/// `hazardRelease`. Never parks.
@inline(never)
func hazardAcquire(_ vm: VMPointer, _ w: WorkerPointer, _ k: Int, _ o: Oop) -> UInt64 {
    let om = unsafe vm.pointee.om
    guard unsafe vm.pointee.epochsOn else { return om.stateWord(o.raw) }
    let line = unsafe vm.shared(w.pointee.index)
    if k == 0 { unsafe line.pointee.hazard0.store(o.raw, ordering: .sequentiallyConsistent) }
    else { unsafe line.pointee.hazard1.store(o.raw, ordering: .sequentiallyConsistent) }
    unsafe vm.pointee.hazardsHeld.pointee.wrappingAdd(1, ordering: .sequentiallyConsistent)
    let sw = unsafe om.stateWordAtomic(o.raw)
    var e = unsafe sw.pointee.load(ordering: .sequentiallyConsistent)
    unsafe w.pointee.relocation.hazardsTaken &+= 1
    if e & EntryState.relocatingBit != 0 {
        unsafe w.pointee.relocation.hazardWaits &+= 1
        let t0 = nanoseconds()
        var spins = 0
        while e & EntryState.relocatingBit != 0 {
            spins &+= 1
            if spins & 63 == 0 { sched_yield() }
            e = unsafe sw.pointee.load(ordering: .sequentiallyConsistent)
        }
        unsafe noteSpin(w.pointer(to: \Worker.relocation)!, nanoseconds() &- t0)
    }
    return e
}

/// Clear hazard slot `k` (release): the primitive's accesses through the
/// body happen before the relocator can see the slot free.
@inline(__always)
func hazardRelease(_ vm: VMPointer, _ w: WorkerPointer, _ k: Int) {
    guard unsafe vm.pointee.epochsOn else { return }
    let line = unsafe vm.shared(w.pointee.index)
    if k == 0 { unsafe line.pointee.hazard0.store(0, ordering: .releasing) }
    else { unsafe line.pointee.hazard1.store(0, ordering: .releasing) }
    unsafe vm.pointee.hazardsHeld.pointee.wrappingSubtract(1, ordering: .releasing)
}

/// The relocator, after its CAS and fence: does any worker's hazard slot
/// name `o`? The count first, then the slots (all seq_cst).
@inline(__always)
func isHazarded(_ vm: VMPointer, _ o: UInt64) -> Bool {
    if unsafe vm.pointee.hazardsHeld.pointee.load(ordering: .sequentiallyConsistent) == 0 { return false }
    for i in unsafe 0..<vm.pointee.workerCount {
        let line = unsafe vm.shared(i)
        if unsafe line.pointee.hazard0.load(ordering: .sequentiallyConsistent) == o
            || line.pointee.hazard1.load(ordering: .sequentiallyConsistent) == o {
            return true
        }
    }
    return false
}

// MARK: - the array copy primitive

/// Primitive 38, `replaceFrom: start to: stop with: source startingAt: from`:
/// slots `start...stop` of the receiver get slots `from...` of `source`,
/// in ascending order (as the Smalltalk fallback does, overlap included).
/// Pointer objects only; a byte object or a bad index fails, and the
/// method's bytecodes run. The one primitive that holds body pointers
/// across a loop, so the one that needs hazard slots: the receiver in slot
/// 0 and the source in slot 1, for the whole loop. Each store runs the
/// barriers the flag word asks for (the SATB record of the overwritten
/// value while marking) and module 4's insertion barrier, and is seq_cst
/// (the young-collection model's finding: a store a barrier's load
/// follows). No post-store check: under the hazard the body cannot move.
func primReplace(_ m: Machine, _ c: PrimitiveCall) -> Oop {
    guard c.argc == 4 else { return .none }
    let om = m.om
    let rcv = c.receiver, src = m.argument(2, of: c), startO = c.arg0, stopO = c.arg1, fromO = m.argument(3, of: c)
    guard rcv.isObject, src.isObject, startO.isSmallInteger, stopO.isSmallInteger, fromO.isSmallInteger else { return .none }
    let rc = m.classIndex(of: rcv), sc = m.classIndex(of: src)
    guard !om.isSealed(rc), !om.isSealed(sc), !om.isBytes(rcv), !om.isBytes(src) else { return .none }
    let start = startO.smallIntegerValue, stop = stopO.smallIntegerValue, from = fromO.smallIntegerValue
    let n = stop - start + 1
    if n == 0 && start >= 1 && start <= Int64(om.count(of: rcv)) + 1 { return rcv }
    guard n > 0, start >= 1, stop <= Int64(om.count(of: rcv)), from >= 1, from + n - 1 <= Int64(om.count(of: src)) else {
        return .none
    }
    let w = unsafe workerOf(m.state)
    guard let vm = unsafe w.pointee.vm else {
        // Module 2's standalone interpreter: nothing relocates.
        for k in 0..<Int(n) {
            m.store(rcv, Int(start - 1) + k, om.load(src, Int(from - 1) + k), .arrayCopy)
        }
        return rcv
    }
    let d = unsafe hazardAcquire(vm, w, 0, rcv)
    let s = unsafe hazardAcquire(vm, w, 1, src)
    unsafe copySlots(vm, w, om, rcv.raw, d, Int(start - 1), s, Int(from - 1), Int(n))
    unsafe hazardRelease(vm, w, 1)
    unsafe hazardRelease(vm, w, 0)
    return rcv
}

/// The copy loop under the hazard slots: `n` slots from the source body at
/// `s` (from slot `j`) into the receiver's body at `d` (from slot `i`).
@inline(never)
func copySlots(_ vm: VMPointer, _ w: WorkerPointer, _ om: ObjectMemory, _ o: UInt64, _ d: UInt64, _ i: Int,
               _ s: UInt64, _ j: Int, _ n: Int) {
    let st = unsafe w.pointer(to: \Worker.interp)!
    let flags = unsafe barrierWord(vm.pointee.flag).pointee.load(ordering: .relaxed)
    let mk = unsafe vm.pointee.marking
    let young = unsafe flags > 1 ? vm.pointee.young : nil
    let ordered = unsafe young?.pointee.config.testSwitches.arrayCopyOrdering ?? true
    let ho = om.headerWord(o)
    var k = 0
    while k < n {
        let v = om.loadAtomic(bodyOffset: s, j &+ k)
        if flags & 1 != 0, let mk = unsafe mk {
            // The SATB record of the overwritten value (as `satbRecord`,
            // through the body this primitive holds).
            let b = unsafe mk.buffer(w.pointee.index)
            unsafe b.pointee.slowCalls &+= 1
            if unsafe mk.phaseNow == .marking && !mk.pointee.config.testSwitches.satbOff
                && (mk.pointee.config.testSwitches.literal || ho & Header.youngBit == 0) {
                unsafe satbPushIfCandidate(mk, om, w, om.loadAtomic(bodyOffset: d, i &+ k))
            }
        }
        // Module 7: the young deletion record of the overwritten value.
        if let y = unsafe young, unsafe y.pointee.config.testSwitches.youngDeletionBarrier {
            unsafe youngDeletionRecord(vm, y, w, om.loadAtomic(bodyOffset: d, i &+ k))
        }
        if _slowPath(!ordered) {
            // Test switch `arrayCopyOrdering` off: a relaxed store, and the
            // barrier's seq_cst load of the remembered word overtakes it
            // (C++ and ARMv8 allow `str` then `ldar` to reorder): the load
            // runs first, the hook stands for the store buffer, then the
            // store (docs/models/young-collection.md, finding 1).
            unsafe copyStoreUnordered(vm, st, om, o, ho, d, i &+ k, v)
        } else {
            om.storeSlot(atState: d, i &+ k, v)
            if v & Oop.objectTagMask == 0 {
                let hv = om.headerWord(v)
                if hv & Header.youngBit != 0 && (ho ^ hv) & Header.youngNurseryMask != 0 {
                    unsafe rememberSlow(st, Oop(raw: o), hv, BarrierSite.arrayCopy.rawValue)
                }
            }
            // The same test window after the store and the load.
            if let y = unsafe young, let h = unsafe y.pointee.copyWindow.pointee.hook {
                unsafe h(y.pointee.copyWindow.pointee.context, w.pointee.index)
            }
        }
        k &+= 1
    }
}

/// The broken variant of the array copy's store (test switch): the
/// insertion barrier's load first, the copy window hook, then a relaxed
/// store.
@inline(never)
private func copyStoreUnordered(_ vm: VMPointer, _ st: StatePointer, _ om: ObjectMemory, _ o: UInt64, _ ho: UInt64,
                                _ d: UInt64, _ i: Int, _ v: UInt64) {
    if v & Oop.objectTagMask == 0 {
        let hv = om.headerWord(v)
        if hv & Header.youngBit != 0 && (ho ^ hv) & Header.youngNurseryMask != 0 {
            unsafe rememberSlow(st, Oop(raw: o), hv, BarrierSite.arrayCopy.rawValue)
        }
    }
    if let y = unsafe vm.pointee.young {
        let hook = unsafe y.pointee.copyWindow.pointee
        if let h = unsafe hook.hook { unsafe h(hook.context, workerOf(st).pointee.index) }
    }
    om.setWordAtomic(atOffset: d &+ 8 &+ UInt64(i) &<< 3, v)
}
