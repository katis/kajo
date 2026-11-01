// Headless tests of concurrent marking and lazy sweeping (SPEC.md "SATB
// barrier", "Phases", "Triggers and fallback", "Verifier", "Test-only
// protocol switches"). Every runtime has every verifier on: the mark sets
// are compared with a from-scratch traversal at each final mark, and the
// inherited scavenge verifier checks after each scavenge that nothing names
// a freed entry. The manual tests drive the marker from the test thread so
// the interleaving is exact. Run also under ThreadSanitizer.

import Darwin
import Kasm
import Synchronization
import Testing
@testable import VMC

/// Pair, list helpers, globals. Globals used: 7 holder H, 8 and 9 scratch.
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
; nil list: n -> n Pairs, x = 1..n, linked through y. t0 = n, t1 = i, t2 = head
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
; nil sumList: l. t0 = l, t1 = sum
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
; global 7 := H, a Pair whose x is a 100-element list O
method UndefinedObject mkH temps=0
  push_nil
  push_int 7
  push_lit @Pair
  send basicNew 0
  push_nil
  push_int 100
  send list: 1
  push_nil
  send x:y: 2
  send g:put: 2
  return_top
end
; global 7 := H, a Pair with x nil
method UndefinedObject mkEmptyH temps=0
  push_nil
  push_int 7
  push_lit @Pair
  send basicNew 0
  push_nil
  push_nil
  send x:y: 2
  send g:put: 2
  return_top
end
; Z := Array new: 1. Z at: 1 put: H x. global 9 := Z. H x: nil y: nil.
; Afterwards O is reachable only through the young Z.
method UndefinedObject moveOut temps=1
  push_lit @Array
  push_int 1
  send new: 1
  store_temp 0
  push_temp 0
  push_int 1
  push_nil
  push_int 7
  send g: 1
  send x 0
  send at:put: 2
  pop
  push_nil
  push_int 9
  push_temp 0
  send g:put: 2
  pop
  push_nil
  push_int 7
  send g: 1
  push_nil
  push_nil
  send x:y: 2
  return_top
end
method UndefinedObject sumZ temps=0
  push_nil
  push_nil
  push_int 9
  send g: 1
  push_int 1
  send at: 1
  send sumList: 1
  return_top
end
; global 8 := O, a 100-element list
method UndefinedObject mkO temps=0
  push_nil
  push_int 8
  push_nil
  push_int 100
  send list: 1
  send g:put: 2
  return_top
end
; global 9 := Y, a Pair with x O. global 8 := nil: O is reachable only through Y.
method UndefinedObject mkY temps=0
  push_nil
  push_int 9
  push_lit @Pair
  send basicNew 0
  push_nil
  push_int 8
  send g: 1
  push_nil
  send x:y: 2
  send g:put: 2
  pop
  push_nil
  push_int 8
  push_nil
  send g:put: 2
  return_top
end
method UndefinedObject sumY temps=0
  push_nil
  push_nil
  push_int 9
  send g: 1
  send x 0
  send sumList: 1
  return_top
end
; H x: (Y x) y: nil (over nil: no SATB record), then global 9 := nil (Y dies)
method UndefinedObject copyToHAndDropY temps=0
  push_nil
  push_int 7
  send g: 1
  push_nil
  push_int 9
  send g: 1
  send x 0
  push_nil
  send x:y: 2
  pop
  push_nil
  push_int 9
  push_nil
  send g:put: 2
  return_top
end
method UndefinedObject sumH temps=0
  push_nil
  push_nil
  push_int 7
  send g: 1
  send x 0
  send sumList: 1
  return_top
end
; global 8 := Array new: 10; then n times: slot (i \\\\ 10) + 1 := a fresh
; 2000-Pair list. Answers the sum over the 10 lists left. t0 = n, t1 = i, t2 = s, t3 = k
method UndefinedObject churnLists: temps=3
  push_nil
  push_int 8
  push_lit @Array
  push_int 10
  send new: 1
  send g:put: 2
  pop
  push_int 0
  store_temp 1
loop:
  push_temp 1
  push_temp 0
  lt
  jump_if_false sum
  push_nil
  push_int 8
  send g: 1
  push_temp 1
  push_int 10
  send \\\\ 1
  push_int 1
  add
  push_nil
  push_lit 2000
  send list: 1
  send at:put: 2
  pop
  push_temp 1
  push_int 1
  add
  store_temp 1
  jump loop
sum:
  push_int 0
  store_temp 2
  push_int 1
  store_temp 3
