// Module 11a: serving is a property of the development build
// (docs/modules/app-project.md, part 3), at the level ShellTests work at: a
// generated app's runner on a host that keeps the views' properties. A
// development build serves at launch with no argument (the token is the
// store's, the pairing screen gets it, a client on loopback opens a session
// and reads the app's label through the view hop); a development half over
// a release image cannot serve; a release build (no development half) has
// no transport at all.

import Darwin
import Foundation
import Testing
@testable import KajoApp
@testable import KajoAppDevelopment
@testable import KajoCompiler
@testable import KajoDev
@testable import KajoGenerator
@testable import KajoVM

/// The generated Sample app's sources (written once), built with the
/// kernel as a development image and as a release image.
let sampleSources: String = {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("kajo-sample-\(getpid())").path
    try? FileManager.default.removeItem(atPath: d)
    _ = try! AppProjectGenerator.write(fixtureSpec, into: d).get()
    return d + "/src"
}()

func sampleImage(release: Bool) -> String {
    var o = KernelBuild.Options()
    o.release = release
    let r = try! KernelBuild.build(KernelBuild.sources(in: [kernelDirectory, sampleSources]), options: o)
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("kajo-sample-\(getpid())-\(release ? "release" : "development").img").path
    FileManager.default.createFile(atPath: path, contents: Data(r.image))
    return path
}

let sampleDevelopmentImage = sampleImage(release: false)
let sampleReleaseImage = sampleImage(release: true)

/// A host with no toolkit: every view keeps its properties.
@MainActor final class PropertyPlatform: ShellPlatform {
    var views: [Int: [String: ShellValue]] = [:]
    var next = 1
    var statuses: [String] = []
    var eventHandler: ((ShellEvent) -> Void)?
    var textDrawn: ((Int) -> Void)?
    var maximumFramesPerSecond: Int { 120 }

    func viewCall(_ call: ViewCall) -> ShellValue? {
        let a = call.arguments
        switch call.op {
        case "create":
            let h = next
            next += 1
            views[h] = [:]
            return .int(Int64(h))
        case "set":
            guard a.count == 2, case .string(let k) = a[0], views[call.handle] != nil else { return nil }
            views[call.handle]?[k] = a[1]
            return a[1]
        case "get":
            guard a.count == 1, case .string(let k) = a[0] else { return nil }
            return views[call.handle]?[k] ?? .nil
        default:
            return views[call.handle] == nil ? nil : .nil
        }
    }
    func releaseView(_ handle: Int) { views[handle] = nil }
    func startDisplayLink(_ tick: @escaping @MainActor (Double, Double) -> Void) {}
    func stopDisplayLink() {}
    func showStatus(_ line: String) { statuses.append(line) }
    func typeKey(_ handle: Int, _ text: String) -> Bool { false }
}

@MainActor final class RecordingPresenter: PairingPresenter {
    var shown: [PairingInfo?] = []
    var onNewToken: (() -> Void)?
    func showPairing(_ info: PairingInfo?) { shown.append(info) }
    func askSecret(_ prompt: String, _ done: @escaping (String?) -> Void) { done(nil) }
}

/// The client's requests off the main thread (the view hop needs it).
func offMain<T: Sendable>(_ f: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { c in
        Thread { c.resume(with: Result { try f() }) }.start()
    }
}

@MainActor func closeApp(_ r: KajoAppRunner) {
    r.runtime?.stopProtocol()
    r.runtime?.vm.close()
}

