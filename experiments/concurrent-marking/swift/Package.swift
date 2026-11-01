// swift-tools-version: 6.0
import PackageDescription

// Concurrent-marking experiment: ../generational-gc/swift copied and
// extended with SATB concurrent marking and lazy sweeping of old space. See
// ../SPEC.md "Package shape".
//
// `-Xswiftc -DNO_MARK_BARRIER` removes the SATB barrier (stop-the-world
// collection only). `-Xswiftc -DNO_BARRIER` and `-DNO_BUDGET` as before.
let package = Package(
    name: "concurrent-marking",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "Kasm"),
        .target(name: "VMC", dependencies: ["Kasm"]),
        .executableTarget(name: "cm-bench", dependencies: ["VMC", "Kasm"]),
        .executableTarget(name: "kajo-ui", dependencies: ["VMC", "Kasm"]),
        .testTarget(name: "VMCTests", dependencies: ["VMC", "Kasm"]),
    ]
)
