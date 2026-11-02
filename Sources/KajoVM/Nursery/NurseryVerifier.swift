import Synchronization

// The nursery's verifiers (docs/modules/nursery.md "Verifiers"): each
// redoes a piece of the scavenge's reasoning from scratch. On in checked
// builds at every scavenge, one flag away in release (`config.verify`),
// reported through module 1's `record` (trap or count).

/// What the verifier before a scavenge expects of it.
struct ScavengeExpectation {
    /// Young objects reachable from the roots, the remembered holders and
    /// every old object (old objects are live to a scavenge).
    var reachable = 0
    /// Per entry: 1 if a reachable young object.
    var reached = RawArray<UInt8>()
    /// Weak slots naming a young object: holder, slot, referent.
    var weakSlots: [(holder: UInt64, slot: Int, referent: UInt64)] = []
}

private func young(_ om: ObjectMemory, _ v: UInt64) -> Bool {
    Oop(raw: v).isObject && om.headerWord(v) & Header.youngBit != 0
}

/// The strong slot count of an object: all of them but a weak object's
/// indexed part.
private func strongSlots(_ om: ObjectMemory, _ h: Header) -> Int {
    if h.isBytes { return 0 }
    let f = om.classFormat(h.classIndex)
    return f.isWeak ? Swift.min(Int(h.count), f.namedSlots) : Int(h.count)
}

/// Remembered set: every old holder of a young object is remembered for
/// its nursery and is in exactly one buffer; every buffered holder is
/// old, used and marked.
private func checkRemembered(_ n: NurseryPointer, _ out: inout Issues) {
    let om = unsafe n.pointee.om
    let hw = om.highWater
    var inBuffer = RawArray<UInt8>(repeating: 0, count: Int(hw))
    defer { inBuffer.free() }
    for k in 0..<(unsafe n.pointee.count) {
        let rem = unsafe n.alloc(k).pointee.rem
        for i in 0..<rem.count {
            let o = Oop(raw: rem[i])
            guard o.isObject && o.entryIndex < hw && om.isUsedReference(o) else {
                out.fail("remembered buffer \(k) holds \(o), not a used entry")
                continue
            }
            if inBuffer[Int(o.entryIndex)] != 0 { out.fail("entry \(o.entryIndex) is twice in the remembered buffers") }
            inBuffer[Int(o.entryIndex)] = 1
            if om.header(o).isYoung { out.fail("young entry \(o.entryIndex) is in remembered buffer \(k)") }
            if unsafe n.remMarker(o.raw).pointee.load(ordering: .relaxed) == 0 {
                out.fail("entry \(o.entryIndex) is in remembered buffer \(k) with a clear marker")
            }
        }
    }
    var e: UInt64 = 1
    while e < hw {
        defer { e &+= 1 }
        let raw = e &<< 4
        let marker = unsafe n.remMarker(raw).pointee.load(ordering: .relaxed)
        if marker != 0 && inBuffer[Int(e)] == 0 { out.fail("entry \(e) is marked remembered but in no buffer") }
        // Module 5: a pending-dead entry (a lazy sweep will free it) left
        // the remembered set at the final mark and may name anything.
        if EntryState.isFree(om.stateWord(raw)) || om.isPendingDead(e) { continue }
        let h = Header(raw: om.headerWord(raw))
        if h.isYoung || h.isBytes { continue }
        for i in 0..<Int(h.count) {
            let v = om.load(Oop(raw: raw), i)
            if young(om, v.raw) {
                let bit = UInt16(truncatingIfNeeded: 1 &<< om.header(v).nurseryIndex)
                if marker & bit == 0 {
                    out.fail("entry \(e) is old, names young \(v) (nursery \(om.header(v).nurseryIndex)) in slot \(i), and is not remembered for it")
                }
            }
        }
    }
}

