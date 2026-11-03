// Module 8c: the image loader as a trust boundary for saved Processes
// (docs/modules/image-processes.md "The loader's rules"). A valid image
// with Processes in every saved form (waiting on a Semaphore, a live
// Context in a method frame below a block frame, never run, the saver) is
// loaded, one rule's subject is changed in the heap, and the re-encoded
// image must be refused with that rule's message.

import Foundation
import Testing
@testable import KajoVM

/// Two waiters on global 1's Semaphore, a holder (thisContext in temp 0,
/// waiting inside a block), a Process that has never run, and the saver.
let loaderBaseSrc = snapshotSrc + """
method UndefinedObject setup temps=0
  push_nil
  push_int 1
  push_nil
  send newSemaphore 0
  send globalAt:put: 2
  return_top
end
method UndefinedObject waiter temps=0
  push_nil
  push_int 1
  send globalAt: 1
  send wait 0
  pop
  push_int 7
  return_top
end
method UndefinedObject holder temps=1
  push_this_context
  store_temp 0
  push_closure blk 0
  value
  pop
  push_int 11
  return_top
block blk args=0 copied=0 temps=0
  push_nil
  push_int 1
  send globalAt: 1
  send wait 0
  block_return
end
method UndefinedObject neverRun: temps=0
  push_temp 0
  return_top
end
method UndefinedObject saver temps=0
  push_nil
  push_nil
  send snapshot: 1
  jump_if_false here
  push_int 100
  return_top
here:
  push_int 1
  return_top
end
"""

/// The base image and the ids of its Processes.
struct LoaderBase {
    let bytes: [UInt8]
    let waiter: Int64, waiter2: Int64, holder: Int64, neverRun: Int64, saver: Int64
}

/// Built once: one worker driven from the test thread, so every Process is
/// where the test put it when the saver saves.
let loaderBase: LoaderBase = {
    let rt = try! Runtime(loaderBaseSrc, background: 1, start: false)
    func run(_ sel: String, _ args: [Oop] = [], priority: Int = Priority.normal) -> Oop {
        let p = rt.spawn(sel, args, priority: priority)
        _ = rt.vm.runOneSlice(worker: 1)
        return p
    }
    _ = run("setup")
    let w1 = run("waiter"), h = run("holder"), w2 = run("waiter")
    let n = rt.spawn("neverRun:", [int(5)])
    let s = run("saver", priority: Priority.ui)
    precondition(rt.vm.state(of: s) == .terminated && rt.vm.result(of: s) == Oop(smallInteger: 1))
    let images = rt.vm.takeSavedImages()
    precondition(images.count == 1)
    let base = LoaderBase(bytes: images[0], waiter: processId(rt, w1), waiter2: processId(rt, w2), holder: processId(rt, h),
                          neverRun: processId(rt, n), saver: processId(rt, s))
    rt.stop(verifyHeap: false)
    return base
}()

func loaderConfig() -> ObjectMemoryConfig {
    var c = ObjectMemoryConfig()
    c.heapBytes = 2048 * BlockHeap.blockBytes
    c.entryCapacity = 1 << 20
    c.entryChunk = 256
    c.verify = true
    c.onVerifyFailure = .trap
    return c
}

/// A loaded image with saved Processes, read and changed through its heap.
struct SavedView {
    let img: Image
    var om: ObjectMemory { img.om }
    var nilObj: Oop { img.nilObject }
    var state: Oop { img.savedScheduler }

    var pairs: [(p: Oop, stack: Oop)] {
        let list = om.load(state, SavedScheduler.processes)
        var out: [(Oop, Oop)] = []
        for c in 0..<Int(om.count(of: list)) {
            let lc = om.load(list, c)
            for k in 0..<Int(om.count(of: lc) / 2) { out.append((om.load(lc, 2 * k), om.load(lc, 2 * k + 1))) }
        }
        return out
    }

