// swift-tools-version: 6.0
import PackageDescription

// Concurrent-relocation experiment: ../../concurrent-marking/swift copied and
// extended with an age field and survivor spaces in the nursery, and
// concurrent relocation (compaction) of old space by the marker thread. See
// ../SPEC.md "Package shape".
//
// `-Xswiftc -DNO_POST_STORE` compiles the post-store check out (relocation
// then unavailable). `-DNO_MARK_BARRIER`, `-DNO_BARRIER`, `-DNO_BUDGET` as
// before.
let package = Package(
    name: "concurrent-relocation",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "Kasm"),
        .target(name: "VMR", dependencies: ["Kasm"]),
        .executableTarget(name: "cr-bench", dependencies: ["VMR", "Kasm"]),
        .executableTarget(name: "kajo-ui", dependencies: ["VMR", "Kasm"]),
        .testTarget(name: "VMRTests", dependencies: ["VMR", "Kasm"]),
    ]
)
