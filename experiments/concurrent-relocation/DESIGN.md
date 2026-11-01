# Experiment: age-based promotion and concurrent relocation of old space

## Question

Two problems remain from ADRs 0005 and 0006. Promotion on first survival
floods old space (the alloc storm promotes 1.5 GB/s into 64 MiB and forces
stop-the-world fallbacks), and old space never compacts: allocation uses only
fully empty blocks, so scattered survivors pin memory (5 percent scattered
survivors pinned 375 MiB non-generationally, and the same shape will return
in old space).

This experiment adds both of the next collector pieces and asks:

1. **Age field.** How much does promoting after N survivals (N = 1, 2, 4)
   cut the promotion rate and the fallback count under the alloc storm, and
   what does copying survivors twice cost in scavenge pause?
2. **Concurrent relocation.** Can the marker thread compact old space while
   mutators run, with correctness guaranteed by the object table and a
   post-store check, and what does the universal store barrier cost?
3. **Footprint.** How much old space does relocation reclaim on scattered
   survivors, measured as bytes in use versus live bytes over time?
4. **Frames.** Does the main thread hold 120 Hz under the alloc storm once
   promotion is cut and old space compacts, and does relocation under a
   heavily mutating large heap stay invisible to the window?

The object table makes relocation cheap because an oop never changes: moving
a body updates one entry and no reference anywhere. ZGC and Shenandoah need
colored pointers or Brooks pointers and load barriers for this; Kajo already
pays the indirection and needs none of that. What it does need is spelled
out below, and each need is a measurement.

## Starting point

Copy `experiments/concurrent-marking/swift/`. Do not modify that experiment
or the earlier ones. Keep everything: nursery, parallel scavenge, remembered
set, SATB marking, lazy sweep, budget, Processes, scenario app. Follow the
Swift notes in `AGENTS.md`, especially: slow paths are one out-of-line call
with nothing live across them, side tables not header bits for marks set
from the hot path, collector thread QoS set deliberately, wait time separate
from work time, and the snapshot taken when nothing is young.

## Part 1: age field and survivor space

- Age lives in spare bits of the entry header word or in a byte map; say
  which and why. It is only read and written by scavenges, so a header bit
  is acceptable if there are spare bits.
- Each worker's nursery is split into an eden and a survivor region
  (semispace within the nursery: survivor-from and survivor-to). A scavenge
  copies live eden objects and survivor-from objects with age below N into
  survivor-to with age plus one, and objects at age N into old space.
  Survivor-to overflow promotes early; count those.
