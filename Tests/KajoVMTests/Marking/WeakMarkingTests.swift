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
