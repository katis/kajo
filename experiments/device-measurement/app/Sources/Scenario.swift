// Part C: concurrent-young's kajo-ui scenarios on UIKit. A port of
// ../../concurrent-young/swift/Sources/kajo-ui/main.swift: the turns, the
// frame account, the event timer, the run-loop observer, the watchdog and
// every key of the result line are that file's, unchanged; what changed is
// the shell (UIWindow from the scene, UILabel/UISlider/UITextView in place of
// the AppKit views, a CADisplayLink on the main run loop asking for 120 Hz,
// a view moved every frame so ProMotion does not throttle an idle screen),
// the number of background workers (`bg`, default 5: the phone has 6 cores
// where the Mac ran 7 on 12), and the output (Output.shared plus device
// telemetry). Device scenario ids map to the Mac's:
//   D0 = Y0 idle, D1 = Y1 storm stw, D2 = Y2 storm local, D3 = Y3 storm
//   offload, D4 = Y4l fragmentation ring local, D5 = Y5o heavy main-thread
//   allocation offload.

import Darwin
import Kasm
import QuartzCore
import Synchronization
import UIKit
import VMR

let deviceScenarios = ["D0": "Y0", "D1": "Y1", "D2": "Y2", "D3": "Y3", "D4": "Y4l", "D5": "Y5o"]

// MARK: - stats helpers

func pct(_ xs: [Double], _ p: Double) -> Double {
    if xs.isEmpty { return 0 }
    let s = xs.sorted()
    return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
}

func f3(_ x: Double) -> String { String(format: "%.3f", x) }
func f2(_ x: Double) -> String { String(format: "%.2f", x) }

func samplesMs(_ s: UnsafeMutablePointer<Samples>, from: Int = 0) -> [Double] {
    let v = s.pointee.values()
    return v[min(from, v.count)...].map { Double($0) / 1e6 }
}

// MARK: - hooks (C function pointers; VM threads call wakeMain)

let wakePending = Atomic<Bool>(false)
let watchdogReported = Atomic<Bool>(false)

let wakeHook: WakeHook = { _ in
    if wakePending.exchange(true, ordering: .acquiringAndReleasing) { return }
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            wakePending.store(false, ordering: .releasing)
            ScenarioController.shared?.turn(.wake)
        }
    }
}

let uiHook: UIHook = { _, kind, value in
    MainActor.assumeIsolated { ScenarioController.shared?.ui(kind, value) ?? 0 }
}

let stuckHook: StuckHook = { _, id, sel, ms in
    let name = String(cString: sel)
    MainActor.assumeIsolated { ScenarioController.shared?.stuck(id: id, method: name, ms: ms, source: "shell") }
}

/// Built outside the main actor: a closure written inside a @MainActor
/// method is inferred main-actor isolated, and Swift 6 traps when GCD runs
/// it on another queue (found on the first run).
func watchdogHandler(bits: UInt, killAt: UInt64, kill: Bool) -> @Sendable () -> Void {
    return {
        let vm = UnsafeMutablePointer<VMCore>(bitPattern: bits)!
        let ms = mainBusyMs(vm)
        if ms > 300 && !watchdogReported.exchange(true, ordering: .relaxed) {
            let id = vm.pointee.mainBusyId.load(ordering: .relaxed)
            fputs("STUCK process=\(id) ms=\(f2(ms)) via=watchdog (main thread held)\n", stderr)
        }
        if kill && now() >= killAt && ms > 0 { interruptMain(vm) }
    }
}

// MARK: - the controller

enum TurnKind { case tick, event, wake }

@MainActor
final class ScenarioController: UIViewController {
    static var shared: ScenarioController?

    let opts: Options
    let info: LaunchInfo
    let scenarioId: String
    let ys: String
    let bg: Int
    let seconds: Double
    let warmup: Double
    let runN: Int
    var thermalStart = ""
    var mover: UIView!
    var moverX: CGFloat = 0
    var rt: Runtime!
    var vm: VMRef { rt.vm }
    var label: UILabel!
    var textView: UITextView!
    var slider: UISlider!
    var lines: [String] = []
    var link: CADisplayLink?

