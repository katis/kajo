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
    om.store(o, i, v)
    if v.raw & 1 == 0 {
        let hv = om.headerWord(v.raw)
        if hv & Header.youngBit != 0 {
            if (om.headerWord(o.raw) ^ hv) & Header.youngNurseryMask != 0 {
                unsafe rememberSlow(s, o, hv, site.rawValue)
            }
        }
    }
}

/// The barrier's slow path: `o` names a young object of the nursery in
/// `hv` and is not young in that nursery. An old holder is remembered for
/// that nursery (its marker bit set; pushed on this worker's buffer when
/// the marker was clear); a young holder never is: a stop-the-world
/// scavenge traces it if it is reachable (module 7 keeps per-nursery sets
/// for it). Relaxed atomics: the scavenge reads the markers and buffers
/// after the stop's handshake (module 7's handshake will need seq_cst).
@inline(never)
func rememberSlow(_ s: StatePointer, _ o: Oop, _ hv: UInt64, _ site: UInt8) {
    guard let a = unsafe s.pointee.young, let n = unsafe workerOf(s).pointee.vm?.pointee.nursery else { return }
    if unsafe site == a.pointee.skipSite { return }
    unsafe a.pointee.barrierSlowCalls &+= 1
    let om = unsafe s.pointee.om
    if om.headerWord(o.raw) & Header.youngBit != 0 {
        unsafe a.pointee.barrierYoungHolders &+= 1
        return
    }
    let bit = UInt16(truncatingIfNeeded: 1 &<< ((hv & Header.nurseryMask) &>> Header.nurseryShift))
    let r = unsafe n.remMarker(o.raw)
    if unsafe r.pointee.load(ordering: .relaxed) & bit != 0 { return }
    if unsafe r.pointee.bitwiseOr(bit, ordering: .relaxed).oldValue == 0 {
        unsafe a.pointee.rem.append(o.raw)
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
    unsafe w.pointee.interp.om.store(o, i, v)
}
