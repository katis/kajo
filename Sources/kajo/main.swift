import Foundation
import KajoCompiler
import KajoDev
import KajoGenerator
import KajoAOT
import KajoVM

let usage = """
usage: kajo run <file.kasm>... [--workers N] [--heap MiB] [--entries N]
                [--stress every,tiny,oneblock,preempt,stop,tinynursery,promoteall,scavenge]
                [--slice-ms 5] [--nursery KiB] [--survivor KiB] [--age N] [--verify]
                [--gc cm|stw] [--stress cycle,alwayson,neverapply] [--floor 0.6]
                [--safety 2] [--escalate-below 0.25] [--sweep-stop-words n|-1] [--entry-rate on|off] [--reloc on|off]
                [--stalls on|off] [--marker-slowdown N]
                [--stress everyblock,everycycle] [--reloc-threshold 0.5]
                [--reloc-cap 0.5] [--sample-ms N] [--young stw|local|offload]
                [--stress everyhalf,everypoll,barrieron] [--main-ms N|-1 --main-alloc N --main-work N]
                [--snapshot-at N --snapshot-to out.img] [--sources dir]
       kajo run <image.img> [the options above]
       kajo run <image.img> --protocol <socket>|tcp[:port] [--name <Bonjour name>] [the options above]
       kajo build-image [-o kernel.img] [--no-init] [--release] [--with <dir>]... [<dir or file.st>...]   (default: kernel/)
       kajo seal <in.img> <out.img>
       kajo test [image.img] [--filter pattern] [--tag tag] [--junit path] [--workers N] [--heap MiB] [--sources dir]
       kajo new <Name> --bundle-id <id> --kajo <checkout> [--team <id>] [--directory <dir>] [--platforms macOS,iOS]
       kajo aot <file.kasm>...|<image.img> -o <dir>
       kajo run ... --native <module.dylib>
       kajo version
\(clientUsage)

run: loads the kasm files in order into a fresh image (or loads an image),
runs one Process per worker sending run: i of: workers to nil (to the
image's entry point), and prints one key=value line: the sum of their
answers, the run time, the counters, per-worker QoS and the stops.
--snapshot-at N saves the image with every Process in it at the run's N-th
slow poll to --snapshot-to. An image with saved Processes is resumed
instead: its Processes run until nothing can happen without the host, and
the checksum is the sum of what those that ended answered. --sources dir
opens a directory to Smalltalk's file primitives (Smalltalk writeTonel:,
readTonelFile:): they read and write under it and nowhere else; without
it they fail.

build-image: compiles Tonel class files (a directory's *.st) with the
bootstrap compiler into a verified image. --with <dir> (repeatable) adds a
package directory to kernel/ (or to the directories named): a development
image is kernel/ --with tools (module 9c), each class recording its
package.

run --protocol: a development target (module 9b): the image serves the
development protocol on the Unix socket until interrupted, prints the
socket and the pairing token a client opens its session with, and prints
the Transcript and every stopped Process on stderr. Release images refuse.
--protocol tcp[:port] (module 9d) serves on TCP instead, on every
interface, advertised with Bonjour as _kajo-dev._tcp (--name, or this
Mac's name), and prints the port and the addresses with the token. --release marks it a release
image: Smalltalk cannot make, install or remove methods in it.

new (module 11a, 11b): writes a Kajo app project into <dir> (default
./<Name>, which must be empty or absent): an xcodegen spec with
<Name>-macOS and <Name>-iOS (or the one --platforms names) over one Tonel
directory (src/, the package <Name> with the class <Name>App and its
test), the Swift the targets run, the Info.plists (only Debug's name the
local network), the build phase that makes a development image (Debug) or
a release image (Release) with the checkout's prebuilt kajo, and the Xcode
project when xcodegen is found. --kajo names a Kajo distribution checkout
(Prebuilt/ with the Release frameworks and kajo; the Kajo app copies its
own to Application Support, scripts/dist.sh makes one).

aot (AOT 1): reads an image (or the kasm files `run` would load) and writes
the native engine's C for every method to <dir> (kajo_native.h and the
kajo_native_*.c files); compile them with clang into a dylib and pass it to
`run --native` (or `test --native`).
A method whose bytecodes changed since runs interpreted.

seal: loads an image (every loader check), marks it a release image and
saves it to <out.img>. Nothing clears the mark.

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
    var protocolSocket: String? = nil
    var serviceName: String? = nil
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
        case "--sweep-stop-words": options.sweepStopWords = Int(value())
        case "--entry-rate": options.entryRateRule = value() != "off"
        case "--marker-slowdown": options.markerSlowdown = Int(value()) ?? 1
        case "--stalls": options.stalls = value() != "off"
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
        case "--sources": options.sourcesDirectory = value()
        case "--protocol": protocolSocket = value()
        case "--name": serviceName = value()
        case "--native": options.native = loadNative(value())
        case let a where a.hasPrefix("--"): fail("unknown option \(a)\n\(usage)")
        default: paths.append(args[i])
        }
        i += 1
    }
    if paths.isEmpty { fail(usage) }
    if let socket = protocolSocket {
        guard paths.count == 1, let data = FileManager.default.contents(atPath: paths[0]), Headless.isImage([UInt8](data)) else {
            fail("--protocol serves an image")
        }
        serveTarget(image: [UInt8](data), options: options, socket: socket, name: serviceName)
    }
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
        print("checksum=\(checksum) ms=\(oneDecimal(outcome.milliseconds)) workers=\(options.workers) \(counters) \(report)")
    case .failure(let f):
        fail("kajo: \(f)", 1)
    }
case "build-image":
    var out = "kernel.img"
    var dirs: [String] = []
    var with: [String] = []
    var options = KernelBuild.Options()
    var i = 0
    while i < args.count {
        switch args[i] {
        case "-o":
            i += 1
            guard i < args.count else { fail(usage) }
            out = args[i]
        case "--with":
            i += 1
            guard i < args.count else { fail(usage) }
            with.append(args[i])
        case "--no-init": options.initialize = false
        case "--release": options.release = true
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
    dirs += with
    do {
        let t0 = Date()
        let r = try KernelBuild.build(KernelBuild.sources(in: dirs), options: options)
        for w in r.warnings { FileHandle.standardError.write((w + "\n").data(using: .utf8)!) }
        guard FileManager.default.createFile(atPath: out, contents: Data(r.image)) else { fail("cannot write \(out)") }
        print("\(out): \(r.classes) classes, \(r.methods) methods, \(r.image.count) bytes, \(Int((Date().timeIntervalSince(t0) * 1000).rounded())) ms\(options.release ? ", release image" : "")")
    } catch {
        fail("kajo build-image: \(error)", 1)
    }
case "new":
    var spec = AppProjectSpec(name: "", bundleIdentifier: "", kajo: .path(""))
    var path: String? = nil, directory: String? = nil
    var i = 0
    func value() -> String {
        i += 1
        guard i < args.count else { fail("\(args[i - 1]) needs a value\n\(usage)") }
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--bundle-id": spec.bundleIdentifier = value()
        case "--team": spec.team = value()
        case "--kajo": path = value()
        case "--directory": directory = value()
        case "--platforms":
            let names = value().split(separator: ",").map(String.init)
            let ps = names.compactMap(AppPlatform.init(rawValue:))
            guard ps.count == names.count else { fail("kajo new: --platforms takes macOS, iOS or macOS,iOS") }
            spec.platforms = AppPlatform.allCases.filter(ps.contains)
        case let a where a.hasPrefix("-"): fail("unknown option \(a)\n\(usage)")
        default:
            guard spec.name.isEmpty else { fail("one name\n\(usage)") }
            spec.name = args[i]
        }
        i += 1
    }
    guard !spec.name.isEmpty, !spec.bundleIdentifier.isEmpty else { fail(usage) }
    guard let p = path else { fail("kajo new: where Kajo comes from: --kajo <checkout>") }
    // A relative checkout is taken from the current directory.
    spec.kajo = .path(p.hasPrefix("/") ? p : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(p))
    if let r = AppProjectGenerator.check(spec) ?? AppProjectGenerator.checkCheckout(spec.kajo) { fail("kajo new: \(r)", 1) }
    let dir: String
    switch AppProjectGenerator.resolve(directory ?? spec.name, base: FileManager.default.currentDirectoryPath) {
    case .success(let d): dir = d
    case .failure(let r): fail("kajo new: \(r)", 1)
    }
    switch AppProjectGenerator.write(spec, into: dir) {
    case .success(let files):
        print("\(dir): \(files.count) files")
        do {
            // The Kajo app's, when this kajo is its Contents/Helpers/kajo.
            let bundled = ((CommandLine.arguments[0] as NSString).resolvingSymlinksInPath as NSString).deletingLastPathComponent + "/../Resources/xcodegen/bin/xcodegen"
            print(try AppProjectGenerator.generateXcodeProject(in: dir, xcodegen: bundled) ? "\(dir)/\(spec.name).xcodeproj" : "no xcodegen on PATH: run `xcodegen generate` in \(dir)")
        } catch {
            fail("kajo new: \(error)", 1)
        }
    case .failure(let r): fail("kajo new: \(r)", 1)
    }
case "aot":
    runAOT(args)
case "seal":
    guard args.count == 2 else { fail(usage) }
    guard let data = FileManager.default.contents(atPath: args[0]) else { fail("cannot read \(args[0])") }
    switch Headless.seal(image: [UInt8](data)) {
    case .success(let b):
        guard FileManager.default.createFile(atPath: args[1], contents: Data(b)) else { fail("cannot write \(args[1])") }
        print("\(args[1]): release image, \(b.count) bytes")
    case .failure(let f):
        fail("kajo seal: \(f)", 1)
    }
case "test":
    if args.contains("--target") { exit(runClientCommand("test", args)) }
    runTests(args)
case "eval", "compile", "browse", "debug", "request", "mcp":
    exit(runClientCommand(command, args))
default:
    fail(usage)
}

/// AOT 1: `--native <dylib>`.
func loadNative(_ path: String) -> NativeModule {
    switch NativeModule.load(dylib: path) {
    case .success(let m): return m
    case .failure(let e): fail("kajo: \(e)")
    }
}

/// AOT 1: `kajo aot <inputs> -o <dir>`.
func runAOT(_ args: [String]) {
    var out: String? = nil
    var paths: [String] = []
    var options = AOTOptions()
    var i = 0
    while i < args.count {
        if args[i] == "-o" {
            i += 1
            guard i < args.count else { fail(usage) }
            out = args[i]
        } else if args[i] == "--return-marker" {
            options.returnByLookup = false
        } else if args[i].hasPrefix("--no-") {
            // Part 3's steps, each switchable for its measurement.
            switch args[i] {
            case "--no-inline-stores": options.inlineStores = false
            case "--no-inline-closures": options.inlineClosures = false
            default: fail("unknown option \(args[i])\n\(usage)")
            }
        } else if args[i].hasPrefix("-") {
            fail("unknown option \(args[i])\n\(usage)")
        } else {
            paths.append(args[i])
        }
        i += 1
    }
    guard let dir = out, !paths.isEmpty else { fail(usage) }
    var files: [(path: String, text: String)] = []
    var imageBytes: [UInt8]? = nil
    for p in paths {
        guard let data = FileManager.default.contents(atPath: p) else { fail("cannot read \(p)") }
        if Headless.isImage([UInt8](data)) {
            guard paths.count == 1 else { fail("an image is generated from alone") }
            imageBytes = [UInt8](data)
            break
        }
        guard let text = String(data: data, encoding: .utf8) else { fail("cannot read \(p)") }
        files.append((p, text))
    }
    let t0 = Date()
    let image: Image
    switch Headless.imageForNative(files: files, image: imageBytes) {
    case .success(let im): image = im
    case .failure(let f): fail("kajo aot: \(f)", 1)
    }
    defer { image.close() }
    let infos = image.nativeMethodInfos()
    let t1 = Date()
    let o = AOTGenerator.generate(infos, nilOop: image.nilOop, trueOop: image.trueOop, falseOop: image.falseOop, options: options)
    let t2 = Date()
    do {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    } catch {
        fail("kajo aot: cannot create \(dir)", 1)
    }
    for f in o.files {
        let path = (dir as NSString).appendingPathComponent(f.name)
        guard FileManager.default.createFile(atPath: path, contents: Data(f.text.utf8)) else { fail("kajo aot: cannot write \(path)", 1) }
    }
    let path = "\(dir): \(o.files.count) files"
    for d in o.declined { FileHandle.standardError.write("declined: \(d.name): \(d.reason)\n".data(using: .utf8)!) }
    print("\(path): methods=\(o.methods) groups=\(o.groups) declined=\(o.declined.count) resumePoints=\(o.resumePoints) bytes=\(o.source.utf8.count) readMs=\(Int(t1.timeIntervalSince(t0) * 1000)) generateMs=\(Int(t2.timeIntervalSince(t1) * 1000))")
}

/// `kajo run <image> --protocol <socket>`: serve until SIGINT or SIGTERM.
func serveTarget(image: [UInt8], options: Headless.Options, socket: String, name: String?) -> Never {
    let target: DevTarget
    var listen = DevTarget.Listen.unix(socket)
    if socket == "tcp" || socket.hasPrefix("tcp:") {
        guard let port = Int(socket == "tcp" ? "0" : String(socket.dropFirst(4))), (0...65535).contains(port) else { fail("--protocol tcp:<port>") }
        listen = .tcp(port: port, loopbackOnly: false, advertise: true, name: name)
    }
    do {
        target = try DevTarget(image: image, options: options, listen: listen) { line in
            // The Transcript (a stopped Process prints its line there) on stderr.
            if let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], o["kind"] as? String == "transcript" {
                FileHandle.standardError.write(((o["text"] as? String ?? "") + "\n").data(using: .utf8)!)
            }
        }
    } catch {
        fail("kajo run: \(error)", 1)
    }
    if let port = target.server.port {
        print("kajo: development protocol on tcp port \(port): \(localAddresses().map { $0.contains(":") ? "tcp://[\($0)]:\(port)" : "tcp://\($0):\(port)" }.joined(separator: " "))")
    } else {
        print("kajo: development protocol on \(socket)")
    }
    print("kajo: token \(target.server.token)")
    // C's stdout is a global the strict memory safety check calls unsafe:
    // the one unsafe construct of this target (the review fixes, part 2,
    // item 12).
    unsafe fflush(stdout)
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let sources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
        let s = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        s.setEventHandler { target.stop() }
        s.resume()
        return s
    }
    target.run()
    _ = sources
    target.close()
    exit(0)
}

/// `x` with one decimal, as `%.1f` wrote it (String(format:) takes C
/// varargs, which strict memory safety calls unsafe).
func oneDecimal(_ x: Double) -> String {
    let n = Int((x * 10).rounded())
    return "\(n < 0 && n > -10 ? "-" : "")\(n / 10).\(abs(n % 10))"
}
