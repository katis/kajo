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
    // The counter yields 2000 times on one worker: it was ready at the save.
    if let c = r.process(id: counterId) { #expect(r.result(c) == 2001000) } else { Issue.record("the counter was not resumed") }
    #expect(r.vm.counters[.processesResumed] == 2)
    r.stop()
}
