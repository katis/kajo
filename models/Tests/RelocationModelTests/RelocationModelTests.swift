// The model checks of docs/models/relocation.md. Each positive test explores
// every interleaving of one configuration and expects no claim to fail. Each
// negative test turns one rule off and expects the explorer to find the
// claim that rule protects broken; the shortest violating interleaving it
// finds is copied into the comment above the test.

import Testing
@testable import RelocationModel

/// Explore, print the report (state counts, longest trace, time, traces).
func check(_ name: String, _ config: Configuration) -> Report {
    let report = explore(config)
    print("\(name): \(report)")
    return report
}

/// Explore with one rule off and expect `claim` to fail; print its trace.
func expectViolation(_ name: String, _ config: Configuration, _ claim: Claim) {
    let report = check(name, config)
    let found = report.violations[claim]
    #expect(found != nil, "\(name): expected claim \(claim) to fail")
}

// MARK: - the five claims hold

@Suite struct TheClaimsHold {
    @Test func inTheStandardConfiguration() {
        let r = check("standard", .standard)
        #expect(r.violations.isEmpty)
        #expect(r.finishedRuns > 0)
    }

    @Test func withAThirdMutator() {
        let r = check("three mutators", .threeMutators)
        #expect(r.violations.isEmpty)
        #expect(r.finishedRuns > 0)
    }

    @Test func underContentionAndTwoPauses() {
        let r = check("contended", .contended)
        #expect(r.violations.isEmpty)
        #expect(r.finishedRuns > 0)
    }
}

// MARK: - each rule is needed

@Suite struct EachRuleIsNeeded {
    // Found by the explorer (shortest interleaving, breadth-first):
    //
    // claim 1 no lost store violated: M0 reads 0 from new(o0).s0 after its own completed store of 1
    //   1. M0 store o0.s0 := 1: e1 = offset[o0] (relaxed) -> old(o0)
    //   2. M0 store o0.s0 := 1: old(o0).s0 := 1 (seq_cst, buffered); no post-store check, done
    //   3. M0 poll: E (acquire) -> 0
    //   4. M0 poll: epoch[M0] := 0 (release, buffered)
    //   5. R poll: no pause
    //   6. R relocate o0: CAS offset[o0] old(o0) -> old(o0)+R (seq_cst), fence (seq_cst)
    //   7. R relocate o0: hz[M0] (seq_cst) -> none
    //   8. R relocate o0: hz[M1] (seq_cst) -> none
    //   9. R relocate o0: copy old(o0).s0 (relaxed) -> 0, new(o0).s0 := 0 (relaxed, buffered)
    //   10. R relocate o0: switch offset[o0] := new(o0) (release, buffered)
    //   11. M0 drain: old(o0).s0 = 1 (seq_cst store becomes visible)
    //   12. M0 drain: epoch[M0] = 0 (release store becomes visible)
    //   13. M0 poll: no pause requested
    //   14. R drain: new(o0).s0 = 0 (relaxed store becomes visible)
    //   15. R drain: offset[o0] = new(o0) (release store becomes visible)
    //   16. M0 read o0.s0: e = offset[o0] (relaxed) -> new(o0)
    //   17. M0 read o0.s0: new(o0).s0 (relaxed) -> 0
    @Test func withoutThePostStoreCheckAStoreIsLost() {
        var c = Configuration.standard
        c.postStoreCheck = false
        expectViolation("postStoreCheck off", c, .noLostStore)
    }

    // Found by the explorer (shortest interleaving, breadth-first):
    //
    // claim 3 no hazarded move violated: R switches o1 while M1 holds it under its hazard slot
    //   1. M1 hazard o1.s0 := 2: hz[M1] := o1 (seq_cst, buffered)
    //   2. R poll: no pause
    //   3. R relocate o0: CAS offset[o0] old(o0) -> old(o0)+R (seq_cst), fence (seq_cst)
    //   4. R relocate o0: copy old(o0).s0 (relaxed) -> 0, new(o0).s0 := 0 (relaxed, buffered)
    //   5. R relocate o0: switch offset[o0] := new(o0) (release, buffered)
    //   6. M1 drain: hz[M1] = 2 (seq_cst store becomes visible)
    //   7. M1 hazard o1.s0 := 2: e = offset[o1] (seq_cst) -> old(o1): body pointer p taken
    //   8. R drain: new(o0).s0 = 0 (relaxed store becomes visible)
    //   9. R drain: offset[o0] = new(o0) (release store becomes visible)
    //   10. R poll: no pause
    //   11. R relocate o1: CAS offset[o1] old(o1) -> old(o1)+R (seq_cst), fence (seq_cst)
    //   12. R relocate o1: copy old(o1).s0 (relaxed) -> 0, new(o1).s0 := 0 (relaxed, buffered)
    //   13. R relocate o1: switch offset[o1] := new(o1) (release, buffered)
    //
    // Also broken in this configuration: claim 1.
    @Test func withoutTheHazardCheckAHazardedObjectIsMoved() {
        var c = Configuration.standard
        c.hazardCheck = false
        expectViolation("hazardCheck off", c, .noHazardedMove)
    }

