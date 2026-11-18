import Foundation
import Darwin
import Synchronization
import Testing
@testable import KajoVM

// A Delay does not outlive its VM (docs/modules/delay-outlives-vm.md).
// `startDelay` arms a one-shot GCD timer that signals its VM from outside.
// The VM's end (`VMLife.end`, in `VM.destroy`) takes the life cell's lock
// that every such signal holds while it touches the VM, so a timer that
// comes later does nothing and is counted (`VM.lateSignals`), and the end
// report says how many timers were pending (`VMEndReport.timersPending`).

/// Part 1's reproduction: a VM with one Process waiting on a 2 s Delay is
/// shut down and destroyed at once; the freed VM state is reused and
/// overwritten (as minutes of a busy test process did in Types 2's gate
/// run), and the test stays alive until the timer has fired. On 0395be3
/// the timer's `signalFromOutside` followed the overwritten pointer: signal
/// 11 in a debug build, "ThreadSanitizer: SEGV ... External.swift:30" under
/// the sanitizer, 3 runs of 3 each.
@Test func aDelayPendingWhenTheVMEndsDoesNotTouchIt() throws {
    try delayPendingAtTheEnd(switches: VMTestSwitches())
}

/// The broken variant: the fix switched off (`lateSignalsIgnoreEnd`). It
/// crashes the test process, so it runs by hand only:
/// `KAJO_BROKEN_DELAY_END=1 swift test --filter brokenVariant`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["KAJO_BROKEN_DELAY_END"] != nil))
func brokenVariantALateTimerTouchesTheFreedVM() throws {
    var s = VMTestSwitches()
    s.lateSignalsIgnoreEnd = true
    try delayPendingAtTheEnd(switches: s)
}

private func delayPendingAtTheEnd(switches: VMTestSwitches) throws {
    let rt = try Runtime(sleeperSrc, background: 1, configure: { $0.testSwitches = switches })
    let p = rt.spawn("sleeper:", [int(2000)])
    #expect(eventually { rt.state(p) == .waiting })
    // The pending table holds the Delay's Semaphore, as it always has.
    #expect(rt.vm.pendingRootCount == 1)
    #expect(rt.vm.timersPending == 1)
    let end = rt.stop()
    #expect(end.timersPending == 1)
    #expect(end.undeliveredSignals == 0)
    let scribble = Scribble(bytes: MemoryLayout<VMState>.stride, alignment: 128, count: 4096)
    defer { scribble.free() }
    // Alive past the timer's time: until it has fired into nothing. A GCD
    // timer's callback can wait long for a thread under the sanitizer and
    // load, so the bound is long and only a hang reaches it.
    #expect(eventually(120) { rt.vm.lateSignals == 1 }, "the timer did not fire in 120 s")
    #expect(rt.vm.timersPending == 0)
}

/// A timer that fires between `shutdown` and `destroy` is still taken: its
/// signal is queued (no worker drains it any more) and `destroy` frees the
/// node, counted as undelivered; nothing is late.
@Test func aTimerFiringBetweenShutdownAndDestroyIsTaken() throws {
    let rt = try Runtime(sleeperSrc, background: 1)
    let p = rt.spawn("sleeper:", [int(1500)])
    #expect(eventually { rt.state(p) == .waiting })
    rt.vm.shutdown()
    #expect(eventually(120) { rt.vm.timersPending == 0 }, "the timer did not fire in 120 s")
    #expect(!rt.vm.isQuiescent)  // the signal waits in the external queue
    let end = rt.stop(shutdown: false)
    #expect(end.timersPending == 0)
    #expect(end.undeliveredSignals == 1)
    #expect(rt.vm.lateSignals == 0)
}

/// Every way in through `VMRef` (the bridge's, the tests') is refused once
/// the VM has ended: a signal does nothing, a root answers -1, both counted.
@Test func aVMRefHeldPastTheEndIsRefused() throws {
    let rt = try Runtime(sleeperSrc, background: 1)
    let sem = rt.vm.newSemaphore()
    let ref = rt.vm.ref
    rt.vm.release(sem)
    let end = rt.stop()
    #expect(end.timersPending == 0)
    let scribble = Scribble(bytes: MemoryLayout<VMState>.stride, alignment: 128, count: 4096)
    defer { scribble.free() }
    let t = TestThread {
        ref.signalFromOutside(sem, handle: nil)
        _ = ref.rootPending(sem)
    }
    t.join()
    #expect(ref.rootPending(sem) == -1)
    #expect(rt.vm.lateSignals == 3)
}

/// A timer and the VM's end at the same moment: many VMs, each ended by its
/// own thread at a time spread around its Delay's (the threads start at a
/// gate), under the sanitizer in the gates. Whichever side takes the life
/// cell's lock first decides; the counts must agree either way: a timer
/// pending at the end fires into nothing (`lateSignals` 1), one that fired
/// before it was delivered or freed undelivered.
@Test func aTimerAndTheEndAtTheSameMomentAreDecidedByTheLock() throws {
    let vms = 16, delayMs = 1500
    let rts = try (0..<vms).map { _ in try Runtime(sleeperSrc, background: 1, heapBlocks: 512, entries: 1 << 16) }
    let ps = rts.map { $0.spawn("sleeper:", [int(Int64(delayMs))]) }
    let t0 = now()
    for (rt, p) in zip(rts, ps) {
        #expect(eventually { let s = rt.state(p); return s == .waiting || s == .terminated })
    }
    let box = RaceBox()
    let threads = (0..<vms).map { i in
        let rt = rts[i]
        // From 150 ms before the Delay's time to 300 ms after it.
        let at = t0 + UInt64(delayMs - 150 + i * 450 / (vms - 1)) * 1_000_000
        return TestThread {
            box.arrived.add(1, ordering: .relaxed)
            while box.arrived.load(ordering: .relaxed) < vms {}
            while now() < at { usleep(200) }
            rt.vm.shutdown()
            let e = rt.vm.destroy()
            box.ends.withLock { $0[i] = e }
        }
    }
    for t in threads { t.join() }
    var pendingAtEnd = 0, delivered = 0, undelivered = 0
    for (i, rt) in rts.enumerated() {
        let e = box.ends.withLock { $0[i] }!
        #expect(eventually(120) { rt.vm.timersPending == 0 }, "VM \(i): the timer did not fire in 120 s")
        #expect(e.timersPending + e.undeliveredSignals <= 1, "VM \(i): \(e)")
        #expect(Int(rt.vm.lateSignals) == e.timersPending, "VM \(i): \(e), late \(rt.vm.lateSignals)")
        if e.timersPending == 1 { pendingAtEnd += 1 } else if e.undeliveredSignals == 1 { undelivered += 1 } else { delivered += 1 }
        rt.image.destroy()
    }
    print("delay-race vms=\(vms) pendingAtEnd=\(pendingAtEnd) undelivered=\(undelivered) delivered=\(delivered)")
    #expect(pendingAtEnd + undelivered + delivered == vms)
}

private final class RaceBox: @unchecked Sendable {
    let ends = Mutex<[Int: VMEndReport]>([:])
    let arrived = Atomic<Int>(0)
}

/// Allocations of one size and alignment filled with a non-pointer pattern:
/// a late reader of freed memory of that size follows garbage.
struct Scribble {
    let blocks: [UnsafeMutableRawPointer]
    init(bytes: Int, alignment: Int, count: Int) {
        blocks = (0..<count).map { _ in
            let p = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: alignment)
            p.initializeMemory(as: UInt8.self, repeating: 0xA5, count: bytes)
            return p
        }
    }
    func free() { for p in blocks { p.deallocate() } }
}
