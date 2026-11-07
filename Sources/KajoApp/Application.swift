import Darwin
import Dispatch
import Foundation
import KajoVM
import QuartzCore
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// Module 11a (docs/modules/app-project.md): the entry a generated app's
// Swift calls. The app's whole Swift is
//
//     import KajoPin
//     #if DEBUG
//     import KajoPinDevelopment
//     #endif
//
//     @main enum Main {
//         static func main() {
//             let app = KajoAppConfiguration(name: "Sample", appClass: "SampleApp")
//             #if DEBUG
//             KajoApplication.main(app, development: Development())
//             #else
//             KajoApplication.main(app)
//             #endif
//         }
//     }
//
// The bundled image (`<Resources>/kajo/app.img`) is opened, the app class's
// `open` runs as a main Process at UI priority, and from then on the app is
// its windows and the event loop. A development build passes the
// development half (KajoAppDevelopment), which serves the protocol from
// launch; a release build passes nothing and links none of it.

/// What a generated app tells the library: its name, the Smalltalk class
/// whose class-side `open` starts it, the image it bundles, and the VM's
/// size.
public struct KajoAppConfiguration: Sendable {
    /// The app's name (its Bonjour name in a development build, its menu).
    public var name: String
    /// The class whose `open` (class side) builds the first window.
    public var appClass: String
    /// The image in the bundle's `kajo/` resources directory.
    public var imageName: String
    public var workers: Int
    public var heapMiB: Int

    public init(name: String, appClass: String, imageName: String = "app.img", workers: Int = 2, heapMiB: Int = 256) {
        self.name = name
        self.appClass = appClass
        self.imageName = imageName
        self.workers = workers
        self.heapMiB = heapMiB
    }

    /// The bundled image's path.
    public var imagePath: String { (Bundle.main.resourcePath ?? ".") + "/kajo/" + imageName }
}

/// What a development build adds to a running app (KajoAppDevelopment's
/// `Development`): called once the app's `open` has run and its window is
/// on the screen (`KajoAppRunner.startDevelopment`).
@MainActor public protocol AppDevelopment: AnyObject {
    func started(_ app: KajoAppRunner)
}

/// One app: the runtime over the bundled image on a platform host, the
/// app class opened, and, after its first frame, the development half told.
@MainActor public final class KajoAppRunner {
    public let configuration: KajoAppConfiguration
    public let platform: ShellPlatform
    public let development: AppDevelopment?
    public private(set) var runtime: ShellRuntime?
    /// The shake on iOS, the development build's way to its pairing screen.
    public var onShake: (() -> Void)?

    public init(configuration: KajoAppConfiguration, platform: ShellPlatform, development: AppDevelopment?) {
        self.configuration = configuration
        self.platform = platform
        self.development = development
    }

    /// Open the image (the bundled one, or `imagePath`) and run the app
    /// class's `open`. False when the app did not open (the reason is the
    /// status line). The development half is told by `startDevelopment`,
    /// which a launch calls after the app's first frame: nothing serving
    /// waits for comes before the window.
    @discardableResult
    public func start(imagePath: String? = nil) -> Bool {
        var o = Headless.Options()
        o.workers = configuration.workers
        o.heapMiB = configuration.heapMiB
        // An app runs for days: the collectors' logs keep the last records
        // only (their sums cover the whole run).
        o.logCapacity = Headless.Options.appLogCapacity
        // The development answers: a development build is a host a debugger
        // can come to (it serves from launch), so from before the image
        // resumes an unhandled error stops its Process, the app's own
        // start-up included; a release build reports and ends it.
        o.stopsForDebugger = development != nil
        let rt: ShellRuntime
        do {
            rt = try ShellRuntime(imagePath: imagePath ?? configuration.imagePath, options: o, platform: platform,
                                  events: appTranscriptSink())
        } catch {
            platform.showStatus("\(configuration.name): \(error)")
            return false
        }
        runtime = rt
        LaunchTrace.step("image-opened")
        rt.start()
        guard let p = rt.vm.spawn("open", receiver: configuration.appClass, main: true, priority: 2) else {
            platform.showStatus("\(configuration.name): the image has no class \(configuration.appClass)")
            return false
        }
        let end = ShellVM.now() + 10_000_000_000
        while rt.vm.state(of: p) != .terminated && ShellVM.now() < end {
            rt.turn(.wake)
            // An error in `open` stopped it for the debugger: serving starts
            // anyway (it does not depend on that Process), and a client
            // that connects finds the stop.
            if o.stopsForDebugger && rt.vm.state(of: p) == .waiting && rt.vm.isStoppedForDebugger(p) {
                appLog("\(configuration.name): \(configuration.appClass) open stopped for the debugger (process \(p.id))")
                break
            }
        }
        rt.vm.release(p)
        LaunchTrace.step("app-opened")
        return true
    }

