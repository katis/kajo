// The weekly margins (docs/modules/weekly-margins.md): a test that waits
// against a bound prints one line when the wait ends, passing or failing,
// with the value and the bound the wait used, and scripts/margins.py reads
// the test gates' outputs into a table (the weekly run's summary.md, `just
// margins <dir>`). The compiler tests have the same helper
// (Tests/KajoCompilerTests/Margins.swift); both are tested against one
// committed sample line that the reader's test reads too
// (Tests/KajoCompilerTests/Fixtures/margins/sample-line.txt).
//
//   kajo-margin name=<name> kind=<kind> value=<v> bound=<b> unit=<unit>
//
// The helper only prints: no test's result or timing depends on it beyond
// the line of output.
import Foundation
import Synchronization
import Testing

/// What a margin's bound is on. `deadline`: a clock on the whole wait, the
/// value the time it took. `quiet`: a bound on a stretch with no progress,
/// the value the longest such stretch. `ceiling`: a measured value an
/// assertion bounds. `time`: a value with no bound (printed `bound=-`).
enum MarginKind: String {
    case deadline, quiet, ceiling, time
}

/// One margin line. A name keeps only letters, digits and `._:/#+-`
/// (anything else becomes `_`), so the line always parses.
func marginLine(_ name: String, _ kind: MarginKind, value: Double, bound: Double?, unit: String = "s") -> String {
    let safe = String(name.map { $0.isLetter || $0.isNumber || "._:/#+-".contains($0) ? $0 : "_" })
    let b = kind == .time ? "-" : bound.map { String(format: "%.3f", $0) } ?? "-"
    return "kajo-margin name=\(safe) kind=\(kind.rawValue) value=\(String(format: "%.3f", value)) bound=\(b) unit=\(unit)"
}

/// Prints the margin line (stdout, one `print`).
func printMargin(_ name: String, _ kind: MarginKind, value: Double, bound: Double?, unit: String = "s") {
    print(marginLine(name, kind, value: value, bound: bound, unit: unit))
}

/// The largest fraction (the largest value, for a time) printed so far per
/// name in this process.
private let largestMargins = Mutex<[String: Double]>([:])

/// Prints the margin line only when its fraction is larger than any printed
/// before under the name in this process: a site called thousands of times
/// a run (the random programs) prints a handful of lines, the last of them
/// its largest, which is the one the reader keeps.
func printLargestMargin(_ name: String, _ kind: MarginKind, value: Double, bound: Double?, unit: String = "s") {
    let f = kind == .time ? value : bound.map { value / $0 } ?? value
    let larger = largestMargins.withLock { d -> Bool in
        if let old = d[name], old >= f { return false }
        d[name] = f
        return true
    }
    if larger { printMargin(name, kind, value: value, bound: bound, unit: unit) }
}

/// A test function's name as `#function` gives it, without its parameters.
func marginTest(_ function: String) -> String { String(function.prefix { $0 != "(" }) }

/// The fields of a margin line, as scripts/margins.py reads them (the
/// helper's own test).
func parseMarginLine(_ line: String) -> (name: String, kind: MarginKind, value: Double, bound: Double?, unit: String)? {
    let t = line.split(separator: " ")
    guard t.count == 6, t[0] == "kajo-margin" else { return nil }
    var kv: [String: String] = [:]
    for (want, tok) in zip(["name", "kind", "value", "bound", "unit"], t.dropFirst()) {
        let p = tok.split(separator: "=", maxSplits: 1)
        guard p.count == 2, p[0] == want else { return nil }
        kv[want] = String(p[1])
    }
    guard let k = MarginKind(rawValue: kv["kind"]!), let v = Double(kv["value"]!) else { return nil }
    let b = kv["bound"] == "-" ? nil : Double(kv["bound"]!)
    guard (k == .time) == (b == nil) else { return nil }
    return (kv["name"]!, k, v, b, kv["unit"]!)
}

/// The helper and the reader agree on the shape: the committed sample line
/// parses to its fields, and the helper prints exactly that line for them.
@Test func aMarginLineParsesBackToWhatTheHelperPrinted() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("KajoCompilerTests/Fixtures/margins/sample-line.txt")
    let sample = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .newlines)
    let m = try #require(parseMarginLine(sample))
    #expect(m.name == "Sample.until.ready" && m.kind == .quiet && m.value == 12.5 && m.bound == 60 && m.unit == "s")
    #expect(marginLine(m.name, m.kind, value: m.value, bound: m.bound, unit: m.unit) == sample)
    let t = marginLine("a body time", .time, value: 17.25, bound: 99)
    #expect(t == "kajo-margin name=a_body_time kind=time value=17.250 bound=- unit=s")
    #expect(parseMarginLine(t)?.bound == nil)
}
