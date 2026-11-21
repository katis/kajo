// The third review's small fixes, part 2, item 6 (verification.A1): one
// `VerificationLevel`, one default per build, one function that sets every
// configuration's verifier switch from it.

import Testing
@testable import KajoVM

/// What each level sets, through `apply` and through `Headless.configs`
/// (the path of `kajo run`, `kajo test` and `ShellVM`), and the switches no
/// level touches.
@Test(arguments: VerificationLevel.allCases)
func eachLevelSetsEveryVerifierSwitch(_ level: VerificationLevel) throws {
    var vc = VMConfig(), om = ObjectMemoryConfig()
    level.apply(&vc, &om)
    #expect(vc.verifyStops == (level != .off))
    #expect(om.verify == (level == .all))
    #expect(vc.young.verify == (level == .all))
    #expect(vc.verifySymbols == false, "the symbol verifier is not a level")
    var o = Headless.Options()
    o.verify = level
    #expect(o.level == level)
    let (hvc, hom) = try Headless.configs(o).get()
    #expect(hvc.verifyStops == vc.verifyStops && hom.verify == om.verify && hvc.young.verify == vc.young.verify)
    #expect(hom.onVerifyFailure == .trap, "Headless traps at every level")
    #expect(VerificationLevel(name: level.name) == level)
}

/// One default per build: `all` checked, `off` release; the configurations'
/// own defaults agree with it (the young verifier excepted: it is off by
/// default in every build and on at `all`), and `withoutHeap` is the build's
/// level with the heap verifiers off.
@Test func theBuildsLevelIsTheConfigurationsDefault() throws {
    #expect(VerificationLevel.build == (checkedBuild ? .all : .off))
    #expect(VerificationLevel.withoutHeap == (checkedBuild ? .stops : .off))
    #expect(VMConfig().verifyStops == (VerificationLevel.build != .off))
    #expect(ObjectMemoryConfig().verify == (VerificationLevel.build == .all))
    #expect(VMConfig().young.verify == false)
    #expect(Headless.Options().level == .build)
    #expect(VerificationLevel(name: "on") == nil)
}
