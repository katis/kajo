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
    private var collectorThread: pthread_t? = nil

    public init(_ img: Image, background: Int, pollEvery: Int? = nil, sliceMs: Double? = nil, start: Bool = true,
                verify: Bool = false, config: CMConfig? = nil, young: YCConfig? = nil) {
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
        #if NO_POST_STORE
        if cfg.relocThreshold > 0 { fatal("NO_POST_STORE build: relocation unavailable (KAJO_RELOC=off)") }
        #endif
        if cfg.relocThreshold > 0 && !cfg.concurrent { fatal("relocation needs concurrent marking (KAJO_GC=cm)") }
        vm.pointee.cmConfig = cfg
        var ycfg = young ?? ycConfigFromEnv()
        if (verify && young == nil) || v == "young" || v == "all" { ycfg.verifyYoung = true }
        if ycfg.mode != YoungMode.stw && (!cfg.concurrent || img.vm.pointee.heap.nurseryBytes == 0) {
            fatal("KAJO_YOUNG=\(YoungMode.name(ycfg.mode)) needs KAJO_GC=cm and a nursery")
        }
        vm.pointee.ycConfig = ycfg
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
        if vm.pointee.ycConfig.mode == YoungMode.offload && collectorThread == nil { collectorThread = startCollector(vm) }
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

    /// Tests: only the young collector thread (offload), workers stepped by
    /// the test.
    public func startCollectorOnly() {
        if vm.pointee.ycConfig.mode == YoungMode.offload && collectorThread == nil { collectorThread = startCollector(vm) }
    }

    public var mainWorker: WorkerRef { workers[0] }

    /// CPU time (user + system) of the marker threads so far, read from the
    /// kernel (tests: an idle marker must not spin; SPEC.md amendment 18).
    public func markerThreadsCpuNs() -> UInt64 {
        var total: UInt64 = 0
        for t in markerThreads {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(pthread_mach_thread_np(t), thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            if kr != KERN_SUCCESS { continue }
            func ns(_ v: time_value_t) -> UInt64 { UInt64(v.seconds) * 1_000_000_000 + UInt64(v.microseconds) * 1000 }
            total += ns(info.user_time) + ns(info.system_time)
        }
        return total
    }

    public var markerThreadCount: Int { markerThreads.count }

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
        if let t = collectorThread { stopCollector(vm, t); collectorThread = nil }
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
    if let q = getenv("KAJO_CM_QOS").map({ String(cString: $0) }), q == "high" { c.markerQoS = QOS_CLASS_USER_INITIATED }
    if let n = envInt("KAJO_AGE") {
        if n < 1 || n > 7 { fatal("KAJO_AGE=\(n): 1 to 7") }
        c.ageN = n
    }
    if let kb = envInt("KAJO_SURVIVOR_KB") { c.survivorBytes = kb * 1024 }
    if let r = getenv("KAJO_RELOC").map({ String(cString: $0) }) {
        if r == "off" { c.relocThreshold = 0 } else if r == "all" { c.relocThreshold = 101 }
        else if let t = Int(r), t >= 1, t <= 100 { c.relocThreshold = t } else { fatal("KAJO_RELOC=\(r)?") }
    }
    if let cap = envDouble("KAJO_RELOC_CAP") { c.relocCap = cap }
    return c
}

/// `KAJO_YOUNG`, `KAJO_IM`, `KAJO_YC_QOS` (SPEC.md "Package shape").
public func ycConfigFromEnv() -> YCConfig {
    var c = YCConfig()
    if let m = getenv("KAJO_YOUNG").map({ String(cString: $0) }) {
        switch m {
        case "stw": c.mode = YoungMode.stw
        case "local": c.mode = YoungMode.local
        case "offload": c.mode = YoungMode.offload
        default: fatal("KAJO_YOUNG=\(m)?")
        }
    }
    if let m = getenv("KAJO_IM").map({ String(cString: $0) }) { c.imYoung = m != "scavenge" }
    if let q = getenv("KAJO_YC_QOS").map({ String(cString: $0) }) {
        c.collectorQoS = q == "interactive" ? QOS_CLASS_USER_INTERACTIVE : q == "utility" ? QOS_CLASS_UTILITY : QOS_CLASS_USER_INITIATED
    }
    return c
}

public func envInt(_ name: String) -> Int? { getenv(name).flatMap { Int(String(cString: $0)) } }
public func envDouble(_ name: String) -> Double? { getenv(name).flatMap { Double(String(cString: $0)) } }

public struct RunResult {
    public var checksum: Int64
    public var results: [Int64]
    public var ms: Double
    /// Footprint samples (ms since start, old space in use, live bytes of
    /// the latest sweep), every `KAJO_SAMPLE_MS` (SPEC.md "Kernels").
    public var footprint: [(Double, Int, UInt64)] = []
}

/// Samples old space in use and live bytes on its own thread.
final class FootprintSampler: @unchecked Sendable {
    let vm: VMRef
    let intervalNs: UInt64
    let t0: UInt64
    var samples: [(Double, Int, UInt64)] = []
    var stop = false
    var lock = pthread_mutex_t()
    var thread: pthread_t? = nil

    init(_ vm: VMRef, intervalMs: Int) {
        self.vm = vm
        intervalNs = UInt64(intervalMs) * 1_000_000
        t0 = now()
        pthread_mutex_init(&lock, nil)
    }

    func sample() {
        let s = (Double(now() &- t0) / 1e6, vm.pointee.heap.blocksInUse() * blockSize, vm.metric(.liveBytes))
        pthread_mutex_lock(&lock); samples.append(s); pthread_mutex_unlock(&lock)
    }

    func start() {
        sample()
        let ctx = Unmanaged.passRetained(self).toOpaque()
        pthread_create(&thread, nil, { arg in
            let me = Unmanaged<FootprintSampler>.fromOpaque(arg).takeRetainedValue()
            var next = me.t0 &+ me.intervalNs
            while true {
                pthread_mutex_lock(&me.lock); let s = me.stop; pthread_mutex_unlock(&me.lock)
                if s { break }
                let t = now()
                if t >= next { me.sample(); next &+= me.intervalNs }
                usleep(2000)
            }
            return nil
        }, ctx)
    }

    func finish() -> [(Double, Int, UInt64)] {
        pthread_mutex_lock(&lock); stop = true; pthread_mutex_unlock(&lock)
        if let t = thread { pthread_join(t, nil) }
        sample()
        return samples
    }
}

/// Fork `n` Processes `nil kernel: i * 256 + n` (lib.kasm unpacks it into
/// `run: i of: n`) on `n` background workers; wall time from the first fork
/// to the last termination.
public func runKernel(_ img: Image, workers n: Int, sampleMs: Int? = nil) -> (RunResult, Runtime) {
    let rt = Runtime(img, background: n)
    let vm = rt.vm
    // share: the shared Array of 256 slots per worker in global 5.
    if img.symbol("shareLoop:") != nil { hostNewArrayInGlobal(vm, 256 * max(n, 1), global: 5) }
    let sel = rt.symbol("kernel:")
    let sampler = sampleMs.map { FootprintSampler(vm, intervalMs: $0) }
    sampler?.start()
    let t0 = now()
    vm.set(.kernelStartAt, t0)
    var ids: [Int64] = []
    for i in 0..<n {
        let p = spawn(vm, vm.pointee.nilObj, sel, mkInt(Int64(i * 256 + n)))
        ids.append(processId(vm, p))
    }
    waitAllTerminated(vm)
    let ms = Double(now() - t0) / 1e6
    let fp = sampler?.finish() ?? []
    rt.stop()
    var results: [Int64] = []
    for id in ids {
        let r = vm.pointee.results[Int(id)]
        if !isInt(r) { fatal("kernel returned a non-SmallInteger") }
        results.append(intVal(r))
    }
    return (RunResult(checksum: results.reduce(0, &+), results: results, ms: ms, footprint: fp), rt)
}

/// Old space: `KAJO_HEAP_MB`, default 64 MiB (as in the earlier
/// experiments), `2 N + 64` MiB for `oldheapN`, 256 MiB for `fragment`
/// (SPEC.md "Kernels").
public func loadKernel(_ kernel: String) throws -> Image {
    let def = oldheapMB(kernel).map { 2 * $0 + 64 } ?? (kernel.hasPrefix("fragment") ? 256 : 64)
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
        l += " remset=\(r.remSet) entalloc=\(r.entriesAllocated) entfreed=\(r.entriesFreed) busy=\(r.meanBusyNs)"
        l += " survived=\(r.survivedBytes) overflow=\(r.overflowBytes) survroots=\(r.survRootsNs) survwords=\(r.survRootWords)"
        l += " select=\(r.selectNs) pin=\(r.pinNs) pins=\(r.framePins) relocblocks=\(r.relocBlocks) pendfreed=\(r.pendingFreed) pendfree=\(r.pendingFreeNs) relocverify=\(r.relocVerifyNs)\n"
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
        l += " freedent=\(c.freedEntries) freedblocks=\(c.freedBlocks) snapent=\(c.snapEntries) floating=\(c.floatingBytes) missed=\(c.missed)"
        l += " rcand=\(c.relocCandidates) rblocks=\(c.relocBlocks) rcapped=\(c.relocCapped) rplanned=\(c.relocPlannedBytes) rpins=\(c.framePins)"
        l += " rmoved=\(c.relocMovedBytes) rmovedobj=\(c.relocMovedObjects) rskippin=\(c.relocSkipPinned) rskiphz=\(c.relocSkipHazard)"
        l += " rnospace=\(c.relocNoSpace) revac=\(c.relocEvacuated) rcpu=\(c.relocCpuNs) rwall=\(c.relocWallNs)\n"
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
    var o = "nursery_kb=\(vm.pointee.heap.nurseryBytes / 1024) age_n=\(vm.pointee.cmConfig.ageN) scavenges=\(sc.count) fulls=\(fu.count)"
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
        let surv = total(sc) { $0.survivedBytes }
        o += " survived_mb=" + r3(surv / 1048576)
        o += " overflow_mb=" + r3(total(sc) { $0.overflowBytes } / 1048576)
        o += " copied_kb_per_scav=" + r3((prom + surv) / n / 1024)
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
    let sampleMs = envInt("KAJO_SAMPLE_MS") ?? (kernel.hasPrefix("fragment") ? 100 : nil)
    let (r, rt) = runKernel(img, workers: workers, sampleMs: sampleMs)
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
    line += relocSummary(vm, rt)
    line += ycSummary(vm, rt, wallMs: r.ms)
    if !r.footprint.isEmpty {
        let mb = 1048576.0
        line += " footprint=" + r.footprint.map { "\(Int($0.0)):\(fixed(Double($0.1) / mb, 1)):\(fixed(Double($0.2) / mb, 1))" }.joined(separator: ",")
    }
    line += " rss_mb=\(peakRSS() >> 20)"
    return line
}

/// Concurrent-marking summary over pause records `recs` and the cycles that
/// started within them (SPEC.md "Headless matrix"). Times in ms.
func cmSummary(_ vm: VMRef, _ recs: [GCRecord]) -> String {
    let cfg = vm.pointee.cmConfig
    var o = " gc=\(cfg.concurrent ? "cm" : "stw") markers=\(cfg.markers) force=\(cfg.force ? 1 : 0)"
    o += " marker_qos=\(cfg.markerQoS == QOS_CLASS_UTILITY ? "utility" : "high")"
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
    o += " floating_mb_max=\(r3(done.map { Double($0.floatingBytes) / 1048576 }.max() ?? 0)) cm_missed=\(done.reduce(0) { $0 + $1.missed })"
    o += " cm_verify_runs=\(vm.metric(.cmVerifyRuns))"
    let first = cycles.first?.startNs ?? 0, last = recs.last.map { $0.atNs &+ $0.totalNs } ?? 0
    // Aborted cycles end at their fallback; only completed ones and a cycle
    // still marking at the end are counted (an earlier version counted an
    // aborted cycle up to the end of the window).
    let markingNs = cycles.reduce(0.0) { acc, c in
        if c.finalNs != 0 { return acc + Double(c.finalNs &- c.startNs) }
        if !c.aborted && c.startNs < last { return acc + Double(last &- c.startNs) }
        return acc
    }
    if last > since { o += " marking_pct=\(r1(100 * markingNs / Double(last &- since)))" }
    _ = first
    return o
}

/// Relocation and post-store-check summary (SPEC.md "Headless matrix").
public func relocSummary(_ vm: VMRef, _ rt: Runtime, from: Int = 0, base: [Metric: UInt64] = [:], workerBase: [(UInt64, UInt64, UInt64, UInt64)] = []) -> String {
    let cfg = vm.pointee.cmConfig
    var o = " reloc=\(cfg.relocThreshold > 100 ? "all" : cfg.relocThreshold == 0 ? "off" : String(cfg.relocThreshold))"
    #if NO_POST_STORE
    o += " poststore=0"
    #else
    o += " poststore=1"
    #endif
    var redo: UInt64 = 0, spins: UInt64 = 0, spinNs: UInt64 = 0, spinMax: UInt64 = 0, hzw: UInt64 = 0
    for (i, w) in rt.workers.enumerated() {
        let b = i < workerBase.count ? workerBase[i] : (0, 0, 0, 0)
        redo &+= w.pointee.storeRedo &- b.0; spins &+= w.pointee.spinEpisodes &- b.1; spinNs &+= w.pointee.spinNs &- b.2
        spinMax = max(spinMax, w.pointee.spinMaxNs); hzw &+= w.pointee.hazardWaits &- b.3
    }
    o += " stores_redone=\(redo) spin_episodes=\(spins) spin_ms=\(fixed(Double(spinNs) / 1e6, 3)) spin_max_ms=\(fixed(Double(spinMax) / 1e6, 3)) hazard_waits=\(hzw)"
    let mw = rt.workers[0]
    o += " main_redo=\(mw.pointee.storeRedo) main_spin_max_ms=\(fixed(Double(mw.pointee.spinMaxNs) / 1e6, 3))"
    let all = vm.pointee.gcLog.pointee.records
    let recs = Array(all[min(from, all.count)...])
    let since = recs.first?.atNs ?? 0
    let cycles = vm.pointee.cm.log.pointee.records.filter { $0.startNs >= since && $0.relocBlocks > 0 }
    func ms(_ ns: UInt64) -> Double { Double(ns) / 1e6 }
    let mb = 1048576.0
    o += " reloc_cycles=\(cycles.count)"
    o += " reloc_blocks=\(cycles.reduce(0) { $0 + $1.relocBlocks }) reloc_candidates=\(cycles.reduce(0) { $0 + $1.relocCandidates }) reloc_capped=\(cycles.reduce(0) { $0 + $1.relocCapped })"
    o += " reloc_planned_mb=\(fixed(Double(cycles.reduce(0) { $0 + $1.relocPlannedBytes }) / mb, 3))"
    // Totals from the counters (a cycle still relocating at the end has no
    // applied record), minus `base` (the scenario window's start values).
    func d(_ m: Metric) -> UInt64 { vm.metric(m) &- (base[m] ?? 0) }
    o += " reloc_moved_mb=\(fixed(Double(d(.relocMovedBytes)) / mb, 3)) reloc_moved_objs=\(d(.relocMovedObjects))"
    o += " reloc_skip_pinned=\(d(.relocSkipPinned)) reloc_skip_hazard=\(d(.relocSkipHazard)) reloc_nospace=\(d(.relocNoSpace)) reloc_cas_failed=\(d(.relocCasFail))"
    o += " reloc_evacuated=\(d(.relocEvacuated)) frame_pins=\(d(.relocPins))"
    o += " reloc_cpu_ms=\(fixed(cycles.reduce(0.0) { $0 + ms($1.relocCpuNs) }, 3)) reloc_wall_ms_p50=\(fixed(pctl(cycles.map { ms($0.relocWallNs) }, 0.5), 3)) reloc_wall_ms_max=\(fixed(cycles.map { ms($0.relocWallNs) }.max() ?? 0, 3))"
    let fe = d(.relocFreedEpoch), fp = d(.relocFreedPause)
    o += " freed_epoch=\(fe) freed_pause=\(fp) free_delay_mean_ms=\(fixed(fe + fp > 0 ? ms(d(.relocFreeDelayNs)) / Double(fe + fp) : 0, 3)) free_delay_max_ms=\(fixed(ms(vm.metric(.relocFreeDelayMaxNs)), 3))"
    let fin = recs.filter { $0.kind == PauseKind.final && $0.relocBlocks > 0 }
    o += " final_select_ms_max=\(fixed(fin.map { ms($0.selectNs) }.max() ?? 0, 3)) final_pin_ms_max=\(fixed(fin.map { ms($0.pinNs) }.max() ?? 0, 3))"
    let pf = recs.filter { $0.pendingFreed > 0 }
    o += " pause_free_ms_max=\(fixed(pf.map { ms($0.pendingFreeNs) }.max() ?? 0, 3)) reloc_verify_ms_max=\(fixed(recs.map { ms($0.relocVerifyNs) }.max() ?? 0, 3))"
    let ini = recs.filter { $0.kind == PauseKind.initial }
    o += " initial_survroots_ms_p50=\(fixed(pctl(ini.map { ms($0.survRootsNs) }, 0.5), 3)) initial_survroots_ms_max=\(fixed(ini.map { ms($0.survRootsNs) }.max() ?? 0, 3))"
    return o
}

/// Young-collection summary (SPEC.md "Headless matrix"). Times in ms. With
/// `from`/`base`: only records and worker counters after that point.
public func ycSummary(_ vm: VMRef, _ rt: Runtime, wallMs: Double, from: Int = 0, hsFrom: Int = 0,
                      workerBase: [[UInt64]] = []) -> String {
    let cfg = vm.pointee.ycConfig
    func ms(_ ns: UInt64) -> Double { Double(ns) / 1e6 }
    func r3(_ x: Double) -> String { fixed(x, 3) }
    var o = " young=\(YoungMode.name(cfg.mode)) im=\(cfg.imYoung ? "young" : "scavenge")"
    #if NO_YOUNG_BARRIER
    o += " ybarrier=0"
    #else
    o += " ybarrier=1"
    #endif
    let all = vm.pointee.yc.log.pointee.records
    let recs = Array(all[min(from, all.count)...])
    func dist(_ name: String, _ xs: [Double]) {
        o += " \(name)_p50=\(r3(pctl(xs, 0.5))) \(name)_p99=\(r3(pctl(xs, 0.99))) \(name)_max=\(r3(xs.max() ?? 0))"
    }
    o += " yc_count=\(recs.count)"
    dist("yc_total", recs.map { ms($0.totalNs) })
    dist("yc_h0", recs.map { ms($0.h0Ns) })
    dist("yc_h1", recs.map { ms($0.h1Ns) })
    dist("yc_trace", recs.map { ms($0.traceNs) })
    dist("yc_eden_wait", recs.map { ms($0.epochWaitNs) })
    dist("yc_queue", recs.filter { $0.offloaded }.map { ms($0.startAt &- $0.openAt) })
    let rounds = recs.map { Double($0.rounds) }
    o += " yc_rounds_mean=\(fixed(rounds.isEmpty ? 0 : rounds.reduce(0, +) / Double(rounds.count), 2)) yc_rounds_max=\(Int(rounds.max() ?? 0))"
    o += " yc_rounds_gt2=\(recs.filter { $0.rounds > 2 }.count)"
    func sum(_ f: (YCRecord) -> UInt64) -> UInt64 { recs.reduce(0) { $0 &+ f($1) } }
    o += " yc_del_records=\(sum { $0.delRecords }) yc_stack_roots=\(sum { $0.stackRoots }) yc_proc_scans=\(sum { $0.procScans })"
    o += " yc_holders=\(sum { $0.holders }) yc_carried_mean=\(fixed(recs.isEmpty ? 0 : Double(sum { $0.carried }) / Double(recs.count), 1))"
    o += " yc_cross_rem=\(sum { $0.crossRemembered }) yc_hazard_retries=\(sum { $0.hazardRetries }) yc_deferred=\(sum { $0.deferredFrees })"
    o += " yc_promoted_mb=\(r3(Double(sum { $0.promotedBytes }) / 1048576)) yc_survived_mb=\(r3(Double(sum { $0.survivedBytes }) / 1048576))"
    o += " yc_overflow_mb=\(r3(Double(sum { $0.overflowBytes }) / 1048576)) yc_young_mb=\(r3(Double(sum { $0.youngBytes }) / 1048576))"
    let busy = Double(sum { $0.totalNs }) / 1e6
    o += " yc_busy_ms=\(r3(busy))"
    if let c = vm.pointee.yc.collector.pointee {
        o += " collector_cpu_ms=\(r3(ms(c.pointee.collectorCpuNs))) collector_busy_pct=\(fixed(wallMs > 0 ? 100 * busy / wallMs : 0, 1))"
    }
    let hs = vm.pointee.yc.hsLatency.pointee.values()
    dist("hs_lat", hs[min(hsFrom, hs.count)...].map { Double($0) / 1e6 })
    let worst = vm.pointee.yc.hsWorst.pointee
    o += " hs_worst_by=\(worst.1) hs_worst_kind=\(worst.2)"
    // Per-worker pauses (the owning worker's own), waits, acknowledgements.
    var pauses: [Double] = []
    var acksOwn: UInt64 = 0, acksOther: UInt64 = 0, ackOwnNs: UInt64 = 0, ackOtherNs: UInt64 = 0
    var cw: UInt64 = 0, cwNs: UInt64 = 0, cwMax: UInt64 = 0, stwWait: UInt64 = 0, del: UInt64 = 0, cross: UInt64 = 0, resume: UInt64 = 0
    for w in rt.workers {
        pauses += w.pointee.pauseSamples.pointee.values().map { Double($0) / 1e6 }
        acksOwn &+= w.pointee.ackOwn; acksOther &+= w.pointee.ackOther
        ackOwnNs &+= w.pointee.ackOwnNs; ackOtherNs &+= w.pointee.ackOtherNs
        cw &+= w.pointee.collWaits; cwNs &+= w.pointee.collWaitNs; cwMax = max(cwMax, w.pointee.collWaitMaxNs)
        stwWait &+= w.pointee.stwWaitNs; del &+= w.pointee.delPushed; cross &+= w.pointee.crossRem; resume &+= w.pointee.resumeScans
    }
    dist("own_pause", pauses)
    o += " acks_own=\(acksOwn) acks_own_ms=\(r3(ms(ackOwnNs))) acks_other=\(acksOther) acks_other_ms=\(r3(ms(ackOtherNs)))"
    o += " coll_waits=\(cw) coll_wait_ms=\(r3(ms(cwNs))) coll_wait_max_ms=\(r3(ms(cwMax))) stw_wait_ms=\(r3(ms(stwWait)))"
    o += " del_pushed=\(del) cross_rem_barrier=\(cross) resume_scans=\(resume)"
    _ = workerBase
    return o
}
