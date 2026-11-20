import Darwin
import Foundation
import Synchronization

// Module 9a: the VM's public surface for native shells (docs/modules/shells.md
// "The host surface"). A shell opens a VM over an image, gives it the main
// thread in turns, posts the native events it receives, answers the view
// primitives on its main thread and gets the stuck report, the NDJSON event
// stream and the counters back. Oops never cross this surface: a Process is
// a `ShellProcess` handle rooted until released, values are `ShellValue`s.

/// A value crossing the shell boundary: what view primitives take and
/// answer, what events carry, what a spawned Process takes and answered.
public enum ShellValue: Sendable, Equatable, CustomStringConvertible {
    case `nil`
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)

    public var description: String {
        switch self {
        case .nil: "nil"
        case .bool(let b): "\(b)"
        case .int(let i): "\(i)"
        case .double(let d): "\(d)"
        case .string(let s): s
        }
    }

    public var int: Int64? {
        switch self {
        case .int(let i): i
        case .double(let d): Int64(exactly: d.rounded()) ?? nil
        default: nil
        }
    }

    public var double: Double? {
        switch self {
        case .int(let i): Double(i)
        case .double(let d): d
        default: nil
        }
    }

    public var string: String? { if case .string(let s) = self { s } else { nil } }
}

/// One view primitive (150) reaching the shell's view host, on the main
/// thread inside a turn: the op (`create`, `setText`, ...), the native
/// view's handle (0: none) and the arguments. ADR 0010 lists the ops.
public struct ViewCall: Sendable, Equatable {
    public let op: String
    public let handle: Int
    public let arguments: [ShellValue]
    public init(op: String, handle: Int, arguments: [ShellValue]) {
        self.op = op
        self.handle = handle
        self.arguments = arguments
    }
}

/// What a native event is to the kernel's event loop (`UIEvent kind`).
public enum ShellEventKind: Int, Sendable, CaseIterable {
    /// A Button was pressed (target: its handle).
    case click = 1
    /// A Slider moved (target: its handle; value: the Float it moved to).
    case valueChanged = 2
    /// A Window was closed by the user (target: its handle).
    case close = 3
    /// The display link fired (value: the frame number).
    case frame = 4
    /// A measurement event (value: its sequence number).
    case synthetic = 5
    /// Text was entered (target: the view; value: the String).
    case text = 6
    // Module 9c (docs/modules/developer-ui.md): the second round of views and
    // the protocol client.
    /// A key the view was told to report (`keys`) was pressed before the
    /// view handled it (target: the view; value: its name, `cmd-s`).
    case key = 7
    /// An outline's or a table's selection changed (target: the view;
    /// value: the item id or the row, 0 for none).
    case selectionChanged = 8
    /// An item or a row was double-clicked (value: the item id or the row).
    case doubleClick = 9
    /// The user expanded an outline item whose children were not supplied
    /// yet (value: its id): the on-demand form asks for them.
    case expand = 10
    /// A menu or toolbar item was chosen (target: the menu or the toolbar;
    /// value: the item's id).
    case menu = 11
    /// A line a protocol connection received, checked and canonical
    /// (target: the connection; value: the JSON object's text).
    case line = 12
    /// A protocol connection ended (target: the connection; value: why).
    case lost = 13
    /// A timer the image asked for fired (target: its token).
    case timer = 14
    /// The user changed a text view's text (target: the view).
    case textChanged = 15
    /// The first pieces of a line longer than one object can be (target:
    /// the connection; value: at most 16 KiB of its text, cut between
    /// scalars); the `line` event that follows carries the last piece.
    case linePart = 16
    /// Module 9d: the client transport's targets changed (a phone appeared
    /// on the network or went; value: nil): the target picker lists them
    /// again (`ClientTransport targets`).
    case targets = 17
}

/// An event the shell posts. `timeNs` is when it happened (AGENTS.md:
/// never when it was enqueued) on the uptime clock (`ShellVM.now()`,
/// `CLOCK_UPTIME_RAW`, the clock `mach_absolute_time`, `CACurrentMediaTime`
/// and UIKit and AppKit event timestamps count).
public struct ShellEvent: Sendable, Equatable {
    public let kind: ShellEventKind
    public let target: Int
    public let value: ShellValue
    public let timeNs: UInt64
    public init(kind: ShellEventKind, target: Int = 0, value: ShellValue = .nil, timeNs: UInt64) {
        self.kind = kind
        self.target = target
        self.value = value
        self.timeNs = timeNs
    }
}

