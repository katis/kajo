import Darwin
import Dispatch
import Foundation
import KajoDev
import KajoApp
import KajoAppDevelopment
import KajoVM

// Module 9c (docs/modules/developer-ui.md): the developer UI in the macOS
// shell. `mode=dev` opens the tools on a development image that serves its
// own protocol (the local target); `mode=devsession` runs the scripted
// session or the typing measurement on the display and prints one result
// line. Both are binding code: the tools are the image's (`DevTools`,
// `DevSessionBench`), the shell owns the sockets, the display link and the
// key events it synthesizes for the measurement.

/// The socket a development image serves on (the temporary directory: the
/// path must fit `sun_path`).
func devSocketPath(_ options: LaunchOptions) -> String {
    options.string("protocol", FileManager.default.temporaryDirectory.appendingPathComponent("kajo-dev-\(getpid()).sock").path)
}

/// `mode=dev [image=path] [protocol=socket] [project=dir] [workers=N]
/// [heap=MiB]`: the development image (the bundled `dev.img` by default)
/// serving the protocol, and its tools opened on it: Kajo develops Kajo.
/// With `project=`, the files of every change the tools make to the local
/// target are written there (`just tools` passes the repository's
/// `tools/`). Runs until the app quits.
@MainActor public final class DevMode {
    let options: LaunchOptions
    let platform: ShellPlatform
    var runtime: ShellRuntime?
    var server: ProtocolServer?

    let pairing: PairingPresenter?

    public init(_ options: LaunchOptions, platform: ShellPlatform, pairing: PairingPresenter? = nil) {
        self.pairing = pairing
        self.options = options
        self.platform = platform
    }

    public func start(resources: ShellResources = .main) {
        var o = Headless.Options()
        o.workers = options.int("workers", 2)
        o.heapMiB = options.int("heap", 512)
        // The developer UI serves its own protocol: errors stop for the
        // debugger from before the image resumes (the development answers).
        o.stopsForDebugger = true
        // The developer UI runs for days: the collectors' logs keep the last
        // records only (their sums cover the whole run).
        o.logCapacity = options.int("logs", Headless.Options.appLogCapacity)
        do {
            let rt = try makeShellRuntime(imagePath: options.string("image", resources.devImage), options: o, platform: platform,
                                       events: devTranscriptSink(), pairing: pairing)
            runtime = rt
            rt.clientHost?.readTargetsFile()
            rt.start()
            rt.ticking = false
            guard let s = try rt.serveProtocol(socket: devSocketPath(options)) else {
                platform.showStatus("dev: the image serves no protocol (a release image?)")
                return
            }
            server = s
            var args: [ShellValue] = [.string(s.path)]
            args.append(options["project"].map { .string($0) } ?? .nil)
            guard let p = rt.vm.spawn("openLocal:project:", receiver: "DevTools", arguments: args, main: true, priority: 2) else {
                platform.showStatus("dev: the image has no DevTools (build it with --with tools)")
                return
            }
            let end = ShellVM.now() + 10_000_000_000
            while rt.vm.state(of: p) != .terminated && ShellVM.now() < end { rt.turn(.wake) }
            rt.vm.release(p)
            platform.showStatus("dev: protocol \(s.path) token \(s.token)")
            Output.shared.emit(resultLine("dev", options, "opened=1 protocol=\(s.path)"))
        } catch {
            platform.showStatus("dev: \(error)")
        }
    }
}

/// Transcript lines to the results (the console) as they come.
nonisolated func devTranscriptSink() -> @Sendable ([UInt8]) -> Void {
    { bytes in
        guard let o = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
              o["kind"] as? String == "transcript", let t = o["text"] as? String else { return }
        Output.shared.emit("transcript: " + t)
    }
}

