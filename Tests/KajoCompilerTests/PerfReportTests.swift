// The performance report's script (scripts/perf-report.py, the runtime
// comparison of experiments/runtime-comparison/DESIGN.md): run on the fixture
// raw files in Fixtures/perf, its README blocks and one SVG byte for byte
// against the goldens beside them, a second run byte-identical, and every
// hand-written line of the README left as it was.
//
// Regenerate the goldens after a deliberate change to the script (and read
// the diff before committing it):
//
//   F=Tests/KajoCompilerTests/Fixtures/perf; T=$(mktemp -d); cp $F/README.in.md $T/README.md
//   scripts/perf-report.py --raw $F/bench-raw.txt --slices $F/slices-raw.txt \
//       --device $F/fixture-phone --readme $T/README.md --svg-dir $T
//   cp $T/README.md $F/README.golden.md; cp $T/fib.svg $F/fib.golden.svg

import Foundation
import Testing

let perfFixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/perf").path
let perfScript = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/perf-report.py").path

/// Runs the script on the fixtures into `dir`; answers its exit status and output.
func runPerfReport(into dir: String) throws -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["python3", perfScript,
                   "--raw", perfFixtures + "/bench-raw.txt",
                   "--slices", perfFixtures + "/slices-raw.txt",
                   "--device", perfFixtures + "/fixture-phone",
                   "--readme", dir + "/README.md",
                   "--svg-dir", dir]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: out, as: UTF8.self))
}

/// The lines outside every generated block, markers included.
func handWrittenLines(_ text: String) -> [Substring] {
    var inside = false
    var kept: [Substring] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("<!-- generated: ") { inside = true; kept.append(line); continue }
        if line == "<!-- /generated -->" { inside = false }
        if !inside { kept.append(line) }
    }
    return kept
}

@Suite struct PerfReportTests {
    @Test func theReportOfTheFixtureIsTheGoldenByteForByte() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kajo-perf-\(getpid())-\(UInt32.random(in: 0...UInt32.max))").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let skeleton = try String(contentsOfFile: perfFixtures + "/README.in.md", encoding: .utf8)
        try skeleton.write(toFile: dir + "/README.md", atomically: true, encoding: .utf8)

        let (status, output) = try runPerfReport(into: dir)
        #expect(status == 0, "\(output)")
        let readme = try #require(FileManager.default.contents(atPath: dir + "/README.md"))
        let golden = try #require(FileManager.default.contents(atPath: perfFixtures + "/README.golden.md"))
        #expect(Array(readme) == Array(golden), "README.md differs from README.golden.md")
        let svg = try #require(FileManager.default.contents(atPath: dir + "/fib.svg"))
        let goldenSVG = try #require(FileManager.default.contents(atPath: perfFixtures + "/fib.golden.svg"))
        #expect(Array(svg) == Array(goldenSVG), "fib.svg differs from fib.golden.svg")

        // The hand-written lines survive, and a second run writes the same bytes.
        let text = String(decoding: readme, as: UTF8.self)
        #expect(handWrittenLines(text) == handWrittenLines(skeleton))
        let (again, againOutput) = try runPerfReport(into: dir)
        #expect(again == 0, "\(againOutput)")
        #expect(FileManager.default.contents(atPath: dir + "/README.md") == readme)
        #expect(FileManager.default.contents(atPath: dir + "/fib.svg") == svg)

        // Every SVG reads in both themes and without colour: text and axes in
        // currentColor, one title, the values as text.
        for name in ["fib", "dispatch", "binarytrees", "collections", "arith", "scaling"] {
            let s = try String(contentsOfFile: dir + "/\(name).svg", encoding: .utf8)
            #expect(s.components(separatedBy: "<title>").count == 2, "\(name).svg")
            #expect(s.contains("fill=\"currentColor\""), "\(name).svg")
            #expect(!s.contains("@import") && !s.contains("url("), "\(name).svg")
        }
    }

    @Test func aReadmeWithoutAMarkerIsRefused() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kajo-perf-\(getpid())-\(UInt32.random(in: 0...UInt32.max))").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let skeleton = try String(contentsOfFile: perfFixtures + "/README.in.md", encoding: .utf8)
        let broken = skeleton.replacingOccurrences(of: "<!-- generated: caveats -->\n<!-- /generated -->\n", with: "")
        #expect(broken != skeleton)
        try broken.write(toFile: dir + "/README.md", atomically: true, encoding: .utf8)
        let (status, output) = try runPerfReport(into: dir)
        #expect(status != 0)
        #expect(output.contains("caveats"))
        #expect(try String(contentsOfFile: dir + "/README.md", encoding: .utf8) == broken)
    }
}
