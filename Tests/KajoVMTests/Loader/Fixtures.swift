import Foundation

/// Tests/KajoVMTests/Fixtures, found from this file's path (experiments are
/// deletable, so fixtures are copies kept here).
let fixturesDir: String = {
    let parts = #filePath.split(separator: "/", omittingEmptySubsequences: false)
    return parts.dropLast(2).joined(separator: "/") + "/Fixtures"
}()

func fixture(_ path: String) -> String {
    let url = URL(fileURLWithPath: "\(fixturesDir)/\(path)")
    guard let s = try? String(contentsOf: url, encoding: .utf8) else { fatalError("missing fixture \(path)") }
    return s
}

func kernel(_ name: String) -> String { fixture("kernels/\(name).kasm") }

/// The benchmark kernels and their single-worker checksums, as published in
/// experiments/vm-language-bench/RESULTS.md (arith, fib, sends, alloc) and
/// experiments/object-representation/RESULTS.md (ivars, walk).
let goldenKernels: [(name: String, checksum: Int64)] = [
    ("arith", 372_800_000),
    ("fib", 24_682_992),
    ("sends", 1_066_666_666_666_668),
    ("alloc", 41_950_911),
    ("ivars", 36_383_626),
    ("walk", 9_016_009_025_388_544),
]

/// The sources a kernel is loaded with: the prelude, object-representation's
/// lib, then the kernel.
func kernelSources(_ name: String) -> [(file: String, text: String)] {
    [("prelude.kasm", kernel("prelude")), ("lib.kasm", kernel("lib")), ("\(name).kasm", kernel(name))]
}
