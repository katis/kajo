import Darwin

/// What a VM is built with. Everything here is fixed once the VM exists.
struct VMConfig: Sendable {
    /// Background workers (OS threads at user-initiated QoS). The main
    /// worker (index 0) belongs to the shell and runs only in `runMain`.
    var backgroundWorkers = 1
    /// Words per Process stack segment (64 KiB).
    var stackWords = 8192
    /// Polls between two budget checks (clock reads, external queue,
    /// terminate requests). ADR 0004: 1024.
    var pollEvery = 1024
    /// A background worker's time slice; 0 disables preemption of
    /// background Processes (kernel cost isolation).
    var sliceNs: UInt64 = 5_000_000
    /// Native records: the most Processes alive at once.
    var recordCapacity = 32_768
    /// Pending-root slots: the most outstanding operations (Delays) at once.
    var pendingCapacity = 1 << 16
    var stress: VMStress = []
    /// Module 4: the nurseries (`bytes` 0: none, every object old).
    var nursery = NurseryConfig()
    /// Module 5: concurrent marking of old space (needs a nursery; off: the
    /// stop-the-world oracle).
    var marking = MarkingConfig()
    /// Injected yields and sleeps, seeded (docs/VERIFICATION.md layer 5).
    var perturb: Perturbation? = nil
    /// The stop and schedule verifiers at every stop (checked builds).
    var verifyStops = checkedBuild
    var testSwitches = VMTestSwitches()

    init() {}
}

/// Stress flags of this module (module 1's are in `StressFlags`).
struct VMStress: OptionSet, Sendable {
    let rawValue: UInt8
    /// Countdown 1 and a deadline that has always passed: every poll but
    /// the first of a slice preempts the running Process.
    static let preemptEveryPoll = VMStress(rawValue: 1)
    /// Countdown 1 and every poll slow path stops the world and collects.
    static let stopEveryPoll = VMStress(rawValue: 2)

    init(rawValue: UInt8) { self.rawValue = rawValue }

    /// `preempt`, `stop`, comma separated (the `--stress` syntax).
    init(parsing s: String) {
        var f: VMStress = []
        for part in s.split(separator: ",") {
            switch part {
            case "preempt": f.insert(.preemptEveryPoll)
            case "stop": f.insert(.stopEveryPoll)
            default: break
            }
        }
        self = f
    }
}

/// Schedule perturbation: at poll slow paths, park points, fork, signal
/// and wait, a worker yields its CPU or sleeps up to `maxSleepUs` with
/// probability `probability`, drawn from a per-worker generator seeded
/// from `seed`. Later modules widen their protocols' windows with it.
struct Perturbation: Sendable {
    var seed: UInt64
    var probability: Double
    var maxSleepUs: UInt32 = 20

    init(seed: UInt64, probability: Double, maxSleepUs: UInt32 = 20) {
        self.seed = seed
        self.probability = probability
        self.maxSleepUs = maxSleepUs
    }
}

/// Switches that turn a rule off so a test can show the rule matters.
/// Never set outside tests.
struct VMTestSwitches: Sendable {
    /// The worker's result register is not cleared when its Process
    /// terminates (concurrent-young amendment 8).
    var keepResultRegister = false
    /// The generational-gc bug: a stop does not zero `parked` when it
    /// releases the world; each parker decrements it when it wakes.
    var countReleasedAsParked = false
    /// The poll flushes the registers after a stop instead of before it, so
    /// the stop scans the stack through a stale sp.
    var flushAfterStop = false
    /// A suspending worker publishes the Process and only then (in a second
    /// critical section) clears `current` and the record's `runningOn`.
    var publishBeforeClearing = false
    /// Delays are not registered in the pending-root table.
    var noPendingRoots = false
}

/// C-convention hooks the shell sets before any worker starts, so no
/// closure built in `@MainActor` context ever runs on a VM thread
/// (AGENTS.md). `context` is passed back to every hook.
@unsafe struct VMHooks: @unchecked Sendable {
    var context: UnsafeMutableRawPointer? = nil
    /// A main-affine Process became ready: schedule a turn. Any thread.
    var wakeMain: (@convention(c) (UnsafeMutableRawPointer?) -> Void)? = nil
    /// A main-affine Process has been runnable longer than the limit given
    /// to `checkStuck`: id, selector, milliseconds. Called once per Process.
    var stuck: (@convention(c) (UnsafeMutableRawPointer?, Int64, UnsafePointer<CChar>, Double) -> Void)? = nil
    /// A shell call (primitive 29) on the main worker: kind, value, answer.
    var shell: (@convention(c) (UnsafeMutableRawPointer?, Int64, Int64) -> Int64)? = nil

    init(context: UnsafeMutableRawPointer? = nil,
         wakeMain: (@convention(c) (UnsafeMutableRawPointer?) -> Void)? = nil,
         stuck: (@convention(c) (UnsafeMutableRawPointer?, Int64, UnsafePointer<CChar>, Double) -> Void)? = nil,
         shell: (@convention(c) (UnsafeMutableRawPointer?, Int64, Int64) -> Int64)? = nil) {
        unsafe self.context = context
        unsafe self.wakeMain = unsafe wakeMain
        unsafe self.stuck = unsafe stuck
        unsafe self.shell = unsafe shell
    }
}
