import Dispatch
import Foundation
import KajoApp
import KajoDev
import KajoVM
import QuartzCore
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// Module 11a (docs/modules/app-project.md, part 3): serving is a property
// of the development build. A Debug build of a generated app passes
// `Development()` to `KajoApplication.main`; from launch, with no
// argument, it serves the development protocol over TCP, advertised with
// Bonjour as "<app> on <device>", with the per-install token of module 9d,
// and the pairing screen is reached from the running app (a shake on iOS,
// the app menu's Pairing item on the Mac). A release build links none of
// this; its image would refuse to serve anyway.

/// A development build's half of a running app.
@MainActor public final class Development: AppDevelopment {
    let store: PairingTokenStore?
    let port: Int
    let loopbackOnly: Bool
    let advertise: Bool
    let presenter: PairingPresenter?
    public private(set) var server: ProtocolServer?
    /// The pairing screen the running app reaches.
    public private(set) var pairing: PairingPresenter?
    /// The advertised name.
    public private(set) var serviceName = ""
    var frames: FrameMonitor?

    /// `store`: where the token lives (Application Support by default);
    /// `port` 0 lets the system pick; `presenter` replaces the platform's
    /// pairing screen (a test's).
    public init(store: PairingTokenStore? = PairingTokenStore.applicationSupport(), port: Int = 0, loopbackOnly: Bool = false,
                advertise: Bool = true, presenter: PairingPresenter? = nil) {
        self.store = store
        self.port = port
        self.loopbackOnly = loopbackOnly
        self.advertise = advertise
        self.presenter = presenter
    }

    /// "<app> on <device>": what tells apps apart on one device (a Bonjour
    /// name is at most 63 bytes).
    public static func serviceName(app: String, device: String) -> String {
        var n = "\(app) on \(device)"
        while n.utf8.count > 63 { n.removeLast() }
        return n
    }

    /// The device in the service name; nothing here may wait. On iOS it
    /// is the model's name ("iPhone", "iPad"): the user's name for the
    /// device needs an entitlement, `gethostname` answers "localhost", and
    /// `ProcessInfo.hostName` answered "localhost" too after 35.0 s on the
    /// main thread of an iPhone and an iPad (it waits for a name lookup that
    /// never answers), which held the first frame of every Debug launch.
    /// Two devices of one model are told apart by Bonjour, which renames
    /// the second ("Sample on iPhone (2)") and reports the name it took to
    /// the pairing screen.
    static var deviceName: String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return UIDevice.current.name
        #endif
    }

    public func started(_ app: KajoAppRunner) {
        guard let rt = app.runtime else { return }
        let screen = presenter ?? Development.platformScreen(app)
        pairing = screen
        LaunchTrace.step("pairing-screen")
        serviceName = Development.serviceName(app: app.configuration.name, device: Development.deviceName)
        LaunchTrace.step("device-name")
        do {
            server = try rt.serveTCP(port: port, loopbackOnly: loopbackOnly, advertise: advertise, store: store,
                                     imageName: app.configuration.imageName, serviceName: serviceName, pairing: screen)
        } catch {
            rt.platform.showStatus("\(app.configuration.name): cannot serve: \(error)")
        }
        guard let s = server else {
            rt.platform.showStatus("\(app.configuration.name): the image serves no protocol (a release image?)")
            return
        }
        // The port and the name go to the console (the token never does).
        appLog("serving=tcp port=\(s.port ?? 0) addresses=\(localAddresses().joined(separator: ",")) name=\(serviceName.replacingOccurrences(of: " ", with: "_"))")
        if let a = CommandLine.arguments.first(where: { $0.hasPrefix("kajo-frames=") }), let secs = Double(a.dropFirst(12)) {
            frames = FrameMonitor(seconds: secs, server: s)
        }
    }

    /// The platform's pairing screen and the way to it.
    static func platformScreen(_ app: KajoAppRunner) -> PairingPresenter? {
        #if os(iOS)
        guard let host = app.platform as? UIKitHost else { return nil }
        let screen = PairingScreen(host: host, showsAtOnce: false)
        app.onShake = { [weak screen] in screen?.toggle() }
        return screen
        #elseif os(macOS)
        guard let host = app.platform as? AppKitHost else { return nil }
        let screen = PairingScreen(host: host, style: .window)
        if let menu = NSApp.mainMenu?.items.first?.submenu {
            let item = NSMenuItem(title: "Pairing…", action: #selector(PairingScreen.toggle), keyEquivalent: "p")
            item.keyEquivalentModifierMask = [.command, .shift]
            item.target = screen
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        return screen
        #else
        return nil
        #endif
    }
}

/// `kajo-frames=<seconds>` among a development build's launch arguments:
/// the display's frames counted for that long after a second's warmup, one
/// result line (frames missed, what the server served meanwhile), then the
/// app quits. The round trip's measurement (module 11a); the frames are
/// counted beside the app, which runs as it always does.
@MainActor final class FrameMonitor: NSObject {
    let seconds: Double
    let server: ProtocolServer
    var link: CADisplayLink?
    var times: [Double] = []
    var start = 0.0
    var base = ServerStats.Values()
    let nominal: Double
    var activity: NSObjectProtocol?

    init(seconds: Double, server: ProtocolServer) {
        self.seconds = seconds
        self.server = server
        #if os(macOS)
        nominal = Double(NSScreen.main?.maximumFramesPerSecond ?? 60)
        #else
        nominal = Double(UIScreen.main.maximumFramesPerSecond)
        #endif
        super.init()
        #if os(macOS)
        // The window is measured as a developer would see it: the display
        // stays on and App Nap does not throttle the app's display link
        // while another app (the tools) is in front of it.
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated, .latencyCritical],
                                                         reason: "Kajo frame measurement")
        AppKitHost.wakeDisplay()
        guard let l = NSScreen.main?.displayLink(target: self, selector: #selector(frame(_:))) else { return }
        #else
        // The screen stays on for the window (a locked screen has no frames).
        UIApplication.shared.isIdleTimerDisabled = true
        let l = CADisplayLink(target: self, selector: #selector(frame(_:)))
        #endif
        l.preferredFrameRateRange = CAFrameRateRange(minimum: Float(nominal), maximum: Float(nominal), preferred: Float(nominal))
        l.add(to: .main, forMode: .common)
        link = l
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                self.start = CACurrentMediaTime()
                self.base = server.stats.values
                appLog("frames=start")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1 + seconds) { MainActor.assumeIsolated { self.end() } }
    }

    @objc func frame(_ l: CADisplayLink) {
        if start > 0 { times.append(l.timestamp) }
    }

    func end() {
        let stop = CACurrentMediaTime()
        link?.invalidate()
        let fa = FrameAccount(timestamps: times.filter { $0 >= start && $0 <= stop }, start: start, end: stop, nominalHz: nominal)
        let v = server.stats.values
        appLog("mode=app run=frames build=debug seconds=\(f3(stop - start)) nominal_hz=\(f2(nominal)) frames=\(fa.frames) expected=\(fa.expected) missed=\(fa.missed) drops=\(fa.drops) gap_p99_ms=\(f3(fa.gapP99Ms)) gap_max_ms=\(f3(fa.gapMaxMs)) served_sessions=\(v.sessions - base.sessions) served_requests=\(v.requests - base.requests) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
        exit(0)
    }
}
