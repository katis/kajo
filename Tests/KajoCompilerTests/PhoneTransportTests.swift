// Module 9d: the phone transport (docs/modules/phone-transport.md). The
// server over TCP on loopback with the token rule and the failure limits,
// a token replaced, Bonjour browsing against a listener the test starts,
// the address and targets-file forms and the TXT record, and the tools on
// another target over TCP whose link drops: the client reconnects, the
// requests pending at the loss are answered, the stopped Process is still
// there and its debugger shows it again.

import Darwin
import Foundation
import Synchronization
import Testing
@testable import KajoCompiler
@testable import KajoDev
@testable import KajoVM

/// A headless target serving over TCP on loopback (port 0), on its own
/// thread until `close`.
final class TCPTarget: @unchecked Sendable, CustomReflectable {
    var customMirror: Mirror { Mirror(self, children: ["port": port]) }
    let target: DevTarget
    let port: Int
    private let done = DispatchSemaphore(value: 0)

    init(_ image: [UInt8] = projectImage, advertise: String? = nil) throws {
        var o = Headless.Options()
        o.workers = 2
        o.heapMiB = 512
        target = try DevTarget(image: image, options: o, listen: .tcp(port: 0, loopbackOnly: true, advertise: advertise != nil, name: advertise))
        port = try #require(target.server.port)
        let t = target, d = done
        let th = Thread {
            t.run()
            d.signal()
        }
        th.name = "kajo-test-tcp-target"
        th.start()
    }

    var address: String { "tcp://127.0.0.1:\(port)" }

    func client() throws -> ProtocolClient { try ProtocolClient(path: address) }

    func close() {
        target.stop()
        _ = done.wait(timeout: .now() + 30)
        target.close()
    }
}

/// A clock a test moves.
final class TestClock: Sendable {
    let now = Atomic<UInt64>(1_000_000_000)
    func advance(seconds: Double) { now.add(UInt64(seconds * 1e9), ordering: .relaxed) }
}

@Suite(.serialized) struct PhoneTransportTests {
    @Test func theServerRecordsEachRequestsTimeInTheTarget() throws {
        // The devices' link measurement (2026-11-06): every request with an
        // integer id is recorded with when its bytes were read, when the
        // reply reached deliver and when the writer finished it, in that
        // order, under the id the client sent.
        let t = try TCPTarget()
        defer { t.close() }
        let server = t.target.server
        let c = try t.client()
        defer { c.close() }
        try c.open(token: server.token, client: "developer", timeout: 60)
        #expect(try c.eval("3 + 4")["value"] == .string("7"))
        #expect(try c.eval("6 * 7")["value"] == .string("42"))
        // The writer notes a reply written after write() returns, which may
        // be after the client read it: a bounded wait.
        let end = ShellVM.now() + 30_000_000_000
        var records = server.stats.requestRecords.records.filter { $0.kind == "evaluate" }
        while (records.count < 2 || records.contains { $0.writtenNs == 0 }) && ShellVM.now() < end {
            usleep(10_000)
            records = server.stats.requestRecords.records.filter { $0.kind == "evaluate" }
        }
        #expect(records.count == 2)
        #expect(Set(records.map(\.id)).count == 2)
        for r in records {
            #expect(r.readNs > 0 && r.readNs <= r.deliveredNs && r.deliveredNs <= r.writtenNs)
        }
        #expect(server.stats.requestRecords.dropped == 0)
        // session.open is the transport's, not a recorded request.
        #expect(!server.stats.requestRecords.records.contains { $0.kind == "session.open" })
    }

