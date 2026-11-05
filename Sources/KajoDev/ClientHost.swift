import Darwin
import Foundation
import KajoVM

// Module 9c: the protocol client's transport, the host's side of primitive
// 164 (docs/modules/developer-ui.md, "The protocol client in the image").
// The developer UI is Smalltalk and speaks the development protocol from
// inside its image; the shell (or `kajo run`, or a test) owns the sockets.
// Ops, from `ShellCallbacks.client` on any VM worker:
//
//   targets                         the known targets, one "name<TAB>path<TAB>token?" line each
//                                   (token? is 1 when the host holds one; the token itself never
//                                   enters the image)
//   connect  path client package token project
//                                   a new connection (its handle at once); the connect and the
//                                   session.open (with the token given, else the one the host
//                                   holds for the path) happen on a thread of its own
//   send     conn line              one request line, written in order on the connection's queue
//   close    conn
//   timer    ms token               a `timer` event (target: token) after ms milliseconds
//
// What a connection receives is trusted for nothing: each line is read by
// the bounded JSON reader and handed to the image as the canonical text
// the writer makes of it (a `line` event, target the connection); a line
// that is not JSON is a `line` event of kind `client.error` naming why,
// never a trap. A line longer than 16 KiB arrives in pieces (`linePart`
// events, then the `line` with the last): no object of the image can hold
// more than one heap block. When the connection was opened with a project directory,
// the `files` of every reply are written there (9b's `ProjectWriter`: file
// names only). The end of a connection is a `lost` event.
//
// Module 9d (docs/modules/phone-transport.md): a target is a name or an
// address (a socket path, `tcp://host:port`, `bonjour:<name>`), resolved
// and connected on the connection's own thread; `targets` also lists the
// `_kajo-dev._tcp` services a Bonjour browser sees (`startBrowsing`), and a
// change of that list is a `targets` event. The host keeps every token:
// those of `~/.kajo/targets` (whose lines may name any address form), its
// own transport's, and one the developer typed (remembered for the
// address, so a reconnect needs no second typing; never handed back).

public final class ClientHost: @unchecked Sendable, CustomReflectable {
    /// Reflection never shows the tokens the host holds.
    public var customMirror: Mirror { Mirror(self, children: ["connections": openConnections]) }

    /// A known target: where it is (a socket path or another address form,
    /// `TargetAddress`) and, when the host knows it, its token (in memory
    /// only: never written, never handed to the image).
    public struct Target: Sendable, CustomReflectable {
        public var customMirror: Mirror { Mirror(self, children: ["name": name, "path": path]) }
        public let name: String
        public let path: String
        public let token: String?
        public init(name: String, path: String, token: String?) {
            self.name = name
            self.path = path
            self.token = token
        }
    }

