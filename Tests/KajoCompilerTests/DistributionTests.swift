// Module 11b: the Kajo app's file-system parts (docs/modules/distribution.md,
// part 1): the checkout copied to Application Support once per version and
// never taken half-copied, the command line tool's link made only where it
// may be and never over someone else's file, and New App's request over a
// checkout. Every test runs against scratch directories, as the app does
// under KAJO_SUPPORT_DIR and KAJO_CLI_LINK_DIR.

import Foundation
import Testing
@testable import KajoGenerator
@testable import KajoShellCore

@Suite struct DistributionTests {
    let fm = FileManager.default

    /// A fake checkout with the parts the generator asks for.
    func fakeCheckout(_ d: String) throws {
        try fm.createDirectory(atPath: d + "/Prebuilt/bin", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: d + "/kernel", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: d + "/tools", withIntermediateDirectories: true)
        fm.createFile(atPath: d + "/Prebuilt/Package.swift", contents: Data("// prebuilt\n".utf8))
        fm.createFile(atPath: d + "/Prebuilt/bin/kajo", contents: Data(repeating: 7, count: 4096), attributes: [.posixPermissions: 0o755])
        fm.createFile(atPath: d + "/kernel/Object.class.st", contents: Data("Class { #name : #Object }\n".utf8))
    }

    @Test func thePathsFollowTheBundleAndTheOverrides() {
        let p = ProductPaths(version: "0.3", bundle: "/Applications/Kajo.app", environment: [:], home: "/Users/me")
        #expect(p.bundledCheckout == "/Applications/Kajo.app/Contents/Resources/Kajo-0.3")
        #expect(p.installedCheckout == "/Users/me/Library/Application Support/Kajo/0.3")
        #expect(p.cli == "/Applications/Kajo.app/Contents/Helpers/kajo")
        #expect(p.xcodegen == "/Applications/Kajo.app/Contents/Resources/xcodegen/bin/xcodegen")
        #expect(p.linkDirectory == "/usr/local/bin")
        let o = ProductPaths(version: "0.3", bundle: "/A/Kajo.app", environment: ["KAJO_SUPPORT_DIR": "/tmp/s", "KAJO_CLI_LINK_DIR": "/tmp/b"])
        #expect(o.installedCheckout == "/tmp/s/0.3")
        #expect(o.linkDirectory == "/tmp/b")
    }

