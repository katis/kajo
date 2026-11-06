// Collectors review, finding 5: a reshape lists every instance of the class
// and only then ran module 4's hook before old-space operations, whose
// promote-all scavenge (and the lazy sweep it applies) frees the instances
// that were dead: the plan then gave a freed entry a body. The hook runs
// first now. This is module 1's own reshape (the redefine primitive runs
// the hook itself before it lists anything: LiveClassTests).

import Testing
@testable import KajoVM

private let reshapeSrc = markingSrc + "\n" + """
; twenty Pairs nobody keeps
method UndefinedObject dropList temps=0
  push_nil
  push_int 20
  send list: 1
  pop
  push_int 0
  return_top
end
"""

@Test func aReshapeWithDeadYoungInstancesReshapesOnlyTheLiveOnes() throws {
    let rt = try Runtime(reshapeSrc, background: 1, start: false, configure: { c in
        c.nursery.bytes = 1024 * 1024
        c.young.mode = .stw
        c.marking.enabled = false
    })
    rt.run("mkO")       // global 8: a list of 100 Pairs, young
    rt.run("dropList")  // twenty dead young Pairs
    let pair = try #require(rt.image.classIndex(named: "Pair"))
    let o = rt.global(8)
    #expect(rt.young(o))
    var reshaped = -1
    var refused: ReshapeError? = nil
    rt.vm.withWorldStopped(roots: false) { om, _ in
        do { reshaped = try om.reshape(classIndex: pair, namedSlots: 2, layout: [0, 1, nil], fill: rt.image.nilObject) }
        catch { refused = error as? ReshapeError ?? .notRegistered }
    }
    #expect(refused == nil)
    let live = rt.vm.inspect { $0.allInstances(of: pair) }
    #expect(live.count == 100 && reshaped == 100)
    #expect(rt.vm.inspect { om in live.allSatisfy { om.count(of: $0) == 3 && !om.header($0).isYoung } })
    #expect(rt.slot(o, 0) == int(100))
    rt.noFailures()
    rt.stop()
}
