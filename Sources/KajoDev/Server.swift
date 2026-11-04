import Darwin
import Foundation

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

/// The text of `errno`.
func errnoText() -> String { unsafe String(cString: strerror(errno)) }

public final class ProtocolServer: @unchecked Sendable {
    public let path: String
    public let token: String
    private let post: @Sendable (Int, [UInt8]) -> Void
    private let lock = NSLock()
    private var listenFD: Int32 = -1  // under lock
    private var connections: [Int: Connection] = [:]  // under lock
    private var nextConnection = 1  // under lock
    private var stopped = false  // under lock
    private var acceptThread: Thread?

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
        self.token = token
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
        let old = umask(0o077)  // the socket file is the user's only
        let bound = withUnsafePointer(to: &addr) {
            unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { unsafe bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(old)
        guard bound == 0, listen(fd, 16) == 0 else {
            let e = errnoText()
            close(fd)
            throw Failure(description: "bind \(path): \(e)")
        }
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
            var one: Int32 = 1
            unsafe setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            if stopped {
                lock.unlock()
                close(c)
                return
            }
            let id = nextConnection
            nextConnection += 1
            let conn = Connection(id: id, fd: c)
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
            guard request.kind == "session.open", let t = request["token"]?.string, ProtocolServer.same(t, token) else {
                conn.send(errorReply(id: request.id, "no session without the token: the first request is session.open with the token the target showed"))
                return false
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
            post(conn.id, DevRequest(id: request.id, kind: "session.open", arguments: args).canonical)
            return true
        }
        if request.kind == "session.open" || request.kind == "session.close" {
            conn.send(errorReply(id: request.id, "\(request.kind) is the transport's"))
            return true
        }
        post(conn.id, request.canonical)
        return true
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
        unsafe unlink(path)
    }

    deinit { stop() }
}

/// One client's socket: its writes in order on a serial queue.
final class Connection: @unchecked Sendable {
    let id: Int
    let fd: Int32
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var open = false  // under lock: the session was opened
    private var pending = 0  // under lock: bytes queued
    private var closed = false  // under lock

    init(id: Int, fd: Int32) {
        self.id = id
        self.fd = fd
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
        lock.unlock()
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
        shutdown(fd, SHUT_RDWR)
        // The fd is closed after the queued writes, so it is never reused
        // under one of them.
        queue.async { [fd] in Darwin.close(fd) }
    }
}
