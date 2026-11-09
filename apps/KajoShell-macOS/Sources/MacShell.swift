// The Kajo app (module 11b, docs/modules/distribution.md), and the macOS
// shell of module 9a it grew from. Launched with no `mode=` it is the
// product: the checkout it carries copied to Application Support, the
// development image with the tools, File > New App... and File > Install
// Command Line Tool... (KajoShellCore's ProductMode). With `mode=` it is the
// measurement tool over the AppKit host, as before (KajoShellCore's modes,
// shared with the iOS shell):
//
//   Kajo.app/Contents/MacOS/Kajo mode=tests|golden|scenario|serve|dev|devsession|demo key=value...

import AppKit
import IOKit.pwr_mgt
import KajoApp
import KajoAppDevelopment
import KajoShellCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var host: AppKitHost?
    var pairing: PairingScreen?
    var app: ShellApp?
    var product: ProductMode?

    func applicationDidFinishLaunching(_ n: Notification) {
        LaunchTrace.step("did-finish-launching")
        let options = LaunchOptions()
        if options["mode"] == nil {
            startProduct(options)
            return
        }
        let h = AppKitHost(statusWindow: true, keepDisplayAwake: true)
        host = h
        LaunchTrace.step("host-ready")
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

    /// The product: no status window, no display assertion; the menu bar
    /// before the tools add their Tools menu to it.
    func startProduct(_ options: LaunchOptions) {
        let h = AppKitHost(statusWindow: false, keepDisplayAwake: false)
        host = h
        let p = PairingScreen(host: h, style: .window)
        pairing = p
        let m = ProductMode(options, host: h, pairing: p)
        product = m
        m.installMenus()
        NSApp.activate()
        DispatchQueue.main.async { MainActor.assumeIsolated { m.start() } }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
}

@main @MainActor enum Main {
    static let delegate = AppDelegate()

    static func main() {
        // `kajo-launch-report` among the arguments: a `launch step=` line per
        // step of the launch (the first-launch follow-up).
        LaunchTrace.step("main")
        // A measurement launch (any `mode=`) holds the display for its whole
        // life, taken before the wake below so the display is never on
        // without it (the first-launch follow-up, docs/modules/first-launch.md:
        // the golden launches held no display assertion, so with the user
        // idle past the display-sleep time powerd asked for the display off
        // at every exit, and the off it asked for between the last golden
        // launch and the first scenario launch landed inside that scenario's
        // window, 2.8 to 5 s with no frames, the assertion the scenario took
        // at its link's start notwithstanding; a released assertion keeps
        // the display on for the gap to the next launch instead). Released
        // when the process exits. No setting is changed.
        if CommandLine.arguments.contains(where: { $0.hasPrefix("mode=") }) {
            var display: IOPMAssertionID = 0
            _ = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn), "Kajo shell launch" as CFString, &display)
        }
        // Wake an asleep display first (the mini's TV sleeps after ten
        // minutes), as a key press would. No setting is changed.
        var activity: IOPMAssertionID = 0
        _ = IOPMAssertionDeclareUserActivity("Kajo launch" as CFString, kIOPMUserActiveLocal, &activity)
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
