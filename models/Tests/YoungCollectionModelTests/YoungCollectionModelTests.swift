// The model checks of docs/models/young-collection.md. Each positive test
// explores every interleaving of one configuration and expects no claim to
// fail. Each negative test turns one rule off and expects the explorer to
// find the claim that rule protects broken; the shortest violating
// interleaving it finds is copied into the comment above the test.

import Testing
@testable import YoungCollectionModel

/// Explore, print the report (state counts, longest trace, time, traces).
func check(_ name: String, _ config: Configuration) -> Report {
    let report = explore(config)
    print("\(name): \(report)")
    return report
}

/// Explore with one rule off and expect `claim` to fail (with `message`, if
/// given); print the trace.
@discardableResult
func expectViolation(_ name: String, _ config: Configuration, _ claim: Claim, message: String? = nil) -> Report {
    let report = check(name, config)
    if let m = message {
        let t = report.violationsByMessage[m]
        #expect(t?.claim == claim, "\(name): expected \"\(m)\"")
        if let t { print("\(name) [\(m)]:\n\(t)") }
    } else {
        #expect(report.violations[claim] != nil, "\(name): expected claim \(claim) to fail")
    }
    return report
}

func holds(_ r: Report) {
    #expect(r.violations.isEmpty)
    #expect(r.finishedRuns > 0)
}

// MARK: - the claims hold

@Suite struct TheClaimsHold {
    /// Claims 1 to 3 in local collection, with store buffers.
    @Test func inLocalCollection() { holds(check("local", .local)) }

    /// The same, sequentially consistent.
    @Test func inLocalCollectionUnderSequentialConsistency() {
        var c = Configuration.local
        c.sequentiallyConsistent = true
        holds(check("local, sequentially consistent", c))
    }

    /// Claim 3: a record that only the second drain round publishes.
    @Test func withAChainCutAcrossDrainRounds() { holds(check("chain", .chain)) }

    /// Claim 6 with the interpreter's store.
    @Test func whenAStoreRacesTheRememberedSetScan() { holds(check("remembered", .remembered())) }

    /// Claim 7, a barriered store into the new-half object.
    @Test func whenTheOwnerAllocatesDuringItsCollection() { holds(check("new half", .newHalf())) }

    /// Claim 7, the allocation's own initialising store.
    @Test func whenTheOwnerInitialisesANewHalfObject() {
        holds(check("new half, initialising store", .newHalf(initialising: true)))
    }

    /// Claim 4: body pointers, a blocking region, leave and enter, a
    /// quiescent waiter.
    @Test func forEdenReuse() { holds(check("epochs", .epochs)) }

    /// Claim 5 against a snapshot and a lazy sweep. Witness states are runs
    /// in which the deferred entry was kept across the pause, freed by its
    /// nursery and reused: the rule's case happened, and nothing broke.
    @Test func forDeferredEntriesAgainstASnapshot() {
        let r = check("ownership, snapshot and sweep", .ownership([.snapshot, .sweep]))
        holds(r)
        #expect(r.witnesses > 0)
    }

    /// Claim 5 against a full stop-the-world collection.
    @Test func forDeferredEntriesAgainstAFullCollection() {
        let r = check("ownership, full collection", .ownership([.fullCollection]))
        holds(r)
        #expect(r.witnesses > 0)
    }
}

// MARK: - each rule is needed

@Suite struct EachRuleIsNeeded {
    // Found by the explorer (shortest interleaving, breadth-first), "single round, sequentially consistent":
    //
    // claim 1 no lost object violated: W collect frees X, which a worker can still reach
    //   1. B poll: E (acquire) -> 0, epoch[B] := 0 (release)
    //   2. B poll: E (acquire) -> 0, epoch[B] := 0 (release)
    //   3. B store G.s0 := nil: barrierWord (relaxed) -> 0
    //   4. W collect: opens nursery 0's collection (collecting[0] := 1, barrierWord += 1, Y = {X})
    //   5. W collect [0] opens H1 (round 1, need 3)
    //   6. W collect [0] acknowledges H1 of nursery 0: stack scan finds {}; E (acquire) -> 0, epoch[W] := 0 (release)
    //   7. A poll: acknowledges H1 of nursery 0: stack scan finds {}
    //   8. A poll: E (acquire) -> 0, epoch[A] := 0 (release)
    //   9. A r0 := G.s0: G.s0 (relaxed) -> X
    //   10. B store G.s0 := nil: G.s0 := nil (seq_cst)
    //   11. B store G.s0 := nil: post-store check: offset[G] (seq_cst) unchanged
    //   12. B store G.s0 := nil: no insertion barrier (nil not young in another nursery than G)
    //   13. B poll: acknowledges H1 of nursery 0: stack scan finds {}
    //   14. W collect [0] H1 complete; T1, carried {G}
    //   15. W collect [0] new half scanned
    //   16. W collect [0] scanHolder G: fetch_and rem (seq_cst) -> was member 0, fence
    //   17. W collect [0] scanHolder G: header (relaxed) -> 1 slot
    //   18. W collect [0] scanHolder G: s0 (relaxed) -> nil
    //   19. W collect [0] scanHolder G: names nothing in nursery 0: not kept
    //   20. W collect [0] carried holders scanned
    //   21. W collect [0] takes handed: roots {}, rem {}, del {}
    //   22. W collect [0] stack roots visited
    //   23. W collect [0] remembered holders scanned
    //   24. W collect [0] deletion records visited
    //   25. W collect [0] gray stack empty
    //   26. W collect [0] T1 done: another drain round
    //   27. W collect [0] opens drain (round 2, need 3)
    //   28. W collect [0] acknowledges drain of nursery 0; E (acquire) -> 0, epoch[W] := 0 (release)
    //   29. A poll: acknowledges drain of nursery 0
    //   30. B poll: acknowledges drain of nursery 0
    //   31. W collect [0] drain round complete
    //   32. W collect [0] takes handed: roots {}, rem {}, del {}
    //   33. W collect [0] stack roots visited
    //   34. W collect [0] remembered holders scanned
    //   35. W collect [0] deletion records visited
    //   36. W collect [0] gray stack empty
    //   37. W collect [0] stops marking: the round copied nothing
    //   38. W collect [0] finish: collecting[0] := 0, barrierWord -= 1 (under the mutex)
    //   39. W collect [0] carried set folded
    //   40. W collect [0] sweep: X dead: entry freed
    @Test func claim2WithoutTheBarrierOnRoundAnObjectIsLostUnderSequentialConsistency() {
        var c = Configuration.local
        c.barrierOnRound = false
        c.sequentiallyConsistent = true
        c.terminationCheck = false
        expectViolation("single round, sequentially consistent", c, .noLostObject)
    }

    // Found by the explorer (shortest interleaving, breadth-first), "no drain rounds":
    //
    // claim 3 termination is sound violated: W collect stops marking (no drain rounds) with X reachable and unmarked
    //   1. W collect: opens nursery 0's collection (collecting[0] := 1, barrierWord += 1, Y = {X})
    //   2. W collect [0] opens H0 (round 1, need 3)
    //   3. W collect [0] acknowledges H0 of nursery 0; E (acquire) -> 0, epoch[W] := 0 (release)
    //   4. A poll: acknowledges H0 of nursery 0
    //   5. B poll: acknowledges H0 of nursery 0
    //   6. W collect [0] H0 complete
    //   7. B poll: E (acquire) -> 0, epoch[B] := 0 (release)
    //   8. W drain: epoch[W] = 0 (release store becomes visible)
    //   9. W collect [0] opens H1 (round 2, need 3)
    //   10. W collect [0] acknowledges H1 of nursery 0: stack scan finds {}; E (acquire) -> 0, epoch[W] := 0 (release)
    //   11. A poll: acknowledges H1 of nursery 0: stack scan finds {}
    //   12. A poll: E (acquire) -> 0, epoch[A] := 0 (release)
    //   13. A r0 := G.s0: G.s0 (relaxed) -> X
    //   14. W drain: epoch[W] = 0 (release store becomes visible)
    //   15. B drain: epoch[B] = 0 (release store becomes visible)
    //   16. B poll: acknowledges H1 of nursery 0: stack scan finds {}
    //   17. W collect [0] H1 complete; T1, carried {G}
    //   18. W collect [0] new half scanned
    //   19. W collect [0] scanHolder G: fetch_and rem (seq_cst) -> was member 0, fence
    //   20. W collect [0] scanHolder G: header (relaxed) -> 1 slot
    //   21. B poll: E (acquire) -> 0, epoch[B] := 0 (release)
    //   22. B store G.s0 := nil: barrierWord (relaxed) -> 1: barriers on
    //   23. B store G.s0 := nil: old G.s0 (relaxed) -> X, collecting[0] (acquire) -> 1: del[0] += X
    //   24. B store G.s0 := nil: G.s0 := nil (seq_cst)
    //   25. B drain: epoch[B] = 0 (release store becomes visible)
    //   26. B drain: G.s0 = nil (seq_cst store becomes visible)
    //   27. W collect [0] scanHolder G: s0 (relaxed) -> nil
    //   28. W collect [0] scanHolder G: names nothing in nursery 0: not kept
    //   29. W collect [0] carried holders scanned
    //   30. W collect [0] takes handed: roots {}, rem {}, del {}
    //   31. W collect [0] stack roots visited
    //   32. W collect [0] remembered holders scanned
    //   33. W collect [0] deletion records visited
    //   34. W collect [0] gray stack empty
    //   35. W collect [0] stops marking: no drain rounds
    @Test func claim3WithoutDrainRoundsMarkingStopsEarly() {
        var c = Configuration.local
        c.termination = .afterT1
        expectViolation("no drain rounds", c, .soundTermination)
    }

