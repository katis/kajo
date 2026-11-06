import Darwin
import Dispatch
import Foundation
import KajoApp
import KajoDev
import KajoVM
import Synchronization

// Module 9b and 9d (docs/modules/development-protocol.md and
// phone-transport.md), moved here by module 11a: a runtime serving the
// development protocol on a Unix socket or over TCP with a Bonjour
// advertisement (`_kajo-dev._tcp`, its TXT record the image's name, the
// protocol's and the kernel's version, never the token), and what the
// pairing screen shows. Only a development image serves. This library is
// what a Debug build links and a Release build does not: the second lock
// beside the release image refusing to serve.

/// What the pairing screen shows.
public struct PairingInfo: Sendable {
    public var name: String
    public var addresses: [String]
    public var port: Int
    public var token: String
    public var status: String
}

/// Where the pairing screen is shown and a token is asked for: a platform
/// half (PairingScreen on AppKit and UIKit) or a test's.
@MainActor public protocol PairingPresenter: AnyObject {
    /// While the runtime serves over TCP, what a developer needs to pair
    /// with it (its Bonjour name, addresses, the token, large; nil hides
    /// it). The presenter decides when it is on the screen.
    func showPairing(_ info: PairingInfo?)
    /// The action of the "new token" button.
    var onNewToken: (() -> Void)? { get set }
    /// Module 9d: ask the developer for a secret (a target's pairing token,
    /// read off the phone's screen) in a secure text field of the
    /// platform's own; `done` gets the text, or nil when cancelled. The
    /// text goes to the client transport, never to the image.
    func askSecret(_ prompt: String, _ done: @escaping (String?) -> Void)
}

/// The pairing token kept for an install: stable across launches, in the
/// app's own directory (Application Support) with mode 0600, made again by
/// the "new token" button. Never logged, never in a result line.
public struct PairingTokenStore: Sendable, CustomReflectable {
    public var customMirror: Mirror { Mirror(self, children: ["path": path]) }
    public let path: String

    public init(directory: String) {
        path = directory + "/kajo-pairing-token"
    }

    /// The store of this install: Application Support (on the Mac, the
    /// app's own folder in it, named by its bundle identifier).
    public static func applicationSupport() -> PairingTokenStore? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        #if os(macOS)
        return PairingTokenStore(directory: dir.appendingPathComponent(Bundle.main.bundleIdentifier ?? "kajo").path)
        #else
        return PairingTokenStore(directory: dir.path)
        #endif
    }

    /// The kept token, or a new one written.
    public func load() -> String {
        if let d = FileManager.default.contents(atPath: path), let t = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           t.utf8.count == 20, t.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) }) {
            return t
        }
        return renew()
    }

    /// A new token, written with mode 0600 (made in a file created that way,
    /// then moved over the old one).
    @discardableResult
    public func renew() -> String {
        let t = ProtocolServer.makeToken()
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let tmp = path + ".new"
        unsafe unlink(tmp)
        let fd = unsafe open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return t }
        let bytes = Array(t.utf8)
        _ = bytes.withUnsafeBytes { unsafe write(fd, $0.baseAddress!, bytes.count) }
        close(fd)
        unsafe rename(tmp, path)
        return t
    }
}

/// What a serving runtime keeps (`ShellRuntime.developmentState`): the
/// transport, its advertisement, the client host of the image's tools.
final class ServingState: @unchecked Sendable {
    let server = Mutex<ProtocolServer?>(nil)
    let advertiser = Mutex<BonjourAdvertiser?>(nil)
    var client: ClientHost?
}

extension ShellRuntime {
    var serving: ServingState {
        if let s = developmentState as? ServingState { return s }
        let s = ServingState()
        developmentState = s
        return s
    }

    /// Module 9c: the client transport's targets (the runtime's own when it
    /// serves, those of `~/.kajo/targets`), when one was attached. Their
    /// tokens stay in it.
    public var clientHost: ClientHost? { serving.client }

    /// Module 9c: attach primitive 164's transport, made before the runtime
    /// (its callback went to `ShellRuntime.init`): replies arrive as events,
    /// and a token is asked for in `secrets`' secure field.
    public func attachClient(_ host: ClientHost, secrets: PairingPresenter?) {
        serving.client = host
        let shell = vm
        host.setSink { e in shell.post(e) }
        host.setSecretPrompt(ShellRuntime.secretPrompt(PresenterBox(secrets)))
    }

