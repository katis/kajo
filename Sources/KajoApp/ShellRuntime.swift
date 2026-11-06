import Dispatch
import Foundation
import KajoVM
import Synchronization

/// Shared by the callbacks (built outside the main actor) and the runtime.
final class RuntimeLink: @unchecked Sendable {
    weak var runtime: ShellRuntime?
    let wakePending = Atomic<Bool>(false)
    let events: @Sendable ([UInt8]) -> Void
    /// Module 11a: a second reader of every kernel line, set by a
    /// development build while it serves (the transport's replies and
    /// events); nil in a release app, which has no transport to give one.
    let tap = Mutex<(@Sendable ([UInt8]) -> Void)?>(nil)
    /// Module 9c: the protocol client's transport behind primitive 164, when
    /// the host gives one (the shells' development modes); nil fails it.
    let client: (@Sendable (ViewCall) -> ShellValue?)?
    init(events: @escaping @Sendable ([UInt8]) -> Void, client: (@Sendable (ViewCall) -> ShellValue?)?) {
        self.events = events
        self.client = client
    }

    /// Every kernel line: the mode's sink, then the tap.
    func emit(_ e: [UInt8]) {
        events(e)
        if let t = tap.withLock({ $0 }) { t(e) }
    }
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
    /// stream on the emitting VM thread; `client` is primitive 164's
    /// transport (module 9c), when the host has one.
    public init(imagePath: String, options: Headless.Options, platform: ShellPlatform,
                events: @escaping @Sendable ([UInt8]) -> Void,
                client: (@Sendable (ViewCall) -> ShellValue?)? = nil) throws {
        let link = RuntimeLink(events: events, client: client)
        self.link = link
        self.platform = platform
        vm = try ShellVM(imageAt: imagePath, options: options, callbacks: ShellRuntime.callbacks(link))
        link.runtime = self
        platform.eventHandler = { [weak self] e in self?.deliver(e) }
    }

    /// Module 11a: what a development build keeps beside the runtime while
    /// it serves (KajoAppDevelopment's transport, advertisement and client
    /// host); nil in a release app.
    public var developmentState: AnyObject?

    /// Module 11a: a second reader of every kernel line (on the emitting VM
    /// thread, so built outside main-actor context), or nil.
    public func setEventTap(_ tap: (@Sendable ([UInt8]) -> Void)?) {
        link.tap.withLock { $0 = tap }
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
        c.events = { e in link.emit(e) }
        c.client = link.client
        return c
    }

    public func start() { vm.start() }

    /// Module 9c: every view call's time in the platform (ns), after it.
    public var onViewDone: ((ViewCall, UInt64) -> Void)?

    func view(_ call: ViewCall) -> ShellValue? {
        onView?(call)
        guard let done = onViewDone else { return platform.viewCall(call) }
        let t0 = ShellVM.now()
        let r = platform.viewCall(call)
        done(call, ShellVM.now() &- t0)
        return r
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
