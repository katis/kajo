import Foundation
import Darwin
import Synchronization
import Testing
@testable import KajoVM

// The VM's Delay timers and the process's global queue (docs/modules/known-faults.md,
// item 1). `startDelay` arms each Delay with `DispatchQueue.global().asyncAfter`;
// the owner approved a queue of their own after a counter of how late a Delay
// fires (`VM.delayLateness`). Part 1 measured at most 22.7 ms late in the
// loaded sanitizer suite and found that this test passes on the starting
// commit, so no queue was built (the module's rule). These tests keep the
// property and the counter checked.

/// A Delay fires while the process's default global queue can start
/// nothing new. Blocks that spin hold every thread that queue may have (a
/// canary queued after them has not run); a Process then waits on a 50 ms
/// Delay, and it must end while the canary still waits. It passed 3 of 3
/// on the starting commit (183b5db, part 1's `item1/full-queue-before/`):
/// the Delay's timer block ran 1 to 6 ms late while the canary still
/// waited, where the host's timers on 0b53285 never fired in 20 s. It cannot
/// fail there; it is the guard that a later change keeps it so.
@Test func aDelayFiresWhileTheGlobalQueueIsFull() throws {
    let rt = try Runtime(sleeperSrc, background: 1)
    defer { rt.stop() }
    let release = Atomic<Bool>(false)
    let spinning = Atomic<Int>(0)
    let canary = Atomic<Bool>(false)
    let spinners = ProcessInfo.processInfo.activeProcessorCount * 4
    for _ in 0..<spinners {
        DispatchQueue.global().async {
            spinning.add(1, ordering: .relaxed)
            while !release.load(ordering: .relaxed) {}
        }
    }
    defer { release.store(true, ordering: .relaxed) }
    // The canary is the evidence that the queue is full (the host timers'
    // test, Review3SmallFixesTests, has the same shape).
    usleep(200_000)
    DispatchQueue.global().async { canary.store(true, ordering: .relaxed) }
    usleep(200_000)
    let fullBefore = !canary.load(ordering: .relaxed)
    let p = rt.spawn("sleeper:", [int(50)])
    let armed = now()
    // A hang's bound only: the claim is the order (the Delay before the
    // canary) and the lateness below, not this clock.
    while rt.state(p) != .terminated, now() - armed < 20_000_000_000 { usleep(1000) }
    let ended = rt.state(p) == .terminated
    let endedWhileFull = ended && !canary.load(ordering: .relaxed)
    let ms = Double(now() - armed) / 1e6
    let held = spinning.load(ordering: .relaxed)
    release.store(true, ordering: .relaxed)
    let late = rt.vm.delayLateness
    print("delay-queue full=\(fullBefore) ended=\(ended) whileFull=\(endedWhileFull) ms=\(ms) spinning=\(held) of \(spinners) "
          + "fired=\(late.fired) lateMaxMs=\(late.maxMs)")
    // The Delay's lateness against a ceiling: fired minus due, read from
    // the VM's own counter (a timer that never fired reads the 20 s wait).
    let value = late.fired == 1 ? late.maxMs : ms
    printMargin("delay.globalQueueFull", .ceiling, value: value, bound: 1000, unit: "ms")
    #expect(fullBefore, "the global queue ran the canary: it was not full (\(held) of \(spinners) blocks spinning)")
    #expect(endedWhileFull, "the Delay did not end while the global queue was full (\(ms) ms, \(held) of \(spinners) spinning)")
    #expect(late.fired == 1 && late.maxMs < 1000, "the Delay fired \(late.fired) times, \(late.maxMs) ms late")
}

/// The counter counts what fired: twenty Delays of 30 ms, each noted once,
/// none fired early, the mean no larger than the maximum.
@Test func theLatenessCounterNotesEveryDelay() throws {
    let rt = try Runtime(sleeperSrc, background: 1)
    defer { rt.stop() }
    for _ in 0..<20 { rt.spawn("sleeper:", [int(30)]) }
    rt.waitAllTerminated()
    let late = rt.vm.delayLateness
    print("delay-lateness fired=\(late.fired) meanMs=\(late.meanMs) maxMs=\(late.maxMs) late10=\(late.late10ms) late100=\(late.late100ms)")
    #expect(late.fired == 20)
    #expect(late.meanMs <= late.maxMs)
    #expect(late.late100ms <= late.late10ms && late.late10ms <= late.fired)
}
