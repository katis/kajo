// The sweep stop (docs/modules/sweep-stop.md): a stop that finds the entry
// table empty while a cycle sweeps hands over what is swept (a partial
// apply) and sweeps itself at most `sweepStopWords` words, instead of
// finishing the whole sweep inside the stop (19 to 30 ms on the Mac's
// binarytrees at 8 workers). The rules each have a test that fails with
// their switch: the bound (`sweepStopUnbounded`), the one-owner check
// (`applyAheadOfSweep`, the broken variant: an entry handed over before the
// sweep reached it must fail the verifier), the relocation cut-off, and
// the entry-rate trigger (`noEntryRateRule`).

import Darwin
import Testing
@testable import KajoVM

/// A stepped runtime (the test is the marker) with a small entry table and
/// no trigger of its own, as the large-bytes follow-up's tests.
private func sweepRuntime(entries: Int = 40_000, nurseryKB: Int = 1024,
                          _ change: (inout VMConfig) -> Void = { _ in }) throws -> Runtime {
    try Runtime(markingSrc, background: 1, heapBlocks: 2048, entries: entries, start: false, configure: { c in
        c.nursery.bytes = nurseryKB << 10
        c.nursery.age = 1
        c.marking.enabled = true
        c.marking.markerThread = false
        c.marking.floor = 2
        c.marking.safetyFactor = 0
        change(&c)
    })
}

/// 20 000 old Pairs made garbage and a cycle marked: its sweep pending.
private func sweepPending(_ rt: Runtime) {
    #expect(rt.runInt("churnLists:", 10) == 10 * 2000 * 2001 / 2)
    rt.scavenge()
    rt.vm.setGlobal(8, rt.image.nilObject)
    rt.vm.startCycle()
    _ = rt.vm.markStep(10_000_000)
    rt.vm.finalMark()
    #expect(rt.phase == .sweeping)
}

@Test func aBoundedSweepStopHandsOverWhatIsSweptAndLeavesTheRest() throws {
    let rt = try sweepRuntime { $0.marking.sweepStopWords = 16 }
    sweepPending(rt)
    let runs0 = rt.image.om.counters.verifierRuns
    #expect(rt.vm.sweepStop() == .partial)
    #expect(rt.vm.sweepStop() == .partial)
    #expect(rt.phase == .sweeping)
    let log = rt.vm.sweepStopLog
    #expect(log.count == 2)
    for r in log {
        #expect(r.outcome == .partial && r.wordsInStop == 16, "\(r)")
        #expect(r.entriesHanded == r.entriesFreedInStop, "\(r)")
    }
    #expect(log[1].cursorWords == 16 && log.map(\.entriesHanded).reduce(0, +) > 0, "\(log)")
    // The verifier ran at both stops (heap, free lists, the one-owner check).
    #expect(rt.image.om.counters.verifierRuns >= runs0 + 2)
    rt.vm.sweep()
    rt.scavenge()
    #expect(rt.phase == .idle)
    let c = rt.marking
    #expect(c.sweepStops == 2 && c.sweepStopsPartial == 2 && c.cyclesCompleted == 1, "\(c)")
    rt.noFailures()
    rt.stop()
}

@Test func whatTheMarkerSweptIsHandedOverWithoutSweepingInTheStop() throws {
    let rt = try sweepRuntime { $0.marking.sweepStopEnoughEntries = 1 }
    sweepPending(rt)
    #expect(!rt.vm.sweepStep(words: 64))
    #expect(rt.vm.sweepStop() == .partial)
    let r = rt.vm.sweepStopLog[0]
    #expect(r.cursorWords == 64 && r.wordsInStop == 0 && r.entriesFreedInStop == 0, "\(r)")
    #expect(r.entriesHanded == r.entriesFreed && r.entriesHanded > 0 && r.pendingRuns > 0, "\(r)")
    rt.vm.sweep()
    rt.scavenge()
    rt.noFailures()
    rt.stop()
}

@Test func withTheSwitchTheSweepStopFinishesTheWholeSweep() throws {
    let rt = try sweepRuntime {
        $0.marking.sweepStopWords = 16
        $0.marking.testSwitches.sweepStopUnbounded = true
    }
    sweepPending(rt)
    #expect(rt.vm.sweepStop() == .unbounded)
    #expect(rt.phase == .idle)
    let r = rt.vm.sweepStopLog[0]
    #expect(r.wordsInStop == r.totalWords && r.wordsInStop > 16, "\(r)")
    rt.noFailures()
    rt.stop()
}

/// The young allocation's own path: the churn empties the table while the
/// cycle sweeps (the test never sweeps), and every stop it asks for hands
/// over 16 words' worth at most, until one of them reaches the end. No
/// full collection, no verifier failure (the verifier runs at every one).
@Test func anEmptyTableWhileSweepingIsServedByBoundedStops() throws {
    let rt = try sweepRuntime { $0.marking.sweepStopWords = 16 }
    sweepPending(rt)
    #expect(rt.runInt("churnLists:", 25) == 10 * 2000 * 2001 / 2)
    let c = rt.marking
    let log = rt.vm.sweepStopLog
    #expect(c.sweepStopsPartial >= 2 && c.sweepStopsUnbounded == 0, "\(c)")
    #expect(log.allSatisfy { $0.wordsInStop <= 16 && $0.cause == .entries }, "\(log)")
    #expect(c.fallbacks == 0 && rt.vm.nurseryCounters.fullCollectionsRun == 0, "\(c)")
    #expect(rt.image.om.verifierReports.isEmpty, "\(rt.image.om.verifierReports.prefix(2))")
    rt.noFailures()
    rt.stop()
}

