// The final mark on the devices (docs/modules/final-mark.md): the final
// mark's record and the bound on what its stop waits for and does.

import Darwin
import Foundation
import Synchronization
import Testing
@testable import KajoVM

// MARK: - the record

/// A final mark requested while a young collection is open waits for it
/// before the request (module 7: no stop interleaves a collection), and its
/// record says so: the collection open, the time before the request apart
/// from the stop (which counts from the request: its time to safepoint and
/// work), and the work and its parts after the verifier.
@Test func theFinalMarksRecordSplitsItsTimeToSafepoint() throws {
    let hooks = YoungHooks()
    let rt = try youngRuntime(.local, src: markingSrc, marking: true) { c in
        hooks.install(&c.young.testSwitches)
        c.young.verify = false
    }
    let vm = rt.vm
    rt.run("mkEmptyH")
    vm.collect()
    vm.startYoungCycle()
    #expect(rt.phase == .marking)
    _ = vm.markStep(10_000_000)
    let done = Flag()
    var t: TestThread? = nil
    hooks.set(1) { k in
        guard k == 1 else { return }
        t = TestThread { vm.finalMark(); done.set() }
        #expect(eventually { vm.stopsWanted == 1 })
    }
    vm.collectYoung(worker: 1)
    hooks.set(1, nil)
    #expect(eventually(30) { done.isSet })
    t?.join()
    let r = try #require(vm.cycleLog.last)
    #expect(r.finalCollectionsOpen == 1)
    #expect(r.finalBeforeRequestNs > 0)
    #expect(r.finalPauseNs >= r.finalTtspNs)
    #expect(r.finalWorkNs > 0 && r.finalWorkNs >= r.relocationAtFinalNs &+ r.sweepSetupNs)
    let stop = try #require(vm.stops.last { $0.kind == .finalMark })
    #expect(stop.collectionsOpen == 1 && stop.beforeRequestNs == r.finalBeforeRequestNs)
    #expect(stop.timeToSafepointNs == r.finalTtspNs && stop.pauseNs >= r.finalPauseNs)
    #expect(rt.marking.missed == 0)
    rt.stop()
}

// MARK: - the bound on the final mark's tracing

/// Ten 2000-Pair lists in old space and a cycle with nothing marked
/// concurrently: a final mark that may trace at most `bound` units gives
/// up (the world is released with the cycle still marking), the marker's
/// concurrent step finishes the work, and the next final mark is small.
/// Every attempt stays within the bound plus what one step may overshoot
/// it by (every worker's partial buffer, one queued item, one traced
/// object). The test switch `unboundedFinalMark` is the broken variant.
private func finalMarkAgainstTheBound(bounded: Bool, bound: Int = 256) throws -> (units: UInt64, giveUps: UInt64) {
    let rt = try markingRuntime(young: .stw) { m in
        m.finalMarkWork = bound
        m.testSwitches.unboundedFinalMark = !bounded
    }
    #expect(rt.runInt("churnLists:", 10) == 10 * 2000 * 2001 / 2)
    rt.scavenge()
    rt.vm.startCycle()
    #expect(rt.phase == .marking)
    rt.vm.finalMark()                       // nothing marked yet: past the bound
    if bounded {
        #expect(rt.phase == .marking)
        _ = rt.vm.markStep(10_000_000)      // the work, concurrently
        rt.vm.finalMark()
    }
    #expect(rt.phase == .sweeping)
    let r = try #require(rt.vm.cycleLog.last)
    #expect(rt.marking.missed == 0)
    rt.vm.sweep()
    rt.scavenge()
    #expect(rt.phase == .idle)
    rt.noFailures()
    rt.stop()
    return (r.finalWorkUnitsMax, r.finalGiveUps)
}

@Test func theFinalMarksStopIsBoundedInWork() throws {
    let bound = 256
    let (units, giveUps) = try finalMarkAgainstTheBound(bounded: true, bound: bound)
    #expect(giveUps == 1)
    #expect(units <= UInt64(bound + SATBBuffer.capacity * 3 + MarkChunk.weight), "units \(units)")
}

@Test func withoutTheBoundTheFinalMarkTracesEverythingInItsStop() throws {
    let (units, giveUps) = try finalMarkAgainstTheBound(bounded: false)
    #expect(giveUps == 0)
    #expect(units > 20_000, "units \(units)")
}

// MARK: - the young-root scan outside the initial mark's stop

/// global 7 is H (old, empty), global 9 is Y (young, nursery 1) holding O
/// (old), O's only path. `moveYToH` moves O from Y into H and clears Y's
/// slot: a store into a young holder whose nursery's scan is still owed.
private let moveSrc = markingSrc + """
method UndefinedObject moveYToH temps=0
  push_nil
  push_int 7
  send g: 1
  push_nil
  push_int 9
  send g: 1
  send x 0
  push_nil
  send x:y: 2
  pop
  push_nil
  push_int 9
  send g: 1
  push_nil
  push_nil
  send x:y: 2
  return_top
end

"""

