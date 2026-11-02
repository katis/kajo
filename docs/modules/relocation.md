# Module 6: concurrent relocation of old space

Status: brief (2026-11-02). Becomes the description of the module as built.
Starts after module 5 is built; its agent must read
`docs/modules/concurrent-marking.md` as built first, because relocation runs
on the marker thread between the final mark and the sweep and uses the
marker's live-byte counts.

Decisions it implements: the relocation half of ADR 0007 (the entry's offset
word is the single switch, a RELOCATING state that still leads to the intact
old body through a second mapping of the heap, a post-store check on every
heap store, permanent pins for objects the interpreter holds raw pointers
into, frame pins for running frames, hazard slots for primitives that hold a
body pointer across a loop, evacuated blocks freed by epoch, policy decided
on footprint alone) and the findings of the model check in
`docs/models/relocation.md`, which are requirements here.

Evidence: `experiments/concurrent-relocation/SPEC.md` Part 2 ("Selecting the
relocation set", "Pins and hazards", "Entry state encoding", "Copy protocol",
"Freeing old blocks: epochs", "Phases", "Verifier", "Test-only switches") and
RESULTS.md sections 4 to 9; `docs/models/relocation.md` (the claims, the
negative traces and "What the model found"); the AGENTS.md lessons on the
post-store check, hazard slots, epoch freeing and the double mapping.

Ports into `Sources/KajoVM/Relocation/`. Tests in `Tests/KajoVMTests/Relocation/`.

## What it hides

- Which old objects move, when, and where to.
- What RELOCATING means, how a mutator never sees it as anything but the
  intact old body, and how a store that races a copy lands in the new body.
- Which objects may never move, and how a running frame's objects are kept
  still.
- When an evacuated block's memory is reused.

## What is and is not decided

**Decided by the ADR and the model**:

- Entry states: NORMAL `off`, RELOCATING `off + 2^32`, switched `new`. The
  heap is mapped twice (module 1 already does this: `reserveTwice`), so a
  RELOCATING offset addresses the old body through the alias with no mask
  and no branch. Say at the mapping that ThreadSanitizer cannot see the
  alias and that the protocol is covered by the model, the tests and the
  ordering argument.
