// Workers and threads around an Image, and the headless kernel runner
// (SPEC.md "Workers", "Kernels").

import Darwin
import Kasm

private struct ThreadCtx {
    var vm: VMRef
    var w: WorkerRef
}

private func threadMain(_ arg: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
    let ctx = arg.assumingMemoryBound(to: ThreadCtx.self)
    backgroundLoop(ctx.pointee.vm, ctx.pointee.w)
    return nil
}

/// A VM with its workers: worker 0 is the main worker (driven by the shell
/// through `runMain`), workers 1...n are background pthreads, the last one is
/// the host's (used by `spawn` and friends from the host thread).
public final class Runtime {
    public let img: Image
    public var vm: VMRef { img.vm }
    public let background: Int
    public let workers: [WorkerRef]
    private var threads: [pthread_t] = []
    private var markerThreads: [pthread_t] = []
    private var ctxs: UnsafeMutablePointer<ThreadCtx>

    /// `config`: the collector configuration; nil reads the environment
    /// (SPEC.md "Package shape"). `verify` turns on every verifier.
    public init(_ img: Image, background: Int, pollEvery: Int? = nil, sliceMs: Double? = nil, start: Bool = true,
                verify: Bool = false, config: CMConfig? = nil) {
        self.img = img
        self.background = background
        let vm = img.vm
        var cfg = config ?? cmConfigFromEnv()
        let v = getenv("KAJO_VERIFY").map { String(cString: $0) } ?? ""
        if verify || v == "cm" || v == "all" { cfg.verify = true }
        vm.pointee.verify = verify || v == "all"
        #if NO_MARK_BARRIER
        if cfg.concurrent && img.vm.pointee.heap.nurseryBytes > 0 { fatal("NO_MARK_BARRIER build: concurrent marking unavailable (KAJO_GC=stw)") }
        #endif
        vm.pointee.cmConfig = cfg
        if let n = pollEvery ?? envInt("KAJO_POLL_N") { vm.pointee.pollEvery = max(1, n) }
        if let s = sliceMs ?? envDouble("KAJO_SLICE_MS") { vm.pointee.sliceNs = UInt64(s * 1e6) }
        vm.pointee.verboseGC = getenv("KAJO_VERBOSE_GC") != nil
        var ws = [Worker.create(id: 0, nilObj: vm.pointee.nilObj, main: true)]
        for i in 1...max(background, 1) where i <= background {
            ws.append(Worker.create(id: i, nilObj: vm.pointee.nilObj))
        }
        ws.append(Worker.create(id: ws.count, nilObj: vm.pointee.nilObj))
        workers = ws
        setWorkers(vm, ws)
        // Global 1: the event Semaphore (a permanent root).
        vm.pointee.globals[0] = hostNewSemaphore(vm)
        ctxs = .allocate(capacity: max(background, 1))
        if start { self.start() }
    }

    /// Start the background worker threads and the marker threads (once).
    public func start() {
        if !threads.isEmpty { return }
        let cfg = vm.pointee.cmConfig
        if cfg.concurrent && !cfg.manual && vm.pointee.heap.nurseryBytes > 0 && markerThreads.isEmpty {
            markerThreads = startMarkers(vm, max(1, min(2, cfg.markers)))
        }
        for i in 0..<background {
            (ctxs + i).initialize(to: ThreadCtx(vm: vm, w: workers[1 + i]))
            var tid: pthread_t? = nil
            if pthread_create(&tid, nil, threadMain, UnsafeMutableRawPointer(ctxs + i)) != 0 { fatal("pthread_create") }
            threads.append(tid!)
        }
    }

    public var mainWorker: WorkerRef { workers[0] }

    public func symbol(_ name: String) -> Oop {
        guard let s = img.symbol(name) else { fatal("no symbol \(name)") }
        return s
    }

    /// Stop and join the background workers, then the markers.
    public func stop() {
        shutdownWorkers(vm)
        for t in threads { pthread_join(t, nil) }
        threads = []
        if !markerThreads.isEmpty { stopMarkers(vm, markerThreads); markerThreads = [] }
    }
}

