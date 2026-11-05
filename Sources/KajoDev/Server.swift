import Darwin
import Foundation
import KajoVM

// Module 9b: the target's half of the transport (docs/modules/development-protocol.md,
// "Transport"): a Unix-domain socket the host opens (`kajo run --protocol`,
// the macOS shell), a pairing token the first message must present, one
// session per connection. The host owns the socket; the image owns the
// meaning: every checked request goes into the VM's inbox
// (`ShellVM.postRequest`) and the kernel's replies and events come back
// through `deliver`, replies to their connection, events to every session.
//
// Each connection has a reading thread and a serial writing queue; a
// client that stops reading is dropped once 64 MiB wait for it. The token
// lives in this object's memory only: nothing here writes it to a file.
//
// Module 9d (docs/modules/phone-transport.md): the same server listens on
// TCP as well (the iOS shell's `protocol=tcp`), one accept loop, the same
// reader, the same first-line token rule, and limits for a network where
// every host may try the token: three failed `session.open` close a
// connection, and ten failures within a minute make the listener refuse
// every connection for a minute (`status` says so, the phone shows it).
// The token can be replaced (the phone's "new token"), which ends every
// session.

/// The text of `errno`.
func errnoText() -> String { unsafe String(cString: strerror(errno)) }

public final class ProtocolServer: @unchecked Sendable, CustomReflectable {
    /// Reflection (a test's failure message, a debugger's dump) never shows
    /// the token.
    public var customMirror: Mirror { Mirror(self, children: ["path": path]) }

    /// Where a client on this machine reaches the server: the socket's
    /// path, or `tcp://127.0.0.1:<port>`.
    public let path: String
    /// The TCP port (nil on a Unix socket).
    public let port: Int?
    private var currentToken: String  // under lock
    /// The token a session must present (it changes with `replaceToken`).
    public var token: String {
        lock.lock()
        defer { lock.unlock() }
        return currentToken
    }
    private let post: @Sendable (Int, [UInt8]) -> Void
    private let lock = NSLock()
    private var listenFD: Int32 = -1  // under lock
    private var connections: [Int: Connection] = [:]  // under lock
    private var nextConnection = 1  // under lock
    private var stopped = false  // under lock
    private var acceptThread: Thread?

