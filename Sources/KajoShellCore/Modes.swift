import Darwin
import Dispatch
import Foundation
import KajoCompiler
import KajoApp
import KajoAppDevelopment
import KajoVM

/// The images and kernels a shell bundles (`apps/Shared/build-images.sh`
/// writes them into the app's resources under `kajo/`).
public struct ShellResources: Sendable {
    public let directory: String
    public init(directory: String) { self.directory = directory }
    public static var main: ShellResources { ShellResources(directory: (Bundle.main.resourcePath ?? ".") + "/kajo") }

    public var kernelImage: String { directory + "/kernel.img" }
    public var shellImage: String { directory + "/shell.img" }
    /// Module 9c: the development image (kernel/, tools/, the scenario
    /// loads and the scripted session), and the same with 2000 classes.
    public var devImage: String { directory + "/dev.img" }
    public var dev2000Image: String { directory + "/dev2000.img" }
    public func smalltalkImage(_ name: String) -> String { directory + "/st-\(name).img" }
    public func kasm(_ name: String) -> String { directory + "/kasm/\(name).kasm" }
}

/// `just golden`'s kernels and their single-worker checksums.
public enum GoldenKernels {
    public static let kasm: [(String, Int64)] = [
        ("arith", 372_800_000), ("fib", 24_682_992), ("sends", 1_066_666_666_666_668), ("alloc", 41_950_911),
        ("ivars", 36_383_626), ("walk", 9_016_009_025_388_544), ("storeheavy", 512_000), ("closures", 210_210_000),
        ("floats", 7_499_750_000),
    ]
    public static let smalltalk: [(String, Int64)] = [("sends", 1_066_666_666_666_668), ("ivars", 36_383_626), ("closures", 210_210_000)]
}

/// The launch's common prefix and the telemetry suffix.
public func resultLine(_ mode: String, _ options: LaunchOptions, _ body: String) -> String {
    "mode=\(mode) run=\(options.int("run", 1)) tag=\(options.string("tag", "-")) \(body)" + Telemetry.suffix()
}

/// Leave after the console has the last lines.
public func finish(_ code: Int32 = 0) -> Never {
    Output.shared.emit("DONE")
    unsafe fflush(stdout)
    usleep(300_000)
    exit(code)
}

// MARK: - golden

/// `mode=golden [kernel=name|all] [kind=kasm|st|all] [workers=N]`: the
/// kernels of `just golden` through Headless on this thread (a background
/// thread), one result line each with its checksum and time.
public func runGolden(_ options: LaunchOptions, resources: ShellResources = .main) {
    let which = options.string("kernel", "all")
    let kind = options.string("kind", "all")
    let workers = options.int("workers", 1)
    var o = Headless.Options()
    o.workers = workers
    o.heapMiB = options.int("heap", 1024)
    o.sliceMs = 0
    var failed = 0
    if kind == "all" || kind == "kasm" {
        for (name, want) in GoldenKernels.kasm where which == "all" || which == name {
            let paths = [resources.kasm("prelude"), resources.kasm("lib"), resources.kasm(name)]
            let files = paths.map { (path: $0, text: (try? String(contentsOfFile: $0, encoding: .utf8)) ?? "") }
            let t0 = Telemetry.thermal()
            let r = Headless.run(files, options: o)
            failed += emitGolden("kasm", name, want, workers, r, t0, options)
        }
    }
    if kind == "all" || kind == "st" {
        for (name, want) in GoldenKernels.smalltalk where which == "all" || which == name {
            let bytes = FileManager.default.contents(atPath: resources.smalltalkImage(name)).map { [UInt8]($0) } ?? []
            let t0 = Telemetry.thermal()
            let r = Headless.run(image: bytes, options: o)
            failed += emitGolden("st", name, want, workers, r, t0, options)
        }
    }
    Output.shared.emit(resultLine("golden", options, "summary=1 failed=\(failed)"))
}

private func emitGolden(_ kind: String, _ name: String, _ want: Int64, _ workers: Int, _ r: Headless.Outcome,
                        _ thermalStart: String, _ options: LaunchOptions) -> Int {
    let got: String
    var ok = 0
    switch r.checksum {
    case .success(let v):
        got = "\(v)"
        ok = workers == 1 ? (v == want ? 1 : 0) : -1  // -1: no published checksum at this count
    case .failure(let f): got = "error:" + "\(f)".replacingOccurrences(of: " ", with: "_")
    }
    let qos = r.report.first { $0.name == "qos" }?.value ?? "-"
    Output.shared.emit(resultLine("golden", options,
        "kind=\(kind) kernel=\(name) workers=\(workers) checksum=\(got) expected=\(workers == 1 ? "\(want)" : "-") ok=\(ok) ms=\(f1(r.milliseconds)) qos=\(qos) thermal_start=\(thermalStart)"))
    return ok == 0 ? 1 : 0
}

