// The image build is a test (kernel.md): kernel/ compiles into a verified
// image, its own SUnit tests pass when the image runs headless, the event
// stream is NDJSON of the v1 kinds, JUnit XML derives from it, and the
// image survives a load and save round trip.

import Foundation
import Synchronization
import Testing
@testable import KajoCompiler
@testable import KajoVM

/// The package's kernel/ directory.
let kernelDirectory: String = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { url.deleteLastPathComponent() }
    return url.appendingPathComponent("kernel").path
}()

/// One build per test process.
let kernelImage: [UInt8] = {
    try! KernelBuild.build(KernelBuild.sources(in: [kernelDirectory])).image
}()

final class Lines: Sendable {
    private let lines = Mutex<[[UInt8]]>([])
    func add(_ l: [UInt8]) { lines.withLock { $0.append(l) } }
    var all: [[UInt8]] { lines.withLock { $0 } }
}

func runKernelTests(_ image: [UInt8], _ arguments: [String] = []) -> (Result<Int64, Headless.Failure>, [[UInt8]]) {
    let lines = Lines()
    var o = Headless.Options()
    o.heapMiB = 256
    // The verifier's faults (docs/modules/verifier-faults.md, part 4): the
    // heap verifiers run in the release build's kernel tests (the
    // test-release gate) and not in a checked build's (swift test, the
    // sanitizer gates): the owner's answer of 2026-11-20, the verifiers
    // costing 1.7 times the kernel tests in release and 3 times in debug
    // (docs/decisions/50-review-3-small-fixes.md). Not the build's level,
    // which is the opposite. Part 2, item 6: the release build's level is
    // `all` (the heap verifiers and, since then, the stop verifiers too),
    // the checked build's the build's level without the heap verifiers.
    o.verify = checkedBuild ? .withoutHeap : .all
    let r = Headless.test(image: image, arguments: arguments, options: o) { lines.add($0) }
    return (r, lines.all)
}

// Gate speed (docs/modules/gate-speed.md, change 1): the kernel's tests run
// as several VMs at the same time, each over a part of the tests, on the
// same kernelImage. The parts are computed from what the runner lists
// (`--list`, the tests the unfiltered run would run), so a test added to
// kernel/ tomorrow is in a part without anyone editing a list; each part is
// one run by the event protocol over its tests named exactly (`--test`);
// theKernelTestPartsAreExactlyTheUnfilteredRun asserts that the parts hold
// every listed test exactly once, and each part asserts that it ran exactly
// its own. One VM ran all of them in turn before: 3081 s of the sanitizer
// gate and 3719 s under load, the rest of the suite long finished.

/// One test as the runner lists it.
struct ListedKernelTest: Sendable, Hashable {
    let name: String
    let cls: String
    let tags: [String]
}

/// The tests a run with these arguments would run, as `--list` answers
/// them, with the run.listed total.
func listKernelTests(_ image: [UInt8], _ arguments: [String] = []) -> (tests: [ListedKernelTest], total: Int?, ok: Bool) {
    let (r, lines) = runKernelTests(image, ["--list"] + arguments)
    let events = TestReport(lines).events
    let tests = events.filter { $0["kind"] as? String == "test.listed" }.map {
        ListedKernelTest(name: $0["test"] as? String ?? "?", cls: $0["class"] as? String ?? "?", tags: $0["tags"] as? [String] ?? [])
    }
    let total = events.first { $0["kind"] as? String == "run.listed" }?["total"] as? Int
    return (tests, total, (try? r.get()) == 0)
}

/// Every test of the kernel image, listed once per test process.
let kernelTestList: [ListedKernelTest] = listKernelTests(kernelImage).tests

