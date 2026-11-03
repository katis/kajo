// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "kajo",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "KajoVM", targets: ["KajoVM"]),
        .library(name: "KajoCompiler", targets: ["KajoCompiler"]),
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
        // Module 8b: the bootstrap compiler (Smalltalk method syntax and
        // Tonel class files to bytecode set v1), the kernel image build.
        // Not the trusted base: everything it makes goes through the VM's
        // bytecode verifier. No unsafe code.
        .target(
            name: "KajoCompiler",
            dependencies: ["KajoVM"],
            swiftSettings: [.strictMemorySafety()]
        ),
        // Headless command line: boot an image, run tests, serve the
        // development protocol. No UI here.
        .executableTarget(
            name: "kajo",
            dependencies: ["KajoVM", "KajoCompiler"]
        ),
        // libFuzzer targets for the kasm and snapshot loaders (`just fuzz`).
        // Built plainly they replay a corpus and mutate it.
        .executableTarget(
            name: "fuzz-kasm",
            dependencies: ["KajoVM"],
            swiftSettings: [.strictMemorySafety()]
        ),
        .executableTarget(
            name: "fuzz-snapshot",
            dependencies: ["KajoVM"],
            swiftSettings: [.strictMemorySafety()]
        ),
        // Module 8b: the Smalltalk syntax (scanner, parser, compiler, Tonel).
        .executableTarget(
            name: "fuzz-syntax",
            dependencies: ["KajoVM", "KajoCompiler"],
            swiftSettings: [.strictMemorySafety()]
        ),
        .testTarget(
            name: "KajoVMTests",
            dependencies: ["KajoVM"],
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "KajoCompilerTests",
            dependencies: ["KajoVM", "KajoCompiler"],
            exclude: ["Fixtures"]
        ),
    ]
)
