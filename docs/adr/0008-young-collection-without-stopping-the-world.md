# ADR 0008: Young collection without stopping the world

Date: 2026-11-02
Status: accepted (owner, 2026-11-04, on module 9a's Mac mini and iPhone 13 Pro measurements, `docs/modules/shells.md`)

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

## Model checked (2026-11-02)

`docs/models/young-collection.md`, `cd models && swift test`. The protocol is model checked before module 7 builds it: seven claims hold
in nine configurations and each rule turned off finds its trace, including
the single-round loss under sequential consistency and the deferred-entry
double free of amendment 17. One real hole: the array-copy primitive's
relaxed stores can be overtaken by the barrier's seq_cst load of the
remembered word, so a concurrent clear-then-scan misses the store and the
holder is never re-armed. Every store a barrier's load follows is seq_cst
or fenced. Also: the owner's new-half scan alone covers amendment 7 (the
snoop is redundant), and the wake from a quiescent wait must store epoch 0
like `enterVM`.

## Built (module 7, 2026-11-03)

Built in `Sources/KajoVM/YoungCollection/` (docs/modules/young-collection.md)
on modules 1 to 6, with the model's findings as requirements: the policy is
the default (the main worker's nursery offloaded to a collector thread at
user-initiated, background workers local, the stop-the-world scavenge the
oracle and what module 1's operations run); rounds on module 3's flag word,
proxies for workers outside the VM and in blocking regions (the shell call
is one), two rounds before any stack scan, drain rounds until one copies
nothing; module 6's copy protocol for every young object, so the nursery
region is now inside the heap's doubly mapped memory; the initial mark's
young-root scan replaces the global scavenge; deferred entry frees owned by
their nursery (released at a stop-the-world pause by the same owner);
seq_cst array-copy stores and remembered-word loads; the quiescent wake's
epoch 0; the snoop dropped. Every rule has a test that fails without it.

Headless, M2 Max, five interleaved runs, medians; the main thread runs
120 Hz frames with about a quarter of each frame in Smalltalk (`kajo run
--main-ms`); every checksum equals the oracle's in every run:

| main worker, ms per 10 s stopped for others | stop-the-world | local | offload |
|---|--:|--:|--:|
| storm (alloc, 8 workers) | 708 | 134 | 129 |
| ring (fragment, 8 workers) | 2 273 | 206 | 185 |
| share (8 workers) | 139 | 195 | 203 |
| storm, ring, share with 1 worker | 386, 83, 10.5 | 4.1, 2.5, 2.4 | 4.7, 3.3, 2.2 |

The pieces are acknowledgements of 28 to 44 µs (1 000 to 1 500 per 10 s
under the eight-worker storm and ring); the rest is the marking cycle's
pauses. Under heavy main-thread allocation the main worker's own
collections cost 88 to 91 ms per 10 s locally (1.1 ms each) and 7.6 to 7.7
ms offloaded (flips of at most 0.021 ms). Rounds: p50 0.04 ms, p99 0.3 ms
(0.9 on the ring), max 1.4 to 4.0 ms, no single slowest participant.
Barrier cost with no collection running against module 6, aligned builds:
`ivars` 1.005 and 0.997, `storeheavy` 1.000 and 0.990 (one and eight
workers); with the young bits always on (every store out of line) 1.17 and
1.9. Idle: the collector thread and the marker used 0 ns of CPU and woke 0
times in a parked second. The young-root scan is 2.3 to 2.7 ms with eight
busy nurseries. `share` is the one scenario where the main thread does
worse than under stop-the-world (195 against 139 ms per 10 s: many cheap
collections, one acknowledgement each), as the experiment found.

**For the owner: should ADRs 0004 to 0008 be accepted?** The headless
evidence each asked for is in: 0004 (Smalltalk UI on the main thread with
budgeted preemption) built in module 3, its turn-overrun bound holding with
young collections (acknowledgements reported apart, every 64th slow poll
checks the budget); 0005 (generational collection) in module 4, kept as the
oracle and the fallback; 0006 (concurrent marking) in module 5 and 0007
(age field, concurrent relocation) in modules 4 and 6, each with its
measurements; 0008 here, where the main thread's stopped time under the
storm is 5 times lower than stop-the-world and comes in tens of
microseconds. What still waits for the shell (module 9) and the device: the
120 Hz scenarios with AppKit and missed frames rather than a driver loop's
stopped time, event latency, the mixed QoS policy and the collector thread
on the phone's efficiency cores, energy, and the share case's
acknowledgement cost on a real UI thread. Accepting them would make this
stack the design until the shell's measurements say otherwise; keeping them
proposed until module 9 has run on the device is the cautious reading.

## Device (9a) (2026-11-04)

Module 9a's shells drive module 7's scenarios from a real display link with
the main thread's work in Smalltalk (docs/modules/shells.md). First the
Mac mini's
120 Hz display (M2 Pro, 7 background workers, the module 7 QoS policy:
young collector user-initiated, marker utility), 10 s, three runs, medians
with ranges; "for others" is ADR 0008's attribution (parked in stops,
acknowledgements of other nurseries' rounds, polls that found none owed,
waits for a pending stop), per 10 s:

| main thread, ms per 10 s stopped for others | stop-the-world | local | offload |
|---|--:|--:|--:|
| storm | 338 (293 to 338)² | 87 (86 to 94) | 92 (89 to 99) |
| ring | 1196 (1146 to 1212)¹ | 143 (138 to 153) | 126 (123 to 136) |
| share | 89 (78 to 91)² | 104 (102 to 104) | 104 (103 to 105) |
| frames missed of 1200 | storm 0, ring 6 (5 to 7)¹, share 0 | 0 | 0 |

¹ at a 1024 MiB heap: at 600 MiB the parallel scavenge traps ("promotion
found no block: the promotion reserve is exhausted") in every run.
² re-run 25 minutes after the rest of the matrix (the first pass's lines
were lost to a filtering mistake in the results file), thermal nominal.

Acknowledgements on the real UI thread: 3 400 (storm) to 4 900 (ring) per
10 s at a mean of 20 to 25 µs; the longest 0.25 ms. **The share case's
answer on a real UI thread**: as headless, the one scenario worse than
stop-the-world (104 against 89 ms per 10 s), all of it acknowledgements;
no frame is missed under any mode, so on the Mac it costs CPU on the main
thread, not frames. The collector thread (offload) did almost nothing in
these scenarios (the main worker's nursery is the only offloaded one and
the frame load allocates little): under storm with events it ran 78
percent of its CPU on performance cores. The marker ran 61 to 84 percent
on performance cores at utility QoS with every performance core busy.
The headless figures of module 7 (8 workers on the M2 Max: storm 708, 134,
129; ring 2 273, 206, 185; share 139, 195, 203) and the iPhone 17 Pro's
(device-measurement: storm stw 108, local 25, offload 29 with 5 workers)
bracket these.

**The iPhone 13 Pro** (2026-11-04, after the owner signed Xcode in to the
team; the iOS shell at 120.0 Hz, 5 background workers, the same QoS
policy, 10 s, three runs interleaved, medians with ranges). Thermal state
over the matrix: nominal for three minutes, fair from the golden kernels at
six workers, **serious from the first ring run (six minutes in) to the end
(fourteen minutes)**; fib at one worker went from 1808 to 2471 ms, 37
percent slower. Every row below but storm's first run ran at serious; the
modes of a scenario ran back to back in each run.

| main thread, ms per 10 s stopped for others | stop-the-world | local | offload |
|---|--:|--:|--:|
| storm | 464 (404 to 556) | 43 (42 to 51) | 48 (45 to 50) |
| ring | 1252 (1226 to 1530) | 76 (76 to 77) | 81 (68 to 83) |
| share | 113 (97 to 117) | 55 (54 to 55) | 54 (51 to 57) |
| frames missed of 1200 | storm 0, ring 2 (1 to 4), share 0 | 0 | 0 |
| process CPU power, W | storm 3.4, ring 1.8, share 2.0 | 2.4, 1.8, 2.0 | 2.0, 1.8, 2.0 |
| peak footprint, MB | storm 553, ring 558, share 56 | 679, 557, 57 | 655, 557, 57 |

- **share is not worse on the phone**: young collection without stopping
  the world halves the main thread's stopped time (54 to 55 against 113 ms
  per 10 s). The acknowledgements are 1 800 to 1 900 per 10 s at 30 µs
  (the Mac's 4 300 at 25); the stop-the-world scavenges, 300 a run at p50
  0.99 ms, are what costs more there. On the phone no scenario is worse
  under local or offload than under the oracle.
- The gap elsewhere is wider than on the Mac: storm about 10 times,
  ring 15 to 16 times.
- The ring under the oracle missed 2 (1 to 4) frames behind stop-the-world
  scavenges of 8 ms p50 and 14 to 16 ms max; no full collection ran there
  (old space peaked at 425 to 452 MB), so the Mac's 250 ms compacting
  pauses did not occur.
- Acknowledgements on the phone's UI thread: 1 300 (storm) to 2 200 (ring)
  per 10 s, mean 29 to 31 µs, the longest on the main thread 0.09 to 0.30
  ms and once 1.5 ms. Over every participant the ack p99 was 0.9 to 2.3 ms
  and the max 3.6 to 12.4 ms, the slowest a background worker in 21 of 24
  runs.
- **The mixed QoS policy on the A15**: the marker at utility ran on the
  efficiency cores (P share 0.00 to 0.01), 130 ms of wall time and 85 to
  92 ms of CPU per ring cycle under local and offload (263 to 293 ms wall
  under the oracle), and kept up: 0 fallbacks and 0 aborts in every run,
  every cycle but the one open at the window's end finished. The young
  collector thread (user-initiated) ran on performance cores when it ran
  (P share 0.96 to 1.00 with events), 0.7 to 1.5 ms of CPU per run: only
  the main worker's nursery is offloaded and the frame load allocates
  little. The five workers ran 34 to 36 percent of their CPU on
  performance cores.
- **The final mark is longer with young collection on**: max 7.4 to 17.3
  ms (p50 0.3 to 6.7) under local and offload against 0.18 to 0.59 under
  the stop-the-world scavenge. It cost no frame (the longest main-thread
  turn under local and offload was 7.7 ms) and was not investigated here.
- Energy is the process's CPU only (`ri_energy_nj`; no DRAM, display or
  render server): 1.8 to 3.4 W with five busy workers, the oracle the
  highest under the storm.

The table the acceptance question above waited for now exists for the
iPhone 13 Pro; the decision stays the owner's.

Measured (iPad, 2026-11-06): the iPad Pro 12.9-inch 3rd generation (A12X:
4 performance and 4 efficiency cores), the same matrix at 5 background
workers, thermal nominal then fair (docs/modules/shells.md). Main thread
stopped for others, ms per 10 s, stop-the-world / local / offload: storm
475 (469 to 550) / 54 (52 to 60) / 53 (52 to 54); ring 1244 (1243 to
1315) / 101 (99 to 108) / 93 (92 to 106); share 71 (69 to 76) / 70 (58 to
71) / 64 (64 to 67). 0 frames missed in every row. share is even on the
iPad (the oracle's scavenges 0.57 to 0.60 ms p50, the acknowledgements
39 to 43 µs mean). The marker at utility stayed on the efficiency cores
(P share 0.00), 0 fallbacks and 0 aborts in 60 scenario runs; the
workers ran 74 to 77 percent on performance cores. At 7 workers (every
core busy) local and offload still missed nothing while the ring under
the oracle missed 23 (7 to 30): storm 475 / 65 / 80, ring 1418 / 119 /
117, share 79 / 79 / 78.
