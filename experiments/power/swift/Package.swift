// swift-tools-version: 6.0
import PackageDescription

// power: the energy experiment on device (../DESIGN.md, ../SPEC.md).
// - VMB: object-representation's object table variant, every file a symlink
//   to the original except Runner.swift, which is entry-locality's recorded
//   copy (workers at user-initiated QoS), as entry-locality ran it.
// - VMR: concurrent-young's object memory through device-measurement's
//   per-file symlinks (its Blocks.swift carries the vm_map change for iOS).
// - Kasm: Kasm.swift symlinked; KernelFiles.swift is a recorded copy (see its
//   header).
// - PowerC, PowerKit, PowerVM: this experiment's code.
// - VMRTests: concurrent-young's test files, symlinked, run against this
//   package's VMR.
let package = Package(
    name: "power",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "PowerAll", targets: ["Kasm", "VMB", "VMR", "PowerC", "PowerKit", "PowerVM"]),
    ],
    targets: [
        .target(name: "Kasm"),
        .target(name: "VMB", dependencies: ["Kasm"]),
        .target(name: "VMR", dependencies: ["Kasm"]),
        .target(name: "PowerC"),
        .target(name: "PowerKit", dependencies: ["PowerC"]),
        .target(name: "PowerVM", dependencies: ["VMR", "Kasm", "PowerKit"]),
        .testTarget(name: "PowerKitTests", dependencies: ["PowerKit"]),
        .testTarget(name: "PowerVMTests", dependencies: ["PowerVM", "VMR", "Kasm", "PowerKit", "VMB"]),
        .testTarget(name: "VMRTests", dependencies: ["VMR", "Kasm"]),
    ]
)
