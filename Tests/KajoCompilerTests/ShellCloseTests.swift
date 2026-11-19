// A closed shell frees its VM (docs/modules/shell-close.md). `ShellVM.close`
// terminates every Process, joins the VM's threads and frees the VM and its
// image at once. A Delay, an event's signal or a request's signal may still
// hold a pending root then; after `shutdown` no worker drains them, so
// nothing the close could wait for will come. Since the Delay fix every
// thread the VM does not join reaches it under `VMLife`'s lock, which
// `VM.destroy` ends before it frees anything. `close` answers a
// `ShellCloseReport`; no test here asserts that it was fast.

import Darwin
import Foundation
import Synchronization
import Testing
@testable import KajoCompiler
@testable import KajoVM

/// Bounded waits for something that must come (a hang only reaches them).
private let closeWait: Double = compilerTestsUnderThreadSanitizer ? 600 : 120

private func until(_ seconds: Double = closeWait, _ cond: () -> Bool) -> Bool {
    let end = ShellVM.now() + UInt64(seconds * 1e9)
    while !cond() {
        if ShellVM.now() > end { return false }
        usleep(1000)
    }
    return true
}

/// The broken variant (the old 3 s wait put back): the reproducing test
/// then fails its named check. By hand only, since it leaks a VM:
/// `KAJO_BROKEN_SHELL_CLOSE=1 swift test --filter aShellClosedWithADelay`.
private let brokenOldWait = ProcessInfo.processInfo.environment["KAJO_BROKEN_SHELL_CLOSE"] != nil

/// A thread a test joins.
private final class Joined: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    init(_ body: @escaping @Sendable () -> Void) {
        let d = done
        let t = Thread {
            body()
            d.signal()
        }
        t.stackSize = 1 << 20
        t.start()
    }
    func join() { done.wait() }
}

private final class Reports: @unchecked Sendable {
    let all = Mutex<[ShellCloseReport]>([])
}

private final class Race: @unchecked Sendable {
    let arrived = Atomic<Int>(0)
    let closed = Atomic<Bool>(false)
    let posts = Atomic<Int>(0)
}

