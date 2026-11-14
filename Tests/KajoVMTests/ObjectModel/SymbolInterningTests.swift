// Symbol interning without a stop (docs/modules/symbol-interning.md): the
// suspected hole of the brief, the uniqueness, growth and re-interning
// tests, the method-cache test and the broken variants.

import Darwin
import Testing
@testable import KajoVM

let symbolInterningSrc = weakMarkingSrc + "\n" + """
method String asSymbol temps=0 prim=129
  push_nil
  return_top
end
method UndefinedObject internDrop: temps=0
  push_temp 0
  send asSymbol 0
  push_nil
  identical
  jump_if_false made
  push_int 1
  return_top
made:
  push_int 0
  return_top
end
"""

func internRuntime(_ src: String = symbolInterningSrc, background: Int = 1, _ change: (inout VMConfig) -> Void = { _ in }) throws -> Runtime {
    try Runtime(src, background: background, heapBlocks: 2048, start: false, configure: { c in
        c.nursery.bytes = 1024 * 1024
        c.nursery.age = 1
        c.marking.enabled = true
        c.marking.markerThread = false
        change(&c)
    })
}

extension Runtime {
    /// The host worker interns `s` by the slow path alone, as a worker
    /// whose lock-free lookup missed just before another worker's insert of
    /// the same bytes landed, and stores the answer into slot `i` of
    /// `holder` (a program's `H x: aString asSymbol`), holding it nowhere
    /// else.
    @discardableResult
    func internSlowInto(_ s: String, _ holder: Oop, _ i: Int) -> Oop {
        let str = vm.newString(s)
        return vm.host { w in
            let m = vm.machine(w)
            let sym = m.internSlow(str, m.om.byteObjectHash(str))
            if sym != .none { m.store(holder, i, sym, .instVarAtPut) }
            return sym
        }
    }
}

/// The brief's suspected hole: a worker's lookup misses, another worker
/// interns the same bytes and drops the Symbol, a scavenge with an initial
/// mark comes, and the first worker's second lookup (in the intern stop
/// before this module, under the lock since) finds the Symbol, a snapshot
/// entry held only by the bucket's weak slot, and hands it on. Stored into
/// an already scanned holder and dropped, it is swept under the holder
/// unless the second lookup keeps it alive.
private func secondLookupDuringMarking(keepAlive: Bool) throws -> (missed: UInt64, alive: Bool) {
    let rt = try internRuntime { c in c.testSwitches.internNoKeepAlive = !keepAlive }
    #expect(rt.runInt("internDrop:", oop: rt.vm.newString("zzHole")) == 0)  // made and dropped
    rt.run("mkWeakH")
    rt.scavenge()
    let h = rt.global(13)
    rt.vm.startCycle()
    _ = rt.vm.markStep(10_000_000)  // H, the table and the bucket scanned; the Symbol not marked
    let sym = rt.internSlowInto("zzHole", h, 0)  // the second lookup finds it
    _ = rt.vm.markStep(10_000_000)
    rt.vm.finalMark()
    let missed = rt.marking.missed
    if missed > 0 {
        rt.stop(verifyHeap: false)
        return (missed, false)
    }
    rt.vm.sweep()
    rt.scavenge()
    let alive = rt.vm.inspect { $0.isUsedReference(sym) } && rt.slot(h, 0) == sym
    rt.stop(verifyHeap: alive)
    return (missed, alive)
}

@Test func aSymbolTheSecondLookupFindsDuringMarkingIsKeptAlive() throws {
    let (missed, alive) = try secondLookupDuringMarking(keepAlive: true)
    #expect(missed == 0 && alive, "missed \(missed)")
    let (missedOff, aliveOff) = try secondLookupDuringMarking(keepAlive: false)
    #expect(missedOff > 0 || !aliveOff)
}
