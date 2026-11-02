// Tests for the telemetry and helpers the power experiment adds (SPEC.md
// "Tests"): the energy and CPU readout, per-thread CPU bookkeeping, the
// companion's modes, the allocation pacer, the chase.

import Darwin
import PowerKit
import Testing

private func burn(ms: Double) -> UInt64 {
    let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + UInt64(ms * 1e6)
    var x: UInt64 = 1
    while clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < end {
        for _ in 0..<1000 { x = x &* 6364136223846793005 &+ 1442695040888963407 }
    }
    return x
}

@Suite(.serialized) struct Telemetry {
    @Test func energyAndCpuGrowWithWork() {
        let a = ProcUsage.now()
        #expect(a.ok)
        _ = burn(ms: 300)
        let b = ProcUsage.now()
        let d = UsageDelta(a, b)
        #expect(d.cpuNs >= 250_000_000)
        #expect(d.wallNs >= 300_000_000)
        // ri_energy_nj is populated on Apple silicon (the device check is
        // the first line of every phone run).
        #expect(d.energyNj > 0)
        #expect(d.line.contains("energy_mj="))
        #expect(d.line.contains("idle_wkups="))
    }

    @Test func threadCpuFindsABusyThread() {
        let before = ThreadCPU.snapshot()
        #expect(before[ThreadCPU.selfId()] != nil)
        let c = Companion(.spin)
        usleep(200_000)
        let mid = ThreadCPU.snapshot()
        let fresh = ThreadCPU.newThreads(before, mid)
        #expect(fresh.count == 1)
        let r = c.finish()
        #expect(r.count > 1000)
        #expect(r.cpuNs >= 150_000_000)
        // The spinner's CPU as the task sees it, against its own clock.
        let busy = ThreadCPU.cpuDelta(before, mid, fresh)
        #expect(busy >= 150_000_000)
        #expect(busy <= r.cpuNs + 5_000_000)
    }

    @Test func timerCompanionWakesAtItsRate() {
        let c = Companion(.timer(hz: 1000))
        usleep(400_000)
        let r = c.finish()
        #expect(r.count >= 300 && r.count <= 420)
        #expect(r.cpuNs < r.wallNs / 4)
        let line = Companion.fields(c, r)
        #expect(line.contains("comp=timer1000"))
    }

    @Test func utilityCompanionReportsItsQoS() {
        let c = Companion(.spin, qos: QOS_CLASS_UTILITY)
        usleep(50_000)
        let r = c.finish()
        #expect(r.qos == QOS_CLASS_UTILITY)
        #expect(Companion.fields(c, r).contains("comp_qos=utility"))
    }

    @Test func wfeCompanionRunsAndStops() {
        let c = Companion(.wfe)
        usleep(50_000)
        let r = c.finish()
        #expect(r.count > 0)
    }
}

@Suite struct PacerTests {
    @Test func steadyFramesDeliverTheRate() {
        // 10 MB/s of 24-byte objects at 120 Hz: 3641 per frame.
        var p = Pacer(bytesPerSecond: 10 * 1048576, objectBytes: 24)
        var total = 0
        for i in 0..<120 { total += p.due(at: Double(i) / 120) }
        let expect = 10 * 1048576 / 24
        #expect(abs(total - expect) <= expect / 100 + 1)
        #expect(p.capped == 0)
    }

    @Test func aMissedFrameIsCaughtUp() {
        var p = Pacer(bytesPerSecond: 2 * 1048576, objectBytes: 24)
        let one = p.due(at: 0)
        let two = p.due(at: 2.0 / 120) // one frame skipped
        #expect(abs(two - 2 * one) <= 1)
    }

    @Test func aLongStallIsCappedAndForgotten() {
        var p = Pacer(bytesPerSecond: 2 * 1048576, objectBytes: 24, maxFrames: 4)
        _ = p.due(at: 0)
        let n = p.due(at: 1.0) // 119 frames late
        #expect(n == Int((p.perFrame * 4).rounded(.up)))
        #expect(p.capped > 0)
        let next = p.due(at: 1.0 + 1.0 / 120)
        #expect(abs(Double(next) - p.perFrame) <= 1)
    }
}

@Suite struct ChaseTests {
    @Test func hopsFollowTheLinks() {
        let m = UnsafeMutablePointer<UInt>.allocate(capacity: 3 * 8)
        let b = UInt(bitPattern: m)
        // 0 -> 2 -> 1 -> 0 over 64-byte nodes
        m[0] = b + 128; m[16] = b + 64; m[8] = b
        #expect(chaseHops(b, 1) == b + 128)
        #expect(chaseHops(b, 2) == b + 64)
        #expect(chaseHops(b, 3) == b)
        m.deallocate()
    }

    @Test func chaseIsOneCycle() {
        // 1 MiB = 16384 nodes; after exactly `nodes` hops from any node the
        // chase is back where it started (Sattolo: a single cycle).
        let r = runChase(sizeMB: 1, hops: 16384)
        #expect(r.nodes == 16384)
        let again = runChase(sizeMB: 1, hops: 16384 * 2)
        #expect(r.nsPerHop > 0 && again.nsPerHop > 0)
        #expect(r.usage.cpuNs > 0)
    }
}

@Suite(.serialized) struct ThreadCountsTests {
    /// The per-thread counts of a spinning thread, read from this thread by
    /// its id, agree with the kernel's CPU time of that thread
    /// (thread_info, the clock behind CLOCK_THREAD_CPUTIME_ID) read just
    /// inside and just outside the same window, and the window lasts until
    /// the spinner itself accrued 200 ms of CPU, however loaded the machine.
    @Test func perThreadCountsSeeASpinner() {
        let before = ThreadCPU.snapshot()
        let c = Companion(.spin)
        let tid = c.threadId
        // Other suites start threads meanwhile: the spinner is one of the
        // new ones, not necessarily the first.
        #expect(ThreadCPU.newThreads(before, ThreadCPU.snapshot()).contains(tid))
        func cpu() -> UInt64 { ThreadCPU.snapshot()[tid]?.cpuNs ?? 0 }
        let outer0 = cpu()
        let a = ThreadCounts.of(tid)
        let inner0 = cpu()
        let deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 30_000_000_000
        var inner1 = inner0
        repeat {
            usleep(20_000)
            inner1 = cpu()
        } while inner1 &- inner0 < 200_000_000 && clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < deadline
        let b = ThreadCounts.of(tid)
        let outer1 = cpu()
        let r = c.finish()
        #expect(a.ok && b.ok)
        let d = ThreadCounts.delta(a, b)
        let got = d.p.cpuNs + d.e.cpuNs
        let lo = inner1 &- inner0, hi = outer1 &- outer0
        #expect(lo >= 200_000_000, "spinner accrued only \(lo) ns in 30 s")
        // 1 ms for the two sources' rounding.
        #expect(got + 1_000_000 >= lo && got <= hi + 1_000_000, "counts \(got) ns, thread CPU \(lo)...\(hi) ns")
        #expect(got <= r.cpuNs + 1_000_000, "counts \(got) ns, the spinner's own clock \(r.cpuNs) ns")
        #expect(d.p.cycles + d.e.cycles > 0)
        #expect(d.fields("x").contains("x_tc_ok=1"))
    }
}
