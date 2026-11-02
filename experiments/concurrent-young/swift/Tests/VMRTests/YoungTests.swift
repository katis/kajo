// Tests of young collection without stopping the world (SPEC.md "Part 1",
// "Part 2", "Ordering and soundness", "Test-only switches"). Each rule has a
// test that passes with it and fails with it switched off. The collector is
// worker 1, run from the test thread (`ycCollectNow`); the young verifier
// runs at a forced pause after every collection. The interleavings come
// from the collector's hook after H1 (run on the test thread) or from a
// helper thread acting as another worker.

import Darwin
import Kasm
import Synchronization
import Testing
@testable import VMR

/// Globals: 8 Y holder, 9 holder H, 10 Semaphore, 11 stop flag.
private let ysrc = """
class Pair Object 2
method Pair x temps=0
  push_ivar 0
  return_top
end
method Pair x: temps=0
  push_temp 0
  store_ivar 0
  return_self
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
method UndefinedObject pair: temps=0
  push_lit @Pair
  send basicNew 0
  push_temp 0
  push_nil
  send x:y: 2
  return_top
end
method Object slowPeek: temps=0 prim=39
end
; global 8 := Pair x: (Pair x: 42): P in this worker's nursery holding Y.
method UndefinedObject mkP temps=0
  push_nil
  push_int 8
  push_nil
  push_nil
  push_int 42
  send pair: 1
  send pair: 1
  send g:put: 2
  pop
  push_nil
  return_top
end
; global 8 := Y (Pair x: 42). Answers nil: a Process's result slot would
; hold Y (a dead Process remembered as a holder keeps it alive).
method UndefinedObject mkY temps=0
  push_nil
  push_int 8
  push_nil
  push_int 42
  send pair: 1
  send g:put: 2
  pop
  push_nil
  return_top
end
; Take Y out of P (global 8), clear P's slot, wait holding Y; answer Y x.
method UndefinedObject steal temps=1
  push_nil
  push_int 8
  send g: 1
  send x 0
  store_temp 0
  push_nil
  push_int 8
  send g: 1
  push_nil
  send x: 1
  pop
  push_nil
  push_int 10
  send g: 1
  send wait 0
  pop
  push_temp 0
  send x 0
  return_top
end
; global 9 := H (Pair in this worker's nursery) x: Y (global 8); global 8 := nil.
method UndefinedObject hold temps=0
  push_nil
  push_int 9
  push_nil
  push_nil
  push_int 8
  send g: 1
  send pair: 1
  send g:put: 2
  pop
  push_nil
  push_int 8
  push_nil
  send g:put: 2
  return_top
end
; H x x
method UndefinedObject readH temps=0
  push_nil
  push_int 9
  send g: 1
  send x 0
  send x 0
  return_top
end
; Take Y (global 8), clear global 8, spin until global 11 is not nil
; (polling), answer Y x.
method UndefinedObject spinHolding temps=1
  push_nil
  push_int 8
  send g: 1
  store_temp 0
  push_nil
  push_int 8
  push_nil
  send g:put: 2
  pop
loop:
  push_nil
  push_int 11
  send g: 1
  push_nil
  identical
  jump_if_true loop
  push_temp 0
  send x 0
  return_top
end
; (global 8) slowPeek: 1
method UndefinedObject peek temps=0
  push_nil
  push_int 8
  send g: 1
  push_int 1
  send slowPeek: 1
  return_top
end
; Old O (global 9) x: Y (global 8).
method UndefinedObject linkOY temps=0
  push_nil
  push_int 9
  send g: 1
  push_nil
  push_int 8
  send g: 1
  send x: 1
  return_top
end
; global 9 := Pair (to be made old).
method UndefinedObject mkO temps=0
  push_nil
  push_int 9
  push_nil
  push_int 7
  send pair: 1
  send g:put: 2
  return_top
end
; churn: n Pairs. t0 = n, t1 = i
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

/// A local-mode runtime stepped from the test thread, workers 1..3, the
/// young verifier after every collection.
private func yRuntime(ageN: Int = 2, _ change: (inout YCConfig) -> Void = { _ in }) throws -> Runtime {
    let img = try Image.fromSources(try baseSources() + [ysrc], heapSize: 64 << 20, nurseryBytes: 1 << 20)
    var cfg = CMConfig()
    cfg.manual = true
    cfg.ageN = ageN
    cfg.threshold = 2 // no marking cycle
    var y = YCConfig()
    y.mode = YoungMode.local
    y.verifyYoung = true
    change(&y)
    let rt = Runtime(img, background: 3, pollEvery: 64, start: false, verify: true, config: cfg, young: y)
    rt.vm.pointee.globals[9] = hostNewSemaphore(rt.vm)
    rt.vm.pointee.globals[10] = rt.vm.pointee.nilObj
    return rt
}

private func spawnSel(_ rt: Runtime, _ sel: String, _ arg: Oop? = nil) -> Oop {
    spawn(rt.vm, rt.vm.pointee.nilObj, rt.symbol(sel), arg ?? rt.vm.pointee.nilObj)
}

/// Run one slice of the next ready Process on worker `i` from this thread.
private func slice(_ rt: Runtime, _ i: Int) { #expect(runOneSlice(rt.vm, rt.workers[i])) }

private func failures(_ rt: Runtime) -> UInt64 { rt.vm.metric(.verifyFailures) }
private func dumpLast(_ rt: Runtime) {
    let l = rt.vm.pointee.yc.log.pointee
    if l.count > 0 { let r = l.recs[l.count - 1]; print("DBG stack=\(r.stackRoots) proc=\(r.procScans) holders=\(r.holders) del=\(r.delRecords) copied=\(r.copiedObjects) carried=\(r.carried)") }
}

// The hook runs on the collector's thread; tests set the action before the
// collection and clear it after.
nonisolated(unsafe) private var hookAction: ((Int) -> Void)? = nil
private let testHook: YCHook = { _, k, point in if point == 1 { hookAction?(k) } }
nonisolated(unsafe) private var hook0Action: ((Int) -> Void)? = nil
private let testHook0: YCHook = { _, k, point in if point == 0 { hook0Action?(k) } }

@Suite(.serialized) struct YoungCollection {
// MARK: - deletion barrier and second handshake

/// P (nursery 1, reachable from global 8) holds Y. After H1, a Process on
/// worker 2 takes Y into a temporary, clears P's slot and parks holding it.
/// Its stack was scanned when it resumed, before it took Y; P is scanned at
/// T1 with the slot already cleared. Only the deletion record, published in
/// the drain round, keeps Y. Answers (verifier failures, Y x after).
private func stealDuringCollection(_ change: (inout YCConfig) -> Void) throws -> (UInt64, Int64?) {
    let rt = try yRuntime { $0.hook = testHook; change(&$0) }
    let vm = rt.vm
    _ = spawnSel(rt, "mkP")
    slice(rt, 1)                       // P, Y in nursery 1
    let thief = spawnSel(rt, "steal")
    hookAction = { _ in slice(rt, 2) } // runs until it waits holding Y
    ycCollectNow(vm, rt.workers[1])
    hookAction = nil
    let f = failures(rt)
    var r: Int64? = nil
    if f == 0 {
        hostSignal(vm, global(rt, 10))
        slice(rt, 2)
        r = result(rt, thief)
    }
    rt.stop()
    return (f, r)
}

@Test func youngDeletionBarrierKeepsAValueTakenAfterH1() throws {
    let (f, r) = try stealDuringCollection { _ in }
    #expect(f == 0)
    #expect(r == 42)
}

@Test func withoutTheYoungDeletionBarrierTheValueIsLost() throws {
    let (f, _) = try stealDuringCollection { $0.youngDeletion = false }
    #expect(f > 0)
}

@Test func withoutTheSecondHandshakeTheDeletionRecordIsNeverSeen() throws {
    let (f, _) = try stealDuringCollection { $0.secondHandshake = false }
    #expect(f > 0)
}

// MARK: - cross-nursery barrier

/// Y in nursery 1 is held only by H, a young object of nursery 2 reachable
/// from global 9. Collecting nursery 1 must find Y through H's remembered
/// bit for nursery 1.
private func crossNursery(_ on: Bool) throws -> (UInt64, Int64?) {
    let rt = try yRuntime { $0.crossNursery = on }
    let vm = rt.vm
    _ = spawnSel(rt, "mkY")
    slice(rt, 1)
    _ = spawnSel(rt, "hold")
    slice(rt, 2)
    let h = global(rt, 9)
    #expect(vm.pointee.om.isYoung(h) && hdrNursery(vm.pointee.om.header(h)) == 2)
    ycCollectNow(vm, rt.workers[1])
    let f = failures(rt)
    var r: Int64? = nil
    if f == 0 {
        let p = spawnSel(rt, "readH")
        slice(rt, 2)
        r = result(rt, p)
    }
    rt.stop()
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

// MARK: - handshake stack scan

/// A thread acting as worker 2 runs a Process that takes Y off global 8 and
/// spins (polling) with Y only on its stack while worker 1 collects.
private func stackOnly(_ scan: Bool) throws -> (UInt64, Int64?) {
    let rt = try yRuntime { $0.stackScan = scan }
    let vm = rt.vm
    _ = spawnSel(rt, "mkY")
    slice(rt, 1)
    let p = spawnSel(rt, "spinHolding")
    let w2 = rt.workers[2]
    let bits = UInt(bitPattern: vm), wbits = UInt(bitPattern: w2)
    var tid: pthread_t? = nil
    pthread_create(&tid, nil, { arg in
        let pr = arg.assumingMemoryBound(to: (UInt, UInt).self)
        let v = UnsafeMutablePointer<VMCore>(bitPattern: pr.pointee.0)!
        let w = UnsafeMutablePointer<Worker>(bitPattern: pr.pointee.1)!
        _ = runOneSlice(v, w)
        pr.deallocate()
        return nil
    }, { let p = UnsafeMutablePointer<(UInt, UInt)>.allocate(capacity: 1); p.initialize(to: (bits, wbits)); return UnsafeMutableRawPointer(p) }())
    // Wait until the Process cleared global 8 (it holds Y on its stack).
    #expect(eventually { atomicWord(vm.pointee.globals + 7).pointee.load(ordering: .acquiring) == vm.pointee.nilObj })
    ycCollectNow(vm, rt.workers[1])
    let f = failures(rt)
    atomicWord(vm.pointee.globals + 10).pointee.store(mkInt(1), ordering: .releasing)
    pthread_join(tid!, nil)
    let r: Int64? = f == 0 ? result(rt, p) : nil
    rt.stop()
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

// MARK: - epoch rule before eden reuse

/// A thread acting as worker 2 runs `slowPeek:` on Y (nursery 1): it takes
/// Y's body pointer, enters a blocking region and waits. Worker 1 collects
/// (Y is copied; worker 2 is acknowledged by proxy) and then churns over
/// its eden. The primitive then reads through its pointer.
private func peekAcross(_ epoch: Bool) throws -> Int64 {
    let rt = try yRuntime { $0.epochRule = epoch; $0.verifyYoung = false }
    let vm = rt.vm
    _ = spawnSel(rt, "mkY")
    slice(rt, 1)
    let p = spawnSel(rt, "peek")
    slowPeekGate.store(1, ordering: .releasing)
    slowPeekHeld.store(0, ordering: .releasing)
    let bits = UInt(bitPattern: vm), wbits = UInt(bitPattern: rt.workers[2])
    var tid: pthread_t? = nil
    pthread_create(&tid, nil, { arg in
        let pr = arg.assumingMemoryBound(to: (UInt, UInt).self)
        _ = runOneSlice(UnsafeMutablePointer<VMCore>(bitPattern: pr.pointee.0)!, UnsafeMutablePointer<Worker>(bitPattern: pr.pointee.1)!)
        pr.deallocate()
        return nil
    }, { let p = UnsafeMutablePointer<(UInt, UInt)>.allocate(capacity: 1); p.initialize(to: (bits, wbits)); return UnsafeMutableRawPointer(p) }())
    #expect(eventually { slowPeekHeld.load(ordering: .acquiring) == 1 })
    // With the rule the collection waits for worker 2's epoch: let the
    // primitive go a while later from yet another thread.
    var opener: pthread_t? = nil
    pthread_create(&opener, nil, { _ in usleep(300_000); slowPeekGate.store(0, ordering: .releasing); return nil }, nil)
    ycCollectNow(vm, rt.workers[1])
    _ = spawnSel(rt, "churn:", mkInt(20_000))
    slice(rt, 1)                       // over the old eden
    pthread_join(opener!, nil)
    pthread_join(tid!, nil)
    let r = result(rt, p)
    rt.stop()
    return r
}

@Test func edenIsReusedOnlyAfterEveryWorkersEpoch() throws {
    #expect(try peekAcross(true) == 42)
}

@Test func withoutTheEpochRuleAPrimitiveReadsAReusedEden() throws {
    #expect(try peekAcross(false) != 42)
}

// MARK: - remembered holders carried across collections

/// N = 3. O is old; O x: Y (young, nursery 1) remembers O for nursery 1.
/// Collection 1 scans O, Y survives (age 1) and O must stay remembered:
/// collection 2 finds Y only through O.
private func carried(_ carry: Bool) throws -> (UInt64, Int64?) {
    let rt = try yRuntime(ageN: 3) { $0.carryRem = carry }
    let vm = rt.vm
    _ = spawnSel(rt, "mkO")
    slice(rt, 1)
    hostCollect(vm, full: true) // O old
    _ = spawnSel(rt, "mkY")
    slice(rt, 1)
    _ = spawnSel(rt, "linkOY")
    slice(rt, 1)
    atomicWord(vm.pointee.globals + 7).pointee.store(vm.pointee.nilObj, ordering: .relaxed)
    let o = global(rt, 9)
    #expect(!vm.pointee.om.isYoung(o))
    ycCollectNow(vm, rt.workers[1])
    let y = vm.pointee.om.slot(o, 0)
    let f1 = failures(rt)
    #expect(vm.pointee.om.isYoung(y))
    ycCollectNow(vm, rt.workers[1])
    let f = failures(rt)
    var r: Int64? = nil
    if f == 0 && f1 == 0 { r = intVal(vm.pointee.om.slot(vm.pointee.om.slot(o, 0), 0)) }
    rt.stop()
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

/// Part 2: worker 1 flips and the collector thread copies; the same Y held
/// only by another nursery's young holder survives, and the young verifier
/// is clean.
@Test func anOffloadedCollectionFindsACrossNurseryHolder() throws {
    let img = try Image.fromSources(try baseSources() + [ysrc], heapSize: 64 << 20, nurseryBytes: 1 << 20)
    var cfg = CMConfig()
    cfg.manual = true
    cfg.ageN = 2
    cfg.threshold = 2
    var y = YCConfig()
    y.mode = YoungMode.offload
    y.verifyYoung = true
    let rt = Runtime(img, background: 3, pollEvery: 64, start: false, verify: true, config: cfg, young: y)
    rt.startCollectorOnly()
    let vm = rt.vm
    _ = spawnSel(rt, "mkY")
    slice(rt, 1)
    _ = spawnSel(rt, "hold")
    slice(rt, 2)
    ycCollectNow(vm, rt.workers[1]) // nursery 1's eden half goes to the collector
    ycCollectNow(vm, rt.workers[1]) // and the other half
    #expect(failures(rt) == 0)
    #expect(eventually { vm.metric(.youngVerifyRuns) >= 2 })
    let p = spawnSel(rt, "readH")
    slice(rt, 2)
    #expect(result(rt, p) == 42)
    rt.stop()
}


// MARK: - offload: the owner's new eden half

/// Offload. Y (nursery 1) is in the eden half worker 1 hands over. Before
/// H0, worker 1 (run by the collector's hook, the test thread being
/// outside) allocates H in its new half holding Y, publishes H in global 9
/// and clears global 8. H is not in Y, so the collector does not trace it:
/// only the scan of the new half's objects allocated before the owner's H1
/// acknowledgement, or the snoop that remembers H at the store, keeps Y.
private func newHalf(scan: Bool, snoop: Bool) throws -> UInt64 {
    let img = try Image.fromSources(try baseSources() + [ysrc], heapSize: 64 << 20, nurseryBytes: 1 << 20)
    var cfg = CMConfig()
    cfg.manual = true
    cfg.ageN = 2
    cfg.threshold = 2
    var y = YCConfig()
    y.mode = YoungMode.offload
    y.verifyYoung = true
    y.newHalfScan = scan
    y.snoop = snoop
    y.hook = testHook0
    let rt = Runtime(img, background: 3, pollEvery: 64, start: false, verify: true, config: cfg, young: y)
    rt.vm.pointee.globals[9] = hostNewSemaphore(rt.vm)
    rt.startCollectorOnly()
    let vm = rt.vm
    _ = spawnSel(rt, "mkY")
    slice(rt, 1)
    _ = spawnSel(rt, "hold")
    hook0Action = { k in if k == 1 { _ = runOneSlice(vm, rt.workers[1]) } }
    ycFlipNow(vm, rt.workers[1])
    ycWaitDone(vm, 1)
    hook0Action = nil
    #expect(eventually { vm.metric(.youngVerifyRuns) >= 1 })
    let f = failures(rt)
    rt.stop()
    return f
}

@Test func theOwnersNewHalfObjectsAreScannedAtT1() throws {
    #expect(try newHalf(scan: true, snoop: false) == 0)
}

@Test func theSnoopRemembersANewHalfHolder() throws {
    #expect(try newHalf(scan: false, snoop: true) == 0)
}

@Test func withoutNewHalfScanAndSnoopTheValueIsLost() throws {
    #expect(try newHalf(scan: false, snoop: false) > 0)
}
}
