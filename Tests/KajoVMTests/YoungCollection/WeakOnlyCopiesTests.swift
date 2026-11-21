// The third review's small fixes, part 2, item 4 (memory.A1): the counter
// `weakOnlyCopies`, objects the concurrent young collector first copied
// through a weak object's indexed slot. The stop-the-world scavenge does not
// trace those slots (a young referent held only weakly dies there); the
// concurrent collector traces them as strong (v0), so such an object is
// copied, promoted and left to a marking cycle. The counter says how many.

import Testing
@testable import KajoVM

/// A weak bag (no named slots, indexed slots weak) whose slot 1 takes a
/// fresh Pair every iteration, held by nothing else; a second Pair per
/// iteration is garbage, so the nursery fills and is collected while the
/// bag names a young Pair only weakly.
let weakOnlySrc = """
class WeakBag Object 0 weak
class Pair Object 2
; args t0 = w, t1 = n; t2 the bag, t3 i
method UndefinedObject run:of: temps=2
  push_lit @WeakBag
  push_int 8
  send new: 1
  store_temp 2
  push_int 0
  store_temp 3
loop:
  push_temp 3
  push_lit 200000
  lt
  jump_if_false done
  push_temp 2
  push_int 1
  push_lit @Pair
  send basicNew 0
  send at:put: 2
  pop
  push_lit @Pair
  send basicNew 0
  pop
  push_temp 3
  push_int 1
  add
  store_temp 3
  jump loop
done:
  push_int 0
  return_top
end
"""

private func weakOnlyRun(young: String) -> Headless.Outcome {
    var o = Headless.Options()
    o.workers = 1
    o.nurseryKB = 1024  // a collection every 1 MiB: about a dozen in the run
    o.young = young
    o.verify = .withoutHeap
    return Headless.run([("prelude.kasm", kernel("prelude")), ("lib.kasm", kernel("lib")), ("weak.kasm", weakOnlySrc)],
                        options: o)
}

/// Under offload the collector copies the Pairs it finds through the bag's
/// weak slot and counts them; under the oracle (`--young stw`) no
/// concurrent collection runs and the counter reads 0.
@Test func weakOnlyCopiesCountsWhatOnlyAWeakSlotHeld() throws {
    let off = weakOnlyRun(young: "offload")
    #expect(try off.checksum.get() == 0)
    let offCount = UInt64(reportValue(off, "weakOnlyCopies") ?? "") ?? 0
    let collections = (UInt64(reportValue(off, "ycLocal") ?? "") ?? 0) + (UInt64(reportValue(off, "ycOffloaded") ?? "") ?? 0)
    print("weak-only offload: weakOnlyCopies=\(offCount) ycLocal=\(reportValue(off, "ycLocal") ?? "-") ycOffloaded=\(reportValue(off, "ycOffloaded") ?? "-") ycPromoted=\(reportValue(off, "ycPromoted") ?? "-")")
    #expect(collections > 0, "no concurrent young collection ran")
    #expect(offCount > 0)
    let stw = weakOnlyRun(young: "stw")
    #expect(try stw.checksum.get() == 0)
    let stwCount = reportValue(stw, "weakOnlyCopies")
    print("weak-only stw: weakOnlyCopies=\(stwCount ?? "-")")
    #expect(stwCount == nil || stwCount == "0")
}
