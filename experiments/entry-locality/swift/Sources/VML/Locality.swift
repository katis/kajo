// L only: Runner.swift's benchLine (../../shared/Runner.swift) followed by the
// entry-locality report of the same VM after the kernel ran. Identical to
// benchLine for every kernel but snapshot, which goes to benchLine.

import Darwin
import Kasm

public func benchLineWithLocality(kernel: String, workers: Int, snapshotDir: String) throws -> String {
    if kernel == "snapshot" { return try benchLine(kernel: kernel, workers: workers, snapshotDir: snapshotDir) }
    let img = try loadKernel(kernel)
    let vm = img.vm
    vm.pointee.verboseGC = getenv("KAJO_VERBOSE_GC") != nil
    let isOp = opKernels.contains(kernel)
    var line = "variant=\(variantName) kernel=\(kernel) workers=\(workers)"
    let r = runKernel(img, workers: workers, selector: isOp ? "opRun:of:" : "run:of:")
    line += " ms=\((r.ms * 10).rounded() / 10) checksum=\(r.checksum) misses=\(r.misses)"
    var maxPark: UInt64 = 0
    if let ws = vm.pointee.workers {
        for i in 0..<vm.pointee.workerCount { maxPark = max(maxPark, ws[i].pointee.parkedNs) }
    }
    func fmt(_ ns: UInt64) -> String { "\((Double(ns) / 1e6 * 1000).rounded() / 1000)" }
    for m in Metric.allCases {
        let v = vm.metric(m)
        if v == 0 { continue }
        let name = "\(m)"
        line += name.hasSuffix("Ns") ? " \(name.dropLast(2))_ms=\(fmt(v))" : " \(name)=\(v)"
    }
    var ru = rusage()
    getrusage(RUSAGE_SELF, &ru)
    line += " parkedMax_ms=\(fmt(maxPark)) rss_mb=\(Int(ru.ru_maxrss) >> 20) worker_qos=\(r.workerQoS)"
    return line + " " + localityLine(vm)
}
