import Synchronization

// The final-mark verifier (docs/modules/concurrent-marking.md
// "Verifiers"): a from-scratch traversal of everything reachable, young
// and old, from the stop's roots, compared with the mark set. A reachable
// unmarked snapshot entry is a bug (missed: counted; trap in checked
// builds, the cycle abandoned and a full collection otherwise); a marked
// unreachable one is floating garbage (counted in bytes); a marked entry
// that is not a snapshot entry means the marker read what it must never
// read. Runs in every test and at every final mark of a checked build.

struct MarkVerdict {
    var missed: UInt64 = 0
    var floatingObjects: UInt64 = 0
    var floatingBytes: UInt64 = 0
    var failed = false
}

func verifyFinalMark(_ vm: VMPointer, _ mk: MarkingPointer, _ stop: StopContext) -> MarkVerdict {
    let om = unsafe mk.pointee.om
    let snap = unsafe mk.pointee.snapshot
    let hw = om.highWater
    var out = Issues()
    var reached = RawArray<UInt8>(repeating: 0, count: Int(hw))
    var stack = RawArray<UInt64>()
    defer { reached.free(); stack.free() }
    func visit(_ v: Oop, _ from: @autoclosure () -> String) {
        if !v.isObject { return }
        if !om.isValidReferenceOrInteger(v, highWater: hw) {
            out.fail("\(from()) holds \(v), not a used entry")
            return
        }
        if reached[Int(v.entryIndex)] != 0 { return }
        reached[Int(v.entryIndex)] = 1
        stack.append(v.raw)
    }
    for r in stop.roots() { visit(r, "a root") }
    om.forEachRoot(extraRoots: []) { visit($0, "a root") }
    // Weak slots are not edges; an unfired ephemeron's slots are edges once
    // its key is reached (ADR 0009 section 1, as module 1's verifier).
    var pending: [Oop] = []
    while true {
        while let raw = stack.popLast() {
            let o = Oop(raw: raw)
            let h = om.header(o)
            if h.isBytes { continue }
            let f = om.classFormat(h.classIndex)
            var n = Int(h.count)
            if f.isWeak { n = Swift.min(n, f.namedSlots) }
            if f.isEphemeron && !h.isFiredEphemeron && n > 0 {
                let key = om.load(o, 0)
                if key.isObject && om.isValidReferenceOrInteger(key, highWater: hw) && reached[Int(key.entryIndex)] == 0 {
                    pending.append(o)
                    continue
                }
            }
            for i in 0..<n { visit(om.load(o, i), "entry \(o.entryIndex) slot \(i)") }
        }
        let ready = pending.filter { reached[Int(om.load($0, 0).entryIndex)] != 0 }
        if ready.isEmpty { break }
        pending.removeAll { reached[Int(om.load($0, 0).entryIndex)] != 0 }
        for o in ready { for i in 0..<Int(om.header(o).count) { visit(om.load(o, i), "entry \(o.entryIndex) slot \(i)") } }
    }
    var v = MarkVerdict()
    var e: UInt64 = 1
    while e < hw {
        defer { e &+= 1 }
        let marked = om.markRelaxed(e) != 0
        if !snap.contains(e) {
            if marked { out.fail("entry \(e) is marked but not a snapshot entry") }
            continue
        }
        let r = reached[Int(e)] != 0
        if r && !marked {
            v.missed &+= 1
            out.fail("entry \(e) is reachable but not marked (missed)")
        } else if marked && !r {
            v.floatingObjects &+= 1
            v.floatingBytes &+= om.bodyWords(entry: e &<< 4) &<< 3
        }
    }
    v.failed = !out.list.isEmpty
    om.record("marking verifier, final mark of cycle \(unsafe mk.cycleNow)", out.list)
    return v
}
