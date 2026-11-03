// The object model with modules 3 to 7 running: immediates are not
// references in any collector, a materialized frame's Context keeps the
// frame pin, stacks grow by copying with their frame links intact, and
// read-only flips race no young collector.

import Testing
@testable import KajoVM

/// global 11 := an Array of n slots holding, in turn, a SmallFloat, a
/// Character, a boxed Float and a SmallInteger; `checkImm:` answers how
/// many slots still hold what was stored (n when nothing was lost).
let immediatesSrc = pairSrc + """
method UndefinedObject fillImm: temps=2
  push_lit @Array
  push_temp 0
  send new: 1
  store_temp 1
  push_int 1
  store_temp 2
loop:
  push_temp 2
  push_temp 0
  le
  jump_if_false done
  push_temp 1
  push_temp 2
  push_nil
  push_temp 2
  send imm: 1
  send at:put: 2
  pop
  push_temp 2
  push_int 1
  add
  store_temp 2
  jump loop
done:
  push_nil
  push_int 11
  push_temp 1
  send g:put: 2
  pop
  push_int 0
  return_top
end
; the value for slot i: i \\\\ 4 = 0 a SmallFloat i + 0.5, 1 the Character
; with value i, 2 a boxed Float (1e70 * 1e70, a fresh object), 3 i
method UndefinedObject imm: temps=1
  push_temp 0
  push_int 4
  send \\\\ 1
  store_temp 1
  push_temp 1
  push_int 0
  eq
  jump_if_false c1
  push_temp 0
  send asFloat 0
  push_lit 0.5
  add
  return_top
c1:
  push_temp 1
  push_int 1
  eq
  jump_if_false c2
  push_temp 0
  send asCharacter 0
  return_top
c2:
  push_temp 1
  push_int 2
  eq
  jump_if_false c3
  push_lit 1.0e70
  push_lit 1.0e70
  mul
  return_top
c3:
  push_temp 0
  return_top
end
method UndefinedObject checkImm: temps=3
  push_nil
  push_int 11
  send g: 1
  store_temp 1
  push_int 0
  store_temp 3
  push_int 1
  store_temp 2
loop:
  push_temp 2
  push_temp 0
  le
  jump_if_false done
  push_temp 1
  push_temp 2
  at
  push_nil
  push_temp 2
  send imm: 1
  eq
  jump_if_false next
  push_temp 3
  push_int 1
  add
  store_temp 3
next:
  push_temp 2
  push_int 1
  add
  store_temp 2
  jump loop
done:
  push_temp 3
  return_top
end
method SmallInteger asFloat temps=0 prim=59
end
method Object asCharacter temps=0 prim=77
end
method Float = temps=0 prim=68
end
method Float * temps=0 prim=62
end
method Character = temps=0
  push_self
  push_temp 0
  identical
  return_top
end
"""

private let immN: Int64 = 2000

/// Every collector over objects holding SmallFloats and Characters (whose
/// low bits are not 1, so a `raw & 1` "is it an integer" test would read
/// them as references): the scavenge, module 1's collection and
/// compaction, a concurrent marking cycle with relocation of every live
/// block, and the young collections without stopping the world. Every
/// verifier is on; nothing may be lost or misread.
@Test(arguments: [YoungMode.stw, .local, .offload])
func immediatesAreNotReferencesInAnyCollector(_ mode: YoungMode) throws {
    let rt = try Runtime(immediatesSrc, background: 1, heapBlocks: 2048, start: false, configure: { c in
        c.nursery.bytes = 1 << 20
        c.nursery.age = 1
        c.young.mode = mode
        c.young.verify = true
        c.young.verifyEvery = 1
        c.marking.enabled = true
        c.marking.markerThread = false
        c.marking.floor = 2
        c.marking.safetyFactor = 0
        c.relocation.testSwitches.manualRelocation = true
        c.relocation.stress = .relocateEveryLiveBlock
    })
    #expect(rt.runInt("fillImm:", immN) == 0)
    #expect(rt.runInt("checkImm:", immN) == immN)
    if mode != .stw { rt.vm.collectYoung(worker: 1) }
    rt.scavenge()  // old now
    #expect(rt.runInt("checkImm:", immN) == immN)
    rt.vm.startCycle()
    _ = rt.vm.markStep(10_000_000)
    rt.vm.finalMark()
    rt.vm.relocate()
    rt.vm.sweep()
    rt.scavenge()
    #expect(rt.runInt("checkImm:", immN) == immN)
    rt.vm.collect()
    rt.vm.compact()
    #expect(rt.runInt("checkImm:", immN) == immN)
    rt.noFailures()
    rt.stop()
}