    // frames
    var frameTimes: [Double] = []
    var linkDurations: [Double] = []
    /// ms between the frame's vsync timestamp and our callback running.
    var callbackLate: [Double] = []
    var measureStart = 0.0
    var measureEnd = 0.0
    var t0 = 0.0
    var measuring = false

    // turns and the frame account (ns)
    let frameAccountNs: Int64 = 4_000_000
    var frameRemaining: Int64 = 4_000_000
    var turns = 0
    var turnsUIOnly = 0
    var vmMainNs: UInt64 = 0
    var maxTurnNs: UInt64 = 0
    var maxTurnKind = ""
    var maxTurnParkedNs: UInt64 = 0
    var maxTurnEnterWaitNs: UInt64 = 0

    // run-loop iterations
    var iterStart: UInt64 = 0
    var iterVmNs: UInt64 = 0
    var iterParkedNs: UInt64 = 0
    var iterEnterNs: UInt64 = 0
    var buildWaitS = 0.0
    /// Main-thread time outside turns: checkStuck (enters the VM, takes the
    /// scheduler lock) and the event timer handler, max over the window.
    var checkStuckMax: UInt64 = 0
    var timerHandlerMax: UInt64 = 0
    var iterTurns = 0
    var worstIter: UInt64 = 0
    var worstIterVm: UInt64 = 0
    var worstIterParked: UInt64 = 0
    var worstIterEnter: UInt64 = 0
    var worstIterTurns = 0
    var observer: CFRunLoopObserver?

    // events
    var eventTimer: DispatchSourceTimer?
    var eventsPosted = 0
    var eventsStart = 0.0
    var eventRate = 0.0
    var labelValue: Int64 = 0
    var labelUpdates = 0
    /// ms the 1 ms event timer fired after the oldest event it had to post was due.
    var timerLate: [Double] = []
    var native = false
    var nativeLatency: [Double] = []

    // stuck reports
    var stuckReports: [String] = []

    // scenario
    var spin50us = 0
    var spin1ms = 0
    var spin20us = 0
    var churn100us = 0
    var gcLogStart = 0
    var rssBefore = 0
    var rssParked = 0
    var parkedProcs = 0
    var metricsAtStart: [Metric: UInt64] = [:]
    var sampleStart: [String: Int] = [:]
    var watchdog: DispatchSourceTimer?
    var watchdogMs = 0.0

    init(_ o: Options, info: LaunchInfo) {
        opts = o
        self.info = info
        scenarioId = o["scenario"] ?? "D0"
        ys = deviceScenarios[scenarioId] ?? scenarioId
        bg = o.int("bg", 5)
        seconds = o.double("seconds", 10)
        warmup = o.double("warmup", 1)
        runN = o.int("run", 1)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: setup

    override func viewDidLoad() {
        super.viewDidLoad()
        buildWindow()
    }

    var started = false
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if started { return }
        started = true
        // After the first frame: launch must not be blocked by loading.
        DispatchQueue.main.async { MainActor.assumeIsolated { self.start() } }
    }

