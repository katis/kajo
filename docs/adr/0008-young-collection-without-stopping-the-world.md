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