    private let lock = NSLock()
    private var sink: (@Sendable (ShellEvent) -> Void)?  // under lock
    private var targets: [Target] = []  // under lock
    private var connections: [Int: ClientConnection] = [:]  // under lock
    private var next = 1  // under lock
    private var closedAll = false  // under lock
    private var typedTokens: [String: String] = [:]  // under lock: address -> a token given at connect
    private var browser: BonjourBrowser?  // under lock
    /// Lines received and malformed lines (for tests).
    private var lines = 0  // under lock
    private var malformed = 0  // under lock
    public var linesReceived: Int {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
    public var malformedLines: Int {
        lock.lock()
        defer { lock.unlock() }
        return malformed
    }

    public init() {}

    /// Where events go (`ShellVM.post`); set once the VM exists.
    public func setSink(_ post: @escaping @Sendable (ShellEvent) -> Void) {
        lock.lock()
        sink = post
        lock.unlock()
    }

    private func post(_ e: ShellEvent) {
        lock.lock()
        let s = sink
        lock.unlock()
        s?(e)
    }

    /// A target the image may list and connect to by path; a later one of
    /// the same name replaces it.
    public func addTarget(_ t: Target) {
        lock.lock()
        targets.removeAll { $0.name == t.name }
        targets.append(t)
        lock.unlock()
    }

    public var knownTargets: [Target] {
        lock.lock()
        defer { lock.unlock() }
        return targets
    }

    /// `~/.kajo/targets` (or `path`): one target per line, `name address
    /// [token]`, blank-separated, or tab-separated when the line has a tab
    /// (a Bonjour name may hold blanks); `#` starts a comment. The address
    /// is any `TargetAddress` form. Answers how many were read. The tokens
    /// stay in this object.
    @discardableResult
    public func readTargetsFile(_ path: String = NSHomeDirectory() + "/.kajo/targets") -> Int {
        guard let data = FileManager.default.contents(atPath: path), data.count < 1 << 20,
              let text = String(data: data, encoding: .utf8) else { return 0 }
        var n = 0
        for raw in text.split(separator: "\n") {
            guard let t = ClientHost.targetLine(String(raw)) else { continue }
            addTarget(t)
            n += 1
        }
        return n
    }

    /// One line of a targets file, or nil (a comment, a blank line, or a
    /// line that is not `name address [token]` with a name of 1 to 64
    /// printable bytes, an address `TargetAddress` reads and a token of
    /// letters and digits). Fuzzed (`just fuzz protocol`).
    public static func targetLine(_ raw: String) -> Target? {
        let line = String(raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        let f: [String]
        if line.contains("\t") {
            f = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } else {
            f = line.split(whereSeparator: { $0 == " " }).map(String.init)
        }
        guard f.count >= 2, f.count <= 3, isTargetName(f[0]), TargetAddress.parse(f[1]) != nil else { return nil }
        if f.count == 3 {
            guard !f[2].isEmpty, f[2].utf8.count <= 128, f[2].utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) })
            else { return nil }
        }
        return Target(name: f[0], path: f[1], token: f.count == 3 ? f[2] : nil)
    }

    /// A target's name: 1 to 64 bytes, no control characters.
    public static func isTargetName(_ n: String) -> Bool {
        !n.isEmpty && n.utf8.count <= 64 && !n.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    }

    /// Module 9d: browse for phones (`_kajo-dev._tcp`); the image gets a
    /// `targets` event whenever the list changes.
    public func startBrowsing() {
        lock.lock()
        defer { lock.unlock() }
        guard browser == nil else { return }
        browser = BonjourBrowser { [weak self] in
            self?.post(ShellEvent(kind: .targets, timeNs: ShellVM.now()))
        }
    }

    public func stopBrowsing() {
        lock.lock()
        let b = browser
        browser = nil
        lock.unlock()
        b?.stop()
    }

    /// The targets the image may list: the known ones, then each Bonjour
    /// service not already known by its address (named by its service
    /// name, at `bonjour:<name>`, with the token a known target of that
    /// address holds).
    public var listedTargets: [Target] {
        lock.lock()
        let known = targets
        let b = browser
        lock.unlock()
        var out = known
        for s in b?.services ?? [] {
            let address = TargetAddress.bonjour(s.name).description
            if out.contains(where: { $0.path == address || $0.name == s.name }) { continue }
            out.append(Target(name: s.name, path: address, token: nil))
        }
        return out
    }

    /// What a `connect` names: a known or browsed target's name, or an
    /// address. The address and the token the host holds for it.
    func resolve(_ named: String) -> (address: TargetAddress, token: String?)? {
        let all = listedTargets
        lock.lock()
        let typed = typedTokens
        lock.unlock()
        func token(_ address: String) -> String? {
            all.first(where: { $0.path == address && $0.token != nil })?.token ?? typed[address]
        }
        if let t = all.first(where: { $0.name == named }), let a = TargetAddress.parse(t.path) {
            return (a, t.token ?? token(t.path))
        }
        guard let a = TargetAddress.parse(named) else { return nil }
        return (a, token(a.description))
    }

    /// The callback for `ShellCallbacks.client`.
    public var callback: @Sendable (ViewCall) -> ShellValue? { { [self] call in handle(call) } }

    func handle(_ call: ViewCall) -> ShellValue? {
        let a = call.arguments
        switch call.op {
        case "targets":
            // Names and addresses are checked where they enter (no tab, no
            // line break): the image splits these lines on tabs.
            let all = listedTargets
            lock.lock()
            let typed = typedTokens
            lock.unlock()
            let lines = all.map { "\($0.name)\t\($0.path)\t\($0.token == nil && typed[$0.path] == nil ? 0 : 1)" }
            return .string(lines.joined(separator: "\n"))
        case "connect":
            guard a.count == 5, let named = a[0].string, let client = a[1].string,
                  let (address, held) = resolve(named) else { return nil }
            let package = a[2].string, project = a[4].string
            let token = a[3].string ?? held
            lock.lock()
            if closedAll {
                lock.unlock()
                return nil
            }
            // A token typed by hand is kept for the address (in memory):
            // a reconnect after a dropped link opens the session with it.
            if let typed = a[3].string { typedTokens[address.description] = typed }
            let id = next
            next += 1
            let c = ClientConnection(id: id, address: address, project: project)
            connections[id] = c
            lock.unlock()
            let t = Thread { [self] in run(c, client: client, package: package, token: token) }
            t.name = "kajo-client-\(id)"
            t.start()
            return .int(Int64(id))
        case "send":
            guard a.count == 1, let line = a[0].string, !line.utf8.contains(10), let c = connection(call.handle) else { return nil }
            return .bool(c.send(Array(line.utf8)))
        case "close":
            guard let c = connection(call.handle) else { return .bool(false) }
            c.close()
            return .bool(true)
        case "timer":
            guard a.count == 2, let ms = a[0].int, ms >= 0, ms <= 3_600_000, let token = a[1].int, token >= 0 else { return nil }
            let target = Int(token)
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(ms))) { [self] in
                post(ShellEvent(kind: .timer, target: target, timeNs: ShellVM.now()))
            }
            return .bool(true)
        default:
            return nil
        }
    }

    private func connection(_ id: Int) -> ClientConnection? {
        lock.lock()
        defer { lock.unlock() }
        return connections[id]
    }

    /// A connection's thread: connect, open the session, read lines until
    /// the end, then the `lost` event.
    private func run(_ c: ClientConnection, client: String, package: String?, token: String?) {
        guard let token else {
            finish(c, "no token for \(c.address): enter it or list it in ~/.kajo/targets")
            return
        }
        if let e = c.connect() {
            finish(c, e)
            return
        }
        var args: [(String, JSONValue)] = [("token", .string(token)), ("client", .string(client))]
        if let package { args.append(("package", .string(package))) }
        c.open(DevRequest(id: .string("session"), kind: "session.open", arguments: args).line)
        c.readLines(limit: 64 << 20) { line, tooLong in
            let value = tooLong ? clientError("a line longer than 64 MiB from the target") : ClientHost.check(line)
            lock.lock()
            lines += 1
            if value["kind"]?.string == "client.error" { malformed += 1 }
            lock.unlock()
            let out = value
            if let dir = c.project, value["kind"]?.string == "reply", value["ok"] == .bool(true), let r = value["result"],
               r["files"] != nil {
                do { try ProjectWriter(directory: dir).apply(r) } catch {
                    post(ShellEvent(kind: .line, target: c.id, value: .string(String(decoding: writeJSON(clientError("\(error)")), as: UTF8.self)),
                                    timeNs: ShellVM.now()))
                }
            }
            let now = ShellVM.now()
            let pieces = linePieces(String(decoding: writeJSON(out), as: UTF8.self))
            for (k, p) in pieces.enumerated() {
                post(ShellEvent(kind: k == pieces.count - 1 ? .line : .linePart, target: c.id, value: .string(p), timeNs: now))
            }
        }
        finish(c, "the target closed the connection")
    }

    private func finish(_ c: ClientConnection, _ why: String) {
        c.release()
        lock.lock()
        connections[c.id] = nil
        lock.unlock()
        post(ShellEvent(kind: .lost, target: c.id, value: .string(why), timeNs: ShellVM.now()))
    }

    /// A line a target sent, as the value the image is given: the JSON
    /// object it holds, or a `client.error` object saying why not. The
    /// fuzz target holds it to never trapping (`just fuzz protocol`).
    public static func check(_ line: [UInt8]) -> JSONValue {
        var limits = JSONLimits()
        limits.bytes = 64 << 20
        limits.stringBytes = 64 << 20
        limits.depth = 64
        limits.elements = 1 << 20
        switch parseJSON(line, limits: limits) {
        case .success(let v):
            if case .object = v { return v }
            return clientError("a line from the target that is not a JSON object")
        case .failure(let e):
            return clientError("a malformed line from the target: \(e)")
        }
    }

    /// Close every connection (the shell quits, the VM closes); later
    /// connects fail.
    public func closeAll() {
        lock.lock()
        closedAll = true
        let all = Array(connections.values)
        lock.unlock()
        for c in all { c.close() }
    }

    public var openConnections: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections.count
    }

    /// Module 9d: end every connection's socket as a dropped link would
    /// (the client did not close it: its `DevClient` reconnects). The
    /// measurement's dropped link and the tests'.
    public func dropConnections() {
        lock.lock()
        let all = Array(connections.values)
        lock.unlock()
        for c in all { c.drop() }
    }
}

