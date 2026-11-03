// The model checks of docs/models/save-hold.md: both claims hold in every
// interleaving of the standard configurations, and each rule turned off
// lets the explorer find the claim it protects broken (its shortest trace
// is printed).

import Testing
@testable import SaveHoldModel

func check(_ name: String, _ c: Configuration) -> Report {
    let r = explore(c)
    print("\(name): \(r)")
    return r
}

@Suite struct TheSaveHoldClaimsHold {
    @Test func withTwoWorkersAndTwoProcesses() {
        let r = check("standard", .standard)
        #expect(r.violations.isEmpty && r.finishedRuns > 0)
    }

    @Test func withThreeWorkersAndThreeProcesses() {
        let r = check("three", .three)
        #expect(r.violations.isEmpty && r.finishedRuns > 0)
    }
}

@Suite struct EachSaveHoldRuleIsNeeded {
    /// Without the stop's check, a worker that dequeued before the hold
    /// (or past it) is caught mid-slice when dequeue ignores the hold.
    @Test func theCheckInTheStop() {
        var c = Configuration.standard
        c.checkInStop = false
        c.dequeueRespectsHold = false
        #expect(check("no check, dequeue ignores the hold", c).violations[.cleanSave] != nil)
    }

    /// Without the poll that puts a held Process back, the stop alone sees
    /// Processes mid-slice.
    @Test func thePollThatLeaves() {
        var c = Configuration.standard
        c.leaveAtPoll = false
        c.waitOutside = false
        c.checkInStop = false
        #expect(check("no leave at the poll", c).violations[.cleanSave] != nil)
    }

    /// Without the broadcast, a worker asleep while the scheduler was held
    /// never runs the Processes put back.
    @Test func theBroadcastOnRelease() {
        var c = Configuration.standard
        c.broadcastOnRelease = false
        #expect(check("no broadcast", c).violations[.everyoneFinishes] != nil)
    }
}
