// The `pointersTo:` follow-up (docs/modules/pointers-to.md): primitives 169
// (`pointersTo:limit:`) and 170 (`pointerCountTo:`). They run in the same
// stop kind and hook as 167 and 168, so young holders are promoted and
// found, a marking cycle in progress is abandoned or its sweep finished
// without a verifier failure, garbage holds until a collection frees it,
// and the walk compares every slot raw: a large holder's last slot, a weak
// slot, an immediate target, a self-reference; a method whose literal frame
// holds the target stands for that frame; an object held only by a frame
// has no holder; the answer is never its own element.

import Testing
@testable import KajoVM

private let pointersSrc = pairSrc + """
class WeakBag Object 0 weak
method Object pointersTo:limit: temps=0 prim=169
  push_nil
  return_top
end
method Object pointerCountTo: temps=0 prim=170
  push_int -1
  return_top
end
; nil ptrs: anObject limit: n
method UndefinedObject ptrs:limit: temps=0
  push_nil
  push_temp 0
  push_temp 1
  send pointersTo:limit: 2
  return_top
end
method UndefinedObject ptrCount: temps=0
  push_nil
  push_temp 0
  send pointerCountTo: 1
  return_top
end
; global 9 := a fresh Pair, answered
method UndefinedObject target temps=0
  push_nil
  push_int 9
  push_nil
  push_int 1
  send pair: 1
  send g:put: 2
  return_top
end
; global k := (Array new: n) with anObject at its last slot, answered
method UndefinedObject hold:in:size: temps=1
  push_lit @Array
  push_temp 2
  send new: 1
  store_temp 3
  push_temp 3
  push_temp 2
  push_temp 0
  send at:put: 2
  pop
  push_nil
  push_temp 1
  push_temp 3
  send g:put: 2
  return_top
end
; global k := (WeakBag new: 2) with anObject at 2, answered
method UndefinedObject weaklyHold:in: temps=1
  push_lit @WeakBag
  push_int 2
  send new: 1
  store_temp 2
  push_temp 2
  push_int 2
  push_temp 0
  send at:put: 2
  pop
  push_nil
  push_temp 1
  push_temp 2
  send g:put: 2
  return_top
end
; global k := an Array holding itself, answered
method UndefinedObject selfHolderIn: temps=1
  push_lit @Array
  push_int 1
  send new: 1
  store_temp 1
  push_temp 1
  push_int 1
  push_temp 1
  send at:put: 2
  pop
  push_nil
  push_temp 0
  push_temp 1
  send g:put: 2
  return_top
end
; a fresh Pair held only by this frame's temporary: its holders' count
method UndefinedObject countOfATemporary temps=1
  push_nil
  push_int 5
  send pair: 1
  store_temp 0
  push_nil
  push_temp 0
  send ptrCount: 1
  return_top
end
; global k := nil, then nil ptrs: anObject limit: 100 in the same Process
method UndefinedObject drop:thenPtrs: temps=0
  push_nil
  push_temp 0
  push_nil
  send g:put: 2
  pop
  push_nil
  push_temp 1
  push_int 100
  send ptrs:limit: 2
  return_top
end
method UndefinedObject collect temps=0
  push_nil
  push_nil
  send gc: 1
  push_int 0
  return_top
end
"""

private func pointersRuntime() throws -> Runtime {
    try markingRuntime(pointersSrc, nurseryKB: 4096)
}

extension Runtime {
    fileprivate func runOop(_ selector: String, _ args: [Oop] = []) -> Oop {
        let p = spawn(selector, args)
        while vm.liveProcessCount > 0 { _ = vm.runOneSlice(worker: 1) }
        defer { vm.release(p) }
        #expect(vm.error(of: p) == nil, "\(selector): \(String(describing: vm.error(of: p)))")
        return vm.result(of: p)
    }

