// swift-tools-version: 6.0
import PackageDescription

// Three object-representation variants built from one interpreter source.
// `shared/` is symlinked into each VM module; VMC is VMA's sources with
// OOP_OFFSET. See ../SPEC.md "Package shape".
let package = Package(
    name: "object-representation",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "Kasm"),
        .target(name: "VMA", dependencies: ["Kasm"],
                swiftSettings: [.define("FORWARDERS")]),
        .target(name: "VMC", dependencies: ["Kasm"],
                swiftSettings: [.define("FORWARDERS"), .define("OOP_OFFSET")]),
        .executableTarget(name: "orep-bench", dependencies: ["VMA", "VMC"]),
        .testTarget(name: "VMATests", dependencies: ["VMA", "Kasm"],
                    swiftSettings: [.define("VARIANT_A"), .define("FORWARDERS")]),
        .testTarget(name: "VMCTests", dependencies: ["VMC", "Kasm"],
                    swiftSettings: [.define("VARIANT_C"), .define("FORWARDERS"), .define("OOP_OFFSET")]),
    ]
)
