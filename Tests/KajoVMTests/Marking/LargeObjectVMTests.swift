// Module 10: large objects in a running VM (docs/modules/large-objects.md):
// allocated old from Smalltalk past a nursery, kept and freed whole by the
// concurrent marking cycle's lazy sweep, never selected by the relocator,
// and marked by the concurrent marker in bounded steps. Each reader's
// broken variant (`TestSwitches.runBlind`) fails its test.

import Testing
@testable import KajoVM

/// `nil mkLarge: n at: g` makes an Array of n slots (a large object when n
/// passes 4095), stores 7 in its last slot, puts it in global g; `nil
/// sumLarge: g` answers its last slot plus its size.
let largeSrc = markingSrc + """
method UndefinedObject mkLarge:at: temps=1
  push_lit @Array
  push_temp 0
  send new: 1
  store_temp 2
  push_temp 2
  push_temp 0
  push_int 7
  send at:put: 2
  pop
  push_nil
  push_temp 1
  push_temp 2
  send g:put: 2
  pop
  push_int 0
  return_top
end
method UndefinedObject lastOf: temps=1
  push_nil
  push_temp 0
  send g: 1
  store_temp 1
  push_temp 1
  push_temp 1
  size
  send at: 1
  push_temp 1
  size
  add
  return_top
end

"""

/// A runtime with manual marking and every verifier recording; one run
/// reader blind when given.
private func largeRuntime(blind: RunReader? = nil, _ change: (inout VMConfig) -> Void = { _ in }) throws -> Runtime {
    var sw = TestSwitches()
    sw.runBlind = blind
    return try Runtime(largeSrc, background: 1, heapBlocks: 2048, start: false, configure: { c in
        c.nursery.bytes = 1 << 20
        c.nursery.age = 1
        c.marking.enabled = true
        c.marking.markerThread = false
        change(&c)
    }, switches: sw)
}

private func head(_ rt: Runtime, _ g: Int) -> Int {
    let o = rt.global(g)
    return rt.vm.inspect { $0.blockIndex(of: o) }
}

private func runInUse(_ rt: Runtime, head b: Int) -> Bool {
    rt.vm.inspect { om in
        let h = om.heap
        guard h.isInUse(b), h.kind(b) == BlockKind.head else { return false }
        return (b + 1..<b + h.runLength(head: b)).allSatisfy { h.isInUse($0) && h.kind($0) == BlockKind.continuation }
    }
}

@Test func aLargeObjectFromSmalltalkIsOldAtBirthInARun() throws {
    let rt = try largeRuntime()
    #expect(rt.runInt("mkLarge:at:", args: [int(20_000), int(8)]) == 0)
    #expect(rt.runInt("lastOf:", 8) == 20_007)
    let a = rt.global(8)
    #expect(rt.vm.inspect { om in !om.header(a).isYoung && om.header(a).isLarge && om.oldMap.contains(a.entryIndex) })
    #expect(runInUse(rt, head: head(rt, 8)))
    // A small one stays young.
    #expect(rt.runInt("mkLarge:at:", args: [int(100), int(9)]) == 0)
    let small = rt.global(9)
    #expect(rt.vm.inspect { om in om.header(small).isYoung })
    rt.scavenge()
    #expect(rt.runInt("lastOf:", 8) == 20_007)
    rt.noFailures()
    rt.stop()
}

