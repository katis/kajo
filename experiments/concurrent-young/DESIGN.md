# Experiment: young collection without stopping the world

## Question

After ADR 0007, old-space marking, sweeping and compaction are off the frame
budget. What drops frames now is the scavenge: a stop-the-world pause of
every worker whenever any worker's nursery fills. Under the storm that is
3 to 5 ms per scavenge, 4.7 ms p50 with a 16 MiB nursery, 6 to 22 ms on the
fragmentation ring, and the main thread pays all of it although it
allocated almost nothing. The main thread's frame budget at 120 Hz is 8.3
ms, shared with AppKit.

This experiment asks:

1. **Local scavenge.** Can a worker collect its own nursery while every
   other worker keeps running, so background allocation never stops the
   main thread? What are the main thread's pauses once it is stopped only
   by its own nursery, and what do the extra barriers and the lost
   parallelism cost the mutators?
2. **Offloaded scavenge.** Can the copying be done by a collector thread,
   so that the owning worker pauses only to scan its own stack and flip to a
   fresh eden? This is the version the main thread wants: its pause becomes
   a stack scan of a shallow UI stack, tens of microseconds, whatever it
   allocated.
3. **Marking.** The initial-mark snapshot of ADR 0006/0007 was taken at a
   global scavenge. Without one, what does the initial mark have to do, and
   what does it cost?
4. **Frames.** Under the storm, the fragmentation ring and heavy
   main-thread allocation, how many frames does the main thread miss, and
   which pauses remain attributable to other workers' allocation? The goal
   is zero of the latter.

The object table and the relocation protocol of ADR 0007 do most of the
work: moving a young body is the same entry switch as moving an old one,
the post-store check already runs on every store, and the epoch rule
already says when memory may be reused. What is new is finding the roots of
one nursery while the others run, and a soundness argument for it.

## Starting point

Copy `experiments/concurrent-relocation/swift/` into
`experiments/concurrent-young/swift/`. Do not modify the earlier
experiments. Keep everything: table, nurseries with survivor spaces,
concurrent marking, lazy sweep, relocation, budget, Processes, scenario app,
verifiers. Follow the Swift notes in `AGENTS.md`, in particular: slow paths
are one out-of-line call with nothing of the instruction live across them,
side tables not header bits for marks set from the hot path, collector QoS
set deliberately, wait time separate from work time, and every rule gets a
test that fails without it.

Write `SPEC.md` first: the exact protocol, the ordering argument, the
barrier definitions, and which of the choices below you took and why.

## Part 1: local scavenge

A worker W whose eden is full collects its own nursery. Only W stops. The
objects to find are W's young objects (eden and survivor-from of W); call the
set Y. Everything below is the proposed protocol; change it where you find
it wrong or needlessly slow, and record the change.

### Where references to Y can be

- W's own stack and current Process, and W's registers.
- The global roots (globals, class table, ready queues, pending, host roots).
- Other workers' running stacks and parked Process stacks.
- Old objects. Today the write barrier remembers an old holder of any young
  value, per storing worker, in per-worker buffers plus a byte map.
- **Other workers' young objects.** Today nothing records a young object of
  nursery A holding a young object of nursery W, because the global scavenge
  found both. Now it must be recorded.

### Barriers

- **Cross-nursery barrier (insertion).** On a pointer store of a young value
  into a holder that is not young in the same nursery as the value, remember
  the holder, as the generational barrier does today for old holders. Define
  the nursery test: the table entry's header has the young bit; the nursery
  index can come from the body offset's range, or from spare header bits set
  at allocation. Say which and show the fast path's instruction count. The
  remembered byte map and buffers are reused; a remembered holder may now
  be young.
- **Young deletion barrier.** While any local scavenge is in progress, a
  pointer store that overwrites a reference to a young object records the
  old value in the storing worker's buffer. This is the SATB barrier of
  ADR 0006 with a different predicate (old value young, instead of old value
  unmarked); share the fast path's flag test if you can: one load of "any
  barrier on" then the predicate. The argument for why it is needed is the
  usual one: a mutator can load the only reference to y from a slot into its
  stack after its stack was scanned and before the slot is scanned, then
  clear the slot. The deletion record keeps y found. Write a test that loses
  an object without the barrier.

