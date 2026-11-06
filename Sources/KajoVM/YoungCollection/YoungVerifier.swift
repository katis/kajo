import Darwin
import Synchronization

// The young verifier (docs/modules/young-collection.md "Verifiers";
// concurrent-young SPEC "Young verifier"), at a stop after a collection:
// a from-scratch walk from every root through every reachable object. Its
// entry is used and not a deferred free; nothing is RELOCATING; a young
// object's body lies in its nursery's eden (or current eden half) or
// survivor-from; an old object's body lies in old space. Then module 4's
// remembered-set check. Reported through module 1's `record`.

func verifyYoungInStop(_ vm: VMPointer, _ y: YoungPointer, _ stop: StopContext) {
    unsafe markStop(vm, .verify)
    let n = unsafe y.pointee.nursery
    let om = unsafe vm.pointee.om
    let hw = om.highWater
    var out = Issues()
    var seen = RawArray<UInt8>(repeating: 0, count: Int(hw))
    defer { seen.free() }
    var stack = RawArray<UInt64>()
    defer { stack.free() }
    func visit(_ v: UInt64) {
        if v & Oop.objectTagMask != 0 || v == 0 { return }
        let e = Int(truncatingIfNeeded: v &>> 4)
        if UInt64(e) >= hw { out.fail("young verifier: oop \(Oop(raw: v)) beyond the table"); return }
        if seen[e] != 0 { return }
        seen[e] = 1
        stack.append(v)
    }
    for r in stop.roots() { visit(r.raw) }
    om.forEachRoot(extraRoots: []) { visit($0.raw) }
    while let o = stack.popLast() {
        let e = o &>> 4
        let s = om.stateWord(o)
        if EntryState.isFree(s) { out.fail("young verifier: reachable entry \(e) is free"); continue }
        let h = Header(raw: om.headerWord(o))
        if h.isDeferredFree { out.fail("young verifier: reachable entry \(e) is a deferred free"); continue }
        if s & EntryState.relocatingBit != 0 { out.fail("young verifier: entry \(e) is RELOCATING at a pause"); continue }
        if h.isYoung {
            let k = h.nurseryIndex
            guard unsafe k < n.pointee.count else { out.fail("young verifier: young entry \(e) names nursery \(k)"); continue }
            let a = unsafe n.alloc(k).pointee
            let v = unsafe n.survivors(k).pointee
            let end = s &+ h.bodyBytes
            let inEden = unsafe s >= a.edenStart && end <= a.top
            let inFrom = unsafe s >= v.survFromStart && end <= v.survFromTop
            if !inEden && !inFrom {
                out.fail("young verifier: young entry \(e) of nursery \(k) has its body at \(s), outside its eden and survivor-from")
            }
        } else if om.nurseryRegion.contains(s) {
            out.fail("young verifier: old entry \(e) has its body in the nursery region")
        }
        if h.isBytes { continue }
        for i in 0..<Int(h.count) { visit(om.loadAtomic(bodyOffset: s, i)) }
    }
    let rem = unsafe verifyRememberedAtPause(n)
    unsafe pthread_mutex_lock(vm.pointee.safepointLock)
    unsafe y.pointee.log.pointee.verifierRuns &+= 1
    unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
    om.record("young verifier", out.list + rem.map { "young verifier: \($0)" })
}
