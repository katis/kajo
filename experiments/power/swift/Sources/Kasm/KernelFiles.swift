// Kernel file lookup for the power app and tests. A recorded copy of
// ../../../../device-measurement/swift/Sources/Kasm/KernelFiles.swift (the
// union of object-representation's and concurrent-young's lookups, with
// `experimentsDir` a variable and `kernelFlavor` picking which lookup runs).
//
// Changes against device-measurement's copy, and nothing else:
// - `experimentsDir` defaults to the repository's experiments/ directory
//   derived from #filePath (as the originals do), so `swift test` on the Mac
//   finds the kernels; the app sets it to the bundled copy.
// - The object-representation flavor is entry-locality's lookup
//   (../../../../entry-locality/swift/Sources/Kasm/KernelFiles.swift): sized
//   walk kernels walkN / walkbuildN over entry-locality/kernels (el-lib.kasm,
//   walksize.kasm), plus one addition: `walkNxR` = walkN with R traversals
//   instead of 2 (SPEC.md "Part 1"), so a launch spends most of its time in
//   the traversal.
// - `powerSources()`: the power scenario's sources (concurrent-young's base,
//   oldheap.kasm, power.kasm; SPEC.md "Part 2").

import Darwin

public enum KernelFlavor: Sendable { case objectRepresentation, concurrentYoung }

nonisolated(unsafe) public var experimentsDir: String = {
    let parts = #filePath.split(separator: "/", omittingEmptySubsequences: false)
    return parts.dropLast(5).joined(separator: "/")
}()
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

// MARK: - object-representation flavor (entry-locality's sized walks)

public let oldKernels: Set<String> = ["arith", "fib", "sends", "alloc"]
public let opKernels: Set<String> = ["become", "reshape", "compact", "snapshot"]
public let allKernels = ["arith", "fib", "sends", "alloc", "ivars", "walk", "walkbuild",
                         "become", "reshape", "compact", "snapshot"]
public var oldKernelsDir: String { experimentsDir + "/vm-language-bench/kernels" }
public var newKernelsDir: String { experimentsDir + "/entry-locality/kernels" }

/// A sized walk kernel: (template file, log2 nodes, traversals). `walkNxR`
/// is walkN with R traversals (power addition).
public func sizedWalk(_ kernel: String) -> (String, Int, Int)? {
    for (prefix, file, reps) in [("walkcompactbuild", "walkcompact", 0), ("walkcompact", "walkcompact", 2),
                                 ("walkbuild", "walksize", 0), ("walkmark", "walkmark", 0), ("walk", "walksize", 2)] {
        guard kernel.hasPrefix(prefix) else { continue }
        let rest = kernel.dropFirst(prefix.count)
        let parts = rest.split(separator: "x", omittingEmptySubsequences: false)
        if let n = Int(parts[0]), n >= 4, n <= 26 {
            if parts.count == 1 { return (file, n, reps) }
            if parts.count == 2, prefix == "walk", let r = Int(parts[1]), r >= 1 { return (file, n, r) }
        }
    }
    return nil
}

func constMethod(_ sel: String, _ v: Int) -> String {
    "method UndefinedObject \(sel) temps=0\n  push_lit \(v)\n  return_top\nend\n"
}

/// Source files for a kernel, in load order: old prelude, lib, kernel.
func orepKernelSources(_ kernel: String) throws -> [String] {
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

// MARK: - power

public var powerKernelsDir: String { experimentsDir + "/power/kernels" }

/// The power scenario (SPEC.md "Part 2"): concurrent-young's base sources,
/// concurrent-marking's oldheap.kasm (the old heap, `oldheapMB` live MiB,
/// a group replaced every `replaceEvery` mutation iterations) and power.kasm.
public func powerSources(oldheapMB mb: Int, replaceEvery: Int = 4096) throws -> [String] {
    try baseSources() + [try readTextFile("\(cmKernelsDir)/oldheap.kasm"), oldheapSizeSource(mb, replaceEvery: replaceEvery),
                         try readTextFile("\(powerKernelsDir)/power.kasm")]
}
