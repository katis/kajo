// Mutation tests of the barrier sites (docs/modules/nursery.md "Barrier
// sites"; experiments/generational-gc RESULTS section 5): each site is
// switched off in turn (`skipBarrierAt`) and a scenario that makes an old
// holder name a young object through it runs; the remembered-set verifier
// before the next scavenge must report it. Sites whose holder is always
// young (a fresh object) or that another barriered store in the same
// critical section covers cannot fail; the table below says which, and
// the test checks the table.

import Testing
@testable import KajoVM

private let siteSrc = schedulerSrc + """
; global 8 := Array new: 4, global 9 := a Pair (old after a scavenge)
method UndefinedObject makeHolders temps=0
  push_nil
  push_int 8
  push_lit @Array
  push_int 4
  send new: 1
  send g:put: 2
  pop
  push_nil
  push_int 9
  push_nil
  push_int 0
  send pair: 1
  send g:put: 2
  pop
  push_int 0
  return_top
end
method UndefinedObject viaIvar temps=0
  push_nil
  push_int 9
  send g: 1
  push_nil
  push_int 5
  send pair: 1
  push_int 0
  send x:y: 2
  pop
  push_int 0
  return_top
end
method UndefinedObject viaAtPut temps=0
  push_nil
  push_int 8
  send g: 1
  push_int 1
  push_nil
  push_int 5
  send pair: 1
  send at:put: 2
  pop
  push_int 0
  return_top
end
method UndefinedObject viaGlobal temps=0
  push_nil
  push_int 12
  push_nil
  push_int 5
  send pair: 1
  send globalAt:put: 2
  pop
  push_int 0
  return_top
end
class Catcher Object 0
method Catcher doesNotUnderstand: temps=0
  push_nil
  push_int 13
  push_temp 0
  send globalAt:put: 2
  return_top
end
method UndefinedObject viaMessage temps=0
  push_lit @Catcher
  send basicNew 0
  push_nil
  push_int 5
  send pair: 1
  send frob: 1
  pop
  push_int 0
  return_top
end
method UndefinedObject child temps=0
  push_int 1
  return_top
end
method UndefinedObject viaFork temps=0
  push_nil
  push_lit #child
  push_nil
  push_nil
  push_false
  push_nil
  send newSemaphore 0
  send fork:with:priority:main:exit: 5
  pop
  push_int 0
  return_top
end
"""

/// The sites whose removal the verifier sees, as measured: the rest are
/// covered by another barriered store into the same holder in the same
/// critical section, or their holder is young.
let barrierSitesCaught: Set<BarrierSite> = [
    .storeIvar, .atPut, .globalAtPut, .hostGlobal, .readyQueueLink, .unlinkLink, .processResult, .waitingOn,
    .waiterLink, .lastWaiterOnWait,
]

/// Run the scenarios with `skip` switched off; answers whether a verifier
/// failed.
private func siteScenario(_ skip: BarrierSite?) throws -> Bool {
    if [.readyQueueLink, .unlinkLink, .unlinkFirstWaiter, .unlinkLastWaiter, .processResult, .waitingOn, .waiterLink,
        .firstWaiterOnWait, .lastWaiterOnWait, .firstWaiterOnSignal].contains(skip) {
        return try schedulerStores(siteSrc, skip: skip)
    }
    let rt = try nurseryRuntime(siteSrc, age: 1, configure: { $0.nursery.testSwitches.skipBarrierAt = skip })
    do {
        rt.spawn("makeHolders")
        rt.runOn(1)
        try rt.checkedScavenge()
        for sel in ["viaIvar", "viaAtPut", "viaGlobal", "viaMessage", "viaFork"] {
            rt.spawn(sel)
            rt.runOn(1)
            try rt.checkedScavenge()
        }
        rt.vm.setGlobal(14, rt.vm.newArray(2))
        try rt.checkedScavenge()
        while rt.vm.runOneSlice(worker: 1) {}
        try rt.checkedScavenge()
    } catch {
        rt.stop(verifyHeap: false)
        return true
    }
    rt.stop()
    return false
}

@Test func everyBarrierSiteScenarioIsCleanWithEveryBarrier() throws {
    #expect(try !siteScenario(nil))
}

@Test(arguments: BarrierSite.allCases)
func aBarrierSiteSwitchedOff(_ site: BarrierSite) throws {
    let caught = try siteScenario(site)
    print("barrier site \(site): \(caught ? "caught" : "not caught")")
    #expect(caught == barrierSitesCaught.contains(site), "site \(site): caught \(caught)")
}