    // Found by the explorer (shortest interleaving, breadth-first), "one drain round":
    //
    // claim 3 termination is sound violated: W collect stops marking (one drain round done) with Z reachable and unmarked
    //   1. W collect: opens nursery 0's collection (collecting[0] := 1, barrierWord += 1, Y = {X, Z})
    //   2. W collect [0] opens H0 (round 1, need 3)
    //   3. W collect [0] acknowledges H0 of nursery 0; E (acquire) -> 0, epoch[W] := 0 (release)
    //   4. A poll: acknowledges H0 of nursery 0
    //   5. A poll: E (acquire) -> 0, epoch[A] := 0 (release)
    //   6. B poll: acknowledges H0 of nursery 0
    //   7. W collect [0] H0 complete
    //   8. B poll: E (acquire) -> 0, epoch[B] := 0 (release)
    //   9. W drain: epoch[W] = 0 (release store becomes visible)
    //   10. W collect [0] opens H1 (round 2, need 3)
    //   11. W collect [0] acknowledges H1 of nursery 0: stack scan finds {}; E (acquire) -> 0, epoch[W] := 0 (release)
    //   12. W drain: epoch[W] = 0 (release store becomes visible)
    //   13. A drain: epoch[A] = 0 (release store becomes visible)
    //   14. A poll: acknowledges H1 of nursery 0: stack scan finds {}
    //   15. A poll: E (acquire) -> 0, epoch[A] := 0 (release)
    //   16. A r0 := G.s0: G.s0 (relaxed) -> X
    //   17. A r1 := r0.s0: X.s0 (relaxed) -> Z
    //   18. A drain: epoch[A] = 0 (release store becomes visible)
    //   19. B drain: epoch[B] = 0 (release store becomes visible)
    //   20. B poll: acknowledges H1 of nursery 0: stack scan finds {}
    //   21. W collect [0] H1 complete; T1, carried {G}
    //   22. W collect [0] new half scanned
    //   23. W collect [0] scanHolder G: fetch_and rem (seq_cst) -> was member 0, fence
    //   24. W collect [0] scanHolder G: header (relaxed) -> 1 slot
    //   25. B poll: E (acquire) -> 0, epoch[B] := 0 (release)
    //   26. B r0 := G.s0: G.s0 (relaxed) -> X
    //   27. B store G.s0 := nil: barrierWord (relaxed) -> 1: barriers on
    //   28. B store G.s0 := nil: old G.s0 (relaxed) -> X, collecting[0] (acquire) -> 1: del[0] += X
    //   29. B store G.s0 := nil: G.s0 := nil (seq_cst)
    //   30. B drain: epoch[B] = 0 (release store becomes visible)
    //   31. B drain: G.s0 = nil (seq_cst store becomes visible)
    //   32. W collect [0] scanHolder G: s0 (relaxed) -> nil
    //   33. W collect [0] scanHolder G: names nothing in nursery 0: not kept
    //   34. W collect [0] carried holders scanned
    //   35. W collect [0] takes handed: roots {}, rem {}, del {}
    //   36. W collect [0] stack roots visited
    //   37. W collect [0] remembered holders scanned
    //   38. W collect [0] deletion records visited
    //   39. W collect [0] gray stack empty
    //   40. W collect [0] T1 done: another drain round
    //   41. W collect [0] opens drain (round 3, need 3)
    //   42. W collect [0] acknowledges drain of nursery 0; E (acquire) -> 0, epoch[W] := 0 (release)
    //   43. A poll: acknowledges drain of nursery 0
    //   44. B store G.s0 := nil: post-store check: offset[G] (seq_cst) unchanged
    //   45. B store G.s0 := nil: no insertion barrier (nil not young in another nursery than G)
    //   46. B poll: acknowledges drain of nursery 0: publishes del {X}
    //   47. W collect [0] drain round complete
    //   48. B poll: E (acquire) -> 0, epoch[B] := 0 (release)
    //   49. B store r0.s0 := nil: barrierWord (relaxed) -> 1: barriers on
    //   50. B store r0.s0 := nil: old X.s0 (relaxed) -> Z, collecting[0] (acquire) -> 1: del[0] += Z
    //   51. B store r0.s0 := nil: X.s0 := nil (seq_cst)
    //   52. W drain: epoch[W] = 0 (release store becomes visible)
    //   53. W collect [0] takes handed: roots {}, rem {}, del {X}
    //   54. W collect [0] stack roots visited
    //   55. W collect [0] remembered holders scanned
    //   56. W collect [0] visits deletion record X, copies X
    //   57. W collect [0] deletion records visited
    //   58. B drain: epoch[B] = 0 (release store becomes visible)
    //   59. B drain: X.s0 = nil (seq_cst store becomes visible)
    //   60. W collect [0] drain: X.s0 (relaxed) -> nil
    //   61. W collect [0] drain: X scanned
    //   62. W collect [0] gray stack empty
    //   63. W collect [0] stops marking: one drain round done
    @Test func claim3StoppingAfterOneDrainRoundStopsEarly() {
        var c = Configuration.chain
        c.termination = .afterOneDrainRound
        expectViolation("one drain round", c, .soundTermination)
    }

    // Found by the explorer (shortest interleaving, breadth-first), "epoch rule off":
    //
    // claim 4 no premature reuse violated: C reuses the old eden while M holds a pointer into Q's old body
    //   1. W flip: opens nursery 0's collection (collecting[0] := 1, barrierWord += 1, Y = {Q}), flips to the other eden half, queues it for C
    //   2. M r0 := G.s0: body pointer from offset[G] (relaxed) -> old body
    //   3. M r0 := G.s0: G.s0 (relaxed) -> Q
    //   4. M r1 := r0.s0: body pointer from offset[Q] (relaxed) -> old body
    //   5. M r1 := r0.s0: Q.s0 (relaxed) -> nil
    //   6. M poll: E (acquire) -> 0, epoch[M] := 0 (release)
    //   7. C takes nursery 0's collection from the queue
    //   8. M drain: epoch[M] = 0 (release store becomes visible)
    //   9. M slowPeek r1 := r0.s0: blockingBegin (epoch word kept)
    //   10. M slowPeek r1 := r0.s0: body pointer from offset[Q] (relaxed) -> old body; blocks
    //   11. C [0] opens H0 (round 1, need 1); M by proxy
    //   12. W waitDone: acknowledges H0 of nursery 0; E (acquire) -> 0, epoch[W] := 0 (release)
    //   13. C [0] H0 complete
    //   14. C [0] opens H1 (round 2, need 1); M by proxy: stack scan finds {Q}
    //   15. W drain: epoch[W] = 0 (release store becomes visible)
    //   16. W waitDone: acknowledges H1 of nursery 0: stack scan finds {}, records new half {}; E (acquire) -> 0, epoch[W] := 0 (release)
    //   17. C [0] H1 complete; T1, carried {G}
    //   18. C [0] new half scanned
    //   19. C [0] scanHolder G: fetch_and rem (seq_cst) -> was member 0, fence
    //   20. C [0] scanHolder G: header (relaxed) -> 1 slot
    //   21. C [0] scanHolder G: s0 (relaxed) -> Q, copies Q (offset CAS, fence, switch release)
    //   22. W drain: epoch[W] = 0 (release store becomes visible)
    //   23. C drain: offset[Q] = copy (release store becomes visible)
    //   24. C [0] scanHolder G: names Y_0: keepForNext, fetch_or rem pending 0 (seq_cst) -> was 0
    //   25. C [0] carried holders scanned
    //   26. C [0] takes handed: roots {Q}, rem {}, del {}
    //   27. C [0] visits root Q: nothing to copy
    //   28. C [0] stack roots visited
    //   29. C [0] remembered holders scanned
    //   30. C [0] deletion records visited
    //   31. C [0] drain: Q.s0 (relaxed) -> nil
    //   32. C [0] drain: Q scanned
    //   33. C [0] gray stack empty
    //   34. C [0] T1 done: another drain round
    //   35. C [0] opens drain (round 3, need 1); M by proxy
    //   36. W waitDone: acknowledges drain of nursery 0; E (acquire) -> 0, epoch[W] := 0 (release)
    //   37. C [0] drain round complete
    //   38. C [0] takes handed: roots {}, rem {}, del {}
    //   39. C [0] stack roots visited
    //   40. C [0] remembered holders scanned
    //   41. C [0] deletion records visited
    //   42. C [0] gray stack empty
    //   43. C [0] stops marking: the round copied nothing
    //   44. C [0] finish: collecting[0] := 0, barrierWord -= 1 (under the mutex)
    //   45. C [0] foldCarried G: fetch_or member 0, fetch_and ~pending 0: was pending 0
    //   46. C [0] carried set folded
    //   47. C [0] sweep: Q survives
    //   48. C [0] entry sweep done; carried := {G}
    //   49. C [0] s = E, E := 1 (seq_cst fetch_add); no epoch rule
    //   50. C [0] old eden and survivor-from may be reused
    @Test func claim4WithoutTheEpochRuleTheOldEdenIsReusedUnderAPointer() {
        var c = Configuration.epochs
        c.epochRule = false
        expectViolation("epoch rule off", c, .noPrematureReuse)
    }

    // Found by the explorer (shortest interleaving, breadth-first), "blocking regions quiescent":
    //
    // claim 4 no premature reuse violated: C reuses the old eden while M holds a pointer into Q's old body
    //   1. W flip: opens nursery 0's collection (collecting[0] := 1, barrierWord += 1, Y = {Q}), flips to the other eden half, queues it for C
    //   2. M r0 := G.s0: body pointer from offset[G] (relaxed) -> old body
    //   3. M r0 := G.s0: G.s0 (relaxed) -> Q
    //   4. M r1 := r0.s0: body pointer from offset[Q] (relaxed) -> old body
    //   5. M r1 := r0.s0: Q.s0 (relaxed) -> nil
    //   6. M poll: E (acquire) -> 0, epoch[M] := 0 (release)
    //   7. C takes nursery 0's collection from the queue
    //   8. M drain: epoch[M] = 0 (release store becomes visible)
    //   9. M slowPeek r1 := r0.s0: blockingBegin, epoch[M] := quiescent (no epoch rule for blocking regions)
    //   10. M slowPeek r1 := r0.s0: body pointer from offset[Q] (relaxed) -> old body; blocks
    //   11. C [0] opens H0 (round 1, need 1); M by proxy
    //   12. W waitDone: acknowledges H0 of nursery 0; E (acquire) -> 0, epoch[W] := 0 (release)
    //   13. C [0] H0 complete
    //   14. C [0] opens H1 (round 2, need 1); M by proxy: stack scan finds {Q}
    //   15. W drain: epoch[W] = 0 (release store becomes visible)
    //   16. W waitDone: acknowledges H1 of nursery 0: stack scan finds {}, records new half {}; E (acquire) -> 0, epoch[W] := 0 (release)
    //   17. C [0] H1 complete; T1, carried {G}
    //   18. C [0] new half scanned
    //   19. C [0] scanHolder G: fetch_and rem (seq_cst) -> was member 0, fence
    //   20. C [0] scanHolder G: header (relaxed) -> 1 slot
    //   21. C [0] scanHolder G: s0 (relaxed) -> Q, copies Q (offset CAS, fence, switch release)
    //   22. W drain: epoch[W] = 0 (release store becomes visible)
    //   23. W waitDone: waits: epoch[W] := quiescent (under the mutex)
    //   24. C drain: offset[Q] = copy (release store becomes visible)
    //   25. C [0] scanHolder G: names Y_0: keepForNext, fetch_or rem pending 0 (seq_cst) -> was 0
    //   26. C [0] carried holders scanned
    //   27. C [0] takes handed: roots {Q}, rem {}, del {}
    //   28. C [0] visits root Q: nothing to copy
    //   29. C [0] stack roots visited
    //   30. C [0] remembered holders scanned
    //   31. C [0] deletion records visited
    //   32. C [0] drain: Q.s0 (relaxed) -> nil
    //   33. C [0] drain: Q scanned
    //   34. C [0] gray stack empty
    //   35. C [0] T1 done: another drain round
    //   36. C [0] opens drain (round 3, need 1); M by proxy
    //   37. W waitDone: acknowledges drain of nursery 0; E (acquire) -> 0, epoch[W] := 0 (release)
    //   38. C [0] drain round complete
    //   39. C [0] takes handed: roots {}, rem {}, del {}
    //   40. C [0] stack roots visited
    //   41. C [0] remembered holders scanned
    //   42. C [0] deletion records visited
    //   43. C [0] gray stack empty
    //   44. C [0] stops marking: the round copied nothing
    //   45. C [0] finish: collecting[0] := 0, barrierWord -= 1 (under the mutex)
    //   46. C [0] foldCarried G: fetch_or member 0, fetch_and ~pending 0: was pending 0
    //   47. C [0] carried set folded
    //   48. C [0] sweep: Q survives
    //   49. C [0] entry sweep done; carried := {G}
    //   50. C [0] s = E, E := 1 (seq_cst fetch_add)
    //   51. C [0] epoch wait: epoch[W] (acquire) -> quiescent
    //   52. C [0] epoch wait: epoch[M] (acquire) -> quiescent
    //   53. C [0] every epoch word > 0
    //   54. C [0] old eden and survivor-from may be reused
    @Test func claim4ABlockingRegionThatQuiescesLetsTheEdenBeReusedUnderItsPointer() {
        var c = Configuration.epochs
        c.blockingRegionsKeepEpoch = false
        expectViolation("blocking regions quiescent", c, .noPrematureReuse)
    }