### Protocol

1. W's eden is full at an allocation. W sets its state to "collecting",
   increments the global count that turns the young deletion barrier on
   (acquire/release), then requests a **root handshake**: every other
   worker, at its next safepoint poll, scans its own stack and registers for
   references into Y and pushes them to W's root buffer, publishes its
   remembered and deletion buffers (swap the buffer pointer for an empty
   one), and acknowledges. A parked worker is at a safepoint and
   acknowledges without work. Parked Processes' stacks are scanned by W
   itself; a Process picked up after W started is covered by the deletion
   barrier plus the picking worker's scan, argue why in SPEC.md.
2. W scans the global roots, its own stack, parked Process stacks, and the
   remembered holders from every published buffer, processing only
   references into Y: copy to W's survivor-to or promotion buffer with the
   age rule of ADR 0007, using the **relocation copy protocol** per object
   (CAS the entry to RELOCATING, copy, publish the new offset). Other
   workers' stores into an object being copied are handled by the
   post-store check as today; reads need nothing. Transitive scanning of
   copied objects is as in the current scavenge.
3. **Second handshake.** Workers publish their deletion and remembered
   buffers again; W processes the new records. Repeat until a handshake
   yields no new reference into Y. Count the iterations.
4. W frees dead entries of Y (entry sweep over its young log as today), and
   marks its old eden and survivor-from as **reusable only after every
   worker has passed a safepoint** since the last switch, the epoch rule of
   ADR 0007. Measure how long W waits for that before it can allocate
   again. If the wait shows up, give each worker two edens and flip instead
   of waiting; say which you did.
5. A remembered holder stays remembered if it still names any young object
   of any nursery after the scavenge.

Local scavenges of different workers may overlap. If the first version
serializes them with a lock, count the time workers spend waiting for it
and report it as a cost, and say in RESULTS.md whether overlap is needed.

### What a parked or long-running worker does to the handshake

Handshake latency is bounded by the slowest worker's poll. A worker inside
a long primitive does not poll. Report the latency distribution (request to
last acknowledgement) and the worst case, and name what caused it.

## Part 2: offloaded scavenge

Same protocol, but W does not do the copying. W's own part is: raise the
barrier, scan its own stack and registers into the root buffer, flip to a
fresh eden (two edens per worker here, the second half of what was eden, or
a separate region; say which and what it costs in nursery bytes), and
continue running. A **young collector thread** (one per VM, or the marker
thread, or one per nursery being collected; measure one shared thread
first) runs steps 1 to 5 on W's behalf while W allocates in the new eden.
W's stores into objects being copied are handled by the post-store check
like anyone else's. If W fills the new eden before the collector has
finished the old one, W waits; count those waits and their duration.

The main thread is the worker this is for. Report its pauses separately:
own stack scan plus flip, time waiting for the collector, and any remaining
stop-the-world events (initial mark, final mark, fallbacks).

## Part 3: marking without a global scavenge

ADR 0007 takes the marking snapshot at the end of a scavenge and scans the
survivor spaces as roots. There is no global scavenge any more. Options:

- (a) At the initial-mark pause, scan every nursery's live-or-dead young
  objects (eden and survivor-from, all workers, in parallel) as roots,
  greying every old object they name. Linear memory, a few MiB per worker.
  Measure the pause.
- (b) Force a global stop-the-world scavenge at the initial mark, once per
  marking cycle, as before.

Build (a). Write the soundness argument in SPEC.md: young objects are not
snapshot entries, every old object reachable from a young object at the
snapshot is marked at the snapshot, and local scavenges during marking
promote black. Keep (b) as a switch for comparison and report both pauses.
Do not forget the lost-object test from experiments/concurrent-marking; it
must still fail without the young-root scan.

## Verifier and tests

- Every rule gets a test that passes with it and fails without it: the
  young deletion barrier, the cross-nursery barrier, the handshake stack
  scan, the epoch wait before eden reuse (use a deliberately slow primitive
  holding a body pointer, the hazard slot machinery is there), the second
  handshake, the young-root scan at the initial mark, and remembered holders
  carried across a local scavenge.
