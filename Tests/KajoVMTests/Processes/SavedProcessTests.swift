// Module 8c: Processes saved in the image (docs/modules/image-processes.md).
// Every round trip runs a program to its end in the VM that saved it and
// again from the saved image in a fresh VM, and both must answer what an
// uninterrupted run answers.

import Darwin
import Foundation
import Testing
@testable import KajoVM

/// The snapshot primitive (142) for kasm programs: `nil snapshot: nil`
/// saves for the host and answers false; the image resumes with true.
let snapshotSrc = """
method UndefinedObject snapshot: temps=0 prim=142
end

"""

/// A VM over an image saved with Processes: loaded (verified) and resumed.
final class Resumed {
    let image: Image
    let vm: VM

    init(_ bytes: [UInt8], background: Int, heapBlocks: Int = 2048, start: Bool = true, stress: StressFlags = [], verify: Bool = true,
         configure: (inout VMConfig) -> Void = { _ in }) throws {
        var vc = VMConfig()
        vc.backgroundWorkers = background
        vc.verifyStops = true
        configure(&vc)
        var c = ObjectMemoryConfig()
        c.heapBytes = heapBlocks * BlockHeap.blockBytes
        c.reserveBytes = vc.nursery.reserveBytes(workers: background + 2)
        c.nurseryRegionBytes = vc.nursery.regionBytes(workers: background + 2)
        c.entryCapacity = 1 << 20
        c.entryChunk = 256
        c.verify = verify
        c.onVerifyFailure = .record
        c.stress = stress
        image = try Image.load(image: bytes, config: c)
        vm = VM(image: image, config: vc)
        if start { vm.start() }
    }

    /// The resumed Process with this id (ids survive the save).
    func process(id: Int64) -> Oop? {
        vm.resumedProcesses.first { p in vm.inspect { $0.load(p, ProcessLayout.id).smallIntegerValue } == id }
    }

    func result(_ p: Oop) -> Int64? {
        let v = vm.result(of: p)
        return v.isSmallInteger ? v.smallIntegerValue : nil
    }

    @discardableResult
    func waitAllTerminated(_ seconds: Double = 60) -> Bool {
        let ok = eventually(seconds) { vm.liveProcessCount == 0 }
        if !ok { Issue.record("\(vm.liveProcessCount) resumed Processes still live") }
        return ok
    }

    func stop() {
        vm.shutdown()
        image.om.retireAllContexts()
        let reports = image.om.verifyHeap() + image.om.verifyFreeLists()
        #expect(reports == [], "\(reports.prefix(3))")
        #expect(image.om.counters.verifierFailures == 0, "\(image.om.verifierReports.prefix(3))")
        vm.destroy()
        image.destroy()
    }
}

func processId(_ rt: Runtime, _ p: Oop) -> Int64 { rt.vm.inspect { $0.load(p, ProcessLayout.id).smallIntegerValue } }

/// One ready Process beside the saver: the saver answers 1 where it saved
/// (snapshot: answered false) and 100 where it resumed (true); the other
/// counts to the same sum in both.
private let oneReadySrc = snapshotSrc + """
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
method UndefinedObject count: temps=2
  push_int 0
  store_temp 1
  push_int 0
  store_temp 2
loop:
  push_temp 2
  push_temp 0
  lt
  jump_if_false done
  push_temp 2
  push_int 1
  add
  store_temp 2
  push_temp 1
  push_temp 2
  add
  store_temp 1
  push_nil
  send yield 0
  pop
  jump loop
done:
  push_temp 1
  return_top
end
"""

