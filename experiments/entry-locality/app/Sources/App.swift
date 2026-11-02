// The device app (device-measurement's pattern): one run per launch,
// selected by launch arguments `key=value`. The main thread draws a status
// view; the run happens on a background Thread at user-initiated QoS. Every
// result line goes to stdout (streamed by `devicectl device process launch
// --console`) and is appended to Documents/<out>.
//
//   part=hello                                   arith on B, 1 worker
//   part=1 mode=chase|dsep|dlocal|dhalf|spread size=MB threads=N [work=K]
//   part=3 variant=A|B|C|L kernel=walk22 workers=1
//
// Common: run=N tag=... out=file.txt [stream=MB: a companion thread
// streams through its own MB buffer while the run is measured]

import Darwin
import Kasm
import MemChase
import UIKit
import VMA
import VMB
import VMC
import VML

struct Options: Sendable {
    var kv: [String: String] = [:]
    subscript(_ k: String) -> String? { kv[k] }
    func int(_ k: String, _ d: Int) -> Int { kv[k].flatMap { Int($0) } ?? d }

    static func parse() -> Options {
        var o = Options()
        for a in CommandLine.arguments.dropFirst() {
            guard let eq = a.firstIndex(of: "=") else { continue }
            let k = String(a[..<eq]), v = String(a[a.index(after: eq)...])
            if k.hasPrefix("KAJO_") { setenv(k, v, 1) }
            o.kv[k] = v
        }
        return o
    }
}

enum Telemetry {
    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// (phys_footprint, ledger_phys_footprint_peak) in bytes.
    static func footprint() -> (UInt64, UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? (info.phys_footprint, UInt64(max(0, info.ledger_phys_footprint_peak))) : (0, 0)
    }

    static func mb(_ b: UInt64) -> String { "\((Double(b) / 1048576 * 10).rounded() / 10)" }

    static func suffix() -> String {
        let (fp, peak) = footprint()
        return " thermal=\(thermal()) footprint_mb=\(mb(fp)) footprint_peak_mb=\(mb(peak)) avail_mb=\(os_proc_available_memory() >> 20)"
    }
}

final class Output: @unchecked Sendable {
    static let shared = Output()
    private let lock = NSLock()
    private var path: String = ""
    var onLine: (@Sendable (String) -> Void)?

    func setFile(_ name: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        path = docs.appendingPathComponent(name).path
    }

    func emit(_ line: String) {
        lock.lock()
        print(line)
        fflush(stdout)
        if let f = fopen(path, "a") {
            fputs(line + "\n", f)
            fclose(f)
        }
        lock.unlock()
        onLine?(line)
    }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        true
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        let opt = Options.parse()
        experimentsDir = Bundle.main.resourcePath! + "/experiments"
        Output.shared.setFile(opt["out"] ?? "results.txt")
        let battery: String
        switch UIDevice.current.batteryState {
        case .charging: battery = "charging"
        case .full: battery = "full"
        case .unplugged: battery = "unplugged"
        default: battery = "unknown"
        }
        let pre = "battery=\(battery) battery_level=\((UIDevice.current.batteryLevel * 100).rounded() / 100) low_power=\(ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0)"
        let w = UIWindow(windowScene: ws)
        let s = StatusViewController()
        s.title = opt.kv.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        w.rootViewController = s
        Output.shared.onLine = { line in
            DispatchQueue.main.async { MainActor.assumeIsolated { s.show(line) } }
        }
        startHeadless(opt, pre: pre)
        w.makeKeyAndVisible()
        window = w
    }
}

func runPart3(_ opt: Options) throws -> String {
    let kernel = opt["kernel"] ?? "walk22"
    let n = opt.int("workers", 1)
    let snap = NSTemporaryDirectory()
    switch opt["variant"] ?? "A" {
    case "A": return try VMA.benchLine(kernel: kernel, workers: n, snapshotDir: snap)
    case "B": return try VMB.benchLine(kernel: kernel, workers: n, snapshotDir: snap)
    case "C": return try VMC.benchLine(kernel: kernel, workers: n, snapshotDir: snap)
    case "L": return try VML.benchLineWithLocality(kernel: kernel, workers: n, snapshotDir: snap)
    default: throw KasmError("variant must be A, B, C or L")
    }
}

func startHeadless(_ opt: Options, pre: String) {
    let t = Thread {
        let part = opt["part"] ?? "hello"
        let tag = opt["tag"].map { " tag=\($0)" } ?? ""
        let head = "part=\(part) run=\(opt.int("run", 1))\(tag) \(pre) cores=\(ProcessInfo.processInfo.processorCount) thermal_start=\(Telemetry.thermal())"
        var line: String
        let streamMB = opt.int("stream", 0)
        let streamer = streamMB > 0 ? Streamer(mb: streamMB) : nil
        let u0 = ProcUsage.now()
        do {
            switch part {
            case "1":
                line = runChase(ChaseSpec(mode: opt["mode"] ?? "chase", sizeMB: opt.int("size", 64),
                                          threads: opt.int("threads", 1), work: opt.int("work", 0)))
            case "3": line = try runPart3(opt)
            default: line = try VMB.benchLine(kernel: "arith", workers: 1, snapshotDir: NSTemporaryDirectory())
            }
        } catch {
            line = "FAILED=1 error=\(String(describing: error).replacingOccurrences(of: " ", with: "_"))"
        }
        let u1 = ProcUsage.now()
        if let st = streamer { line += " stream_mb=\(streamMB) stream_mbs=\(Int(st.finish()))" }
        line += ProcUsage.line(u0, u1)
        Output.shared.emit(head + " " + line + " thermal_end=\(Telemetry.thermal())" + Telemetry.suffix())
        Output.shared.emit("DONE")
        usleep(200_000)
        exit(0)
    }
    t.stackSize = 16 << 20
    t.qualityOfService = .userInitiated
    t.start()
}

final class StatusViewController: UIViewController {
    let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        label.numberOfLines = 0
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.text = "running: " + (title ?? "")
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 100),
        ])
    }

    func show(_ line: String) {
        label.text = String(line.prefix(1500))
    }
}