/// `KAJO_GC`, `KAJO_CM_THRESHOLD`, `KAJO_CM_MARKERS`, `KAJO_CM_FORCE`.
public func cmConfigFromEnv() -> CMConfig {
    var c = CMConfig()
    if let g = getenv("KAJO_GC").map({ String(cString: $0) }) {
        if g == "stw" { c.concurrent = false } else if g == "cm" { c.concurrent = true } else { fatal("KAJO_GC=\(g)?") }
    }
    if let t = envDouble("KAJO_CM_THRESHOLD") { c.threshold = t / 100 }
    if let m = envInt("KAJO_CM_MARKERS") { c.markers = m }
    if envInt("KAJO_CM_FORCE") == 1 { c.force = true; c.threshold = 0 }
    return c
}

public func envInt(_ name: String) -> Int? { getenv(name).flatMap { Int(String(cString: $0)) } }
public func envDouble(_ name: String) -> Double? { getenv(name).flatMap { Double(String(cString: $0)) } }

public struct RunResult {
    public var checksum: Int64
    public var results: [Int64]
    public var ms: Double
}

/// Fork `n` Processes `nil kernel: i * 256 + n` (lib.kasm unpacks it into
/// `run: i of: n`) on `n` background workers; wall time from the first fork
/// to the last termination.
public func runKernel(_ img: Image, workers n: Int) -> (RunResult, Runtime) {
    let rt = Runtime(img, background: n)
    let vm = rt.vm
    let sel = rt.symbol("kernel:")
    let t0 = now()
    vm.set(.kernelStartAt, t0)
    var ids: [Int64] = []
    for i in 0..<n {
        let p = spawn(vm, vm.pointee.nilObj, sel, mkInt(Int64(i * 256 + n)))
        ids.append(processId(vm, p))
    }
    waitAllTerminated(vm)
    let ms = Double(now() - t0) / 1e6
    rt.stop()
    var results: [Int64] = []
    for id in ids {
        let r = vm.pointee.results[Int(id)]
        if !isInt(r) { fatal("kernel returned a non-SmallInteger") }
        results.append(intVal(r))
    }
    return (RunResult(checksum: results.reduce(0, &+), results: results, ms: ms), rt)
}

/// Old space: `KAJO_HEAP_MB`, default 64 MiB (as in the earlier
/// experiments), or `2 N + 64` MiB for `oldheapN` (SPEC.md "Kernels").
public func loadKernel(_ kernel: String) throws -> Image {
    let def = oldheapMB(kernel).map { 2 * $0 + 64 } ?? 64
    return try Image.fromSources(try kernelSources(kernel), heapSize: (envInt("KAJO_HEAP_MB") ?? def) << 20)
}

/// Append one line per pause to `KAJO_GC_DUMP`, prefixed by `KAJO_TAG`.
public func dumpPauses(_ vm: VMRef, prefix: String, from: Int = 0) {
    guard let path = getenv("KAJO_GC_DUMP").map({ String(cString: $0) }), let f = fopen(path, "a") else { return }
    let tag = getenv("KAJO_TAG").map { String(cString: $0) } ?? ""
    let recs = vm.pointee.gcLog.pointee.records
    for r in recs[min(from, recs.count)...] {
        var l = "\(tag) \(prefix) kind=\(PauseKind.name(r.kind)) total=\(r.totalNs) ttsp=\(r.ttspNs) coord=\(r.coordNs)"
        l += " apply=\(r.applyNs) snap=\(r.snapNs) cmroots=\(r.cmRootsNs) rootwords=\(r.cmRootWords) greyed=\(r.greyed) scavpart=\(r.scavNs)"
        l += " drain=\(r.drainNs) drainent=\(r.drainEntries) drainobj=\(r.drainObjects) filter=\(r.filterNs) filtered=\(r.filtered) verify=\(r.verifyNs)"
        l += " roots=\(r.critRootsNs) rem=\(r.critRemNs) copy=\(r.critCopyNs) sweep=\(r.critSweepNs) mark=\(r.markNs) mssweep=\(r.msSweepNs)"
        l += " prep=\(r.prepNs) finish=\(r.finishNs) parts=\(r.participants) young=\(r.youngBytes) promoted=\(r.promotedBytes)"
        l += " remset=\(r.remSet) entalloc=\(r.entriesAllocated) entfreed=\(r.entriesFreed) busy=\(r.meanBusyNs)\n"
        fputs(l, f)
    }
    // One line per concurrent cycle that started in this window.
    let since = recs[min(from, recs.count)...].first?.atNs ?? UInt64.max
    for c in vm.pointee.cm.log.pointee.records where c.startNs >= since {
        var l = "\(tag) \(prefix) kind=cycle cycle=\(c.cycle) aborted=\(c.aborted ? 1 : 0) done=\(c.finalNs != 0 ? 1 : 0) applied=\(c.appliedNs != 0 ? 1 : 0)"
        l += " marking=\(c.finalNs != 0 ? c.finalNs &- c.startNs : 0) markcpu=\(c.markCpuNs) marked=\(c.markedBytes) markedobj=\(c.markedObjects)"
        l += " drainedobj=\(c.drainedObjects) promoted=\(c.promotedBytes) scavs=\(c.scavenges) satb=\(c.satbEntries) satbbuf=\(c.satbBuffers)"
        l += " sweepcpu=\(c.sweepCpuNs) sweepwall=\(c.sweepWallNs) toapply=\(c.appliedNs != 0 ? c.appliedNs &- c.finalNs : 0)"
        l += " oldstart=\(c.oldBlocksStart) oldfinal=\(c.oldBlocksFinal) oldafter=\(c.oldBlocksAfter) live=\(c.liveBytes) freed=\(c.freedBytes)"
        l += " freedent=\(c.freedEntries) freedblocks=\(c.freedBlocks) snapent=\(c.snapEntries) floating=\(c.floatingBytes) missed=\(c.missed)\n"
        fputs(l, f)
    }
    fclose(f)
}

