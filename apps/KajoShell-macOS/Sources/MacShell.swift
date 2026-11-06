// The macOS shell (module 9a): a measurement tool over the AppKit host,
// which since module 11a is KajoApp's (the one a generated app's Mac target
// runs). Everything else is KajoShellCore, shared with the iOS shell.
//
//   KajoShell.app/Contents/MacOS/KajoShell mode=tests|golden|scenario|serve|dev|devsession|demo key=value...

import AppKit
import IOKit.pwr_mgt
import KajoApp
import KajoAppDevelopment
import KajoShellCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var host: AppKitHost?
    var pairing: PairingScreen?
    var app: ShellApp?

    func applicationDidFinishLaunching(_ n: Notification) {
        let h = AppKitHost(statusWindow: true, keepDisplayAwake: true)
        host = h
        // Module 9d: the Mac serving over TCP shows how to pair in its
        // status line (as 9b's socket's token is shown there); no button.
        let p = PairingScreen(host: h, style: .statusLine)
        pairing = p
        let a = ShellApp(platform: h, pairing: p)
        app = a
        Output.shared.setOnLine(statusSink { [weak h] line in h?.showStatus(line) })
        NSApp.activate()
        // After the first frame, as on iOS.
        DispatchQueue.main.async { MainActor.assumeIsolated { a.start() } }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
}

@main @MainActor enum Main {
    static let delegate = AppDelegate()

    static func main() {
        // Wake an asleep display first (the mini's TV sleeps after ten
        // minutes), as a key press would. No setting is changed.
        var activity: IOPMAssertionID = 0
        _ = IOPMAssertionDeclareUserActivity("Kajo shell launch" as CFString, kIOPMUserActiveLocal, &activity)
        // No window restoration: after a crash AppKit would ask, in a modal
        // alert at launch, whether to reopen windows, and a scripted run
        // would wait for it forever (a registered default, in memory; AppKit then
        // leaves saved state alone and writes new state to a temporary folder).
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        let application = NSApplication.shared
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}
