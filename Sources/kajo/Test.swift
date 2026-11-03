import Foundation
import KajoCompiler
import KajoVM

/// `kajo test`: the event stream on stdout as it happens (one JSON object
/// per line), then a human summary on stderr and JUnit XML, both derived
/// from the same events.
func runTests(_ args: [String]) -> Never {
    var imagePath: String? = nil
    var arguments: [String] = []
    var junit: String? = nil
    var options = Headless.Options()
    var i = 0
    func value() -> String {
        i += 1
        guard i < args.count else { fail("\(args[i - 1]) needs a value\n\(usage)") }
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--filter": arguments += ["--filter", value()]
        case "--tag": arguments += ["--tag", value()]
        case "--junit": junit = value()
        case "--workers": options.workers = Int(value()) ?? 0
        case "--heap": options.heapMiB = Int(value()) ?? 0
        case "--gc": options.gc = value()
        case "--young": options.young = value()
        case let a where a.hasPrefix("--"): fail("unknown option \(a)\n\(usage)")
        default: imagePath = args[i]
        }
        i += 1
    }
    let bytes: [UInt8]
    if let imagePath {
        guard let data = FileManager.default.contents(atPath: imagePath) else { fail("cannot read \(imagePath)") }
        bytes = [UInt8](data)
    } else {
        do {
            let r = try KernelBuild.build(KernelBuild.sources(in: ["kernel"]))
            for w in r.warnings { FileHandle.standardError.write((w + "\n").data(using: .utf8)!) }
            bytes = r.image
        } catch {
            fail("kajo test: building kernel/: \(error)", 2)
        }
    }
    let collector = EventCollector()
    let outcome = Headless.test(image: bytes, arguments: arguments, options: options) { collector.add($0) }
    let events = collector.events
    var total = 0, passed = 0, failed = 0, errored = 0, us = 0
    var failures: [String] = []
    for e in events {
        switch e["kind"] as? String {
        case "run.finished":
            total = e["total"] as? Int ?? 0
            passed = e["passed"] as? Int ?? 0
            failed = e["failed"] as? Int ?? 0
            errored = e["errored"] as? Int ?? 0
            us = e["us"] as? Int ?? 0
        case "test.failed", "test.errored":
            let kind = e["kind"] as? String == "test.failed" ? "FAIL " : "ERROR"
            failures.append("\(kind) \(e["test"] as? String ?? "?"): \(e["message"] as? String ?? "")")
        default:
            break
        }
    }
    var summary = failures.joined(separator: "\n")
    if !summary.isEmpty { summary += "\n" }
    summary += "kajo test: \(total) tests, \(passed) passed, \(failed) failed, \(errored) errored in \(us / 1000) ms\n"
    FileHandle.standardError.write(summary.data(using: .utf8)!)
    if let junit {
        guard FileManager.default.createFile(atPath: junit, contents: junitXML(events).data(using: .utf8)) else {
            fail("cannot write \(junit)", 2)
        }
    }
    switch outcome {
    case .success(let n): exit(n == 0 && failed + errored == 0 ? 0 : 1)
    case .failure(let f): fail("kajo test: \(f)", 2)
    }
}

/// Writes each event to stdout as it arrives and keeps it for the summary.
final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var parsed: [[String: Any]] = []

    func add(_ line: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardOutput.write(Data(line + [10]))
        if let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] { parsed.append(o) }
    }

    var events: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return parsed
    }
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

/// JUnit XML from the events: a testsuite per class, a testcase per test,
/// failure and error elements with the message and the frames, the
/// transcript as system-out.
func junitXML(_ events: [[String: Any]]) -> String {
    var suites: [String: [(name: String, seconds: Double, body: String)]] = [:]
    var order: [String] = []
    var transcript: [String] = []
    var fails = 0, errs = 0
    for e in events {
        let kind = e["kind"] as? String ?? ""
        if kind == "transcript" { transcript.append(e["text"] as? String ?? "") }
        guard kind == "test.passed" || kind == "test.failed" || kind == "test.errored" else { continue }
        let cls = e["class"] as? String ?? "?"
        if suites[cls] == nil { order.append(cls); suites[cls] = [] }
        let seconds = Double(e["us"] as? Int ?? 0) / 1e6
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
        x += "  <testsuite name=\"\(xmlEscaped(cls))\" tests=\"\(cases.count)\" failures=\"\(f)\" errors=\"\(er)\" time=\"\(String(format: "%.6f", t))\">\n"
        for c in cases {
            x += "    <testcase classname=\"\(xmlEscaped(cls))\" name=\"\(xmlEscaped(c.name))\" time=\"\(String(format: "%.6f", c.seconds))\""
            x += c.body.isEmpty ? "/>\n" : ">\(c.body)</testcase>\n"
        }
        x += "  </testsuite>\n"
    }
    x += "  <system-out>\(xmlEscaped(transcript.joined(separator: "\n")))</system-out>\n</testsuites>\n"
    return x
}