/// Before copying: the remembered set, where young bodies are, and what
/// the scavenge must copy.
func verifyBeforeScavenge(_ n: NurseryPointer, roots: RawArray<UInt64>) -> ScavengeExpectation {
    let om = unsafe n.pointee.om
    let hw = om.highWater
    var out = Issues()
    unsafe checkRemembered(n, &out)
    unsafe checkYoungBodies(n, &out, after: false)
    var x = ScavengeExpectation()
    x.reached = RawArray(repeating: 0, count: Int(hw))
    var stack: [UInt64] = []
    func visit(_ v: UInt64) {
        guard young(om, v) else { return }
        let i = Int(v &>> 4)
        if x.reached[i] != 0 { return }
        x.reached[i] = 1
        x.reachable += 1
        stack.append(v)
    }
    for i in 0..<roots.count { visit(roots[i]) }
    var e: UInt64 = 1
    while e < hw {
        defer { e &+= 1 }
        let raw = e &<< 4
        if EntryState.isFree(om.stateWord(raw)) || om.isPendingDead(e) { continue }
        let h = Header(raw: om.headerWord(raw))
        if h.isYoung { continue }
        let strong = strongSlots(om, h)
        for i in 0..<strong { visit(om.load(Oop(raw: raw), i).raw) }
        if !h.isBytes {
            for i in strong..<Int(h.count) where young(om, om.load(Oop(raw: raw), i).raw) {
                x.weakSlots.append((raw, i, om.load(Oop(raw: raw), i).raw))
            }
        }
    }
    while let o = stack.popLast() {
        let h = om.header(Oop(raw: o))
        let strong = strongSlots(om, h)
        for i in 0..<strong { visit(om.load(Oop(raw: o), i).raw) }
        if !h.isBytes {
            for i in strong..<Int(h.count) where young(om, om.load(Oop(raw: o), i).raw) {
                x.weakSlots.append((o, i, om.load(Oop(raw: o), i).raw))
            }
        }
    }
    // Weak slots of young objects that die are never looked at again.
    let reached = x.reached
    x.weakSlots.removeAll { young(om, $0.holder) && reached[Int($0.holder &>> 4)] == 0 }
    om.record("nursery verifier, before scavenge \(unsafe n.pointee.phase.pointee.number)", out.list)
    return x
}

/// Every young body lies in its header's nursery: before a scavenge in eden
/// or survivor-from, after one in survivor-from with the scavenge's tag
/// and an age below N; and every young entry is in its nursery's survivor
/// log after a scavenge (the next entry sweep's input).
private func checkYoungBodies(_ n: NurseryPointer, _ out: inout Issues, after: Bool) {
    let om = unsafe n.pointee.om
    let hw = om.highWater
    let ageLimit = UInt64(unsafe n.pointee.config.age)
    let tag = unsafe n.pointee.phase.pointee.tag
    var logged = RawArray<UInt8>(repeating: 0, count: Int(hw))
    defer { logged.free() }
    if after {
        for k in 0..<(unsafe n.pointee.count) {
            let log = unsafe n.alloc(k).pointee.survLog
            for i in 0..<log.count {
                let e = Int(log[i])
                if e == 0 || e >= Int(hw) { out.fail("survivor log \(k) holds entry \(e)"); continue }
                if logged[e] != 0 { out.fail("entry \(e) is twice in the survivor logs") }
                logged[e] = UInt8(k &+ 1)
            }
        }
    }
    var e: UInt64 = 1
    while e < hw {
        defer { e &+= 1 }
        let raw = e &<< 4
        let s = om.stateWord(raw)
        if EntryState.isFree(s) { continue }
        let h = Header(raw: om.headerWord(raw))
        if !h.isYoung {
            if s &+ h.bodyBytes > UInt64(om.heap.bytes) { out.fail("old entry \(e) has its body at \(s), outside old space") }
            continue
        }
        let k = h.nurseryIndex
        guard unsafe k < n.pointee.count else { out.fail("young entry \(e) names nursery \(k), which does not exist"); continue }
        let a = unsafe n.alloc(k).pointee
        let end = s &+ h.bodyBytes
        let inEden = unsafe s >= a.edenStart && end <= a.top
        let inFrom = unsafe s >= a.survFromStart && end <= a.survFromTop
        if after {
            if !inFrom { out.fail("young entry \(e) is not in nursery \(k)'s survivor-from after a scavenge (body at \(s))") }
            if h.age == 0 || h.age >= ageLimit { out.fail("young entry \(e) has age \(h.age) after a scavenge (N = \(ageLimit))") }
            if h.raw & tag == 0 { out.fail("young entry \(e) lacks this scavenge's claim tag") }
            if logged[Int(e)] != UInt8(k &+ 1) { out.fail("young entry \(e) is not in nursery \(k)'s survivor log") }
        } else if !inEden && !inFrom {
            out.fail("young entry \(e) is in neither eden nor survivor-from of nursery \(k) (body at \(s))")
        }
    }
    if after {
        for k in 0..<(unsafe n.pointee.count) {
            let a = unsafe n.alloc(k).pointee
            if unsafe a.top != a.edenStart { out.fail("nursery \(k)'s eden is not empty after a scavenge") }
        }
    }
}

