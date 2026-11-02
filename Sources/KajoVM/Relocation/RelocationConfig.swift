/// Concurrent relocation's configuration (docs/modules/relocation.md). Part
/// of `VMConfig`; fixed once the VM exists. Needs concurrent marking: the
/// marker thread relocates between the final mark and the sweep, from the
/// live bytes per block the marker counted.
struct RelocationConfig: Sendable {
    var enabled = true
    /// A snapshot block is a candidate when its live bytes are below this
    /// fraction of a block (and above zero: an empty block is the sweep's).
    var threshold = 0.5
    /// Candidates are taken in block order until the bytes to move would
    /// exceed this fraction of the free blocks under the soft limit (the
    /// to-space must come from somewhere, and relocation must not cause a
    /// fallback).
    var cap = 0.5
    /// A relocation is planned at the initial mark (live bytes counted)
    /// unless the last completed cycle found old space at least this dense
    /// (marked bytes over the bytes of the blocks in use). The first cycle
    /// always plans.
    var planBelow = 0.75
    var stress: RelocationStress = []
    var testSwitches = RelocationTestSwitches()

    init() {}
}

/// Stress flags (docs/VERIFICATION.md layer 3).
struct RelocationStress: OptionSet, Sendable {
    let rawValue: UInt8
    /// Every snapshot block with a live object is selected, full ones
    /// included, in every cycle (the cap still applies).
    static let relocateEveryLiveBlock = RelocationStress(rawValue: 1)
    /// A relocation is planned in every cycle, whatever the density; with
    /// module 5's `cycleAtEveryScavenge`, relocation runs continuously.
    static let relocateAtEveryCycle = RelocationStress(rawValue: 2)

    init(rawValue: UInt8) { self.rawValue = rawValue }

    /// `everyblock`, `everycycle`, comma separated.
    init(parsing s: String) {
        var f: RelocationStress = []
        for part in s.split(separator: ",") {
            switch part {
            case "everyblock": f.insert(.relocateEveryLiveBlock)
            case "everycycle": f.insert(.relocateAtEveryCycle)
            default: break
            }
        }
        self = f
    }
}

/// Switches that turn a rule off so a test can show the rule matters.
/// Never set outside tests.
struct RelocationTestSwitches: Sendable {
    /// Pinned objects (for good, or by a frame) are skipped.
    var pinRule = true
    /// The relocator checks the hazard slots after its CAS.
    var hazardRule = true
    /// A pending block waits until every worker's epoch passed its switch.
    var epochRule = true
    /// `enterVM` stores epoch 0 (seq_cst) before it reads the epoch.
    var enterZero = true
    /// The marker thread never relocates; the test calls the pass itself
    /// (`VM.relocate`) or the step functions.
    var manualRelocation = false
}