/// A line in pieces of at most 16 KiB, cut between scalars: no object of
/// the image can hold more than 32 KiB (a `linePart` event per piece but
/// the last, which is the `line` event).
public func linePieces(_ text: String, limit: Int = 16384) -> [String] {
    if text.utf8.count <= limit { return [text] }
    var out: [String] = []
    var piece = String.UnicodeScalarView()
    var bytes = 0
    for u in text.unicodeScalars {
        let n = String(u).utf8.count
        if bytes + n > limit {
            out.append(String(piece))
            piece = String.UnicodeScalarView()
            bytes = 0
        }
        piece.append(u)
        bytes += n
    }
    out.append(String(piece))
    return out
}

func clientError(_ message: String) -> JSONValue {
    .object([("v", .int(1)), ("kind", .string("client.error")), ("error", .string(message))])
}

/// One client socket: connected on its own thread, written in order on a
/// serial queue (lines sent before the session opened wait for it, so the
/// session's request is always the first), read by the same thread until
/// the end, which also closes the descriptor (after the queued writes).
final class ClientConnection: @unchecked Sendable {
    let id: Int
    let address: TargetAddress
    let project: String?
    private let lock = NSLock()
    private var fd: Int32 = -1  // under lock
    private var ready = false  // under lock: session.open was queued
    private var held: [[UInt8]] = []  // under lock: lines sent before that
    private var closed = false  // under lock
    private let queue: DispatchQueue