/// The initial mark records the nurseries and leaves their scans owed; the
/// marker's step does them (the stop scanned none).
@Test func theInitialMarkLeavesTheYoungRootsOwed() throws {
    let rt = try youngRuntime(.local, src: markingSrc, marking: true)
    rt.run("mkEmptyH")
    rt.run("mkO")
    rt.vm.collect()
    rt.run("mkY")
    rt.vm.startYoungCycle()
    #expect(rt.phase == .marking)
    #expect(rt.vm.rootScanState(1) == RootScanState.owed)
    #expect(rt.vm.youngCounters.youngRootScanNs == 0)
    _ = rt.vm.markStep(10_000_000)
    #expect(rt.vm.rootScanState(1) == RootScanState.none)
    let s = rt.vm.rootScanStats
    #expect(s[RootScanStat.byMarker] >= 1 && s[RootScanStat.inStop] == 0)
    rt.vm.finalMark()
    #expect(rt.phase == .sweeping && rt.marking.missed == 0)
    rt.vm.sweep()
    #expect(rt.runInt("sumY") == 100 * 101 / 2)
    rt.stop()
}

/// O leaves the young Y for H after H was traced and before Y's nursery
/// was scanned. With the barrier on young holders of an owed nursery the
/// store records O; without it (`noOwedScanBarrier`) the scan, done in the
/// final mark's stop, finds Y empty and the verifier reports O.
private func storeIntoAnOwedNursery(barrier: Bool) throws -> UInt64 {
    let rt = try youngRuntime(.local, src: moveSrc, marking: true) { c in
        c.marking.testSwitches.markerSkipsRootScans = true
        c.marking.testSwitches.unboundedFinalMark = true
        c.marking.testSwitches.noOwedScanBarrier = !barrier
    }
    rt.run("mkEmptyH")
    rt.run("mkO")
    rt.vm.collect()
    rt.run("mkY")
    rt.vm.startYoungCycle()
    _ = rt.vm.markStep(10_000_000)          // H traced; Y's nursery not scanned
    #expect(rt.vm.rootScanState(1) == RootScanState.owed)
    rt.run("moveYToH")
    rt.vm.finalMark()                       // the scan in the stop: Y is empty
    #expect(rt.vm.rootScanStats[RootScanStat.inStop] >= 1)
    let missed = rt.marking.missed
    if missed == 0 {
        rt.vm.sweep()
        #expect(rt.runInt("sumH") == 100 * 101 / 2)
    }
    rt.stop(verifyHeap: missed == 0)
    return missed
}

@Test func aStoreIntoAYoungHolderWhoseScanIsOwedIsRecorded() throws {
    #expect(try storeIntoAnOwedNursery(barrier: true) == 0)
}

@Test func withoutTheOwedScanBarrierTheValueIsLost() throws {
    #expect(try storeIntoAnOwedNursery(barrier: false) > 0)
}

/// O is copied from the young Y into H (over nil: no record) and Y dies,
/// after H was traced and before Y's nursery was scanned; then nursery 1
/// collects. The collection scans the nursery first (Y's body still names
/// O); with `collectBeforeRootScan` Y is freed unscanned and the verifier
/// reports O.
private func collectionOfAnOwedNursery(scanFirst: Bool) throws -> UInt64 {
    let rt = try youngRuntime(.local, src: markingSrc, marking: true) { c in
        c.marking.testSwitches.markerSkipsRootScans = true
        c.marking.testSwitches.unboundedFinalMark = true
        c.marking.testSwitches.collectBeforeRootScan = !scanFirst
        c.young.verify = false  // the broken variant's eden is walked after its reuse
    }
    rt.run("mkEmptyH")
    rt.run("mkO")
    rt.vm.collect()
    rt.run("mkY")
    rt.vm.startYoungCycle()
    _ = rt.vm.markStep(10_000_000)          // H traced; Y's nursery not scanned
    rt.run("copyToHAndDropY")
    rt.vm.collectYoung(worker: 1)           // Y dies here
    #expect(rt.vm.rootScanStats[RootScanStat.byCollector] == (scanFirst ? 1 : 0))
    _ = rt.vm.markStep(10_000_000)          // the collector's candidates
    rt.vm.finalMark()
    let missed = rt.marking.missed
    if missed == 0 {
        rt.vm.sweep()
        #expect(rt.runInt("sumH") == 100 * 101 / 2)
    }
    rt.stop(verifyHeap: missed == 0)
    return missed
}

@Test func aCollectionScansItsOwedNurseryBeforeItMovesIt() throws {
    #expect(try collectionOfAnOwedNursery(scanFirst: true) == 0)
}

@Test func withoutTheScanBeforeTheCollectionTheValueIsLost() throws {
    #expect(try collectionOfAnOwedNursery(scanFirst: false) > 0)
}

