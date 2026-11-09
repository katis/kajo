// Module 11a: the app project generator (docs/modules/app-project.md, part
// 2); since module 11b the prebuilt pin and the wizard's targets
// (docs/modules/distribution.md). Its output for a fixed input, byte for byte against the fixture
// project; every refusal and the name rules; writing into a directory; the
// generated Tonel compiles with the kernel and its test passes.

import Foundation
import Testing
@testable import KajoCompiler
@testable import KajoGenerator
@testable import KajoVM

let appProjectFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/app-project/Sample").path

let fixtureSpec = AppProjectSpec(name: "Sample", bundleIdentifier: "dev.katajamaki.kajo.sample", team: "BDN6M642M2",
                                 kajo: .path("/path/to/kajo"))

func generated(_ spec: AppProjectSpec) throws -> [GeneratedFile] {
    switch AppProjectGenerator.files(for: spec) {
    case .success(let f): return f
    case .failure(let r): throw r
    }
}

func scratchDirectory(_ tag: String) -> String {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("kajo-new-\(getpid())-\(tag)-\(UInt32.random(in: 0...UInt32.max))").path
    try? FileManager.default.removeItem(atPath: d)
    return d
}

@Suite struct AppProjectTests {
    @Test func theOutputForAFixedInputIsTheFixtureByteForByte() throws {
        let files = try generated(fixtureSpec)
        var onDisk: [String] = []
        let e = FileManager.default.enumerator(atPath: appProjectFixture)
        while let p = e?.nextObject() as? String {
            var dir: ObjCBool = false
            FileManager.default.fileExists(atPath: appProjectFixture + "/" + p, isDirectory: &dir)
            if !dir.boolValue { onDisk.append(p) }
        }
        #expect(files.map(\.path) == onDisk.sorted())
        #expect(files.map(\.path) == files.map(\.path).sorted())
        for f in files {
            let want = try #require(FileManager.default.contents(atPath: appProjectFixture + "/" + f.path))
            #expect(Array(f.text.utf8) == Array(want), "\(f.path) differs from the fixture")
        }
        // The same input twice: the same bytes.
        #expect(try generated(fixtureSpec) == files)
        #expect(files.filter(\.executable).map(\.path) == ["scripts/build-images.sh"])
    }

    @Test func onlyDebugPlistsNameTheLocalNetwork() throws {
        let files = try generated(fixtureSpec)
        for f in files where f.path.hasSuffix(".plist") {
            let debug = f.path.contains("Debug")
            #expect(f.text.contains("NSBonjourServices") == debug, "\(f.path)")
            #expect(f.text.contains("NSLocalNetworkUsageDescription") == debug, "\(f.path)")
            // An iPhone app renders at 120 Hz only with this key, in both
            // configurations; the Mac has no such cap.
            #expect(f.text.contains("<key>CADisableMinimumFrameDurationOnPhone</key>\n\t<true/>") == f.path.contains("iOS"), "\(f.path)")
            #expect(try PropertyListSerialization.propertyList(from: Data(f.text.utf8), format: nil) is [String: Any])
        }
        let yml = try #require(files.first { $0.path == "project.yml" }).text
        // Debug links the development objects, Release does not; neither
        // links the development product through Xcode.
        #expect(yml.components(separatedBy: "-framework KajoAppDevelopment -framework KajoDev").count == 3)
        #expect(yml.components(separatedBy: "link: false").count == 3)
    }

    @Test func thePinIsTheCheckoutsPrebuiltPackageInBothConfigurations() throws {
        let spec = AppProjectSpec(name: "Notes", bundleIdentifier: "com.example.notes",
                                  kajo: .path("/Users/me/Library/Application Support/Kajo/0.2/"))
        let files = try generated(spec)
        let yml = try #require(files.first { $0.path == "project.yml" }).text
        // One local package, the prebuilt one; no package of Kajo's sources,
        // no trait, nothing fetched.
        #expect(yml.contains("packages:\n  Kajo:\n    path: \"/Users/me/Library/Application Support/Kajo/0.2/Prebuilt\"\n"))
        #expect(!yml.contains("KajoPin") && !yml.contains("KajoAppBuild") && !yml.contains("url:"))
        #expect(yml.components(separatedBy: "product: KajoApp\n").count == 3)
        #expect(!yml.contains("DEVELOPMENT_TEAM"))
        #expect(yml.contains("Notes-macOS:") && yml.contains("Notes-iOS:"))
        #expect(yml.contains("ARCHS: arm64"))
        #expect(!files.contains { $0.path.hasPrefix("KajoPin/") })
        let script = try #require(files.first { $0.path == "scripts/build-images.sh" }).text
        #expect(script.contains("kajo_root='/Users/me/Library/Application Support/Kajo/0.2'\nkajo=$kajo_root/Prebuilt/bin/kajo\n"))
        // The build phase compiles nothing: no swift, no toolchain.
        #expect(!script.contains("swift build") && !script.contains("swiftly"))
        let app = try #require(files.first { $0.path == "Sources/App.swift" }).text
        #expect(app.contains("import KajoApp\n#if DEBUG\nimport KajoAppDevelopment\n#endif"))
        #expect(files.contains { $0.path == "src/NotesApp.class.st" })
    }