// MARK: - tests

/// `mode=tests [filter=pattern] [tag=tag]`: the kernel's SUnit tests in the
/// shell, with the platform's views behind the wrappers (ViewTest hops to
/// the main thread and goes through the real toolkit). The NDJSON stream to
/// stdout and `tests.ndjson`, the summary and `junit.xml` as `kajo test`
/// writes them, from the same events.
@MainActor public final class TestsMode {
    let options: LaunchOptions
    let platform: ShellPlatform
    var runtime: ShellRuntime?
    let collector = EventLines()

    let pairing: PairingPresenter?

    public init(_ options: LaunchOptions, platform: ShellPlatform, pairing: PairingPresenter? = nil) {
        self.pairing = pairing
        self.options = options
        self.platform = platform
    }

    public func start(resources: ShellResources = .main) {
        let dir = (Output.shared.filePath as NSString).deletingLastPathComponent
        let ndjson = (dir as NSString).appendingPathComponent(options.string("ndjson", "tests.ndjson"))
        FileManager.default.createFile(atPath: ndjson, contents: Data())
        let collector = self.collector
        let sink = makeTestSink(collector, ndjson)
        var o = Headless.Options()
        o.workers = options.int("workers", 2)
        o.heapMiB = options.int("heap", 512)
        do {
            let rt = try makeShellRuntime(imagePath: resources.kernelImage, options: o, platform: platform, events: sink, pairing: pairing)
            runtime = rt
            rt.start()
            let filter: ShellValue = options["filter"].map { .string($0) } ?? .nil
            let tag: ShellValue = options["testtag"].map { .string($0) } ?? .nil
            guard let p = rt.vm.spawn("testFilter:tag:", arguments: [filter, tag]) else {
                Output.shared.emit(resultLine("tests", options, "FAILED=1 error=spawn"))
                finish(2)
            }
            let t0 = ShellVM.now()
            let thermal0 = Telemetry.thermal()
            waitThenFinish(rt.vm, p, t0, thermal0, dir, collector, options)
        } catch {
            Output.shared.emit(resultLine("tests", options, "FAILED=1 error=\("\(error)".replacingOccurrences(of: " ", with: "_"))"))
            finish(2)
        }
    }
}

/// Collected NDJSON lines.
public final class EventLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [[UInt8]] = []
    public init() {}
    public func add(_ l: [UInt8]) { lock.lock(); lines.append(l); lock.unlock() }
    public var all: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return lines }
}

/// Built outside the main actor: runs on VM threads.
nonisolated func makeTestSink(_ c: EventLines, _ path: String) -> @Sendable ([UInt8]) -> Void {
    let lock = NSLock()
    return { line in
        c.add(line)
        lock.lock()
        FileHandle.standardOutput.write(Data(line + [10]))
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(Data(line + [10]))
            try? h.close()
        }
        lock.unlock()
    }
}

/// Wait for the test Process on a background thread, then report and exit.
nonisolated func waitThenFinish(_ vm: ShellVM, _ p: ShellProcess, _ t0: UInt64, _ thermal0: String, _ dir: String,
                                _ collector: EventLines, _ options: LaunchOptions) {
    let t = Thread {
        vm.waitUntilTerminated(p)
        let ms = Double(ShellVM.now() - t0) / 1e6
        let failure = vm.failure(of: p)
        let report = TestReport(collector.all)
        FileHandle.standardError.write(Data(report.summary.utf8))
        try? report.junitXML.write(toFile: (dir as NSString).appendingPathComponent("junit.xml"), atomically: true, encoding: .utf8)
        let answer = vm.result(of: p).map { "\($0)" } ?? "?"
        Output.shared.emit(resultLine("tests", options,
            "total=\(report.total) passed=\(report.passed) failed=\(report.failed) errored=\(report.errored) answer=\(answer) vm_error=\(failure == nil ? 0 : 1) ms=\(f1(ms)) us_reported=\(report.microseconds) thermal_start=\(thermal0)"))
        finish(report.failed + report.errored == 0 && report.total > 0 && failure == nil ? 0 : 1)
    }
    t.stackSize = 16 << 20
    t.qualityOfService = .userInitiated
    t.start()
}

/// Run `body` on a background thread with a big stack (headless modes; iOS
/// kills an app that blocks the main thread at launch).
public func onBackgroundThread(_ body: @escaping @Sendable () -> Void) {
    let t = Thread { body() }
    t.stackSize = 16 << 20
    t.qualityOfService = .userInitiated
    t.start()
}
