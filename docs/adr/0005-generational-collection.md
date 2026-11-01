# ADR 0005: Generational collection with per-worker nurseries

Date: 2026-11-01
Status: proposed

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
