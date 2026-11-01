// Kernel file lookup. Kernels of earlier experiments are read in place (not
// copied): arith, fib, sends, alloc and the prelude from vm-language-bench,
// ivars from object-representation, lib.kasm and ui.kasm from
// ui-thread-scheduling, churn/survivors/gclib/gcui from generational-gc.
// oldheap.kasm from concurrent-marking. This experiment's own .kasm files
// (fragment, storeheavy) live in ../../kernels.

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
public let cmKernelsDir = experimentsDir + "/concurrent-marking/kernels"
public let crKernelsDir = experimentsDir + "/concurrent-relocation/kernels"

public let kernelNames = ["arith", "fib", "sends", "ivars", "storeheavy", "alloc", "churn", "survivors5", "survivors30",
                          "oldheap64", "oldheap256", "oldheap512", "fragment"]

/// oldheap.kasm's parameters: live MiB, total mutation iterations (MB *
/// 250 000), and the replacement interval (SPEC.md "Kernels").
public func oldheapSizeSource(_ mb: Int, replaceEvery: Int = 4096) -> String {
    func m(_ sel: String, _ v: Int) -> String { "method UndefinedObject \(sel) temps=0\n  push_lit \(v)\n  return_top\nend\n" }
    return m("oldheapMB", mb) + m("oldheapIters", mb * 250_000) + m("oldheapReplaceEvery", replaceEvery)
}

/// Live MiB of an `oldheapN` kernel name, else nil.
public func oldheapMB(_ kernel: String) -> Int? {
    kernel.hasPrefix("oldheap") ? Int(kernel.dropFirst("oldheap".count)) : nil
}

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
    case "storeheavy": file = [try readTextFile("\(crKernelsDir)/storeheavy.kasm")]
    case let k where k.hasPrefix("fragment"):
        // fragment (2 000 000 iterations) or fragmentN (N iterations).
        let iters = k == "fragment" ? 2_000_000 : Int(k.dropFirst("fragment".count)) ?? 0
        if iters <= 0 { throw KasmError("bad kernel \(k)") }
        file = [try readTextFile("\(crKernelsDir)/fragment.kasm"),
                "method UndefinedObject fragmentIters temps=0\n  push_lit \(iters)\n  return_top\nend\n"]
    case let k where k.hasPrefix("survivors"):
        guard let p = Int(k.dropFirst("survivors".count)), p >= 0, p <= 100 else { throw KasmError("bad kernel \(k)") }
        file = [try readTextFile("\(ggcKernelsDir)/survivors.kasm"), survivalPercentSource(p)]
    case let k where k.hasPrefix("oldheap"):
        guard let mb = oldheapMB(k), mb > 0 else { throw KasmError("bad kernel \(k)") }
        file = [try readTextFile("\(cmKernelsDir)/oldheap.kasm"), oldheapSizeSource(mb)]
    default: throw KasmError("unknown kernel \(kernel)")
    }
    return try baseSources() + file
}

/// Sources for the app: base, alloc.kasm (G1, G2, G4, G5 run its tree
/// builder), ui.kasm, gcui.kasm; with `survivors` (G3) survivors.kasm, whose
/// run:of: replaces alloc's, and survivalPercent.
public func appSources(survivors: Int? = nil, oldheap: Int? = nil, fragment: Bool = false) throws -> [String] {
    var s = try baseSources() + [try readTextFile("\(langKernelsDir)/alloc.kasm"),
                                 try readTextFile("\(utsKernelsDir)/ui.kasm"),
                                 try readTextFile("\(ggcKernelsDir)/gcui.kasm")]
    if let p = survivors {
        s += [try readTextFile("\(ggcKernelsDir)/survivors.kasm"), survivalPercentSource(p)]
    }
    if let mb = oldheap {
        s += [try readTextFile("\(cmKernelsDir)/oldheap.kasm"), oldheapSizeSource(mb, replaceEvery: 32768)]
    }
    if fragment {
        s += [try readTextFile("\(crKernelsDir)/fragment.kasm"),
              "method UndefinedObject fragmentIters temps=0\n  push_lit 2000000\n  return_top\nend\n"]
    }
    return s
}