    /// Module 9d: the limits on failed pairings (set before `start`).
    public struct Limits: Sendable {
        /// Failed `session.open` requests after which a connection closes.
        public var attemptsPerConnection = 3
        /// Failures (a wrong token, or a first request that is not
        /// `session.open`) within `windowNs` that stop the listener ...
        public var failuresPerWindow = 10
        public var windowNs: UInt64 = 60_000_000_000
        /// ... for this long: every connection is closed as it comes.
        public var pauseNs: UInt64 = 60_000_000_000
        public init() {}
    }
    private var currentLimits = Limits()  // under lock
    private var currentClock: @Sendable () -> UInt64 = { ShellVM.now() }  // under lock
    public var limits: Limits {
        get { lock.lock(); defer { lock.unlock() }; return currentLimits }
        set { lock.lock(); currentLimits = newValue; lock.unlock() }
    }
    /// The clock the limits count with (a test's own, to see a minute pass).
    public var clock: @Sendable () -> UInt64 {
        get { lock.lock(); defer { lock.unlock() }; return currentClock }
        set { lock.lock(); currentClock = newValue; lock.unlock() }
    }
    private var failureTimes: [UInt64] = []  // under lock
    private var refusingUntil: UInt64 = 0  // under lock
    /// Called when the listener starts or stops refusing (true: refusing,
    /// with the failures that made it): the phone says so on its screen.
    private var refusingAction: (@Sendable (Bool, Int) -> Void)?  // under lock
    public var onRefusing: (@Sendable (Bool, Int) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return refusingAction }
        set { lock.lock(); refusingAction = newValue; lock.unlock() }
    }
    /// What the server did, for result lines and tests (never the token).
    public let stats = ServerStats()

    /// A short random token: 20 letters and digits (about 100 bits).
    public static func makeToken() -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        var bytes = [UInt8](repeating: 0, count: 20)
        unsafe arc4random_buf(&bytes, bytes.count)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Listen on `path` (a stale socket file there is replaced; a socket
    /// someone answers on, or any other file, is refused). `post` hands a
    /// checked request to the VM: the connection and the canonical JSON.
    public init(path: String, token: String = ProtocolServer.makeToken(),
                post: @escaping @Sendable (Int, [UInt8]) -> Void) throws {
        self.path = path
        self.port = nil
        self.currentToken = token
        self.post = post
        guard path.utf8.count < 104 else { throw Failure(description: "the socket path is longer than 103 bytes") }
        var st = stat()
        if unsafe lstat(path, &st) == 0 {
            guard st.st_mode & S_IFMT == S_IFSOCK else { throw Failure(description: "\(path) exists and is not a socket") }
            if ProtocolServer.answers(path) { throw Failure(description: "\(path) is in use") }
            unsafe unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(description: "socket: \(errnoText())") }
        var addr = ProtocolServer.address(path)
        let bound = withUnsafePointer(to: &addr) {
            unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { unsafe bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        // The socket file is the user's only (before anyone may connect:
        // `listen` comes after; the process-wide umask is not touched).
        guard bound == 0, unsafe chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            let e = errnoText()
            close(fd)
            throw Failure(description: "bind \(path): \(e)")
        }
        listenFD = fd
    }

    /// Module 9d: listen on TCP `port` (0: the system picks; `port` then
    /// says which), on every interface (IPv6 and IPv4) or on loopback only.
    public init(tcpPort: Int, loopbackOnly: Bool = false, token: String = ProtocolServer.makeToken(),
                post: @escaping @Sendable (Int, [UInt8]) -> Void) throws {
        guard (0...65535).contains(tcpPort) else { throw Failure(description: "a TCP port is 0 to 65535") }
        self.currentToken = token
        self.post = post
        // Every interface: one IPv6 socket that takes IPv4 too. Loopback
        // only: IPv4's 127.0.0.1 (a client resolving localhost tries ::1,
        // then this).
        let fd = socket(loopbackOnly ? AF_INET : AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(description: "socket: \(errnoText())") }
        var zero: Int32 = 0, one: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        if !loopbackOnly { unsafe setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &zero, size) }
        unsafe setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, size)
        var bound: Int32 = -1
        var chosen = 0
        if loopbackOnly {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(tcpPort).bigEndian
            addr.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            bound = withUnsafeMutablePointer(to: &addr) {
                unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { p -> Int32 in
                    guard unsafe bind(fd, p, len) == 0 else { return -1 }
                    return unsafe getsockname(fd, p, &len)
                }
            }
            chosen = Int(UInt16(bigEndian: addr.sin_port))
        } else {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = UInt16(tcpPort).bigEndian
            addr.sin6_addr = in6addr_any
            var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
            bound = withUnsafeMutablePointer(to: &addr) {
                unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { p -> Int32 in
                    guard unsafe bind(fd, p, len) == 0 else { return -1 }
                    return unsafe getsockname(fd, p, &len)
                }
            }
            chosen = Int(UInt16(bigEndian: addr.sin6_port))
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let e = errnoText()
            close(fd)
            throw Failure(description: "listen on TCP port \(tcpPort): \(e)")
        }
        let p = chosen
        port = p
        path = "tcp://127.0.0.1:\(p)"
        listenFD = fd
    }

    static func address(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { p in
            for (i, b) in bytes.enumerated() where i < p.count - 1 { unsafe p[i] = b }
        }
        return addr
    }

    /// Whether something accepts connections on `path`.
    static func answers(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = address(path)
        return withUnsafePointer(to: &addr) {
            unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { unsafe connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }

    /// Accept connections on a thread of its own.
    public func start() {
        let t = Thread { [self] in acceptLoop() }
        t.name = "kajo-protocol-accept"
        acceptThread = t
        t.start()
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let fd = listenFD
            lock.unlock()
            if fd < 0 { return }
            let c = accept(fd, nil, nil)
            if c < 0 {
                if errno == EINTR { continue }
                return
            }
            configureStream(c, tcp: port != nil)
            lock.lock()
            if stopped {
                lock.unlock()
                close(c)
                return
            }
            if refusing() {
                lock.unlock()
                stats.add(\.refusedConnections)
                close(c)
                continue
            }
            let id = nextConnection
            nextConnection += 1
            let conn = Connection(id: id, fd: c, stats: stats)
            connections[id] = conn
            lock.unlock()
            let t = Thread { [self] in readLoop(conn) }
            t.name = "kajo-protocol-\(id)"
            t.start()
        }
    }

    private func readLoop(_ conn: Connection) {
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 65536)
        var discarding = false
        reading: while true {
            let n = unsafe read(conn.fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            var start = 0
            for i in 0..<n where chunk[i] == 10 {
                buffer += chunk[start..<i]
                start = i + 1
                if discarding {
                    discarding = false
                    conn.send(errorReply(id: .null, "malformed request: longer than \(RequestLimits.lineBytes) bytes"))
                } else if !handle(conn, buffer) {
                    break reading
                }
                buffer.removeAll(keepingCapacity: true)
            }
            if start < n { buffer += chunk[start..<n] }
            if buffer.count > RequestLimits.lineBytes {
                discarding = true
                buffer.removeAll()
            }
        }
        lock.lock()
        connections[conn.id] = nil
        lock.unlock()
        if conn.isOpen {
            post(conn.id, DevRequest(id: .null, kind: "session.close", arguments: []).canonical)
        }
        conn.close()
    }

    /// One line from a connection. False ends the connection.
    private func handle(_ conn: Connection, _ line: [UInt8]) -> Bool {
        if line.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 13 }) { return true }
        let request: DevRequest
        switch parseRequest(line) {
        case .success(let r): request = r
        case .failure(let refusal):
            conn.send(errorReply(id: refusal.id, refusal.message))
            return conn.isOpen
        }
        if !conn.isOpen {
            // No session without the token: the first request opens one.
            // Module 9d: a wrong token is a failed attempt, three close the
            // connection; a first request that is not session.open closes it
            // at once (9b); both count towards the listener's limit.
            guard request.kind == "session.open" else {
                noteFailure()
                conn.send(errorReply(id: request.id, "no session without the token: the first request is session.open with the token the target showed"))
                return false
            }
            guard let t = request["token"]?.string, ProtocolServer.same(t, token) else {
                noteFailure()
                conn.failedOpens += 1
                conn.send(errorReply(id: request.id, "no session without the token: the first request is session.open with the token the target showed"))
                return conn.failedOpens < limits.attemptsPerConnection
            }
            guard let client = request["client"]?.string, isClientName(client) else {
                conn.send(errorReply(id: request.id, "session.open needs a client: developer or agent:<name>"))
                return false
            }
            var args: [(String, JSONValue)] = [("client", .string(client))]
            if let p = request["package"], p != .null {
                guard let ps = p.string, isPackageName(ps) else {
                    conn.send(errorReply(id: request.id, "a package name is a letter, then letters, digits and -"))
                    return false
                }
                args.append(("package", .string(ps)))
            }
            conn.isOpen = true
            stats.add(\.sessions)
            post(conn.id, DevRequest(id: request.id, kind: "session.open", arguments: args).canonical)
            return true
        }
        if request.kind == "session.open" || request.kind == "session.close" {
            conn.send(errorReply(id: request.id, "\(request.kind) is the transport's"))
            return true
        }
        // Module 9c: the image takes a request as one String, which cannot
        // pass one heap block; a longer one is refused here, not dropped.
        let canonical = request.canonical
        guard canonical.count <= RequestLimits.imageBytes else {
            conn.send(errorReply(id: request.id, "a request longer than \(RequestLimits.imageBytes) bytes: the image takes a request as one String of at most one heap block"))
            return true
        }
        stats.add(\.requests)
        post(conn.id, canonical)
        return true
    }

    /// Under lock: whether the listener refuses now (and when a pause
    /// ends, that it no longer does).
    private func refusing() -> Bool {
        guard refusingUntil != 0 else { return false }
        if currentClock() < refusingUntil { return true }
        refusingUntil = 0
        failureTimes.removeAll()
        let r = refusingAction
        DispatchQueue.global().async { r?(false, 0) }
        return false
    }

    /// A failed pairing: the tenth within the window stops the listener.
    private func noteFailure() {
        stats.add(\.failedOpens)
        lock.lock()
        let now = currentClock()
        let l = currentLimits
        failureTimes.append(now)
        failureTimes.removeAll { now &- $0 > l.windowNs }
        var started = false
        if refusingUntil == 0 && failureTimes.count >= l.failuresPerWindow {
            refusingUntil = now &+ l.pauseNs
            started = true
        }
        let n = failureTimes.count
        let r = refusingAction
        lock.unlock()
        if started { r?(true, n) }
    }

    /// Whether the listener refuses connections now.
    public var isRefusing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return refusing()
    }

    /// Module 9d: a new token (the phone's button). Every connection ends:
    /// a session opened with the old token is over.
    public func replaceToken(_ t: String = ProtocolServer.makeToken()) {
        lock.lock()
        currentToken = t
        let all = Array(connections.values)
        lock.unlock()
        for c in all { c.close() }
    }

    /// Module 9d: end every connection as a dropped link would (the
    /// measurement's dropped link; tests).
    public func dropConnections() {
        lock.lock()
        let all = Array(connections.values)
        lock.unlock()
        for c in all { c.close() }
    }

    /// Constant time in the length of the expected token.
    static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var d = UInt8(x.count == y.count ? 0 : 1)
        for i in 0..<y.count { d |= (i < x.count ? x[i] : 0) ^ y[i] }
        return d == 0
    }

    /// A line the kernel emitted (`ShellCallbacks.events`, any VM thread):
    /// a reply goes to its connection, anything else to every session.
    public func deliver(_ line: [UInt8]) {
        let t0 = ShellVM.now()
        defer { stats.noteDeliver(ShellVM.now() &- t0) }
        let prefix = Array("{\"v\":1,\"kind\":\"reply\",\"conn\":".utf8)
        if line.count > prefix.count, Array(line[0..<prefix.count]) == prefix {
            var i = prefix.count, conn = 0
            while i < line.count, (48...57).contains(line[i]), conn < 1 << 40 {
                conn = conn * 10 + Int(line[i] - 48)
                i += 1
            }
            lock.lock()
            let c = connections[conn]
            lock.unlock()
            c?.send(line)
            return
        }
        lock.lock()
        let open = connections.values.filter(\.isOpen)
        lock.unlock()
        for c in open { c.send(line) }
    }

    public var sessionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections.values.filter(\.isOpen).count
    }

    /// Stop accepting, close every connection, remove the socket file.
    public func stop() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        let fd = listenFD
        listenFD = -1
        let all = Array(connections.values)
        connections = [:]
        lock.unlock()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        for c in all { c.close() }
        if port == nil { unsafe unlink(path) }
    }

    deinit { stop() }
}

