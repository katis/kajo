import Foundation
import KajoCompiler
import KajoVM

let usage = """
usage: kajo run <file.kasm>... [--workers N] [--heap MiB] [--entries N]
                [--stress every,tiny,oneblock,preempt,stop,tinynursery,promoteall,scavenge]
                [--slice-ms 5] [--nursery KiB] [--survivor KiB] [--age N] [--verify]
                [--gc cm|stw] [--stress cycle,alwayson,neverapply] [--floor 0.6]
                [--safety 2] [--escalate-below 0.25] [--reloc on|off]
                [--stress everyblock,everycycle] [--reloc-threshold 0.5]
                [--reloc-cap 0.5] [--sample-ms N] [--young stw|local|offload]
                [--stress everyhalf,everypoll,barrieron] [--main-ms N|-1 --main-alloc N --main-work N]
                [--snapshot-at N --snapshot-to out.img]
       kajo run <image.img> [the options above]
       kajo build-image [-o kernel.img] [--no-init] [<dir or file.st>...]   (default: kernel/)
       kajo test [image.img] [--filter pattern] [--tag tag] [--junit path] [--workers N] [--heap MiB]
       kajo version

run: loads the kasm files in order into a fresh image (or loads an image),
runs one Process per worker sending run: i of: workers to nil (to the
image's entry point), and prints one key=value line: the sum of their
answers, the run time, the counters, per-worker QoS and the stops.
--snapshot-at N saves the image with every Process in it at the run's N-th
slow poll to --snapshot-to. An image with saved Processes is resumed
instead: its Processes run until nothing can happen without the host, and
the checksum is the sum of what those that ended answered.

build-image: compiles Tonel class files (a directory's *.st) with the
bootstrap compiler into a verified image.

test: runs the image's TestCases (built from kernel/ when no image is given)
and writes the NDJSON event stream on stdout, a summary on stderr, and JUnit
XML with --junit. Exit status 0 when every test passed, 1 otherwise.
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
            options.nurseryStress = v.filter { ["tinynursery", "promoteall", "scavenge"].contains($0) }.joined(separator: ",")
            options.markingStress = v.filter { ["cycle", "alwayson", "neverapply"].contains($0) }.joined(separator: ",")
            options.relocationStress = v.filter { ["everyblock", "everycycle"].contains($0) }.joined(separator: ",")
            options.youngStress = v.filter { ["everyhalf", "everypoll", "barrieron"].contains($0) }.joined(separator: ",")
        case "--nursery": options.nurseryKB = Int(value()) ?? -1
        case "--survivor": options.survivorKB = Int(value()) ?? -1
        case "--age": options.age = Int(value()) ?? 0
        case "--slice-ms": options.sliceMs = Double(value()) ?? 5
        case "--verify": options.verify = true
        case "--gc": options.gc = value()
        case "--floor": options.floor = Double(value()) ?? 0.6
        case "--safety": options.safetyFactor = Double(value()) ?? 2
        case "--escalate-below": options.escalateBelow = Double(value()) ?? 0.25
        case "--reloc": options.relocation = value()
        case "--reloc-threshold": options.relocationThreshold = Double(value()) ?? 0.5
        case "--reloc-cap": options.relocationCap = Double(value()) ?? 0.5
        case "--sample-ms": options.sampleMs = Int(value()) ?? 0
        case "--young": options.young = value()
        case "--main-ms": options.mainMs = Int(value()) ?? 0
        case "--main-alloc": options.mainAlloc = Int(value()) ?? 0
        case "--main-work": options.mainWork = Int(value()) ?? 0
        case "--snapshot-at": options.snapshotAt = Int(value()) ?? 0
        case "--snapshot-to": options.snapshotTo = value()
        case let a where a.hasPrefix("--"): fail("unknown option \(a)\n\(usage)")
        default: paths.append(args[i])
        }
        i += 1
    }
    if paths.isEmpty { fail(usage) }
    var files: [(path: String, text: String)] = []
    var imageBytes: [UInt8]? = nil
    for p in paths {
        guard let data = FileManager.default.contents(atPath: p) else { fail("cannot read \(p)") }
        if Headless.isImage([UInt8](data)) {
            guard paths.count == 1 else { fail("an image runs alone") }
            imageBytes = [UInt8](data)
            break
        }
        guard let text = String(data: data, encoding: .utf8) else { fail("cannot read \(p)") }
        files.append((p, text))
    }
    // The Transcript on stderr, a line per event.
    options.events = { line in
        if let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], o["kind"] as? String == "transcript" {
            FileHandle.standardError.write(((o["text"] as? String ?? "") + "\n").data(using: .utf8)!)
        }
    }
    let outcome = imageBytes.map { Headless.run(image: $0, options: options) } ?? Headless.run(files, options: options)
    switch outcome.checksum {
    case .success(let checksum):
        let counters = outcome.counters.map { "\($0.name)=\($0.value)" }.joined(separator: " ")
        let report = outcome.report.map { "\($0.name)=\($0.value)" }.joined(separator: " ")
        print("checksum=\(checksum) ms=\(String(format: "%.1f", outcome.milliseconds)) workers=\(options.workers) \(counters) \(report)")
    case .failure(let f):
        fail("kajo: \(f)", 1)
    }
case "build-image":
    var out = "kernel.img"
    var dirs: [String] = []
    var options = KernelBuild.Options()
    var i = 0
    while i < args.count {
        switch args[i] {
        case "-o":
            i += 1
            guard i < args.count else { fail(usage) }
            out = args[i]
        case "--no-init": options.initialize = false
        case "--heap":
            i += 1
            guard i < args.count, let n = Int(args[i]) else { fail(usage) }
            options.heapMiB = n
        case let a where a.hasPrefix("-"): fail("unknown option \(a)\n\(usage)")
        default: dirs.append(args[i])
        }
        i += 1
    }
    if dirs.isEmpty { dirs = ["kernel"] }
    do {
        let t0 = Date()
        let r = try KernelBuild.build(KernelBuild.sources(in: dirs), options: options)
        for w in r.warnings { FileHandle.standardError.write((w + "\n").data(using: .utf8)!) }
        guard FileManager.default.createFile(atPath: out, contents: Data(r.image)) else { fail("cannot write \(out)") }
        print("\(out): \(r.classes) classes, \(r.methods) methods, \(r.image.count) bytes, \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000)) ms")
    } catch {
        fail("kajo build-image: \(error)", 1)
    }
case "test":
    runTests(args)
default:
    fail(usage)
}
