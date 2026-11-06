import KajoVM

// Module 11a (docs/modules/app-project.md): the library a Kajo app links.
// Module 9a's runtime and the AppKit and UIKit hosts, moved out of the
// shells so that a generated app and the shells in apps/ run one
// implementation of every view wrapper. Nothing here serves the
// development protocol, measures, or compiles: those are
// KajoAppDevelopment (a Debug build's) and KajoShellCore (the shells').

/// What a platform host (AppKit or UIKit) gives the runtime: the view host
/// behind primitive 150, the display link, a status line.
@MainActor public protocol ShellPlatform: AnyObject {
    /// One view primitive, on the main thread inside a turn (ADR 0010's
    /// ops: create, set, get, frame, origin, add, call). nil fails it.
    func viewCall(_ call: ViewCall) -> ShellValue?
    /// The wrapper of `handle` died: release the native view.
    func releaseView(_ handle: Int)
    /// The display's nominal rate (frames per second).
    var maximumFramesPerSecond: Int { get }
    /// Call `tick(timestamp, targetTimestamp)` (seconds, the uptime clock)
    /// on the main thread at every display refresh.
    func startDisplayLink(_ tick: @escaping @MainActor (Double, Double) -> Void)
    func stopDisplayLink()
    func showStatus(_ line: String)
    /// Where the platform's controls send their events (a click, a slider
    /// move, a window closed); the runtime sets it.
    var eventHandler: ((ShellEvent) -> Void)? { get set }
    /// Module 9c: a text view drew (its handle), for the typing measurement.
    var textDrawn: ((Int) -> Void)? { get set }
    /// Module 9c: a key typed into the text view `handle` as the window
    /// server would deliver it (the typing measurement); false when the
    /// platform cannot.
    func typeKey(_ handle: Int, _ text: String) -> Bool
}

/// Where a turn came from.
public enum TurnKind: String, Sendable { case tick, event, wake }
