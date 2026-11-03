// Young collection without stopping the world (docs/modules/young-
// collection.md), ported from experiments/concurrent-young's YoungTests.
// Each rule has a test that passes with it and fails with it switched off
// (`YoungTestSwitches`). The collector is the test thread acting as the
// collecting worker; interleavings come from collector hooks run on its
// thread, or from helper threads acting as other workers. The young
// verifier runs at a stop after every collection.

import Darwin
import Foundation
import Synchronization
import Testing
@testable import KajoVM

// MARK: - the young deletion barrier and the second handshake

/// P (nursery 1, reachable from global 8) holds Y. After H1 (the hook), a
/// Process on worker 2 takes Y into a temporary, clears P's slot and parks
/// holding it. Its stack was scanned when it resumed, before it took Y; P is
/// scanned at T1 with the slot already cleared. Only the deletion record,
/// published in the drain round, keeps Y. Answers (verifier failures, Y x).
private func stealDuringCollection(_ change: (inout YoungTestSwitches) -> Void) throws -> (UInt64, Int64?) {
    let hooks = YoungHooks()
    let rt = try youngRuntime(.local) { c in
        hooks.install(&c.young.testSwitches)
        change(&c.young.testSwitches)
    }
    let sem = rt.semaphore(global: 10)
    rt.spawn("mkP")
    rt.runOn(1)                               // P, Y in nursery 1
    let thief = rt.spawn("steal")
    hooks.set(1) { k in if k == 1 { rt.runOn(2) } }  // runs until it waits holding Y
    rt.vm.collectYoung(worker: 1)
    hooks.set(1, nil)
    let f = rt.verifierFailures
    var r: Int64? = nil
    if f == 0 {
        rt.vm.signal(sem)
        rt.runOn(2)
        r = rt.result(thief)
    }
    rt.stop(verifyHeap: f == 0)
    return (f, r)
}

@Test func youngDeletionBarrierKeepsAValueTakenAfterH0() throws {
    let (f, r) = try stealDuringCollection { _ in }
    #expect(f == 0)
    #expect(r == 42)
}

@Test func withoutTheYoungDeletionBarrierTheValueIsLost() throws {
    let (f, _) = try stealDuringCollection { $0.youngDeletionBarrier = false }
    #expect(f > 0)
}

@Test func withoutTheSecondHandshakeTheDeletionRecordIsNeverSeen() throws {
    let (f, _) = try stealDuringCollection { $0.secondHandshake = false }
    #expect(f > 0)
}

// MARK: - the cross-nursery barrier

/// Y in nursery 1 is held only by H, a young object of nursery 2 reachable
/// from global 9. Collecting nursery 1 must find Y through H's remembered
/// bit for nursery 1.
private func crossNursery(_ on: Bool) throws -> (UInt64, Int64?) {
    let rt = try youngRuntime(.local) { $0.young.testSwitches.crossNurseryBarrier = on }
    rt.spawn("mkY")
    rt.runOn(1)
    rt.spawn("hold")
    rt.runOn(2)
    let h = rt.global(9)
    let hd = rt.header(h)
    #expect(hd.isYoung && hd.nurseryIndex == 2)
    rt.vm.collectYoung(worker: 1)
    let f = rt.verifierFailures
    var r: Int64? = nil
    if f == 0 {
        let p = rt.spawn("readH")
        rt.runOn(2)
        r = rt.result(p)
    }
    rt.stop(verifyHeap: f == 0)
    return (f, r)
}

@Test func aYoungHolderInAnotherNurseryIsRememberedAndScanned() throws {
    let (f, r) = try crossNursery(true)
    #expect(f == 0)
    #expect(r == 42)
}

@Test func withoutTheCrossNurseryBarrierTheValueIsLost() throws {
    let (f, _) = try crossNursery(false)
    #expect(f > 0)
}

// MARK: - the handshake stack scan