    // Found by the explorer (shortest interleaving, breadth-first):
    //
    // claim 4 no premature free violated: R frees the block while M0 holds a body pointer into it
    //   1. M0 store o0.s0 := 1: e1 = offset[o0] (relaxed) -> old(o0)
    //   2. R poll: no pause
    //   3. R relocate o0: CAS offset[o0] old(o0) -> old(o0)+R (seq_cst), fence (seq_cst)
    //   4. R relocate o0: hz[M0] (seq_cst) -> none
    //   5. R relocate o0: hz[M1] (seq_cst) -> none
    //   6. R relocate o0: copy old(o0).s0 (relaxed) -> 0, new(o0).s0 := 0 (relaxed, buffered)
    //   7. R relocate o0: switch offset[o0] := new(o0) (release, buffered)
    //   8. R drain: new(o0).s0 = 0 (relaxed store becomes visible)
    //   9. R drain: offset[o0] = new(o0) (release store becomes visible)
    //   10. R poll: no pause
    //   11. R relocate o1: CAS offset[o1] old(o1) -> old(o1)+R (seq_cst), fence (seq_cst)
    //   12. R relocate o1: hz[M0] (seq_cst) -> none
    //   13. R relocate o1: hz[M1] (seq_cst) -> none
    //   14. R relocate o1: copy old(o1).s0 (relaxed) -> 0, new(o1).s0 := 0 (relaxed, buffered)
    //   15. R relocate o1: switch offset[o1] := new(o1) (release, buffered)
    //   16. R drain: new(o1).s0 = 0 (relaxed store becomes visible)
    //   17. R drain: offset[o1] = new(o1) (release store becomes visible)
    //   18. R addPending: block pending with s = 0, E := 1 (seq_cst fetch_add)
    //   19. R tryFreePending: no epoch rule: frees the block
    @Test func withoutTheEpochRuleABlockIsFreedUnderABodyPointer() {
        var c = Configuration.standard
        c.epochRule = false
        expectViolation("epochRule off", c, .noPrematureFree)
    }

    // Found by the explorer (shortest interleaving, breadth-first):
    //
    // claim 1 no lost store violated: M0 reads 0 from new(o0).s0 after its own completed store of 1
    //   1. M0 store o0.s0 := 1: e1 = offset[o0] (relaxed) -> old(o0)
    //   2. M0 store o0.s0 := 1: old(o0).s0 := 1 (release, buffered)
    //   3. M0 store o0.s0 := 1: e2 = offset[o0] (acquire) -> old(o0), unchanged: done
    //   4. M0 poll: E (acquire) -> 0
    //   5. M0 poll: epoch[M0] := 0 (release, buffered)
    //   6. R poll: no pause
    //   7. R relocate o0: CAS offset[o0] old(o0) -> old(o0)+R (seq_cst), fence (seq_cst)
    //   8. R relocate o0: hz[M0] (seq_cst) -> none
    //   9. R relocate o0: hz[M1] (seq_cst) -> none
    //   10. R relocate o0: copy old(o0).s0 (relaxed) -> 0, new(o0).s0 := 0 (relaxed, buffered)
    //   11. R relocate o0: switch offset[o0] := new(o0) (release, buffered)
    //   12. M0 drain: old(o0).s0 = 1 (release store becomes visible)
    //   13. M0 drain: epoch[M0] = 0 (release store becomes visible)
    //   14. M0 poll: no pause requested
    //   15. R drain: new(o0).s0 = 0 (relaxed store becomes visible)
    //   16. R drain: offset[o0] = new(o0) (release store becomes visible)
    //   17. M0 read o0.s0: e = offset[o0] (relaxed) -> new(o0)
    //   18. M0 read o0.s0: new(o0).s0 (relaxed) -> 0
    @Test func withReleaseAcquireInThePostStoreCheckAStoreIsLost() {
        var c = Configuration.standard
        c.seqCstStoreReload = false
        expectViolation("seqCstStoreReload off", c, .noLostStore)
    }
}