enum KernelTestParts {
    /// How many VMs run at once. Measured on 3cf22fe under the sanitizer
    /// (one VM, the mini idle): 2921 s of tests, of which the two
    /// every-method tests are 698 and 691 s and the long chain 585 s, each
    /// one test; the other 246 tests are 948 s. Five parts would make the
    /// longest part the longest test, but five VMs beside the rest of the
    /// bundle starve its timers: `theToolsReconnectAfterADroppedLink` failed
    /// in 6 of 8 sanitizer runs at five parts, 1 of 2 at three, 0 of 1 at two
    /// and at one (docs/modules/gate-speed.md, "The reconnect test"). Two
    /// parts of about 1460 sanitizer seconds each. `KAJO_KERNEL_TEST_PARTS`
    /// overrides the count (the measurement).
    static let count = Int(ProcessInfo.processInfo.environment["KAJO_KERNEL_TEST_PARTS"] ?? "").flatMap { $0 > 0 ? $0 : nil } ?? 2

    /// Seconds under the sanitizer measured on 3cf22fe for every test of 5 s
    /// or more there (the doc's table; a plain build is 26 to 32 times
    /// shorter, test for test). Only the balance of the parts reads this:
    /// a test missing from it (a new one, a renamed one) is still in a part,
    /// weighed as the measured mean of the rest (0.32 s), or as a
    /// ClassFuzzTest (150 s) when it is tagged `<slow>`.
    static let measuredSeconds: [String: Double] = [
        "LiveCompileTest>>testEveryMethodMakesAsInstalled": 697.9,
        "CompilerTest>>testEveryMethodCompilesAsTheBootstrapDid": 691.4,
        "CompilerTest>>testALongChainIsWalkedByALoop": 584.5,
        "ClassFuzzTest>>testSeededSpecificationsAreRefusedOrAccepted": 152.8,
        "TonelTest>>testTheReaderReadsWhatTheWriterWrote": 138.0,
        "LargeObjectTest>>testStringsPastTheCountField": 123.7,
        "DevelopmentTest>>testARemovedClassStillNamedIsKept": 95.8,
        "LargeObjectTest>>testALargeArrayIsAnArray": 61.2,
        "LargeObjectTest>>testJsonInPieces": 51.1,
        "LargeObjectTest>>testLargeStringsAndByteArrays": 45.0,
        "LargeObjectTest>>testGrowableCollectionsPassOneBlock": 36.7,
        "ClassFuzzTest>>testSeededReshapesAreRefusedOrAccepted": 29.9,
        "MakeFuzzTest>>testSeededMutationsAreRefusedOrRun": 17.7,
        "RegistryTest>>testHandlesFromManyProcessesAreDistinct": 14.0,
        "RegistryTest>>testThePragmaIndexIsWholeWhileItIsRebuilt": 13.9,
        "DevelopmentTest>>testACollectionThatHoldsItselfPrintsCut": 13.5,
        "TonelTest>>testAClassDefinedAndRedefinedFromTonel": 10.4,
        "TonelTest>>testATagIsTheFilesDirectory": 10.3,
        "LiveClassTest>>testReshapeKeepsValuesByNameAndRecompiles": 10.0,
        "LiveClassTest>>testOldClosuresFollowTheirMethod": 7.8,
        "LiveClassTest>>testARedefinitionThatTheSubclassesNamesClashWithIsRefused": 7.3,
        "LiveClassTest>>testClassSideInstanceVariables": 6.7,
        "DevelopmentTest>>testClassDefineIntoATagAndMoving": 6.7,
        "LiveClassTest>>testDefinitionsTheVMRefuses": 6.4,
        "LiveClassTest>>testARemovalThatBreaksAMethodChangesNothing": 6.4,
        "LiveClassTest>>testARunningMethodRefusesTheReshape": 5.6,
        "LiveClassTest>>testDefineInstantiateRemove": 5.3,
    ]

    static func weight(_ t: ListedKernelTest) -> Double {
        measuredSeconds[t.name] ?? (t.tags.contains("slow") ? 150 : 0.32)
    }

    /// The tests' names in `count` parts: heaviest first (then by name),
    /// each to the lightest part so far (then the lowest index).
    static func split(_ tests: [ListedKernelTest], into n: Int) -> [[String]] {
        var parts = [[String]](repeating: [], count: n)
        var load = [Double](repeating: 0, count: n)
        for t in tests.sorted(by: { (weight($0), $1.name) > (weight($1), $0.name) }) {
            let k = load.indices.min { (load[$0], $0) < (load[$1], $1) }!
            parts[k].append(t.name)
            load[k] += weight(t)
        }
        return parts
    }
}

