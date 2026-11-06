// The relocation verifier (docs/modules/relocation.md "Verifier"): at the
// end of every pause when the object memory verifies (every test, checked
// builds), after the pause freed the pending blocks and did its work.
//
// - No entry is RELOCATING (the relocator polls only between objects, and
//   it is counted stopped only after the safepoint mutex, a full fence,
//   followed its last switch or revert: docs/models/relocation.md,
//   finding 3).
// - Every used entry's body is in the nursery region or in an in-use old
//   block, inside the block's bodies (its used bytes, or an allocation
//   context's bump pointer), and its back reference names the entry.
//   Pending-dead entries (a lazy sweep will free them) are skipped: a dead
//   snapshot entry's body may lie in an evacuated block already freed.
// - The pool holds no block twice and no free block that has a body; the
//   pending list is empty (the pause freed it); no block of the relocation
//   set is in the pool.

func verifyRelocation(_ vm: VMPointer, _ r: RelocationPointer) -> [String] {
    var out = Issues()
    let om = unsafe r.pointee.om
    let st = unsafe r.pointee.state
    let h = om.heap
    let hw = om.highWater
    let ends = om.bodyEnds()
    let nursery = om.nurseryRegion
    var inPool = [UInt8](repeating: 0, count: h.blockCount)
    for b in om.poolBlocks {
        if inPool[b] != 0 { out.fail("block \(b) is twice in the pool") }
        if h.isRun(b) { out.fail("block \(b) of a run is in the pool") }
        inPool[b] = 1
    }
    if unsafe st.pointee.pendingBlocks.count != 0 {
        out.fail(unsafe "\(st.pointee.pendingBlocks.count) evacuated blocks still pending at the end of a pause")
    }
    for i in unsafe st.pointee.cursor..<st.pointee.selected.count {
        let b = unsafe Int(st.pointee.selected[i])
        if inPool[b] != 0 { out.fail("block \(b) of the relocation set is in the pool") }
        if h.isRun(b) { out.fail("block \(b) of the relocation set is part of a run") }
    }
    var e: UInt64 = 1
    while e < hw {
        defer { e &+= 1 }
        let raw = e &<< 4
        let s = om.stateWord(raw)
        if EntryState.isFree(s) { continue }
        if s & EntryState.relocatingBit != 0 {
            out.fail("entry \(e) is RELOCATING at a pause")
            continue
        }
        if om.isPendingDead(e) { continue }
        let hd = Header(raw: om.headerWord(raw))
        // Module 7: a deferred entry free's body may have been reused.
        if hd.isDeferredFree { continue }
        if nursery.contains(s) {
            if BackRef.entryIndex(h.word(atOffset: s)) != e { out.fail("entry \(e): its young body's back reference names another entry") }
            continue
        }
        if s >= UInt64(h.bytes) {
            out.fail("entry \(e): body at \(s) is outside the heap")
            continue
        }
        let b = BlockHeap.block(ofOffset: s)
        if !h.isInUse(b) {
            out.fail("entry \(e): body in block \(b), which is free")
            continue
        }
        if s &+ (om.bodyWords(entry: e &<< 4) &<< 3) > BlockHeap.start(ofBlock: b) &+ ends[b] {
            out.fail("entry \(e): body at \(s) runs past the bodies of block \(b)")
        }
        if BackRef.entryIndex(h.word(atOffset: s)) != e { out.fail("entry \(e): its body's back reference names another entry") }
    }
    for b in 0..<h.blockCount where inPool[b] != 0 && !h.isInUse(b) && h.usedBytes(b) != 0 {
        out.fail("free block \(b) in the pool has \(h.usedBytes(b)) used bytes")
    }
    return out.list
}
