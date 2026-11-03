// Ported from experiments/concurrent-marking/swift/Tests/VMCTests/
// ConcurrentTests.swift. Each test fails without the rule it covers; the
// broken variants run with a test switch (`MarkingTestSwitches`) and must
// see the verifier report the missed object. The manual runtimes have no
// marker thread: the test thread is the marker (`markStep`, `finalMark`,
// `sweep`), so the interleaving with Smalltalk on worker 1 is exact.

import Darwin
import Testing
@testable import KajoVM

// MARK: - SATB

/// O (a 100-element list) is reachable at the snapshot only through the old
/// H. After the initial mark the mutator moves O into a young Array (which
/// the marker never scans) and clears H's slot. Only the SATB record of the
/// overwritten value keeps O.
private func satbScenario(satb: Bool) throws -> Runtime {
    let rt = try markingRuntime { $0.testSwitches.satbOff = !satb }
    rt.run("mkH")
    rt.scavenge()  // H and O old
    rt.vm.startCycle()
    #expect(rt.phase == .marking)
    rt.run("moveOut")
    _ = rt.vm.markStep(10_000_000)
    rt.vm.finalMark()
    return rt
}

@Test func satbKeepsAValueOverwrittenDuringMarking() throws {
    let rt = try satbScenario(satb: true)
    #expect(rt.marking.missed == 0)
    #expect(rt.marking.satbPushed >= 1)
    rt.vm.sweep()
    rt.scavenge()
    #expect(rt.runInt("sumZ") == 5050)
    // Another full cycle and a stop-the-world collection agree.
    rt.vm.startCycle()
    rt.finishCycle()
    #expect(rt.runInt("sumZ") == 5050)
    rt.vm.collect()
    #expect(rt.runInt("sumZ") == 5050)
    rt.noFailures()
    rt.stop()
}

@Test func withoutSATBTheVerifierReportsTheMissedObject() throws {
    let rt = try satbScenario(satb: false)
    #expect(rt.marking.missed > 0)
    #expect(verifierCounts(rt).failures > 0)
    // The cycle was abandoned, nothing was freed: the list is intact.
    #expect(rt.phase == .idle && rt.marking.aborts >= 1)
    #expect(rt.runInt("sumZ") == 5050)
    rt.stop(verifyHeap: false)
}

// MARK: - promotion during marking

@Test func objectsPromotedDuringMarkingSurviveTheCycle() throws {
    let rt = try markingRuntime()
    rt.vm.startCycle()
    // Allocated and promoted while marking: never snapshot entries.
    rt.run("mkO")
    rt.scavenge()
    let o = rt.global(8)
    #expect(!rt.young(o))
    #expect(!rt.vm.isSnapshotEntry(o))
    rt.finishCycle()
    rt.vm.startCycle()
    rt.finishCycle()
    #expect(rt.runInt("sumList:", oop: o) == 5050)
    rt.noFailures()
    rt.stop()
}

/// The textbook protocol (DESIGN.md of the experiment): the initial mark
/// does not scavenge, so the young Y exists at the snapshot and holds the
/// only reference to the old O. Y is promoted during marking; the textbook
/// rule pushes it grey.
private func literalPromotion(grey: Bool) throws -> UInt64 {
    let rt = try markingRuntime { $0.testSwitches.literal = true; $0.testSwitches.literalGrey = grey }
    rt.run("mkO")
    rt.scavenge()                 // O old
    rt.run("mkY")                 // Y young -> O
    rt.vm.startCycle(scavenge: false)
    _ = rt.vm.markStep(10_000_000) // nothing reaches O: Y is not a snapshot entry
    rt.scavenge()                 // Y promoted while marking
    _ = rt.vm.markStep(10_000_000)
    rt.vm.finalMark()
    let missed = rt.marking.missed
    if missed == 0 {
        rt.vm.sweep()
        rt.scavenge()
        #expect(rt.runInt("sumY") == 5050)
    }
    rt.stop(verifyHeap: missed == 0)
    return missed
}

@Test func literalProtocolNeedsItsGreyPromotionRule() throws {
    #expect(try literalPromotion(grey: true) == 0)
    #expect(try literalPromotion(grey: false) > 0)
}

/// The case the textbook protocol loses: Y (young at the snapshot) holds
/// the only reference to O; the mutator copies O into the already scanned
/// H over nil (no SATB record) and drops Y, which dies unpromoted. With
/// the initial mark taken at the end of a scavenge (this module's protocol)
/// Y is old at the snapshot, so O is marked through it.
private func youngAtSnapshot(literal: Bool) throws -> (UInt64, Int64?) {
    let rt = try markingRuntime { $0.testSwitches.literal = literal }
    rt.run("mkEmptyH")
    rt.run("mkO")
    rt.scavenge()                 // H, O old
    rt.run("mkY")                 // Y young -> O
    rt.vm.startCycle(scavenge: !literal)
    _ = rt.vm.markStep(10_000_000) // H scanned (black)
    rt.run("copyToHAndDropY")
    rt.scavenge()                 // Y dies (literal) or was already old
    _ = rt.vm.markStep(10_000_000)
    rt.vm.finalMark()
    let missed = rt.marking.missed
    var sum: Int64? = nil
    if missed == 0 {
        rt.vm.sweep()
        rt.scavenge()
        sum = rt.runInt("sumH")
    }
    rt.stop(verifyHeap: missed == 0)
    return (missed, sum)
}