    @MainActor func start() {
        ScenarioController.shared = self
        do {
            // SPEC.md "Scenarios": 4 MiB nurseries, N = 2, KAJO_GC=cm.
            let s = ys
            let frag = s.hasPrefix("Y4")
            let share = s == "Y6"
            let src = try appSources(fragment: frag, share: share)
            let img = try Image.fromSources(src, heapSize: (frag ? 512 : 64) << 20, nurseryBytes: 4 << 20)
            var cfg = cmConfigFromEnv()
            cfg.concurrent = true
            cfg.ageN = 2
            cfg.relocThreshold = frag ? 50 : 0
            // Y4: cycles from 30 percent of 512 MiB (R5 of ADR 0007).
            if frag { cfg.threshold = 0.30 }
            cfg.verify = false
            var y = ycConfigFromEnv()
            switch s {
            case "Y1", "Y4s", "Y5s": y.mode = YoungMode.stw // Y4s, Y5s: baselines for Y4, Y5
            case "Y2", "Y4l", "Y5l": y.mode = YoungMode.local
            default: y.mode = YoungMode.offload
            }
            y.verifyYoung = false
            rt = Runtime(img, background: share ? bg + 1 : bg, config: cfg, young: y)
        } catch {
            Output.shared.emit("scenario=\(scenarioId) FAILED=1 error=load_failed"); exit(1)
        }
        vm.pointee.wakeMain = wakeHook
        vm.pointee.uiHook = uiHook
        vm.pointee.stuckHook = stuckHook
        thermalStart = Telemetry.thermal()
        calibrate()
        startLoad()
        t0 = CACurrentMediaTime()
        measureStart = t0 + warmup
        measureEnd = measureStart + seconds
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
        installObserver()
        startWatchdog()
        DispatchQueue.main.asyncAfter(deadline: .now() + warmup) { MainActor.assumeIsolated { self.beginMeasure() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + warmup + seconds + 0.05) {
            MainActor.assumeIsolated { self.finish() }
        }
    }

    /// Time `spin:` on the main worker to size the per-event work.
    @MainActor func calibrate() {
        let n = 200_000
        var best = Double.infinity
        for _ in 0..<5 {
            spawn(vm, vm.pointee.nilObj, rt.symbol("spin:"), mkInt(Int64(n)), priority: 2, main: true)
            let st = runMain(vm, budgetNs: 1_000_000_000)
            best = min(best, Double(st.ns) / Double(n))
        }
        spin50us = max(1, Int(50_000 / best))
        spin1ms = max(1, Int(1_000_000 / best))
        spin20us = max(1, Int(20_000 / best))
        // G4: Points allocated in ~100 us on the main thread.
        let m = 50_000
        var bestc = Double.infinity
        for _ in 0..<5 {
            spawn(vm, vm.pointee.nilObj, rt.symbol("churnBatch:"), mkInt(Int64(m)), priority: 2, main: true)
            let st = runMain(vm, budgetNs: 1_000_000_000)
            bestc = min(bestc, Double(st.ns) / Double(m))
        }
        churn100us = max(1, min(65_535, Int(100_000 / bestc)))
    }

    @MainActor func buildWindow() {
        let v = view!
        v.backgroundColor = .systemBackground
        let layer = CALayer()
        layer.frame = CGRect(x: 30, y: 90, width: 60, height: 60)
        layer.backgroundColor = UIColor.systemOrange.cgColor
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 1
        spin.repeatCount = .infinity
        layer.add(spin, forKey: "spin")
        v.layer.addSublayer(layer)
        // Moved by every display-link callback: something changes every
        // frame, so the display is not throttled below 120 Hz.
        mover = UIView(frame: CGRect(x: 0, y: 160, width: 12, height: 12))
        mover.backgroundColor = .systemBlue
        v.addSubview(mover)
        label = UILabel(frame: CGRect(x: 110, y: 100, width: 260, height: 24))
        label.font = .monospacedDigitSystemFont(ofSize: 18, weight: .regular)
        label.text = "\(scenarioId) (\(ys))"
        v.addSubview(label)
        slider = UISlider(frame: CGRect(x: 20, y: 190, width: 340, height: 30))
        slider.minimumValue = 0
        slider.maximumValue = 100
        slider.value = 42
        v.addSubview(slider)
        textView = UITextView(frame: CGRect(x: 20, y: 240, width: 340, height: 400))
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        v.addSubview(textView)
    }

    @MainActor func startLoad() {
        let s = ys
        let nilObj = vm.pointee.nilObj
        if s == "Y0" { return }
        if s.hasPrefix("Y5") {
            // Heavy main-thread allocation: R6's ~100 us of Point churn after
            // every event, background workers idle.
            spawn(vm, nilObj, rt.symbol("uiChurnLoop:"), mkInt(Int64(spin50us * 65536 + churn100us)), priority: uiPriority, main: true)
        } else {
            spawn(vm, nilObj, rt.symbol("uiLoop:"), mkInt(Int64(spin50us)), priority: uiPriority, main: true)
        }
        startEvents()
        if s.hasPrefix("Y4") {
            for w in 1...7 { spawn(vm, nilObj, rt.symbol("fragLoop:"), mkInt(Int64(w)), priority: 1) }
        } else if s == "Y6" {
            hostNewArrayInGlobal(vm, 256 * 8, global: 5)
            for _ in 1...8 { spawn(vm, nilObj, rt.symbol("shareLoop:"), mkInt(8), priority: 1) }
        } else if !s.hasPrefix("Y5") {
            for _ in 0..<7 { spawn(vm, nilObj, rt.symbol("allocLoop"), nilObj, priority: 1) }
        }
    }

    var footprint: [(Double, Int, UInt64)] = []
    var footprintTimer: DispatchSourceTimer?
    var workerBase: [(UInt64, UInt64, UInt64, UInt64)] = []

    var mainBase: [UInt64] = []
    var ycLogStart = 0
    var hsStart = 0
    var mainPauseStart = 0

    /// The main worker's attribution counters (SPEC.md "Scenarios").
    func mainCounters() -> [UInt64] {
        let m = rt.workers[0]
        var c: [UInt64] = [m.pointee.ownPauses, m.pointee.ownPauseNs, m.pointee.collWaits, m.pointee.collWaitNs,
                           m.pointee.stwWaitNs, m.pointee.ackOwn, m.pointee.ackOwnNs, m.pointee.ackOther, m.pointee.ackOtherNs,
                           m.pointee.parkedForOthersNs, m.pointee.parkedNs, m.pointee.resumeScans, m.pointee.ownPauseOpenNs]
        for k in 0..<16 { c.append(m.pointee.parkedByKind[k]) }
        return c
    }

    @MainActor func beginMeasure() {
        measuring = true
        mainBase = mainCounters()
        ycLogStart = vm.pointee.yc.log.pointee.count
        hsStart = vm.pointee.yc.hsLatency.pointee.count
        mainPauseStart = rt.workers[0].pointee.pauseSamples.pointee.count
        for m in Metric.allCases { metricsAtStart[m] = vm.metric(m) }
        // Read on the main thread while the workers run (a benign race on
        // aligned counters): the window's starting values.
        workerBase = rt.workers.map { ($0.pointee.storeRedo, $0.pointee.spinEpisodes, $0.pointee.spinNs, $0.pointee.hazardWaits) }
        let mStart = CACurrentMediaTime()
        let ft = DispatchSource.makeTimerSource(queue: .main)
        ft.schedule(deadline: .now(), repeating: .seconds(1))
        ft.setEventHandler { [unowned self] in
            MainActor.assumeIsolated {
                self.footprint.append(((CACurrentMediaTime() - mStart) * 1000, self.vm.pointee.heap.blocksInUse() * blockSize,
                                       self.vm.metric(.liveBytes)))
            }
        }
        ft.resume()
        footprintTimer = ft
        sampleStart = ["event": vm.pointee.eventLatency.pointee.count, "eventPost": vm.pointee.eventLatencyPost.pointee.count, "hop": vm.pointee.hopLatency.pointee.count,
                       "perHop": vm.pointee.mainPerHop.pointee.count, "ttsp": vm.pointee.gcTtsp.pointee.count,
                       "stw": vm.pointee.gcStw.pointee.count, "enter": vm.pointee.mainEnterWait.pointee.count]
        eventsStart = Double(eventsPosted)
        timerLate = []
        nativeLatency = []
        gcLogStart = vm.pointee.gcLog.pointee.count
        turns = 0; turnsUIOnly = 0; vmMainNs = 0; maxTurnNs = 0
        worstIter = 0
        labelUpdates = 0
    }

    // MARK: events

    @MainActor func startEvents() {
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .nanoseconds(0))
        let start = CACurrentMediaTime()
        let startTicks = ticks()
        let msTicks = nsToTicks(1_000_000)
        t.setEventHandler { [unowned self] in
            MainActor.assumeIsolated {
                // Catch up to exactly 1000/s. Each event is stamped with the
                // time it was due, as a window-server event carries the time
                // it happened, so latency includes time the main thread was
                // unavailable to the shell.
                let due = Int((CACurrentMediaTime() - start) * 1000)
                let nowT = ticks()
                if self.eventsPosted < due {
                    let firstDue = startTicks &+ UInt64(self.eventsPosted + 1) &* msTicks
                    if nowT > firstDue { self.timerLate.append(Double(ticksToNs(nowT &- firstDue)) / 1e6) }
                }
                var n = 0
                let hs = now()
                defer {
                    let hd = now() &- hs
                    if self.measuring && hd > self.timerHandlerMax { self.timerHandlerMax = hd }
                }
                while self.eventsPosted < due && n < 10_000 {
                    let stamp = startTicks &+ UInt64(self.eventsPosted + 1) &* msTicks
                    if self.native {
                        // S1n control: the same work done natively by the shell.
                        let t = ticks()
                        let until = t &+ nsToTicks(50_000)
                        while ticks() < until {}
                        self.labelValue &+= 1
                        self.label.text = String(self.labelValue)
                        self.nativeLatency.append(Double(ticksToNs(ticks() &- stamp)) / 1e6)
                    } else {
                        postEvent(self.vm, kind: 1, value: Int64(self.eventsPosted & 0xFFFF), wake: false, at: stamp)
                    }
                    self.eventsPosted += 1
                    n += 1
                }
                if self.native { return }
                if n > 0 { self.turn(.event) }
            }
        }
        t.resume()
        eventTimer = t
    }