/// `mode=devsession [classes=2000|0] [load=storm|none] [typing=N] [rate=20]
/// [workers=N] [timeout=180]`: the scripted session (`DevSessionBench
/// start:package:`) on the development image with 2000 classes (classes=0:
/// the plain one), or with `typing=N` the typing measurement: N keys typed
/// into a browser's source pane at `rate` per second, each timed from the
/// key event to the first time the text view draws after the image coloured
/// the change. With `load=storm` the image runs 9a's storm scenario on its
/// background workers meanwhile. The frames are the display link's across
/// the whole session; one result line at the end.
///
/// The discoverability follow-up: `session=instances` (local target only)
/// runs `DevSessionBench startInstances:` instead of the session.
///
/// Module 9d: `target=<name|address> [targets=<file>] [project=<dir>]
/// [package=Kernel]` runs the session against another target (the phone)
/// instead of the image's own socket: the client transport reads the
/// targets file (the token stays in it) and browses Bonjour; the image
/// does not serve. The session's dropped link is the shell's: the bench's
/// transcript line `devsession: drop` closes every client socket as a
/// link that died would.
@MainActor public final class DevSessionMode {
    let options: LaunchOptions
    let platform: ShellPlatform
    var runtime: ShellRuntime!
    var server: ProtocolServer?
    let typing: Int
    let rate: Int
    let load: String
    let target: String?
    let hostBox = HostBox()
    var frameTimes: [Double] = []
    var startTs = 0.0
    var finished = false
    var maxTurnNs: UInt64 = 0
    var maxTurn: ShellTurn?
    var longTurns = 0
    var turns = 0
    var preempted = 0
    var viewCalls = 0
    var viewNs: [String: (n: Int, total: UInt64, max: UInt64)] = [:]

    // typing
    var typeHandle = 0
    var typed = 0
    var typeTimer: DispatchSourceTimer?
    var pending: [(t0: UInt64, coloured: Bool)] = []
    var typingLatencies: [Double] = []
    var colourLatencies: [Double] = []
    var typingStart = 0.0
    var typingEnd = 0.0

    let pairing: PairingPresenter?

    public init(_ options: LaunchOptions, platform: ShellPlatform, pairing: PairingPresenter? = nil) {
        self.pairing = pairing
        self.options = options
        self.platform = platform
        typing = options.int("typing", 0)
        rate = max(1, options.int("rate", 20))
        load = options.string("load", "none")
        target = options["target"]
    }