    @Test func theServerServesTCPWithTheTokenRuleAndTheLimits() throws {
        let t = try TCPTarget()
        defer { t.close() }
        let server = t.target.server
        let clock = TestClock()
        server.clock = { clock.now.load(ordering: .relaxed) }
        let refusals = Mutex<[Bool]>([])
        server.onRefusing = { r, _ in refusals.withLock { $0.append(r) } }
        // A session over TCP, on IPv4 and IPv6 loopback.
        let c = try t.client()
        try c.open(token: server.token, client: "developer", timeout: 60)
        #expect(try c.eval("3 + 4")["value"] == .string("7"))
        c.close()
        // localhost: ::1 first (nothing listens there), then 127.0.0.1.
        let c6 = try ProtocolClient(path: "tcp://localhost:\(t.port)")
        try c6.open(token: server.token, client: "developer", timeout: 60)
        #expect(try c6.eval("6 * 7")["value"] == .string("42"))
        c6.close()
        // A wrong token is refused twice on one connection and the
        // third refusal closes it.
        let w = try t.client()
        for _ in 0..<2 {
            let r = try w.send("session.open", [("token", .string("wrong")), ("client", .string("developer"))], timeout: 30)
            #expect(r["ok"] == .bool(false))
            #expect(!w.isClosed)
        }
        let r3 = try w.send("session.open", [("token", .string("wrong")), ("client", .string("developer"))], timeout: 30)
        #expect(r3["ok"] == .bool(false))
        #expect(throws: ProtocolError.self) { _ = try w.send("session.open", [("token", .string(server.token)), ("client", .string("developer"))], timeout: 30) }
        w.close()
        // Seven more failures (ten within the minute) and the listener
        // refuses every connection, the right token included.
        for _ in 0..<7 {
            let x = try t.client()
            _ = try? x.send("session.open", [("token", .string("nope")), ("client", .string("developer"))], timeout: 30)
            x.close()
        }
        #expect(server.isRefusing)
        #expect(refusals.withLock { $0 } == [true])
        let refused = try? t.client()
        #expect(throws: ProtocolError.self) { try refused?.open(token: server.token, client: "developer", timeout: 30) ?? { throw ProtocolError("closed") }() }
        refused?.close()
        #expect(server.stats.values.refusedConnections >= 1)
        // A minute later it serves again.
        clock.advance(seconds: 61)
        #expect(!server.isRefusing)
        let again = try t.client()
        try again.open(token: server.token, client: "developer", timeout: 60)
        #expect(try again.eval("1 + 1")["value"] == .string("2"))
        again.close()
        let v = server.stats.values
        #expect(v.failedOpens == 10)
        #expect(v.sessions >= 3)
        #expect(v.requests >= 3)
        #expect(v.bytesWritten > 0)
        // The end of the pause is reported on a global queue: under
        // ThreadSanitizer, with the suite's other targets busy, it came
        // later than 10 s once (module 10's gate run), so the bound is the
        // sanitizer's there (AGENTS.md: a bound the sanitizer inflates).
        let end = ShellVM.now() + (compilerTestsUnderThreadSanitizer ? 120 : 10) * 1_000_000_000
        while ShellVM.now() < end && refusals.withLock({ $0.count }) < 2 { usleep(2000) }
        #expect(refusals.withLock { $0 } == [true, false])
    }

    @Test func aNewTokenEndsEverySession() throws {
        let t = try TCPTarget()
        defer { t.close() }
        let old = t.target.server.token
        let c = try t.client()
        try c.open(token: old, client: "developer", timeout: 60)
        t.target.server.replaceToken()
        #expect(t.target.server.token != old)
        #expect(throws: ProtocolError.self) { _ = try c.eval("1") }
        c.close()
        let c2 = try t.client()
        #expect(throws: ProtocolError.self) { try c2.open(token: old, client: "developer", timeout: 30) }
        c2.close()
        let c3 = try t.client()
        try c3.open(token: t.target.server.token, client: "developer", timeout: 60)
        #expect(try c3.eval("2 + 2")["value"] == .string("4"))
        c3.close()
    }

