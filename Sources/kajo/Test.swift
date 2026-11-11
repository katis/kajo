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
        case "--sources": options.sourcesDirectory = value()
        case "--native": options.native = loadNative(value())
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
    let report = TestReport(events)
    FileHandle.standardError.write(report.summary.data(using: .utf8)!)
    // AOT 1: the native engine's counts (bound, interpreted, declined, switches).
    for e in events where e.starts(with: Array("{\"v\":1,\"kind\":\"native\"".utf8)) {
        FileHandle.standardError.write(Data(Array("native: ".utf8) + e + [10]))
    }
    if Headless.isReleaseImage(bytes) == true { FileHandle.standardError.write("kajo test: a release image\n".data(using: .utf8)!) }
    let failed = report.failed, errored = report.errored
    if let junit {
        guard FileManager.default.createFile(atPath: junit, contents: report.junitXML.data(using: .utf8)) else {
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
    private var lines: [[UInt8]] = []

    func add(_ line: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardOutput.write(Data(line + [10]))
        lines.append(line)
    }

    var events: [[UInt8]] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

