# ADR 0008: Young collection without stopping the world

Date: 2026-11-02
Status: proposed

## Context

After ADR 0007 the scavenge was the last collector pause in the frame
budget: every worker stopped whenever any worker's nursery filled, 3 to 5 ms
under the storm and 6 to 22 ms on the fragmentation ring, paid by the main
thread although it allocated almost nothing.
`experiments/concurrent-young/` built two forms of young collection that
stop only the allocating worker: local collection, where the owner collects
its own nursery while the others run, and offloaded collection, where the
owner flips to a fresh eden half and a collector thread does the copying.
See its RESULTS.md and the 16 amendments in its SPEC.md.

## What was measured

Main-thread time stopped because another worker allocated, per 10 s at
120 Hz, median of three runs:

| load | stop-the-world | local | offload |
|---|--:|--:|--:|
| allocation storm | 126 ms | 36 ms | 67 ms |
| fragmentation ring | 27 ms | 0.4 ms | 1.2 ms |
| heavy main-thread allocation | 0 | 0.01 ms | 0.04 ms |
| young objects shared across 8 workers | - | - | 113 ms |

Frames missed of 1200:

| load | stop-the-world | local | offload |
|---|--:|--:|--:|
| allocation storm | 58 | 6 | 5 |
| fragmentation ring | 27 | 12 | 19 |
| heavy main-thread allocation | 34 | 47 | 48 |
| shared young objects | - | - | 0 |

The residue under local and offload is round acknowledgements: the main
thread answers each other worker's collection at three of its polls, about
30 us each. The heavy main-thread allocation misses are the load itself and
not the collector, with the stop-the-world baseline missing 34 and no
collector time on the main thread; why local and offload miss more there is
unexplained.

The owner's own pause: local p50 0.4 to 2.2 ms at 8 workers, the whole
collection, with p99 better than stop-the-world on some kernels and worse
on others because one thread copies what eight copied in parallel. Offload
flip p50 0.005 to 0.05 ms, p99 under 0.12 ms, the main thread's worst flip
0.03 ms.

Costs: the two new barriers cost 0 to 2 percent at one worker on every
kernel and are within noise at eight. Local collection costs 1.00 to 1.06 at
one worker and 0.94 to 1.17 at eight. One collector thread serving eight
allocating workers is 94 to 98 percent busy and makes them 1.14 to 1.69
times slower; at one worker offload is faster than everything else because
the copy runs on a second core.

Handshake latency at 8 workers: p50 0.05 to 0.08 ms, p99 0.2 to 1.5 ms, max
2 to 17 ms, bounded by the slowest worker reaching a poll and dominated by
OS descheduling, the same tail the stop-the-world time-to-safepoint has.

Initial mark without a global scavenge: scanning every nursery as roots
costs 1.4 to 2.4 ms at 8 workers, single threaded, against 0.6 to 2.7 ms for
forcing a global scavenge. It is now the largest main-thread pause under the
storm at 2.4 to 2.6 ms per cycle.

Checksums equalled stop-the-world in every run of every kernel. The young
verifier, a from-scratch reachability walk, ran after collections in the
tests and 5321 times in two scenarios with no failure. ThreadSanitizer
clean. 72 tests, each rule with a test that loses an object without it.

## Decision

Nurseries are collected without stopping the world.

- **The main thread's nursery is collected by a collector thread.** The
  main thread's pause is a flip of eden halves, tens of microseconds. Its
  stack is scanned at its own handshake acknowledgement, never at the flip.
- **Background workers collect their own nurseries** while the others run.
  One collector thread cannot serve many allocating workers; local
  collection keeps the copying on the core that allocated. This combination
  is the recommendation of the experiment and has not itself been measured;
  each half has.
