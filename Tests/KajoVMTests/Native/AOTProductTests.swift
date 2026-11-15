import Foundation
import Testing
import KajoAOT
@testable import KajoVM

// AOT 2 (docs/modules/aot-product.md): the generator's size levers, each a
// `kajo aot` option. Every lever changes only the code inside a module
// (which functions exist, where a send's probe lives, which methods are
// generated); none changes what the VM reads of a module or what a method's
// code assumes, so the content and layout hashes are AOT 1's. Each lever
// must answer what the interpreter answers, with the interpreter's send
// count (rule 7's drift detector), and a subset's methods left out run
// interpreted beside the generated ones.

/// The levers alone and the product's configuration, as `kajo aot`'s
/// arguments over AOT 1's full configuration.
let leverArguments: [[String]] = [
    ["--full"],
    [],  // the defaults: the product's configuration
    ["--full", "--hot", "entry-loops"], ["--full", "--hot", "entry"], ["--full", "--hot", "none"],
    ["--full", "--send-helper"], ["--full", "--shared-tails"], ["--full", "--cold-minsize"],
    ["--full", "--subset", "callees"], ["--full", "--subset", "loops"],
    ["--full", "--subset", "callees,no-accessors,max=64"],
    ["--hot", "none", "--send-helper", "--shared-tails", "--cold-minsize"],
]

func leverOptions(_ args: [String]) throws -> AOTOptions {
    switch AOTOptions.parse(args) {
    case .success(let (o, rest)):
        #expect(rest.isEmpty)
        return o
    case .failure(let e): throw e
    }
}

@Test(arguments: leverArguments)
func everyLeverAnswersWhatTheInterpreterAnswers(_ args: [String]) throws {
    let module = try moduleGenerated(from: switchProgram(1), options: try leverOptions(args))
    let rt = try Runtime(switchProgram(1), background: 1, native: false, module: module)
    let p = rt.spawn("root")
    #expect(rt.waitAllTerminated())
    #expect(rt.result(p) == 200_006, "\(args)")
    let r = try #require(rt.vm.nativeReport)
    #expect(r.refused == nil && r.bound > 0, "\(args): \(r)")
    let native = rt.vm.interpreterCounters.sends
    #expect(rt.vm.nativeCounters.entries > 0, "\(args)")
    rt.stop()
    let ip = try Runtime(switchProgram(1), background: 1, native: false)
    _ = ip.spawn("root")
    #expect(ip.waitAllTerminated())
    #expect(native == ip.vm.interpreterCounters.sends, "\(args): send counts")
    ip.stop()
}

/// The broken variants of AOT 1 still fail under the product's
/// configuration with every method generated (the send helper counts the
/// sends; the cold function polls at every backward jump).
@Test func theBrokenVariantsFailInTheProductsConfiguration() throws {
    var o = NativeTest.options
    o.brokenNoSendCount = true
    let broken = try moduleGenerated(from: switchProgram(1), options: o)
    let rt = try Runtime(switchProgram(1), background: 1, native: false, module: broken)
    let p = rt.spawn("root")
    #expect(rt.waitAllTerminated())
    #expect(rt.result(p) == 200_006)
    let a = rt.vm.interpreterCounters.sends
    rt.stop()
    let ok = try Runtime(switchProgram(1), background: 1, native: false)
    _ = ok.spawn("root")
    #expect(ok.waitAllTerminated())
    #expect(a < ok.vm.interpreterCounters.sends, "the uncounted sends went unnoticed")
    ok.stop()
    var f = NativeTest.options
    f.brokenNoFlushAtPoll = true
    let lost = try moduleGenerated(from: operandAcrossPolls, options: f)
    let rt2 = try Runtime(operandAcrossPolls, background: 1, configure: { $0.stress = .preemptEveryPoll }, native: false, module: lost)
    let p2 = rt2.spawn("acc:", [Oop(smallInteger: 3000)])
    #expect(rt2.waitAllTerminated())
    #expect(rt2.vm.result(of: p2) != Oop(smallInteger: 9000), "the broken variant went unnoticed")
    rt2.stop()
}

/// A subset by the static rule: `spin:` (a loop) and what it sends are
/// generated, `root`, `outer` and `callee:` are not; each side calls the
/// other, the left-out methods are unbound (not declined), and the answer
/// is the interpreter's.
@Test func aSubsetsLeftOutMethodsRunInterpretedBesideTheGeneratedOnes() throws {
    let o = try leverOptions(["--subset", "loops"])
    let rt0 = try Runtime(switchProgram(1), background: 1, start: false, native: false)
    let infos = rt0.image.nativeMethodInfos()
    let out = NativeTest.source(for: rt0.image, options: o)
    rt0.stop(verifyHeap: false)
    #expect(out.excluded > 0 && out.declined.isEmpty && out.methods + out.excluded == infos.count, "\(out.methods) \(out.excluded)")
    let module = try NativeTest.compile(out.source, name: "kajo-native-subset")
    let rt = try Runtime(switchProgram(1), background: 1, native: false, module: module)
    let p = rt.spawn("root")
    #expect(rt.waitAllTerminated())
    #expect(rt.result(p) == 200_006)
    let r = try #require(rt.vm.nativeReport)
    #expect(r.bound == out.methods && r.unboundNoMatch == out.excluded, "\(r)")
    let n = rt.vm.nativeCounters
    #expect(n.toInterpreterUnbound + n.toNativeAtPoll + n.toNativeAtReturn > 0, "\(n)")
    #expect(r.unboundNoMatch > 0 && module.methodsDeclined == 0)
    rt.stop()
}

@Test func theOptionsParseAndRefuse() throws {
    let o = try leverOptions(["--full", "--hot", "entry", "--send-helper", "--subset", "callees,no-accessors,max=100"])
    #expect(o.hot == .entry && o.sendHelper && !o.sharedTails && o.subset?.callees == true && o.subset?.noAccessors == true
        && o.subset?.maxBytes == 100)
    #expect(try leverOptions(o.arguments).arguments == o.arguments)
    for bad in [["--hot"], ["--hot", "warm"], ["--subset"], ["--subset", "callees,max=0"], ["--subset", "every"]] {
        if case .success = AOTOptions.parse(bad) { Issue.record("accepted \(bad)") }
    }
    if case .success(let (_, rest)) = AOTOptions.parse(["-o", "dir", "x.img"]) { #expect(rest == ["-o", "dir", "x.img"]) }
}

/// The test process links no module: the main image has no
/// `__DATA_CONST,__kajo_native` section.
@Test func noModuleIsLinkedIntoTheTestProcess() {
    #expect(NativeModule.linkedInMainImage() == nil)
}
