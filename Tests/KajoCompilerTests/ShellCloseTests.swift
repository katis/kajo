// A closed shell frees its VM (docs/modules/shell-close.md). `ShellVM.close`
// terminates every Process, joins the VM's threads and frees the VM and its
// image. A Delay, an event's signal or a request's signal may still hold a
// pending root then; after `shutdown` no worker drains them, so nothing the
// close could wait for will come. Since the Delay fix every thread the VM
// does not join reaches it under `VMLife`'s lock, which `VM.destroy` ends
// before it frees anything.

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

@Suite struct ShellCloseTests {
    /// Part 1's reproduction: a started shell with one Process waiting on a
    /// long Delay is closed. The Delay's Semaphore holds a pending root that
    /// only a drain could release, and no worker drains after `shutdown`.
    /// The check reads the VM's life cell, which outlives the VM: `ended` is
    /// set by `VM.destroy` and by nothing else. On 5778e78 `close` waited its
    /// 3 s and returned without destroying.
    @Test func aShellClosedWithADelayPendingFreesItsVM() throws {
        let shell = TestShell()
        let vm = try openShell(shell)
        let p = try #require(vm.spawn("evaluate:", receiver: "Compiler",
                                      arguments: [.string("(Delay forSeconds: 60) wait. nil")]))
        #expect(until { vm.vm.timersPending == 1 }, "the Delay was never armed")
        #expect(vm.state(of: p) == .waiting)
        let life = vm.vm.life
        vm.close()
        #expect(life.snapshot.ended, "close left the VM undestroyed")
    }
}
