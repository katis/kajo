// Kernel file lookup. Kernels of earlier experiments are read in place (not
// copied): arith, fib, sends, alloc and the prelude from vm-language-bench,
// ivars from object-representation, lib.kasm and ui.kasm from
// ui-thread-scheduling. This experiment's own .kasm files live in ../../kernels.

import Darwin

/// experiments/ directory, derived from this file's path.
public let experimentsDir: String = {
    let parts = #filePath.split(separator: "/", omittingEmptySubsequences: false)
    return parts.dropLast(5).joined(separator: "/")
}()
public let langKernelsDir = experimentsDir + "/vm-language-bench/kernels"
public let orepKernelsDir = experimentsDir + "/object-representation/kernels"
public let utsKernelsDir = experimentsDir + "/ui-thread-scheduling/kernels"
public let ggcKernelsDir = experimentsDir + "/generational-gc/kernels"

public let kernelNames = ["arith", "fib", "sends", "ivars", "alloc", "churn", "survivors5", "survivors30"]

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

/// Prelude, ui-thread-scheduling's lib.kasm, this experiment's gclib.kasm.
public func baseSources() throws -> [String] {
    try ["\(langKernelsDir)/prelude.kasm", "\(utsKernelsDir)/lib.kasm", "\(ggcKernelsDir)/gclib.kasm"].map(readTextFile)
}

/// `UndefinedObject survivalPercent` answering `p` (survivors.kasm reads it).
public func survivalPercentSource(_ p: Int) -> String {
    "method UndefinedObject survivalPercent temps=0\n  push_int \(p)\n  return_top\nend\n"
}

/// Sources for a benchmark kernel: base, then the kernel file(s).
public func kernelSources(_ kernel: String) throws -> [String] {
    let file: [String]
    switch kernel {
    case "arith", "fib", "sends", "alloc": file = [try readTextFile("\(langKernelsDir)/\(kernel).kasm")]
    case "ivars": file = [try readTextFile("\(orepKernelsDir)/ivars.kasm")]
    case "churn": file = [try readTextFile("\(ggcKernelsDir)/churn.kasm")]
    case let k where k.hasPrefix("survivors"):
        guard let p = Int(k.dropFirst("survivors".count)), p >= 0, p <= 100 else { throw KasmError("bad kernel \(k)") }
        file = [try readTextFile("\(ggcKernelsDir)/survivors.kasm"), survivalPercentSource(p)]
    default: throw KasmError("unknown kernel \(kernel)")
    }
    return try baseSources() + file
}

/// Sources for the app: base, alloc.kasm (G1, G2, G4, G5 run its tree
/// builder), ui.kasm, gcui.kasm; with `survivors` (G3) survivors.kasm, whose
/// run:of: replaces alloc's, and survivalPercent.
public func appSources(survivors: Int? = nil) throws -> [String] {
    var s = try baseSources() + [try readTextFile("\(langKernelsDir)/alloc.kasm"),
                                 try readTextFile("\(utsKernelsDir)/ui.kasm"),
                                 try readTextFile("\(ggcKernelsDir)/gcui.kasm")]
    if let p = survivors {
        s += [try readTextFile("\(ggcKernelsDir)/survivors.kasm"), survivalPercentSource(p)]
    }
    return s
}