@Suite(.serialized) @MainActor struct AppServingTests {
    @Test func aDevelopmentBuildServesAtLaunchWithItsStoresToken() async throws {
        let dir = scratchDirectory("store")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = PairingTokenStore(directory: dir)
        let presenter = RecordingPresenter()
        let development = Development(store: store, loopbackOnly: true, advertise: false, presenter: presenter)
        let platform = PropertyPlatform()
        let app = KajoAppRunner(configuration: KajoAppConfiguration(name: "Sample", appClass: "SampleApp"), platform: platform,
                                development: development)
        #expect(app.start(imagePath: sampleDevelopmentImage))
        defer { closeApp(app) }
        // Serving from launch: no argument asked for it.
        let server = try #require(development.server)
        let port = try #require(server.port)
        #expect(development.serviceName.hasPrefix("Sample on "))
        // The pairing screen has the token the store keeps (mode 0600).
        let token = store.load()
        let info = try #require(presenter.shown.last ?? nil)
        #expect(info.token == token && info.port == port)
        let mode = try FileManager.default.attributesOfItem(atPath: store.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // A client opens a session with it and reads the label the app's
        // open set, through the view hop to this (the main) thread.
        let label: String = try await offMain {
            let c = try ProtocolClient(address: .tcp(host: "127.0.0.1", port: port))
            defer { c.close() }
            try c.open(token: token, client: "developer", package: "Sample")
            let r = try c.request("evaluate", [("source", .string("SampleApp pressed. SampleApp labelText"))])
            return r["value"]?.string ?? ""
        }
        #expect(label == "'Pressed 1 times'")
        #expect(platform.views.values.contains { $0["text"] == .string("Pressed 1 times") })
        // A wrong token is refused.
        let refused: Bool = try await offMain {
            let c = try ProtocolClient(address: .tcp(host: "127.0.0.1", port: port))
            defer { c.close() }
            return (try? c.open(token: String(repeating: "a", count: 20), client: "developer")) == nil
        }
        #expect(refused)
    }

    @Test func aDevelopmentHalfOverAReleaseImageCannotServe() throws {
        let dir = scratchDirectory("release-store")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let presenter = RecordingPresenter()
        let development = Development(store: PairingTokenStore(directory: dir), loopbackOnly: true, advertise: false, presenter: presenter)
        let platform = PropertyPlatform()
        let app = KajoAppRunner(configuration: KajoAppConfiguration(name: "Sample", appClass: "SampleApp"), platform: platform,
                                development: development)
        #expect(app.start(imagePath: sampleReleaseImage))
        defer { closeApp(app) }
        #expect(app.runtime?.vm.isReleaseImage == true)
        #expect(development.server == nil)
        #expect(presenter.shown.isEmpty)
        #expect(platform.statuses.contains { $0.contains("serves no protocol") })
        // The app itself runs: its window and label are there.
        #expect(platform.views.values.contains { $0["text"] == .string("Hello from Kajo") })
        // No token was made for it.
        #expect(!FileManager.default.fileExists(atPath: dir + "/kajo-pairing-token"))
    }

    @Test func aReleaseBuildHasNoTransport() throws {
        let platform = PropertyPlatform()
        let app = KajoAppRunner(configuration: KajoAppConfiguration(name: "Sample", appClass: "SampleApp"), platform: platform,
                                development: nil)
        #expect(app.start(imagePath: sampleReleaseImage))
        defer { closeApp(app) }
        #expect(platform.views.values.contains { $0["text"] == .string("Hello from Kajo") })
        #expect(app.runtime?.developmentState == nil)
        #expect(app.runtime?.protocolServer == nil)
    }

    @Test func anAppThatDoesNotOpenSaysWhy() {
        let platform = PropertyPlatform()
        let app = KajoAppRunner(configuration: KajoAppConfiguration(name: "Sample", appClass: "NoSuchApp"), platform: platform,
                                development: nil)
        #expect(!app.start(imagePath: sampleDevelopmentImage))
        defer { closeApp(app) }
        #expect(platform.statuses.last?.contains("no class NoSuchApp") == true)
        let missing = KajoAppRunner(configuration: KajoAppConfiguration(name: "Sample", appClass: "SampleApp"), platform: platform,
                                    development: nil)
        #expect(!missing.start(imagePath: "/nonexistent/app.img"))
        #expect(missing.runtime == nil)
    }

    @Test func theServiceNameTellsAppsApartAndFitsBonjour() {
        #expect(Development.serviceName(app: "Sample", device: "Joni's iPad") == "Sample on Joni's iPad")
        let long = Development.serviceName(app: String(repeating: "A", count: 30), device: String(repeating: "é", count: 40))
        #expect(long.utf8.count <= 63 && long.hasPrefix(String(repeating: "A", count: 30) + " on "))
    }
}