    func process(_ id: Int64) -> Oop { pairs.first { om.load($0.p, ProcessLayout.id) == Oop(smallInteger: id) }!.p }
    func stack(_ p: Oop) -> Oop { pairs.first { $0.p == p }!.stack }
    func slot(_ p: Oop, _ i: Int) -> Int { Int(om.load(p, i).smallIntegerValue) }
    func setSlot(_ p: Oop, _ i: Int, _ v: Oop) { om.store(p, i, v) }
    func setInt(_ p: Oop, _ i: Int, _ v: Int) { om.store(p, i, Oop(smallInteger: Int64(v))) }
    func word(_ p: Oop, _ i: Int) -> Oop {
        om.load(om.load(stack(p), i / SavedScheduler.chunkWords), i % SavedScheduler.chunkWords)
    }
    func setWord(_ p: Oop, _ i: Int, _ v: Oop) {
        om.store(om.load(stack(p), i / SavedScheduler.chunkWords), i % SavedScheduler.chunkWords, v)
    }
    func semaphore() -> Oop { om.load(img.globals, 0) }
    /// A new sp, the stack's one chunk rebuilt to fit it (nil past the old top).
    func setSp(_ p: Oop, _ sp: Int) {
        let old = slot(p, ProcessLayout.sp)
        let ch = newArray(sp + 1)
        for i in 0...min(sp, old) { om.store(ch, i, word(p, i)) }
        om.store(stack(p), 0, ch)
        setInt(p, ProcessLayout.sp, sp)
    }
    func newArray(_ n: Int) -> Oop {
        let a = om.allocate(img.context, classIndex: WellKnown.array, slots: n, fill: nilObj, extraRoots: [])!
        return a
    }
    /// The image again, its heap as changed (no collection: nothing is lost).
    func encoded() -> [UInt8] { img.encodedImage(snapshot: om.snapshot()) }
}

enum SavedCorruption: String, CaseIterable {
    case stateRunning, priorityOutOfRange, recordNotMinusOne, registersNotIntegers, fpAboveHdr
    case frameMethodNotAMethod, fpDisagreesWithTheMethod, pcInsideAnInstruction, depthDisagrees, callerPcDisagrees
    case blockWithoutItsClosure, receiverOfAnotherClass, contextNamesAnotherFrame, contextOfAnotherProcess
    case liveContextNamedNowhere, markerOutOfRange, waitingOnNothing, waiterListCycle, processInTwoLists
    case readyInTheWrongQueue, queueTailNotTheLast, excessSignalsWithWaiters, stackChunkTooShort
    case finalizationNotASemaphore, saverWithoutTrue, liveProcessNotSaved, duplicateId, neverRunArgcDisagrees
    case bottomFrameLinks, schedulerStateWrongSize, nextIdTooSmall, callerLinksNotIntegers, liveProcessWithResult

    /// A word of the message the loader must give.
    var expected: String {
        switch self {
        case .stateRunning: "saved with state"
        case .priorityOutOfRange: "priority or affinity"
        case .recordNotMinusOne: "record is not -1"
        case .registersNotIntegers: "registers are not SmallIntegers"
        case .fpAboveHdr: "registers (sp"
        case .frameMethodNotAMethod: "not in the method table"
        case .fpDisagreesWithTheMethod: "its method says"
        case .pcInsideAnInstruction, .depthDisagrees: "traced"
        case .callerPcDisagrees: "caller pc"
        case .blockWithoutItsClosure: "without its closure"
        case .receiverOfAnotherClass: "receiver does not fit"
        case .contextNamesAnotherFrame, .contextOfAnotherProcess: "Context does not name it"
        case .liveContextNamedNowhere: "no saved frame names"
        case .markerOutOfRange: "return marker"
        case .waitingOnNothing: "waits on no Semaphore"
        case .waiterListCycle: "two lists, or a cycle"
        case .processInTwoLists: "two lists, or a cycle"
        case .readyInTheWrongQueue: "another state, priority or affinity"
        case .queueTailNotTheLast: "tail is not the last"
        case .excessSignalsWithWaiters: "waiters and excess signals"
        case .stackChunkTooShort: "stack chunk"
        case .finalizationNotASemaphore: "finalization Semaphore"
        case .saverWithoutTrue: "resume after a send with true"
        case .liveProcessNotSaved: "but not saved"
        case .duplicateId: "id (unique"
        case .neverRunArgcDisagrees: "first method takes"
        case .bottomFrameLinks: "bottom frame"
        case .schedulerStateWrongSize: "scheduler state is not an Array"
        case .nextIdTooSmall: "id (unique"
        case .callerLinksNotIntegers: "caller links are not SmallIntegers"
        case .liveProcessWithResult: "has a result"
        }
    }
}

