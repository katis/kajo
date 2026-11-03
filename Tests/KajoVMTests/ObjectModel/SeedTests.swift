import Testing
@testable import KajoVM

/// Every kasm fuzz seed loads (a seed that does not is a weak seed).
@Test(arguments: ["alloc", "arith", "edges", "fib", "ivars", "sends", "walk", "objectmodel", "v1"])
func kasmFuzzSeedsLoad(_ name: String) throws {
    let img = try makeImage()
    defer { img.destroy() }
    try img.load([(file: "\(name).kasm", text: fixture("fuzz/kasm/\(name).kasm"))])
}
