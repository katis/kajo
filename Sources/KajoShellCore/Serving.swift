import Darwin
import Dispatch
import Foundation
import KajoDev
import KajoVM

// Module 9d (docs/modules/phone-transport.md): a shell serving the
// development protocol over TCP, the iOS shell's `protocol=tcp[:port]`: the
// listener, the Bonjour advertisement (`_kajo-dev._tcp`, its TXT record the
// image's name, the protocol's and the kernel's version, never the token),
// and the pairing screen (the token large, the Bonjour name, the addresses,
// a "new token" button, the listener refusing after failed pairings).
// Only a development image serves, and only when asked.

/// What the pairing screen shows.
public struct PairingInfo: Sendable {
    public var name: String
    public var addresses: [String]
    public var port: Int
    public var token: String
    public var status: String
}

/// The pairing token kept for an install: stable across launches, in the
/// app's own directory (Application Support on iOS) with mode 0600, made
/// again by the "new token" button. Never logged, never in a result line.
public struct PairingTokenStore: Sendable, CustomReflectable {
    public var customMirror: Mirror { Mirror(self, children: ["path": path]) }
    public let path: String

    public init(directory: String) {
        path = directory + "/kajo-pairing-token"
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

extension ShellRuntime {
    /// Serve over TCP on `port` (0: the system picks), advertised with
    /// Bonjour (as `serviceName`, or the device's name) unless `advertise`
    /// is false, with the token `store` keeps
    /// (or one in memory); the pairing screen shows it. Nil in a release
    /// image (no transport opens).
    public func serveTCP(port: Int, loopbackOnly: Bool = false, advertise: Bool = true, store: PairingTokenStore?,
                         imageName: String, serviceName: String? = nil) throws -> ProtocolServer? {
        if vm.isReleaseImage { return nil }
        let shell = vm
        let token = store?.load() ?? ProtocolServer.makeToken()
        let server = try ProtocolServer(tcpPort: port, loopbackOnly: loopbackOnly, token: token) { conn, json in
            shell.postRequest(connection: conn, json: json)
        }
        let pairing = PairingBox(PairingInfo(name: "", addresses: localAddresses(), port: server.port ?? 0, token: token, status: "serving"))
        let show: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.platform.showPairing(pairing.value) } }
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
            link.advertiser.withLock { $0 = a }
        }
        platform.onNewToken = { [weak self, weak server] in
            guard let server else { return }
            let t = store?.renew() ?? ProtocolServer.makeToken()
            server.replaceToken(t)
            self?.link.client.addTarget(ClientHost.Target(name: "local", path: server.path, token: t))
            pairing.update { $0.token = t }
            show()
        }
        platform.showPairing(pairing.value)
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

/// `protocol=tcp`, `protocol=tcp:<port>`: the TCP port asked for (0: any),
/// or nil for anything else (a socket path).
public func tcpPort(_ option: String?) -> Int? {
    guard let o = option else { return nil }
    if o == "tcp" { return 0 }
    guard o.hasPrefix("tcp:"), let p = Int(o.dropFirst(4)), (0...65535).contains(p) else { return nil }
    return p
}
