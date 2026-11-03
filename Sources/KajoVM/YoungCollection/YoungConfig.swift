import Darwin

/// How nurseries are collected (docs/modules/young-collection.md, ADR 0008).
enum YoungMode: UInt8, Sendable, CaseIterable {
    /// Module 4's stop-the-world scavenge of every nursery: the oracle.
    case stw
    /// Every nursery is collected by its owner while the others run.
    case local
    /// The policy: the main worker's nursery (two eden halves) is collected
    /// by the young collector thread while the main worker runs on in the
    /// other half; background workers (and the host) collect locally.
    case offload

    init?(name: String) {
        switch name {
        case "stw": self = .stw
        case "local": self = .local
        case "offload": self = .offload
        default: return nil
        }
    }

    var name: String { ["stw", "local", "offload"][Int(rawValue)] }
}

/// Young collection's configuration. Part of `VMConfig`; fixed once the VM
/// exists. Needs a nursery whose region is mapped twice
/// (`ObjectMemoryConfig.nurseryRegionBytes`); without one, or without a
/// nursery, the mode is `stw`.
struct YoungConfig: Sendable {
    var mode = YoungMode.offload
    /// Offload: the young collector thread is started with the VM. Off (or
    /// before `VM.start`), an offloaded nursery is collected by its owner
    /// right after its flip (tests that drive workers from one thread).
    var collectorThread = true
    /// The collector thread's QoS (ADR 0008's device policy: user-initiated;
    /// the marker at utility, module 5).
    var collectorQoS = QOS_CLASS_USER_INITIATED
    /// The young verifier at a stop after every `verifyEvery`-th collection
    /// (checked builds; the tests turn it on).
    var verify = checkedBuild
    var verifyEvery = 1
    var stress: YoungStress = []
    var testSwitches = YoungTestSwitches()

    init() {}
}

/// Stress flags (docs/VERIFICATION.md layer 3).
struct YoungStress: OptionSet, Sendable {
    let rawValue: UInt8
    /// Offload: 64 KiB eden halves, so the offloaded nursery is collected
    /// every time 64 KiB fill.
    static let collectAtEveryHalf = YoungStress(rawValue: 1)
    /// While a collection runs its collector opens a drain round after every
    /// 16 objects it copies: every poll of every participant services a
    /// round.
    static let roundAtEveryPoll = YoungStress(rawValue: 2)

    init(rawValue: UInt8) { self.rawValue = rawValue }

    /// `everyhalf`, `everypoll`, comma separated.
    init(parsing s: String) {
        var f: YoungStress = []
        for part in s.split(separator: ",") {
            switch part {
            case "everyhalf": f.insert(.collectAtEveryHalf)
            case "everypoll": f.insert(.roundAtEveryPoll)
            default: break
            }
        }
        self = f
    }
}

/// A test hook: called by a collector with (context, nursery, point).
/// Points: 0 before H0, 1 after H1 (before T1), 3 after T1's work (before
/// the drain rounds), 2 after the entry sweep (before the epoch rule).
typealias YoungHook = @convention(c) (UnsafeMutableRawPointer?, Int, Int) -> Void

/// Switches that turn a rule off so a test can show the rule matters
/// (docs/modules/young-collection.md "Tests"). Never set outside tests.
struct YoungTestSwitches: @unchecked Sendable {
    /// The barrier records the young value a store overwrites while its
    /// nursery is collected.
    var youngDeletionBarrier = true
    /// Drain rounds after T1 until one copies nothing (off: none).
    var secondHandshake = true
    /// The barrier remembers a young holder of another nursery (off: old
    /// holders only, module 4's rule).
    var crossNurseryBarrier = true
    /// A participant scans its stack at its H1 acknowledgement (and a
    /// resumer a parked Process's).
    var handshakeStackScan = true
    /// The old eden and survivor-from are reused, and deferred entries
    /// freed, only after every participant's epoch passed the collection's.
    var epochRule = true
    /// Holders a collection keeps stay in its nursery's remembered set
    /// (off: forgotten after one collection).
    var carryHolders = true
    /// Offload: the owner's new-half objects allocated before its H1
    /// acknowledgement are scanned at T1.
    var newHalfScan = true
    /// A dead remembered holder's free belongs to its nursery (off: the
    /// initial mark's snapshot includes deferred entries and a pause frees
    /// them without telling their nursery, the experiment's bug).
    var deferredOwnership = true
    /// The wake from a quiescent wait stores epoch 0 before it loads the
    /// global epoch, as `enterVM` does (the model's finding 3).
    var quiescentWakeZero = true
    /// The array copy primitive's stores are seq_cst (off: relaxed, the
    /// remembered word loaded before the store is visible: the model's
    /// finding 1, with the store buffer replaced by a hook).
    var arrayCopyOrdering = true
    /// The initial mark scans every nursery's young bodies as roots (off:
    /// module 5's lost object comes back).
    var youngRoots = true
    var hook: YoungHook? = nil
    var hookContext: UnsafeMutableRawPointer? = nil

    init() {}
}