    // Found by the explorer (shortest interleaving, breadth-first), "waiters not quiescent":
    //
    // claim no deadlock violated: no thread can move and the run is not finished
    //   1. W flip: opens nursery 0's collection (collecting[0] := 1, barrierWord += 1, Y = {Q}), flips to the other eden half, queues it for C
    //   2. M r0 := G.s0: body pointer from offset[G] (relaxed) -> old body
    //   3. M r0 := G.s0: G.s0 (relaxed) -> Q
    //   4. M r1 := r0.s0: body pointer from offset[Q] (relaxed) -> old body
    //   5. M r1 := r0.s0: Q.s0 (relaxed) -> nil
    //   6. M poll: E (acquire) -> 0, epoch[M] := 0 (release)
    //   7. C takes nursery 0's collection from the queue
    //   8. M drain: epoch[M] = 0 (release store becomes visible)
    //   9. M slowPeek r1 := r0.s0: blockingBegin (epoch word kept)
    //   10. M slowPeek r1 := r0.s0: body pointer from offset[Q] (relaxed) -> old body; blocks
    //   11. M slowPeek r1 := r0.s0: reads Q.s0 through the pointer -> nil
    //   12. M slowPeek r1 := r0.s0: blockingEnd
    //   13. M leaveVM: epoch[M] := quiescent, leaves the VM, holds nothing (under the mutex)
    //   14. M enterVM: enters the VM
    //   15. M enterVM: epoch[M] := 0 (seq_cst)
    //   16. M drain: epoch[M] = 0 (seq_cst store becomes visible)
    //   17. M enterVM: E (seq_cst) -> 0, epoch[M] := 0 (release)
    //   18. M r0 := G.s0: body pointer from offset[G] (relaxed) -> old body
    //   19. M r0 := G.s0: G.s0 (relaxed) -> Q
    //   20. M r1 := r0.s0: body pointer from offset[Q] (relaxed) -> old body
    //   21. M r1 := r0.s0: Q.s0 (relaxed) -> nil
    //   22. M drain: epoch[M] = 0 (release store becomes visible)
    //   23. M leaveVM: epoch[M] := quiescent, leaves the VM, holds nothing (under the mutex)
    //   24. C [0] opens H0 (round 1, need 1); M by proxy
    //   25. W waitDone: acknowledges H0 of nursery 0; E (acquire) -> 0, epoch[W] := 0 (release)
    //   26. C [0] H0 complete
    //   27. C [0] opens H1 (round 2, need 1); M by proxy
    //   28. W drain: epoch[W] = 0 (release store becomes visible)
    //   29. W waitDone: acknowledges H1 of nursery 0: stack scan finds {}, records new half {}; E (acquire) -> 0, epoch[W] := 0 (release)
    //   30. C [0] H1 complete; T1, carried {G}
    //   31. C [0] new half scanned
    //   32. C [0] scanHolder G: fetch_and rem (seq_cst) -> was member 0, fence
    //   33. C [0] scanHolder G: header (relaxed) -> 1 slot
    //   34. C [0] scanHolder G: s0 (relaxed) -> Q, copies Q (offset CAS, fence, switch release)
    //   35. W drain: epoch[W] = 0 (release store becomes visible)
    //   36. C drain: offset[Q] = copy (release store becomes visible)
    //   37. C [0] scanHolder G: names Y_0: keepForNext, fetch_or rem pending 0 (seq_cst) -> was 0
    //   38. C [0] carried holders scanned
    //   39. C [0] takes handed: roots {}, rem {}, del {}
    //   40. C [0] stack roots visited
    //   41. C [0] remembered holders scanned
    //   42. C [0] deletion records visited
    //   43. C [0] drain: Q.s0 (relaxed) -> nil
    //   44. C [0] drain: Q scanned
    //   45. C [0] gray stack empty
    //   46. C [0] T1 done: another drain round
    //   47. C [0] opens drain (round 3, need 1); M by proxy
    //   48. W waitDone: acknowledges drain of nursery 0; E (acquire) -> 0, epoch[W] := 0 (release)
    //   49. C [0] drain round complete
    //   50. C [0] takes handed: roots {}, rem {}, del {}
    //   51. C [0] stack roots visited
    //   52. C [0] remembered holders scanned
    //   53. C [0] deletion records visited
    //   54. C [0] gray stack empty
    //   55. C [0] stops marking: the round copied nothing
    //   56. C [0] finish: collecting[0] := 0, barrierWord -= 1 (under the mutex)
    //   57. C [0] foldCarried G: fetch_or member 0, fetch_and ~pending 0: was pending 0
    //   58. C [0] carried set folded
    //   59. C [0] sweep: Q survives
    //   60. C [0] entry sweep done; carried := {G}
    //   61. C [0] s = E, E := 1 (seq_cst fetch_add)
    //   62. C [0] epoch wait: epoch[W] (acquire) -> 0
    //   63. C [0] epoch wait: epoch[M] (acquire) -> quiescent
    //   64. C [0] epoch wait: min 0 <= 0: again
    //   65. W drain: epoch[W] = 0 (release store becomes visible)
    //   66. (no step can follow)
    @Test func claim4AWaiterThatKeepsItsEpochDeadlocksWithTheEpochWait() {
        var c = Configuration.epochs
        c.waitersAreQuiescent = false
        expectViolation("waiters not quiescent", c, .noDeadlock)
    }

