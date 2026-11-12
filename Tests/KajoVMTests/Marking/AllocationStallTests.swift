import Foundation
import Testing
@testable import KajoVM

// Allocation stalls (docs/modules/allocation-stalls.md, "Tests"): a
// background worker that would take old space or the entry table past a
// limit waits for the concurrent collector's progress instead of stopping
// the world; a fallback is taken only when a cycle begun after the stall
// began has completed, been applied and left the resource missing.
//
// The ring-like load is fragment.kasm (module 6's kernel, the shells'
// `ring:` before it was bounded): 14-slot nodes live 32 768 iterations in a
// ring per worker and die in old space, every 20th evicted node is kept.

private func itersSource(_ n: Int) -> String {
    "method UndefinedObject fragmentIters temps=0\n  push_lit \(n)\n  return_top\nend\n"
}

private func ringFiles(_ iters: Int) -> [(path: String, text: String)] {
    [("prelude.kasm", kernel("prelude")), ("lib.kasm", kernel("lib")), ("iters.kasm", itersSource(iters)),
     ("fragment.kasm", kernel("fragment"))]
}

/// What a headless run answered, its report by name.
struct StallRun {
    let checksum: Int64?
    let failure: String?
    let report: [String: String]
    func n(_ k: String) -> Double { Double(report[k] ?? "") ?? -1 }
    var summary: String {
        ["fallbacks", "unjustifiedFallbacks", "fallbacksByStall", "fallbacksByMain", "stalls", "stallMaxMs", "cycles",
         "markerSlowSpins", "fallbackLog"].map { "\($0)=\(report[$0] ?? "-")" }.joined(separator: " ")
    }
}

/// The compiled module for an image of `files` (AOT 1: modules bind by
/// content, so one generated from the same kasm binds in the run's image).
private func nativeModule(_ files: [(path: String, text: String)]) throws -> NativeModule {
    var c = ObjectMemoryConfig()
    c.heapBytes = 64 << 20
    let image = try Image(memory: ObjectMemory(c))
    defer { image.destroy() }
    try image.load(files.map { (file: $0.path, text: $0.text) })
    return try NativeTest.module(for: image)
}

private func headless(_ files: [(path: String, text: String)], young: String, workers: Int = 2, heapMiB: Int,
                      nurseryKB: Int = 512, slowdown: Int = 1, stalls: Bool = true, reloc: String = "on",
                      native: Bool = nativeRuntimes) throws -> StallRun {
    var o = Headless.Options()
    o.workers = workers
    o.heapMiB = heapMiB
    o.nurseryKB = nurseryKB
    o.young = young
    o.markerSlowdown = slowdown
    o.stalls = stalls
    o.relocation = reloc
    if native { o.native = try nativeModule(files) }
    let out = Headless.run(files, options: o)
    var report: [String: String] = [:]
    for (k, v) in out.report { report[k] = v }
    for c in out.counters { report[c.name] = "\(c.value)" }
    switch out.checksum {
    case .success(let v): return StallRun(checksum: v, failure: nil, report: report)
    case .failure(let f): return StallRun(checksum: nil, failure: "\(f)", report: report)
    }
}

/// The ring-like load's answer with room to spare (no stall, no fallback).
/// Two workers, 400 000 iterations: 8 MiB of ring nodes live, 51 MB
/// promoted, on a 16 MiB heap.
private let ringIters = underThreadSanitizer ? 150_000 : 400_000
private let ringReference: Int64? = {
    try? headless(ringFiles(ringIters), young: "offload", heapMiB: 256, native: false).checksum
}()

// MARK: - the ring-like load

/// A slowed marker (16 times, standing for a mutator 16 times faster: the
/// tests run a debug build, whose interpreter is slow against its
/// marker) on a heap the live data fits with room: every young mode stalls
/// instead of falling back, and answers what the load answers with room to
/// spare.
@Test(arguments: ["stw", "local", "offload"])
func aRingLikeLoadStallsInsteadOfFallingBack(_ young: String) throws {
    let r = try headless(ringFiles(ringIters), young: young, heapMiB: 16, slowdown: 16)
    #expect(r.checksum != nil && r.checksum == ringReference, "\(young): \(r.failure ?? "") \(r.summary)")
    #expect(r.n("fallbacks") == 0 && r.n("unjustifiedFallbacks") == 0, "\(young): \(r.summary)")
    #expect(r.n("stalls") > 0 && r.n("markerSlowSpins") > 0, "\(young): \(r.summary)")
}