    // MARK: turns

    @MainActor func turn(_ kind: TurnKind) {
        var budget: Int64
        var minPrio = 0
        if frameRemaining > 200_000 {
            budget = min(kind == .tick ? 3_000_000 : 1_000_000, frameRemaining)
        } else {
            budget = 500_000
            minPrio = uiPriority
            turnsUIOnly += 1
        }
        let st = runMain(vm, budgetNs: UInt64(budget), minPriority: minPrio)
        frameRemaining -= Int64(st.ns)
        turns += 1
        vmMainNs &+= st.ns
        iterVmNs &+= st.ns
        iterParkedNs &+= st.parkedNs
        iterEnterNs &+= st.enterWaitNs &+ st.leaveWaitNs
        iterTurns += 1
        if measuring && st.ns > maxTurnNs {
            maxTurnNs = st.ns
            maxTurnKind = "\(kind)"
            maxTurnParkedNs = st.parkedNs
            maxTurnEnterWaitNs = st.enterWaitNs &+ st.leaveWaitNs
        }
    }

    @objc func tick(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        if now >= measureStart && now <= measureEnd {
            frameTimes.append(l.timestamp)
            linkDurations.append(l.targetTimestamp - l.timestamp)
            callbackLate.append((now - l.timestamp) * 1000)
        }
        moverX = moverX >= 360 ? 0 : moverX + 3
        mover.frame.origin.x = moverX
        frameRemaining = frameAccountNs
        turn(.tick)
        let cs = VMR.now()
        checkStuck(vm, limitNs: 300_000_000)
        let csd = VMR.now() &- cs
        if measuring && csd > checkStuckMax { checkStuckMax = csd }
    }

