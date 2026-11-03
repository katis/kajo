// Mutation under relocation of every live block (docs/modules/relocation.md
// "Tests"): `kernel` on four workers with a marker thread, a cycle at every
// scavenge, every live snapshot block selected in every cycle (cap 0.9),
// every verifier on; the checksum must equal stop-the-world's. The oldheap
// rewires and the fragment keeper writes race with the copies, and
// fragment's array copies with the hazard check: a lost store would change
// the checksum. Run also under ThreadSanitizer.

import Darwin
import Testing
@testable import KajoVM

/// The ring (32 768 nodes per worker) must wrap for fragment to keep
/// nodes and copy them: at least 4 x 32 768 iterations. Under
/// ThreadSanitizer (10 to 50 times slower) the smallest that still does.
#if DEBUG
private let oldheapIterations = underThreadSanitizer ? 300_000 : 1_000_000
private let fragmentIterations = underThreadSanitizer ? 140_000 : 160_000
#else
private let oldheapIterations = 4_000_000
private let fragmentIterations = 400_000
#endif

private let oldheapSource = kernel("oldheap") + """
method UndefinedObject oldheapMB temps=0
  push_int 4
  return_top
end
method UndefinedObject oldheapIters temps=0
  push_lit \(oldheapIterations)
  return_top
end
method UndefinedObject oldheapReplaceEvery temps=0
  push_lit 4096
  return_top
end
"""

private func fragmentKernel(_ iterations: Int) -> String {
    kernel("fragment") + """
    method UndefinedObject fragmentIters temps=0
      push_lit \(iterations)
      return_top
    end
    """
}
private let fragmentSource = fragmentKernel(fragmentIterations)

/// `run: i of: 4` on four workers; the summed checksum and the runtime
/// (stopped by the caller).
private func runKernel(_ src: String, heapBlocks: Int, relocate: Bool?, perturb: Bool = false) throws -> (Int64, Runtime) {
    let rt = try Runtime(src, background: 4, heapBlocks: heapBlocks, entries: 1 << 21, pollEvery: 256, start: false,
                         configure: { c in
                             c.nursery.bytes = 1 << 20
                             guard let relocate else {
                                 c.marking.enabled = false  // the oracle
                                 return
                             }
                             c.marking.stress = .cycleAtEveryScavenge
                             c.relocation.enabled = relocate
                             c.relocation.stress = [.relocateEveryLiveBlock, .relocateAtEveryCycle]
                             c.relocation.cap = 0.9
                             if perturb { c.perturb = Perturbation(seed: 7, probability: 0.05, maxSleepUs: 20) }
                         })
    rt.start()
    var ps: [Oop] = []
    for i in 0..<4 { ps.append(rt.spawn("run:of:", [int(Int64(i)), int(4)])) }
    rt.waitAllTerminated(underThreadSanitizer ? 900 : 180)
    return (ps.map { rt.result($0) }.reduce(0, &+), rt)
}

private func underRelocation(_ src: String, heapBlocks: Int, _ name: String) throws {
    let (a, stw) = try runKernel(src, heapBlocks: heapBlocks, relocate: nil)
    stw.stop()
    let (b, rt) = try runKernel(src, heapBlocks: heapBlocks, relocate: true)
    #expect(a == b)
    let r = rt.relocation
    let m = rt.marking
    #expect(m.missed == 0 && r.verifierFailures == 0 && r.parksWhileRelocating == 0)
    // The relocation verifier runs at every pause from a final mark that
    // selected blocks to the first pause after the cycle: at least once
    // per selecting cycle.
    #expect(r.objectsMoved > 1000 && r.cyclesSelected >= 2 && r.verifierRuns >= r.cyclesSelected, "\(r)")
    if name == "fragment" { #expect(r.hazardsTaken > 0) }
    print("\(name) under relocation: \(m.cyclesCompleted) cycles, moved \(r.objectsMoved) objects (\(r.bytesMoved) bytes), \(r.blocksEvacuated) blocks evacuated, skipped pinned \(r.skippedPinned) hazard \(r.skippedHazard), stores redone \(r.storesRedone), spins \(r.spinEpisodes) (max \(r.spinMaxNs) ns), hazards taken \(r.hazardsTaken), freed by epoch \(r.freedByEpoch) at pauses \(r.freedAtPause), frame pins \(r.framePins)")
    rt.noFailures()
    rt.stop()
}

@Test func oldheapUnderAggressiveRelocationMatchesStopTheWorld() throws {
    try underRelocation(oldheapSource, heapBlocks: 72 * 32, "oldheap")
}

@Test func fragmentUnderAggressiveRelocationMatchesStopTheWorld() throws {
    try underRelocation(fragmentSource, heapBlocks: 128 * 32, "fragment")
}

/// The model's liveness finding as an assertion under stress: with
/// perturbation reaching the relocator between objects and inside every
/// copy (yields and sleeps between the CAS and the switch), and stops
/// coming from scavenges on four workers, the relocator never parks
/// between a CAS and its switch or revert (`park` counts it; checked
/// builds that trap stop there), and the perturbation did reach the copies.
@Test func theRelocatorNeverParksWhileRelocating() throws {
    // A release build runs 400 000 iterations in a fraction of a second,
    // too few cycles when the whole suite runs beside it; more iterations
    // need a larger heap: with perturbation slowing the relocator, a 128
    // MiB heap ran out (module 4's promotion reserve) at 1.6 million.
    #if DEBUG
    let (src, heap) = (fragmentSource, 128 * 32)
    #else
    let (src, heap) = (fragmentKernel(800_000), 512 * 32)
    #endif
    let (_, rt) = try runKernel(src, heapBlocks: heap, relocate: true, perturb: true)
    // The pass's totals are added when it ends; under load the utility-QoS
    // marker can still be in its first pass when the kernel finishes (one
    // loaded run: a 20 s final mark, 3357 objects copied, none counted yet),
    // so the progress check counts the copies perturbation reached.
    let r = rt.relocation
    #expect(r.perturbedCopies >= 200 && r.perturbedCopies >= 2 * r.objectsMoved, "\(r) \(rt.marking)")
    #expect(r.parksWhileRelocating == 0)
    #expect(rt.vm.counters.stops > 10)
    rt.noFailures()
    rt.stop()
}