/// Part 5: the marker 4 and 16 times slower. The claim is speed
/// independence: the oracle's checksum, no fallback where the live data
/// fits, the stalls counted (printed: at 4 the debug build's mutator may
/// not outrun the marker at all), the switch's slow path taken.
@Test(arguments: [4, 16], ["stw", "offload"])
func aSlowedMarkerPacesTheMutator(_ factor: Int, _ young: String) throws {
    let r = try headless(ringFiles(ringIters), young: young, heapMiB: 16, slowdown: factor)
    print("slowed marker x\(factor) \(young): \(r.summary)")
    #expect(r.checksum == ringReference, "x\(factor) \(young): \(r.failure ?? "") \(r.summary)")
    #expect(r.n("fallbacks") == 0 && r.n("unjustifiedFallbacks") == 0, "x\(factor) \(young): \(r.summary)")
    #expect(r.n("markerSlowSpins") > 0, "x\(factor) \(young): \(r.summary)")
}

// MARK: - a full heap, fragmentation, the main worker

/// Every background worker keeps everything it allocates: the live data
/// does not fit. A stall's fallback is justified by a completed cycle that
/// began after it (its record names the cycle), then module 4's
/// out-of-memory rule applies: the run fails, nothing is unjustified. It
/// ends by itself (no wall-clock bound).
@Test func aFullHeapFallsBackJustifiedThenRunsOutOfMemory() throws {
    let src = """
    method UndefinedObject run:of: temps=2
      push_nil
      store_temp 2
    loop:
      push_lit @Array
      push_int 14
      send new: 1
      store_temp 3
      push_temp 3
      push_int 1
      push_temp 2
      send at:put: 2
      pop
      push_temp 3
      store_temp 2
      jump loop
    end
    """
    let files = [("prelude.kasm", kernel("prelude")), ("lib.kasm", kernel("lib")), ("full.kasm", src)]
    for young in ["stw", "offload"] {
        let r = try headless(files, young: young, heapMiB: 12)
        #expect(r.failure?.contains("outOfMemory") == true || r.failure?.contains("out of memory") == true,
                "\(young): \(r.failure ?? "answered \(String(describing: r.checksum))")")
        #expect(r.n("unjustifiedFallbacks") == 0, "\(young): \(r.summary)")
        #expect(r.n("fallbacksByStall") >= 1, "\(young): \(r.summary)")
        // Each stall's record names what justified it: a cycle (`cycleN`), a
        // full collection that ran meanwhile, no cycle able to start, or
        // the cycle-start scavenge (`fallbackSummary`, field 3).
        for rec in (r.report["fallbackLog"] ?? "").split(separator: ",") where rec.contains("/stall/") {
            let f = rec.split(separator: "/")
            #expect(f.count > 3 && (f[3].hasPrefix("cycle") || ["full", "nostart", "start"].contains(String(f[3]))),
                    "\(young): \(rec)")
        }
    }
}

/// One object in twenty kept per block (fragment.kasm) on a heap too
/// small for its blocks without relocation: with relocation off the
/// justified fallbacks' records show the cycle's live bytes far below the
/// blocks in use (fragmentation, not a full heap); with relocation on, the
/// cycles that stalls wait on evacuate the sparse blocks and nothing falls
/// back.
@Test func fragmentationIsToldFromAFullHeap() throws {
    let off = try headless(ringFiles(ringIters), young: "offload", heapMiB: 16, slowdown: 16, reloc: "off")
    #expect(off.checksum == ringReference, "\(off.failure ?? "") \(off.summary)")
    #expect(off.n("unjustifiedFallbacks") == 0, "\(off.summary)")
    if off.n("fallbacks") > 0 {
        // Field 5 after the requester's four: the justifying cycle's marked
        // bytes over the blocks in use, percent (`fallbackSummary`): 52 to
        // 65 here, where a full heap reads 90 and more.
        for rec in (off.report["fallbackLog"] ?? "").split(separator: ",") where rec.contains("/stall/") {
            let f = rec.split(separator: "/")
            #expect(f.count > 5 && (Double(f[5]) ?? 100) < 80, "not fragmentation: \(rec)")
        }
    }
    let on = try headless(ringFiles(ringIters), young: "offload", heapMiB: 16, slowdown: 16, reloc: "on")
    #expect(on.checksum == ringReference, "\(on.failure ?? "") \(on.summary)")
    #expect(on.n("fallbacks") == 0 && on.n("unjustifiedFallbacks") == 0, "\(on.summary)")
    #expect(off.n("fallbacks") >= 1, "relocation off did not fall back: \(off.summary)")
}

