// Parts 2 and 3 (SPEC.md): the main worker on the main thread, driven by a
// 120 Hz CADisplayLink as a shell would drive it (device-measurement's
// Scenario.swift is the model: a view moved every callback so ProMotion
// does not throttle, frames counted from the link's timestamps).
//
// Part 2: every tick runs one `pwFrame:` turn whose size comes from the
// Pacer (rate MB/s of PPoints, 10 percent kept) plus 64 oldheap mutation
// iterations (256 every 120th frame: one group replaced per second).
// Part 3 modes: novm (no VM at all), parked (VM up, no link), link (link and
// mover, the VM never entered), tick (link, mover, an empty VM turn),
// tickalloc (tick plus Part 2's frame at `rate`).
//
// The measured window starts `warmup` seconds after the link starts and
// lasts `seconds`; process, per-thread and per-core-type telemetry are
// sampled at both ends on the main thread.

import Darwin
import Kasm
import PowerKit
import PowerVM
import QuartzCore
import UIKit
import VMR

func pct(_ xs: [Double], _ p: Double) -> Double {
    if xs.isEmpty { return 0 }
    let s = xs.sorted()
    return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
}
func f3(_ x: Double) -> String { String(format: "%.3f", x) }
func f2(_ x: Double) -> String { String(format: "%.2f", x) }

@MainActor
final class PowerController: UIViewController {
    let opts: Options
    let info: LaunchInfo
    let part: String
    let mode: String
    let rateMB: Double
    let seconds: Double
    let warmup: Double
    let percent: Int
    var session: Session?
    var link: CADisplayLink?
    var mover: UIView!
    var moverX: CGFloat = 0
    var label: UILabel!
    var pacer: Pacer
    var thermalStart = ""
    var mainTid: UInt64 = 0

    // window
    var measuring = false
    var measureStart = 0.0
    var measureEnd = 0.0
    var frameTimes: [Double] = []
    var turnMs: [Double] = []
    var parkedMs: [Double] = []
    var tickCount = 0
    var oldHWM = 0
    var u0 = ProcUsage()
    var ts0: [UInt64: ThreadSample] = [:]
    var tc0: [String: ThreadCounts] = [:]
    var gcLogStart = 0
    var ycLogStart = 0
    var hsStart = 0
    var mainPauseStart = 0
    var points0 = 0
    var mut0 = 0
    var metrics0: [Metric: UInt64] = [:]
    var setupMs = 0.0

    init(_ o: Options, info: LaunchInfo) {
        opts = o
        self.info = info
        part = o["part"] ?? "2"
        mode = part == "2" ? "alloc" : (o["mode"] ?? "parked")
        rateMB = o.double("rate", 2)
        seconds = o.double("seconds", part == "2" ? 30 : 60)
        warmup = o.double("warmup", 3)
        percent = o.int("pct", 10)
        // Bytes the mutation churns per second (64 OHPoints per frame plus
        // a 256-iteration frame per second) are taken from the target so
        // the total allocation is `rate`.
        let churn = (64.0 * 119 + 256) * Double(pointBodyBytes)
        pacer = Pacer(bytesPerSecond: max(0, o.double("rate", 2) * 1048576 - churn), objectBytes: pointBodyBytes)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    var usesVM: Bool { mode != "novm" }
    var usesLink: Bool { mode != "novm" && mode != "parked" }
    var allocates: Bool { mode == "alloc" || mode == "tickalloc" }

    override func viewDidLoad() {
        super.viewDidLoad()
        let v = view!
        v.backgroundColor = .systemBackground
        label = UILabel(frame: CGRect(x: 20, y: 100, width: 360, height: 60))
        label.numberOfLines = 2
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.text = "power part=\(part) mode=\(mode) rate=\(rateMB)"
        v.addSubview(label)
        mover = UIView(frame: CGRect(x: 0, y: 180, width: 12, height: 12))
        mover.backgroundColor = .systemBlue
        v.addSubview(mover)
    }

    var started = false
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if started { return }
        started = true
        DispatchQueue.main.async { MainActor.assumeIsolated { self.start() } }
    }