@Test func oneReadyProcessRoundTrips() throws {
    // The counter must still be ready when the saver saves; on a loaded
    // machine (the full suite took 109 and 164 s for this test) the saver's
    // thread can be descheduled while the counter yields to its end, and the
    // image then holds the saver alone. Repeat the round (at most five
    // times) until the save caught the counter, never accepting less.
    for attempt in 1...5 {
        let rt = try Runtime(oneReadySrc, background: 1)
        let counter = rt.spawn("count:", [int(2000)])
        let saver = rt.spawn("saver")
        rt.waitAllTerminated()
        #expect(rt.result(saver) == 1)
        #expect(rt.result(counter) == 2001000)
        let images = rt.vm.takeSavedImages()
        #expect(images.count == 1)
        #expect(rt.vm.counters[.snapshots] == 1)
        let saverId = processId(rt, saver), counterId = processId(rt, counter)
        rt.stop()
        guard let bytes = images.first else { return }
        let r = try Resumed(bytes, background: 1)
        #expect(r.vm.resumedSaver != nil)
        r.waitAllTerminated()
        if let s = r.process(id: saverId) { #expect(r.result(s) == 100) } else { Issue.record("the saver was not resumed") }
        guard let c = r.process(id: counterId) else {
            r.stop()
            if attempt == 5 { Issue.record("the counter had ended before the save in five rounds") }
            continue
        }
        // The counter yields 2000 times on one worker: it was ready at the save.
        #expect(r.result(c) == 2001000)
        #expect(r.vm.counters[.processesResumed] == 2)
        r.stop()
        return
    }
}

/// Saved stacks with return markers (a read-only store's discard frame, a
/// non-local return's cascade frame) and a stack grown past 8192 words,
/// each waiting on global 1's Semaphore at the save.
private let shapesSrc = snapshotSrc + """
class Cell Object 1
method Cell x: temps=0
  push_temp 0
  store_ivar 0
  push_int 1
  return_top
end
method Object setReadOnly: temps=0 prim=93
end
method Object modificationForbiddenAt:value: temps=0
  push_nil
  push_int 1
  send globalAt: 1
  send wait 0
  pop
  push_int -5
  return_top
end
method UndefinedObject discarding temps=1
  push_lit @Cell
  send basicNew 0
  store_temp 0
  push_temp 0
  push_true
  send setReadOnly: 1
  pop
  push_temp 0
  push_int 8
  send x: 1
  push_int 10
  add
  return_top
end
class K Object 0
method K make temps=0
  push_closure ret 0
  return_top
block ret args=0 copied=0 temps=0
  push_int 5
  nonlocal_return
end
method BlockClosure cannotReturn: temps=0
  push_nil
  push_int 1
  send globalAt: 1
  send wait 0
  pop
  push_temp 0
  push_int 90
  add
  return_top
end
method UndefinedObject cascading temps=0
  push_lit @K
  send basicNew 0
  send make 0
  value
  push_lit 1000
  add
  return_top
end
method UndefinedObject deep: temps=0
  push_temp 0
  push_int 0
  eq
  jump_if_false more
  push_nil
  push_int 1
  send globalAt: 1
  send wait 0
  pop
  push_int 0
  return_top
more:
  push_nil
  push_temp 0
  push_int 1
  sub
  send deep: 1
  push_temp 0
  add
  return_top
end
method UndefinedObject setup temps=0
  push_nil
  push_int 1
  push_nil
  send newSemaphore 0
  send globalAt:put: 2
  return_top
end
method UndefinedObject twoWaits temps=0
  push_nil
  push_int 1
  send globalAt: 1
  send wait 0
  pop
  push_nil
  push_int 1
  send globalAt: 1
  send wait 0
  pop
  push_int 9
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

/// A discard frame, a cascade frame and a grown stack, waiting at the
/// save, then released: the same answers where it saved and where it
/// resumed (on another worker count).
/// The image of `shapesSrc` with the discard, cascade and grown-stack
/// Processes waiting, and their ids (the fuzz seeds use it too).
func shapesImage() throws -> (bytes: [UInt8], ids: [Int64]) {
    let rt = try Runtime(shapesSrc, background: 1, start: false)
    func run(_ sel: String, _ args: [Oop] = [], priority: Int = Priority.normal) -> Oop {
        let p = rt.spawn(sel, args, priority: priority)
        while rt.vm.runOneSlice(worker: 1) {}
        return p
    }
    _ = run("setup")
    let d = run("discarding"), c = run("cascading"), g = run("deep:", [int(3000)])
    #expect(rt.vm.counters.stackGrowths > 0)
    let s = run("saver", priority: Priority.ui)
    #expect(rt.vm.result(of: s) == Oop(smallInteger: 1))
    let ids = [d, c, g].map { processId(rt, $0) }
    let sem = rt.global(1)
    for _ in 0..<3 { rt.vm.signal(sem) }
    while rt.vm.runOneSlice(worker: 1) {}
    #expect([d, c, g].map { rt.result($0) } == [11, 1095, 4501500])
    let images = rt.vm.takeSavedImages()
    rt.stop()
    return (try #require(images.first), ids)
}

/// A discard frame, a cascade frame and a grown stack, waiting at the
/// save, then released: the same answers where it saved and where it
/// resumed (on another worker count).
@Test func markedFramesAndAGrownStackRoundTrip() throws {
    let (bytes, ids) = try shapesImage()
    let r = try Resumed(bytes, background: 3)
    let rsem = r.vm.global(1)
    for _ in 0..<3 { r.vm.signal(rsem) }
    r.waitAllTerminated()
    #expect(ids.map { r.process(id: $0).flatMap(r.result) } == [11, 1095, 4501500])
    r.stop()
}

/// Ready at every priority and affinity: the order they run in after the
/// resume is the order they would have run in.
@Test func readyQueuesKeepPriorityAffinityAndFIFO() throws {
    let src = logSrc + snapshotSrc + """
    method UndefinedObject tag: temps=0
      push_nil
      push_temp 0
      send log: 1
      return_top
    end
    method UndefinedObject saver temps=0
      push_nil
      push_nil
      send snapshot: 1
      pop
      push_int 1
      return_top
    end
    """
    let rt = try Runtime(src, background: 1, start: false)
    _ = rt.spawn("makeLog:", [int(16)])
    while rt.vm.runOneSlice(worker: 1) {}
    _ = rt.spawn("saver", priority: Priority.ui)
    let tags: [(Int, Int, Bool)] = [(1, 1, false), (2, 0, false), (3, 2, false), (4, 1, false), (5, 1, true), (6, 2, true),
                                    (7, 0, true)]
    for (t, prio, main) in tags { _ = rt.spawn("tag:", [int(Int64(t))], priority: prio, main: main) }
    func drain(_ vm: VM) {
        while vm.runOneSlice(worker: 1) {}
        while vm.runMain(budgetNs: 50_000_000).slices > 0 {}
    }
    drain(rt.vm)
    let order = logValues(rt)
    #expect(order == [3, 1, 4, 2, 6, 5, 7])
    let images = rt.vm.takeSavedImages()
    rt.stop()
    guard let bytes = images.first else { Issue.record("no image"); return }
    let r = try Resumed(bytes, background: 1, start: false)
    #expect(r.vm.resumedProcesses.count == 8)
    drain(r.vm)
    let resumedOrder = r.vm.inspect { om -> [Int64] in
        let arr = om.load(r.image.globals, 2)
        let n = Int(om.load(r.image.globals, 3).smallIntegerValue)
        return (0..<n).map { om.load(arr, $0).smallIntegerValue }
    }
    #expect(resumedOrder == order)
    r.stop()
}

/// A Semaphore's excess signals are heap state: two saved, two waits pass.
@Test func excessSignalsSurviveTheSave() throws {
    let rt = try Runtime(shapesSrc, background: 1, start: false)
    _ = rt.spawn("setup")
    while rt.vm.runOneSlice(worker: 1) {}
    rt.vm.signal(rt.global(1))
    rt.vm.signal(rt.global(1))
    _ = rt.spawn("saver")
    while rt.vm.runOneSlice(worker: 1) {}
    let images = rt.vm.takeSavedImages()
    rt.stop()
    let r = try Resumed(try #require(images.first), background: 1)
    #expect(r.vm.excessSignals(r.vm.global(1)) == 2)
    let p = try #require(r.vm.spawn(receiver: r.image.nilObject, selector: "twoWaits"))
    r.waitAllTerminated()
    #expect(r.result(p) == 9)
    r.stop()
}

/// The review fixes, part 2, item 19: a Process saved while it waits gets
/// its `wait` send's length at load, as a live waiter has it, so its debug
/// stop rewinds to the send (part 1's item 3); the three waiters of
/// `shapesImage` each stand after a `send wait 0` of three bytes. On
/// 18e274f a loaded waiter had none (0).
@Test func aLoadedWaiterKnowsTheLengthOfItsWaitSend() throws {
    let (bytes, ids) = try shapesImage()
    let r = try Resumed(bytes, background: 1)
    for id in ids {
        let p = try #require(r.process(id: id))
        #expect(r.vm.waitSendLength(of: p) == 3, "Process \(id)")
    }
    for _ in 0..<3 { r.vm.signal(r.vm.global(1)) }
    r.waitAllTerminated()
    r.stop()
}
