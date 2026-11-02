// The marker thread: its idle cost (experiments/concurrent-young IdleTests,
// SPEC amendment 18: it waits untimed, and every transition it waits for
// signals it) and its QoS policy (utility by default, user-initiated while
// old-space headroom is low; ADR 0006 "Energy on device").

import Darwin
import Testing
@testable import KajoVM

let sparseSrc = pairSrc + """
; global 7 := an Array of n fresh Pairs, global 8 := every 20th of them.
; t0 = n, t1 = i, t2 = all, t3 = keep, t4 = p
method UndefinedObject mkSparse: temps=4
  push_lit @Array
  push_temp 0
  push_int 20
  send // 1
  send new: 1
  store_temp 3
  push_lit @Array
  push_temp 0
  send new: 1
  store_temp 2
  push_int 1
  store_temp 1
loop:
  push_temp 1
  push_temp 0
  le
  jump_if_false done
  push_lit @Pair
  send basicNew 0
  push_temp 1
  push_nil
  send x:y: 2
  store_temp 4
  push_temp 2
  push_temp 1
  push_temp 4
  send at:put: 2
  pop
  push_temp 1
  push_int 20
  send \\\\ 1
  push_int 0
  eq
  jump_if_false next
  push_temp 3
  push_temp 1
  push_int 20
  send // 1
  push_temp 4
  send at:put: 2
  pop
next:
  push_temp 1
  push_int 1
  add
  store_temp 1
  jump loop
done:
  push_nil
  push_int 7
  push_temp 2
  send globalAt:put: 2
  pop
  push_nil
  push_int 8
  push_temp 3
  send globalAt:put: 2
  return_top
end
; global 8 := a list of n Pairs (old once scavenged)
method UndefinedObject mkBig: temps=0
  push_nil
  push_int 8
  push_nil
  push_temp 0
  send list: 1
  send g:put: 2
  return_top
end
"""

/// A threaded runtime with a marker thread and background workers, as an
/// app would have it.
private func threadedRuntime(_ change: (inout MarkingConfig) -> Void = { _ in }) throws -> Runtime {
    try Runtime(sparseSrc, background: 3, heapBlocks: 2048, pollEvery: 64, configure: { c in
        c.nursery.bytes = 1 << 20
        c.nursery.age = 1
        c.marking.enabled = true
        c.marking.markerThread = true
        change(&c.marking)
    })
}

private func sleepMs(_ ms: Int) { usleep(useconds_t(ms * 1000)) }

@Test func aParkedVMDoesNotWakeItsMarker() throws {
    let rt = try threadedRuntime()
    #expect(rt.vm.hasMarkerThread)
    sleepMs(100)  // threads started and waiting
    let cpu0 = rt.vm.markerCPUNanoseconds, waits0 = rt.marking.markerWaits
    sleepMs(1000)
    let cpu = rt.vm.markerCPUNanoseconds &- cpu0, waits = rt.marking.markerWaits &- waits0
    #expect(cpu < 1_000_000, "marker CPU \(cpu) ns in 1 s parked")
    #expect(waits <= 5, "marker woke \(waits) times in 1 s parked")
    rt.stop()
}

/// Wait for cycle `n` to be applied: phase idle again. Answers the
/// milliseconds it took, nil on a timeout.
private func cycleDone(_ rt: Runtime, _ n: UInt64, within s: Double) -> Double? {
    let t0 = now()
    let ok = eventually(s) { rt.marking.cyclesCompleted >= n && rt.phase == .idle }
    return ok ? Double(now() &- t0) / 1e6 : nil
}

@Test func markingCompletesPromptlyAfterIdling() throws {
    let rt = try threadedRuntime()
    sleepMs(300)
    let p = rt.spawn("mkSparse:", [int(4000)])
    rt.waitAllTerminated()
    rt.vm.release(p)  // its result is the kept Array
    rt.scavenge()                                // promote the Pairs
    rt.vm.setGlobal(7, rt.image.nilObject)       // drop all but every 20th
    sleepMs(300)
    let c0 = rt.marking.cyclesCompleted, a0 = rt.marking.aborts
    // Two cycles, each started after an idle period: the marker must be
    // woken for marking, for sweeping and for the apply.
    for k in 1...2 {
        rt.vm.startCycle()
        let ms = cycleDone(rt, c0 + UInt64(k), within: underThreadSanitizer ? 20 : 3)
        #expect(ms != nil, "cycle \(k) did not finish within 3 s after idling")
        if ms == nil { break }
        sleepMs(200)
    }
    #expect(rt.marking.aborts == a0)
    let freed = rt.vm.cycleLog.suffix(2).map(\.entriesFreed).reduce(0, +)
    #expect(freed >= 3800, "entries freed by the two cycles: \(freed)")
    #expect(rt.marking.missed == 0)
    rt.noFailures()
    rt.stop()
}

/// Headroom below the threshold raises the marker to user-initiated at its
/// next poll; a cycle that ends with headroom above it lowers it again. The
/// QoS in effect is logged in each cycle's record.
@Test func theMarkerIsRaisedWhenHeadroomShrinksAndLoweredWhenItRecovers() throws {
    let rt = try Runtime(sparseSrc, background: 1, heapBlocks: 256, pollEvery: 64, configure: { c in
        c.nursery.bytes = 1 << 20
        c.nursery.age = 1
        c.marking.enabled = true
        c.marking.markerThread = true
        c.marking.floor = 2           // no automatic cycle
        c.marking.safetyFactor = 0    // no predictor
        c.marking.escalateBelow = 0.5
    })
    func cycle() -> CycleRecord? {
        let n = rt.marking.cyclesCompleted
        rt.vm.startCycle()
        guard cycleDone(rt, n + 1, within: underThreadSanitizer ? 30 : 5) != nil else {
            Issue.record("cycle did not finish")
            return nil
        }
        return rt.vm.cycleLog.last
    }
    let first = cycle()
    #expect(first?.markerQoS == QOS_CLASS_UTILITY.rawValue)
    #expect(rt.marking.qosEscalations == 0)
    // 200 000 Pairs, old: about 4.8 MB of an 8 MiB soft limit.
    let p = rt.spawn("mkBig:", [int(200_000)])
    rt.waitAllTerminated()
    rt.vm.release(p)  // its result is the list
    rt.scavenge()
    let low = cycle()
    #expect(rt.marking.qosEscalations == 1)
    #expect(low?.markerQoS == QOS_CLASS_USER_INITIATED.rawValue, "\(String(describing: low))")
    rt.vm.setGlobal(8, rt.image.nilObject)
    _ = cycle()   // frees the list: ends with headroom above the threshold
    #expect(rt.marking.qosLowerings == 1)
    let again = cycle()
    #expect(again?.markerQoS == QOS_CLASS_UTILITY.rawValue)
    #expect(rt.marking.missed == 0)
    rt.noFailures()
    rt.stop()
}
