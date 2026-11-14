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
    let endBody = bodyTimer("aRingLikeLoadStallsInsteadOfFallingBack \(young)")
    defer { endBody() }
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
    let endBody = bodyTimer("aSlowedMarkerPacesTheMutator \(factor) \(young)")
    defer { endBody() }
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
    let endBody = bodyTimer("aFullHeapFallsBackJustifiedThenRunsOutOfMemory")
    defer { endBody() }
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
    let endBody = bodyTimer("fragmentationIsToldFromAFullHeap")
    defer { endBody() }
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
    let endBody = bodyTimer("theMainWorkerNeverStallsAndItsFallbacksNameIt")
    defer { endBody() }
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
/// ring Processes started. The tests make their request while the workers
/// stall and then set the marker to full speed (`StallDiag.unslow`): the
/// slowdown is CPU-proportional, and in a loaded suite the marker's share
/// of a core made a slowed cycle 45 to 70 s and a stall's two cycles race
/// the 120 s waits (docs/modules/allocation-stalls.md, "The stall tests in
/// a dense suite"). The waits after the request end on the collector's
/// progress (`StallDiag.waitProgress`): under ThreadSanitizer with the
/// twelve loops the interrupts' wait took up to 322 s of a 600 s bound even
/// with the marker at full speed (full collections of 20 to 30 s).
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

private func waitStalled(_ rt: Runtime, _ d: StallDiag? = nil) -> Bool {
    if let d { return d.wait("stalled", underThreadSanitizer ? 600 : 120) { (rt.vm.stallLog?.stalledNow ?? 0) > 0 } }
    return eventually(underThreadSanitizer ? 600 : 120) { (rt.vm.stallLog?.stalledNow ?? 0) > 0 }
}

// MARK: - diagnostics (the stall tests in a dense suite)

/// A test's body time, printed at its end (`stall-diag body <test> s=`):
/// Swift Testing's own per-test time in a loaded bundle includes the wait
/// for a thread of the cooperative pool.
func bodyTimer(_ name: String) -> () -> Void {
    let t0 = now()
    return { print("stall-diag body \(name) s=\(String(format: "%.1f", Double(now() &- t0) / 1e9))") }
}

/// Seconds since this process started (kinfo_proc's start time).
func processAgeSeconds() -> Double {
    var kp = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0 else { return -1 }
    let st = kp.kp_proc.p_starttime
    var tv = timeval()
    gettimeofday(&tv, nil)
    return Double(tv.tv_sec - st.tv_sec) + Double(tv.tv_usec - st.tv_usec) / 1e6
}

/// The process's threads and CPU so far (proc_pidinfo PROC_PIDTASKINFO).
private func processTask() -> (threads: Int32, cpuS: Double) {
    var ti = proc_taskinfo()
    let n = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.size))
    guard n == Int32(MemoryLayout<proc_taskinfo>.size) else { return (-1, -1) }
    return (ti.pti_threadnum, Double(ti.pti_total_user + ti.pti_total_system) / 1e9)
}

/// A stall test explaining itself: at each wait, a line every 5 s with the
/// marker thread's CPU and priorities, the phase and cycle, the stalls in
/// progress, the workers' CPU and the process's density; every 30 s and at
/// the wait's end the cycle records, the marking counters and the stops by
/// kind. Printed as `stall-diag <test> ...` lines (the suite's output).
final class StallDiag {
    let rt: Runtime
    let name: String
    let t0 = now()
    var lastMarkerCpu: UInt64 = 0
    var lastWall: UInt64 = 0
    /// Stops this object took itself (inspections), left out of `progress`.
    var ownStops: UInt64 = 0
    var lastMarkingRead: UInt64 = 0
    var lastMarking = MarkingCounters()

    init(_ rt: Runtime, _ name: String) {
        self.rt = rt
        self.name = name
        print("stall-diag \(name) begin age=\(String(format: "%.1f", processAgeSeconds()))")
    }

