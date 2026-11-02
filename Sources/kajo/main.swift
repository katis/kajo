import Foundation
import KajoVM

let usage = """
usage: kajo run <file.kasm>... [--workers N] [--heap MiB] [--entries N] [--stress every,tiny,oneblock,preempt,stop]
                [--slice-ms 5] [--verify]
       kajo version

Loads the files in order into a fresh image, runs one Process per worker
sending run: i of: workers to nil, and prints one key=value line: the sum
of their answers, the run time, the counters, per-worker QoS and the stops.
"""

func fail(_ message: String, _ code: Int32 = 2) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail(usage) }
args.removeFirst()

switch command {
case "version", "--version":
    print("kajo \(KajoVM.version)")
case "run":
    var options = Headless.Options()
    var paths: [String] = []
    var i = 0
    func value() -> String {
        i += 1
        guard i < args.count else { fail("\(args[i - 1]) needs a value\n\(usage)") }
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--workers": options.workers = Int(value()) ?? 0
        case "--heap": options.heapMiB = Int(value()) ?? 0
        case "--entries": options.entries = Int(value()) ?? 0
        case "--stress":
            let v = value().split(separator: ",")
            options.stress = v.filter { ["every", "tiny", "oneblock", "all"].contains($0) }.joined(separator: ",")
            options.vmStress = v.filter { ["preempt", "stop"].contains($0) }.joined(separator: ",")
        case "--slice-ms": options.sliceMs = Double(value()) ?? 5
        case "--verify": options.verify = true
        case let a where a.hasPrefix("--"): fail("unknown option \(a)\n\(usage)")
        default: paths.append(args[i])
        }
        i += 1
    }
    if paths.isEmpty { fail(usage) }
    var files: [(path: String, text: String)] = []
    for p in paths {
        guard let text = try? String(contentsOfFile: p, encoding: .utf8) else { fail("cannot read \(p)") }
        files.append((p, text))
    }
    let outcome = Headless.run(files, options: options)
    switch outcome.checksum {
    case .success(let checksum):
        let counters = outcome.counters.map { "\($0.name)=\($0.value)" }.joined(separator: " ")
        let report = outcome.report.map { "\($0.name)=\($0.value)" }.joined(separator: " ")
        print("checksum=\(checksum) ms=\(String(format: "%.1f", outcome.milliseconds)) workers=\(options.workers) \(counters) \(report)")
    case .failure(let f):
        fail("kajo: \(f)", 1)
    }
default:
    fail(usage)
}