/// A thread acting as worker 2 runs a Process that takes Y off global 8 and
/// spins (polling) with Y only on its stack while worker 1 collects.
private func stackOnly(_ scan: Bool) throws -> (UInt64, Int64?) {
    let rt = try youngRuntime(.local) { $0.young.testSwitches.handshakeStackScan = scan }
    rt.spawn("mkY")
    rt.runOn(1)
    let p = rt.spawn("spinHolding")
    let vm = rt.vm
    let t = TestThread { _ = vm.runOneSlice(worker: 2) }
    #expect(eventually { vm.globalNow(8) == vm.image.nilObject })
    rt.vm.collectYoung(worker: 1)
    let f = rt.verifierFailures
    // Lost: the Process would send to a freed entry; it is terminated at
    // its next budget check instead.
    if f > 0 { rt.vm.terminate(p) } else { rt.vm.setGlobalNow(11, int(1)) }
    t.join()
    let r: Int64? = f == 0 ? rt.result(p) : nil
    rt.stop(verifyHeap: f == 0)
    return (f, r)
}

@Test func aRunningWorkersStackIsScannedAtH1() throws {
    let (f, r) = try stackOnly(true)
    #expect(f == 0)
    #expect(r == 42)
}

@Test func withoutTheHandshakeStackScanTheValueIsLost() throws {
    let (f, _) = try stackOnly(false)
    #expect(f > 0)
}

// MARK: - the epoch rule before eden reuse

/// A thread acting as worker 2 runs `slowPeek:` on Y (nursery 1): it takes
/// Y's body address, enters a blocking region and waits at the test's
/// gate. Worker 1 collects (Y is copied; worker 2 is acknowledged by proxy)
/// and then churns over its eden. The primitive then reads through its
/// address. With the rule the collection cannot finish while the primitive
/// holds the address (its epoch word is kept in the region): a helper opens
/// the gate once the collection is past its sweep, and the read comes
/// before the churn. Without it the collection finishes, the churn reuses
/// the eden, and only then is the gate opened. Answers (what the primitive
/// read, whether the collection finished while the address was held).
private func peekAcross(_ epoch: Bool) throws -> (Int64, Bool) {
    let hooks = YoungHooks()
    let rt = try youngRuntime(.local) { c in
        c.young.testSwitches.epochRule = epoch
        // A stop after the collection would wait for the blocking worker.
        c.young.verify = false
        hooks.install(&c.young.testSwitches)
    }
    let vm = rt.vm
    rt.spawn("mkY")
    rt.runOn(1)
    let p = rt.spawn("peek")
    vm.setPeekGate(true)
    let t = TestThread { _ = vm.runOneSlice(worker: 2) }
    #expect(eventually { vm.peekHeld })
    let swept = Flag()
    let finishedWhileHeld = Atomic<Bool>(false)
    var opener: TestThread? = nil
    if epoch {
        hooks.set(2) { k in if k == 1 { swept.set() } }
        opener = TestThread {
            while !swept.isSet { usleep(100) }
            // The collection is past its sweep and in the epoch rule; it
            // cannot finish while the primitive holds its address.
            usleep(20_000)
            if vm.youngLog.contains(where: { $0.nursery == 1 }) { finishedWhileHeld.store(true, ordering: .relaxed) }
            vm.setPeekGate(false)
        }
    }
    rt.vm.collectYoung(worker: 1)
    if !epoch && vm.peekHeld && vm.youngLog.contains(where: { $0.nursery == 1 }) {
        finishedWhileHeld.store(true, ordering: .relaxed)
    }
    rt.spawn("churn:", [int(20_000)])
    rt.runOn(1)                               // over the old eden
    if !epoch { vm.setPeekGate(false) }
    opener?.join()
    t.join()
    let r = rt.result(p)
    rt.stop()
    return (r, finishedWhileHeld.load(ordering: .relaxed))
}

@Test func edenIsReusedOnlyAfterEveryWorkersEpoch() throws {
    let (r, finished) = try peekAcross(true)
    #expect(r == 42)
    #expect(!finished)
}