@Suite struct ShellCloseTests {
    /// Part 1's reproduction: a started shell with one Process waiting on a
    /// long Delay is closed. The Delay's Semaphore holds a pending root that
    /// only a drain could release, and no worker drains after `shutdown`.
    /// The check reads the VM's life cell, which outlives the VM: `ended` is
    /// set by `VM.destroy` and by nothing else. On 5778e78 `close` waited its
    /// 3 s and returned without destroying ("close left the VM undestroyed",
    /// 3 runs of 3).
    @Test func aShellClosedWithADelayPendingFreesItsVM() throws {
        let shell = TestShell()
        let vm = try openShell(shell)
        if brokenOldWait { vm.brokenOldWaitSeconds = 3 }
        let p = try #require(vm.spawn("evaluate:", receiver: "Compiler",
                                      arguments: [.string("(Delay forSeconds: 60) wait. nil")]))
        #expect(until { vm.vm.timersPending == 1 }, "the Delay was never armed")
        // The timer is armed before the Process is waiting: wait for the
        // state too (one read failed 1 full run in 5, Types 3's gates).
        #expect(until { vm.state(of: p) == .waiting }, "the Process never waited: \(vm.state(of: p))")
        let life = vm.vm.life
        let r = vm.close()
        #expect(life.snapshot.ended, "close left the VM undestroyed")
        #expect(r.destroyed, "close answered \(r)")
        // The Delay's Semaphore is the root the old wait waited for.
        #expect(r.pendingRoots == 1 && r.timersPending == 1 && r.undeliveredSignals == 0, "\(r)")
        print("shell-close repro \(r)")
    }

    /// An event the loop never took, and one posted after `shutdown` while
    /// the loop's Semaphore is still registered: the second holds a root
    /// and a queued signal no worker will drain. Both closes destroy; the
    /// counts say which was which.
    @Test func aCloseWithAnEventNotTakenFreesItsVM() throws {
        // Posted before the loop exists: queued, no Semaphore, no root.
        do {
            let shell = TestShell()
            let vm = try openShell(shell)
            vm.post(ShellEvent(kind: .synthetic, value: .int(1), timeNs: ShellVM.now()))
            #expect(vm.queuedEvents == 1)
            let r = vm.close()
            #expect(r == ShellCloseReport(destroyed: true), "\(r)")
        }
        // Posted in the window after `shutdown`, the loop registered.
        let shell = TestShell()
        let vm = try openShell(shell)
        #expect(try run(vm, "start", on: "UIEventLoop") == .bool(true))
        let v = vm
        vm.afterShutdownForTests = { v.post(ShellEvent(kind: .synthetic, value: .int(2), timeNs: ShellVM.now())) }
        let r = vm.close()
        #expect(r.destroyed && r.pendingRoots == 1 && r.undeliveredSignals == 1 && r.timersPending == 0, "\(r)")
        // After the close a post touches only the bridge's queue.
        vm.post(ShellEvent(kind: .synthetic, value: .int(3), timeNs: ShellVM.now()))
        #expect(vm.vm.lateSignals == 0)
    }

    /// A protocol request queued after `shutdown` with the protocol
    /// Process's Semaphore registered: destroyed, one root, one signal
    /// undelivered.
    @Test func aCloseWithARequestQueuedFreesItsVM() throws {
        let shell = TestShell()
        let vm = try openShell(shell)
        vm.openProtocol()
        #expect(try run(vm, "start", on: "DevProtocol", main: false) == .bool(true))
        let v = vm
        vm.afterShutdownForTests = { v.postRequest(connection: 1, json: Array(#"{"op":"ping","id":1}"#.utf8)) }
        let r = vm.close()
        #expect(r.destroyed && r.pendingRoots == 1 && r.undeliveredSignals == 1 && r.timersPending == 0, "\(r)")
        #expect(vm.queuedRequests == 1)
    }

    /// `close` twice and then `deinit`: one destroy. The observer sees every
    /// call's report, the deinit's included.
    @Test func closeTwiceThenDeinitDestroysOnce() throws {
        let reports = Reports()
        do {
            let shell = TestShell()
            let vm = try openShell(shell)
            vm.closeObserver = { r in reports.all.withLock { $0.append(r) } }
            _ = try run(vm, "buildCounter", on: "ShellFixture")
            #expect(vm.close().destroyed)
            #expect(!vm.close().destroyed)
        }
        let all = reports.all.withLock { $0 }
        #expect(all.map(\.destroyed) == [true, false, false], "\(all)")
        // A shell dropped without a close is closed by its deinit.
        let fresh = Reports()
        do {
            let shell = TestShell()
            let vm = try openShell(shell)
            vm.closeObserver = { r in fresh.all.withLock { $0.append(r) } }
        }
        #expect(fresh.all.withLock { $0.map(\.destroyed) } == [true])
    }

    /// A close racing posts from other threads (events and requests, both
    /// Semaphores registered), every thread started at a gate. Under the
    /// sanitizer in the gates: no report. Every post is taken by the bridge;
    /// a signal pushed before the end is drained or freed undelivered, one
    /// after it is refused and counted (`lateSignals`).
    @Test func aCloseRacingPostsIsDecidedByTheLocks() throws {
        let rounds = 8, posters = 4
        var undelivered = 0, late: UInt64 = 0, roots = 0, posts = 0
        for round in 0..<rounds {
            let shell = TestShell()
            let vm = try openShell(shell)
            vm.openProtocol()
            #expect(try run(vm, "start", on: "UIEventLoop") == .bool(true))
            #expect(try run(vm, "start", on: "DevProtocol", main: false) == .bool(true))
            let race = Race()
            let threads = (0..<posters).map { i in
                Joined {
                    race.arrived.add(1, ordering: .relaxed)
                    while race.arrived.load(ordering: .relaxed) < posters + 1 {}
                    var n = 0, after = 0
                    while after < 200 {
                        if i % 2 == 0 {
                            vm.post(ShellEvent(kind: .synthetic, value: .int(Int64(n)), timeNs: ShellVM.now()))
                        } else {
                            vm.postRequest(connection: 1, json: Array(#"{"op":"ping","id":1}"#.utf8))
                        }
                        n += 1
                        if race.closed.load(ordering: .relaxed) { after += 1 }
                    }
                    race.posts.add(n, ordering: .relaxed)
                }
            }
            race.arrived.add(1, ordering: .relaxed)
            while race.arrived.load(ordering: .relaxed) < posters + 1 {}
            let r = vm.close()
            race.closed.store(true, ordering: .relaxed)
            for t in threads { t.join() }
            #expect(r.destroyed, "round \(round): \(r)")
            let n = race.posts.load(ordering: .relaxed)
            #expect(r.undeliveredSignals <= n, "round \(round): \(r), \(n) posts")
            undelivered += r.undeliveredSignals
            late += vm.vm.lateSignals
            roots += r.pendingRoots
            posts += n
        }
        print("shell-close-race rounds=\(rounds) posters=\(posters) posts=\(posts) pendingRoots=\(roots) undelivered=\(undelivered) late=\(late)")
    }
}