    func line(_ label: String) -> String {
        let t = Double(now() &- t0) / 1e9
        let ms = rt.vm.markerThreadSample
        let s = rt.vm.stallsNow
        let w = rt.vm.workerCPUNanoseconds().map { String(format: "%.2f", Double($0) / 1e9) }.joined(separator: "/")
        let task = processTask()
        var la = [Double](repeating: 0, count: 3)
        getloadavg(&la, 3)
        var share = "-"
        if let ms {
            let wall = now()
            if lastWall != 0 && wall > lastWall {
                share = String(format: "%.3f", Double(ms.cpuNs &- lastMarkerCpu) / Double(wall &- lastWall))
            }
            lastMarkerCpu = ms.cpuNs
            lastWall = wall
        }
        let marker = ms.map { "markerCpu=\(String(format: "%.3f", Double($0.cpuNs) / 1e9)) markerShare=\(share) curpri=\($0.curpri) basepri=\($0.basepri) run=\($0.runState) qosSet=\(String($0.qos, radix: 16))" } ?? "marker=-"
        return "stall-diag \(name) \(label) t=\(String(format: "%.1f", t)) age=\(String(format: "%.1f", processAgeSeconds())) "
            + "phase=\(rt.phase) cycle=\(rt.vm.markingCycleNow) "
            + "stalledNow=\(s?.stalledNow ?? -1) stalls=\(s?.count ?? 0) overrides=\(s?.overrides ?? 0) started=\(s?.cyclesStarted ?? 0) "
            + "interrupts=\(rt.vm.counters[.interrupts]) live=\(rt.vm.liveProcessCount) \(marker) workersCpu=\(w) "
            + "threads=\(task.threads) procCpu=\(String(format: "%.0f", task.cpuS)) load=\(String(format: "%.1f", la[0]))"
    }

    /// The marking counters (one inspection stop), at most once a second.
    func markingNow() -> MarkingCounters {
        let t = now()
        if t &- lastMarkingRead >= 1_000_000_000 {
            lastMarking = rt.marking
            ownStops &+= 1
            lastMarkingRead = t
        }
        return lastMarking
    }

    func full(_ label: String) -> String {
        ownStops &+= 2  // the counters and the cycle log
        let c = rt.marking
        let stops = rt.vm.stops
        return line(label) + "\n  stall-diag \(name) counters cycles=\(c.cycles) completed=\(c.cyclesCompleted) applies=\(c.applies) "
            + "fallbacks=\(c.fallbacks) unjustified=\(c.unjustifiedFallbacks) slowSpins=\(c.markerSlowSpins) "
            + "slowSpinS=\(String(format: "%.2f", Double(c.markerSlowSpinNs) / 1e9)) escalations=\(c.qosEscalations) "
            + "lowerings=\(c.qosLowerings) markerWaits=\(c.markerWaits)"
            + "\n  stall-diag \(name) stops n=\(stops.count) \(stopsByKind(stops, workerCount: rt.vm.config.backgroundWorkers + 2))"
            + "\n  stall-diag \(name) stopTotals \(stopTotals(stops))"
            + "\n  stall-diag \(name) cycleRecs \(cycleRecordSummary(rt.vm.cycleLog))"
    }

    /// Each stop kind's count and summed pause and time to safepoint, in
    /// seconds: where a test's wall time went.
    func stopTotals(_ stops: [StopRecord]) -> String {
        var by: [String: (n: Int, pause: UInt64, ttsp: UInt64)] = [:]
        for st in stops {
            var e = by["\(st.kind)"] ?? (0, 0, 0)
            e.n += 1
            e.pause &+= st.pauseNs
            e.ttsp &+= st.timeToSafepointNs
            by["\(st.kind)"] = e
        }
        return by.keys.sorted().map { k in
            let e = by[k]!
            return "\(k):\(e.n)/\(String(format: "%.1f", Double(e.pause) / 1e9))/\(String(format: "%.1f", Double(e.ttsp) / 1e9))"
        }.joined(separator: ",")
    }

    /// The collector's own count of what it has done, read without a stop:
    /// stops (scavenges, full collections, marks, applies), cycles begun,
    /// stalls ended.
    func progress() -> [UInt64] {
        [rt.vm.counters[.stops] &- ownStops, rt.vm.markingCycleNow, rt.vm.stallsNow?.count ?? 0]
    }

