// Concurrent relocation (docs/modules/relocation.md), ported from
// experiments/concurrent-relocation's RelocationTests.swift. Each rule has a
// test that shows what happens without it, through a test-only switch: the
// post-store check, pins, hazard slots, the epoch rule, the epoch 0 at
// `enterVM`. Manual runtimes drive marking and relocation from the test
// thread; the threaded ones are in RelocationKernelTests.swift.

import Darwin
import Synchronization
import Testing
@testable import KajoVM

// MARK: - reclaim

@Test func relocationEvacuatesSparseBlocksAndKeepsTheObjects() throws {
    let rt = try relocRuntime()
    rt.sparseCycle()
    let set = rt.vm.relocationSet
    let a = rt.kept(0)
    let before = rt.vm.stateWord(of: a)
    #expect(set.count >= 2, "set \(set)")
    #expect(set.contains(rt.vm.block(of: a)))
    let inUse = rt.vm.inspect { $0.blocksInUse }
    rt.vm.relocate()
    let after = rt.vm.stateWord(of: a)
    #expect(after != before && after & EntryState.relocatingBit == 0)
    #expect(!set.contains(rt.vm.block(of: a)))
    let c = rt.relocation
    // Every selected block without a pinned object is evacuated and, no
    // worker being inside the VM, freed by epoch at once.
    #expect(c.blocksEvacuated >= 2 && c.objectsMoved >= UInt64(sparseKept), "\(c)")
    #expect(c.freedByEpoch == c.blocksEvacuated)
    #expect(c.blocksEvacuated + (c.skippedPinned > 0 ? 1 : 0) >= UInt64(set.count) - 1)
    let freed = set.filter { !rt.vm.isBlockInUse($0) }
    #expect(UInt64(freed.count) == c.blocksEvacuated)
    #expect(rt.vm.inspect { $0.blocksInUse } < inUse)
    rt.vm.sweep()
    rt.scavenge()  // applies the sweep
    #expect(rt.phase == .idle)
    #expect(rt.keptSum == sparseSum)
    // A second cycle and a full collection agree.
    rt.vm.startCycle()
    _ = rt.vm.markStep(10_000_000)
    rt.vm.finalMark()
    rt.vm.relocate()
    rt.vm.sweep()
    rt.vm.collect()
    #expect(rt.keptSum == sparseSum)
    #expect(rt.relocation.verifierRuns >= 4 && rt.relocation.verifierFailures == 0)
    rt.noFailures()
    rt.stop()
}

// MARK: - post-store check

/// `a` is held RELOCATING after its copy; worker 1 on another thread stores
/// into it (checked, through module 4's barrier, or raw), then the switch
/// is published. Answers the slot before, after, and the stores redone.
private func storeDuringRelocating(checked: Bool) throws -> (Oop, Oop, UInt64) {
    let rt = try relocRuntime()
    rt.sparseCycle()
    let a = rt.kept(0)
    let old = rt.image.om.load(a, 0)
    guard let step = rt.vm.stepBegin(a) else {
        Issue.record("the CAS failed")
        rt.stop()
        return (.none, .none, 0)
    }
    #expect(rt.vm.stateWord(of: a) & EntryState.relocatingBit != 0)
    rt.vm.stepCopy(step)
    let vm = rt.vm
    let started = Flag()
    let t = TestThread {
        let w = vm.state.worker(1)
        enterVM(vm.state, w)
        started.set()
        if checked {
            barrierStore(w, a, 0, Oop(smallInteger: 42), .atPut)
        } else {
            vm.image.om.store(a, 0, Oop(smallInteger: 42))
        }
        leaveVM(vm.state, w)
    }
    if checked {
        // The store lands in the old body through the alias and its check
        // sees RELOCATING; the redo count below confirms it waited.
        #expect(eventually { started.isSet })
        usleep(50_000)
    } else {
        t.join()
    }
    rt.vm.stepSwitch(step)
    if checked { t.join() }
    let after = rt.image.om.load(a, 0)
    let redo = rt.vm.mutatorRelocationCounters(1).storesRedone
    rt.noFailures()
    rt.stop()
    return (old, after, redo)
}

