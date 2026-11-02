# Diagnosis: parallel stop-the-world scavenge fails its verifier under load

## Symptom

`swift test` in `experiments/power/swift` (three test targets at once, the
Mac otherwise idle) failed
`VMRTests/GenerationalTests.swift: sharedYoungObjectsAreClaimedOnceByParallelScavengers`
in 2 of 2 full-suite runs and 1 of 20 runs alone, with the young-collection
verifier reporting at least one failure (`verifyFailures == 0` not met). In
`experiments/concurrent-young/swift` itself: 0 of 23 alone, 2 of 2 full
suites passed; but the very first full run of that suite during the
concurrent-young experiment showed 72 tests with 3 issues while another
process was loading the machine. The failure needs CPU contention. The
verifier writes `verify: <message>` to stderr for the first ten failures
(`Sources/VMR/Scavenge.swift`, `failure(_:_:)`), so the broken invariant is
in the output of a failing run.

The test runs 8 Processes on 8 workers that publish young Arrays through an
old Array and a Semaphore mutex, link neighbours' young Arrays into their own
lists, with 256 KiB nurseries forcing stop-the-world scavenges with 8
participants. The verifier checks that every reachable young object was
promoted exactly once.

## Why it matters

This is the stop-the-world collector, the oracle every checksum comparison
in ADRs 0007 and 0008 leans on, and `docs/VERIFICATION.md` keeps it as the
oracle for the production core. A schedule-dependent bug in it invalidates
the comparisons until it is understood. It may also be a bug in the test or
the verifier rather than the collector; find out which.

## Method

Follow a disciplined loop and record each step in `DIAGNOSIS-parallel-scavenge.md`
(this file; append sections as you go, commit as you go):

1. **Reproduce** on demand. Build the test, then run it in a loop under
   deliberate CPU contention (for example `yes > /dev/null` on all cores, or
   several copies of the test binary at once, or `swift test` with the other
   targets running) until it fails at least 5 times. Record the failure
   rate per condition and the `verify:` messages verbatim. If it cannot be
   made to fail in 200 attempts under contention, say so and stop.
2. **Minimise.** Reduce the test (fewer workers, fewer iterations, smaller
   nursery, no neighbour linking, no Semaphore) until the smallest program
   still fails. Record what removes the failure; that is a clue.
3. **Hypothesise** from the verifier message and SPEC.md's parallel
   scavenge protocol (claim bit, forwarding, cross-nursery insertion
   barrier, per-Process scan words, remembered lists, hazard slots, epoch
   freeing). Write the candidate hypotheses down before instrumenting.
   Candidates worth checking first: a lost claim between two scavengers
   racing on one young object (the CAS and the forwarding read order), a
   Process root scanned twice or not at all when it parks during the
   handshake (`claimParked`), a remembered-list entry naming a freed entry,
   the `result` register or another interpreter register not scanned, and
   the verifier itself reading state that a late participant is still
   writing.
4. **Instrument** cheaply: counters and a ring buffer of events with
   worker id and `mach_absolute_time`, dumped on verifier failure. Run
   under ThreadSanitizer too (`swift test --sanitize=thread --filter ...`)
   and under contention; report what it says, including nothing.
5. **Fix** the root cause, not the symptom. If the bug is in the test or
   the verifier, fix that and say so plainly. Keep the hot path rules of
   AGENTS.md (no ARC, one out-of-line slow call, `&+` arithmetic).
6. **Regression test**: a test that fails without the fix under the
   reproduction conditions in at least 5 of 20 runs and passes with it in
   50 of 50, plus the full VMRTests suite under contention 5 of 5 and once
   under ThreadSanitizer. Record the numbers.

Also re-run `experiments/power/swift`'s full `swift test` once after the fix
(its VMR is a symlink into this experiment) and report.

## Scope

- Changes only inside `experiments/concurrent-young/` (the fix, the test,
  this file) and, if a SPEC amendment is needed, `SPEC.md` there as
  amendment 17. Nothing in other experiments or docs; the parent writes the
  ADR and AGENTS.md notes.
- Do not change benchmark kernels or results. If the fix changes the
  collector's behaviour in a way that could move a number in RESULTS.md,
  say which and do not re-run the matrix.
- The Mac is free for this; use it. The phone is not needed.
- Commit as you go, small commits; never rewrite history.

## Record

### Step 1: reproduce

Harness: the debug test bundle (`swift build --build-tests`) run through
`swiftpm-testing-helper --testing-library swift-testing --filter
sharedYoungObjectsAreClaimedOnce`, several copies at once, with or without
`yes > /dev/null` hogs. M2 Max class Mac, 12 cores (8 P + 4 E), otherwise idle.

| condition | young mode | failed |
|---|---|---|
| 1 copy at a time, no hogs | `local` (test default) | 0 of 20 |
| 4 copies at once, no hogs | `local` | 4 of 40 |
| 4 copies at once + 12 `yes` | `local` | 10 of 40 (3 of 12 in a first trial) |
| 4 copies at once + 12 `yes` | `stw` (`KAJO_TEST_YOUNG=stw`) | 0 of 40 |
| 4 copies at once + 12 `yes` | `offload` | 0 of 40 |

Verbatim messages (each failing run printed 1 to 7, entries differ per run):

```
verify: concurrent mark missed reachable entry 3317264 (class 14)
verify: concurrent mark missed reachable entry 1771264 (class 14)
verify: concurrent mark missed reachable entry 6446752 (class 14)
verify young: reachable entry 30065 is free
```

30 of the 31 messages are the first; one run printed only the last. Class 14
is `Pair` (the first user class; the base sources define none).

First finding, before any minimisation: **this is not the stop-the-world
scavenge's verifier and not the parallel scavenge.** The test's threaded
runtime runs `KAJO_TEST_YOUNG`, whose default is `local` (Part 1 local
collections), and the message is the concurrent-mark verifier
(`verifyMarks`, Concurrent.swift, at every final mark): an entry that was
in the marking snapshot is reachable at the final mark and unmarked. Under
`stw` (the oracle the brief worries about) the same test under the same
contention passed 40 of 40. The one `verify young` message is the young
verifier finding a reachable object whose entry bit in `used` is clear.
Both name a reachable object whose entry the collector treats as something
else: a snapshot entry it never marked, or a free entry.