/// One client's socket: its writes in order on a serial queue.
final class Connection: @unchecked Sendable {
    let id: Int
    let fd: Int32
    let stats: ServerStats
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var open = false  // under lock: the session was opened
    private var pending = 0  // under lock: bytes queued
    private var closed = false  // under lock
    /// Failed session.open requests (the reading thread's own).
    var failedOpens = 0

    init(id: Int, fd: Int32, stats: ServerStats) {
        self.id = id
        self.fd = fd
        self.stats = stats
        queue = DispatchQueue(label: "kajo-protocol-write-\(id)")
    }

    var isOpen: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return open && !closed
        }
        set {
            lock.lock()
            open = newValue
            lock.unlock()
        }
    }

    func send(_ line: [UInt8]) {
        lock.lock()
        if closed || pending > 64 << 20 {
            let drop = !closed
            lock.unlock()
            if drop { close() }
            return
        }
        pending += line.count + 1
        let now = pending
        lock.unlock()
        stats.notePending(now)
        let fd = self.fd
        queue.async { [self] in
            var bytes = line
            bytes.append(10)
            var off = 0
            while off < bytes.count {
                let n = bytes.withUnsafeBytes { unsafe write(fd, $0.baseAddress! + off, bytes.count - off) }
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                off += n
            }
            stats.noteWritten(off)
            lock.lock()
            pending -= bytes.count
            lock.unlock()
        }
    }

    func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        // After the queued writes (a refusal's reply goes out first), and
        // the fd is closed after them, so it is never reused under one.
        queue.async { [fd] in
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }
}

