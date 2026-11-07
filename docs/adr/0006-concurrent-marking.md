# ADR 0006: Concurrent marking and lazy sweeping of old space

Date: 2026-11-01
Status: accepted (owner, 2026-11-04, on module 9a's Mac mini and iPhone 13 Pro measurements, `docs/modules/shells.md`)

## Context

ADR 0005 left full collections of old space as the frame-droppers: 5 to 9 ms
on a 64 MiB heap and 40 to 80 ms on a 256 to 512 MiB one, all stop-the-world.
ADR 0004 cannot be accepted until old-space collection has bounded pauses.
`experiments/concurrent-marking/` added snapshot-at-the-beginning marking on
a background thread and lazy sweeping to the generational table VM. See its
RESULTS.md.

## What was measured

Full collection pauses, p50 in milliseconds:

| live old data | stop-the-world, 1 / 8 workers | concurrent final mark, 1 / 8 workers |
|---|---|---|
| 64 MiB | none / 5.5 (max 11) | 0.010 / 0.10 |
| 256 MiB | 33 / 41 | 0.013 / 0.13 |
| 512 MiB | 66 / 80 | 0.010 / 0.13 |

The initial mark rides on a scavenge and adds under 0.05 ms to it. The final
mark's maximum grows only with leftover barrier records: 0.16, 0.59 and
0.95 ms at the three sizes. With 8 workers the pauses are almost entirely
time to safepoint.

Against the 120 Hz window, frames missed of 1200, median of three runs:

| scenario | stop-the-world | concurrent |
|---|---|---|
| alloc storm, 64 MiB old space | 3 | 7, with 87 fallbacks per 10 s |
| 256 MiB heap, slowly mutating | 6, one 40 ms pause per run | 2 with one marker, 0 with two |

Barrier cost with marking off: at most 4.5 percent on the store-heavy kernel
in the normal build, noise in the alignment-controlled one, nothing
measurable elsewhere. Mutator slowdown with marking forced on: 9 to 12
percent on the large-heap kernel with 8 workers, up to 24 percent with 1.

One marker kept up with 600 to 710 MB/s of promotion with zero fallbacks
and at most 258 MB of headroom. The alloc storm promotes 1.5 GB/s into a
64 MiB old space, which no marker can keep up with; a 256 MiB old space and
a marker at user-initiated QoS together brought its fallbacks to zero.

The verifier compared the concurrent mark set with a from-scratch mark 407
times across two scenario runs and found no missed object.

## Decision

Old space is collected by concurrent marking and lazy sweeping.

- **Snapshot at the beginning, taken at the end of a scavenge.** The
  deletion barrier records the old value of any pointer overwritten while
  marking is on. Taking the snapshot when no young objects exist makes the
  protocol sound and lets promoted objects be allocated black with no
  special handling. See the first lesson below for why the obvious protocol
  is wrong.
- **One marker thread**, at a QoS high enough to run on performance cores
  when the workers are busy. Two markers bought 13 to 40 percent faster
  marking for 1.2 to 1.8 times the CPU and are not worth it.
- **Marks live in a byte map beside the entry table**, set atomically by the
  marker and read by the barrier. The barrier fast path is one byte test.
- **Lazy sweep** in the background, with sweep results published at the next
  pause. Nothing about sweeping stops the world.
- **Fallback to stop-the-world** when old space fills before a cycle ends,
  counted and reported. It is a failure of provisioning, not a mode.

## Costs and conditions

- **Old-space headroom proportional to promotion rate.** Without it,
  fallbacks make things worse than plain stop-the-world. The trigger
  threshold is not a lever; the sweep rate and the marker's priority are.
  Sizing old space is now a first-class tuning problem, and on a phone it
  competes with the entry table's size.
- Promotion on first survival (ADR 0005) is what makes the alloc storm
  promote 1.5 GB/s. An age field attacks the same problem from the other
  side and remains the next collector change.
- Floating garbage of up to 21 MB per cycle under the storm, 2.4 MB under
  the slowly mutating heap.
- Mutators slow by about a tenth while a cycle runs on a large heap.

## Lessons recorded

- **The textbook initial mark loses objects here.** A young object alive at
  the snapshot can hold the only reference to an old object. If the program
  copies that reference into an already-scanned old object and the young one
  dies, the old object is never marked. The experiment's test shows the
  loss. Taking the snapshot at the end of a scavenge, when nothing is young,
  removes the case at no cost.
- **One extra call in the interpreter loop cost 20 percent** through
  register pressure before it cost anything through work. Slow paths must
  be a single out-of-line call with nothing of the instruction live across
  it.
- **The marker at low QoS lands on efficiency cores** when the performance
  cores are busy, and marks at a third to a half of its speed. The QoS of
  collector threads is a correctness-adjacent setting, not a courtesy.

## Consequences

- ADR 0004's precondition, a collector whose pauses fit in a frame, is met
  under the headroom condition above. The remaining frame misses in the
  large-heap scenario had no VM or GC time in them and belong to the AppKit
  side; they are still unexplained.
- The verifier that redoes the mark at the final pause stays in the test
  suite and runs in at least one scenario per benchmark.
- Next collector work, in order of value: an age field with a survivor
  space, compaction of old space, large objects.

## Device measurement (2026-11-02)

On the iPhone 17 Pro the marker at utility QoS landed on efficiency cores
with six busy workers and marked at 0.68 GB per CPU second; at
user-initiated it marked at 3.6, the cycle on a 256 MiB heap fell from
746 to 72 ms, and the allocation storm's fallbacks disappeared. The
"collector QoS is a design input" lesson is a hard requirement on a phone:
the marker runs at user-initiated at least while promotion is high. See
experiments/device-measurement/RESULTS.md.

Measured (iPad, 2026-11-06): on the iPad Pro 12.9-inch 3rd generation
(A12X, 4 performance and 4 efficiency cores) in the iOS shell, the
marker at utility ran on the efficiency cores (P share 0.00 to 0.01;
0.04 to 0.08 under the ring's oracle at 7 workers) under storm, ring and
share at 5 and at 7 busy workers and never fell
back (0 fallbacks, 0 aborts in 60 scenario runs); the large-object churn
counted 1 fallback in 3 runs (the iPhone 13 Pro 3 in 3 runs); the final mark
max 4.8 to 8.6 ms with young collection on at 5 workers
(docs/modules/shells.md; the final mark on the devices found that figure
to be the wait before the stop's request, below).

## Energy on device (2026-11-02)

`experiments/power` measured CPU energy (`ri_energy_nj`, per thread through
`PROC_PIDTHREADCOUNTS`) on the iPhone 17 Pro under a 120 Hz paced
allocation with 10 percent survival and a 200 MB mutating old heap.

- Below about 50 MB/s the whole app, main thread included, runs on the
  efficiency cores whatever the QoS, and the four collector configurations
  are within 0.2 mJ per MB allocated of each other.
- From 100 MB/s up the marker at user-initiated costs 0.13 to 0.15 J per
  marking cycle, 93 to 95 percent on P cores; at utility 0.03 J. The
  marker at utility never fell back to stop-the-world in 60 concurrent
  launches, with promotion up to 28 MB/s.
- Marker at utility with the young collector at user-initiated
  (`conc-mixed`) matched the all-user-initiated configuration's energy
  within 1 to 2 percent at 150 to 200 MB/s, was 13 percent cheaper at 100,
  and never missed a frame.

Amendment: on device the marker runs at **utility** by default and is
raised to user-initiated only when old-space headroom shrinks below a
threshold; the device-measurement result above (fallbacks at utility) was
the allocation storm with six busy workers, which this policy must detect.
The escalation itself was not measured.

**Idle bug, fixed.** `markerLoop` waited with a 1 ms timed wait even when
no block was pending, so a parked VM woke 130 times per second at utility
and 580 at user-initiated under a 2 MB/s trickle. SPEC amendment 18 in
experiments/concurrent-young (commit c8a77da): the marker waits untimed
unless evacuated blocks are pending, every transition it waits for signals
the condition under the lock (the audit is in the commit message; one new
signal site in the relocation pass), and two tests guard it: a parked
second costs the marker under 1 ms of CPU and at most 5 wakeups, and
marking after idling completes within a bound so a lost wake cannot hide.
Re-measured on the iPhone (experiments/power/RESULTS.md, dated section):
parked wakeups fell from 131.6 to 0.08 per second, the no-marker floor; the
120 Hz tick fell from 216 to 76, also the floor. The production marker
inherits the rule (docs/PLAN.md: idle threads wait untimed).

## Built: module 5 (2026-11-03)

Built in `Sources/KajoVM/Marking/` (docs/modules/concurrent-marking.md),
on the production nursery of ADR 0005 and 0007. As decided, with these
choices: the snapshot is a copy of an **old map** (one bit per entry, set
when an entry becomes old: an old allocation, or a promotion seen by the
scavenge's entry sweep), O(table words) to take; the barrier tests one
VM-wide flag word before every pointer store and sends the store to one
out-of-line call when it is set (two instructions in `store_ivar`; 1.4
percent on `ivars` against module 4, interleaved, with marking off); marks
are relaxed byte stores by the one marker participant; a keep-alive read
barrier on `at:` of weak slots was needed (the marker does not trace them
and SATB records stores, not loads); the sweeper requests its own short
apply stop when no scavenge applied first; a module 1 operation abandons a
marking cycle and finishes a sweep in its pause.

The headless matrix (M2 Max, release, five interleaved runs, medians; old
space 2N + 64 MiB, 4 MiB nurseries, N = 2):

| live old data | workers | stop-the-world fulls, max | final mark p50 / max | initial mark added p50 / max | fallbacks |
|---|--:|---|---|---|--:|
| 64 MiB | 1 | 0 | 0.014 / 0.018 ms | 0.12 / 0.14 ms | 0 |
| 64 MiB | 8 | 0 | 0.112 / 0.155 ms | 0.56 / 0.83 ms | 0 |
| 256 MiB | 1 | 2, 35.8 ms | 0.013 / 0.056 ms | 0.08 / 0.16 ms | 0 |
| 256 MiB | 8 | 2, 44.3 ms | 0.143 / 0.234 ms | 0.57 / 0.94 ms | 0 |
| 512 MiB | 1 | 2, 69.2 ms | 0.010 / 0.037 ms | 0.09 / 0.20 ms | 0 |
| 512 MiB | 8 | 2, 86.3 ms | 0.128 / 0.839 ms | 0.60 / 0.94 ms | 0 |

The final mark does not grow with heap size; with eight workers it is
mostly time to safepoint. The initial mark's addition to its scavenge is
mostly the survivor scan (ADR 0007), single threaded. The allocation storm
on eight workers: with a 256 MiB old space and N = 2, about 1 GB/s
promoted and zero fallbacks; at N = 1 (2 GB/s) two fallbacks per run;
into a 64 MiB old space at N = 1, 21 fallbacks per run (stop-the-world
needed 32 full collections). The headroom condition stands.

QoS policy as implemented: the marker thread starts at utility; the policy
wants user-initiated from the scavenge whose end finds headroom below 25
percent of the soft limit, and utility again from the apply of a cycle that
ends above it; the marker changes its own QoS
(`pthread_set_qos_class_self_np`) at its next poll or work period, counts
each change and logs the QoS it marked at per cycle. In the storm with a
64 MiB old space it marked at user-initiated in 12 to 13 of 13 to 15
cycles. The escalation itself is still unmeasured on a phone (module 9).
The marker waits untimed (0 ns of CPU and 0 wakeups in a parked second;
cycles after idling finish in under 2 ms).

## Built (large bytes): the policy watches the entry table and waits (2026-11-06)

On the iPhone 13 Pro and the iPad Pro the plain allocation storm fell
back to a stop-the-world full collection (41 to 84 ms, 4 to 10 frames)
in about half the launches at 7 workers and a tenth at 5, and the large
churn in 8 to 9 of 10 (docs/modules/large-bytes.md, part 2). The storm ran
out of **entries** while the lazy sweep, at utility on efficiency cores,
still held the entries it had freed (pending until the apply); old space
had headroom, so the policy, which looked at old space only and only at
the initial mark, never raised the marker. The large churn ran out of
old space while a cycle was still marking. The trigger itself did not
fire late (the entries and floor triggers fired every time) and is
unchanged. What changed:

- The QoS policy raises the marker when the headroom of old space **or
  of the entry table** (old entries, the ones a sweep has freed but not
  applied counted as used) is under `escalateBelow`, decided at the
  initial mark and now also at every young collection's end while a
  cycle runs; the apply lowers it when both are above.
- A young allocation that finds the table empty during a sweep, and an
  old allocation that finds no room, finish the sweep in their stop and
  apply it instead of a full collection (counted, `sweepsForEntries`,
  `sweepsForOld`).
- An old allocation that finds no room, or a young one that finds the
  entry table empty, while a cycle marks raises the marker and waits for
  the final mark, at most 100 ms, on a background worker (`allocWaits`).

After (the final code, ten launches of each row on each device): no
fallback in 80 launches (storm at 5 and 7 workers, the large churn, the
photo churn), three frames missed in two iPhone storm launches at thermal
serious behind final marks of 8 and 20 ms (not fallbacks; read below as
waits before the request, with the world running), the main
thread's stopped time within the earlier rows but for the iPad's large
churn (166 against 160 ms per 10 s), and on the iPhone the process's CPU
energy 4 to 14 percent lower while the marker's own rose by 7 percent to
3.5 times (it now finishes the cycles the fallbacks used to abandon). The headroom
condition stands; the fallback is still counted where it remains.

## Built (final mark): the stop was never long; its record was (2026-11-07)

The final mark's 7 to 20 ms on the iPhone 13 Pro and the iPad Pro with
young collection on (docs/modules/shells.md, docs/modules/large-bytes.md)
were the stopper's wait for every open young collection before its
request, with the world running, which module 3's stop record counted as
time to safepoint. The record now splits it: the stop itself, from the
request to the release, is 0.16 to 0.54 ms in every mode on both devices
at every thermal state, its time to safepoint at most 0.37 ms, its work
at most 0.40 (module 6's selection the largest part). No phase of the
final mark grew. The stops that cost frames were the initial mark's
young-root scan (ADR 0008's note) and a main-thread flip that waited with
the stopper. Bound anyway, as the brief asked: the final mark's tracing
is bounded in work (`finalMarkWork`, 16 384 units); past the bound, or
with a young-root scan still owed, the stop gives up before anything is
decided and the marker drains concurrently and asks again (at most eight
times a cycle, then it finishes, counted). Under the storm no final mark
came near it (the largest 10 units). The remembered filter now runs
after the ephemerons: a holder marked only by a fired ephemeron lost its
remembered bit and its young referents (a test fails on the starting
commit). After, with young offload: 0 frames missed in 80 storm launches
at 5 and 7 workers on both devices, the main thread's stopped time no
worse than the large-bytes follow-up's final block
(docs/modules/final-mark.md).