    @Test func theWizardsTargetsChooseThePlatforms() throws {
        var spec = fixtureSpec
        spec.platforms = [.macOS]
        var files = try generated(spec)
        var yml = try #require(files.first { $0.path == "project.yml" }).text
        #expect(yml.contains("Sample-macOS:") && !yml.contains("Sample-iOS:") && !yml.contains("iOS: \"18.0\""))
        #expect(files.filter { $0.path.hasSuffix(".plist") }.map(\.path) == ["Info-macOS-Debug.plist", "Info-macOS-Release.plist"])
        spec.platforms = [.iOS]
        files = try generated(spec)
        yml = try #require(files.first { $0.path == "project.yml" }).text
        #expect(!yml.contains("Sample-macOS:") && yml.contains("Sample-iOS:") && !yml.contains("macOS: \"15.0\"") && !yml.contains("ARCHS: arm64"))
        // The iOS target builds only arm64 for the simulator (the prebuilt
        // simulator slice is arm64 only; docs/modules/simulator-slices.md).
        #expect(yml.contains("\"ARCHS[sdk=iphonesimulator*]\": arm64"))
        #expect(files.filter { $0.path.hasSuffix(".plist") }.map(\.path) == ["Info-iOS-Debug.plist", "Info-iOS-Release.plist"])
        // Both, as the fixture: the same files as the default.
        spec.platforms = [.macOS, .iOS]
        #expect(try generated(spec) == (try generated(fixtureSpec)))
        spec.platforms = []
        #expect(AppProjectGenerator.files(for: spec) == .failure(.noTargets))
    }

    @Test func aCheckoutWithoutThePrebuiltKajoIsRefused() throws {
        let fm = FileManager.default
        let d = scratchDirectory("checkout")
        defer { try? fm.removeItem(atPath: d) }
        try fm.createDirectory(atPath: d + "/Prebuilt/bin", withIntermediateDirectories: true)
        #expect(AppProjectGenerator.checkCheckout(.path(d)) == .notACheckout(d))
        fm.createFile(atPath: d + "/Prebuilt/Package.swift", contents: Data())
        fm.createFile(atPath: d + "/Prebuilt/bin/kajo", contents: Data(), attributes: [.posixPermissions: 0o644])
        try fm.createDirectory(atPath: d + "/kernel", withIntermediateDirectories: true)
        #expect(AppProjectGenerator.checkCheckout(.path(d)) == .notACheckout(d))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: d + "/Prebuilt/bin/kajo")
        #expect(AppProjectGenerator.checkCheckout(.path(d)) == nil)
        #expect(AppProjectGenerator.checkCheckout(.path("relative")) != nil)
    }

    @Test func theNameRules() {
        for ok in ["Sample", "Ab", "Notes2", "MyApp", String(repeating: "A", count: 30)] {
            #expect(AppProjectGenerator.checkName(ok) == nil, "\(ok)")
        }
        for bad in ["", "A", "sample", "1App", "My App", "My-App", "My_App", "Ünicode", "Café", String(repeating: "A", count: 31), "App.", "../App"] {
            guard case .invalidName? = AppProjectGenerator.checkName(bad) else {
                Issue.record("\(bad.debugDescription) was not refused as a name")
                continue
            }
        }
        for taken in ["Swift", "Foundation", "UIKit", "AppKit", "Kernel", "Tools", "KajoApp", "KajoPin", "Kajo2", "Object", "Main"] {
            #expect(AppProjectGenerator.checkName(taken) == .reservedName(taken), "\(taken)")
        }
    }