- The copy protocol per object: CAS `off -> off + R` (seq_cst); seq_cst
  fence; read the hazard count and, when nonzero, every worker's hazard
  words (seq_cst); revert if hazarded; copy with relaxed atomics; switch with
  a release store of `new`. No park and no allocation between the CAS and
  the switch or revert (the model's liveness finding): to-space is allocated
  before the CAS, and an assertion in checked builds guards it.
- The post-store check on every heap store outside fresh-object
  initialization: relaxed load of the offset, seq_cst store of the slot,
  seq_cst reload of the offset, one out-of-line call when it changed or had
  R set. Both halves are seq_cst, each on its own (the model shows either
  weakened loses the store). The failed check is one call that redoes the
  store and runs module 4's and module 5's barriers, so nothing of the
  instruction is live across it (the 58-percent lesson).
- Body addresses are always computed from the offset just loaded, never
  from a cached or compared value (the model's address-dependency finding;
  the compiler does not promise what the hardware does).
- Pins: pinned for good (bit 60) at image build for every method, bytecode
  object, literal Array, class, symbol, nil, true and false, plus anything
  module 2's sealed classes need; frame pins (bit 61) at the final mark for
  every old object named by each running frame and its method, cleared by
  the pause that applies or aborts the cycle. The relocator skips pinned
  objects and does not free their block that cycle. Module 2 caches exactly
  two raw pointers (bytecodes, literals), both into pinned objects; the
  module doc re-does the pin and hazard inventory against the production
  interpreter and primitives, as RESULTS.md section 6 did.
- Hazard slots: two per worker in the worker's shared line, plus a global
  count of held slots (amendment 16) so the relocator scans slots only when
  one is held. The primitive protocol: publish the slot (seq_cst), load the
  offset (seq_cst) and spin while RELOCATING, use the body, clear the slot
  (release). The only primitive that needs one in v0 is `replaceFrom:to:
  with:startingAt:` (array copy), which this module adds as a primitive so
  that the rule has a user and a test; its stores are seq_cst or fenced
  before any barrier load (the young-collection model's finding, ADR 0008
  note).
- Epochs: a global epoch counter; each worker's epoch word is stored at
  every poll slow path and every park, quiescent on `leaveVM`, and on
  `enterVM` first zero then the current epoch (the model's finding: without
  the zero a block is freed under an entering worker's pointer). The
  relocator records each fully evacuated block with the epoch, increments
  the epoch, and frees a pending block when every worker's word is past it,
  scanning the words with seq_cst loads (the model's second finding). Every
  pause frees all pending blocks first. A test fails without the zero store
  and one fails without the epoch rule.
- Selection: live bytes per block accumulated by module 5's marker while
  tracing (zeroed at the initial mark, only when a relocation is planned);
  at the final mark, in-use snapshot blocks with live bytes below a
  threshold fraction are candidates, taken in block order until the bytes to
  move would exceed a cap on the free blocks under the soft limit. Blocks
  with no live object are left to the sweep.
- Phases: final mark (selection, frame pins) then relocate, then sweep,
  then apply at the next pause (also clears frame pins). A fallback aborts
  relocation; the full collection frees evacuated blocks by its own sweep.
- Verifier at every pause in checked builds and every test: no entry is
  RELOCATING; every used entry's body is in a nursery or an in-use old block
  inside its used bytes with a back reference naming the entry; the free
  list, in-use set and pending-free list are disjoint and duplicate-free.
- Policy: relocating sparse blocks is enough to stop scattered garbage from
  pinning memory; how much to move per cycle is tuning. Defaults: threshold
  50 percent of a block, cap half the free blocks.

**Decided here, open to change behind the module**:

- The relocator is the marker thread (one thread for marking, relocation
  and sweeping), at the marker's QoS and under module 5's QoS policy. A
  separate relocator thread is a later option if a profile asks for it.
- The post-store check's cost on cache-missing stores (5 to 13 percent on
  the pointer-rewiring kernel) is accepted for v0 and measured again here;
  the cheaper protocols ADR 0007 lists (pre-store check with a handshake,
  skipping recently written blocks) are listed under Not done, not built.

**Not this module**: collecting nurseries without stopping the world (7),
large objects (they still live in blocks and relocate like anything else),
device runs (module 9's app), stack growth and Context materialization
(module 8, ADR 0009 section 3; the frame-pin list must keep working once
frames can be materialized, so the pin walk goes through one function).

## Design notes the brief insists on

- **The model is the specification of the protocol.** Any deviation in step
  order from `docs/models/relocation.md` "Steps and names" is either made in
  the model first (and the model re-run) or recorded as a deviation with the
  argument why it is still covered. The module doc carries a table mapping
  each model step to the production function.
- **The three rules each keep a test that fails without them**: post-store
  check (`aStoreDuringRelocatingLandsInTheNewBody` and the raw-store
  variant), pins (`aFramePinnedObjectIsNotMoved`, waiting since module 2,
  with its "without" variant), hazards (`aHazardedObjectIsSkipped` and the
  lost-store variant), epochs (`aBlockIsNotFreedBeforeEveryWorkersEpochPasses`
  and the freed-at-once variant, `everyPauseFreesThePendingBlocks`), plus the
  new `enterVMStoresEpochZeroFirst` and `theRelocatorNeverParksWhileRelocating`
  (an assertion test under the stress flags).
- **Test-only switches**: `pinRule`, `hazardRule`, `epochRule`,
  `enterZero`, `manualRelocation` (the test calls the pass itself), step
  functions to hold one object in RELOCATING, and a raw store that skips the
  check.
- **Stress flags**: `relocateEveryLiveBlock` (every snapshot block with a
  live object, full ones included, every cycle), `relocateAtEveryCycle` with
  module 5's `cycleAtEveryScavenge`, and module 3's `perturb` extended to
  the relocator: yields between objects and before the switch, never
  between the CAS and the switch (that would be the deadlock the model
  found, and a test asserts the flag cannot place one there).
- **Counters**: candidates, blocks selected, bytes moved, expected and
  actual reclaim, objects skipped (pinned, hazarded), stores redone, spin
  episodes and spin time (max, total, and on the main worker separately),
  frame pins per cycle, hazard slots held, pending blocks and the delay from
  switch to free (mean, max), blocks freed by epoch and at pauses, verifier
  outcomes.
- **No timed wait**: the relocator's wait for pending blocks is the marker's
  untimed wait, with the one timer the marker may legitimately hold while
  evacuated blocks are pending (module 5's rule); audit the signal sites.

## Tests to port, and tests that wait

Port first, from experiments/concurrent-relocation:
`aStoreDuringRelocatingLandsInTheNewBody`, `withoutThePostStoreCheckTheStoreIsLost`,
`aFramePinnedObjectIsNotMoved`, `withoutThePinRuleTheFrameObjectIsMoved`,
`aHazardedObjectIsSkipped`, `withoutTheHazardCheckThePrimitivesStoreIsLost`,
`aBlockIsNotFreedBeforeEveryWorkersEpochPasses`, `withoutTheEpochRuleBlocksAreFreedAtOnce`,
`everyPauseFreesThePendingBlocks`, `relocationEvacuatesSparseBlocksAndKeepsTheObjects`,
`theVerifierCatchesABodyInAFreedBlock`,
`oldheapUnderAggressiveRelocationMatchesStopTheWorld`,
`fragmentUnderAggressiveRelocationMatchesStopTheWorld`.

New: `enterVMStoresEpochZeroFirst` (fails without the zero), the
no-park-while-relocating assertion, array copy's store ordering (a test that
fails with relaxed stores, built from the young-collection model's trace as
far as a stop-the-world VM can show it; otherwise record that it waits for
module 7), the randomized programs under `relocateEveryLiveBlock` against
the oracle.

Wait: module 7's handshake and local collection, the 120 Hz scenarios and
device runs (9), Context materialization's effect on frame pins (8).

## Done when

- Tests green in debug, under load, under ThreadSanitizer; `just ios-check`
  (the alias mapping compiles for iOS; module 1 already does it);
  `just arc-check` extended to the post-store fast path (instruction
  sequence recorded: `ldr; stlr; ldar; cmp; b.ne` or equivalent), the slow
  path, the copy loop and the hazard primitive, zero retain and release, one
  jump table.
- Post-store check cost against module 5's binary, interleaved, five runs:
  within noise on `arith`, `fib`, `sends`, `ivars`, `storeheavy` (ported as
  a fixture), and reported on `oldheap` at 64, 256 and 512 MiB with 1 and 8
  workers (expected 5 to 13 percent on 1 worker, less on 8), with stores
  redone and spins.
- `fragment` reclaim: old space at the end with relocation off, with one
  cycle, and with relocation every cycle (expected about 230, 87 and 17 MB
  as in the experiment, scaled to this heap), with bytes moved and frame
  pins per cycle.
- `oldheap` 256 MiB with every live block relocated every cycle: checksums
  equal to the oracle in every run, objects moved per 10 s reported, main
  worker spin time reported (expected zero or microseconds).
- Idle cost unchanged (no new thread, no timed wait).
- Randomized programs: a hundred seeds per configuration in the suite under
  `relocateEveryLiveBlock`, a thousand in `just soak`.
- `docs/models/relocation.md` updated if any step changed, in the same
  commit; `docs/modules/relocation.md` rewritten as built with the pin and
  hazard inventory and the model-step mapping; `docs/CONTEXT.md` gains
  RELOCATING, Post-store check, Pin, Frame pin, Hazard slot, Epoch, Pending
  block, Apply; ADR 0007 gets a "Built" note with the numbers and ADR 0007's
  status question (accepted?) is raised for the owner with the evidence.
