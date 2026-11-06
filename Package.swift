// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "kajo",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "KajoVM", targets: ["KajoVM"]),
        .library(name: "KajoCompiler", targets: ["KajoCompiler"]),
        .library(name: "KajoShellCore", targets: ["KajoShellCore"]),
        // Module 11a: what a generated app links. KajoApp is the runtime and
        // the AppKit and UIKit hosts (one product, each half compiled for its
        // platform); KajoAppDevelopment is a Debug build's serving half.
        .library(name: "KajoApp", targets: ["KajoApp"]),
        .library(name: "KajoAppDevelopment", targets: ["KajoAppDevelopment"]),
        .library(name: "KajoGenerator", targets: ["KajoGenerator"]),
        .library(name: "KajoDev", targets: ["KajoDev"]),
        .executable(name: "kajo", targets: ["kajo"]),
    ],
    // Module 11a: a generated app's pinned dependency enables KajoAppBuild:
    // Xcode builds every package in its Debug configuration unoptimized and
    // with DEBUG (a checked build: every verifier at every pause), whatever
    // the app's settings say. Under this trait the VM is optimized (-O, file
    // by file: Xcode's index-while-building refuses whole-module flags) and
    // unchecked in Debug too. The repository's own builds never enable it.
    traits: [.trait(name: "KajoAppBuild")],
    targets: [
        // The VM core: object memory, GC, interpreter, scheduler.
        // This is the trusted computing base. Strict memory safety is on so
        // every unsafe construct is labelled and greppable.
        .target(
            name: "KajoVM",
            swiftSettings: [.strictMemorySafety(), .unsafeFlags(["-O"], .when(configuration: .debug, traits: ["KajoAppBuild"]))]
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
        // Module 11a: the runtime over the host surface and the AppKit and
        // UIKit view hosts (moved from apps/), and the entry a generated
        // app's Swift calls. No measurement, no compiler, no protocol.
        .target(
            name: "KajoApp",
            dependencies: ["KajoVM"],
            swiftSettings: [.strictMemorySafety()]
        ),
        // Module 11a: a development build's half: serving the development
        // protocol (9b's socket, 9d's TCP and Bonjour), the pairing screens,
        // the token store, the client transport's attachment.
        .target(
            name: "KajoAppDevelopment",
            dependencies: ["KajoApp", "KajoDev", "KajoVM"],
            swiftSettings: [.strictMemorySafety()]
        ),
        // Module 11a: `kajo new`, the app project generator (a library so
        // the Mac app's wizard can call it). Foundation only.
        .target(
            name: "KajoGenerator",
            swiftSettings: [.strictMemorySafety()]
        ),
        // Module 9a: the Swift both native shells share (apps/): launch
        // options, output, device telemetry, the modes (tests, golden,
        // scenario, demo, dev, devsession, serve) over KajoApp's runtime.
        .target(
            name: "KajoShellCore",
            dependencies: ["KajoApp", "KajoAppDevelopment", "KajoVM", "KajoCompiler", "KajoDev"],
            swiftSettings: [.strictMemorySafety()]
        ),
        // Module 9b: the development protocol outside the VM: its JSON and
        // request checks (the target's trust boundary), the Unix-socket
        // transport a target opens, the client, the MCP server and the CLI
        // commands over it. Ordinary Swift, not a hot path.
        .target(
            name: "KajoDev",
            dependencies: ["KajoVM"],
            swiftSettings: [.strictMemorySafety()]
        ),
        // Headless command line: boot an image, run tests, serve the
        // development protocol. No UI here.
        .executableTarget(
            name: "kajo",
            dependencies: ["KajoVM", "KajoCompiler", "KajoDev", "KajoGenerator"]
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
        // Module 9b: the development protocol's request parser and JSON.
        .executableTarget(
            name: "fuzz-protocol",
            dependencies: ["KajoVM", "KajoDev"],
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
            dependencies: ["KajoVM", "KajoCompiler", "KajoShellCore", "KajoDev", "KajoApp", "KajoAppDevelopment", "KajoGenerator"],
            exclude: ["Fixtures"]
        ),
    ]
)
