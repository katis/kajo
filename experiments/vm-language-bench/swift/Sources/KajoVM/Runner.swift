// Run a kernel on N worker threads and combine the results.

import Darwin

public struct RunResult {
    public var checksum: Int64
    public var results: [Int64]
    public var ms: Double
    public var gcCount: UInt64
    public var gcMs: Double
    public var misses: UInt64
}

public func kernelSources(dir: String, kernel: String) throws -> [String] {
    try ["prelude", kernel].map { k in
        let path = "\(dir)/\(k).kasm"
        guard let f = fopen(path, "r") else { throw KasmError("\(path): cannot open") }
        defer { fclose(f) }
        var bytes: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = fread(&buf, 1, buf.count, f)
            if n <= 0 { break }
            bytes += buf[0..<n]
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Context handed to a pthread. Plain raw-memory struct: no Sendable checking
/// involved because it crosses the thread boundary as a C void pointer.
private struct ThreadCtx {
    var vm: VMRef
    var w: WorkerRef
    var sel: Oop
    var nworkers: Int
    var result: Oop
}

private func threadMain(_ arg: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
    let ctx = arg.assumingMemoryBound(to: ThreadCtx.self)
    let vm = ctx.pointee.vm, w = ctx.pointee.w
    ctx.pointee.result = execute(vm, w, vm.pointee.nilObj, ctx.pointee.sel,
                                 [mkInt(Int64(w.pointee.id)), mkInt(Int64(ctx.pointee.nworkers))])
    workerFinished(vm, w)
    return nil
}

public func runKernel(_ img: Image, workers nworkers: Int) -> RunResult {
    let vm = img.vm
    let ws = (0..<nworkers).map { Worker.create(id: $0, nilObj: vm.pointee.nilObj) }
    setWorkers(vm, ws)
    let sel = img.symbols["run:of:"]!
    let ctxs = UnsafeMutablePointer<ThreadCtx>.allocate(capacity: nworkers)
    for i in 0..<nworkers {
        (ctxs + i).initialize(to: ThreadCtx(vm: vm, w: ws[i], sel: sel, nworkers: nworkers, result: 0))
    }
    let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    var threads: [pthread_t] = []
    for i in 0..<nworkers {
        var tid: pthread_t? = nil
        let rc = pthread_create(&tid, nil, threadMain, UnsafeMutableRawPointer(ctxs + i))
        if rc != 0 { fatal("pthread_create failed") }
        threads.append(tid!)
    }
    for t in threads { pthread_join(t, nil) }
    let ms = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6
    var results: [Int64] = []
    for i in 0..<nworkers {
        let r = ctxs[i].result
        if !isInt(r) { fatal("kernel returned a non-SmallInteger") }
        results.append(intVal(r))
    }
    let misses = ws.reduce(0) { $0 + $1.pointee.misses }
    ctxs.deallocate()
    // Workers stay registered (and allocated) so a later collect could still
    // scan them; this is a one-shot benchmark process.
    return RunResult(checksum: results.reduce(0, &+), results: results, ms: ms,
                     gcCount: vm.pointee.gcCount, gcMs: Double(vm.pointee.gcNanos) / 1e6, misses: misses)
}
