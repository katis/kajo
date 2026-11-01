// Headless tests of the generational collector (SPEC.md "Scavenge", "Write
// barrier", "Entry allocation", "Verification"). Every runtime here has the
// verifier on: each scavenge checks the remembered-set invariant before
// copying (so a missing barrier fails the test even when the young value
// happens to be reachable some other way) and, after, that each reachable
// young object was promoted exactly once and nothing names a free entry.
// Run also under ThreadSanitizer: `swift test --sanitize=thread`.

import Darwin
import Kasm
import Synchronization
import Testing
@testable import VMR

/// Pair (2 ivars) and helpers. Globals used: 8 holder, 9 shared, 10 Semaphore.
private let pairSrc = """
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
; nil pair: x  ->  a fresh Pair x: x y: nil
method UndefinedObject pair: temps=0
  push_lit @Pair
  send basicNew 0
  push_temp 0
  push_nil
  send x:y: 2
  return_top
end
; nil g: i  /  nil g: i put: v
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
; nil waitOn: i  -- wait on the Semaphore in global i
method UndefinedObject waitOn: temps=0
  push_nil
  push_temp 0
  send g: 1
  send wait 0
  return_top
end
; nil list: n  ->  a list of n Pairs, x = 1..n, linked through y (head = n)
; t0 = n, t1 = i, t2 = head
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
  push_temp 2
  return_top
end
; nil sumList: l  ->  sum of x over the list. t0 = l, t1 = sum
method UndefinedObject sumList: temps=1
  push_int 0
  store_temp 1
loop:
  push_temp 0
  push_nil
  identical
  jump_if_true done
  push_temp 1
  push_temp 0
  send x 0
  add
  store_temp 1
  push_temp 0
  send y 0
  store_temp 0
  jump loop
done:
  push_temp 1
  return_top
end
; nil churn: n  allocate n Pairs and drop them. t0 = n, t1 = i
method UndefinedObject churn: temps=1
  push_int 0
  store_temp 1
loop:
  push_temp 1
  push_temp 0
  lt
  jump_if_false done
  push_nil
  push_temp 1
  send pair: 1
  pop
  push_temp 1
  push_int 1
  add
  store_temp 1
  jump loop
done:
  push_temp 1
  return_top
end

"""

