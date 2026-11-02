// Weak slots, ephemerons and the finalization queue (ADR 0009 section 1 as
// v0 implements it; docs/modules/nursery.md). New tests, no experiment had
// them.

import Darwin
import Foundation
import Testing
@testable import KajoVM

/// WeakBag: no named slots, indexed slots weak. Eph: an ephemeron (key,
/// value); `mourn` stores the key's x into global 20 and counts in 21.
let weakSrc = pairSrc + """
class WeakBag Object 0 weak
class Eph Object 2 ephemeron
method Eph key:value: temps=0
  push_temp 0
  store_ivar 0
  push_temp 1
  store_ivar 1
  return_self
end
method Eph mourn temps=0
  push_nil
  push_int 20
  push_ivar 0
  send x 0
  send g:put: 2
  pop
  push_nil
  push_int 21
  push_nil
  push_int 21
  send g: 1
  push_int 1
  add
  send g:put: 2
  return_self
end
; global 7 := WeakBag new: 2 holding (Pair x: 1) and (Pair x: 2); global 8 := the second Pair
method UndefinedObject makeWeak temps=2
  push_lit @WeakBag
  push_int 2
  send new: 1
  store_temp 0
  push_nil
  push_int 2
  send pair: 1
  store_temp 1
  push_temp 0
  push_int 1
  push_nil
  push_int 1
  send pair: 1
  send at:put: 2
  pop
  push_temp 0
  push_int 2
  push_temp 1
  send at:put: 2
  pop
  push_nil
  push_int 8
  push_temp 1
  send g:put: 2
  pop
  push_nil
  push_int 7
  push_temp 0
  send g:put: 2
  return_top
end
; (global 7) at: 1 put: (Pair x: 3) ; the fresh Pair is held only weakly
method UndefinedObject refillWeak temps=0
  push_nil
  push_int 7
  send g: 1
  push_int 1
  push_nil
  push_int 3
  send pair: 1
  send at:put: 2
  pop
  push_int 0
  return_top
end
; global 9 := Eph key: (Pair x: 42) value: (Pair x: 43 y: key). The key is
; held only by the ephemeron (and by the value, which the ephemeron holds).
method UndefinedObject makeEph temps=1
  push_nil
  push_int 42
  send pair: 1
  store_temp 0
  push_nil
  push_int 9
  push_lit @Eph
  send basicNew 0
  push_temp 0
  push_lit @Pair
  send basicNew 0
  push_int 43
  push_temp 0
  send x:y: 2
  send key:value: 2
  send g:put: 2
  pop
  push_int 0
  return_top
end
; the finalization Process: register global 10's Semaphore, then forever
; wait and mourn every queued ephemeron. Answers when global 22 is not nil.
method UndefinedObject finalizer temps=1
  push_nil
  push_nil
  push_int 10
  send g: 1
  send finalizationSemaphore: 1
  pop
loop:
  push_nil
  push_int 10
  send g: 1
  send wait 0
  pop
drain:
  push_nil
  send nextMourner 0
  store_temp 0
  push_temp 0
  push_nil
  identical
  jump_if_true loop
  push_temp 0
  send mourn 0
  pop
  jump drain
end
"""

@Test func aWeakSlotIsNiledByAScavengeWhenItsYoungReferentDies() throws {
    let rt = try nurseryRuntime(weakSrc, age: 1)
    rt.spawn("makeWeak")
    rt.runOn(1)
    let bag = rt.global(7), kept = rt.global(8)
    #expect(rt.young(bag) && rt.slot(bag, 0) != rt.image.nilObject)
    rt.scavenge()   // the bag is young: its weak slots are not traced
    #expect(!rt.young(bag) && rt.slot(bag, 0) == rt.image.nilObject && rt.slot(bag, 1) == kept)
    rt.spawn("refillWeak")   // old bag -> young Pair, through a weak slot: remembered
    rt.runOn(1)
    #expect(rt.remembered(bag))
    rt.scavenge()
    #expect(rt.slot(bag, 0) == rt.image.nilObject && rt.slot(bag, 1) == kept && !rt.remembered(bag))
    #expect(rt.vm.nurseryCounters.weakSlotsNiled == 2)
    rt.noFailures()
    rt.stop()
}

