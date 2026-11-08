import Foundation

// Module 11a (docs/modules/app-project.md, part 2): `kajo new`, the app
// project generator; module 11b (docs/modules/distribution.md) points it at
// a distribution checkout's prebuilt Kajo and gives it the wizard's target
// choice. A library so that the Kajo app's File > New App... calls it; the
// CLI is the other caller. It takes a developer's input, so every check is
// a refusal (a value), never a trap, and its output for a given input is
// the same bytes every time (no dates, no machine names).
//
// The project it writes:
//
//   <Name>/project.yml        xcodegen: <Name>-macOS and/or <Name>-iOS over
//                             one Tonel directory, Debug and Release, and the
//                             one local package: the checkout's Prebuilt/
//   <Name>/Sources/App.swift  the few lines both targets run
//   <Name>/Info-*.plist       per platform and configuration: only Debug
//                             names the Bonjour service and the local network
//   <Name>/src/               the Tonel package: the app class and its test
//   <Name>/scripts/build-images.sh  the build phase: the image of the
//                             configuration with the checkout's prebuilt kajo
//   <Name>/.gitignore, README.md

/// Where the generated project's Kajo comes from: a distribution checkout
/// on this machine (the Kajo app copies its own to Application Support;
/// `scripts/dist.sh` makes one), whose `Prebuilt/` holds the Release
/// frameworks of every module an app links and the Release `kajo`. Module
/// 11a's source pin (the package by path or by URL with the KajoAppBuild
/// trait) is gone with the trait: a Debug build links the same prebuilt
/// Release VM as a Release build.
public enum KajoSource: Sendable, Equatable {
    /// The checkout's root (it holds `kernel/` and `Prebuilt/`).
    case path(String)
}

/// The platforms a project has a target for (the wizard's checkboxes).
public enum AppPlatform: String, Sendable, Equatable, CaseIterable, Comparable {
    case macOS
    case iOS

    public static func < (a: AppPlatform, b: AppPlatform) -> Bool { a.rawValue < b.rawValue }
}

/// What `kajo new` is asked for.
public struct AppProjectSpec: Sendable, Equatable {
    /// The app's name: its class prefix in Smalltalk, its Swift module and
    /// target names, its package and its directory.
    public var name: String
    public var bundleIdentifier: String
    /// The development team, or nil to leave signing to Xcode's settings.
    public var team: String?
    public var kajo: KajoSource
    /// The targets: a Mac app, an iPhone and iPad app, or both (the default).
    public var platforms: [AppPlatform]

    public init(name: String, bundleIdentifier: String, team: String? = nil, kajo: KajoSource,
                platforms: [AppPlatform] = AppPlatform.allCases) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.team = team
        self.kajo = kajo
        self.platforms = platforms
    }

    func has(_ p: AppPlatform) -> Bool { platforms.contains(p) }
}

/// Why the generator refuses. Each is a value the caller shows.
public enum GeneratorRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidName(String, String)
    case reservedName(String)
    case invalidBundleIdentifier(String, String)
    case invalidTeam(String)
    case invalidKajoSource(String)
    case noTargets
    case notACheckout(String)
    case directoryNotEmpty(String)
    case pathEscapes(String)
    case cannotWrite(String)

    public var description: String {
        switch self {
        case .invalidName(let n, let why): "not a name for an app: \(n.debugDescription) (\(why))"
        case .reservedName(let n): "the name \(n.debugDescription) is taken (a module or package Kajo apps already use)"
        case .invalidBundleIdentifier(let b, let why): "not a bundle identifier: \(b.debugDescription) (\(why))"
        case .invalidTeam(let t): "not a development team: \(t.debugDescription) (ten capital letters and digits)"
        case .invalidKajoSource(let why): "not a place Kajo comes from: \(why)"
        case .noTargets: "an app needs a target: the Mac, iPhone and iPad, or both"
        case .notACheckout(let p): "not a Kajo checkout with a prebuilt Kajo (no Prebuilt/Package.swift and Prebuilt/bin/kajo): \(p)"
        case .directoryNotEmpty(let d): "the directory exists and is not empty: \(d)"
        case .pathEscapes(let p): "the path leaves the directory it is relative to: \(p)"
        case .cannotWrite(let why): "cannot write the project: \(why)"
        }
    }
}

/// One file of the project: its path inside the project directory, its
/// text, whether it is a script.
public struct GeneratedFile: Sendable, Equatable {
    public let path: String
    public let text: String
    public let executable: Bool
}

