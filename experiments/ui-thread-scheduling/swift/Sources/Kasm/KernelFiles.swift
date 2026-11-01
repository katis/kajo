// Kernel file lookup. The four kernels of vm-language-bench are read in place
// (not copied); this experiment's own .kasm files live in ../../kernels.

import Darwin

public let oldKernels: Set<String> = ["arith", "fib", "sends", "alloc"]

/// experiments/ directory, derived from this file's path.
public let experimentsDir: String = {
    let parts = #filePath.split(separator: "/", omittingEmptySubsequences: false)
    return parts.dropLast(5).joined(separator: "/")
}()
public let oldKernelsDir = experimentsDir + "/vm-language-bench/kernels"
public let newKernelsDir = experimentsDir + "/ui-thread-scheduling/kernels"

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

/// Prelude (vm-language-bench) then this experiment's lib.kasm.
public func baseSources() throws -> [String] {
    try ["\(oldKernelsDir)/prelude.kasm", "\(newKernelsDir)/lib.kasm"].map(readTextFile)
}

/// Sources for a benchmark kernel: base, then the kernel file.
public func kernelSources(_ kernel: String) throws -> [String] {
    guard oldKernels.contains(kernel) else { throw KasmError("unknown kernel \(kernel)") }
    return try baseSources() + [try readTextFile("\(oldKernelsDir)/\(kernel).kasm")]
}

/// Sources for the app: base, alloc.kasm (S4 runs its tree builder), ui.kasm.
public func appSources() throws -> [String] {
    try baseSources() + [try readTextFile("\(oldKernelsDir)/alloc.kasm"),
                         try readTextFile("\(newKernelsDir)/ui.kasm")]
}
