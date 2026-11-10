// The review fixes, item 14 (kernel.F12): critical: on a Semaphore and a
// Mutex keeps its lock whenever its Process is terminated, driven slice by
// slice on one worker so the cases are exact: a Process waiting in
// critical: and terminated there gives nothing back, and one that a
// signal released and that is terminated before it runs again gives the
// signal back.

import Foundation
import Testing
@testable import KajoCompiler
@testable import KajoVM

private let criticalDirectory: String = {
    var url = URL(fileURLWithPath: #filePath)
    url.deleteLastPathComponent()
    return url.appendingPathComponent("Fixtures/critical").path
}()

private let criticalImage: [UInt8] = {
    try! KernelBuild.build(KernelBuild.sources(in: [kernelDirectory, criticalDirectory])).image
}()

private final class Stepped {
    let img: Image
    let vm: VM
    let cls: Oop

    init() throws {
        var o = Headless.Options()
        o.heapMiB = 256
        o.workers = 2
        let (vc, c) = try Headless.configs(o).get()
        var oc = c
        oc.onVerifyFailure = .record
        img = try Image.load(image: criticalImage, config: oc)
        vm = VM(image: img, config: vc)
        cls = img.om.classOop(img.classIndex(named: "CriticalProbe")!)
    }

    /// Spawn `CriticalProbe selector` (not run yet).
    func spawn(_ selector: String) throws -> Oop { try #require(vm.spawn(receiver: cls, selector: selector)) }

    /// Run slices on worker 1 until nothing is ready (bounded).
    func settle() {
        for _ in 0..<10_000 where vm.runOneSlice(worker: 1) {}
    }

    /// `CriticalProbe selector` run to its end: its SmallInteger answer.
    func answer(_ selector: String) throws -> Int64? {
        let p = try spawn(selector)
        settle()
        #expect(vm.state(of: p) == .terminated)
        defer { vm.release(p) }
        let v = vm.result(of: p)
        return v.isSmallInteger ? v.smallIntegerValue : nil
    }

    func end() {
        vm.terminateAll()
        settle()
        #expect(img.om.counters.verifierFailures == 0)
        vm.destroy()
        img.destroy()
    }
}

@Suite(.serialized) struct ReviewFixesKernelTests {
    /// Terminated while it waits in critical: (the VM unlinks it): no
    /// signal comes back, the test's release leaves the one signal.
    @Test func aProcessTerminatedWhileItWaitsInCriticalGivesNothingBack() throws {
        let t = try Stepped()
        #expect(try t.answer("setUp") == 0)
        let p = try t.spawn("enter")
        t.settle()
        #expect(t.vm.state(of: p) == .waiting)
        #expect(t.vm.interruptProcess(p, kind: 1))
        t.settle()
        #expect(t.vm.state(of: p) == .terminated)
        #expect(try t.answer("release") == 0)
        #expect(try t.answer("excess") == 1)
        #expect(try t.answer("entered") == 0)
        t.vm.release(p)
        t.end()
    }

    /// Released by a signal and terminated before it runs again: it holds
    /// the Semaphore, so its ensure block gives the signal back. On
    /// d78afcc the terminate unwound from right after the wait, before
    /// critical: entered its ensure:, and the signal was lost for good.
    @Test(arguments: ["enter", "enterMutex"])
    func aProcessTerminatedAfterTheSignalGivesItBack(_ selector: String) throws {
        let t = try Stepped()
        #expect(try t.answer("setUp") == 0)
        let p = try t.spawn(selector)
        t.settle()
        #expect(t.vm.state(of: p) == .waiting)
        // One slice: the releasing Process signals and ends; P is ready
        // and has not run.
        let r = try t.spawn(selector == "enter" ? "release" : "releaseMutex")
        #expect(t.vm.runOneSlice(worker: 1))
        #expect(t.vm.state(of: r) == .terminated)
        t.vm.release(r)
        #expect(t.vm.state(of: p) == .ready)
        #expect(t.vm.interruptProcess(p, kind: 1))
        t.settle()
        #expect(t.vm.state(of: p) == .terminated)
        #expect(try t.answer(selector == "enter" ? "excess" : "mutexExcess") == 1)
        t.vm.release(p)
        t.end()
    }
}