/// The work before the stop: the marker scans every owed nursery before
/// it asks for the final mark. With `markerSkipsRootScans` every final mark
/// finds a scan owed and gives up, until the cycle's give-ups run out and
/// one does the scans in its stop (an overrun, counted).
private func finalMarksWithOwedScans(skip: Bool) throws -> (giveUps: UInt64, overruns: UInt64, inStop: UInt64) {
    let rt = try youngRuntime(.local, src: markingSrc, marking: true) { c in
        c.marking.testSwitches.markerSkipsRootScans = skip
    }
    rt.run("mkEmptyH")
    rt.run("mkO")
    rt.vm.collect()
    rt.run("mkY")
    rt.vm.startYoungCycle()
    var attempts = 0
    while rt.phase == .marking && attempts < 20 {
        _ = rt.vm.markStep(10_000_000)
        rt.vm.finalMark()
        attempts += 1
    }
    #expect(rt.phase == .sweeping && rt.marking.missed == 0)
    rt.vm.sweep()
    #expect(rt.runInt("sumY") == 100 * 101 / 2)
    let c = rt.marking
    let inStop = rt.vm.rootScanStats[RootScanStat.inStop]
    rt.stop()
    return (c.finalGiveUps, c.finalOverruns, inStop)
}

@Test func theMarkerScansTheOwedNurseriesBeforeItAsks() throws {
    let r = try finalMarksWithOwedScans(skip: false)
    #expect(r.giveUps == 0 && r.overruns == 0 && r.inStop == 0)
}

@Test func withoutTheScansBeforeTheStopTheFinalMarkGivesUpThenOverruns() throws {
    let r = try finalMarksWithOwedScans(skip: true)
    #expect(r.giveUps == 8 && r.overruns == 1 && r.inStop >= 1)
}

// MARK: - the main worker and a wanted stop

/// Worker 1 (the test thread) collects; during it (hook point 1) a host
/// thread asks for a stop, which waits for the collection (`stwWanted`).
/// The main worker then needs a collection of its own: it opens it while
/// the stop is wanted (once), before worker 1's collection ends (it cannot
/// finish it then: its rounds wait for worker 1, held in the hook). As
/// module 7 built it the main worker waited with the stop (the broken
/// variant, `mainWaitsForWantedStops`, run by hand: the second collection
/// never opens inside the hook; docs/modules/final-mark.md).
@Test func theMainWorkerOpensOneCollectionWhileAStopIsWanted() throws {
    let hooks = YoungHooks()
    let rt = try youngRuntime(.local, src: youngSrc + """
    method UndefinedObject scavengeNow temps=0
      push_nil
      send scavenge 0
      pop
      push_int 7
      return_top
    end

    """) { c in
        hooks.install(&c.young.testSwitches)
        c.young.verify = false
    }
    let vm = rt.vm
    let p = rt.spawn("scavengeNow", main: true)
    let stopped = Flag(), ran = Flag()
    var r: TestThread? = nil, b: TestThread? = nil
    var openedInside = false
    hooks.set(1) { k in
        guard k == 1 else { return }
        r = TestThread { vm.withWorldStopped {}; stopped.set() }
        #expect(eventually { vm.stopsWanted == 1 })
        b = TestThread {
            // Not `state(of:)`: a host call waits for the stopper's host call.
            while vm.liveProcessCount > 0 { _ = vm.runMain(budgetNs: 5_000_000) }
            ran.set()
        }
        openedInside = eventually(30) { vm.collectionsOpen == 2 }
    }
    vm.collectYoung(worker: 1)
    hooks.set(1, nil)
    #expect(openedInside, "the main worker opened its collection while the stop was wanted")
    #expect(eventually(30) { stopped.isSet && ran.isSet })
    r?.join()
    b?.join()
    #expect(rt.result(p) == 7)
    #expect(vm.youngWorkerCounters(0).opensWhileWanted == 1)
    #expect(rt.verifierFailures == 0)
    rt.stop()
}

// MARK: - the remembered filter after the ephemerons

/// An ephemeron whose key is reachable only through it fires at the final
/// mark, and its value V (old) is traced then. V names a young object Y
/// and is remembered. The filter that drops dead holders from the
/// remembered set runs after the ephemerons: before this follow-up it ran
/// first, read V as an unmarked snapshot entry, and dropped it; V survived
/// the sweep, the next scavenge did not scan it and Y went unscanned (the
/// test fails on the starting commit, 4a94f07).
@Test func aHolderMarkedByAFiredEphemeronStaysRemembered() throws {
    let rt = try markingRuntime(weakMarkingSrc, young: .stw)
    rt.run("makeEph")
    rt.scavenge()
    let eph = rt.global(9)
    let value = rt.slot(eph, 1)
    #expect(!rt.young(eph) && !rt.young(value))
    let pair = rt.image.classIndex(named: "Pair")!
    rt.vm.startCycle()                      // a scavenge, then the snapshot
    rt.vm.onHostWorker { m in
        let young = m.allocate(pair, slots: 2)
        m.store(value, 0, young, .atPut)
    }
    #expect(rt.remembered(value))
    _ = rt.vm.markStep(10_000_000)
    rt.vm.finalMark()
    #expect(rt.marking.ephemeronsQueued == 1 && rt.marking.missed == 0)
    #expect(rt.remembered(value))
    rt.vm.sweep()
    rt.scavenge()
    #expect(!rt.young(rt.slot(value, 0)))
    rt.noFailures()
    rt.stop()
}