- **The protocol is sound only with all of its parts**, each with a failing
  test: a barrier-on round before any stack scan, per-Process scan words,
  per-nursery remembered sets with a cross-nursery insertion barrier, a
  young deletion barrier while any collection runs, drain rounds until one
  copies nothing, the epoch rule before eden reuse, and for an owner that
  keeps allocating, a scan of its new eden half plus a snoop barrier.
  Copying uses the entry switch and post-store check of ADR 0007 unchanged.
- **The initial mark scans every nursery as roots.** The marking snapshot
  no longer rides on a global scavenge. The lost-object test from
  experiments/concurrent-marking still fails without this scan.
- **Stop-the-world scavenging stays as a configuration.** It is the
  correctness oracle (docs/VERIFICATION.md) and the fallback when a
  collection cannot complete.

## Costs and conditions

- Round acknowledgements replace scavenge pauses on the main thread: tens of
  milliseconds per 10 s under a storm, in 30 us pieces instead of 2.5 to 25
  ms pauses. A reduction of 2 to 4 times, not elimination. Fewer or cheaper
  rounds are the next thing to build, and each is a correctness argument
  first.
- The young-root scan at the initial mark must become parallel or move out
  of the pause. Budget 2 to 3 ms with eight 4 MiB nurseries until then.
- Every primitive that can block needs a blocking region, or one long
  primitive bounds every handshake. Only the UI primitives have one.
- Local collection copies with one thread per nursery; its p99 depends on
  the slowest running worker. All maxima here depend on OS scheduling of
  every VM thread and must be re-measured on device.
- The flag word that turns the deletion barrier on stays set for a whole
  collection, so every pointer store of every worker goes out of line
  meanwhile. This is a candidate for the unexplained heavy-main-allocation
  misses.

## Lessons recorded

- **The roots were the whole problem; the copying was free.** The object
  table made a concurrent copy of a young object the same entry switch as
  ADR 0007. Every hole was in finding references while mutators ran, and
  every hole was found by a failing-without-rule test or the from-scratch
  verifier, not by reasoning. Fourteen amendments to a spec that looked
  complete.
- **A single root handshake is unsound even under sequential consistency.**
  The barrier must be on at every worker before any stack is scanned, which
  needs its own round.
- **An owner that keeps allocating during its own collection is a root
  source.** Its new eden half holds references the snapshot never saw and
  must be scanned, with a barrier snooping stores into it.
- **Stale remembered lists are a use-after-free.** A remembered holder can
  be freed and reallocated by another nursery's collection before the list
  is read; dead young holders may be freed only after an epoch.
- **Per-object atomics in a copy loop halve the copy rate.** A seq_cst CAS,
  a fence and a hazard scan per object made one collector copy at half the
  stop-the-world per-thread rate until the hazard scan was taken off the
  per-object path.
- **The `result` register is a root** and kept dead objects alive. Found
  only because the without-the-rule tests must fail.

## Consequences

- ADR 0004's precondition now holds for young collection as well: no
  collector pause on the main thread exceeds a frame under any measured
  load. The remaining main-thread cost is acknowledgements and the initial
  mark.
- ADR 0006 and 0007 are amended: the snapshot is taken at the initial-mark
  pause with every nursery scanned as roots, not at a global scavenge.
- Collector work is no longer the first thing to attack. The next
  measurements are the acknowledgement cost, a parallel young-root scan,
  the mixed policy as a whole, and the device run that ADR 0003 has been
  waiting for.

## Device measurement (2026-11-02)

On the iPhone 17 Pro with 5 background workers and the phone cooled, the
display delivered 120 Hz throughout:

| scenario | missed of 1200 | main thread stopped for others' allocation |
|---|--:|--:|
| storm, stop-the-world | 1 | 108 ms (39 scavenges) |
| storm, local | 0 | 25 ms (1040 acknowledgements) |
| storm, offload | 0 | 29 ms (1315 acknowledgements) |
| fragmentation ring, local | 0 | 1.6 ms |
| heavy main-thread allocation, offload | 0 | 0.02 ms |

