// swift-tools-version: 6.0
import PackageDescription

// Generational-gc experiment: ../ui-thread-scheduling/swift copied and
// extended with per-worker nurseries, a parallel scavenge and a write
// barrier. See ../SPEC.md "Package shape".
//
// `-Xswiftc -DNO_BARRIER` removes the write barrier and forces the nursery
// size to 0 (non-generational). `-Xswiftc -DNO_BUDGET` as before.
let package = Package(
    name: "generational-gc",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "Kasm"),
        .target(name: "VMC", dependencies: ["Kasm"]),
        .executableTarget(name: "cm-bench", dependencies: ["VMC", "Kasm"]),
        .executableTarget(name: "kajo-ui", dependencies: ["VMC", "Kasm"]),
        .testTarget(name: "VMCTests", dependencies: ["VMC", "Kasm"]),
    ]
)
