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

### Step 2: minimise

A scratch copy of the test with knobs from the environment
(`Tests/VMRTests/DiagMinTests.swift`, removed after the diagnosis): number
of Processes and workers, iterations, Array size, the Semaphore around
publication, publication into the shared old Array, linking the
neighbour's published Array into the own list (else the own Array), the
fill loop. No final walk. 40 runs per row, 4 copies at once + 12 `yes`,
`local`.

| variant | failed |
|---|---|
| as the test (8 Processes, 8 workers, 3000 iterations, 32 Pairs) | 6 of 40 |
| no neighbour link | 4 of 40 |
| no Semaphore | 22 of 40 |
| no fill (empty Arrays; 32 instead of 125 collections) | 1 of 40 |
| 4 Processes, 4 workers | 3 of 40 |
| 2 Processes, 2 workers | 0 of 40 |
| 1000 iterations | 1 of 40 |
| no Semaphore, no link | 0 of 40 (and 0 of 20 again) |
| no Semaphore, no link, no publication | 0 of 40 |
| no Semaphore, 2 Processes, 2 workers | 0 of 40 |
| no Semaphore, no link, no publication, 1 Process, 1 worker | 0 of 40 |
| no Semaphore, no link, no publication, 8 Processes on 2 workers | 0 of 40 |

(The last five rows and a repeat of "no Semaphore", 8 of 20, ran with the
step 4 instrumentation compiled in; it touches only rare paths.)

Smallest program that still fails often: **8 Processes on 8 workers, each
allocating young Arrays of 32 Pairs, publishing each into a shared old
Array and linking the neighbour's into its own young list, no Semaphore**
(22 of 40). The Semaphore is not needed; it only slows the program and
makes failures rarer. What removes the failure: removing cross-nursery
young-to-young references (no link and no Semaphore), or fewer than 4
workers (fewer overlapping local collections), or fewer collections. The
clue: the failure needs overlapping local collections of different
nurseries *and* young holders remembered for another nursery. With the
Semaphore but no link it still fails (4 of 40): Processes that wait and
resume on another worker make their own list nodes cross-nursery holders.
Neither the Semaphore nor the parallel scavenge is involved.

### Step 3: hypotheses (written before any instrumentation output)

The message says: entry E was in the marking snapshot (`used` minus the
young logs at the initial-mark pause), is reachable at the final mark, and
was never marked. `verify young: reachable entry is free` says a reachable
object's `used` bit is clear. Only `local` fails.

- **H1, lost claim between two parallel scavengers** (the brief's first
  candidate). Unlikely: the failing mode never runs the parallel scavenge
  except as a fallback, and `stw` passed 40 of 40. Would show as a verifier
  message from `Scavenge.swift`, not from `verifyMarks`.
- **H2, a Process root scanned twice or not at all (`claimParked`).** A
  local-collection rule; a miss there loses a young object (young verifier,
  checksum), not an old snapshot entry. Does not explain the mark message.
- **H3, a remembered-list entry naming a freed entry.** Related to H6 below:
  the deferred-free machinery (amendment 10) exists because lists can name
  dead holders.
- **H4, `result` or another interpreter register not a root.** The
  snapshot's roots are the stop's root ranges; a value only in a register
  across a pause would be lost under `stw` too.
- **H5, the verifier reads state a late participant still writes.**
  `verifyMarks` runs in the final-mark pause, world stopped, no young
  collection in progress (stops wait for `ycActive == 0`), markers parked.
  Unlikely.
- **H6, a deferred dead young entry becomes a snapshot entry.** A dead
  young remembered holder's free is deferred to step 6 of its collection;
  if its `rem` word was re-armed meanwhile (another nursery's concurrent
  collection scanning it from a stale list), the free waits for the
  nursery's *next* collection (amendment 10). Until then the entry is used,
  dead, and in no young log. An initial-mark pause in between therefore puts
  it in the snapshot (unmarked, it is dead). The next local collection of
  that nursery, during marking, frees it; any worker can reallocate it for a
  new object (a Pair: class 14). That object is reachable, in the snapshot,
  unmarked: exactly the message. The lazy sweep then frees every unmarked
  snapshot entry, so the live object's entry is freed under it: the
  `verify young` message, and a real lost object. Predicts: the missed
  entry has a `deferKept` event before the cycle's initial mark, then a
  `deferFree` and a `reallocSnap` during marking. Contention fits: a re-arm
  needs one collection to be descheduled between its fetch_and on a holder
  and its `keepForNext`, while the owner's collection sweeps the holder;
  Processes migrating between workers (after a wait or a preemption) make
  their own list nodes cross-nursery holders, so dead remembered holders
  are common. `stw` never defers.
- **H7, the young-root scan misses a young body** (a stale `nurseryTop` or
  survivor top at the pause, or the linear walk stopping at a hole). An old
  object named only by that body is never greyed. Predicts: the missed
  entry was old at the snapshot and never freed or reallocated.
- **H8, the SATB barrier's young-holder skip racing a promotion.** A store
  into a holder whose header still reads young while a local collector
  promotes it. By the snapshot argument (Part 3) the overwritten value is
  grey or recorded elsewhere; listed for completeness.

Instrumentation planned (step 4) separates H6 from H7: a ring of events
(`mach_absolute_time`, worker, entry) for initial and final marks, deferred
pushes, kept and frees, local-sweep frees of snapshot entries during
marking, and entry refills that hand out snapshot entries during marking,
dumped for each entry the mark verifier reports.
