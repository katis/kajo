// Headless tests of concurrent relocation (SPEC.md "Part 2"). Each rule has
// a test that shows what happens without it, through a test-only switch.
// Every runtime has every verifier on, including the relocation verifier at
// every pause. Manual runtimes drive marking, relocation and freeing from
// the test thread; threaded ones run the oldheap and fragment kernels with
// every live block relocated in every cycle and compare checksums with
// stop-the-world. Run also under ThreadSanitizer.

import Darwin
import Dispatch
import Kasm
import Synchronization
import Testing
@testable import VMR

private let src = """
class Pair Object 2
method Pair x temps=0
  push_ivar 0
  return_top
end
method Pair x:y: temps=0
  push_temp 0
  store_ivar 0
  push_temp 1
  store_ivar 1
  return_self
end
method UndefinedObject g:put: temps=0
  push_nil
  push_temp 0
  push_temp 1
  send globalAt:put: 2
  return_top
end
;  global 7 := an Array of n fresh Pairs (x = 1..n); global 8 := an Array of
; every 20th of them. t0 = n, t1 = i, t2 = all, t3 = keep, t4 = p
method UndefinedObject mkSparse: temps=4
  push_lit @Array
  push_temp 0
  push_int 20
  send // 1
  send new: 1
  store_temp 3
  push_lit @Array
  push_temp 0
  send new: 1
  store_temp 2
  push_int 1
  store_temp 1
loop:
  push_temp 1
  push_temp 0
  le
  jump_if_false done
  push_lit @Pair
  send basicNew 0
  push_temp 1
  push_nil
  send x:y: 2
  store_temp 4
  push_temp 2
  push_temp 1
  push_temp 4
  send at:put: 2
  pop
  push_temp 1
  push_int 20
  send \\\\ 1
  push_int 0
  eq
  jump_if_false next
  push_temp 3
  push_temp 1
  push_int 20
  send // 1
  push_temp 4
  send at:put: 2
  pop
next:
  push_temp 1
  push_int 1
  add
  store_temp 1
  jump loop
done:
  push_nil
  push_int 7
  push_temp 2
  send g:put: 2
  pop
  push_nil
  push_int 8
  push_temp 3
  send g:put: 2
  return_top
end
; Hold (global 8) at: 1 in a temp and spin forever (frame-pin test).
method UndefinedObject holdFirst temps=1
  push_nil
  push_int 8
  send globalAt: 1
  push_int 1
  send at: 1
  store_temp 0
loop:
  push_temp 0
  pop
  jump loop
end
"""

private func manualRelocRuntime(_ change: (inout CMConfig) -> Void = { _ in }) throws -> (Runtime, MarkerRef) {
    var c = CMConfig()
    c.manual = true
    c.manualReloc = true
    c.relocThreshold = 50
    change(&c)
    let rt = try runtime(src, background: 1, start: false, config: c)
    return (rt, makeMarker(rt.vm, id: 0))
}

private func runAll(_ rt: Runtime, _ sel: String, _ arg: Int64? = nil) {
    let vm = rt.vm
    spawn(vm, vm.pointee.nilObj, rt.symbol(sel), arg.map(mkInt) ?? vm.pointee.nilObj)
    while liveProcessCount(vm) > 0 { _ = runOneSlice(vm, rt.workers[1]) }
}

private func failures(_ rt: Runtime) -> UInt64 { rt.vm.metric(.verifyFailures) }

/// 4000 Pairs promoted, then all but every 20th dropped: sparse blocks. A
/// cycle marks them and the final mark selects the blocks (threshold 50).
private func sparseCycle(_ rt: Runtime, _ m: MarkerRef, n: Int64 = 4000) {
    let vm = rt.vm
    runAll(rt, "mkSparse:", n)
    hostCollect(vm, full: false)               // promote everything (N = 1)
    vm.pointee.globals[6] = vm.pointee.nilObj  // drop the list
    cmStart(vm)
    cmMark(vm, m, 10_000_000)
    cmFinal(vm)
}

private func keptSum(_ rt: Runtime) -> Int64 {
    let om = rt.vm.pointee.om
    let keep = global(rt, 8)
    var s: Int64 = 0
    for i in 0..<hdrSlots(om.header(keep)) { s += intVal(om.slot(om.slot(keep, i), 0)) }
    return s
}

private let expectedSum: Int64 = (1...200).reduce(0) { $0 + Int64($1 * 20) }

private func keptObject(_ rt: Runtime, _ i: Int) -> Oop { rt.vm.pointee.om.slot(global(rt, 8), i) }

