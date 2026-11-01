// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "kajo",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "KajoVM", targets: ["KajoVM"]),
        .executable(name: "kajo", targets: ["kajo"]),
    ],
    targets: [
        // The VM core: object memory, GC, interpreter, scheduler.
        // This is the trusted computing base. Strict memory safety is on so
        // every unsafe construct is labelled and greppable.
        .target(
            name: "KajoVM",
            swiftSettings: [.strictMemorySafety()]
        ),
        // Headless command line: boot an image, run tests, serve the
        // development protocol. No UI here.
        .executableTarget(
            name: "kajo",
            dependencies: ["KajoVM"]
        ),
        .testTarget(
            name: "KajoVMTests",
            dependencies: ["KajoVM"]
        ),
    ]
)
