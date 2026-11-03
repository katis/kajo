import Foundation

/// What `kajo test` derives from the event stream at the end of a run: the
/// human summary (stderr) and JUnit XML (`--junit`). One source of truth:
/// both read only the events.
public struct TestReport: @unchecked Sendable {
    public let events: [[String: Any]]
    public private(set) var total = 0, passed = 0, failed = 0, errored = 0, microseconds = 0
    public private(set) var failures: [String] = []

    /// The NDJSON lines as they came (lines that are not JSON objects are
    /// skipped).
    public init(_ lines: [[UInt8]]) {
        events = lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
        for e in events {
            switch e["kind"] as? String {
            case "run.finished":
                total = e["total"] as? Int ?? 0
                passed = e["passed"] as? Int ?? 0
                failed = e["failed"] as? Int ?? 0
                errored = e["errored"] as? Int ?? 0
                microseconds = e["us"] as? Int ?? 0
            case "test.failed", "test.errored":
                let kind = e["kind"] as? String == "test.failed" ? "FAIL " : "ERROR"
                failures.append("\(kind) \(e["test"] as? String ?? "?"): \(e["message"] as? String ?? "")")
            default:
                break
            }
        }
    }

    public var summary: String {
        var s = failures.joined(separator: "\n")
        if !s.isEmpty { s += "\n" }
        return s + "kajo test: \(total) tests, \(passed) passed, \(failed) failed, \(errored) errored in \(microseconds / 1000) ms\n"
    }

    public var junitXML: String { TestReport.junitXML(events) }
}

func xmlEscaped(_ s: String) -> String {
    var out = ""
    for c in s.unicodeScalars {
        switch c {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "'": out += "&apos;"
        default:
            if c.value < 32 && c != "\n" && c != "\t" { out += " " } else { out.unicodeScalars.append(c) }
        }
    }
    return out
}

extension TestReport {
/// JUnit XML from the events: a testsuite per class, a testcase per test,
/// failure and error elements with the message and the frames, the
/// transcript as system-out.
static func junitXML(_ events: [[String: Any]]) -> String {
    var suites: [String: [(name: String, seconds: Int, body: String)]] = [:]
    var order: [String] = []
    var transcript: [String] = []
    var fails = 0, errs = 0
    for e in events {
        let kind = e["kind"] as? String ?? ""
        if kind == "transcript" { transcript.append(e["text"] as? String ?? "") }
        guard kind == "test.passed" || kind == "test.failed" || kind == "test.errored" else { continue }
        let cls = e["class"] as? String ?? "?"
        if suites[cls] == nil { order.append(cls); suites[cls] = [] }
        let seconds = e["us"] as? Int ?? 0
        var body = ""
        if kind != "test.passed" {
            let tag = kind == "test.failed" ? "failure" : "error"
            if tag == "failure" { fails += 1 } else { errs += 1 }
            let frames = (e["frames"] as? [String] ?? []).joined(separator: "\n")
            body = "<\(tag) message=\"\(xmlEscaped(e["message"] as? String ?? ""))\" type=\"\(xmlEscaped(e["exception"] as? String ?? ""))\">\(xmlEscaped(frames))</\(tag)>"
        }
        suites[cls]!.append((e["selector"] as? String ?? "?", seconds, body))
    }
    let total = suites.values.reduce(0) { $0 + $1.count }
    var x = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    x += "<testsuites name=\"kajo\" tests=\"\(total)\" failures=\"\(fails)\" errors=\"\(errs)\">\n"
    for cls in order {
        let cases = suites[cls]!
        let f = cases.filter { $0.body.hasPrefix("<failure") }.count, er = cases.filter { $0.body.hasPrefix("<error") }.count
        let t = cases.reduce(0) { $0 + $1.seconds }
        x += "  <testsuite name=\"\(xmlEscaped(cls))\" tests=\"\(cases.count)\" failures=\"\(f)\" errors=\"\(er)\" time=\"\(seconds(t))\">\n"
        for c in cases {
            x += "    <testcase classname=\"\(xmlEscaped(cls))\" name=\"\(xmlEscaped(c.name))\" time=\"\(seconds(c.seconds))\""
            x += c.body.isEmpty ? "/>\n" : ">\(c.body)</testcase>\n"
        }
        x += "  </testsuite>\n"
    }
    x += "  <system-out>\(xmlEscaped(transcript.joined(separator: "\n")))</system-out>\n</testsuites>\n"
    return x
}
}

/// Microseconds as seconds with six decimals (no String(format:): it is
/// not safe code).
func seconds(_ us: Int) -> String {
    let frac = String(us % 1_000_000)
    return "\(us / 1_000_000)." + String(repeating: "0", count: 6 - frac.count) + frac
}