@Test func withoutTheEpochRuleAPrimitiveReadsAReusedEden() throws {
    let (r, finished) = try peekAcross(false)
    #expect(finished)
    #expect(r != 42)
}

// MARK: - remembered holders carried across collections

/// N = 3. O is old; O x: Y (young, nursery 1) remembers O for nursery 1.
/// Collection 1 scans O, Y survives (age 1) and O must stay remembered:
/// collection 2 finds Y only through O.
private func carried(_ carry: Bool) throws -> (UInt64, Int64?) {
    let rt = try youngRuntime(.local, age: 3) { $0.young.testSwitches.carryHolders = carry }
    rt.spawn("mkO")
    rt.runOn(1)
    rt.vm.collect()                           // O old
    rt.spawn("mkY")
    rt.runOn(1)
    rt.spawn("linkOY")
    rt.runOn(1)
    rt.vm.setGlobal(8, rt.image.nilObject)
    let o = rt.global(9)
    #expect(!rt.young(o))
    rt.vm.collectYoung(worker: 1)
    let y = rt.slot(o, 0)
    #expect(rt.young(y) && rt.age(y) == 1)
    let f1 = rt.verifierFailures
    rt.vm.collectYoung(worker: 1)
    let f = rt.verifierFailures
    var r: Int64? = nil
    if f == 0 && f1 == 0 { r = rt.slot(rt.slot(o, 0), 0).smallIntegerValue }
    rt.stop(verifyHeap: f == 0)
    return (f, r)
}

@Test func aRememberedHolderIsCarriedAcrossLocalCollections() throws {
    let (f, r) = try carried(true)
    #expect(f == 0)
    #expect(r == 42)
}

@Test func withoutCarryingTheHolderTheSurvivorIsLost() throws {
    let (f, _) = try carried(false)
    #expect(f > 0)
}

// MARK: - offload

/// The policy: the main worker's (worker 0's) nursery is collected by the
/// young collector thread. Y in nursery 0 is held only by H, young in
/// nursery 2; after two flips (both halves) Y is still there and the young
/// verifier ran after each collection.
@Test func anOffloadedCollectionFindsACrossNurseryHolder() throws {
    let rt = try youngRuntime(.offload)
    rt.vm.startYoungCollectorOnly()
    rt.spawn("mkY", main: true)
    rt.runOn(0)
    rt.spawn("hold")
    rt.runOn(2)
    #expect(rt.header(rt.global(9)).nurseryIndex == 2)
    rt.vm.collectYoung(worker: 0)            // nursery 0's eden half goes to the collector thread
    rt.vm.collectYoung(worker: 0)            // and the other half
    #expect(rt.verifierFailures == 0)
    let yc = rt.vm.youngCounters
    #expect(yc.collectionsOffloaded == 2 && yc.offloadedInline == 0, "\(yc)")
    // The collector thread requests the verifier's stop after it is done.
    #expect(eventually { rt.vm.youngCounters.verifierRuns >= 2 })
    let p = rt.spawn("readH")
    rt.runOn(2)
    #expect(rt.result(p) == 42)
    rt.stop()
}

/// Offload. Y (nursery 0) is in the eden half the main worker hands over.
/// Before H0 (the hook, on the collector thread, once the test thread has
/// left as worker 0) worker 0 allocates H in its new half holding Y,
/// publishes H in global 9 and clears global 8 (that deletion is recorded,
/// then cleared by H0: a record made before H0 may name a freed entry). H
/// is not in Y, so the collector does not trace it: only the scan of the
/// new half's objects allocated before the owner's H1 acknowledgement keeps
/// Y (amendment 7a; the snoop of 7b is dropped, the model's finding 2).
private func newHalf(scan: Bool) throws -> UInt64 {
    let hooks = YoungHooks()
    let rt = try youngRuntime(.offload) { c in
        c.young.testSwitches.newHalfScan = scan
        hooks.install(&c.young.testSwitches)
    }
    let vm = rt.vm
    vm.startYoungCollectorOnly()
    rt.spawn("mkY", main: true)
    rt.runOn(0)
    rt.spawn("hold", main: true)
    // The collector thread acts as worker 0 once the test thread has
    // returned from the flip (its `leaveVM` writes worker 0's counters).
    let flipped = Flag()
    hooks.set(0) { k in
        guard k == 0 else { return }
        while !flipped.isSet { usleep(100) }
        #expect(!vm.isInside(worker: 0))
        #expect(vm.runOneSlice(worker: 0))
    }
    vm.flipYoung(worker: 0)
    flipped.set()
    #expect(vm.waitYoungDone(0))
    hooks.set(0, nil)
    vm.verifyYoung()
    let f = rt.verifierFailures
    rt.stop(verifyHeap: f == 0)
    return f
}