/// A main-affine Process runnable longer than the limit given to
/// `checkStuck`: its id, the selector of the method it is in, and how long.
public struct StuckReport: Sendable, Equatable {
    public let process: Int64
    public let method: String
    public let milliseconds: Double
}

/// The shell's callbacks. Each is called on a VM thread or on the main
/// thread inside a turn, so build them outside `@MainActor` context
/// (AGENTS.md: such a closure is main-actor code and Swift 6 traps when a
/// VM thread runs it); a callback that touches views does so with
/// `MainActor.assumeIsolated` (`views` runs on the main thread) or by
/// dispatching to the main queue (`wakeMain`, `release`).
public struct ShellCallbacks: Sendable {
    /// A main-affine Process became ready: schedule a turn. Any thread.
    public var wakeMain: (@Sendable () -> Void)?
    /// The stuck report, from `checkStuck` (the thread that called it).
    public var stuck: (@Sendable (StuckReport) -> Void)?
    /// One NDJSON event of the kernel's stream (primitive 140): one JSON
    /// object, no newline. Any VM thread; must not block for long.
    public var events: (@Sendable ([UInt8]) -> Void)?
    /// A view primitive on the main thread, inside a turn. nil fails the
    /// primitive (an unknown op or handle). Must not call back into the VM.
    public var views: (@Sendable (ViewCall) -> ShellValue?)?
    /// The wrapper of a handle died (the finalization Process, any worker):
    /// release the native view, on the main thread.
    public var release: (@Sendable (Int) -> Void)?
    /// Module 9c: the protocol client's transport (primitive 164), any
    /// worker, in a blocking region: `connect`, `send`, `close`, `targets`,
    /// `timer` (docs/modules/developer-ui.md). The call's handle is the
    /// connection. Replies and events come back as `line` and `lost`
    /// events posted to the event queue. nil fails the primitive. Must not
    /// call back into the VM and must not block for long.
    public var client: (@Sendable (ViewCall) -> ShellValue?)?
    public init() {}
}

/// One turn of the main thread in the VM (`ShellVM.runTurn`).
public struct ShellTurn: Sendable {
    /// Wall time in the VM.
    public let ns: UInt64
    /// The calling thread's CPU time in the turn.
    public let cpuNs: UInt64
    /// Waiting to enter and to leave the VM (another worker's stop).
    public let enterWaitNs: UInt64
    public let leaveWaitNs: UInt64
    /// Parked in another worker's stop; of it, copying in a parallel scavenge.
    public let parkNs: UInt64
    public let collectorNs: UInt64
    /// Stopping the world itself (an allocation that collected).
    public let stopNs: UInt64
    /// Young collection on the main worker: acknowledgements, flips or own
    /// collections, waits for the collector.
    public let youngNs: UInt64
    public let acks: UInt64
    /// Slices run, and whether the last one was preempted at the budget.
    public let slices: Int
    public let preempted: Bool

    public var pausedNs: UInt64 { enterWaitNs &+ leaveWaitNs &+ parkNs &+ stopNs }
}

/// The main worker's young-collection counters (module 7's attribution of
/// the main thread's stopped time, ADR 0008), cumulative.
public struct MainThreadCounters: Sendable {
    public var acksOwn: UInt64 = 0, acksOwnNs: UInt64 = 0, acksOther: UInt64 = 0, acksOtherNs: UInt64 = 0, ackMaxNs: UInt64 = 0
    public var serviceNs: UInt64 = 0
    public var ownCollections: UInt64 = 0, ownNs: UInt64 = 0, ownMaxNs: UInt64 = 0
    public var flips: UInt64 = 0, flipNs: UInt64 = 0, flipMaxNs: UInt64 = 0
    public var collectorWaits: UInt64 = 0, collectorWaitNs: UInt64 = 0
    public var edenWaits: UInt64 = 0, edenWaitNs: UInt64 = 0
    public var stopWaitNs: UInt64 = 0, drainWaitNs: UInt64 = 0
    /// The final mark on the devices: the longest single wait before
    /// opening a collection while a stop was wanted or pending.
    public var stopWaitMaxNs: UInt64 = 0
    /// Collections the main worker opened while a stop was wanted.
    public var opensWhileWanted: UInt64 = 0
    /// The main worker always offloads, part 1: the longest single wait
    /// for its collector (cumulative maximum, kept by `since`).
    public var collectorWaitMaxNs: UInt64 = 0

    public init() {}

