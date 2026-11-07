// Module 9b: the development protocol against a headless target (what
// `kajo run --protocol` runs: `DevTarget`), through the client the CLI and
// the MCP server use. docs/modules/development-protocol.md.

import Foundation
import Testing
@testable import KajoCompiler
@testable import KajoDev
@testable import KajoVM

let projectFixtureDirectory: String = {
    var url = URL(fileURLWithPath: #filePath)
    url.deleteLastPathComponent()
    return url.appendingPathComponent("Fixtures/project").path
}()

/// The kernel and the fixture project (package Sample), one build.
let projectImage: [UInt8] = {
    try! KernelBuild.build(KernelBuild.sources(in: [kernelDirectory, projectFixtureDirectory])).image
}()

final class SocketNames: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        n += 1
        return FileManager.default.temporaryDirectory.appendingPathComponent("kajo-\(getpid())-\(n).sock").path
    }
}
let socketNames = SocketNames()

/// A target serving on its own thread (its main worker) until `close`.
final class RunningTarget: @unchecked Sendable {
    let target: DevTarget
    let path: String
    private let done = DispatchSemaphore(value: 0)

    init(_ image: [UInt8] = projectImage, workers: Int = 2) throws {
        path = socketNames.next()
        var o = Headless.Options()
        o.workers = workers
        o.heapMiB = 512
        target = try DevTarget(image: image, options: o, socket: path)
        let t = target, d = done
        let th = Thread {
            t.run()
            d.signal()
        }
        th.name = "kajo-test-target-main"
        th.start()
    }

    func session(_ client: String = "agent:test", package: String? = "Sample") throws -> ProtocolClient {
        let c = try ProtocolClient(path: path)
        try c.open(token: target.server.token, client: client, package: package, timeout: 60)
        return c
    }

    func close() {
        target.stop()
        _ = done.wait(timeout: .now() + 30)
        target.close()
    }
}

extension ProtocolClient {
    /// 60 s for a reply, the sanitizer's 300 under ThreadSanitizer: one
    /// evaluate of `aSessionsProjectRebuildsTheImageItEdited` (every
    /// source of five classes, sorted and printed) passed 60 s in module
    /// 10's gate run under the sanitizer and twelve busy loops.
    func eval(_ source: String) throws -> JSONValue {
        try request("evaluate", [("source", .string(source))], timeout: compilerTestsUnderThreadSanitizer ? 300 : 60)
    }
    /// The next process.stopped event after `mark` (60 s at most).
    func stopped(since mark: Int, process: JSONValue? = nil) throws -> JSONValue {
        guard let e = waitForEvent(since: mark, timeout: 60, { $0["kind"]?.string == "process.stopped" && (process == nil || $0["process"] == process) })
        else { throw ProtocolError("no process.stopped") }
        return e
    }
}

@Suite(.serialized) struct DevProtocolTests {
    @Test func theRequestParserRefusesWhatIsNotARequest() {
        let good = #"{"v":1,"id":7,"kind":"method.compile","args":{"className":"Foo","source":"x ^ 1"}}"#
        guard case .success(let r) = parseRequest(Array(good.utf8)) else { Issue.record("a good request refused"); return }
        #expect(r.kind == "method.compile" && r.id == .int(7) && r["className"] == .string("Foo"))
        #expect(String(decoding: r.canonical, as: UTF8.self) == #"{"id":7,"kind":"method.compile","args":{"className":"Foo","source":"x ^ 1"}}"#)
        let bad = [
            "", "{", "[]", "null", #"{"v":1,"kind":"a"}"#, #"{"v":2,"id":1,"kind":"a"}"#, #"{"v":1,"id":1.5,"kind":"a"}"#,
            #"{"v":1,"id":1,"kind":"A.b"}"#, #"{"v":1,"id":1,"kind":"a..b"}"#, #"{"v":1,"id":1,"kind":"a","args":[]}"#,
            #"{"v":1,"id":1,"kind":"a","args":{"X":1}}"#, #"{"v":1,"id":1,"kind":"a","extra":1}"#,
            #"{"v":1,"id":1,"kind":"a","kind":"b"}"#, #"{"v":1,"id":1,"kind":"a","args":{"x":"\ud800"}}"#,
            #"{"v":1,"id":1,"kind":"a","args":{"x":1e999}}"#, #"{"v":1,"id":1,"kind":"a","args":{"x":9223372036854775807}}"#,
            #"{"v":1,"id":1,"kind":"a","args":{"x":"\u0000"}}"#, String(repeating: "[", count: 40) + String(repeating: "]", count: 40),
            #"{"v":1,"id":1,"kind":"a"} x"#, "{\"v\":1,\"id\":1,\"kind\":\"a\",\"args\":{\"x\":\"\u{1}\"}}",
        ]
        for b in bad {
            if case .success = parseRequest(Array(b.utf8)) { Issue.record("accepted: \(b)") }
        }
        if case .success = parseRequest([0xFF, 0xFE]) { Issue.record("accepted bytes that are not UTF-8") }
    }