/// The parts of this test process's run.
let kernelTestParts: [[String]] = KernelTestParts.split(kernelTestList, into: KernelTestParts.count)

@Suite struct KernelTestPartsTests {
    /// The standing assertion, cheap in every build mode: what the runner
    /// selects for each part's names is exactly that part, and the parts
    /// together are the unfiltered run's tests, each once, by name.
    @Test func theKernelTestPartsAreExactlyTheUnfilteredRun() throws {
        let all = listKernelTests(kernelImage)
        #expect(all.ok && all.total == all.tests.count)
        #expect(all.tests.count > 100)
        #expect(Set(all.tests.map(\.name)).count == all.tests.count)
        #expect(all.tests == kernelTestList)
        var union: [String] = []
        for (k, part) in kernelTestParts.enumerated() {
            #expect(!part.isEmpty, "part \(k) is empty")
            let listed = listKernelTests(kernelImage, part.flatMap { ["--test", $0] })
            #expect(listed.ok && listed.tests.map(\.name).sorted() == part.sorted(), "part \(k)")
            union += listed.tests.map(\.name)
        }
        #expect(union.count == Set(union).count, "a test is in two parts")
        #expect(union.sorted() == all.tests.map(\.name).sorted())
        // the split is deterministic: a second split of the list is the same
        #expect(KernelTestParts.split(kernelTestList, into: KernelTestParts.count) == kernelTestParts)
        // a filter and a name compose (the --test path selects, never adds)
        #expect(listKernelTests(kernelImage, ["--filter", "StringTest>>*", "--test", "ArrayTest>>testIsArray"]).tests.isEmpty)
    }

    /// Every part is a whole run by the event protocol (the assertions the
    /// one unfiltered run made), and it ran exactly its tests. Each part
    /// prints one line per test, so a gate's output names every test id
    /// with its outcome (the doc's comparison reads them).
    @Test(arguments: 0..<KernelTestParts.count)
    func theKernelsTestsPassAndTheEventsAreTheProtocol(_ part: Int) throws {
        let names = kernelTestParts[part]
        let (result, lines) = runKernelTests(kernelImage, names.flatMap { ["--test", $0] })
        let report = TestReport(lines)
        #expect(try result.get() == 0, "\(report.failures.prefix(5))")
        #expect(report.total == names.count && report.passed == report.total && report.failed == 0 && report.errored == 0)
        #expect(report.events.count == lines.count)  // every line is one JSON object
        let kinds = Set(report.events.compactMap { $0["kind"] as? String })
        #expect(kinds.isSubset(of: ["run.started", "test.started", "test.passed", "test.failed", "test.errored", "transcript",
                                   "gc", "run.finished"]))
        #expect(kinds.isSuperset(of: ["run.started", "test.started", "test.passed", "run.finished", "gc"]))  // gc: the run's summary at least
        // The verifier's faults, part 4: the release build's parts verify
        // and say so, a checked build's do not (`runKernelTests`).
        let summary = report.events.last { $0["kind"] as? String == "gc" && $0["collection"] as? String == "summary" }
        let verify = summary?["verify"] as? String, verifies = summary?["verifies"] as? Int ?? 0
        print("kernel part \(part): verify=\(verify ?? "-") verifies=\(verifies)")
        #expect(verify == (checkedBuild ? "stops" : "all"), "part \(part): verify=\(verify ?? "-")")
        if !checkedBuild { #expect(verifies > 0, "part \(part): verifies=\(verifies)") }
        for e in report.events {
            #expect(e["v"] as? Int == 1)
            #expect((e["ts"] as? Int ?? 0) > 1_700_000_000_000_000)  // microseconds since 1970
        }
        let started = report.events.filter { $0["kind"] as? String == "test.started" }.count
        #expect(started == report.total)
        #expect(report.events.first?["kind"] as? String == "run.started")
        // the events of the tests come in the order they happened
        let testTimes = report.events.filter { ($0["kind"] as? String ?? "").hasPrefix("test.") }.compactMap { $0["ts"] as? Int }
        #expect(testTimes == testTimes.sorted())
        // exactly this part's tests ran, each once
        let ran = report.events.filter { ["test.passed", "test.failed", "test.errored"].contains($0["kind"] as? String ?? "") }
        #expect(ran.compactMap { $0["test"] as? String }.sorted() == names.sorted())
        let n = KernelTestParts.count
        print(ran.map { e in
            "kernel test part \(part + 1)/\(n) \((e["kind"] as? String ?? "?").dropFirst(5)) \(e["test"] as? String ?? "?") "
                + String(format: "%.3f s", Double(e["us"] as? Int ?? 0) / 1e6)
        }.joined(separator: "\n") + "\nkernel test part \(part + 1)/\(n): \(report.total) tests, \(report.passed) passed in \(report.microseconds / 1000) ms")
    }
}