    public func start(resources: ShellResources = .main) {
        var o = Headless.Options()
        o.workers = options.int("workers", 5)
        o.heapMiB = options.int("heap", 1024)
        // A developer's session (the development answers: a host a
        // debugger can come to).
        o.stopsForDebugger = true
        o.nurseryKB = options.int("nursery", 4096)
        let classes = options.int("classes", 2000)
        let image = options.string("image", classes > 0 ? resources.dev2000Image : resources.devImage)
        do {
            runtime = try makeShellRuntime(imagePath: image, options: o, platform: platform, events: sessionSink(), pairing: pairing)
        } catch {
            Output.shared.emit(resultLine("devsession", options, "FAILED=1 error=\("\(error)".replacingOccurrences(of: " ", with: "_"))"))
            finish(2)
        }
        runtime.start()
        if let h = runtime.clientHost { hostBox.set(h) }
        if target == nil {
            do { server = try runtime.serveProtocol(socket: devSocketPath(options)) } catch {}
            guard server != nil else {
                Output.shared.emit(resultLine("devsession", options, "FAILED=1 error=protocol"))
                finish(2)
            }
        } else {
            runtime.clientHost?.readTargetsFile(options.string("targets", NSHomeDirectory() + "/.kajo/targets"))
            runtime.clientHost?.startBrowsing()
        }
        runtime.onTurn = { [unowned self] t, _ in
            self.turns += 1
            if t.preempted { self.preempted += 1 }
            if t.ns > self.maxTurnNs { self.maxTurnNs = t.ns; self.maxTurn = t }
            if t.ns > 8_333_333 { self.longTurns += 1 }
        }
        runtime.onView = { [unowned self] c in self.noteView(c) }
        runtime.onViewDone = { [unowned self] c, ns in
            let key = c.op == "call" ? (c.arguments.first?.string ?? "call") : c.op == "create" ? "create." + (c.arguments.first?.string ?? "") : c.op
            var v = self.viewNs[key] ?? (0, 0, 0)
            v.n += 1
            v.total &+= ns
            v.max = max(v.max, ns)
            self.viewNs[key] = v
        }
        platform.textDrawn = { [unowned self] h in self.drawn(h) }
        if load != "none", let l = runtime.vm.spawn("startLoad:workers:", receiver: "ShellBench", arguments: [.string(load), .int(Int64(o.workers))]) {
            runtime.vm.waitUntilTerminated(l)
            runtime.vm.release(l)
        }
        runtime.ticking = true
        startTs = Double(ShellVM.now()) / 1e9
        platform.startDisplayLink { [unowned self] ts, _ in
            if !self.finished && ts >= self.startTs { self.frameTimes.append(ts) }
            self.runtime.tick(timestamp: ts)
        }
        var selector = typing > 0 ? "startTyping:" : "start:package:"
        var args: [ShellValue] = [.string(server?.path ?? "")]
        if typing == 0 { args.append(.string(classes > 0 ? "Generated" : "Tools")) }
        // The discoverability follow-up: `session=instances` on the local
        // target, the bar's instance checks and a Workspace evaluating
        // `String allInstances: 100000` ten times, each a step whose frames
        // are counted (`steps_ms_missed`).
        if target == nil && typing == 0 && options["session"] == "instances" {
            selector = "startInstances:"
            args = [.string(server?.path ?? "")]
        }
        if let target {
            selector = "startRemote:package:project:"
            args = [.string(target), .string(options.string("package", "Kernel")), options["project"].map { .string($0) } ?? .nil]
            // Module 11a: `session=app`: the tools against a running app,
            // one method of its class changed (its source read from the
            // file `source=`) and `probe=` evaluated until it answers
            // `expect=`.
            if options["session"] == "app" {
                let source = options["source"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
                selector = "startApp:package:class:selector:source:probe:expect:project:"
                args = [.string(target), .string(options.string("package", "Sample")), .string(options.string("appclass", "SampleApp")),
                        .string(options.string("selector", "pressed")), .string(source), .string(options.string("probe", "")),
                        .string(options.string("expect", "")), options["project"].map { .string($0) } ?? .nil]
            }
        }
        guard let p = runtime.vm.spawn(selector, receiver: "DevSessionBench", arguments: args, main: true, priority: 2) else {
            Output.shared.emit(resultLine("devsession", options, "FAILED=1 error=spawn"))
            finish(2)
        }
        runtime.vm.release(p)
        platform.showStatus("devsession \(options.summary) protocol \(server?.path ?? target ?? "-")")
        let timeout = options.double("timeout", 180)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { MainActor.assumeIsolated { self.end(nil, "timeout") } }
    }

    /// The bench's transcript lines: `devsession: type <handle>` starts the
    /// typing, `devsession: done <json>` ends the session.
    nonisolated func sessionSink() -> @Sendable ([UInt8]) -> Void {
        { bytes in
            guard let o = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
                  o["kind"] as? String == "transcript", let t = o["text"] as? String else { return }
            Output.shared.emit("transcript: " + t)
            if t == "devsession: drop" {
                // The dropped link: every client socket ends now, before
                // the bench's next request (this runs inside its turn).
                self.hostBox.get()?.dropConnections()
            } else if t.hasPrefix("devsession: type ") {
                let h = Int(t.dropFirst("devsession: type ".count).trimmingCharacters(in: .whitespaces)) ?? 0
                DispatchQueue.main.async { MainActor.assumeIsolated { self.startTyping(h) } }
            } else if t.hasPrefix("devsession: done ") {
                let json = String(t.dropFirst("devsession: done ".count))
                DispatchQueue.main.async { MainActor.assumeIsolated { self.end(json, nil) } }
            }
        }
    }

    func noteView(_ c: ViewCall) {
        viewCalls += 1
        guard c.handle == typeHandle, typeHandle != 0, c.op == "call", c.arguments.first == .string("setStyles") else { return }
        let now = ShellVM.now()
        for i in pending.indices where !pending[i].coloured {
            pending[i].coloured = true
            colourLatencies.append(Double(now &- pending[i].t0) / 1e6)
        }
    }

    func drawn(_ h: Int) {
        guard h == typeHandle, !pending.isEmpty else { return }
        let now = ShellVM.now()
        // Every key whose change the image coloured is on the screen with
        // this draw; one not coloured yet waits for a later one.
        var left: [(t0: UInt64, coloured: Bool)] = []
        for p in pending {
            if p.coloured { typingLatencies.append(Double(now &- p.t0) / 1e6) } else { left.append(p) }
        }
        pending = left
    }

    func startTyping(_ h: Int) {
        guard typeHandle == 0 else { return }
        typeHandle = h
        typingStart = Double(ShellVM.now()) / 1e9
        let keys = Array("abc ")
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        t.schedule(deadline: .now() + 0.5, repeating: .nanoseconds(1_000_000_000 / rate), leeway: .nanoseconds(0))
        t.setEventHandler { [unowned self] in
            MainActor.assumeIsolated {
                if self.typed >= self.typing {
                    self.typeTimer?.cancel()
                    self.typingEnd = Double(ShellVM.now()) / 1e9
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { self.end(nil, nil) } }
                    return
                }
                let t0 = ShellVM.now()
                self.pending.append((t0, false))
                if !self.platform.typeKey(self.typeHandle, String(keys[self.typed % keys.count])) { self.pending.removeLast() }
                self.typed += 1
            }
        }
        t.resume()
        typeTimer = t
    }

