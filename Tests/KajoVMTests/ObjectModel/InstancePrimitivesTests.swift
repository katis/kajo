// The discoverability follow-up (docs/modules/discoverability.md):
// primitives 167 (`allInstancesOf:limit:`) and 168 (`instanceCountOf:`).
// Each runs in a stop of kind `instances` after module 1's promote-all
// hook, so young instances are found (promoted first), a marking cycle in
// progress is abandoned or its sweep finished without a verifier failure,
// garbage is found until a collection frees it, the limit holds (an Array
// past 4095 slots is a large object), and a bad argument fails cleanly.

import Testing
@testable import KajoVM

private let instancesSrc = pairSrc + """
class Thing Object 1
class SubThing Thing 1
method Object allOf:limit: temps=0 prim=167
  push_nil
  return_top
end
method Object countOf: temps=0 prim=168
  push_int -1
  return_top
end
; nil pairsUpTo: n  ->  every Pair, at most n
method UndefinedObject pairsUpTo: temps=0
  push_nil
  push_lit @Pair
  push_temp 0
  send allOf:limit: 2
  return_top
end
method UndefinedObject countPairs temps=0
  push_nil
  push_lit @Pair
  send countOf: 1
  return_top
end
; nil classes: anArray limit: n
method UndefinedObject classes:limit: temps=0
  push_nil
  push_temp 0
  push_temp 1
  send allOf:limit: 2
  return_top
end
method UndefinedObject countClasses: temps=0
  push_nil
  push_temp 0
  send countOf: 1
  return_top
end
; global 7 := a list of n young Pairs
method UndefinedObject keep: temps=0
  push_nil
  push_int 7
  push_nil
  push_temp 0
  send list: 1
  send g:put: 2
  return_top
end
method UndefinedObject drop temps=0
  push_nil
  push_int 7
  push_nil
  send g:put: 2
  return_top
end
method UndefinedObject collect temps=0
  push_nil
  push_nil
  send gc: 1
  push_int 0
  return_top
end
; the count of {Thing. SubThing}
method UndefinedObject bothThings temps=1
  push_lit @Array
  push_int 2
  send new: 1
  store_temp 0
  push_temp 0
  push_int 1
  push_lit @Thing
  send at:put: 2
  pop
  push_temp 0
  push_int 2
  push_lit @SubThing
  send at:put: 2
  pop
  push_nil
  push_temp 0
  send countOf: 1
  return_top
end
; global 8 := {a Thing. a SubThing}
method UndefinedObject things temps=1
  push_lit @Array
  push_int 2
  send new: 1
  store_temp 0
  push_temp 0
  push_int 1
  push_lit @Thing
  send basicNew 0
  send at:put: 2
  pop
  push_temp 0
  push_int 2
  push_lit @SubThing
  send basicNew 0
  send at:put: 2
  pop
  push_nil
  push_int 8
  push_temp 0
  send g:put: 2
  return_top
end
"""

private func instancesRuntime() throws -> Runtime {
    try markingRuntime(instancesSrc, nurseryKB: 4096)
}

extension Runtime {
    /// Run `nil selector args` to its end on worker 1 and answer what it
    /// answered (the Process released afterwards).
    fileprivate func runOop(_ selector: String, _ args: [Oop] = []) -> Oop {
        let p = spawn(selector, args)
        while vm.liveProcessCount > 0 { _ = vm.runOneSlice(worker: 1) }
        defer { vm.release(p) }
        #expect(vm.error(of: p) == nil, "\(selector): \(String(describing: vm.error(of: p)))")
        return vm.result(of: p)
    }

    /// An Array answer's size and its elements' class indices (nil for a
    /// non-Array).
    fileprivate func arrayClasses(_ a: Oop) -> [UInt64]? {
        vm.inspect { om -> [UInt64]? in
            guard a.isObject, om.header(a).classIndex == WellKnown.array else { return nil }
            return (0..<Int(om.count(of: a))).map { om.header(om.load(a, $0)).classIndex }
        }
    }

    fileprivate var pairIndex: UInt64 { image.classIndex(named: "Pair")! }

    fileprivate func classNamed(_ name: String) -> Oop { vm.inspect { $0.classOop(image.classIndex(named: name)!) } }

