// Kernel file lookup. The four kernels of the previous experiment are read in
// place from ../vm-language-bench/kernels (not copied).

import Darwin

public let oldKernels: Set<String> = ["arith", "fib", "sends", "alloc"]
public let opKernels: Set<String> = ["become", "reshape", "compact", "snapshot"]
public let allKernels = ["arith", "fib", "sends", "alloc", "ivars", "walk", "walkbuild",
                         "become", "reshape", "compact", "snapshot"]

/// experiments/ directory, derived from this file's path.
public let experimentsDir: String = {
    let parts = #filePath.split(separator: "/", omittingEmptySubsequences: false)
    return parts.dropLast(5).joined(separator: "/")
}()
public let oldKernelsDir = experimentsDir + "/vm-language-bench/kernels"
public let newKernelsDir = experimentsDir + "/object-representation/kernels"

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

/// Source files for a kernel, in load order: old prelude, lib, kernel.
public func kernelSources(_ kernel: String) throws -> [String] {
    let k = oldKernels.contains(kernel) ? "\(oldKernelsDir)/\(kernel).kasm" : "\(newKernelsDir)/\(kernel).kasm"
    return try ["\(oldKernelsDir)/prelude.kasm", "\(newKernelsDir)/lib.kasm", k].map(readTextFile)
}

/// Heap size per kernel (SPEC.md table).
public func heapSizeFor(_ kernel: String) -> Int {
    (oldKernels.contains(kernel) || kernel == "ivars") ? 64 << 20 : 1 << 30
}