@Test func aStoreDuringRelocatingLandsInTheNewBody() throws {
    let (old, after, redo) = try storeDuringRelocating(checked: true)
    #expect(old != Oop(smallInteger: 42))
    #expect(after == Oop(smallInteger: 42))
    #expect(redo == 1)
}

@Test func withoutThePostStoreCheckTheStoreIsLost() throws {
    let (old, after, _) = try storeDuringRelocating(checked: false)
    #expect(after == old)  // the raw store went into the old body only
}

/// The same race through the interpreter: a Process stores into `a` with
/// `x:y:` (two `store_ivar`s) while `a` is RELOCATING.
@Test func aStoreIvarDuringRelocatingLandsInTheNewBody() throws {
    let rt = try relocRuntime()
    rt.sparseCycle()
    let a = rt.kept(0)
    guard let step = rt.vm.stepBegin(a) else {
        Issue.record("the CAS failed")
        rt.stop()
        return
    }
    rt.vm.stepCopy(step)
    let vm = rt.vm
    // Nothing may stop the world while the step holds `a` RELOCATING.
    let done = Flag()
    let t = TestThread {
        let w = vm.state.worker(1)
        enterVM(vm.state, w)
        let s = w.pointer(to: \Worker.interp)!
        // `a x: 7 y: 8` as store_ivar does it, through the interpreter's
        // barrier with the flag line it holds.
        storeWithBarrier(s, s.pointee.safepointFlag, vm.image.om, a, 0, Oop(smallInteger: 7), .storeIvar)
        storeWithBarrier(s, s.pointee.safepointFlag, vm.image.om, a, 1, Oop(smallInteger: 8), .storeIvar)
        leaveVM(vm.state, w)
        done.set()
    }
    usleep(20_000)
    #expect(!done.isSet)  // spinning in the slow path
    rt.vm.stepSwitch(step)
    t.join()
    #expect(rt.image.om.load(a, 0) == Oop(smallInteger: 7) && rt.image.om.load(a, 1) == Oop(smallInteger: 8))
    let m = rt.vm.mutatorRelocationCounters(1)
    // The first store waited for the switch and was redone; the second
    // went straight into the new body.
    #expect(m.storesRedone == 1 && m.spinEpisodes == 1, "\(m)")
    rt.noFailures()
    rt.stop()
}

// MARK: - pins

private func framePin(rule: Bool) throws {
    let rt = try relocRuntime { $0.testSwitches.pinRule = rule; $0.stress = .relocateEveryLiveBlock }
    #expect(rt.runInt("mkSparse:", 4000) == 0)
    rt.scavenge()
    rt.vm.setGlobal(7, rt.image.nilObject)
    let a = rt.kept(0)
    // A Process holding `a` in a temp, spinning on worker 1 on its own thread.
    let p = rt.spawn("holdFirst")
    let vm = rt.vm
    let t = TestThread { _ = vm.runOneSlice(worker: 1) }
    #expect(eventually { rt.state(p) == .running })
    rt.vm.startCycle()
    _ = rt.vm.markStep(10_000_000)
    rt.vm.finalMark()  // the frame holds `a`: frame-pinned
    let method = try #require(rt.image.lookup(WellKnown.undefinedObject, rt.image.symbol("holdFirst")!))
    let code = rt.image.om.load(method, MethodLayout.bytecodes)
    let before = rt.vm.stateWord(of: a), codeBefore = rt.vm.stateWord(of: code)
    #expect(rt.vm.relocationSet.contains(rt.vm.block(of: a)))
    #expect(rt.vm.relocationSet.contains(rt.vm.block(of: code)))
    #expect(rt.header(a).isFramePinned)
    #expect(rt.header(code).isPinnedForGood)
    rt.vm.relocate()
    if rule {
        #expect(rt.vm.stateWord(of: a) == before)
        #expect(rt.vm.stateWord(of: code) == codeBefore)  // pinned for good
        #expect(rt.relocation.skippedPinned >= 2)
    } else {
        #expect(rt.vm.stateWord(of: a) != before)
        // Pinned for good stays pinned: the switch turns off frame pins
        // only (moving the running bytecodes lets the worker execute a
        // freed block's next contents).
        #expect(rt.vm.stateWord(of: code) == codeBefore)
    }
    rt.vm.terminate(p)
    t.join()
    rt.vm.sweep()
    rt.scavenge()  // applies: the frame pin is cleared
    #expect(!rt.header(a).isFramePinned)
    #expect(rt.keptSum == sparseSum)
    #expect(rt.relocation.framePins >= 1)
    rt.noFailures()
    rt.stop()
}

