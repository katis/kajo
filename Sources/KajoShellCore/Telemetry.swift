import Darwin
import Foundation
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
            if i == 0 { out.pCpuNs = cpu; out.pEnergyNj = unsafe w[4] } else { out.eCpuNs &+= cpu; out.eEnergyNj &+= unsafe w[4] }
        }
        out.ok = got > 0
        return out
    }

    public func since(_ a: ThreadCounts) -> ThreadCounts {
        ThreadCounts(ok: ok && a.ok, pCpuNs: pCpuNs &- a.pCpuNs, eCpuNs: eCpuNs &- a.eCpuNs,
                     pEnergyNj: pEnergyNj &- a.pEnergyNj, eEnergyNj: eEnergyNj &- a.eEnergyNj)
    }

    /// `key_cpu_ms=... key_p_frac=... key_mj=...` (leading space).
    public func fields(_ k: String) -> String {
        let tot = pCpuNs &+ eCpuNs
        return " \(k)_tc_ok=\(ok ? 1 : 0) \(k)_cpu_ms=\(f1(Double(tot) / 1e6)) \(k)_p_frac=\(f3(tot > 0 ? Double(pCpuNs) / Double(tot) : 0)) \(k)_mj=\(f1(Double(pEnergyNj &+ eEnergyNj) / 1e6))"
    }
}
