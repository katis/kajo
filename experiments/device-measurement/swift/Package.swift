// swift-tools-version: 6.0
import PackageDescription

// The VMs of ../../object-representation (VMA, VMB, VMC) and
// ../../concurrent-young (VMR, and VMRNB = VMR built with -DNO_YOUNG_BARRIER,
// the `adr7` reference) for the device app. Every source file is a symlink to
// the original, except Sources/Kasm/KernelFiles.swift (see its header and
// ../RESULTS.md "What had to change"). Kasm.swift is identical in both
// experiments, so one Kasm module serves all five VMs.
let package = Package(
    name: "device-vms",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "DeviceVMs", targets: ["Kasm", "VMA", "VMB", "VMC", "VMR", "VMRNB"]),
    ],
    targets: [
        .target(name: "Kasm"),
        .target(name: "VMA", dependencies: ["Kasm"], swiftSettings: [.define("FORWARDERS")]),
        .target(name: "VMC", dependencies: ["Kasm"], swiftSettings: [.define("FORWARDERS"), .define("OOP_OFFSET")]),
        .target(name: "VMB", dependencies: ["Kasm"]),
        .target(name: "VMR", dependencies: ["Kasm"]),
        .target(name: "VMRNB", dependencies: ["Kasm"], swiftSettings: [.define("NO_YOUNG_BARRIER")]),
    ]
)