private let mainChurnSource = kernel("fragment") + itersSource(underThreadSanitizer ? 100_000 : 400_000) + """
method UndefinedObject mainChurn temps=0
  push_nil
  push_int 0
  push_int 1
  send run:of: 2
  return_top
end
"""

/// The main worker alone outruns the collector (its Process main-affine,
/// the background workers idle): it never stalls, and its fallbacks (the
/// reserve's: a promotion that found no block) name the main worker; no
/// background stall is charged.
@Test func theMainWorkerNeverStallsAndItsFallbacksNameIt() throws {
    let rt = try Runtime(mainChurnSource, background: 2, heapBlocks: 640, configure: { c in
        c.nursery.bytes = 512 << 10
        c.marking.enabled = true
        c.marking.markerThread = true
        c.marking.testSwitches.markerSlowdown = 16
    })
    let p = rt.spawn("mainChurn", main: true)
    let end = now() + UInt64((underThreadSanitizer ? 900.0 : 180.0) * 1e9)
    while rt.vm.liveProcessCount > 0 && now() < end {
        if rt.vm.runMain(budgetNs: 2_000_000).slices == 0 { usleep(200) }
    }
    #expect(rt.vm.liveProcessCount == 0)
    _ = rt.vm.result(of: p)
    let c = rt.marking
    let s = rt.vm.stallLog
    #expect((s?.all.count ?? 1) == 0, "\(String(describing: s?.all))")
    #expect(c.unjustifiedFallbacks == 0 && c.fallbacksByStall == 0, "\(c)")
    #expect(c.fallbacks == c.fallbacksByMain, "\(c)")
    rt.vm.release(p)
    rt.stop(verifyHeap: false)
}

// MARK: - a stalled Process: terminate, interrupt, save

private let stalledSource = kernel("fragment") + itersSource(40_000_000) + snapshotSrc + """
method UndefinedObject ringLong temps=0
  push_nil
  push_int 0
  push_int 2
  send run:of: 2
  return_top
end
method UndefinedObject saver temps=0
  push_nil
  push_nil
  send snapshot: 1
  return_top
end
method Process stopForDebugger temps=0
  push_self
  return_top
end
"""

/// A runtime whose background workers stall soon: two rings (one per
/// background worker) on a 16 MiB heap, the marker 16 times slower, the
/// ring Processes started.
private func stallingRuntime() throws -> (Runtime, [Oop]) {
    let rt = try Runtime(stalledSource, background: 2, heapBlocks: 512, configure: { c in
        c.nursery.bytes = 512 << 10
        c.marking.enabled = true
        c.marking.markerThread = true
        // Under ThreadSanitizer the cycles a stall waits for are slow
        // enough at 4 (16 took the stall past the tests' bounds with load).
        c.marking.testSwitches.markerSlowdown = underThreadSanitizer ? 4 : 16
    })
    return (rt, [rt.spawn("ringLong"), rt.spawn("ringLong")])
}

private func waitStalled(_ rt: Runtime) -> Bool {
    eventually(underThreadSanitizer ? 600 : 120) { (rt.vm.stallLog?.stalledNow ?? 0) > 0 }
}

/// A Process stalled in its allocation's slow path is terminated: the
/// request lands at its first poll after the stall, which the collector's
/// progress ends; the termination completes.
@Test func aStalledProcessIsTerminated() throws {
    let (rt, ps) = try stallingRuntime()
    #expect(waitStalled(rt), "never stalled: \(String(describing: rt.vm.stallLog?.all))")
    for p in ps { rt.vm.terminate(p) }
    #expect(rt.waitAllTerminated(underThreadSanitizer ? 600 : 120))
    #expect(ps.allSatisfy { rt.state($0) == .terminated })
    #expect(rt.marking.unjustifiedFallbacks == 0)
    for p in ps { rt.vm.release(p) }
    rt.stop(verifyHeap: false)
}

