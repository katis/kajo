import Darwin
import Foundation
import Network
import dnssd

// Module 9d: the transports behind one line protocol
// (docs/modules/phone-transport.md). A target is reached at an address:
// a Unix-domain socket (9b), TCP (`tcp://host:port`), or a Bonjour service
// a phone advertises (`bonjour:<name>`, resolved to TCP when connecting).
// Whatever the address, the result is one stream descriptor, read and
// written by the same code (`ProtocolServer`'s connections, `ClientHost`'s,
// `ProtocolClient`). Nothing received here is trusted: an address, a
// service name and a TXT record from the network are checked before use
// and fuzzed (`just fuzz protocol`).

/// Where a target listens.
public enum TargetAddress: Equatable, Sendable, CustomStringConvertible {
    /// A Unix-domain socket's path (at most 103 bytes, with a `/`).
    case unix(String)
    /// A TCP host (a name, an IPv4 address, or an IPv6 one) and port.
    case tcp(host: String, port: Int)
    /// A `_kajo-dev._tcp` service's instance name (what a phone advertises).
    case bonjour(String)

    /// The service type a serving target advertises.
    public static let serviceType = "_kajo-dev._tcp"

    /// The address forms: `/path/to.sock` (any text with a `/` that fits
    /// `sun_path`), `tcp://host:port`, `tcp://[v6]:port`, `bonjour:<name>`.
    /// nil for anything else (a target's name is looked up elsewhere).
    public static func parse(_ text: String) -> TargetAddress? {
        guard !text.isEmpty, text.utf8.count <= 320,
              !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
        if text.hasPrefix("tcp://") {
            let rest = text.dropFirst(6)
            let host: Substring, port: Substring
            if rest.hasPrefix("[") {
                guard let close = rest.firstIndex(of: "]") else { return nil }
                host = rest[rest.index(after: rest.startIndex)..<close]
                let after = rest[rest.index(after: close)...]
                guard after.hasPrefix(":"), isIPv6(host) else { return nil }
                port = after.dropFirst()
            } else {
                guard let colon = rest.lastIndex(of: ":") else { return nil }
                host = rest[..<colon]
                port = rest[rest.index(after: colon)...]
                guard isHostName(host) else { return nil }
            }
            guard !port.isEmpty, port.count <= 5, port.utf8.allSatisfy({ (48...57).contains($0) }),
                  let p = Int(port), (1...65535).contains(p) else { return nil }
            return .tcp(host: String(host), port: p)
        }
        if text.hasPrefix("bonjour:") {
            let name = String(text.dropFirst(8))
            return isServiceName(name) ? .bonjour(name) : nil
        }
        guard text.utf8.count < 104, text.contains("/"), !text.contains("\t") else { return nil }
        return .unix(text)
    }

    /// The form `parse` reads back.
    public var description: String {
        switch self {
        case .unix(let p): p
        case .tcp(let h, let p): h.contains(":") ? "tcp://[\(h)]:\(p)" : "tcp://\(h):\(p)"
        case .bonjour(let n): "bonjour:\(n)"
        }
    }

    /// A DNS name or an IPv4 address: letters, digits, `-` and `.`, labels
    /// of 1 to 63 bytes, at most 253 in all.
    static func isHostName<S: StringProtocol>(_ h: S) -> Bool {
        guard !h.isEmpty, h.utf8.count <= 253 else { return false }
        let labels = h.split(separator: ".", omittingEmptySubsequences: false)
        for (i, l) in labels.enumerated() {
            // a trailing dot (an absolute name) is one empty last label
            if l.isEmpty { if i == labels.count - 1 && i > 0 { continue } else { return false } }
            guard l.utf8.count <= 63, l.first != "-", l.last != "-",
                  l.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else { return false }
        }
        return true
    }

    /// An IPv6 address as written between brackets: hex digits, `:` and
    /// `.` (a mapped IPv4 tail), optionally `%` and an interface name. The
    /// resolver refuses what is not one; this keeps anything else out.
    static func isIPv6<S: StringProtocol>(_ h: S) -> Bool {
        let parts = h.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        let addr = parts[0]
        guard addr.utf8.count >= 2, addr.utf8.count <= 45, addr.contains(":"),
              addr.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) || $0 == 58 || $0 == 46 })
        else { return false }
        if parts.count == 2 {
            let zone = parts[1]
            guard !zone.isEmpty, zone.utf8.count <= 15,
                  zone.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { return false }
        }
        return true
    }

    /// A DNS-SD instance name: 1 to 63 bytes of UTF-8, no control
    /// characters (so no tab or line break: names travel in tab-separated
    /// lines to the image).
    public static func isServiceName(_ n: String) -> Bool {
        !n.isEmpty && n.utf8.count <= 63 && !n.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    }
}

