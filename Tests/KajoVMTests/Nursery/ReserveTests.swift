// The promotion reserve's fallback (docs/modules/reserve-and-depth.md):
// promotion that finds no block keeps the object young in place and asks
// for the full collection that makes room; a young collection that runs
// beside mutators opens only with its promotion room promised and stops the
// world for that scavenge otherwise; a full collection compacts when its
// mark-sweep leaves old space past its soft limit. Every verifier runs.

import Darwin
import Foundation
import Testing
@testable import KajoVM

/// Each worker: a ring of 1024 Pairs (a spine of old Arrays) whose nodes
/// live about three edens, so they are promoted and die in old space, plus
/// a young garbage Pair per iteration; the answer is the ring's payload sum
/// at the end. With no promotion reserve and a heap a little larger than
/// the image, promotions run out of blocks again and again.
let reserveLoadSrc = pairSrc + """
; t0 = iterations. t1 = i, t2 = ring, t3 = slot, t4 = sum
method UndefinedObject ring: temps=4
  push_lit @Array
  push_lit 1024
  send new: 1
  store_temp 2
  push_int 1
  store_temp 1
loop:
  push_temp 1
  push_temp 0
  le
  jump_if_false sum
  push_temp 2
  push_temp 1
  push_lit 1024
  mod
  push_int 1
  add
  push_nil
  push_temp 1
  send pair: 1
  send at:put: 2
  pop
  push_nil
  push_temp 1
  send pair: 1
  pop
  push_temp 1
  push_int 1
  add
  store_temp 1
  jump loop
sum:
  push_int 0
  store_temp 4
  push_int 1
  store_temp 3
sumloop:
  push_temp 3
  push_lit 1024
  le
  jump_if_false done
  push_temp 4
  push_temp 2
  push_temp 3
  send at: 1
  send x 0
  add
  store_temp 4
  push_temp 3
  push_int 1
  add
  store_temp 3
  jump sumloop
done:
  push_temp 4
  return_top
end
"""

/// The sum of the last 1024 payloads of `n` iterations.
private func ringSum(_ n: Int64) -> Int64 { (n - 1023...n).reduce(0, +) }

/// The image's blocks plus `headroom`: a heap the load overflows.
private func tightHeapBlocks(_ headroom: Int) throws -> Int {
    let probe = try nurseryRuntime(reserveLoadSrc, background: 4, nurseryKB: 24, start: false)
    defer { probe.stop() }
    return probe.image.om.blocksInUse + headroom
}

