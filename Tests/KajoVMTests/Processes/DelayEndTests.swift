import Foundation
import Darwin
import Testing
@testable import KajoVM

// A Delay does not outlive its VM (docs/modules/delay-outlives-vm.md).
// `startDelay` arms a one-shot GCD timer that signals its VM from outside;
// nothing ends the timer when the VM ends.

/// Part 1's reproduction: a VM with one Process waiting on a 2 s Delay is
/// shut down and destroyed at once; the test stays alive past the timer's
/// time. On the starting commit the timer's `signalFromOutside` reads the
/// freed VM state (a sanitizer report, or a crash).
@Test func aDelayPendingWhenTheVMEndsDoesNotTouchIt() throws {
    let rt = try Runtime(sleeperSrc, background: 1)
    let p = rt.spawn("sleeper:", [int(2000)])
    #expect(eventually { rt.state(p) == .waiting })
    #expect(rt.vm.pendingRootCount == 1)
    rt.stop()
    // The VM state's memory is reused and overwritten, as minutes of a
    // busy test process did in Types 2's gate run: a late timer that reads
    // it follows a garbage pointer in any build.
    let scribble = Scribble(bytes: MemoryLayout<VMState>.stride, alignment: 128, count: 4096)
    usleep(4_000_000)
    scribble.free()
}

/// Allocations of one size and alignment filled with a non-pointer pattern.
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
