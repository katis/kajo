// Collectors review, finding 5, through the redefine primitive (146): a
// redefinition while dead young instances of the class exist and while a
// lazy sweep that frees a dead old instance is pending. The primitive runs
// module 4's hook (promote-all, the sweep applied) before it lists the
// instances, so neither is reshaped; module 1's own reshape now does the
// same (ReshapeOrderTests).

import Foundation
import Testing
@testable import KajoCompiler
@testable import KajoVM

private let redefineFiles: [(file: String, text: [UInt8])] = miniKernel + [objectExtras,
    tonel("Binding", ivars: ["key", "value"], ""),
    tonel("R", classIvars: ["cls", "objs", "spare"], """
    R class >> redefine: spec [
        <primitive: 146>
        ^ nil
    ]
    R class >> primDefine: spec [
        <primitive: 145>
        ^ nil
    ]
    R class >> setUp [
        | r |
        r := self primDefine: {#Point3. Object. #(#x #y). #(). #(). #fixed. nil. 0. 0}.
        r class == String ifTrue: [^ -1].
        cls := r.
        objs := Array new: 3.
        1 to: 3 do: [:i | | o | o := cls basicNew. o instVarAt: 1 put: i. o instVarAt: 2 put: i * 10. objs at: i put: o].
        spare := cls basicNew.
        ^ 1
    ]
    R class >> dropSpare [
        spare := nil.
        ^ 1
    ]
    R class >> garbageThenRedefine [
        cls basicNew.
        cls basicNew.
        (self redefine: {{{cls. 3. #(0 2 1)}}. {}. {}. nil}) == nil ifFalse: [^ -1].
        ^ 1
    ]
    """),
]

@Test func aRedefinitionWithDeadYoungInstancesAndAPendingSweepReshapesOnlyTheLiveOnes() throws {
    var o = KernelBuild.Options()
    o.initialize = false
    o.heapMiB = 64
    let built = try KernelBuild.build(redefineFiles, options: o)
    let image = try Image.load(image: built.image)
    defer { image.destroy() }
    var vc = VMConfig()
    vc.backgroundWorkers = 1
    vc.marking.enabled = true
    vc.marking.markerThread = false
    vc.young.mode = .stw
    vc.verifyStops = true
    let vm = VM(image: image, config: vc)
    vm.start()
    defer { vm.shutdown(); vm.destroy() }
    let r = try #require(image.classIndex(named: "R"))
    func run(_ selector: String) throws -> Int64 {
        let p = try #require(vm.spawn(receiver: image.om.classOop(r), selector: selector))
        vm.waitUntilAllTerminated()
        if let e = vm.error(of: p) { Issue.record("\(selector): \(e)") }
        let v = vm.result(of: p)
        vm.release(p)
        return v.isSmallInteger ? v.smallIntegerValue : -99
    }
    #expect(try run("setUp") == 1)
    vm.collect()  // everything old
    #expect(try run("dropSpare") == 1)
    // A cycle whose sweep frees the spare, left pending (not applied).
    vm.startCycle()
    _ = vm.markStep(10_000_000)
    vm.finalMark()
    vm.sweep()
    #expect(vm.markingPhase == .swept)
    #expect(try run("garbageThenRedefine") == 1)
    // Point3 is R's class-side `cls` (a class defined at run time is not in
    // the loader's tables).
    let pi = vm.inspect { om in UInt64(om.load(om.load(om.classOop(r), ClassLayout.size), ClassLayout.classIndex).smallIntegerValue) }
    let objs = vm.inspect { $0.allInstances(of: pi) }
    #expect(objs.count == 3)
    #expect(vm.inspect { om in objs.allSatisfy { om.count(of: $0) == 3 && om.load($0, 2).smallIntegerValue * 10 == om.load($0, 1).smallIntegerValue } })
    #expect(image.om.counters.verifierFailures == 0 && vm.counters.stopVerifierFailures == 0)
    #expect(vm.markingCounters.missed == 0)
}
