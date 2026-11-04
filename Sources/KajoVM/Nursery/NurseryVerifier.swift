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

/// Remembered set, at a pause: every holder of a young object of nursery
/// n that is old (or, with young collection without stopping the world,
/// young in another nursery) has bit n and is in a list of nursery n (an
/// owner's buffer n or nursery n's carried list); every listed holder is
/// used and has the bit; no word has a bit without a list or a pending
/// bit. Stop-the-world configuration (module 4's rule): only old holders,
/// in exactly one list per nursery. Deferred entry frees (module 7) may be
/// named by stale lists and are skipped.
private func checkRemembered(_ n: NurseryPointer, _ out: inout Issues) {
    let om = unsafe n.pointee.om
    let hw = om.highWater
    let count = unsafe n.pointee.count
    let strict = unsafe !n.pointee.concurrent
    var inList = RawArray<UInt32>(repeating: 0, count: Int(hw))
    defer { inList.free() }
    func visit(_ list: RawArray<UInt64>, _ k: Int, _ name: String) {
        let bit = remBit(k)
        for i in 0..<list.count {
            let o = Oop(raw: list[i])
            guard o.isObject && o.entryIndex < hw else {
                out.fail("\(name) holds \(o), not an entry")
                continue
            }
            if strict && inList[Int(o.entryIndex)] & bit != 0 { out.fail("entry \(o.entryIndex) is twice in nursery \(k)'s lists") }
            inList[Int(o.entryIndex)] |= bit
            // Young collection without stopping the world: a list may name
            // a holder freed (or freed and reused) since it was listed: its
            // nursery's sweep found its remembered word cleared by another
            // collection's scan of it. Every scan of a list tests the bit
            // first (SPEC step 3), so such a name is skipped; what must hold
            // is that every holder of a young object has its bit, and that
            // every bit is listed.
            if !strict { continue }
            if !om.isUsedReference(o) {
                out.fail("\(name) holds \(o), not a used entry")
                continue
            }
            let h = om.header(o)
            if h.isYoung { out.fail("young entry \(o.entryIndex) is in \(name)") }
            if unsafe n.remMarker(o.raw).pointee.load(ordering: .relaxed) & bit == 0 {
                out.fail("entry \(o.entryIndex) is in \(name) with its bit clear")
            }
        }
    }
    for k in 0..<count {
        for i in unsafe 0..<n.pointee.bufferOwners {
            unsafe visit(n.remBuffer(i, k).pointee, k, "remembered buffer \(k) of owner \(i)")
        }
        unsafe visit(n.survivors(k).pointee.carried, k, "nursery \(k)'s carried list")
    }
    var e: UInt64 = 1
    while e < hw {
        defer { e &+= 1 }
        let raw = e &<< 4
        let word = unsafe n.remMarker(raw).pointee.load(ordering: .relaxed)
        if word & 0xFFFF_0000 != 0 { out.fail("entry \(e) has pending remembered bits 0x\(String(word, radix: 16)) at a pause") }
        if word & 0xFFFF & ~inList[Int(e)] != 0 {
            out.fail("entry \(e) is marked remembered (0x\(String(word, radix: 16))) but in no list of those nurseries")
        }
        // Module 5: a pending-dead entry (a lazy sweep will free it) left
        // the remembered set at the final mark and may name anything.
        if EntryState.isFree(om.stateWord(raw)) || om.isPendingDead(e) { continue }
        let h = Header(raw: om.headerWord(raw))
        if h.isBytes || h.isDeferredFree || (h.isYoung && strict) { continue }
        for i in 0..<Int(h.count) {
            let v = om.load(Oop(raw: raw), i)
            if young(om, v.raw) {
                let m = om.header(v).nurseryIndex
                if h.isYoung && h.nurseryIndex == m { continue }
                if word & remBit(m) == 0 {
                    out.fail("entry \(e) (\(h.isYoung ? "young in \(h.nurseryIndex)" : "old")) names young \(v) (nursery \(m)) in slot \(i), and is not remembered for it")
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
        if h.isYoung || h.isDeferredFree { continue }
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
    // Objects the scavenge kept in place (the reserve's fallback): young
    // in its eden or survivor-from, of any age.
    var kept = RawArray<UInt8>(repeating: 0, count: Int(hw))
    defer { kept.free() }
    if after {
        let kl = unsafe n.pointee.phase.pointee.kept
        for i in 0..<kl.count where kl[i] &>> 4 < hw { kept[Int(truncatingIfNeeded: kl[i] &>> 4)] = 1 }
        for k in 0..<(unsafe n.pointee.count) {
            let log = unsafe n.survivors(k).pointee.survLog
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
        if h.isDeferredFree { continue }
        if !h.isYoung {
            if s &+ h.bodyBytes > UInt64(om.heap.bytes) { out.fail("old entry \(e) has its body at \(s), outside old space") }
            continue
        }
        let k = h.nurseryIndex
        guard unsafe k < n.pointee.count else { out.fail("young entry \(e) names nursery \(k), which does not exist"); continue }
        let a = unsafe n.alloc(k).pointee
        let v = unsafe n.survivors(k).pointee
        let end = s &+ h.bodyBytes
        let inEden = unsafe s >= a.edenStart && end <= a.top
        let inFrom = unsafe s >= v.survFromStart && end <= v.survFromTop
        if after && kept[Int(e)] != 0 {
            if !inEden && !inFrom { out.fail("kept entry \(e) is in neither eden nor survivor-from of nursery \(k) (body at \(s))") }
            if h.raw & tag == 0 { out.fail("kept entry \(e) lacks this scavenge's claim tag") }
            if logged[Int(e)] != UInt8(k &+ 1) { out.fail("kept entry \(e) is not in nursery \(k)'s survivor log") }
        } else if after {
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
            // Only kept bodies, each its entry's, from the eden's start.
            var off = unsafe a.edenStart
            while unsafe off < a.top {
                let br = om.heap.word(atOffset: off)
                let e = BackRef.entryIndex(br)
                if e == 0 || e >= hw || kept[Int(e)] == 0 || om.stateWord(e &<< 4) != off {
                    out.fail("nursery \(k)'s eden holds more than its kept objects after a scavenge (at \(off))")
                    break
                }
                off &+= BackRef.words(br) &<< 3
            }
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
        if h.isBytes || h.isDeferredFree || om.isPendingDead(e) { continue }
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

/// The remembered-set check on its own, at a pause (module 7's young
/// verifier after a collection).
func verifyRememberedAtPause(_ n: NurseryPointer) -> [String] {
    var out = Issues()
    unsafe checkRemembered(n, &out)
    return out.list
}
