// Module 9c: the developer UI in Smalltalk (docs/modules/developer-ui.md).
// The development image (kernel/ and tools/) builds, the tools' SUnit tests
// pass, both packages are written back byte for byte, and in a test shell
// whose transport is the real one (`ClientHost`, a Unix socket, the image's
// own `ProtocolServer`) the tools develop the image they run in: a browser
// compiles a method whose file lands in the project directory, and an error
// in a tool's action stops only that Process, a debugger opens on it, the
// fix is defined and the send retried, and the tools go on.

import Darwin
import Foundation
import Synchronization
import Testing
@testable import KajoCompiler
@testable import KajoDev
@testable import KajoVM

let toolsDirectory: String = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { url.deleteLastPathComponent() }
    return url.appendingPathComponent("tools").path
}()

let toolsProbeDirectory: String = {
    var url = URL(fileURLWithPath: #filePath)
    url.deleteLastPathComponent()
    return url.appendingPathComponent("Fixtures/toolsprobe").path
}()

/// kernel/ and tools/: the development image.
let developmentImage: [UInt8] = {
    try! KernelBuild.build(KernelBuild.sources(in: [kernelDirectory, toolsDirectory])).image
}()

/// The development image and the probe the shell tests drive it with.
let probedImage: [UInt8] = {
    try! KernelBuild.build(KernelBuild.sources(in: [kernelDirectory, toolsDirectory, toolsProbeDirectory])).image
}()

/// A view host that takes every op of ADR 0010's two rounds and keeps the
/// properties it was given (the tools' windows in a test shell).
final class ToolsShell: Sendable {
    struct State {
        var next = 1
        var props: [Int: [String: ShellValue]] = [:]
        var kinds: [Int: String] = [:]
        var calls = 0
        var ops: [String: Int] = [:]
    }
    let state = Mutex(State())

    func view(_ call: ViewCall) -> ShellValue? {
        state.withLock { s -> ShellValue? in
            s.calls += 1
            let a = call.arguments
            let key = call.op == "call" ? "call." + (a.first?.string ?? "?") : call.op
            s.ops[key, default: 0] += 1
            if call.op == "create" {
                guard case .string(let kind)? = a.first else { return nil }
                let h = s.next
                s.next += 1
                s.props[h] = [:]
                s.kinds[h] = kind
                return .int(Int64(h))
            }
            guard s.props[call.handle] != nil else { return nil }
            switch call.op {
            case "set":
                guard a.count == 2, case .string(let k) = a[0] else { return nil }
                s.props[call.handle]![k] = a[1]
                return a[1]
            case "get":
                guard a.count == 1, case .string(let k) = a[0] else { return nil }
                if let v = s.props[call.handle]![k] { return v }
                switch k {
                case "selection": return .string("1 0")
                case "selected": return .int(0)
                case "text", "title": return .string("")
                default: return .int(0)
                }
            case "call":
                if a.first?.string == "select", a.count == 3, let x = a[1].int, let y = a[2].int {
                    s.props[call.handle]!["selection"] = .string("\(x) \(y)")
                }
                return .nil
            default:
                return .nil
            }
        }
    }

    var callbacks: ShellCallbacks {
        var c = ShellCallbacks()
        c.views = { [self] call in view(call) }
        return c
    }

    func count(_ op: String) -> Int { state.withLock { $0.ops[op] ?? 0 } }
}

/// A development image in a test shell serving its own protocol, with the
/// real client transport: what the macOS shell's `mode=dev` wires.
final class LocalTools: @unchecked Sendable, CustomReflectable, CustomStringConvertible {
    // A failed expectation prints its operands: never the token.
    var customMirror: Mirror { Mirror(self, children: [:]) }
    var description: String { "LocalTools(\(path))" }

    let vm: ShellVM
    let server: ProtocolServer
    let host = ClientHost()
    let shell = ToolsShell()
    let path = socketNames.next()

    /// `dropOn`: a Transcript line that makes the client transport drop
    /// every socket as a dead link would (module 9d's tests).
    init(image: [UInt8] = probedImage, dropOn: String? = nil) throws {
        let box = ServerBox()
        var c = shell.callbacks
        let h = host
        c.events = { line in
            if let marker = dropOn, line.count < 200, String(decoding: line, as: UTF8.self).contains("\"text\":\"\(marker)\"") {
                h.dropConnections()
            }
            box.server?.deliver(line)
        }
        c.client = host.callback
        var o = Headless.Options()
        o.heapMiB = 512
        o.workers = 2
        vm = try ShellVM(image: image, options: o, callbacks: c)
        let v = vm
        host.setSink { e in v.post(e) }
        server = try ProtocolServer(path: path) { conn, json in v.postRequest(connection: conn, json: json) }
        box.server = server
        host.addTarget(ClientHost.Target(name: "local", path: path, token: server.token))
        vm.openProtocol()
        vm.start()
        let p = try #require(vm.spawn("start", receiver: "DevProtocol"))
        #expect(drive(vm) { vm.state(of: p) == .terminated })
        #expect(vm.result(of: p) == .bool(true))
        vm.release(p)
        server.start()
    }

    func close() {
        host.closeAll()
        server.stop()
        vm.close()
    }

    /// `ToolsProbe selector` on main, run to its end with turns here.
    func probe(_ selector: String, _ args: [ShellValue] = []) throws -> ShellValue? {
        try run(vm, selector, on: "ToolsProbe", args, main: true)
    }

    /// Turns until `ToolsProbe selector` answers true (60 s at most).
    func until(_ selector: String, _ args: [ShellValue] = []) -> Bool {
        let end = ShellVM.now() + 60_000_000_000
        while ShellVM.now() < end {
            if (try? probe(selector, args)) == .bool(true) { return true }
            for _ in 0..<20 { if vm.runTurn(budgetNs: 2_000_000).slices == 0 { usleep(500) } }
        }
        Issue.record("\(selector) never held: \((try? probe("state"))??.string ?? "?")")
        return false
    }
}

@Suite(.serialized) struct ToolsTests {
    @Test func theDevelopmentImageBuildsAndTheToolsTestsPass() throws {
        let r = try KernelBuild.build(KernelBuild.sources(in: [kernelDirectory, toolsDirectory]))
        #expect(r.warnings.isEmpty, "\(r.warnings)")
        let classes = try FileManager.default.contentsOfDirectory(atPath: toolsDirectory).filter { $0.hasSuffix("Test.class.st") }
        #expect(classes.count >= 7)
        var total = 0
        for c in classes.sorted() {
            let name = String(c.dropLast(".class.st".count))
            let (result, lines) = runKernelTests(developmentImage, ["--filter", "\(name)>>*"])
            let report = TestReport(lines)
            #expect(try result.get() == 0, "\(name): \(report.failures.prefix(3))")
            #expect(report.total > 0 && report.passed == report.total, "\(name)")
            total += report.total
        }
        #expect(total >= 25)
    }

    @Test func bothPackagesAreWrittenBackByteForByte() throws {
        let image = try Image.load(image: developmentImage)
        defer { image.destroy() }
        let dir = try temporaryDirectory("packages")
        defer { try? FileManager.default.removeItem(at: dir) }
        for d in ["kernel", "tools"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        _ = try runSmalltalk(image, "writePackages:", ["Kernel", "kernel", "Tools", "tools"], sources: dir.path)
        for (package, source) in [("kernel", kernelDirectory), ("tools", toolsDirectory)] {
            let want = try FileManager.default.contentsOfDirectory(atPath: source).filter { $0.hasSuffix(".st") }.sorted()
            let got = try FileManager.default.contentsOfDirectory(atPath: dir.path + "/" + package).sorted()
            #expect(got == want, "\(package)")
            let differing = want.filter {
                FileManager.default.contents(atPath: source + "/" + $0) != FileManager.default.contents(atPath: dir.path + "/" + package + "/" + $0)
            }
            #expect(differing.isEmpty, "\(package): \(differing.prefix(10))")
        }
    }

    @Test func theClientTransportTrustsNothingTheSocketSends() throws {
        // A fake target that answers lines no protocol would: each is a
        // client.error line event, the connection's end a lost event.
        let path = socketNames.next()
        let events = Mutex<[ShellEvent]>([])
        let host = ClientHost()
        host.setSink { e in events.withLock { $0.append(e) } }
        host.addTarget(ClientHost.Target(name: "bad", path: path, token: "t"))
        let listener = try FakeTarget(path: path, lines: ["{\"v\":1,\"kind\":", "[1,2]", "\u{1}", "{\"v\":1,\"kind\":\"transcript\",\"text\":\"ok\"}"])
        defer { listener.stop() }
        let conn = try #require(host.callback(ViewCall(op: "connect", handle: 0, arguments: [.string(path), .string("developer"), .nil, .nil]))?.int)
        let end = ShellVM.now() + 30_000_000_000
        while ShellVM.now() < end && !events.withLock({ $0.contains { $0.kind == .lost } }) { usleep(2000) }
        let got = events.withLock { $0 }
        #expect(got.allSatisfy { $0.target == Int(conn) })
        let lines = got.filter { $0.kind == .line }.compactMap { $0.value.string }
        #expect(lines.count == 4)
        #expect(lines.prefix(3).allSatisfy { $0.contains("client.error") })
        #expect(lines.last?.contains("transcript") == true)
        #expect(got.last?.kind == .lost)
        #expect(listener.received.first?.contains("session.open") == true)
        #expect(listener.received.first?.contains("\"token\":\"t\"") == true)
        #expect(host.malformedLines == 3)
        // a request line with a line break is refused, an unknown connection too
        #expect(host.callback(ViewCall(op: "send", handle: Int(conn), arguments: [.string("{}\n{}")])) == nil)
        #expect(host.callback(ViewCall(op: "send", handle: 9999, arguments: [.string("{}")])) == nil)
        // no token known: the connection ends at once
        let c2 = try #require(host.callback(ViewCall(op: "connect", handle: 0, arguments: [.string(path + "x"), .string("developer"), .nil, .nil]))?.int)
        while ShellVM.now() < end && !events.withLock({ $0.contains { $0.kind == .lost && $0.target == Int(c2) } }) { usleep(2000) }
        #expect(events.withLock { $0.last?.value.string?.contains("no token") == true })
        host.closeAll()
    }

    @Test func aRequestTooLongForTheImageIsRefusedNotDropped() throws {
        let t = try LocalTools()
        defer { t.close() }
        let c = try ProtocolClient(path: t.path)
        defer { c.close() }
        let token = t.server.token
        try c.open(token: token, client: "developer", timeout: 60)
        let long = "^ '" + String(repeating: "x", count: 40_000) + "'"
        let r = try c.send("evaluate", [("source", .string(long))], timeout: 60)
        #expect(r["ok"] == .bool(false))
        #expect(r["error"]?.string?.contains("one heap block") == true)
        // A reply longer than one heap block comes back whole (written in
        // pieces in the target, joined by its transport).
        let methods = try c.request("package.selectors", [("name", .string("Kernel"))], timeout: 60)
        #expect((methods.array?.count ?? 0) > 2000)
        #expect(writeJSON(methods).count > 32 * 1024)
    }

    @Test func theToolsDevelopTheImageTheyRunIn() throws {
        let t = try LocalTools()
        defer { t.close() }
        let project = try temporaryDirectory("tools-project")
        defer { try? FileManager.default.removeItem(at: project) }
        #expect(try t.probe("open:project:", [.string(t.path), .string(project.path)]) == .bool(true))
        #expect(t.until("ready"))
        // A browser compiles a method into the running image through the
        // protocol; its file is written into the project directory.
        #expect(try t.probe("compileThroughTheBrowser") == .bool(true))
        // The method is installed before the reply leaves the target: wait
        // for the reply, after which the file is written.
        #expect(t.until("compiledThroughTheBrowser"))
        let file = project.appendingPathComponent("ToolsProbe.extension.st").path
        #expect((try? String(contentsOfFile: file, encoding: .utf8))?.contains("probeAnswer") == true)
        #expect(((try t.probe("latencyCount"))?.int ?? 0) >= 4)
        #expect(t.shell.count("call.setTree") >= 1)
        #expect(t.shell.count("call.setStyles") >= 1)
    }

    @Test func anErrorInAToolStopsOnlyItsProcessAndTheToolsGoOn() throws {
        let t = try LocalTools()
        defer { t.close() }
        let project = try temporaryDirectory("tools-debug")
        defer { try? FileManager.default.removeItem(at: project) }
        #expect(try t.probe("open:project:", [.string(t.path), .string(project.path)]) == .bool(true))
        #expect(t.until("ready"))
        let menu = try #require(try t.probe("installMenu")?.int)
        let loop0 = try #require(try t.probe("loopProcessId")?.int)
        // The user chooses the broken action: its doesNotUnderstand: stops
        // the event loop's Process, a new one takes the events, and the
        // process.stopped event opens a debugger in that new loop.
        t.vm.post(ShellEvent(kind: .menu, target: Int(menu), value: .int(1), timeNs: ShellVM.now()))
        #expect(t.until("debuggerReady"))
        #expect(try t.probe("handOvers") == .int(1))
        #expect(try t.probe("loopProcessId")?.int != loop0)
        // Define the missing method from the debugger; accepting it in the
        // browser that opened retries the send, and the action finishes.
        let defined = try t.probe("defineTheMissingMethod")
        #expect(defined == .bool(true), "\(defined.map { "\($0)" } ?? "nil")")
        #expect(try t.probe("acceptTheFix") == .bool(true))
        let end = ShellVM.now() + 60_000_000_000
        while ShellVM.now() < end, (try? t.probe("results"))?.string?.contains("42") != true {
            for _ in 0..<20 { if t.vm.runTurn(budgetNs: 2_000_000).slices == 0 { usleep(500) } }
        }
        #expect(try t.probe("results") == .string("#(42)"))
        // The tools go on: the next action runs in the new loop.
        t.vm.post(ShellEvent(kind: .menu, target: Int(menu), value: .int(2), timeNs: ShellVM.now()))
        let end2 = ShellVM.now() + 30_000_000_000
        while ShellVM.now() < end2, (try? t.probe("results"))?.string != "#(42 #again)" {
            for _ in 0..<20 { if t.vm.runTurn(budgetNs: 2_000_000).slices == 0 { usleep(500) } }
        }
        #expect(try t.probe("results") == .string("#(42 #again)"))
        #expect(try t.probe("handOvers") == .int(1))
        let file = project.appendingPathComponent("ToolsProbe.extension.st").path
        #expect((try? String(contentsOfFile: file, encoding: .utf8))?.contains("missingStep") == true)
    }
}

/// A Unix socket that accepts one connection, reads its first line and
/// answers the lines given, then closes.
final class FakeTarget: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var got: [String] = []
    let path: String

    init(path: String, lines: [String]) throws {
        self.path = path
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = ProtocolServer.address(path)
        let r = withUnsafePointer(to: &addr) {
            unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { unsafe bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard r == 0, listen(s, 1) == 0 else { throw ProtocolError("fake target: bind") }
        fd = s
        let t = Thread { [self] in
            let c = accept(s, nil, nil)
            guard c >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = unsafe read(c, &buf, buf.count)
            if n > 0 {
                let line = String(decoding: buf[0..<n], as: UTF8.self)
                lock.lock()
                got.append(line)
                lock.unlock()
            }
            for l in lines {
                let b = Array((l + "\n").utf8)
                _ = b.withUnsafeBytes { unsafe write(c, $0.baseAddress!, b.count) }
            }
            close(c)
        }
        t.start()
    }

    var received: [String] {
        lock.lock()
        defer { lock.unlock() }
        return got
    }

    func stop() {
        shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(path)
    }
}
