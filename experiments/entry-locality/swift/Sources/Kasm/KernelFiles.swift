// Kernel file lookup for entry-locality. Derived from
// ../../object-representation/swift/Sources/Kasm/KernelFiles.swift; changes:
// - `experimentsDir` is a variable (the iOS app points it at the bundled
//   copy of the kernels, as device-measurement's copy does); the directory
//   constants are computed properties that follow it.
// - `newKernelsDir` is entry-locality/kernels, which symlinks every
//   object-representation kernel and lib.kasm unchanged.
// - Sized walk kernels (SPEC.md "Part 3 kernels"): walkN, walkbuildN,
//   walkcompactN, walkcompactbuildN, walkmarkN load prelude, lib,
//   el-lib.kasm, a template, and two generated constant methods.

import Darwin

nonisolated(unsafe) public var experimentsDir: String = {
    let parts = #filePath.split(separator: "/", omittingEmptySubsequences: false)
    return parts.dropLast(5).joined(separator: "/")
}()

public let oldKernels: Set<String> = ["arith", "fib", "sends", "alloc"]
public let opKernels: Set<String> = ["become", "reshape", "compact", "snapshot"]
public let allKernels = ["arith", "fib", "sends", "alloc", "ivars", "walk", "walkbuild",
                         "become", "reshape", "compact", "snapshot",
                         "walk20", "walkbuild20", "walkcompact20", "walkcompactbuild20", "walkmark20"]
public var oldKernelsDir: String { experimentsDir + "/vm-language-bench/kernels" }
public var newKernelsDir: String { experimentsDir + "/entry-locality/kernels" }

public func readTextFile(_ path: String) throws -> String {
    guard let f = fopen(path, "r") else { throw KasmError("\(path): cannot open") }
    defer { fclose(f) }
    var bytes: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = fread(&buf, 1, buf.count, f)
        if n <= 0 { break }
        bytes += buf[0..<n]
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// A sized walk kernel: (template file, log2 nodes, traversals).
public func sizedWalk(_ kernel: String) -> (String, Int, Int)? {
    for (prefix, file, reps) in [("walkcompactbuild", "walkcompact", 0), ("walkcompact", "walkcompact", 2),
                                 ("walkbuild", "walksize", 0), ("walkmark", "walkmark", 0), ("walk", "walksize", 2)] {
        if kernel.hasPrefix(prefix), let n = Int(kernel.dropFirst(prefix.count)), n >= 4, n <= 26 {
            return (file, n, reps)
        }
    }
    return nil
}

func constMethod(_ sel: String, _ v: Int) -> String {
    "method UndefinedObject \(sel) temps=0\n  push_lit \(v)\n  return_top\nend\n"
}

/// Source files for a kernel, in load order: old prelude, lib, kernel.
public func kernelSources(_ kernel: String) throws -> [String] {
    let base = ["\(oldKernelsDir)/prelude.kasm", "\(newKernelsDir)/lib.kasm"]
    if let (file, n, reps) = sizedWalk(kernel) {
        return try (base + ["\(newKernelsDir)/el-lib.kasm", "\(newKernelsDir)/\(file).kasm"]).map(readTextFile)
            + [constMethod("walkNodes", 1 << n) + constMethod("walkReps", reps)]
    }
    let k = oldKernels.contains(kernel) ? "\(oldKernelsDir)/\(kernel).kasm" : "\(newKernelsDir)/\(kernel).kasm"
    return try (base + [k]).map(readTextFile)
}

/// Heap size per kernel (object-representation's table; 1 GiB for the sized walks).
public func heapSizeFor(_ kernel: String) -> Int {
    (oldKernels.contains(kernel) || kernel == "ivars") ? 64 << 20 : 1 << 30
}