/// Stalled Processes asked to stop for the debugger (primitive 155's
/// interrupt, what stepping uses) run the interrupt once their stall ends.
@Test func aStalledProcessTakesAnInterrupt() throws {
    let (rt, ps) = try stallingRuntime()
    #expect(waitStalled(rt))
    let i0 = rt.vm.counters[.interrupts]
    for p in ps { #expect(rt.vm.interruptProcess(p, kind: InterruptKind.debugStop)) }
    #expect(eventually(underThreadSanitizer ? 600 : 120) { rt.vm.counters[.interrupts] >= i0 + 2 })
    for p in ps { rt.vm.terminate(p) }
    #expect(rt.waitAllTerminated(underThreadSanitizer ? 600 : 120))
    for p in ps { rt.vm.release(p) }
    rt.stop(verifyHeap: false)
}

/// `Smalltalk snapshot:` from another Process while one stalls: the save's
/// hold waits for the stalled Process to leave its worker at a poll, which
/// it reaches when the collector ends the stall (the collector never waits
/// for the saver); the save completes and the image it wrote loads.
@Test func aSaveWaitsForAStallAndItsImageLoads() throws {
    let (rt, ps) = try stallingRuntime()
    #expect(waitStalled(rt))
    let saver = rt.spawn("saver")
    #expect(eventually(underThreadSanitizer ? 600 : 120) { rt.state(saver) == .terminated })
    let images = rt.vm.takeSavedImages()
    #expect(images.count == 1)
    for p in ps { rt.vm.terminate(p) }
    #expect(rt.waitAllTerminated(underThreadSanitizer ? 600 : 120))
    for p in ps + [saver] { rt.vm.release(p) }
    rt.stop(verifyHeap: false)
    if let bytes = images.first {
        let r = try Resumed(bytes, background: 1, heapBlocks: 4096, start: false)
        r.stop()
    }
}

// MARK: - idle after stalls

/// Workers that stalled and finished leave a VM that wakes no thread while
/// idle (every wait in the stall is untimed), and work after the idle
/// period completes.
@Test func aVMIdleAfterStallsWakesNoThread() throws {
    let src = kernel("fragment") + itersSource(underThreadSanitizer ? 100_000 : 300_000) + """
    method UndefinedObject ringShort: temps=0
      push_nil
      push_temp 0
      push_int 2
      send run:of: 2
      return_top
    end
    """
    // Under ThreadSanitizer a third of the iterations on a heap a quarter
    // smaller: old space still reaches its limit.
    let rt = try Runtime(src, background: 2, heapBlocks: underThreadSanitizer ? 384 : 512, configure: { c in
        c.nursery.bytes = 512 << 10
        c.marking.enabled = true
        c.marking.markerThread = true
        c.marking.testSwitches.markerSlowdown = 16
    })
    let ps = (0..<2).map { rt.spawn("ringShort:", [int(Int64($0))]) }
    #expect(rt.waitAllTerminated(underThreadSanitizer ? 900 : 300))
    #expect((rt.vm.stallLog?.all.count ?? 0) > 0, "no stall: \(String(describing: rt.vm.stallLog?.all))")
    // The collector finishes the cycles the run started, then idles.
    _ = eventually(underThreadSanitizer ? 600 : 120) { rt.phase == .idle }
    usleep(200_000)
    let m0 = rt.marking.markerWaits, i0 = rt.vm.counters.idleWakeups, y0 = rt.vm.youngCounters.collectorWakeups
    usleep(1_000_000)
    let m = rt.marking.markerWaits &- m0, i = rt.vm.counters.idleWakeups &- i0, y = rt.vm.youngCounters.collectorWakeups &- y0
    #expect(m <= 5 && i <= 5 && y <= 5, "woke in 1 s idle: marker \(m), workers \(i), young collector \(y)")
    let q = rt.spawn("ringShort:", [int(0)])
    #expect(rt.waitAllTerminated(underThreadSanitizer ? 900 : 300))
    #expect(rt.state(q) == .terminated)
    for p in ps + [q] { rt.vm.release(p) }
    #expect(rt.marking.unjustifiedFallbacks == 0)
    rt.stop()
}

// MARK: - broken variants

private let fullSource = """
method UndefinedObject keepAll temps=2
  push_nil
  store_temp 0
loop:
  push_lit @Array
  push_int 14
  send new: 1
  store_temp 1
  push_temp 1
  push_int 1
  push_temp 0
  send at:put: 2
  pop
  push_temp 1
  store_temp 0
  jump loop
end
"""

/// Two background workers keep everything until the heap is full; with the
/// broken variant the running cycle justifies a stall's fallback, which the
/// fallback's own check finds unjustified. Unchecked (a full heap's many
/// full collections under every verifier take minutes in a debug build);
/// the checked build's verifier on an unjustified fallback is the entry
/// gate's test below.
private func fullHeapUnjustified(broken: Bool) throws -> (UInt64, UInt64) {
    let rt = try Runtime(fullSource, background: 2, heapBlocks: underThreadSanitizer ? 160 : 320, verify: false, configure: { c in
        c.nursery.bytes = 512 << 10
        c.marking.enabled = true
        c.marking.markerThread = true
        c.marking.testSwitches.stallJustifiedByRunningCycle = broken
    })
    let ps = (0..<2).map { _ in rt.spawn("keepAll") }
    #expect(rt.waitAllTerminated(underThreadSanitizer ? 900 : 300))
    let c = rt.marking
    for p in ps { rt.vm.release(p) }
    let v = rt.vm.counters[.unjustifiedFallbacks]
    rt.stop(verifyHeap: false)
    return (c.unjustifiedFallbacks, v)
}

@Test func theRunningCycleDoesNotJustifyAFallback() throws {
    let (u, v) = try fullHeapUnjustified(broken: false)
    #expect(u == 0 && v == 0)
    let (bu, _) = try fullHeapUnjustified(broken: true)
    #expect(bu >= 1, "broken variant: unjustified \(bu)")
}

/// The entry table runs out under the ring (a table of 160 000 entries);
/// with the broken variant the stall's gate ignores the table and the
/// allocation falls back with no justifying cycle: unjustified.
private func entriesGate(broken: Bool) throws -> (MarkingCounters, StallLog?, UInt64) {
    let src = kernel("fragment") + itersSource(underThreadSanitizer ? 150_000 : 400_000) + """
    method UndefinedObject ringShort: temps=0
      push_nil
      push_temp 0
      push_int 2
      send run:of: 2
      return_top
    end
    """
    // A table of 100 000 (two rings keep about 70 000 entries) and the
    // marker 16 times slower: it runs out in every run (at 160 000 and 4
    // times slower some runs never ran out); fewer iterations under
    // ThreadSanitizer.
    let rt = try Runtime(src, background: 2, heapBlocks: 4096, entries: 100_000, configure: { c in
        c.nursery.bytes = 512 << 10
        c.marking.enabled = true
        c.marking.markerThread = true
        c.marking.testSwitches.markerSlowdown = 16
        c.marking.testSwitches.stallIgnoresEntries = broken
    })
    let ps = (0..<2).map { rt.spawn("ringShort:", [int(Int64($0))]) }
    // What must have happened, not the run's end (the sanitized suite
    // with twelve busy loops ran this past 900 s): an entry stall, or with
    // the broken variant an unjustified fallback; then the rings end.
    let seen = eventually(underThreadSanitizer ? 1800 : 300) {
        rt.vm.liveProcessCount == 0
            || (broken ? rt.vm.counters[.unjustifiedFallbacks] > 0 : (rt.vm.stallLog?.entries.count ?? 0) > 0)
    }
    #expect(seen)
    for p in ps { rt.vm.terminate(p) }
    #expect(rt.waitAllTerminated(underThreadSanitizer ? 1800 : 300))
    let c = rt.marking, s = rt.vm.stallLog, v = rt.vm.counters[.unjustifiedFallbacks]
    for p in ps { rt.vm.release(p) }
    rt.stop(verifyHeap: false)
    return (c, s, v)
}

@Test func anEntryStallGateThatIgnoresTheTableFallsBackUnjustified() throws {
    let (c, s, v) = try entriesGate(broken: false)
    #expect((s?.entries.count ?? 0) > 0 && c.unjustifiedFallbacks == 0 && v == 0, "\(String(describing: s?.entries)) \(c)")
    let (bc, _, bv) = try entriesGate(broken: true)
    #expect(bc.unjustifiedFallbacks >= 1 && bv >= 1, "broken variant: \(bc)")
}