    /// Wait for `cond` with no clock on the work itself: the wait fails only
    /// when the collector has counted nothing (no stop, no cycle, no stall;
    /// `progress`) for `quiet` seconds. Reports as `wait`; inspection stops
    /// only at the end, so the reporting adds nothing to the count.
    func waitProgress(_ label: String, quiet: Double, _ cond: () -> Bool) -> Bool {
        let w0 = now()
        var last = progress(), lastChange = w0
        var nextLine = w0 + 10_000_000_000
        print(line("\(label)-start"))
        var ok = false
        while true {
            if cond() { ok = true; break }
            let t = now()
            let p = progress()
            if p != last { last = p; lastChange = t }
            if t &- lastChange > UInt64(quiet * 1e9) { break }
            if t >= nextLine { print(line(label) + " progress=\(p.map(String.init).joined(separator: "/"))"); nextLine = t + 10_000_000_000 }
            usleep(500)
        }
        if !ok { ok = cond() }
        let quietS = Double(now() &- lastChange) / 1e9
        print(full("\(label)-\(ok ? "ok" : "QUIET") waited=\(String(format: "%.1f", Double(now() &- w0) / 1e9)) quiet=\(String(format: "%.1f", quietS))"))
        return ok
    }

    /// `eventually`, reporting: the same bound and condition.
    /// The marker at full speed from here: the slowed marker has done its
    /// part (the workers stall, the request was made while they did); the
    /// stall now ends by an unslowed cycle (docs/modules/allocation-stalls.md,
    /// "The stall tests in a dense suite").
    func unslow() {
        print(line("unslow"))
        rt.vm.setMarkerSlowdown(1)
    }

    /// The test's end: its body's own time.
    func end() { print("stall-diag \(name) end body=\(String(format: "%.1f", Double(now() &- t0) / 1e9)) age=\(String(format: "%.1f", processAgeSeconds()))") }

    func wait(_ label: String, _ seconds: Double, _ cond: () -> Bool) -> Bool {
        let w0 = now()
        let end = w0 + UInt64(seconds * 1e9)
        var nextLine = w0 + 5_000_000_000, nextFull = w0 + 30_000_000_000
        print(line("\(label)-start"))
        var ok = false
        while now() < end {
            if cond() { ok = true; break }
            let t = now()
            if t >= nextFull { print(full(label)); nextFull = t + 30_000_000_000; nextLine = t + 5_000_000_000 }
            else if t >= nextLine { print(line(label)); nextLine = t + 5_000_000_000 }
            usleep(500)
        }
        if !ok { ok = cond() }
        print(full("\(label)-\(ok ? "ok" : "TIMEOUT") waited=\(String(format: "%.1f", Double(now() &- w0) / 1e9))"))
        return ok
    }
}

/// A Process stalled in its allocation's slow path is terminated: the
/// request lands at its first poll after the stall, which the collector's
/// progress ends; the termination completes.
@Test func aStalledProcessIsTerminated() throws {
    let endBody = bodyTimer("aStalledProcessIsTerminated")
    defer { endBody() }
    let (rt, ps) = try stallingRuntime()
    let d = StallDiag(rt, "terminated")
    #expect(waitStalled(rt, d), "never stalled: \(String(describing: rt.vm.stallLog?.all))")
    for p in ps { rt.vm.terminate(p) }
    d.unslow()
    #expect(d.waitProgress("terminated", quiet: underThreadSanitizer ? 600 : 120) { rt.vm.liveProcessCount == 0 }, "\(d.full("fail"))")
    #expect(ps.allSatisfy { rt.state($0) == .terminated })
    #expect(rt.marking.unjustifiedFallbacks == 0)
    for p in ps { rt.vm.release(p) }
    rt.stop(verifyHeap: false)
    d.end()
}

