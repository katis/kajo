// swift-tools-version: 6.2
import PackageDescription

// Model checks of the VM's concurrent protocols (docs/VERIFICATION.md layer
// 6). A separate package so that it never slows the VM's build; run with
// `cd models && swift test`. See docs/models/relocation.md and
// docs/models/young-collection.md.

// Optimized even in debug builds: the explorer spends its time copying and
// hashing small structs, which -Onone makes 4x slower
// (docs/models/relocation.md "Choices").
let optimized: [SwiftSetting] = [.unsafeFlags(["-O"], .when(configuration: .debug))]

let package = Package(
    name: "kajo-models",
    platforms: [.macOS(.v15)],
    targets: [
        // The shared memory model and explorer.
        .target(name: "ModelKit", swiftSettings: optimized),
        .target(name: "RelocationModel", dependencies: ["ModelKit"], swiftSettings: optimized),
        .target(name: "YoungCollectionModel", dependencies: ["ModelKit"], swiftSettings: optimized),
        .testTarget(name: "RelocationModelTests", dependencies: ["RelocationModel"]),
        .testTarget(name: "YoungCollectionModelTests", dependencies: ["YoungCollectionModel"]),
    ]
)
