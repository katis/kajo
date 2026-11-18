// A closed shell refuses its host's calls (docs/modules/closed-shell-calls.md).
// Since shell-close `ShellVM.close` always frees the VM and its image, so a
// host call that enters either after `close` reads freed memory.

import Darwin
import Foundation
import Testing
@testable import KajoCompiler
@testable import KajoVM

/// The hand-run (part 1, and the fix's trap): a closed shell, the freed VM
/// state overwritten, then one host call, named by `KAJO_CLOSED_SHELL_CALL`
/// (`runTurn`, `spawn` or `liveProcessCount`). It ends the test process
/// either way (signal 11 or a sanitizer report on the starting commit, the
/// refusal's message on the fix), so it runs by hand only:
/// `KAJO_CLOSED_SHELL_CALL=spawn swift test --filter aCallAfterCloseByHand`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["KAJO_CLOSED_SHELL_CALL"] != nil))
func aCallAfterCloseByHand() throws {
    let call = ProcessInfo.processInfo.environment["KAJO_CLOSED_SHELL_CALL"] ?? ""
    let shell = TestShell()
    let vm = try openShell(shell)
    #expect(try run(vm, "buildCounter", on: "ShellFixture") != nil)
    let r = vm.close()
    #expect(r.destroyed)
    // Reuse the freed memory as a busy process would: allocations of the
    // VM state's size and alignment filled with a non-pointer pattern.
    let scribble = HandRunScribble(bytes: MemoryLayout<VMState>.stride, alignment: 128, count: 4096)
    defer { scribble.free() }
    print("closed-shell-call \(call): calling after close (\(r))")
    fflush(stdout)
    switch call {
    case "runTurn": print("closed-shell-call runTurn answered \(vm.runTurn(budgetNs: 1_000_000).slices) slices")
    case "spawn": print("closed-shell-call spawn answered \(String(describing: vm.spawn("buildCounter", receiver: "ShellFixture")))")
    case "liveProcessCount": print("closed-shell-call liveProcessCount answered \(vm.liveProcessCount)")
    default: Issue.record("unknown call \(call)")
    }
    print("closed-shell-call \(call): returned")
}

/// Allocations of one size and alignment filled with 0xA5: a late reader
/// of freed memory of that size follows garbage (`DelayEndTests`' Scribble).
private struct HandRunScribble {
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