// MARK: - the frame pin of a materialized frame

private let contextPinSrc = relocSrc + """
; global 10 := thisContext; then spin with the Context only in the frame's
; context word (and the global)
method UndefinedObject holdContext temps=0
  push_nil
  push_int 10
  push_this_context
  send g:put: 2
  pop
loop:
  push_nil
  pop
  jump loop
end
"""

/// The rule: the frame-pin walk covers the frame's context word, so a
/// running frame's Context is not moved by a relocation. Broken variant
/// (test switch `pinWalkSkipsContext`): the Context is moved.
@Test(arguments: [false, true])
func contextMaterializationKeepsTheFramePin(_ broken: Bool) throws {
    let rt = try Runtime(contextPinSrc, background: 1, heapBlocks: 2048, start: false, configure: { c in
        c.nursery.bytes = 1 << 20
        c.nursery.age = 1
        c.marking.enabled = true
        c.marking.markerThread = false
        c.relocation.testSwitches.manualRelocation = true
        c.relocation.stress = .relocateEveryLiveBlock
        c.young.mode = .stw
    }, switches: { var sw = TestSwitches(); sw.pinWalkSkipsContext = broken; return sw }())
    let p = rt.spawn("holdContext")
    let vm = rt.vm
    let t = TestThread { _ = vm.runOneSlice(worker: 1) }
    #expect(eventually { rt.global(10) != rt.image.nilObject })
    rt.scavenge()  // the Context is old now
    let ctx = rt.global(10)
    #expect(rt.vm.inspect { $0.classIndex(of: ctx) } == WellKnown.context && !rt.header(ctx).isYoung)
    rt.vm.startCycle()
    _ = rt.vm.markStep(10_000_000)
    rt.vm.finalMark()
    #expect(rt.header(ctx).isFramePinned == !broken)
    let before = rt.vm.stateWord(of: ctx)
    rt.vm.relocate()
    #expect((rt.vm.stateWord(of: ctx) == before) == !broken)
    rt.vm.terminate(p)
    t.join()
    rt.vm.sweep()
    rt.scavenge()
    rt.noFailures()
    rt.stop()
}

// MARK: - stack growth

private let deepSrc = pairSrc + """
; global 10 := thisContext of the bottom frame; recurse n deep through a
; block that returns non-locally to the bottom frame from the deepest one.
class Deep Object 0
method Deep run: temps=0
  push_nil
  push_int 10
  push_this_context
  send g:put: 2
  pop
  push_self
  push_temp 0
  push_closure out 0
  send down:with: 2
  pop
  push_int -1
  return_top
block out args=1 copied=0 temps=0
  push_temp 0
  nonlocal_return
end
method Deep down:with: temps=0
  push_temp 0
  push_int 0
  eq
  jump_if_false rec
  push_nil
  push_int 10
  send g: 1
  send isDead 0
  jump_if_true dead
  push_temp 1
  push_lit 1000000
  value1
  return_top
dead:
  push_int -2
  return_top
rec:
  push_self
  push_temp 0
  push_int 1
  sub
  push_temp 1
  send down:with: 2
  push_temp 0
  add
  return_top
end
method UndefinedObject deep: temps=0
  push_lit @Deep
  send basicNew 0
  push_temp 0
  send run: 1
  return_top
end
method Context isDead temps=0 prim=107
end
"""

/// The rule: when a frame does not fit, the stack is copied into a segment
/// twice the size and nothing in it changes: frame links are indices, a
/// Context's frame is an index, so the bottom frame's Context is still
/// live at the deepest frame and a non-local return there finds its home.
@Test func stackGrowthPreservesFrameLinks() throws {
    let rt = try Runtime(deepSrc, background: 1, start: false, configure: { c in
        c.stackWords = 256
    })
    #expect(rt.runInt("deep:", 3000) == 1_000_000)
    #expect(rt.vm.counters.stackGrowths >= 6)  // 256 words to 32 Ki and more
    // past the maximum it is still an overflow, of that Process only
    let rt2 = try Runtime(deepSrc, background: 1, start: false, configure: { c in
        c.stackWords = 256
        c.maxStackWords = 4096
    })
    let p = rt2.spawn("deep:", [Oop(smallInteger: 3000)])
    while rt2.vm.liveProcessCount > 0 { _ = rt2.vm.runOneSlice(worker: 1) }
    #expect(rt2.vm.error(of: p)?.kind == .stackOverflow)
    rt.stop()
    rt2.stop()
}