public enum AppProjectGenerator {
    /// Names a generated app may not take: the modules every app imports,
    /// the platform's, and the packages a development image holds.
    static let reserved: Set<String> = ["Swift", "Foundation", "Dispatch", "Darwin", "AppKit", "UIKit", "QuartzCore",
                                        "Combine", "SwiftUI", "Testing", "XCTest", "Kernel", "Tools", "Main", "Self", "Any", "Type",
                                        "Protocol", "Object", "Smalltalk"]

    /// The name rule: a capital letter, then letters and digits, 2 to 30
    /// characters, so that it is a Smalltalk class prefix, a Swift module,
    /// an Xcode target and a bundle identifier component as it is.
    public static func checkName(_ name: String) -> GeneratorRefusal? {
        let u = Array(name.unicodeScalars)
        guard (2...30).contains(u.count) else { return .invalidName(name, "2 to 30 characters") }
        guard ("A"..."Z").contains(u[0]) else { return .invalidName(name, "it starts with a capital letter A to Z") }
        for c in u.dropFirst() where !(("A"..."Z").contains(c) || ("a"..."z").contains(c) || ("0"..."9").contains(c)) {
            return .invalidName(name, "letters A to Z and digits only")
        }
        if reserved.contains(name) || name.hasPrefix("Kajo") { return .reservedName(name) }
        return nil
    }

