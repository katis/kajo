// swift-tools-version: 6.2
import PackageDescription

// Model checks of the VM's concurrent protocols (docs/VERIFICATION.md layer
// 6). A separate package so that it never slows the VM's build; run with
// `cd models && swift test`. See docs/models/relocation.md.
let package = Package(
    name: "kajo-models",
    platforms: [.macOS(.v15)],
    targets: [
        // Optimized even in debug builds: the explorer spends its time
        // copying and hashing small structs, which -Onone makes 4x slower
        // (docs/models/relocation.md "Choices").
        .target(
            name: "RelocationModel",
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
        .testTarget(name: "RelocationModelTests", dependencies: ["RelocationModel"]),
    ]
)