@Test func aWeakSlotIsNiledByAFullCollection() throws {
    let rt = try nurseryRuntime(weakSrc, age: 1)
    rt.spawn("makeWeak")
    rt.runOn(1)
    rt.scavenge()   // bag and the kept Pair old; slot 1 nil'ed by the scavenge
    let bag = rt.global(7), kept = rt.global(8)
    #expect(!rt.young(bag) && !rt.young(kept) && rt.slot(bag, 1) == kept)
    rt.vm.setGlobal(8, rt.image.nilObject)
    rt.vm.collect()
    #expect(rt.slot(bag, 0) == rt.image.nilObject && rt.slot(bag, 1) == rt.image.nilObject)
    #expect(rt.image.om.counters.weakSlotsNiled == 1)
    #expect(rt.vm.inspect { !$0.isUsedReference(kept) })
    rt.noFailures()
    rt.stop()
}

@Test func anOldWeakReferentIsKeptByAScavenge() throws {
    let rt = try nurseryRuntime(weakSrc, age: 1)
    rt.spawn("makeWeak")
    rt.runOn(1)
    rt.scavenge()
    let bag = rt.global(7), kept = rt.global(8)
    #expect(!rt.young(kept))
    rt.vm.setGlobal(8, rt.image.nilObject)
    rt.scavenge()   // an old referent is never nil'ed by a scavenge
    #expect(rt.slot(bag, 1) == kept)
    rt.vm.collect()
    #expect(rt.slot(bag, 1) == rt.image.nilObject)
    rt.noFailures()
    rt.stop()
}

/// The weak-slot rule switched off: a dead young referent's slot is left
/// as it was, naming a freed entry, and the verifier reports it.
@Test func withoutNilingTheVerifierReportsADanglingWeakSlot() throws {
    let rt = try nurseryRuntime(weakSrc, age: 1, configure: { $0.nursery.testSwitches.keepDeadWeakSlots = true })
    rt.spawn("makeWeak")
    rt.runOn(1)
    rt.scavenge()
    #expect(verifierCounts(rt).failures > 0)
    rt.stop(verifyHeap: false)
}

@Test func anEphemeronWhoseKeyDiesIsQueuedOnceAndItsValueTraced() throws {
    let rt = try nurseryRuntime(weakSrc, background: 1, age: 1, start: true)
    rt.semaphore(global: 10)
    rt.vm.setGlobal(21, int(0))
    let fin = rt.spawn("finalizer")
    #expect(eventually { rt.state(fin) == .waiting })
    rt.spawn("makeEph")
    #expect(eventually { rt.vm.liveProcessCount == 1 })
    let eph = rt.global(9)
    let key = rt.slot(eph, 0), value = rt.slot(eph, 1)
    rt.scavenge()   // the scavenge treats an ephemeron as strong
    #expect(rt.slot(eph, 0) == key)
    rt.vm.collect()  // key reachable only through the ephemeron: queued, key and value kept
    #expect(rt.image.om.counters.ephemeronsQueued == 1)
    #expect(rt.slot(eph, 0) == key && rt.slot(value, 1) == key && rt.slot(value, 0) == int(43))
    #expect(eventually { rt.global(21) == int(1) })
    #expect(rt.global(20) == int(42))
    rt.vm.collect()   // fired: not queued again
    #expect(rt.image.om.counters.ephemeronsQueued == 1)
    #expect(rt.global(21) == int(1))
    rt.vm.setGlobal(9, rt.image.nilObject)
    rt.vm.collect()
    #expect(rt.vm.inspect { !$0.isUsedReference(key) && !$0.isUsedReference(value) })
    rt.vm.terminate(fin)
    rt.waitAllTerminated()
    rt.noFailures()
    rt.stop()
}

@Test func anEphemeronWhoseKeyLivesIsNotQueued() throws {
    let rt = try nurseryRuntime(weakSrc, age: 1)
    rt.spawn("makeEph")
    rt.runOn(1)
    let eph = rt.global(9)
    let key = rt.slot(eph, 0)
    rt.vm.setGlobal(11, key)
    rt.vm.collect()
    #expect(rt.image.om.counters.ephemeronsQueued == 0)
    #expect(rt.slot(eph, 0) == key)
    rt.noFailures()
    rt.stop()
}

