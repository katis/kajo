import Testing
@testable import KajoVM

// The main worker always offloads its young collections
// (docs/modules/main-offload.md). Part 1: the counter of young collections
// that ran on the main thread (`ycOnMain*` on the run line), by whose
// nursery, and the main worker's waits for its collector. Part 3: two
// modes, any other name refused, and a young collection the main worker runs itself
// while the collector thread runs is the main-thread verifier's failure.

/// `kajo run prelude lib idle mainload --main-ms <ms> --main-alloc 8000`
/// (the heavymain load of docs/modules/young-collection.md): the calling
/// thread is the main worker and fills its 256 KiB nursery every few frames.
func mainLoadRun(young: String, ms: Int = 600) -> Headless.Outcome {
    var o = Headless.Options()
    o.workers = 2
    o.nurseryKB = 256
    o.young = young
    o.mainMs = ms
    o.mainAlloc = 8000
    o.mainWork = 0
    return Headless.run([("prelude.kasm", kernel("prelude")), ("lib.kasm", kernel("lib")), ("idle.kasm", kernel("idle")),
                         ("mainload.kasm", kernel("mainload"))], options: o)
}

func reportValue(_ out: Headless.Outcome, _ key: String) -> String? {
    out.report.first { $0.name == key }?.value
}

/// Written first (failing on 576eff0, part 1's commit, where the name ran
/// as a mode and showed young collections on the main worker): a name that
/// is no mode is refused with the one generic line that lists the modes
/// that exist; nothing aliases it.
@Test func aNameThatIsNoModeIsRefusedWithTheModesThatExist() throws {
    let out = mainLoadRun(young: "local")
    guard case .failure(let f) = out.checksum else {
        Issue.record("ran: ycOnMainW0=\(reportValue(out, "ycOnMainW0") ?? "-")")
        return
    }
    let line = "\(f)"
    print("refusal: \(line)")
    #expect(line == "--young: stw or offload, not local")
    #expect(YoungMode.allCases.map(\.name) == ["stw", "offload"])
    #expect(YoungMode(name: "local") == nil)
}

/// The same load under the policy: the main worker flips, the collector
/// thread collects, the main-thread counter reads 0.
@Test func theMainThreadCounterReadsZeroUnderOffload() throws {
    let out = mainLoadRun(young: "offload")
    #expect(try out.checksum.get() == 0)
    #expect(Int(reportValue(out, "ycOffloaded") ?? "") ?? 0 > 0, "\(out.report)")
    #expect(reportValue(out, "ycOnMain") == "0")
    #expect(reportValue(out, "ycOnMainW0") == "0")
    #expect(reportValue(out, "ycInline") == "0")
    #expect(Int(reportValue(out, "mainFlips") ?? "") ?? 0 > 0)
    #expect(reportValue(out, "mainOwnCollections") == "0")
    #expect(out.counters.first { $0.name == "youngOnMainFailures" }?.value == 0)
    // The main worker's waits for its collector are on the line.
    #expect(Int(reportValue(out, "ycMainCollectorWaits") ?? "") != nil)
}

@Test func theMainThreadCounterIsAbsentUnderTheOracle() throws {
    let out = mainLoadRun(young: "stw", ms: 200)
    #expect(try out.checksum.get() == 0)
    #expect(reportValue(out, "ycOnMain") == "-")
}

/// The broken variant `mainCollectsItsOwnNursery`: worker 0 takes the
/// owner's local path with the collector thread running. The main-thread
/// verifier counts every such collection (a named check; the policy here
/// records instead of trapping)
/// and the counter of collections on the main worker sees them. Without the
/// switch the same run counts none.
private func mainCollects(broken: Bool) throws -> (failures: UInt64, onMain: UInt64, reports: [String]) {
    // `churn:` is pairSrc's: n Pairs, every one garbage.
    let rt = try Runtime(pairSrc, background: 2, start: true, configure: { c in
        c.nursery.bytes = 256 << 10
        c.young.mode = .offload
        c.young.testSwitches.mainCollectsItsOwnNursery = broken
    })
    let p = rt.spawn("churn:", [int(60_000)], main: true)
    let end = now() + 120_000_000_000
    while rt.vm.liveProcessCount > 0 && now() < end { _ = rt.vm.runMain(budgetNs: 5_000_000) }
    #expect(rt.result(p) == 60_000)
    let failures = rt.vm.counters[.youngOnMainFailures]
    let onMain = rt.vm.youngCounters.onMain.main
    let flips = rt.vm.youngWorkerCounters(0).flips
    let own = rt.vm.youngWorkerCounters(0).ownCollections
    print("main collects its own nursery \(broken): youngOnMainFailures=\(failures) onMain=\(onMain) flips=\(flips) own=\(own)")
    rt.stop()
    return (failures, onMain, [])
}

@Test func theMainWorkerNeverCollectsItsOwnNurseryWithTheCollectorThreadRunning() throws {
    let r = try mainCollects(broken: false)
    #expect(r.failures == 0 && r.onMain == 0)
}

@Test func withTheMainWorkerCollectingItsOwnNurseryTheMainThreadVerifierFails() throws {
    let r = try mainCollects(broken: true)
    #expect(r.failures > 0 && r.failures == r.onMain, "\(r)")
}
