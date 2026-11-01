// kajo-ui <R0..R6|R5n> [--seconds 10] [--warmup 1] [--out file] [--verify]
//
// Copied from ../concurrent-marking (window, frame measurement, turns and
// frame account unchanged); the scenarios are this experiment's R0..R6 and
// R5n (SPEC.md "Scenarios"). R4 first waits until the 256 MiB old heap is
// built, then warms up. `--verify` turns on every verifier (mark sets at
// each final mark, relocation at every pause). Footprint (old space in use,
// live bytes) is sampled once per second. One window, one animated layer, a label, a text
// view, a slider. The Smalltalk UI Process runs synchronously on the main
// thread in budgeted turns; a CADisplayLink records every frame. Prints one
// key=value line and appends it to --out.

import AppKit
import Darwin
import Kasm
import QuartzCore
import Synchronization
import VMR

// MARK: - arguments

struct Options {
    var scenario = "R0"
    var seconds = 10.0
    var warmup = 1.0
    var out: String? = nil
    var run = 0
    var verify = false
}

func parseOptions() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    if let s = args.first, s.hasPrefix("R") { o.scenario = s; args.removeFirst() }
    var i = 0
    while i < args.count {
        let a = args[i], v = i + 1 < args.count ? args[i + 1] : ""
        switch a {
        case "--seconds": o.seconds = Double(v) ?? o.seconds; i += 1
        case "--warmup": o.warmup = Double(v) ?? o.warmup; i += 1
        case "--out": o.out = v; i += 1
        case "--run": o.run = Int(v) ?? 0; i += 1
        case "--verify": o.verify = true
        default: fputs("unknown argument \(a)\n", stderr); exit(1)
        }
        i += 1
    }
    return o
}

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
            Controller.shared?.turn(.wake)
        }
    }
}

let uiHook: UIHook = { _, kind, value in
    MainActor.assumeIsolated { Controller.shared?.ui(kind, value) ?? 0 }
}

