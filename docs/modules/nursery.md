# Module 4: nursery

Status: brief (2026-11-02). Becomes the description of the module as built.

Decisions it implements: ADR 0005 (generational collection with per-worker
nurseries, parallel stop-the-world scavenge, remembered set in a byte map),
the age-field half of ADR 0007 (two survivor halves per nursery, promotion
after N survivals or on overflow, claim tags), and ADR 0009 sections 1 and 6
as far as the collectors are concerned (weak slots and ephemerons from the
first line of the scavenge, the class format the collectors read).

Evidence: `experiments/generational-gc/` (SPEC.md, RESULTS.md: pauses,
barrier sites, entry churn, the parked-count bug), `experiments/
concurrent-relocation/` Part 1 (age field, survivor spaces, claim tags,
remembered holders carried across scavenges; RESULTS.md section 3), and
`experiments/concurrent-young/SPEC.md` "Header word", "Spaces per worker" and
"Barriers" for the final layout of the header and the shape of the barrier,
so that modules 5 to 7 change nothing in the interpreter.

Ports into `Sources/KajoVM/Nursery/`. Tests in `Tests/KajoVMTests/Nursery/`.

## What it hides

- Where a young object lives, how it is allocated, when and where it is
  copied, and when it becomes old.
- The remembered set's representation and the barrier's slow path.
- How dead young entries are returned to the entry allocator.
- How many participants a scavenge has and how they share work.
- Which header bits mean young, which nursery, what age, and who may claim.

## What is and is not decided