    @Test func everyRefusalIsAValue() {
        func refusal(_ s: AppProjectSpec) -> GeneratorRefusal? {
            if case .failure(let r) = AppProjectGenerator.files(for: s) { return r }
            return nil
        }
        var s = fixtureSpec
        s.name = "bad name"
        guard case .invalidName? = refusal(s) else { Issue.record("name"); return }
        s = fixtureSpec
        s.name = "UIKit"
        #expect(refusal(s) == .reservedName("UIKit"))
        for b in ["", "sample", "dev..sample", ".dev.sample", "dev.sample.", "dev.-sample", "dev.sam ple", "dev.sämple", "dev.sample/x",
                  String(repeating: "a.", count: 80) + "a"] {
            s = fixtureSpec
            s.bundleIdentifier = b
            guard case .invalidBundleIdentifier? = refusal(s) else { Issue.record("bundle identifier \(b.debugDescription)"); continue }
        }
        for t in ["", "ABC", "bdn6m642m2", "BDN6M642M2X", "BDN6M642M!"] {
            s = fixtureSpec
            s.team = t
            #expect(refusal(s) == .invalidTeam(t), "\(t)")
        }
        let badSources: [KajoSource] = [
            .path(""), .path("relative/kajo"), .path("/a/\"b"), .path("/a/$HOME"), .path("/a/`x`"), .path("/a/b\\c"), .path("/a/b\nc"),
            .path("/"), .path("/a/.."),
        ]
        for k in badSources {
            s = fixtureSpec
            s.kajo = k
            guard case .invalidKajoSource? = refusal(s) else { Issue.record("Kajo source \(k)"); continue }
        }
        // Accepted forms.
        for k: KajoSource in [.path("/Users/me/code/kajo"), .path("/Users/me/Library/Application Support/Kajo/0.1")] {
            s = fixtureSpec
            s.kajo = k
            #expect(refusal(s) == nil, "\(k)")
        }
        #expect(GeneratorRefusal.invalidTeam("x").description.contains("development team"))
    }

    @Test func aPathWithAParentComponentIsRefused() {
        let base = "/Users/me/apps"
        #expect(AppProjectGenerator.resolve("Sample", base: base) == .success("/Users/me/apps/Sample"))
        #expect(AppProjectGenerator.resolve("./x/Sample", base: base) == .success("/Users/me/apps/x/Sample"))
        #expect(AppProjectGenerator.resolve("/tmp/Sample", base: base) == .success("/tmp/Sample"))
        for p in ["../Sample", "a/../../b", "x/..", "/tmp/../etc", "", "a\nb"] {
            #expect(AppProjectGenerator.resolve(p, base: base) == .failure(.pathEscapes(p)), "\(p.debugDescription)")
        }
    }

    @Test func writingRefusesADirectoryInUseAndALink() throws {
        let fm = FileManager.default
        let d = scratchDirectory("write")
        defer { try? fm.removeItem(atPath: d) }
        let written = try AppProjectGenerator.write(fixtureSpec, into: d).get()
        #expect(written.count == 12)
        let mode = try fm.attributesOfItem(atPath: d + "/scripts/build-images.sh")[.posixPermissions] as? Int
        #expect(mode == 0o755)
        #expect(fm.contents(atPath: d + "/src/package.st") == Data("Package { #name : #Sample }\n".utf8))
        // Again into the same directory: it is not empty now.
        #expect(AppProjectGenerator.write(fixtureSpec, into: d) == .failure(.directoryNotEmpty(d)))
        // An empty directory is fine; a file or a link in its place is not.
        let empty = scratchDirectory("empty")
        try fm.createDirectory(atPath: empty, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: empty) }
        #expect((try? AppProjectGenerator.write(fixtureSpec, into: empty).get())?.count == 12)
        let file = scratchDirectory("file")
        fm.createFile(atPath: file, contents: Data("x".utf8))
        defer { try? fm.removeItem(atPath: file) }
        #expect(AppProjectGenerator.write(fixtureSpec, into: file) == .failure(.directoryNotEmpty(file)))
        let target = scratchDirectory("target")
        try fm.createDirectory(atPath: target, withIntermediateDirectories: true)
        let link = scratchDirectory("link")
        try fm.createSymbolicLink(atPath: link, withDestinationPath: target)
        defer {
            try? fm.removeItem(atPath: link)
            try? fm.removeItem(atPath: target)
        }
        #expect(AppProjectGenerator.write(fixtureSpec, into: link) == .failure(.pathEscapes(link)))
        #expect((try fm.contentsOfDirectory(atPath: target)).isEmpty)
        // A refused spec writes nothing.
        var bad = fixtureSpec
        bad.name = "x"
        let none = scratchDirectory("none")
        guard case .failure(.invalidName) = AppProjectGenerator.write(bad, into: none) else { Issue.record("written"); return }
        #expect(!fm.fileExists(atPath: none))
    }

    @Test func theGeneratedAppCompilesWithTheKernelAndItsTestPasses() throws {
        let d = scratchDirectory("tonel")
        defer { try? FileManager.default.removeItem(atPath: d) }
        _ = try AppProjectGenerator.write(fixtureSpec, into: d).get()
        let r = try KernelBuild.build(KernelBuild.sources(in: [kernelDirectory, d + "/src"]))
        #expect(r.warnings.isEmpty)
        #expect(KernelBuild.package(ofFile: d + "/src/SampleApp.class.st") == "Sample")
        let (result, lines) = runKernelTests(r.image, ["--filter", "SampleAppTest"])
        let report = TestReport(lines)
        #expect(try result.get() == 0, "\(report.failures)")
        #expect(report.total == 1 && report.passed == 1)
    }
}
