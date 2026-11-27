// Gate reliability (docs/modules/gate-reliability.md), fault A: `ShellVM.close`
// terminates every Process and waits until none is alive. One loaded
// sanitizer run sat in that wait for two hours with every VM thread idle.
// Part 1 found why: `VM.terminateAll` took one snapshot, and a Process made
// after it (forked by a Process still running then) was terminated by
// nobody. The close now terminates in rounds until none is alive, and gives
// up after a quiet bound with no Process ending, naming the Processes left
// (`ShellCloseReport.liveProcesses`). These tests close a shell over each
// shape part 1 tried; the close runs on a thread of its own and the test
// waits for it a bounded time (its own watchdog), so a close that never
// returns fails here instead of hanging the suite. The broken variant puts
// the untimed wait back: `KAJO_BROKEN_CLOSE_WAIT=1 swift test --filter
// aCloseWithAProcessForkingWaitersReturns` (by hand; it hangs the close
// until the watchdog and leaks the VM).

import Darwin
import Foundation
import Synchronization
import Testing
@testable import KajoCompiler
@testable import KajoVM

private let brokenUntimedWait = ProcessInfo.processInfo.environment["KAJO_BROKEN_CLOSE_WAIT"] != nil

/// The watchdog on a close: something that must come (a hang only reaches
/// it).
private let closeWatchdog: Double = compilerTestsUnderThreadSanitizer ? 600 : 120

/// A close on a thread of its own: `returned` within the watchdog or not.
private final class Closer: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var report: ShellCloseReport? = nil
    let t0 = ShellVM.now()
    private(set) var tEnd: UInt64 = 0

    init(_ vm: ShellVM) {
        let t = Thread { [self] in
            let r = vm.close()
            lock.lock(); report = r; tEnd = ShellVM.now(); lock.unlock()
            done.signal()
        }
        t.stackSize = 1 << 20
        t.start()
    }

    /// The report, or nil when the close did not return within `seconds`.
    func wait(_ seconds: Double = closeWatchdog) -> ShellCloseReport? {
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return report
    }

    var seconds: Double { lock.lock(); defer { lock.unlock() }; return Double(tEnd &- t0) / 1e9 }
}

/// Spawn `source` through `Compiler evaluate:`, background or main.
private func evaluate(_ vm: ShellVM, _ source: String, main: Bool = false) throws -> ShellProcess {
    try #require(vm.spawn("evaluate:", receiver: "Compiler", arguments: [.string(source)], main: main))
}

/// Turns on this thread for `ms` (the main-affine Processes run here).
private func turns(_ vm: ShellVM, ms: Double) {
    let end = ShellVM.now() + UInt64(ms * 1e6)
    while ShellVM.now() < end { if vm.runTurn(budgetNs: 2_000_000).slices == 0 { usleep(500) } }
}

/// Close on a thread of its own and wait for it; a close that does not
/// return is an issue naming the Processes still alive (read here, from the
/// test's thread: the close holds no lock the read takes).
@discardableResult
private func closeWithin(_ vm: ShellVM, _ what: String) -> ShellCloseReport? {
    let c = Closer(vm)
    guard let r = c.wait() else {
        let live = vm.vm.liveProcesses()
        Issue.record("\(what): close did not return in \(Int(closeWatchdog)) s; \(live.count) live: \(live.map(\.description).joined(separator: "; "))")
        return nil
    }
    print("close-wait \(what): \(String(format: "%.3f", c.seconds)) s \(r)")
    #expect(r.destroyed && r.liveProcesses.isEmpty, "\(what): \(r)")
    return r
}

@Suite struct CloseWaitTests {
    /// Starting position 2's first half: Processes waiting on Semaphores no
    /// one will signal, one of them inside a Mutex's critical block. The
    /// host's termination ends a waiting Process at once, without unwinding.
    @Test func aCloseWithProcessesWaitingForeverReturns() throws {
        let vm = try openShell(TestShell())
        let source = "| m | m := Mutex new. [m critical: [Semaphore new wait]] forkAt: 1. [m critical: [nil]] forkAt: 1. Semaphore new wait"
        _ = try evaluate(vm, source)
        #expect(drive(vm) { vm.liveProcessCount == 3 }, "live \(vm.liveProcessCount)")
        turns(vm, ms: 100)
        let r = closeWithin(vm, "waiting")
        #expect(r?.destroyed == true)
    }

    /// Starting position 1: main-affine Processes, one ready and never run
    /// (no turn after its spawn), one waiting. The closing thread gives no
    /// turn, and the host's termination needs none.
    @Test func aCloseWithMainAffineProcessesReturns() throws {
        let vm = try openShell(TestShell())
        let w = try evaluate(vm, "Semaphore new wait", main: true)
        #expect(drive(vm) { vm.state(of: w) == .waiting })
        _ = try evaluate(vm, "3 + 4", main: true)
        let r = closeWithin(vm, "main")
        #expect(r?.destroyed == true)
    }

