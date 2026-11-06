import Darwin
import Synchronization

// The mutator's side of concurrent relocation (docs/modules/relocation.md
// "Post-store check"; docs/models/relocation.md, steps `M store`). The
// fast path is `ObjectMemory.storeChecked`, inline at every store site:
// relaxed load of the state word, seq_cst store of the slot through it,
// seq_cst reload. When the reload differs or the first load had the
// RELOCATING bit, the site makes one out-of-line call that redoes the
// store into the body the entry leads to once the copy is over, and runs
// whatever barrier the site needs, so nothing of the instruction is live
// across a call (AGENTS.md: 58 percent before, 1 percent after).

/// What one worker's post-store checks and hazard slots did. Written only
/// by the worker's own thread; read by the host with the world stopped.
struct RelocationMutatorCounters: Sendable {
    /// Failed checks: each redid its store at least once.
    var storesRedone: UInt64 = 0
    /// Waits for a RELOCATING entry to be switched or reverted, and their
    /// time (from the first spin to the end of the wait).
    var spinEpisodes: UInt64 = 0
    var spinNs: UInt64 = 0
    var spinMaxNs: UInt64 = 0
    /// Hazard slots published, and those that had to wait for a copy.
    var hazardsTaken: UInt64 = 0
    var hazardWaits: UInt64 = 0
}

/// The post-store check failed for slot `i` of `o`: wait while the entry
/// is RELOCATING (acquire loads; a yield every 64 spins), store `v` into
/// the body the entry now leads to (seq_cst), reload (seq_cst), and repeat
/// until the state word is stable. The body address is computed from the
/// value just loaded. Never polls, never parks: the relocator never parks
/// between its CAS and its switch or revert, so the wait is bounded by one
/// object's copy.
@inline(never)
func postStoreSlow(_ s: StatePointer, _ o: UInt64, _ i: Int, _ v: UInt64) {
    let om = unsafe s.pointee.om
    let sw = unsafe om.stateWordAtomic(o)
    let c = unsafe workerOf(s).pointer(to: \Worker.relocation)!
    unsafe c.pointee.storesRedone &+= 1
    var spins = 0
    var t0: UInt64 = 0
    while true {
        var e = unsafe sw.pointee.load(ordering: .acquiring)
        while e & EntryState.relocatingBit != 0 {
            if spins == 0 { t0 = nanoseconds() }
            spins &+= 1
            if spins & 63 == 0 { sched_yield() }
            e = unsafe sw.pointee.load(ordering: .acquiring)
        }
        om.storeSlot(atState: e, i, v)
        if unsafe sw.pointee.load(ordering: .sequentiallyConsistent) == e { break }
    }
    if spins > 0 { unsafe noteSpin(c, nanoseconds() &- t0) }
}

/// The same for a byte store.
@inline(never)
func postStoreSlowByte(_ s: StatePointer, _ o: UInt64, _ i: Int, _ v: UInt8) {
    let om = unsafe s.pointee.om
    let sw = unsafe om.stateWordAtomic(o)
    let c = unsafe workerOf(s).pointer(to: \Worker.relocation)!
    unsafe c.pointee.storesRedone &+= 1
    var spins = 0
    var t0: UInt64 = 0
    while true {
        var e = unsafe sw.pointee.load(ordering: .acquiring)
        while e & EntryState.relocatingBit != 0 {
            if spins == 0 { t0 = nanoseconds() }
            spins &+= 1
            if spins & 63 == 0 { sched_yield() }
            e = unsafe sw.pointee.load(ordering: .acquiring)
        }
        om.storeByte(atState: e, i, v)
        if unsafe sw.pointee.load(ordering: .sequentiallyConsistent) == e { break }
    }
    if spins > 0 { unsafe noteSpin(c, nanoseconds() &- t0) }
}

@inline(__always)
func noteSpin(_ c: UnsafeMutablePointer<RelocationMutatorCounters>, _ dt: UInt64) {
    unsafe c.pointee.spinEpisodes &+= 1
    unsafe c.pointee.spinNs &+= dt
    if unsafe dt > c.pointee.spinMaxNs { unsafe c.pointee.spinMaxNs = dt }
}

/// A failed check at a barrier site (flag word clear): redo the store,
/// then module 4's insertion barrier. One call, scalars only.
@inline(never)
func storeConflict(_ s: StatePointer, _ o: UInt64, _ i: Int, _ v: UInt64, _ site: UInt8) {
    unsafe postStoreSlow(s, o, i, v)
    if v & Oop.objectTagMask == 0 {
        let om = unsafe s.pointee.om
        let hv = om.headerWord(v)
        if hv & Header.youngBit != 0 && (om.headerWord(o) ^ hv) & Header.youngNurseryMask != 0 {
            unsafe rememberSlow(s, Oop(raw: o), hv, site)
        }
    }
}

/// A checked store with no barrier (SmallIntegers over SmallInteger
/// slots: Process registers, Semaphore counts).
@inline(__always)
func checkedStore(_ s: StatePointer, _ o: Oop, _ i: Int, _ v: Oop) {
    let om = unsafe s.pointee.om
    if _slowPath(!om.storeChecked(o, i, v)) { unsafe postStoreSlow(s, o.raw, i, v.raw) }
}

/// A checked byte store (`at:put:` on a byte object).
@inline(__always)
func checkedStoreByte(_ s: StatePointer, _ o: Oop, _ i: Int, _ v: UInt8) {
    let om = unsafe s.pointee.om
    if _slowPath(!om.storeByteChecked(o, i, v)) { unsafe postStoreSlowByte(s, o.raw, i, v) }
}
