# Module 5: concurrent marking and lazy sweep of old space

Status: brief (2026-11-02). Becomes the description of the module as built.
Starts after module 4 is built; its agent must read `docs/modules/nursery.md`
as built first, because the entry-freeing representation and the barrier
layout chosen there decide two things here.

Decisions it implements: ADR 0006 (snapshot-at-the-beginning marking on one
marker thread, marks in a byte map, lazy sweep published at the next pause,
fallback to stop-the-world counted as a provisioning failure) with its
amendments (snapshot at the end of a scavenge; survivor spaces are roots,
ADR 0007; marker at utility by default, raised when headroom shrinks; the
marker waits untimed, experiments/power), and ADR 0009 section 1 for the
marker (weak slots untraced and nil'ed, ephemerons by the key rule).

Evidence: `experiments/concurrent-marking/` (SPEC.md: side tables, SATB
barrier and buffer protocol, phases, triggers, verifier, test switches;
RESULTS.md sections 6 to 8), `experiments/concurrent-young/SPEC.md`
"Barriers" (the flag word and the shape of the out-of-line store) and Part 3
(what module 7 will change about the initial mark, so that it stays behind
this module), `experiments/power/RESULTS.md` and ADR 0006's device and
energy sections (QoS policy, idle wait), the amendment-18 audit in
experiments/concurrent-young (commit c8a77da) for the untimed wait.

Ports into `Sources/KajoVM/Marking/`. Tests in `Tests/KajoVMTests/Marking/`.

## What it hides

- When an old-space cycle starts, how long it runs, and on which thread.
- What the marker reads, what it never reads (young headers), and how the
  barrier keeps the snapshot intact.
- How dead old entries and blocks are returned, and when allocators see them.
- The marker's QoS and when it changes.
- What happens when old space fills before a cycle ends.

## What is and is not decided

**Decided by the ADRs**: SATB with a deletion barrier; the snapshot is taken
in a pause at the end of a stop-the-world scavenge of every nursery with
survivors scanned as roots, so that nothing young is a snapshot entry; one
marker thread; marks in a byte map beside the table, never in the header;
objects promoted during marking are black by not being snapshot entries;
lazy sweep in the background with results applied at the next pause; the
final mark is its own pause requested by the marker; fallback to module 1's
stop-the-world collection when old space fills, counted, reported, never
hidden; marker QoS utility by default, user-initiated while old-space
headroom is below a threshold; the marker waits untimed; the verifier that
redoes the mark at the final pause stays in the suite and in the checked
build.

**Decided here, open to change behind the module**:

- **The snapshot set.** The marker and barrier need, in O(1) per oop, "was
  this entry an old object at the snapshot"; the sweep needs to enumerate
  exactly those entries; and no snapshot entry may be freed or reused before
  the sweep. The experiments used a `used` bitmap copied at the snapshot. If
  module 4 chose chunk bitmaps for entry freeing, copy them below the high
  water mark. If it kept module 1's free lists, add a used bitmap maintained
  by the allocator (one bit set per entry allocation, cleared by the sweeps)
  or argue for allocate-black with a block walk and show the sweep is still
  bounded by live bytes. Decide and record; the pause cost of taking the
  snapshot must be O(table words), never O(entries) or O(bodies).
- **Mark map**: module 1 already marks in a side byte map at a stop. One
  map, one invariant (outside a cycle every byte is zero), used by the
  oracle and the concurrent marker in turn, since only one of them marks at
  a time. Say so where the map is allocated.
- **Barrier fast path in concurrent-young's shape**: one relaxed load of a
  VM-wide flag word before the store; nonzero sends the store to one
  out-of-line `storeWithBarriers(w, o, i, v)` that records the SATB value,
  stores, and runs module 4's insertion barrier; zero takes module 4's path
  unchanged. Bit 0 of the word is "marking"; module 7 adds its bits without
  touching the fast path. Instruction count recorded for `store_ivar`,
  `at:put:` and the VM-internal store; the slow path is one call with
  nothing of the instruction live across it (the 20 percent lesson).
- **SATB slow path**: return if the holder is young; return if the old value
  is not a reference, not a snapshot entry, or already marked; else push it
  on the worker's 512-oop buffer, hand full buffers to the marker under the
  marking lock (a leaf lock, may be taken under the scheduler lock).
- **Slot stores are relaxed atomics** and marker slot reads relaxed atomic
  loads (plain `str`/`ldr` on arm64); initialising stores into fresh young
  objects stay plain. Module 1's `store` changes accordingly; arc-check
  confirms the instruction sequence is unchanged.
- **The marker is a VM participant**: it enters the VM to work, polls the
  stop flag every 128 traced objects and between queue items, parks without
  taking scavenge work, and leaves the VM to wait when idle. Its wait is
  untimed unless a later module gives it a legitimate timer; every
  transition it waits for signals the condition under the lock, and the
  audit is in the module doc.
- **Final mark**: the marker requests a stop through module 3's protocol;
  with the world stopped it drains every worker's partial buffer, every
  queued item and its own stack, filters dead holders out of the remembered
  set, processes ephemerons (below), nils weak slots, runs the verifier in
  checked builds, then sets the phase to sweeping.
- **Weak slots and ephemerons**: the marker does not trace weak slots; while
  tracing it appends every weak holder and every ephemeron it marks to two
  lists. At the final mark: ephemerons whose key is marked have their other
  slots traced (to a fixpoint, since tracing can mark another key); the rest
  are queued to the finalization Semaphore and their other slots traced
  after, with the key kept alive this cycle; then every weak slot naming an
  unmarked snapshot entry becomes nil. The pause cost is bounded by the
  number of weak holders and ephemerons and is a counter.
- **Lazy sweep** by the marker thread after the final mark: snapshot
  entries unmarked are freed (entries, and the block when nothing live
  remains), results published at the next pause of any kind (apply). If no
  pause comes, the sweeper requests a short apply pause itself. Allocation
  never waits for a sweep; promotion uses module 4's reserve.
- **Triggers**: a cycle starts at the end of a scavenge when old space in
  use is above a floor fraction of the soft limit or when the predicted time
  to fill (promotion rate over the last scavenges times the last cycle's
  duration, with a safety factor) says the next cycle would not finish in
  time. A fixed percentage alone was shown not to be a lever; record what
  the predictor does on the matrix.
- **Fallback**: a scavenge that leaves old space over the soft limit while a
  cycle is running or idle requests module 1's full collection in its own
  pause (module 4's rule); the cycle is aborted (phase idle, marking flags
  off, buffers and queue discarded, mark map cleared). Counted and reported
  with its pause in every benchmark line.
- **QoS policy**: the marker thread starts at utility and is raised to
  user-initiated by `pthread_set_qos_class_self_np` from the marker itself
  at its next poll when old-space headroom falls below a config threshold,
  lowered again when a cycle ends with headroom above it. Escalations are a
  counter; the QoS actually in effect is logged per cycle.
- **Two markers are not built.** The queue and packet shape allow it; a
  second thread, if ever, is the sweeper.

**Not this module**: relocation of old space (6), collecting a nursery
without stopping the world and the initial mark without a global scavenge
(7, concurrent-young Part 3; keep the initial-mark step behind one function
so module 7 replaces it), pacing by mutators, device measurement of the QoS
policy (the escalation itself was never measured; it waits for module 9's
app).

## Design notes the brief insists on

- **The initial mark's roots are exactly module 1's and module 3's full
  root set** plus the survivor spaces of every nursery; the remembered set
  is not a root. Every root word that names a snapshot entry is marked and
  queued.
- **Nothing young is ever read by the marker**: not a header, not a slot.
  The snapshot filter is what guarantees it; the verifier checks that the
  marker never marked a non-snapshot entry.
- **Verifiers**: at every final mark in checked builds and in every test, a
  from-scratch traversal of everything reachable compared with the mark
  set: a reachable unmarked snapshot entry is a bug (count and trap in
  checked builds, record and fall back in release), a marked unreachable
  one is floating garbage (bytes counted). Module 4's scavenge verifier
  keeps running and skips pending-dead entries (snapshot, unmarked, sweep
  not applied) as the experiment's did.
- **Test switches** (never used outside tests): SATB slow path off;
  snapshot without the scavenge (the unsound textbook protocol, so that
  `designLiteralProtocolLosesATargetOfADeadYoungObject` still shows the
  loss); no marker thread, with the test driving start, mark N objects,
  final and sweep from its own thread interleaved with Smalltalk on chosen
  workers.
- **Stress flags**: `cycleAtEveryScavenge`, `markingAlwaysOn` (the barrier
  runs between cycles), `sweepNeverApplies` (to show the fallback), plus
  module 3's `perturb` extended to the marker: yields between queue items,
  at buffer handovers and before the final-mark request.
- **Counters**: cycles, initial-mark pause split (snapshot copy, root scan,
  survivor scan), final-mark pause split (time to safepoint, drain, filter,
  ephemerons, weak nil, verifier), marker CPU and wall time per cycle,
  bytes and objects marked, SATB entries pushed and buffers handed over,
  sweep time and entries and blocks freed, apply time, fallbacks with
  cause, floating garbage bytes, QoS escalations, marker wakeups and
  untimed waits, promotion rate and predicted time to fill at each trigger
  decision.
- **No timed wait anywhere** (`grep timedwait` finds nothing new).

## Tests to port, and tests that wait

Port first, from experiments/concurrent-marking:
`satbKeepsAValueOverwrittenDuringMarking`,
`withoutSATBTheVerifierReportsTheMissedObject`,
`objectsPromotedDuringMarkingSurviveTheCycle`,
`literalProtocolNeedsItsGreyPromotionRule`,
`designLiteralProtocolLosesATargetOfADeadYoungObject`,
`snapshotAfterAScavengeKeepsTheTargetOfAYoungObject`,
`filteringRemovesADeadHolderFromTheRememberedSet`,
`sweepFreesEntriesAndBlocksAndTheyAreReused`,
`oldSpaceFillingDuringACycleFallsBackToAFullCollection`,
`oldheapUnderConcurrentMarkingMatchesStopTheWorld`.

From experiments/concurrent-young's IdleTests: `aParkedVMDoesNotWakeItsMarker`
and `markingCompletesPromptlyAfterIdling`.

New: a weak slot nil'ed at the final mark exactly when its referent died;
an ephemeron whose key is reachable only through it is queued once and its
value traced; an ephemeron whose key is reachable elsewhere is not queued;
the marker never marks a non-snapshot entry (verifier check); QoS escalation
happens when headroom shrinks and is undone when it recovers (observable
through the counter and the logged QoS); the randomized programs agree with
the oracle under `cycleAtEveryScavenge` and `markingAlwaysOn`.

Each rule is checked by breaking it (test switch or hand run); the module
doc says which.

Wait: relocation and frame pins (6), local and offloaded young collection
and the young-root initial mark (7), the 120 Hz scenarios and device QoS
measurement (9).

## Done when

- Tests green in debug, under load, under ThreadSanitizer; `just ios-check`;
  `just arc-check` extended to the barrier fast path with the flag word, the
  SATB slow path, the marker's trace loop and the sweep loop, zero retain
  and release, the dispatch loop still one jump table.
- Barrier cost with marking off at most 3 percent on `ivars` against module
  4's binary, interleaved, five runs, medians and spread; mutator slowdown
  with `markingAlwaysOn` reported on `ivars`, `oldheap` and `alloc` with 1
  and 8 workers.
- The headless matrix of experiments/concurrent-marking re-run here:
  `oldheap` at 64, 256 and 512 MiB of live old data, 1 and 8 workers,
  stop-the-world oracle against concurrent, reporting final-mark p50 and
  max, initial-mark addition to the scavenge, marker CPU per cycle,
  fallbacks, floating garbage. Expected: final mark under 0.2 ms p50 at
  every size with 8 workers and not growing with heap size; the oracle
  growing from about 5 to 80 ms. `alloc` storm with a 64 MiB and a 256 MiB
  old space, fallbacks counted; the marker keeping up with at least 600 MB/s
  of promotion with zero fallbacks given 256 MB of headroom.
- Idle: a parked VM's marker costs under 1 ms of CPU and wakes at most a
  handful of times per second; marking after idling completes within a
  bound.
- Randomized programs: a hundred seeds per configuration in the suite with
  cycles forced at every scavenge, a thousand in `just soak`.
- `docs/modules/concurrent-marking.md` rewritten as built; `docs/CONTEXT.md`
  gains Snapshot, SATB record, Grey, Final mark, Lazy sweep, Apply,
  Fallback, Headroom, Floating garbage; ADR 0006 gets a "Built" note with
  the matrix and the QoS policy as implemented; ADR 0009 section 1 gets the
  marker's ephemeron rule as built.