    fileprivate func instanceStops() -> Int { vm.stops.filter { $0.kind == .instances }.count }
}

@Test func youngInstancesAreFoundAndCountedInAStopOfTheirOwnKind() throws {
    let rt = try instancesRuntime()
    let stops0 = rt.instanceStops()
    _ = rt.runOop("keep:", [int(100)])
    #expect(rt.runInt("countPairs") == 100)
    let all = try #require(rt.arrayClasses(rt.runOop("pairsUpTo:", [int(1000)])))
    #expect(all.count == 100 && all.allSatisfy { $0 == rt.pairIndex })
    #expect(rt.instanceStops() == stops0 + 2)
    rt.noFailures()
    rt.stop()
}

@Test func theLimitHoldsAndALargeAnswerIsALargeObject() throws {
    let rt = try instancesRuntime()
    _ = rt.runOop("keep:", [int(5000)])
    #expect(rt.arrayClasses(rt.runOop("pairsUpTo:", [int(10)]))?.count == 10)
    #expect(rt.arrayClasses(rt.runOop("pairsUpTo:", [int(0)]))?.count == 0)
    let big = rt.runOop("pairsUpTo:", [int(100_000)])
    #expect(rt.arrayClasses(big)?.count == 5000)
    #expect(rt.vm.inspect { $0.count(of: big) } > 4095)
    #expect(rt.runInt("countPairs") == 5000)
    // Past the count field's limit, below zero, or not a class: refused.
    for bad in [int(-1), int(Int64(Header.maxLargeCount) + 1), rt.image.nilObject] {
        #expect(rt.runOop("pairsUpTo:", [bad]) == rt.image.nilObject)
    }
    #expect(rt.runInt("countClasses:", oop: int(3)) == -1)
    rt.noFailures()
    rt.stop()
}

@Test func garbageIsAnInstanceUntilACollectionFreesIt() throws {
    let rt = try instancesRuntime()
    _ = rt.runOop("keep:", [int(300)])
    #expect(rt.runInt("countPairs") == 300)
    _ = rt.runOop("drop")
    #expect(rt.runInt("countPairs") == 300)
    _ = rt.runOop("collect")
    #expect(rt.runInt("countPairs") == 0)
    #expect(rt.arrayClasses(rt.runOop("pairsUpTo:", [int(10)]))?.count == 0)
    rt.noFailures()
    rt.stop()
}

@Test func aMarkingCycleInProgressIsAbandonedWithoutAVerifierFailure() throws {
    let rt = try instancesRuntime()
    _ = rt.runOop("keep:", [int(2000)])
    rt.scavenge()
    rt.vm.startCycle()
    _ = rt.vm.markStep(100)
    #expect(rt.runInt("countPairs") == 2000)
    #expect(rt.phase == .idle)
    // And a sweep pending at the stop is finished and applied first.
    rt.vm.startCycle()
    _ = rt.vm.markStep(10_000_000)
    rt.vm.finalMark()
    #expect(rt.phase == .sweeping)
    #expect(rt.arrayClasses(rt.runOop("pairsUpTo:", [int(5000)]))?.count == 2000)
    #expect(rt.phase == .idle)
    rt.noFailures()
    rt.stop()
}

@Test func anArrayOfClassesIsOneWalkAndTheAnswerIsNotItsOwnElement() throws {
    let rt = try instancesRuntime()
    _ = rt.runOop("things")
    #expect(rt.runInt("countClasses:", oop: rt.classNamed("Thing")) == 1)
    #expect(rt.runInt("countClasses:", oop: rt.classNamed("SubThing")) == 1)
    #expect(rt.runInt("bothThings") == 2)
    let arrays = rt.runInt("countClasses:", oop: rt.classNamed("Array"))
    // Asking for every Array never answers the answer itself.
    let a = rt.runOop("classes:limit:", [rt.classNamed("Array"), int(100_000)])
    let elements = try #require(rt.arrayClasses(a))
    #expect(elements.count == Int(arrays))
    #expect(!rt.vm.inspect { om in (0..<Int(om.count(of: a))).contains { om.load(a, $0) == a } })
    rt.noFailures()
    rt.stop()
}
