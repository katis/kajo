import Darwin
import Foundation

// Module 9b: the client's half: connect to a target's socket, open a
// session with the token, send requests and wait (bounded) for their
// replies, keep the events. The `kajo` CLI, the MCP server and the tests
// speak through it; the developer UI (9c) will speak the same protocol from
// Smalltalk. Module 9d: over any transport (`openStream`: a Unix socket,
// TCP, a Bonjour name), the same code the image's `ClientHost` uses.

public struct ProtocolError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ d: String) { description = d }
}

public final class ProtocolClient: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private let changed = NSCondition()
    private var replies: [String: JSONValue] = [:]  // under changed
    private var events: [JSONValue] = []  // under changed
    private var eventCount = 0  // under changed: events ever received
    private var closed = false  // under changed
    private var closing = false  // under changed: close() was called
    private var nextId = 1  // under lock
    private var fdClosed = false  // under lock
    private var reader: Thread?
    private var eventHandler: (@Sendable (JSONValue) -> Void)?  // under changed
    /// Called on the reading thread for every event (not replies).
    public var onEvent: (@Sendable (JSONValue) -> Void)? {
        get {
            changed.lock()
            defer { changed.unlock() }
            return eventHandler
        }
        set {
            changed.lock()
            eventHandler = newValue
            changed.unlock()
        }
    }

    /// Connect to a target at `path`: a socket path or, since module 9d,
    /// any `TargetAddress` form (`tcp://host:port`, `bonjour:<name>`).
    public convenience init(path: String, timeout: Double = 10) throws {
        guard let address = TargetAddress.parse(path) else { throw ProtocolError("not a target address: \(path)") }
        try self.init(address: address, timeout: timeout)
    }

    public init(address: TargetAddress, timeout: Double = 10) throws {
        fd = try openStream(address, timeout: timeout)
        let t = Thread { [self] in readLoop() }
        t.name = "kajo-client"
        reader = t
        t.start()
    }

    deinit { close() }

    private func readLoop() {
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = unsafe read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            var start = 0
            for i in 0..<n where chunk[i] == 10 {
                buffer += chunk[start..<i]
                start = i + 1
                if case .success(let v) = parseJSON(buffer, limits: { var l = JSONLimits(); l.bytes = 64 << 20; l.stringBytes = 64 << 20; l.depth = 64; l.elements = 1 << 20; return l }()) {
                    receive(v)
                }
                buffer.removeAll(keepingCapacity: true)
            }
            if start < n { buffer += chunk[start..<n] }
        }
        changed.lock()
        closed = true
        changed.broadcast()
        changed.unlock()
    }

    private func receive(_ v: JSONValue) {
        if v["kind"]?.string == "reply" {
            let key = v["id"].map { String(decoding: writeJSON($0), as: UTF8.self) } ?? "null"
            changed.lock()
            replies[key] = v
            changed.broadcast()
            changed.unlock()
            return
        }
        changed.lock()
        events.append(v)
        eventCount += 1
        if events.count > 100_000 { events.removeFirst(50_000) }
        changed.broadcast()
        changed.unlock()
        onEvent?(v)
    }

    /// Send a request and wait at most `timeout` seconds for its reply (the
    /// whole reply object: `ok`, `result` or `error`).
    public func send(_ kind: String, _ args: [(String, JSONValue)] = [], timeout: Double = 60) throws -> JSONValue {
        lock.lock()
        let id = nextId
        nextId += 1
        lock.unlock()
        try write(DevRequest(id: .int(Int64(id)), kind: kind, arguments: args).line)
        let key = "\(id)"
        let deadline = Date(timeIntervalSinceNow: timeout)
        changed.lock()
        defer { changed.unlock() }
        while replies[key] == nil {
            if closed { throw ProtocolError("the target closed the connection") }
            if !changed.wait(until: deadline) && replies[key] == nil {
                throw ProtocolError("no reply to \(kind) within \(timeout) s")
            }
        }
        return replies.removeValue(forKey: key)!
    }

    /// `send`, answering the result or throwing the error.
    public func request(_ kind: String, _ args: [(String, JSONValue)] = [], timeout: Double = 60) throws -> JSONValue {
        let r = try send(kind, args, timeout: timeout)
        guard r["ok"] == .bool(true) else { throw ProtocolError(r["error"]?.string ?? "an error reply without a message") }
        return r["result"] ?? .null
    }

    /// Open the session: the token the target showed, who this is
    /// (`developer`, `agent:<name>`), and the package changes go to.
    @discardableResult
    public func open(token: String, client: String, package: String? = nil, timeout: Double = 30) throws -> JSONValue {
        var args: [(String, JSONValue)] = [("token", .string(token)), ("client", .string(client))]
        if let package { args.append(("package", .string(package))) }
        return try request("session.open", args, timeout: timeout)
    }

    public func write(_ line: [UInt8]) throws {
        var bytes = line
        bytes.append(10)
        lock.lock()
        defer { lock.unlock() }
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBytes { unsafe Darwin.write(fd, $0.baseAddress! + off, bytes.count - off) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { throw ProtocolError("write: the connection is closed") }
            off += n
        }
    }

    /// How many events arrived so far (a mark for `events(since:)`).
    public var eventMark: Int {
        changed.lock()
        defer { changed.unlock() }
        return eventCount
    }

    /// The events kept since `mark`.
    public func events(since mark: Int) -> [JSONValue] {
        changed.lock()
        defer { changed.unlock() }
        let n = eventCount - mark
        return n <= 0 ? [] : Array(events.suffix(min(n, events.count)))
    }

    /// Wait at most `timeout` seconds for an event after `mark` that
    /// `matches`.
    public func waitForEvent(since mark: Int, timeout: Double, _ matches: (JSONValue) -> Bool) -> JSONValue? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        changed.lock()
        defer { changed.unlock() }
        while true {
            let n = eventCount - mark
            if n > 0, let e = events.suffix(min(n, events.count)).first(where: matches) { return e }
            if closed { return nil }
            if !changed.wait(until: deadline) { return nil }
        }
    }

    private var readerDone: Bool {
        changed.lock()
        defer { changed.unlock() }
        return closed
    }

    public var isClosed: Bool {
        changed.lock()
        defer { changed.unlock() }
        return closed || closing
    }

    public func close() {
        // Once: `deinit` calls this again, and a descriptor shut down or
        // closed twice may by then be someone else's (module 9d found a
        // Bonjour resolver's socket closed under it by a client's deinit).
        lock.lock()
        if fdClosed {
            lock.unlock()
            return
        }
        fdClosed = true
        lock.unlock()
        changed.lock()
        closing = true
        changed.unlock()
        shutdown(fd, SHUT_RDWR)
        changed.lock()
        let wasClosed = closed
        changed.unlock()
        if !wasClosed {
            // the reader ends on EOF
            var spins = 0
            while !readerDone && spins < 200 {
                usleep(5_000)
                spins += 1
            }
        }
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 { Darwin.close(fd) }
    }
}
