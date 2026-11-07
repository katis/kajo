import Darwin

/// Concurrent marking's configuration (docs/modules/concurrent-marking.md).
/// Part of `VMConfig`; fixed once the VM exists. Needs a nursery: the
/// snapshot is taken at the end of a scavenge. Off, old space is collected
/// by module 1's stop-the-world mark-sweep only (the oracle).
struct MarkingConfig: Sendable {
    var enabled = true
    /// A cycle starts at the end of a scavenge when old space in use is at
    /// least this fraction of the soft limit (above 1: never by occupancy).
    var floor = 0.6
    /// ...or when the predicted time to fill the headroom (at the promotion
    /// rate of the last scavenges) is below this many times the last
    /// cycle's duration. 0: no prediction.
    var safetyFactor = 2.0
    /// The predictor is consulted only from this fraction of the soft limit
    /// on (a nearly empty old space is cheap to fill and to mark).
    static let predictorFrom = 0.2
    /// Scavenges the promotion rate is averaged over.
    static let rateWindow = 8
    /// Marking rate assumed before any cycle has finished (bytes per second
    /// of old space in use).
    static let assumedMarkBytesPerSecond = 1.0e9
    /// The marker runs at utility QoS and is raised to user-initiated while
    /// old-space headroom (free fraction of the soft limit) is below this.
    var escalateBelow = 0.25
    /// Large bytes, part 2: an old allocation that finds no room while a
    /// cycle marks waits this long at most for its final mark (a
    /// background worker; the main worker never waits). 0: no wait.
    var allocationWaitMs = 100
    /// The final mark on the devices (docs/modules/final-mark.md): the
    /// units of tracing work (an object traced, a large object's chunk as
    /// `MarkChunk.weight`, an SATB entry taken) a final mark may do inside
    /// its stop. Past it the stop gives up: the world is released with
    /// marking still on, the marker drains concurrently and requests the
    /// final mark again. Measured on the devices: the storm's final marks
    /// trace a few hundred units; 16 384 is about a millisecond on the
    /// iPhone's efficiency cores.
    var finalMarkWork = 16_384
    /// After this many give-ups in one cycle the final mark finishes past
    /// the bound (counted, `finalOverruns`): marking must end.
    var finalMarkGiveUps = 8
    /// The marker thread. Off: nothing marks unless a test drives it
    /// (`VM.markStep`, `finalMark`, `sweep`): the manual mode of the tests.
    var markerThread = true
    var stress: MarkingStress = []
    var testSwitches = MarkingTestSwitches()

    init() {}
}

/// Stress flags (docs/VERIFICATION.md layer 3).
struct MarkingStress: OptionSet, Sendable {
    let rawValue: UInt8
    /// A cycle starts at the end of every scavenge that finds none running.
    static let cycleAtEveryScavenge = MarkingStress(rawValue: 1)
    /// The flag word's marking bit is never cleared: every pointer store
    /// takes the barrier's slow path between cycles too.
    static let markingAlwaysOn = MarkingStress(rawValue: 2)
    /// A finished lazy sweep is never applied by a pause or by the sweeper
    /// (only a fallback's full collection publishes it): the fallback path.
    static let sweepNeverApplies = MarkingStress(rawValue: 4)

    init(rawValue: UInt8) { self.rawValue = rawValue }

    /// `cycle`, `alwayson`, `neverapply`, comma separated.
    init(parsing s: String) {
        var f: MarkingStress = []
        for part in s.split(separator: ",") {
            switch part {
            case "cycle": f.insert(.cycleAtEveryScavenge)
            case "alwayson": f.insert(.markingAlwaysOn)
            case "neverapply": f.insert(.sweepNeverApplies)
            default: break
            }
        }
        self = f
    }
}

/// Switches that turn a rule off so a test can show the rule matters.
/// Never set outside tests.
struct MarkingTestSwitches: Sendable {
    /// The SATB slow path returns at once.
    var satbOff = false
    /// The textbook protocol: the initial mark is a pause of its own without
    /// a scavenge, young objects (eden and survivors) exist at the snapshot
    /// and are not scanned, and the barrier does not skip young holders.
    var literal = false
    /// With `literal`: an object promoted while marking joins the snapshot
    /// marked and grey (the textbook's promotion rule).
    var literalGrey = true
    /// The initial mark does not scan the survivor spaces (ADR 0007's rule).
    var noSurvivorRoots = false
    /// The final mark leaves dead holders in the remembered set.
    var noRememberedFilter = false
    /// `at:` on a weak slot does not record its referent while marking.
    var noWeakKeepAlive = false
    /// Large bytes, part 2: the QoS policy as module 5 built it, decided at
    /// the initial mark only and on old space only (the entry table and
    /// the decisions while a cycle runs are off).
    var qosOnBlocksOnly = false
    /// Large bytes, part 2: an empty entry table during a sweep falls back
    /// to a full collection, as before (the sweep is not finished first).
    var noSweepForEntries = false
    /// The final mark on the devices: the final mark's stop does all its
    /// tracing whatever its length, as module 5 built it (the bound off).
    var unboundedFinalMark = false
    /// The initial mark scans every nursery's young bodies in its stop, as
    /// module 7 built it (no scan is left owed).
    var youngRootsInStop = false
    /// The SATB barrier skips every young holder, a nursery's scan owed or
    /// not (the barrier that catches what an owed scan has not read, off).
    var noOwedScanBarrier = false
    /// A young collection moves its nursery's objects without finishing the
    /// nursery's owed scan first.
    var collectBeforeRootScan = false
    /// The marker requests the final mark without scanning the owed
    /// nurseries (the work before the stop skipped).
    var markerSkipsRootScans = false
}