    init(id: Int, address: TargetAddress, project: String?) {
        self.id = id
        self.address = address
        self.project = project
        queue = DispatchQueue(label: "kajo-client-write-\(id)")
    }

    /// nil, or why not (resolving a name and connecting: `openStream`).
    func connect() -> String? {
        let s: Int32
        do { s = try openStream(address) } catch { return "\(error)" }
        lock.lock()
        if closed {
            lock.unlock()
            Darwin.close(s)
            return "closed before it connected"
        }
        fd = s
        lock.unlock()
        return nil
    }

    /// The session's request first, then whatever waited for it.
    func open(_ sessionLine: [UInt8]) {
        lock.lock()
        let f = fd
        let waiting = held
        held = []
        ready = true
        lock.unlock()
        for l in [sessionLine] + waiting { write(f, l) }
    }

    /// Queue one line (a newline is added). False when closed.
    func send(_ line: [UInt8]) -> Bool {
        lock.lock()
        if closed {
            lock.unlock()
            return false
        }
        if !ready {
            held.append(line)
            lock.unlock()
            return true
        }
        let f = fd
        lock.unlock()
        write(f, line)
        return true
    }

    private func write(_ f: Int32, _ line: [UInt8]) {
        queue.async {
            var bytes = line
            bytes.append(10)
            var off = 0
            while off < bytes.count {
                let n = bytes.withUnsafeBytes { unsafe Darwin.write(f, $0.baseAddress! + off, bytes.count - off) }
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                off += n
            }
        }
    }

    /// Read lines until the end; `each` gets a line, or (_, true) for one
    /// past `limit` (whose bytes are dropped).
    func readLines(limit: Int, _ each: ([UInt8], Bool) -> Void) {
        lock.lock()
        let f = fd
        lock.unlock()
        guard f >= 0 else { return }
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 65536)
        var discarding = false
        while true {
            let n = unsafe read(f, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            var start = 0
            for i in 0..<n where chunk[i] == 10 {
                buffer += chunk[start..<i]
                start = i + 1
                if discarding {
                    discarding = false
                    each([], true)
                } else if !buffer.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 13 }) {
                    each(buffer, false)
                }
                buffer.removeAll(keepingCapacity: true)
            }
            if start < n { buffer += chunk[start..<n] }
            if buffer.count > limit {
                discarding = true
                buffer.removeAll()
            }
        }
    }

    /// Any thread: the socket ends under the connection as a link that
    /// died would (writes fail, the reader sees the end).
    func drop() {
        lock.lock()
        let f = fd
        lock.unlock()
        if f >= 0 { shutdown(f, SHUT_RDWR) }
    }

    /// Any thread: end the connection (the reader sees the end).
    func close() {
        lock.lock()
        closed = true
        let f = fd
        lock.unlock()
        if f >= 0 { shutdown(f, SHUT_RDWR) }
    }

    /// The connection's own thread, after reading ended: the descriptor is
    /// closed once the queued writes are done, so it is never reused under
    /// one of them.
    func release() {
        close()
        lock.lock()
        let f = fd
        fd = -1
        lock.unlock()
        queue.sync {}
        if f >= 0 { Darwin.close(f) }
    }
}
