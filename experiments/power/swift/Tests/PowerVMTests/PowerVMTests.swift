// Tests for the power scenario's VM side (SPEC.md "Tests"): the
// rate-limited allocation frame allocates and keeps what it says, the VM's
// threads are identified, and the walkNxR kernel scales the traversal.
// Serialized: the collector configuration comes from the environment.

import Darwin
import Kasm
import PowerKit
import PowerVM
import Testing
import VMR

private func small() -> SessionConfig {
    var c = SessionConfig()
    c.oldheapMB = 2
    c.heapMB = 64
    c.nurseryKB = 256
    c.replaceEvery = 64
    return c
}

private func env(gc: String, young: String) {
    setenv("KAJO_GC", gc, 1)
    setenv("KAJO_YOUNG", young, 1)
    setenv("KAJO_AGE", "2", 1)
    unsetenv("KAJO_YC_QOS")
    unsetenv("KAJO_CM_QOS")
}

@Suite(.serialized) struct FrameTests {
    @Test func stwFramesAllocateAndKeepTheirShare() throws {
        env(gc: "stw", young: "stw")
        let s = try Session(small())
        #expect(s.threads.all.isEmpty) // no collector, no markers, no background workers
        let scav0 = s.vm.metric(.scavenges)
        for _ in 0..<50 { s.frame(points: 2000, mutation: 0, percent: 10) }
        #expect(s.intGlobal(8) == 100_000)      // counter c: every Point
        #expect(s.intGlobal(7) == 10_000)       // keepers: 10 percent
        #expect(s.intGlobal(10) == 100_000 * 99_999 / 2) // sum of x = c
        #expect(s.vm.metric(.scavenges) > scav0) // 2.4 MB through a 256 KiB nursery
        #expect(s.pointsAllocated == 100_000)
        s.stop()
    }

    @Test func keeperStoreIsReplacedWhenFull() throws {
        env(gc: "stw", young: "stw")
        let s = try Session(small())
        // 70 000 keepers at 100 percent: the store fills at 65 536 and restarts.
        for _ in 0..<70 { s.frame(points: 1000, mutation: 0, percent: 100) }
        #expect(s.intGlobal(7) == 70_000 - 65_536)
        s.stop()
    }

    @Test func mutationRunsOnTheOldHeap() throws {
        env(gc: "stw", young: "stw")
        let s = try Session(small())
        let old0 = s.oldBytes
        #expect(old0 >= 2 << 20) // the old heap was built and promoted
        for _ in 0..<20 { s.frame(points: 0, mutation: 64, percent: 0) }
        #expect(s.mutationIters == 1280)
        #expect(s.intGlobal(8) == 0)
        s.stop()
    }

    @Test func offloadSessionIdentifiesCollectorAndMarker() throws {
        env(gc: "cm", young: "offload")
        let s = try Session(small())
        #expect(s.threads.collector.count == 1)
        #expect(s.threads.markers.count == 1)
        #expect(s.threads.unexpected.isEmpty)
        let a = ThreadCPU.snapshot()
        for _ in 0..<60 { s.frame(points: 4000, mutation: 8, percent: 10) }
        let b = ThreadCPU.snapshot()
        #expect(s.intGlobal(8) == 240_000)
        // The collector did the young collections, so it used CPU.
        #expect(ThreadCPU.cpuDelta(a, b, s.threads.collector) > 0)
        #expect(s.vm.pointee.yc.log.pointee.count > 0)
        s.stop()
    }

    @Test func backgroundWorkersAreIdentified() throws {
        env(gc: "cm", young: "offload")
        var c = small()
        c.background = 3
        let s = try Session(c, buildOldHeap: false)
        #expect(s.threads.collector.count == 1)
        #expect(s.threads.markers.count == 1)
        #expect(s.threads.background.count == 3)
        s.emptyFrame()
        s.stop()
    }
}

extension FrameTests {
    @Test func walkWithRepsParses() {
        #expect(sizedWalk("walk22x6")! == ("walksize", 22, 6))
        #expect(sizedWalk("walk22")! == ("walksize", 22, 2))
        #expect(sizedWalk("walkbuild22")! == ("walksize", 22, 0))
        #expect(sizedWalk("walkbuild22x3") == nil)
        #expect(sizedWalk("walk22x") == nil)
    }
}
