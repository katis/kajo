// Ported from experiments/concurrent-relocation/swift/Tests/VMRTests/
// AgeTests.swift (SPEC.md "Part 1"), plus the claim-tag tests the brief
// asks for. Every runtime has every verifier on: after each scavenge young
// objects lie only in eden or survivor-from with an age below N, every old
// holder of a young object is remembered, and each reachable young object
// was copied exactly once.

import Darwin
import Testing
@testable import KajoVM

let ageSrc = """
class Pair Object 2
method Pair x temps=0
  push_ivar 0
  return_top
end
method Pair y temps=0
  push_ivar 1
  return_top
end
method Pair x:y: temps=0
  push_temp 0
  store_ivar 0
  push_temp 1
  store_ivar 1
  return_self
end
method UndefinedObject g: temps=0
  push_nil
  push_temp 0
  send globalAt: 1
  return_top
end
method UndefinedObject g:put: temps=0
  push_nil
  push_temp 0
  push_temp 1
  send globalAt:put: 2
  return_top
end
; global 7 := Pair x: 1 y: (Pair x: 2 y: nil)
method UndefinedObject mkPair temps=0
  push_nil
  push_int 7
  push_lit @Pair
  send basicNew 0
  push_int 1
  push_lit @Pair
  send basicNew 0
  push_int 2
  push_nil
  send x:y: 2
  send x:y: 2
  send g:put: 2
  return_top
end
; (global 7) x: 1 y: (Pair x: 3 y: nil)  (a fresh young object in the holder)
method UndefinedObject storeFresh temps=0
  push_nil
  push_int 7
  send g: 1
  push_int 1
  push_lit @Pair
  send basicNew 0
  push_int 3
  push_nil
  send x:y: 2
  send x:y: 2
  return_top
end
; global 8 := a list of n Pairs (x = 1..n linked through y). t0 = n, t1 = i, t2 = head
method UndefinedObject list: temps=2
  push_int 1
  store_temp 1
  push_nil
  store_temp 2
loop:
  push_temp 1
  push_temp 0
  le
  jump_if_false done
  push_lit @Pair
  send basicNew 0
  push_temp 1
  push_temp 2
  send x:y: 2
  store_temp 2
  push_temp 1
  push_int 1
  add
  store_temp 1
  jump loop
done:
  push_nil
  push_int 8
  push_temp 2
  send g:put: 2
  return_top
end
"""

private func ageRuntime(_ n: Int, survivorKB: Int = 0, configure: (inout VMConfig) -> Void = { _ in }) throws -> Runtime {
    try nurseryRuntime(ageSrc, age: n, survivorKB: survivorKB, configure: configure)
}

private func spawnRun(_ rt: Runtime, _ sel: String, _ args: [Oop] = []) {
    rt.spawn(sel, args)
    rt.runOn(1)
}

@Test func theAgeFieldPromotesAtNAndNotBefore() throws {
    let rt = try ageRuntime(3)
    spawnRun(rt, "mkPair")
    let p = rt.global(7), q = rt.slot(p, 1)
    #expect(rt.young(p) && rt.young(q) && rt.age(p) == 0)
    rt.scavenge()
    #expect(rt.young(p) && rt.young(q) && rt.age(p) == 1 && rt.age(q) == 1)
    rt.scavenge()
    #expect(rt.young(p) && rt.young(q) && rt.age(p) == 2)
    rt.scavenge()
    #expect(!rt.young(p) && !rt.young(q) && rt.age(p) == 0)
    #expect(rt.global(7) == p && rt.slot(p, 1) == q)
    #expect(rt.slot(p, 0) == int(1) && rt.slot(q, 0) == int(2))
    let c = rt.vm.nurseryCounters
    #expect(c.survivedBytes >= 2 * 2 * 24 && c.overflowObjects == 0)
    #expect(c.verifierRuns == 3)
    rt.noFailures()
    rt.stop()
}

@Test func nOfOnePromotesOnFirstSurvival() throws {
    let rt = try ageRuntime(1)
    spawnRun(rt, "mkPair")
    let p = rt.global(7)
    rt.scavenge()
    #expect(!rt.young(p))
    #expect(rt.vm.nurseryCounters.survivedBytes == 0)
    rt.noFailures()
    rt.stop()
}