func pctl(_ xs: [Double], _ p: Double) -> Double {
    if xs.isEmpty { return 0 }
    let s = xs.sorted()
    return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
}

private func ms(_ ns: UInt64) -> Double { Double(ns) / 1e6 }
/// Fixed-point formatting without Foundation.
public func fixed(_ x: Double, _ digits: Int) -> String {
    if !x.isFinite { return "nan" }
    var scale = 1.0
    for _ in 0..<digits { scale *= 10 }
    let v = Int64((abs(x) * scale).rounded())
    let ip = v / Int64(scale), fp = v % Int64(scale)
    var f = String(fp)
    while f.count < digits { f = "0" + f }
    return (x < 0 && v != 0 ? "-" : "") + String(ip) + (digits > 0 ? "." + f : "")
}
private func r3(_ x: Double) -> String { fixed(x, 3) }
private func r1(_ x: Double) -> String { fixed(x, 1) }

/// Collector summary as key=value pairs over the pause records from index
/// `from` (SPEC.md "Pause accounting"). Times in ms.
public func gcSummary(_ vm: VMRef, from: Int = 0) -> String {
    let all: [GCRecord] = vm.pointee.gcLog.pointee.records
    let recs: [GCRecord] = Array(all[min(from, all.count)...])
    let sc: [GCRecord] = recs.filter { $0.kind == PauseKind.scavenge || $0.kind == PauseKind.initial }
    let fu: [GCRecord] = recs.filter { $0.full }
    var o = "nursery_kb=\(vm.pointee.heap.nurseryBytes / 1024) scavenges=\(sc.count) fulls=\(fu.count)"
    func dist(_ name: String, _ xs: [Double]) {
        let p50 = r3(pctl(xs, 0.5)), p99 = r3(pctl(xs, 0.99)), mx = r3(xs.max() ?? 0)
        o += " \(name)_p50=\(p50) \(name)_p99=\(p99) \(name)_max=\(mx)"
    }
    func values(_ rs: [GCRecord], _ f: (GCRecord) -> UInt64) -> [Double] { rs.map { (r: GCRecord) -> Double in ms(f(r)) } }
    func total(_ rs: [GCRecord], _ f: (GCRecord) -> UInt64) -> Double {
        var t = 0.0
        for r in rs { t += Double(f(r)) }
        return t
    }
    if !sc.isEmpty {
        let n = Double(sc.count)
        dist("pause", values(sc) { $0.totalNs })
        dist("ttsp", values(sc) { $0.ttspNs })
        func med(_ f: (GCRecord) -> UInt64) -> String { r3(pctl(values(sc, f), 0.5)) }
        o += " brk_coord=" + med { $0.coordNs }
        o += " brk_roots=" + med { $0.critRootsNs }
        o += " brk_rem=" + med { $0.critRemNs }
        o += " brk_copy=" + med { $0.critCopyNs }
        o += " brk_sweep=" + med { $0.critSweepNs }
        o += " brk_ttsp=" + med { $0.ttspNs }
        o += " brk_prep=" + med { $0.prepNs }
        o += " brk_finish=" + med { $0.finishNs }
        o += " busy_mean=" + med { $0.meanBusyNs }
        o += " packets_per_scav=" + r1(total(sc) { $0.packets } / Double(sc.count))
        let tot = max(total(sc) { $0.totalNs }, 1)
        func share(_ f: (GCRecord) -> UInt64) -> String { r1(100 * total(sc, f) / tot) }
        o += " share_coord=" + share { $0.coordNs }
        o += " share_roots=" + share { $0.critRootsNs }
        o += " share_rem=" + share { $0.critRemNs }
        o += " share_copy=" + share { $0.critCopyNs }
        o += " share_sweep=" + share { $0.critSweepNs }
        let young = total(sc) { $0.youngBytes }
        let prom = total(sc) { $0.promotedBytes }
        let parts = total(sc) { UInt64($0.participants) }
        o += " parts_mean=" + r1(parts / n)
        o += " young_mb_per_scav=" + r3(young / n / 1048576)
        o += " promoted_mb=" + r3(prom / 1048576)
        o += " promoted_kb_per_scav=" + r3(prom / n / 1024)
        o += " survival_pct=" + fixed(100 * prom / max(young, 1), 2)
        o += " remset_mean=" + r1(total(sc) { $0.remSet } / n)
        o += " remset_max=" + String(sc.map { $0.remSet }.max() ?? 0)
        o += " remscanned_mean=" + fixed(total(sc) { $0.remScanned } / n, 0)
        dist("esweep", values(sc) { $0.critSweepNs })
        o += " ent_alloc_per_scav=" + fixed(total(sc) { $0.entriesAllocated } / n, 0)
        o += " ent_freed_per_scav=" + fixed(total(sc) { $0.entriesFreed } / n, 0)
    }
    if !fu.isEmpty {
        dist("full", values(fu) { $0.totalNs })
        o += " full_mark_p50=" + r3(pctl(values(fu) { $0.markNs }, 0.5))
        o += " full_sweep_p50=" + r3(pctl(values(fu) { $0.msSweepNs }, 0.5))
        o += " full_ttsp_max=" + r3(values(fu) { $0.ttspNs }.max() ?? 0)
    }
    o += " fallback_pauses=\(recs.filter { $0.kind == PauseKind.fallback }.count)"
    o += cmSummary(vm, recs)
    var wordTakes: UInt64 = 0, bits: UInt64 = 0, chunks: UInt64 = 0, fresh: UInt64 = 0, slow: UInt64 = 0
    for i in 0..<vm.pointee.workerCount {
        let w = worker(vm, i)
        wordTakes &+= w.pointee.ws.wordTakes
        bits &+= w.pointee.ws.bitsTaken
        chunks &+= w.pointee.ws.chunkTakes
        fresh &+= w.pointee.ws.chunkFresh
        slow &+= w.pointee.barrierSlow
    }
    o += " barrier_slow=\(slow) word_takes=\(wordTakes)"
    o += " bits_per_word=" + r1(Double(bits) / Double(max(wordTakes, 1)))
    o += " chunk_takes=\(chunks) chunk_fresh=\(fresh) table_hwm=\(chunkHwmNow(vm) * chunkEntries)"
    o += " old_mb=" + r3(Double(vm.pointee.heap.blocksInUse() * blockSize) / 1048576)
    return o
}