    @Test func noSessionWithoutTheToken() throws {
        let t = try RunningTarget()
        defer { t.close() }
        let c = try ProtocolClient(path: t.path)
        let r = try c.send("evaluate", [("source", .string("1"))], timeout: 30)
        #expect(r["ok"] == .bool(false))
        #expect(r["error"]?.string?.contains("token") == true)
        let c2 = try ProtocolClient(path: t.path)
        #expect(throws: ProtocolError.self) { try c2.open(token: "not-the-token", client: "developer", timeout: 30) }
        let c3 = try ProtocolClient(path: t.path)
        #expect(throws: ProtocolError.self) { try c3.open(token: t.target.server.token, client: "root", timeout: 30) }
        let s = try t.session()
        let info = try s.request("protocol.describe")
        #expect((info.array?.count ?? 0) >= 25)
        #expect(try s.eval("3 + 4")["value"] == .string("7"))
        s.close()
    }

    @Test func aReleaseImageServesNoProtocol() throws {
        guard case .success(let sealed) = Headless.seal(image: projectImage) else { Issue.record("seal"); return }
        #expect(throws: (any Error).self) { _ = try RunningTarget(sealed) }
    }

    @Test func malformedRequestsAreRepliesAndTheTargetGoesOn() throws {
        // Seeded mutations of good request lines on an open session: each
        // line answered exactly once, by the transport (a refusal) or the
        // image (an error or a result); the target serves on.
        let t = try RunningTarget()
        defer { t.close() }
        let raw = try RawConnection(path: t.path)
        try raw.send(DevRequest(id: .int(0), kind: "session.open",
                                arguments: [("token", .string(t.target.server.token)), ("client", .string("developer"))]).line)
        #expect(try raw.reply()["ok"] == .bool(true))
        let lines = [
            #"{"v":1,"id":1,"kind":"evaluate","args":{"source":"3 + 4"}}"#,
            #"{"v":1,"id":2,"kind":"class.definition","args":{"className":"SampleCounter"}}"#,
            #"{"v":1,"id":3,"kind":"method.source","args":{"className":"SampleCounter","selector":"count","side":null}}"#,
            #"{"v":1,"id":4,"kind":"inspect","args":{"handle":1}}"#,
        ]
        var rng: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Int {
            rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
            return Int(rng % 1_000_000)
        }
        var refused = 0, answered = 0
        for k in 0..<300 {
            var b = Array(lines[k % lines.count].utf8)
            for _ in 0..<(1 + next() % 3) {
                let i = next() % b.count
                switch next() % 4 {
                case 0: b[i] = UInt8(next() % 256)
                case 1: b.remove(at: i)
                case 2: b.insert(UInt8(32 + next() % 95), at: i)
                default: b.swapAt(i, next() % b.count)
                }
            }
            b.removeAll { $0 == 10 || $0 == 13 }
            if b.isEmpty || b.allSatisfy({ $0 == 32 || $0 == 9 }) { continue }
            try raw.send(b)
            let r = try raw.reply()
            #expect(r["kind"] == .string("reply"))
            if r["ok"] == .bool(false) && r["error"]?.string?.hasPrefix("malformed") == true { refused += 1 } else { answered += 1 }
        }
        #expect(refused > 0 && answered > 0)
        try raw.send(DevRequest(id: .int(99), kind: "evaluate", arguments: [("source", .string("6 * 7"))]).line)
        #expect(try raw.reply()["result"]?["value"] == .string("42"))
    }

