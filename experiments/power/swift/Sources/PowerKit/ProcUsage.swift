// Process telemetry from proc_pid_rusage(RUSAGE_INFO_V6) for the app's own
// pid: CPU time (total, on P cores, per QoS class), instructions and cycles,
// energy (ri_energy_nj, ri_penergy_nj, ri_billed_energy,
// ri_serviced_energy), wakeups (ri_pkg_idle_wkups, ri_interrupt_wkups).
// Derived from ../../../../entry-locality/swift/Sources/MemChase/ProcUsage.swift
// (recorded there as an addition); this copy adds the energy, wakeup and QoS
// fields the power experiment needs (SPEC.md "Telemetry").
// proc_pid_rusage is declared in libproc.h, which the iOS SDK lacks; the
// symbol is in libSystem on both platforms.

import Darwin

@_silgen_name("proc_pid_rusage")
private func proc_pid_rusage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer) -> Int32

public struct ProcUsage: Sendable, Equatable {
    public var ok = false
    public var wallNs: UInt64 = 0     // CLOCK_UPTIME_RAW at the sample
    public var cpuNs: UInt64 = 0      // user + system
    public var pNs: UInt64 = 0        // user + system on P cores
    public var instr: UInt64 = 0
    public var cycles: UInt64 = 0
    public var pInstr: UInt64 = 0
    public var pCycles: UInt64 = 0
    public var runnableNs: UInt64 = 0
    public var energyNj: UInt64 = 0   // ri_energy_nj
    public var pEnergyNj: UInt64 = 0  // ri_penergy_nj
    public var billed: UInt64 = 0     // ri_billed_energy
    public var serviced: UInt64 = 0   // ri_serviced_energy
    public var idleWakeups: UInt64 = 0      // ri_pkg_idle_wkups
    public var interruptWakeups: UInt64 = 0 // ri_interrupt_wkups
    public var qosUtilityNs: UInt64 = 0
    public var qosDefaultNs: UInt64 = 0
    public var qosInitiatedNs: UInt64 = 0
    public var qosInteractiveNs: UInt64 = 0
    public var qosOtherNs: UInt64 = 0 // maintenance, background, legacy

    public init() {}

    nonisolated(unsafe) static var timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    public static func now() -> ProcUsage {
        var ri = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &ri) { proc_pid_rusage(getpid(), 6, UnsafeMutableRawPointer($0)) }
        var u = ProcUsage()
        u.wallNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if rc != 0 { return u }
        let tb = timebase
        func ns(_ t: UInt64) -> UInt64 { t &* UInt64(tb.numer) / UInt64(tb.denom) }
        u.ok = true
        u.cpuNs = ns(ri.ri_user_time &+ ri.ri_system_time)
        u.pNs = ns(ri.ri_user_ptime &+ ri.ri_system_ptime)
        u.instr = ri.ri_instructions; u.cycles = ri.ri_cycles
        u.pInstr = ri.ri_pinstructions; u.pCycles = ri.ri_pcycles
        u.runnableNs = ns(ri.ri_runnable_time)
        u.energyNj = ri.ri_energy_nj; u.pEnergyNj = ri.ri_penergy_nj
        u.billed = ri.ri_billed_energy; u.serviced = ri.ri_serviced_energy
        u.idleWakeups = ri.ri_pkg_idle_wkups; u.interruptWakeups = ri.ri_interrupt_wkups
        // ri_cpu_time_qos_* are in Mach absolute time units like ri_user_time.
        u.qosUtilityNs = ns(ri.ri_cpu_time_qos_utility)
        u.qosDefaultNs = ns(ri.ri_cpu_time_qos_default)
        u.qosInitiatedNs = ns(ri.ri_cpu_time_qos_user_initiated)
        u.qosInteractiveNs = ns(ri.ri_cpu_time_qos_user_interactive)
        u.qosOtherNs = ns(ri.ri_cpu_time_qos_maintenance &+ ri.ri_cpu_time_qos_background &+ ri.ri_cpu_time_qos_legacy)
        return u
    }
}

/// The interval between two samples.
public struct UsageDelta: Sendable {
    public var a: ProcUsage
    public var b: ProcUsage
    public init(_ a: ProcUsage, _ b: ProcUsage) { self.a = a; self.b = b }

    public var wallNs: UInt64 { b.wallNs &- a.wallNs }
    public var cpuNs: UInt64 { b.cpuNs &- a.cpuNs }
    public var pNs: UInt64 { b.pNs &- a.pNs }
    public var energyNj: UInt64 { b.energyNj &- a.energyNj }
    public var pEnergyNj: UInt64 { b.pEnergyNj &- a.pEnergyNj }
    public var billed: UInt64 { b.billed &- a.billed }
    public var serviced: UInt64 { b.serviced &- a.serviced }
    public var idleWakeups: UInt64 { b.idleWakeups &- a.idleWakeups }
    public var interruptWakeups: UInt64 { b.interruptWakeups &- a.interruptWakeups }
    public var cycles: UInt64 { b.cycles &- a.cycles }
    public var instr: UInt64 { b.instr &- a.instr }

    /// key=value fields (leading space). Energy in mJ (ri_energy_nj /
    /// ri_penergy_nj; ri_billed_energy and ri_serviced_energy raw, nJ by
    /// their kernel definition), CPU in ms, wakeups as counts.
    public var line: String {
        let cpu = Double(cpuNs), p = Double(pNs)
        let cyc = Double(cycles), pc = Double(b.pCycles &- a.pCycles)
        func r(_ x: Double, _ d: Double = 100) -> String { x.isFinite ? "\((x * d).rounded() / d)" : "0" }
        func ms(_ ns: UInt64) -> String { r(Double(ns) / 1e6, 10) }
        var o = " rusage_ok=\(a.ok && b.ok ? 1 : 0) win_ms=\(ms(wallNs))"
        o += " cpu_ms=\(ms(cpuNs)) p_frac=\(r(cpu > 0 ? p / cpu : 0, 1000))"
        o += " p_ghz=\(r(p > 0 ? pc / p : 0)) e_ghz=\(r(cpu - p > 1e6 ? (cyc - pc) / (cpu - p) : 0))"
        o += " ipc=\(r(cyc > 0 ? Double(instr) / cyc : 0)) runnable_ms=\(ms(b.runnableNs &- a.runnableNs))"
        o += " energy_mj=\(r(Double(energyNj) / 1e6, 10)) penergy_mj=\(r(Double(pEnergyNj) / 1e6, 10))"
        o += " billed_mj=\(r(Double(billed) / 1e6, 10)) serviced_mj=\(r(Double(serviced) / 1e6, 10))"
        o += " idle_wkups=\(idleWakeups) intr_wkups=\(interruptWakeups)"
        o += " qos_ui_ms=\(ms(b.qosInteractiveNs &- a.qosInteractiveNs)) qos_in_ms=\(ms(b.qosInitiatedNs &- a.qosInitiatedNs))"
        o += " qos_def_ms=\(ms(b.qosDefaultNs &- a.qosDefaultNs)) qos_ut_ms=\(ms(b.qosUtilityNs &- a.qosUtilityNs))"
        o += " qos_other_ms=\(ms(b.qosOtherNs &- a.qosOtherNs))"
        return o
    }
}
