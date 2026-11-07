import Darwin
import Dispatch
import Foundation
import KajoDev
import KajoApp
import KajoAppDevelopment
import KajoVM

/// `mode=scenario scenario=storm|ring|share|large|photo|idle gc=cm|stw young=stw|local|offload
/// workers=N seconds=10 warmup=1 events=0|1000 hog=0|1 budget=on|off`:
/// module 7's scenarios driven by the real display link. The window is
/// built in Smalltalk (ShellBench), a probe view is moved by Smalltalk on
/// every frame event (so ProMotion does not throttle) after module 7's
/// main-thread load (`mainTick:work:`), synthetic events set a label in
/// Smalltalk and their latency is taken at the view call, a hog loops on
/// main. One result line at the end, then the app exits.
///
/// Module 9b: `debugstop=1` (with `protocol=<socket>`, default in the
/// temporary directory) serves the development protocol, and a client on a
/// thread of its own stops the event loop's Process (main-affine) for the
/// debugger for the whole window, asking the target to evaluate `3 + 4`
/// every 50 ms meanwhile; then lets it go on and checks it handles the
/// events that queued. The frames are the window's, the event loop stopped.
///
/// The development answers: `debugstop=noclient` runs the window with the
/// host's setting on (an unhandled error stops its Process for a debugger
/// that can still come) and no protocol: at the window's start a frame
/// handler fails once, the event loop hands itself over and the old loop's
/// Process stands stopped with nobody connected (`stops=N` forks N more
/// background Processes that die the same way, up to `Debugger stopCap`);
/// after `seconds` the shell starts serving on loopback, a client on a
/// thread of its own finds the stops in session.open's answer, reads the
/// loop's frames and lets it go on, and the frames are counted for `after`
/// seconds more. The result line has both windows' frames, the stops and
/// the footprint they hold.
///
/// Module 9d: `protocol=tcp[:port]` (and `mode=serve`, which defaults to it
/// and to `scenario=idle`) serves the development protocol over TCP with
/// Bonjour and the pairing screen while the scenario runs; whoever connects
/// (the Mac's tools) makes requests meanwhile, and the result line counts
/// what the server did in the window.
@MainActor public final class ScenarioMode {
    let options: LaunchOptions
    let platform: ShellPlatform
    var runtime: ShellRuntime!
    var vm: ShellVM { runtime.vm }

    let name: String
    let seconds: Double
    let warmup: Double
    let eventRate: Int
    let hog: Bool
    let budgetOff: Bool
    let debugStop: Bool
    let noClient: Bool
    let afterSeconds: Double
    let stopsAsked: Int
    let noClientResult = NoClientBox()
    var noClientServer: ProtocolServer?
    var serveAtTs = 0.0
    var footprintBefore: UInt64 = 0
    var footprintStopped: UInt64 = 0
    var loopBefore: Int64 = 0
    let servePort: Int?
    var protocolServer: ProtocolServer?
    var tcpServer: ProtocolServer?
    var servedBase = ServerStats.Values()
    let debugResult = DebugStopBox()

    // frames (seconds, uptime clock)
    var frameTimes: [Double] = []
    var callbackLate: [Double] = []
    var measureStart = 0.0
    var measureEnd = 0.0
    var measuring = false
    var finished = false

    // turns in the window
    var turns = 0, slices = 0, preempted = 0
    var vmNs: UInt64 = 0, parkNs: UInt64 = 0, stopNs: UInt64 = 0, waitNs: UInt64 = 0, collectorNs: UInt64 = 0
    var youngNs: UInt64 = 0, cpuNs: UInt64 = 0
    var maxTurnNs: UInt64 = 0, maxTurnKind = "-"
    /// The final mark on the devices: the longest turn's park, enter and
    /// leave waits and young-collection time, and the longest of each in
    /// any one turn.
    var maxTurnParts = (park: UInt64(0), wait: UInt64(0), young: UInt64(0))
    var maxParkNs: UInt64 = 0, maxWaitNs: UInt64 = 0

    // events
    var eventTimer: DispatchSourceTimer?
    var eventsPosted = 0
    var eventsStartNs: UInt64 = 0
    var stamps: [UInt64] = []
    /// When the timer's handler posted each event (the uptime clock).
    var posted: [UInt64] = []
    var latencies: [Double] = []
    /// Each measured event's due stamp, handler time and view time: where
    /// the latency goes (the timer, the turn it waited behind, the turn
    /// that handled it).
    var eventTimes: [(due: UInt64, posted: UInt64, shown: UInt64)] = []
    /// The main thread's turns in the window: start, end (uptime ns), kind.
    var turnSpans: [(start: UInt64, end: UInt64, kind: TurnKind)] = []
    var usageBase = ProcessUsage()
    var latencyLabel = 0
    var labelUpdates = 0

    // stuck
    var hogProcess: ShellProcess?
    var hogStartNs: UInt64 = 0
    var stuckMs: Double? = nil
    var stuckMethod = "-"

