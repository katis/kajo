import Darwin

/// What a VM is built with. Everything here is fixed once the VM exists.
struct VMConfig: Sendable {
    /// Background workers (OS threads at user-initiated QoS). The main
    /// worker (index 0) belongs to the shell and runs only in `runMain`.
    var backgroundWorkers = 1
    /// Words per Process stack segment (64 KiB) when the Process is made.
    var stackWords = 8192
    /// Module 8: a stack that runs out is copied into a segment twice its
    /// size, up to this many words (8 MiB); past it a frame that does not
    /// fit is a stack overflow (the Process ends with the VMError).
    var maxStackWords = 1 << 20
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
    /// The collectors' logs (scavenges, young collections, rounds, marking
    /// and relocation cycles, main-thread hops) keep this many records each,
    /// the oldest dropped first and counted; their sums and maxima cover
    /// the whole run (`RecordRing`, docs/modules/collectors-review.md). The
    /// default, the stop log's size, holds every record of the measurement
    /// runs (a 10 s shell scenario, the bench, the soak); an app that runs
    /// for days takes `ShellOptions.appLogCapacity`.
    var logCapacity = 1 << 16
    var stress: VMStress = []
    /// Module 4: the nurseries (`bytes` 0: none, every object old).
    var nursery = NurseryConfig()
    /// Module 5: concurrent marking of old space (needs a nursery; off: the
    /// stop-the-world oracle).
    var marking = MarkingConfig()
    /// Module 6: concurrent relocation of old space (needs marking).
    var relocation = RelocationConfig()
    /// Module 7: young collection without stopping the world (needs a
    /// nursery in a doubly mapped region; `stw`: module 4's scavenge only).
    var young = YoungConfig()
    /// Module 8e: the directory the host opened the VM with (`kajo run
    /// --sources`, `kajo test --sources`): the file primitives (148, 149)
    /// read and write under it and nowhere else; nil, none of them works.
    var sourcesDirectory: String? = nil
    /// Injected yields and sleeps, seeded (docs/VERIFICATION.md layer 5).
    var perturb: Perturbation? = nil
    /// The stop and schedule verifiers at every stop (checked builds).
    var verifyStops = checkedBuild
    /// Module 8c (tests and `kajo run --snapshot-at`): the n-th slow poll
    /// (VM wide) saves the image with every Process in it for the host
    /// (`VM.takeSavedImages`); 0 never.
    var snapshotAtPoll = 0
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
    /// Module 8b: an NDJSON event from primitive 140 (one JSON object, no
    /// newline). Any VM thread, inside the VM; must not block for long.
    var event: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>, Int) -> Void)? = nil
    /// Module 9a: the shell's bridge (an unretained `ShellBridge`, kept
    /// alive by its `ShellVM`): the view host, the event queue and the
    /// handle releases of primitives 150 to 154. nil outside a shell, where
    /// those primitives fail (or answer that there is no shell).
    var host: UnsafeMutableRawPointer? = nil

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