@Test func theOwnersNewHalfObjectsAreScannedAtT1() throws {
    #expect(try newHalf(scan: true) == 0)
}

@Test func withoutNewHalfScanTheValueIsLost() throws {
    #expect(try newHalf(scan: false) > 0)
}

// MARK: - deferred entry frees (amendments 10 and 17)

/// H (nursery 2) holds Y (nursery 1), so it is remembered for nursery 1,
/// and dies. Collecting nursery 2 finds H dead with a nonzero remembered
/// word: its free is deferred to the epoch. Meanwhile (hook point 2) H's
/// membership bit is re-armed, as another collection's fold does for a
/// holder it kept from a stale list, so the free waits for nursery 2's next
/// collection: H's entry is used, dead, and in no young log.
private func keptDeferredHolder(_ change: (inout VMConfig) -> Void = { _ in }) throws -> (Runtime, Oop, YoungHooks) {
    let hooks = YoungHooks()
    let rt = try youngRuntime(.local, marking: true) { c in
        hooks.install(&c.young.testSwitches)
        change(&c)
    }
    rt.spawn("mkY")
    rt.runOn(1)
    rt.spawn("hold")
    rt.runOn(2)
    let h = rt.global(9)
    #expect(rt.header(h).isYoung && rt.header(h).nurseryIndex == 2)
    #expect(rt.vm.rememberedWord(h) & 2 != 0)
    rt.vm.setGlobal(9, rt.image.nilObject)  // H (and Y) dead
    let vm = rt.vm
    hooks.set(2) { k in if k == 2 { vm.orRememberedWordNow(h, 2) } }
    rt.vm.collectYoung(worker: 2)
    hooks.set(2, nil)
    #expect(rt.vm.deferredEntries().contains(h) && rt.vm.isEntryUsed(h))
    return (rt, h, hooks)
}

/// Worker 2 allocates `n` Pairs kept in global 12. Answers whether one of
/// them took entry `e`.
private func keepOn2(_ rt: Runtime, _ n: Int, reusing e: Oop) -> Bool {
    rt.spawn("keep:", [int(Int64(n))])
    rt.drain(on: 2)
    return rt.vm.inspect { om in
        var node = om.load(rt.image.globals, 11)
        while node != rt.image.nilObject {
            if node == e { return true }
            node = om.load(node, 1)
        }
        return false
    }
}

private func sumKeep(_ rt: Runtime) -> Int64 {
    let p = rt.spawn("sumKeep")
    rt.drain(on: 2)
    return rt.result(p)
}

/// The initial mark comes while H's free is still deferred. Nursery 2's
/// next collection frees the entry during marking and worker 2 reuses it
/// for a live Pair. A snapshot that counted H's entry would report the
/// Pair as a missed snapshot entry at the final mark and the sweep would
/// free it under its holder.
private func deferredAcrossACycle(own: Bool) throws -> (missed: UInt64, failures: UInt64, sum: Int64?) {
    let (rt, h, hooks) = try keptDeferredHolder { $0.young.testSwitches.deferredOwnership = own }
    defer { withExtendedLifetime(hooks) {} }  // the collector's hook context
    rt.vm.startYoungCycle()
    #expect(rt.phase == .marking)
    #expect(rt.vm.isSnapshotEntry(h) == !own)
    #expect(rt.vm.youngCounters.snapshotExclusions >= 1)
    rt.vm.collectYoung(worker: 2)            // the deferred free
    #expect(!rt.vm.isEntryUsed(h))
    #expect(keepOn2(rt, 200, reusing: h))
    _ = rt.vm.markStep(10_000_000)
    rt.vm.finalMark()
    let missed = rt.marking.missed
    var sum: Int64? = nil
    if missed == 0 {
        rt.vm.sweep()
        rt.vm.collectYoung(worker: 2)
        rt.vm.verifyYoung()
        sum = sumKeep(rt)
    }
    let f = rt.verifierFailures
    rt.stop(verifyHeap: missed == 0 && f == 0)
    return (missed, f, sum)
}

