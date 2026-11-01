# Experiment: a generational nursery on the object table VM

## Question

ADR 0003 (object table) and ADR 0004 (Smalltalk UI on the main thread) both
wait on one fact: can the collector's pauses fit inside a 120 Hz frame while
the VM allocates hard on every core? The non-generational mark-sweep paused
6 to 8 ms against an 8.3 ms frame and cost the main thread frames.

This experiment adds a generational nursery to the table VM and measures:

1. Young-collection pause distribution against nursery size, worker count,
   and survival rate. Target to beat: p99 under 2 ms, max under 4 ms, with
   8 workers allocating.
2. Write barrier cost on the send and field-access kernels.
3. Promotion and remembered-set behaviour on a survivor-heavy workload.
4. Whether the main thread stays at 120 Hz under the allocation storm that
   dropped frames in the previous experiment.
5. How many VM-internal store sites needed a barrier, and how the entry
   table copes with young-object churn.

## Starting point

Copy `experiments/ui-thread-scheduling/swift/` (VM with Processes, scheduler,
budget, hop-to-main, external signals, the AppKit scenario app and its frame
measurement). Do not modify that experiment. Keep everything it does; the
collector is the only thing that changes, plus a write barrier in the
interpreter and primitives. Follow the Swift notes in `AGENTS.md`.

## The collector

### Spaces

- **Nursery**: each worker allocates young objects in its own nursery, a
  contiguous region of the heap's blocks sized by a parameter (test 1, 4 and
  16 MiB per worker). Young bodies live there; the existing TLAB mechanism
  allocates within it.
- **Old space**: the existing block heap with the existing mark-sweep, used
  for promoted and large objects. Full collections stay stop-the-world
  mark-sweep; their pauses are reported separately. Do not try to shorten
  them here.
- **Young/old distinction**: either a bit in the entry's header word or a
  body-offset range check against the nursery region. Pick whichever makes
  the barrier cheapest and say which. The entry header is one load away and
  the barrier already needs the target entry, so the bit is the likely
  winner.

### Entries

Entries are identity and cannot be renumbered, so there is no bulk reset of
a young entry region. Instead:

- Each worker takes entry chunks as before. Young objects consume entries
  from the worker's current chunk.
- After a scavenge, dead young entries are freed per chunk with a bitmap
  sweep of only the chunks that held young entries since the last scavenge.
  A chunk that is entirely free goes back to the global pool; a partially
  free one is reused by its worker through a free list or bitmap scan.
- Report entry churn: entries allocated and freed per scavenge, and the time
  the entry sweep takes within the pause.

### Scavenge

- Stop-the-world across all workers, using the existing safepoint protocol.
  Every worker then scavenges in parallel: each copies survivors from its own
  nursery to old space and updates their entries. A survivor referenced from
  another worker's nursery is claimed by whoever reaches it first with an
  atomic compare-and-swap on the entry's body offset or a forwarding mark in
  the entry header. Report pause scaling from 1 to 8 workers.
- Promotion policy: promote on first survival. Simplest, and the
  survivor-heavy kernel will show its cost. Note what an age field would buy.
- Roots: every Process's stack (the used part only, parked Processes
  included), the remembered set, the class table, globals, external-signal
  roots, and the event queue.
- A scavenge is triggered when any worker's nursery is exhausted. Old-space
  exhaustion triggers a full collection as today.

### Write barrier

- On every store of a pointer into an object: `store_ivar`, `at:put:`, and
  every VM-internal store into a heap object (scheduler links, Semaphore
  queues, Process slots, event queue, class table updates). Count the
  VM-internal sites; that count is a result.
- Mechanism: if the holder is old and the value is young, record the holder
  once (a "remembered" bit in the entry header prevents duplicates) in the
  worker's remembered buffer. Remembered objects are scanned as roots at
  scavenge and un-remembered if they no longer point to young objects.
- Provide a build flag that disables the barrier (with the collector then
  running non-generationally) so its cost can be measured in isolation on
  `ivars`, `sends`, `fib` and `arith`.

## Kernels

Reuse `arith`, `fib`, `sends`, `ivars`, `alloc` by path reference. Add:

- **churn**: allocates short-lived objects at a high rate (fresh Points or
  small arrays per iteration, used immediately and dropped), almost nothing
  survives. The generational best case.
- **survivors**: grows a long-lived structure incrementally (appends to a
  large linked structure or array of arrays) while also churning, so a
  steady fraction of each nursery survives and gets promoted and the
  remembered set is exercised by old-to-young stores. Parametrise the
  survival fraction (around 5 percent and 30 percent).

Headless matrix: each kernel × {non-generational, generational with 1, 4,
16 MiB nurseries} × {1, 8 workers}, 5 runs, median. For each report wall
time, number of scavenges, scavenge pause p50/p99/max, promoted bytes,
remembered set size at scavenge, entry sweep time, and full collections if
any. Control alignment as before.

## Scenarios in the AppKit app

Reuse the frame measurement unchanged. Run, 10 s each, 3 runs, median run:

| id | scenario |
|---|---|
| G0 | idle (the measurement control) |
| G1 | 1000 events/s + 7 workers running `alloc` in a loop, non-generational (reproduces the previous experiment's drops) |
| G2 | G1 with the generational collector, 4 MiB nurseries |
| G3 | G2 but the workers run `survivors` at 30 percent |
| G4 | G2 with the UI Process itself running `churn` between events on the main thread |
| G5 | G2 with 16 MiB nurseries |

Report frames missed, max gap, scavenge pause distribution, time-to-safepoint
distribution, full collections, and the worst main-thread stall with the VM
time inside it. Events carry the time they happened, as before.

## RESULTS.md must contain

1. The headless matrix table and the scenario table.
2. Barrier cost: with and without, per kernel.
3. Pause scaling with worker count, and the share of each pause spent in
   stop-the-world coordination, copying, entry sweep, and remembered set
   processing.
4. The VM-internal barrier site count and the list.
5. Entry churn numbers and whether the table ever became the bottleneck.
6. Honest notes: what was hard, what broke, what a real system would need
   next (an age field, large-object handling, concurrent old-space marking,
   compaction of old space), and whether the pause target was met.
7. A recommendation paragraph with caveats; the ADRs are decided afterwards.

## Layout

```
experiments/generational-gc/
  DESIGN.md
  SPEC.md          nursery layout, young/old encoding, entry chunk sweep,
                   barrier protocol, scavenge claiming protocol, parameters
  kernels/         churn.kasm, survivors.kasm
  swift/           the copied package, extended
  bench.sh
  RESULTS.md
```

## Non-goals

Concurrent or incremental collection, compaction, growable stacks, large
object space beyond what the block size forces, an age field, iOS.