    init(acksOwn: UInt64, acksOwnNs: UInt64, acksOther: UInt64, acksOtherNs: UInt64, ackMaxNs: UInt64, serviceNs: UInt64,
         ownCollections: UInt64, ownNs: UInt64, ownMaxNs: UInt64, flips: UInt64, flipNs: UInt64, flipMaxNs: UInt64,
         collectorWaits: UInt64, collectorWaitNs: UInt64, edenWaits: UInt64, edenWaitNs: UInt64, stopWaitNs: UInt64,
         drainWaitNs: UInt64, stopWaitMaxNs: UInt64 = 0, opensWhileWanted: UInt64 = 0, collectorWaitMaxNs: UInt64 = 0) {
        self.stopWaitMaxNs = stopWaitMaxNs
        self.collectorWaitMaxNs = collectorWaitMaxNs
        self.opensWhileWanted = opensWhileWanted
        self.acksOwn = acksOwn; self.acksOwnNs = acksOwnNs; self.acksOther = acksOther; self.acksOtherNs = acksOtherNs
        self.ackMaxNs = ackMaxNs; self.serviceNs = serviceNs; self.ownCollections = ownCollections; self.ownNs = ownNs
        self.ownMaxNs = ownMaxNs; self.flips = flips; self.flipNs = flipNs; self.flipMaxNs = flipMaxNs
        self.collectorWaits = collectorWaits; self.collectorWaitNs = collectorWaitNs; self.edenWaits = edenWaits
        self.edenWaitNs = edenWaitNs; self.stopWaitNs = stopWaitNs; self.drainWaitNs = drainWaitNs
    }

    /// Stopped because another worker allocated (rounds of other nurseries'
    /// collections, polls that found none owed, waits for a pending stop and
    /// for collections before a stop); add the turns' `parkNs`.
    public var othersNs: UInt64 { acksOtherNs &+ serviceNs &+ stopWaitNs &+ drainWaitNs }
    /// Its own: flips or own collections, waits for the collector and for
    /// eden reuse, its own rounds.
    public var ownTotalNs: UInt64 { flipNs &+ ownNs &+ collectorWaitNs &+ acksOwnNs &+ edenWaitNs }

    /// `self - earlier`, field by field (maxima are kept).
    public func since(_ e: MainThreadCounters) -> MainThreadCounters {
        var d = self
        d.acksOwn &-= e.acksOwn; d.acksOwnNs &-= e.acksOwnNs; d.acksOther &-= e.acksOther; d.acksOtherNs &-= e.acksOtherNs
        d.serviceNs &-= e.serviceNs; d.ownCollections &-= e.ownCollections; d.ownNs &-= e.ownNs
        d.flips &-= e.flips; d.flipNs &-= e.flipNs; d.collectorWaits &-= e.collectorWaits
        d.collectorWaitNs &-= e.collectorWaitNs; d.edenWaits &-= e.edenWaits; d.edenWaitNs &-= e.edenWaitNs
        d.stopWaitNs &-= e.stopWaitNs; d.drainWaitNs &-= e.drainWaitNs
        d.opensWhileWanted &-= e.opensWhileWanted
        return d
    }
}

/// A VM thread: its role, the 64-bit thread id (for per-thread counters),
/// the QoS class it got.
public struct ShellThread: Sendable {
    public let role: String
    public let threadID: UInt64
    public let qos: UInt32
}

/// A stop of the world (a collection's pause): its kind, when it was
/// requested (uptime ns) and how long it took.
public struct ShellPause: Sendable {
    public let kind: String
    public let atNs: UInt64
    public let pauseNs: UInt64
}

/// What `ShellVM.close` did (docs/modules/shell-close.md). No oop.
public struct ShellCloseReport: Sendable, Equatable, CustomStringConvertible {
    /// This call freed the VM and its image. The first `close` always does;
    /// a later one finds it closed and answers false with zero counts.
    public let destroyed: Bool
    /// Pending roots left besides the finalization Semaphore's when the VM
    /// ended: a Delay's Semaphore, or a signal's that no worker drained
    /// (what the old 3 s wait waited for in vain). Freed with the VM.
    public let pendingRoots: Int
    /// Delay timers armed and not yet fired when the VM ended; each fires
    /// later into nothing.
    public let timersPending: Int
    /// External signals queued after the workers' last drain (an event's,
    /// a request's, a Delay's), freed undelivered.
    public let undeliveredSignals: Int

    public init(destroyed: Bool, pendingRoots: Int = 0, timersPending: Int = 0, undeliveredSignals: Int = 0) {
        self.destroyed = destroyed
        self.pendingRoots = pendingRoots
        self.timersPending = timersPending
        self.undeliveredSignals = undeliveredSignals
    }