@Test func aDeferredEntryFreeIsNotASnapshotEntry() throws {
    let r = try deferredAcrossACycle(own: true)
    #expect(r.missed == 0 && r.failures == 0)
    #expect((r.sum ?? 0) == 20_100)
}

@Test func withoutDeferredOwnershipTheSnapshotHoldsAReusedEntry() throws {
    let r = try deferredAcrossACycle(own: false)
    #expect(r.missed > 0 || r.failures > 0)
}

/// A full collection while H's free is deferred. Its promote-all scavenge
/// takes every remembered list, so nothing names H; the pause releases the
/// deferred free (H's nursery's own free, at the pause instead of its next
/// collection) and takes it from the nursery's list: freed once. Freeing it
/// in the pause and leaving it in the list let nursery 2's next collection
/// free it a second time after worker 2 reused it (the experiment's bug).
private func deferredAcrossAFullCollection(own: Bool) throws -> (failures: UInt64, sum: Int64?, listed: Bool) {
    let (rt, h, hooks) = try keptDeferredHolder { $0.young.testSwitches.deferredOwnership = own }
    defer { withExtendedLifetime(hooks) {} }  // the collector's hook context
    let released0 = rt.vm.nurseryCounters.deferredReleased
    rt.vm.collect()
    #expect(rt.vm.nurseryCounters.deferredReleased == released0 + 1)
    #expect(!rt.vm.isEntryUsed(h))
    let listed = rt.vm.deferredEntries().contains(h)
    // Module 1's sweep discarded the stashes: whether worker 2 reuses the
    // entry now depends on the pool. Either way a second free is caught: a
    // reused entry freed under its Pair, or a free entry put in a second
    // list (the free-list verifier: one owner per entry).
    _ = keepOn2(rt, 200, reusing: h)
    rt.vm.collectYoung(worker: 2)            // the nursery's free, if it kept the entry
    rt.vm.verifyYoung()
    let lists = rt.vm.inspect { $0.verifyFreeLists() }
    if !lists.isEmpty, ProcessInfo.processInfo.environment["KAJO_SHOW_REPORTS"] != nil { print("REPORT: \(lists[0])") }
    let f = rt.verifierFailures + UInt64(lists.count)
    let sum: Int64? = f == 0 ? sumKeep(rt) : nil
    rt.stop(verifyHeap: f == 0 && (sum ?? 0) == 20_100)
    return (f, sum, listed)
}

@Test func aFullCollectionLeavesADeferredEntryFreeToItsNursery() throws {
    let r = try deferredAcrossAFullCollection(own: true)
    #expect(!r.listed)
    #expect(r.failures == 0)
    #expect((r.sum ?? 0) == 20_100)
}

@Test func withoutDeferredOwnershipAFullCollectionFreesAnEntryTwice() throws {
    let r = try deferredAcrossAFullCollection(own: false)
    #expect(r.listed)
    #expect(r.failures > 0 || (r.sum ?? 0) != 20_100)
}

// MARK: - the array copy's store ordering (the model's finding 1)

