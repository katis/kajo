import Darwin
import Foundation

// The final mark on the devices (docs/modules/final-mark.md): what each
// final mark's record carries beside its phases, read by the stopper
// outside the stop (the thermal state, and its own CPU by core type before
// the request) and once more at the end of the stop's work. Out of line and
// apart from the marker's loop: Foundation's object and the syscall stay
// off every path `just arc-check` covers.

/// The calling thread's CPU time and cycles on performance and efficiency
/// cores, from proc_pidinfo(PROC_PIDTHREADCOUNTS = 34), the private flavor
/// experiments/power read on iOS (level 0 the performance cores). `ok` is
/// false where it does not read (the record then says so).
struct CoreTime: Sendable {
    var ok = false
    var pCpuNs: UInt64 = 0
    var eCpuNs: UInt64 = 0
    var pCycles: UInt64 = 0
    var eCycles: UInt64 = 0

    @inline(never)
    static func now() -> CoreTime {
        var tid: UInt64 = 0
        unsafe pthread_threadid_np(nil, &tid)
        // Two levels of five words each after one word of header.
        var buf = (UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0),
                   UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0))
        let bytes = Int32(MemoryLayout.size(ofValue: buf))
        let r = unsafe withUnsafeMutableBytes(of: &buf) { unsafe proc_pidinfo(getpid(), 34, tid, $0.baseAddress, bytes) }
        var out = CoreTime()
        guard r > 8 else { return out }
        let levels = Swift.min(2, (Int(r) - 8) / 40)
        var tb = mach_timebase_info_data_t()
        unsafe mach_timebase_info(&tb)
        unsafe withUnsafeBytes(of: &buf) { raw in
            for i in 0..<levels {
                let w = { (k: Int) -> UInt64 in unsafe raw.load(fromByteOffset: 8 + i * 40 + k * 8, as: UInt64.self) }
                let cpu = (w(2) &+ w(3)) &* UInt64(tb.numer) / UInt64(Swift.max(1, tb.denom))
                if i == 0 { out.pCpuNs = cpu; out.pCycles = w(1) } else { out.eCpuNs &+= cpu; out.eCycles &+= w(1) }
            }
        }
        out.ok = levels > 0
        return out
    }

    func since(_ a: CoreTime) -> CoreTime {
        CoreTime(ok: ok && a.ok, pCpuNs: pCpuNs &- a.pCpuNs, eCpuNs: eCpuNs &- a.eCpuNs,
                 pCycles: pCycles &- a.pCycles, eCycles: eCycles &- a.eCycles)
    }
}

/// `ProcessInfo.thermalState` as a number: 0 nominal, 1 fair, 2 serious,
/// 3 critical.
@inline(never)
func thermalStateNow() -> UInt8 {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: 0
    case .fair: 1
    case .serious: 2
    case .critical: 3
    @unknown default: 9
    }
}

/// What the stopper of a final mark knows before it requests the stop.
struct FinalMarkContext: Sendable {
    var thermal: UInt8 = 0
    var qos: UInt32 = 0
    var core = CoreTime()

    @inline(never)
    static func take() -> FinalMarkContext {
        FinalMarkContext(thermal: thermalStateNow(), qos: qos_class_self().rawValue, core: CoreTime.now())
    }
}
