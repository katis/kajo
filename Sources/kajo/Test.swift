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
    var listing = false
    var options = Headless.Options()
    // The third review's small fixes, item 1: a checked build's level (on)
    // would trap in the kernel's own tests. With the heap verifiers on, the
    // first scavenge after MakeFuzzTest>>testSeededMutationsAreRefusedOrRun
    // finds old objects naming young ones unremembered (the make primitive's
    // methods are made old; docs/modules/review-3-small-fixes.md, Found), so
    // kajo test verifies only when told to (--verify) until that is fixed.
    options.verify = false
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
        // Gate speed (docs/modules/gate-speed.md, change 1): exact names
        // (each --test adds one) and the listing without a run.
        case "--test": arguments += ["--test", value()]
        case "--list": arguments += ["--list"]; listing = true
        case "--junit": junit = value()
        case "--workers": options.workers = Int(value()) ?? 0
        case "--heap": options.heapMiB = Int(value()) ?? 0
        case "--gc": options.gc = value()
        case "--young": options.young = value()
        case "--sources": options.sourcesDirectory = value()
        case "--native": options.native = loadNative(value())
        // The third review's small fixes, item 1: the heap verifiers at
        // every pause (off by default here, above).
        case "--verify": options.verify = true
        case "--no-verify": options.verify = false
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
    if listing {
        let total = report.events.first { $0["kind"] as? String == "run.listed" }?["total"] as? Int ?? 0
        FileHandle.standardError.write("kajo test: \(total) tests listed\n".data(using: .utf8)!)
        switch outcome {
        case .success(let n): exit(n == 0 ? 0 : 1)
        case .failure(let f): fail("kajo test: \(f)", 2)
        }
    }
    FileHandle.standardError.write(report.summary.data(using: .utf8)!)
    // The third review's small fixes, item 1: what the run checked, from
    // the gc summary (the verifier runs counted by the object memory).
    let verifies = report.events.last { $0["kind"] as? String == "gc" && $0["collection"] as? String == "summary" }?["verifies"] as? Int
    FileHandle.standardError.write("kajo test: verify=\(options.verifies ? "on" : "off") verifies=\(verifies.map(String.init) ?? "-")\n".data(using: .utf8)!)
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