// MARK: - read-only flips during young collections

private let flipSrc = pairSrc + """
; n times: a fresh Pair, read-only on and off, kept in global 12 (a ring of 64)
method UndefinedObject flips: temps=2
  push_nil
  push_int 12
  push_lit @Array
  push_int 64
  send new: 1
  send g:put: 2
  pop
  push_int 1
  store_temp 1
loop:
  push_temp 1
  push_temp 0
  le
  jump_if_false done
  push_lit @Pair
  send basicNew 0
  store_temp 2
  push_temp 2
  push_true
  send setReadOnly: 1
  pop
  push_temp 2
  push_false
  send setReadOnly: 1
  pop
  push_temp 2
  push_true
  send setReadOnly: 1
  pop
  push_nil
  push_int 12
  send g: 1
  push_temp 1
  push_int 64
  send \\\\ 1
  push_int 1
  add
  push_temp 2
  send at:put: 2
  pop
  push_temp 1
  push_int 1
  add
  store_temp 1
  jump loop
done:
  push_int 0
  return_top
end
method Object setReadOnly: temps=0 prim=93
end
"""

/// Read-only is set with an atomic or on the header while the young
/// collector may compare-and-swap the same word: neither loses its bits.
@Test(arguments: [YoungMode.local, .offload])
func readOnlyFlipsRaceNoYoungCollection(_ mode: YoungMode) throws {
    let rt = try youngRuntime(mode, src: flipSrc, background: 2, start: true)
    let ps = (0..<2).map { _ in rt.spawn("flips:", [Oop(smallInteger: 150_000)]) }
    rt.waitAllTerminated()
    for p in ps { #expect(rt.result(p) == 0) }
    let ring = rt.global(12)
    #expect(rt.vm.inspect { om in (0..<64).allSatisfy { om.isReadOnly(om.load(ring, $0)) } })
    #expect(rt.vm.youngLog.reduce(0) { $0 + $1.claimFailures } == 0)
    #expect(rt.vm.youngLog.count > 0)
    rt.noFailures()
    rt.stop()
}

// MARK: - installation and the other workers' caches

private let installSrc = pairSrc + """
class Q Object 0
method Q answer temps=0
  push_int 1
  return_top
end
method Q doesNotUnderstand: temps=0
  push_int 99
  return_top
end
method Class removeSelector: temps=0 prim=98
end
; send `answer` until it answers 99 (global 10 := 1 once it has run), at
; most 20 million times; it allocates nothing in the loop, so no
; collection's stop flushes its cache for it
method UndefinedObject spinAsk temps=2
  push_int 0
  store_temp 0
  push_lit @Q
  send basicNew 0
  store_temp 1
loop:
  push_nil
  push_int 10
  push_int 1
  send g:put: 2
  pop
  push_temp 1
  send answer 0
  push_int 99
  eq
  jump_if_true done
  push_temp 0
  push_int 1
  add
  store_temp 0
  push_temp 0
  push_lit 20000000
  lt
  jump_if_true loop
  push_int -1
  return_top
done:
  push_temp 0
  return_top
end
method UndefinedObject removeAnswer temps=0
  push_lit @Q
  push_lit #answer
  send removeSelector: 1
  pop
  push_int 0
  return_top
end
"""

/// The rule: a method dictionary changes in a stop, and every worker
/// flushes its lookup cache when it sees the stop, before it runs again.
/// A Process spinning on `answer` on one worker sees the method removed by
/// another worker's Process (its cached line would keep answering 1).
@Test func aRemovedMethodIsGoneFromEveryWorkersCache() throws {
    // The spinner runs on worker 1 (its own thread, no deadline), the
    // remover on worker 2 (this thread): only the stop reaches worker 1.
    let rt = try Runtime(installSrc, background: 2, start: false)
    let spinner = rt.spawn("spinAsk")
    let vm = rt.vm
    let t = TestThread { _ = vm.runOneSlice(worker: 1, budgetNs: .max) }
    #expect(eventually { rt.global(10) != rt.image.nilObject })
    let remover = rt.spawn("removeAnswer")
    while rt.vm.runOneSlice(worker: 2) {}
    t.join()
    #expect(rt.result(remover) == 0)
    #expect(rt.result(spinner) >= 0)  // -1: it never saw the removal
    rt.stop()
}
