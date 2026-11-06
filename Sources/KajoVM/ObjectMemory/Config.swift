/// Debug builds are checked builds: every verifier runs at every pause.
/// Release builds keep the verifiers one flag away (`verify`). Module 11a:
/// an app's Debug build (the KajoAppBuild trait its pinned dependency
/// enables, Package.swift) is not a checked build; Xcode compiles every
/// package with DEBUG in its Debug configuration whatever the app asks.
#if DEBUG && !KajoAppBuild
let checkedBuild = true
#else
let checkedBuild = false
#endif

/// Flags that make the collector run far more often than it would
/// (docs/VERIFICATION.md, layer 3).
struct StressFlags: OptionSet, Sendable {
    let rawValue: UInt8
    /// `allocate` runs a full collection before every allocation.
    static let collectAtEveryAllocation = StressFlags(rawValue: 1)
    /// The heap is a single block.
    static let oneBlockHeap = StressFlags(rawValue: 2)
    /// Entry chunks of two entries: every other allocation refills.
    static let tinyEntryChunks = StressFlags(rawValue: 4)

    static let all: StressFlags = [.collectAtEveryAllocation, .oneBlockHeap, .tinyEntryChunks]

    /// `KAJO_STRESS`, a comma-separated list of `every`, `oneblock`, `tiny`
    /// or `all`.
    init(parsing s: String) {
        var f: StressFlags = []
        for part in s.split(separator: ",") {
            switch part {
            case "every": f.insert(.collectAtEveryAllocation)
            case "oneblock": f.insert(.oneBlockHeap)
            case "tiny": f.insert(.tinyEntryChunks)
            case "all": f.formUnion(.all)
            default: break
            }
        }
        self = f
    }

    init(rawValue: UInt8) { self.rawValue = rawValue }
}

enum VerifyFailurePolicy: Sendable {
    /// Stop the VM with the report (checked builds).
    case trap
    /// Count the failure and keep the report (tests; release builds record
    /// and module 5 onward falls back to stop-the-world).
    case record
}

struct ObjectMemoryConfig: Sendable {
    /// Old space's soft size: a multiple of the block size. Mutators may
    /// fill this much; the blocks of `reserveBytes` beyond it are for
    /// promotion only (module 4), so a scavenge never fails for lack of
    /// space. Blocks, reserve and nurseries together fit in 4 GiB.
    var heapBytes = 64 << 20
    /// The promotion reserve: blocks after the soft limit that only a
    /// scavenge's promotion may take (module 4 sizes it from the nurseries,
    /// `NurseryConfig.reserveBytes`). A multiple of the block size.
    var reserveBytes = 0
    /// Module 7: bytes mapped twice after the blocks for the nursery region
    /// (`NurseryConfig.regionBytes`), so a young body can be RELOCATING
    /// while a young collector copies it. 0: the nurseries go into plain
    /// memory beyond the blocks, and only stop-the-world scavenges collect
    /// them. A multiple of the block size.
    var nurseryRegionBytes = 0
    /// Module 10 (vm-teardown's first follow-up): blocks after the promotion
    /// reserve that only the VM's final collection may take, so the
    /// promote-all at the VM's end grows old space instead of trapping when
    /// the soft limit and the reserve are full. nil: as large as the
    /// promotion reserve (which `NurseryConfig.reserveBytes` sizes to twice
    /// what the nurseries hold). Address space only until used; clamped so
    /// the reservation stays within 4 GiB. A multiple of the block size.
    var endGrowthBytes: Int? = nil
    /// Entries reserved; the table never grows in module 1.
    var entryCapacity = 1 << 22
    /// Entries per refill of an allocation context.
    var entryChunk = 4096
    var stress: StressFlags = []
    var verify = checkedBuild
    var onVerifyFailure: VerifyFailurePolicy = checkedBuild ? .trap : .record
    var testSwitches = TestSwitches()
    /// Tests: every address-space reservation the object memory makes or
    /// releases is recorded here, and one may be made to fail (the
    /// collectors review, finding 6: a partial failure of `init` leaked
    /// the reservations before it).
    var reservations: ReservationProbe? = nil

    init() {}

    /// The configuration after the stress flags are applied.
    var effective: ObjectMemoryConfig {
        var c = self
        if stress.contains(.oneBlockHeap) { c.heapBytes = BlockHeap.blockBytes; c.reserveBytes = 0; c.endGrowthBytes = 0 }
        if stress.contains(.tinyEntryChunks) { c.entryChunk = 2 }
        return c
    }
}

enum ObjectMemoryError: Error, Equatable {
    case invalidConfig(String)
    case reservationFailed(String)
}

/// Switches that turn a rule off so a test can show the rule matters. Never
/// set outside tests.
struct TestSwitches: Sendable {
    /// Compaction moves pinned bodies.
    var ignorePins = false
    // Module 8: each turns one object-model rule off, out of line only,
    // so the suite shows the rule's test failing without it.
    /// A non-local return cuts straight to its home, past unwind marks.
    var skipUnwindMarks = false
    /// `send_super` looks up from the receiver's class's superclass, not
    /// the method class's.
    var superFromReceiverClass = false
    /// LargeInteger results are not normalized to SmallIntegers.
    var noNormalization = false
    /// The UTF-8 boundary check accepts any offset in range.
    var noBoundaryCheck = false
    /// The frame-pin walk skips the frame's Context word.
    var pinWalkSkipsContext = false
    /// Module 10: one reader of a body treats a run of blocks as ordinary
    /// blocks, as module 1 did, so its test shows the run rule matters.
    var runBlind: RunReader? = nil
}

/// Module 10: the readers of a body that know runs, each with a broken
/// variant (`TestSwitches.runBlind`).
enum RunReader: Sendable, Equatable {
    /// The eager sweep frees a run's continuations with no live body.
    case sweep
    /// The lazy sweep's apply does the same.
    case lazySweep
    /// Compaction treats a live run's blocks as sources and destinations.
    case compaction
    /// The heap verifier walks a head only to one block and accepts an
    /// entry into a continuation.
    case verifier
    /// The block pool's rebuild offers run blocks to allocators.
    case pool
    /// The relocator may select a run's head.
    case relocation
    /// The snapshot writer drops the side table (every block ordinary).
    case snapshot
}
