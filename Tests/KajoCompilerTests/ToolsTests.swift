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

/// Types 2: the type checker's package.
let typesDirectory: String = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { url.deleteLastPathComponent() }
    return url.appendingPathComponent("types").path
}()

let toolsProbeDirectory: String = {
    var url = URL(fileURLWithPath: #filePath)
    url.deleteLastPathComponent()
    return url.appendingPathComponent("Fixtures/toolsprobe").path
}()

/// kernel/, tools/ and (since Types 2) types/: the development image.
let developmentImage: [UInt8] = {
    try! KernelBuild.build(KernelBuild.sources(in: [kernelDirectory, toolsDirectory, typesDirectory])).image
}()

/// The development image and the probe the shell tests drive it with.
let probedImage: [UInt8] = {
    try! KernelBuild.build(KernelBuild.sources(in: [kernelDirectory, toolsDirectory, typesDirectory, toolsProbeDirectory])).image
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
/// What the host side of a test's tools did, in milliseconds after the drop
/// (the failed sanitizer gate's part, docs/modules/review-3-small-fixes.md):
/// the timers the image arms and when the host fires them, connects, lost
/// connections and the first lines after a connect. Never an argument of a
/// connect (the token is the host's).
final class HostLog: @unchecked Sendable {
    private let lock = NSLock()
    private var t0: UInt64 = 0
    private var entries: [(UInt64, String)] = []
    private var linesSinceConnect = 0
    func drop() { lock.lock(); if t0 == 0 { t0 = ShellVM.now() }; lock.unlock() }
    func note(_ what: String, line: Bool = false) {
        let now = ShellVM.now()
        lock.lock()
        defer { lock.unlock() }
        guard entries.count < 400 else { return }
        if line { guard linesSinceConnect < 2 else { return }; linesSinceConnect += 1 }
        if what == "connect" { linesSinceConnect = 0 }
        entries.append((now, what))
    }
    /// The entries from 40 s before the drop on (every arm), each at its milliseconds from the drop.
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        guard t0 != 0 else { return "no drop" }
        return entries.filter { Int64($0.0) - Int64(t0) > -40_000_000_000 || $0.1.hasPrefix("arm") }
            .map { "\((Int64($0.0) - Int64(t0)) / 1_000_000) \($0.1)" }.joined(separator: "; ")
    }
}

final class LocalTools: @unchecked Sendable, CustomReflectable, CustomStringConvertible {
    // A failed expectation prints its operands: never the token.
    var customMirror: Mirror { Mirror(self, children: [:]) }
    var description: String { "LocalTools(\(path))" }

    let vm: ShellVM
    let server: ProtocolServer
    let host = ClientHost()
    let shell = ToolsShell()
    let path = socketNames.next()
    let hostLog = HostLog()
    /// The weekly margins (docs/modules/weekly-margins.md): the test that
    /// made these tools, the start of a margin's name (`tools.<test>.`),
    /// and the longest probe so far against the bound its drive used.
    let test: String
    private var longestProbeNs: UInt64 = 0

    /// `dropOn`: a Transcript line that makes the client transport drop
    /// every socket as a dead link would (module 9d's tests).
    init(image: [UInt8] = probedImage, dropOn: String? = nil, test: String = #function) throws {
        self.test = marginTest(test)
        let box = ServerBox()
        var c = shell.callbacks
        let h = host
        let log = hostLog
        c.events = { line in
            if let marker = dropOn, line.count < 200, String(decoding: line, as: UTF8.self).contains("\"text\":\"\(marker)\"") {
                log.drop()
                h.dropConnections()
            }
            box.server?.deliver(line)
        }
        let hc = host.callback
        c.client = { call in
            let r = hc(call)
            switch call.op {
            case "timer": log.note("arm \(call.arguments.first?.int ?? -1) ms token \(call.arguments.dropFirst().first?.int ?? -1)")
            case "connect": log.note("connect")
            default: break
            }
            return r
        }
        var o = Headless.Options()
        o.heapMiB = 512
        o.workers = 2
        vm = try ShellVM(image: image, options: o, callbacks: c)
        let v = vm
        host.setSink { e in
            switch e.kind {
            case .timer: log.note("fired token \(e.target)")
            case .lost: log.note("lost \(e.target)")
            case .line: log.note("line \(e.target)", line: true)
            default: break
            }
            v.post(e)
        }
        server = try ProtocolServer(path: path) { conn, json in v.postRequest(connection: conn, json: json) }
        box.server = server
        host.addTarget(ClientHost.Target(name: "local", path: path, token: server.token))
        vm.openProtocol()
        vm.start()
        let p = try #require(vm.spawn("start", receiver: "DevProtocol"))
        // Something that must come waits long everywhere (AGENTS.md): 30 s
        // ran out once under ThreadSanitizer in the full suite.
        #expect(drive(vm, seconds: 120) { vm.state(of: p) == .terminated })
        #expect(vm.result(of: p) == .bool(true))
        vm.release(p)
        server.start()
    }

    func close() {
        printMargins()
        host.closeAll()
        server.stop()
        vm.close()
    }

    /// The weekly margins, at the tools' end: the longest probe against its
    /// drive's bound, and the longest round trip per request kind of every
    /// client in the image (`ToolsProbe longestReplies`, read from the
    /// clients' latencies: from the send to the dispatch in the tools' event
    /// loop) against that client's request timeout, as `tools.roundtrip.<kind>`
    /// (one name per kind across the tools tests: the table keeps the largest).
    /// Nothing here is an issue: a probe that does not end prints nothing.
    func printMargins() {
        printMargin("tools.\(test).probe", .deadline, value: Double(longestProbeNs) / 1e9, bound: driveSeconds * driveScale)
        guard let p = vm.spawn("longestReplies", receiver: "ToolsProbe", arguments: [], main: true) else { return }
        defer { vm.release(p) }
        guard drive(vm, until: { vm.state(of: p) == .terminated }), vm.failure(of: p) == nil,
              let s = vm.result(of: p)?.string else { return }
        let f = s.split(separator: "\t", omittingEmptySubsequences: false)
        guard let timeoutMs = f.first.flatMap({ Double($0) }), timeoutMs > 0 else { return }
        for kv in f.dropFirst() {
            guard let eq = kv.lastIndex(of: "="), let ms = Double(kv[kv.index(after: eq)...]) else { continue }
            printMargin("tools.roundtrip.\(kv[..<eq])", .ceiling, value: ms, bound: timeoutMs, unit: "ms")
        }
    }

    /// Turns until `ToolsProbe selector` answers true, `seconds` at most
    /// (Types 3: a wait for the type checker, long everywhere).
    func until(_ selector: String, _ args: [ShellValue] = [], seconds: Double, explain: String) -> Bool {
        let t0 = ShellVM.now()
        let end = ShellVM.now() + UInt64(seconds * 1e9)
        // The weekly margins: the wait against its deadline, when it ends.
        func report() { printMargin(marginName(selector, args), .deadline, value: Double(ShellVM.now() &- t0) / 1e9, bound: seconds) }
        while ShellVM.now() < end {
            if (try? probe(selector, args)) == .bool(true) { report(); return true }
            for _ in 0..<20 { if vm.runTurn(budgetNs: 2_000_000).slices == 0 { usleep(500) } }
        }
        report()
        Issue.record("\(selector) never held: \((try? probe(explain))??.string ?? "?") stops \(standingStops)")
        return false
    }

    /// Every standing debugger stop with its frames (`ToolsProbe stops`),
    /// for a failure message: the tools test's fault (docs/modules/
    /// tools-test-fault.md) printed only "Process N stopped" and no frame.
    var standingStops: String {
        guard !readingStops.exchange(true, ordering: .relaxed) else { return "(a stops probe is running)" }
        defer { readingStops.store(false, ordering: .relaxed) }
        return (try? probe("stops"))??.string ?? "?"
    }
    private let readingStops = Atomic<Bool>(false)

    /// `ToolsProbe selector` on main, run to its end with turns here (the
    /// shell tests' `run`); a probe that does not end says why: the
    /// standing stops with their frames (the tools test's fault was a
    /// probe stopped at an error, docs/modules/tools-test-fault.md).
    func probe(_ selector: String, _ args: [ShellValue] = []) throws -> ShellValue? {
        let p = try #require(vm.spawn(selector, receiver: "ToolsProbe", arguments: args, main: true))
        defer { vm.release(p) }
        let t0 = ShellVM.now()
        defer { longestProbeNs = max(longestProbeNs, ShellVM.now() &- t0) }
        if !drive(vm, until: { vm.state(of: p) == .terminated }) {
            Issue.record("ToolsProbe \(selector) did not end: stops \(standingStops)")
        }
        if let f = vm.failure(of: p) { Issue.record("\(selector): \(f)") }
        return vm.result(of: p)
    }

    /// Turns until `ToolsProbe selector` answers true. The wait fails on a
    /// quiet stretch of 60 s: no request of the local client pending and
    /// no reply dispatched (`ToolsProbe activity`, read once a second), or
    /// after 300 s in all with a request pending (a hang). The weekly run's
    /// two failures (docs/modules/weekly-1123-failures.md): a 60 s clock on
    /// the whole step failed `definedInTag:` once under the sanitizer with
    /// the suite's load, where one probe took up to 17 s, a round trip 19 s,
    /// and the tools' event loop dispatches the replies it waits for as the
    /// CPU it gets allows; a pending request is ended by the client's own
    /// 30 s timeout. A failure line says why it ended, how long the wait
    /// was, how many probes ran and the longest, and each clause of the
    /// condition when the probe has a `...Why` companion (`why`), then the
    /// tools' state and stops.
    func until(_ selector: String, _ args: [ShellValue] = []) -> Bool {
        let t0 = ShellVM.now()
        let quietNs: UInt64 = 60_000_000_000, ceilingNs: UInt64 = 300_000_000_000
        var probes = 0
        var longest: UInt64 = 0
        var activity: Int64? = nil, lastChange = t0, nextRead = t0
        var reason = ""
        var longestQuiet: UInt64 = 0
        // The weekly margins: the longest quiet stretch against the quiet
        // bound and the whole wait against the ceiling, when the wait ends.
        func report() {
            let name = marginName(selector, args), n = ShellVM.now()
            printMargin(name + ".quiet", .quiet, value: Double(max(longestQuiet, n &- lastChange)) / 1e9, bound: Double(quietNs) / 1e9)
            printMargin(name + ".total", .deadline, value: Double(n &- t0) / 1e9, bound: Double(ceilingNs) / 1e9)
        }
        while true {
            let p0 = ShellVM.now()
            let held = (try? probe(selector, args)) == .bool(true)
            probes += 1
            longest = max(longest, ShellVM.now() &- p0)
            if held { report(); return true }
            for _ in 0..<20 { if vm.runTurn(budgetNs: 2_000_000).slices == 0 { usleep(500) } }
            let n = ShellVM.now()
            if n >= nextRead {
                nextRead = n + 1_000_000_000
                let a = (try? probe("activity"))??.int ?? -1
                // Replies dispatched times 1000 plus requests pending: a
                // change, or a request pending, is the tools doing something.
                if a != activity || (a > 0 && a % 1000 > 0) { lastChange = n }
                activity = a
            }
            longestQuiet = max(longestQuiet, n &- lastChange)
            if n &- lastChange > quietNs { reason = "quiet"; break }
            if n &- t0 > ceilingNs { reason = "ceiling"; break }
        }
        report()
        let waited = String(format: "%.1f", Double(ShellVM.now() &- t0) / 1e9)
        let clauses: String = why(selector, args)
        let state: String = (try? probe("state"))??.string ?? "?"
        let longestS = String(format: "%.1f", Double(longest) / 1e9)
        Issue.record("\(selector) never held (\(reason), activity \(activity.map { "\($0)" } ?? "-")): waited \(waited) s, \(probes) probes, longest \(longestS) s; why \(clauses); \(state) stops \(standingStops)")
        return false
    }

    /// A margin's name for an until: the test, the probe's selector and its
    /// arguments (`tools.<test>.definedInTag:Probes`).
    func marginName(_ selector: String, _ args: [ShellValue]) -> String {
        let a = args.map { v -> String in
            if let s = v.string { return s }
            if let i = v.int { return String(i) }
            return "\(v)"
        }.joined(separator: ",")
        return "tools.\(test).\(selector)\(a)"
    }

    /// Each clause of `ToolsProbe selector`, from its companion probe
    /// (`definedInTag:` has `definedInTagWhy:`, `ready` has `readyWhy`),
    /// or "none" when it has none.
    func why(_ selector: String, _ args: [ShellValue]) -> String {
        let w = selector.hasSuffix(":") ? String(selector.dropLast()) + "Why:" : selector + "Why"
        guard (try? probe("explains:", [.string(w)])) == .bool(true) else { return "none" }
        return (try? probe(w, args))??.string ?? "?"
    }
}

@Suite(.serialized) struct ToolsTests {
    @Test func theDevelopmentImageBuildsAndTheToolsTestsPass() throws {
        let r = try KernelBuild.build(KernelBuild.sources(in: [kernelDirectory, toolsDirectory, typesDirectory]))
        #expect(r.warnings.isEmpty, "\(r.warnings)")
        let classes = try tonelFiles(in: toolsDirectory).filter { $0.hasSuffix("Test.class.st") }
        #expect(classes.count >= 7)
        var total = 0
        for c in classes.sorted() {
            let name = String((c as NSString).lastPathComponent.dropLast(".class.st".count))
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
        for d in ["kernel", "tools", "types"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        _ = try runSmalltalk(image, "writePackages:", ["Kernel", "kernel", "Tools", "tools", "Types", "types"], sources: dir.path)
        for (package, source) in [("kernel", kernelDirectory), ("tools", toolsDirectory), ("types", typesDirectory)] {
            let want = try tonelFiles(in: source)
            let got = try tonelFiles(in: dir.path + "/" + package)
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
        let conn = try #require(host.callback(ViewCall(op: "connect", handle: 0, arguments: [.string(path), .string("developer"), .nil]))?.int)
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
        let c2 = try #require(host.callback(ViewCall(op: "connect", handle: 0, arguments: [.string(path + "x"), .string("developer"), .nil]))?.int)
        while ShellVM.now() < end && !events.withLock({ $0.contains { $0.kind == .lost && $0.target == Int(c2) } }) { usleep(2000) }
        #expect(events.withLock { $0.last?.value.string?.contains("no token") == true })
        host.closeAll()
    }

    @Test func aRequestLongerThanOneHeapBlockReachesTheImage() throws {
        let t = try LocalTools()
        defer { t.close() }
        let c = try ProtocolClient(path: t.path)
        defer { c.close() }
        let token = t.server.token
        try c.open(token: token, client: "developer", timeout: 60, margin: #function)
        // Module 10: 9c refused a request over one heap block; the image
        // now takes it as one String (a large object).
        let long = "^ '" + String(repeating: "x", count: 40_000) + "' byteSize"
        let r = try c.send("evaluate", [("source", .string(long))], timeout: 60, margin: #function)
        #expect(r["ok"] == .bool(true))
        #expect(r["result"]?["value"] == .string("40000"), "\(r)")
        // Past the line limit a request is still refused with a reply.
        #expect(RequestLimits.imageBytes == (1 << 24) - 1)
        // A reply longer than one heap block comes back whole (written in
        // pieces in the target, joined by its transport).
        let methods = try c.request("package.selectors", [("name", .string("Kernel"))], timeout: 60, margin: #function)
        #expect((methods.array?.count ?? 0) > 2000)
        #expect(writeJSON(methods).count > 32 * 1024)
    }

    @Test func theToolsDevelopTheImageTheyRunIn() throws {
        let t = try LocalTools()
        defer { t.close() }
        let project = try temporaryDirectory("tools-project")
        defer { try? FileManager.default.removeItem(at: project) }
        // The project directory is the host's (2026-11-11): set before the
        // tools open, never named by the image.
        _ = try t.host.setProject(project.path, for: "local").get()
        #expect(try t.probe("open:", [.string(t.path)]) == .bool(true))
        #expect(t.until("ready"))
        // A browser compiles a method into the running image through the
        // protocol; its file is written into the project directory.
        #expect(try t.probe("compileThroughTheBrowser") == .bool(true))
        // The method is installed before the reply leaves the target: wait
        // for the reply, after which the file is written.
        #expect(t.until("compiledThroughTheBrowser"))
        let file = project.appendingPathComponent("ToolsProbe.extension.st").path
        #expect((try? String(contentsOfFile: file, encoding: .utf8))?.contains("probeAnswer") == true)
        // Types 1: a method with types in its pattern, accepted in the
        // browser's source pane, is compiled, kept with its types, shown
        // with them, and its file holds the typed pattern.
        // KAJO_TOOLS_HOLD_INSTALL=<ms>, by hand: the typed method's install
        // waits that long before its source is recorded (the fault forced,
        // docs/modules/tools-test-fault.md).
        if let ms = ProcessInfo.processInfo.environment["KAJO_TOOLS_HOLD_INSTALL"].flatMap({ Int64($0) }) {
            #expect(try t.probe("holdInstalls:", [.int(ms)]) == .bool(true))
        }
        #expect(try t.probe("compileTypedThroughTheBrowser") == .bool(true))
        #expect(t.until("compiledTypedThroughTheBrowser"))
        #expect((try? String(contentsOfFile: file, encoding: .utf8))?.contains("ToolsProbe >> probeTyped: x <Integer> ^<Integer> [") == true)
        #expect(((try t.probe("latencyCount"))?.int ?? 0) >= 4)
        #expect(t.shell.count("call.setTree") >= 1)
        #expect(t.shell.count("call.setStyles") >= 1)
    }

    /// Types 3: the browser on a real target (the image it runs in, no
    /// fake) marks a method's type diagnostic and says its text, and after
    /// the method is fixed and accepted holds none, the checker's event
    /// having named it. The waits are on the browser's own state, long
    /// everywhere (`typesWait`). The checker starts without its whole check
    /// (the probe says why); the first request's time is measured apart.
    @Test func theBrowserMarksADiagnosticAndFollowsTheFix() throws {
        let t0 = Date()
        let t = try LocalTools()
        defer { t.close() }
        let project = try temporaryDirectory("types-project")
        defer { try? FileManager.default.removeItem(at: project) }
        _ = try t.host.setProject(project.path, for: "local").get()
        #expect(try t.probe("startTypesWithoutTheWholeCheck") == .bool(true))
        #expect(try t.probe("open:", [.string(t.path)]) == .bool(true))
        #expect(t.until("ready"))
        #expect(try t.probe("defineTypesProbe") == .bool(true))
        #expect(t.until("typesProbeDefined", seconds: typesWait, explain: "typesState"))
        #expect(try t.probe("compileTypesProbe:", [.string("answer ^<String>\n\t^ 3")]) == .bool(true))
        #expect(t.until("typesProbeShows:", [.int(1)], seconds: typesWait, explain: "typesState"))
        #expect(try t.probe("markTypesEvents") == .bool(true))
        #expect(try t.probe("compileTypesProbe:", [.string("answer ^<String>\n\t^ 'three'")]) == .bool(true))
        #expect(t.until("typesProbeShows:", [.int(0)], seconds: typesWait, explain: "typesState"))
        // The event that named the fixed method came (two publications: its
        // own wait, after the browser's).
        #expect(t.until("typesEventCame", seconds: typesWait, explain: "typesState"))
        print("types-tools body_s=\(String(format: "%.1f", Date().timeIntervalSince(t0)))")
    }

    /// Tags as subdirectories, from the tools: a class defined in the
    /// browser into a new tag has its file in the project's `<Tag>/`; a
    /// definition with another tag moves the file (the old one and its
    /// emptied directory gone); removing the class removes the file. With
    /// the project a copy of tools/, the copy is tools/ again afterwards.
    /// KAJO_TOOLSRUN_OUT names a directory the listings are written to.
    ///
    /// Each step prints its own time (`tools-tags <step> s= t=`, the step's
    /// and the body's so far): the weekly run of 2026-11-23 failed it at
    /// 378.8 s under the sanitizer with load, against 37 to 68 s in every
    /// recorded pass, and said nothing of where the time went.
    @Test func aClassDefinedIntoATagFromTheBrowserMovesWithItsTag() throws {
        let t0 = ShellVM.now()
        var last = t0
        func step(_ name: String) {
            let n = ShellVM.now()
            print("tools-tags \(name) s=\(String(format: "%.1f", Double(n &- last) / 1e9)) t=\(String(format: "%.1f", Double(n &- t0) / 1e9))")
            last = n
        }
        let t = try LocalTools()
        defer { t.close() }
        step("started")
        let project = try temporaryDirectory("tools-tags")
        defer { try? FileManager.default.removeItem(at: project) }
        try FileManager.default.removeItem(at: project)
        try FileManager.default.copyItem(atPath: toolsDirectory, toPath: project.path)
        let out = ProcessInfo.processInfo.environment["KAJO_TOOLSRUN_OUT"]
        func listing(_ step: String) throws -> [String] {
            let files = try tonelFiles(in: project.path)
            if let out { try (files.joined(separator: "\n") + "\n").write(toFile: out + "/" + step + ".txt", atomically: true, encoding: .utf8) }
            return files
        }
        let before = try listing("0-before")
        // The project directory is the host's (2026-11-11): set before the
        // tools open, never named by the image.
        _ = try t.host.setProject(project.path, for: "local").get()
        step("copied")
        #expect(try t.probe("open:", [.string(t.path)]) == .bool(true))
        step("open")
        #expect(t.until("ready"))
        step("ready")
        // KAJO_TOOLS_HOLD_LOOP=<ms>, by hand: the first define's reply is
        // dispatched that much later, the event loop held by the reply
        // before it (the weekly run's failure forced, docs/modules/
        // weekly-1123-failures.md).
        if let ms = ProcessInfo.processInfo.environment["KAJO_TOOLS_HOLD_LOOP"].flatMap({ Int64($0) }) {
            #expect(try t.probe("holdLoop:", [.int(ms)]) == .bool(true))
        }
        #expect(try t.probe("defineInTag:", [.string("Probes")]) == .bool(true))
        step("defineInTag-Probes")
        #expect(t.until("definedInTag:", [.string("Probes")]))
        step("definedInTag-Probes")
        let defined = try listing("1-defined-in-Probes")
        #expect(defined == (before + ["Probes/ToolsTagProbe.class.st"]).sorted())
        let text = try String(contentsOf: project.appendingPathComponent("Probes/ToolsTagProbe.class.st"), encoding: .utf8)
        #expect(text.hasPrefix("Class {\n\t#name : #ToolsTagProbe,\n\t#superclass : #Object,\n\t#instVars : [\n\t\t'a'\n\t]\n}\n"), "\(text)")
        #expect(try t.probe("defineInTag:", [.string("Moved")]) == .bool(true))
        step("defineInTag-Moved")
        #expect(t.until("definedInTag:", [.string("Moved")]))
        step("definedInTag-Moved")
        let moved = try listing("2-moved-to-Moved")
        #expect(moved == (before + ["Moved/ToolsTagProbe.class.st"]).sorted())
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("Probes").path))
        #expect(try t.probe("removeTagProbe") == .bool(true))
        step("removeTagProbe")
        #expect(t.until("tagProbeRemoved"))
        step("tagProbeRemoved")
        let after = try listing("3-removed")
        #expect(after == before)
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("Moved").path))
        for f in after {
            #expect(FileManager.default.contents(atPath: project.path + "/" + f) == FileManager.default.contents(atPath: toolsDirectory + "/" + f), "\(f)")
        }
        step("end")
        print("tools-tags replies \((try? t.probe("repliesNow"))??.string ?? "?")")
    }

    @Test func anErrorInAToolStopsOnlyItsProcessAndTheToolsGoOn() throws {
        let t = try LocalTools()
        defer { t.close() }
        let project = try temporaryDirectory("tools-debug")
        defer { try? FileManager.default.removeItem(at: project) }
        // The project directory is the host's (2026-11-11): set before the
        // tools open, never named by the image.
        _ = try t.host.setProject(project.path, for: "local").get()
        #expect(try t.probe("open:", [.string(t.path)]) == .bool(true))
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
        printMargin("tools.\(t.test).results42", .deadline, value: Double(Int64(ShellVM.now()) - Int64(end) + 60_000_000_000) / 1e9, bound: 60)
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