    public var description: String {
        "destroyed=\(destroyed) pendingRoots=\(pendingRoots) timersPending=\(timersPending) undeliveredSignals=\(undeliveredSignals)"
    }
}

/// A Process spawned by the shell, rooted until `ShellVM.release`.
public struct ShellProcess: Sendable, Hashable {
    let oop: Oop
    /// The Process's id (`Process id` in Smalltalk, `process` in events).
    public let id: Int64

    public enum State: Sendable { case ready, running, waiting, terminated }
}

public enum ShellError: Error, CustomStringConvertible, Sendable {
    case image(String)
    case options(String)

    public var description: String {
        switch self {
        case .image(let s): "image: \(s)"
        case .options(let s): "options: \(s)"
        }
    }
}

/// A VM over an image, opened for a shell. Thread rules: `runTurn` and
/// `checkStuck` on the shell's main thread (the main worker is that
/// thread); `post`, `spawn`, the Process calls, the counters and `snapshot`
/// from any thread (each enters the VM like a primitive does).
///
/// After `close` (docs/modules/closed-shell-calls.md) the VM and its image
/// are freed, and every member but `post`, `postRequest`, `queuedEvents`,
/// `queuedRequests` and `close` itself stops the process with a message
/// naming the call ("ShellVM.spawn after close"). The check catches a call
/// made after `close` returned; it does not make a call safe to race with
/// `close` on another thread. A host closes from the thread that drives
/// the VM, once nothing else calls it but the four bridge calls.
public final class ShellVM: @unchecked Sendable {
    let image: Image
    let vm: VM
    let bridge: ShellBridge
    private let closeLock = NSLock()
    /// The review fixes (item 20, primitives.F10): the Processes the shell
    /// holds (spawned and not released), by id. A `ShellProcess` carries an
    /// oop and outlives `release`; every call checks it is still held, so a
    /// released one is refused and never reads whatever reused its entry.
    private let heldLock = NSLock()
    private var held: [Int64: Oop] = [:]  // under heldLock
    /// Set by the first `close` (under `closeLock`), read by every checked
    /// member with one relaxed load: an atomic, so a call on any thread
    /// reads it without the lock and ThreadSanitizer sees no race; relaxed,
    /// because it catches calls ordered after the close by the caller's own
    /// synchronization (the same thread, or a join), not racing ones.
    private let closed = Atomic<Bool>(false)
    private var started = false  // under closeLock

    /// Open a VM over image bytes (the kernel image, or one with saved
    /// Processes, which resume when the VM starts). `options` are
    /// `kajo run`'s: workers (background, at least 1), heap, nursery,
    /// collector modes; `options.events` is ignored (`callbacks.events`).
    public init(image bytes: [UInt8], options: Headless.Options = Headless.Options(), callbacks: ShellCallbacks) throws(ShellError) {
        let vc: VMConfig, config: ObjectMemoryConfig
        // The third review's small fixes, item 1: a shell verifies only
        // when its host says so (`options.verify`), not at the checked
        // build's level. With the heap verifiers on in every debug ShellVM,
        // the sanitizer gate failed twice in a row on tool tests over a
        // shell, each time another one (docs/modules/review-3-small-
        // fixes.md, Found); the cause was not found.
        var options = options
        if options.verify == nil { options.verify = false }
        switch Headless.configs(options) {
        case .success(let c): (vc, config) = c
        case .failure(let f): throw .options("\(f)")
        }
        do { image = try Image.load(image: bytes, config: config) } catch { throw .image("\(error)") }
        guard image.entryPoint != image.nilObject else {
            image.destroy()
            throw .image("the image names no entry point")
        }
        bridge = ShellBridge(callbacks, stopsForDebugger: options.stopsForDebugger)
        vm = VM(image: image, config: vc)
        bridge.ref = vm.ref
        let ctx = unsafe Unmanaged.passUnretained(bridge).toOpaque()
        var hooks = unsafe vm.hooks
        unsafe hooks.context = ctx
        unsafe hooks.host = ctx
        unsafe hooks.wakeMain = shellWakeHook
        unsafe hooks.stuck = shellStuckHook
        unsafe hooks.event = shellEventHook
        unsafe vm.hooks = hooks
    }

    /// Open the image file at `path`.
    public convenience init(imageAt path: String, options: Headless.Options = Headless.Options(), callbacks: ShellCallbacks) throws(ShellError) {
        guard let data = FileManager.default.contents(atPath: path) else { throw .image("cannot read \(path)") }
        try self.init(image: [UInt8](data), options: options, callbacks: callbacks)
    }

    deinit { close() }