    /// A Process forked after the close's snapshot of the live Processes:
    /// a background Process that forks waiters in rounds of 50 and signals
    /// each round's when it is full. At the close it is running; it is
    /// terminated at its next budget check (every 1024 polls), and the
    /// waiters it forks before that were in no snapshot and are never
    /// terminated: the round it did not finish waits for ever.
    @Test func aCloseWithAProcessForkingWaitersReturns() throws {
        let vm = try openShell(TestShell())
        let source = """
            | gate n | gate := Semaphore new. n := 0.
            [true] whileTrue: [[gate wait] forkAt: 1. n := n + 1. n = 50 ifTrue: [50 timesRepeat: [gate signal]. n := 0]]
            """
        if brokenUntimedWait { vm.brokenUntimedWait = true }
        _ = try evaluate(vm, source)
        #expect(drive(vm) { vm.liveProcessCount > 10 }, "live \(vm.liveProcessCount)")
        let r = closeWithin(vm, "forking waiters")
        #expect(r?.destroyed == true)
    }

    /// The same with main-affine children: a background Process forks
    /// main-affine Processes, at most 20 not yet run, which only a turn runs.
    /// The test turns until the close; the close's thread gives none, so a
    /// child forked after the snapshot is never run and never terminated.
    @Test func aCloseWithAProcessForkingMainAffineProcessesReturns() throws {
        let vm = try openShell(TestShell())
        let source = """
            | pending | pending := 0.
            [true] whileTrue: [pending < 20 ifTrue: [pending := pending + 1.
                [pending := pending - 1] fork: #forkedValue with: nil priority: 1 main: true exit: nil]]
            """
        _ = try evaluate(vm, source)
        #expect(drive(vm) { vm.liveProcessCount > 5 }, "live \(vm.liveProcessCount)")
        turns(vm, ms: 300)
        let r = closeWithin(vm, "forking main")
        #expect(r?.destroyed == true)
    }

    /// The tools' shape (DevProtocol's `run:` takes its lock first): a
    /// Process holds a Mutex most of the time, so the close terminates it at
    /// a budget check inside the critical block and the Mutex stays held
    /// (the host's termination does not unwind); another forks Processes
    /// that take the Mutex, at most 20 not yet through. One forked after the
    /// snapshot waits on it for ever.
    @Test func aCloseWithAProcessForkingWaitersOnAHeldMutexReturns() throws {
        let vm = try openShell(TestShell())
        let source = """
            | m x k | m := Mutex new. x := 0. k := 0.
            [[true] whileTrue: [m critical: [200 timesRepeat: [x := x + 1]]]] forkAt: 1.
            [true] whileTrue: [k < 20 ifTrue: [k := k + 1. [m critical: [k := k - 1]] forkAt: 1]]
            """
        _ = try evaluate(vm, source)
        #expect(drive(vm) { vm.liveProcessCount > 3 }, "live \(vm.liveProcessCount)")
        turns(vm, ms: 100)
        let r = closeWithin(vm, "held mutex")
        #expect(r?.destroyed == true)
    }
}

/// A host callback through which the bound's test holds a worker.
private final class Holder: @unchecked Sendable {
    let entered = Atomic<Bool>(false)
    let seconds: Double
    init(seconds: Double) { self.seconds = seconds }
    var callbacks: ShellCallbacks {
        var c = TestShell().callbacks
        c.client = { [self] _ in
            entered.store(true, ordering: .relaxed)
            usleep(UInt32(seconds * 1e6))
            return .nil
        }
        return c
    }
}

@Suite struct CloseBoundTests {
    /// The bound: a Process that no round can end (it runs a host callback
    /// that holds its worker, so it never reaches a budget check while the
    /// close waits). The close gives up after its quiet bound, names the
    /// Process (running, on a worker, its termination requested) and
    /// destroys the VM; it returns once the callback lets the worker go
    /// (the join of a thread held in a host callback is not bounded).
    @Test func aCloseWithAProcessThatCannotEndGivesUpAndSaysWhich() throws {
        let holder = Holder(seconds: 3)
        var o = Headless.Options()
        o.heapMiB = 256
        o.workers = 2
        let vm = try ShellVM(image: shellImage, options: o, callbacks: holder.callbacks)
        vm.start()
        vm.closeQuietSeconds = 0.5
        vm.expectsLiveAtClose = true
        let life = vm.vm.life
        _ = try evaluate(vm, "ClientTransport primCall: 'targets' handle: nil with: #()")
        #expect(drive(vm) { holder.entered.load(ordering: .relaxed) }, "the callback was never entered")
        let c = Closer(vm)
        let r = try #require(c.wait(), "the close did not return in \(Int(closeWatchdog)) s")
        print("close-bound: \(String(format: "%.3f", c.seconds)) s \(r)")
        #expect(life.snapshot.ended && r.destroyed, "\(r)")
        let p = try #require(r.liveProcesses.first, "\(r)")
        #expect(r.liveProcesses.count == 1 && p.state == "running" && p.runningOn >= 0 && p.terminateRequested, "\(r)")
    }
}
