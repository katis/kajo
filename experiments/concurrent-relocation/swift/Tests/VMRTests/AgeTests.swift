// Headless tests of the age field and the survivor spaces (SPEC.md "Part 1").
// Every runtime has every verifier on: after each scavenge the verifier
// checks that young objects are only in survivor spaces with an age below N
// and in a young log, that every old holder of a young object is
// remembered, and that the scavenge copied each reachable young object
// exactly once.

import Darwin
import Kasm
import Testing
@testable import VMR

private let src = """
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

private func ageRuntime(_ n: Int, survivorKB: Int = 0) throws -> Runtime {
    var cfg = CMConfig()
    cfg.ageN = n
    cfg.survivorBytes = survivorKB * 1024
    return try runtime(src, background: 1, start: false, config: cfg)
}

private func spawnRun(_ rt: Runtime, _ sel: String, _ arg: Oop? = nil) {
    let vm = rt.vm
    spawn(vm, vm.pointee.nilObj, rt.symbol(sel), arg ?? vm.pointee.nilObj)
    #expect(runOneSlice(vm, rt.workers[1]))
}

private func age(_ rt: Runtime, _ o: Oop) -> Int { hdrAge(rt.vm.pointee.om.header(o)) }
private func young(_ rt: Runtime, _ o: Oop) -> Bool { rt.vm.pointee.om.isYoung(o) }
private func slot(_ rt: Runtime, _ o: Oop, _ i: Int) -> Oop { rt.vm.pointee.om.slot(o, i) }
private func remembered(_ rt: Runtime, _ o: Oop) -> Bool {
    rt.vm.pointee.space.rem[Int(o >> 4)].load(ordering: .relaxed) != 0
}

@Test func theAgeFieldPromotesAtNAndNotBefore() throws {
    let rt = try ageRuntime(3)
    let vm = rt.vm
    spawnRun(rt, "mkPair")
    let p = global(rt, 7), q = slot(rt, p, 1)
    #expect(young(rt, p) && young(rt, q) && age(rt, p) == 0)
    hostCollect(vm, full: false)
    #expect(young(rt, p) && young(rt, q) && age(rt, p) == 1 && age(rt, q) == 1)
    hostCollect(vm, full: false)
    #expect(young(rt, p) && young(rt, q) && age(rt, p) == 2)
    hostCollect(vm, full: false)
    #expect(!young(rt, p) && !young(rt, q) && age(rt, p) == 0)
    #expect(global(rt, 7) == p && slot(rt, p, 1) == q)
    #expect(slot(rt, p, 0) == mkInt(1) && slot(rt, q, 0) == mkInt(2))
    #expect(vm.metric(.survivedBytes) >= 2 * 2 * 24 && vm.metric(.overflowObjects) == 0)
    #expect(vm.metric(.verifyRuns) == 3 && vm.metric(.verifyFailures) == 0)
    rt.stop()
}

@Test func nOfOnePromotesOnFirstSurvival() throws {
    let rt = try ageRuntime(1)
    spawnRun(rt, "mkPair")
    let p = global(rt, 7)
    hostCollect(rt.vm, full: false)
    #expect(!young(rt, p))
    #expect(rt.vm.metric(.survivedBytes) == 0 && rt.vm.metric(.verifyFailures) == 0)
    rt.stop()
}

@Test func survivorOverflowPromotesEarly() throws {
    // 16 KiB survivor halves; a 2000-Pair list (48 000 bytes) survives.
    let rt = try ageRuntime(4, survivorKB: 16)
    let vm = rt.vm
    spawnRun(rt, "list:", mkInt(2000))
    hostCollect(vm, full: false)
    let survived = vm.metric(.survivedBytes), overflow = vm.metric(.overflowBytes)
    #expect(survived > 0 && survived <= 16 * 1024)
    #expect(overflow > 0 && survived + overflow >= 2000 * 24)
    #expect(vm.metric(.overflowObjects) > 0)
    // The list is intact across the split.
    var sum: Int64 = 0
    var o = global(rt, 8)
    while o != vm.pointee.nilObj { sum += intVal(slot(rt, o, 0)); o = slot(rt, o, 1) }
    #expect(sum == 2000 * 2001 / 2)
    #expect(vm.metric(.verifyFailures) == 0)
    rt.stop()
}

@Test func anOldHolderOfASurvivorStaysRemembered() throws {
    let rt = try ageRuntime(3)
    let vm = rt.vm
    spawnRun(rt, "mkPair")
    for _ in 0..<3 { hostCollect(vm, full: false) }
    let h = global(rt, 7)
    #expect(!young(rt, h) && !remembered(rt, h))
    spawnRun(rt, "storeFresh")   // old H -> young Y: the barrier remembers H
    let y = slot(rt, h, 1)
    #expect(young(rt, y) && remembered(rt, h))
    hostCollect(vm, full: false)  // Y survives (age 1): H stays remembered
    #expect(young(rt, y) && age(rt, y) == 1 && remembered(rt, h))
    hostCollect(vm, full: false)
    #expect(young(rt, y) && age(rt, y) == 2 && remembered(rt, h))
    hostCollect(vm, full: false)  // Y promoted: H leaves the remembered set
    #expect(!young(rt, y) && !remembered(rt, h))
    #expect(slot(rt, h, 1) == y && slot(rt, y, 0) == mkInt(3))
    #expect(vm.metric(.verifyFailures) == 0)
    rt.stop()
}

@Test func aPromotedHolderOfASurvivorIsRemembered() throws {
    let rt = try ageRuntime(3)
    let vm = rt.vm
    spawnRun(rt, "mkPair")
    hostCollect(vm, full: false)
    hostCollect(vm, full: false)  // P and Q age 2
    let p = global(rt, 7)
    spawnRun(rt, "storeFresh")    // young P -> fresh Y: no barrier (young holder)
    let y = slot(rt, p, 1)
    #expect(young(rt, p) && age(rt, p) == 2 && young(rt, y) && !remembered(rt, p))
    hostCollect(vm, full: false)  // P promoted, Y survives: P must be remembered
    #expect(!young(rt, p) && young(rt, y) && remembered(rt, p))
    hostCollect(vm, full: false)
    hostCollect(vm, full: false)
    #expect(!young(rt, y) && !remembered(rt, p) && slot(rt, y, 0) == mkInt(3))
    #expect(vm.metric(.verifyFailures) == 0)
    rt.stop()
}

@Test func aFullCollectionPromotesTheSurvivors() throws {
    let rt = try ageRuntime(4)
    let vm = rt.vm
    spawnRun(rt, "mkPair")
    hostCollect(vm, full: false)
    let p = global(rt, 7)
    #expect(young(rt, p))
    hostCollect(vm, full: true)
    #expect(!young(rt, p) && !young(rt, slot(rt, p, 1)))
    #expect(vm.metric(.verifyFailures) == 0)
    rt.stop()
}