@Test func survivorOverflowPromotesEarly() throws {
    // 16 KiB survivor halves; a 2000-Pair list (48 000 bytes) survives.
    let rt = try ageRuntime(4, survivorKB: 16)
    spawnRun(rt, "list:", [int(2000)])
    rt.scavenge()
    let c = rt.vm.nurseryCounters
    #expect(c.survivedBytes > 0 && c.survivedBytes <= 16 * 1024)
    #expect(c.overflowBytes > 0 && c.survivedBytes + c.overflowBytes >= 2000 * 24)
    #expect(c.overflowObjects > 0)
    // The list is intact across the split.
    var sum: Int64 = 0
    var o = rt.global(8)
    while o != rt.image.nilObject { sum += rt.slot(o, 0).smallIntegerValue; o = rt.slot(o, 1) }
    #expect(sum == 2000 * 2001 / 2)
    rt.noFailures()
    rt.stop()
}

/// The rule found by this test (concurrent-relocation RESULTS section 7,
/// item 3): a remembered holder stays remembered while it holds a
/// survivor. Switched off, the verifier finds the unremembered holder.
@Test(arguments: [false, true])
func anOldHolderOfASurvivorStaysRemembered(_ broken: Bool) throws {
    let rt = try ageRuntime(3, configure: { $0.nursery.testSwitches.dropCarriedHolders = broken })
    spawnRun(rt, "mkPair")
    for _ in 0..<3 { rt.scavenge() }
    let h = rt.global(7)
    #expect(!rt.young(h) && !rt.remembered(h))
    spawnRun(rt, "storeFresh")   // old H -> young Y: the barrier remembers H
    let y = rt.slot(h, 1)
    #expect(rt.young(y) && rt.remembered(h))
    rt.scavenge()  // Y survives (age 1): H stays remembered
    if broken {
        rt.scavenge()
        #expect(verifierCounts(rt).failures > 0)
        rt.stop(verifyHeap: false)
        return
    }
    #expect(rt.young(y) && rt.age(y) == 1 && rt.remembered(h))
    rt.scavenge()
    #expect(rt.young(y) && rt.age(y) == 2 && rt.remembered(h))
    rt.scavenge()  // Y promoted: H leaves the remembered set
    #expect(!rt.young(y) && !rt.remembered(h))
    #expect(rt.slot(h, 1) == y && rt.slot(y, 0) == int(3))
    rt.noFailures()
    rt.stop()
}

/// A holder promoted while it names a survivor is remembered; switched
/// off, the verifier finds it.
@Test(arguments: [false, true])
func aPromotedHolderOfASurvivorIsRemembered(_ broken: Bool) throws {
    let rt = try ageRuntime(3, configure: { $0.nursery.testSwitches.forgetPromotedHolders = broken })
    spawnRun(rt, "mkPair")
    rt.scavenge()
    rt.scavenge()  // P and Q age 2
    let p = rt.global(7)
    spawnRun(rt, "storeFresh")    // young P -> fresh Y: no barrier (young holder)
    let y = rt.slot(p, 1)
    #expect(rt.young(p) && rt.age(p) == 2 && rt.young(y) && !rt.remembered(p))
    rt.scavenge()  // P promoted, Y survives: P must be remembered
    if broken {
        rt.scavenge()
        #expect(verifierCounts(rt).failures > 0)
        rt.stop(verifyHeap: false)
        return
    }
    #expect(!rt.young(p) && rt.young(y) && rt.remembered(p))
    rt.scavenge()
    rt.scavenge()
    #expect(!rt.young(y) && !rt.remembered(p) && rt.slot(y, 0) == int(3))
    rt.noFailures()
    rt.stop()
}

@Test func aFullCollectionPromotesTheSurvivors() throws {
    let rt = try ageRuntime(4)
    spawnRun(rt, "mkPair")
    rt.scavenge()
    let p = rt.global(7)
    #expect(rt.young(p))
    rt.vm.collect()
    #expect(!rt.young(p) && !rt.young(rt.slot(p, 1)))
    #expect(rt.vm.nurseryCounters.promoteAllScavenges >= 1)
    rt.noFailures()
    rt.stop()
}