    /// An Array answer's elements (nil for a non-Array).
    fileprivate func elements(_ a: Oop) -> [Oop]? {
        vm.inspect { om -> [Oop]? in
            guard a.isObject, om.header(a).classIndex == WellKnown.array else { return nil }
            return (0..<Int(om.count(of: a))).map { om.load(a, $0) }
        }
    }

    fileprivate func holders(_ o: Oop, limit: Int64 = 100_000) -> [Oop] {
        elements(runOop("ptrs:limit:", [o, int(limit)])) ?? []
    }

    fileprivate func holderCount(_ o: Oop) -> Int64 { runInt("ptrCount:", oop: o) }

    fileprivate func instanceStops() -> [StopRecord] { vm.stops.filter { $0.kind == .instances } }
}

@Test func youngHoldersArePromotedAndFoundInAStopOfKindInstances() throws {
    let rt = try pointersRuntime()
    let t = rt.runOop("target")
    let a = rt.runOop("hold:in:size:", [t, int(7), int(1)])
    let b = rt.runOop("hold:in:size:", [t, int(8), int(3)])
    let c = rt.runOop("hold:in:size:", [t, int(10), int(2)])
    #expect(rt.vm.inspect { $0.header(a).isYoung && $0.header(b).isYoung })
    let stops0 = rt.instanceStops().count
    // The globals Array holds the target too (global 9).
    let g = rt.image.globals
    #expect(rt.holderCount(t) == 4)
    let found = rt.holders(t)
    #expect(Set(found.map(\.raw)) == Set([a, b, c, g].map(\.raw)) && found.count == 4)
    #expect(rt.vm.inspect { !$0.header(a).isYoung })
    // The two walks' stops are of kind instances and record the slots compared.
    let stops = rt.instanceStops()
    #expect(stops.count == stops0 + 2)
    #expect(stops.suffix(2).allSatisfy { $0.words > 0 })
    #expect(rt.holders(t, limit: 2).count == 2)
    #expect(rt.holders(t, limit: 0).isEmpty)
    rt.noFailures()
    rt.stop()
}

@Test func aLargeHolderAtItsLastSlotAndAWeakHolderAreFound() throws {
    let rt = try pointersRuntime()
    let t = rt.runOop("target")
    let big = rt.runOop("hold:in:size:", [t, int(7), int(5000)])
    #expect(rt.vm.inspect { $0.count(of: big) } == 5000)
    let weak = rt.runOop("weaklyHold:in:", [t, int(8)])
    let found = Set(rt.holders(t).map(\.raw))
    #expect(found == [big.raw, weak.raw, rt.image.globals.raw])
    #expect(rt.holderCount(t) == 3)
    rt.noFailures()
    rt.stop()
}

@Test func anImmediateTargetASelfReferenceAndTheAnswerItself() throws {
    let rt = try pointersRuntime()
    let three = rt.runOop("hold:in:size:", [int(3), int(7), int(4)])
    #expect(rt.holders(int(3)).contains(three))
    #expect(rt.holderCount(int(3)) >= 1)
    // A self-reference is a holder.
    let s = rt.runOop("selfHolderIn:", [int(8)])
    #expect(Set(rt.holders(s).map(\.raw)) == [s.raw, rt.image.globals.raw])
    // nil is in nearly every slot: the answer, filled with nil while it
    // is made, is never one of its own elements, and the count agrees
    // with an answer under no limit.
    // Each run's Process is garbage after it; collect before each walk.
    _ = rt.runOop("collect")
    let n = rt.holderCount(rt.image.nilObject)
    _ = rt.runOop("collect")
    let all = rt.runOop("ptrs:limit:", [rt.image.nilObject, int(Int64(Header.maxLargeCount))])
    let elements = try #require(rt.elements(all))
    #expect(!elements.contains(all))
    #expect(Int64(elements.count) == n, "\(elements.count) listed, \(n) counted")
    #expect(rt.holders(rt.image.nilObject, limit: 1).count == 1)
    rt.noFailures()
    rt.stop()
}

