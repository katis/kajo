// The final mark on the devices (docs/modules/final-mark.md): the final
// mark's record and the bound on what its stop waits for and does.

import Darwin
import Foundation
import Synchronization
import Testing
@testable import KajoVM

// MARK: - the record

/// A final mark requested while a young collection is open waits for it
/// before the request (module 7: no stop interleaves a collection), and its
/// record says so: the collection open, the time before the request, the
/// time from the request to the last park, the two adding up to the stop's
/// time to safepoint, and the work and its parts after the verifier.
@Test func theFinalMarksRecordSplitsItsTimeToSafepoint() throws {
    let hooks = YoungHooks()
    let rt = try youngRuntime(.local, src: markingSrc, marking: true) { c in
        hooks.install(&c.young.testSwitches)
        c.young.verify = false
    }
    let vm = rt.vm
    rt.run("mkEmptyH")
    vm.collect()
    vm.startYoungCycle()
    #expect(rt.phase == .marking)
    _ = vm.markStep(10_000_000)
    let done = Flag()
    var t: TestThread? = nil
    hooks.set(1) { k in
        guard k == 1 else { return }
        t = TestThread { vm.finalMark(); done.set() }
        #expect(eventually { vm.stopsWanted == 1 })
    }
    vm.collectYoung(worker: 1)
    hooks.set(1, nil)
    #expect(eventually(30) { done.isSet })
    t?.join()
    let r = try #require(vm.cycleLog.last)
    #expect(r.finalCollectionsOpen == 1)
    #expect(r.finalBeforeRequestNs > 0)
    #expect(r.finalBeforeRequestNs &+ r.finalParkWaitNs == r.finalTtspNs)
    #expect(r.finalWorkNs > 0 && r.finalWorkNs >= r.relocationAtFinalNs &+ r.sweepSetupNs)
    let stop = try #require(vm.stops.last { $0.kind == .finalMark })
    #expect(stop.collectionsOpen == 1 && stop.beforeRequestNs == r.finalBeforeRequestNs)
    #expect(stop.stoppedNs == stop.pauseNs &- stop.beforeRequestNs)
    #expect(rt.marking.missed == 0)
    rt.stop()
}
