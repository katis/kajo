// Part B: concurrent-young's headless kernels. `stw`, `local`, `offload`
// run VMR (barriers compiled in, KAJO_YOUNG picks the collector; `stw` is the
// Mac matrix's `adr7b`), `adr7` runs VMRNB (-DNO_YOUNG_BARRIER, stw), the
// Mac matrix's checksum reference. The collector environment (KAJO_GC=cm,
// KAJO_AGE=2, KAJO_NURSERY_KB=4096, KAJO_YOUNG) comes from the launch
// arguments, as bench.sh passed it on the Mac.

import Darwin
import Kasm
import VMR
import VMRNB

func runPartB(_ opt: Options) throws -> String {
    kernelFlavor = .concurrentYoung
    let kernel = opt["kernel"] ?? "alloc"
    let n = opt.int("workers", 1)
    let cfg = opt["cfg"] ?? "stw"
    let env = ["KAJO_YOUNG", "KAJO_YC_QOS", "KAJO_CM_QOS", "KAJO_NURSERY_KB", "KAJO_HEAP_MB"]
        .map { k in " env_\(k)=\(getenv(k).map { String(cString: $0) } ?? "-")" }.joined()
    let line = cfg == "adr7" ? try VMRNB.benchLine(kernel: kernel, workers: n)
                             : try VMR.benchLine(kernel: kernel, workers: n)
    return "cfg=\(cfg)" + env + " " + line
}