/// G is old and remembered for nursery 1 (it named a young object of
/// nursery 1 once) but names nothing young. A thread acting as worker 2
/// holds X (young, nursery 1) on its stack through the collection's H0
/// and H1, then copies X into G with primitive 38. The array copy's
/// barrier finds G's bit set and remembers nothing; the collector clears
/// the bit with its `fetch_and` and reads G's slots. With seq_cst stores
/// either the collector's read sees X (G is kept) or the barrier's load
/// sees the cleared bit (G is remembered again). The copy window (a hook
/// on worker 2) holds the store where a store buffer would hold a relaxed
/// one: after the barrier's load (broken variant) or after the store and
/// the load (seq_cst), until the collector has scanned its holders
/// (hook point 3). X survives this collection on worker 2's stack either
/// way; without the ordering G is no longer remembered while it names X,
/// which the remembered-set check at the verifier's stop reports, and the
/// next collection frees X under G. Answers (failures, G at: 2's x).
private func copyAcrossTheScan(ordered: Bool) throws -> (UInt64, Int64?) {
    let hooks = YoungHooks()
    let rt = try youngRuntime(.local) { c in
        c.young.testSwitches.arrayCopyOrdering = ordered
        hooks.install(&c.young.testSwitches)
    }
    let vm = rt.vm
    rt.spawn("mkG")
    rt.runOn(1)
    vm.collect()                              // G old
    rt.spawn("armG")
    rt.runOn(1)                               // G remembered for nursery 1, names nothing young
    let g = rt.global(13)
    #expect(!rt.young(g) && vm.rememberedWord(g) & 2 != 0)
    rt.spawn("mkX")
    rt.runOn(1)                               // X young in nursery 1
    let copier = rt.spawn("copier")
    let inWindow = Flag(), scanned = Flag()
    let window = CopyWindow { if !inWindow.isSet { inWindow.set(); while !scanned.isSet { usleep(100) } } }
    vm.setCopyWindow(copyWindowThunk, context: window.context)
    hooks.set(1) { k in
        guard k == 1 else { return }
        vm.setGlobalNow(11, int(1))           // worker 2 goes on to the copy
        while !inWindow.isSet { usleep(100) }
    }
    hooks.set(3) { k in if k == 1 { scanned.set() } }
    let t2 = TestThread { _ = vm.runOneSlice(worker: 2) }
    #expect(eventually { vm.globalNow(10) == vm.image.nilObject })  // X taken
    vm.collectYoung(worker: 1)
    hooks.set(1, nil)
    hooks.set(3, nil)
    let f1 = rt.verifierFailures
    vm.setGlobalNow(12, int(1))
    t2.join()
    vm.setCopyWindow(nil, context: nil)
    withExtendedLifetime(window) {}
    #expect(rt.result(copier) == 0)
    var r: Int64? = nil
    if f1 == 0 {
        vm.collectYoung(worker: 1)            // X is found through G only
        if rt.verifierFailures == 0 {
            let p = rt.spawn("readG")
            rt.runOn(1)
            r = rt.result(p)
        }
    }
    let f = rt.verifierFailures
    rt.stop(verifyHeap: f == 0)
    return (f, r)
}

/// A C hook with a Swift action (the copy window, `VM.setCopyWindow`).
final class CopyWindow: @unchecked Sendable {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }
}

let copyWindowThunk: @convention(c) (UnsafeMutableRawPointer?, Int) -> Void = { ctx, _ in
    guard let ctx else { return }
    Unmanaged<CopyWindow>.fromOpaque(ctx).takeUnretainedValue().action()
}

@Test func theArrayCopyStoreIsSeenByTheCollector() throws {
    let (f, r) = try copyAcrossTheScan(ordered: true)
    #expect(f == 0)
    #expect(r == 42)
}

@Test func withRelaxedArrayCopyStoresTheHolderIsLost() throws {
    let (f, _) = try copyAcrossTheScan(ordered: false)
    #expect(f > 0)
}

// MARK: - the wake from a quiescent wait (the model's finding 3)

