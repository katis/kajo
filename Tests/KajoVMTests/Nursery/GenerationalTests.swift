// Ported from experiments/generational-gc/swift/Tests/VMGTests/
// GenerationalTests.swift (the parked-count test is module 3's). The
// experiment promoted on first survival; where a test reasons about that it
// runs with age 1, otherwise with the default age of 2.

import Darwin
import Testing
@testable import KajoVM

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
    let rt = try nurseryRuntime(src)
    rt.spawn("makeKeep")
    rt.runOn(1)
    let p = rt.global(7)
    let arr = rt.slot(p, 1)
    #expect(rt.young(p) && rt.young(arr) && rt.space(p) == .eden(1) && rt.space(arr) == .eden(1))
    rt.scavenge()   // survives: young, age 1, in the scavenger's survivor space
    #expect(rt.global(7) == p && rt.young(p) && rt.age(p) == 1 && rt.young(arr) && rt.age(arr) == 1)
    #expect(rt.space(p).isSurvivor && rt.space(arr).isSurvivor)
    rt.scavenge()   // promoted at N = 2
    #expect(rt.global(7) == p)
    #expect(!rt.young(p) && rt.space(p) == .old && !rt.young(arr) && rt.space(arr) == .old)
    #expect(rt.slot(p, 0) == int(7) && rt.slot(p, 1) == arr)
    #expect((0..<3).map { rt.slot(arr, $0).smallIntegerValue } == [11, 22, 33])
    #expect(rt.vm.nurseryCounters.scavenges == 2 && rt.vm.nurseryCounters.verifierRuns == 2)
    rt.noFailures()
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
    let rt = try nurseryRuntime(src, age: 1)
    rt.spawn("makeHolders")
    rt.runOn(1)
    rt.scavenge()
    let holder = rt.global(8), pair9 = rt.global(9)
    #expect(!rt.young(holder) && !rt.young(pair9))
    rt.spawn("storeYoung")
    rt.runOn(1)
    let young = rt.slot(holder, 1)
    #expect(rt.young(young) && rt.slot(pair9, 0) == young)
    #expect(rt.remembered(holder) && rt.remembered(pair9))
    #expect(rt.vm.rememberedBufferCount(worker: 1) == 2) // each holder once
    rt.scavenge()
    #expect(rt.slot(holder, 1) == young && !rt.young(young) && rt.space(young) == .old)
    #expect(rt.slot(young, 0) == int(5) && rt.slot(young, 1) == int(6))
    #expect(!rt.remembered(holder) && !rt.remembered(pair9))
    rt.noFailures()
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
    let rt = try nurseryRuntime(src, age: 1)
    rt.spawn("makeHolder")
    rt.runOn(1)
    rt.scavenge()
    let holder = rt.global(8)
    #expect(!rt.young(holder))
    // A VM-internal store without the barrier: old holder, young value.
    let pair = rt.image.classIndex(named: "Pair")!
    rt.vm.onHostWorker { m in
        let young = m.allocate(pair, slots: 2)
        m.om.store(holder, 0, young)   // module 1's raw store: no barrier
    }
    rt.scavenge()
    #expect(verifierCounts(rt).failures > 0)
    #expect(rt.image.om.verifierReports.contains { $0.contains("not remembered") })
    rt.stop(verifyHeap: false)
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
    let rt = try nurseryRuntime(src, background: 2, age: 1)
    let sem = rt.semaphore(global: 10)
    rt.spawn("makeShared")
    rt.runOn(1)
    rt.scavenge()
    rt.spawn("producer")
    rt.runOn(1)
    let y = rt.slot(rt.global(8), 0)
    let consumer = rt.spawn("consumer")
    rt.runOn(2) // runs until it waits, holding X (nursery 2) -> Y (nursery 1)
    #expect(rt.slot(rt.global(8), 0) == rt.image.nilObject && rt.young(y))
    #expect(rt.space(y) == .eden(1) && rt.header(y).nurseryIndex == 1)
    let promoted0 = rt.vm.nurseryCounters.promotedObjects
    rt.scavenge()
    #expect(!rt.young(y) && rt.slot(y, 0) == int(42))
    #expect(rt.vm.nurseryCounters.promotedObjects > promoted0)
    rt.vm.signal(sem)
    rt.runOn(2)
    #expect(rt.result(consumer) == 42)
    rt.noFailures()
    rt.stop()
}

