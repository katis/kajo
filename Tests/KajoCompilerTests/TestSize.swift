// Check time (docs/modules/check-time.md): a test whose claim holds at a
// smaller size runs that size in the tiers and its full size in the weekly
// run, which exports `KAJO_TEST_SIZE=full` (scripts/weekly.sh). The tiers
// leave it unset. A test reads the size only through `sized(_:tier:full:)`
// or `.weeklyUnderSanitizer(_:)`, with an id that is a row of `sizedTests`:
// `TestSizeTests` reads this target's sources and fails on an id no row
// names and on a row no source names. The VM tests have their own switch and
// table (Tests/KajoVMTests/TestSize.swift).
//
// Part 1's rules (`~/kajo-scratch/check-time/part1/rules.txt`, the doc's
// "The rules"): the assertions are the same at both sizes; a claim over
// every X runs a fixed part of X in a tier only where another gate of the
// tier runs all of it; under that rule a sanitizer gate may leave a test to
// the weekly run when the tier's plain gate runs it whole.
import Foundation
import Testing

enum TestSize: String { case tier, full }

/// The size a value of `KAJO_TEST_SIZE` names: `full`, or `tier` for
/// anything else (unset included).
func parseTestSize(_ value: String?) -> TestSize { value == "full" ? .full : .tier }

/// This process's size.
let testSize: TestSize = parseTestSize(ProcessInfo.processInfo.environment["KAJO_TEST_SIZE"])

/// The value for `size` (this process's by default). `id` is a row of
/// `sizedTests`.
func sized<T>(_ id: String, tier: T, full: T, at size: TestSize = testSize) -> T { size == .full ? full : tier }

extension Trait where Self == ConditionTrait {
    /// Skipped in a tier's sanitizer gate (`tsan-load`), run everywhere else:
    /// the plain gate of every tier runs it, and the weekly run (full size)
    /// runs it under the sanitizer too. `id` is a row of `sizedTests`.
    static func weeklyUnderSanitizer(_ id: String) -> Self {
        .disabled(if: compilerTestsUnderThreadSanitizer && testSize == .tier,
                  "check time: under the sanitizer in the weekly run only (\(id))")
    }
}

/// One row: what the test claims and what each size runs.
struct SizedTest {
    let claim: String
    let tier: String
    let full: String
}

let sizedTests: [String: SizedTest] = [
    "KernelTestParts.sanitizerTier": SizedTest(
        claim: "the kernel's SUnit tests pass and their events are the protocol (KernelTestPartsTests)",
        tier: "under the sanitizer, every kernel test but the ones in KernelTestParts.weeklyUnderSanitizer, which swift-test and kernel-test run whole in every tier",
        full: "every kernel test, in every gate"),
    "TypeCheckerTests.theDiagnosticsRequest": SizedTest(
        claim: "the diagnostics request answers its three scopes after a whole-image check and the event follows a change",
        tier: "the plain gate only (47 s); under the sanitizer the whole-image check took 1047 s",
        full: "every gate, the sanitizer's included"),
    "TypeCheckerTests.theTypesPackage": SizedTest(
        claim: "the types package builds without warnings and its 34 SUnit tests pass in the development image",
        tier: "the plain gate only (29 s); under the sanitizer and twelve loops 1132 to 1532 s, the end of the compiler tests' shard",
        full: "every gate, the sanitizer's included"),
]

/// The ids this target's sources name through the switch, file by file.
func sizedIdsInSources(_ root: String) throws -> [String: [String]] {
    var out: [String: [String]] = [:]
    let files = FileManager.default.enumerator(atPath: root)?.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") } ?? []
    for f in files where !f.hasPrefix("Fixtures/") && f != "TestSize.swift" {
        let text = try String(contentsOfFile: root + "/" + f, encoding: .utf8)
        for m in text.matches(of: /(?:sized|weeklyUnderSanitizer)\(\s*"([^"]+)"/) { out[String(m.1), default: []].append(f) }
    }
    return out
}

@Suite struct TestSizeTests {
    /// Every id a source passes is a row, every row is passed somewhere, and
    /// the line the weekly summary reads says this process's size.
    @Test func everySizedTestHasARow() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
        let used = try sizedIdsInSources(dir)
        print("kajo-test-size size=\(testSize.rawValue) sized=\(sizedTests.count)")
        for id in used.keys.sorted() where sizedTests[id] == nil { Issue.record("\(id) (\(used[id]!)) reads the size and has no row in sizedTests") }
        for id in sizedTests.keys.sorted() where used[id] == nil { Issue.record("\(id) is a row of sizedTests and no source reads it") }
        #expect(!used.isEmpty)
    }

    /// The switch at each size: unset (and any other value) is the tier's,
    /// `full` is the weekly's, and `sized` answers by it.
    @Test func theSwitchReadsItsVariable() {
        #expect(parseTestSize(nil) == .tier && parseTestSize("") == .tier && parseTestSize("tier") == .tier)
        #expect(parseTestSize("Full") == .tier && parseTestSize("full ") == .tier)
        #expect(parseTestSize("full") == .full)
        #expect(sized("KernelTestParts.sanitizerTier", tier: 1, full: 2, at: .tier) == 1)
        #expect(sized("KernelTestParts.sanitizerTier", tier: 1, full: 2, at: .full) == 2)
        #expect(testSize == parseTestSize(ProcessInfo.processInfo.environment["KAJO_TEST_SIZE"]))
    }
}