/// A participant that waited (quiescent) wakes and stores the epoch.
/// Between its load of the global epoch and its store (the enter window
/// hook, where a later relaxed load of an offset could already have been
/// satisfied: the store-buffering shape), a collector's epoch check must
/// not pass: the wake stores 0 first, as `enterVM` does. Without the 0 the
/// word still reads quiescent there, and a collection that bumped the
/// epoch would reuse an eden under the offset. Answers the smallest
/// participant word the hook saw and the epoch before.
private func wakeWindow(zero: Bool) throws -> (seen: UInt64, epoch: UInt64) {
    let rt = try youngRuntime(.local) { $0.young.testSwitches.quiescentWakeZero = zero }
    let vm = rt.vm
    let seen = Atomic<UInt64>(0)
    let probe = EpochProbe { seen.store(vm.minimumEpoch, ordering: .relaxed) }
    vm.enter(worker: 2)
    let e = vm.globalEpoch
    vm.setEnterWindow(epochProbeThunk, context: probe.context)
    vm.quiesceAndWake(worker: 2)
    vm.setEnterWindow(nil, context: nil)
    vm.leave(worker: 2)
    withExtendedLifetime(probe) {}
    rt.stop()
    return (seen.load(ordering: .relaxed), e)
}

final class EpochProbe: @unchecked Sendable {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }
}

let epochProbeThunk: @convention(c) (UnsafeMutableRawPointer?, Int) -> Void = { ctx, _ in
    guard let ctx else { return }
    Unmanaged<EpochProbe>.fromOpaque(ctx).takeUnretainedValue().action()
}

@Test func aQuiescentWakeStoresEpochZeroFirst() throws {
    let (seen, e) = try wakeWindow(zero: true)
    // A collection whose epoch is e waits while any word is at most e.
    #expect(seen == 0 && seen <= e)
}

@Test func withoutTheZeroAQuiescentWakeLetsTheEpochPass() throws {
    let (seen, e) = try wakeWindow(zero: false)
    #expect(seen == quiescentEpoch && seen > e)
}

// MARK: - the initial mark without a scavenge (Part 3)

/// Module 5's lost object under the young-root scan: H and O are old, Y is
/// young (nursery 1) and the only path to O. The initial-mark pause does
/// not scavenge; with the young-root scan Y's slots are greyed and O is
/// marked; without it the final mark's verifier reports O reachable and
/// unmarked.
private func youngRootAtSnapshot(scan: Bool) throws -> UInt64 {
    let rt = try youngRuntime(.local, src: markingSrc, marking: true) { $0.young.testSwitches.youngRoots = scan }
    rt.run("mkEmptyH")
    rt.run("mkO")
    rt.vm.collect()                           // H, O old
    rt.run("mkY")                             // Y young -> O; O reachable only through Y
    #expect(rt.young(rt.global(9)) && !rt.young(rt.slot(rt.global(9), 0)))
    rt.vm.startYoungCycle()
    #expect(rt.phase == .marking)
    #expect(rt.vm.youngCounters.initialMarks == (scan ? 1 : 0))
    _ = rt.vm.markStep(10_000_000)
    rt.vm.finalMark()
    let missed = rt.marking.missed
    if missed == 0 {
        rt.vm.sweep()
        #expect(rt.runInt("sumY") == 100 * 101 / 2)
    }
    rt.stop(verifyHeap: missed == 0)
    return missed
}

@Test func theYoungRootScanGreysWhatYoungObjectsName() throws {
    #expect(try youngRootAtSnapshot(scan: true) == 0)
}

@Test func withoutTheYoungRootScanTheVerifierReportsTheLoss() throws {
    #expect(try youngRootAtSnapshot(scan: false) > 0)
}

// MARK: - idle