    func start() {
        mainTid = ThreadCPU.selfId()
        if usesVM {
            var c = SessionConfig()
            c.oldheapMB = opts.int("oldheap", 200)
            c.heapMB = opts.int("heap", 768)
            c.nurseryKB = opts.int("nursery", 4096)
            c.background = opts.int("bg", part == "3" ? 5 : 0)
            do {
                session = try Session(c)
                setupMs = session!.setupMs
            } catch {
                Output.shared.emit(info.head + " FAILED=1 error=session_\(String(describing: error).replacingOccurrences(of: " ", with: "_"))")
                exit(1)
            }
        }
        thermalStart = Telemetry.thermal()
        if usesLink {
            let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            l.add(to: .main, forMode: .common)
            link = l
        }
        let t = CACurrentMediaTime()
        measureStart = t + warmup
        measureEnd = measureStart + seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + warmup) { MainActor.assumeIsolated { self.begin() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + warmup + seconds) { MainActor.assumeIsolated { self.finish() } }
    }

    /// The VM threads to account separately, by role.
    func roles() -> [String: [UInt64]] {
        var r: [String: [UInt64]] = ["main": [mainTid]]
        if let s = session {
            r["coll"] = s.threads.collector
            r["marker"] = s.threads.markers
            r["bg"] = s.threads.background
        }
        return r
    }

    func begin() {
        if let s = session {
            let vm = s.vm
            gcLogStart = vm.pointee.gcLog.pointee.count
            ycLogStart = vm.pointee.yc.log.pointee.count
            hsStart = vm.pointee.yc.hsLatency.pointee.count
            mainPauseStart = s.rt.workers[0].pointee.pauseSamples.pointee.count
            for m in Metric.allCases { metrics0[m] = vm.metric(m) }
            points0 = s.pointsAllocated
            mut0 = s.mutationIters
            oldHWM = s.oldBytes
        }
        tc0 = [:]
        for (k, ids) in roles() { tc0[k] = ThreadCounts.sum(ids.map { ThreadCounts.of($0) }) }
        ts0 = ThreadCPU.snapshot()
        frameTimes = []; turnMs = []; parkedMs = []
        measuring = true
        u0 = ProcUsage.now()
    }

    @objc func tick(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        if measuring { frameTimes.append(l.timestamp) }
        moverX = moverX >= 360 ? 0 : moverX + 3
        mover.frame.origin.x = moverX
        tickCount += 1
        guard let s = session, mode != "link" else { return }
        let st: TurnStats
        if allocates {
            let n = pacer.due(at: now)
            st = s.frame(points: n, mutation: tickCount % 120 == 0 ? 256 : 64, percent: percent)
        } else {
            st = s.emptyFrame()
        }
        if measuring {
            turnMs.append(Double(st.ns) / 1e6)
            parkedMs.append(Double(st.parkedNs) / 1e6)
            oldHWM = max(oldHWM, s.oldBytes)
        }
    }