@Test func aMethodWhoseLiteralFrameHoldsTheTargetIsTheHolder() throws {
    let rt = try pointersRuntime()
    let pair = rt.vm.inspect { $0.classOop(rt.image.classIndex(named: "Pair")!) }
    let found = rt.holders(pair)
    let (methods, frames, literalFrames) = rt.vm.inspect { om -> (Int, Int, Set<UInt64>) in
        var methods = 0, frames = 0
        var literalFrames = Set<UInt64>()
        for o in found where om.header(o).classIndex == WellKnown.method {
            let lf = om.load(o, MethodLayout.literals)
            if (0..<Int(om.count(of: lf))).contains(where: { om.load(lf, $0) == pair }) { methods += 1 }
            literalFrames.insert(lf.raw)
        }
        for o in found where literalFrames.contains(o.raw) { frames += 1 }
        return (methods, frames, literalFrames)
    }
    // Every method pushing @Pair (pair: and list: at least).
    #expect(methods >= 2)
    #expect(frames == 0)
    #expect(!literalFrames.isEmpty)
    #expect(!found.contains { o in rt.vm.inspect { $0.header(o).classIndex == WellKnown.array && literalFrames.contains(o.raw) } })
    rt.noFailures()
    rt.stop()
}

@Test func anObjectHeldOnlyByAFrameHasNoHolder() throws {
    let rt = try pointersRuntime()
    #expect(rt.runInt("countOfATemporary") == 0)
    rt.noFailures()
    rt.stop()
}

@Test func garbageHoldsUntilACollectionFreesIt() throws {
    let rt = try pointersRuntime()
    let t = rt.runOop("target")
    _ = rt.runOop("hold:in:size:", [t, int(7), int(1)])
    #expect(rt.holderCount(t) == 2)
    _ = rt.runOop("g:put:", [int(7), rt.image.nilObject])
    #expect(rt.holderCount(t) == 2)
    _ = rt.runOop("collect")
    #expect(rt.holderCount(t) == 1)
    #expect(rt.holders(t) == [rt.image.globals])
    rt.noFailures()
    rt.stop()
}

@Test func aMarkingCycleInProgressIsAbandonedAndAPendingSweepAppliedFirst() throws {
    let rt = try pointersRuntime()
    let t = rt.runOop("target")
    _ = rt.runOop("hold:in:size:", [t, int(7), int(1)])
    rt.scavenge()
    rt.vm.startCycle()
    _ = rt.vm.markStep(100)
    #expect(rt.holderCount(t) == 2)
    #expect(rt.phase == .idle)
    rt.vm.startCycle()
    _ = rt.vm.markStep(10_000_000)
    rt.vm.finalMark()
    #expect(rt.phase == .sweeping)
    #expect(rt.holders(t).count == 2)
    #expect(rt.phase == .idle)
    rt.noFailures()
    rt.stop()
}

@Test func aBadLimitIsRefused() throws {
    let rt = try pointersRuntime()
    let t = rt.runOop("target")
    for bad in [int(-1), int(Int64(Header.maxLargeCount) + 1), rt.image.nilObject] {
        #expect(rt.runOop("ptrs:limit:", [t, bad]) == rt.image.nilObject)
    }
    rt.noFailures()
    rt.stop()
}

@Test func whenTheAnswersAllocationCollectsTheAnswerIsExact() throws {
    // Every allocation through the object memory collects first, so the
    // answer's own allocation frees a garbage holder the walk listed: the
    // Array is then filled by a second walk, and the answer is exact.
    let rt = try Runtime(pointersSrc, background: 1, start: false, stress: .collectAtEveryAllocation,
                         configure: { $0.nursery.bytes = 4096 * 1024 })
    let t = rt.runOop("target")
    _ = rt.runOop("hold:in:size:", [t, int(7), int(1)])
    rt.scavenge()
    let collections = rt.image.om.counters.collections
    #expect(rt.elements(rt.runOop("drop:thenPtrs:", [int(7), t])) == [rt.image.globals])
    #expect(rt.image.om.counters.collections > collections)
    rt.noFailures()
    rt.stop()
}