    /// Reverse DNS: two or more components of letters, digits and hyphens,
    /// none empty or starting with a hyphen, at most 155 characters.
    public static func checkBundleIdentifier(_ b: String) -> GeneratorRefusal? {
        guard !b.isEmpty, b.utf8.count <= 155 else { return .invalidBundleIdentifier(b, "1 to 155 characters") }
        let parts = b.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return .invalidBundleIdentifier(b, "two components or more, reverse DNS") }
        for p in parts {
            guard !p.isEmpty else { return .invalidBundleIdentifier(b, "an empty component") }
            guard p.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }) else {
                return .invalidBundleIdentifier(b, "letters A to Z, digits, hyphens and dots only")
            }
            guard !p.hasPrefix("-") else { return .invalidBundleIdentifier(b, "a component starts with a hyphen") }
        }
        return nil
    }

    public static func checkTeam(_ t: String) -> GeneratorRefusal? {
        let u = Array(t.unicodeScalars)
        guard u.count == 10, u.allSatisfy({ ("A"..."Z").contains($0) || ("0"..."9").contains($0) }) else { return .invalidTeam(t) }
        return nil
    }

    /// A path that lands in the project spec and the build script as
    /// written: absolute, naming a directory, and without quotes,
    /// backslashes, dollars, backticks or control characters.
    public static func checkKajo(_ k: KajoSource) -> GeneratorRefusal? {
        switch k {
        case .path(let p):
            guard !p.isEmpty, p.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 && !"\"'\\$`".unicodeScalars.contains($0) }) else {
                return .invalidKajoSource("a path without quotes, backslashes, dollars or control characters")
            }
            guard p.hasPrefix("/") else { return .invalidKajoSource("an absolute path to a Kajo checkout") }
            let last = p.split(separator: "/").last.map(String.init) ?? ""
            guard !last.isEmpty, last != ".", last != ".." else { return .invalidKajoSource("the path names no directory") }
        }
        return nil
    }

    /// The checkout on disk has what a generated project uses: the
    /// prebuilt package and `kajo`, and the kernel's sources. Not part of
    /// `files(for:)`, which stays a function of its input; `kajo new` and
    /// the wizard ask it before writing.
    public static func checkCheckout(_ k: KajoSource) -> GeneratorRefusal? {
        if let r = checkKajo(k) { return r }
        switch k {
        case .path(let p):
            let fm = FileManager.default
            guard fm.fileExists(atPath: p + "/Prebuilt/Package.swift"), fm.isExecutableFile(atPath: p + "/Prebuilt/bin/kajo"),
                  fm.fileExists(atPath: p + "/kernel") else { return .notACheckout(p) }
        }
        return nil
    }

    /// Every check, in the order a developer would fix them.
    public static func check(_ spec: AppProjectSpec) -> GeneratorRefusal? {
        if let r = checkName(spec.name) { return r }
        if let r = checkBundleIdentifier(spec.bundleIdentifier) { return r }
        if let t = spec.team, let r = checkTeam(t) { return r }
        if spec.platforms.isEmpty { return .noTargets }
        return checkKajo(spec.kajo)
    }

    /// The project's files, in path order, or the refusal.
    public static func files(for spec: AppProjectSpec) -> Result<[GeneratedFile], GeneratorRefusal> {
        if let r = check(spec) { return .failure(r) }
        let t = Templates(spec)
        var out = [GeneratedFile(path: ".gitignore", text: t.gitignore, executable: false)]
        if spec.has(.iOS) {
            out.append(GeneratedFile(path: "Info-iOS-Debug.plist", text: t.iosPlist(debug: true), executable: false))
            out.append(GeneratedFile(path: "Info-iOS-Release.plist", text: t.iosPlist(debug: false), executable: false))
        }
        if spec.has(.macOS) {
            out.append(GeneratedFile(path: "Info-macOS-Debug.plist", text: t.macPlist(debug: true), executable: false))
            out.append(GeneratedFile(path: "Info-macOS-Release.plist", text: t.macPlist(debug: false), executable: false))
        }
        out += [
            GeneratedFile(path: "README.md", text: t.readme, executable: false),
            GeneratedFile(path: "Sources/App.swift", text: t.mainSwift, executable: false),
            GeneratedFile(path: "project.yml", text: t.projectYML, executable: false),
            GeneratedFile(path: "scripts/build-images.sh", text: t.buildImages, executable: true),
            GeneratedFile(path: "src/\(spec.name)App.class.st", text: t.appClass, executable: false),
            GeneratedFile(path: "src/\(spec.name)AppTest.class.st", text: t.appTest, executable: false),
            GeneratedFile(path: "src/package.st", text: t.packageST, executable: false),
        ]
        return .success(out)
    }

    /// The directory a relative `path` names under `base`, or the refusal
    /// when it has a `..` component (it could leave `base`). An absolute
    /// path is taken as it is.
    public static func resolve(_ path: String, base: String) -> Result<String, GeneratorRefusal> {
        guard !path.isEmpty, !path.unicodeScalars.contains(where: { $0.value < 32 }) else { return .failure(.pathEscapes(path)) }
        let comps = path.split(separator: "/")
        if path.hasPrefix("/") {
            guard !comps.contains("..") else { return .failure(.pathEscapes(path)) }
            return .success(path)
        }
        guard !comps.contains("..") else { return .failure(.pathEscapes(path)) }
        return .success((base as NSString).appendingPathComponent(comps.filter { $0 != "." }.joined(separator: "/")))
    }

    /// Write the project into `directory` (made if it is not there; refused
    /// if it is there and holds anything, or is a symbolic link). Answers the
    /// files written.
    public static func write(_ spec: AppProjectSpec, into directory: String) -> Result<[String], GeneratorRefusal> {
        let files: [GeneratedFile]
        switch self.files(for: spec) {
        case .success(let f): files = f
        case .failure(let r): return .failure(r)
        }
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: directory) {
            if attrs[.type] as? FileAttributeType == .typeSymbolicLink { return .failure(.pathEscapes(directory)) }
            guard attrs[.type] as? FileAttributeType == .typeDirectory else { return .failure(.directoryNotEmpty(directory)) }
            guard (try? fm.contentsOfDirectory(atPath: directory))?.isEmpty ?? false else { return .failure(.directoryNotEmpty(directory)) }
        }
        var written: [String] = []
        do {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for f in files {
                let p = (directory as NSString).appendingPathComponent(f.path)
                try fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try Data(f.text.utf8).write(to: URL(fileURLWithPath: p), options: .withoutOverwriting)
                if f.executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p) }
                written.append(f.path)
            }
        } catch {
            return .failure(.cannotWrite("\(error.localizedDescription)"))
        }
        return .success(written)
    }

    /// Where xcodegen is: the one the Kajo app carries (`Contents/Helpers/
    /// xcodegen/bin/xcodegen`, so a developer needs nothing beyond Xcode),
    /// then PATH and Homebrew's places.
    public static func findXcodegen(bundled: String? = nil) -> String? {
        let fm = FileManager.default
        if let b = bundled, fm.isExecutableFile(atPath: b) { return b }
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":") + ["/opt/homebrew/bin", "/usr/local/bin"]
        return paths.map({ "\($0)/xcodegen" }).first(where: { fm.isExecutableFile(atPath: $0) })
    }

    /// `xcodegen generate` in the project directory: true when it made the
    /// Xcode project, false when there is no xcodegen (the README says how
    /// to make it later).
    public static func generateXcodeProject(in directory: String, xcodegen: String? = nil) throws -> Bool {
        guard let tool = findXcodegen(bundled: xcodegen) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["generate", "--spec", (directory as NSString).appendingPathComponent("project.yml"), "--quiet"]
        p.currentDirectoryURL = URL(fileURLWithPath: directory)
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw GeneratorRefusal.cannotWrite("xcodegen exited with \(p.terminationStatus)") }
        return true
    }
}
