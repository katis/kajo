/// Debug builds are checked builds: every verifier runs at every pause.
/// Release builds keep the verifiers one flag away (`verify`).
#if DEBUG
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
    /// A multiple of the block size, at most 4 GiB (the alias distance).
    var heapBytes = 64 << 20
    /// Entries reserved; the table never grows in module 1.
    var entryCapacity = 1 << 22
    /// Entries per refill of an allocation context.
    var entryChunk = 4096
    var stress: StressFlags = []
    var verify = checkedBuild
    var onVerifyFailure: VerifyFailurePolicy = checkedBuild ? .trap : .record

    init() {}

    /// The configuration after the stress flags are applied.
    var effective: ObjectMemoryConfig {
        var c = self
        if stress.contains(.oneBlockHeap) { c.heapBytes = BlockHeap.blockBytes }
        if stress.contains(.tinyEntryChunks) { c.entryChunk = 2 }
        return c
    }
}

enum ObjectMemoryError: Error, Equatable {
    case invalidConfig(String)
    case reservationFailed(String)
}
