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
    let t0 = nanoseconds()
    let blocks = try tightBlocks(24)
    let rt = try nurseryRuntime(twinRingSrc, background: 4, nurseryKB: 24, start: true, heapBlocks: blocks,
                                configure: { c in
        c.nursery.testSwitches.promotionReserveBlocks = 0
        c.nursery.testSwitches.keptAcrossNurseries = true
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
    let nc = rt.vm.nurseryCounters
    #expect(nc.keptMovedAcross > 0, "no kept body moved across: \(nc)")
    let (runs, failures) = verifierCounts(rt)
    #expect(runs > 0)
    print("verifier-faults kept-across \(mode): keptObjects=\(nc.keptObjects) keptMovedAcross=\(nc.keptMovedAcross) "
          + "exhausted=\(nc.exhaustedScavenges) verifierRuns=\(runs) failures=\(failures) bodyS=\(String(format: "%.1f", Double(nanoseconds() - t0) / 1e9))")
    rt.noFailures()
    rt.stop()
}
