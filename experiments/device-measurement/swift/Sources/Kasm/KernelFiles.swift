// Kernel file lookup for the device app: the union of
// ../../object-representation/swift/Sources/Kasm/KernelFiles.swift and
// ../../concurrent-young/swift/Sources/Kasm/KernelFiles.swift, the only file
// of either package that does not run on iOS unchanged (both derive the
// kernel directory from #filePath, a path on the Mac).
//
// Changes against the originals, and nothing else:
// - `experimentsDir` is a variable the app sets to the bundled copy of the
//   kernels (`<bundle>/experiments/<experiment>/kernels/*.kasm`, copied by a
//   build phase, same relative layout as the repository).
// - The two packages' `kernelSources` and `readTextFile` share names but
//   not behaviour; `kernelFlavor` picks which one runs. The app sets it
//   once per launch before loading a kernel.
// - Directory constants are computed properties so they follow
//   `experimentsDir`.

import Darwin

public enum KernelFlavor: Sendable { case objectRepresentation, concurrentYoung }

nonisolated(unsafe) public var experimentsDir: String = "."
nonisolated(unsafe) public var kernelFlavor: KernelFlavor = .concurrentYoung

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

public func kernelSources(_ kernel: String) throws -> [String] {
    switch kernelFlavor {
    case .objectRepresentation: return try orepKernelSources(kernel)
    case .concurrentYoung: return try cyKernelSources(kernel)
    }
}

// MARK: - object-representation (verbatim but for the names above)

public let oldKernels: Set<String> = ["arith", "fib", "sends", "alloc"]
public let opKernels: Set<String> = ["become", "reshape", "compact", "snapshot"]
public let allKernels = ["arith", "fib", "sends", "alloc", "ivars", "walk", "walkbuild",
                         "become", "reshape", "compact", "snapshot"]
public var oldKernelsDir: String { experimentsDir + "/vm-language-bench/kernels" }
public var newKernelsDir: String { experimentsDir + "/object-representation/kernels" }

/// Source files for a kernel, in load order: old prelude, lib, kernel.
func orepKernelSources(_ kernel: String) throws -> [String] {
    let k = oldKernels.contains(kernel) ? "\(oldKernelsDir)/\(kernel).kasm" : "\(newKernelsDir)/\(kernel).kasm"
    return try ["\(oldKernelsDir)/prelude.kasm", "\(newKernelsDir)/lib.kasm", k].map(readTextFile)
}

/// Heap size per kernel (SPEC.md table).
public func heapSizeFor(_ kernel: String) -> Int {
    (oldKernels.contains(kernel) || kernel == "ivars") ? 64 << 20 : 1 << 30
}

// MARK: - concurrent-young (verbatim but for the names above)

public var langKernelsDir: String { experimentsDir + "/vm-language-bench/kernels" }
public var orepKernelsDir: String { experimentsDir + "/object-representation/kernels" }
public var utsKernelsDir: String { experimentsDir + "/ui-thread-scheduling/kernels" }
public var ggcKernelsDir: String { experimentsDir + "/generational-gc/kernels" }
public var cmKernelsDir: String { experimentsDir + "/concurrent-marking/kernels" }
public var crKernelsDir: String { experimentsDir + "/concurrent-relocation/kernels" }
public var cyKernelsDir: String { experimentsDir + "/concurrent-young/kernels" }

public let kernelNames = ["arith", "fib", "sends", "ivars", "storeheavy", "alloc", "churn", "survivors5", "survivors30",
                          "oldheap64", "oldheap256", "oldheap512", "fragment", "share"]

public func oldheapSizeSource(_ mb: Int, replaceEvery: Int = 4096) -> String {
    func m(_ sel: String, _ v: Int) -> String { "method UndefinedObject \(sel) temps=0\n  push_lit \(v)\n  return_top\nend\n" }
    return m("oldheapMB", mb) + m("oldheapIters", mb * 250_000) + m("oldheapReplaceEvery", replaceEvery)
}

public func oldheapMB(_ kernel: String) -> Int? {
    kernel.hasPrefix("oldheap") ? Int(kernel.dropFirst("oldheap".count)) : nil
}

public func baseSources() throws -> [String] {
    try ["\(langKernelsDir)/prelude.kasm", "\(utsKernelsDir)/lib.kasm", "\(ggcKernelsDir)/gclib.kasm"].map(readTextFile)
}

public func survivalPercentSource(_ p: Int) -> String {
    "method UndefinedObject survivalPercent temps=0\n  push_int \(p)\n  return_top\nend\n"
}

func cyKernelSources(_ kernel: String) throws -> [String] {
    let file: [String]
    switch kernel {
    case "arith", "fib", "sends", "alloc": file = [try readTextFile("\(langKernelsDir)/\(kernel).kasm")]
    case "ivars": file = [try readTextFile("\(orepKernelsDir)/ivars.kasm")]
    case "churn": file = [try readTextFile("\(ggcKernelsDir)/churn.kasm")]
    case "storeheavy": file = [try readTextFile("\(crKernelsDir)/storeheavy.kasm")]
    case "share": file = [try readTextFile("\(cyKernelsDir)/share.kasm")]
    case let k where k.hasPrefix("fragment"):
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

public func appSources(survivors: Int? = nil, oldheap: Int? = nil, fragment: Bool = false, share: Bool = false) throws -> [String] {
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
    if share { s += [try readTextFile("\(cyKernelsDir)/share.kasm")] }
    return s
}