/// The claim protocol on one header: scavenge s claims with tag bit
/// 62 + (s & 1); the winner writes its decision into the header; a second
/// claim in the same scavenge loses and reads that decision; the next
/// scavenge, using the other bit, sees the object unclaimed.
@Test func theClaimTagAlternatesAndALoserReadsTheDecision() {
    var cell = ClaimCell(Header(classIndex: 5, count: 2, isBytes: false).youngIn(nursery: 3).raw)
    // scavenge 7 (tag bit 63), age 0 -> survives with age 1 in participant 2's nursery
    let first = cell.claim(scavenge: 7, ageLimit: 3, participant: 2, promoteAll: false, hasRoom: true)
    #expect(first.won && first.decision == .survive)
    let h1 = Header(raw: cell.value)
    #expect(h1.isYoung && h1.age == 1 && h1.nurseryIndex == 2 && h1.claimTag == 0b10)
    let second = cell.claim(scavenge: 7, ageLimit: 3, participant: 5, promoteAll: false, hasRoom: true)
    #expect(!second.won && second.decision == .survive)
    #expect(Header(raw: cell.value) == h1)
    // scavenge 8 (tag bit 62): unclaimed; age 1 -> 2, still below 3
    let third = cell.claim(scavenge: 8, ageLimit: 3, participant: 4, promoteAll: false, hasRoom: true)
    #expect(third.won && third.decision == .survive)
    let h2 = Header(raw: cell.value)
    #expect(h2.age == 2 && h2.nurseryIndex == 4 && h2.claimTag == 0b01)
    // scavenge 9: age 2 + 1 = 3 reaches N: promoted, every young bit cleared
    let fourth = cell.claim(scavenge: 9, ageLimit: 3, participant: 1, promoteAll: false, hasRoom: true)
    #expect(fourth.won && fourth.decision == .promote)
    let h3 = Header(raw: cell.value)
    #expect(!h3.isYoung && h3.age == 0 && h3.nurseryIndex == 0 && h3.claimTag == 0)
    #expect(h3.classIndex == 5 && h3.count == 2)
    // a loser of a promotion reads "promoted"
    let fifth = cell.claim(scavenge: 9, ageLimit: 3, participant: 6, promoteAll: false, hasRoom: true)
    #expect(!fifth.won && fifth.decision == .promote)
}

@Test func survivorToFullPromotesAndPromoteAllIgnoresTheAge() {
    var a = ClaimCell(Header(classIndex: 5, count: 2, isBytes: false).youngIn(nursery: 1).raw)
    let r = a.claim(scavenge: 1, ageLimit: 4, participant: 1, promoteAll: false, hasRoom: false)
    #expect(r.won && r.decision == .promoteOverflow && !Header(raw: a.value).isYoung)
    var b = ClaimCell(Header(classIndex: 5, count: 2, isBytes: false).youngIn(nursery: 1).raw)
    let s = b.claim(scavenge: 1, ageLimit: 4, participant: 1, promoteAll: true, hasRoom: true)
    #expect(s.won && s.decision == .promote && !Header(raw: b.value).isYoung)
}

/// With one claim tag for every scavenge, an object survivor of scavenge s
/// looks claimed in scavenge s + 1: nobody copies it, its entry is freed
/// while reachable, and the verifier reports it.
@Test(arguments: [false, true])
func aSurvivorIsCopiedByTheNextScavenge(_ sameTag: Bool) throws {
    let rt = try ageRuntime(3, configure: { $0.nursery.testSwitches.sameClaimTag = sameTag })
    spawnRun(rt, "mkPair")
    let p = rt.global(7)
    rt.scavenge()
    rt.scavenge()
    if sameTag {
        #expect(verifierCounts(rt).failures > 0)
        rt.stop(verifyHeap: false)
        return
    }
    #expect(rt.young(p) && rt.age(p) == 2 && rt.slot(rt.slot(p, 1), 0) == int(2))
    rt.noFailures()
    rt.stop()
}