@Suite(.serialized) struct KernelImageTests {
    @Test func theKernelBuildsWithoutWarnings() throws {
        let r = try KernelBuild.build(KernelBuild.sources(in: [kernelDirectory]))
        #expect(r.warnings.isEmpty, "\(r.warnings)")
        #expect(r.classes > 100)
        #expect(r.methods > 1300)
        // and loads as an image (verified all or nothing)
        let img = try Image.load(image: r.image)
        defer { img.destroy() }
        #expect(img.entryPoint != img.nilObject)
    }

    @Test func filterAndTagSelectTests() throws {
        let (r1, l1) = runKernelTests(kernelImage, ["--filter", "StringTest>>testScalars*"])
        #expect(try r1.get() == 0)
        let rep1 = TestReport(l1)
        #expect(rep1.total == 1)
        let (r2, l2) = runKernelTests(kernelImage, ["--tag", "expectedFailure"])
        #expect(try r2.get() == 0)
        let rep2 = TestReport(l2)
        #expect(rep2.total == 1)
        #expect(rep2.events.contains { $0["kind"] as? String == "test.passed" && $0["expectedFailure"] as? Bool == true })
    }

    @Test func failuresCarryTheMessageAndTheFrames() throws {
        // SUnitSample is abstract; its failing tests run when named.
        let src = KernelBuild.sources
        let extra: [(file: String, text: [UInt8])] = [("Failing.class.st", Array("""
        Class { #name : #FailingSample, #superclass : #TestCase }
        FailingSample >> testFails [ self assert: 1 + 1 equals: 3 ]
        FailingSample >> testErrors [ ^ nil foo ]
        FailingSample >> testPasses [ self assert: true ]
        """.utf8))]
        let image = try KernelBuild.build(try src([kernelDirectory]) + extra.map { ($0.file, $0.text, nil) }).image
        let (result, lines) = runKernelTests(image, ["--filter", "FailingSample"])
        #expect(try result.get() == 2)
        let report = TestReport(lines)
        #expect(report.total == 3 && report.passed == 1 && report.failed == 1 && report.errored == 1)
        let failed = try #require(report.events.first { $0["kind"] as? String == "test.failed" })
        #expect(failed["message"] as? String == "Expected 3 but was 2")
        #expect((failed["frames"] as? [String])?.contains("FailingSample>>testFails") == true)
        let errored = try #require(report.events.first { $0["kind"] as? String == "test.errored" })
        #expect(errored["exception"] as? String == "MessageNotUnderstood")
        let xml = report.junitXML
        #expect(xml.contains("<testsuite name=\"FailingSample\" tests=\"3\" failures=\"1\" errors=\"1\""))
        #expect(xml.contains("<failure message=\"Expected 3 but was 2\" type=\"TestFailure\">"))
        #expect(xml.contains("<error message=\"nil does not understand #foo\" type=\"MessageNotUnderstood\">"))
        #expect(report.summary.hasSuffix("kajo test: 3 tests, 1 passed, 1 failed, 1 errored in \(report.microseconds / 1000) ms\n"))
    }

