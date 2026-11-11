// The review fixes, items 4 to 6 (docs/modules/review-fixes.md;
// primitives.F2 to F4 of docs/reviews/2026-11-10/primitives.md): the
// listener's accept loop and its limits on connections that have not
// opened a session, writes queued after a close, and the session.close
// the image hears whoever ends a connection.

import Darwin
import Foundation
import Testing
@testable import KajoCompiler
@testable import KajoDev
@testable import KajoVM

/// A raw TCP connection to loopback `port`.
private func rawConnect(_ port: Int) -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    // A write to a connection the server closed must fail, not raise
    // SIGPIPE in the test process (the 1 MiB below is cut off on purpose).
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var a = sockaddr_in()
    a.sin_family = sa_family_t(AF_INET)
    a.sin_port = in_port_t(UInt16(port).bigEndian)
    a.sin_addr.s_addr = inet_addr("127.0.0.1")
    let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    #expect(r == 0)
    return fd
}

/// Whether the server closed `fd` within `seconds` (a read answers 0 or
/// an error).
private func closedByServer(_ fd: Int32, within seconds: Double) -> Bool {
    var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let end = ShellVM.now() + UInt64(seconds * 1e9)
    while ShellVM.now() < end {
        if poll(&p, 1, 100) > 0 {
            var b = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &b, b.count)
            if n <= 0 { return true }
        }
    }
    return false
}

@Suite(.serialized) struct ReviewFixesTransportTests {
    /// Item 4: twenty connections that send nothing are accepted and closed
    /// (at most eight at once, the rest after the time limit), a
    /// connection that sends 1 MiB without a newline is closed, and a
    /// paired client still connects and is served. On d78afcc every one
    /// stayed open with a thread of its own and the 1 MiB was buffered.
    @Test func connectionsWithoutASessionAreBounded() throws {
        let t = try TCPTarget()
        defer { t.close() }
        let server = t.target.server
        var l = server.limits
        l.unpairedNs = 2_000_000_000
        server.limits = l
        // One at a time, each accepted before the next (a listen backlog of
        // 16 overflowed under ThreadSanitizer and the kernel reset three:
        // closed, but never the server's to count).
        let idle = (0..<20).map { k -> Int32 in
            let fd = rawConnect(t.port)
            let end = ShellVM.now() + 30_000_000_000
            while server.acceptedCount < k + 1 && ShellVM.now() < end { usleep(1000) }
            return fd
        }
        defer { idle.forEach { close($0) } }
        // The first twelve were closed to make room for the last eight ...
        #expect(idle.prefix(12).allSatisfy { closedByServer($0, within: 30) })
        // ... which the time limit closes.
        #expect(idle.suffix(8).allSatisfy { closedByServer($0, within: 30) })
        #expect(server.stats.values.unpairedClosed >= 20)
        // 1 MiB with no newline, before any session.
        let big = rawConnect(t.port)
        defer { close(big) }
        let mib = [UInt8](repeating: 65, count: 1 << 20)
        var sent = 0
        while sent < mib.count {
            let n = mib.withUnsafeBytes { write(big, $0.baseAddress! + sent, mib.count - sent) }
            if n <= 0 { break }
            sent += n
        }
        #expect(sent < mib.count || closedByServer(big, within: 30))
        // A paired client is served.
        let c = try t.client()
        defer { c.close() }
        try c.open(token: server.token, client: "developer", timeout: 60)
        #expect(try c.eval("3 + 4")["value"] == .string("7"))
        // A session's line is not bound by the unpaired limit.
        let long = String(repeating: "1 + ", count: 4000) + "1"
        // Compiling 4000 sends in Smalltalk under the sanitizer and twelve
        // busy loops ran past eval's 300 s in the review fixes' part 2 gate
        // run (unloaded the whole test took 247 s): the bound of something
        // that must come is long, the assertion unchanged.
        let r = try c.send("evaluate", [("source", .string(long))], timeout: compilerTestsUnderThreadSanitizer ? 1800 : 60)
        #expect(r["result"]?["value"] == .string("4001"), "\(r)")
    }

    /// Item 5: no write is queued behind a connection's close. Senders on
    /// eight threads race a close (the old window, the unlock before the
    /// enqueue, held open by a sleep); every write block ran before the
    /// shutdown.
    @Test func noWriteRunsAfterItsConnectionsClose() throws {
        var pair: [Int32] = [0, 0]
        Connection.sendWindowUs.store(200, ordering: .relaxed)
        defer { Connection.sendWindowUs.store(0, ordering: .relaxed) }
        for round in 0..<20 {
            #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
            var one: Int32 = 1
            setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let stats = ServerStats()
            let conn = Connection(id: round, fd: pair[0], stats: stats)
            let group = DispatchGroup()
            for _ in 0..<8 {
                DispatchQueue.global().async(group: group) {
                    for _ in 0..<20 { conn.send(Array("{\"v\":1}".utf8)) }
                }
            }
            usleep(500)
            conn.close()
            _ = group.wait(timeout: .now() + 60)
            conn.finish()
            #expect(stats.values.lateWrites == 0)
            close(pair[1])
        }
    }

