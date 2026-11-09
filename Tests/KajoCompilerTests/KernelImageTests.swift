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
    let r = Headless.test(image: image, arguments: arguments, options: o) { lines.add($0) }
    return (r, lines.all)
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

    @Test func theKernelsTestsPassAndTheEventsAreTheProtocol() throws {
        let (result, lines) = runKernelTests(kernelImage)
        let report = TestReport(lines)
        #expect(try result.get() == 0, "\(report.failures.prefix(5))")
        #expect(report.total > 100 && report.passed == report.total && report.failed == 0 && report.errored == 0)
        #expect(report.events.count == lines.count)  // every line is one JSON object
        let kinds = Set(report.events.compactMap { $0["kind"] as? String })
        #expect(kinds.isSubset(of: ["run.started", "test.started", "test.passed", "test.failed", "test.errored", "transcript",
                                   "gc", "run.finished"]))
        #expect(kinds.isSuperset(of: ["run.started", "test.started", "test.passed", "run.finished", "gc"]))
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
