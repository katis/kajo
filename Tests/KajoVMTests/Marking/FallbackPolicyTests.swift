// Large bytes, part 2 (docs/modules/large-bytes.md): the devices' storm
// fell back to a full collection when the entry table ran out while the
// lazy sweep still held the entries it had freed (pending until its
// apply), with the marker at utility on efficiency cores. Two rules: the
// QoS policy watches the entry table and is decided while a cycle runs,
// and an empty table during a sweep finishes the sweep in the stop rather
// than collecting the whole heap. Each test fails with its rule's switch.

import Darwin
import Testing
@testable import KajoVM

/// A stepped runtime (the test is the marker) with a small entry table and
/// no trigger of its own: cycles start only when the test starts them.
private func entriesRuntime(entries: Int, nurseryKB: Int = 1024,
                            _ change: (inout MarkingConfig) -> Void = { _ in }) throws -> Runtime {
    try Runtime(markingSrc, background: 1, heapBlocks: 2048, entries: entries, start: false, configure: { c in
        c.nursery.bytes = nurseryKB << 10
        c.nursery.age = 1
        c.marking.enabled = true
        c.marking.markerThread = false
        c.marking.floor = 2  // never by occupancy or entries
        c.marking.safetyFactor = 0
        change(&c.marking)
    })
}

/// 20 000 old Pairs made garbage, a cycle marked and its sweep left pending
/// (the test never sweeps), then a churn that needs the dead Pairs' entries:
/// the table runs out while the cycle is sweeping.
private func tableRunsOutWhileSweeping(rule: Bool) throws -> (MarkingCounters, Int64, UInt64) {
    let rt = try entriesRuntime(entries: 40_000) { $0.testSwitches.noSweepForEntries = !rule }
    #expect(rt.runInt("churnLists:", 10) == 10 * 2000 * 2001 / 2)
    rt.scavenge()  // the ten lists old
    rt.vm.setGlobal(8, rt.image.nilObject)
    rt.vm.startCycle()
    _ = rt.vm.markStep(10_000_000)
    rt.vm.finalMark()
    #expect(rt.phase == .sweeping)
    let sum = rt.runInt("churnLists:", 25)
    let c = rt.marking
    let fulls = rt.vm.nurseryCounters.fullCollectionsRun
    rt.noFailures()
    rt.stop()
    return (c, sum, fulls)
}

@Test func anEmptyEntryTableWhileSweepingFinishesTheSweepNotAFullCollection() throws {
    let (c, sum, fulls) = try tableRunsOutWhileSweeping(rule: true)
    #expect(sum == 10 * 2000 * 2001 / 2)
    #expect(c.sweepsFinishedForEntries >= 1, "\(c)")
    #expect(c.fallbacks == 0 && fulls == 0, "fallbacks \(c.fallbacks), full collections \(fulls)")
}

@Test func withoutTheRuleAnEmptyTableWhileSweepingFallsBack() throws {
    let (c, sum, fulls) = try tableRunsOutWhileSweeping(rule: false)
    #expect(sum == 10 * 2000 * 2001 / 2)
    #expect(c.sweepsFinishedForEntries == 0)
    #expect(c.fallbacksEntries >= 1 && c.fallbacksSweeping >= 1 && fulls >= 1, "\(c)")
}

/// The QoS policy decides on the entry table too: a cycle whose snapshot
/// holds most of the table wants the marker raised, though old space has
/// headroom; with the policy as module 5 built it (blocks only), it does
/// not. (About 20 500 of 32 000 entries are old at the initial mark, a
/// headroom of 0.36: the threshold is raised to 0.4 for the test.)
private func policyWantsRaise(entriesRule: Bool) throws -> (Bool, MarkingCounters) {
    let rt = try entriesRuntime(entries: 32_000) {
        $0.testSwitches.qosOnBlocksOnly = !entriesRule
        $0.escalateBelow = 0.4
    }
    #expect(rt.runInt("churnLists:", 10) == 10 * 2000 * 2001 / 2)
    rt.scavenge()
    rt.vm.startCycle()  // decides the policy
    let want = rt.vm.markerWantsRaise
    let c = rt.marking
    _ = rt.vm.markStep(10_000_000)
    rt.vm.finalMark()
    rt.vm.sweep()
    rt.scavenge()
    rt.noFailures()
    rt.stop()
    return (want, c)
}

@Test func theQoSPolicyWatchesTheEntryTable() throws {
    #expect(try policyWantsRaise(entriesRule: true).0)
    #expect(try !policyWantsRaise(entriesRule: false).0)
}

/// While a cycle marks, module 7's young collections promote into the
/// table; the policy, decided again at each collection's end, wants the
/// marker raised once the table's headroom is low. As module 5 built it
/// (decided only at the initial mark, when the table was nearly empty),
/// it never does.
private func raisedDuringTheCycle(rule: Bool) throws -> (Bool, Bool, MarkingCounters) {
    let rt = try entriesRuntime(entries: 80_000, nurseryKB: 128) { $0.testSwitches.qosOnBlocksOnly = !rule }
    rt.vm.startCycle()
    let atStart = rt.vm.markerWantsRaise
    #expect(rt.runInt("churnLists:", 40) == 10 * 2000 * 2001 / 2)
    let after = rt.vm.markerWantsRaise
    let c = rt.marking
    _ = rt.vm.markStep(10_000_000)
    rt.vm.finalMark()
    rt.vm.sweep()
    rt.scavenge()
    rt.noFailures()
    rt.stop()
    return (atStart, after, c)
}

@Test func theQoSPolicyIsDecidedWhileACycleRuns() throws {
    let (atStart, after, c) = try raisedDuringTheCycle(rule: true)
    // The manual marker never progresses here, so the table runs out in
    // the end (a fallback while marking); the decision came before it.
    #expect(!atStart && after, "\(c)")
    let (_, broken, _) = try raisedDuringTheCycle(rule: false)
    #expect(!broken)
}
