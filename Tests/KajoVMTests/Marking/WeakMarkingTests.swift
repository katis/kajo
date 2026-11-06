// Weak slots and ephemerons under the concurrent marker (ADR 0009 section
// 1; docs/modules/concurrent-marking.md "Weak slots and ephemerons"), the
// keep-alive read barrier on weak slots, and the verifier's
// non-snapshot-mark check. New tests: no experiment had them.

import Darwin
import Testing
@testable import KajoVM

let weakMarkingSrc = weakSrc + """
; global 7 := WeakBag new: 2 holding A := Pair x: 1 (global 11) and
; B := Pair x: 2 (global 12), so both survive the first scavenge.
method UndefinedObject makeWeakOld temps=1
  push_lit @WeakBag
  push_int 2
  send new: 1
  store_temp 0
  push_nil
  push_int 11
  push_nil
  push_int 1
  send pair: 1
  send g:put: 2
  pop
  push_nil
  push_int 12
  push_nil
  push_int 2
  send pair: 1
  send g:put: 2
  pop
  push_temp 0
  push_int 1
  push_nil
  push_int 11
  send g: 1
  send at:put: 2
  pop
  push_temp 0
  push_int 2
  push_nil
  push_int 12
  send g: 1
  send at:put: 2
  pop
  push_nil
  push_int 7
  push_temp 0
  send g:put: 2
  return_top
end
; global 13 := H, an empty Pair
method UndefinedObject mkWeakH temps=0
  push_nil
  push_int 13
  push_lit @Pair
  send basicNew 0
  push_nil
  push_nil
  send x:y: 2
  send g:put: 2
  return_top
end
; H x: ((global 7) at: 1) y: nil -- read a weak slot, store it into H
method UndefinedObject weakToH temps=0
  push_nil
  push_int 13
  send g: 1
  push_nil
  push_int 7
  send g: 1
  push_int 1
  send at: 1
  push_nil
  send x:y: 2
  return_top
end
method UndefinedObject hxx temps=0
  push_nil
  push_int 13
  send g: 1
  send x 0
  send x 0
  return_top
end
method Object instVarAt: temps=0 prim=91
  push_nil
  return_top
end
method Object slotAt: temps=0 prim=117
  push_nil
  return_top
end
method Object shallowCopy temps=0 prim=96
  push_nil
  return_top
end
method Object replaceFrom:to:with:startingAt: temps=0 prim=38
  push_lit @Object
  return_top
end
; weakToHByReplace
method UndefinedObject weakToHByReplace temps=0
  push_nil
  push_int 13
  send g: 1
  push_int 1
  push_int 1
  push_nil
  push_int 7
  send g: 1
  push_int 1
  send replaceFrom:to:with:startingAt: 4
  return_top
end
; weakToHByInstVarAt
method UndefinedObject weakToHByInstVarAt temps=0
  push_nil
  push_int 13
  send g: 1
  push_nil
  push_int 7
  send g: 1
  push_int 1
  send instVarAt: 1
  push_nil
  send x:y: 2
  return_top
end
; weakToHBySlotAt
method UndefinedObject weakToHBySlotAt temps=0
  push_nil
  push_int 13
  send g: 1
  push_nil
  push_int 7
  send g: 1
  push_int 1
  send slotAt: 1
  push_nil
  send x:y: 2
  return_top
end
; weakToHByShallowCopy
method UndefinedObject weakToHByShallowCopy temps=0
  push_nil
  push_int 13
  send g: 1
  push_nil
  push_int 7
  send g: 1
  send shallowCopy 0
  push_nil
  send x:y: 2
  return_top
end
"""

@Test func aWeakSlotIsNiledAtTheFinalMarkExactlyWhenItsReferentDied() throws {
    let rt = try markingRuntime(weakMarkingSrc)
    rt.run("makeWeakOld")
    rt.scavenge()
    let bag = rt.global(7), a = rt.global(11), b = rt.global(12)
    #expect(!rt.young(bag) && !rt.young(a) && !rt.young(b))
    rt.vm.setGlobal(11, rt.image.nilObject)  // A is held only weakly now
    rt.vm.startCycle()
    _ = rt.vm.markStep(10_000_000)
    rt.vm.finalMark()
    #expect(rt.marking.missed == 0)
    #expect(rt.slot(bag, 0) == rt.image.nilObject && rt.slot(bag, 1) == b)
    #expect(rt.marking.weakSlotsNiled == 1)
    rt.vm.sweep()
    rt.scavenge()
    #expect(rt.vm.inspect { !$0.isUsedReference(a) && $0.isUsedReference(b) })
    // A second cycle with B still held: nothing more is nil'ed.
    rt.vm.startCycle()
    rt.finishCycle()
    #expect(rt.slot(bag, 1) == b && rt.marking.weakSlotsNiled == 1)
    rt.noFailures()
    rt.stop()
}