    // bases at the window's start
    var mainBase = MainThreadCounters()
    var counterBase: [String: UInt64] = [:]
    var energyBase: UInt64? = nil
    var threadBase: [(ShellThread, ThreadCounts)] = []
    var mainThreadBase = ThreadCounts()
    var mainTid: UInt64 = 0
    var pauseBase = 0
    var thermalStart = ""
    var mainQoS = "-"
    var startNs: UInt64 = 0

    let pairing: PairingPresenter?

    public init(_ options: LaunchOptions, platform: ShellPlatform, pairing: PairingPresenter? = nil) {
        self.pairing = pairing
        self.options = options
        self.platform = platform
        name = options.string("scenario", "idle")
        seconds = options.double("seconds", 10)
        warmup = options.double("warmup", 1)
        eventRate = options.int("events", 0)
        hog = options.int("hog", 0) == 1
        budgetOff = options.string("budget", "on") == "off"
        debugStop = options.string("debugstop", "0") == "1"
        noClient = options.string("debugstop", "0") == "noclient"
        afterSeconds = noClient ? options.double("after", 5) : 0
        stopsAsked = options.int("stops", 0)
        servePort = tcpPort(options.string("protocol", options.mode == "serve" ? "tcp" : ""))
    }

    /// After the first frame (iOS kills an app that blocks its main thread
    /// at launch).
    public func start(resources: ShellResources = .main) {
        var o = Headless.Options()
        o.workers = options.int("workers", 5)
        o.heapMiB = options.int("heap", name == "ring" ? 600 : 512)
        o.nurseryKB = options.int("nursery", 4096)
        o.gc = options.string("gc", "cm")
        o.young = options.string("young", "offload")
        o.relocation = options.string("reloc", "on")
        // The development answers: a scenario that serves (debugstop=1,
        // protocol=, mode=serve) is a host a debugger can come to; every
        // other scenario reports and ends an unhandled error.
        o.stopsForDebugger = debugStop || servePort != nil || noClient
        thermalStart = Telemetry.thermal()
        mainTid = Telemetry.threadID()
        mainQoS = Telemetry.qosName(qos_class_self().rawValue)
        do {
            runtime = try makeShellRuntime(imagePath: resources.shellImage, options: o, platform: platform,
                                       events: transcriptSink(), pairing: pairing)
        } catch {
            Output.shared.emit(resultLine("scenario", options, "scenario=\(name) FAILED=1 error=\("\(error)".replacingOccurrences(of: " ", with: "_"))"))
            finish(2)
        }
        runtime.start()
        if debugStop {
            let path = options.string("protocol", FileManager.default.temporaryDirectory.appendingPathComponent("kajo-shell-\(getpid()).sock").path)
            do { protocolServer = try runtime.serveProtocol(socket: path) } catch {
                Output.shared.emit(resultLine("scenario", options, "scenario=\(name) FAILED=1 error=protocol_\("\(error)".replacingOccurrences(of: " ", with: "_"))"))
                finish(2)
            }
        }
        if let port = servePort {
            do {
                tcpServer = try runtime.serveTCP(port: port, store: pairingTokenStore(options), imageName: "shell.img",
                                                 serviceName: options["bonjour"], pairing: pairing)
            } catch {
                Output.shared.emit(resultLine("scenario", options, "scenario=\(name) FAILED=1 error=protocol_\("\(error)".replacingOccurrences(of: " ", with: "_"))"))
                finish(2)
            }
            guard let s = tcpServer else {
                Output.shared.emit(resultLine("scenario", options, "scenario=\(name) FAILED=1 error=no_protocol_in_this_image"))
                finish(2)
            }
            // The port goes to the console (the token never does).
            Output.shared.emit("serving=tcp port=\(s.port ?? 0) addresses=\(localAddresses().joined(separator: ","))")
        }
        runtime.onTurn = { [unowned self] t, k in self.noteTurn(t, k) }
        runtime.onView = { [unowned self] c in self.noteView(c) }
        runtime.onStuck = { [unowned self] r in self.noteStuck(r) }
        // The window, the frame and synthetic actions, the event loop.
        let work = options.int("mainwork", 60000), alloc = options.int("mainalloc", 20)
        guard let p = vm.spawn("openScenario:mainAlloc:mainWork:", receiver: "ShellBench",
                               arguments: [.string(name), .int(Int64(alloc)), .int(Int64(work))], main: true, priority: 2) else {
            Output.shared.emit(resultLine("scenario", options, "scenario=\(name) FAILED=1 error=spawn"))
            finish(2)
        }
        let end = ShellVM.now() + 10_000_000_000
        while vm.state(of: p) != .terminated && ShellVM.now() < end { _ = vm.runTurn(budgetNs: 5_000_000) }
        latencyLabel = Int(vm.result(of: p)?.int ?? 0)
        vm.release(p)
        // The background load, one Process per background worker.
        if let l = vm.spawn("startLoad:workers:", receiver: "ShellBench", arguments: [.string(name), .int(Int64(o.workers))]) {
            vm.waitUntilTerminated(l)
            vm.release(l)
        }
        runtime.postFrames = true
        runtime.ticking = true
        if budgetOff { runtime.budgetOffNs = UInt64(max(1, seconds - 1) * 1e9) }
        startNs = ShellVM.now()
        let t0 = Double(startNs) / 1e9
        measureStart = t0 + warmup
        measureEnd = measureStart + seconds + afterSeconds
        platform.startDisplayLink { [unowned self] ts, target in self.tick(ts, target) }
        if eventRate > 0 { startEvents() }
        DispatchQueue.main.asyncAfter(deadline: .now() + warmup) { MainActor.assumeIsolated { self.begin() } }
        if noClient {
            DispatchQueue.main.asyncAfter(deadline: .now() + warmup + seconds) { MainActor.assumeIsolated { self.serveNoClient() } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + warmup + seconds + afterSeconds + (debugStop ? 2.5 : 0.05)) { MainActor.assumeIsolated { self.end() } }
        platform.showStatus("scenario \(name) \(options.summary)" + (protocolServer.map { " protocol \($0.path) token \($0.token)" } ?? ""))
    }

    nonisolated func transcriptSink() -> @Sendable ([UInt8]) -> Void {
        { bytes in
            guard let o = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
                  o["kind"] as? String == "transcript", let t = o["text"] as? String else { return }
            Output.shared.emit("transcript: " + t)
        }
    }

    var ticksTotal = 0
    var beginLateMs = 0.0
    var beginNs: UInt64 = 0
    var lastTickTs = 0.0

    func tick(_ ts: Double, _ target: Double) {
        ticksTotal += 1
        lastTickTs = ts
        let now = Double(ShellVM.now()) / 1e9
        // By timestamp, not by `measuring`: the window's frames are those
        // the display delivered in it, however late begin() ran.
        if !finished && ts >= measureStart && ts <= measureEnd {
            frameTimes.append(ts)
            callbackLate.append((now - ts) * 1000)
        }
        runtime.tick(timestamp: ts)
    }

    func noteTurn(_ t: ShellTurn, _ k: TurnKind) {
        guard measuring else { return }
        turns += 1
        let now = ShellVM.now()
        if turnSpans.count < 200_000 { turnSpans.append((now &- t.ns, now, k)) }
        slices += t.slices
        if t.preempted { preempted += 1 }
        vmNs &+= t.ns; cpuNs &+= t.cpuNs; parkNs &+= t.parkNs; stopNs &+= t.stopNs
        waitNs &+= t.enterWaitNs &+ t.leaveWaitNs; collectorNs &+= t.collectorNs; youngNs &+= t.youngNs
        if t.ns > maxTurnNs {
            maxTurnNs = t.ns; maxTurnKind = k.rawValue
            maxTurnParts = (t.parkNs, t.enterWaitNs &+ t.leaveWaitNs, t.youngNs)
        }
        maxParkNs = max(maxParkNs, t.parkNs)
        maxWaitNs = max(maxWaitNs, t.enterWaitNs &+ t.leaveWaitNs)
    }

    func noteView(_ c: ViewCall) {
        guard c.handle == latencyLabel, c.op == "set", c.arguments.count == 2,
              c.arguments[0] == .string("text"), let s = c.arguments[1].string, let seq = Int(s),
              seq >= 0, seq < stamps.count else { return }
        labelUpdates += 1
        if measuring {
            let now = ShellVM.now()
            latencies.append(Double(now &- stamps[seq]) / 1e6)
            eventTimes.append((stamps[seq], posted[seq], now))
        }
    }

    func noteStuck(_ r: StuckReport) {
        if stuckMs == nil, let hp = hogProcess, r.process == hp.id {
            stuckMs = Double(ShellVM.now() - hogStartNs) / 1e6
            stuckMethod = r.method
        }
    }

    /// 1000 synthetic events a second from a 1 ms timer on the main queue,
    /// each stamped with the time it was due (as a window-server event
    /// carries the time it happened), handled in a turn at once.
    func startEvents() {
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        t.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / eventRate), leeway: .nanoseconds(0))
        eventsStartNs = ShellVM.now()
        let interval = UInt64(1_000_000_000 / eventRate)
        t.setEventHandler { [unowned self] in
            MainActor.assumeIsolated {
                let fired = ShellVM.now()
                let due = Int((fired - self.eventsStartNs) / interval)
                var n = 0
                while self.eventsPosted < due && n < 10_000 {
                    let stamp = self.eventsStartNs + UInt64(self.eventsPosted + 1) * interval
                    self.stamps.append(stamp)
                    self.posted.append(fired)
                    self.vm.post(ShellEvent(kind: .synthetic, value: .int(Int64(self.eventsPosted)), timeNs: stamp))
                    self.eventsPosted += 1
                    n += 1
                }
                if n > 0 { self.runtime.turn(.event) }
            }
        }
        t.resume()
        eventTimer = t
    }

    func begin() {
        measuring = true
        mainBase = vm.mainThreadCounters
        counterBase = Dictionary(vm.counters.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
        energyBase = Telemetry.energyNj()
        threadBase = vm.threads.map { ($0, ThreadCounts.of($0.threadID)) }
        mainThreadBase = ThreadCounts.of(mainTid)
        pauseBase = vm.pauses.count
        servedBase = tcpServer?.stats.values ?? ServerStats.Values()
        latencies = []
        eventTimes = []
        turnSpans = []
        usageBase = ProcessUsage.now()
        beginNs = ShellVM.now()
        beginLateMs = (Double(beginNs) / 1e9 - measureStart) * 1000
        if hog {
            hogStartNs = ShellVM.now()
            hogProcess = vm.spawn("hog", receiver: "ShellBench", main: true, priority: 1)
        }
        if let server = protocolServer {
            startDebugClient(path: server.path, token: server.token, until: UInt64(measureEnd * 1e9), result: debugResult)
        }
        if noClient { breakEventLoop() }
    }

    /// `debugstop=noclient`: a frame handler fails once (the loop hands
    /// itself over and the old loop stops), and `stops` background
    /// Processes die in errors; nobody is connected.
    func breakEventLoop() {
        footprintBefore = Telemetry.footprint().now
        if let p = vm.spawn("breakEventLoopOnce", receiver: "ShellBench", main: true, priority: 2) {
            let end = ShellVM.now() + 2_000_000_000
            while vm.state(of: p) != .terminated && ShellVM.now() < end { _ = vm.runTurn(budgetNs: 2_000_000) }
            loopBefore = vm.result(of: p)?.int ?? 0
            vm.release(p)
        }
        if stopsAsked > 0, let p = vm.spawn("failInProcesses:", receiver: "ShellBench", arguments: [.int(Int64(stopsAsked))]) {
            vm.waitUntilTerminated(p)
            vm.release(p)
        }
    }

    /// `debugstop=noclient` after `seconds`: serve on loopback and let a
    /// client find the stops and let the loop's go on.
    func serveNoClient() {
        footprintStopped = Telemetry.footprint().now
        serveAtTs = Double(ShellVM.now()) / 1e9
        do {
            noClientServer = try runtime.serveTCP(port: 0, loopbackOnly: true, advertise: false, store: nil, imageName: "shell.img",
                                                  serviceName: nil, pairing: nil)
        } catch {
            noClientResult.withLock { $0.error = "serve: \(error)" }
        }
        guard let s = noClientServer, let port = s.port else {
            noClientResult.withLock { $0.error = $0.error.isEmpty ? "no server" : $0.error }
            return
        }
        startNoClientClient(port: port, token: s.token, loop: loopBefore, result: noClientResult)
    }

    func end() {
        if finished { return }
        finished = true
        measuring = false
        eventTimer?.cancel()
        platform.stopDisplayLink()
        let nominal = Double(platform.maximumFramesPerSecond)
        let fa = FrameAccount(timestamps: frameTimes, start: measureStart, end: measureEnd, nominalHz: nominal)
        let fa120 = FrameAccount(timestamps: frameTimes, start: measureStart, end: measureEnd, nominalHz: 120)
        func ms(_ ns: UInt64) -> String { f3(Double(ns) / 1e6) }
        // Turn and counter sums run from begin() to here: per 10 s of that.
        let counted = max(0.001, Double(ShellVM.now() - beginNs) / 1e9)
        func per10(_ ns: UInt64) -> String { f3(Double(ns) / 1e6 * 10 / counted) }
        let m = vm.mainThreadCounters.since(mainBase)
        let counters = Dictionary(vm.counters.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
        func d(_ k: String) -> UInt64 { (counters[k] ?? 0) &- (counterBase[k] ?? 0) }
        var line = "scenario=\(name) gc=\(options.string("gc", "cm")) young=\(options.string("young", "offload")) workers=\(options.int("workers", 5))"
        line += " seconds=\(seconds) events=\(eventRate) hog=\(hog ? 1 : 0) budget=\(budgetOff ? "off" : "on") thermal_start=\(thermalStart)"
        line += " nominal_hz=\(f2(nominal)) refresh_hz=\(f2(fa.deliveredHz)) frames=\(fa.frames) expected=\(fa.expected)"
        line += " ticks_total=\(ticksTotal) begin_late_ms=\(f3(beginLateMs)) counted_s=\(f3(counted))"
        line += " drops=\(fa.drops) missed=\(fa.missed) missed120=\(fa120.missed)"
        line += " gap_p50_ms=\(f3(fa.gapP50Ms)) gap_p99_ms=\(f3(fa.gapP99Ms)) gap_max_ms=\(f3(fa.gapMaxMs))"
        line += " cb_late_p50_ms=\(f3(percentile(callbackLate, 0.5))) cb_late_p99_ms=\(f3(percentile(callbackLate, 0.99))) cb_late_max_ms=\(f3(callbackLate.max() ?? 0))"
        line += " turns=\(turns) slices=\(slices) preempted_turns=\(preempted) max_turn_ms=\(ms(maxTurnNs)) max_turn_kind=\(maxTurnKind)"
        line += " max_turn_park_ms=\(ms(maxTurnParts.park)) max_turn_wait_ms=\(ms(maxTurnParts.wait)) max_turn_young_ms=\(ms(maxTurnParts.young))"
        line += " max_park_ms=\(ms(maxParkNs)) max_enter_leave_wait_ms=\(ms(maxWaitNs))"
        line += " main_vm_ms_per10s=\(per10(vmNs)) main_cpu_ms_per10s=\(per10(cpuNs))"
        // ADR 0008's attribution: stopped because another worker allocated
        // (parked in stops, rounds of other nurseries' collections, polls that
        // found none owed, waits for a pending stop) and its own.
        let others = parkNs &+ m.othersNs
        let own = stopNs &+ m.ownTotalNs
        line += " main_stopped_others_ms_per10s=\(per10(others)) main_stopped_own_ms_per10s=\(per10(own))"
        line += " main_park_ms_per10s=\(per10(parkNs)) main_copy_in_stops_ms_per10s=\(per10(collectorNs)) main_enter_leave_wait_ms_per10s=\(per10(waitNs))"
        line += " main_acks_other=\(m.acksOther) main_acks_other_ms_per10s=\(per10(m.acksOtherNs)) main_ack_other_mean_us=\(m.acksOther == 0 ? "-" : f1(Double(m.acksOtherNs) / Double(m.acksOther) / 1e3))"
        line += " main_ack_max_ms=\(ms(m.ackMaxNs)) main_acks_own=\(m.acksOwn) main_flips=\(m.flips) main_flip_max_ms=\(ms(m.flipMaxNs))"
        line += " main_own_collections=\(m.ownCollections) main_own_max_ms=\(ms(m.ownMaxNs)) main_collector_waits=\(m.collectorWaits) main_collector_wait_ms=\(ms(m.collectorWaitNs))"
        line += " main_stop_wait_ms_per10s=\(per10(m.stopWaitNs)) main_stop_wait_max_ms=\(ms(m.stopWaitMaxNs)) main_opens_while_wanted=\(m.opensWhileWanted) main_drain_wait_ms_per10s=\(per10(m.drainWaitNs))"
        if eventRate > 0 {
            line += " events_posted=\(eventsPosted) label_updates=\(labelUpdates) ev_n=\(latencies.count)"
            line += " ev_lat_p50_ms=\(f3(percentile(latencies, 0.5))) ev_lat_p99_ms=\(f3(percentile(latencies, 0.99))) ev_lat_max_ms=\(f3(latencies.max() ?? 0))"
            line += eventBreakdown()
        }
        line += turnBreakdown(counted)
        if hog {
            line += " stuck_ms=\(stuckMs.map(f1) ?? "-") stuck_method=\(stuckMethod)"
        }
        if debugStop {
            let r = debugResult.withLock { $0 }
            line += " debug_stopped=\(r.stopped ? 1 : 0) debug_reason=\(r.reason) debug_process=\(r.process) debug_stopped_s=\(f3(r.stoppedSeconds))"
            line += " protocol_replies=\(r.rtts.count) protocol_errors=\(r.errors) protocol_rtt_p50_ms=\(f3(percentile(r.rtts, 0.5))) protocol_rtt_p99_ms=\(f3(percentile(r.rtts, 0.99))) protocol_rtt_max_ms=\(f3(r.rtts.max() ?? 0))"
            line += " debug_resumed=\(r.resumed ? 1 : 0) handled_while_stopped=\(r.handledWhileStopped) handled_after_resume=\(r.handledAfterResume) debug_error=\(r.error.isEmpty ? "-" : r.error.replacingOccurrences(of: " ", with: "_"))"
            runtime.stopProtocol()
        }
        if noClient {
            let r = noClientResult.withLock { $0 }
            let stoppedEnd = serveAtTs > 0 ? serveAtTs : measureEnd
            let fs = FrameAccount(timestamps: frameTimes.filter { $0 >= measureStart && $0 <= stoppedEnd }, start: measureStart,
                                  end: stoppedEnd, nominalHz: nominal)
            let resumedAt = r.proceededAtNs > 0 ? Double(r.proceededAtNs) / 1e9 : measureEnd
            let fr = FrameAccount(timestamps: frameTimes.filter { $0 >= resumedAt && $0 <= measureEnd }, start: resumedAt,
                                  end: measureEnd, nominalHz: nominal)
            line += " noclient=1 stops_asked=\(stopsAsked) loop_before=\(loopBefore) stopped_s=\(f3(stoppedEnd - measureStart))"
            line += " frames_stopped=\(fs.frames) expected_stopped=\(fs.expected) missed_stopped=\(fs.missed) gap_max_stopped_ms=\(f3(fs.gapMaxMs))"
            line += " frames_after=\(fr.frames) expected_after=\(fr.expected) missed_after=\(fr.missed) gap_max_after_ms=\(f3(fr.gapMaxMs)) after_s=\(f3(measureEnd - resumedAt))"
            line += " footprint_before_mb=\(f1(Double(footprintBefore) / 1_048_576)) footprint_stopped_mb=\(f1(Double(footprintStopped) / 1_048_576))"
            line += " stops_delta_kb=\(footprintStopped >= footprintBefore ? f1(Double(footprintStopped - footprintBefore) / 1024) : "-")"
            line += " info_stops=\(r.infoStops) loop_found=\(r.loopFound ? 1 : 0) loop_frames=\(r.frames) refused=\(r.refused) hand_overs=\(r.handOvers)"
            line += " open_ms=\(f3(r.openMs)) frames_ms=\(f3(r.framesMs)) proceed_ms=\(f3(r.proceedMs)) loop_ended=\(r.loopEnded ? 1 : 0)"
            line += " noclient_error=\(r.error.isEmpty ? "-" : r.error.replacingOccurrences(of: " ", with: "_"))"
            runtime.stopProtocol()
        }
        if let s = tcpServer {
            line += requestRecords(s)
            // What the server did in the window (sessions, requests, bytes
            // written; the longest a VM thread spent handing it a line).
            let v = s.stats.values, b = servedBase
            line += " served=tcp served_sessions=\(v.sessions - b.sessions) served_requests=\(v.requests - b.requests) served_bytes=\(v.bytesWritten - b.bytesWritten)"
            line += " served_failed_opens=\(v.failedOpens - b.failedOpens) served_refused=\(v.refusedConnections - b.refusedConnections) served_open_sessions=\(s.sessionCount)"
            let n = v.delivers - b.delivers
            line += " deliver_n=\(n) deliver_mean_us=\(n == 0 ? "-" : f1(Double(v.deliverTotalNs &- b.deliverTotalNs) / Double(n) / 1e3)) deliver_max_us=\(f1(Double(v.deliverMaxNs) / 1e3)) writer_max_pending_kb=\(f1(Double(v.maxPendingBytes) / 1024))"
            runtime.stopProtocol()
        }
        line += " preemptions=\(d("preemptions")) hops=\(d("hops")) view_calls=\(d("viewCalls")) shell_events=\(d("shellEvents")) stuck_reports=\(d("stuckReports"))"
        line += " stops=\(vm.pauses.count - pauseBase)"
        if let e0 = energyBase, let e1 = Telemetry.energyNj() {
            line += " energy_mj=\(f1(Double(e1 &- e0) / 1e6)) power_w=\(f3(Double(e1 &- e0) / 1e9 / counted))"
        }
        // Where the VM's threads ran: CPU on performance and efficiency cores.
        var workers = ThreadCounts(ok: true)
        for (t, base) in threadBase {
            let c = ThreadCounts.of(t.threadID).since(base)
            if t.role.hasPrefix("worker") {
                workers = workers + c
            } else {
                line += c.fields(t.role) + " \(t.role)_qos=\(Telemetry.qosName(t.qos))"
            }
        }
        line += workers.fields("workers") + ThreadCounts.of(mainTid).since(mainThreadBase).fields("main")
        line += " worker_qos=" + (vm.threads.filter { $0.role.hasPrefix("worker") }.map { Telemetry.qosName($0.qos) }.first ?? "-")
        // The QoS each thread actually got (its base priority now) and each
        // worker's share on performance cores.
        line += ThreadPriority.of(mainTid).fields("main") + " main_qos_asked=\(mainQoS)"
        for t in vm.threads where !t.role.hasPrefix("worker") { line += ThreadPriority.of(t.threadID).fields(t.role) }
        let ws = vm.threads.filter { $0.role.hasPrefix("worker") }
        line += " workers_qos_got=" + ws.map { ThreadPriority.of($0.threadID).qosName }.joined(separator: ",")
        line += " workers_pri=" + ws.map { let p = ThreadPriority.of($0.threadID); return p.ok ? "\(p.base)/\(p.current)" : "-" }.joined(separator: ",")
        line += " workers_p_fracs=" + threadBase.filter { $0.0.role.hasPrefix("worker") }.map { t, b -> String in
            let c = ThreadCounts.of(t.threadID).since(b)
            let tot = c.pCpuNs &+ c.eCpuNs
            return f2(tot > 0 ? Double(c.pCpuNs) / Double(tot) : 0)
        }.joined(separator: ",")
        line += ProcessUsage.now().fields(since: usageBase)
        // The collectors' report over the whole run (warm-up included).
        for (k, v) in vm.collectorReport(seconds: Double(ShellVM.now() - startNs) / 1e9) {
            line += " gc_\(k)=\(v.replacingOccurrences(of: " ", with: "_"))"
        }
        line += " load_failures=\(loadFailures()) thermal_end=\(Telemetry.thermal()) screen_max_fps=\(platform.maximumFramesPerSecond)"
        Output.shared.emit(resultLine("scenario", options, line))
        finish(0)
    }

    /// Where the events' latency went: the timer's own lateness (due to
    /// handler), the handler to the view call (the event turn), and whether
    /// the event fell due while the main thread was in a turn (and then how
    /// long that turn still had to run, and from its end to the handler).
    func eventBreakdown() -> String {
        let ms = { (a: UInt64, b: UInt64) -> Double in b > a ? Double(b - a) / 1e6 : 0 }
        let fire = eventTimes.map { ms($0.due, $0.posted) }
        let handle = eventTimes.map { ms($0.posted, $0.shown) }
        // The turns are in time order; for each event the turn that covers
        // its due time, if any (a binary search on starts).
        let spans = turnSpans
        var inTurn = 0
        var rest: [Double] = [], after: [Double] = [], notInFire: [Double] = []
        var kinds: [String: Int] = [:]
        for e in eventTimes {
            var lo = 0, hi = spans.count
            while lo < hi { let mid = (lo + hi) / 2; if spans[mid].start <= e.due { lo = mid + 1 } else { hi = mid } }
            if lo > 0, spans[lo - 1].end > e.due {
                let sp = spans[lo - 1]
                inTurn += 1
                kinds[sp.kind.rawValue, default: 0] += 1
                rest.append(ms(e.due, sp.end))
                after.append(ms(sp.end, e.posted))
            } else {
                notInFire.append(ms(e.due, e.posted))
            }
        }
        let n = max(1, eventTimes.count)
        var o = " ev_fire_p50_ms=\(f3(percentile(fire, 0.5))) ev_fire_p99_ms=\(f3(percentile(fire, 0.99))) ev_handle_p50_ms=\(f3(percentile(handle, 0.5))) ev_handle_p99_ms=\(f3(percentile(handle, 0.99)))"
        o += " ev_due_in_turn_frac=\(f3(Double(inTurn) / Double(n))) ev_due_in_turn_kinds=" + kinds.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
        o += " ev_turn_rest_p50_ms=\(f3(percentile(rest, 0.5))) ev_turn_rest_p99_ms=\(f3(percentile(rest, 0.99))) ev_after_turn_p50_ms=\(f3(percentile(after, 0.5))) ev_after_turn_p99_ms=\(f3(percentile(after, 0.99)))"
        o += " ev_free_fire_p50_ms=\(f3(percentile(notInFire, 0.5))) ev_free_fire_p99_ms=\(f3(percentile(notInFire, 0.99)))"
        return o
    }

    /// The main thread's turns in the window by kind: count, p50, p99 and
    /// max ms, and the fraction of the window the main thread was in one.
    func turnBreakdown(_ counted: Double) -> String {
        var by: [String: [Double]] = [:]
        var total: UInt64 = 0
        for sp in turnSpans {
            by[sp.kind.rawValue, default: []].append(Double(sp.end &- sp.start) / 1e6)
            total &+= sp.end &- sp.start
        }
        var o = " main_busy_frac=\(f3(Double(total) / 1e9 / counted))"
        for (k, v) in by.sorted(by: { $0.key < $1.key }) {
            o += " turn_\(k)_n=\(v.count) turn_\(k)_p50_ms=\(f3(percentile(v, 0.5))) turn_\(k)_p99_ms=\(f3(percentile(v, 0.99))) turn_\(k)_max_ms=\(f3(v.max() ?? 0))"
        }
        return o
    }

    /// The served requests' times in the target (read to reply written),
    /// summed on the result line and written one per line to
    /// `requests-<tag>.txt` beside the results for the link measurement,
    /// with the uptime and wall clocks read together for alignment.
    func requestRecords(_ s: ProtocolServer) -> String {
        let (records, dropped) = s.stats.requestRecords
        let done = records.filter { $0.writtenNs != 0 }
        let service = done.map { Double($0.writtenNs &- $0.readNs) / 1e6 }
        let inVM = records.filter { $0.deliveredNs != 0 }.map { Double($0.deliveredNs &- $0.readNs) / 1e6 }
        let dir = (Output.shared.filePath as NSString).deletingLastPathComponent
        let path = (dir as NSString).appendingPathComponent("requests-\(options.string("tag", "-")).txt")
        var text = "uptime_ns=\(ShellVM.now()) wall_s=\(f3(Date().timeIntervalSince1970)) dropped=\(dropped)\n"
        for r in records { text += "\(r.connection) \(r.id) \(r.kind) \(r.readNs) \(r.deliveredNs) \(r.writtenNs)\n" }
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        return " served_records=\(records.count) served_records_dropped=\(dropped) served_service_p50_ms=\(f3(percentile(service, 0.5))) served_service_p99_ms=\(f3(percentile(service, 0.99))) served_service_max_ms=\(f3(service.max() ?? 0)) served_invm_max_ms=\(f3(inVM.max() ?? 0))"
    }

    func loadFailures() -> String {
        guard let p = vm.spawn("failures", receiver: "ShellBench") else { return "-" }
        let end = ShellVM.now() + 2_000_000_000
        while vm.state(of: p) != .terminated && ShellVM.now() < end { usleep(1000) }
        return vm.result(of: p).map { "\($0)" } ?? "-"
    }
}

final class DebugStopBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = DebugStopResult()
    func withLock<T>(_ f: (inout DebugStopResult) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return f(&value)
    }
}

