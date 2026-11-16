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
    var frames: FrameWindow?

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
        if let secs = FrameWindow.requested() {
            // The round trip's measurement (module 11a): the frames beside
            // what the server served meanwhile.
            var base = ServerStats.Values()
            frames = FrameWindow(seconds: secs, build: "debug", begin: { base = s.stats.values }, extra: {
                let v = s.stats.values
                return " served_sessions=\(v.sessions - base.sessions) served_requests=\(v.requests - base.requests)"
            })
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