@Test func largeObjectsAreAllocatedOld() throws {
    let src = """
    method UndefinedObject big temps=0
      push_nil
      push_int 7
      push_lit @Array
      push_lit 2000
      send new: 1
      send globalAt:put: 2
      pop
      push_nil
      push_int 8
      push_lit @Array
      push_int 100
      send new: 1
      send globalAt:put: 2
      return_top
    end
    """
    let rt = try nurseryRuntime(src)
    rt.spawn("big")
    rt.runOn(1)
    #expect(!rt.young(rt.global(7)) && rt.space(rt.global(7)) == .old)
    #expect(rt.young(rt.global(8)))
    rt.noFailures()
    rt.stop()
}

@Test func aSnapshotAfterPromoteAllHasNothingYoung() throws {
    let rt = try nurseryRuntime(pairSrc + """
    method UndefinedObject keepList temps=0
      push_nil
      push_int 7
      push_nil
      push_lit 500
      send list: 1
      send g:put: 2
      return_top
    end
    """, age: 3)
    rt.spawn("keepList")
    rt.runOn(1)
    rt.scavenge()
    #expect(rt.young(rt.global(7)))
    let bytes = rt.vm.snapshot()
    #expect(!rt.young(rt.global(7)))
    var c = ObjectMemoryConfig()
    c.heapBytes = 2048 * BlockHeap.blockBytes
    c.entryCapacity = 1 << 20
    let om = try ObjectMemory.load(snapshot: bytes, config: c)
    let hw = om.highWater
    var young = 0
    for e in 1..<hw where om.isUsedReference(Oop(entryIndex: e)) && om.header(Oop(entryIndex: e)).isYoung { young += 1 }
    #expect(young == 0)
    om.destroy()
    rt.noFailures()
    rt.stop()
}

/// Snapshot version 2 keeps the class formats, the finalization queue and
/// the nil object weak slots become. With `KAJO_WRITE_SNAPSHOT_SEED` set it
/// also writes the snapshot fuzz seed (Fixtures/fuzz/snapshot/seed.snap).
@Test func aSnapshotKeepsFormatsTheFinalizationQueueAndNil() throws {
    let rt = try nurseryRuntime(weakSrc, age: 1)
    rt.spawn("makeWeak")
    rt.runOn(1)
    rt.spawn("makeEph")
    rt.runOn(1)
    rt.vm.collect()   // the ephemeron's key is only its own: queued
    #expect(rt.image.om.finalizationQueueCount == 1)
    let bytes = rt.vm.snapshot()
    var c = ObjectMemoryConfig()
    c.heapBytes = 2048 * BlockHeap.blockBytes
    c.reserveBytes = 2048 * BlockHeap.blockBytes
    c.entryCapacity = 1 << 20
    let om = try ObjectMemory.load(snapshot: bytes, config: c)
    let weakBag = rt.image.classIndex(named: "WeakBag")!, eph = rt.image.classIndex(named: "Eph")!
    #expect(om.classFormat(weakBag).isWeak && om.classFormat(eph).isEphemeron && om.classFormat(eph).namedSlots == 2)
    #expect(om.finalizationQueueCount == 1 && om.nilObject == rt.image.nilObject)
    if let path = ProcessInfo.processInfo.environment["KAJO_WRITE_SNAPSHOT_SEED"] {
        try Data(bytes).write(to: URL(fileURLWithPath: path))
    }
    om.destroy()
    rt.noFailures()
    rt.stop()
}

/// The loader refuses a young header (a snapshot follows a promote-all) and
/// an unknown format bit.
@Test func theSnapshotLoaderRefusesYoungObjectsAndBadFormats() throws {
    let rt = try nurseryRuntime(weakSrc, age: 1)
    let bytes = rt.vm.snapshot()
    rt.stop()
    let L = try SnapshotLayout(parsing: bytes)
    func word(_ b: [UInt8], _ at: Int) -> UInt64 { SnapshotLayout.word(b, at) }
    func put(_ b: inout [UInt8], _ at: Int, _ v: UInt64) { for k in 0..<8 { b[at + k] = UInt8(truncatingIfNeeded: v >> (8 * UInt64(k))) } }
    var young = bytes
    let nilEntry = L.tableAt + Int(word(bytes, 8 * 8) >> 4) * 16 + 8
    put(&young, nilEntry, word(bytes, nilEntry) | Header.youngBit)
    #expect(throws: SnapshotError.self) { _ = try ObjectMemory.load(snapshot: young) }
    var format = bytes
    put(&format, L.formatsAt + 8, 1 << 30)
    #expect(throws: SnapshotError.self) { _ = try ObjectMemory.load(snapshot: format) }
}