    // Found by the explorer (shortest interleaving, breadth-first), "deferred entry in the snapshot, live object swept":
    //
    // claim 5 one owner per entry violated: O sweeps snapshot entry H, which its nursery freed and a worker reused for a live object
    //   1. W0 collect: opens nursery 0's collection (collecting[0] := 1, barrierWord += 1, Y = {H})
    //   2. W0 collect [0] opens H0 (round 1, need 2)
    //   3. W0 collect [0] acknowledges H0 of nursery 0; E (acquire) -> 0, epoch[W0] := 0 (release)
    //   4. W1 collect: opens nursery 1's collection (collecting[1] := 1, barrierWord += 1, Y = {Y})
    //   5. W1 collect [1] opens H0 (round 1, need 2)
    //   6. W1 collect [1] acknowledges H0 of nursery 0; E (acquire) -> 0, epoch[W1] := 0 (release)
    //   7. W0 collect [0] H0 complete
    //   8. O requests a stop (stwWanted): no collection opens
    //   9. W0 drain: epoch[W0] = 0 (release store becomes visible)
    //   10. W0 collect [0] opens H1 (round 2, need 2)
    //   11. W0 collect [0] acknowledges H1 of nursery 0: stack scan finds {}; E (acquire) -> 0, epoch[W0] := 0 (release)
    //   12. W0 drain: epoch[W0] = 0 (release store becomes visible)
    //   13. W0 collect [0] acknowledges H0 of nursery 1; E (acquire) -> 0, epoch[W0] := 0 (release)
    //   14. W0 drain: epoch[W0] = 0 (release store becomes visible)
    //   15. W1 drain: epoch[W1] = 0 (release store becomes visible)
    //   16. W1 collect [1] acknowledges H1 of nursery 0: stack scan finds {}; E (acquire) -> 0, epoch[W1] := 0 (release)
    //   17. W0 collect [0] H1 complete; T1, carried {}
    //   18. W0 collect [0] new half scanned
    //   19. W0 collect [0] carried holders scanned
    //   20. W0 collect [0] takes handed: roots {}, rem {}, del {}
    //   21. W0 collect [0] stack roots visited
    //   22. W0 collect [0] remembered holders scanned
    //   23. W0 collect [0] deletion records visited
    //   24. W0 collect [0] gray stack empty
    //   25. W0 collect [0] T1 done: another drain round
    //   26. W1 drain: epoch[W1] = 0 (release store becomes visible)
    //   27. W1 collect [1] acknowledges H0 of nursery 1; E (acquire) -> 0, epoch[W1] := 0 (release)
    //   28. W1 collect [1] H0 complete
    //   29. W1 drain: epoch[W1] = 0 (release store becomes visible)
    //   30. W1 collect [1] opens H1 (round 2, need 2)
    //   31. W1 collect [1] acknowledges H1 of nursery 1: stack scan finds {Y}; E (acquire) -> 0, epoch[W1] := 0 (release)
    //   32. W0 collect [0] opens drain (round 3, need 2)
    //   33. W0 collect [0] acknowledges drain of nursery 0; E (acquire) -> 0, epoch[W0] := 0 (release)
    //   34. W0 drain: epoch[W0] = 0 (release store becomes visible)
    //   35. W0 collect [0] acknowledges H1 of nursery 1: stack scan finds {}; E (acquire) -> 0, epoch[W0] := 0 (release)
    //   36. W1 collect [1] H1 complete; T1, carried {H}
    //   37. W1 collect [1] new half scanned
    //   38. W0 drain: epoch[W0] = 0 (release store becomes visible)
    //   39. W1 drain: epoch[W1] = 0 (release store becomes visible)
    //   40. W1 collect [1] scanHolder H: fetch_and rem (seq_cst) -> was member 1, fence
    //   41. W1 collect [1] scanHolder H: header (relaxed) -> 1 slot
    //   42. W1 collect [1] scanHolder H: s0 (relaxed) -> Y, copies Y
    //   43. W1 collect [1] scanHolder H: names Y_1: keepForNext, fetch_or rem pending 1 (seq_cst) -> was 0
    //   44. W1 collect [1] carried holders scanned
    //   45. W1 collect [1] takes handed: roots {Y}, rem {}, del {}
    //   46. W1 collect [1] visits root Y: nothing to copy
    //   47. W1 collect [1] stack roots visited
    //   48. W1 collect [1] remembered holders scanned
    //   49. W1 collect [1] deletion records visited
    //   50. W1 collect [1] gray stack empty
    //   51. W1 collect [1] T1 done: another drain round
    //   52. W1 collect [1] opens drain (round 3, need 2)
    //   53. W0 collect [0] acknowledges drain of nursery 1; E (acquire) -> 0, epoch[W0] := 0 (release)
    //   54. W1 collect [1] acknowledges drain of nursery 0; E (acquire) -> 0, epoch[W1] := 0 (release)
    //   55. W0 collect [0] drain round complete
    //   56. W0 drain: epoch[W0] = 0 (release store becomes visible)
    //   57. W0 collect [0] takes handed: roots {}, rem {}, del {}
    //   58. W0 collect [0] stack roots visited
    //   59. W0 collect [0] remembered holders scanned
    //   60. W0 collect [0] deletion records visited
    //   61. W0 collect [0] gray stack empty
    //   62. W0 collect [0] stops marking: the round copied nothing
    //   63. W0 collect [0] finish: collecting[0] := 0, barrierWord -= 1 (under the mutex)
    //   64. W0 collect [0] carried set folded
    //   65. W0 collect [0] sweep: H dead, rem (relaxed) -> pending 1: header slots := 0 (release), rem := 0 (seq_cst), free deferred
    //   66. W0 collect [0] entry sweep done; carried := {}
    //   67. W0 drain: header[H] = 0 (release store becomes visible)
    //   68. W0 drain: rem[H] = 0 (seq_cst store becomes visible)
    //   69. W1 drain: epoch[W1] = 0 (release store becomes visible)
    //   70. W1 collect [1] acknowledges drain of nursery 1; E (acquire) -> 0, epoch[W1] := 0 (release)
    //   71. W1 collect [1] drain round complete
    //   72. W1 drain: epoch[W1] = 0 (release store becomes visible)
    //   73. W1 collect [1] takes handed: roots {}, rem {}, del {}
    //   74. W1 collect [1] stack roots visited
    //   75. W1 collect [1] remembered holders scanned
    //   76. W1 collect [1] deletion records visited
    //   77. W1 collect [1] gray stack empty
    //   78. W1 collect [1] stops marking: the round copied nothing
    //   79. W1 collect [1] finish: collecting[1] := 0, barrierWord -= 1 (under the mutex)
    //   80. W1 collect [1] foldCarried H: fetch_or member 1, fetch_and ~pending 1: was 0
    //   81. W1 collect [1] carried set folded
    //   82. W1 collect [1] sweep: Y survives
    //   83. W1 collect [1] entry sweep done; carried := {H}
    //   84. W1 collect [1] s = E, E := 1 (seq_cst fetch_add); epoch[W1] := 1 (release)
    //   85. W0 collect [0] s = E, E := 2 (seq_cst fetch_add); epoch[W0] := 2 (release)
    //   86. W0 collect [0] epoch wait: epoch[W0] (acquire) -> 2
    //   87. W0 drain: epoch[W0] = 2 (release store becomes visible)
    //   88. W1 collect [1] epoch wait: epoch[W0] (acquire) -> 2
    //   89. W1 collect [1] epoch wait: epoch[W1] (acquire) -> 1
    //   90. W1 collect [1] every epoch word > 0
    //   91. W1 collect [1] old eden and survivor-from may be reused
    //   92. W1 collect [1] deferred frees done
    //   93. W1 drain: epoch[W1] = 1 (release store becomes visible)
    //   94. W1 collect [1] collection done
    //   95. W1 leaveVM: epoch[W1] := quiescent, leaves the VM, holds nothing (under the mutex)
    //   96. W0 collect [0] epoch wait: epoch[W1] (acquire) -> quiescent
    //   97. W0 collect [0] every epoch word > 1
    //   98. W0 collect [0] old eden and survivor-from may be reused
    //   99. W0 collect [0] deferred H: exchange rem 0 (seq_cst) -> was member 1: re-armed, kept for the next collection
    //   100. W0 collect [0] deferred frees done
    //   101. W0 collect [0] collection done
    //   102. O initial mark (world stopped): snapshot {H}, marks the reachable ones
    //   103. W0 collect: opens nursery 0's collection (collecting[0] := 1, barrierWord += 1, Y = {})
    //   104. W0 collect [0] opens H0 (round 4, need 1); W1 by proxy
    //   105. W0 collect [0] acknowledges H0 of nursery 0; E (acquire) -> 2, epoch[W0] := 2 (release)
    //   106. W0 collect [0] H0 complete
    //   107. W0 drain: epoch[W0] = 2 (release store becomes visible)
    //   108. W0 collect [0] opens H1 (round 5, need 1); W1 by proxy
    //   109. W0 collect [0] acknowledges H1 of nursery 0: stack scan finds {}; E (acquire) -> 2, epoch[W0] := 2 (release)
    //   110. W0 collect [0] H1 complete; T1, carried {}
    //   111. W0 collect [0] new half scanned
    //   112. W0 collect [0] carried holders scanned
    //   113. W0 drain: epoch[W0] = 2 (release store becomes visible)
    //   114. W0 collect [0] takes handed: roots {}, rem {}, del {}
    //   115. W0 collect [0] stack roots visited
    //   116. W0 collect [0] remembered holders scanned
    //   117. W0 collect [0] deletion records visited
    //   118. W0 collect [0] gray stack empty
    //   119. W0 collect [0] T1 done: another drain round
    //   120. W0 collect [0] opens drain (round 6, need 1); W1 by proxy
    //   121. W0 collect [0] acknowledges drain of nursery 0; E (acquire) -> 2, epoch[W0] := 2 (release)
    //   122. W0 collect [0] drain round complete
    //   123. W0 drain: epoch[W0] = 2 (release store becomes visible)
    //   124. W0 collect [0] takes handed: roots {}, rem {}, del {}
    //   125. W0 collect [0] stack roots visited
    //   126. W0 collect [0] remembered holders scanned
    //   127. W0 collect [0] deletion records visited
    //   128. W0 collect [0] gray stack empty
    //   129. W0 collect [0] stops marking: the round copied nothing
    //   130. W0 collect [0] finish: collecting[0] := 0, barrierWord -= 1 (under the mutex)
    //   131. W0 collect [0] carried set folded
    //   132. W0 collect [0] entry sweep done; carried := {}
    //   133. W0 collect [0] s = E, E := 3 (seq_cst fetch_add); epoch[W0] := 3 (release)
    //   134. W0 collect [0] epoch wait: epoch[W0] (acquire) -> 3
    //   135. W0 collect [0] epoch wait: epoch[W1] (acquire) -> quiescent
    //   136. W0 collect [0] every epoch word > 2
    //   137. W0 collect [0] old eden and survivor-from may be reused
    //   138. W0 drain: epoch[W0] = 3 (release store becomes visible)
    //   139. W0 collect [0] deferred H: exchange rem 0 (seq_cst) -> was 0: entry freed
    //   140. W0 collect [0] deferred frees done
    //   141. W0 collect [0] collection done
    //   142. W0 r0 := alloc H: H young in nursery 0
    //   143. O sweep: frees unmarked snapshot entry H
    // Found by the explorer (shortest interleaving, breadth-first), "deferred entry in the snapshot, freed twice":
    //
    // claim 5 one owner per entry violated: W0 collect frees deferred entry H, but the old-space collector already freed it
    //   1. W0 collect: opens nursery 0's collection (collecting[0] := 1, barrierWord += 1, Y = {H})
    //   2. W0 collect [0] opens H0 (round 1, need 2)
    //   3. W0 collect [0] acknowledges H0 of nursery 0; E (acquire) -> 0, epoch[W0] := 0 (release)
    //   4. W1 collect: opens nursery 1's collection (collecting[1] := 1, barrierWord += 1, Y = {Y})
    //   5. W1 collect [1] opens H0 (round 1, need 2)
    //   6. W1 collect [1] acknowledges H0 of nursery 0; E (acquire) -> 0, epoch[W1] := 0 (release)
    //   7. W0 collect [0] H0 complete
    //   8. O requests a stop (stwWanted): no collection opens
    //   9. W0 drain: epoch[W0] = 0 (release store becomes visible)
    //   10. W0 collect [0] opens H1 (round 2, need 2)
    //   11. W0 collect [0] acknowledges H1 of nursery 0: stack scan finds {}; E (acquire) -> 0, epoch[W0] := 0 (release)
    //   12. W0 drain: epoch[W0] = 0 (release store becomes visible)
    //   13. W0 collect [0] acknowledges H0 of nursery 1; E (acquire) -> 0, epoch[W0] := 0 (release)
    //   14. W0 drain: epoch[W0] = 0 (release store becomes visible)
    //   15. W1 drain: epoch[W1] = 0 (release store becomes visible)
    //   16. W1 collect [1] acknowledges H1 of nursery 0: stack scan finds {}; E (acquire) -> 0, epoch[W1] := 0 (release)
    //   17. W0 collect [0] H1 complete; T1, carried {}
    //   18. W0 collect [0] new half scanned
    //   19. W0 collect [0] carried holders scanned
    //   20. W0 collect [0] takes handed: roots {}, rem {}, del {}
    //   21. W0 collect [0] stack roots visited
    //   22. W0 collect [0] remembered holders scanned
    //   23. W0 collect [0] deletion records visited
    //   24. W0 collect [0] gray stack empty
    //   25. W0 collect [0] T1 done: another drain round
    //   26. W1 drain: epoch[W1] = 0 (release store becomes visible)
    //   27. W1 collect [1] acknowledges H0 of nursery 1; E (acquire) -> 0, epoch[W1] := 0 (release)
    //   28. W1 collect [1] H0 complete
    //   29. W1 drain: epoch[W1] = 0 (release store becomes visible)
    //   30. W1 collect [1] opens H1 (round 2, need 2)
    //   31. W1 collect [1] acknowledges H1 of nursery 1: stack scan finds {Y}; E (acquire) -> 0, epoch[W1] := 0 (release)
    //   32. W0 collect [0] opens drain (round 3, need 2)
    //   33. W0 collect [0] acknowledges drain of nursery 0; E (acquire) -> 0, epoch[W0] := 0 (release)
    //   34. W0 drain: epoch[W0] = 0 (release store becomes visible)
    //   35. W0 collect [0] acknowledges H1 of nursery 1: stack scan finds {}; E (acquire) -> 0, epoch[W0] := 0 (release)
    //   36. W1 collect [1] H1 complete; T1, carried {H}
    //   37. W1 collect [1] new half scanned
    //   38. W0 drain: epoch[W0] = 0 (release store becomes visible)
    //   39. W1 drain: epoch[W1] = 0 (release store becomes visible)
    //   40. W1 collect [1] scanHolder H: fetch_and rem (seq_cst) -> was member 1, fence
    //   41. W1 collect [1] scanHolder H: header (relaxed) -> 1 slot
    //   42. W1 collect [1] scanHolder H: s0 (relaxed) -> Y, copies Y
    //   43. W1 collect [1] scanHolder H: names Y_1: keepForNext, fetch_or rem pending 1 (seq_cst) -> was 0
    //   44. W1 collect [1] carried holders scanned
    //   45. W1 collect [1] takes handed: roots {Y}, rem {}, del {}
    //   46. W1 collect [1] visits root Y: nothing to copy
    //   47. W1 collect [1] stack roots visited
    //   48. W1 collect [1] remembered holders scanned
    //   49. W1 collect [1] deletion records visited
    //   50. W1 collect [1] gray stack empty
    //   51. W1 collect [1] T1 done: another drain round
    //   52. W1 collect [1] opens drain (round 3, need 2)
    //   53. W0 collect [0] acknowledges drain of nursery 1; E (acquire) -> 0, epoch[W0] := 0 (release)
    //   54. W1 collect [1] acknowledges drain of nursery 0; E (acquire) -> 0, epoch[W1] := 0 (release)
    //   55. W0 collect [0] drain round complete
    //   56. W0 drain: epoch[W0] = 0 (release store becomes visible)
    //   57. W0 collect [0] takes handed: roots {}, rem {}, del {}
    //   58. W0 collect [0] stack roots visited
    //   59. W0 collect [0] remembered holders scanned
    //   60. W0 collect [0] deletion records visited
    //   61. W0 collect [0] gray stack empty
    //   62. W0 collect [0] stops marking: the round copied nothing
    //   63. W0 collect [0] finish: collecting[0] := 0, barrierWord -= 1 (under the mutex)
    //   64. W0 collect [0] carried set folded
    //   65. W0 collect [0] sweep: H dead, rem (relaxed) -> pending 1: header slots := 0 (release), rem := 0 (seq_cst), free deferred
    //   66. W0 collect [0] entry sweep done; carried := {}
    //   67. W0 drain: header[H] = 0 (release store becomes visible)
    //   68. W0 drain: rem[H] = 0 (seq_cst store becomes visible)
    //   69. W1 drain: epoch[W1] = 0 (release store becomes visible)
    //   70. W1 collect [1] acknowledges drain of nursery 1; E (acquire) -> 0, epoch[W1] := 0 (release)
    //   71. W1 collect [1] drain round complete
    //   72. W1 drain: epoch[W1] = 0 (release store becomes visible)
    //   73. W1 collect [1] takes handed: roots {}, rem {}, del {}
    //   74. W1 collect [1] stack roots visited
    //   75. W1 collect [1] remembered holders scanned
    //   76. W1 collect [1] deletion records visited
    //   77. W1 collect [1] gray stack empty
    //   78. W1 collect [1] stops marking: the round copied nothing
    //   79. W1 collect [1] finish: collecting[1] := 0, barrierWord -= 1 (under the mutex)
    //   80. W1 collect [1] foldCarried H: fetch_or member 1, fetch_and ~pending 1: was 0
    //   81. W1 collect [1] carried set folded
    //   82. W1 collect [1] sweep: Y survives
    //   83. W1 collect [1] entry sweep done; carried := {H}
    //   84. W1 collect [1] s = E, E := 1 (seq_cst fetch_add); epoch[W1] := 1 (release)
    //   85. W0 collect [0] s = E, E := 2 (seq_cst fetch_add); epoch[W0] := 2 (release)
    //   86. W0 collect [0] epoch wait: epoch[W0] (acquire) -> 2
    //   87. W0 drain: epoch[W0] = 2 (release store becomes visible)
    //   88. W1 collect [1] epoch wait: epoch[W0] (acquire) -> 2
    //   89. W1 collect [1] epoch wait: epoch[W1] (acquire) -> 1
    //   90. W1 collect [1] every epoch word > 0
    //   91. W1 collect [1] old eden and survivor-from may be reused
    //   92. W1 collect [1] deferred frees done
    //   93. W1 drain: epoch[W1] = 1 (release store becomes visible)
    //   94. W1 collect [1] collection done
    //   95. W1 leaveVM: epoch[W1] := quiescent, leaves the VM, holds nothing (under the mutex)
    //   96. W0 collect [0] epoch wait: epoch[W1] (acquire) -> quiescent
    //   97. W0 collect [0] every epoch word > 1
    //   98. W0 collect [0] old eden and survivor-from may be reused
    //   99. W0 collect [0] deferred H: exchange rem 0 (seq_cst) -> was member 1: re-armed, kept for the next collection
    //   100. W0 collect [0] deferred frees done
    //   101. W0 collect [0] collection done
    //   102. O initial mark (world stopped): snapshot {H}, marks the reachable ones
    //   103. W0 collect: opens nursery 0's collection (collecting[0] := 1, barrierWord += 1, Y = {})
    //   104. W0 collect [0] opens H0 (round 4, need 1); W1 by proxy
    //   105. W0 collect [0] acknowledges H0 of nursery 0; E (acquire) -> 2, epoch[W0] := 2 (release)
    //   106. W0 collect [0] H0 complete
    //   107. O sweep: frees unmarked snapshot entry H
    //   108. W0 drain: epoch[W0] = 2 (release store becomes visible)
    //   109. W0 collect [0] opens H1 (round 5, need 1); W1 by proxy
    //   110. W0 collect [0] acknowledges H1 of nursery 0: stack scan finds {}; E (acquire) -> 2, epoch[W0] := 2 (release)
    //   111. W0 collect [0] H1 complete; T1, carried {}
    //   112. W0 collect [0] new half scanned
    //   113. W0 collect [0] carried holders scanned
    //   114. W0 drain: epoch[W0] = 2 (release store becomes visible)
    //   115. W0 collect [0] takes handed: roots {}, rem {}, del {}
    //   116. W0 collect [0] stack roots visited
    //   117. W0 collect [0] remembered holders scanned
    //   118. W0 collect [0] deletion records visited
    //   119. W0 collect [0] gray stack empty
    //   120. W0 collect [0] T1 done: another drain round
    //   121. W0 collect [0] opens drain (round 6, need 1); W1 by proxy
    //   122. W0 collect [0] acknowledges drain of nursery 0; E (acquire) -> 2, epoch[W0] := 2 (release)
    //   123. W0 collect [0] drain round complete
    //   124. W0 drain: epoch[W0] = 2 (release store becomes visible)
    //   125. W0 collect [0] takes handed: roots {}, rem {}, del {}
    //   126. W0 collect [0] stack roots visited
    //   127. W0 collect [0] remembered holders scanned
    //   128. W0 collect [0] deletion records visited
    //   129. W0 collect [0] gray stack empty
    //   130. W0 collect [0] stops marking: the round copied nothing
    //   131. W0 collect [0] finish: collecting[0] := 0, barrierWord -= 1 (under the mutex)
    //   132. W0 collect [0] carried set folded
    //   133. W0 collect [0] entry sweep done; carried := {}
    //   134. W0 collect [0] s = E, E := 3 (seq_cst fetch_add); epoch[W0] := 3 (release)
    //   135. W0 collect [0] epoch wait: epoch[W0] (acquire) -> 3
    //   136. W0 collect [0] epoch wait: epoch[W1] (acquire) -> quiescent
    //   137. W0 collect [0] every epoch word > 2
    //   138. W0 collect [0] old eden and survivor-from may be reused
    //   139. W0 drain: epoch[W0] = 3 (release store becomes visible)
    //   140. W0 collect [0] deferred H: exchange rem 0 (seq_cst) -> was 0: entry freed
    @Test func claim5ADeferredEntryInTheSnapshotIsFreedTwiceOrSweptUnderANewObject() {
        var c = Configuration.ownership([.snapshot, .sweep])
        c.deferredEntriesBelongToTheirNursery = false
        expectViolation("deferred entry in the snapshot, live object swept", c, .oneOwnerPerEntry,
                        message: "O sweeps snapshot entry H, which its nursery freed and a worker reused for a live object")
        expectViolation("deferred entry in the snapshot, freed twice", c, .oneOwnerPerEntry,
                        message: "W0 collect frees deferred entry H, but the old-space collector already freed it")
    }