    @Test func bonjourFindsAListenerTheTestStarts() throws {
        let name = "kajo-test-\(getpid())"
        let t = try TCPTarget(advertise: name)
        defer { t.close() }
        let events = Mutex<[ShellEvent]>([])
        let host = ClientHost()
        host.setSink { e in events.withLock { $0.append(e) } }
        host.startBrowsing()
        defer { host.stopBrowsing() }
        let end = ShellVM.now() + 30_000_000_000
        while ShellVM.now() < end && !host.listedTargets.contains(where: { $0.name == name }) { usleep(10_000) }
        #expect(host.listedTargets.contains { $0.name == name && $0.path == "bonjour:\(name)" })
        #expect(events.withLock { $0.contains { $0.kind == .targets } })
        // Listed without a token until one is known for the address.
        let lines = host.callback(ViewCall(op: "targets", handle: 0, arguments: []))?.string ?? ""
        #expect(lines.contains("\(name)\tbonjour:\(name)\t0"))
        // The Swift client reaches it by its Bonjour name.
        let c = try ProtocolClient(path: "bonjour:\(name)")
        try c.open(token: t.target.server.token, client: "developer", timeout: 60)
        #expect(try c.eval("5 + 5")["value"] == .string("10"))
        c.close()
        // The client transport too, by the name, with the token a targets
        // file gives for the address (the image never sees it).
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kajo-targets-\(getpid())").path
        defer { unlink(file) }
        FileManager.default.createFile(atPath: file, contents: Data("# a phone\n\(name)\tbonjour:\(name)\t\(t.target.server.token)\n".utf8))
        #expect(host.readTargetsFile(file) == 1)
        let conn = try #require(host.callback(ViewCall(op: "connect", handle: 0, arguments: [.string(name), .string("developer"), .nil, .nil]))?.int)
        let end2 = ShellVM.now() + 60_000_000_000
        while ShellVM.now() < end2 && !events.withLock({ $0.contains { ($0.kind == .line || $0.kind == .lost) && $0.target == Int(conn) } }) { usleep(2000) }
        let reply = events.withLock { $0.first { ($0.kind == .line || $0.kind == .lost) && $0.target == Int(conn) } }?.value.string ?? ""
        #expect(reply.contains("\"id\":\"session\"") && reply.contains("\"ok\":true"), "\(reply)")
        #expect(!reply.contains(t.target.server.token))
        host.closeAll()
    }

