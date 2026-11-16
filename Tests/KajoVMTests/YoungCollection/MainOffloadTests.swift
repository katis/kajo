import Testing
@testable import KajoVM

// The main worker always offloads its young collections
// (docs/modules/main-offload.md). Part 1: the counter of young collections
// that ran on the main thread (`ycOnMain*` on the run line), by whose
// nursery, and the main worker's waits for its collector.

/// `kajo run prelude lib idle mainload --main-ms <ms> --main-alloc 8000`
/// (the heavymain load of docs/modules/young-collection.md): the calling
/// thread is the main worker and fills its nursery every few frames.
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

@Test func theMainThreadCounterSeesTheMainWorkersCollectionsUnderLocal() throws {
    let out = mainLoadRun(young: "local")
    #expect(try out.checksum.get() == 0)
    let local = Int(reportValue(out, "ycLocal") ?? "") ?? -1
    let onMain = Int(reportValue(out, "ycOnMainW0") ?? "") ?? -1
    #expect(onMain > 0, "\(out.report)")
    #expect(onMain <= local)
    #expect(reportValue(out, "ycOnMain") == reportValue(out, "ycOnMainW0"))
    #expect(Double(reportValue(out, "ycOnMainW0MaxMs") ?? "") ?? 0 > 0)
}

@Test func theMainThreadCounterReadsZeroUnderOffload() throws {
    let out = mainLoadRun(young: "offload")
    #expect(try out.checksum.get() == 0)
    #expect(Int(reportValue(out, "ycOffloaded") ?? "") ?? 0 > 0, "\(out.report)")
    #expect(reportValue(out, "ycOnMain") == "0")
    #expect(reportValue(out, "ycOnMainW0") == "0")
    #expect(reportValue(out, "ycInline") == "0")
    // The main worker's waits for its collector are on the line.
    #expect(Int(reportValue(out, "ycMainCollectorWaits") ?? "") != nil)
}

@Test func theMainThreadCounterIsAbsentUnderTheOracle() throws {
    let out = mainLoadRun(young: "stw", ms: 200)
    #expect(try out.checksum.get() == 0)
    #expect(reportValue(out, "ycOnMain") == "-")
}