/// A live large object (global 8), a dead one (global 9 dropped), and one
/// allocated while the cycle marks (global 10); the lazy sweep's apply.
private func lazySweepScenario(_ blind: RunReader?) throws -> (failures: [String], liveKept: Bool, deadFreed: Bool, newKept: Bool) {
    let rt = try largeRuntime(blind: blind)
    #expect(rt.runInt("mkLarge:at:", args: [int(20_000), int(8)]) == 0)
    #expect(rt.runInt("mkLarge:at:", args: [int(20_000), int(9)]) == 0)
    let live = head(rt, 8), dead = head(rt, 9)
    rt.scavenge()
    rt.vm.setGlobal(9, rt.image.nilObject)
    rt.vm.startCycle()
    #expect(rt.runInt("mkLarge:at:", args: [int(9_000), int(10)]) == 0)
    let fresh = head(rt, 10)
    rt.finishCycle()
    let deadFreed = rt.vm.inspect { !$0.heap.isInUse(dead) }
    let liveKept = runInUse(rt, head: live) && rt.runInt("lastOf:", 8) == 20_007
    let newKept = runInUse(rt, head: fresh) && rt.runInt("lastOf:", 10) == 9_007
    let failures = rt.image.om.verifierReports + (rt.vm.markingCounters.missed > 0 ? ["the final-mark verifier missed \(rt.vm.markingCounters.missed)"] : [])
    rt.vm.shutdown()
    rt.vm.destroy()
    rt.image.destroy()
    return (failures, liveKept, deadFreed, newKept)
}

@Test func theLazySweepFreesADeadRunWholeAndKeepsLiveOnes() throws {
    let r = try lazySweepScenario(nil)
    #expect(r.failures.isEmpty, "\(r.failures.prefix(2))")
    #expect(r.liveKept && r.deadFreed && r.newKept)
}

@Test func withoutTheRunRuleTheLazySweepFreesALiveRunsContinuations() throws {
    let r = try lazySweepScenario(.lazySweep)
    #expect(!r.failures.isEmpty || !r.liveKept)
}

/// Relocation of every live block of a cycle: never a run's.
private func relocationScenario(_ blind: RunReader?) throws -> (selectedRun: Bool, moved: Bool, noSpace: UInt64, failures: [String]) {
    let rt = try largeRuntime(blind: blind) { c in
        c.relocation.testSwitches.manualRelocation = true
        c.relocation.stress = [.relocateEveryLiveBlock, .relocateAtEveryCycle]
        c.relocation.cap = 1
    }
    #expect(rt.runInt("mkLarge:at:", args: [int(20_000), int(8)]) == 0)
    rt.scavenge()
    let b = head(rt, 8)
    let before = rt.vm.stateWord(of: rt.global(8))
    rt.vm.startCycle()
    _ = rt.vm.markStep(10_000_000)
    rt.vm.finalMark()
    let selected = rt.vm.relocationSet.contains(b)
    rt.vm.relocate()
    rt.vm.sweep()
    rt.scavenge()
    let moved = rt.vm.stateWord(of: rt.global(8)) != before
    let noSpace = rt.vm.relocationCounters.noSpace
    let failures = rt.image.om.verifierReports
    rt.vm.shutdown()
    rt.vm.destroy()
    rt.image.destroy()
    return (selected, moved, noSpace, failures)
}

@Test func theRelocatorNeverSelectsARun() throws {
    let r = try relocationScenario(nil)
    #expect(!r.selectedRun && !r.moved && r.noSpace == 0 && r.failures.isEmpty)
}

@Test func withoutTheRunRuleTheRelocatorSelectsARun() throws {
    let r = try relocationScenario(.relocation)
    #expect(r.selectedRun)
}

/// The concurrent marker traces a 1M-slot Array in bounded steps (module
/// 10 splits a large object's scan) and the cycle's verifier agrees.
@Test func theMarkerTracesAMillionSlotArrayInSteps() throws {
    let rt = try largeRuntime()
    #expect(rt.runInt("mkLarge:at:", args: [int(1_000_000), int(8)]) == 0)
    rt.scavenge()
    rt.vm.startCycle()
    // One traced item per step: the Array takes 245 chunks of 4096 slots.
    for _ in 0..<400 { rt.vm.markStep(1) }
    rt.vm.finalMark()
    #expect(rt.vm.markingCounters.chunksSplit >= 244)
    rt.vm.sweep()
    rt.scavenge()
    #expect(rt.runInt("lastOf:", 8) == 1_000_007)
    rt.noFailures()
    rt.stop()
}