    /// The refusal of `call` (a member's name) on a closed shell, or nil
    /// while it is open: the one place the rule and its message live. The
    /// checked members trap on it; the tests ask it for every name.
    func refusal(_ call: String) -> String? {
        closed.load(ordering: .relaxed) ? "ShellVM.\(call) after close" : nil
    }

    /// The check at the top of every member that enters the VM or the
    /// image: one relaxed load and a branch; the message is built out of
    /// line, only on the way to the trap, which names the member's line.
    @inline(__always)
    private func checkOpen(_ call: StaticString, file: StaticString = #fileID, line: UInt = #line) {
        if closed.load(ordering: .relaxed) { refuse(call, file: file, line: line) }
    }

    @inline(never)
    private func refuse(_ call: StaticString, file: StaticString, line: UInt) -> Never {
        fatalError(refusal("\(call)") ?? "ShellVM.\(call) refused", file: file, line: line)
    }

    /// Start the background workers, the marker and the young collector.
    /// Saved Processes resume from here (main-affine ones at the next turn).
    public func start() {
        closeLock.lock()
        defer { closeLock.unlock() }
        checkOpen("start")
        precondition(!started, "ShellVM.start twice")
        started = true
        vm.start()
    }

    /// Terminate every Process, stop and join the VM's threads, and free the
    /// VM and its image, at once (docs/modules/shell-close.md). A Delay's
    /// timer, an event's or a request's signal may still hold a pending
    /// root: after `shutdown` no worker drains, so nothing would ever
    /// release it, and nothing needs to. Every thread the VM does not join
    /// reaches it through `VMLife`'s lock (`VMRef`, each Delay's timer), and
    /// `VM.destroy` ends the VM under that lock before it frees anything, so
    /// a signal that comes later does nothing and is counted
    /// (docs/modules/delay-outlives-vm.md). The bridge's Semaphores are
    /// unregistered first: a post after `close` takes no root and signals
    /// nothing. Answers what it did. Idempotent: a later call frees nothing
    /// and answers `destroyed` false. Not from inside a callback, and from
    /// the thread that drives the VM: every member but `post`,
    /// `postRequest`, `queuedEvents` and `queuedRequests` stops with a
    /// message once `close` has returned, but a call already running on
    /// another thread when `close` begins reads freed memory, which no
    /// check can prevent (docs/modules/closed-shell-calls.md).
    @discardableResult
    public func close() -> ShellCloseReport {
        let r = closeOnce()
        closeObserver?(r)
        return r
    }

    /// Tests: sees every `close`'s report, `deinit`'s included (the one
    /// destroy is counted across a close, a second close and the deinit).
    var closeObserver: (@Sendable (ShellCloseReport) -> Void)?
    /// Tests: runs inside the first `close` after `shutdown`, before the
    /// Semaphores are unregistered (a post there is the window the old
    /// wait waited on).
    var afterShutdownForTests: (@Sendable () -> Void)?
    /// The broken variant (docs/modules/shell-close.md): the old wait put
    /// back, for this many seconds, leaking the VM when the pending count
    /// has not fallen. Set by the reproducing test only under
    /// `KAJO_BROKEN_SHELL_CLOSE=1`.
    var brokenOldWaitSeconds: Double? = nil

    private func closeOnce() -> ShellCloseReport {
        closeLock.lock()
        defer { closeLock.unlock() }
        if closed.load(ordering: .relaxed) { return ShellCloseReport(destroyed: false) }
        closed.store(true, ordering: .relaxed)
        if started {
            vm.terminateAll()
            vm.waitUntilAllTerminated()
            vm.shutdown()
        }
        afterShutdownForTests?()
        let h = bridge.unregister()
        if h >= 0 { unsafe unregisterPending(vm.state, h) }
        let ph = bridge.unregisterProtocol()
        if ph >= 0 { unsafe unregisterPending(vm.state, ph) }
        let fin = unsafe vm.state.pointee.finalization.pointee.handle >= 0 ? 1 : 0
        if let seconds = brokenOldWaitSeconds {
            let deadline = ShellVM.now() + UInt64(seconds * 1e9)
            while vm.pendingRootCount > fin && ShellVM.now() < deadline { usleep(5_000) }
            if vm.pendingRootCount > fin { return ShellCloseReport(destroyed: false, pendingRoots: vm.pendingRootCount - fin) }
        }
        let pending = max(0, vm.pendingRootCount - fin)
        let end = vm.destroy()
        image.destroy()
        return ShellCloseReport(destroyed: true, pendingRoots: pending, timersPending: end.timersPending,
                                undeliveredSignals: end.undeliveredSignals)
    }