func corruptSaved(_ c: SavedCorruption) throws -> [UInt8] {
    let img = try Image.load(image: loaderBase.bytes, config: loaderConfig())
    defer { img.destroy() }
    let v = SavedView(img: img)
    let om = v.om
    let w1 = v.process(loaderBase.waiter), w2 = v.process(loaderBase.waiter2)
    let h = v.process(loaderBase.holder), n = v.process(loaderBase.neverRun), s = v.process(loaderBase.saver)
    let hHdr = v.slot(h, ProcessLayout.hdr)  // the block frame
    let hFp = v.slot(h, ProcessLayout.fp)
    let callerHdr = Int(v.word(h, hHdr + Frame.callerHdr).smallIntegerValue)  // the holder's method frame
    let ctx = v.word(h, callerHdr + Frame.context)
    precondition(ctx.isObject && om.classIndex(of: ctx) == WellKnown.context, "the holder's frame has its Context")
    switch c {
    case .stateRunning: v.setInt(w1, ProcessLayout.state, 1)
    case .priorityOutOfRange: v.setInt(n, ProcessLayout.priority, 5)
    case .recordNotMinusOne: v.setInt(w1, ProcessLayout.record, 0)
    case .registersNotIntegers: v.setSlot(h, ProcessLayout.fp, v.nilObj)
    case .fpAboveHdr: v.setInt(h, ProcessLayout.fp, hHdr + 1)
    case .frameMethodNotAMethod: v.setWord(h, hHdr + Frame.method, v.nilObj)
    case .fpDisagreesWithTheMethod: v.setInt(h, ProcessLayout.fp, hFp - 1)
    case .pcInsideAnInstruction: v.setInt(h, ProcessLayout.pc, v.slot(h, ProcessLayout.pc) - 1)
    case .depthDisagrees: v.setSp(h, v.slot(h, ProcessLayout.sp) - 1)
    case .callerPcDisagrees:
        // After the `value`'s pop: no operand where the answer goes.
        v.setWord(h, hHdr + Frame.callerPC, Oop(smallInteger: v.word(h, hHdr + Frame.callerPC).smallIntegerValue + 1))
    case .blockWithoutItsClosure: v.setWord(h, hHdr - 1, v.nilObj)
    case .receiverOfAnotherClass: v.setWord(w1, v.slot(w1, ProcessLayout.fp), Oop(smallInteger: 3))
    case .contextNamesAnotherFrame: om.store(ctx, ContextLayout.frame, Oop(smallInteger: Int64(hHdr)))
    case .contextOfAnotherProcess: om.store(ctx, ContextLayout.process, w1)
    case .liveContextNamedNowhere:
        v.setWord(h, callerHdr + Frame.context, Oop(smallInteger: 0))  // the frame forgets it; the Context stays live
        om.addRoot(ctx)
    case .markerOutOfRange: v.setWord(h, hHdr + Frame.context, Oop(smallInteger: 7))
    case .waitingOnNothing: v.setSlot(w2, ProcessLayout.waitingOn, v.nilObj)
    case .waiterListCycle: v.setSlot(w2, ProcessLayout.next, w1)
    case .processInTwoLists:
        // The never-run Process also last in the Semaphore's waiters.
        v.setSlot(w2, ProcessLayout.next, n)
        om.store(v.semaphore(), SemaphoreLayout.lastWaiter, n)
    case .readyInTheWrongQueue: v.setInt(n, ProcessLayout.priority, 0)
    case .queueTailNotTheLast:
        let q = om.load(v.state, SavedScheduler.queues)
        let tailAt = Priority.count * Affinity.count + queueIndex(main: false, priority: Priority.normal)
        om.store(q, tailAt, s)  // the never-run Process is the last
    case .excessSignalsWithWaiters: om.store(v.semaphore(), SemaphoreLayout.excessSignals, Oop(smallInteger: 2))
    case .stackChunkTooShort:
        let st = v.stack(h)
        om.store(st, 0, v.newArray(3))
    case .finalizationNotASemaphore: om.store(v.state, SavedScheduler.finalization, v.newArray(1))
    case .saverWithoutTrue: v.setWord(s, v.slot(s, ProcessLayout.sp), img.falseObject)
    case .liveProcessNotSaved:
        // Drop the never-run Process's pair (nothing links to it but its
        // queue's head word, read after every Process is checked).
        let list = om.load(v.state, SavedScheduler.processes)
        let lc = om.load(list, 0)
        let k = Int(om.count(of: lc))
        let shorter = v.newArray(k - 2)
        var j = 0
        for i in stride(from: 0, to: k, by: 2) where om.load(lc, i) != n {
            om.store(shorter, j, om.load(lc, i))
            om.store(shorter, j + 1, om.load(lc, i + 1))
            j += 2
        }
        om.store(list, 0, shorter)
    case .duplicateId: om.store(w2, ProcessLayout.id, om.load(w1, ProcessLayout.id))
    case .neverRunArgcDisagrees:
        // One more word on the stack (sp 3) than the method's argument.
        v.setSp(n, 3)
    case .bottomFrameLinks:
        // The holder's method frame is its bottom frame.
        v.setWord(h, callerHdr + Frame.callerHdr, Oop(smallInteger: 1))
    case .schedulerStateWrongSize:
        let a = v.newArray(SavedScheduler.size + 1)
        for i in 0..<SavedScheduler.size { om.store(a, i, om.load(v.state, i)) }
        om.store(img.specialObjects, SpecialObjects.scheduler, a)
    case .nextIdTooSmall: om.store(v.state, SavedScheduler.nextId, Oop(smallInteger: 2))
    case .callerLinksNotIntegers: v.setWord(h, hHdr + Frame.callerFP, v.nilObj)
    case .liveProcessWithResult: v.setSlot(n, ProcessLayout.result, Oop(smallInteger: 1))
    }
    return v.encoded()
}