    func finish() {
        let u1 = ProcUsage.now()
        measuring = false
        let ts1 = ThreadCPU.snapshot()
        var tc1: [String: ThreadCounts] = [:]
        let rl = roles()
        for (k, ids) in rl { tc1[k] = ThreadCounts.sum(ids.map { ThreadCounts.of($0) }) }
        link?.invalidate()
        var line = info.head + " mode=\(mode) seconds=\(seconds) warmup=\(warmup) setup_ms=\(f2(setupMs))"
        for k in ["KAJO_GC", "KAJO_YOUNG", "KAJO_YC_QOS", "KAJO_CM_QOS", "KAJO_AGE"] {
            line += " env_\(k)=\(getenv(k).map { String(cString: $0) } ?? "-")"
        }
        line += " cfg=\(opts["cfg"] ?? "-") rate_mb_s=\(rateMB) pct=\(percent)"
        // Frames: gaps between link timestamps (plus the window edges).
        if usesLink {
            let points = [measureStart] + frameTimes + [measureEnd]
            var gaps: [Double] = []
            for i in 1..<points.count { gaps.append(points[i] - points[i - 1]) }
            let p120 = 1.0 / 120
            let drops = gaps.filter { $0 > 1.5 * p120 }
            let missed = drops.reduce(0) { $0 + max(0, Int(($1 / p120).rounded()) - 1) }
            let gapsMs = gaps.map { $0 * 1000 }
            line += " frames=\(frameTimes.count) refresh_hz=\(f2(Double(frameTimes.count) / seconds)) drops120=\(drops.count) missed120=\(missed)"
            line += " gap_p50_ms=\(f3(pct(gapsMs, 0.5))) gap_p99_ms=\(f3(pct(gapsMs, 0.99))) gap_max_ms=\(f3(gapsMs.max() ?? 0))"
            line += " turn_p50_ms=\(f3(pct(turnMs, 0.5))) turn_p99_ms=\(f3(pct(turnMs, 0.99))) turn_max_ms=\(f3(turnMs.max() ?? 0))"
            line += " turn_total_ms=\(f2(turnMs.reduce(0, +))) parked_total_ms=\(f3(parkedMs.reduce(0, +))) parked_max_ms=\(f3(parkedMs.max() ?? 0))"
        }
        if let s = session {
            let vm = s.vm
            let pts = s.pointsAllocated - points0, mut = s.mutationIters - mut0
            let allocMB = Double((pts + mut) * pointBodyBytes) / 1048576
            line += " bg=\(s.config.background) oldheap_mb=\(s.config.oldheapMB) heap_mb=\(s.config.heapMB)"
            line += " points=\(pts) mut_iters=\(mut) alloc_mb=\(f3(allocMB)) alloc_mb_s=\(f3(allocMB / seconds)) pacer_capped=\(pacer.capped)"
            line += " old_hwm_mb=\(f2(Double(oldHWM) / 1048576)) old_end_mb=\(f2(Double(s.oldBytes) / 1048576))"
            func d(_ m: Metric) -> UInt64 { vm.metric(m) &- (metrics0[m] ?? 0) }
            line += " d_scavenges=\(d(.scavenges)) d_fulls=\(d(.fullGCs)) d_yc=\(d(.ycCollections)) d_cm_cycles=\(d(.cmCycles)) d_cm_fallbacks=\(d(.cmFallbacks))"
            line += " d_young_mb=\(f3(Double(d(.youngBytes)) / 1048576)) d_promoted_mb=\(f3(Double(d(.promotedBytes)) / 1048576))"
            let ps = s.rt.workers[0].pointee.pauseSamples.pointee.values()
            let mine = ps[min(mainPauseStart, ps.count)...].map { Double($0) / 1e6 }
            line += " main_own_n=\(mine.count) main_own_p50_ms=\(f3(pct(mine, 0.5))) main_own_p99_ms=\(f3(pct(mine, 0.99))) main_own_max_ms=\(f3(mine.max() ?? 0))"
            line += " vm_threads=coll:\(s.threads.collector.count),marker:\(s.threads.markers.count),bg:\(s.threads.background.count),unexpected:\(s.threads.unexpected.count)"
            line += " " + gcSummary(vm, from: gcLogStart)
            line += ycSummary(vm, s.rt, wallMs: seconds * 1000, from: ycLogStart, hsFrom: hsStart)
        }
        // Per role: CPU from thread_info (all levels) and the core-type split.
        for k in ["main", "coll", "marker", "bg"] {
            guard let ids = rl[k] else { continue }
            let cpu = ThreadCPU.cpuDelta(ts0, ts1, ids)
            line += " \(k)_cpu_thread_ms=\(f3(Double(cpu) / 1e6))"
            if let a = tc0[k], let b = tc1[k] { line += ThreadCounts.delta(a, b).fields(k) }
        }
        // Every thread that ran in the window: role or name/priority, CPU ms.
        var known: [UInt64: String] = [:]
        for (k, ids) in rl { for (i, t) in ids.enumerated() { known[t] = ids.count > 1 ? "\(k)\(i + 1)" : k } }
        var parts: [String] = []
        var otherMs = 0.0
        for (tid, b) in ts1.sorted(by: { $0.key < $1.key }) {
            let a = ts0[tid]?.cpuNs ?? 0
            let ms = Double(b.cpuNs &- a) / 1e6
            if ms < 0.01 { continue }
            let name = known[tid] ?? ("t" + (b.name.isEmpty ? "" : "[" + b.name.replacingOccurrences(of: " ", with: "_") + "]") + "/p\(b.curPri)")
            if known[tid] == nil { otherMs += ms }
            parts.append("\(name):\(f3(ms))")
        }
        line += " other_cpu_ms=\(f3(otherMs)) threads=\(parts.joined(separator: ","))"
        line += " thread_count=\(ts1.count)"
        line += UsageDelta(u0, u1).line
        line += " " + Telemetry.battery() + Telemetry.suffix()
        Output.shared.emit(line)
        Output.shared.emit("DONE")
        usleep(200_000)
        exit(0)
    }
}