    /// The uptime clock events are stamped on, in nanoseconds.
    public static func now() -> UInt64 { nanoseconds() }

    // MARK: module 9b: the development protocol

    /// A host serving the development protocol (a transport: KajoDev's
    /// `ProtocolServer`) opens the inbox before the kernel's protocol
    /// Process registers (`DevProtocol start`); without it primitive 159
    /// fails and the image serves nothing. Any thread. A host that opens it
    /// is a host a debugger can come to, so it also turns
    /// `stopsForDebugger` on (the development answers: hosts that serve
    /// ask for it before the image resumes; this covers one that starts
    /// serving later or did not ask).
    public func openProtocol() {
        checkOpen("openProtocol")
        stopsForDebugger = true
        bridge.openProtocol()
    }

    /// Any thread: one request the transport parsed and checked, as the
    /// canonical JSON object the kernel's reader takes, and the connection
    /// it came on. The kernel's replies carry `"conn"` and come out through
    /// `callbacks.events` like every other event.
    public func postRequest(connection: Int, json: [UInt8]) { bridge.postRequest(connection: connection, json: json) }

    /// Requests posted and not yet taken by the protocol Process.
    public var queuedRequests: Int { bridge.queuedRequests }

    /// The development answers (docs/modules/development-answers.md): an
    /// unhandled error in this development image stops its Process for the
    /// debugger (a client can still come) rather than being reported and
    /// ending it. The host's one setting, `Headless.Options.stopsForDebugger`
    /// at the open; a host that starts serving sets it too. A release image
    /// never stops whatever it says. Any thread.
    public var stopsForDebugger: Bool {
        get {
            checkOpen("stopsForDebugger")
            return bridge.stopsForDebugger.load(ordering: .acquiring)
        }
        set {
            checkOpen("stopsForDebugger")
            bridge.stopsForDebugger.store(newValue, ordering: .releasing)
        }
    }

    // MARK: turns

    /// One turn of the main worker on the calling thread (the shell's main
    /// thread): main-affine Processes of at least `minPriority` (0 to 2) run
    /// until none is ready or `budgetNs` is spent (budgeted preemption,
    /// ADR 0004). External signals, the event queue's included, are drained
    /// at its start.
    public func runTurn(budgetNs: UInt64, minPriority: Int = 0) -> ShellTurn {
        checkOpen("runTurn")
        let t = vm.runMain(budgetNs: budgetNs, minPriority: minPriority)
        return ShellTurn(ns: t.ns, cpuNs: t.cpuNs, enterWaitNs: t.enterWaitNs, leaveWaitNs: t.leaveWaitNs,
                         parkNs: t.parkNs, collectorNs: t.collectorNs, stopNs: t.stopNs, youngNs: t.youngNs,
                         acks: t.acks, slices: t.slices, preempted: t.preempted)
    }

    /// The stuck report: every main-affine Process runnable for longer than
    /// `limitNs` is reported once through `callbacks.stuck`.
    public func checkStuck(limitNs: UInt64) {
        checkOpen("checkStuck")
        vm.checkStuck(limitNs: limitNs)
    }

    // MARK: events

    /// Queue a native event for the kernel's event loop. Any thread; takes a
    /// mutex for the append and pushes one external signal. A native
    /// callback posts and returns (ADR 0004); a turn then handles it.
    public func post(_ event: ShellEvent) { bridge.post(event) }

    /// Events posted and not yet taken by the event loop.
    public var queuedEvents: Int { bridge.queued }

    // MARK: Processes

    /// A new Process sending `selector` to the class named `receiver` (nil:
    /// the image's entry point, the class Smalltalk) with `arguments`: on
    /// the main worker if `main`, else on any worker, at `priority` (0 to
    /// 2). nil when the class or the method is missing, an argument cannot
    /// be made, or the record table is full. Rooted until `release`.
    public func spawn(_ selector: String, receiver: String? = nil, arguments: [ShellValue] = [],
                      main: Bool = false, priority: Int = 1) -> ShellProcess? {
        checkOpen("spawn")
        guard (0..<Priority.count).contains(priority) else { return nil }
        let rcv: Oop
        if let receiver {
            guard let ci = image.classIndex(named: receiver) else { return nil }
            rcv = image.om.classOop(ci)
        } else {
            rcv = image.entryPoint
        }
        guard let args = hostValues(arguments) else { return nil }
        defer { for a in args where a.isObject { vm.release(a) } }
        guard let p = vm.spawn(receiver: rcv, selector: selector, arguments: args, priority: priority, main: main) else { return nil }
        let id = vm.inspect { $0.load(p, ProcessLayout.id).smallIntegerValue }
        heldLock.lock()
        held[id] = p
        heldLock.unlock()
        return ShellProcess(oop: p, id: id)
    }