    // Found by the explorer (shortest interleaving, breadth-first), "deferred entry freed by a full collection":
    //
    // claim 5 one owner per entry violated: W0 collect frees deferred entry H, but the old-space collector already freed it
    //   1. W0 collect: opens nursery 0's collection (collecting[0] := 1, barrierWord += 1, Y = {H})
    //   2. W0 collect [0] opens H0 (round 1, need 2)
    //   3. W0 collect [0] acknowledges H0 of nursery 0; E (acquire) -> 0, epoch[W0] := 0 (release)
    //   4. W1 collect: opens nursery 1's collection (collecting[1] := 1, barrierWord += 1, Y = {Y})
    //   5. W1 collect [1] opens H0 (round 1, need 2)
    //   6. W1 collect [1] acknowledges H0 of nursery 0; E (acquire) -> 0, epoch[W1] := 0 (release)
    //   7. W0 collect [0] H0 complete
    //   8. O requests a stop (stwWanted): no collection opens
    //   9. W0 drain: epoch[W0] = 0 (release store becomes visible)
    //   10. W0 collect [0] opens H1 (round 2, need 2)
    //   11. W0 collect [0] acknowledges H1 of nursery 0: stack scan finds {}; E (acquire) -> 0, epoch[W0] := 0 (release)
    //   12. W0 drain: epoch[W0] = 0 (release store becomes visible)
    //   13. W0 collect [0] acknowledges H0 of nursery 1; E (acquire) -> 0, epoch[W0] := 0 (release)
    //   14. W0 drain: epoch[W0] = 0 (release store becomes visible)
    //   15. W1 drain: epoch[W1] = 0 (release store becomes visible)
    //   16. W1 collect [1] acknowledges H1 of nursery 0: stack scan finds {}; E (acquire) -> 0, epoch[W1] := 0 (release)
    //   17. W0 collect [0] H1 complete; T1, carried {}
    //   18. W0 collect [0] new half scanned
    //   19. W0 collect [0] carried holders scanned
    //   20. W0 collect [0] takes handed: roots {}, rem {}, del {}
    //   21. W0 collect [0] stack roots visited
    //   22. W0 collect [0] remembered holders scanned
    //   23. W0 collect [0] deletion records visited
    //   24. W0 collect [0] gray stack empty
    //   25. W0 collect [0] T1 done: another drain round
    //   26. W1 drain: epoch[W1] = 0 (release store becomes visible)
    //   27. W1 collect [1] acknowledges H0 of nursery 1; E (acquire) -> 0, epoch[W1] := 0 (release)
    //   28. W1 collect [1] H0 complete
    //   29. W1 drain: epoch[W1] = 0 (release store becomes visible)
    //   30. W1 collect [1] opens H1 (round 2, need 2)
    //   31. W1 collect [1] acknowledges H1 of nursery 1: stack scan finds {Y}; E (acquire) -> 0, epoch[W1] := 0 (release)
    //   32. W0 collect [0] opens drain (round 3, need 2)
    //   33. W0 collect [0] acknowledges drain of nursery 0; E (acquire) -> 0, epoch[W0] := 0 (release)
    //   34. W0 drain: epoch[W0] = 0 (release store becomes visible)
    //   35. W0 collect [0] acknowledges H1 of nursery 1: stack scan finds {}; E (acquire) -> 0, epoch[W0] := 0 (release)
    //   36. W1 collect [1] H1 complete; T1, carried {H}
    //   37. W1 collect [1] new half scanned
    //   38. W0 drain: epoch[W0] = 0 (release store becomes visible)
    //   39. W1 drain: epoch[W1] = 0 (release store becomes visible)
    //   40. W1 collect [1] scanHolder H: fetch_and rem (seq_cst) -> was member 1, fence
    //   41. W1 collect [1] scanHolder H: header (relaxed) -> 1 slot
    //   42. W1 collect [1] scanHolder H: s0 (relaxed) -> Y, copies Y
    //   43. W1 collect [1] scanHolder H: names Y_1: keepForNext, fetch_or rem pending 1 (seq_cst) -> was 0
    //   44. W1 collect [1] carried holders scanned
    //   45. W1 collect [1] takes handed: roots {Y}, rem {}, del {}
    //   46. W1 collect [1] visits root Y: nothing to copy
    //   47. W1 collect [1] stack roots visited
    //   48. W1 collect [1] remembered holders scanned
    //   49. W1 collect [1] deletion records visited
    //   50. W1 collect [1] gray stack empty
    //   51. W1 collect [1] T1 done: another drain round
    //   52. W1 collect [1] opens drain (round 3, need 2)
    //   53. W0 collect [0] acknowledges drain of nursery 1; E (acquire) -> 0, epoch[W0] := 0 (release)
    //   54. W1 collect [1] acknowledges drain of nursery 0; E (acquire) -> 0, epoch[W1] := 0 (release)
    //   55. W0 collect [0] drain round complete
    //   56. W0 drain: epoch[W0] = 0 (release store becomes visible)
    //   57. W0 collect [0] takes handed: roots {}, rem {}, del {}
    //   58. W0 collect [0] stack roots visited
    //   59. W0 collect [0] remembered holders scanned
    //   60. W0 collect [0] deletion records visited
    //   61. W0 collect [0] gray stack empty
    //   62. W0 collect [0] stops marking: the round copied nothing
    //   63. W0 collect [0] finish: collecting[0] := 0, barrierWord -= 1 (under the mutex)
    //   64. W0 collect [0] carried set folded
    //   65. W0 collect [0] sweep: H dead, rem (relaxed) -> pending 1: header slots := 0 (release), rem := 0 (seq_cst), free deferred
    //   66. W0 collect [0] entry sweep done; carried := {}
    //   67. W0 drain: header[H] = 0 (release store becomes visible)
    //   68. W0 drain: rem[H] = 0 (seq_cst store becomes visible)
    //   69. W1 drain: epoch[W1] = 0 (release store becomes visible)
    //   70. W1 collect [1] acknowledges drain of nursery 1; E (acquire) -> 0, epoch[W1] := 0 (release)
    //   71. W1 collect [1] drain round complete
    //   72. W1 drain: epoch[W1] = 0 (release store becomes visible)
    //   73. W1 collect [1] takes handed: roots {}, rem {}, del {}
    //   74. W1 collect [1] stack roots visited
    //   75. W1 collect [1] remembered holders scanned
    //   76. W1 collect [1] deletion records visited
    //   77. W1 collect [1] gray stack empty
    //   78. W1 collect [1] stops marking: the round copied nothing
    //   79. W1 collect [1] finish: collecting[1] := 0, barrierWord -= 1 (under the mutex)
    //   80. W1 collect [1] foldCarried H: fetch_or member 1, fetch_and ~pending 1: was 0
    //   81. W1 collect [1] carried set folded
    //   82. W1 collect [1] sweep: Y survives
    //   83. W1 collect [1] entry sweep done; carried := {H}
    //   84. W1 collect [1] s = E, E := 1 (seq_cst fetch_add); epoch[W1] := 1 (release)
    //   85. W0 collect [0] s = E, E := 2 (seq_cst fetch_add); epoch[W0] := 2 (release)
    //   86. W0 collect [0] epoch wait: epoch[W0] (acquire) -> 2
    //   87. W0 drain: epoch[W0] = 2 (release store becomes visible)
    //   88. W1 collect [1] epoch wait: epoch[W0] (acquire) -> 2
    //   89. W1 collect [1] epoch wait: epoch[W1] (acquire) -> 1
    //   90. W1 collect [1] every epoch word > 0
    //   91. W1 collect [1] old eden and survivor-from may be reused
    //   92. W1 collect [1] deferred frees done
    //   93. W1 drain: epoch[W1] = 1 (release store becomes visible)
    //   94. W1 collect [1] collection done
    //   95. W1 leaveVM: epoch[W1] := quiescent, leaves the VM, holds nothing (under the mutex)
    //   96. W0 collect [0] epoch wait: epoch[W1] (acquire) -> quiescent
    //   97. W0 collect [0] every epoch word > 1
    //   98. W0 collect [0] old eden and survivor-from may be reused
    //   99. W0 collect [0] deferred H: exchange rem 0 (seq_cst) -> was member 1: re-armed, kept for the next collection
    //   100. W0 collect [0] deferred frees done
    //   101. W0 collect [0] collection done
    //   102. O full collection (world stopped): frees {H}
    //   103. W0 collect: opens nursery 0's collection (collecting[0] := 1, barrierWord += 1, Y = {})
    //   104. W0 collect [0] opens H0 (round 4, need 1); W1 by proxy
    //   105. W0 collect [0] acknowledges H0 of nursery 0; E (acquire) -> 2, epoch[W0] := 2 (release)
    //   106. W0 collect [0] H0 complete
    //   107. W0 drain: epoch[W0] = 2 (release store becomes visible)
    //   108. W0 collect [0] opens H1 (round 5, need 1); W1 by proxy
    //   109. W0 collect [0] acknowledges H1 of nursery 0: stack scan finds {}; E (acquire) -> 2, epoch[W0] := 2 (release)
    //   110. W0 collect [0] H1 complete; T1, carried {}
    //   111. W0 collect [0] new half scanned
    //   112. W0 collect [0] carried holders scanned
    //   113. W0 drain: epoch[W0] = 2 (release store becomes visible)
    //   114. W0 collect [0] takes handed: roots {}, rem {}, del {}
    //   115. W0 collect [0] stack roots visited
    //   116. W0 collect [0] remembered holders scanned
    //   117. W0 collect [0] deletion records visited
    //   118. W0 collect [0] gray stack empty
    //   119. W0 collect [0] T1 done: another drain round
    //   120. W0 collect [0] opens drain (round 6, need 1); W1 by proxy
    //   121. W0 collect [0] acknowledges drain of nursery 0; E (acquire) -> 2, epoch[W0] := 2 (release)
    //   122. W0 collect [0] drain round complete
    //   123. W0 drain: epoch[W0] = 2 (release store becomes visible)
    //   124. W0 collect [0] takes handed: roots {}, rem {}, del {}
    //   125. W0 collect [0] stack roots visited
    //   126. W0 collect [0] remembered holders scanned
    //   127. W0 collect [0] deletion records visited
    //   128. W0 collect [0] gray stack empty
    //   129. W0 collect [0] stops marking: the round copied nothing
    //   130. W0 collect [0] finish: collecting[0] := 0, barrierWord -= 1 (under the mutex)
    //   131. W0 collect [0] carried set folded
    //   132. W0 collect [0] entry sweep done; carried := {}
    //   133. W0 collect [0] s = E, E := 3 (seq_cst fetch_add); epoch[W0] := 3 (release)
    //   134. W0 collect [0] epoch wait: epoch[W0] (acquire) -> 3
    //   135. W0 collect [0] epoch wait: epoch[W1] (acquire) -> quiescent
    //   136. W0 collect [0] every epoch word > 2
    //   137. W0 collect [0] old eden and survivor-from may be reused
    //   138. W0 drain: epoch[W0] = 3 (release store becomes visible)
    //   139. W0 collect [0] deferred H: exchange rem 0 (seq_cst) -> was 0: entry freed
    @Test func claim5AFullCollectionThatFreesADeferredEntryFreesItTwice() {
        var c = Configuration.ownership([.fullCollection])
        c.deferredEntriesBelongToTheirNursery = false
        expectViolation("deferred entry freed by a full collection", c, .oneOwnerPerEntry)
    }