// MARK: - reclaim

@Test func relocationEvacuatesSparseBlocksAndKeepsTheObjects() throws {
    let (rt, m) = try manualRelocRuntime()
    let vm = rt.vm
    sparseCycle(rt, m)
    let set = relocSet(vm)
    #expect(set.count >= 3 && set.contains(0)) // the image's block is sparse too
    let a = keptObject(rt, 0)
    let before = offsetOf(vm, a)
    #expect(set.contains(blockOfObject(vm, a)))
    let inUse = vm.pointee.heap.blocksInUse()
    cmRelocate(vm, m)
    #expect(offsetOf(vm, a) != before && offsetOf(vm, a) & relocBit == 0)
    #expect(!set.contains(blockOfObject(vm, a)))
    // Every selected block but the image's (pinned objects) is evacuated
    // and freed by epoch: no worker is inside the VM.
    #expect(vm.metric(.relocEvacuated) == UInt64(set.count - 1))
    #expect(vm.metric(.relocFreedEpoch) == UInt64(set.count - 1))
    #expect(vm.metric(.relocMovedObjects) >= 200 && vm.metric(.relocSkipPinned) > 0)
    for b in set where b != 0 { #expect(!vm.pointee.heap.isInUse(b)) }
    #expect(vm.pointee.heap.blocksInUse() < inUse)
    cmSweep(vm, m)
    hostCollect(vm, full: false)                // applies the sweep
    #expect(keptSum(rt) == expectedSum)
    // A second cycle and a full collection agree.
    cmStart(vm); cmMark(vm, m, 10_000_000); cmFinal(vm); cmRelocate(vm, m); cmSweep(vm, m)
    hostCollect(vm, full: true)
    #expect(keptSum(rt) == expectedSum)
    #expect(vm.metric(.relocVerifyRuns) >= 4 && failures(rt) == 0)
    rt.stop()
}

// MARK: - post-store check

/// The object is held in RELOCATING after its copy; another thread stores
/// into it (checked or not), then the switch is published.
private func storeDuringRelocating(checked: Bool) throws -> (Oop, Oop, UInt64) {
    let (rt, m) = try manualRelocRuntime()
    let vm = rt.vm
    sparseCycle(rt, m)
    let a = keptObject(rt, 0)
    let old = vm.pointee.om.slot(a, 0)
    guard let step = testRelocBegin(vm, m, a) else { Issue.record("begin failed"); fatal("begin") }
    #expect(offsetOf(vm, a) & relocBit != 0)
    testRelocCopy(vm, step)
    let w = rt.workers[1]
    let bits = UInt(bitPattern: vm), wb = UInt(bitPattern: w)
    let started = Flag()
    let t = Thread {
        let vm = UnsafeMutablePointer<VMCore>(bitPattern: bits)!
        let w = UnsafeMutablePointer<Worker>(bitPattern: wb)!
        enterVM(vm, w)
        started.set()
        if checked { setSlot(w, vm.pointee.om, a, 0, mkInt(42)) } else { vm.pointee.om.setSlotRaw(a, 0, mkInt(42)) }
        leaveVM(vm, w)
    }
    if checked {
        // Give the store time to land in the old body through the alias and
        // its check time to see RELOCATING; `redo == 1` below confirms it.
        #expect(eventually { started.isSet })
        usleep(50_000)
    } else {
        t.join()
    }
    testRelocSwitch(vm, m, step)
    if checked { t.join() }
    let after = vm.pointee.om.slot(a, 0)
    let redo = w.pointee.storeRedo
    #expect(failures(rt) == 0)
    rt.stop()
    return (old, after, redo)
}

@Test func aStoreDuringRelocatingLandsInTheNewBody() throws {
    let (old, after, redo) = try storeDuringRelocating(checked: true)
    #expect(old != mkInt(42))
    #expect(after == mkInt(42))
    #expect(redo == 1)
}

@Test func withoutThePostStoreCheckTheStoreIsLost() throws {
    let (old, after, _) = try storeDuringRelocating(checked: false)
    #expect(after == old) // the store went into the old body only
}

// MARK: - pins

@Test func aFramePinnedObjectIsNotMoved() throws {
    try framePin(rule: true)
}

@Test func withoutThePinRuleTheFrameObjectIsMoved() throws {
    try framePin(rule: false)
}

private func framePin(rule: Bool) throws {
    let (rt, m) = try manualRelocRuntime { $0.pinRule = rule; $0.relocThreshold = 101 }
    let vm = rt.vm
    runAll(rt, "mkSparse:", 4000)
    hostCollect(vm, full: false)
    vm.pointee.globals[6] = vm.pointee.nilObj
    let a = keptObject(rt, 0)
    // A Process holding `a` in a temp, spinning on worker 1's own thread.
    let p = spawn(vm, vm.pointee.nilObj, rt.symbol("holdFirst"), vm.pointee.nilObj)
    let w = rt.workers[1]
    let bits = UInt(bitPattern: vm), wb = UInt(bitPattern: w)
    let t = Thread {
        let vm = UnsafeMutablePointer<VMCore>(bitPattern: bits)!
        _ = runOneSlice(vm, UnsafeMutablePointer<Worker>(bitPattern: wb)!)
    }
    // Running once the Process is no longer on a ready queue (read inside
    // the VM under the scheduler lock).
    #expect(eventually { processState(vm, p) == stRunning })
    cmStart(vm)
    cmMark(vm, m, 10_000_000)
    cmFinal(vm)                       // the frame holds `a`: pinned
    let before = offsetOf(vm, a)
    let method = rt.vm.pointee.om.slot(lookup(vm, UInt64(ciNil), rt.symbol("holdFirst")), mBytecodes)
    let methodBefore = offsetOf(vm, method)
    #expect(relocSet(vm).contains(blockOfObject(vm, a)))
    #expect(vm.pointee.om.header(a) & framePinBit != 0)
    cmRelocate(vm, m)
    if rule {
        #expect(offsetOf(vm, a) == before)
        #expect(offsetOf(vm, method) == methodBefore) // pinned for good
        #expect(vm.metric(.relocSkipPinned) >= 2)
    } else {
        #expect(offsetOf(vm, a) != before)
        #expect(offsetOf(vm, method) != methodBefore)
    }
    hostTerminate(vm, p)
    t.join()
    cmSweep(vm, m)
    hostCollect(vm, full: false)
    #expect(vm.pointee.om.header(a) & framePinBit == 0) // cleared by the apply
    #expect(keptSum(rt) == expectedSum)
    #expect(failures(rt) == 0)
    rt.stop()
}

// MARK: - hazards

private func hazard(rule: Bool) throws -> (Bool, Bool) {
    let (rt, m) = try manualRelocRuntime { $0.hazardRule = rule }
    let vm = rt.vm
    sparseCycle(rt, m)
    let a = keptObject(rt, 0)
    let before = offsetOf(vm, a)
    let w = rt.workers[1]
    enterVM(vm, w)
    let body = hazardAcquire(w, vm.pointee.om, 0, a) // a primitive holds a's body
    // The relocator runs meanwhile (on the marker record: this thread).
    w.pointee.hz[hzEpoch].store(quiescent, ordering: .relaxed) // let blocks be freed; not under test here
    cmRelocate(vm, m)
    let moved = offsetOf(vm, a) != before
    // The primitive stores through its raw pointer, then releases.
    atomicWord(body + 1).pointee.store(mkInt(99), ordering: .relaxed)
    hazardRelease(w, 0)
    leaveVM(vm, w)
    let seen = vm.pointee.om.slot(a, 0) == mkInt(99)
    if rule {
        #expect(vm.metric(.relocSkipHazard) == 1)
        #expect(!relocSet(vm).isEmpty && !pendingBlocks(vm).contains(blockOfObject(vm, a)))
    }
    #expect(failures(rt) == 0)
    rt.stop()
    return (moved, seen)
}

@Test func aHazardedObjectIsSkipped() throws {
    let (moved, seen) = try hazard(rule: true)
    #expect(!moved && seen)
}

@Test func withoutTheHazardCheckThePrimitivesStoreIsLost() throws {
    let (moved, seen) = try hazard(rule: false)
    #expect(moved && !seen)
}

// MARK: - epochs

private func epochs(rule: Bool) throws -> (Int, Int) {
    let (rt, m) = try manualRelocRuntime { $0.epochRule = rule }
    let vm = rt.vm
    sparseCycle(rt, m)
    let w = rt.workers[1]
    enterVM(vm, w)                     // active, epoch taken now, no poll yet
    cmRelocate(vm, m)
    let freedDuring = Int(vm.metric(.relocFreedEpoch))
    let waiting = pendingBlocks(vm).count
    for b in pendingBlocks(vm) { #expect(vm.pointee.heap.isInUse(b)) }
    testAdvanceEpoch(vm, w)            // the worker passes a poll
    cmTryFree(vm, m)
    #expect(pendingBlocks(vm).isEmpty)
    #expect(Int(vm.metric(.relocFreedEpoch)) == freedDuring + waiting)
    leaveVM(vm, w)
    #expect(failures(rt) == 0)
    rt.stop()
    return (freedDuring, waiting)
}

@Test func aBlockIsNotFreedBeforeEveryWorkersEpochPasses() throws {
    let (freedDuring, waiting) = try epochs(rule: true)
    #expect(freedDuring == 0 && waiting >= 2)
}

@Test func withoutTheEpochRuleBlocksAreFreedAtOnce() throws {
    let (freedDuring, waiting) = try epochs(rule: false)
    #expect(freedDuring >= 2 && waiting == 0)
}

@Test func everyPauseFreesThePendingBlocks() throws {
    let (rt, m) = try manualRelocRuntime()
    let vm = rt.vm
    sparseCycle(rt, m)
    let w = rt.workers[1]
    enterVM(vm, w)
    cmRelocate(vm, m)
    let waiting = pendingBlocks(vm).count
    #expect(waiting >= 2)
    leaveVM(vm, w)
    hostCollect(vm, full: false)
    #expect(pendingBlocks(vm).isEmpty && vm.metric(.relocFreedPause) == UInt64(waiting))
    #expect(failures(rt) == 0)
    rt.stop()
}

// MARK: - verifier

@Test func theVerifierCatchesABodyInAFreedBlock() throws {
    let (rt, m) = try manualRelocRuntime()
    let vm = rt.vm
    sparseCycle(rt, m)
    // Free a selected block without relocating it: its live objects now
    // sit in a free block.
    let b = relocSet(vm)[0]
    vm.pointee.heap.freeAtPause(b)
    hostCollect(vm, full: false)
    #expect(failures(rt) > 0)
    rt.stop()
}

// MARK: - threads: mutation under relocation of every live block

/// `kernel` on 4 workers, cycles back to back, every live snapshot block
/// relocated in every cycle, every verifier on; checksum against
/// stop-the-world. The oldheap rewires and the fragment keeper writes race
/// with the copies: lost stores would change the checksum.
private func underRelocation(_ kernel: String, heapMB: Int, nurseryKB: Int) throws {
    func once(_ cfg: CMConfig) throws -> (Int64, VMRef, Runtime) {
        let img = try Image.fromSources(try kernelSources(kernel), heapSize: heapMB << 20, nurseryBytes: nurseryKB << 10)
        let rt = Runtime(img, background: 4, pollEvery: 256, start: false, verify: false, config: cfg)
        rt.start()
        let sel = rt.symbol("kernel:")
        var ps: [Oop] = []
        for i in 0..<4 { ps.append(spawn(rt.vm, rt.vm.pointee.nilObj, sel, mkInt(Int64(i * 256 + 4)))) }
        waitAllTerminated(rt.vm)
        rt.stop()
        return (ps.map { result(rt, $0) }.reduce(0, &+), rt.vm, rt)
    }
    var stw = CMConfig()
    stw.concurrent = false
    var agg = CMConfig()
    agg.force = true
    agg.threshold = 0
    agg.verify = true
    agg.ageN = 2
    agg.relocThreshold = 101
    agg.relocCap = 0.9
    let (a, _, _) = try once(stw)
    let (b, vm, rt) = try once(agg)
    #expect(a == b)
    #expect(vm.metric(.cmMissed) == 0 && vm.metric(.verifyFailures) == 0)
    #expect(vm.metric(.relocMovedObjects) > 1000 && vm.metric(.relocVerifyRuns) > 10)
    var redo: UInt64 = 0
    for w in rt.workers { redo += w.pointee.storeRedo }
    print("\(kernel) under relocation: moved \(vm.metric(.relocMovedObjects)) objects, \(vm.metric(.relocEvacuated)) blocks, stores redone \(redo), hazards \(vm.metric(.relocSkipHazard)), freed by epoch \(vm.metric(.relocFreedEpoch)) at pauses \(vm.metric(.relocFreedPause))")
}

@Test func oldheapUnderAggressiveRelocationMatchesStopTheWorld() throws {
    try underRelocation("oldheap4", heapMB: 72, nurseryKB: 1024)
}

@Test func fragmentUnderAggressiveRelocationMatchesStopTheWorld() throws {
    try underRelocation("fragment400000", heapMB: 128, nurseryKB: 1024)
}

/// A flag set by one thread and polled by another.
final class Flag: @unchecked Sendable {
    private let a = Atomic<Bool>(false)
    func set() { a.store(true, ordering: .releasing) }
    var isSet: Bool { a.load(ordering: .acquiring) }
}