/// The broken variant: the stop also hands over the dead entries of the
/// first snapshot word past the cursor, which the sweep has not reached.
/// The verifier at the stop names an entry with two owners. (Nothing runs
/// after it: the sweep would free those entries again.)
@Test func handingOverAnEntryTheSweepHasNotReachedFailsTheVerifier() throws {
    let rt = try sweepRuntime {
        $0.marking.sweepStopWords = 16
        $0.marking.testSwitches.applyAheadOfSweep = true
    }
    sweepPending(rt)
    let before = rt.image.om.counters.verifierFailures
    #expect(rt.vm.sweepStop() == .partial)
    let after = rt.image.om.counters.verifierFailures
    #expect(after > before)
    #expect(rt.image.om.verifierReports.contains { $0.contains("the sweep has not reached it") }, "\(rt.image.om.verifierReports.prefix(2))")
    rt.stop(verifyHeap: false)
}

/// A bounded sweep must not run ahead of the cycle's relocation pass (the
/// relocator moves only snapshot entries and would evacuate a block with a
/// swept live body in it): the stop cuts the pass off, nothing is moved,
/// and the rest of the cycle and the relocation verifier are clean.
@Test func aBoundedSweepStopCutsOffAPendingRelocationPass() throws {
    let rt = try sweepRuntime {
        $0.marking.sweepStopWords = 16
        $0.relocation.stress = [.relocateEveryLiveBlock, .relocateAtEveryCycle]
    }
    sweepPending(rt)
    #expect(rt.vm.sweepStop() == .partial)
    let r = rt.vm.sweepStopLog[0]
    #expect(r.relocationCutOff, "\(r)")
    rt.vm.sweep()
    #expect(rt.vm.relocationCountersNow.objectsMoved == 0)
    rt.scavenge()
    #expect(rt.phase == .idle)
    #expect(rt.marking.sweepStopRelocCutOffs == 1)
    #expect(rt.runInt("churnLists:", 5) == 5 * 2000 * 2001 / 2)
    rt.noFailures()
    rt.stop()
}

// MARK: - part 3: the entry-rate rule

@Test func theEntryRateRuleStartsACycleBeforeTheTableFills() {
    // Decided on a given state: 160 000 entries, 60 000 old (below the
    // 0.6 floor), a million entries a second and a horizon of two 50 ms
    // cycles: the 100 000 free entries last 100 ms, not under the horizon;
    // at 80 000 old (80 ms) the rule fires.
    var c = MarkingConfig()
    c.markerThread = false
    #expect(fillsWithin(c, capacity: 160_000, old: 60_000, rate: 1e6, horizonNs: 100e6) == false)
    #expect(fillsWithin(c, capacity: 160_000, old: 80_000, rate: 1e6, horizonNs: 100e6) == true)
    #expect(fillsWithin(c, capacity: 160_000, old: 80_000, rate: 0, horizonNs: 100e6) == false)
    c.testSwitches.noEntryRateRule = true
    #expect(fillsWithin(c, capacity: 160_000, old: 80_000, rate: 1e6, horizonNs: 100e6) == false)
}

/// `entryRateFillsTable` on a VM of `capacity` entries.
private func fillsWithin(_ c: MarkingConfig, capacity: Int, old: UInt64, rate: Double, horizonNs: Double) -> Bool {
    let rt = try! Runtime(markingSrc, background: 1, heapBlocks: 2048, entries: capacity, start: false, configure: { v in
        v.marking = c
        v.marking.enabled = true
    })
    defer { rt.stop() }
    guard let mk = unsafe rt.vm.state.pointee.marking else { return false }
    return unsafe entryRateFillsTable(mk, entryRate: rate, oldEntries: old, withinNs: horizonNs)
}

// MARK: - part 4: the ring's cascade of full collections

/// A full collection whose mark-sweep leaves old space at or above the
/// cycle trigger's floor compacts in the same stop (the ring's records: a
/// non-compacting one at 98 percent of the limit was followed by two or
/// three more). With the floor above what the sweep leaves, it does not.
private func fullCompacts(floor: Double) throws -> UInt64 {
    let rt = try sweepRuntime { $0.marking.floor = floor }
    #expect(rt.runInt("churnLists:", 10) == 10 * 2000 * 2001 / 2)
    rt.scavenge()
    let before = rt.vm.nurseryCounters.fullCompactions
    rt.vm.runFullCollection()
    let n = rt.vm.nurseryCounters.fullCompactions - before
    #expect(rt.runInt("churnLists:", 3) == 3 * 2000 * 2001 / 2)
    rt.noFailures()
    rt.stop()
    return n
}

@Test func aFullCollectionThatLeavesOldSpaceAboveTheFloorCompacts() throws {
    #expect(try fullCompacts(floor: 0) == 1)
    #expect(try fullCompacts(floor: 2) == 0)
}