    // Found by the explorer (shortest interleaving, breadth-first), "relaxed remembered-word load, no post-store reload":
    //
    // claim 1 no lost object violated: W collect frees X, which a worker can still reach
    //   1. W collect: opens nursery 0's collection (collecting[0] := 1, barrierWord += 1, Y = {X})
    //   2. M poll: E (acquire) -> 0, epoch[M] := 0 (release)
    //   3. A poll: E (acquire) -> 0, epoch[A] := 0 (release)
    //   4. A r0 := G.s0: G.s0 (relaxed) -> nil
    //   5. A poll: E (acquire) -> 0, epoch[A] := 0 (release)
    //   6. A drop r0: r0 := nil
    //   7. M drain: epoch[M] = 0 (release store becomes visible)
    //   8. A drain: epoch[A] = 0 (release store becomes visible)
    //   9. A drain: epoch[A] = 0 (release store becomes visible)
    //   10. A leaveVM: epoch[A] := quiescent, leaves the VM, holds nothing (under the mutex)
    //   11. W collect [0] opens H0 (round 1, need 2); A by proxy
    //   12. W collect [0] acknowledges H0 of nursery 0; E (acquire) -> 0, epoch[W] := 0 (release)
    //   13. M poll: acknowledges H0 of nursery 0
    //   14. W collect [0] H0 complete
    //   15. W drain: epoch[W] = 0 (release store becomes visible)
    //   16. W collect [0] opens H1 (round 2, need 2); A by proxy
    //   17. W collect [0] acknowledges H1 of nursery 0: stack scan finds {}; E (acquire) -> 0, epoch[W] := 0 (release)
    //   18. M poll: acknowledges H1 of nursery 0: stack scan finds {X}
    //   19. W collect [0] H1 complete; T1, carried {G}
    //   20. W collect [0] new half scanned
    //   21. M poll: E (acquire) -> 0, epoch[M] := 0 (release)
    //   22. M store G.s0 := r0: barrierWord (relaxed) -> 1: barriers on
    //   23. M store G.s0 := r0: old G.s0 (relaxed) -> nil
    //   24. M store G.s0 := r0: G.s0 := X (seq_cst)
    //   25. M store G.s0 := r0: rem[G] (relaxed) -> member 0: already remembered
    //   26. M drop r0: r0 := nil
    //   27. W drain: epoch[W] = 0 (release store becomes visible)
    //   28. W collect [0] scanHolder G: fetch_and rem (seq_cst) -> was member 0, fence
    //   29. W collect [0] scanHolder G: header (relaxed) -> 1 slot
    //   30. W collect [0] scanHolder G: s0 (relaxed) -> nil
    //   31. W collect [0] scanHolder G: names nothing in nursery 0: not kept
    //   32. W collect [0] carried holders scanned
    //   33. W collect [0] takes handed: roots {X}, rem {}, del {}
    //   34. W collect [0] visits root X, copies X
    //   35. W collect [0] stack roots visited
    //   36. W collect [0] remembered holders scanned
    //   37. W collect [0] deletion records visited
    //   38. W collect [0] gray stack empty
    //   39. W collect [0] T1 done: another drain round
    //   40. M drain: epoch[M] = 0 (release store becomes visible)
    //   41. M drain: G.s0 = X (seq_cst store becomes visible)
    //   42. M leaveVM: epoch[M] := quiescent, leaves the VM, holds nothing (under the mutex)
    //   43. W collect [0] opens drain (round 3, need 1); M by proxy; A by proxy
    //   44. W collect [0] acknowledges drain of nursery 0; E (acquire) -> 0, epoch[W] := 0 (release)
    //   45. W collect [0] drain round complete
    //   46. W drain: epoch[W] = 0 (release store becomes visible)
    //   47. W collect [0] takes handed: roots {}, rem {}, del {}
    //   48. W collect [0] stack roots visited
    //   49. W collect [0] remembered holders scanned
    //   50. W collect [0] deletion records visited
    //   51. W collect [0] gray stack empty
    //   52. W collect [0] stops marking: the round copied nothing
    //   53. W collect [0] finish: collecting[0] := 0, barrierWord -= 1 (under the mutex)
    //   54. W collect [0] carried set folded
    //   55. W collect [0] sweep: X survives
    //   56. W collect [0] entry sweep done; carried := {}
    //   57. W collect [0] s = E, E := 1 (seq_cst fetch_add); epoch[W] := 1 (release)
    //   58. W collect [0] epoch wait: epoch[W] (acquire) -> 1
    //   59. W collect [0] epoch wait: epoch[M] (acquire) -> quiescent
    //   60. W collect [0] epoch wait: epoch[A] (acquire) -> quiescent
    //   61. W collect [0] every epoch word > 0
    //   62. W collect [0] old eden and survivor-from may be reused
    //   63. W collect [0] deferred frees done
    //   64. W drain: epoch[W] = 1 (release store becomes visible)
    //   65. W collect [0] collection done
    //   66. W collect: opens nursery 0's collection (collecting[0] := 1, barrierWord += 1, Y = {X})
    //   67. W collect [0] opens H0 (round 4, need 1); M by proxy; A by proxy
    //   68. W collect [0] acknowledges H0 of nursery 0; E (acquire) -> 1, epoch[W] := 1 (release)
    //   69. W collect [0] H0 complete
    //   70. W drain: epoch[W] = 1 (release store becomes visible)
    //   71. W collect [0] opens H1 (round 5, need 1); M by proxy; A by proxy
    //   72. W collect [0] acknowledges H1 of nursery 0: stack scan finds {}; E (acquire) -> 1, epoch[W] := 1 (release)
    //   73. W collect [0] H1 complete; T1, carried {}
    //   74. W collect [0] new half scanned
    //   75. W collect [0] carried holders scanned
    //   76. W drain: epoch[W] = 1 (release store becomes visible)
    //   77. W collect [0] takes handed: roots {}, rem {}, del {}
    //   78. W collect [0] stack roots visited
    //   79. W collect [0] remembered holders scanned
    //   80. W collect [0] deletion records visited
    //   81. W collect [0] gray stack empty
    //   82. W collect [0] T1 done: another drain round
    //   83. W collect [0] opens drain (round 6, need 1); M by proxy; A by proxy
    //   84. W collect [0] acknowledges drain of nursery 0; E (acquire) -> 1, epoch[W] := 1 (release)
    //   85. W collect [0] drain round complete
    //   86. W drain: epoch[W] = 1 (release store becomes visible)
    //   87. W collect [0] takes handed: roots {}, rem {}, del {}
    //   88. W collect [0] stack roots visited
    //   89. W collect [0] remembered holders scanned
    //   90. W collect [0] deletion records visited
    //   91. W collect [0] gray stack empty
    //   92. W collect [0] stops marking: the round copied nothing
    //   93. W collect [0] finish: collecting[0] := 0, barrierWord -= 1 (under the mutex)
    //   94. W collect [0] carried set folded
    //   95. W collect [0] sweep: X dead: entry freed
    @Test func claim6WithARelaxedRememberedWordLoadAHolderIsLost() {
        var c = Configuration.remembered()
        c.rememberLoadOrder = .relaxed
        c.postStoreReload = false
        c.terminationCheck = false
        expectViolation("relaxed remembered-word load, no post-store reload", c, .noLostObject)
    }

