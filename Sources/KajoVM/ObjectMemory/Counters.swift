/// Counters, not logs (docs/PLAN.md). Read with the world stopped or after
/// the allocating threads have joined; allocation counters are kept per
/// context and summed here.
struct Counters: Sendable, Equatable {
    var allocations: UInt64 = 0
    var allocatedBytes: UInt64 = 0
    /// Allocation attempts that found no block or no entry and asked for a
    /// collection.
    var allocationFailures: UInt64 = 0
    var entryRefills: UInt64 = 0
    var blockRefills: UInt64 = 0

    var collections: UInt64 = 0
    var compactions: UInt64 = 0
    var stressCollections: UInt64 = 0
    var entriesSwept: UInt64 = 0
    var blocksFreed: UInt64 = 0
    var objectsMoved: UInt64 = 0
    var bytesMoved: UInt64 = 0
    /// Live objects left in place because they were pinned, per compaction.
    var pinsHonoured: UInt64 = 0
    var becomes: UInt64 = 0
    var forwardedObjects: UInt64 = 0
    var referencesForwarded: UInt64 = 0
    var reshapedObjects: UInt64 = 0
    var snapshotsSaved: UInt64 = 0
    /// Weak slots set to nil because their referent was reclaimed (full
    /// collections; the scavenge counts its own).
    var weakSlotsNiled: UInt64 = 0
    /// Ephemerons queued for finalization (each at most once).
    var ephemeronsQueued: UInt64 = 0
    var verifierRuns: UInt64 = 0
    var verifierFailures: UInt64 = 0
}

/// Per-context allocation counters, in the context's own cache lines.
struct AllocationCounters {
    var allocations: UInt64 = 0
    var allocatedBytes: UInt64 = 0
    var allocationFailures: UInt64 = 0
    var entryRefills: UInt64 = 0
    var blockRefills: UInt64 = 0

    mutating func add(_ o: AllocationCounters) {
        allocations &+= o.allocations
        allocatedBytes &+= o.allocatedBytes
        allocationFailures &+= o.allocationFailures
        entryRefills &+= o.entryRefills
        blockRefills &+= o.blockRefills
    }
}