    @Test func theAddressFormsTheTargetsFileAndTheTXTRecord() {
        let good: [(String, TargetAddress)] = [
            ("/tmp/kajo.sock", .unix("/tmp/kajo.sock")), ("tcp://192.168.1.5:52000", .tcp(host: "192.168.1.5", port: 52000)),
            ("tcp://jonis-iphone.local.:80", .tcp(host: "jonis-iphone.local.", port: 80)),
            ("tcp://[fe80::1%en0]:9000", .tcp(host: "fe80::1%en0", port: 9000)), ("bonjour:Joni’s iPhone", .bonjour("Joni’s iPhone")),
        ]
        for (text, address) in good {
            #expect(TargetAddress.parse(text) == address, "\(text)")
            #expect(TargetAddress.parse(address.description) == address)
        }
        let bad = ["", "phone", "tcp://", "tcp://host", "tcp://host:0", "tcp://host:65536", "tcp://ho st:1", "tcp://-a:1", "tcp://a..b:1",
                   "tcp://[zz::1]:1", "tcp://[::1]", "bonjour:", "bonjour:a\tb", "/tmp/a\tb", "/" + String(repeating: "x", count: 110),
                   "bonjour:" + String(repeating: "n", count: 64), "tcp://1.2.3.4:12a"]
        for b in bad { #expect(TargetAddress.parse(b) == nil, "\(b)") }
        let lines = [
            "phone bonjour:phone abcdef123", "phone\tbonjour:Joni’s iPhone\tabc", "mac tcp://192.168.1.10:5000", "local /tmp/k.sock tok # comment",
        ]
        for l in lines { #expect(ClientHost.targetLine(l) != nil, "\(l)") }
        let badLines = ["# only a comment", "", "one", "a b c d", "a notanaddress", "a /tmp/x.sock to-ken", "\u{1}x /tmp/x.sock"]
        for l in badLines { #expect(ClientHost.targetLine(l) == nil, "\(l)") }
        let pairs = [("image", "shell.img"), ("protocol", "1"), ("kernel", "0.1.0")]
        let decoded = TXTRecord.decode(TXTRecord.encode(pairs))
        #expect(decoded.map { $0.0 } == ["image", "protocol", "kernel"] && decoded.map { $0.1 } == ["shell.img", "1", "0.1.0"])
        // From the network: lengths past the end, no '=', control bytes,
        // a key too long: skipped, never a trap.
        #expect(TXTRecord.decode([200, 65, 61]).isEmpty)
        #expect(TXTRecord.decode([3, 97, 98, 99, 4, 107, 61, 1, 2]).isEmpty)
        #expect(TXTRecord.decode([34] + Array(repeating: 97, count: 33) + [61]).isEmpty)
        #expect(TXTRecord.decode([5, 107, 61, 0xFF, 0xFE, 0x41]).isEmpty)
    }

    @Test func aTokenIsPairedInTheHostNeverInTheImage() throws {
        // The owner's rule (2026-11-05): no token passes through the image,
        // not even a typed one. The tools ask the host to pair a target; the
        // host's secure field (here a fake that types the token the target
        // shows) keeps it; the tools then connect with it, by name.
        let remote = try TCPTarget()
        defer { remote.close() }
        let t = try LocalTools()
        defer { t.close() }
        let token = remote.target.server.token
        let asked = Mutex<[String]>([])
        t.host.setSecretPrompt { prompt, done in
            asked.withLock { $0.append(prompt) }
            done(token)
        }
        t.host.addTarget(ClientHost.Target(name: "phone", path: remote.address, token: nil))
        #expect(try t.probe("holdsTokenFor:", [.string(remote.address)]) == .bool(false))
        #expect(try t.probe("pair:", [.string("phone")]) == .bool(false))
        #expect(t.until("holdsTokenFor:", [.string(remote.address)]))
        #expect(asked.withLock { $0.count } == 1 && !asked.withLock { $0[0] }.contains(token))
        #expect(try t.probe("openRemote:", [.string("phone")]) == .bool(true))
        #expect(t.until("remoteReady"))
        // A connect never takes a token from the image: primitive 164's
        // connect has four arguments, none of them a token.
        #expect(t.host.callback(ViewCall(op: "connect", handle: 0, arguments: [.string("phone"), .string("developer"), .nil, .string(token), .nil])) == nil)
    }

    @Test func theToolsReconnectAfterADroppedLink() throws {
        // The target: a headless image over TCP; the tools: a development
        // image in a test shell whose client transport holds the target's
        // token, and drops every socket when the probe asks.
        let remote = try TCPTarget()
        defer { remote.close() }
        let t = try LocalTools(dropOn: "probe: drop")
        defer { t.close() }
        t.host.addTarget(ClientHost.Target(name: "phone", path: remote.address, token: remote.target.server.token))
        #expect(try t.probe("openRemote:", [.string(remote.address)]) == .bool(true))
        #expect(t.until("remoteReady"))
        #expect(try t.probe("stopRemote") == .bool(true))
        #expect(t.until("remoteDebuggerReady"))
        let pid = try #require(try t.probe("remoteProcess")?.int)
        #expect(try t.probe("dropWithRequests") == .bool(true))
        #expect(t.until("reconnected"))
        #expect(((try t.probe("remoteRetried"))?.int ?? 0) >= 2)
        // One reconnect: the first new session opened (the drop is the only loss).
        #expect(try t.probe("remoteReconnects") == .int(1))
        // The target agrees: the Process is still stopped there.
        let c = try remote.client()
        try c.open(token: remote.target.server.token, client: "developer", package: nil, timeout: 60)
        let list = try c.request("process.list")
        #expect(list.array?.contains { $0["process"] == .int(pid) && $0["stopped"] != nil } == true)
        _ = try c.request("process.terminate", [("process", .int(pid))])
        c.close()
        #expect(remote.target.server.stats.values.sessions >= 3)
    }
}

/// The suite runs under ThreadSanitizer as a gate; a bound it inflates gets
/// a value of its own (as `KajoVMTests`' `underThreadSanitizer`).
let compilerTestsUnderThreadSanitizer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__tsan_init") != nil