    // Found by the explorer (shortest interleaving, breadth-first), "no new-half scan, no snoop":
    //
    // claim 1 no lost object violated: C frees X, which a worker can still reach
    //   1. W flip: opens nursery 0's collection (collecting[0] := 1, barrierWord += 1, Y = {X}), flips to the other eden half, queues it for C
    //   2. W r1 := alloc N: N young in nursery 0, new half
    //   3. W store r1.s0 := r0: barrierWord (relaxed) -> 1: barriers on
    //   4. W store r1.s0 := r0: old N.s0 (relaxed) -> nil
    //   5. W store r1.s0 := r0: N.s0 := X (seq_cst)
    //   6. C takes nursery 0's collection from the queue
    //   7. C [0] opens H0 (round 1, need 2)
    //   8. A poll: acknowledges H0 of nursery 0
    //   9. W drain: N.s0 = X (seq_cst store becomes visible)
    //   10. W store r1.s0 := r0: post-store check: offset[N] (seq_cst) unchanged
    //   11. W store r1.s0 := r0: no insertion barrier (X not young in another nursery than N)
    //   12. W store G.s0 := r1: barrierWord (relaxed) -> 1: barriers on
    //   13. W store G.s0 := r1: old G.s0 (relaxed) -> nil
    //   14. W store G.s0 := r1: G.s0 := N (seq_cst)
    //   15. W drain: G.s0 = N (seq_cst store becomes visible)
    //   16. W store G.s0 := r1: post-store check: offset[G] (seq_cst) unchanged
    //   17. W store G.s0 := r1: rem[G] (seq_cst) -> 0
    //   18. W store G.s0 := r1: fetch_or rem[G] member 0 (seq_cst) -> was 0: rem[0] += G
    //   19. W drop r0: r0 := nil
    //   20. W drop r1: r1 := nil
    //   21. W poll: acknowledges H0 of nursery 0
    //   22. C [0] H0 complete
    //   23. C [0] opens H1 (round 2, need 2)
    //   24. W poll: acknowledges H1 of nursery 0: stack scan finds {}, publishes rem {G}, records new half {N}
    //   25. A poll: acknowledges H1 of nursery 0: stack scan finds {}
    //   26. C [0] H1 complete; T1, carried {}
    //   27. C [0] new half scanned
    //   28. C [0] carried holders scanned
    //   29. C [0] takes handed: roots {}, rem {G}, del {}
    //   30. C [0] stack roots visited
    //   31. C [0] scanHolder G: fetch_and rem (seq_cst) -> was member 0, fence
    //   32. C [0] scanHolder G: header (relaxed) -> 1 slot
    //   33. C [0] scanHolder G: s0 (relaxed) -> N
    //   34. C [0] scanHolder G: names Y_0: keepForNext, fetch_or rem pending 0 (seq_cst) -> was 0
    //   35. C [0] remembered holders scanned
    //   36. C [0] deletion records visited
    //   37. C [0] gray stack empty
    //   38. C [0] T1 done: another drain round
    //   39. C [0] opens drain (round 3, need 2)
    //   40. W poll: acknowledges drain of nursery 0
    //   41. A poll: acknowledges drain of nursery 0
    //   42. C [0] drain round complete
    //   43. C [0] takes handed: roots {}, rem {}, del {}
    //   44. C [0] stack roots visited
    //   45. C [0] remembered holders scanned
    //   46. C [0] deletion records visited
    //   47. C [0] gray stack empty
    //   48. C [0] stops marking: the round copied nothing
    //   49. C [0] finish: collecting[0] := 0, barrierWord -= 1 (under the mutex)
    //   50. C [0] foldCarried G: fetch_or member 0, fetch_and ~pending 0: was pending 0
    //   51. C [0] carried set folded
    //   52. C [0] sweep: X dead: entry freed
    @Test func claim7WithoutNewHalfScanAndSnoopTheValueIsLost() {
        var c = Configuration.newHalf()
        c.newHalfScan = false
        c.snoop = false
        c.terminationCheck = false
        expectViolation("no new-half scan, no snoop", c, .noLostObject)
    }
}

// MARK: - probes and findings

/// What the model says beyond the brief's switches (docs "What the model
/// found").
@Suite struct Probes {
    /// The relaxed remembered-word load alone does not fail here: the
    /// interpreter store's post-store check reloads the offset word with
    /// seq_cst between the store and the barrier, and in this model (as on
    /// ARMv8) a later load cannot pass it. C++ does not promise that.
    @Test func aRelaxedRememberedWordLoadIsOrderedByThePostStoreReload() {
        var c = Configuration.remembered()
        c.rememberLoadOrder = .relaxed
        holds(check("relaxed remembered-word load", c))
    }

    /// SPEC point 2's argument on its own: a seq_cst store and a seq_cst
    /// load, no reload in between.
    @Test func theSeqCstStoreAndLoadAloneKeepTheHolder() {
        var c = Configuration.remembered()
        c.postStoreReload = false
        holds(check("no post-store reload", c))
    }

