# Module 7: young collection without stopping the world

Status: brief (2026-11-02). Becomes the description of the module as built.
Starts after module 6 is built; its agent must read `docs/modules/
concurrent-marking.md` and `relocation.md` as built first, because local
collection copies through module 6's entry switch and post-store check, and
the initial mark changes from module 5's global scavenge to a young-root
scan.

Decisions it implements: ADR 0008 with its amendments (the main thread's
nursery is collected by a collector thread after a flip of eden halves;
background workers collect their own nurseries; the initial mark scans every
nursery as roots; stop-the-world scavenging stays as the oracle and the
fallback; the young collector runs at user-initiated and the marker at
utility, the device's mixed policy) and the findings of the model check in
`docs/models/young-collection.md`, which are requirements here.

Evidence: `experiments/concurrent-young/SPEC.md` (all of it, including the
amendments), RESULTS.md and DIAGNOSIS-parallel-scavenge.md;
`experiments/device-measurement/RESULTS.md` and `experiments/power/RESULTS.md`
for the device and energy sections of ADR 0008; `docs/models/young-collection.md`.

Ports into `Sources/KajoVM/YoungCollection/`. Tests in
`Tests/KajoVMTests/YoungCollection/`.

## What it hides

- Whether a nursery is collected by its owner, by the collector thread, or
  by a stop-the-world scavenge, and when each is chosen.
- The handshake protocol: what a round is, who acknowledges, what is done at
  each kind of round, and why two rounds precede any stack scan.
- When the old eden half and survivor-from may be reused.
- Which entries are in an in-between state and who owns them.

## What is and is not decided

**Decided by the ADR and the model**:

- **Attention word**: bit 0 stop requested, bits 1.. twice the open rounds;
  the poll is unchanged (one load). The poll slow path parks for a stop and
  services rounds.
- **Rounds**: H0 (barrier on: clear the worker's own deletion records for
  this nursery, nothing else) completes before H1 (roots: scan own stack and
  the `current` register, mark the current Process scanned, publish
  remembered and deletion buffers) is opened; H2.. (drain: publish buffers)
  until the first round that copied nothing. The model reproduces the loss
  with a single round under sequential consistency; `withoutTheSecondHandshake`
  stays in the suite.
- **Proxy acknowledgement**: workers outside the VM and workers inside a
  blocking region are acknowledged by the collector under the safepoint
  mutex, which scans a blocking worker's flushed stack; a blocking region's
  epoch word does not advance. Every primitive that can block for long
  without touching the heap brackets itself; in v0 that is the shell-call
  primitive and the test primitive.
- **T1**: Process roots under the scheduler lock with per-Process scan words
  claimed by CAS, global roots, published buffers, carried holders.
  Evacuation of a reachable young object: claim with a header CAS that
  writes the decision (survive with age + 1 into this nursery's survivor-to,
  or promote), then module 6's copy protocol (CAS the offset to RELOCATING,
  fence, hazard count then hazard words, copy, switch). The header is
  decided before the offset CAS so a mutator whose post-store check fails
  reads the decided header in its slow path.