@Test func aFramePinnedObjectIsNotMoved() throws { try framePin(rule: true) }

@Test func withoutThePinRuleTheFrameObjectIsMoved() throws { try framePin(rule: false) }

// MARK: - hazard slots

/// Worker 1 (on the test thread) holds `a`'s body under hazard slot 0, as
/// the array copy primitive does, while the relocator runs; then it stores
/// through its body offset and releases. Answers whether `a` moved and
/// whether the store is visible through `a`'s entry.
private func hazard(rule: Bool) throws -> (Bool, Bool) {
    let rt = try relocRuntime { $0.testSwitches.hazardRule = rule }
    rt.sparseCycle()
    let a = rt.kept(0)
    let before = rt.vm.stateWord(of: a)
    rt.vm.enter(worker: 1)
    let body = rt.vm.hazardAcquireForTest(worker: 1, slot: 0, a)
    rt.vm.relocate()  // the relocator, on this thread as the marker
    let moved = rt.vm.stateWord(of: a) != before
    rt.image.om.storeSlot(atState: body, 0, Oop(smallInteger: 99).raw)
    rt.vm.hazardReleaseForTest(worker: 1, slot: 0)
    let hazards = rt.vm.relocationCountersNow.skippedHazard
    let pending = rt.vm.pendingBlocksNow
    rt.vm.leave(worker: 1)
    let seen = rt.image.om.load(a, 0) == Oop(smallInteger: 99)
    if rule {
        #expect(hazards == 1)
        #expect(!pending.contains(rt.vm.block(of: a)))
    }
    rt.noFailures()
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

/// The primitive itself: `replaceFrom:to:with:startingAt:` copies a young
/// Pair into an old Array and runs the insertion barrier (its own site).
@Test func theArrayCopyPrimitiveStoresWithItsBarrier() throws {
    let rt = try relocRuntime()
    #expect(rt.runInt("mkSparse:", 4000) == 0)
    rt.scavenge()  // global 8 is old
    let fresh = rt.vm.newArray(1)
    rt.vm.setGlobal(9, fresh)
    #expect(rt.runInt("copyNine") == 0)
    let m = rt.vm.mutatorRelocationCounters(1)
    #expect(m.hazardsTaken == 2 && m.hazardWaits == 0)
    #expect(rt.slot(rt.global(8), 0) == rt.image.nilObject)  // a fresh Array holds nil
    rt.scavenge()  // the remembered-set verifier runs before it
    rt.noFailures()
    rt.stop()
}

// MARK: - epochs

/// Worker 1 is inside the VM (entered, no poll since) while the relocator
/// evacuates blocks. Answers the blocks freed during the pass and those
/// left pending.
private func epochs(rule: Bool) throws -> (UInt64, Int) {
    let rt = try relocRuntime { $0.testSwitches.epochRule = rule }
    rt.sparseCycle()
    rt.vm.enter(worker: 1)
    rt.vm.relocate()
    let freedDuring = rt.vm.relocationCountersNow.freedByEpoch
    let waiting = rt.vm.pendingBlocksNow
    for b in waiting { #expect(rt.vm.isBlockInUseNow(b)) }
    rt.vm.advanceEpoch(worker: 1)  // the worker passes a poll
    rt.vm.freePendingNow()
    #expect(rt.vm.pendingBlocksNow.isEmpty)
    #expect(rt.vm.relocationCountersNow.freedByEpoch == freedDuring + UInt64(waiting.count))
    rt.vm.leave(worker: 1)
    rt.noFailures()
    rt.stop()
    return (freedDuring, waiting.count)
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
    let rt = try relocRuntime()
    rt.sparseCycle()
    rt.vm.enter(worker: 1)
    rt.vm.relocate()
    let waiting = rt.vm.pendingBlocksNow.count
    #expect(waiting >= 2)
    rt.vm.leave(worker: 1)
    rt.scavenge()  // a pause
    #expect(rt.vm.pendingBlocks.isEmpty)
    #expect(rt.relocation.freedAtPause == UInt64(waiting))
    rt.noFailures()
    rt.stop()
}

/// What the entering worker saw in `enterVM`'s window (between its load of
/// the epoch and its store of it): the test hook loads `a`'s body offset
/// there, as a load that overtakes the buffered epoch store would, and lets
/// the relocator run before it goes on.
private final class EnterWindow: @unchecked Sendable {
    let vm: VM
    let a: Oop
    let inWindow = Flag()
    let relocated = Flag()
    let armed = Atomic<Bool>(false)
    let offset = Atomic<UInt64>(0)
    init(vm: VM, a: Oop) { self.vm = vm; self.a = a }
}

private func enterWindow(zero: Bool) throws -> (heldBlockFreed: Bool, inUseAfter: Bool) {
    let rt = try relocRuntime { $0.testSwitches.enterZero = zero }
    rt.sparseCycle()
    let a = rt.kept(0)
    let window = EnterWindow(vm: rt.vm, a: a)
    rt.vm.setEnterWindow({ ctx, worker in
        let w = Unmanaged<EnterWindow>.fromOpaque(ctx!).takeUnretainedValue()
        guard worker == 1, w.armed.exchange(false, ordering: .acquiringAndReleasing) else { return }
        w.offset.store(w.vm.stateWord(of: w.a), ordering: .relaxed)
        w.inWindow.set()
        while !w.relocated.isSet { usleep(100) }
    }, context: Unmanaged.passUnretained(window).toOpaque())
    let block = rt.vm.block(of: a)
    window.armed.store(true, ordering: .releasing)
    let vm = rt.vm
    let t = TestThread {
        vm.enter(worker: 1)  // stops in the window until the relocator ran
        vm.leave(worker: 1)
    }
    #expect(eventually { window.inWindow.isSet })
    rt.vm.relocate()  // moves `a`, evacuates its block, tries to free it
    let freed = !rt.vm.isBlockInUseNow(block)
    window.relocated.set()
    t.join()
    #expect(BlockHeap.block(ofOffset: window.offset.load(ordering: .relaxed)) == block)
    rt.vm.setEnterWindow(nil, context: nil)
    let inUse = rt.vm.isBlockInUseNow(block)
    rt.noFailures()
    rt.stop()
    return (freed, inUse)
}

/// The model's finding 1: without the 0, a relocator that reads the
/// entering worker's epoch word as still quiescent frees a block under an
/// offset the worker already loaded.
@Test func enterVMStoresEpochZeroFirst() throws {
    let (freed, _) = try enterWindow(zero: true)
    #expect(!freed)
}

@Test func withoutTheEpochZeroAtEnterTheBlockIsFreedUnderTheWorker() throws {
    let (freed, _) = try enterWindow(zero: false)
    #expect(freed)
}

// MARK: - verifier

@Test func theVerifierCatchesABodyInAFreedBlock() throws {
    let rt = try relocRuntime()
    rt.sparseCycle()
    // Free a selected block without relocating it: its live objects now
    // lie in a free block.
    let b = try #require(rt.vm.relocationSet.first { $0 == rt.vm.block(of: rt.kept(0)) })
    rt.vm.freeBlockForTest(b)
    rt.scavenge()
    #expect(rt.relocation.verifierFailures > 0)
    #expect(rt.image.om.verifierReports.contains { $0.contains("relocation verifier") && $0.contains("which is free") })
    rt.stop(verifyHeap: false)
}