@Test func designLiteralProtocolLosesATargetOfADeadYoungObject() throws {
    let (missed, _) = try youngAtSnapshot(literal: true)
    #expect(missed > 0)
}

@Test func snapshotAfterAScavengeKeepsTheTargetOfAYoungObject() throws {
    let (missed, sum) = try youngAtSnapshot(literal: false)
    #expect(missed == 0)
    #expect(sum == 5050)
}

// MARK: - final mark and sweep

/// A dead snapshot object made remembered during marking leaves the
/// remembered set at the final mark; otherwise the next scavenge would scan
/// a freed entry. Broken (`noRememberedFilter`): the scavenge after the
/// sweep reads the freed holder and its verifier reports it.
private func deadRememberedHolder(filter: Bool) throws -> Runtime {
    // The stop-the-world configuration: its remembered-set verifier is
    // strict (module 7's collections tolerate stale names of freed holders
    // in the lists, which every scan skips by the remembered bit).
    let rt = try markingRuntime(young: .stw) { $0.testSwitches.noRememberedFilter = !filter }
    rt.run("mkHolder")
    rt.scavenge()
    let holder = rt.global(9)
    #expect(!rt.young(holder))
    // Drop the holder before the snapshot, then make it remembered during
    // marking through a VM-internal store: a snapshot entry, unmarked.
    rt.vm.setGlobal(9, rt.image.nilObject)
    rt.vm.startCycle()
    let host = rt.vm.config.backgroundWorkers + 1
    let pair = rt.image.classIndex(named: "Pair")!
    rt.vm.onHostWorker { m in
        let young = m.allocate(pair, slots: 2)
        m.store(holder, 0, young, .atPut)
    }
    #expect(rt.vm.rememberedBufferCount(worker: host) == 1)
    _ = rt.vm.markStep(10_000_000)
    rt.vm.finalMark()
    if filter {
        #expect(rt.vm.rememberedBufferCount(worker: host) == 0)
        #expect(!rt.remembered(holder))
        #expect(rt.marking.remFiltered == 1)
    }
    rt.vm.sweep()
    rt.scavenge()  // would scan the freed holder if it were still remembered
    return rt
}

@Test func filteringRemovesADeadHolderFromTheRememberedSet() throws {
    let rt = try deadRememberedHolder(filter: true)
    rt.noFailures()
    rt.stop()
}

@Test func withoutFilteringTheScavengeReadsAFreedHolder() throws {
    let rt = try deadRememberedHolder(filter: false)
    #expect(verifierCounts(rt).failures > 0)
    rt.stop(verifyHeap: false)
}

@Test func sweepFreesEntriesAndBlocksAndTheyAreReused() throws {
    let rt = try markingRuntime()
    #expect(rt.runInt("churnLists:", 40) == 10 * 2000 * 2001 / 2)
    rt.scavenge()
    let before = rt.image.om.blocksInUse
    rt.vm.setGlobal(8, rt.image.nilObject)  // drop all ten lists
    rt.vm.startCycle()
    rt.finishCycle()
    let after = rt.image.om.blocksInUse
    #expect(after * 2 < before, "blocks in use \(before) -> \(after)")
    let c = rt.vm.cycleLog.last!
    #expect(c.entriesFreed >= 10 * 2000 && c.blocksFreed > 0)
    let hw = rt.image.om.highWater
    #expect(rt.runInt("churnLists:", 40) == 10 * 2000 * 2001 / 2)
    rt.scavenge()
    // Freed entries were reused: the table barely grew.
    #expect(rt.image.om.highWater <= hw + 4096, "high water \(hw) -> \(rt.image.om.highWater)")
    rt.noFailures()
    rt.stop()
}

// MARK: - survivors are roots (ADR 0007)

/// With survivor spaces, something is young at the snapshot: the survivors.
/// S (a survivor) holds the only reference to the old O; the mutator copies
/// O into the already scanned H over nil and drops S, which dies in the next
/// scavenge. Scanning survivors at the initial mark keeps O; without the
/// scan (`noSurvivorRoots`) the verifier reports it missed.
private func survivorAtSnapshot(scan: Bool) throws -> UInt64 {
    // Module 4's scavenge and ADR 0007's survivor scan (module 7's young-root
    // scan has its own test in YoungCollection/).
    let rt = try markingRuntime(age: 2, young: .stw) { $0.testSwitches.noSurvivorRoots = !scan }
    rt.run("mkEmptyH")
    rt.run("mkO")
    rt.scavenge()
    rt.scavenge()                 // H, O old (N = 2)
    rt.run("mkY")                 // Y young -> O
    rt.vm.startCycle()            // Y survives that scavenge: young at the snapshot
    #expect(rt.young(rt.global(9)))
    _ = rt.vm.markStep(10_000_000)
    rt.run("copyToHAndDropY")
    rt.scavenge()                 // Y dies
    _ = rt.vm.markStep(10_000_000)
    rt.vm.finalMark()
    let missed = rt.marking.missed
    if missed == 0 {
        rt.vm.sweep()
        rt.scavenge()
        #expect(rt.runInt("sumH") == 5050)
    }
    rt.stop(verifyHeap: missed == 0)
    return missed
}