/// Stalled Processes asked to stop for the debugger (primitive 155's
/// interrupt, what stepping uses) run the interrupt once their stall ends.
@Test func aStalledProcessTakesAnInterrupt() throws {
    let endBody = bodyTimer("aStalledProcessTakesAnInterrupt")
    defer { endBody() }
    let (rt, ps) = try stallingRuntime()
    let d = StallDiag(rt, "interrupt")
    #expect(waitStalled(rt, d))
    let i0 = rt.vm.counters[.interrupts]
    for p in ps { #expect(rt.vm.interruptProcess(p, kind: InterruptKind.debugStop)) }
    d.unslow()
    #expect(d.waitProgress("interrupts", quiet: underThreadSanitizer ? 600 : 120) { rt.vm.counters[.interrupts] >= i0 + 2 }, "\(d.full("fail"))")
    for p in ps { rt.vm.terminate(p) }
    #expect(d.waitProgress("terminated", quiet: underThreadSanitizer ? 600 : 120) { rt.vm.liveProcessCount == 0 }, "\(d.full("fail"))")
    for p in ps { rt.vm.release(p) }
    rt.stop(verifyHeap: false)
    d.end()
}

/// `Smalltalk snapshot:` from another Process while one stalls: the save's
/// hold waits for the stalled Process to leave its worker at a poll, which
/// it reaches when the collector ends the stall (the collector never waits
/// for the saver); the save completes and the image it wrote loads.
@Test func aSaveWaitsForAStallAndItsImageLoads() throws {
    let endBody = bodyTimer("aSaveWaitsForAStallAndItsImageLoads")
    defer { endBody() }
    let (rt, ps) = try stallingRuntime()
    let d = StallDiag(rt, "save")
    #expect(waitStalled(rt, d))
    let saver = rt.spawn("saver")
    d.unslow()
    #expect(d.waitProgress("saved", quiet: underThreadSanitizer ? 600 : 120) { rt.state(saver) == .terminated }, "\(d.full("fail"))")
    let images = rt.vm.takeSavedImages()
    #expect(images.count == 1)
    for p in ps { rt.vm.terminate(p) }
    #expect(d.waitProgress("terminated", quiet: underThreadSanitizer ? 600 : 120) { rt.vm.liveProcessCount == 0 }, "\(d.full("fail"))")
    for p in ps + [saver] { rt.vm.release(p) }
    rt.stop(verifyHeap: false)
    d.end()
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
    let endBody = bodyTimer("aVMIdleAfterStallsWakesNoThread")
    defer { endBody() }
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
    let d = StallDiag(rt, "idle")
    // The slowed marker makes the stalls; once one has happened the rings
    // finish with the marker at full speed, and the wait for them is on
    // the collector's progress, not a clock (a slowed run to the end took
    // 455 to 655 s of this body under ThreadSanitizer with the twelve
    // loops, against the 900 s bound).
    let quiet: Double = underThreadSanitizer ? 600 : 120
    #expect(d.wait("stalled", underThreadSanitizer ? 600 : 120) {
        (rt.vm.stallLog.map { $0.stalledNow > 0 || $0.all.count > 0 } ?? false) || rt.vm.liveProcessCount == 0
    },
            "\(d.full("fail"))")
    d.unslow()
    #expect(d.waitProgress("rings", quiet: quiet) { rt.vm.liveProcessCount == 0 }, "\(d.full("fail"))")
    #expect((rt.vm.stallLog?.all.count ?? 0) > 0, "no stall: \(String(describing: rt.vm.stallLog?.all))")
    // The collector finishes the cycles the run started, then idles.
    _ = d.wait("idle", underThreadSanitizer ? 600 : 120) { rt.phase == .idle }
    usleep(200_000)
    let m0 = rt.marking.markerWaits, i0 = rt.vm.counters.idleWakeups, y0 = rt.vm.youngCounters.collectorWakeups
    usleep(1_000_000)
    let m = rt.marking.markerWaits &- m0, i = rt.vm.counters.idleWakeups &- i0, y = rt.vm.youngCounters.collectorWakeups &- y0
    #expect(m <= 5 && i <= 5 && y <= 5, "woke in 1 s idle: marker \(m), workers \(i), young collector \(y)")
    let q = rt.spawn("ringShort:", [int(0)])
    #expect(d.waitProgress("ringAfterIdle", quiet: quiet) { rt.vm.liveProcessCount == 0 }, "\(d.full("fail"))")
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
///
/// The run stops at what the claim needs, not at the out-of-memory answer
/// (`aFullHeapFallsBackJustifiedThenRunsOutOfMemory` has that): the first
/// `fullHeapStalls` justified stalls, each one's fallback checked as it
/// runs, in both runs: none unjustified with the rule, at least one with
/// the broken variant (in every measured run all of them were; the broken
/// run also ends at its first unjustified fallback, read once a second). Run
/// to the end, a full heap took 41 to 58 full collections and 515 to 824 s
/// under ThreadSanitizer with the twelve loops, against a 900 s bound. No
/// wait races a clock: each ends when it is met or when the collector has
/// counted nothing for the quiet bound (`StallDiag.waitProgress`).
private let fullHeapStalls: UInt64 = 4

