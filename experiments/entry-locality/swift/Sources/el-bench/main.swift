// el-bench <A|B|C|L> <kernel> <workers>: one kernel per process; prints
// the bench line of ../shared/Runner.swift (workers at KAJO_WORKER_QOS,
// user-initiated by default) and, for L, the locality of entries after the
// run (SPEC.md "Part 3 kernels").
import Darwin
import Kasm
import VMA
import VMB
import VMC
import MemChase
import VML

public func elBenchLine(variant: String, kernel: String, workers: Int, snapshotDir: String) throws -> String {
    switch variant {
    case "A": return try VMA.benchLine(kernel: kernel, workers: workers, snapshotDir: snapshotDir)
    case "B": return try VMB.benchLine(kernel: kernel, workers: workers, snapshotDir: snapshotDir)
    case "C": return try VMC.benchLine(kernel: kernel, workers: workers, snapshotDir: snapshotDir)
    case "L":
        return try VML.benchLineWithLocality(kernel: kernel, workers: workers, snapshotDir: snapshotDir)
    default: throw KasmError("variant must be A, B, C or L")
    }
}

let a = CommandLine.arguments
guard a.count == 4, let n = Int(a[3]) else {
    print("usage: el-bench <A|B|C|L> <kernel> <workers>")
    exit(1)
}
do {
    let streamMB = getenv("KAJO_STREAM_MB").flatMap { Int(String(cString: $0)) } ?? 0
    let streamer = streamMB > 0 ? Streamer(mb: streamMB) : nil
    let u0 = ProcUsage.now()
    var line = try elBenchLine(variant: a[1], kernel: a[2], workers: n, snapshotDir: experimentsDir + "/entry-locality/swift/.build")
    let u1 = ProcUsage.now()
    if let st = streamer { line += " stream_mb=\(streamMB) stream_mbs=\(Int(st.finish()))" }
    print(line + ProcUsage.line(u0, u1))
} catch {
    print("FAILED=1 error=\(error)")
    exit(1)
}
