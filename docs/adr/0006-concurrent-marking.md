# ADR 0006: Concurrent marking and lazy sweeping of old space

Date: 2026-11-01
Status: proposed

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