**Decided by the ADRs**: one nursery per worker; eden plus two survivor
halves; header bits 52..55 nursery index, 56 young, 57..59 age, 62..63 claim
tag (module 1's reserved bits, exactly); promotion after N = 2 survivals or
on survivor overflow; the scavenge stops the world and every worker
participates; claiming is one CAS on the header; the remembered marker is a
byte map beside the table, never a header bit; mutators never write a
published header; a full collection never runs inside a scavenge pause;
every store of a pointer into a heap object, VM code included, carries the
barrier; host code reads heap objects only inside the VM.

**Decided here, open to change behind the module**:

- **Nurseries sit in the heap reservation beyond the block range**, one
  contiguous region per worker slot (default 4 MiB, config; survivor half =
  nursery / 8). Module 1 keeps every body addressable by its byte offset,
  so entries point into nurseries unchanged. The nursery region is never a
  pool block and is never swept by the old collector.
- **Large objects are allocated old.** Above a threshold (default 8 KiB,
  config) `allocate` goes to the worker's module 1 allocation context. The
  experiments copied every survivor up to 32 KiB; ADR 0005's "What a real
  system needs" and the alloc kernel say not to.
- **Dead young entries.** Module 1 allocates entries from per-context free
  lists refilled by runs from a pool. The scavenge must free the entries of
  dead young objects by touching only what was allocated since the last
  scavenge, never the whole table. Choose between a per-worker log of the
  runs taken since the last scavenge (sweep the runs' entries by their young
  bit) and the experiment's chunk bitmaps with young logs. Either way
  `verifyFreeLists`'s one-owner rule holds after every scavenge and the
  entry sweep is a counter.
- **Barrier fast path in concurrent-young's shape**: after the store, if
  the value is a reference and its header is young and the holder's young
  and nursery bits differ from the value's, call `remember(w, o, nursery)`
  out of line. Three instructions when the value is old (the common case
  loads only the value's header). The slow path and the remembered set
  behind it are this module's; module 7 later adds the deletion record and
  the flag word without touching the fast path.
- **Remembered set**: one byte per entry (or 16 bits, if the cost is the
  same, so module 7's per-nursery sets need no table change; decide and
  record), per-worker remembered buffers written only by their owner,
  holders carried across scavenges while they still hold a young object,
  young holders never remembered.
- **Work sharing**: per-participant work stacks with stealing or packets, as
  the experiments did; the copy rate per participant is a counter so the
  halving seen at eight participants is visible.
- **Weak slots and ephemerons**: the class table gains a format word
  (ADR 0009 section 6) with weak and ephemeron flags, settable from kasm's
  class directive. The scavenge does not trace weak slots and nils those
  that named a dead young object at the end of the scavenge; module 1's
  mark-sweep (the oracle) does the same for dead old objects. Ephemerons:
  module 1's collector implements the key rule and the finalization queue
  (a Semaphore the collector signals through module 3's external signal
  queue, drained by a Process the tests write in kasm); the scavenge treats
  an ephemeron's slots as strong, so finalization of a young key waits for
  the first full collection. Record this as the v0 rule.
- **Promotion reserve**: old space keeps a reserve equal to the sum of the
  nurseries so a scavenge never fails for lack of space. A scavenge that
  leaves old space over its soft limit requests a full collection in its
  own pause at the next poll, never in the same stop.
- **Snapshot**: module 1's snapshot runs after a scavenge with promote-all,
  so nothing is young in an image. Image loading allocates old.
- **The main worker waits for the stop like every other worker.** ADR 0008
  (module 7) is what takes it off the pause; nothing here anticipates it
  except the header and barrier layout.

**Not this module**: concurrent marking (5), relocation of old space (6),
collecting a nursery without stopping the world (7), nursery sizing from
observed survival, card marking, device runs (the app target does not exist
yet; the headless matrix runs on the Mac and the device numbers come with
module 9's app).

## Design notes the brief insists on

- **The scavenge's roots are module 3's stop roots plus the remembered
  holders**: every Process stack through its saved sp, every worker's saved
  registers, the ready queues, records, pending roots, globals and the class
  table. Nothing is scanned through a running worker's live registers; the
  stop flushes them.
- **Claiming**: scavenge s uses tag bit 62 + (s & 1); the winning CAS writes
  the decision (survive with age + 1 and the winner's nursery index, or
  promote with young, nursery, age and tag cleared) into the header. A loser
  reads the decision from the header. No pass clears tags.
- **Promotion** allocates in old space through the participant's module 1
  context (bump in its private block), copies the body, writes the new
  offset into the entry. The oop never changes. A promoted object's slots
  that still name young objects make it a remembered holder.
- **A scavenge that happens while module 1's collect or compact is
  requested** promotes everything (promote-all) so the old collector runs
  with nothing young, as the experiments did; the two pauses are still
  separate.
- **Barrier sites**: `store_ivar`, `at:put:`, and one VM-internal `store`
  that every VM store of an oop into a heap object goes through (module 3's
  scheduler and Semaphore stores among them). Grep for raw stores; the
  remembered-set verifier after every scavenge is what catches a miss, and
  mutation-testing each site (remove it, see the verifier fail) is recorded
  in the module doc as the experiment did.
- **Verifiers at every scavenge in checked builds**: remembered-set
  invariant (every old holder of a young object is remembered), exactly-once
  promotion, nursery ownership (every young body lies in its header's
  nursery, in eden or survivor-from), no reference from old space to a dead
  young object, weak slots nil'ed exactly when their referent died. Module
  1's verifiers keep running at full collections.
- **Stress flags**: `tinyNurseries` (64 KiB eden, 8 KiB survivors),
  `promoteAll`, `scavengeAtEveryAllocation`, and the existing ones. The
  randomized programs of module 3 run under each, with the nursery on and
  off; the no-nursery configuration is the oracle and checksums must agree.
- **Counters**: scavenges, pause p50, p99, max with the slowest participant,
  time to safepoint, promoted and survived bytes, overflow promotions,
  copied bytes per participant and the rate, remembered holders scanned and
  slots per holder, barrier slow-path calls, entries freed per scavenge and
  the sweep time, full collections requested by a scavenge, weak slots
  nil'ed, ephemerons queued.
- **No timed waits**; participants wait on the stop's condition variable
  only.

## Tests to port, and tests that wait

Port first:

- generational-gc: `youngSurvivorKeepsItsOopAndContents`,
  `oldHolderOfAYoungObjectIsRememberedAndTheYoungOneSurvives`,
  `theVerifierCatchesAStoreThatSkipsTheBarrier`,
  `aYoungObjectReachableOnlyFromAnotherNurseryIsPromotedOnce`,
  `sharedYoungObjectsAreClaimedOnceByParallelScavengers`,
  `deadYoungEntriesAreFreedAndReused`, `aParkedProcessStackIsScanned`,
  `aFullCollectionWorksAfterPromotions`,
  `schedulerStoresIntoOldObjectsAreBarriered`.
- concurrent-relocation Part 1: a survivor stays young with age + 1, promotes
  at N, overflow promotion when survivor-to is full, a remembered holder is
  carried while it still holds a survivor and dropped when it does not, the
  claim tag alternates so a losing participant reads the right decision,
  full collections promote everything.
- New: weak slot nil'ed by a scavenge and by a full collection; an
  ephemeron's key kept alive only by the ephemeron is queued once by a full
  collection and its value traced after; a large object is allocated old;
  snapshot after promote-all has nothing young; module 3's randomized
  programs agree with the no-nursery oracle under every flag.
- Each rule found by a failing test is checked by breaking it (test switch
  or hand run, as module 3 did), and the module doc says which.

Wait: everything concurrent (modules 5 to 7), `aFramePinnedObjectIsNotMoved`
(6), the 120 Hz scenarios and the device matrix (9).

## Done when

- Tests green in debug, under load, under ThreadSanitizer; `just ios-check`;
  `just arc-check` extended to the barrier fast path (instruction count
  recorded), the eden allocation fast path and the scavenge copy loop, zero
  retain and release, the dispatch loop still one jump table.
- Barrier cost at most 3 percent on `ivars` and the eden allocator no slower
  than module 1's bump on `alloc`, both interleaved against module 3's
  binary, five runs, medians and spread.
- The headless matrix of generational-gc and concurrent-relocation Part 1,
  re-run here: churn, survivors5, survivors30, alloc, oldheap64 and
  fragment kernels, 1 and 8 workers, nurseries 1, 4 and 16 MiB, N = 1 and
  N = 2, reporting scavenge p50, p99 and max with the slowest participant,
  promoted MB/s, overflow MB, full collections, copy rate per participant.
  Expected from the experiments: churn at 8 workers p99 under 0.4 ms;
  survivors30 at 4 MiB p99 near 2 ms; alloc at 4 MiB promotes most of its
  trees at N = 1 and far less at N = 2. Deviations are findings, not
  failures, but say why.
- The randomized programs agree with the oracle for a hundred seeds per
  configuration in the suite and a thousand in `just soak`.
- Idle cost unchanged from module 3 (no new thread, no timed wait).
- `docs/modules/nursery.md` rewritten as built; `docs/CONTEXT.md` gains
  Nursery, Eden, Survivor, Age, Claim tag, Remembered set, Barrier, Weak
  slot, Ephemeron, Format; ADRs 0005 and 0007 get a "Built" note with the
  matrix numbers; ADR 0009 sections 1 and 6 get a note on what v0 does.