// MARK: - streams

/// The socket options of every stream: no SIGPIPE; on TCP, no Nagle delay
/// (requests and replies are small lines that want to leave at once) and
/// keepalive probes, so a link that died without a word (a phone that left
/// the network) is noticed in about 25 s of silence.
func configureStream(_ fd: Int32, tcp: Bool) {
    var one: Int32 = 1
    let size = socklen_t(MemoryLayout<Int32>.size)
    unsafe setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, size)
    guard tcp else { return }
    unsafe setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, size)
    unsafe setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, size)
    var idle: Int32 = 10, interval: Int32 = 5, count: Int32 = 3
    unsafe setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &idle, size)
    unsafe setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &interval, size)
    unsafe setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &count, size)
}

/// A connected stream to `address`, on the calling thread: a Bonjour name
/// is resolved first (its TXT record must name protocol 1), a host name
/// through the resolver, each of its addresses tried with `timeout`
/// seconds to connect. Throws why not.
public func openStream(_ address: TargetAddress, timeout: Double = 10) throws -> Int32 {
    switch address {
    case .unix(let path):
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw ProtocolError("socket: \(errnoText())") }
        configureStream(s, tcp: false)
        var addr = ProtocolServer.address(path)
        let r = withUnsafePointer(to: &addr) {
            unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { unsafe Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if r != 0 {
            let e = errnoText()
            Darwin.close(s)
            throw ProtocolError("connect \(path): \(e)")
        }
        return s
    case .tcp(let host, let port):
        return try connectTCP(host: host, port: port, timeout: timeout)
    case .bonjour(let name):
        let r = try BonjourResolver.resolve(name, timeout: timeout)
        if let v = r.txt.first(where: { $0.0 == "protocol" })?.1, v != "1" {
            throw ProtocolError("\(name) speaks protocol \(v), not 1")
        }
        return try connectTCP(host: r.host, port: r.port, timeout: timeout)
    }
}

/// Every address the resolver gives for `host`, in its order, until one
/// connects within `timeout` (non-blocking connect and a poll).
func connectTCP(host: String, port: Int, timeout: Double) throws -> Int32 {
    var hints = unsafe addrinfo()
    unsafe hints.ai_socktype = SOCK_STREAM
    unsafe hints.ai_family = AF_UNSPEC
    unsafe hints.ai_flags = AI_NUMERICSERV
    var list: UnsafeMutablePointer<addrinfo>? = nil
    let rc = unsafe getaddrinfo(host, String(port), &hints, &list)
    guard rc == 0, let first = unsafe list else {
        throw ProtocolError("cannot resolve \(host): \(unsafe String(cString: gai_strerror(rc)))")
    }
    defer { unsafe freeaddrinfo(first) }
    var why = "no address"
    var next: UnsafeMutablePointer<addrinfo>? = unsafe first
    let ms = Int32(max(0.1, min(timeout, 60)) * 1000)
    while let ai = unsafe next {
        unsafe next = unsafe ai.pointee.ai_next
        let s = unsafe socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        if s < 0 { why = "socket: \(errnoText())"; continue }
        let flags = fcntl(s, F_GETFL)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        var r = unsafe Darwin.connect(s, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
        if r != 0 && errno == EINPROGRESS {
            var p = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
            if unsafe poll(&p, 1, ms) == 1 {
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                unsafe getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len)
                r = err == 0 ? 0 : -1
                if err != 0 { why = "connect \(host):\(port): \(unsafe String(cString: strerror(err)))" }
            } else {
                why = "connect \(host):\(port): no answer within \(ms) ms"
            }
        } else if r != 0 {
            why = "connect \(host):\(port): \(errnoText())"
        }
        if r == 0 {
            _ = fcntl(s, F_SETFL, flags)
            configureStream(s, tcp: true)
            return s
        }
        Darwin.close(s)
    }
    throw ProtocolError(why)
}

// MARK: - TXT records

/// A DNS TXT record: length-prefixed `key=value` strings. What a serving
/// target advertises (the image's name, the protocol's version, the
/// kernel's version; never the token) and what a resolver hands back from
/// the network, so `decode` trusts nothing.
public enum TXTRecord {
    public static func encode(_ pairs: [(String, String)]) -> [UInt8] {
        var out: [UInt8] = []
        for (k, v) in pairs {
            let entry = Array("\(k)=\(v)".utf8.prefix(255))
            out.append(UInt8(entry.count))
            out += entry
        }
        return out.isEmpty ? [0] : out
    }

    /// The pairs of a record, at most 16, each key 1 to 32 bytes of
    /// printable ASCII, each value at most 128 bytes of UTF-8 without
    /// control characters; anything else is skipped.
    public static func decode(_ bytes: [UInt8]) -> [(String, String)] {
        var out: [(String, String)] = []
        var i = 0
        while i < bytes.count && out.count < 16 {
            let n = Int(bytes[i])
            i += 1
            guard i + n <= bytes.count else { break }
            let entry = bytes[i..<i + n]
            i += n
            guard let eq = entry.firstIndex(of: 61) else { continue }
            if let pair = checked(Array(entry[entry.startIndex..<eq]), Array(entry[(eq + 1)...])) { out.append(pair) }
        }
        return out
    }

    /// A key and a value from the network, or nil.
    public static func checked(_ key: [UInt8], _ value: [UInt8]) -> (String, String)? {
        guard !key.isEmpty, key.count <= 32, key.allSatisfy({ $0 > 32 && $0 < 127 && $0 != 61 }), value.count <= 128,
              let v = String(validating: value, as: UTF8.self),
              !v.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
        return (String(decoding: key, as: UTF8.self), v)
    }
}

// MARK: - Bonjour

/// A Bonjour name resolved to a host and port (dns_sd's resolve, on the
/// calling thread with a deadline: a connection's own thread).
enum BonjourResolver {
    final class Box {
        var host: String?
        var port = 0
        var txt: [UInt8] = []
        var interface: UInt32 = 0
        var error: Int32 = 0
        var done = false
    }

    static func resolve(_ name: String, timeout: Double) throws -> (host: String, port: Int, txt: [(String, String)]) {
        let box = Box()
        let reply: DNSServiceResolveReply = { _, _, interface, error, _, host, port, length, txt, context in
            guard let context = unsafe context else { return }
            let b = unsafe Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
            if b.done { return }
            b.done = true
            b.error = error
            guard error == kDNSServiceErr_NoError, let host = unsafe host else { return }
            b.host = unsafe String(cString: host)
            b.port = Int(UInt16(bigEndian: port))
            b.interface = interface
            if let txt = unsafe txt, length > 0 {
                b.txt = unsafe Array(UnsafeRawBufferPointer(start: txt, count: Int(length)))
            }
        }
        var ref: DNSServiceRef? = nil
        let started = unsafe DNSServiceResolve(&ref, 0, 0, name, TargetAddress.serviceType, "local.", reply,
                                               Unmanaged.passUnretained(box).toOpaque())
        guard started == kDNSServiceErr_NoError, let r = unsafe ref else { throw ProtocolError("cannot resolve \(name): dns_sd error \(started)") }
        defer { unsafe DNSServiceRefDeallocate(r) }
        let fd = unsafe DNSServiceRefSockFD(r)
        let end = Date(timeIntervalSinceNow: timeout)
        while !box.done {
            let left = Int32(end.timeIntervalSinceNow * 1000)
            guard left > 0 else { throw ProtocolError("no Bonjour service \(name) answered within \(timeout) s") }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let n = unsafe poll(&p, 1, left)
            if n < 0 && errno == EINTR { continue }
            if n > 0 { _ = unsafe DNSServiceProcessResult(r) }
        }
        guard box.error == kDNSServiceErr_NoError, var host = box.host, (1...65535).contains(box.port) else {
            throw ProtocolError("cannot resolve \(name): dns_sd error \(box.error)")
        }
        // A service found on the loopback interface is this machine's.
        let loopback = unsafe if_nametoindex("lo0")
        if box.interface == UInt32(kDNSServiceInterfaceIndexLocalOnly) || box.interface == loopback {
            host = "localhost"
        }
        guard TargetAddress.isHostName(host) else { throw ProtocolError("\(name) resolved to a host name that is not one") }
        return (host, box.port, TXTRecord.decode(box.txt))
    }
}

/// A serving target's advertisement (`_kajo-dev._tcp`, dns_sd's register,
/// its replies on a queue of its own). The name the system registered
/// (the device's name when none is given, renamed on a conflict) comes
/// back through `registered`.
@safe public final class BonjourAdvertiser: @unchecked Sendable {
    final class Box: @unchecked Sendable {
        let registered: @Sendable (String?, Int32) -> Void
        init(_ r: @escaping @Sendable (String?, Int32) -> Void) { registered = r }
    }

    private let queue = DispatchQueue(label: "kajo-bonjour")
    private let lock = NSLock()
    private var ref: DNSServiceRef?  // under lock
    private let box: Unmanaged<Box>

    /// Advertise `port` with `txt` under `name` (nil: the device's name) on
    /// every interface, or only on loopback (`loopbackOnly`: tests).
    public init(name: String?, port: Int, txt: [(String, String)], loopbackOnly: Bool = false,
                registered: @escaping @Sendable (String?, Int32) -> Void) throws {
        unsafe box = unsafe Unmanaged.passRetained(Box(registered))
        let reply: DNSServiceRegisterReply = { _, _, error, name, _, _, context in
            guard let context = unsafe context else { return }
            let b = unsafe Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
            b.registered(error == kDNSServiceErr_NoError ? unsafe name.map { unsafe String(cString: $0) } : nil, error)
        }
        let record = TXTRecord.encode(txt)
        var r: DNSServiceRef? = nil
        let interface: UInt32 = loopbackOnly ? unsafe if_nametoindex("lo0") : 0
        let e = unsafe DNSServiceRegister(&r, 0, interface, name, TargetAddress.serviceType, nil, nil, UInt16(port).bigEndian,
                                          UInt16(record.count), record, reply, box.toOpaque())
        guard e == kDNSServiceErr_NoError, let made = unsafe r else {
            unsafe box.release()
            throw ProtocolError("Bonjour: dns_sd error \(e)")
        }
        unsafe DNSServiceSetDispatchQueue(made, queue)
        unsafe ref = made
    }

    /// Withdraw the advertisement (on its queue, where its replies run).
    public func stop() {
        lock.lock()
        let r = unsafe ref
        unsafe ref = nil
        lock.unlock()
        guard let r = unsafe r else { return }
        queue.sync { unsafe DNSServiceRefDeallocate(r) }
        unsafe box.release()
    }

    deinit { stop() }
}

/// The `_kajo-dev._tcp` services on the network (Network.framework's
/// browser), by instance name with their checked TXT pairs; `changed` runs
/// on the browser's queue after every change.
public final class BonjourBrowser: @unchecked Sendable {
    private let browser: NWBrowser
    private let queue = DispatchQueue(label: "kajo-bonjour-browse")
    private let lock = NSLock()
    private var found: [String: [(String, String)]] = [:]  // under lock

    public init(changed: @escaping @Sendable () -> Void) {
        browser = NWBrowser(for: .bonjourWithTXTRecord(type: TargetAddress.serviceType, domain: "local."), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var now: [String: [(String, String)]] = [:]
            for r in results {
                guard case .service(let name, _, _, _) = r.endpoint, TargetAddress.isServiceName(name), now.count < 64 else { continue }
                var pairs: [(String, String)] = []
                if case .bonjour(let txt) = r.metadata {
                    for (k, v) in txt.dictionary.sorted(by: { $0.key < $1.key }) {
                        if let p = TXTRecord.checked(Array(k.utf8), Array(v.utf8)), pairs.count < 16 { pairs.append(p) }
                    }
                }
                now[name] = pairs
            }
            self.lock.lock()
            let same = Set(now.keys) == Set(self.found.keys)
            self.found = now
            self.lock.unlock()
            if !same { changed() }
        }
        browser.start(queue: queue)
    }

    /// The services seen now: name and TXT pairs, sorted by name.
    public var services: [(name: String, txt: [(String, String)])] {
        lock.lock()
        defer { lock.unlock() }
        return found.keys.sorted().map { ($0, found[$0]!) }
    }

    public func stop() { browser.cancel() }
}

// MARK: - this machine

/// This machine's addresses a phone's owner would type: IPv4 and global
/// IPv6 of every interface that is up, loopback and link-local left out
/// (what the phone shows beside its token).
public func localAddresses() -> [String] {
    var list: UnsafeMutablePointer<ifaddrs>? = nil
    guard unsafe getifaddrs(&list) == 0, let first = unsafe list else { return [] }
    defer { unsafe freeifaddrs(first) }
    var out: [String] = []
    var next: UnsafeMutablePointer<ifaddrs>? = unsafe first
    while let i = unsafe next {
        unsafe next = unsafe i.pointee.ifa_next
        let flags = unsafe Int32(i.pointee.ifa_flags)
        guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let a = unsafe i.pointee.ifa_addr else { continue }
        let family = unsafe Int32(a.pointee.sa_family)
        guard family == AF_INET || family == AF_INET6 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let len = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
        guard unsafe getnameinfo(a, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        let text = String(decoding: host.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if family == AF_INET6 && (text.hasPrefix("fe80") || text.contains("%")) { continue }
        if !out.contains(text) { out.append(text) }
    }
    return out.sorted { ($0.contains(":") ? 1 : 0, $0) < ($1.contains(":") ? 1 : 0, $1) }
}
