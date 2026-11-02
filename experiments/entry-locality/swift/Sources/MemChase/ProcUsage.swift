// Process CPU telemetry from proc_pid_rusage(RUSAGE_INFO_V6): CPU time,
// instructions and cycles in total and on performance cores. Added after
// the first device runs of Part 1 showed launch-to-launch spreads of 2x on
// single-thread chases (RESULTS.md "What sets the cost"): it tells whether a
// run sat on performance or efficiency cores and at what clock.
// proc_pid_rusage is declared in libproc.h, which the iOS SDK lacks; the
// symbol is in libSystem on both platforms.

import Darwin

@_silgen_name("proc_pid_rusage")
private func proc_pid_rusage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer) -> Int32

public struct ProcUsage: Sendable {
    public var cpuNs: UInt64 = 0      // user + system
    public var pNs: UInt64 = 0        // user + system on P cores
    public var instr: UInt64 = 0
    public var cycles: UInt64 = 0
    public var pInstr: UInt64 = 0
    public var pCycles: UInt64 = 0
    public var runnableNs: UInt64 = 0
    public var energyNj: UInt64 = 0

    public static func now() -> ProcUsage {
        var ri = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &ri) { proc_pid_rusage(getpid(), 6, UnsafeMutableRawPointer($0)) }
        if rc != 0 { return ProcUsage() }
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        func ns(_ t: UInt64) -> UInt64 { t &* UInt64(tb.numer) / UInt64(tb.denom) }
        return ProcUsage(cpuNs: ns(ri.ri_user_time &+ ri.ri_system_time),
                         pNs: ns(ri.ri_user_ptime &+ ri.ri_system_ptime),
                         instr: ri.ri_instructions, cycles: ri.ri_cycles,
                         pInstr: ri.ri_pinstructions, pCycles: ri.ri_pcycles,
                         runnableNs: ns(ri.ri_runnable_time), energyNj: ri.ri_energy_nj)
    }

    /// key=value fields for the interval from `a` to `b`: CPU ms, share of
    /// CPU time on P cores, average clock on P and on E cores (cycles per
    /// CPU ns), IPC, time runnable but not running.
    public static func line(_ a: ProcUsage, _ b: ProcUsage) -> String {
        let cpu = Double(b.cpuNs &- a.cpuNs), p = Double(b.pNs &- a.pNs)
        let cyc = Double(b.cycles &- a.cycles), pc = Double(b.pCycles &- a.pCycles)
        let ins = Double(b.instr &- a.instr)
        func r(_ x: Double, _ d: Double = 100) -> String { x.isFinite ? "\((x * d).rounded() / d)" : "0" }
        return " cpu_ms=\(r(cpu / 1e6, 10)) p_frac=\(r(cpu > 0 ? p / cpu : 0, 1000))"
            + " p_ghz=\(r(p > 0 ? pc / p : 0)) e_ghz=\(r(cpu - p > 1e6 ? (cyc - pc) / (cpu - p) : 0))"
            + " ipc=\(r(cyc > 0 ? ins / cyc : 0)) runnable_ms=\(r(Double(b.runnableNs &- a.runnableNs) / 1e6, 10))"
            + " energy_mj=\(r(Double(b.energyNj &- a.energyNj) / 1e6, 10))"
    }
}