    @Test func changesAreInstalledMarkedAndWrittenToTheProject() throws {
        let t = try RunningTarget()
        defer { t.close() }
        let s = try t.session("agent:claude", package: "Sample")
        let dir = try temporaryDirectory("project-\(t.path.hashValue)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = ProjectWriter(directory: dir.path)
        // A method into a class of the package: its class file.
        let r1 = try s.request("method.compile", [("className", .string("SampleCounter")), ("source", .string("reset\n\tcount := 0")),
                                                  ("category", .string("accessing"))])
        #expect(try project.apply(r1) == ["SampleCounter.class.st"])
        let text = try String(contentsOf: dir.appendingPathComponent("SampleCounter.class.st"), encoding: .utf8)
        // The development answers: the agent's mark is a pragma in the
        // source, the metadata the category only.
        #expect(text.contains("{ #category : #accessing }\nSampleCounter >> reset [\n\t<author: #'agent:claude'>\n\tcount := 0\n]"))
        #expect(text.contains("{ #category : #accessing }\nSampleCounter >> increment [\n\t<author: #'agent:fixture'>\n"))
        #expect(!text.contains("#author :"))
        // A method into a kernel class: the package's extension file.
        let r2 = try s.request("method.compile", [("className", .string("Object")), ("source", .string("sampleThrice: x ^ x * 3")),
                                                  ("category", .string("*Sample"))])
        #expect(try project.apply(r2) == ["Object.extension.st"])
        let ext = try String(contentsOf: dir.appendingPathComponent("Object.extension.st"), encoding: .utf8)
        #expect(ext.hasPrefix("Extension { #name : #Object }\n"))
        #expect(ext.contains("Object >> sampleTwice: x [") && ext.contains("Object >> sampleThrice: x ["))
        let src = try s.request("method.source", [("className", .string("Object")), ("selector", .string("sampleThrice:"))])
        #expect(src["author"] == .string("agent:claude") && src["package"] == .string("Sample"))
        // A class defined by the session belongs to its package.
        let r3 = try s.request("class.define", [("name", .string("SampleThing")), ("superclass", .string("Object")),
                                                ("instanceVariables", .array([.string("a"), .string("b")])),
                                                ("category", .string("Sample-Core"))])
        #expect(try project.apply(r3) == ["SampleThing.class.st"])
        let def = try s.request("class.definition", [("className", .string("SampleThing"))])
        #expect(def["package"] == .string("Sample") && def["instanceVariables"] == .array([.string("a"), .string("b")]))
        let r4 = try s.request("class.remove", [("className", .string("SampleThing"))])
        #expect(try project.apply(r4) == ["-SampleThing.class.st"])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("SampleThing.class.st").path))
        // A refused change is an error reply and writes nothing.
        let bad = try s.send("method.compile", [("className", .string("SampleCounter")), ("source", .string("broken ^ ^"))])
        #expect(bad["ok"] == .bool(false) && bad["error"]?.string?.contains("CompileError") == true)
        // The project writer takes nothing but file names of the project.
        for evil in ["../x.class.st", "/tmp/x.class.st", "x.st", ".class.st", "a/b.class.st"] {
            #expect(throws: ProtocolError.self) {
                try project.apply(.object([("files", .array([.object([("path", .string(evil)), ("text", .string(""))])]))]))
            }
        }
    }

    @Test func aNewDevProtocolMethodIsANewRequest() throws {
        let t = try RunningTarget()
        defer { t.close() }
        let s = try t.session()
        let before = try s.request("protocol.describe").array?.count ?? 0
        _ = try s.request("method.compile", [("className", .string("DevSession")),
                                             ("source", .string("sampleEcho: text\n\t\"Answer the text twice.\"\n\t<devProtocol>\n\t^ text , text"))])
        let after = try s.request("protocol.describe").array ?? []
        #expect(after.count == before + 1)
        let d = after.first { $0["kind"] == .string("sample.echo") }
        #expect(d?["arguments"] == .array([.string("text")]) && d?["comment"] == .string("Answer the text twice."))
        #expect(try s.request("sample.echo", [("text", .string("ab"))]) == .string("abab"))
        let r = try s.send("sample.echo", [("txt", .string("ab"))])
        #expect(r["ok"] == .bool(false) && r["error"]?.string?.contains("no argument txt") == true)
    }
}

extension ProtocolClient {
    /// Start a doit that stops; its Process id and the process.stopped event.
    func stopIn(_ source: String) throws -> (JSONValue, JSONValue) {
        let mark = eventMark
        let r = try send("evaluate", [("source", .string(source))])
        #expect(r["ok"] == .bool(false) && r["error"]?.string?.hasPrefix("stopped") == true)
        let e = try stopped(since: mark)
        return (e["process"] ?? .null, e)
    }

