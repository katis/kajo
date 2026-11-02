import Foundation
import Testing
@testable import KajoVM

/// Worker 0 of `n`: the kernels divide their work by the worker count, so a
/// large `n` is a scaled-down run with the same code paths.
let scaledWorkers: [String: Int64] = [
    "arith": 8000, "fib": 96, "sends": 40000, "alloc": 320, "ivars": 8000, "walk": 1024,
]

private func kernelHarness(_ name: String, stress: StressFlags = [], heapBlocks: Int = 2048, entries: Int = 1 << 20,
                           verify: Bool = true) throws -> Harness {
    try Harness(kernel(name), base: ["prelude", "lib"], heapBlocks: heapBlocks, entries: entries, stress: stress, verify: verify)
}

/// Each fixture kernel, scaled down, answers what its Swift model answers
/// (and the models reproduce the published checksums).
@Test(arguments: goldenKernels.map(\.name))
func scaledKernelsMatchTheirModels(_ name: String) throws {
    let n = scaledWorkers[name]!
    let h = try kernelHarness(name)
    defer { h.destroy() }
    #expect(try h.value("run:of:", [0, n]) == KernelModel.checksum(name, w: 0, n: n))
    #expect(try h.value("run:of:", [1, n]) == KernelModel.checksum(name, w: 1, n: n))
}

/// The full-size kernels with their published single-worker checksums.
/// Minutes in a debug build, so they run in release builds or with
/// KAJO_GOLDEN=1 (`just golden` runs them through `kajo run`).
@Test(.enabled(if: !checkedBuild || ProcessInfo.processInfo.environment["KAJO_GOLDEN"] != nil),
      arguments: goldenKernels.map(\.name))
func goldenKernelChecksums(_ name: String) throws {
    let walk = name == "walk"  // 4M nodes
    let h = try kernelHarness(name, heapBlocks: walk ? 16384 : 2048, entries: walk ? 1 << 23 : 1 << 20)
    defer { h.destroy() }
    #expect(try h.value() == goldenKernels.first { $0.name == name }!.checksum)
}

/// Stress flags from module 1 under the allocating kernels: a collection
/// at every allocation runs thousands of collections and the checksums do
/// not change. The verifiers at every pause would make this ten times
/// slower in a debug build, so they run once at the end; the checksum is
/// the oracle.
@Test(arguments: ["alloc", "walk"])
func allocatingKernelsUnderACollectionAtEveryAllocation(_ name: String) throws {
    let n: Int64 = name == "alloc" ? 320 * 64 : 1024   // alloc: the long-lived tree only; walk: 4096 nodes
    let h = try kernelHarness(name, stress: .collectAtEveryAllocation, heapBlocks: 64, verify: false)
    defer { h.destroy() }
    #expect(try h.value("run:of:", [0, n]) == KernelModel.checksum(name, w: 0, n: n))
    #expect(h.om.counters.stressCollections > 4000)
    #expect(verified(h.om) == [])
}

/// Tiny entry chunks: every other allocation refills. (A one-block heap
/// cannot hold a kernel image.)
@Test func kernelsUnderTinyEntryChunks() throws {
    for name in ["sends", "alloc", "walk"] {
        let n = scaledWorkers[name]!
        let h = try kernelHarness(name, stress: .tinyEntryChunks)
        defer { h.destroy() }
        #expect(try h.value("run:of:", [0, n]) == KernelModel.checksum(name, w: 0, n: n), "\(name)")
    }
}