/// After the scavenge: it copied exactly the reachable young objects
/// (each claimed once), nothing names a freed entry, young bodies are in
/// survivor-from, the remembered set is complete, weak slots are nil
/// exactly when their referent died, and the entry stashes have one owner
/// per entry.
func verifyAfterScavenge(_ n: NurseryPointer, roots: RawArray<UInt64>, expected x: ScavengeExpectation, copied: UInt64) {
    var x = x
    defer { x.reached.free() }
    let om = unsafe n.pointee.om
    let hw = om.highWater
    var out = Issues()
    if copied != UInt64(x.reachable) {
        out.fail("the scavenge copied \(copied) objects, \(x.reachable) young objects were reachable")
    }
    for i in 0..<roots.count where !om.isValidReferenceOrInteger(Oop(raw: roots[i]), highWater: hw) {
        out.fail("root \(Oop(raw: roots[i])) names a freed entry")
    }
    var e: UInt64 = 1
    while e < hw {
        defer { e &+= 1 }
        let raw = e &<< 4
        if EntryState.isFree(om.stateWord(raw)) {
            if x.reached[Int(e)] != 0 { out.fail("reachable young entry \(e) was freed") }
            continue
        }
        let h = Header(raw: om.headerWord(raw))
        if h.isBytes || om.isPendingDead(e) { continue }
        for i in 0..<Int(h.count) {
            let v = om.load(Oop(raw: raw), i)
            if !om.isValidReferenceOrInteger(v, highWater: hw) { out.fail("entry \(e) slot \(i) names \(v), a freed entry") }
        }
    }
    let nilObj = om.nilObject
    for (holder, slot, referent) in x.weakSlots {
        let now = om.load(Oop(raw: holder), slot)
        let lived = x.reached[Int(referent &>> 4)] != 0
        if lived && now.raw != referent { out.fail("weak slot \(slot) of \(Oop(raw: holder)) lost its live referent") }
        if !lived && now != nilObj { out.fail("weak slot \(slot) of \(Oop(raw: holder)) still names dead \(Oop(raw: referent))") }
    }
    unsafe checkYoungBodies(n, &out, after: true)
    unsafe checkRemembered(n, &out)
    om.record("nursery verifier, after scavenge \(unsafe n.pointee.phase.pointee.number)",
              out.list + om.verifyFreeLists())
}

/// The after-scavenge checks on their own (world stopped, right after a
/// scavenge, before anything allocates): tests of the verifier.
func verifyNurseryAfterScavenge(_ n: NurseryPointer) -> [String] {
    var out = Issues()
    unsafe checkYoungBodies(n, &out, after: true)
    unsafe checkRemembered(n, &out)
    return out.list
}
