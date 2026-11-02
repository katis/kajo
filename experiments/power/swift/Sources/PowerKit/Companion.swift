// A companion thread for Part 1 (SPEC.md "Part 1"): it runs beside the
// measured worker and does nothing useful. Modes:
//   spin        a load-free loop (`yield` hint every iteration); QoS given
//   timer       wakes `hz` times a second on absolute deadlines
//               (mach_wait_until), does nothing, sleeps again
//   wfe         a loop of `wfe` (waits for an event or the event stream)
// It counts its own iterations or wakeups and its own CPU time
// (CLOCK_THREAD_CPUTIME_ID), reported by `finish()`.

import Darwin
import PowerC
import Synchronization

public final class Companion: @unchecked Sendable {
    public enum Mode: Sendable, Equatable {
        case spin
        case timer(hz: Int)
        case wfe
    }

    public let mode: Mode
    public let qos: qos_class_t
    private let stop = Atomic<Bool>(false)
    private let started = Atomic<Bool>(false)
    private var tid: pthread_t? = nil
    /// The companion thread's 64-bit id (ThreadCPU, ThreadCounts); written
    /// by the thread before `started`, so valid once `init` returns.
    public private(set) var threadId: UInt64 = 0
    // Written by the companion thread before it exits, read after join.
    private var cpuNs: UInt64 = 0
    private var wallNs: UInt64 = 0
    private var count: UInt64 = 0
    private var lateNs: UInt64 = 0
    private var qosSeen: qos_class_t = QOS_CLASS_UNSPECIFIED
    private var counts = ThreadCounts()
    private var counts0 = ThreadCounts()

    public init(_ mode: Mode, qos: qos_class_t = QOS_CLASS_USER_INITIATED) {
        self.mode = mode
        self.qos = qos
        var attr = pthread_attr_t()
        pthread_attr_init(&attr)
        pthread_attr_set_qos_class_np(&attr, qos, 0)
        let me = Unmanaged.passRetained(self).toOpaque()
        pthread_create(&tid, &attr, { arg in
            let c = Unmanaged<Companion>.fromOpaque(arg).takeRetainedValue()
            c.loop()
            return nil
        }, me)
        pthread_attr_destroy(&attr)
        while !started.load(ordering: .acquiring) { sched_yield() }
    }

    private func loop() {
        qosSeen = qos_class_self()
        let me = ThreadCPU.selfId()
        threadId = me
        counts0 = ThreadCounts.of(me)
        let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        started.store(true, ordering: .releasing)
        var n: UInt64 = 0
        switch mode {
        case .spin:
            while !stop.load(ordering: .relaxed) { kajo_yield(); n &+= 1 }
        case .wfe:
            while !stop.load(ordering: .relaxed) { kajo_wfe(); n &+= 1 }
        case .timer(let hz):
            var tb = mach_timebase_info_data_t()
            mach_timebase_info(&tb)
            let periodNs = UInt64(1_000_000_000 / max(1, hz))
            let periodTicks = periodNs &* UInt64(tb.denom) / UInt64(tb.numer)
            var due = mach_absolute_time() &+ periodTicks
            var late: UInt64 = 0
            while !stop.load(ordering: .relaxed) {
                mach_wait_until(due)
                let t = mach_absolute_time()
                if t > due { late &+= t &- due }
                n &+= 1
                due &+= periodTicks
                if due < t { due = t &+ periodTicks } // fell behind: do not burst
            }
            lateNs = late &* UInt64(tb.numer) / UInt64(tb.denom)
        }
        count = n
        cpuNs = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- c0
        counts = ThreadCounts.delta(counts0, ThreadCounts.of(me))
        wallNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- t0
    }

    public var name: String {
        switch mode {
        case .spin: return "spin"
        case .wfe: return "wfe"
        case .timer(let hz): return "timer\(hz)"
        }
    }

    public struct Report: Sendable {
        public var cpuNs: UInt64
        public var wallNs: UInt64
        public var count: UInt64
        public var lateNs: UInt64
        public var qos: qos_class_t
        /// Per core type, from PROC_PIDTHREADCOUNTS (its own thread).
        public var counts: ThreadCounts
    }

    /// Stop, join, and report what the companion did.
    @discardableResult
    public func finish() -> Report {
        stop.store(true, ordering: .relaxed)
        if let t = tid { pthread_join(t, nil); tid = nil }
        return Report(cpuNs: cpuNs, wallNs: wallNs, count: count, lateNs: lateNs, qos: qosSeen, counts: counts)
    }

    /// key=value fields (leading space) for a report.
    public static func fields(_ c: Companion?, _ r: Report?) -> String {
        guard let c, let r else { return " comp=none" }
        let q = r.qos == QOS_CLASS_UTILITY ? "utility" : r.qos == QOS_CLASS_USER_INITIATED ? "user-initiated" :
            r.qos == QOS_CLASS_USER_INTERACTIVE ? "user-interactive" : "other"
        let rate = r.wallNs > 0 ? Double(r.count) / (Double(r.wallNs) / 1e9) : 0
        return " comp=\(c.name) comp_qos=\(q) comp_cpu_ms=\((Double(r.cpuNs) / 1e5).rounded() / 10)"
            + " comp_wall_ms=\((Double(r.wallNs) / 1e5).rounded() / 10) comp_count=\(r.count)"
            + " comp_rate_hz=\(rate.rounded()) comp_late_mean_us=\(r.count > 0 ? (Double(r.lateNs) / Double(r.count) / 100).rounded() / 10 : 0)"
            + r.counts.fields("comptc")
    }
}
