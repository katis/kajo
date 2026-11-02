// A companion thread that streams through its own buffer (sequential
// 64-bit loads, summed) for as long as a measurement runs, so the memory
// system sees sustained bandwidth demand. Added after the first device
// runs (RESULTS.md "What sets the cost") to test whether a single
// latency-bound thread leaves DRAM in a slow state.

import Darwin
import Synchronization

public final class Streamer: @unchecked Sendable {
    private let buf: UnsafeMutablePointer<UInt64>
    private let words: Int
    private let stop = Atomic<Bool>(false)
    private var tid: pthread_t? = nil
    private var bytes: UInt64 = 0
    private var ns: UInt64 = 0
    private var sink: UInt64 = 0

    /// Start streaming over `mb` MiB at `qos`.
    public init(mb: Int, qos: qos_class_t = QOS_CLASS_USER_INITIATED) {
        words = (mb << 20) / 8
        buf = .allocate(capacity: words)
        for i in 0..<words { buf[i] = UInt64(i) }
        var attr = pthread_attr_t()
        pthread_attr_init(&attr)
        pthread_attr_set_qos_class_np(&attr, qos, 0)
        let me = Unmanaged.passUnretained(self).toOpaque()
        pthread_create(&tid, &attr, { arg in
            Unmanaged<Streamer>.fromOpaque(arg).takeUnretainedValue().loop()
            return nil
        }, me)
    }

    private func loop() {
        let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var s: UInt64 = 0
        var passes: UInt64 = 0
        while !stop.load(ordering: .relaxed) {
            var i = 0
            while i < words { s &+= buf[i]; i &+= 8 } // one load per 64-byte line
            passes &+= 1
        }
        ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- t0
        bytes = passes &* UInt64(words * 8)
        sink = s
    }

    /// Stop and return the bandwidth it achieved, in MB/s (lines touched).
    public func finish() -> Double {
        stop.store(true, ordering: .relaxed)
        if let t = tid { pthread_join(t, nil) }
        buf.deallocate()
        return ns > 0 ? Double(bytes) / Double(ns) * 1e9 / 1048576 + Double(sink & 0) : 0
    }
}
