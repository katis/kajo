import Darwin
import Foundation

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

    public init() {}

    init(acksOwn: UInt64, acksOwnNs: UInt64, acksOther: UInt64, acksOtherNs: UInt64, ackMaxNs: UInt64, serviceNs: UInt64,
         ownCollections: UInt64, ownNs: UInt64, ownMaxNs: UInt64, flips: UInt64, flipNs: UInt64, flipMaxNs: UInt64,
         collectorWaits: UInt64, collectorWaitNs: UInt64, edenWaits: UInt64, edenWaitNs: UInt64, stopWaitNs: UInt64,
         drainWaitNs: UInt64) {
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
public final class ShellVM: @unchecked Sendable {
    let image: Image
    let vm: VM
    let bridge: ShellBridge
    private let closeLock = NSLock()
    private var closed = false
    private var started = false

    /// Open a VM over image bytes (the kernel image, or one with saved
    /// Processes, which resume when the VM starts). `options` are
    /// `kajo run`'s: workers (background, at least 1), heap, nursery,
    /// collector modes; `options.events` is ignored (`callbacks.events`).
    public init(image bytes: [UInt8], options: Headless.Options = Headless.Options(), callbacks: ShellCallbacks) throws(ShellError) {
        let vc: VMConfig, config: ObjectMemoryConfig
        switch Headless.configs(options) {
        case .success(let c): (vc, config) = c
        case .failure(let f): throw .options("\(f)")
        }
        do { image = try Image.load(image: bytes, config: config) } catch { throw .image("\(error)") }
        guard image.entryPoint != image.nilObject else {
            image.destroy()
            throw .image("the image names no entry point")
        }
        bridge = ShellBridge(callbacks)
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

    /// Start the background workers, the marker and the young collector.
    /// Saved Processes resume from here (main-affine ones at the next turn).
    public func start() {
        closeLock.lock()
        defer { closeLock.unlock() }
        precondition(!started && !closed)
        started = true
        vm.start()
    }

    /// Terminate every Process, stop the threads and free the VM and its
    /// image. Waits up to `timeoutSeconds` for outstanding Delays' timers
    /// (they would signal a freed VM); past it the VM is leaked, not freed.
    /// Idempotent; not from inside a callback.
    public func close(timeoutSeconds: Double = 3) {
        closeLock.lock()
        defer { closeLock.unlock() }
        if closed { return }
        closed = true
        if started {
            vm.terminateAll()
            vm.waitUntilAllTerminated()
            vm.shutdown()
        }
        let h = bridge.unregister()
        if h >= 0 { unsafe unregisterPending(vm.state, h) }
        let fin = unsafe vm.state.pointee.finalization.pointee.handle >= 0 ? 1 : 0
        let deadline = ShellVM.now() + UInt64(timeoutSeconds * 1e9)
        while vm.pendingRootCount > fin && ShellVM.now() < deadline { usleep(5_000) }
        if vm.pendingRootCount > fin { return }
        vm.destroy()
        image.destroy()
    }

    /// The uptime clock events are stamped on, in nanoseconds.
    public static func now() -> UInt64 { nanoseconds() }

    // MARK: turns

    /// One turn of the main worker on the calling thread (the shell's main
    /// thread): main-affine Processes of at least `minPriority` (0 to 2) run
    /// until none is ready or `budgetNs` is spent (budgeted preemption,
    /// ADR 0004). External signals, the event queue's included, are drained
    /// at its start.
    public func runTurn(budgetNs: UInt64, minPriority: Int = 0) -> ShellTurn {
        let t = vm.runMain(budgetNs: budgetNs, minPriority: minPriority)
        return ShellTurn(ns: t.ns, cpuNs: t.cpuNs, enterWaitNs: t.enterWaitNs, leaveWaitNs: t.leaveWaitNs,
                         parkNs: t.parkNs, collectorNs: t.collectorNs, stopNs: t.stopNs, youngNs: t.youngNs,
                         acks: t.acks, slices: t.slices, preempted: t.preempted)
    }

    /// The stuck report: every main-affine Process runnable for longer than
    /// `limitNs` is reported once through `callbacks.stuck`.
    public func checkStuck(limitNs: UInt64) { vm.checkStuck(limitNs: limitNs) }

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

    public func state(of p: ShellProcess) -> ShellProcess.State {
        switch vm.state(of: p.oop) {
        case .ready: .ready
        case .running: .running
        case .waiting: .waiting
        case .terminated: .terminated
        }
    }

    /// What a terminated Process answered, as a value (nil for an object
    /// that is not one).
    public func result(of p: ShellProcess) -> ShellValue? {
        let r = vm.result(of: p.oop)
        return unsafe vm.host { w in shellValue(unsafe vm.machine(w), r) }
    }

    /// Why a Process was terminated by the VM (an error), if it was.
    public func failure(of p: ShellProcess) -> String? { vm.error(of: p.oop).map { "\($0)" } }

    /// Block until `p` has terminated (one watcher at a time). Not on the
    /// main thread while `p` needs main turns.
    public func waitUntilTerminated(_ p: ShellProcess) { vm.waitUntilTerminated(p.oop) }

    public func terminate(_ p: ShellProcess) { vm.terminate(p.oop) }

    /// The shell no longer needs `p`.
    public func release(_ p: ShellProcess) { vm.release(p.oop) }

    public var liveProcessCount: Int { vm.liveProcessCount }

    /// Processes the image held and the VM resumed (module 8c).
    public var resumedProcessCount: Int { vm.resumedProcesses.count }

    // MARK: snapshot

    /// The shell's save command: `Smalltalk snapshot: path` in a new
    /// Process on a background worker, waited for. True when the image was
    /// written. The saved image resumes every Process, the saver answering
    /// true there. Call it off the main thread when main-affine Processes
    /// must run for the save to finish.
    public func snapshot(to path: String) -> Bool {
        guard let p = spawn("snapshot:", arguments: [.string(path)]) else { return false }
        defer { release(p) }
        waitUntilTerminated(p)
        return failure(of: p) == nil && result(of: p) == .bool(false) && FileManager.default.fileExists(atPath: path)
    }

    // MARK: telemetry

    /// The VM's counters (module 3's and this module's) and the object
    /// memory's, in a stable order.
    public var counters: [(name: String, value: UInt64)] {
        let m = image.om.counters
        return vm.counters.named + [("collections", m.collections), ("allocations", m.allocations),
                                    ("allocatedBytes", m.allocatedBytes)]
    }

    /// The collectors' report lines of `kajo run` (modules 4 to 7): pauses,
    /// cycles, relocation, young collection and the collector's QoS and CPU.
    public func collectorReport(seconds: Double) -> [(name: String, value: String)] {
        let stops = vm.stops
        return nurseryReport(vm, stops: stops, ms: seconds * 1000) + markingReport(vm, stops: stops)
            + relocationReport(vm) + youngReport(vm, ms: seconds * 1000)
    }

    /// The main worker's young-collection counters, cumulative. Read on the
    /// main thread between turns.
    public var mainThreadCounters: MainThreadCounters {
        let y = vm.youngWorkerCounters(0)
        return MainThreadCounters(
            acksOwn: y.acksOwn, acksOwnNs: y.acksOwnNs, acksOther: y.acksOther, acksOtherNs: y.acksOtherNs,
            ackMaxNs: y.ackMaxNs, serviceNs: y.serviceNs, ownCollections: y.ownCollections, ownNs: y.ownNs,
            ownMaxNs: y.ownMaxNs, flips: y.flips, flipNs: y.flipNs, flipMaxNs: y.flipMaxNs,
            collectorWaits: y.collectorWaits, collectorWaitNs: y.collectorWaitNs, edenWaits: y.edenWaits,
            edenWaitNs: y.edenWaitNs, stopWaitNs: y.stopWaitNs, drainWaitNs: y.drainWaitNs)
    }

    /// Every stop so far (the last 65 536).
    public var pauses: [ShellPause] { vm.stops.map { ShellPause(kind: "\($0.kind)", atNs: $0.atNs, pauseNs: $0.pauseNs) } }

    /// The VM's threads that exist: background workers, the marker, the
    /// young collector (the main worker is the shell's thread).
    public var threads: [ShellThread] { vm.shellThreads() }

    /// Round latencies of young collection (ns), the hop latencies (ns).
    public var hopLatencies: [UInt64] { vm.hopLatencies }
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