// MARK: - probes beyond the brief's four switches

/// Rules the brief does not name as switches but that the model shows are
/// load-bearing, and negative evidence for claims 2 and 5.
@Suite struct Probes {
    // Found by the explorer (shortest interleaving, breadth-first):
    //
    // claim 4 no premature free violated: R frees the block while M1 holds a body pointer into it
    //   1. M0 store o0.s0 := 1: e1 = offset[o0] (relaxed) -> old(o0)
    //   2. M0 store o0.s0 := 1: old(o0).s0 := 1 (seq_cst, buffered)
    //   3. M1 hazard o1.s0 := 2: hz[M1] := o1 (seq_cst, buffered)
    //   4. R poll: no pause
    //   5. M0 drain: old(o0).s0 = 1 (seq_cst store becomes visible)
    //   6. M0 store o0.s0 := 1: e2 = offset[o0] (seq_cst) -> old(o0), unchanged: done
    //   7. R relocate o0: CAS offset[o0] old(o0) -> old(o0)+R (seq_cst), fence (seq_cst)
    //   8. R relocate o0: hz[M0] (seq_cst) -> none
    //   9. R relocate o0: hz[M1] (seq_cst) -> none
    //   10. R relocate o0: copy old(o0).s0 (relaxed) -> 1, new(o0).s0 := 1 (relaxed, buffered)
    //   11. R relocate o0: switch offset[o0] := new(o0) (release, buffered)
    //   12. M1 drain: hz[M1] = 2 (seq_cst store becomes visible)
    //   13. M1 hazard o1.s0 := 2: e = offset[o1] (seq_cst) -> old(o1): body pointer p taken
    //   14. M1 hazard o1.s0 := 2: old(o1).s0 := 2 through p (relaxed, buffered)
    //   15. M1 hazard o1.s0 := 2: old(o1).s0 through p (relaxed) -> 2
    //   16. M1 hazard o1.s0 := 2: hz[M1] := 0 (release, buffered): hazard released
    //   17. M1 leaveVM: epoch[M1] := quiescent (release, buffered)
    //   18. M1 drain: old(o1).s0 = 2 (relaxed store becomes visible)
    //   19. M1 drain: hz[M1] = 0 (release store becomes visible)
    //   20. M1 drain: epoch[M1] = quiescent (release store becomes visible)
    //   21. M1 leaveVM: leaves the VM
    //   22. M1 enterVM: enters the VM
    //   23. M1 enterVM: E (seq_cst) -> 0
    //   24. M1 enterVM: epoch[M1] := 0 (release, buffered)
    //   25. M1 read o1.s0: e = offset[o1] (relaxed) -> old(o1)
    //   26. R drain: new(o0).s0 = 1 (relaxed store becomes visible)
    //   27. R drain: offset[o0] = new(o0) (release store becomes visible)
    //   28. R poll: no pause
    //   29. R relocate o1: CAS offset[o1] old(o1) -> old(o1)+R (seq_cst), fence (seq_cst)
    //   30. R relocate o1: hz[M0] (seq_cst) -> none
    //   31. R relocate o1: hz[M1] (seq_cst) -> none
    //   32. R relocate o1: copy old(o1).s0 (relaxed) -> 2, new(o1).s0 := 2 (relaxed, buffered)
    //   33. R relocate o1: switch offset[o1] := new(o1) (release, buffered)
    //   34. R drain: new(o1).s0 = 2 (relaxed store becomes visible)
    //   35. R drain: offset[o1] = new(o1) (release store becomes visible)
    //   36. R addPending: block pending with s = 0, E := 1 (seq_cst fetch_add)
    //   37. M0 poll: E (acquire) -> 1
    //   38. M0 poll: epoch[M0] := 1 (release, buffered)
    //   39. M0 drain: epoch[M0] = 1 (release store becomes visible)
    //   40. R tryFreePending: epoch[M0] (acquire) -> 1
    //   41. R tryFreePending: epoch[M1] (acquire) -> quiescent
    //   42. R tryFreePending: every epoch word > 0: frees the block
    @Test func withoutTheZeroBeforeTheEpochAnEnteringWorkerIsMissed() {
        var c = Configuration.standard
        c.enterPublishesZeroFirst = false
        expectViolation("enterPublishesZeroFirst off", c, .noPrematureFree)
    }

