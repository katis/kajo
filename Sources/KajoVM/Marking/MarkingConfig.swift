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
}