/// What a server did (module 9d's measurements and tests).
public final class ServerStats: @unchecked Sendable {
    public struct Values: Sendable {
        public var sessions = 0
        public var requests = 0
        public var failedOpens = 0
        public var refusedConnections = 0
        /// Bytes written to clients, the most ever queued for one, and the
        /// time `deliver` took on the VM thread that emitted a line (the
        /// writer never blocks it: the socket is the writing queue's).
        public var bytesWritten = 0
        public var maxPendingBytes = 0
        public var delivers = 0
        public var deliverTotalNs: UInt64 = 0
        public var deliverMaxNs: UInt64 = 0
        public init() {}
    }
    private let lock = NSLock()
    private var v = Values()  // under lock

    public var values: Values {
        lock.lock()
        defer { lock.unlock() }
        return v
    }

    func add(_ k: WritableKeyPath<Values, Int>) {
        lock.lock()
        v[keyPath: k] += 1
        lock.unlock()
    }

    func notePending(_ n: Int) {
        lock.lock()
        v.maxPendingBytes = max(v.maxPendingBytes, n)
        lock.unlock()
    }

    func noteWritten(_ n: Int) {
        lock.lock()
        v.bytesWritten += n
        lock.unlock()
    }

    func noteDeliver(_ ns: UInt64) {
        lock.lock()
        v.delivers += 1
        v.deliverTotalNs &+= ns
        v.deliverMaxNs = max(v.deliverMaxNs, ns)
        lock.unlock()
    }
}