let stuckHook: StuckHook = { _, id, sel, ms in
    let name = String(cString: sel)
    MainActor.assumeIsolated { Controller.shared?.stuck(id: id, method: name, ms: ms, source: "shell") }
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
final class Controller: NSObject, NSApplicationDelegate {
    static var shared: Controller?

    let opt: Options
    var rt: Runtime!
    var vm: VMRef { rt.vm }
    var window: NSWindow!
    var label: NSTextField!
    var textView: NSTextView!
    var slider: NSSlider!
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

    init(_ o: Options) { opt = o; super.init() }

    // MARK: setup

    func applicationDidFinishLaunching(_ notification: Notification) {
        start()
    }

    @MainActor func start() {
        Controller.shared = self
        do {
            // SPEC.md "Scenarios": 4 MiB nurseries throughout; R4 loads
            // oldheap at 256 MiB live with a 576 MiB soft limit, R5/R5n
            // fragment with 512 MiB.
            let s = opt.scenario
            let big = oldHeap
            let frag = s.hasPrefix("R5")
            let src = try appSources(oldheap: big ? 256 : nil, fragment: frag)
            let img = try Image.fromSources(src, heapSize: (big ? 576 : frag ? 512 : 64) << 20, nurseryBytes: 4 << 20)
            var cfg = cmConfigFromEnv()
            cfg.concurrent = true
            cfg.ageN = s == "R1" ? 1 : 2
            cfg.relocThreshold = ["R0", "R3", "R5", "R6"].contains(s) ? 50 : s == "R4" ? 101 : 0
            if s == "R4" { cfg.force = true; cfg.threshold = 0 }
            // R5/R5n: cycles from 30 percent of 512 MiB, so the paced
            // fragment load (about 40 MB/s promoted) starts them early in
            // the window.
            if frag { cfg.threshold = 0.30 }
            cfg.verify = opt.verify
            rt = Runtime(img, background: 7, config: cfg)
        } catch {
            fputs("load failed: \(error)\n", stderr); exit(1)
        }
        vm.pointee.wakeMain = wakeHook
        vm.pointee.uiHook = uiHook
        vm.pointee.stuckHook = stuckHook
        calibrate()
        buildWindow()
        startLoad()
        if oldHeap {
            // Wait (run loop running, window animating) until every worker
            // built its share of the old heap.
            let tb = CACurrentMediaTime()
            while hostCountNonNil(vm, global: 12) < 7 {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
                if CACurrentMediaTime() - tb > 120 { fputs("old heap not built\n", stderr); exit(1) }
            }
            buildWaitS = CACurrentMediaTime() - tb
        }
        t0 = CACurrentMediaTime()
        measureStart = t0 + opt.warmup
        measureEnd = measureStart + opt.seconds
        let l = window.contentView!.displayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
        installObserver()
        startWatchdog()
        DispatchQueue.main.asyncAfter(deadline: .now() + opt.warmup) { MainActor.assumeIsolated { self.beginMeasure() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + opt.warmup + opt.seconds + 0.05) {
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
        let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 320),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "kajo-ui \(opt.scenario)"
        let v = NSView(frame: w.contentRect(forFrameRect: w.frame))
        v.wantsLayer = true
        let layer = CALayer()
        layer.frame = CGRect(x: 30, y: 220, width: 60, height: 60)
        layer.backgroundColor = NSColor.systemOrange.cgColor
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 1
        spin.repeatCount = .infinity
        layer.add(spin, forKey: "spin")
        v.layer!.addSublayer(layer)
        label = NSTextField(labelWithString: "0")
        label.frame = NSRect(x: 120, y: 240, width: 330, height: 24)
        label.font = .monospacedDigitSystemFont(ofSize: 18, weight: .regular)
        v.addSubview(label)
        slider = NSSlider(value: 42, minValue: 0, maxValue: 100, target: nil, action: nil)
        slider.frame = NSRect(x: 120, y: 200, width: 330, height: 24)
        v.addSubview(slider)
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 20, width: 440, height: 160))
        textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        v.addSubview(scroll)
        w.contentView = v
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    var oldHeap: Bool { opt.scenario == "R4" }

    @MainActor func startLoad() {
        let s = opt.scenario
        let nilObj = vm.pointee.nilObj
        if s == "R0" { return }
        if s == "R6" {
            spawn(vm, nilObj, rt.symbol("uiChurnLoop:"), mkInt(Int64(spin50us * 65536 + churn100us)), priority: uiPriority, main: true)
        } else {
            spawn(vm, nilObj, rt.symbol("uiLoop:"), mkInt(Int64(spin50us)), priority: uiPriority, main: true)
        }
        startEvents()
        if oldHeap {
            hostNewArrayInGlobal(vm, 7, global: 12)
            for w in 1...7 { spawn(vm, nilObj, rt.symbol("ohLoop:"), mkInt(Int64(w)), priority: 1) }
        } else if s.hasPrefix("R5") {
            for w in 1...7 { spawn(vm, nilObj, rt.symbol("fragLoop:"), mkInt(Int64(w)), priority: 1) }
        } else {
            for _ in 0..<7 { spawn(vm, nilObj, rt.symbol("allocLoop"), nilObj, priority: 1) }
        }
    }

    var footprint: [(Double, Int, UInt64)] = []
    var footprintTimer: DispatchSourceTimer?
    var workerBase: [(UInt64, UInt64, UInt64, UInt64)] = []

    @MainActor func beginMeasure() {
        measuring = true
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
                        self.label.stringValue = String(self.labelValue)
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
            label.stringValue = String(value)
            return value
        case 1:
            appendLine(String(value))
            return value
        default:
            return Int64(slider.doubleValue)
        }
    }

    @MainActor func appendLine(_ s: String) {
        let storage = textView.textStorage!
        storage.append(NSAttributedString(string: s + "\n"))
        let text = storage.string
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 200 {
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length),
                                      with: lines.suffix(200).joined(separator: "\n"))
        }
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
        let killAt = now() + UInt64((opt.warmup + 9.0) * 1e9)
        let kill = false
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        t.schedule(deadline: .now(), repeating: .milliseconds(10))
        t.setEventHandler(handler: watchdogHandler(bits: bits, killAt: killAt, kill: kill))
        t.resume()
        watchdog = t
    }

    // MARK: results

    @MainActor func finish() {
        eventTimer?.cancel()
        watchdog?.cancel()
        link?.invalidate()
        let nominal = 1.0 / Double(window.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60)
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
        var line = "scenario=\(opt.scenario) run=\(opt.run) seconds=\(opt.seconds) verify=\(opt.verify ? 1 : 0) build_wait_s=\(f2(buildWaitS))"
        line += " nominal_hz=\(f2(1 / nominal)) refresh_hz=\(f2(rate)) frames=\(frameTimes.count)"
        line += " drops=\(drops.count) missed=\(missed)"
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
        let mb = 1048576.0
        line += " footprint=" + footprint.map { "\(Int($0.0)):\(f2(Double($0.1) / mb)):\(f2(Double($0.2) / mb))" }.joined(separator: ",")
        dumpPauses(vm, prefix: "scenario=\(opt.scenario) run=\(opt.run)", from: gcLogStart)
        line += " sched_locks=\(d(.schedLocks)) sched_contended=\(d(.schedContended)) sched_wait_ms=\(f3(Double(d(.schedWaitNs)) / 1e6))"
        line += " idle_ms=\(f2(Double(d(.idleNs)) / 1e6)) rss_mb=\(f2(Double(currentRSS()) / 1048576))"
        print(line)
        fflush(stdout)
        if let path = opt.out, let f = fopen(path, "a") {
            fputs(line + "\n", f)
            fclose(f)
        }
        exit(0)
    }
}

// MARK: - main

let options = parseOptions()
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = Controller(options)
app.delegate = controller
app.run()