/// A parked VM wakes neither its young collector nor its marker: both
/// wait untimed (the power experiment: a timed wait is the VM's whole idle
/// cost). Zero is zero whatever the load, so a window can measure it.
@Test func aParkedVMDoesNotWakeItsYoungCollector() throws {
    let rt = try Runtime(youngSrc, background: 2, configure: { $0.young.mode = .offload })
    #expect(rt.vm.youngMode == .offload)
    #expect(eventually { rt.vm.youngCollectorQoS != QOS_CLASS_UNSPECIFIED })
    usleep(100_000)
    let cpu0 = rt.vm.youngCollectorCPUNanoseconds, w0 = rt.vm.youngCounters.collectorWakeups
    let m0 = rt.vm.markerCPUNanoseconds, mw0 = rt.marking.markerWaits
    usleep(1_000_000)
    let cpu = rt.vm.youngCollectorCPUNanoseconds &- cpu0, wakes = rt.vm.youngCounters.collectorWakeups &- w0
    let mcpu = rt.vm.markerCPUNanoseconds &- m0, mwakes = rt.marking.markerWaits &- mw0
    print("idle young collector: \(cpu) ns of CPU and \(wakes) wakeups in 1 s parked; marker \(mcpu) ns, \(mwakes) wakeups; "
          + "collector QoS \(rt.vm.youngCollectorQoS.rawValue)")
    #expect(cpu == 0 && wakes == 0)
    #expect(mcpu < 1_000_000 && mwakes == 0)
    #expect(rt.vm.youngCollectorQoS == QOS_CLASS_USER_INITIATED)
    rt.stop()
}

/// Work after idling completes: the main worker's offloaded collections
/// wake the idle collector thread (every transition its untimed wait
/// depends on signals under the safepoint mutex: a queued collection,
/// shutdown).
@Test func offloadedCollectionsCompleteAfterIdling() throws {
    let rt = try Runtime(youngSrc, background: 1, configure: { c in
        c.young.mode = .offload
        c.nursery.bytes = 256 << 10
    })
    usleep(300_000)
    for _ in 0..<3 {
        let p = rt.spawn("churn:", [int(30_000)], main: true)
        while rt.vm.liveProcessCount > 0 { _ = rt.vm.runMain(budgetNs: 5_000_000) }
        #expect(rt.result(p) == 30_000)
        usleep(200_000)
    }
    let yc = rt.vm.youngCounters
    #expect(yc.collectionsOffloaded >= 3 && yc.offloadedInline == 0, "\(yc)")
    #expect(rt.vm.youngWorkerCounters(0).flips >= 3)
    rt.noFailures()
    rt.stop()
}

// MARK: - a stop and an opener waiting for it

/// Worker 1 (the test thread) collects; during it (hook point 1) a host
/// thread asks for a stop (it waits for the collection: `stwWanted`) and a
/// thread acting as worker 2 runs a Process whose `scavenge` opens a
/// collection, which waits while the stop is wanted. When worker 1's
/// collection ends the stop is requested: worker 2, blocked inside the VM,
/// must be woken to park, or the stop waits for it forever. The suite hung
/// that way once (a random program, the marker's final mark against two
/// openers): the stop's request now broadcasts. The 50 ms sleep only makes
/// the interleaving likely; the assertions do not depend on it.
@Test func aStopWakesAnOpenerThatWaitsForIt() throws {
    let hooks = YoungHooks()
    let rt = try youngRuntime(.local, src: youngSrc + """
    method UndefinedObject scavengeNow temps=0
      push_nil
      send scavenge 0
      pop
      push_int 7
      return_top
    end

    """) { c in
        hooks.install(&c.young.testSwitches)
        c.young.verify = false  // no stop of worker 1's own after its collection
    }
    let vm = rt.vm
    let p = rt.spawn("scavengeNow")
    let stopped = Flag(), ran = Flag()
    var r: TestThread? = nil, b: TestThread? = nil
    hooks.set(1) { k in
        guard k == 1 else { return }
        r = TestThread { vm.withWorldStopped {}; stopped.set() }
        #expect(eventually { vm.stopsWanted == 1 })
        b = TestThread { _ = vm.runOneSlice(worker: 2); ran.set() }
        usleep(50_000)
    }
    vm.collectYoung(worker: 1)
    hooks.set(1, nil)
    #expect(eventually(30) { stopped.isSet && ran.isSet })
    r?.join()
    b?.join()
    #expect(rt.result(p) == 7)
    #expect(rt.verifierFailures == 0)
    rt.stop()
}
