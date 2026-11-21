// The verifier's faults (docs/modules/verifier-faults.md), fault 1: the
// make primitive (143) makes a method's literal frame in old space, and a
// literal it takes as it is (an instance of an ordinary class, a Binding, a
// collection) may be young. The frame must then be remembered
// for that object's nursery, or a scavenge frees the object under the
// method. Every heap verifier runs, failures recorded, not trapped.

import Darwin
import Foundation
import Testing
@testable import KajoCompiler
@testable import KajoVM

private let verifierFaultsDirectory: String = {
    var url = URL(fileURLWithPath: #filePath)
    url.deleteLastPathComponent()
    return url.appendingPathComponent("Fixtures/verifier-faults").path
}()

private let makeYoungImage: [UInt8] = {
    try! KernelBuild.build(KernelBuild.sources(in: [kernelDirectory, verifierFaultsDirectory])).image
}()

/// The image driven slice by slice on worker 1 (so its Processes allocate
/// in nursery 1), the verifiers on in any build, their failures recorded.
private final class MakeYoungRun {
    let img: Image
    let vm: VM
    let cls: Oop

    init(skipBarrierAt site: BarrierSite? = nil) throws {
        var o = Headless.Options()
        o.heapMiB = 256
        o.workers = 2
        o.verify = .all
        let (c0, c) = try Headless.configs(o).get()
        var vc = c0
        vc.nursery.testSwitches.skipBarrierAt = site
        var oc = c
        oc.onVerifyFailure = .record
        img = try Image.load(image: makeYoungImage, config: oc)
        vm = VM(image: img, config: vc)
        cls = img.om.classOop(img.classIndex(named: "MakeYoungProbe")!)
    }

    /// `MakeYoungProbe selector args` run to its end on worker 1: its
    /// SmallInteger answer.
    func answer(_ selector: String, _ args: [Int64] = []) throws -> Int64? {
        let p = try #require(vm.spawn(receiver: cls, selector: selector, arguments: args.map { Oop(smallInteger: $0) }))
        for _ in 0..<100_000 where vm.runOneSlice(worker: 1) {}
        #expect(vm.state(of: p) == .terminated, "\(selector) did not end")
        defer { vm.release(p) }
        let v = vm.result(of: p)
        return v.isSmallInteger ? v.smallIntegerValue : nil
    }

    var failures: UInt64 { img.om.counters.verifierFailures }
    var runs: UInt64 { img.om.counters.verifierRuns }
    var reports: [String] { img.om.verifierReports }

    func end() {
        vm.terminateAll()
        for _ in 0..<10_000 where vm.runOneSlice(worker: 1) {}
        vm.destroy()
        img.destroy()
    }
}

/// The objects the make primitive takes as they are and that may be young
/// (part 1's table, docs/modules/verifier-faults.md): 1 an instance of an
/// ordinary class, 2 a Binding, 3 an OrderedCollection, 4 a Set.
/// Made into a method that alone names it, then two scavenges: no
/// remembered-set failure, and the method still answers the object. On
/// 07fcad1 the first scavenge's verifier fails ("nursery verifier, before
/// scavenge 1: entry E (old) names young @Y (nursery 1) in slot 0, and is
/// not remembered for it [holder: Array ..., read-only, pinned ...]").
@Suite(.serialized) struct MakeYoungLiteralTests {
    @Test(arguments: [Int64(1), 2, 3, 4])
    func aMadeMethodsYoungLiteralIsRememberedAndSurvivesAScavenge(_ kind: Int64) throws {
        let t = try MakeYoungRun()
        defer { t.end() }
        let made = try t.answer("make:", [kind])
        #expect(made == 1, "kind \(kind): the VM refused the method (\(String(describing: made)))")
        t.vm.scavenge()
        t.vm.scavenge()
        #expect(t.runs > 0)
        #expect(t.failures == 0, "kind \(kind): \(t.reports.prefix(2))")
        // Only when nothing failed: a freed entry read through the method
        // is undefined, not a failing check.
        if t.failures == 0 { #expect(try t.answer("check:", [kind]) == 1, "kind \(kind)") }
    }

    /// A closure is an instance of a sealed class: refused, never made.
    @Test func aClosureLiteralIsRefused() throws {
        let t = try MakeYoungRun()
        defer { t.end() }
        #expect(try t.answer("make:", [5]) == -1)
    }

    /// The fix taken out by its test switch (the barrier skipped at the
    /// make primitive's literal frame): the verifier names the frame. Run
    /// in the suite because the broken variant fails a verifier, not a trap.
    @Test func withoutTheBarrierTheVerifierNamesTheLiteralFrame() throws {
        let t = try MakeYoungRun(skipBarrierAt: .methodLiteral)
        defer { t.end() }
        #expect(try t.answer("make:", [1]) == 1)
        t.vm.scavenge()
        print("verifier-faults broken methodLiteral: failures=\(t.failures) \(t.reports.first ?? "-")")
        #expect(t.failures > 0, "the broken variant passed the verifier")
        #expect(t.reports.first?.contains("is not remembered for it [holder: Array") == true, "\(t.reports.prefix(1))")
    }

    /// Starting position 2: the compiler alone (a class variable added
    /// live, its Binding made in Smalltalk and compiled into a method) puts
    /// no young object in an old frame: the redefinition promotes everything
    /// before it makes the methods. Passes on 07fcad1 as on the head.
    @Test func aClassVariableAddedLiveLeavesNoYoungLiteral() throws {
        let t = try MakeYoungRun()
        defer { t.end() }
        #expect(try t.answer("liveClassVariable") == 0)
        t.vm.scavenge()
        #expect(try t.answer("liveClassVariableCheck") == 1)
        t.vm.scavenge()
        #expect(t.runs > 0)
        #expect(t.failures == 0, "\(t.reports.prefix(2))")
    }
}