The split holds on device: the collector thread keeps up with the main
thread alone (1.5 percent busy, flips 0.023 ms max) and does not keep up
with six allocating workers (76 to 96 percent busy). Local collection's
own pause is worse than on the Mac relative to stop-the-world, 1.1 to 1.9
times its p50, because one copying thread lands on an efficiency core.
Most maxima moved down on the phone, not up. The eden-reuse wait has a
10 ms floor at 2 and 6 workers, one scheduler quantum, since the epoch
rule waits for a descheduled worker. A hot phone (thermal state serious)
nearly doubled the main thread's acknowledgement time; a frame budget
must be stated with a thermal state. The checksum gate held in 1044
launches. Not run on device: ThreadSanitizer, the verifier scenarios, the
share kernel. See experiments/device-measurement/RESULTS.md.

## Energy on device (2026-11-02)

`experiments/power` (CPU energy only, 120 Hz paced allocation, 10 percent
survival, medians of 3), mJ per MB allocated:

| MB/s | stop-the-world | offload + marker, both user-initiated | both utility | collector user-initiated, marker utility |
|--:|--:|--:|--:|--:|
| 2 | 1.98 | 2.22 | 2.08 | 2.05 |
| 10 | 1.54 | 1.64 | 1.60 | 1.62 |
| 50 | 1.62 | 1.79 | 1.74 | 1.74 |
| 100 | 4.23 | 4.72 | 4.60 | 4.09 |
| 200 | 7.70 | 7.97 | 9.61 | 8.15 |

Stop-the-world is 5 to 12 percent cheaper in energy below 50 MB/s, where
everything runs on efficiency cores, but its scavenges there take 4.5 to
5.3 ms and its full collections miss 4 to 7 frames per run from 100 MB/s.
The collector thread at utility costs more energy than at user-initiated
from 150 MB/s (the main thread waited for it 130 to 160 times per run) and
first missed frames at 150 MB/s; at user-initiated it took 13 to 16 percent
of mutator CPU and 9 to 15 percent of energy. The young collector and the
five parked workers use no CPU when idle; the idle wakeups belong to the
marker (ADR 0006).

Amendment: on device the young collector thread stays at
**user-initiated**; the marker goes to utility (ADR 0006). This is the
"mixed" policy and it never missed a frame up to 200 MB/s.

**Defect found and fixed (2026-11-02).** The test
`sharedYoungObjectsAreClaimedOnceByParallelScavengers` failed under CPU
contention (10 of 40 under load, 0 of 20 idle). The parallel stop-the-world
scavenge was not at fault: the failing check was the concurrent-mark
verifier, and the test runs the `local` mode by default; `stw` and `offload`
passed 40 of 40 under the same load. Root cause (SPEC amendment 10 and 17,
`experiments/concurrent-young/DIAGNOSIS-parallel-scavenge.md`): a dead
remembered young holder whose `rem` word another nursery's collection
re-armed keeps its entry used until its own nursery's next collection,
during which it is in no young log. The initial-mark snapshot and the full
sweep both read "used and in no young log" as an old object, so the
nursery and the old-space collector both freed the entry, and the second
free took the object that had reused it. The fix (commit 7484f9b, 28
lines, no hot-path change) makes the nursery the only owner of a deferred
entry: the snapshot excludes deferred entries, the full sweep hides their
bits, and the scavenge verifier skips them as the other verifiers already
did. Two deterministic regression tests fail 20 of 20 without the fix and
pass 50 of 50 with it; the full suite passes under load and under
ThreadSanitizer. The oracle (`stw`) never defers a free, so no stop-the-world
number changes; `local` and `offload` old-space counts (snapshot entries,
sweep frees, floating garbage) in concurrent-young's RESULTS.md and the
tables above could differ by the kept entries and were not re-run. All
published checksums were equal, so no run lost an object that a checksum
saw. The verifier found the defect; the checksum did not.