    @Test func theCheckoutIsCopiedOncePerVersionAndNeverHalfway() throws {
        let d = scratchDirectory("install")
        defer { try? fm.removeItem(atPath: d) }
        let from = d + "/bundle/Kajo-0.3", root = d + "/support"
        try fakeCheckout(from)
        let paths = ProductPaths(version: "0.3", bundle: d + "/bundle", environment: ["KAJO_SUPPORT_DIR": root])
        // No checkout in the bundle: nothing is made.
        #expect(CheckoutInstaller.install(from: d + "/nothing", to: root + "/0.3") == .noCheckout)
        #expect(!fm.fileExists(atPath: root))
        // The first launch copies, with the marker last.
        guard case .copied(let bytes, _) = CheckoutInstaller.install(from: from, to: paths.installedCheckout) else {
            Issue.record("not copied")
            return
        }
        #expect(bytes >= 4096)
        #expect(fm.contents(atPath: root + "/0.3/Prebuilt/bin/kajo")?.count == 4096)
        #expect(fm.fileExists(atPath: root + "/0.3/" + CheckoutInstaller.marker))
        #expect(CheckoutInstall.copied(bytes, 1).line(paths).contains(root + "/0.3"))
        // A developer's change in the copy survives the next launch.
        fm.createFile(atPath: root + "/0.3/tools/Edited.class.st", contents: Data("x".utf8))
        #expect(CheckoutInstaller.install(from: from, to: paths.installedCheckout) == .present)
        #expect(fm.fileExists(atPath: root + "/0.3/tools/Edited.class.st"))
        // Another version sits beside it.
        let from2 = d + "/bundle/Kajo-0.4"
        try fakeCheckout(from2)
        guard case .copied = CheckoutInstaller.install(from: from2, to: root + "/0.4") else { Issue.record("0.4"); return }
        #expect(Set(try fm.contentsOfDirectory(atPath: root)) == ["0.3", "0.4"])
        // A folder without the marker (an interrupted copy) is moved aside,
        // never deleted, and a complete copy takes its place.
        try fm.createDirectory(atPath: root + "/0.5", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/0.5/half", contents: Data("h".utf8))
        guard case .copied = CheckoutInstaller.install(from: from, to: root + "/0.5") else { Issue.record("0.5"); return }
        #expect(fm.fileExists(atPath: root + "/0.5/" + CheckoutInstaller.marker))
        let aside = try fm.contentsOfDirectory(atPath: root).filter { $0.hasPrefix("0.5.incomplete-") }
        #expect(aside.count == 1)
        #expect(fm.fileExists(atPath: root + "/" + aside[0] + "/half"))
        #expect(!(try fm.contentsOfDirectory(atPath: root)).contains { $0.contains(".partial-") })
    }

    @Test func theCommandLineToolIsLinkedOnlyWhereItMayBe() throws {
        let d = scratchDirectory("cli")
        defer { try? fm.removeItem(atPath: d) }
        let cli = d + "/Kajo.app/Contents/Helpers/kajo", bin = d + "/bin"
        try fm.createDirectory(atPath: cli.components(separatedBy: "/kajo").dropLast().joined(separator: "/kajo"), withIntermediateDirectories: true)
        try fm.createDirectory(atPath: (cli as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fm.createFile(atPath: cli, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        // No such directory: the command to run instead, nothing made.
        guard case .needsPermission(let command) = CommandLineTool.install(cli: cli, into: bin) else { Issue.record("missing dir"); return }
        #expect(command.contains("ln -sf '\(cli)' \(bin)/kajo"))
        #expect(!fm.fileExists(atPath: bin))
        try fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
        #expect(CommandLineTool.install(cli: cli, into: bin) == .linked(bin + "/kajo"))
        #expect(try fm.destinationOfSymbolicLink(atPath: bin + "/kajo") == cli)
        // Again (another copy of the app): our link is replaced.
        let cli2 = d + "/Other/Kajo.app/Contents/Helpers/kajo"
        try fm.createDirectory(atPath: (cli2 as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fm.createFile(atPath: cli2, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        #expect(CommandLineTool.install(cli: cli2, into: bin) == .linked(bin + "/kajo"))
        #expect(try fm.destinationOfSymbolicLink(atPath: bin + "/kajo") == cli2)
        // Someone else's kajo is left alone.
        try fm.removeItem(atPath: bin + "/kajo")
        fm.createFile(atPath: bin + "/kajo", contents: Data("theirs".utf8))
        #expect(CommandLineTool.install(cli: cli, into: bin) == .occupied(bin + "/kajo"))
        #expect(fm.contents(atPath: bin + "/kajo") == Data("theirs".utf8))
        // A directory that cannot be written: the command, nothing made.
        let ro = d + "/ro"
        try fm.createDirectory(atPath: ro, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ro) }
        guard case .needsPermission = CommandLineTool.install(cli: cli, into: ro) else { Issue.record("read-only dir"); return }
        #expect(CommandLineTool.install(cli: d + "/none", into: bin) == .failed("no kajo in the app at \(d)/none"))
    }

    @Test func newAppMakesTheProjectOverTheCheckoutOrSaysWhy() throws {
        let d = scratchDirectory("newapp")
        defer { try? fm.removeItem(atPath: d) }
        let ck = d + "/support/0.3"
        try fakeCheckout(ck)
        let loc = d + "/Developer"
        try fm.createDirectory(atPath: loc, withIntermediateDirectories: true)
        // A refusal is the generator's text; nothing is written.
        let bad = NewAppRequest(name: "sample", bundleIdentifier: "com.example.sample", location: loc, platforms: [.macOS, .iOS])
        guard case .failure(let why) = bad.create(checkout: ck, xcodegen: nil) else { Issue.record("accepted"); return }
        #expect(why.description.contains("capital letter"))
        #expect(try fm.contentsOfDirectory(atPath: loc).isEmpty)
        let none = NewAppRequest(name: "Sample", bundleIdentifier: "com.example.sample", location: loc, platforms: [])
        guard case .failure = none.create(checkout: ck, xcodegen: nil) else { Issue.record("no targets accepted"); return }
        let noCheckout = NewAppRequest(name: "Sample", bundleIdentifier: "com.example.sample", location: loc, platforms: [.iOS])
        guard case .failure(let w2) = noCheckout.create(checkout: d + "/missing", xcodegen: nil) else { Issue.record("no checkout"); return }
        #expect(w2.description.contains("prebuilt"))
        // The project, pinned to the checkout, for the chosen target; the
        // Xcode project when xcodegen is found.
        let ok = NewAppRequest(name: "Sample", bundleIdentifier: "com.example.sample", location: loc, platforms: [.iOS])
        let r = ok.create(checkout: ck, xcodegen: nil)
        let yml = try #require(fm.contents(atPath: loc + "/Sample/project.yml")).map { Character(UnicodeScalar($0)) }
        #expect(String(yml).contains("path: \"\(ck)/Prebuilt\""))
        #expect(String(yml).contains("Sample-iOS:") && !String(yml).contains("Sample-macOS:"))
        if AppProjectGenerator.findXcodegen() != nil {
            #expect(r == .success(loc + "/Sample/Sample.xcodeproj"))
            #expect(fm.fileExists(atPath: loc + "/Sample/Sample.xcodeproj/project.pbxproj"))
        }
        // The same folder again: refused, the first project untouched.
        guard case .failure(let w3) = ok.create(checkout: ck, xcodegen: nil) else { Issue.record("written twice"); return }
        #expect(w3.description.contains("not empty"))
    }
}
