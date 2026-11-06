// Collectors review, finding 4: the barrier word is shared. Bit 0 is
// module 5's marking, bits 1 and up module 7's count (2 per open young
// collection, 2 for the VM under the young stress flag `barrierAlwaysOn`).
// Marking stored the whole word, so after the first cycle the stress flag
// no longer sent stores to the young deletion barrier, and the VM's end
// subtracted 2 from a word that was 0. Marking now sets and clears bit 0
// only, and the stop verifier checks the word at every stop.

import Testing
@testable import KajoVM

private func barrierRuntime() throws -> Runtime {
    try Runtime(markingSrc, background: 1, start: false, configure: { c in
        c.nursery.bytes = 1024 * 1024
        c.nursery.age = 1
        c.marking.enabled = true
        c.marking.markerThread = false
        c.young.stress = .barrierAlwaysOn
    })
}

private func deletionBarrierCalls(_ rt: Runtime) -> UInt64 {
    (0..<(rt.vm.config.backgroundWorkers + 2)).reduce(0) { $0 &+ rt.vm.youngWorkerCounters($1).deletionBarrierCalls }
}

@Test func markingKeepsModule7sCountInTheBarrierWord() throws {
    let rt = try barrierRuntime()
    #expect(rt.vm.barrierWordValue == 2)
    // A whole cycle: on at the initial mark, off at the final mark.
    rt.vm.startCycle()
    #expect(rt.phase == .marking && rt.vm.barrierWordValue == 3)
    rt.finishCycle()
    #expect(rt.vm.barrierWordValue == 2)
    // The stress flag still sends every store to the young deletion
    // barrier after the cycle.
    let before = deletionBarrierCalls(rt)
    rt.run("mkH")
    #expect(deletionBarrierCalls(rt) > before)
    // A cycle abandoned by an old-space operation (module 1's collect).
    rt.vm.startCycle()
    #expect(rt.vm.barrierWordValue == 3)
    rt.vm.collect()
    #expect(rt.phase == .idle && rt.vm.barrierWordValue == 2)
    #expect(rt.vm.counters.stopVerifierFailures == 0)
    rt.noFailures()
    rt.stop()
}

/// The verifier at every stop sees a word that does not count what it
/// should: set a stray count bit by hand and the next stop reports it.
@Test func theStopVerifierChecksTheBarrierWord() throws {
    let rt = try barrierRuntime()
    rt.vm.withWorldStopped { unsafe barrierWord(rt.vm.state.pointee.flag).pointee.wrappingAdd(2, ordering: .relaxed) }
    #expect(rt.vm.counters.stopVerifierFailures == 1)
    rt.vm.withWorldStopped { unsafe barrierWord(rt.vm.state.pointee.flag).pointee.wrappingSubtract(2, ordering: .relaxed) }
    #expect(rt.vm.counters.stopVerifierFailures == 1)
    rt.stop()
}
