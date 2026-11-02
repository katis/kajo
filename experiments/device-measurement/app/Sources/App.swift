// The device app: one run per launch, selected by launch arguments
// (`key=value`; keys starting with KAJO_ are set as environment variables
// before the VM reads them). The main thread draws a status view; headless
// kernels run on a background thread. Every result line goes to stdout
// (streamed by `devicectl device process launch --console`) and is appended
// to Documents/<out> (default results.txt), so a killed run leaves data.
//
//   part=hello                                   trivial kernel (VMB arith, 1 worker)
//   part=A variant=A|B|C kernel=walk workers=6   object-representation's benchLine
//   part=B cfg=stw|adr7|local|offload kernel=alloc workers=6 [KAJO_...]
//                                               concurrent-young's benchLine
//   part=C scenario=D0..D5 run=1 [seconds=10 warmup=1 bg=5]
//
// Common: run=N tag=... out=file.txt

import Darwin
import Kasm
import UIKit

// MARK: - options

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

// MARK: - telemetry

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

    static func availableMB() -> Int { Int(os_proc_available_memory() >> 20) }

    static func mb(_ b: UInt64) -> String { String(format: "%.1f", Double(b) / 1048576) }

    /// Appended to every result line.
    static func suffix() -> String {
        let (fp, peak) = footprint()
        return " thermal=\(thermal()) footprint_mb=\(mb(fp)) footprint_peak_mb=\(mb(peak)) avail_mb=\(availableMB())"
    }
}

// MARK: - output

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

// MARK: - app

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        true
    }
}

/// Launch-time facts gathered on the main thread.
struct LaunchInfo: Sendable {
    var battery: String
    var batteryLevel: Float
    var lowPower: Bool
    var cores: Int
    var activeCores: Int
    var maxFps: Int
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    var status: StatusViewController?
    var scenario: AnyObject?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        let opt = Options.parse()
        experimentsDir = Bundle.main.resourcePath! + "/experiments"
        Output.shared.setFile(opt["out"] ?? "results.txt")
        let bs: String
        switch UIDevice.current.batteryState {
        case .charging: bs = "charging"
        case .full: bs = "full"
        case .unplugged: bs = "unplugged"
        default: bs = "unknown"
        }
        let info = LaunchInfo(battery: bs, batteryLevel: UIDevice.current.batteryLevel,
                              lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                              cores: ProcessInfo.processInfo.processorCount,
                              activeCores: ProcessInfo.processInfo.activeProcessorCount,
                              maxFps: ws.screen.maximumFramesPerSecond)
        let w = UIWindow(windowScene: ws)
        let part = opt["part"] ?? "hello"
        if part == "C" {
            let c = ScenarioController(opt, info: info)
            w.rootViewController = c
            scenario = c
        } else {
            let s = StatusViewController()
            s.title = opt.kv.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            w.rootViewController = s
            status = s
            Output.shared.onLine = { line in
                DispatchQueue.main.async { MainActor.assumeIsolated { s.show(line) } }
            }
            startHeadless(opt, info: info)
        }
        w.makeKeyAndVisible()
        window = w
    }
}

/// The headless part: one kernel on a background thread, then exit.
func startHeadless(_ opt: Options, info: LaunchInfo) {
    let t = Thread {
        let part = opt["part"] ?? "hello"
        let run = opt.int("run", 1)
        let tag = opt["tag"].map { " tag=\($0)" } ?? ""
        let t0 = Telemetry.thermal()
        let pre = "part=\(part) run=\(run)\(tag) battery=\(info.battery) battery_level=\(String(format: "%.2f", info.batteryLevel)) low_power=\(info.lowPower ? 1 : 0) cores=\(info.cores) thermal_start=\(t0) avail_start_mb=\(Telemetry.availableMB())"
        var line: String
        do {
            switch part {
            case "A": line = try runPartA(opt)
            case "B": line = try runPartB(opt)
            default: line = try runHello()
            }
        } catch {
            line = "FAILED=1 error=\(String(describing: error).replacingOccurrences(of: " ", with: "_"))"
        }
        Output.shared.emit(pre + " " + line + " thermal_end=\(Telemetry.thermal())" + Telemetry.suffix())
        Output.shared.emit("DONE")
        // Let the console stream the lines, then leave; devicectl --console
        // returns when the process exits.
        usleep(200_000)
        exit(0)
    }
    t.stackSize = 16 << 20
    t.qualityOfService = .userInitiated
    t.start()
}

// MARK: - status view

final class StatusViewController: UIViewController {
    let label = UILabel()
    let spinner = UIView()

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
        spinner.frame = CGRect(x: 40, y: 80, width: 30, height: 30)
        spinner.backgroundColor = .systemOrange
        view.addSubview(spinner)
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 1
        spin.repeatCount = .infinity
        spinner.layer.add(spin, forKey: "spin")
    }

    func show(_ line: String) {
        label.text = String(line.prefix(1500))
    }
}
