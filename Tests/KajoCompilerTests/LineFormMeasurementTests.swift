// Large bytes, part 3 (docs/modules/large-bytes.md): a long reply written
// in pieces of 16 KiB (`Json writePieces:`, each piece a young ByteArray)
// against one ByteArray (`Json write:`, old at birth past one block). The
// measurement (KAJO_MEASURE_LINEFORM=1, release): 100 `package.selectors`
// replies of the kernel's selectors from a headless target in each form,
// three rounds interleaved: their time, the bytes allocated old, the bytes
// promoted, the large objects made and the marking cycles started.

import Foundation
import Testing
@testable import KajoDev
@testable import KajoVM

@Test func lineFormsMeasured() throws {
    guard ProcessInfo.processInfo.environment["KAJO_MEASURE_LINEFORM"] != nil else { return }
    for round in 0..<3 {
        for form in ["pieces", "string"] {
            let t = try RunningTarget(projectImage)
            defer { t.close() }
            let c = try t.session()
            _ = try c.request("evaluate", [("source", .string("DevProtocol oneString: \(form == "string")"))])
            let r = try c.request("package.selectors", [("name", .string("Kernel"))])
            let replyBytes = writeJSON(r).count
            let vm = t.target.vm.vm
            func sample() -> (old: UInt64, promoted: UInt64, large: UInt64, cycles: UInt64, young: UInt64) {
                let om = vm.image.om
                return (om.allocationCounters.allocatedBytes,
                        vm.nurseryCounters.promotedBytes &+ vm.youngCounters.promotedBytes,
                        om.largeObjectCounters.bytes, vm.markingCounters.cycles, vm.nurseryCounters.youngAllocations)
            }
            let a = sample()
            let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            for _ in 0..<100 { _ = try c.request("package.selectors", [("name", .string("Kernel"))]) }
            let ms = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6
            let b = sample()
            print("lineform \(form) round \(round): 100 replies of \(replyBytes) bytes in \(String(format: "%.1f", ms)) ms, "
                  + "old allocated \(b.old - a.old) B, promoted \(b.promoted - a.promoted) B, large \(b.large - a.large) B, "
                  + "cycles started \(b.cycles - a.cycles), young allocations \(b.young - a.young)")
            c.close()
        }
    }
}
