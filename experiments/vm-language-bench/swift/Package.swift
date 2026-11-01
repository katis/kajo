// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "kajo-bench",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "KajoVM"),
        .executableTarget(name: "kajo-bench", dependencies: ["KajoVM"]),
        .testTarget(name: "KajoVMTests", dependencies: ["KajoVM"]),
    ]
)
