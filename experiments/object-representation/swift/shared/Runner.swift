// Run a kernel on N worker threads, orchestrate the snapshot reload, and
// format one result line. Shared by every variant.

import Darwin
import Kasm

public struct RunResult {
    public var checksum: Int64
    public var results: [Int64]
    public var ms: Double
    public var misses: UInt64
}

/// Context handed to a pthread as a C void pointer.
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

public func runKernel(_ img: Image, workers nworkers: Int, selector: String = "run:of:") -> RunResult {
    let vm = img.vm
    let ws = (0..<nworkers).map { Worker.create(id: $0, nilObj: vm.pointee.nilObj) }
    setWorkers(vm, ws)
    guard let sel = img.symbol(selector) else { fatal("no selector \(selector)") }
    let ctxs = UnsafeMutablePointer<ThreadCtx>.allocate(capacity: nworkers)
    for i in 0..<nworkers {
        (ctxs + i).initialize(to: ThreadCtx(vm: vm, w: ws[i], sel: sel, nworkers: nworkers, result: 0))
    }
    let t0 = now()
    var threads: [pthread_t] = []
    for i in 0..<nworkers {
        var tid: pthread_t? = nil
        let rc = pthread_create(&tid, nil, threadMain, UnsafeMutableRawPointer(ctxs + i))
        if rc != 0 { fatal("pthread_create failed") }
        threads.append(tid!)
    }
    for t in threads { pthread_join(t, nil) }
    let ms = Double(now() - t0) / 1e6
    var results: [Int64] = []
    for i in 0..<nworkers {
        let r = ctxs[i].result
        if !isInt(r) { fatal("kernel returned a non-SmallInteger") }
        results.append(intVal(r))
    }
    let misses = ws.reduce(0) { $0 + $1.pointee.misses }
    vm.add(.tlabRefills, ws.reduce(0) { $0 + $1.pointee.tlabRefills })
    vm.add(.entryRefills, ws.reduce(0) { $0 + entryRefills($1) })
    ctxs.deallocate()
    // Workers stay registered so a later collect could still scan them.
    return RunResult(checksum: results.reduce(0, &+), results: results, ms: ms, misses: misses)
}

public func loadKernel(_ kernel: String) throws -> Image {
    try Image.fromSources(try kernelSources(kernel), heapSize: heapSizeFor(kernel))
}

private func peakRSS() -> Int {
    var ru = rusage()
    getrusage(RUSAGE_SELF, &ru)
    return Int(ru.ru_maxrss) // bytes on Darwin
}

private func fmt(_ ns: UInt64) -> String {
    let ms = Double(ns) / 1e6
    return "\((ms * 1000).rounded() / 1000)"
}

/// Run one kernel and return the bench line (key=value pairs).
public func benchLine(kernel: String, workers: Int, snapshotDir: String) throws -> String {
    let img = try loadKernel(kernel)
    let vm = img.vm
    vm.pointee.verboseGC = getenv("KAJO_VERBOSE_GC") != nil
    let isOp = opKernels.contains(kernel)
    var line = "variant=\(variantName) kernel=\(kernel) workers=\(workers)"
    if kernel == "snapshot" {
        vm.pointee.snapshotPath = "\(snapshotDir)/snapshot-\(variantName).img"
    }
    let r = runKernel(img, workers: workers, selector: isOp ? "opRun:of:" : "run:of:")
    line += " ms=\((r.ms * 10).rounded() / 10) checksum=\(r.checksum) misses=\(r.misses)"
    var maxPark: UInt64 = 0
    if let ws = vm.pointee.workers {
        for i in 0..<vm.pointee.workerCount { maxPark = max(maxPark, ws[i].pointee.parkedNs) }
    }
    var reloadOK = ""
    var loadMetrics: [(Metric, UInt64)] = []
    if kernel == "snapshot" {
        let t0 = now()
        let loaded = try loadSnapshot(vm.pointee.snapshotPath)
        let loadNs = now() - t0
        loaded.vm.set(.snapLoadNs, loadNs)
        loaded.vm.set(.snapWordsChanged, UInt64(countChangedWords(loaded.vm, vm.pointee.snapshotPath)))
        let r2 = runKernel(loaded, workers: 1, selector: "reloaded:of:")
        reloadOK = " reload_checksum=\(r2.checksum) reload_ok=\(r2.checksum == r.checksum ? 1 : 0)"
        reloadOK += " old_base=0x\(String(UInt(bitPattern: vm.pointee.heap.base), radix: 16)) new_base=0x\(String(UInt(bitPattern: loaded.vm.pointee.heap.base), radix: 16))"
        for m in [Metric.snapLoadNs, .snapRelocNs, .snapRelocSlots, .snapRelocRoots, .snapWordsChanged, .snapEntriesScanned] {
            loadMetrics.append((m, loaded.vm.metric(m)))
        }
    }
    for m in Metric.allCases {
        var v = vm.metric(m)
        if let lm = loadMetrics.first(where: { $0.0 == m }) { v = lm.1 }
        if v == 0 && !loadMetrics.contains(where: { $0.0 == m }) { continue }
        let name = "\(m)"
        line += name.hasSuffix("Ns") ? " \(name.dropLast(2))_ms=\(fmt(v))" : " \(name)=\(v)"
    }
    line += " parkedMax_ms=\(fmt(maxPark)) rss_mb=\(peakRSS() >> 20)" + reloadOK
    return line
}