    // MARK: hooks

    @MainActor func ui(_ kind: Int, _ value: Int64) -> Int64 {
        switch kind {
        case 0:
            labelValue = value
            labelUpdates += 1
            label.text = String(value)
            return value
        case 1:
            appendLine(String(value))
            return value
        default:
            return Int64(slider.value)
        }
    }

    @MainActor func appendLine(_ s: String) {
        lines.append(s)
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        textView.text = lines.joined(separator: "\n")
    }

    @MainActor func stuck(id: Int64, method: String, ms: Double, source: String) {
        let line = "STUCK process=\(id) method=\(method) ms=\(f2(ms)) via=\(source)"
        stuckReports.append(line)
        fputs(line + "\n", stderr)
        appendLine(line)
    }

    // MARK: run-loop observer and watchdog

    @MainActor func installObserver() {
        let obs = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault,
            CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [unowned self] _, act in
            MainActor.assumeIsolated {
                let t = now()
                if act == .afterWaiting {
                    self.iterStart = t
                    self.iterVmNs = 0; self.iterParkedNs = 0; self.iterEnterNs = 0; self.iterTurns = 0
                } else if self.iterStart != 0 {
                    let d = t &- self.iterStart
                    if self.measuring && d > self.worstIter {
                        self.worstIter = d
                        self.worstIterVm = self.iterVmNs
                        self.worstIterParked = self.iterParkedNs
                        self.worstIterEnter = self.iterEnterNs
                        self.worstIterTurns = self.iterTurns
                    }
                    self.iterStart = 0
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
        observer = obs
    }

    /// Off-main: reports a main-thread Process slice longer than 300 ms
    /// (the shell cannot, it does not have the thread); in S7 it terminates
    /// the hog 9 s into the measured window.
    @MainActor func startWatchdog() {
        let bits = UInt(bitPattern: vm)
        let killAt = now() + UInt64((warmup + 9.0) * 1e9)
        let kill = false
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        t.schedule(deadline: .now(), repeating: .milliseconds(10))
        t.setEventHandler(handler: watchdogHandler(bits: bits, killAt: killAt, kill: kill))
        t.resume()
        watchdog = t
    }

    // MARK: results

    /// Main-thread pause attribution over the window (SPEC.md "Scenarios"),
    /// ms. Wait (blocked on another thread) is kept apart from work.
    func mainAttribution() -> String {
        let c = mainCounters()
        func d(_ i: Int) -> UInt64 { c[i] &- (i < mainBase.count ? mainBase[i] : 0) }
        func ms(_ ns: UInt64) -> String { f3(Double(ns) / 1e6) }
        let mode = YoungMode.name(vm.pointee.ycConfig.mode)
        var o = " main_own_\(mode == "offload" ? "flips" : "collections")=\(d(0)) main_own_ms=\(ms(d(1)))"
        let ps = rt.workers[0].pointee.pauseSamples.pointee.values()
        let mine = ps[min(mainPauseStart, ps.count)...].map { Double($0) / 1e6 }
        o += " main_own_p50_ms=\(f3(pct(mine, 0.5))) main_own_p99_ms=\(f3(pct(mine, 0.99))) main_own_max_ms=\(f3(mine.max() ?? 0))"
        o += " main_own_open_ms=\(ms(d(12)))"
        o += " main_coll_waits=\(d(2)) main_coll_wait_ms=\(ms(d(3))) main_stw_pending_wait_ms=\(ms(d(4)))"
        o += " main_acks_own=\(d(5)) main_acks_own_ms=\(ms(d(6))) main_acks_other=\(d(7)) main_acks_other_ms=\(ms(d(8)))"
        o += " main_resume_scans=\(d(11))"
        // Stops by kind (main parked in them), and who requested scavenges.
        for k in 0..<7 {
            let n = d(13 + 8 + k), t = d(13 + k)
            if n > 0 { o += " main_stw_\(PauseKind.name(UInt8(k)))=\(n) main_stw_\(PauseKind.name(UInt8(k)))_ms=\(ms(t))" }
        }
        o += " main_parked_ms=\(ms(d(10)))"
        // Mine (own collection's work and waits) vs others'.
        let others = d(9) &+ d(8) &+ d(4)
        o += " main_stopped_for_others_ms=\(ms(others)) main_stw_scav_for_others_ms=\(ms(d(9)))"
        var cyc: UInt64 = 0
        for k in [PauseKind.full, PauseKind.initial, PauseKind.final, PauseKind.fallback, PauseKind.apply, PauseKind.verify] {
            cyc &+= d(13 + Int(k))
        }
        o += " main_oldspace_pauses_ms=\(ms(cyc))"
        // Every pause in the window by kind, and scavenges by requester.
        let recs = Array(vm.pointee.gcLog.pointee.records[min(gcLogStart, vm.pointee.gcLog.pointee.count)...])
        for k in 0..<7 {
            let rk = recs.filter { $0.kind == UInt8(k) }
            if rk.isEmpty { continue }
            let ts = rk.map { Double($0.totalNs) / 1e6 }
            o += " stw_\(PauseKind.name(UInt8(k)))_n=\(rk.count) stw_\(PauseKind.name(UInt8(k)))_max_ms=\(f3(ts.max() ?? 0)) stw_\(PauseKind.name(UInt8(k)))_p50_ms=\(f3(pct(ts, 0.5)))"
            o += " stw_\(PauseKind.name(UInt8(k)))_drainwait_max_ms=\(f3((rk.map { Double($0.drainWaitNs) / 1e6 }).max() ?? 0))"
        }
        let sc = recs.filter { $0.kind == PauseKind.scavenge }
        o += " stw_scav_by_main=\(sc.filter { $0.requester == 0 }.count) stw_scav_by_others=\(sc.filter { $0.requester != 0 }.count)"
        return o
    }

    @MainActor func finish() {
        eventTimer?.cancel()
        watchdog?.cancel()
        link?.invalidate()
        let maxFps = view.window?.windowScene?.screen.maximumFramesPerSecond ?? info.maxFps
        let nominal = 1.0 / Double(maxFps)
        // Gaps between consecutive frames, plus the window edges, so a main
        // thread held across the whole window shows as one long gap.
        let points = [measureStart] + frameTimes + [measureEnd]
        var gaps: [Double] = []
        for i in 1..<points.count { gaps.append(points[i] - points[i - 1]) }
        let drops = gaps.filter { $0 > 1.5 * nominal }
        let missed = drops.reduce(0) { $0 + max(0, Int(($1 / nominal).rounded()) - 1) }
        let rate = Double(frameTimes.count) / (measureEnd - measureStart)
        let gapsMs = gaps.map { $0 * 1000 }
        func d(_ m: Metric) -> UInt64 { vm.metric(m) &- (metricsAtStart[m] ?? 0) }
        var line = "part=C scenario=\(scenarioId) mac_scenario=\(ys) run=\(runN) bg=\(bg) seconds=\(seconds) verify=0 build_wait_s=\(f2(buildWaitS))"
        line += " battery=\(info.battery) battery_level=\(f2(Double(info.batteryLevel))) low_power=\(info.lowPower ? 1 : 0) cores=\(info.cores) thermal_start=\(thermalStart)"
        line += " nominal_hz=\(f2(1 / nominal)) refresh_hz=\(f2(rate)) frames=\(frameTimes.count)"
        line += " drops=\(drops.count) missed=\(missed)"
        // The 120 Hz frame budget of the brief, whatever the display runs at
        // (the experiment ran on a 165 Hz external display): gaps longer than
        // 1.5 x 8.33 ms, counted in 8.33 ms frames.
        let p120 = 1.0 / 120
        let drops120 = gaps.filter { $0 > 1.5 * p120 }
        let missed120 = drops120.reduce(0) { $0 + max(0, Int(($1 / p120).rounded()) - 1) }
        line += " drops120=\(drops120.count) missed120=\(missed120)"
        line += " gap_p50_ms=\(f3(pct(gapsMs, 0.5))) gap_p99_ms=\(f3(pct(gapsMs, 0.99))) gap_max_ms=\(f3(gapsMs.max() ?? 0))"
        line += " cb_late_p50_ms=\(f3(pct(callbackLate, 0.5))) cb_late_p99_ms=\(f3(pct(callbackLate, 0.99))) cb_late_max_ms=\(f3(callbackLate.max() ?? 0))"
        line += " link_duration_ms=\(f3(pct(linkDurations, 0.5) * 1000))"
        line += " worst_iter_ms=\(f3(Double(worstIter) / 1e6)) worst_iter_vm_ms=\(f3(Double(worstIterVm) / 1e6))"
        line += " worst_iter_gcpark_ms=\(f3(Double(worstIterParked) / 1e6)) worst_iter_gcenter_ms=\(f3(Double(worstIterEnter) / 1e6)) worst_iter_turns=\(worstIterTurns)"
        line += " max_turn_ms=\(f3(Double(maxTurnNs) / 1e6)) max_turn_kind=\(maxTurnKind) max_turn_gcpark_ms=\(f3(Double(maxTurnParkedNs) / 1e6)) max_turn_gcenter_ms=\(f3(Double(maxTurnEnterWaitNs) / 1e6))"
        line += " turns=\(turns) ui_only_turns=\(turnsUIOnly) vm_main_ms=\(f2(Double(vmMainNs) / 1e6))"
        line += " checkstuck_max_ms=\(f3(Double(checkStuckMax) / 1e6)) timer_handler_max_ms=\(f3(Double(timerHandlerMax) / 1e6))"
        let ev = samplesMs(vm.pointee.eventLatency, from: sampleStart["event"] ?? 0)
        if !ev.isEmpty {
            line += " events_posted=\(eventsPosted - Int(eventsStart)) events_handled=\(ev.count)"
            line += " ev_lat_p50_ms=\(f3(pct(ev, 0.5))) ev_lat_p99_ms=\(f3(pct(ev, 0.99))) ev_lat_max_ms=\(f3(ev.max() ?? 0))"
            let evp = samplesMs(vm.pointee.eventLatencyPost, from: sampleStart["eventPost"] ?? 0)
            line += " ev_post_lat_p50_ms=\(f3(pct(evp, 0.5))) ev_post_lat_p99_ms=\(f3(pct(evp, 0.99))) ev_post_lat_max_ms=\(f3(evp.max() ?? 0))"
        }
        if !timerLate.isEmpty || native {
            line += " timer_late_p50_ms=\(f3(pct(timerLate, 0.5))) timer_late_p99_ms=\(f3(pct(timerLate, 0.99))) timer_late_max_ms=\(f3(timerLate.max() ?? 0)) timer_late_n=\(timerLate.count)"
        }
        if native {
            line += " events_posted=\(eventsPosted - Int(eventsStart)) native_lat_p50_ms=\(f3(pct(nativeLatency, 0.5))) native_lat_p99_ms=\(f3(pct(nativeLatency, 0.99))) native_lat_max_ms=\(f3(nativeLatency.max() ?? 0))"
        }
        line += " label_updates=\(labelUpdates) stuck_reports=\(stuckReports.count + (watchdogReported.load(ordering: .relaxed) ? 1 : 0))"
        line += " spin50us=\(spin50us) spin1ms=\(spin1ms)"
        line += " preemptions=\(d(.preemptions)) gc_count=\(d(.gcCount)) overflows=\(d(.overflows)) forks=\(d(.forks))"
        let enter = samplesMs(vm.pointee.mainEnterWait, from: sampleStart["enter"] ?? 0)
        line += " main_enter_waits=\(enter.count) main_enter_wait_max_ms=\(f3(enter.max() ?? 0))"
        footprintTimer?.cancel()
        line += " churn100us=\(churn100us) " + gcSummary(vm, from: gcLogStart)
        line += relocSummary(vm, rt, from: gcLogStart, base: metricsAtStart, workerBase: workerBase)
        line += ycSummary(vm, rt, wallMs: seconds * 1000, from: ycLogStart, hsFrom: hsStart)
        line += mainAttribution()
        line += " verifyFailures=\(vm.metric(.verifyFailures)) youngVerifyRuns=\(vm.metric(.youngVerifyRuns)) relocVerifyRuns=\(vm.metric(.relocVerifyRuns))"
        line += " screen=iPhone screen_max_fps=\(maxFps)"
        let mb = 1048576.0
        line += " footprint=" + footprint.map { "\(Int($0.0)):\(f2(Double($0.1) / mb)):\(f2(Double($0.2) / mb))" }.joined(separator: ",")
        dumpPauses(vm, prefix: "scenario=\(scenarioId) run=\(runN)", from: gcLogStart)
        line += " sched_locks=\(d(.schedLocks)) sched_contended=\(d(.schedContended)) sched_wait_ms=\(f3(Double(d(.schedWaitNs)) / 1e6))"
        line += " idle_ms=\(f2(Double(d(.idleNs)) / 1e6)) rss_mb=\(f2(Double(currentRSS()) / 1048576))"
        line += " thermal_end=\(Telemetry.thermal())" + Telemetry.suffix()
        Output.shared.emit(line)
        Output.shared.emit("DONE")
        usleep(200_000)
        exit(0)
    }
}

