import Darwin
import KajoVM

let args = CommandLine.arguments
if args.count < 3 {
    fputs("usage: kajo-bench <arith|fib|sends|alloc> <workers> [kernels-dir]\n", stderr)
    exit(1)
}
let kernel = args[1]
guard let n = Int(args[2]) else { fputs("bad worker count\n", stderr); exit(1) }
let defaultDir = String(#filePath.split(separator: "/", omittingEmptySubsequences: false).dropLast(4).joined(separator: "/")) + "/kernels"
let dir = args.count > 3 ? args[3] : defaultDir
do {
    let srcs = try kernelSources(dir: dir, kernel: kernel)
    let img = try Image.fromSources(srcs)
    img.vm.pointee.verboseGC = getenv("KAJO_VERBOSE_GC") != nil
    let r = runKernel(img, workers: n)
    print("lang=swift kernel=\(kernel) workers=\(n) ms=\(String(format1: r.ms)) gc=\(r.gcCount) gc_ms=\(String(format1: r.gcMs)) misses=\(r.misses) checksum=\(r.checksum)")
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}

extension String {
    init(format1 v: Double) {
        let t = (v * 10).rounded() / 10
        self = "\(t)"
    }
}