/// What the debug-stop client saw (module 9b).
struct DebugStopResult: Sendable {
    var stopped = false
    var reason = "-"
    var process: Int64 = 0
    var stoppedSeconds = 0.0
    var rtts: [Double] = []
    var errors = 0
    var resumed = false
    var handledWhileStopped: Int64 = -1
    var handledAfterResume: Int64 = -1
    var error = ""
}

/// The client of `debugstop=1`, on a thread of its own: stop the event
/// loop's Process, keep asking the target until `until` (uptime ns), let
/// the Process go on, see it handle the events that queued.
nonisolated func startDebugClient(path: String, token: String, until: UInt64, result: DebugStopBox) {
    onBackgroundThread {
        do {
            let c = try ProtocolClient(path: path)
            defer { c.close() }
            try c.open(token: token, client: "agent:debugstop", timeout: 10)
            func eval(_ s: String) throws -> Int64 {
                Int64(try c.request("evaluate", [("source", .string(s))], timeout: 10)["value"]?.string ?? "") ?? -1
            }
            let pid = try eval("UIEventLoop process id")
            let mark = c.eventMark
            _ = try c.request("process.suspend", [("process", .int(pid))], timeout: 10)
            guard let e = c.waitForEvent(since: mark, timeout: 10, { $0["kind"]?.string == "process.stopped" && $0["process"] == .int(pid) }) else {
                result.withLock { $0.error = "the event loop did not stop" }
                return
            }
            let stoppedAt = ShellVM.now()
            let handled0 = try eval("UIEventLoop handledCount")
            result.withLock {
                $0.stopped = true
                $0.reason = e["reason"]?.string ?? "-"
                $0.process = pid
            }
            while ShellVM.now() < until {
                let t0 = ShellVM.now()
                do {
                    _ = try c.request("evaluate", [("source", .string("3 + 4"))], timeout: 10)
                    let rtt = Double(ShellVM.now() - t0) / 1e6
                    result.withLock { $0.rtts.append(rtt) }
                } catch {
                    result.withLock { $0.errors += 1 }
                }
                usleep(50_000)
            }
            let handled1 = try eval("UIEventLoop handledCount")
            _ = try c.request("process.proceed", [("process", .int(pid))], timeout: 10)
            let stoppedS = Double(ShellVM.now() - stoppedAt) / 1e9
            usleep(500_000)
            let handled2 = try eval("UIEventLoop handledCount")
            result.withLock {
                $0.stoppedSeconds = stoppedS
                $0.handledWhileStopped = handled1 - handled0
                $0.handledAfterResume = handled2 - handled1
                $0.resumed = handled2 > handled1
            }
        } catch {
            result.withLock { $0.error = "\(error)" }
        }
    }
}