    func end(_ json: String?, _ failure: String?) {
        if finished { return }
        finished = true
        let endTs = Double(ShellVM.now()) / 1e9
        platform.stopDisplayLink()
        typeTimer?.cancel()
        let nominal = Double(platform.maximumFramesPerSecond)
        let fa = FrameAccount(timestamps: frameTimes.filter { $0 <= endTs }, start: startTs, end: endTs, nominalHz: nominal)
        var line = "target=\(target == nil ? "local" : "remote") classes=\(options.int("classes", 2000)) load=\(load) workers=\(options.int("workers", 5)) typing=\(typing)"
        line += " seconds=\(f3(endTs - startTs)) nominal_hz=\(f2(nominal)) frames=\(fa.frames) expected=\(fa.expected) missed=\(fa.missed) drops=\(fa.drops)"
        line += " gap_p99_ms=\(f3(fa.gapP99Ms)) gap_max_ms=\(f3(fa.gapMaxMs)) turns=\(turns) preempted_turns=\(preempted) max_turn_ms=\(f3(Double(maxTurnNs) / 1e6)) view_calls=\(viewCalls)"
        // The longest turn: what stopped it from ending at its budget.
        if let t = maxTurn {
            func ms(_ ns: UInt64) -> String { f1(Double(ns) / 1e6) }
            line += " long_turns=\(longTurns) max_turn_cpu_ms=\(ms(t.cpuNs)) max_turn_park_ms=\(ms(t.parkNs)) max_turn_stop_ms=\(ms(t.stopNs)) max_turn_young_ms=\(ms(t.youngNs)) max_turn_collector_ms=\(ms(t.collectorNs)) max_turn_wait_ms=\(ms(t.enterWaitNs &+ t.leaveWaitNs)) max_turn_slices=\(t.slices)"
        }
        if typing > 0 {
            if typingEnd > typingStart {
                let tw = FrameAccount(timestamps: frameTimes.filter { $0 >= typingStart && $0 <= typingEnd }, start: typingStart, end: typingEnd, nominalHz: nominal)
                line += " typing_frames=\(tw.frames) typing_missed=\(tw.missed)"
            }
            line += " typed=\(typed) type_n=\(typingLatencies.count) type_p50_ms=\(f3(percentile(typingLatencies, 0.5))) type_p99_ms=\(f3(percentile(typingLatencies, 0.99))) type_max_ms=\(f3(typingLatencies.max() ?? 0))"
            line += " colour_p50_ms=\(f3(percentile(colourLatencies, 0.5))) colour_p99_ms=\(f3(percentile(colourLatencies, 0.99)))"
        }
        // The slowest view ops (AppKit's time inside the hop): op:count:total_ms:max_ms.
        let slow = viewNs.sorted { $0.value.max > $1.value.max }.prefix(8)
        line += " view_slowest=" + slow.map { "\($0.key):\($0.value.n):\(f1(Double($0.value.total) / 1e6)):\(f1(Double($0.value.max) / 1e6))" }.joined(separator: ",")
        let total = viewNs.values.reduce(UInt64(0)) { $0 &+ $1.total }
        line += " view_total_ms=\(f1(Double(total) / 1e6))"
        if let failure { line += " FAILED=1 error=\(failure)" }
        if let json {
            // Each step's frames missed: its start is on the image's clock
            // (`Smalltalk microsecondClock`, the uptime clock the display
            // link's timestamps count too).
            if let d = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], let steps = d["steps"] as? [[Any]] {
                var parts: [String] = []
                for st in steps where st.count >= 3 {
                    guard let name = st[0] as? String, let us = (st[1] as? NSNumber)?.doubleValue, let at = (st[2] as? NSNumber)?.doubleValue else { continue }
                    let a = at / 1e6, b = a + us / 1e6
                    let w = FrameAccount(timestamps: frameTimes.filter { $0 >= a && $0 <= b }, start: a, end: b, nominalHz: nominal)
                    parts.append("\(name):\(f1(us / 1000)):\(w.missed)")
                }
                line += " steps_ms_missed=" + parts.joined(separator: ",")
            }
            line += " session=" + json.replacingOccurrences(of: " ", with: "_")
        }
        runtime.stopProtocol()
        Output.shared.emit(resultLine("devsession", options, line))
        finish(failure == nil ? 0 : 2)
    }
}

/// The client transport, for a sink built before the runtime (module 9d).
final class HostBox: @unchecked Sendable {
    private let lock = NSLock()
    private var host: ClientHost?
    func set(_ h: ClientHost) {
        lock.lock()
        host = h
        lock.unlock()
    }
    func get() -> ClientHost? {
        lock.lock()
        defer { lock.unlock() }
        return host
    }
}
