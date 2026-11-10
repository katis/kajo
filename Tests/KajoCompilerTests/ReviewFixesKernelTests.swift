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

#if os(macOS)
import KajoApp

/// The review fixes, item 12 (tools.F1): a view's geometry set to a huge
/// or non-finite value reads back without trapping. AppKit keeps a view's
/// frame within 2^45 (a width of 1.0e20 reads back 35 184 372 088 832, an
/// integer), so the report's trap is not reached through an NSView, but a
/// non-finite one raised AppKit's exception at set (the test process died
/// on it), so geometry arguments must be finite now; the
/// conversion itself (`geometryValue`) is what a UIView or a window
/// reaches, checked at its edges: on d78afcc `Int64(d)` trapped for any
/// integral |d| >= 2^63 and for infinity.
@MainActor @Test func aHugeGeometryReadsBackWithoutATrap() throws {
    let host = AppKitHost(statusWindow: false, keepDisplayAwake: false)
    let h = try #require(host.viewCall(ViewCall(op: "create", handle: 0, arguments: [.string("view")]))?.int)
    for (k, v) in [("width", 1.0e20), ("x", -3.0e19), ("height", Double.infinity), ("y", -Double.infinity), ("width", Double.nan)] {
        let set = host.viewCall(ViewCall(op: "set", handle: Int(h), arguments: [.string(k), .double(v)]))
        #expect(v.isFinite ? set != nil : set == nil, "\(k) := \(v) answered \(String(describing: set))")
        let back = host.viewCall(ViewCall(op: "get", handle: Int(h), arguments: [.string(k)]))
        #expect(back?.double != nil, "\(k) := \(v) read back as \(String(describing: back))")
    }
    _ = host.viewCall(ViewCall(op: "set", handle: Int(h), arguments: [.string("height"), .int(40)]))
    #expect(host.viewCall(ViewCall(op: "get", handle: Int(h), arguments: [.string("height")])) == .int(40))
    #expect(geometryValue(1.0e20) == .double(1.0e20))
    #expect(geometryValue(-9.3e18) == .double(-9.3e18))
    #expect(geometryValue(.infinity) == .double(.infinity))
    #expect(geometryValue(-.infinity) == .double(-.infinity))
    if case .double(let d) = geometryValue(.nan) { #expect(d.isNaN) } else { Issue.record("NaN as an integer") }
    #expect(geometryValue(9_007_199_254_740_992) == .double(9_007_199_254_740_992))
    #expect(geometryValue(9_007_199_254_740_991) == .int(9_007_199_254_740_991))
    #expect(geometryValue(-12) == .int(-12))
    #expect(geometryValue(2.5) == .double(2.5))
    _ = host.viewCall(ViewCall(op: "release", handle: Int(h), arguments: []))
}
#endif