private func fullHeapUnjustified(broken: Bool) throws -> (MarkingCounters, UInt64, StallTally) {
    let rt = try Runtime(fullSource, background: 2, heapBlocks: underThreadSanitizer ? 160 : 320, verify: false, configure: { c in
        c.nursery.bytes = 512 << 10
        c.marking.enabled = true
        c.marking.markerThread = true
        c.marking.testSwitches.stallJustifiedByRunningCycle = broken
    })
    let ps = (0..<2).map { _ in rt.spawn("keepAll") }
    let d = StallDiag(rt, broken ? "fullHeapBroken" : "fullHeap")
    let quiet: Double = underThreadSanitizer ? 600 : 120
    // Each justified stall's worker runs its fallback before its next
    // poll, so once the Processes have terminated every such fallback has
    // been checked and counted (the VM-wide counter only in a checked
    // build; the marking log's in every build, read after the run).
    let seen = d.waitProgress("seen", quiet: quiet) {
        rt.vm.liveProcessCount == 0 || (rt.vm.stallLog?.all.justified ?? 0) >= fullHeapStalls
            || (broken && d.markingNow().unjustifiedFallbacks > 0)
    }
    #expect(seen, "\(d.full("fail"))")
    for p in ps { rt.vm.terminate(p) }
    #expect(d.waitProgress("terminated", quiet: quiet) { rt.vm.liveProcessCount == 0 }, "\(d.full("fail"))")
    d.end()
    let c = rt.marking
    let tally = rt.vm.stallLog?.all ?? StallTally()
    for p in ps { rt.vm.release(p) }
    let v = rt.vm.counters[.unjustifiedFallbacks]
    rt.stop(verifyHeap: false)
    return (c, v, tally)
}

@Test func theRunningCycleDoesNotJustifyAFallback() throws {
    let endBody = bodyTimer("theRunningCycleDoesNotJustifyAFallback")
    defer { endBody() }
    let (c, v, t) = try fullHeapUnjustified(broken: false)
    #expect(c.unjustifiedFallbacks == 0 && v == 0, "\(c)")
    // The claim is about fallbacks that stalls led to: there were some.
    #expect(t.justified >= 1 && c.fallbacksByStall >= 1, "no justified stall's fallback: \(t) \(c)")
    let (bc, _, _) = try fullHeapUnjustified(broken: true)
    #expect(bc.unjustifiedFallbacks >= 1, "broken variant: unjustified \(bc.unjustifiedFallbacks)")
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
    let endBody = bodyTimer("anEntryStallGateThatIgnoresTheTableFallsBackUnjustified")
    defer { endBody() }
    let (c, s, v) = try entriesGate(broken: false)
    #expect((s?.entries.count ?? 0) > 0 && c.unjustifiedFallbacks == 0 && v == 0, "\(String(describing: s?.entries)) \(c)")
    let (bc, _, bv) = try entriesGate(broken: true)
    #expect(bc.unjustifiedFallbacks >= 1 && bv >= 1, "broken variant: \(bc)")
}
