// Helpers for the concurrent-marking tests (docs/modules/concurrent-marking.md).
// Every runtime has every verifier on (`Runtime` sets `verify` and
// `.record`): the mark set is compared with a from-scratch traversal at
// every final mark, and module 4's scavenge verifier and module 1's heap
// verifiers keep running across lazy sweeps.

import Darwin
import Testing
@testable import KajoVM

/// Methods of experiments/concurrent-marking's ConcurrentTests.swift, over
/// `pairSrc` (Pair, g:, g:put:, list:, sumList:). Globals: 7 the holder H,
/// 8 and 9 scratch.
let markingSrc = pairSrc + """
; global 7 := H, a Pair whose x is a 100-element list O
method UndefinedObject mkH temps=0
  push_nil
  push_int 7
  push_lit @Pair
  send basicNew 0
  push_nil
  push_int 100
  send list: 1
  push_nil
  send x:y: 2
  send g:put: 2
  return_top
end
; global 7 := H, a Pair with x nil
method UndefinedObject mkEmptyH temps=0
  push_nil
  push_int 7
  push_lit @Pair
  send basicNew 0
  push_nil
  push_nil
  send x:y: 2
  send g:put: 2
  return_top
end
; Z := Array new: 1. Z at: 1 put: H x. global 9 := Z. H x: nil y: nil.
; Afterwards O is reachable only through the young Z.
method UndefinedObject moveOut temps=1
  push_lit @Array
  push_int 1
  send new: 1
  store_temp 0
  push_temp 0
  push_int 1
  push_nil
  push_int 7
  send g: 1
  send x 0
  send at:put: 2
  pop
  push_nil
  push_int 9
  push_temp 0
  send g:put: 2
  pop
  push_nil
  push_int 7
  send g: 1
  push_nil
  push_nil
  send x:y: 2
  return_top
end
method UndefinedObject sumZ temps=0
  push_nil
  push_nil
  push_int 9
  send g: 1
  push_int 1
  send at: 1
  send sumList: 1
  return_top
end
; global 8 := O, a 100-element list
method UndefinedObject mkO temps=0
  push_nil
  push_int 8
  push_nil
  push_int 100
  send list: 1
  send g:put: 2
  return_top
end
; global 9 := Y, a Pair with x O. global 8 := nil: O is reachable only through Y.
method UndefinedObject mkY temps=0
  push_nil
  push_int 9
  push_lit @Pair
  send basicNew 0
  push_nil
  push_int 8
  send g: 1
  push_nil
  send x:y: 2
  send g:put: 2
  pop
  push_nil
  push_int 8
  push_nil
  send g:put: 2
  return_top
end
method UndefinedObject sumY temps=0
  push_nil
  push_nil
  push_int 9
  send g: 1
  send x 0
  send sumList: 1
  return_top
end
; H x: (Y x) y: nil (over nil: no SATB record), then global 9 := nil (Y dies)
method UndefinedObject copyToHAndDropY temps=0
  push_nil
  push_int 7
  send g: 1
  push_nil
  push_int 9
  send g: 1
  send x 0
  push_nil
  send x:y: 2
  pop
  push_nil
  push_int 9
  push_nil
  send g:put: 2
  return_top
end
method UndefinedObject sumH temps=0
  push_nil
  push_nil
  push_int 7
  send g: 1
  send x 0
  send sumList: 1
  return_top
end
; global 8 := Array new: 10; then n times: slot (i \\\\ 10) + 1 := a fresh
; 2000-Pair list. Answers the sum over the 10 lists left. t0 = n, t1 = i, t2 = s, t3 = k
method UndefinedObject churnLists: temps=3
  push_nil
  push_int 8
  push_lit @Array
  push_int 10
  send new: 1
  send g:put: 2
  pop
  push_int 0
  store_temp 1
loop:
  push_temp 1
  push_temp 0
  lt
  jump_if_false sum
  push_nil
  push_int 8
  send g: 1
  push_temp 1
  push_int 10
  send \\\\ 1
  push_int 1
  add
  push_nil
  push_lit 2000
  send list: 1
  send at:put: 2
  pop
  push_temp 1
  push_int 1
  add
  store_temp 1
  jump loop
sum:
  push_int 0
  store_temp 2
  push_int 1
  store_temp 3
sloop:
  push_temp 3
  push_int 10
  le
  jump_if_false done
  push_temp 2
  push_nil
  push_nil
  push_int 8
  send g: 1
  push_temp 3
  send at: 1
  send sumList: 1
  add
  store_temp 2
  push_temp 3
  push_int 1
  add
  store_temp 3
  jump sloop
done:
  push_temp 2
  return_top
end
; global 9 := Array new: 4 (old after a scavenge)
method UndefinedObject mkHolder temps=0
  push_nil
  push_int 9
  push_lit @Array
  push_int 4
  send new: 1
  send g:put: 2
  return_top
end

"""

/// A runtime stepped from the test thread: no worker threads and no marker
/// thread (`markerThread = false`), so the test is the marker and decides
/// the interleaving. Promotion on first survival (the experiment's), with
/// every verifier on.
func markingRuntime(_ src: String = markingSrc, background: Int = 1, age: Int = 1, nurseryKB: Int = 1024,
                    heapBlocks: Int = 2048, start: Bool = false,
                    _ change: (inout MarkingConfig) -> Void = { _ in }) throws -> Runtime {
    try Runtime(src, background: background, heapBlocks: heapBlocks, start: start, configure: { c in
        c.nursery.bytes = nurseryKB * 1024
        c.nursery.age = age
        c.marking.enabled = true
        c.marking.markerThread = false
        change(&c.marking)
    })
}

extension Runtime {
    /// Spawn `nil selector` (with an argument) and run it to completion on
    /// background worker 1 from this thread; answer its SmallInteger.
    func runInt(_ selector: String, _ arg: Int64? = nil) -> Int64 {
        runInt(selector, args: arg.map { [int($0)] } ?? [])
    }

    func runInt(_ selector: String, oop: Oop) -> Int64 { runInt(selector, args: [oop]) }

    func runInt(_ selector: String, args: [Oop]) -> Int64 {
        let p = spawn(selector, args)
        while vm.liveProcessCount > 0 { _ = vm.runOneSlice(worker: 1) }
        defer { vm.release(p) }
        return result(p)
    }

    /// Spawn `nil selector` and run one slice of it on worker 1. The
    /// Process is released: a terminated Process's `result` slot holds
    /// what the method answered, and a rooted one would keep it alive.
    func run(_ selector: String) {
        let p = spawn(selector)
        runOn(1)
        vm.release(p)
    }

    var phase: MarkingPhase { vm.markingPhase }
    var marking: MarkingCounters { vm.markingCounters }

    /// Finish the current cycle from the test thread: mark everything,
    /// final mark, sweep, and a scavenge that applies the sweep.
    func finishCycle(_ s: Testing.SourceLocation = #_sourceLocation) {
        _ = vm.markStep(10_000_000)
        vm.finalMark()
        #expect(phase == .sweeping, sourceLocation: s)
        vm.sweep()
        #expect(phase == .swept, sourceLocation: s)
        scavenge()
        #expect(phase == .idle, sourceLocation: s)
    }
}
