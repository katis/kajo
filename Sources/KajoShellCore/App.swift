import Dispatch
import Foundation
import KajoApp
import KajoAppDevelopment
import KajoVM

/// `mode=demo`: the window ShellDemo builds in Smalltalk; Transcript lines
/// go to its text view as text events. Runs until the app quits.
@MainActor public final class DemoMode {
    let options: LaunchOptions
    let platform: ShellPlatform
    var runtime: ShellRuntime?
    var transcriptView = 0
    let pending = PendingLines()

    let pairing: PairingPresenter?

    public init(_ options: LaunchOptions, platform: ShellPlatform, pairing: PairingPresenter? = nil) {
        self.pairing = pairing
        self.options = options
        self.platform = platform
    }

    public func start(resources: ShellResources = .main) {
        var o = Headless.Options()
        o.workers = options.int("workers", 2)
        o.heapMiB = options.int("heap", 256)
        // An app that runs for days: the collectors' logs keep the last
        // records only (their sums cover the whole run).
        o.logCapacity = options.int("logs", Headless.Options.appLogCapacity)
        do {
            let rt = try makeShellRuntime(imagePath: resources.shellImage, options: o, platform: platform,
                                       events: demoSink(pending), pairing: pairing)
            runtime = rt
            rt.start()
            guard let p = rt.vm.spawn("open", receiver: "ShellDemo", main: true, priority: 2) else {
                platform.showStatus("demo: cannot spawn ShellDemo open")
                return
            }
            let end = ShellVM.now() + 10_000_000_000
            while rt.vm.state(of: p) != .terminated && ShellVM.now() < end { rt.turn(.wake) }
            transcriptView = Int(rt.vm.result(of: p)?.int ?? 0)
            rt.vm.release(p)
            pending.target = { [weak self] line in self?.post(line) }
            pending.flush()
            // Module 9b: `protocol=<socket>` serves the development protocol;
            // the status line shows where and the token.
            if let path = options["protocol"], let server = try rt.serveProtocol(socket: path) {
                platform.showStatus("demo: protocol \(server.path) token \(server.token)")
                Output.shared.emit("protocol=\(server.path)")
                return
            }
            platform.showStatus("demo")
            Output.shared.emit(resultLine("demo", options, "opened=1 transcript_view=\(transcriptView)"))
        } catch {
            platform.showStatus("demo: \(error)")
        }
    }

    func post(_ line: String) {
        guard let rt = runtime, transcriptView != 0 else { return }
        rt.deliver(ShellEvent(kind: .text, target: transcriptView, value: .string(line), timeNs: ShellVM.now()))
    }
}

/// Transcript lines from VM threads, handed to the main thread.
@MainActor final class PendingLines {
    var lines: [String] = []
    var target: ((String) -> Void)?
    func add(_ l: String) {
        if let target { target(l) } else { lines.append(l) }
    }
    func flush() {
        let ls = lines
        lines = []
        for l in ls { target?(l) }
    }
}

nonisolated func demoSink(_ p: PendingLines) -> @Sendable ([UInt8]) -> Void {
    { bytes in
        guard let o = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
              o["kind"] as? String == "transcript", let t = o["text"] as? String else { return }
        Output.shared.emit("transcript: " + t)
        DispatchQueue.main.async { MainActor.assumeIsolated { p.add(t) } }
    }
}

/// The shells' entry: pick the mode from the launch arguments.
@MainActor public final class ShellApp {
    public let options: LaunchOptions
    public let platform: ShellPlatform
    /// Module 11a: the platform's pairing screen (KajoAppDevelopment's).
    public let pairing: PairingPresenter?
    public private(set) var scenario: ScenarioMode?
    public private(set) var demo: DemoMode?
    var tests: TestsMode?
    var dev: DevMode?
    var devSession: DevSessionMode?

    public init(platform: ShellPlatform, pairing: PairingPresenter?, options: LaunchOptions = LaunchOptions()) {
        self.options = options
        self.platform = platform
        self.pairing = pairing
        Output.shared.setDirectory(options.string("outdir", Output.defaultDirectory), file: options.string("out", "results.txt"))
    }

    /// Call after the first frame is on screen.
    public func start() {
        let o = options
        Output.shared.emit("mode=\(o.mode) start=1 \(o.summary) cores=\(ProcessInfo.processInfo.processorCount) screen_max_fps=\(platform.maximumFramesPerSecond) thermal=\(Telemetry.thermal())")
        switch o.mode {
        case "golden":
            platform.showStatus("golden \(o.summary)")
            startGolden(o)
        case "spin":
            platform.showStatus("spin \(o.summary)")
            startSpin(o)
        case "tests":
            platform.showStatus("tests \(o.summary)")
            let t = TestsMode(o, platform: platform, pairing: pairing)
            tests = t
            t.start()
        case "scenario", "serve":
            let s = ScenarioMode(o, platform: platform, pairing: pairing)
            scenario = s
            s.start()
        case "dev":
            let d = DevMode(o, platform: platform, pairing: pairing)
            dev = d
            d.start()
        case "devsession":
            let d = DevSessionMode(o, platform: platform, pairing: pairing)
            devSession = d
            d.start()
        default:
            let d = DemoMode(o, platform: platform, pairing: pairing)
            demo = d
            d.start()
        }
    }
}

/// The energy counters' known workload (Spin.swift), off the main thread.
nonisolated func startSpin(_ o: LaunchOptions) {
    onBackgroundThread {
        runSpin(o)
        finish(0)
    }
}

/// Built outside the main actor: the closure runs on a background thread.
nonisolated func startGolden(_ o: LaunchOptions) {
    onBackgroundThread {
        runGolden(o)
        finish(0)
    }
}

/// A status sink for `Output.setOnLine` (called on VM threads), built
/// outside the main actor.
public nonisolated func statusSink(_ show: @escaping @MainActor (String) -> Void) -> @Sendable (String) -> Void {
    let box = MainBox(show)
    return { line in DispatchQueue.main.async { MainActor.assumeIsolated { box.f(line) } } }
}

final class MainBox: @unchecked Sendable {
    let f: @MainActor (String) -> Void
    init(_ f: @escaping @MainActor (String) -> Void) { self.f = f }
}