final class NoClientBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = NoClientResult()
    func withLock<T>(_ f: (inout NoClientResult) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return f(&value)
    }
}

/// What the client of `debugstop=noclient` saw.
struct NoClientResult: Sendable {
    var infoStops = -1
    var loopFound = false
    var frames = -1
    var refused: Int64 = -1
    var handOvers: Int64 = -1
    var openMs = 0.0, framesMs = 0.0, proceedMs = 0.0
    var proceededAtNs: UInt64 = 0
    var loopEnded = false
    var error = ""
}

/// The client of `debugstop=noclient`, on a thread of its own: connect
/// after the stops, find them in session.open's answer, read the stopped
/// loop's frames, let it go on, see it end (its generation is no longer the
/// loop's).
nonisolated func startNoClientClient(port: Int, token: String, loop: Int64, result: NoClientBox) {
    onBackgroundThread {
        do {
            let c = try ProtocolClient(address: .tcp(host: "127.0.0.1", port: port))
            defer { c.close() }
            var t0 = ShellVM.now()
            let info = try c.open(token: token, client: "agent:noclient", timeout: 10)
            let openMs = Double(ShellVM.now() - t0) / 1e6
            let stops = info["stopped"]?.array ?? []
            let found = stops.contains { $0["process"] == .int(loop) }
            t0 = ShellVM.now()
            let frames = try c.request("process.frames", [("process", .int(loop))], timeout: 10).array?.count ?? -1
            let framesMs = Double(ShellVM.now() - t0) / 1e6
            t0 = ShellVM.now()
            _ = try c.request("process.proceed", [("process", .int(loop))], timeout: 10)
            let done = ShellVM.now()
            func eval(_ s: String) throws -> String { try c.request("evaluate", [("source", .string(s))], timeout: 10)["value"]?.string ?? "" }
            var ended = false
            for _ in 0..<2000 {
                if try eval("(Debugger processWithId: \(loop)) isNil or: [(Debugger processWithId: \(loop)) isTerminated]") == "true" {
                    ended = true
                    break
                }
                usleep(1000)
            }
            let refused = Int64(try eval("Debugger refusedStops")) ?? -1
            let hand = Int64(try eval("UIEventLoop handOverCount")) ?? -1
            result.withLock {
                $0.infoStops = stops.count
                $0.loopFound = found
                $0.frames = frames
                $0.openMs = openMs
                $0.framesMs = framesMs
                $0.proceedMs = Double(done - t0) / 1e6
                $0.proceededAtNs = done
                $0.loopEnded = ended
                $0.refused = refused
                $0.handOvers = hand
            }
        } catch {
            result.withLock { $0.error = "\(error)" }
        }
    }
}

/// Where the pairing token is kept: the app's Application Support on iOS
/// (stable per install, mode 0600); on the Mac in memory (nil: its shell
/// shows the token in the status line as 9b's does) unless `tokendir=`
/// names a directory (the Mac-to-Mac measurement reads it from there as
/// the phone's is copied from its container).
func pairingTokenStore(_ options: LaunchOptions) -> PairingTokenStore? {
    #if os(iOS)
    return PairingTokenStore.applicationSupport()
    #else
    return options["tokendir"].map { PairingTokenStore(directory: $0) }
    #endif
}
