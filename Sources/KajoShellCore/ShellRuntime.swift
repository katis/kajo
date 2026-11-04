import Dispatch
import Foundation
import KajoVM
import Synchronization

/// What a platform shell (AppKit or UIKit) gives the shared code: the view
/// host behind primitive 150, the display link, a status line.
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
}

/// Where a turn came from.
public enum TurnKind: String, Sendable { case tick, event, wake }

/// Shared by the callbacks (built outside the main actor) and the runtime.
final class RuntimeLink: @unchecked Sendable {
    weak var runtime: ShellRuntime?
    let wakePending = Atomic<Bool>(false)
    let events: @Sendable ([UInt8]) -> Void
    init(events: @escaping @Sendable ([UInt8]) -> Void) { self.events = events }
}

/// A ShellVM driven by the main run loop: turns when a main-affine Process
/// becomes ready (`wakeMain`), after events are posted and at every display
/// refresh, with the frame account of the experiments (4 ms of each frame
/// for the VM; past it, UI-priority turns of 0.5 ms only).
@MainActor public final class ShellRuntime {
    public let vm: ShellVM
    public unowned let platform: ShellPlatform
    let link: RuntimeLink

    /// The VM's share of a frame, and what is left of it.
    public var frameAccountNs: Int64 = 4_000_000
    public private(set) var frameRemaining: Int64 = 4_000_000
    /// Budget of a turn at a tick and at an event (ADR 0004's budgets);
    /// `budgetOff` makes every turn one long turn (the control).
    public var tickBudgetNs: Int64 = 3_000_000
    public var eventBudgetNs: Int64 = 1_000_000
    public var budgetOffNs: UInt64? = nil
    /// Observers: every turn, every view call before it reaches the
    /// platform, every stuck report.
    public var onTurn: ((ShellTurn, TurnKind) -> Void)?
    public var onView: ((ViewCall) -> Void)?
    public var onStuck: ((StuckReport) -> Void)?
    public private(set) var turns = 0
    public private(set) var uiOnlyTurns = 0

    /// Open `imagePath` with `options`; `events` gets the kernel's NDJSON
    /// stream on the emitting VM thread.
    public init(imagePath: String, options: Headless.Options, platform: ShellPlatform,
                events: @escaping @Sendable ([UInt8]) -> Void) throws {
        let link = RuntimeLink(events: events)
        self.link = link
        self.platform = platform
        vm = try ShellVM(imageAt: imagePath, options: options, callbacks: ShellRuntime.callbacks(link))
        link.runtime = self
        platform.eventHandler = { [weak self] e in self?.deliver(e) }
    }

    /// The callbacks, built outside main-actor context (AGENTS.md).
    nonisolated static func callbacks(_ link: RuntimeLink) -> ShellCallbacks {
        var c = ShellCallbacks()
        c.wakeMain = {
            if link.wakePending.exchange(true, ordering: .acquiringAndReleasing) { return }
            DispatchQueue.main.async {
                link.wakePending.store(false, ordering: .releasing)
                MainActor.assumeIsolated { link.runtime?.turn(.wake) }
            }
        }
        c.views = { call in MainActor.assumeIsolated { link.runtime?.view(call) } }
        c.release = { h in DispatchQueue.main.async { MainActor.assumeIsolated { link.runtime?.platform.releaseView(h) } } }
        c.stuck = { r in MainActor.assumeIsolated { link.runtime?.onStuck?(r) } }
        c.events = { e in link.events(e) }
        return c
    }

    public func start() { vm.start() }

    func view(_ call: ViewCall) -> ShellValue? {
        onView?(call)
        return platform.viewCall(call)
    }

    /// Whether a display link calls `tick`. Without one the frame account
    /// is renewed by the clock, and a turn that left work (preempted, or
    /// UI-only) schedules another at once.
    public var ticking = false
    var frameStartNs: UInt64 = 0
    var followUp = false

    /// One turn now.
    public func turn(_ kind: TurnKind) {
        if !ticking {
            let now = ShellVM.now()
            if now &- frameStartNs > UInt64(1e9) / UInt64(max(1, platform.maximumFramesPerSecond)) {
                frameStartNs = now
                frameRemaining = frameAccountNs
            }
        }
        var budget: UInt64
        var minPriority = 0
        if let off = budgetOffNs {
            budget = off
        } else if frameRemaining > 200_000 {
            budget = UInt64(min(kind == .tick ? tickBudgetNs : eventBudgetNs, frameRemaining))
        } else {
            budget = 500_000
            minPriority = 2
            uiOnlyTurns += 1
        }
        let t = vm.runTurn(budgetNs: budget, minPriority: minPriority)
        frameRemaining -= Int64(t.ns)
        turns += 1
        onTurn?(t, kind)
        if !ticking && (t.preempted || minPriority > 0) && !followUp {
            followUp = true
            DispatchQueue.main.async { MainActor.assumeIsolated { self.followUp = false; self.turn(.wake) } }
        }
    }

    /// A display refresh: a new frame account, a frame event for the
    /// kernel's frame actions (when `postFrames`), a turn, the stuck check.
    public var postFrames = false
    public private(set) var frameNumber: Int64 = 0
    public var stuckLimitNs: UInt64 = 300_000_000

    public func tick(timestamp: Double) {
        frameRemaining = frameAccountNs
        frameStartNs = UInt64(timestamp * 1e9)
        frameNumber += 1
        if postFrames {
            vm.post(ShellEvent(kind: .frame, value: .int(frameNumber), timeNs: UInt64(timestamp * 1e9)))
        }
        turn(.tick)
        vm.checkStuck(limitNs: stuckLimitNs)
    }

    /// Post an event and handle it in a turn now (ADR 0004: synchronously
    /// in the run-loop turn that delivered it).
    public func deliver(_ e: ShellEvent) {
        vm.post(e)
        turn(.event)
    }
}
