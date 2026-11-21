// The verifier's faults (docs/modules/verifier-faults.md), fault 2: a body
// a scavenge keeps in place (the promotion reserve's fallback) and places in
// another nursery than its own leaves the young objects of its first nursery
// that name it, and the young objects of that nursery it names, unremembered
// across nurseries. A young collection beside the mutators (module 7) then
// misses those holders. The rare path (its own nursery has no room) is
// driven by the test switch `keptAcrossNurseries`; every verifier runs.

import Darwin
import Foundation
import Testing
@testable import KajoVM

/// The image's blocks plus `headroom`: a heap the reserve load overflows
/// (as `ReserveTests`).
private func tightBlocks(_ headroom: Int) throws -> Int {
    let probe = try nurseryRuntime(twinRingSrc, background: 4, nurseryKB: 24, start: false)
    defer { probe.stop() }
    return probe.image.om.blocksInUse + headroom
}

/// The reserve's load with each ring node a Pair whose `y` is another Pair
/// made just before it, by the same worker in the same nursery: a young
/// holder of a young object of its own nursery, remembered by nobody until
/// one of the two moves to another nursery. The sum reads the inner Pairs.
private let twinRingSrc: String = {
    var s = reserveLoadSrc
    let store = "  push_nil\n  push_temp 1\n  send pair: 1\n  send at:put: 2\n"
    precondition(s.components(separatedBy: store).count == 2)
    s = s.replacingOccurrences(of: store, with: "  push_nil\n  push_temp 1\n  send twin: 1\n  send at:put: 2\n")
    let read = "  send at: 1\n  send x 0\n"
    precondition(s.components(separatedBy: read).count == 2)
    s = s.replacingOccurrences(of: read, with: "  send at: 1\n  send y 0\n  send x 0\n")
    return s + """
    ; nil twin: x  ->  (nil pair: x) x: x y: (nil pair: x)
    method UndefinedObject twin: temps=0
      push_nil
      push_temp 0
      send pair: 1
      push_temp 0
      push_nil
      push_temp 0
      send pair: 1
      send x:y: 2
      return_top
    end
    """
}()

/// The reserve's load with no reserve, its kept bodies of one nursery
/// placed in the others at every exhausted scavenge: whatever the young
/// mode, every remembered-set check passes, and the edge was crossed
/// (bodies moved across, counted). On 07fcad1 the offloaded mode fails the
/// nursery verifier: "entry E (young in A) names young @R (nursery B) ...,
/// and is not remembered for it", the holder or the referent "kept and
/// moved from nursery A to B".
@Test(arguments: YoungMode.allCases)
func keptBodiesPlacedInAnotherNurseryStayRemembered(_ mode: YoungMode) throws {
    let (rt, nc, runs, failures, seconds) = try keptAcrossRun(mode, rescan: true)
    print("verifier-faults kept-across \(mode): keptObjects=\(nc.keptObjects) keptMovedAcross=\(nc.keptMovedAcross) "
          + "keptAcrossHolders=\(nc.keptAcrossHolders) exhausted=\(nc.exhaustedScavenges) verifierRuns=\(runs) failures=\(failures) bodyS=\(seconds)")
    #expect(nc.keptMovedAcross > 0, "no kept body moved across: \(nc)")
    // The fix's own path ran: young holders remembered after the moves
    // (offloaded mode only; the stop-the-world mode remembers old holders).
    #expect((nc.keptAcrossHolders > 0) == (mode == .offload), "\(nc)")
    #expect(runs > 0)
    rt.noFailures()
    rt.stop()
}

/// The fix taken out by its test switch (`keptAcrossWithoutRescan`): the
/// offloaded mode fails the nursery verifier and the line names a body
/// kept and moved across. Run in the suite because the broken variant
/// fails a verifier, not a trap.
@Test func withoutTheRescanTheVerifierNamesAMovedBody() throws {
    let (rt, nc, _, failures, _) = try keptAcrossRun(.offload, rescan: false)
    #expect(nc.keptMovedAcross > 0, "no kept body moved across: \(nc)")
    #expect(failures > 0, "the broken variant passed the verifier: \(nc)")
    #expect(rt.image.om.verifierReports.contains { $0.contains("kept and moved from nursery") },
            "\(rt.image.om.verifierReports.prefix(1))")
    rt.stop(verifyHeap: false)
}

/// The twin ring on four background workers, no promotion reserve, a
/// tight heap, kept bodies placed across nurseries, marking off: the
/// runtime after the Processes ended, its counters, the verifier's runs
/// and failures and the body's seconds.
private func keptAcrossRun(_ mode: YoungMode, rescan: Bool) throws -> (Runtime, NurseryCounters, UInt64, UInt64, String) {
    let t0 = nanoseconds()
    let blocks = try tightBlocks(24)
    let rt = try nurseryRuntime(twinRingSrc, background: 4, nurseryKB: 24, start: true, heapBlocks: blocks,
                                configure: { c in
        c.nursery.testSwitches.promotionReserveBlocks = 0
        c.nursery.testSwitches.keptAcrossNurseries = true
        c.nursery.testSwitches.keptAcrossWithoutRescan = !rescan
        // As the reserve tests: without the lazy sweep only full
        // collections free old space, so promotion runs out again and again.
        c.marking.enabled = false
        c.young.mode = mode
        c.young.verify = true
        c.young.verifyEvery = 1
    })
    let n: Int64 = underThreadSanitizer ? 20_000 : 60_000
    var ps: [Oop] = []
    for _ in 0..<4 { ps.append(rt.spawn("ring:", [int(n)])) }
    rt.waitAllTerminated(underThreadSanitizer ? 600 : 120)
    for p in ps { #expect(rt.result(p) == (n - 1023...n).reduce(0, +)) }
    let (runs, failures) = verifierCounts(rt)
    return (rt, rt.vm.nurseryCounters, runs, failures, String(format: "%.1f", Double(nanoseconds() - t0) / 1e9))
}