- N is a runtime parameter; measure N = 1 (today's behaviour), 2 and 4.
  Report promotion bytes per second, fallbacks, scavenge pause p50/p99/max,
  and bytes copied per scavenge, for `alloc`, `churn`, `survivors5`,
  `survivors30`, 1 and 8 workers, 4 MiB nurseries.
- Keep the concurrent-marking rule that the snapshot is taken at the end of
  a scavenge when nothing is young. Survivors are young, so the snapshot
  must still be sound with a survivor space: either show that the rule
  holds unchanged (survivors are scanned as roots? promoted? explain) or
  adjust the protocol and write the test that fails without the adjustment.

## Part 2: concurrent relocation

### Selecting the relocation set

- Marking accumulates live bytes per old-space block (the mark byte map plus
  body sizes). At the final-mark pause, blocks with live bytes below a
  threshold (test 25, 50 and 75 percent of block size) form the relocation
  set. Report blocks selected, bytes to move, and the expected reclaim.

### Pinning

- Any raw body pointer the interpreter or a primitive holds across a point
  where the collector could move the object is a hazard. Inventory them:
  the previous experiments found five places where the interpreter caches a
  raw pointer into a body (pc into bytecodes, literal frame, receiver body
  for ivars, and others), with a resync after every park point.
- Rule for the experiment: at the final-mark pause, pin every object
  referenced from the current frame of each running worker, and never
  relocate methods, bytecode objects, literal arrays, classes, symbols, the
  class table, nil, true and false. Pinning is a bit in the entry header set
  only at pauses, so it may live in the header. Parked Processes re-derive
  on resume and need no pins; verify that claim by reading the resync code,
  and state in SPEC.md exactly which frame slots are re-derived when.
- Primitives that hold a body pointer for longer than a single bytecode
  (bulk `at:put:`, copies) register the object in a per-worker hazard slot
  before touching it and clear it after. The relocator checks hazard slots
  and skips a hazarded object until the next pass. Count how many primitives
  needed this.

### Copy protocol

- Entry layout today is 16 bytes: body offset word and header word. Put the
  relocation state (RELOCATING, and the new offset once copied) where a
  single 64-bit atomic write publishes the switch; the simplest is to keep
  state bits in the offset word. Define the exact encoding in SPEC.md.
- Relocator, for each object in the set: skip if pinned or hazarded; CAS the
  entry from NORMAL to RELOCATING; allocate to-space in a fresh block; copy
  the body; publish NEW-OFFSET with a single release store or CAS that also
  clears RELOCATING; record the old block's range for deferred free.
- Mutator reads need no barrier. The old body stays intact until the switch,
  and after the switch the entry points to the new body. A read of either
  during the copy returns a correct value.
- Mutator stores get a **post-store check**: perform the store into the body
  obtained from the entry, then load the entry's offset word with acquire
  ordering; if it changed (the object was RELOCATING or has moved), redo the
  store into the current body, spinning while RELOCATING. The store should
  be a store-release so the relocator's copy either sees it or the mutator
  sees the state change; write out the ordering argument in SPEC.md in a
  short paragraph. This check runs on **every** store into a heap object,
  SmallIntegers included, because the copy covers all slots. That is a new
  cost; measure it with a build flag that compiles it out.
- The existing generational and SATB barrier work stays as it is and runs
  only for pointer stores.

### Freeing old bodies

- Old blocks are freed only after every worker has passed a safepoint since
  the switch. Give each worker an epoch counter advanced at its safepoint
  polls (every Nth poll is fine) and free a block when all workers' epochs
  exceed the switch epoch. Report the delay between switch and free.

### Verification

- A verifier at each pause: every entry's offset lies in a live block, no
  entry points into a freed block, no block is both in the free pool and
  referenced. Run it in every test and in at least one scenario run.
- Checksums: every kernel's checksum must equal the stop-the-world
  configuration's. The `oldheap` mutation loop under concurrent relocation
  is the real test for lost stores; run it with the relocation threshold set
  to relocate as much as possible to maximise conflicts.
- Tests that fail without each rule: a store during RELOCATING lands in the
  new body; a pinned object is not moved; a hazarded object is skipped; a
  block is not freed before every worker's epoch passes; the age field
  promotes at N and not before; survivor overflow promotes early.
- ThreadSanitizer clean.

## Kernels

Reuse all existing kernels by path reference. Add:

- **fragment**: allocates many medium-lived objects, keeps 5 percent of them
  at scattered addresses for the whole run, and churns the rest, so old
  space fills with sparse blocks. Report old-space bytes in use versus live
  bytes, sampled once per second, with and without relocation.
- **storeheavy**: a loop of SmallInteger stores into instance variables of a
  few hot objects, no pointer stores, so the post-store check is the only
  barrier that fires. The cleanest measurement of its cost.

Headless matrix: kernels × {ADR 0006 configuration; plus age N=2; plus age
N=4; plus relocation at each threshold with N=2} × {1, 8 workers}, 5 runs,
median, alignment controlled on the compute kernels. Report wall time,
promotion rate, fallbacks, scavenge pauses, relocation bytes moved,
relocation conflicts (stores redone, objects skipped for pins or hazards),
blocks reclaimed, time from switch to free, and peak RSS.

## Scenarios in the AppKit app

Reuse the frame measurement. 10 s each, 3 runs, median run:

| id | scenario |
|---|---|
| R0 | idle |
| R1 | alloc storm on 7 workers, ADR 0006 configuration (reproduce: 7 missed, 87 fallbacks) |
| R2 | R1 with age N=2 |
| R3 | R2 with relocation at 50 percent |
| R4 | `oldheap` 256 MiB on 7 workers with relocation forced aggressive, mutation loop running |
| R5 | `fragment` on 7 workers, with and without relocation, footprint sampled per second |
| R6 | R3 plus allocation on the main thread between events |

Report frames missed, max gap, every pause kind, fallbacks, relocation
activity, and the worst main-thread stall with VM time inside it, wait time
separated from work.

## RESULTS.md must contain

1. The headless matrix and scenario tables.
2. Age field: promotion rate and fallbacks versus N, and the scavenge pause
   cost of copying survivors.
3. Post-store check cost on `storeheavy`, `ivars`, `sends`, `fib`, `arith`,
   and the relocator's conflict counts.
4. Footprint reclaimed on `fragment`, as a curve or table.
5. The pin and hazard inventory: every raw body pointer the interpreter
   holds, how each is handled, and how many primitives needed hazard slots.
6. The verifier's findings and what the tests caught during development.
7. Honest notes: what was hard, what broke, what a real system needs next
   (concurrent root scanning through the scheduler, concurrent young
   collection, large objects).
8. A recommendation paragraph with caveats; the ADR is decided afterwards.

## Layout

```
experiments/concurrent-relocation/
  DESIGN.md
  SPEC.md          age encoding, survivor layout, snapshot soundness argument,
                   entry state encoding, copy protocol and ordering argument,
                   pin and hazard rules, epoch protocol, verifier, parameters
  kernels/         fragment.kasm, storeheavy.kasm
  swift/           the copied package, extended
  bench.sh
  RESULTS.md
```

## Non-goals

Concurrent young collection, concurrent root scanning, large objects, iOS.
