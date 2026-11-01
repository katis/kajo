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
    private var ctxs: UnsafeMutablePointer<ThreadCtx>

    public init(_ img: Image, background: Int, pollEvery: Int? = nil, sliceMs: Double? = nil, start: Bool = true) {
        self.img = img
        self.background = background
        let vm = img.vm
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

    /// Start the background worker threads (once).
    public func start() {
        if !threads.isEmpty { return }
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

    /// Stop and join the background workers.
    public func stop() {
        shutdownWorkers(vm)
        for t in threads { pthread_join(t, nil) }
        threads = []
    }
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
    var ids: [Int64] = []
    for i in 0..<n {
        let p = spawn(vm, vm.pointee.nilObj, sel, mkInt(Int64(i * 256 + n)))
        ids.append(intVal(vm.pointee.om.slot(p, pId)))
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

public func loadKernel(_ kernel: String) throws -> Image {
    try Image.fromSources(try kernelSources(kernel), heapSize: 64 << 20)
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
    #if NO_BUDGET
    let build = "nobudget"
    #else
    let build = "budget"
    #endif
    var line = "kernel=\(kernel) workers=\(workers) vm=\(build) pollN=\(vm.pointee.pollEvery) sliceMs=\(Double(vm.pointee.sliceNs) / 1e6)"
    line += " ms=\((r.ms * 10).rounded() / 10) checksum=\(r.checksum)"
    let slices = rt.workers.reduce(0) { $0 + $1.pointee.slices }
    line += " slices=\(slices)"
    for m in Metric.allCases {
        let v = vm.metric(m)
        if v == 0 { continue }
        let name = "\(m)"
        line += name.hasSuffix("Ns") ? " \(name.dropLast(2))_ms=\(Double(v / 1000) / 1000)" : " \(name)=\(v)"
    }
    line += " rss_mb=\(peakRSS() >> 20)"
    return line
}