    /// Item 6: a new token ends a session the image was told of, and the
    /// image hears it (session.close): it keeps no DevSession for it. On
    /// d78afcc the reader saw `closed` set and posted nothing.
    @Test func aNewTokenTellsTheImageTheSessionEnded() throws {
        let t = try TCPTarget()
        defer { t.close() }
        let c = try t.client()
        try c.open(token: t.target.server.token, client: "developer", timeout: 60)
        #expect(try c.eval("DevProtocol sessionCount")["value"] == .string("1"))
        t.target.server.replaceToken()
        c.close()
        let c2 = try t.client()
        defer { c2.close() }
        try c2.open(token: t.target.server.token, client: "developer", timeout: 60)
        var count = ""
        for _ in 0..<3000 {
            count = try c2.eval("DevProtocol sessionCount")["value"]?.string ?? ""
            if count == "1" { break }
            usleep(10_000)
        }
        #expect(count == "1")
        // The same for a dropped link the server noticed.
        let c3 = try t.client()
        try c3.open(token: t.target.server.token, client: "developer", timeout: 60)
        t.target.server.dropConnections()
        c3.close()
        let c4 = try t.client()
        defer { c4.close() }
        try c4.open(token: t.target.server.token, client: "developer", timeout: 60)
        for _ in 0..<3000 {
            count = try c4.eval("DevProtocol sessionCount")["value"]?.string ?? ""
            if count == "1" { break }
            usleep(10_000)
        }
        #expect(count == "1")
    }

    /// Item 16 (primitives.F5): one object of 100 000 distinct keys (the
    /// client's limits allow a million) is read in a CPU budget; with the
    /// members searched for each key it took about 5 x 10^9 comparisons.
    @Test func theDuplicateKeyCheckIsLinear() throws {
        var line = Array("{".utf8)
        for k in 0..<100_000 {
            if k > 0 { line.append(44) }
            line += Array("\"k\(k)\":1".utf8)
        }
        line.append(125)
        var limits = JSONLimits()
        limits.bytes = 1 << 26
        limits.elements = 1 << 20
        func cpu() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
        let t0 = cpu()
        guard case .success(.object(let fields)) = parseJSON(line, limits: limits) else {
            Issue.record("refused")
            return
        }
        let ns = cpu() - t0
        #expect(fields.count == 100_000)
        #expect(ns < (compilerTestsUnderThreadSanitizer ? 60 : 10) * 1_000_000_000, "\(Double(ns) / 1e9) s of CPU")
        // and a duplicate is still refused
        if case .success = parseJSON(Array(#"{"a":1,"b":2,"a":3}"#.utf8)) { Issue.record("a duplicate key accepted") }
    }

    /// Item 15 (kernel.F13): the protocol's own Process is refused for
    /// suspend, step, evaluate and terminate, and the target still serves.
    /// On d78afcc process.suspend parked it and nothing was served again.
    @Test func theProtocolProcessIsNotSuspendedOrTerminated() throws {
        let t = try TCPTarget()
        defer { t.close() }
        let c = try t.client()
        defer { c.close() }
        try c.open(token: t.target.server.token, client: "developer", timeout: 60)
        let id = try c.eval("(ProcessorScheduler primAllProcesses detect: [:p | p notNil and: [DevProtocol isProtocolProcess: p]]) id")["value"]?.string ?? ""
        let pid = JSONValue.int(try #require(Int64(id)))
        for (kind, args) in [("process.suspend", [("process", pid)]), ("process.terminate", [("process", pid)]),
                             ("process.step", [("process", pid), ("mode", .string("over"))]),
                             ("process.evaluate", [("process", pid), ("source", .string("1"))])] {
            let r = try c.send(kind, args, timeout: 60)
            #expect(r["ok"] == .bool(false), "\(kind) was not refused")
            #expect(r["error"]?.string?.contains("serves the development protocol") == true, "\(kind): \(r)")
        }
        #expect(try c.eval("3 + 4")["value"] == .string("7"))
    }
}

/// The review fixes, item 18 (primitives.F7's second half): a remove in a
/// reply's files takes a file or a link, never a directory: a directory in
/// a class file's place is refused and keeps what it holds. On d78afcc
/// `removeItem` removed it with everything in it.
@Test func aProjectRemoveNeverTakesADirectory() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kajo-project-remove-\(getpid())")
    try? FileManager.default.removeItem(at: dir)
    defer { try? FileManager.default.removeItem(at: dir) }
    let trap = dir.appendingPathComponent("A.class.st")
    try FileManager.default.createDirectory(at: trap, withIntermediateDirectories: true)
    try "keep".write(to: trap.appendingPathComponent("inside.txt"), atomically: false, encoding: .utf8)
    try "x".write(to: dir.appendingPathComponent("B.class.st"), atomically: false, encoding: .utf8)
    let writer = ProjectWriter(directory: dir.path)
    #expect(throws: ProtocolError.self) {
        try writer.apply(.object([("files", .array([.object([("path", .string("A.class.st")), ("remove", .bool(true))])]))]))
    }
    #expect(FileManager.default.fileExists(atPath: trap.appendingPathComponent("inside.txt").path))
    // a file is removed as before
    _ = try writer.apply(.object([("files", .array([.object([("path", .string("B.class.st")), ("remove", .bool(true))])]))]))
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("B.class.st").path))
}

/// The review fixes, item 19 (primitives.F9): primitive 160 that cannot
/// allocate (a full heap, here the bridge's test hook) puts the request
/// back and signals for it again; it is answered. On d78afcc it was
/// dequeued, lost, and the client waited for its timeout.
@Test func aRequestTheImageCannotAllocateIsNotLost() throws {
    let t = try TCPTarget()
    defer { t.close() }
    let c = try t.client()
    defer { c.close() }
    try c.open(token: t.target.server.token, client: "developer", timeout: 60)
    t.target.vm.bridge.failAllocations.store(3, ordering: .relaxed)
    #expect(try c.eval("3 + 4")["value"] == .string("7"))
    #expect(t.target.vm.bridge.failAllocations.load(ordering: .relaxed) == 0)
}