    /// Wait (bounded) until `SampleDebug result` prints as `expected`.
    func waitForResult(_ expected: String) throws {
        for _ in 0..<3000 {
            if try eval("SampleDebug result")["value"] == .string(expected) { return }
            usleep(10_000)
        }
        Issue.record("SampleDebug result never became \(expected): \(try eval("SampleDebug result"))")
    }

    func compile(_ cls: String, _ source: String) throws {
        _ = try request("method.compile", [("className", .string(cls)), ("source", .string(source))])
    }
}

@Suite(.serialized) struct DebuggerProtocolTests {
    @Test func aMissingMethodIsDefinedAndTheSendRetried() throws {
        let t = try RunningTarget()
        defer { t.close() }
        let s = try t.session()
        // Defined on the receiver's class.
        var (p, e) = try s.stopIn("SampleDebug result: (SampleDebug new zork: 3)")
        #expect(e["reason"] == .string("error"))
        #expect(e["error"]?.string?.contains("zork:") == true)
        let frames = try s.request("process.frames", [("process", p)]).array ?? []
        #expect(frames.first?["method"] == .string("Object>>doesNotUnderstand:"))
        #expect(frames.count >= 2 && frames[1]["method"]?.string?.contains("DoIt") == true)
        try s.compile("SampleDebug", "zork: x ^ x * 100")
        _ = try s.request("process.retrySend", [("process", p)])
        try s.waitForResult("300")
        // Defined on a superclass of the receiver's.
        (p, _) = try s.stopIn("SampleDebug result: (SampleDebugSub new zork2: 4)")
        try s.compile("SampleDebug", "zork2: x ^ x + 1000")
        _ = try s.request("process.retrySend", [("process", p)])
        try s.waitForResult("1004")
        // Needing a class defined first.
        (p, _) = try s.stopIn("SampleDebug result: SampleDebug new makeHelper value")
        _ = try s.request("class.define", [("name", .string("SampleHelper")), ("superclass", .string("Object"))])
        try s.compile("SampleHelper", "value ^ 7")
        try s.compile("SampleDebug", "makeHelper ^ SampleHelper new")
        _ = try s.request("process.retrySend", [("process", p)])
        try s.waitForResult("7")
        // Not at doesNotUnderstand: refused, the Process still stopped.
        (p, _) = try s.stopIn("SampleDebug new failing: 1")
        let r = try s.send("process.retrySend", [("process", p)])
        #expect(r["ok"] == .bool(false))
        let list = try s.request("process.list").array ?? []
        #expect(list.contains { $0["process"] == p && $0["stopped"] == .string("error") })
        _ = try s.request("process.terminate", [("process", p)])
    }

