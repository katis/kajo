// The nursery verifiers' own tests: corrupt one thing, see the verifier
// before or after the next scavenge report it (module 1's style).

import Synchronization
import Testing
@testable import KajoVM

private let keepSrc = pairSrc + """
method UndefinedObject keep temps=0
  push_nil
  push_int 7
  push_nil
  push_int 1
  send pair: 1
  send g:put: 2
  pop
  push_nil
  push_int 8
  push_lit @Array
  push_int 2
  send new: 1
  send g:put: 2
  pop
  push_int 0
  return_top
end
"""

enum NurseryCorruption: CaseIterable, Sendable {
    case youngInTheWrongNursery, markerWithoutBuffer, holderNotRemembered, survivorOutOfItsLog

    var needle: String {
        switch self {
        case .youngInTheWrongNursery: "neither eden nor survivor-from"
        case .markerWithoutBuffer: "in no buffer"
        case .holderNotRemembered: "not remembered"
        case .survivorOutOfItsLog: "survivor log"
        }
    }
}

@Test(arguments: NurseryCorruption.allCases)
func theNurseryVerifierCatches(_ c: NurseryCorruption) throws {
    let rt = try nurseryRuntime(keepSrc, age: 3)
    rt.spawn("keep")
    rt.runOn(1)
    let p = rt.global(7), arr = rt.global(8)
    let n = rt.vm.state.pointee.nursery!
    switch c {
    case .youngInTheWrongNursery:
        rt.vm.withWorldStopped { rt.image.om.setHeader(p, rt.image.om.header(p).youngIn(nursery: 0)) }
    case .markerWithoutBuffer:
        rt.vm.withWorldStopped { n.remMarker(rt.image.nilObject.raw).pointee.store(1, ordering: .relaxed) }
    case .holderNotRemembered:
        rt.scavenge(); rt.scavenge(); rt.scavenge()   // both old (N = 3)
        rt.vm.onHostWorker { m in m.om.store(arr, 0, m.allocate(WellKnown.array, slots: 1)) }
    case .survivorOutOfItsLog:
        rt.scavenge()   // p survives, logged in its nursery's survivor log
        let reports = rt.vm.inspect { _ in
            for k in 0..<n.pointee.count { n.alloc(k).pointee.survLog.removeAll() }
            return verifyNurseryAfterScavenge(n)
        }
        #expect(reports.contains { $0.contains(c.needle) }, "\(reports.prefix(2))")
        rt.stop(verifyHeap: false)
        return
    }
    rt.scavenge()
    let reports = rt.image.om.verifierReports
    #expect(reports.contains { $0.contains(c.needle) }, "\(reports.prefix(2))")
    rt.stop(verifyHeap: false)
}