    private var developmentStarted = false

    /// Tell the development half, once, after `start` opened the app (a
    /// release build has none: nothing happens).
    public func startDevelopment() {
        guard let d = development, runtime != nil, !developmentStarted else { return }
        developmentStarted = true
        d.started(self)
        LaunchTrace.step("development-started")
    }
}

/// `body` once, at the `frames`-th display frame from now or after `bound`
/// seconds, whichever comes first: a launch's step that must not delay the
/// first frame and must not wait for frames that may never come (no
/// display, an occluded window).
@MainActor final class AfterFrames {
    private var body: (@MainActor (String) -> Void)?
    private var link: LinkTarget?
    private var seen = 0

    @discardableResult
    init(frames: Int, bound: Double, display: Bool = true, _ body: @escaping @MainActor (String) -> Void) {
        self.body = body
        if display {
            link = LinkTarget { [weak self] _ in
                guard let self else { return }
                self.seen += 1
                if self.seen >= frames { self.fire("frame") }
            }.start()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + bound) { MainActor.assumeIsolated { self.fire("bound") } }
    }

    /// Whether `body` has run.
    var fired: Bool { body == nil }

    private func fire(_ why: String) {
        link?.stop()
        link = nil
        guard let b = body else { return }
        body = nil
        b(why)
    }
}

extension ShellVM {
    /// The development answers: whether `p` stands stopped for the
    /// debugger (asked of the kernel in a Process of its own, waited for at
    /// most two seconds). For a host waiting for a Process it spawned.
    public func isStoppedForDebugger(_ p: ShellProcess) -> Bool {
        guard let q = spawn("isStoppedProcessId:", receiver: "Debugger", arguments: [.int(p.id)]) else { return false }
        defer { release(q) }
        let end = ShellVM.now() + 2_000_000_000
        while state(of: q) != .terminated && ShellVM.now() < end { usleep(200) }
        return result(of: q) == .bool(true)
    }
}

/// The app's Transcript to its standard output (the console of a launch
/// from Xcode or `devicectl --console`). Built outside the main actor: VM
/// threads call it.
nonisolated func appTranscriptSink() -> @Sendable ([UInt8]) -> Void {
    { bytes in
        guard let o = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
              o["kind"] as? String == "transcript", let t = o["text"] as? String else { return }
        FileHandle.standardOutput.write(Data(("transcript: " + t + "\n").utf8))
    }
}

/// `kajo-launch-report` among the launch arguments: one line on standard
/// output with the time from the process's start to the first frame after
/// the app's `open` (module 11a's cold-launch measurement; a line, not a
/// mode, so the release build has it too).
@MainActor enum LaunchReport {
    static var link: AnyObject?

    static func arm(build: String) {
        guard CommandLine.arguments.contains("kajo-launch-report"), let start = processStart() else { return }
        #if os(macOS)
        AppKitHost.wakeDisplay()
        #endif
        let target = LinkTarget { ts in
            let now = Date().timeIntervalSince1970
            let ms = ((now - start) * 10_000).rounded() / 10
            appLog("mode=app run=launch build=\(build) first_frame_ms=\(ms) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
            (link as? Invalidating)?.stop()
            link = nil
        }
        link = target.start()
    }

    /// The process's start (wall clock, seconds).
    nonisolated static func processStart() -> Double? {
        var info = unsafe kinfo_proc()
        var size = unsafe MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let rc = unsafe sysctl(&mib, 4, &info, &size, nil, 0)
        guard rc == 0 else { return nil }
        let t = unsafe info.kp_proc.p_un.__p_starttime
        return Double(t.tv_sec) + Double(t.tv_usec) / 1e6
    }
}

/// `kajo-launch-report` among the launch arguments: one console line per
/// step of the launch, `launch step=<name> ms=<ms>` with the time since the
/// process's start at which the step ended (taken when it happened, not
/// when the line is written), so a wait between the start and the first
/// frame shows where it is.
public enum LaunchTrace {
    static let enabled = CommandLine.arguments.contains("kajo-launch-report")
    static let start: Double? = LaunchReport.processStart()

    /// The step `name` has ended; `detail` is appended to the line as is.
    public static func step(_ name: String, _ detail: String = "") {
        guard enabled, let s = start else { return }
        let ms = ((Date().timeIntervalSince1970 - s) * 10_000).rounded() / 10
        appLog("launch step=\(name) ms=\(ms)" + (detail.isEmpty ? "" : " " + detail))
    }
}

@MainActor protocol Invalidating: AnyObject { func stop() }

/// A one-shot display link: `fire` at the first frame.
@MainActor final class LinkTarget: NSObject, Invalidating {
    let fire: (Double) -> Void
    var link: CADisplayLink?
    init(_ fire: @escaping (Double) -> Void) { self.fire = fire }