    @Test func theTranscriptIsAnEventWithItsProcess() throws {
        let extra: [(file: String, text: [UInt8])] = [("Shows.class.st", Array("""
        Class { #name : #ShowsSample, #superclass : #TestCase }
        ShowsSample >> testShows [ Transcript show: 'hello '; show: 42; cr ]
        """.utf8))]
        let image = try KernelBuild.build(try KernelBuild.sources(in: [kernelDirectory]) + extra.map { ($0.file, $0.text, nil) }).image
        let (_, lines) = runKernelTests(image, ["--filter", "ShowsSample"])
        let report = TestReport(lines)
        let t = try #require(report.events.first { $0["kind"] as? String == "transcript" })
        #expect(t["text"] as? String == "hello 42")
        #expect(t["process"] is Int)
        #expect(report.junitXML.contains("<system-out>hello 42</system-out>"))
    }

    @Test func theImageRoundTripsThroughLoadAndSave() throws {
        let first = try Image.load(image: kernelImage)
        let again = try first.saveImage()
        first.destroy()
        let second = try Image.load(image: again)
        let third = try second.saveImage()
        second.destroy()
        #expect(again == third)  // a loaded and saved image saves the same bytes
        let (result, lines) = runKernelTests(again, ["--filter", "ReflectionTest"])
        #expect(try result.get() == 0)
        #expect(TestReport(lines).passed == TestReport(lines).total)
    }

    /// Compiling and installing is deterministic to the byte. The kernel's
    /// initialization runs in a VM, where which worker allocates decides
    /// entry placement and so identity hashes: those builds differ in a few
    /// bytes (4 of 900 000 in one comparison) and have the same length.
    @Test func theBuildIsDeterministicBeforeInitialization() throws {
        var o = KernelBuild.Options()
        o.initialize = false
        let a = try KernelBuild.build(KernelBuild.sources(in: [kernelDirectory]), options: o).image
        let b = try KernelBuild.build(KernelBuild.sources(in: [kernelDirectory]), options: o).image
        #expect(a == b)
        let c = try KernelBuild.build(KernelBuild.sources(in: [kernelDirectory])).image
        #expect(c.count == kernelImage.count)
    }

    @Test func aBrokenClassFileRefusesTheWholeBuild() throws {
        let bad: [(file: String, text: [UInt8])] = [("Bad.class.st", Array("""
        Class { #name : #Bad, #superclass : #Object }
        Bad >> broken [ ^ 1 + ]
        """.utf8))]
        #expect(throws: CompileError.self) { _ = try KernelBuild.build(try KernelBuild.sources(in: [kernelDirectory]) + bad.map { ($0.file, $0.text, nil) }) }
        let unknown: [(file: String, text: [UInt8])] = [("Bad.class.st", Array("""
        Class { #name : #Bad, #superclass : #NoSuchClass }
        """.utf8))]
        #expect(throws: CompileError.self) { _ = try KernelBuild.build(try KernelBuild.sources(in: [kernelDirectory]) + unknown.map { ($0.file, $0.text, nil) }) }
        let wrongWellKnown: [(file: String, text: [UInt8])] = [("Point.class.st", Array("""
        Class { #name : #Message, #superclass : #Object, #instVars : [ 'a' ] }
        """.utf8))]
        #expect(throws: CompileError.self) {
            _ = try KernelBuild.build(try KernelBuild.sources(in: [kernelDirectory]).filter { !$0.file.hasSuffix("/Message.class.st") }
                                      + wrongWellKnown.map { ($0.file, $0.text, nil) })
        }
    }

    @Test func anUnconsumedPragmaWarns() throws {
        let extra: [(file: String, text: [UInt8])] = [("P.class.st", Array("""
        Class { #name : #PragmaSample, #superclass : #Object }
        PragmaSample >> m [ <expectedFailur> ^ 1 ]
        """.utf8))]
        let r = try KernelBuild.build(try KernelBuild.sources(in: [kernelDirectory]) + extra.map { ($0.file, $0.text, nil) })
        #expect(r.warnings.count == 1 && r.warnings[0].contains("<expectedFailur>"))
    }
}