@Test(arguments: YoungMode.allCases, [0, 4])
func promotionPastTheReserveKeepsObjectsYoungAndTheProgramFinishes(_ mode: YoungMode, _ reserve: Int) throws {
    let blocks = try tightHeapBlocks(24)
    let rt = try nurseryRuntime(reserveLoadSrc, background: 4, nurseryKB: 24, start: true, heapBlocks: blocks,
                                configure: { c in
        c.nursery.testSwitches.promotionReserveBlocks = reserve
        // Concurrent marking's lazy sweep keeps this load's old space under
        // its soft limit; without it only full collections free old space.
        c.marking.enabled = false
        c.young.mode = mode
        c.young.verify = true
        c.young.verifyEvery = 4
    })
    let n: Int64 = underThreadSanitizer ? 20_000 : 60_000
    var ps: [Oop] = []
    for _ in 0..<4 { ps.append(rt.spawn("ring:", [int(n)])) }
    rt.waitAllTerminated(underThreadSanitizer ? 600 : 120)
    for p in ps { #expect(rt.result(p) == ringSum(n)) }
    let nc = rt.vm.nurseryCounters
    let yc = rt.vm.youngCounters
    #expect(nc.fullCollectionsRun > 0)
    if reserve == 0 {
        // Promotion ran out and the scavenge kept objects (counted,
        // reported), the full collections it requested ran, nothing trapped.
        #expect(rt.image.om.reserveExhaustions > 0)
        #expect(nc.exhaustedScavenges > 0 && nc.keptObjects > 0, "\(nc)")
    }
    if mode != .stw {
        // Young collections were refused their promotion room and stopped
        // the world for module 4's scavenge instead; with a reserve of four
        // blocks most of them still ran beside the mutators.
        #expect(yc.fallbacks[YoungFallback.reserve.rawValue] > 0, "\(yc)")
        if reserve > 0 { #expect(yc.collectionsLocal + yc.collectionsOffloaded > 0, "\(yc)") }
    }
    if ProcessInfo.processInfo.environment["KAJO_RESERVE_DEBUG"] != nil {
        print("RESERVE \(mode) \(reserve): exhaustions \(rt.image.om.reserveExhaustions) \(nc) \(yc)")
    }
    let report = Dictionary(nurseryReport(rt.vm, stops: rt.vm.stops, ms: 1), uniquingKeysWith: { a, _ in a })
    #expect(report["reserveExhaustions"] == "\(rt.image.om.reserveExhaustions)")
    #expect(report["keptObjects"] == "\(nc.keptObjects)")
    rt.noFailures()
    rt.stop()
}

/// The ring's cause: a mark-sweep frees whole blocks only, so an old space
/// whose blocks each keep one live object stays past its soft limit after
/// the full collection, and the scavenges after it promote into the
/// reserve. The full collection compacts then.
@Test func aFullCollectionCompactsAFragmentedOldSpace() throws {
    let rt = try nurseryRuntime(pairSrc + """
    ; holder at: i put: a Pair for i = 1..n, then every 64th linked into the
    ; chain in global 8 and the holder dropped: the survivors are scattered
    ; over every block the Pairs filled.
    ; t0 = n. t1 = i, t2 = holder, t3 = p
    method UndefinedObject scatter: temps=3
      push_lit @Array
      push_temp 0
      send new: 1
      store_temp 2
      push_int 1
      store_temp 1
    fill:
      push_temp 1
      push_temp 0
      le
      jump_if_false thin
      push_temp 2
      push_temp 1
      push_nil
      push_temp 1
      send pair: 1
      send at:put: 2
      pop
      push_temp 1
      push_int 1
      add
      store_temp 1
      jump fill
    thin:
      push_int 64
      store_temp 1
    thinloop:
      push_temp 1
      push_temp 0
      le
      jump_if_false done
      push_temp 2
      push_temp 1
      send at: 1
      store_temp 3
      push_temp 3
      push_temp 3
      send x 0
      push_nil
      push_int 8
      send g: 1
      send x:y: 2
      pop
      push_nil
      push_int 8
      push_temp 3
      send g:put: 2
      pop
      push_temp 1
      push_int 64
      add
      store_temp 1
      jump thinloop
    done:
      push_int 0
      return_top
    end
    """, background: 1, nurseryKB: 64, start: true, configure: { $0.young.mode = .stw })
    // 1000-slot holders fit a block; forty of them, each filled with Pairs
    // (one after the other: the chain in global 8 is not shared).
    for _ in 0..<40 {
        rt.spawn("scatter:", [int(1000)])
        rt.waitAllTerminated()
    }
    let om = rt.image.om
    // A full collection with old space under its soft limit only sweeps.
    let compactions = om.counters.compactions
    rt.vm.runFullCollection()
    #expect(om.counters.compactions == compactions)
    // Lower the soft limit below the blocks the scattered survivors occupy
    // (a sixty-fourth of the Pairs, beside the image): the next one
    // compacts.
    let inUse = om.blocksInUse
    rt.vm.withWorldStopped { om.softLimitBlocks = inUse - 2 }
    rt.vm.runFullCollection()
    #expect(om.counters.compactions > compactions)
    #expect(rt.vm.nurseryCounters.fullCompactions > 0)
    #expect(om.blocksInUse < inUse / 2, "\(om.blocksInUse) of \(inUse)")
    rt.noFailures()
    rt.stop()
}