@Test func anEphemeronWhoseKeyIsReachableOnlyThroughItIsQueuedOnceAndItsValueTraced() throws {
    let rt = try markingRuntime(weakMarkingSrc)
    rt.run("makeEph")
    rt.scavenge()
    let eph = rt.global(9)
    let key = rt.slot(eph, 0), value = rt.slot(eph, 1)
    #expect(!rt.young(eph) && !rt.young(key) && !rt.young(value))
    rt.vm.startCycle()
    _ = rt.vm.markStep(10_000_000)
    rt.vm.finalMark()
    #expect(rt.marking.missed == 0)
    #expect(rt.marking.ephemeronsQueued == 1)
    #expect(rt.image.om.finalizationQueueCount == 1)
    #expect(rt.header(eph).isFiredEphemeron)
    rt.vm.sweep()
    rt.scavenge()
    // Key and value survive this cycle; the value's slots were traced.
    #expect(rt.slot(eph, 0) == key && rt.slot(value, 0) == int(43) && rt.slot(value, 1) == key)
    // Fired: strong from now on, never queued again.
    rt.vm.startCycle()
    rt.finishCycle()
    #expect(rt.marking.ephemeronsQueued == 1 && rt.image.om.finalizationQueueCount == 1)
    rt.noFailures()
    rt.stop()
}

@Test func anEphemeronWhoseKeyIsReachableElsewhereIsNotQueued() throws {
    let rt = try markingRuntime(weakMarkingSrc)
    rt.run("makeEph")
    rt.scavenge()
    let eph = rt.global(9)
    let key = rt.slot(eph, 0)
    rt.vm.setGlobal(11, key)
    rt.vm.startCycle()
    rt.finishCycle()
    #expect(rt.marking.ephemeronsQueued == 0 && rt.marking.missed == 0)
    #expect(!rt.header(eph).isFiredEphemeron && rt.slot(eph, 0) == key)
    rt.noFailures()
    rt.stop()
}

/// A referent held only weakly at the snapshot is read through its weak
/// slot during marking and stored into an already scanned object. The
/// marker never traces weak slots, so only the keep-alive read barrier on
/// `at:` keeps it; without it (`noWeakKeepAlive`) the verifier reports the
/// object missed (and the weak slot would have been nil'ed under a live
/// reference).
private func weakReadDuringMarking(keepAlive: Bool) throws -> (UInt64, Int64?) {
    let rt = try markingRuntime(weakMarkingSrc) { $0.testSwitches.noWeakKeepAlive = !keepAlive }
    rt.run("makeWeakOld")
    rt.run("mkWeakH")
    rt.scavenge()
    rt.vm.setGlobal(11, rt.image.nilObject)
    rt.vm.startCycle()
    _ = rt.vm.markStep(10_000_000)  // H and the bag scanned; A not marked
    rt.run("weakToH")
    _ = rt.vm.markStep(10_000_000)
    rt.vm.finalMark()
    let missed = rt.marking.missed
    var v: Int64? = nil
    if missed == 0 {
        rt.vm.sweep()
        rt.scavenge()
        v = rt.runInt("hxx")
    }
    rt.stop(verifyHeap: missed == 0)
    return (missed, v)
}

@Test func aWeakReferentReadDuringMarkingIsKeptAlive() throws {
    let (missed, v) = try weakReadDuringMarking(keepAlive: true)
    #expect(missed == 0 && v == 1)
    let (missedOff, _) = try weakReadDuringMarking(keepAlive: false)
    #expect(missedOff > 0)
}

/// The marker never marks an entry that is not a snapshot entry: the
/// final-mark verifier checks it. A mark set by hand on an object promoted
/// during marking is reported.
@Test func theMarkingVerifierReportsAMarkedNonSnapshotEntry() throws {
    let rt = try markingRuntime()
    rt.vm.startCycle()
    rt.run("mkO")
    rt.scavenge()
    let o = rt.global(8)
    #expect(!rt.young(o) && !rt.vm.isSnapshotEntry(o))
    rt.vm.corruptMark(o)
    _ = rt.vm.markStep(10_000_000)
    rt.vm.finalMark()
    #expect(verifierCounts(rt).failures > 0)
    #expect(rt.image.om.verifierReports.contains { $0.contains("not a snapshot entry") })
    rt.stop(verifyHeap: false)
}

