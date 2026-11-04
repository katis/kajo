import Darwin
import Dispatch
import Foundation
import KajoVM

/// `mode=scenario scenario=storm|ring|share|idle gc=cm|stw young=stw|local|offload
/// workers=N seconds=10 warmup=1 events=0|1000 hog=0|1 budget=on|off`:
/// module 7's scenarios driven by the real display link. The window is
/// built in Smalltalk (ShellBench), a probe view is moved by Smalltalk on
/// every frame event (so ProMotion does not throttle) after module 7's
/// main-thread load (`mainTick:work:`), synthetic events set a label in
/// Smalltalk and their latency is taken at the view call, a hog loops on
/// main. One result line at the end, then the app exits.
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

    // events
    var eventTimer: DispatchSourceTimer?
    var eventsPosted = 0
    var eventsStartNs: UInt64 = 0
    var stamps: [UInt64] = []
    var latencies: [Double] = []
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
    var startNs: UInt64 = 0

    public init(_ options: LaunchOptions, platform: ShellPlatform) {
        self.options = options
        self.platform = platform
        name = options.string("scenario", "idle")
        seconds = options.double("seconds", 10)
        warmup = options.double("warmup", 1)
        eventRate = options.int("events", 0)
        hog = options.int("hog", 0) == 1
        budgetOff = options.string("budget", "on") == "off"
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
        thermalStart = Telemetry.thermal()
        mainTid = Telemetry.threadID()
        do {
            runtime = try ShellRuntime(imagePath: resources.shellImage, options: o, platform: platform,
                                       events: transcriptSink())
        } catch {
            Output.shared.emit(resultLine("scenario", options, "scenario=\(name) FAILED=1 error=\("\(error)".replacingOccurrences(of: " ", with: "_"))"))
            finish(2)
        }
        runtime.start()
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
        measureEnd = measureStart + seconds
        platform.startDisplayLink { [unowned self] ts, target in self.tick(ts, target) }
        if eventRate > 0 { startEvents() }
        DispatchQueue.main.asyncAfter(deadline: .now() + warmup) { MainActor.assumeIsolated { self.begin() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + warmup + seconds + 0.05) { MainActor.assumeIsolated { self.end() } }
        platform.showStatus("scenario \(name) \(options.summary)")
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
        slices += t.slices
        if t.preempted { preempted += 1 }
        vmNs &+= t.ns; cpuNs &+= t.cpuNs; parkNs &+= t.parkNs; stopNs &+= t.stopNs
        waitNs &+= t.enterWaitNs &+ t.leaveWaitNs; collectorNs &+= t.collectorNs; youngNs &+= t.youngNs
        if t.ns > maxTurnNs { maxTurnNs = t.ns; maxTurnKind = k.rawValue }
    }

    func noteView(_ c: ViewCall) {
        guard c.handle == latencyLabel, c.op == "set", c.arguments.count == 2,
              c.arguments[0] == .string("text"), let s = c.arguments[1].string, let seq = Int(s),
              seq >= 0, seq < stamps.count else { return }
        labelUpdates += 1
        if measuring { latencies.append(Double(ShellVM.now() &- stamps[seq]) / 1e6) }
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
                let due = Int((ShellVM.now() - self.eventsStartNs) / interval)
                var n = 0
                while self.eventsPosted < due && n < 10_000 {
                    let stamp = self.eventsStartNs + UInt64(self.eventsPosted + 1) * interval
                    self.stamps.append(stamp)
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
        latencies = []
        beginNs = ShellVM.now()
        beginLateMs = (Double(beginNs) / 1e9 - measureStart) * 1000
        if hog {
            hogStartNs = ShellVM.now()
            hogProcess = vm.spawn("hog", receiver: "ShellBench", main: true, priority: 1)
        }
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
        if eventRate > 0 {
            line += " events_posted=\(eventsPosted) label_updates=\(labelUpdates) ev_n=\(latencies.count)"
            line += " ev_lat_p50_ms=\(f3(percentile(latencies, 0.5))) ev_lat_p99_ms=\(f3(percentile(latencies, 0.99))) ev_lat_max_ms=\(f3(latencies.max() ?? 0))"
        }
        if hog {
            line += " stuck_ms=\(stuckMs.map(f1) ?? "-") stuck_method=\(stuckMethod)"
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
                workers = ThreadCounts(ok: workers.ok && c.ok, pCpuNs: workers.pCpuNs &+ c.pCpuNs, eCpuNs: workers.eCpuNs &+ c.eCpuNs,
                                       pEnergyNj: workers.pEnergyNj &+ c.pEnergyNj, eEnergyNj: workers.eEnergyNj &+ c.eEnergyNj)
            } else {
                line += c.fields(t.role) + " \(t.role)_qos=\(Telemetry.qosName(t.qos))"
            }
        }
        line += workers.fields("workers") + ThreadCounts.of(mainTid).since(mainThreadBase).fields("main")
        line += " worker_qos=" + (vm.threads.filter { $0.role.hasPrefix("worker") }.map { Telemetry.qosName($0.qos) }.first ?? "-")
        // The collectors' report over the whole run (warm-up included).
        for (k, v) in vm.collectorReport(seconds: Double(ShellVM.now() - startNs) / 1e9) {
            line += " gc_\(k)=\(v.replacingOccurrences(of: " ", with: "_"))"
        }
        line += " load_failures=\(loadFailures()) thermal_end=\(Telemetry.thermal()) screen_max_fps=\(platform.maximumFramesPerSecond)"
        Output.shared.emit(resultLine("scenario", options, line))
        finish(0)
    }

    func loadFailures() -> String {
        guard let p = vm.spawn("failures", receiver: "ShellBench") else { return "-" }
        let end = ShellVM.now() + 2_000_000_000
        while vm.state(of: p) != .terminated && ShellVM.now() < end { usleep(1000) }
        return vm.result(of: p).map { "\($0)" } ?? "-"
    }
}
