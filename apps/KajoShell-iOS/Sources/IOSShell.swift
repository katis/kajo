// The iOS shell (module 9a): a measurement tool over the UIKit host, which
// since module 11a is KajoApp's (the one a generated app's iOS target
// runs). Everything else is KajoShellCore, shared with the macOS shell.
// Launch arguments select the mode:
//
//   xcrun devicectl device process launch --console --device <udid> \
//       dev.katajamaki.kajo.shell mode=tests|golden|scenario|serve|demo key=value...
//
// Module 9d: mode=serve (or protocol=tcp[:port] in a scenario) serves the
// development protocol over TCP, advertised with Bonjour, and shows the
// pairing screen at once: the token, the name, the addresses, a "new
// token" button.
//
// iOS kills an app that blocks its main thread at launch: the mode starts
// after the first frame, headless modes run on a background thread, and the
// status view draws meanwhile.

import KajoApp
import KajoAppDevelopment
import KajoShellCore
import UIKit

final class RootController: UIViewController {
    var host: UIKitHost?
    var pairing: PairingScreen?
    var app: ShellApp?
    var started = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if started { return }
        started = true
        // The status line and the spinner the measurements rely on (the
        // render server draws the spinner every frame, so ProMotion never
        // throttles the display).
        let h = UIKitHost(root: view, statusLine: true, spinner: true)
        host = h
        let p = PairingScreen(host: h, showsAtOnce: true)
        pairing = p
        let a = ShellApp(platform: h, pairing: p)
        app = a
        Output.shared.setOnLine(statusSink { [weak h] line in h?.showStatus(line) })
        // After the first frame.
        DispatchQueue.main.async { MainActor.assumeIsolated { a.start() } }
    }
}

@main final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool { true }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        let w = UIWindow(windowScene: ws)
        w.rootViewController = RootController()
        w.makeKeyAndVisible()
        window = w
    }
}