public func peakRSS() -> Int {
    var ru = rusage()
    getrusage(RUSAGE_SELF, &ru)
    return Int(ru.ru_maxrss) // bytes on Darwin
}

/// Current resident size in bytes (task_info), for S5's per-Process cost.
public func currentRSS() -> Int {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int(info.resident_size) : -1
}

/// One bench line (key=value pairs).
public func benchLine(kernel: String, workers: Int) throws -> String {
    let img = try loadKernel(kernel)
    let (r, rt) = runKernel(img, workers: workers)
    let vm = rt.vm
    #if NO_BARRIER
    let build = "nobarrier"
    #else
    let build = "barrier"
    #endif
    var line = "kernel=\(kernel) workers=\(workers) vm=\(build) pollN=\(vm.pointee.pollEvery) sliceMs=\(Double(vm.pointee.sliceNs) / 1e6)"
    line += " ms=\((r.ms * 10).rounded() / 10) checksum=\(r.checksum)"
    let slices = rt.workers.reduce(0) { $0 + $1.pointee.slices }
    line += " slices=\(slices) \(gcSummary(vm))"
    var satbSlow: UInt64 = 0, satbPushed: UInt64 = 0, handovers: UInt64 = 0
    for w in rt.workers { satbSlow &+= w.pointee.satbSlow; satbPushed &+= w.pointee.satbPushed; handovers &+= w.pointee.satbHandovers }
    line += " satb_slow=\(satbSlow) satb_pushed=\(satbPushed) satb_handovers=\(handovers)"
    if let mb = oldheapMB(kernel) {
        // Fixed work of oldheap.kasm: MB * 250 000 iterations, a rewire every
        // 8th, a 32 776-byte group replaced every 4096th.
        let iters = Double(mb * 250_000)
        let start = vm.metric(.kernelStartAt), built = vm.metric(.buildDoneAt)
        let endNs = start &+ UInt64(r.ms * 1e6)
        let mutS = Double(endNs &- built) / 1e9
        line += " live_target_mb=\(mb) build_ms=\(fixed(Double(built &- start) / 1e6, 1)) mutate_ms=\(fixed(mutS * 1000, 1))"
        line += " rewires_per_s=\(fixed(iters / 8 / mutS, 0)) replaced_mb_per_s=\(fixed((iters / 4096).rounded(.down) * 32776 / 1048576 / mutS, 1))"
    }
    dumpPauses(vm, prefix: "kernel=\(kernel) workers=\(workers) nursery_kb=\(vm.pointee.heap.nurseryBytes / 1024)")
    for m in Metric.allCases {
        let v = vm.metric(m)
        if v == 0 { continue }
        let name = "\(m)"
        line += name.hasSuffix("Ns") ? " \(name.dropLast(2))_ms=\(Double(v / 1000) / 1000)" : " \(name)=\(v)"
    }
    line += " rss_mb=\(peakRSS() >> 20)"
    return line
}

