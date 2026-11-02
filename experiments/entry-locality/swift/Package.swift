// swift-tools-version: 6.0
import PackageDescription

// entry-locality: object memories A, B, C (per-file symlinks to
// ../../object-representation, unchanged), L (local entries, derived from
// B; the interpreter and VM files symlinked from object-representation's
// shared/), the Part 1 chase microbenchmark, and the bench CLIs. See
// ../SPEC.md "Package shape".
let package = Package(
    name: "entry-locality",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "ELVMs", targets: ["Kasm", "VMA", "VMB", "VMC", "VML", "MemChase"]),
    ],
    targets: [
        .target(name: "Kasm"),
        .target(name: "MemChase"),
        .target(name: "VMA", dependencies: ["Kasm"], swiftSettings: [.define("FORWARDERS")]),
        .target(name: "VMC", dependencies: ["Kasm"],
                swiftSettings: [.define("FORWARDERS"), .define("OOP_OFFSET")]),
        .target(name: "VMB", dependencies: ["Kasm"]),
        .target(name: "VML", dependencies: ["Kasm"]),
        .executableTarget(name: "chase-bench", dependencies: ["MemChase"]),
        .executableTarget(name: "el-bench", dependencies: ["VMA", "VMB", "VMC", "VML", "Kasm", "MemChase"]),
        .testTarget(name: "VMBTests", dependencies: ["VMB", "Kasm"],
                    swiftSettings: [.define("VARIANT_B")]),
        .testTarget(name: "VMLTests", dependencies: ["VML", "Kasm"],
                    swiftSettings: [.define("VARIANT_B"), .define("VARIANT_L")]),
    ]
)