    // Found by the explorer (shortest interleaving, breadth-first):
    //
    // claim 2 no stale read violated: M0 reads uninitialised to-space at new(o0).s0
    //   1. M0 store o0.s0 := 1: e1 = offset[o0] (relaxed) -> old(o0)
    //   2. M0 store o0.s0 := 1: old(o0).s0 := 1 (seq_cst, buffered)
    //   3. R poll: no pause
    //   4. M0 drain: old(o0).s0 = 1 (seq_cst store becomes visible)
    //   5. M0 store o0.s0 := 1: e2 = offset[o0] (seq_cst) -> old(o0), unchanged: done
    //   6. M0 poll: E (acquire) -> 0
    //   7. M0 poll: epoch[M0] := 0 (release, buffered)
    //   8. R relocate o0: CAS offset[o0] old(o0) -> old(o0)+R (seq_cst), fence (seq_cst)
    //   9. R relocate o0: hz[M0] (seq_cst) -> none
    //   10. R relocate o0: hz[M1] (seq_cst) -> none
    //   11. R relocate o0: copy old(o0).s0 (relaxed) -> 1, new(o0).s0 := 1 (relaxed, buffered)
    //   12. R relocate o0: switch offset[o0] := new(o0) (relaxed, buffered)
    //   13. M0 drain: epoch[M0] = 0 (release store becomes visible)
    //   14. M0 poll: no pause requested
    //   15. R drain: offset[o0] = new(o0) (relaxed store becomes visible)
    //   16. M0 read o0.s0: e = offset[o0] (relaxed) -> new(o0)
    //   17. M0 read o0.s0: new(o0).s0 (relaxed) -> uninit
    //
    // Also broken in this configuration: claim 1.
    @Test func withARelaxedSwitchAReadSeesUninitialisedToSpace() {
        var c = Configuration.standard
        c.switchOrder = .relaxed
        expectViolation("switchOrder relaxed", c, .noStaleRead)
    }

    // Found by the explorer (shortest interleaving, breadth-first):
    //
    // claim 5 no RELOCATING at a pause violated: o0 is RELOCATING with the world stopped
    //   1. M0 store o0.s0 := 1: e1 = offset[o0] (relaxed) -> old(o0)
    //   2. M0 store o0.s0 := 1: old(o0).s0 := 1 (seq_cst, buffered)
    //   3. M1 hazard o1.s0 := 2: hz[M1] := o1 (seq_cst, buffered)
    //   4. R poll: no pause
    //   5. S requests a pause (gcRequested)
    //   6. M0 drain: old(o0).s0 = 1 (seq_cst store becomes visible)
    //   7. M0 store o0.s0 := 1: e2 = offset[o0] (seq_cst) -> old(o0), unchanged: done
    //   8. M0 poll: E (acquire) -> 0
    //   9. M0 poll: epoch[M0] := 0 (release, buffered)
    //   10. R relocate o0: CAS offset[o0] old(o0) -> old(o0)+R (seq_cst), fence (seq_cst)
    //   11. R poll: pause requested: parks
    //   12. M0 drain: epoch[M0] = 0 (release store becomes visible)
    //   13. M0 poll: pause requested: parks
    //   14. M1 drain: hz[M1] = 2 (seq_cst store becomes visible)
    //   15. M1 hazard o1.s0 := 2: e = offset[o1] (seq_cst) -> old(o1): body pointer p taken
    //   16. M1 hazard o1.s0 := 2: old(o1).s0 := 2 through p (relaxed, buffered)
    //   17. M1 hazard o1.s0 := 2: old(o1).s0 through p (relaxed) -> 2
    //   18. M1 hazard o1.s0 := 2: hz[M1] := 0 (release, buffered): hazard released
    //   19. M1 leaveVM: epoch[M1] := quiescent (release, buffered)
    //   20. M1 drain: old(o1).s0 = 2 (relaxed store becomes visible)
    //   21. M1 drain: hz[M1] = 0 (release store becomes visible)
    //   22. M1 drain: epoch[M1] = quiescent (release store becomes visible)
    //   23. M1 leaveVM: leaves the VM
    //   24. S world stopped; releases it
    //
    // Also broken in this configuration: no deadlock.
    @Test func pollingWhileRelocatingStopsTheWorldWithAnEntryRelocating() {
        var c = Configuration.standard
        c.relocatorPollsOnlyBetweenObjects = false
        expectViolation("relocatorPollsOnlyBetweenObjects off", c, .noRelocatingAtPause)
        #expect(explore(c).violations[.noDeadlock] != nil)
    }
}
