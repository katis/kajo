# ADR 0005: Generational collection with per-worker nurseries

Date: 2026-11-01
Status: accepted (owner, 2026-11-04, on module 9a's Mac mini and iPhone 13 Pro measurements, `docs/modules/shells.md`)

## Context

ADR 0004 needs a collector whose pauses fit in an 8.3 ms frame while every
core allocates. The non-generational mark-sweep paused 6 to 9 ms and dropped
frames. `experiments/generational-gc/` added a nursery per worker to the
object table VM, with a parallel stop-the-world scavenge, promotion on first
survival, and a write barrier with a remembered set. See its RESULTS.md.

## What was measured

Headless, 8 workers allocating, pauses pooled over 5 runs:

| kernel | 1 MiB nursery | 4 MiB | 16 MiB |
|---|---|---|---|
| churn, nothing survives | p99 0.25 ms | 0.32 ms | 0.34 ms |
| survivors, 5 percent | p99 0.64 ms | 1.13 ms | 3.08 ms |
| survivors, 30 percent | p99 0.83 ms, max 3.2 | 2.26 ms, max 4.2 | 4.86 ms |
| alloc, binary trees | p99 1.24 ms, 19 full collections | 4.42 ms, 80 percent survive | 4.88 ms |

Against the 120 Hz window, median of three runs, frames missed of 1200:

| scenario | missed | scavenge p99 | full collections |
|---|---|---|---|
| alloc storm, non-generational | 1 | none | 491 at 6.8 ms |
| alloc storm, 4 MiB nurseries | 2 | 3.6 ms | 389 at 6.5 ms |
| 30 percent survivors, 4 MiB | 0 | 1.8 ms | 119 at 4.8 ms |
| alloc storm plus main-thread allocation | 5 | 3.6 ms | 397 |
| alloc storm, 16 MiB nurseries | 0 | 3.6 ms | 149 |

Barrier cost: about 2 percent on the field-store kernel, noise elsewhere.
Time to safepoint stayed under 0.22 ms. The entry table never became the
bottleneck: sweeping freed young entries costs tens of microseconds. The
non-generational collector ran out of memory on scattered 5 percent
survivors, pinning 375 MiB where the generational one needed 26.

## Decision

Kajo's collector is generational.

- Each worker allocates into its own nursery. The size is a tuning
  parameter; 4 MiB per worker is the starting point.
- Young collections stop the world and all workers scavenge in parallel. An
  object is claimed with one compare-and-swap on its entry, the body is
  copied, the entry's offset is updated, and no reference anywhere changes.
  This is the object table paying for itself.
- The write barrier records old objects that receive young pointers, with
  the remembered marker in a byte map beside the table rather than a header
  bit, because mutators setting header bits race every other worker's reads.
- Full collections of old space run in their own pause, never stacked inside
  a scavenge pause.

## What the experiment did not settle

- **The pause target was not met in general.** p99 under 2 ms and max under
  4 ms held for low-survival work at any nursery size and for everything at
  1 MiB, but medium-lived data (3 MiB trees in a 4 MiB nursery) survived at
  80 percent and the scavenge p99 reached 4.4 ms.
- **Promotion on first survival is wrong for medium-lived data.** It floods
  old space and triggers full collections more often than non-generational
  collection did. An age field with a survivor space is the known fix. It
  cuts full collections, not scavenge pauses.
- **Full collections remain the frame-droppers** at 5 to 9 ms. The nursery
  made them rarer, not shorter. Concurrent marking of old space is now the
  prerequisite ADR 0004 waits on, and compaction of old space the one after.
- Copy throughput per participant halved from 1 to 8 participants. Not
  dissected; likely memory bandwidth or false sharing on shared structures.
- Table size grows with nursery capacity, not live data: 90 MB of entries
  for 8 workers at 16 MiB. On a phone, nursery size is bounded by this as
  much as by pause time.

## Consequences

- Every store of a pointer into a heap object goes through the barrier,
  including stores made by VM code. The experiment needed eleven such sites
  in the scheduler and Semaphore code alone, and a verifier that checks the
  remembered set invariant after every scavenge caught the missing ones.
  That verifier is part of the test suite from now on.
- Host code may not read heap objects outside the VM, because young objects
  move. Host-side inspection enters the VM like a primitive does.
- The stop-the-world protocol must not count a worker released from one
  stop as parked for the next. The experiment hit this bug and has a
  regression test for it.
- Next experiment: concurrent marking of old space with the same write
  barrier, measured against the same window.

## Built (module 4, 2026-11-02)

`Sources/KajoVM/Nursery/` (docs/modules/nursery.md) builds this decision:
one nursery per worker (eden plus two survivor halves, beyond the block
range), a parallel stop-the-world scavenge in which the stopper and every
parked worker take part (claim by one CAS on the header, copy, update the
entry; no reference changes), a barrier in concurrent-young's shape on
every store of an oop into a heap object (18 tagged sites, VM stores
included) with a 16-bit marker per entry beside the table and per-worker
buffers, a promotion reserve beyond old space's soft limit, and full
collections in pauses of their own. Dead young entries go back to
per-nursery entry stashes rather than the experiment's chunk bitmaps.

Headless numbers (M2 Max, release, medians of five runs; every checksum
the experiments'):

| kernel, 8 workers | 1 MiB p99 | 4 MiB p99 | 16 MiB p99 | 4 MiB max |
|---|--:|--:|--:|--:|
| churn | 0.26 ms | 0.53 ms | 1.76 ms | 0.60 ms |
| survivors5 (N = 1) | 0.65 ms | 1.06 ms | 2.82 ms | 1.15 ms |
| survivors30 (N = 1) | 0.69 ms | 1.55 ms | 5.96 ms | 1.68 ms |
| alloc (N = 1) | 1.20 ms | 3.90 ms | 4.89 ms | 4.39 ms |

- The barrier's fast path is four instructions when the value is old; it
  did not show against code placement (ivars 0.93x module 3).
- Eden allocation is no slower than module 1's bump (churn 0.97x module 3).
- churn's pauses are the entry sweep plus time to safepoint: the stash
  sweep reads every young entry (0.07 ms per 4 MiB nursery), where the
  experiment's bitmaps read one word per 64. Its 4 MiB p99 is 0.53 ms
  against the experiment's 0.32.
- Copy rate per participant still halves from one participant to eight.
- Two findings outside the collector: a stop longer than a 5 ms slice
  livelocked a stop-at-every-poll program (a slice's first budget check
  no longer preempts), and the main worker copies in the scavenges it is
  parked in (ADR 0008 takes it off the pause).
