// orep-bench <A|B|C> <kernel> <workers>: one result line of key=value pairs.

import Darwin
import Kasm
import VMA
import VMB
import VMC

let args = CommandLine.arguments
if args.count < 4 {
    fputs("usage: orep-bench <A|B|C> <kernel> <workers>\n  kernels: \(allKernels.joined(separator: " "))\n", stderr)
    exit(1)
}
guard let n = Int(args[3]) else { fputs("bad worker count\n", stderr); exit(1) }
let snapDir = getenv("KAJO_SNAPSHOT_DIR").map { String(cString: $0) }
    ?? experimentsDir + "/object-representation/swift/.build"
do {
    let line: String
    switch args[1] {
    case "A": line = try VMA.benchLine(kernel: args[2], workers: n, snapshotDir: snapDir)
    case "B": line = try VMB.benchLine(kernel: args[2], workers: n, snapshotDir: snapDir)
    case "C": line = try VMC.benchLine(kernel: args[2], workers: n, snapshotDir: snapDir)
    default: fputs("variant must be A, B or C\n", stderr); exit(1)
    }
    print(line)
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