    func start() -> LinkTarget {
        #if os(macOS)
        guard let screen = NSScreen.main else { return self }
        let l = screen.displayLink(target: self, selector: #selector(frame(_:)))
        #else
        let l = CADisplayLink(target: self, selector: #selector(frame(_:)))
        #endif
        l.add(to: .main, forMode: .common)
        link = l
        return self
    }

    @objc func frame(_ l: CADisplayLink) { fire(l.timestamp) }
    func stop() {
        link?.invalidate()
        link = nil
    }
}

/// The entry a generated app's `main` calls; it never returns.
public enum KajoApplication {
    /// The running app, once its host exists.
    @MainActor public private(set) static var current: KajoAppRunner?
    @MainActor static var pending: (KajoAppConfiguration, AppDevelopment?)?

    /// Run the app: the platform's application object, the host, the
    /// runtime, the app class opened after the first frame. `development`
    /// is a development build's half (nil in a release build).
    @MainActor public static func main(_ configuration: KajoAppConfiguration, development: AppDevelopment? = nil) -> Never {
        pending = (configuration, development)
        #if os(macOS)
        // No window restoration: after a crash AppKit would ask, in a modal
        // alert at launch, whether to reopen windows (the Smalltalk windows
        // are the image's to open).
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        // A measurement launch needs frames from an asleep display too.
        if CommandLine.arguments.contains(where: { $0 == "kajo-launch-report" || $0.hasPrefix("kajo-frames=") }) { AppKitHost.wakeDisplay() }
        let application = NSApplication.shared
        let delegate = AppKitAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        exit(0)
        #else
        let code = unsafe UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(KajoUIAppDelegate.self))
        exit(code)
        #endif
    }

    /// Make the runner on `platform` and open the app after the first frame
    /// (iOS kills an app that blocks its main thread at launch).
    @MainActor static func launch(on platform: ShellPlatform) -> KajoAppRunner? {
        guard let (c, d) = pending else { return nil }
        let r = KajoAppRunner(configuration: c, platform: platform, development: d)
        current = r
        LaunchTrace.step("host-ready")
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard r.start() else { return }
                LaunchReport.arm(build: d == nil ? "release" : "debug")
                // The window first: the development half (serving, its
                // name, its token, Bonjour) starts once the app's first
                // frame is on the screen, at the second frame, or after a
                // second when no frames come.
                if d != nil {
                    AfterFrames(frames: 2, bound: 1) { why in
                        LaunchTrace.step("development-due", "by=\(why)")
                        r.startDevelopment()
                    }
                }
            }
        }
        return r
    }
}

/// An app's status lines (errors opening the image) to its standard output,
/// unbuffered (the console of a launch from Xcode or `devicectl --console`).
public nonisolated func appLog(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

#if os(macOS)
@MainActor final class AppKitAppDelegate: NSObject, NSApplicationDelegate {
    var host: AppKitHost?

    func applicationDidFinishLaunching(_ n: Notification) {
        let h = AppKitHost(statusWindow: false, keepDisplayAwake: false)
        h.onStatus = { appLog($0) }
        host = h
        NSApp.mainMenu = AppKitAppDelegate.menu(KajoApplication.pending?.0.name ?? "Kajo")
        _ = KajoApplication.launch(on: h)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    /// The app's menu bar: the app menu (Hide, Quit) and Edit (the text
    /// fields' commands). A development build adds its Pairing item to the
    /// app menu.
    static func menu(_ name: String) -> NSMenu {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu(title: name)
        app.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        bar.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        bar.addItem(editItem)
        return bar
    }
}
#elseif os(iOS)
@objc(KajoAppDelegate) public final class KajoUIAppDelegate: UIResponder, UIApplicationDelegate {
    public func application(_ application: UIApplication,
                            didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool { true }
}

/// The scene a generated app's Info.plist names (`KajoSceneDelegate`).
@objc(KajoSceneDelegate) public final class KajoSceneDelegate: UIResponder, UIWindowSceneDelegate {
    public var window: UIWindow?

    public func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let w = KajoWindow(windowScene: ws)
        w.rootViewController = KajoRootController()
        w.makeKeyAndVisible()
        window = w
        LaunchTrace.step("window")
    }
}

/// The window: a shake anywhere reaches it at the end of the responder
/// chain.
final class KajoWindow: UIWindow {
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake, let r = KajoApplication.current, let s = r.onShake { s() } else { super.motionEnded(motion, with: event) }
    }
}

final class KajoRootController: UIViewController {
    var host: UIKitHost?
    var runner: KajoAppRunner?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if host != nil { return }
        let h = UIKitHost(root: view, statusLine: false, spinner: false)
        h.onStatus = { appLog($0) }
        host = h
        runner = KajoApplication.launch(on: h)
    }
}
#endif