    /// The secure field, built outside main-actor context: the platform asks
    /// on the main thread, after the turn that asked has ended.
    nonisolated static func secretPrompt(_ box: PresenterBox) -> @Sendable (String, @escaping @Sendable (String?) -> Void) -> Void {
        { prompt, done in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let p = box.presenter else { return done(nil) }
                    p.askSecret(prompt) { done($0) }
                }
            }
        }
    }

    /// Serve the development protocol on a Unix socket at `path` (module
    /// 9b): the transport, the inbox, the kernel's protocol Process
    /// (`DevProtocol start`), which from now on also stops a Process at an
    /// unhandled error. Nil in a release image.
    public func serveProtocol(socket path: String) throws -> ProtocolServer? {
        if vm.isReleaseImage { return nil }
        let shell = vm
        let server = try ProtocolServer(path: path) { conn, json in shell.postRequest(connection: conn, json: json) }
        return startServing(server)
    }

    /// The transport is open: the inbox, the kernel's protocol Process; the
    /// image's own tools may connect to it (the local target: the client
    /// transport holds the token, the image never). Nil when the image
    /// would not start it.
    func startServing(_ server: ProtocolServer) -> ProtocolServer? {
        let state = serving
        state.server.withLock { $0 = server }
        setEventTap(ShellRuntime.servingTap(state, StatusBox(platform)))
        vm.openProtocol()
        guard let p = vm.spawn("start", receiver: "DevProtocol") else {
            server.stop()
            state.server.withLock { $0 = nil }
            setEventTap(nil)
            return nil
        }
        let end = ShellVM.now() + 10_000_000_000
        while vm.state(of: p) != .terminated && ShellVM.now() < end { _ = vm.runTurn(budgetNs: 2_000_000) }
        let started = vm.result(of: p) == .bool(true)
        vm.release(p)
        guard started else {
            server.stop()
            state.server.withLock { $0 = nil }
            setEventTap(nil)
            return nil
        }
        server.start()
        state.client?.addTarget(ClientHost.Target(name: "local", path: server.path, token: server.token))
        return server
    }

    /// Every kernel line while serving: replies to their connection, events
    /// to every session, and a stopped Process shown in the status line so
    /// it cannot hide. Built outside main-actor context (VM threads run it).
    nonisolated static func servingTap(_ state: ServingState, _ status: StatusBox) -> @Sendable ([UInt8]) -> Void {
        let stopped = Array("\"kind\":\"process.stopped\"".utf8)
        return { e in
            guard let s = state.server.withLock({ $0 }) else { return }
            s.deliver(e)
            if e.count > 40, e[0..<min(e.count, 60)].firstRange(of: stopped) != nil, case .success(let v) = parseJSON(e) {
                let line = "Process \(v["process"].map { String(decoding: writeJSON($0), as: UTF8.self) } ?? "?") stopped (\(v["reason"]?.string ?? "?")): \(v["error"]?.string ?? "")"
                DispatchQueue.main.async { MainActor.assumeIsolated { status.platform?.showStatus(line) } }
            }
        }
    }

    /// The protocol server while one serves.
    public var protocolServer: ProtocolServer? { serving.server.withLock { $0 } }

    /// Stop serving (the socket file goes).
    public func stopProtocol() {
        let state = serving
        state.advertiser.withLock { a in
            a?.stop()
            a = nil
        }
        state.client?.closeAll()
        let s = state.server.withLock { s in
            let old = s
            s = nil
            return old
        }
        s?.stop()
        setEventTap(nil)
    }

    /// Module 9d: serve over TCP on `port` (0: the system picks), advertised
    /// with Bonjour (as `serviceName`, or the device's name) unless
    /// `advertise` is false, with the token `store` keeps (or one in
    /// memory); `pairing` shows it. Nil in a release image (no transport
    /// opens).
    public func serveTCP(port: Int, loopbackOnly: Bool = false, advertise: Bool = true, store: PairingTokenStore?,
                         imageName: String, serviceName: String? = nil, pairing presenter: PairingPresenter?) throws -> ProtocolServer? {
        if vm.isReleaseImage { return nil }
        let shell = vm
        let token = store?.load() ?? ProtocolServer.makeToken()
        let server = try ProtocolServer(tcpPort: port, loopbackOnly: loopbackOnly, token: token) { conn, json in
            shell.postRequest(connection: conn, json: json)
        }
        let pairing = PairingBox(PairingInfo(name: "", addresses: localAddresses(), port: server.port ?? 0, token: token, status: "serving"))
        let box = PresenterBox(presenter)
        let show: @Sendable () -> Void = {
            DispatchQueue.main.async { MainActor.assumeIsolated { box.presenter?.showPairing(pairing.value) } }
        }
        server.onRefusing = { refusing, failures in
            pairing.update { $0.status = refusing ? "refusing every connection for a minute: \(failures) failed pairings" : "serving" }
            show()
        }
        guard startServing(server) != nil else { return nil }
        if advertise {
            let txt = [("image", imageName), ("protocol", "1"), ("kernel", KajoVM.version)]
            let a = try? BonjourAdvertiser(name: serviceName, port: server.port ?? 0, txt: txt, loopbackOnly: loopbackOnly) { name, error in
                pairing.update { $0.name = name ?? "(Bonjour: error \(error))" }
                show()
            }
            serving.advertiser.withLock { $0 = a }
        }
        let state = serving
        presenter?.onNewToken = { [weak server] in
            guard let server else { return }
            let t = store?.renew() ?? ProtocolServer.makeToken()
            server.replaceToken(t)
            state.client?.addTarget(ClientHost.Target(name: "local", path: server.path, token: t))
            pairing.update { $0.token = t }
            show()
        }
        presenter?.showPairing(pairing.value)
        return server
    }
}

final class PairingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var info: PairingInfo
    init(_ i: PairingInfo) { info = i }
    var value: PairingInfo {
        lock.lock()
        defer { lock.unlock() }
        return info
    }
    func update(_ f: (inout PairingInfo) -> Void) {
        lock.lock()
        f(&info)
        lock.unlock()
    }
}

/// A presenter or a platform handed to closures that run on other threads
/// and come back to the main thread to use it.
final class PresenterBox: @unchecked Sendable {
    weak var presenter: PairingPresenter?
    init(_ p: PairingPresenter?) { presenter = p }
}

final class StatusBox: @unchecked Sendable {
    weak var platform: ShellPlatform?
    init(_ p: ShellPlatform) { platform = p }
}

/// `protocol=tcp`, `protocol=tcp:<port>`: the TCP port asked for (0: any),
/// or nil for anything else (a socket path).
public func tcpPort(_ option: String?) -> Int? {
    guard let o = option else { return nil }
    if o == "tcp" { return 0 }
    guard o.hasPrefix("tcp:"), let p = Int(o.dropFirst(4)), (0...65535).contains(p) else { return nil }
    return p
}