    @Test func aFixedMethodIsRestartedInItsFrame() throws {
        let t = try RunningTarget()
        defer { t.close() }
        let s = try t.session()
        let (p, _) = try s.stopIn("SampleDebug result: (SampleDebug new failing: 2)")
        let frames = try s.request("process.frames", [("process", p)]).array ?? []
        guard let k = frames.firstIndex(where: { $0["method"] == .string("SampleDebug>>failing:") }) else {
            Issue.record("no failing: frame in \(frames)"); return
        }
        // Its variables and an evaluation in it.
        #expect(frames[k]["variables"]?.array?.first?["name"] == .string("x"))
        #expect(try s.request("process.evaluate", [("process", p), ("frame", .int(Int64(k + 1))), ("source", .string("x * 21"))])["value"]
                == .string("42"))
        try s.compile("SampleDebug", "failing: x ^ x * 1000")
        _ = try s.request("process.restart", [("process", p), ("frame", .int(Int64(k + 1)))])
        try s.waitForResult("2000")
    }

    @Test func aStoppedProcessSteps() throws {
        let t = try RunningTarget()
        defer { t.close() }
        let s = try t.session()
        let (p, _) = try s.stopIn("SampleDebug result: (SampleDebug new stepped: 5)")
        let frames = try s.request("process.frames", [("process", p)]).array ?? []
        guard let k = frames.firstIndex(where: { $0["method"] == .string("SampleDebug>>stepped:") }) else {
            Issue.record("no stepped: frame"); return
        }
        let source = frames[k]["source"]?.string ?? ""
        func text(_ e: JSONValue) -> String {
            guard let r = e["frames"]?.array?.first?["range"]?.array, let a = r.first?.int, let b = r.last?.int else { return "?" }
            let bytes = Array(source.utf8)
            return String(decoding: bytes[Int(a - 1)..<Int(b)], as: UTF8.self)
        }
        func step(_ mode: String, _ frame: Int) throws -> JSONValue {
            let mark = s.eventMark
            _ = try s.request("process.step", [("process", p), ("mode", .string(mode)), ("frame", .int(Int64(frame)))])
            let e = try s.stopped(since: mark, process: p)
            #expect(e["reason"] == .string("step"))
            return e
        }
        // Over, from the error: the frame goes on after the failed send.
        var e = try step("over", k + 1)
        #expect(e["frames"]?.array?.first?["method"] == .string("SampleDebug>>stepped:"))
        #expect(text(e) == "self first: n")
        // Into: the callee's first send.
        e = try step("into", 1)
        #expect(e["frames"]?.array?.first?["method"] == .string("SampleDebug>>first:"))
        // Out: back in the caller, after the send.
        e = try step("out", 1)
        #expect(e["frames"]?.array?.first?["method"] == .string("SampleDebug>>stepped:"))
        #expect(text(e) == "self first: n")
        // Over: the next send in the same frame.
        e = try step("over", 1)
        #expect(text(e) == "self second: a")
        #expect(try s.request("process.evaluate", [("process", p), ("frame", .int(1)), ("source", .string("a"))])["value"] == .string("6"))
        // An assignment reaches the frame (the send's operands were pushed
        // before the stop, so the send itself still takes 6).
        _ = try s.request("process.evaluate", [("process", p), ("frame", .int(1)), ("source", .string("a := 10"))])
        #expect(try s.request("process.evaluate", [("process", p), ("frame", .int(1)), ("source", .string("a"))])["value"] == .string("10"))
        _ = try s.request("process.proceed", [("process", p)])
        try s.waitForResult("9")
    }

    @Test func terminateRunsEnsureBlocksAndSuspendStops() throws {
        let t = try RunningTarget()
        defer { t.close() }
        let s = try t.session()
        let (p, _) = try s.stopIn("[SampleDebug result: #started. SampleDebug new zork3] ensure: [SampleDebug result: #ensured]")
        _ = try s.request("process.terminate", [("process", p)])
        try s.waitForResult("#ensured")
        #expect(!(try s.request("process.list").array ?? []).contains { $0["process"] == p })
        // A busy Process suspended, looked at, let go, terminated.
        let id = try s.eval("([[true] whileTrue: [SampleDebug result: 1]] forkAt: 0) id")["value"]?.string ?? ""
        let pid = JSONValue.int(Int64(id) ?? -1)
        try s.waitForResult("1")
        let mark = s.eventMark
        _ = try s.request("process.suspend", [("process", pid)])
        let e = try s.stopped(since: mark, process: pid)
        #expect(e["reason"] == .string("suspended"))
        _ = try s.request("process.proceed", [("process", pid)])
        _ = try s.request("process.terminate", [("process", pid)])
        for _ in 0..<3000 where (try s.request("process.list").array ?? []).contains(where: { $0["process"] == pid }) { usleep(10_000) }
        #expect(!(try s.request("process.list").array ?? []).contains { $0["process"] == pid })
    }
}

/// A connection that sends raw lines and reads replies one by one (events
/// skipped), each within 60 s.
final class RawConnection {
    let fd: Int32
    var buffer: [UInt8] = []

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = ProtocolServer.address(path)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard r == 0 else { throw ProtocolError("connect") }
    }

    deinit { close(fd) }

    func send(_ line: [UInt8]) throws {
        let b = line + [10]
        var off = 0
        while off < b.count {
            let n = b.withUnsafeBytes { write(fd, $0.baseAddress! + off, b.count - off) }
            guard n > 0 else { throw ProtocolError("write") }
            off += n
        }
    }

    func reply() throws -> JSONValue {
        let deadline = Date(timeIntervalSinceNow: 60)
        while true {
            if let i = buffer.firstIndex(of: 10) {
                let line = Array(buffer[..<i])
                buffer.removeFirst(i + 1)
                guard case .success(let v) = parseJSON(line) else { throw ProtocolError("not JSON: \(String(decoding: line, as: UTF8.self))") }
                if v["kind"]?.string == "reply" { return v }
                continue
            }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let left = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            guard left > 0, poll(&p, 1, left) > 0 else { throw ProtocolError("no reply within 60 s") }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { throw ProtocolError("closed") }
            buffer += chunk[0..<n]
        }
    }
}

