// Part A: object-representation's three object memories (ADR 0003), its
// benchLine unchanged.

import Foundation
import Kasm
import VMA
import VMB
import VMC

func runPartA(_ opt: Options) throws -> String {
    kernelFlavor = .objectRepresentation
    let kernel = opt["kernel"] ?? "walk"
    let n = opt.int("workers", 1)
    let snap = NSTemporaryDirectory()
    switch opt["variant"] ?? "A" {
    case "A": return try VMA.benchLine(kernel: kernel, workers: n, snapshotDir: snap)
    case "B": return try VMB.benchLine(kernel: kernel, workers: n, snapshotDir: snap)
    case "C": return try VMC.benchLine(kernel: kernel, workers: n, snapshotDir: snap)
    default: throw KasmError("variant must be A, B or C")
    }
}

/// The first thing run on the phone: arith on B, one worker.
func runHello() throws -> String {
    kernelFlavor = .objectRepresentation
    return try VMB.benchLine(kernel: "arith", workers: 1, snapshotDir: NSTemporaryDirectory())
}