/// Concurrent-marking summary over pause records `recs` and the cycles that
/// started within them (SPEC.md "Headless matrix"). Times in ms.
func cmSummary(_ vm: VMRef, _ recs: [GCRecord]) -> String {
    let cfg = vm.pointee.cmConfig
    var o = " gc=\(cfg.concurrent ? "cm" : "stw") markers=\(cfg.markers) force=\(cfg.force ? 1 : 0)"
    o += " threshold_pct=\(Int((cfg.threshold * 100).rounded()))"
    guard cfg.concurrent else { return o }
    let since = recs.first?.atNs ?? 0
    let cycles = vm.pointee.cm.log.pointee.records.filter { $0.startNs >= since }
    let ini = recs.filter { $0.kind == PauseKind.initial }
    let fin = recs.filter { $0.kind == PauseKind.final }
    let fb = recs.filter { $0.kind == PauseKind.fallback }
    func ms(_ ns: UInt64) -> Double { Double(ns) / 1e6 }
    func dist(_ name: String, _ xs: [Double]) {
        o += " \(name)_p50=\(r3(pctl(xs, 0.5))) \(name)_p99=\(r3(pctl(xs, 0.99))) \(name)_max=\(r3(xs.max() ?? 0))"
    }
    let done = cycles.filter { !$0.aborted && $0.finalNs != 0 }
    let applied = done.filter { $0.appliedNs != 0 }
    o += " cycles=\(cycles.count) cycles_done=\(done.count) cycles_applied=\(applied.count) aborted=\(cycles.filter { $0.aborted }.count) fallbacks=\(fb.count)"
    dist("initial", ini.map { ms($0.totalNs) })
    dist("initial_mark", ini.map { ms($0.snapNs &+ $0.cmRootsNs) })
    o += " initial_snap_p50=\(r3(pctl(ini.map { ms($0.snapNs) }, 0.5))) initial_roots_p50=\(r3(pctl(ini.map { ms($0.cmRootsNs) }, 0.5)))"
    o += " initial_scav_p50=\(r3(pctl(ini.map { ms($0.scavNs) }, 0.5))) initial_ttsp_max=\(r3(ini.map { ms($0.ttspNs) }.max() ?? 0))"
    o += " initial_rootwords_p50=\(Int(pctl(ini.map { Double($0.cmRootWords) }, 0.5)))"
    dist("final", fin.map { ms($0.totalNs &- $0.verifyNs) })
    dist("final_drain", fin.map { ms($0.drainNs) })
    dist("final_ttsp", fin.map { ms($0.ttspNs) })
    o += " final_drainent_p50=\(Int(pctl(fin.map { Double($0.drainEntries) }, 0.5))) final_drainobj_max=\(fin.map { $0.drainObjects }.max() ?? 0)"
    o += " final_verify_max=\(r3(fin.map { ms($0.verifyNs) }.max() ?? 0))"
    let applies = recs.filter { $0.applyNs > 0 }
    o += " apply_p50=\(r3(pctl(applies.map { ms($0.applyNs) }, 0.5))) apply_max=\(r3(applies.map { ms($0.applyNs) }.max() ?? 0))"
    let durs = done.map { ms($0.finalNs &- $0.startNs) }
    dist("marking_ms", durs)
    let markCpu = done.reduce(0.0) { $0 + ms($1.markCpuNs) }
    let markedMB = done.reduce(0.0) { $0 + Double($1.markedBytes) / 1048576 }
    o += " mark_cpu_ms_total=\(r3(markCpu)) mark_cpu_ms_p50=\(r3(pctl(done.map { ms($0.markCpuNs) }, 0.5)))"
    o += " marked_mb_p50=\(r3(pctl(done.map { Double($0.markedBytes) / 1048576 }, 0.5)))"
    o += " marked_objs_p50=\(Int(pctl(done.map { Double($0.markedObjects) }, 0.5)))"
    o += " mark_mb_per_cpu_s=\(r1(markCpu > 0 ? markedMB / (markCpu / 1000) : 0))"
    o += " drained_objs_max=\(done.map { $0.drainedObjects }.max() ?? 0)"
    let sweepCpu = applied.reduce(0.0) { $0 + ms($1.sweepCpuNs) }
    o += " sweep_cpu_ms_total=\(r3(sweepCpu)) sweep_cpu_ms_p50=\(r3(pctl(applied.map { ms($0.sweepCpuNs) }, 0.5)))"
    o += " sweep_wall_ms_p50=\(r3(pctl(applied.map { ms($0.sweepWallNs) }, 0.5)))"
    o += " sweep_to_apply_ms_p50=\(r3(pctl(applied.map { ms($0.appliedNs &- $0.finalNs) }, 0.5)))"
    o += " satb_entries=\(done.reduce(0) { $0 + $1.satbEntries }) satb_buffers=\(done.reduce(0) { $0 + $1.satbBuffers })"
    o += " promoted_during_mb_p50=\(r3(pctl(done.map { Double($0.promotedBytes) / 1048576 }, 0.5)))"
    o += " promoted_during_mb_max=\(r3(done.map { Double($0.promotedBytes) / 1048576 }.max() ?? 0))"
    o += " scav_during_p50=\(Int(pctl(done.map { Double($0.scavenges) }, 0.5)))"
    let bmb = Double(blockSize) / 1048576
    o += " old_start_mb_p50=\(r1(pctl(done.map { Double($0.oldBlocksStart) * bmb }, 0.5)))"
    o += " old_final_mb_max=\(r1(done.map { Double($0.oldBlocksFinal) * bmb }.max() ?? 0))"
    o += " old_after_mb_p50=\(r1(pctl(applied.map { Double($0.oldBlocksAfter) * bmb }, 0.5)))"
    o += " live_mb_p50=\(r3(pctl(applied.map { Double($0.liveBytes) / 1048576 }, 0.5)))"
    o += " freed_mb_p50=\(r3(pctl(applied.map { Double($0.freedBytes) / 1048576 }, 0.5)))"
    o += " freed_blocks_p50=\(Int(pctl(applied.map { Double($0.freedBlocks) }, 0.5)))"
    o += " snap_entries_p50=\(Int(pctl(applied.map { Double($0.snapEntries) }, 0.5)))"
    o += " floating_mb_max=\(r3(done.map { Double($0.floatingBytes) / 1048576 }.max() ?? 0)) missed=\(done.reduce(0) { $0 + $1.missed })"
    let first = cycles.first?.startNs ?? 0, last = recs.last.map { $0.atNs &+ $0.totalNs } ?? 0
    let markingNs = cycles.reduce(0.0) { $0 + Double(($1.finalNs != 0 ? $1.finalNs : last) &- $1.startNs) }
    if last > since { o += " marking_pct=\(r1(100 * markingNs / Double(last &- since)))" }
    _ = first
    return o
}