- **Barriers**: module 5's flag word gains bits 1.. (twice the nurseries
  being collected); the out-of-line store does the SATB record if bit 0,
  the young deletion record if any collection runs, the store with the
  post-store check, and the cross-nursery insertion barrier of module 4.
  Every store a barrier's load follows is seq_cst or has a seq_cst fence
  before the load (the model's array-copy finding); the array-copy primitive
  from module 6 is fixed accordingly and `theArrayCopyStoreIsSeenByTheCollector`
  fails without it.
- **Remembered sets per nursery**: module 4's 16-bit marker per entry
  becomes membership plus pending bits (amendment 9: during a pass only the
  "kept for next time" bit is set and folded in at the end); per-worker
  per-nursery buffers; carried lists per nursery; re-arm by the storer when
  the collector's fetch-and-clear raced its store (SPEC point 2).
- **Deferred entry frees are owned by their nursery** (amendments 10 and
  17): a dead remembered holder whose remembered word another nursery
  re-armed keeps its entry until its own nursery's next collection; module
  5's snapshot excludes it, module 1's sweep leaves it used, every verifier
  skips it. The model reproduces the double free without the rule; the two
  regression tests from the diagnosis stay.
- **Epoch rule before reuse** of the old eden and survivor-from, and before
  deferred frees: every participant's epoch word past the collection's
  epoch; waiting workers are quiescent (amendment 14); the wake from a
  quiescent wait stores epoch 0 then the current epoch, as `enterVM` does
  (the model's finding). The eden-reuse wait is measured; on the phone it
  has a 10 ms floor from the scheduler quantum.
- **Offload**: the owner's eden is two halves; a full half is handed to the
  young collector thread, the owner flips and continues; the owner's stack
  is scanned at its H1 acknowledgement, never at the flip; the owner's new
  half allocated before its acknowledgement is scanned at T1 (amendment 7a).
  The snoop (7b) is dropped: the model shows the scan alone suffices in
  every configuration, and `withoutNewHalfScanTheValueIsLost` keeps the
  scan honest. If the production code finds a case the model did not, the
  snoop comes back with a test and the model is extended first.
- **Policy**: the main worker's nursery is offloaded; background workers
  collect locally; one young collector thread at user-initiated QoS, the
  marker at utility (ADR 0006), both logged; stop-the-world scavenge remains
  as the oracle configuration and as the fallback when `stwWanted` is set.
  Stops and collections never interleave: a stop requester sets `stwWanted`,
  waits until no collection is active (servicing rounds), then stops.
- **Initial mark without a global scavenge** (concurrent-young Part 3):
  the snapshot is module 5's set minus every nursery's young entries and
  deferred entries; every nursery's active eden and survivor-from bodies are
  walked linearly and their slots greyed. This replaces module 5's
  initial-mark step behind the one function module 5 kept for it. The
  lost-object test from module 5 fails without the young-root scan.
- **The collector thread is a VM participant** like the marker: it parks
  through stops, runs queued collections while waiting for a stop but never
  nested inside its own collection (amendment 11), can be a stopper
  (amendment 15, it has no nursery and promotes everything in a
  stop-the-world scavenge), waits untimed when idle.

**Decided here, open to change behind the module**:

- The owner never does another nursery's work; collectors service other
  collections' rounds in their own waits and every 256 copied objects.
- The young-root scan at the initial mark is single-threaded in v0 and its
  time is a counter; making it parallel is listed under Not done with the
  budget ADR 0008 gives (2 to 3 ms with eight 4 MiB nurseries).
- Acknowledgement cost on the main worker (tens of microseconds each, a
  thousand per 10 s under a storm) is accepted for v0 and measured.

**Not this module**: the shell and the 120 Hz scenarios (9), device runs of
the mixed policy (9), Context materialization (8), nursery sizing from
observed survival.

## Design notes the brief insists on

- **The model is the specification of the handshake and ownership
  protocol.** Any step-order change is made in `models/` first and the model
  re-run; the module doc maps each model step to the production function.
- **Every rule keeps a test that fails without it**, ported from the
  experiment: the young deletion barrier, the second handshake, the
  cross-nursery barrier, the handshake stack scan, the epoch rule, carried
  holders, the new-half scan, the deferred-entry rules; plus the new ones
  for array copy's ordering and the quiescent wake's zero store.
- **Verifiers**: the young verifier after every collection (reachable young
  objects of the collected nursery were all copied; nothing names a freed
  entry; survivor-from and eden contents as module 4's verifier checks),
  module 5's mark verifier at every final mark, the relocation verifier at
  every pause, each skipping deferred entries by the same rule, agreed in
  the same commit as any new in-between state.
- **Test switches**: `youngDeletionBarrier`, `secondHandshake`,
  `crossNurseryBarrier`, `handshakeStackScan`, `epochRule`, `carryHolders`,
  `newHalfScan`, `deferredOwnership`, `quiescentWakeZero`, `arrayCopyOrdering`.
- **Stress flags**: `collectAtEveryHalf` (offload: collect every time a half
  fills, with 64 KiB halves), `roundAtEveryPoll`, module 3's `perturb`
  extended to the collector and to the acknowledgement paths.
- **Counters**: collections by mode, rounds per collection and their
  acknowledgement latency (p50, p99, max, slowest participant), copy rate,
  objects evacuated and promoted, overflow, eden-reuse waits (count, time,
  max), carried holders, deletion records, deferred frees pending and
  released, snapshot exclusions, fallbacks to stop-the-world with cause,
  young-root scan time, main-worker acknowledgement time per second, flips
  and their duration, collector and marker QoS and CPU per cycle.
- **No timed wait** anywhere; the collector and the marker wait untimed.

## Tests to port, and tests that wait

Port first, from experiments/concurrent-young (YoungTests, IdleTests):
`youngDeletionBarrierKeepsAValueTakenAfterH0`, `withoutTheYoungDeletionBarrierTheValueIsLost`,
`withoutTheSecondHandshakeTheDeletionRecordIsNeverSeen`,
`aYoungHolderInAnotherNurseryIsRememberedAndScanned`, `withoutTheCrossNurseryBarrierTheValueIsLost`,
`aRunningWorkersStackIsScannedAtH1`, `withoutTheHandshakeStackScanTheValueIsLost`,
`edenIsReusedOnlyAfterEveryWorkersEpoch`, `withoutTheEpochRuleAPrimitiveReadsAReusedEden`,
`aRememberedHolderIsCarriedAcrossLocalCollections`, `withoutCarryingTheHolderTheSurvivorIsLost`,
`anOffloadedCollectionFindsACrossNurseryHolder`, `theOwnersNewHalfObjectsAreScannedAtT1`,
`withoutNewHalfScanAndSnoopTheValueIsLost` (becomes `withoutNewHalfScanTheValueIsLost`),
`aDeferredEntryFreeIsNotASnapshotEntry`, `aFullCollectionLeavesADeferredEntryFreeToItsNursery`,
`sharedYoungObjectsAreClaimedOnceByParallelScavengers` in every mode under load,
and the idle tests for the collector thread.

New: `theArrayCopyStoreIsSeenByTheCollector` (fails with relaxed stores),
`aQuiescentWakeStoresEpochZeroFirst`, the initial-mark lost-object test from
module 5 under the young-root scan, randomized programs in every mode
against the stop-the-world oracle.

Wait: the 120 Hz scenarios, event latency and the device matrix (9).

## Done when

- Tests green in debug, under load, under ThreadSanitizer; `just ios-check`;
  `just arc-check` extended to the flag-word store path with all bits, the
  acknowledgement slow path and the collector's copy loop, zero retain and
  release, one jump table.
- Barrier cost with no collection running within noise of module 6 on
  `ivars`; slowdown with a collection running reported.
- The headless matrix of experiments/concurrent-young re-run here: alloc
  storm, fragment ring, heavy main-worker allocation, share, with 1 and 8
  workers in `stw`, `local` and `offload`, reporting the main worker's
  stopped time per 10 s and its pieces, acknowledgement p50, p99, max with
  the slowest participant, collection p50 and p99 per mode, eden-reuse
  waits, fallbacks, checksums equal to the oracle. Expected: main-worker
  stopped time 2 to 4 times lower than stop-the-world under the storm, in
  pieces of tens of microseconds.
- Idle: the collector thread and the marker cost zero CPU and zero wakeups
  per second when the VM is parked.
- Randomized programs: a hundred seeds per mode and configuration in the
  suite, a thousand in `just soak`.
- `docs/models/young-collection.md` updated with any step change in the
  same commit; `docs/modules/young-collection.md` rewritten as built;
  `docs/CONTEXT.md` gains Round, Acknowledgement, Blocking region, Flip,
  Local collection, Offloaded collection, Deferred free, Young-root scan;
  ADR 0008 gets a "Built" note and ADRs 0004 to 0008's status question
  (accepted?) is raised for the owner with the headless evidence and what
  still waits for the shell and the device.