@Test func theBaseImageLoadsAndResumes() throws {
    let r = try Resumed(loaderBase.bytes, background: 2)
    #expect(r.vm.resumedProcesses.count == 5)
    let sem = r.vm.global(1)
    for _ in 0..<3 { r.vm.signal(sem) }
    r.waitAllTerminated()
    let results = [loaderBase.waiter, loaderBase.waiter2, loaderBase.holder, loaderBase.neverRun, loaderBase.saver]
        .map { r.process(id: $0).flatMap { r.result($0) } }
    #expect(results == [7, 7, 11, 5, 100])
    r.stop()
}

@Test(arguments: SavedCorruption.allCases)
func theLoaderRefusesASavedProcess(_ c: SavedCorruption) throws {
    let b = try corruptSaved(c)
    do {
        try Image.load(image: b, config: loaderConfig()).destroy()
        Issue.record("\(c.rawValue) loaded")
    } catch {
        print("saved-Process corruption \(c.rawValue): \(error)")
        #expect("\(error)".contains(c.expected), "\(c.rawValue): \(error)")
    }
}

/// The base image re-encoded without a change loads: the corruptions are
/// refused for their change, not for the re-encoding.
@Test func theBaseImageReencodedLoads() throws {
    let img = try Image.load(image: loaderBase.bytes, config: loaderConfig())
    let b = SavedView(img: img).encoded()
    img.destroy()
    try Image.load(image: b, config: loaderConfig()).destroy()
}

/// Seeded mutations of an image with saved Processes: each loads cleanly
/// (and a VM installs its Processes) or is refused; nothing traps.
@Test func mutatedSavedProcessImagesLoadCleanOrAreRejected() throws {
    var g = SplitMix(seed: 23)
    var loaded = 0, rejected = 0
    for _ in 0..<300 {
        var b = loaderBase.bytes
        for _ in 0..<(1 + Int(g.next() % 3)) {
            let k = Int(g.next() % UInt64(b.count))
            b[k] ^= UInt8(truncatingIfNeeded: 1 << (g.next() % 8))
        }
        if FuzzEntry.image(b) { loaded += 1 } else { rejected += 1 }
    }
    #expect(rejected > 0 && loaded + rejected == 300)
}

/// The snapshot fuzzer's seeds with saved Processes
/// (`Fixtures/fuzz/snapshot/saved-*.img`): Processes waiting, never run,
/// with a live Context and a block frame, the saver; marked frames and a
/// grown stack. Each loads through the fuzz entry, which installs them in
/// a VM. `KAJO_WRITE_FUZZ_SEEDS=1` writes them.
@Test func savedProcessFuzzSeedsLoadThroughTheFuzzEntry() throws {
    let seeds: [(String, [UInt8])] = [("saved-states", loaderBase.bytes), ("saved-shapes", try shapesImage().bytes)]
    for (name, b) in seeds {
        #expect(FuzzEntry.image(b), "\(name)")
        let url = URL(fileURLWithPath: "\(fixturesDir)/fuzz/snapshot/\(name).img")
        if ProcessInfo.processInfo.environment["KAJO_WRITE_FUZZ_SEEDS"] != nil { try Data(b).write(to: url) }
        if let d = try? Data(contentsOf: url) { #expect(FuzzEntry.image([UInt8](d)), "\(name) fixture") }
    }
}