    // Found by the explorer (shortest interleaving, breadth-first), "arrayCopy store":
    //
    // claim 1 no lost object violated: W collect frees X, which a worker can still reach
    //   1. W collect: opens nursery 0's collection (collecting[0] := 1, barrierWord += 1, Y = {X})
    //   2. M poll: E (acquire) -> 0, epoch[M] := 0 (release)
    //   3. A poll: E (acquire) -> 0, epoch[A] := 0 (release)
    //   4. A r0 := G.s0: G.s0 (relaxed) -> nil
    //   5. A poll: E (acquire) -> 0, epoch[A] := 0 (release)
    //   6. A drop r0: r0 := nil
    //   7. M drain: epoch[M] = 0 (release store becomes visible)
    //   8. A drain: epoch[A] = 0 (release store becomes visible)
    //   9. A drain: epoch[A] = 0 (release store becomes visible)
    //   10. A leaveVM: epoch[A] := quiescent, leaves the VM, holds nothing (under the mutex)
    //   11. W collect [0] opens H0 (round 1, need 2); A by proxy
    //   12. W collect [0] acknowledges H0 of nursery 0; E (acquire) -> 0, epoch[W] := 0 (release)
    //   13. M poll: acknowledges H0 of nursery 0
    //   14. W collect [0] H0 complete
    //   15. W drain: epoch[W] = 0 (release store becomes visible)
    //   16. W collect [0] opens H1 (round 2, need 2); A by proxy
    //   17. W collect [0] acknowledges H1 of nursery 0: stack scan finds {}; E (acquire) -> 0, epoch[W] := 0 (release)
    //   18. M poll: acknowledges H1 of nursery 0: stack scan finds {X}
    //   19. W collect [0] H1 complete; T1, carried {G}
    //   20. W collect [0] new half scanned
    //   21. M poll: E (acquire) -> 0, epoch[M] := 0 (release)
    //   22. M arrayCopy G.s0 := r0: barrierWord (relaxed) -> 1: barriers on
    //   23. M arrayCopy G.s0 := r0: old G.s0 (relaxed) -> nil
    //   24. M arrayCopy G.s0 := r0: G.s0 := X (relaxed)
    //   25. M arrayCopy G.s0 := r0: rem[G] (seq_cst) -> member 0: already remembered
    //   26. M drop r0: r0 := nil
    //   27. W drain: epoch[W] = 0 (release store becomes visible)
    //   28. W collect [0] scanHolder G: fetch_and rem (seq_cst) -> was member 0, fence
    //   29. W collect [0] scanHolder G: header (relaxed) -> 1 slot
    //   30. W collect [0] scanHolder G: s0 (relaxed) -> nil
    //   31. W collect [0] scanHolder G: names nothing in nursery 0: not kept
    //   32. W collect [0] carried holders scanned
    //   33. W collect [0] takes handed: roots {X}, rem {}, del {}
    //   34. W collect [0] visits root X, copies X
    //   35. W collect [0] stack roots visited
    //   36. W collect [0] remembered holders scanned
    //   37. W collect [0] deletion records visited
    //   38. W collect [0] gray stack empty
    //   39. W collect [0] T1 done: another drain round
    //   40. M drain: epoch[M] = 0 (release store becomes visible)
    //   41. M drain: G.s0 = X (relaxed store becomes visible)
    //   42. M leaveVM: epoch[M] := quiescent, leaves the VM, holds nothing (under the mutex)
    //   43. W collect [0] opens drain (round 3, need 1); M by proxy; A by proxy
    //   44. W collect [0] acknowledges drain of nursery 0; E (acquire) -> 0, epoch[W] := 0 (release)
    //   45. W collect [0] drain round complete
    //   46. W drain: epoch[W] = 0 (release store becomes visible)
    //   47. W collect [0] takes handed: roots {}, rem {}, del {}
    //   48. W collect [0] stack roots visited
    //   49. W collect [0] remembered holders scanned
    //   50. W collect [0] deletion records visited
    //   51. W collect [0] gray stack empty
    //   52. W collect [0] stops marking: the round copied nothing
    //   53. W collect [0] finish: collecting[0] := 0, barrierWord -= 1 (under the mutex)
    //   54. W collect [0] carried set folded
    //   55. W collect [0] sweep: X survives
    //   56. W collect [0] entry sweep done; carried := {}
    //   57. W collect [0] s = E, E := 1 (seq_cst fetch_add); epoch[W] := 1 (release)
    //   58. W collect [0] epoch wait: epoch[W] (acquire) -> 1
    //   59. W collect [0] epoch wait: epoch[M] (acquire) -> quiescent
    //   60. W collect [0] epoch wait: epoch[A] (acquire) -> quiescent
    //   61. W collect [0] every epoch word > 0
    //   62. W collect [0] old eden and survivor-from may be reused
    //   63. W collect [0] deferred frees done
    //   64. W drain: epoch[W] = 1 (release store becomes visible)
    //   65. W collect [0] collection done
    //   66. W collect: opens nursery 0's collection (collecting[0] := 1, barrierWord += 1, Y = {X})
    //   67. W collect [0] opens H0 (round 4, need 1); M by proxy; A by proxy
    //   68. W collect [0] acknowledges H0 of nursery 0; E (acquire) -> 1, epoch[W] := 1 (release)
    //   69. W collect [0] H0 complete
    //   70. W drain: epoch[W] = 1 (release store becomes visible)
    //   71. W collect [0] opens H1 (round 5, need 1); M by proxy; A by proxy
    //   72. W collect [0] acknowledges H1 of nursery 0: stack scan finds {}; E (acquire) -> 1, epoch[W] := 1 (release)
    //   73. W collect [0] H1 complete; T1, carried {}
    //   74. W collect [0] new half scanned
    //   75. W collect [0] carried holders scanned
    //   76. W drain: epoch[W] = 1 (release store becomes visible)
    //   77. W collect [0] takes handed: roots {}, rem {}, del {}
    //   78. W collect [0] stack roots visited
    //   79. W collect [0] remembered holders scanned
    //   80. W collect [0] deletion records visited
    //   81. W collect [0] gray stack empty
    //   82. W collect [0] T1 done: another drain round
    //   83. W collect [0] opens drain (round 6, need 1); M by proxy; A by proxy
    //   84. W collect [0] acknowledges drain of nursery 0; E (acquire) -> 1, epoch[W] := 1 (release)
    //   85. W collect [0] drain round complete
    //   86. W drain: epoch[W] = 1 (release store becomes visible)
    //   87. W collect [0] takes handed: roots {}, rem {}, del {}
    //   88. W collect [0] stack roots visited
    //   89. W collect [0] remembered holders scanned
    //   90. W collect [0] deletion records visited
    //   91. W collect [0] gray stack empty
    //   92. W collect [0] stops marking: the round copied nothing
    //   93. W collect [0] finish: collecting[0] := 0, barrierWord -= 1 (under the mutex)
    //   94. W collect [0] carried set folded
    //   95. W collect [0] sweep: X dead: entry freed
    /// Finding: `primArrayCopy` stores with a relaxed store and no post-store
    /// check, so the remembered-word load (seq_cst) can pass the store and
    /// the holder drops out of the remembered set; the next collection
    /// frees what only that holder names.
    @Test func theArrayCopyStoreLosesARememberedHolder() {
        var c = Configuration.remembered(copyStore: true)
        c.terminationCheck = false
        expectViolation("arrayCopy store", c, .noLostObject)
    }

    /// Either half of amendment 7 alone covers a barriered store.
    @Test func theNewHalfScanAloneSuffices() {
        var c = Configuration.newHalf()
        c.snoop = false
        holds(check("new half, scan only", c))
        c = .newHalf(initialising: true)
        c.snoop = false
        holds(check("new half, initialising store, scan only", c))
    }

    @Test func theSnoopAloneCoversABarrieredStore() {
        var c = Configuration.newHalf()
        c.newHalfScan = false
        holds(check("new half, snoop only", c))
    }

    // Found by the explorer (shortest interleaving, breadth-first), "initialising store, snoop only":
    //
    // claim 1 no lost object violated: C frees X, which a worker can still reach
    //   1. W flip: opens nursery 0's collection (collecting[0] := 1, barrierWord += 1, Y = {X}), flips to the other eden half, queues it for C
    //   2. W r1 := alloc N with s0 := r0: N young in nursery 0, new half, s0 := X (relaxed, no barrier)
    //   3. W store G.s0 := r1: barrierWord (relaxed) -> 1: barriers on
    //   4. W store G.s0 := r1: old G.s0 (relaxed) -> nil
    //   5. W store G.s0 := r1: G.s0 := N (seq_cst)
    //   6. C takes nursery 0's collection from the queue
    //   7. C [0] opens H0 (round 1, need 2)
    //   8. A poll: acknowledges H0 of nursery 0
    //   9. W drain: N.s0 = X (relaxed store becomes visible)
    //   10. W drain: G.s0 = N (seq_cst store becomes visible)
    //   11. W store G.s0 := r1: post-store check: offset[G] (seq_cst) unchanged
    //   12. W store G.s0 := r1: rem[G] (seq_cst) -> 0
    //   13. W store G.s0 := r1: fetch_or rem[G] member 0 (seq_cst) -> was 0: rem[0] += G
    //   14. W drop r0: r0 := nil
    //   15. W drop r1: r1 := nil
    //   16. W poll: acknowledges H0 of nursery 0
    //   17. C [0] H0 complete
    //   18. C [0] opens H1 (round 2, need 2)
    //   19. W poll: acknowledges H1 of nursery 0: stack scan finds {}, publishes rem {G}, records new half {N}
    //   20. A poll: acknowledges H1 of nursery 0: stack scan finds {}
    //   21. C [0] H1 complete; T1, carried {}
    //   22. C [0] new half scanned
    //   23. C [0] carried holders scanned
    //   24. C [0] takes handed: roots {}, rem {G}, del {}
    //   25. C [0] stack roots visited
    //   26. C [0] scanHolder G: fetch_and rem (seq_cst) -> was member 0, fence
    //   27. C [0] scanHolder G: header (relaxed) -> 1 slot
    //   28. C [0] scanHolder G: s0 (relaxed) -> N
    //   29. C [0] scanHolder G: names Y_0: keepForNext, fetch_or rem pending 0 (seq_cst) -> was 0
    //   30. C [0] remembered holders scanned
    //   31. C [0] deletion records visited
    //   32. C [0] gray stack empty
    //   33. C [0] T1 done: another drain round
    //   34. C [0] opens drain (round 3, need 2)
    //   35. W poll: acknowledges drain of nursery 0
    //   36. A poll: acknowledges drain of nursery 0
    //   37. C [0] drain round complete
    //   38. C [0] takes handed: roots {}, rem {}, del {}
    //   39. C [0] stack roots visited
    //   40. C [0] remembered holders scanned
    //   41. C [0] deletion records visited
    //   42. C [0] gray stack empty
    //   43. C [0] stops marking: the round copied nothing
    //   44. C [0] finish: collecting[0] := 0, barrierWord -= 1 (under the mutex)
    //   45. C [0] foldCarried G: fetch_or member 0, fetch_and ~pending 0: was pending 0
    //   46. C [0] carried set folded
    //   47. C [0] sweep: X dead: entry freed
    /// The snoop is in the store barrier, so it cannot see an allocation's
    /// initialising store: only the new-half scan covers that.
    @Test func theSnoopAloneMissesAnInitialisingStore() {
        var c = Configuration.newHalf(initialising: true)
        c.newHalfScan = false
        c.terminationCheck = false
        expectViolation("initialising store, snoop only", c, .noLostObject)
    }

    /// Claim 2's negative with store buffers as well.
    @Test func aSingleRoundAlsoFailsWithStoreBuffers() {
        var c = Configuration.local
        c.barrierOnRound = false
        expectViolation("single round", c, .soundTermination)
    }
}

// MARK: - the memory-model extension

@Suite struct SequentiallyConsistentMemory {
    /// Store buffering (Dekker) is impossible without buffers: a store is
    /// visible before the thread's next step.
    @Test func storesAreVisibleAtOnce() {
        var m = Memory(words: [0, 0], threads: 2, sequentiallyConsistent: true)
        m.store(0, 0, 1, .relaxed)
        #expect(m.isDrained(0))
        #expect(m.load(1, 0, .relaxed) == 1)
        #expect(m.drainable(0).isEmpty)
    }

    @Test func readModifyWriteWaitsForTheBuffer() {
        var m = Memory(words: [0], threads: 1)
        m.store(0, 0, 1, .release)
        #expect(m.readModifyWrite(0, 0, { $0 + 1 }) == nil)
        _ = m.drain(0, 0)
        #expect(m.readModifyWrite(0, 0, { $0 + 1 }) == 1)
        #expect(m.words[0] == 2)
    }
}
