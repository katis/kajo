// swift-tools-version: 6.0
import PackageDescription

// UI-thread scheduling experiment: variant B of ../object-representation
// extended with Processes, budgeted preemption, hop-to-main and external
// signals. See ../SPEC.md "Package shape".
//
// `-Xswiftc -DNO_BUDGET` removes the per-poll budget countdown (cost isolation).
let package = Package(
    name: "ui-thread-scheduling",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "Kasm"),
        .target(name: "VMP", dependencies: ["Kasm"]),
        .executableTarget(name: "uts-bench", dependencies: ["VMP", "Kasm"]),
        .executableTarget(name: "kajo-ui", dependencies: ["VMP", "Kasm"]),
        .testTarget(name: "VMPTests", dependencies: ["VMP", "Kasm"]),
    ]
)