sloop:
  push_temp 3
  push_int 10
  le
  jump_if_false done
  push_temp 2
  push_nil
  push_nil
  push_int 8
  send g: 1
  push_temp 3
  send at: 1
  send sumList: 1
  add
  store_temp 2
  push_temp 3
  push_int 1
  add
  store_temp 3
  jump sloop
done:
  push_temp 2
  return_top
end
; Remembered dead holder: global 9 := Array new: 4 (old after a scavenge);
; later `storeYoungThenDrop` stores a young Pair into it and drops it.
method UndefinedObject mkHolder temps=0
  push_nil
  push_int 9
  push_lit @Array
  push_int 4
  send new: 1
  send g:put: 2
  return_top
end
method UndefinedObject storeYoungThenDrop temps=0
  push_nil
  push_int 9
  send g: 1
  push_int 1
  push_lit @Pair
  send basicNew 0
  push_int 1
  push_int 2
  send x:y: 2
  send at:put: 2
  pop
  push_nil
  push_int 9
  push_nil
  send g:put: 2
  return_top
end

"""

private func manualConfig(_ change: (inout CMConfig) -> Void = { _ in }) -> CMConfig {
    var c = CMConfig()
    c.manual = true
    change(&c)
    return c
}

/// A runtime stepped from the test thread, with this thread as the marker.
private func manualRuntime(heap: Int = 64 << 20, _ change: (inout CMConfig) -> Void = { _ in }) throws -> (Runtime, MarkerRef) {
    let rt = try runtime(src, background: 1, heap: heap, start: false, config: manualConfig(change))
    return (rt, makeMarker(rt.vm, id: 0))
}

private func run(_ rt: Runtime, _ sel: String) -> Oop {
    let p = spawn(rt.vm, rt.vm.pointee.nilObj, rt.symbol(sel), rt.vm.pointee.nilObj)
    #expect(runOneSlice(rt.vm, rt.workers[1]))
    return p
}

private func runInt(_ rt: Runtime, _ sel: String, _ arg: Int64? = nil) -> Int64 {
    let vm = rt.vm
    let p = spawn(vm, vm.pointee.nilObj, rt.symbol(sel), arg.map(mkInt) ?? vm.pointee.nilObj)
    while liveProcessCount(vm) > 0 { _ = runOneSlice(vm, rt.workers[1]) }
    return result(rt, p)
}

private func failures(_ rt: Runtime) -> UInt64 { rt.vm.metric(.verifyFailures) }

/// Finish the current cycle from the test thread: mark everything, final
/// mark, sweep, and a scavenge that applies the sweep.
private func finishCycle(_ rt: Runtime, _ m: MarkerRef) {
    let vm = rt.vm
    cmMark(vm, m, 10_000_000)
    cmFinal(vm)
    #expect(cmPhaseNow(vm) == CMPhase.sweeping)
    cmSweep(vm, m)
    #expect(cmPhaseNow(vm) == CMPhase.swept)
    hostCollect(vm, full: false)
    #expect(cmPhaseNow(vm) == CMPhase.idle)
}

// MARK: - SATB

/// O (a 100-element list) is reachable at the snapshot only through the old
/// H. After the initial mark the mutator moves O into a young Array (which
/// the marker never scans) and clears H's slot. Only the SATB record of the
/// overwritten value keeps O.
private func satbScenario(satb: Bool) throws -> (Runtime, UInt64) {
    let (rt, m) = try manualRuntime { $0.satb = satb }
    let vm = rt.vm
    _ = run(rt, "mkH")
    hostCollect(vm, full: false) // H and O old
    cmStart(vm)
    #expect(cmPhaseNow(vm) == CMPhase.marking)
    _ = run(rt, "moveOut")
    cmMark(vm, m, 10_000_000)
    cmFinal(vm)
    let missed = vm.metric(.cmMissed)
    return (rt, missed)
}

@Test func satbKeepsAValueOverwrittenDuringMarking() throws {
    let (rt, missed) = try satbScenario(satb: true)
    let vm = rt.vm
    #expect(missed == 0)
    #expect(rt.workers[1].pointee.satbPushed >= 1)
    let m = vm.pointee.cm.markers[0]
    cmSweep(vm, m)
    hostCollect(vm, full: false)
    #expect(runInt(rt, "sumZ") == 5050)
    // Another full cycle and a stop-the-world collection agree.
    cmStart(vm)
    finishCycle(rt, m)
    #expect(runInt(rt, "sumZ") == 5050)
    #expect(failures(rt) == 0)
    rt.stop()
}

@Test func withoutSATBTheVerifierReportsTheMissedObject() throws {
    let (rt, missed) = try satbScenario(satb: false)
    #expect(missed > 0)
    #expect(failures(rt) > 0)
    rt.stop()
}

// MARK: - promotion during marking

@Test func objectsPromotedDuringMarkingSurviveTheCycle() throws {
    let (rt, m) = try manualRuntime()
    let vm = rt.vm
    cmStart(vm)
    // Allocated and promoted while marking: never snapshot entries.
    _ = run(rt, "mkO")
    hostCollect(vm, full: false)
    #expect(!vm.pointee.om.isYoung(global(rt, 8)))
    #expect(!vm.pointee.cm.inSnap(global(rt, 8)))
    finishCycle(rt, m)
    cmStart(vm)
    finishCycle(rt, m)
    let s = spawn(vm, vm.pointee.nilObj, rt.symbol("sumList:"), global(rt, 8))
    #expect(runOneSlice(vm, rt.workers[1]))
    #expect(result(rt, s) == 5050)
    #expect(failures(rt) == 0)
    rt.stop()
}

/// DESIGN.md's literal protocol: the initial mark does not scavenge, so the
/// young Y exists at the snapshot and holds the only reference to the old
/// O. Y is promoted during marking; DESIGN.md's rule pushes it grey.
private func literalPromotion(grey: Bool) throws -> UInt64 {
    let (rt, m) = try manualRuntime { $0.literal = true; $0.literalGrey = grey }
    let vm = rt.vm
    _ = run(rt, "mkO")
    hostCollect(vm, full: false) // O old
    _ = run(rt, "mkY")            // Y young -> O
    cmStart(vm, scavenge: false)
    cmMark(vm, m, 10_000_000)     // nothing reaches O: Y is not a snapshot entry
    hostCollect(vm, full: false)  // Y promoted while marking
    cmMark(vm, m, 10_000_000)
    cmFinal(vm)
    let missed = vm.metric(.cmMissed)
    if missed == 0 {
        cmSweep(vm, m)
        hostCollect(vm, full: false)
        #expect(runInt(rt, "sumY") == 5050)
    }
    rt.stop()
    return missed
}

@Test func literalProtocolNeedsItsGreyPromotionRule() throws {
    #expect(try literalPromotion(grey: true) == 0)
    #expect(try literalPromotion(grey: false) > 0)
}

/// The case DESIGN.md's protocol loses: Y (young at the snapshot) holds the
/// only reference to O; the mutator copies O into the already scanned H
/// over nil (no SATB record) and drops Y, which dies unpromoted. With the
/// initial mark taken after a scavenge (this experiment's protocol) Y is a
/// snapshot entry, so O is marked through it.
private func youngAtSnapshot(literal: Bool) throws -> (UInt64, Int64?) {
    let (rt, m) = try manualRuntime { $0.literal = literal }
    let vm = rt.vm
    _ = run(rt, "mkEmptyH")
    _ = run(rt, "mkO")
    hostCollect(vm, full: false) // H, O old
    _ = run(rt, "mkY")            // Y young -> O
    cmStart(vm, scavenge: !literal)
    cmMark(vm, m, 10_000_000)     // H scanned (black)
    _ = run(rt, "copyToHAndDropY")
    hostCollect(vm, full: false)  // Y dies (literal) or was already old
    cmMark(vm, m, 10_000_000)
    cmFinal(vm)
    let missed = vm.metric(.cmMissed)
    var sum: Int64? = nil
    if missed == 0 {
        cmSweep(vm, m)
        hostCollect(vm, full: false)
        sum = runInt(rt, "sumH")
    }
    rt.stop()
    return (missed, sum)
}

@Test func designLiteralProtocolLosesATargetOfADeadYoungObject() throws {
    let (missed, _) = try youngAtSnapshot(literal: true)
    #expect(missed > 0)
}

@Test func snapshotAfterAScavengeKeepsTheTargetOfAYoungObject() throws {
    let (missed, sum) = try youngAtSnapshot(literal: false)
    #expect(missed == 0)
    #expect(sum == 5050)
}

// MARK: - final mark and sweep

@Test func filteringRemovesADeadHolderFromTheRememberedSet() throws {
    let (rt, m) = try manualRuntime()
    let vm = rt.vm
    _ = run(rt, "mkHolder")
    hostCollect(vm, full: false)
    let holder = global(rt, 9)
    // Drop the holder before the snapshot, then make it remembered during
    // marking through a VM-internal store: it is a snapshot entry, unmarked.
    vm.pointee.globals[8] = vm.pointee.nilObj
    cmStart(vm)
    let w = rt.workers.last!
    enterVM(vm, w)
    let young = alloc(vm, w, try rt.img.classIndex("Pair"), 2, false)
    store(vm, w, holder, 0, young)
    leaveVM(vm, w)
    #expect(w.pointee.remBuf.count == 1)
    cmMark(vm, m, 10_000_000)
    cmFinal(vm)
    #expect(w.pointee.remBuf.count == 0)
    #expect(vm.pointee.space.rem[Int(holder >> 4)].load(ordering: .relaxed) == 0)
    cmSweep(vm, m)
    hostCollect(vm, full: false) // would scan the freed holder if it were still remembered
    #expect(failures(rt) == 0)
    rt.stop()
}

@Test func sweepFreesEntriesAndBlocksAndTheyAreReused() throws {
    let (rt, m) = try manualRuntime()
    let vm = rt.vm
    #expect(runInt(rt, "churnLists:", 40) == 10 * 2000 * 2001 / 2)
    hostCollect(vm, full: false)
    let before = vm.pointee.heap.blocksInUse()
    vm.pointee.globals[7] = vm.pointee.nilObj // drop all ten lists
    cmStart(vm)
    finishCycle(rt, m)
    let after = vm.pointee.heap.blocksInUse()
    #expect(after * 2 < before)
    let c = vm.pointee.cm.log.pointee.records.last!
    #expect(c.freedEntries >= 10 * 2000 && c.freedBlocks > 0)
    let hwm = chunkHwmNow(vm)
    #expect(runInt(rt, "churnLists:", 40) == 10 * 2000 * 2001 / 2)
    hostCollect(vm, full: false)
    #expect(chunkHwmNow(vm) <= hwm + 2) // freed entries were reused
    #expect(failures(rt) == 0)
    rt.stop()
}

// MARK: - fallback

@Test func oldSpaceFillingDuringACycleFallsBackToAFullCollection() throws {
    // 4 MiB old space, no marker progress (manual, never stepped): the cycle
    // cannot finish, old space fills, and a stop-the-world collection runs.
    let (rt, _) = try manualRuntime(heap: 4 << 20) { $0.threshold = 0.3 }
    let vm = rt.vm
    #expect(runInt(rt, "churnLists:", 200) == 10 * 2000 * 2001 / 2)
    #expect(vm.metric(.cmCycles) >= 1)
    #expect(vm.metric(.cmFallbacks) >= 1)
    #expect(vm.metric(.cmAborts) >= 1)
    #expect(failures(rt) == 0)
    rt.stop()
}

// MARK: - threads

/// The oldheap kernel at 4 MiB on 4 workers with a marker thread: rewiring
/// under the SATB barrier, promotion during marking, sweeps and applies
/// between scavenges, with a cycle at every scavenge (force mode). Its
/// checksum must equal the stop-the-world run's.
@Test func oldheapUnderConcurrentMarkingMatchesStopTheWorld() throws {
    func once(_ cfg: CMConfig) throws -> (Int64, VMRef) {
        let img = try Image.fromSources(try kernelSources("oldheap4"), heapSize: 72 << 20, nurseryBytes: 1 << 20)
        let rt = Runtime(img, background: 4, pollEvery: 256, start: false, verify: false, config: cfg)
        rt.start()
        let sel = rt.symbol("kernel:")
        var ps: [Oop] = []
        for i in 0..<4 { ps.append(spawn(rt.vm, rt.vm.pointee.nilObj, sel, mkInt(Int64(i * 256 + 4)))) }
        waitAllTerminated(rt.vm)
        rt.stop()
        return (ps.map { result(rt, $0) }.reduce(0, &+), rt.vm)
    }
    var stw = CMConfig()
    stw.concurrent = false
    var cm = CMConfig()
    cm.force = true
    cm.threshold = 0
    cm.verify = true
    let (a, _) = try once(stw)
    let (b, vm) = try once(cm)
    #expect(a == b)
    #expect(vm.metric(.cmCycles) >= 3)
    #expect(vm.metric(.cmVerifyRuns) >= 2)
    #expect(vm.metric(.cmMissed) == 0)
    #expect(vm.metric(.verifyFailures) == 0)
    var two = cm
    two.markers = 2
    let (c, vm2) = try once(two)
    #expect(a == c)
    #expect(vm2.metric(.cmMissed) == 0)
}