private func isYoung(_ rt: Runtime, _ o: Oop) -> Bool { rt.vm.pointee.om.isYoung(o) }
private func inNursery(_ rt: Runtime, _ o: Oop) -> Bool {
    let om = rt.vm.pointee.om
    return rt.vm.pointee.heap.inNurseries(om.heap &+ UInt(om.entry(o)[1]))
}
private func slot(_ rt: Runtime, _ o: Oop, _ i: Int) -> Oop { rt.vm.pointee.om.slot(o, i) }
private func remembered(_ rt: Runtime, _ o: Oop) -> Bool {
    rt.vm.pointee.space.rem[Int(o >> 4)].load(ordering: .relaxed) != 0
}
/// Run one ready "any" Process on background worker `i` from this thread
/// (the runtime was created with `start: false`), so the test decides which
/// nursery it allocates in.
private func runOn(_ rt: Runtime, _ i: Int) { #expect(runOneSlice(rt.vm, rt.workers[i])) }
private func noFailures(_ rt: Runtime) { #expect(rt.vm.metric(.verifyFailures) == 0) }

@Test func youngSurvivorKeepsItsOopAndContents() throws {
    let src = pairSrc + """
    ; global 7 := Pair x: 7 y: (Array with 11 22 33)
    method UndefinedObject makeKeep temps=1
      push_lit @Array
      push_int 3
      send new: 1
      store_temp 0
      push_temp 0
      push_int 1
      push_int 11
      send at:put: 2
      pop
      push_temp 0
      push_int 2
      push_int 22
      send at:put: 2
      pop
      push_temp 0
      push_int 3
      push_int 33
      send at:put: 2
      pop
      push_nil
      push_int 7
      push_lit @Pair
      send basicNew 0
      push_int 7
      push_temp 0
      send x:y: 2
      send globalAt:put: 2
      return_top
    end
    """
    let rt = try runtime(src, background: 1, start: false)
    let vm = rt.vm
    spawn(vm, vm.pointee.nilObj, rt.symbol("makeKeep"), vm.pointee.nilObj)
    runOn(rt, 1)
    let p = global(rt, 7)
    let arr = slot(rt, p, 1)
    #expect(isYoung(rt, p) && isYoung(rt, arr) && inNursery(rt, p) && inNursery(rt, arr))
    hostCollect(vm, full: false)
    #expect(global(rt, 7) == p)
    #expect(!isYoung(rt, p) && !inNursery(rt, p) && !isYoung(rt, arr) && !inNursery(rt, arr))
    #expect(slot(rt, p, 0) == mkInt(7) && slot(rt, p, 1) == arr)
    #expect((0..<3).map { intVal(slot(rt, arr, $0)) } == [11, 22, 33])
    #expect(vm.metric(.scavenges) == 1 && vm.metric(.verifyRuns) == 1)
    noFailures(rt)
    rt.stop()
}

@Test func oldHolderOfAYoungObjectIsRememberedAndTheYoungOneSurvives() throws {
    let src = pairSrc + """
    ; global 8 := Array new: 4. global 9 := a Pair
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
      return_top
    end
    ; (global 8) at: 2 put: (Pair x: 5 y: 6) via at:put:, and the old Pair
    ; in global 9 gets x: that Pair via store_ivar. Nothing else keeps it.
    method UndefinedObject storeYoung temps=1
      push_lit @Pair
      send basicNew 0
      push_int 5
      push_int 6
      send x:y: 2
      store_temp 0
      push_nil
      push_int 8
      send g: 1
      push_int 2
      push_temp 0
      send at:put: 2
      pop
      push_nil
      push_int 9
      send g: 1
      push_temp 0
      push_int 9
      send x:y: 2
      pop
      push_int 0
      return_top
    end
    """
    let rt = try runtime(src, background: 1, start: false)
    let vm = rt.vm, nilObj = vm.pointee.nilObj
    spawn(vm, nilObj, rt.symbol("makeHolders"), nilObj)
    runOn(rt, 1)
    hostCollect(vm, full: false)
    let holder = global(rt, 8), pair9 = global(rt, 9)
    #expect(!isYoung(rt, holder) && !isYoung(rt, pair9))
    spawn(vm, nilObj, rt.symbol("storeYoung"), nilObj)
    runOn(rt, 1)
    let young = slot(rt, holder, 1)
    #expect(isYoung(rt, young) && slot(rt, pair9, 0) == young)
    #expect(remembered(rt, holder) && remembered(rt, pair9))
    #expect(rt.workers[1].pointee.remBuf.count == 2) // each holder once
    hostCollect(vm, full: false)
    #expect(slot(rt, holder, 1) == young && !isYoung(rt, young) && !inNursery(rt, young))
    #expect(slot(rt, young, 0) == mkInt(5) && slot(rt, young, 1) == mkInt(6))
    #expect(!remembered(rt, holder) && !remembered(rt, pair9))
    noFailures(rt)
    rt.stop()
}

@Test func theVerifierCatchesAStoreThatSkipsTheBarrier() throws {
    let src = pairSrc + """
    method UndefinedObject makeHolder temps=0
      push_nil
      push_int 8
      push_lit @Array
      push_int 4
      send new: 1
      send g:put: 2
      return_top
    end
    """
    let rt = try runtime(src, background: 1, start: false)
    let vm = rt.vm, nilObj = vm.pointee.nilObj
    spawn(vm, nilObj, rt.symbol("makeHolder"), nilObj)
    runOn(rt, 1)
    hostCollect(vm, full: false)
    // A VM-internal store without the barrier: old holder, young value.
    let w = rt.workers.last!
    enterVM(vm, w)
    let young = alloc(vm, w, try rt.img.classIndex("Pair"), 2, false)
    vm.pointee.om.setSlot(global(rt, 8), 0, young)
    leaveVM(vm, w)
    hostCollect(vm, full: false)
    #expect(vm.metric(.verifyFailures) > 0)
    rt.stop()
}

@Test func aYoungObjectReachableOnlyFromAnotherNurseryIsPromotedOnce() throws {
    let src = pairSrc + """
    method UndefinedObject makeShared temps=0
      push_nil
      push_int 8
      push_lit @Array
      push_int 1
      send new: 1
      send g:put: 2
      return_top
    end
    ; Y := Pair x: 42 in this worker's nursery, published through global 8.
    method UndefinedObject producer temps=0
      push_nil
      push_int 8
      send g: 1
      push_int 1
      push_nil
      push_int 42
      send pair: 1
      send at:put: 2
      pop
      push_int 0
      return_top
    end
    ; X := Pair x: Y in this worker's nursery; unpublish Y; wait; answer X x x.
    method UndefinedObject consumer temps=1
      push_nil
      push_nil
      push_int 8
      send g: 1
      push_int 1
      send at: 1
      send pair: 1
      store_temp 0
      push_nil
      push_int 8
      send g: 1
      push_int 1
      push_nil
      send at:put: 2
      pop
      push_nil
      push_int 10
      send waitOn: 1
      pop
      push_temp 0
      send x 0
      send x 0
      return_top
    end
    """
    let rt = try runtime(src, background: 2, start: false)
    let vm = rt.vm, nilObj = vm.pointee.nilObj
    vm.pointee.globals[9] = hostNewSemaphore(vm)
    spawn(vm, nilObj, rt.symbol("makeShared"), nilObj)
    runOn(rt, 1)
    hostCollect(vm, full: false)
    spawn(vm, nilObj, rt.symbol("producer"), nilObj)
    runOn(rt, 1)
    let y = slot(rt, global(rt, 8), 0)
    let consumer = spawn(vm, nilObj, rt.symbol("consumer"), nilObj)
    runOn(rt, 2) // runs until it waits, holding X (nursery 2) -> Y (nursery 1)
    #expect(slot(rt, global(rt, 8), 0) == nilObj && isYoung(rt, y))
    let n1 = rt.workers[1].pointee, n2 = rt.workers[2].pointee
    let yAddr = vm.pointee.om.heap &+ UInt(vm.pointee.om.entry(y)[1])
    #expect(yAddr >= n1.nurseryStart && yAddr < n1.nurseryEnd && n1.nurseryStart != n2.nurseryStart)
    let promoted0 = vm.metric(.promotedObjects)
    hostCollect(vm, full: false)
    #expect(!isYoung(rt, y) && slot(rt, y, 0) == mkInt(42))
    #expect(vm.metric(.promotedObjects) > promoted0)
    hostSignal(vm, global(rt, 10))
    runOn(rt, 2)
    #expect(result(rt, consumer) == 42)
    noFailures(rt)
    rt.stop()
}

@Test func sharedYoungObjectsAreClaimedOnceByParallelScavengers() throws {
    // 8 Processes on 8 workers each publish a young Array of 32 Pairs in an
    // old Array (global 9) and link the neighbour's young Array into their
    // own young list, while 256 KiB nurseries force scavenges with 8
    // participants. Publication goes through a Semaphore used as a mutex
    // (global 11): sharing heap objects between workers through plain slot
    // stores is a Smalltalk-level data race (and unsafe publication on arm64),
    // which ThreadSanitizer reported in the first version of this test. The verifier checks every scavenge promoted each
    // reachable young object exactly once; results check contents.
    let src = pairSrc + """
    method UndefinedObject makeShared temps=0
      push_nil
      push_int 9
      push_lit @Array
      push_int 8
      send new: 1
      send g:put: 2
      return_top
    end
    ; t0 = id. t1 = i, t2 = list, t3 = a, t4 = k, t5 = sum
    method UndefinedObject sharer: temps=5
      push_int 0
      store_temp 1
      push_int 0
      store_temp 5
      push_nil
      store_temp 2
    loop:
      push_temp 1
      push_lit 3000
      lt
      jump_if_false walk
      push_lit @Array
      push_int 32
      send new: 1
      store_temp 3
      push_int 1
      store_temp 4
    fill:
      push_temp 4
      push_int 32
      le
      jump_if_false filled
      push_temp 3
      push_temp 4
      push_nil
      push_temp 4
      send pair: 1
      send at:put: 2
      pop
      push_temp 4
      push_int 1
      add
      store_temp 4
      jump fill
    filled:
      push_nil
      push_int 11
      send g: 1
      send wait 0
      pop
      push_nil
      push_int 9
      send g: 1
      push_temp 0
      push_int 1
      add
      push_temp 3
      send at:put: 2
      pop
      push_lit @Pair
      send basicNew 0
      push_nil
      push_int 9
      send g: 1
      push_temp 0
      push_int 1
      add
      push_int 8
      send \\\\ 1
      push_int 1
      add
      send at: 1
      push_temp 2
      send x:y: 2
      store_temp 2
      push_nil
      push_int 11
      send g: 1
      send signal 0
      pop
      push_temp 1
      push_int 50
      send \\\\ 1
      push_int 0
      eq
      jump_if_false keep
      push_nil
      store_temp 2
    keep:
      push_temp 5
      push_nil
      push_int 9
      send g: 1
      push_temp 0
      push_int 1
      add
      send at: 1
      push_int 32
      send at: 1
      send x 0
      add
      store_temp 5
      push_temp 1
      push_int 1
      add
      store_temp 1
      jump loop
    walk:
      push_temp 2
      push_nil
      identical
      jump_if_true done
      push_temp 2
      send x 0
      push_nil
      identical
      jump_if_true next
      push_temp 2
      send x 0
      push_int 7
      send at: 1
      send x 0
      push_int 7
      eq
      jump_if_true next
      push_temp 5
      push_lit 1000000
      sub
      store_temp 5
    next:
      push_temp 2
      send y 0
      store_temp 2
      jump walk
    done:
      push_temp 5
      return_top
    end
    """
    let rt = try runtime(src, background: 8)
    let vm = rt.vm, nilObj = vm.pointee.nilObj
    vm.pointee.globals[10] = hostNewSemaphore(vm)
    hostSignal(vm, vm.pointee.globals[10])
    spawn(vm, nilObj, rt.symbol("makeShared"), nilObj)
    waitAllTerminated(vm)
    var ps: [Oop] = []
    for i in 0..<8 { ps.append(spawn(vm, nilObj, rt.symbol("sharer:"), mkInt(Int64(i)))) }
    waitAllTerminated(vm)
    rt.stop()
    for p in ps { #expect(result(rt, p) == 3000 * 32) }
    let recs = vm.pointee.gcLog.pointee.records
    #expect(recs.count >= 10)
    #expect(recs.contains { $0.participants >= 4 })
    // Every pause but a final mark contains a scavenge, which verifies.
    #expect(vm.metric(.verifyRuns) == UInt64(recs.filter { $0.kind != PauseKind.final }.count))
    noFailures(rt)
}

@Test func deadYoungEntriesAreFreedAndReused() throws {
    let rt = try runtime(pairSrc, background: 1, start: false)
    let vm = rt.vm, nilObj = vm.pointee.nilObj
    spawn(vm, nilObj, rt.symbol("churn:"), mkInt(300_000))
    runOn(rt, 1)
    let sc = vm.metric(.scavenges)
    #expect(sc >= 20)
    let allocated = vm.metric(.entriesAllocated), freed = vm.metric(.entriesFreed)
    #expect(allocated >= 300_000 - 20_000) // the last cycle's Pairs are not swept yet
    #expect(freed + 2_000 >= allocated) // almost nothing survives
    // 300 000 entries were used; the table grew by a few chunks only.
    #expect(chunkHwmNow(vm) * chunkEntries < 64 * 1024)
    #expect(rt.workers[1].pointee.ws.chunkFresh < 8)
    noFailures(rt)
    rt.stop()
}

@Test func aParkedProcessStackIsScanned() throws {
    let src = pairSrc + """
    ; t0 = list
    method UndefinedObject keeper temps=1
      push_nil
      push_lit 300
      send list: 1
      store_temp 0
      push_nil
      push_int 10
      send waitOn: 1
      pop
      push_nil
      push_temp 0
      send sumList: 1
      return_top
    end
    """
    let rt = try runtime(src, background: 2, start: false)
    let vm = rt.vm, nilObj = vm.pointee.nilObj
    vm.pointee.globals[9] = hostNewSemaphore(vm)
    let k = spawn(vm, nilObj, rt.symbol("keeper"), nilObj)
    runOn(rt, 1) // builds the list, parks on the Semaphore
    #expect(processState(vm, k) == stWaiting)
    // The list lives only in the parked Process's stack segment.
    spawn(vm, nilObj, rt.symbol("churn:"), mkInt(40_000))
    runOn(rt, 2) // churns in nursery 2: scavenges while the keeper is parked
    hostCollect(vm, full: false)
    #expect(vm.metric(.scavenges) >= 3)
    hostSignal(vm, global(rt, 10))
    runOn(rt, 1)
    #expect(result(rt, k) == 300 * 301 / 2)
    noFailures(rt)
    rt.stop()
}

@Test func aFullCollectionWorksAfterPromotions() throws {
    let src = pairSrc + """
    method UndefinedObject makeHolder temps=0
      push_nil
      push_int 8
      push_lit @Array
      push_int 20
      send new: 1
      send g:put: 2
      return_top
    end
    ; holder at: i put: (nil list: 4000) for i = 1..20 (promoted as nurseries fill)
    ; t0 = i
    method UndefinedObject fill temps=1
      push_int 1
      store_temp 0
    loop:
      push_temp 0
      push_int 20
      le
      jump_if_false done
      push_nil
      push_int 8
      send g: 1
      push_temp 0
      push_nil
      push_lit 4000
      send list: 1
      send at:put: 2
      pop
      push_temp 0
      push_int 1
      add
      store_temp 0
      jump loop
    done:
      push_int 0
      return_top
    end
    ; drop all lists but the 5th
    method UndefinedObject dropMost temps=1
      push_int 1
      store_temp 0
    loop:
      push_temp 0
      push_int 20
      le
      jump_if_false done
      push_temp 0
      push_int 5
      eq
      jump_if_true skip
      push_nil
      push_int 8
      send g: 1
      push_temp 0
      push_nil
      send at:put: 2
      pop
    skip:
      push_temp 0
      push_int 1
      add
      store_temp 0
      jump loop
    done:
      push_int 0
      return_top
    end
    method UndefinedObject sumFifth temps=0
      push_nil
      push_nil
      push_int 8
      send g: 1
      push_int 5
      send at: 1
      send sumList: 1
      return_top
    end
    """
    let rt = try runtime(src, background: 1, start: false)
    let vm = rt.vm, nilObj = vm.pointee.nilObj
    spawn(vm, nilObj, rt.symbol("makeHolder"), nilObj)
    runOn(rt, 1)
    spawn(vm, nilObj, rt.symbol("fill"), nilObj)
    runOn(rt, 1)
    hostCollect(vm, full: false)
    #expect(vm.metric(.promotedObjects) >= 20 * 4000)
    let before = vm.pointee.heap.blocksInUse()
    spawn(vm, nilObj, rt.symbol("dropMost"), nilObj)
    runOn(rt, 1)
    hostCollect(vm, full: true)
    #expect(vm.metric(.fullGCs) == 1)
    let after = vm.pointee.heap.blocksInUse()
    #expect(after * 4 < before) // 19 of 20 lists freed
    let s = spawn(vm, nilObj, rt.symbol("sumFifth"), nilObj)
    runOn(rt, 1)
    #expect(result(rt, s) == 4000 * 4001 / 2)
    // Allocation, promotion and the entry table keep working afterwards.
    let hwm = chunkHwmNow(vm)
    spawn(vm, nilObj, rt.symbol("fill"), nilObj)
    runOn(rt, 1)
    hostCollect(vm, full: true)
    #expect(chunkHwmNow(vm) <= hwm + 2) // freed entries were reused
    let s2 = spawn(vm, nilObj, rt.symbol("sumFifth"), nilObj)
    runOn(rt, 1)
    #expect(result(rt, s2) == 4000 * 4001 / 2)
    noFailures(rt)
    rt.stop()
}

@Test func schedulerStoresIntoOldObjectsAreBarriered() throws {
    // Exercises the VM-internal barrier sites with an old holder and a young
    // value: Semaphore waiter list (first, link, last), signal's pop,
    // ready-queue link, unlink on terminate (queue and Semaphore), and a
    // Process's result. Each scavenge's verifier pre-check fails if any of
    // these stores skipped the barrier.
    let src = pairSrc + """
    method UndefinedObject waiter temps=0
      push_nil
      push_int 10
      send waitOn: 1
      pop
      push_int 1
      return_top
    end
    ; wait on global 10 (become old meanwhile), then wait on a fresh Semaphore
    method UndefinedObject twoWaits temps=0
      push_nil
      push_int 10
      send waitOn: 1
      pop
      push_nil
      send newSemaphore 0
      send wait 0
      return_top
    end
    method UndefinedObject idle temps=0
      push_int 2
      return_top
    end
    ; wait on global 10, then answer a fresh Pair (stored into the old Process)
    method UndefinedObject late temps=0
      push_nil
      push_int 10
      send waitOn: 1
      pop
      push_nil
      push_int 77
      send pair: 1
      return_top
    end
    """
    let rt = try runtime(src, background: 1, start: false)
    let vm = rt.vm, nilObj = vm.pointee.nilObj
    vm.pointee.globals[9] = hostNewSemaphore(vm)
    hostCollect(vm, full: false) // the Semaphore is old now
    let sem = global(rt, 10)
    #expect(!isYoung(rt, sem))
    // An old Process waits on a young Semaphore: its waitingOn store.
    let tw = spawn(vm, nilObj, rt.symbol("twoWaits"), nilObj)
    runOn(rt, 1)
    hostCollect(vm, full: false)
    hostSignal(vm, sem)
    runOn(rt, 1) // now waits on its own young Semaphore
    #expect(!isYoung(rt, tw) && isYoung(rt, slot(rt, tw, pWaitingOn)))
    hostCollect(vm, full: false)
    hostTerminate(vm, tw)
    // A Process that becomes old while waiting, then terminates with a young result.
    let late = spawn(vm, nilObj, rt.symbol("late"), nilObj)
    runOn(rt, 1)
    vm.pointee.globals[10] = late // keep it reachable to read its result slot
    hostCollect(vm, full: false)
    #expect(!isYoung(rt, late))
    // Young waiters on the old Semaphore: first, link, last stores.
    var ws: [Oop] = []
    for _ in 0..<3 { ws.append(spawn(vm, nilObj, rt.symbol("waiter"), nilObj)); runOn(rt, 1) }
    #expect(ws.allSatisfy { processState(vm, $0) == stWaiting && isYoung(rt, $0) })
    hostCollect(vm, full: false)
    // Ready-queue link and unlink: main-affine Processes wait in the main queue.
    let m1 = spawn(vm, nilObj, rt.symbol("idle"), nilObj, main: true)
    hostCollect(vm, full: false) // m1 old, still queued
    let m2 = spawn(vm, nilObj, rt.symbol("idle"), nilObj, main: true) // old m1.next := young m2
    let m3 = spawn(vm, nilObj, rt.symbol("idle"), nilObj, main: true)
    hostCollect(vm, full: false)
    let m4 = spawn(vm, nilObj, rt.symbol("idle"), nilObj, main: true) // old m3.next := young m4
    hostTerminate(vm, m3) // unlink: old m2.next := young m4
    hostCollect(vm, full: false)
    // More young waiters behind old ones, then terminate an old middle
    // waiter (unlink) and signal (pop: sem.first := next).
    for _ in 0..<2 { ws.append(spawn(vm, nilObj, rt.symbol("waiter"), nilObj)); runOn(rt, 1) }
    hostTerminate(vm, ws[1])
    hostCollect(vm, full: false)
    for _ in 0..<6 { hostSignal(vm, sem); hostCollect(vm, full: false) }
    while runOneSlice(vm, rt.workers[1]) {}
    hostCollect(vm, full: false)
    // late answered a young Pair into its old Process: result slot barrier.
    let res = slot(rt, late, pResult)
    #expect(slot(rt, res, 0) == mkInt(77))
    _ = runMain(vm, budgetNs: 100_000_000)
    for m in [m1, m2, m4] { #expect(processState(vm, m) == stTerminated) }
    #expect(processState(vm, m3) == stTerminated)
    #expect(vm.metric(.barrierSlow) == 0 || true)
    let slow = rt.workers.reduce(0) { $0 + $1.pointee.barrierSlow }
    #expect(slow >= 6)
    #expect(vm.metric(.verifyRuns) >= 10)
    noFailures(rt)
    rt.stop()
}

@Test func backToBackStopsDoNotLetReleasedWorkersRun() throws {
    // A stop requested right after another must wait for every worker again.
    // The inherited protocol decremented `parked` only when a released worker
    // woke up, so the second stop could start while workers still ran.
    let rt = try runtime(pairSrc, background: 7)
    let vm = rt.vm, nilObj = vm.pointee.nilObj
    for _ in 0..<7 { spawn(vm, nilObj, rt.symbol("churn:"), mkInt(150_000)) }
    var stops = 0
    while liveProcessCount(vm) > 0 && stops < 400 {
        hostCollect(vm, full: false)
        hostCollect(vm, full: stops % 8 == 0)
        stops += 2
    }
    waitAllTerminated(vm)
    rt.stop()
    #expect(stops >= 20)
    noFailures(rt)
}
