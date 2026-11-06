import Darwin
import Synchronization

// The snapshot-at-the-beginning barrier (docs/modules/concurrent-marking.md
// "Barrier"). The fast path is in module 4's `storeWithBarrier`: one
// relaxed load of the VM-wide barrier word before the store; nonzero sends
// the whole store to `storeWithBarriers`, one out-of-line call with nothing
// of the instruction live across it (AGENTS.md: one extra call site cost
// 20 percent through register pressure).

/// The store with every barrier the flag word asks for: the SATB record of
/// the old value while marking (bit 0), module 7's young deletion record
/// while a young collection runs (bits 1..), the store with the post-store
/// check, then module 4's insertion barrier. Scalars only; the VM is
/// reached through the worker.
@inline(never)
func storeWithBarriers(_ s: StatePointer, _ o: UInt64, _ i: Int, _ v: UInt64, _ site: UInt8) {
    let om = unsafe s.pointee.om
    let w = unsafe workerOf(s)
    if let vm = unsafe w.pointee.vm {
        if let mk = unsafe vm.pointee.marking { unsafe satbRecord(mk, om, w, o, i) }
        // Module 7: the young deletion barrier while a collection runs.
        unsafe youngDeletionBarrier(vm, w, o, i)
    }
    // Module 6: the post-store check (this call is already out of line).
    if _slowPath(!om.storeChecked(Oop(raw: o), i, Oop(raw: v))) { unsafe postStoreSlow(s, o, i, v) }
    if v & Oop.objectTagMask == 0 {
        let hv = om.headerWord(v)
        if hv & Header.youngBit != 0 && (om.headerWord(o) ^ hv) & Header.youngNurseryMask != 0 {
            unsafe rememberSlow(s, Oop(raw: o), hv, site)
        }
    }
}

/// Record the value slot `i` of `o` holds before it is overwritten: return
/// if no cycle is marking, if the holder is young (created after the
/// snapshot: overwriting its slots deletes no snapshot edge), if the old
/// value is not a reference, not a snapshot entry, or already marked; else
/// push it on this worker's buffer.
@inline(__always)
func satbRecord(_ mk: MarkingPointer, _ om: ObjectMemory, _ w: WorkerPointer, _ o: UInt64, _ i: Int) {
    let b = unsafe mk.buffer(w.pointee.index)
    unsafe b.pointee.slowCalls &+= 1
    if unsafe mk.phaseNow != .marking { return }
    let sw = unsafe mk.pointee.config.testSwitches
    if sw.satbOff { return }
    if !sw.literal && om.headerWord(o) & Header.youngBit != 0 { return }
    let old = om.loadAtomic(bodyOffset: om.stateWord(o), i)
    unsafe satbPushIfCandidate(mk, om, w, old)
}

/// Push `v` on worker `w`'s SATB buffer if it is an unmarked snapshot entry.
@inline(__always)
func satbPushIfCandidate(_ mk: MarkingPointer, _ om: ObjectMemory, _ w: WorkerPointer, _ v: UInt64) {
    if v & Oop.objectTagMask != 0 || v == 0 { return }
    let e = v &>> 4
    if unsafe !mk.pointee.snapshot.contains(e) { return }
    if om.markRelaxed(e) != 0 { return }
    let b = unsafe mk.buffer(w.pointee.index)
    if unsafe b.pointee.count == SATBBuffer.capacity { unsafe handOver(mk, w, b) }
    unsafe b.pointee.words[b.pointee.count] = v
    unsafe b.pointee.count &+= 1
    unsafe b.pointee.pushed &+= 1
}

/// A full buffer goes to the marker's queue under the marking lock (a leaf
/// lock: it may be taken under the scheduler lock); the worker takes an
/// empty one from the free list.
@inline(never)
func handOver(_ mk: MarkingPointer, _ w: WorkerPointer, _ b: UnsafeMutablePointer<SATBBuffer>) {
    if let vm = unsafe w.pointee.vm { unsafe perturb(vm, w) }
    unsafe pthread_mutex_lock(mk.pointee.lock)
    let q = unsafe mk.pointee.queue
    unsafe q.pointee.items.append(MarkItem(words: b.pointee.words, count: b.pointee.count, grey: false))
    unsafe b.pointee.words = takeBufferLocked(q)
    unsafe b.pointee.count = 0
    unsafe b.pointee.handed &+= 1
    if unsafe q.pointee.waiting > 0 { unsafe pthread_cond_signal(mk.pointee.cond) }
    unsafe pthread_mutex_unlock(mk.pointee.lock)
}

/// An empty 512-oop buffer. The marking lock is held.
func takeBufferLocked(_ q: UnsafeMutablePointer<MarkQueue>) -> UnsafeMutablePointer<UInt64> {
    if let p = unsafe q.pointee.free.popLast() { return unsafe p }
    let p = unsafe UnsafeMutablePointer<UInt64>.allocate(capacity: SATBBuffer.capacity)
    unsafe q.pointee.allocated.append(p)
    return unsafe p
}

// MARK: - the keep-alive read barrier on weak slots

/// `at:` read `v` from slot `i` of `o` while the flag word was set. If `o`
/// is weak, `i` one of its weak slots and a cycle is marking, the referent
/// is recorded like an overwritten value: the marker never traces weak
/// slots, so a referent read through one and stored elsewhere would
/// otherwise be swept under a live reference.
@inline(never)
func weakReadBarrier(_ s: StatePointer, _ o: Oop, _ i: Int, _ v: Oop) {
    let w = unsafe workerOf(s)
    guard let vm = unsafe w.pointee.vm, let mk = unsafe vm.pointee.marking, v.isObject else { return }
    if unsafe mk.phaseNow != .marking || mk.pointee.config.testSwitches.noWeakKeepAlive { return }
    let om = unsafe s.pointee.om
    let f = om.classFormat(om.header(o).classIndex)
    if !f.isWeak || i < f.namedSlots { return }
    unsafe mk.buffer(w.pointee.index).pointee.keepAlive &+= 1
    unsafe satbPushIfCandidate(mk, om, w, v.raw)
}
