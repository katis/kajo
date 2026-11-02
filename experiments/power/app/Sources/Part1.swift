// Part 1 (SPEC.md "Part 1"): entry-locality's walk on the object table
// (VMB, workers at user-initiated QoS) and the chase, each beside an
// optional companion thread, with process energy over the run, the
// companion's own CPU time and energy, and the energy check of `hello`.

import Darwin
import Kasm
import PowerKit
import UIKit
import VMB

func companion(_ name: String) -> Companion? {
    switch name {
    case "spin": return Companion(.spin)
    case "spinut": return Companion(.spin, qos: QOS_CLASS_UTILITY)
    case "wfe": return Companion(.wfe)
    case let s where s.hasPrefix("t"):
        guard let hz = Int(s.dropFirst()), hz > 0 else { return nil }
        return Companion(.timer(hz: hz))
    default: return nil
    }
}

func runWalk(_ opt: Options) -> String {
    kernelFlavor = .objectRepresentation
    let kernel = opt["kernel"] ?? "walk22x4"
    let workers = opt.int("workers", 1)
    let compName = opt["comp"] ?? "none"
    let c = companion(compName)
    usleep(20_000)
    let u0 = ProcUsage.now()
    var line: String
    do {
        line = try VMB.benchLine(kernel: kernel, workers: workers, snapshotDir: NSTemporaryDirectory())
    } catch {
        line = "FAILED=1 kernel=\(kernel) error=\(String(describing: error).replacingOccurrences(of: " ", with: "_"))"
    }
    let u1 = ProcUsage.now()
    let r = c?.finish()
    let reps = sizedWalk(kernel).map { $0.2 } ?? 0
    let n = sizedWalk(kernel).map { $0.1 } ?? 0
    return "variant=B comp_cfg=\(compName) reps=\(reps) log2n=\(n) " + line + UsageDelta(u0, u1).line + Companion.fields(c, r)
}

func runChasePart(_ opt: Options) -> String {
    let size = opt.int("size", 256)
    let hops = opt.int("hops", 1 << 25)
    let compName = opt["comp"] ?? "none"
    let c = companion(compName)
    usleep(20_000)
    let res = runChase(sizeMB: size, hops: hops)
    let r = c?.finish()
    let f = { (x: Double) in "\((x * 100).rounded() / 100)" }
    return "mode=chase comp_cfg=\(compName) size_mb=\(size) nodes=\(res.nodes) hops=\(hops) ns_hop=\(f(res.nsPerHop))"
        + " build_ms=\(f(Double(res.buildNs) / 1e6)) hop_ms=\(f(Double(res.hopNs) / 1e6)) sink=\(res.sink & 1)"
        + res.usage.line + Companion.fields(c, r)
}

/// The energy readout check: is ri_energy_nj populated, and does it grow
/// with work? One second idle (sleeping), one second of a busy loop.
func runHello() -> String {
    let a = ProcUsage.now()
    usleep(1_000_000)
    let b = ProcUsage.now()
    var x: UInt64 = 1
    let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 1_000_000_000
    while clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < end {
        for _ in 0..<1000 { x = x &* 6364136223846793005 &+ 1442695040888963407 }
    }
    let c = ProcUsage.now()
    let idle = UsageDelta(a, b), busy = UsageDelta(b, c)
    func mj(_ v: UInt64) -> String { "\((Double(v) / 1e5).rounded() / 10)" }
    return "hello=1 sink=\(x & 1) idle_energy_mj=\(mj(idle.energyNj)) busy_energy_mj=\(mj(busy.energyNj))"
        + " idle_billed_mj=\(mj(idle.billed)) busy_billed_mj=\(mj(busy.billed))"
        + " idle_serviced_mj=\(mj(idle.serviced)) busy_serviced_mj=\(mj(busy.serviced))"
        + " idle_penergy_mj=\(mj(idle.pEnergyNj)) busy_penergy_mj=\(mj(busy.pEnergyNj))"
        + " idle_cpu_ms=\(Double(idle.cpuNs) / 1e6) busy_cpu_ms=\(Double(busy.cpuNs) / 1e6)"
        + " idle_wkups=\(idle.idleWakeups) busy_wkups=\(busy.idleWakeups)"
        + " abs_energy_mj=\(mj(c.energyNj)) abs_billed_mj=\(mj(c.billed))"
        + busy.line
}

/// The unplugged cross-check (SPEC.md "Unplugged"): launched over the
/// cable, waits up to `wait` minutes for the battery state to become
/// unplugged, settles 20 s, then runs `seq` (Part 1 configurations,
/// comma separated `kernel/comp`), one line each, in this process.
func startUnplugged(_ opt: Options, info: LaunchInfo) {
    let t = Thread {
        let waitS = opt.int("wait", 30) * 60
        var waited = 0
        Output.shared.emit(info.head + " unplugged=waiting")
        while waited < waitS {
            let st = DispatchQueue.main.sync { MainActor.assumeIsolated { UIDevice.current.batteryState } }
            if st == .unplugged { break }
            sleep(1)
            waited += 1
        }
        if waited >= waitS {
            Output.shared.emit(info.head + " unplugged=timeout waited_s=\(waited)" + Telemetry.suffix())
            Output.shared.emit("DONE")
            exit(0)
        }
        sleep(20)
        let seq = (opt["seq"] ?? "walk22x4/none,walk22x4/spin,walkbuild22/none,walkbuild22/spin").split(separator: ",")
        for rep in 0..<opt.int("reps", 3) {
            for item in seq {
                let p = item.split(separator: "/")
                var o = Options()
                o.kv = ["kernel": String(p[0]), "comp": p.count > 1 ? String(p[1]) : "none", "workers": "1"]
                let bat = DispatchQueue.main.sync { MainActor.assumeIsolated { Telemetry.battery() } }
                let line = runWalk(o)
                Output.shared.emit("part=1 run=\(rep + 1) tag=unplugged \(bat) thermal_start=\(Telemetry.thermal()) " + line + Telemetry.suffix())
            }
        }
        Output.shared.emit("DONE")
        exit(0)
    }
    t.stackSize = 16 << 20
    t.qualityOfService = .userInitiated
    t.start()
}
