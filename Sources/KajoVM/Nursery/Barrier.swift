import Synchronization

// The write barrier (docs/modules/nursery.md "Barrier"), in
// experiments/concurrent-young's shape: first one relaxed load of the
// VM-wide barrier word (module 5, docs/modules/concurrent-marking.md);
// nonzero sends the whole store to one out-of-line `storeWithBarriers`
// (the SATB record, the store, this barrier). Zero: the store, then, if
// the value is a reference whose header is young and the holder's young
// and nursery bits differ from the value's, one out-of-line call. The
// common case (an old value) loads only the value's header: `tbnz` on the
// tag, `ldr` of the header, `tbz` on the young bit.

/// Store `v` into slot `i` of `o` and run the barriers. Every store of an
/// oop that may be young into a heap object goes through here (the sites
/// are `BarrierSite`).
@_transparent
func storeWithBarrier(_ s: StatePointer, _ om: ObjectMemory, _ o: Oop, _ i: Int, _ v: Oop, _ site: BarrierSite) {
    unsafe storeWithBarrier(s, s.pointee.safepointFlag, om, o, i, v, site)
}

/// The same with the flag line in hand (the interpreter keeps it in a
/// register for its polls).
@_transparent
func storeWithBarrier(_ s: StatePointer, _ flag: UnsafeMutablePointer<Atomic<UInt32>>, _ om: ObjectMemory, _ o: Oop,
                      _ i: Int, _ v: Oop, _ site: BarrierSite) {
    if unsafe barrierWord(flag).pointee.load(ordering: .relaxed) != 0 {
        unsafe storeWithBarriers(s, o.raw, i, v.raw, site.rawValue)
        return
    }
    // Module 6: the post-store check; a failed one is one call that redoes
    // the store and runs this barrier.
    if _slowPath(!om.storeChecked(o, i, v)) {
        unsafe storeConflict(s, o.raw, i, v.raw, site.rawValue)
        return
    }
    // SmallIntegers first (one tbnz), then the rest of the immediate
    // pattern (module 8): only a reference has a header to load.
    if v.raw & 1 == 0 && v.raw & Oop.objectTagMask == 0 {
        let hv = om.headerWord(v.raw)
        if hv & Header.youngBit != 0 {
            if (om.headerWord(o.raw) ^ hv) & Header.youngNurseryMask != 0 {
                unsafe rememberSlow(s, o, hv, site.rawValue)
            }
        }
    }
}

/// The barrier's slow path: `o` names a young object of the nursery in
/// `hv` and is not young in that nursery. The holder is remembered for
/// that nursery: its remembered bit set and, when this call set it, the
/// holder pushed on this worker's buffer for that nursery. A young holder
/// of another nursery is remembered too when young collection runs without
/// stopping the world (module 7: a local collection of the value's nursery
/// scans it); in the stop-the-world configuration only old holders are
/// (module 4: a scavenge traces every young holder that is reachable).
///
/// The load of the remembered word is seq_cst, and so is the store before
/// it at every site (the interpreter's checked store, the array copy):
/// a young collector clears a holder's bit with a seq_cst `fetch_and`
/// before it reads the holder's slots, so either it sees this store or
/// this load sees the cleared bit and remembers the holder again
/// (concurrent-young SPEC point 2; docs/models/young-collection.md
/// findings 1 and 4: do not lean on the post-store check's reload).
@inline(never)
func rememberSlow(_ s: StatePointer, _ o: Oop, _ hv: UInt64, _ site: UInt8) {
    guard let a = unsafe s.pointee.young, let n = unsafe workerOf(s).pointee.vm?.pointee.nursery else { return }
    if unsafe site == a.pointee.skipSite { return }
    unsafe a.pointee.barrierSlowCalls &+= 1
    let om = unsafe s.pointee.om
    if unsafe om.headerWord(o.raw) & Header.youngBit != 0 && !a.pointee.rememberYoungHolders {
        unsafe a.pointee.barrierYoungHolders &+= 1
        return
    }
    let k = Int(truncatingIfNeeded: (hv & Header.nurseryMask) &>> Header.nurseryShift)
    let bit = remBit(k)
    let r = unsafe n.remMarker(o.raw)
    if unsafe r.pointee.load(ordering: .sequentiallyConsistent) & bit != 0 { return }
    if unsafe r.pointee.bitwiseOr(bit, ordering: .sequentiallyConsistent).oldValue & bit == 0 {
        unsafe (a.pointee.buffers + k).pointee.append(o.raw)
    }
}

extension Machine {
    /// A VM store of an oop into a heap object, with the barrier.
    @inline(__always)
    func store(_ o: Oop, _ i: Int, _ v: Oop, _ site: BarrierSite) {
        unsafe storeWithBarrier(state, om, o, i, v, site)
    }
}

/// The same from a worker pointer (module 3's scheduler).
@inline(__always)
func barrierStore(_ w: WorkerPointer, _ o: Oop, _ i: Int, _ v: Oop, _ site: BarrierSite) {
    unsafe storeWithBarrier(w.pointer(to: \Worker.interp)!, w.pointee.interp.om, o, i, v, site)
}

/// A VM store of nil (or another old value) over a pointer slot: no
/// insertion barrier is needed, but the overwritten value is a deletion
/// the SATB barrier must see (module 5).
@inline(__always)
func clearingStore(_ w: WorkerPointer, _ o: Oop, _ i: Int, _ v: Oop) {
    let s = unsafe w.pointer(to: \Worker.interp)!
    if unsafe barrierWord(s.pointee.safepointFlag).pointee.load(ordering: .relaxed) != 0 {
        unsafe storeWithBarriers(s, o.raw, i, v.raw, 0)
        return
    }
    unsafe checkedStore(s, o, i, v)
}