/// Module 9b's measurements (`KAJO_MEASURE=1`, release build): the round
/// trips of protocol.describe, a compile and a step, and what stepping over
/// a send costs the stepped Process. Printed, not asserted on (AGENTS.md:
/// no wall-clock assertion).
@Suite(.serialized) struct ProtocolMeasureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KAJO_MEASURE"] != nil))
    func protocolLatencies() throws {
        let t = try RunningTarget()
        defer { t.close() }
        let s = try t.session()
        func p(_ xs: [Double], _ q: Double) -> Double { let v = xs.sorted(); return v[min(v.count - 1, Int(Double(v.count) * q))] }
        func timed(_ n: Int, _ body: () throws -> Void) rethrows -> [Double] {
            var out: [Double] = []
            for _ in 0..<n {
                let t0 = ShellVM.now()
                try body()
                out.append(Double(ShellVM.now() - t0) / 1e6)
            }
            return out
        }
        _ = try timed(20) { _ = try s.request("protocol.describe") }
        let describe = try timed(200) { _ = try s.request("protocol.describe") }
        var k = 0
        let compile = try timed(100) {
            k += 1
            _ = try s.request("method.compile", [("className", .string("SampleCounter")), ("source", .string("m\(k % 10)\n\t^ \(k) + count"))])
        }
        let evaluate = try timed(200) { _ = try s.eval("3 + 4") }
        let (pid, _) = try s.stopIn("SampleDebug result: (SampleDebug new stepped: 1)")
        _ = try s.request("process.step", [("process", pid), ("mode", .string("over")), ("frame", .int(2))])
        _ = try s.stopped(since: 0, process: pid)
        var steps: [Double] = []
        for _ in 0..<40 {
            let mark = s.eventMark
            let t0 = ShellVM.now()
            _ = try s.request("process.step", [("process", pid), ("mode", .string("into")), ("frame", .int(1))])
            let e = try s.stopped(since: mark, process: pid)
            steps.append(Double(ShellVM.now() - t0) / 1e6)
            if e["frames"]?.array?.first?["method"]?.string?.contains("DoIt") == true { break }
        }
        _ = try s.request("process.terminate", [("process", pid)])
        // Stepping over a send of n sends against running it unstepped.
        let n = 200_000
        let plain = try timed(3) { _ = try s.eval("SampleDebug new spin: \(n)") }
        var over: [Double] = []
        for _ in 0..<3 {
            let (q, _) = try s.stopIn("SampleDebug new spun: \(n)")
            let frames = try s.request("process.frames", [("process", q)]).array ?? []
            let f = (frames.firstIndex { $0["method"] == .string("SampleDebug>>spun:") } ?? 1) + 1
            let mark = s.eventMark
            let t0 = ShellVM.now()
            _ = try s.request("process.step", [("process", q), ("mode", .string("over")), ("frame", .int(Int64(f)))])
            _ = try s.stopped(since: mark, process: q)
            let mark2 = s.eventMark
            _ = try s.request("process.step", [("process", q), ("mode", .string("over")), ("frame", .int(1))])
            _ = try s.stopped(since: mark2, process: q)
            over.append(Double(ShellVM.now() - t0) / 1e6)
            _ = try s.request("process.terminate", [("process", q)])
        }
        let r = "describe_p50_ms=\(p(describe, 0.5)) describe_p99_ms=\(p(describe, 0.99)) compile_p50_ms=\(p(compile, 0.5)) compile_p99_ms=\(p(compile, 0.99)) evaluate_p50_ms=\(p(evaluate, 0.5)) evaluate_p99_ms=\(p(evaluate, 0.99)) step_n=\(steps.count) step_p50_ms=\(p(steps, 0.5)) step_p99_ms=\(p(steps, 0.99)) spin_sends=\(2 * n) plain_ms=\(plain.sorted()[1]) step_over_ms=\(over.sorted()[1])"
        print("PROTOCOL-MEASURE " + r)
        if let f = ProcessInfo.processInfo.environment["KAJO_MEASURE_OUT"] { try? (r + "\n").write(toFile: f, atomically: true, encoding: .utf8) }
    }
}