/// Collectors review, finding 1: every primitive that reads a slot of an
/// object a program could make weak and hands the value on keeps the
/// referent alive while marking, as `at:` does. A referent A held only
/// weakly at the snapshot is read during marking and ends in H, a holder
/// the marker has already scanned: by `replaceFrom:to:with:startingAt:`
/// (primitive 38's copy loop), `instVarAt:`, `slotAt:`, or inside a
/// `shallowCopy` of the weak bag (a new weak object, whose slots the final
/// mark never nils). Answers the final mark's missed count and whether A
/// is still a used entry after the sweep and a scavenge while H still
/// reaches it.
private func weakRouteDuringMarking(_ selector: String, keepAlive: Bool) throws -> (missed: UInt64, alive: Bool) {
    let rt = try markingRuntime(weakMarkingSrc) { $0.testSwitches.noWeakKeepAlive = !keepAlive }
    rt.run("makeWeakOld")
    rt.run("mkWeakH")
    rt.scavenge()
    let a = rt.global(11), h = rt.global(13)
    rt.vm.setGlobal(11, rt.image.nilObject)
    rt.vm.startCycle()
    _ = rt.vm.markStep(10_000_000)  // H and the bag scanned; A not marked
    rt.run(selector)
    _ = rt.vm.markStep(10_000_000)
    rt.vm.finalMark()
    let missed = rt.marking.missed
    if missed > 0 {
        rt.stop(verifyHeap: false)
        return (missed, false)
    }
    rt.vm.sweep()
    rt.scavenge()
    let hx = rt.slot(h, 0)
    let held = selector == "weakToHByShallowCopy" ? rt.slot(hx, 0) : hx
    #expect(held == a || held == rt.image.nilObject)
    let alive = rt.vm.inspect { $0.isUsedReference(a) }
    rt.stop(verifyHeap: alive)
    return (missed, alive)
}

@Test(arguments: ["weakToHByReplace", "weakToHByInstVarAt", "weakToHBySlotAt", "weakToHByShallowCopy"])
func aWeakReferentCopiedOutDuringMarkingIsKeptAlive(_ selector: String) throws {
    let (missed, alive) = try weakRouteDuringMarking(selector, keepAlive: true)
    #expect(missed == 0 && alive, "\(selector)")
    // Without the keep-alive barrier the referent is lost: the verifier
    // reports it missed, or (a new weak copy) the sweep frees it under the
    // copy's slot.
    let (missedOff, aliveOff) = try weakRouteDuringMarking(selector, keepAlive: false)
    #expect(missedOff > 0 || !aliveOff, "\(selector)")
}

private let internSrc = weakMarkingSrc + "\n" + """
method String asSymbol temps=0 prim=129
  push_nil
  return_top
end
method UndefinedObject internDrop: temps=0
  push_temp 0
  send asSymbol 0
  push_nil
  identical
  jump_if_false made
  push_int 1
  return_top
made:
  push_int 0
  return_top
end
"""

/// Collectors review, finding 1, beside the copy: the symbol table's
/// bucket growth copies a full weak bucket into a new, larger one. During
/// marking the new bucket is not a snapshot entry, so the final mark never
/// nils its slots: a Symbol held only by the old bucket must be kept alive
/// as it is copied, or the sweep frees it under the new bucket's slot.
/// Answers whether every slot of the grown bucket is nil or a used entry.
private func bucketGrowthDuringMarking(keepAlive: Bool) throws -> Bool {
    let rt = try markingRuntime(internSrc) { $0.testSwitches.noWeakKeepAlive = !keepAlive }
    let table = rt.image.symbolTable
    func bucket(_ s: String) -> Int { Int(truncatingIfNeeded: utf8Hash(Array(s.utf8))) & (SymbolTable.buckets - 1) }
    let b = bucket("zzGrow0")
    let names = Array((0..<1_000_000).lazy.map { "zzGrow\($0)" }.filter { bucket($0) == b }.prefix(64))
    // Fill the bucket (a new bucket holds four), then one more grows it.
    let (size, free) = rt.vm.inspect { om -> (Int, Int) in
        let k = om.load(table, b)
        if k == rt.image.nilObject { return (0, 0) }
        let n = Int(om.count(of: k))
        return (n, (0..<n).filter { om.load(k, $0) == rt.image.nilObject }.count)
    }
    let fill = size == 0 ? SymbolTable.firstBucket : free
    try #require(fill + 1 <= names.count)
    for s in names.prefix(fill) { #expect(rt.runInt("internDrop:", oop: rt.vm.newString(s)) == 0) }
    rt.scavenge()
    rt.vm.startCycle()
    _ = rt.vm.markStep(10_000_000)  // the table and the full bucket scanned; its Symbols not marked
    #expect(rt.runInt("internDrop:", oop: rt.vm.newString(names[fill])) == 0)  // grows the bucket while marking
    _ = rt.vm.markStep(10_000_000)
    rt.vm.finalMark()
    #expect(rt.marking.missed == 0)
    rt.vm.sweep()
    rt.scavenge()
    let whole = rt.vm.inspect { om -> Bool in
        let k = om.load(table, b)
        return (0..<Int(om.count(of: k))).allSatisfy { i in
            let v = om.load(k, i)
            return v == rt.image.nilObject || om.isUsedReference(v)
        }
    }
    rt.stop(verifyHeap: whole)
    return whole
}

@Test func aSymbolCopiedIntoAGrownBucketDuringMarkingIsKeptAlive() throws {
    #expect(try bucketGrowthDuringMarking(keepAlive: true))
    #expect(try !bucketGrowthDuringMarking(keepAlive: false))
}