    /// Strings as rooted new objects (released by the caller), the rest as
    /// immediates; nil if a value cannot be made.
    private func hostValues(_ values: [ShellValue]) -> [Oop]? {
        var out: [Oop] = []
        for v in values {
            switch v {
            case .nil: out.append(image.nilObject)
            case .bool(let b): out.append(b ? image.trueObject : image.falseObject)
            case .int(let i):
                guard Oop.fitsSmallInteger(i) else { return nil }
                out.append(Oop(smallInteger: i))
            case .double(let d):
                guard let f = Oop(smallFloat: d) else { return nil }
                out.append(f)
            case .string(let s): out.append(vm.newString(s))
            }
        }
        return out
    }

    /// Whether the shell still holds `p` (not released).
    func holds(_ p: ShellProcess) -> Bool {
        heldLock.lock()
        defer { heldLock.unlock() }
        return held[p.id] == p.oop
    }

    /// A released Process reads as terminated: the shell let it go.
    public func state(of p: ShellProcess) -> ShellProcess.State {
        checkOpen("state")
        guard holds(p) else { return .terminated }
        switch vm.state(of: p.oop) {
        case .ready: return .ready
        case .running: return .running
        case .waiting: return .waiting
        case .terminated: return .terminated
        }
    }

    /// What a terminated Process answered, as a value (nil for an object
    /// that is not one).
    public func result(of p: ShellProcess) -> ShellValue? {
        checkOpen("result")
        guard holds(p) else { return nil }
        let r = vm.result(of: p.oop)
        return unsafe vm.host { w in shellValue(unsafe vm.machine(w), r) }
    }

    /// Why a Process was terminated by the VM (an error), if it was.
    public func failure(of p: ShellProcess) -> String? {
        checkOpen("failure")
        guard holds(p) else { return "released by the shell" }
        return vm.error(of: p.oop).map { "\($0)" }
    }

    /// Block until `p` has terminated (one watcher at a time). Not on the
    /// main thread while `p` needs main turns.
    public func waitUntilTerminated(_ p: ShellProcess) {
        checkOpen("waitUntilTerminated")
        guard holds(p) else { return }
        vm.waitUntilTerminated(p.oop)
    }

    public func terminate(_ p: ShellProcess) {
        checkOpen("terminate")
        guard holds(p) else { return }
        vm.terminate(p.oop)
    }

    /// The shell no longer needs `p`.
    public func release(_ p: ShellProcess) {
        checkOpen("release")
        heldLock.lock()
        let mine = held[p.id] == p.oop
        if mine { held[p.id] = nil }
        heldLock.unlock()
        if mine { vm.release(p.oop) }
    }

    public var liveProcessCount: Int {
        checkOpen("liveProcessCount")
        return vm.liveProcessCount
    }

    /// Processes the image held and the VM resumed (module 8c).
    public var resumedProcessCount: Int {
        checkOpen("resumedProcessCount")
        return vm.resumedProcesses.count
    }
    /// Module 8d: the image is a release image (its header's flag).
    public var isReleaseImage: Bool {
        checkOpen("isReleaseImage")
        return image.isRelease
    }
    /// AOT 2: what binding the native module did (nil: none was given).
    public var nativeBindReport: NativeBindReport? {
        checkOpen("nativeBindReport")
        return vm.nativeReport
    }
    /// AOT 2: the methods the given module's generator wrote and declined.
    public var nativeGenerated: (generated: UInt64, declined: UInt64)? {
        checkOpen("nativeGenerated")
        return vm.config.native.map { ($0.methodsGenerated, $0.methodsDeclined) }
    }

    // MARK: snapshot

    /// The shell's save command: `Smalltalk snapshot: path` in a new
    /// Process on a background worker, waited for. True when the image was
    /// written. The saved image resumes every Process, the saver answering
    /// true there. Call it off the main thread when main-affine Processes
    /// must run for the save to finish.
    public func snapshot(to path: String) -> Bool {
        checkOpen("snapshot")
        guard let p = spawn("snapshot:", arguments: [.string(path)]) else { return false }
        defer { release(p) }
        waitUntilTerminated(p)
        return failure(of: p) == nil && result(of: p) == .bool(false) && FileManager.default.fileExists(atPath: path)
    }

    // MARK: telemetry

