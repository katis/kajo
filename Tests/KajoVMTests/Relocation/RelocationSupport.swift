// Helpers for the concurrent-relocation tests (docs/modules/relocation.md).
// Every runtime has every verifier on (`Runtime` sets `verify` and
// `.record`): the relocation verifier runs at the end of every pause, the
// mark verifier at every final mark, module 4's at every scavenge.

import Darwin
import Synchronization
import Testing
@testable import KajoVM

/// Pair (pairSrc) plus: `mkSparse:` (global 7 := an Array of n Pairs with x
/// = 1..n, global 8 := an Array of every 20th), `holdFirst` (a frame that
/// holds `(global 8) at: 1` in a temp forever).
let relocSrc = pairSrc + """
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
  send g:put: 2
  pop
  push_nil
  push_int 8
  push_temp 3
  send g:put: 2
  pop
  push_int 0
  return_top
end
; (global 8) at: 1 in a temp, then spin forever
method UndefinedObject holdFirst temps=1
  push_nil
  push_int 8
  send g: 1
  push_int 1
  send at: 1
  store_temp 0
loop:
  push_temp 0
  pop
  jump loop
end
; (global 8) replaceFrom: 1 to: 1 with: (global 9) startingAt: 1
method UndefinedObject copyNine temps=0
  push_nil
  push_int 8
  send g: 1
  push_int 1
  push_int 1
  push_nil
  push_int 9
  send g: 1
  push_int 1
  send replaceFrom:to:with:startingAt: 4
  pop
  push_int 0
  return_top
end
method Object replaceFrom:to:with:startingAt: temps=0 prim=38
  push_lit @Object
  return_top
end

"""

/// Manual marking (the test is the marker) and manual relocation (the test
/// calls the pass or the steps), promotion on first survival.
func relocRuntime(background: Int = 1, _ change: (inout RelocationConfig) -> Void = { _ in }) throws -> Runtime {
    try Runtime(relocSrc, background: background, heapBlocks: 2048, start: false, configure: { c in
        c.nursery.bytes = 1 << 20
        c.nursery.age = 1
        c.marking.markerThread = false
        c.relocation.testSwitches.manualRelocation = true
        change(&c.relocation)
    })
}

let sparseKept = 200
let sparseSum: Int64 = (1...200).reduce(0) { $0 + Int64($1 * 20) }

extension Runtime {
    /// 4000 Pairs promoted, then all but every 20th dropped: sparse blocks.
    /// A cycle marks them; the final mark selects the blocks.
    func sparseCycle(_ s: Testing.SourceLocation = #_sourceLocation) {
        #expect(runInt("mkSparse:", 4000) == 0, sourceLocation: s)
        scavenge()
        vm.setGlobal(7, image.nilObject)
        vm.startCycle()
        _ = vm.markStep(10_000_000)
        vm.finalMark()
        #expect(phase == .sweeping, sourceLocation: s)
    }

    func kept(_ i: Int) -> Oop { image.om.load(global(8), i) }

    /// The sum of the kept Pairs' x, read without a stop (no thread runs).
    var keptSum: Int64 {
        let om = image.om
        let keep = global(8)
        var s: Int64 = 0
        for i in 0..<Int(om.count(of: keep)) { s += om.load(om.load(keep, i), 0).smallIntegerValue }
        return s
    }

    var relocation: RelocationCounters { vm.relocationCounters }
}

/// A flag set by one thread and polled by another.
final class Flag: @unchecked Sendable {
    private let a = Atomic<Bool>(false)
    func set() { a.store(true, ordering: .releasing) }
    var isSet: Bool { a.load(ordering: .acquiring) }
}
