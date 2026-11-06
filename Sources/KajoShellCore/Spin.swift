import Darwin
import Dispatch
import Foundation
import KajoAppDevelopment

/// `mode=spin threads=N cpums=M qos=userInitiated|userInteractive|utility
/// settle=1`: a known workload for the energy counters (the devices
/// investigation of 2026-11-06): N threads at the QoS asked, each running
/// an integer loop until its own CPU time reaches M ms, after `settle`
/// seconds of quiet. One result line: what `ri_energy_nj` and the rest of
/// the process's rusage say over the run, and each thread's CPU, share on
/// performance cores, energy, clock and IPC from its per-thread counts
/// (proc_pidinfo flavor 34) and the priority it got. No VM runs.
public func runSpin(_ options: LaunchOptions) {
    let n = max(1, min(16, options.int("threads", 1)))
    let cpuNs = UInt64(max(1, options.int("cpums", 2000))) * 1_000_000
    let qosName = options.string("qos", "userInitiated")
    let qos: QualityOfService = switch qosName {
    case "userInteractive": .userInteractive
    case "utility": .utility
    case "background": .background
    case "default": .default
    default: .userInitiated
    }
    usleep(UInt32(max(0, options.double("settle", 1)) * 1e6))
    let thermalStart = Telemetry.thermal()
    let box = SpinResults(n)
    let done = DispatchSemaphore(value: 0)
    let u0 = ProcessUsage.now()
    let e0 = Telemetry.energyNj()
    let wall0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    for i in 0..<n {
        let t = Thread {
            let tid = Telemetry.threadID()
            let c0 = ThreadCounts.of(tid)
            let w0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            var x: UInt64 = UInt64(i) &+ 1
            while clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- start < cpuNs {
                for _ in 0..<100_000 { x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }
            }
            let pri = ThreadPriority.of(tid)
            let c = ThreadCounts.of(tid).since(c0)
            box.set(i, SpinResult(counts: c, wallNs: clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- w0, priority: pri, sink: x))
            done.signal()
        }
        t.qualityOfService = qos
        t.stackSize = 1 << 20
        t.start()
    }
    for _ in 0..<n { done.wait() }
    let wallNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- wall0
    let u1 = ProcessUsage.now()
    let e1 = Telemetry.energyNj()
    let results = box.all
    var total = ThreadCounts(ok: true)
    for r in results { total = total + r.counts }
    var line = "threads=\(n) cpums=\(cpuNs / 1_000_000) qos=\(qosName) thermal_start=\(thermalStart) wall_ms=\(f1(Double(wallNs) / 1e6))"
    if let e0, let e1 {
        line += " energy_mj=\(f1(Double(e1 &- e0) / 1e6)) power_w=\(f3(Double(e1 &- e0) / Double(wallNs)))"
    }
    line += u1.fields(since: u0) + total.fields("spin")
    // Each thread: cpu ms : P share : mJ : P GHz : E GHz : IPC on P : base/current priority.
    line += " per_thread=" + results.map { r in
        let c = r.counts, tot = c.pCpuNs &+ c.eCpuNs
        let pg = c.pCpuNs > 1_000_000 ? f2(Double(c.pCycles) / Double(c.pCpuNs)) : "0"
        let eg = c.eCpuNs > 1_000_000 ? f2(Double(c.eCycles) / Double(c.eCpuNs)) : "0"
        let ipc = c.pCycles > 0 ? f2(Double(c.pInstr) / Double(c.pCycles)) : "0"
        return "\(f1(Double(tot) / 1e6)):\(f3(tot > 0 ? Double(c.pCpuNs) / Double(tot) : 0)):\(f1(Double(c.pEnergyNj &+ c.eEnergyNj) / 1e6)):\(pg):\(eg):\(ipc):\(r.priority.base)/\(r.priority.current)"
    }.joined(separator: ",")
    line += " per_thread_wall_ms=" + results.map { f1(Double($0.wallNs) / 1e6) }.joined(separator: ",")
    line += " sink=\(results.reduce(UInt64(0)) { $0 ^ $1.sink } & 0xff) thermal_end=\(Telemetry.thermal())"
    Output.shared.emit(resultLine("spin", options, line))
}

struct SpinResult: Sendable {
    var counts = ThreadCounts()
    var wallNs: UInt64 = 0
    var priority = ThreadPriority()
    var sink: UInt64 = 0
}

final class SpinResults: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [SpinResult]
    init(_ n: Int) { results = Array(repeating: SpinResult(), count: n) }
    func set(_ i: Int, _ r: SpinResult) { lock.lock(); results[i] = r; lock.unlock() }
    var all: [SpinResult] { lock.lock(); defer { lock.unlock() }; return results }
}
