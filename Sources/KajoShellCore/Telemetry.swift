import Darwin
import Foundation
import KajoAppDevelopment
import Synchronization

/// Module 8d: the kind of the image the shell opened last ("-" before one).
private let openedImageKind = Mutex<String>("-")

// Device telemetry for every result line (AGENTS.md: device numbers carry a
// thermal state; log the QoS each thread got; energy from ri_energy_nj is
// the process's CPU energy and counts no DRAM, display or render server).

@_silgen_name("proc_pid_rusage")
private func proc_pid_rusage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer) -> Int32

@_silgen_name("proc_pidinfo")
private func proc_pidinfo(_ pid: Int32, _ flavor: Int32, _ arg: UInt64, _ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> Int32

public enum Telemetry {
    public static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    /// (phys_footprint, its ledger peak) in bytes.
    public static func footprint() -> (now: UInt64, peak: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            unsafe $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                unsafe task_info(selfTask(), task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? (info.phys_footprint, UInt64(max(0, info.ledger_phys_footprint_peak))) : (0, 0)
    }

    /// `mach_task_self_` is a mutable global in both SDKs (see VirtualMemory).
    private static func selfTask() -> mach_port_t { unsafe mach_task_self_ }

    /// Memory the process may still use before jetsam (iOS), MB; -1 elsewhere.
    public static func availableMB() -> Int {
        #if os(iOS)
        Int(os_proc_available_memory() >> 20)
        #else
        -1
        #endif
    }

    /// The process's CPU energy so far (ri_energy_nj), nJ; nil if unread.
    public static func energyNj() -> UInt64? {
        var ri = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &ri) { unsafe proc_pid_rusage(getpid(), 6, UnsafeMutableRawPointer($0)) }
        return rc == 0 ? ri.ri_energy_nj : nil
    }

    static func mb(_ b: UInt64) -> String { f1(Double(b) / 1_048_576) }

    /// Appended to every result line.
    public static func suffix() -> String {
        let (fp, peak) = footprint()
        return " thermal=\(thermal()) footprint_mb=\(mb(fp)) footprint_peak_mb=\(mb(peak)) avail_mb=\(availableMB()) image=\(imageKind)"
    }

    /// Module 8d: `release` or `development`, the kind of the image the
    /// shell opened (every result line carries it).
    public static var imageKind: String { openedImageKind.withLock { $0 } }
    public static func noteImage(release: Bool) { openedImageKind.withLock { $0 = release ? "release" : "development" } }

    public static func qosName(_ q: UInt32) -> String {
        switch q {
        case QOS_CLASS_USER_INTERACTIVE.rawValue: "userInteractive"
        case QOS_CLASS_USER_INITIATED.rawValue: "userInitiated"
        case QOS_CLASS_DEFAULT.rawValue: "default"
        case QOS_CLASS_UTILITY.rawValue: "utility"
        case QOS_CLASS_BACKGROUND.rawValue: "background"
        case 0: "-"
        default: "\(q)"
        }
    }

    /// The calling thread's 64-bit id.
    public static func threadID() -> UInt64 {
        var tid: UInt64 = 0
        unsafe pthread_threadid_np(nil, &tid)
        return tid
    }
}

/// Per-thread CPU time and energy by core type, from
/// proc_pidinfo(PROC_PIDTHREADCOUNTS = 34), a flavor outside the public SDK
/// (xnu's proc_info_private.h) that experiments/power read on iOS 27: one
/// record per performance level, level 0 the performance cores. `ok` is
/// false where it does not read.
public struct ThreadCounts: Sendable {
    public var ok = false
    /// CPU ns and energy nJ on performance and on efficiency cores.
    public var pCpuNs: UInt64 = 0, eCpuNs: UInt64 = 0, pEnergyNj: UInt64 = 0, eEnergyNj: UInt64 = 0
    /// Instructions and cycles on performance and on efficiency cores (the
    /// record's first two words; zero where the counters do not run).
    public var pInstr: UInt64 = 0, eInstr: UInt64 = 0, pCycles: UInt64 = 0, eCycles: UInt64 = 0

    public init(ok: Bool = false, pCpuNs: UInt64 = 0, eCpuNs: UInt64 = 0, pEnergyNj: UInt64 = 0, eEnergyNj: UInt64 = 0,
                pInstr: UInt64 = 0, eInstr: UInt64 = 0, pCycles: UInt64 = 0, eCycles: UInt64 = 0) {
        self.ok = ok
        self.pCpuNs = pCpuNs; self.eCpuNs = eCpuNs; self.pEnergyNj = pEnergyNj; self.eEnergyNj = eEnergyNj
        self.pInstr = pInstr; self.eInstr = eInstr; self.pCycles = pCycles; self.eCycles = eCycles
    }

    public static func of(_ tid: UInt64) -> ThreadCounts {
        let levels = 2, recWords = 5
        let bytes = 8 + levels * recWords * 8
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
        defer { unsafe buf.deallocate() }
        unsafe memset(buf, 0, bytes)
        let r = unsafe proc_pidinfo(getpid(), 34, tid, buf, Int32(bytes))
        var out = ThreadCounts()
        guard r > 8 else { return out }
        let got = min(levels, (Int(r) - 8) / (recWords * 8))
        var tb = mach_timebase_info_data_t()
        unsafe mach_timebase_info(&tb)
        for i in 0..<got {
            let w = unsafe buf.advanced(by: 8 + i * recWords * 8).assumingMemoryBound(to: UInt64.self)
            let cpu = unsafe (w[2] &+ w[3]) &* UInt64(tb.numer) / UInt64(tb.denom)
            if i == 0 {
                out.pCpuNs = cpu; out.pEnergyNj = unsafe w[4]; out.pInstr = unsafe w[0]; out.pCycles = unsafe w[1]
            } else {
                out.eCpuNs &+= cpu; out.eEnergyNj &+= unsafe w[4]; out.eInstr &+= unsafe w[0]; out.eCycles &+= unsafe w[1]
            }
        }
        out.ok = got > 0
        return out
    }

    public func since(_ a: ThreadCounts) -> ThreadCounts {
        ThreadCounts(ok: ok && a.ok, pCpuNs: pCpuNs &- a.pCpuNs, eCpuNs: eCpuNs &- a.eCpuNs,
                     pEnergyNj: pEnergyNj &- a.pEnergyNj, eEnergyNj: eEnergyNj &- a.eEnergyNj,
                     pInstr: pInstr &- a.pInstr, eInstr: eInstr &- a.eInstr, pCycles: pCycles &- a.pCycles, eCycles: eCycles &- a.eCycles)
    }

    public static func + (a: ThreadCounts, b: ThreadCounts) -> ThreadCounts {
        ThreadCounts(ok: a.ok && b.ok, pCpuNs: a.pCpuNs &+ b.pCpuNs, eCpuNs: a.eCpuNs &+ b.eCpuNs,
                     pEnergyNj: a.pEnergyNj &+ b.pEnergyNj, eEnergyNj: a.eEnergyNj &+ b.eEnergyNj,
                     pInstr: a.pInstr &+ b.pInstr, eInstr: a.eInstr &+ b.eInstr, pCycles: a.pCycles &+ b.pCycles, eCycles: a.eCycles &+ b.eCycles)
    }

    /// `key_cpu_ms=... key_p_frac=... key_mj=...` (leading space), and the
    /// clock and IPC on each core type (cycles per CPU ns; 0 where the
    /// counters read zero or the thread did not run there).
    public func fields(_ k: String) -> String {
        let tot = pCpuNs &+ eCpuNs
        func ratio(_ a: UInt64, _ b: UInt64) -> String { b > 0 ? f2(Double(a) / Double(b)) : "0" }
        var o = " \(k)_tc_ok=\(ok ? 1 : 0) \(k)_cpu_ms=\(f1(Double(tot) / 1e6)) \(k)_p_frac=\(f3(tot > 0 ? Double(pCpuNs) / Double(tot) : 0)) \(k)_mj=\(f1(Double(pEnergyNj &+ eEnergyNj) / 1e6))"
        o += " \(k)_p_mj=\(f1(Double(pEnergyNj) / 1e6)) \(k)_p_ghz=\(ratio(pCycles, pCpuNs > 1_000_000 ? pCpuNs : 0)) \(k)_e_ghz=\(ratio(eCycles, eCpuNs > 1_000_000 ? eCpuNs : 0))"
        o += " \(k)_p_ipc=\(ratio(pInstr, pCycles)) \(k)_e_ipc=\(ratio(eInstr, eCycles))"
        return o
    }
}

/// A thread's scheduling priority as the kernel has it now
/// (proc_pidinfo(PROC_PIDTHREADID64INFO = 15) on the 64-bit thread id:
/// `pth_priority`, the base the QoS gives, and `pth_curpri`, the current).
/// Base 46 and up is user-interactive (an app's main thread reads 46 or
/// 47), 37 user-initiated, 31 default, 20 utility, 4 background: the QoS a
/// thread actually got, not the one asked for.
public struct ThreadPriority: Sendable {
    public var ok = false
    public var base: Int32 = 0
    public var current: Int32 = 0

    public static func of(_ tid: UInt64) -> ThreadPriority {
        // struct proc_threadinfo: two UInt64 times, then eight Int32
        // (cpu_usage, policy, run_state, flags, sleep_time, curpri,
        // priority, maxpriority) and a 64-byte name.
        let bytes = 16 + 8 * 4 + 64
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
        defer { unsafe buf.deallocate() }
        unsafe memset(buf, 0, bytes)
        let r = unsafe proc_pidinfo(getpid(), 15, tid, buf, Int32(bytes))
        guard r == Int32(bytes) else { return ThreadPriority() }
        let w = unsafe buf.advanced(by: 16).assumingMemoryBound(to: Int32.self)
        return unsafe ThreadPriority(ok: true, base: w[6], current: w[5])
    }

    /// The QoS class a base priority belongs to.
    public var qosName: String {
        guard ok else { return "-" }
        switch base {
        case 46...: return "userInteractive"
        case 37..<46: return "userInitiated"
        case 31..<37: return "default"
        case 20..<31: return "utility"
        case 1..<20: return "background"
        default: return "\(base)"
        }
    }

    /// ` key_pri=base/current key_qos_got=name` (leading space).
    public func fields(_ k: String) -> String { " \(k)_pri=\(ok ? "\(base)/\(current)" : "-") \(k)_qos_got=\(qosName)" }
}

/// The process's rusage (proc_pid_rusage, RUSAGE_INFO_V6) as
/// experiments/power read it: CPU, on P cores, instructions and cycles,
/// energy (ri_energy_nj, ri_penergy_nj), billed and serviced energy.
public struct ProcessUsage: Sendable {
    public var ok = false
    public var cpuNs: UInt64 = 0, pCpuNs: UInt64 = 0
    public var instr: UInt64 = 0, cycles: UInt64 = 0, pInstr: UInt64 = 0, pCycles: UInt64 = 0
    public var energyNj: UInt64 = 0, pEnergyNj: UInt64 = 0, billed: UInt64 = 0, serviced: UInt64 = 0

    public static func now() -> ProcessUsage {
        var ri = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &ri) { unsafe proc_pid_rusage(getpid(), 6, UnsafeMutableRawPointer($0)) }
        var u = ProcessUsage()
        guard rc == 0 else { return u }
        var tb = mach_timebase_info_data_t()
        unsafe mach_timebase_info(&tb)
        func ns(_ t: UInt64) -> UInt64 { t &* UInt64(tb.numer) / UInt64(tb.denom) }
        u.ok = true
        u.cpuNs = ns(ri.ri_user_time &+ ri.ri_system_time)
        u.pCpuNs = ns(ri.ri_user_ptime &+ ri.ri_system_ptime)
        u.instr = ri.ri_instructions; u.cycles = ri.ri_cycles
        u.pInstr = ri.ri_pinstructions; u.pCycles = ri.ri_pcycles
        u.energyNj = ri.ri_energy_nj; u.pEnergyNj = ri.ri_penergy_nj
        u.billed = ri.ri_billed_energy; u.serviced = ri.ri_serviced_energy
        return u
    }

    /// The interval since `a` as ` rusage_ok=.. cpu_ms=.. ...` (leading space).
    public func fields(since a: ProcessUsage) -> String {
        let cpu = cpuNs &- a.cpuNs, p = pCpuNs &- a.pCpuNs
        let cyc = cycles &- a.cycles, pc = pCycles &- a.pCycles, ins = instr &- a.instr
        func ms(_ x: UInt64) -> String { f1(Double(x) / 1e6) }
        func ratio(_ x: UInt64, _ y: UInt64) -> String { y > 1_000_000 ? f2(Double(x) / Double(y)) : "0" }
        var o = " rusage_ok=\(ok && a.ok ? 1 : 0) ru_cpu_ms=\(ms(cpu)) ru_p_cpu_ms=\(ms(p))"
        o += " ru_instr=\(ins) ru_cycles=\(cyc) ru_p_ghz=\(ratio(pc, p)) ru_e_ghz=\(ratio(cyc &- pc, cpu &- p)) ru_ipc=\(cyc > 0 ? f2(Double(ins) / Double(cyc)) : "0")"
        o += " ru_energy_mj=\(f1(Double(energyNj &- a.energyNj) / 1e6)) ru_penergy_mj=\(f1(Double(pEnergyNj &- a.pEnergyNj) / 1e6))"
        o += " ru_billed_mj=\(f1(Double(billed &- a.billed) / 1e6)) ru_serviced_mj=\(f1(Double(serviced &- a.serviced) / 1e6))"
        return o
    }
}