@Test func survivorsAreRootsAtTheInitialMark() throws {
    #expect(try survivorAtSnapshot(scan: true) == 0)
    #expect(try survivorAtSnapshot(scan: false) > 0)
}

// MARK: - fallback

@Test func oldSpaceFillingDuringACycleFallsBackToAFullCollection() throws {
    // 4 MiB old space, no marker progress (manual, never stepped): the cycle
    // cannot finish, old space fills, and a stop-the-world collection runs.
    let rt = try markingRuntime(heapBlocks: 128) { $0.floor = 0.3 }
    #expect(rt.runInt("churnLists:", 200) == 10 * 2000 * 2001 / 2)
    let c = rt.marking
    #expect(c.cycles >= 1)
    #expect(c.fallbacks >= 1)
    #expect(c.aborts >= 1)
    #expect(rt.vm.nurseryCounters.fullCollectionsRun >= 1)
    rt.noFailures()
    rt.stop()
}

// MARK: - threads

/// The oldheap kernel at 4 MiB on 4 workers with a marker thread: rewiring
/// under the SATB barrier, promotion during marking, sweeps and applies
/// between scavenges, with a cycle at every scavenge. Its checksum must
/// equal the stop-the-world run's.
/// A release build runs a million iterations in about 20 ms, too few
/// scavenges for several cycles.
#if DEBUG
private let oldheapTestIterations = 1_000_000
#else
private let oldheapTestIterations = 4_000_000
#endif

@Test(arguments: [false, true])
func oldheapUnderConcurrentMarkingMatchesStopTheWorld(_ alwaysOn: Bool) throws {
    func once(_ concurrent: Bool) throws -> (Int64, Runtime) {
        let src = kernel("oldheap") + """
        method UndefinedObject oldheapMB temps=0
          push_int 4
          return_top
        end
        method UndefinedObject oldheapIters temps=0
          push_lit \(oldheapTestIterations)
          return_top
        end
        method UndefinedObject oldheapReplaceEvery temps=0
          push_lit 4096
          return_top
        end
        """
        let rt = try Runtime(src, background: 4, heapBlocks: 72 * 32, entries: 1 << 21, pollEvery: 256, start: false,
                             configure: { c in
                                 c.nursery.bytes = 1 << 20
                                 c.marking.enabled = concurrent
                                 c.marking.stress = alwaysOn ? [.cycleAtEveryScavenge, .markingAlwaysOn] : [.cycleAtEveryScavenge]
                             })
        rt.start()
        var ps: [Oop] = []
        for i in 0..<4 { ps.append(rt.spawn("run:of:", [int(Int64(i)), int(4)])) }
        rt.waitAllTerminated(underThreadSanitizer ? 600 : 120)
        return (ps.map { rt.result($0) }.reduce(0, &+), rt)
    }
    let (a, stw) = try once(false)
    #expect(stw.vm.markingCounters.cycles == 0)
    stw.stop()
    let (b, rt) = try once(true)
    #expect(a == b)
    let c = rt.marking
    #expect(c.cycles >= 2, "cycles \(c.cycles), completed \(c.cyclesCompleted), scavenges \(rt.vm.nurseryCounters.scavenges)")
    #expect(c.verifierRuns >= 1)
    #expect(c.missed == 0)
    rt.noFailures()
    rt.stop()
}

/// `sweepNeverApplies`: every cycle sweeps but no pause publishes it, so
/// old space only ever shrinks through fallbacks, which a module 1
/// operation's hook applies first. The data stays intact and every free
/// entry keeps one owner (the pending runs are a free list).
@Test func aSweepThatNeverAppliesFallsBack() throws {
    let rt = try markingRuntime(heapBlocks: 128) { $0.floor = 0.3; $0.stress = .sweepNeverApplies }
    // The test is the marker: run each cycle the triggers start to its
    // sweep, between the program's slices.
    let p = rt.spawn("churnLists:", [int(200)])
    while rt.vm.liveProcessCount > 0 {
        _ = rt.vm.runOneSlice(worker: 1, budgetNs: 2_000_000)
        if rt.phase == .marking {
            _ = rt.vm.markStep(10_000_000)
            rt.vm.finalMark()
        }
        if rt.phase == .sweeping { rt.vm.sweep() }
    }
    #expect(rt.result(p) == 10 * 2000 * 2001 / 2)
    rt.vm.release(p)
    let c = rt.marking
    #expect(c.cycles >= 1 && c.applies >= 1 && c.fallbacks >= 1, "\(c)")
    #expect(rt.vm.stops.filter { $0.kind == .apply }.isEmpty)
    #expect(c.missed == 0)
    rt.noFailures()
    rt.stop()
}