- A **young verifier** usable from tests and scenarios: at a forced pause
  after a local scavenge, a from-scratch reachability walk confirms that no
  reachable object's entry was freed, no reachable body lies in a reusable
  eden, and every young object's nursery index matches the entry. Keep the
  relocation and mark verifiers of ADR 0007 running.
- Checksums of every kernel equal to the stop-the-world configuration, as a
  hard gate.
- ThreadSanitizer clean (`swift test --sanitize=thread`), as a gate. Note
  that the double mapping is invisible to it, as in ADR 0007.

## Kernels

Reuse `alloc`, `churn`, `survivors5`, `survivors30`, `oldheap`, `fragment`,
`storeheavy`, `ivars`, `sends`, `fib`, `arith`. Add:

- `share.kasm`: workers allocate young objects and exchange them through a
  shared old Array, so that most references into a nursery come from other
  workers' stacks and nurseries. This stresses the cross-nursery barrier,
  the handshake stack scans and the deletion barrier. Checksum over what
  each worker finally holds.

## Headless matrix

Configurations: `adr7` (stop-the-world scavenge, the copied VM unchanged,
reference), `local` (Part 1), `offload` (Part 2), `nobarrier` (`local` with
the cross-nursery and deletion barriers compiled out: for cost only, not
for correctness), and `adr7` against `local` with the barriers compiled in
but local scavenge off, to separate barrier cost from collection cost.
Kernels x 1 and 8 workers x 5 interleaved runs, medians; nurseries 4 MiB and
16 MiB for `alloc` and `survivors30`. Report wall time, checksum, scavenge
count, per-worker pause p50/p99/max (the owning worker's own pause),
handshake latency p50/p99/max, second-handshake iterations, deletion
records, cross-nursery remembered holders, eden-reuse wait, collector-busy
share, promotion rate and fallbacks.

## Scenarios (AppKit app, 120 Hz, 10 s after 1 s warm-up, 3 runs)

- Y0 idle.
- Y1 storm, `adr7` (reference: R2 of ADR 0007, N = 2).
- Y2 storm, `local`.
- Y3 storm, `offload`.
- Y4 fragmentation ring (R5 of ADR 0007), `local` and `offload`.
- Y5 heavy main-thread allocation (the main thread's own nursery fills many
  times a second) on top of idle workers, `local` and `offload`. This is
  where offloading should show.
- Y6 `share` on 8 workers with the UI on top, `offload`.

For each: frames missed of 1200, maximum gap, and the **main-thread pause
attribution**: own scavenge or stack-scan, handshake acknowledgements
performed by the main thread (count and total time), stop-the-world events
by kind, and wait time distinct from work time. The number to watch is
main-thread time stopped because another worker allocated; report it on its
own line.

## RESULTS.md must contain

- Answers to the four questions, with numbers.
- The headless matrix and the scenario table.
- Mutator cost of the barriers separated from the cost of lost scavenge
  parallelism, both against `adr7`.
- Main-thread pause attribution per scenario.
- Handshake latency and what bounds it.
- Initial-mark pause with young-root scan against the forced global
  scavenge.
- What the verifier and ThreadSanitizer caught.
- Honest notes: what was hard, what disappointed, what a real system needs
  next.
- A recommendation paragraph, with caveats, usable as ADR input.

## Layout

```
experiments/concurrent-young/
  DESIGN.md      this brief
  SPEC.md        protocol, ordering argument, barriers, choices taken
  kernels/       share.kasm (others reused from ../concurrent-relocation)
  swift/         the package: VMR, Kasm, cy-bench, kajo-ui
  bench.sh       runs the matrix and the scenarios, writes RESULTS data
  report.py      turns raw output into the tables
  RESULTS.md
```

## Non-goals

- Parallel copying inside one local scavenge.
- Adaptive nursery or survivor sizing.
- Large objects.
- A cheaper post-store check.
- Changing the scheduler beyond what the handshake needs.