    /// The VM's counters (module 3's and this module's) and the object
    /// memory's, in a stable order.
    public var counters: [(name: String, value: UInt64)] {
        checkOpen("counters")
        let m = image.om.counters
        return vm.counters.named + [("collections", m.collections), ("allocations", m.allocations),
                                    ("allocatedBytes", m.allocatedBytes)]
    }

    /// The collectors' report lines of `kajo run` (modules 4 to 7): pauses,
    /// cycles, relocation, young collection and the collector's QoS and CPU.
    public func collectorReport(seconds: Double) -> [(name: String, value: String)] {
        checkOpen("collectorReport")
        let stops = vm.stops
        return nurseryReport(vm, stops: stops, ms: seconds * 1000) + markingReport(vm, stops: stops)
            + relocationReport(vm) + youngReport(vm, ms: seconds * 1000)
    }

    /// The main worker's young-collection counters, cumulative. Read on the
    /// main thread between turns.
    public var mainThreadCounters: MainThreadCounters {
        checkOpen("mainThreadCounters")
        let y = vm.youngWorkerCounters(0)
        return MainThreadCounters(
            acksOwn: y.acksOwn, acksOwnNs: y.acksOwnNs, acksOther: y.acksOther, acksOtherNs: y.acksOtherNs,
            ackMaxNs: y.ackMaxNs, serviceNs: y.serviceNs, ownCollections: y.ownCollections, ownNs: y.ownNs,
            ownMaxNs: y.ownMaxNs, flips: y.flips, flipNs: y.flipNs, flipMaxNs: y.flipMaxNs,
            collectorWaits: y.collectorWaits, collectorWaitNs: y.collectorWaitNs, edenWaits: y.edenWaits,
            edenWaitNs: y.edenWaitNs, stopWaitNs: y.stopWaitNs, drainWaitNs: y.drainWaitNs, stopWaitMaxNs: y.stopWaitMaxNs,
            opensWhileWanted: y.opensWhileWanted, collectorWaitMaxNs: y.collectorWaitMaxNs)
    }

    /// Every stop so far (the last 65 536).
    public var pauses: [ShellPause] {
        checkOpen("pauses")
        return vm.stops.map { ShellPause(kind: "\($0.kind)", atNs: $0.atNs, pauseNs: $0.pauseNs) }
    }

    /// The VM's threads that exist: background workers, the marker, the
    /// young collector (the main worker is the shell's thread).
    public var threads: [ShellThread] {
        checkOpen("threads")
        return vm.shellThreads()
    }

    /// How long each hop to main took, from the hop to the retried send on
    /// the main worker (ns).
    public var hopLatencies: [UInt64] {
        checkOpen("hopLatencies")
        return vm.hopLatencies
    }
}

/// A host-readable value (inside the VM).
func shellValue(_ m: Machine, _ v: Oop) -> ShellValue? {
    if v == m.nilObject { return .nil }
    if v == m.trueObject { return .bool(true) }
    if v == m.falseObject { return .bool(false) }
    if v.isSmallInteger { return .int(v.smallIntegerValue) }
    if let s = m.text(v) { return .string(s) }
    if let d = m.double(v) { return .double(d) }
    return nil
}

extension VM {
    /// A new String, rooted for the host.
    func newString(_ s: String) -> Oop {
        unsafe host { w in
            let o = unsafe machine(w).newString(Array(s.utf8))
            precondition(o != .none, "heap full")
            keepForHost(o)
            return o
        }
    }

    /// The VM's own threads with their 64-bit ids and QoS.
    func shellThreads() -> [ShellThread] {
        var out: [ShellThread] = []
        func add(_ role: String, _ port: UInt32, _ qos: UInt32) {
            guard port != 0 else { return }
            var info = thread_identifier_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_identifier_info>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                unsafe $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    unsafe thread_info(port, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &count)
                }
            }
            if kr == KERN_SUCCESS { out.append(ShellThread(role: role, threadID: info.thread_id, qos: qos)) }
        }
        for i in 1...max(1, config.backgroundWorkers) where i <= config.backgroundWorkers {
            add("worker\(i)", unsafe state.shared(i).pointee.machThread.load(ordering: .relaxed), workerQoS(i).rawValue)
        }
        if let mk = unsafe state.pointee.marking {
            add("marker", unsafe mk.pointee.machThread.pointee.load(ordering: .relaxed), 0)
        }
        if let y = unsafe state.pointee.young {
            add("collector", unsafe y.pointee.collectorMachThread.pointee.load(ordering: .relaxed), youngCollectorQoS.rawValue)
        }
        return out
    }
}
