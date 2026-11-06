import Foundation

// Module 11a (docs/modules/app-project.md, part 2): `kajo new`, the app
// project generator. A library so that the Mac app's wizard can call it
// later; the CLI is one caller. It takes a developer's input, so every
// check is a refusal (a value), never a trap, and its output for a given
// input is the same bytes every time (no dates, no machine names).
//
// The project it writes:
//
//   <Name>/project.yml        xcodegen: <Name>-macOS and <Name>-iOS over one
//                             Tonel directory, Debug and Release
//   <Name>/KajoPin/           the pinned Kajo (a path, or a URL and a
//                             revision) with the KajoAppBuild trait, and the
//                             two products the app imports
//   <Name>/Sources/App.swift  the few lines both targets run
//   <Name>/Info-*.plist       per platform and configuration: only Debug
//                             names the Bonjour service and the local network
//   <Name>/src/               the Tonel package: the app class and its test
//   <Name>/scripts/build-images.sh  the build phase: the image of the
//                             configuration with the pinned checkout's kajo
//   <Name>/.gitignore, README.md

/// Where the generated project's Kajo comes from.
public enum KajoSource: Sendable, Equatable {
    /// A Kajo checkout on this machine (the tests' and the gate's form).
    case path(String)
    /// A repository and a revision (the real form, once there is a
    /// repository to name; module 11a raises it as a question).
    case git(url: String, revision: String)
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

    public init(name: String, bundleIdentifier: String, team: String? = nil, kajo: KajoSource) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.team = team
        self.kajo = kajo
    }
}

/// Why the generator refuses. Each is a value the caller shows.
public enum GeneratorRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidName(String, String)
    case reservedName(String)
    case invalidBundleIdentifier(String, String)
    case invalidTeam(String)
    case invalidKajoSource(String)
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

    /// A path, URL or revision that lands in the package manifest and the
    /// build script as written: no quotes, backslashes, dollars, backticks
    /// or control characters, and the forms each takes.
    public static func checkKajo(_ k: KajoSource) -> GeneratorRefusal? {
        func plain(_ s: String) -> Bool {
            !s.isEmpty && s.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 && !"\"'\\$`".unicodeScalars.contains($0) }
        }
        switch k {
        case .path(let p):
            guard plain(p) else { return .invalidKajoSource("a path without quotes, backslashes, dollars or control characters") }
            guard p.hasPrefix("/") else { return .invalidKajoSource("an absolute path to a Kajo checkout") }
            guard packageIdentity(k) != nil else { return .invalidKajoSource("the path names no directory") }
        case .git(let url, let rev):
            guard plain(url), !url.contains(" ") else { return .invalidKajoSource("a URL without spaces, quotes or control characters") }
            guard url.hasPrefix("https://") || url.hasPrefix("ssh://") || url.hasPrefix("git@") else {
                return .invalidKajoSource("an https://, ssh:// or git@ URL")
            }
            guard packageIdentity(k) != nil else { return .invalidKajoSource("the URL names no repository") }
            guard (7...40).contains(rev.count), rev.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
                return .invalidKajoSource("a revision is 7 to 40 lowercase hexadecimal digits")
            }
        }
        return nil
    }

    /// SwiftPM's identity of the Kajo package: the last path component,
    /// lowercased, without `.git`.
    public static func packageIdentity(_ k: KajoSource) -> String? {
        let s: String
        switch k {
        case .path(let p): s = p
        case .git(let url, _): s = url
        }
        var last = String(s.split(whereSeparator: { $0 == "/" || $0 == ":" }).last ?? "")
        if last.hasSuffix(".git") { last.removeLast(4) }
        guard !last.isEmpty, last != ".", last != ".." else { return nil }
        return last.lowercased()
    }

    /// Every check, in the order a developer would fix them.
    public static func check(_ spec: AppProjectSpec) -> GeneratorRefusal? {
        if let r = checkName(spec.name) { return r }
        if let r = checkBundleIdentifier(spec.bundleIdentifier) { return r }
        if let t = spec.team, let r = checkTeam(t) { return r }
        return checkKajo(spec.kajo)
    }

    /// The project's files, in path order, or the refusal.
    public static func files(for spec: AppProjectSpec) -> Result<[GeneratedFile], GeneratorRefusal> {
        if let r = check(spec) { return .failure(r) }
        let t = Templates(spec)
        let out = [
            GeneratedFile(path: ".gitignore", text: t.gitignore, executable: false),
            GeneratedFile(path: "Info-iOS-Debug.plist", text: t.iosPlist(debug: true), executable: false),
            GeneratedFile(path: "Info-iOS-Release.plist", text: t.iosPlist(debug: false), executable: false),
            GeneratedFile(path: "Info-macOS-Debug.plist", text: t.macPlist(debug: true), executable: false),
            GeneratedFile(path: "Info-macOS-Release.plist", text: t.macPlist(debug: false), executable: false),
            GeneratedFile(path: "KajoPin/Package.swift", text: t.pinManifest, executable: false),
            GeneratedFile(path: "KajoPin/Sources/KajoPin/KajoPin.swift", text: t.pinSource, executable: false),
            GeneratedFile(path: "KajoPin/Sources/KajoPinDevelopment/KajoPinDevelopment.swift", text: t.pinDevelopmentSource, executable: false),
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

    /// `xcodegen generate` in the project directory when xcodegen is on
    /// PATH: true when it made the Xcode project, false when there is no
    /// xcodegen (the README says how to make it later).
    public static func generateXcodeProject(in directory: String) throws -> Bool {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":") + ["/opt/homebrew/bin", "/usr/local/bin"]
        guard let tool = paths.map({ "\($0)/xcodegen" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return false }
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