/// Module 7: in every mode (the stop-the-world scavenge, local collection,
/// the offload policy); the suite also runs under load and under
/// ThreadSanitizer. Without stopping the world each worker collects its own
/// nursery while the others take its objects (cross-nursery holders, the
/// deletion barrier, rounds), and the young verifier runs after every
/// fourth collection.
@Test(arguments: YoungMode.allCases)
func sharedYoungObjectsAreClaimedOnceByParallelScavengers(_ mode: YoungMode) throws {
    // 8 Processes on 8 workers each publish a young Array of 32 Pairs in an
    // old Array (global 9) and link the neighbour's young Array into their
    // own young list, while 256 KiB nurseries force scavenges with up to 8
    // participants. Publication goes through a Semaphore used as a mutex
    // (global 11). The verifier checks every scavenge copied each reachable
    // young object exactly once; results check contents.
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
    let rt = try nurseryRuntime(src, background: 8, nurseryKB: 256, start: true, configure: {
        $0.young.mode = mode
        $0.young.verify = true
        $0.young.verifyEvery = 4
    })
    let mutex = rt.semaphore(global: 11)
    rt.vm.signal(mutex)
    rt.spawn("makeShared")
    rt.waitAllTerminated()
    // Rounds of eight sharers until a scavenge had four participants, at
    // most three: a parked worker joins a scavenge, and in a loaded release
    // suite (module 8c's gate run) one round's workers were too often
    // descheduled or idle for four to be parked in any of its scavenges.
    for _ in 0..<3 {
        var ps: [Oop] = []
        for i in 0..<8 { ps.append(rt.spawn("sharer:", [int(Int64(i))])) }
        rt.waitAllTerminated(underThreadSanitizer ? 600 : 120)
        for p in ps { #expect(rt.result(p) == 3000 * 32) }
        if mode != .stw || rt.vm.scavengeLog.contains(where: { $0.participants >= 4 }) { break }
    }
    let log = rt.vm.scavengeLog
    if mode == .stw {
        #expect(log.count >= 10)
        #expect(log.contains { $0.participants >= 4 })
        #expect(rt.vm.nurseryCounters.verifierRuns == UInt64(log.count))
    } else {
        let yc = rt.vm.youngCounters
        #expect(yc.collectionsLocal + yc.collectionsOffloaded >= 10, "\(yc)")
        #expect(yc.verifierRuns >= 2)
    }
    rt.noFailures()
    rt.stop()
}

@Test func deadYoungEntriesAreFreedAndReused() throws {
    // Module 4's scavenge sweep (module 7's collections sweep the same way).
    let rt = try nurseryRuntime(pairSrc, nurseryKB: 256, configure: { $0.young.mode = .stw })
    rt.spawn("churn:", [int(300_000)])
    rt.runOn(1)
    let c = rt.vm.nurseryCounters
    #expect(c.scavenges >= 20)
    #expect(c.youngAllocations >= 300_000)
    #expect(c.entriesFreed + 2_000 >= c.youngAllocations - 10_000) // the last cycle's Pairs are not swept yet
    // 300 000 entries were used; the table grew by a few runs only.
    #expect(rt.vm.inspect { $0.highWater } < 64 * 1024)
    rt.noFailures()
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
    let rt = try nurseryRuntime(src, background: 2, nurseryKB: 256)
    let sem = rt.semaphore(global: 10)
    let k = rt.spawn("keeper")
    rt.runOn(1) // builds the list, parks on the Semaphore
    #expect(rt.state(k) == .waiting)
    // The list lives only in the parked Process's stack segment.
    rt.spawn("churn:", [int(40_000)])
    rt.runOn(2) // churns in nursery 2: scavenges while the keeper is parked
    rt.scavenge()
    // Module 7: or young collections without stopping the world.
    let yc = rt.vm.youngCounters
    #expect(rt.vm.nurseryCounters.scavenges + yc.collectionsLocal + yc.collectionsOffloaded >= 3)
    rt.vm.signal(sem)
    rt.runOn(1)
    #expect(rt.result(k) == 300 * 301 / 2)
    rt.noFailures()
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
    let rt = try nurseryRuntime(src, age: 1, nurseryKB: 256)
    rt.spawn("makeHolder")
    rt.runOn(1)
    rt.spawn("fill")
    rt.runOn(1)
    rt.scavenge()
    #expect(rt.vm.nurseryCounters.promotedObjects + rt.vm.youngCounters.promotedObjects >= 20 * 4000)
    let before = rt.vm.inspect { $0.blocksInUse }
    rt.spawn("dropMost")
    rt.runOn(1)
    let fulls = rt.image.om.counters.collections
    rt.vm.collect()
    #expect(rt.image.om.counters.collections == fulls + 1)
    let after = rt.vm.inspect { $0.blocksInUse }
    #expect(after * 4 < before) // 19 of 20 lists freed
    let s = rt.spawn("sumFifth")
    rt.runOn(1)
    #expect(rt.result(s) == 4000 * 4001 / 2)
    // Allocation, promotion and the entry table keep working afterwards.
    let hw = rt.vm.inspect { $0.highWater }
    rt.spawn("fill")
    rt.runOn(1)
    rt.vm.collect()
    #expect(rt.vm.inspect { $0.highWater } <= hw + 8192) // freed entries were reused
    let s2 = rt.spawn("sumFifth")
    rt.runOn(1)
    #expect(rt.result(s2) == 4000 * 4001 / 2)
    rt.noFailures()
    rt.stop()
}

@Test func schedulerStoresIntoOldObjectsAreBarriered() throws {
    // Exercises the VM-internal barrier sites with an old holder and a young
    // value: Semaphore waiter list (first, link, last), signal's pop,
    // ready-queue link, unlink on terminate (queue and Semaphore), and a
    // Process's result. Each scavenge's verifier pre-check fails if any of
    // these stores skipped the barrier.
    #expect(try !schedulerStores(schedulerSrc, skip: nil))
}

let schedulerSrc = pairSrc + """
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

/// The body of `schedulerStoresIntoOldObjectsAreBarriered`, also run with
/// one barrier site switched off by the mutation tests.
/// Answers whether a verifier failed.
func schedulerStores(_ src: String, skip: BarrierSite?) throws -> Bool {
    let rt = try nurseryRuntime(src, age: 1, configure: { $0.nursery.testSwitches.skipBarrierAt = skip })
    do {
        try schedulerSteps(rt)
    } catch {
        // A verifier failed: the scavenge after it freed a reachable entry,
        // so the program must not go on.
        rt.stop(verifyHeap: false)
        return true
    }
    let failed = verifierCounts(rt).failures > 0
    rt.stop(verifyHeap: !failed)
    return failed
}

struct VerifierFailed: Error {}

extension Runtime {
    /// A scavenge that throws once a verifier has failed (tests that break
    /// a rule stop there).
    func checkedScavenge() throws {
        scavenge()
        if verifierCounts(self).failures > 0 { throw VerifierFailed() }
    }
}

private func schedulerSteps(_ rt: Runtime) throws {
    let sem = rt.semaphore(global: 10)
    try rt.checkedScavenge() // the Semaphore is old now
    #expect(!rt.young(sem))
    // An old Process waits on a young Semaphore: its waitingOn store.
    let tw = rt.spawn("twoWaits")
    rt.runOn(1)
    try rt.checkedScavenge()
    rt.vm.signal(sem)
    rt.runOn(1) // now waits on its own young Semaphore
    #expect(!rt.young(tw) && rt.young(rt.slot(tw, ProcessLayout.waitingOn)))
    try rt.checkedScavenge()
    rt.vm.terminate(tw)
    // A Process that becomes old while waiting, then terminates with a young result.
    let late = rt.spawn("late")
    rt.runOn(1)
    try rt.checkedScavenge()
    #expect(!rt.young(late))
    // Young waiters on the old Semaphore: first, link, last stores.
    var ws: [Oop] = []
    for _ in 0..<3 { ws.append(rt.spawn("waiter")); rt.runOn(1) }
    #expect(ws.allSatisfy { rt.state($0) == .waiting && rt.young($0) })
    try rt.checkedScavenge()
    // Ready-queue link and unlink: main-affine Processes wait in the main queue.
    let m1 = rt.spawn("idle", main: true)
    try rt.checkedScavenge() // m1 old, still queued
    let m2 = rt.spawn("idle", main: true) // old m1.next := young m2
    let m3 = rt.spawn("idle", main: true)
    try rt.checkedScavenge()
    let m4 = rt.spawn("idle", main: true) // old m3.next := young m4
    rt.vm.terminate(m3) // unlink: old m2.next := young m4
    try rt.checkedScavenge()
    // More young waiters behind old ones, then terminate an old middle
    // waiter (unlink) and signal (pop: sem.first := next).
    for _ in 0..<2 { ws.append(rt.spawn("waiter")); rt.runOn(1) }
    rt.vm.terminate(ws[1])
    try rt.checkedScavenge()
    for _ in 0..<6 { rt.vm.signal(sem); try rt.checkedScavenge() }
    while rt.vm.runOneSlice(worker: 1) {}
    try rt.checkedScavenge()
    // late answered a young Pair into its old Process: result slot barrier.
    let res = rt.slot(late, ProcessLayout.result)
    #expect(rt.slot(res, 0) == int(77))
    _ = rt.vm.runMain(budgetNs: 100_000_000)
    for m in [m1, m2, m3, m4] { #expect(rt.state(m) == .terminated) }
    #expect(rt.vm.nurseryCounters.barrierSlowCalls >= 6)
    #expect(rt.vm.nurseryCounters.verifierRuns >= 10)
}
