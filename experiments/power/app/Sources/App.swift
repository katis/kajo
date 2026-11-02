// The power app (device-measurement's and entry-locality's pattern): one
// configuration per launch, selected by launch arguments `key=value`
// (`KAJO_*` keys become environment variables before anything reads them).
// Every result line goes to stdout (streamed by `devicectl device process
// launch --console`) and is appended to Documents/<out>. SPEC.md lists
// the parts and every key of the result lines.
//
//   part=hello                 energy readout check: 1 s idle, 1 s busy
//   part=1 kernel=walk22x6|walkbuild22 workers=1|2 comp=...   walk on B
//   part=1c size=256 hops=N comp=...                             chase
//   part=2 rate=MB/s seconds=30 (collector config in KAJO_* args)
//   part=3 mode=novm|parked|link|tick|tickalloc seconds=60
//   part=unplugged             waits for the cable to go, then runs a
//                              fixed Part 1 sequence in this process
//
// comp = none | spin | spinut (spin at utility) | wfe | t10000 | t1000 | t100

import Darwin
import Kasm
import PowerKit
import UIKit

struct Options: Sendable {
    var kv: [String: String] = [:]
    subscript(_ k: String) -> String? { kv[k] }
    func int(_ k: String, _ d: Int) -> Int { kv[k].flatMap { Int($0) } ?? d }
    func double(_ k: String, _ d: Double) -> Double { kv[k].flatMap { Double($0) } ?? d }

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

    @MainActor static func battery() -> String {
        let d = UIDevice.current
        let st: String
        switch d.batteryState {
        case .charging: st = "charging"
        case .full: st = "full"
        case .unplugged: st = "unplugged"
        default: st = "unknown"
        }
        return "battery=\(st) battery_level=\((d.batteryLevel * 100).rounded() / 100) low_power=\(ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0)"
    }

    static func suffix() -> String {
        let (fp, peak) = footprint()
        return " thermal_end=\(thermal()) footprint_mb=\(mb(fp)) footprint_peak_mb=\(mb(peak)) avail_mb=\(os_proc_available_memory() >> 20)"
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

/// What every line starts with (computed on the main thread at launch).
struct LaunchInfo: Sendable {
    var head: String
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
        let part = opt["part"] ?? "hello"
        let tag = opt["tag"].map { " tag=\($0)" } ?? ""
        let info = LaunchInfo(head: "part=\(part) run=\(opt.int("run", 1))\(tag) \(Telemetry.battery()) cores=\(ProcessInfo.processInfo.processorCount) thermal_start=\(Telemetry.thermal())")
        let w = UIWindow(windowScene: ws)
        if part == "2" || part == "3" {
            w.rootViewController = PowerController(opt, info: info)
        } else {
            let s = StatusViewController()
            s.title = opt.kv.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            w.rootViewController = s
            Output.shared.onLine = { line in
                DispatchQueue.main.async { MainActor.assumeIsolated { s.show(line) } }
            }
            if part == "unplugged" { startUnplugged(opt, info: info) } else { startHeadless(opt, info: info) }
        }
        w.makeKeyAndVisible()
        window = w
    }
}

/// Parts hello, 1 and 1c on a background Thread at user-initiated QoS (the
/// main thread only shows a static label).
func startHeadless(_ opt: Options, info: LaunchInfo) {
    let t = Thread {
        let line: String
        switch opt["part"] ?? "hello" {
        case "1": line = runWalk(opt)
        case "1c": line = runChasePart(opt)
        default: line = runHello()
        }
        Output.shared.emit(info.head + " " + line + Telemetry.suffix())
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
