# Module 6: concurrent relocation of old space

Status: built, 2026-11-03. `Sources/KajoVM/Relocation/`, with the object
memory's side in `ObjectMemory/` (the checked stores, the state word as an
atomic, the pool operations for evacuated blocks) and hooks in modules 3
and 5. Tests in `Tests/KajoVMTests/Relocation/` and one random-program
configuration.

Decisions it implements: the relocation half of ADR 0007 (the entry's
state word is the single switch, a RELOCATING state that still leads to the
intact old body through the heap's second mapping, a post-store check on
every mutator heap store, pins for good for what the interpreter holds raw
pointers into, frame pins for running frames, hazard slots for the one
primitive that holds a body pointer across a loop, evacuated blocks freed
by epoch, policy decided on footprint alone) and the findings of
`docs/models/relocation.md`, each a requirement here (table below).
Evidence: experiments/concurrent-relocation (SPEC Part 2, RESULTS 4 to 9,
its tests), ported by their tests first.

## What it hides

- Which old objects move, when, and where to.
- What RELOCATING means, how a mutator never sees it as anything but the
  intact old body, and how a store that races a copy lands in the new body.
- Which objects may never move, and how a running frame's objects are kept
  still.
- When an evacuated block's memory is reused.

## The cycle

Relocation rides module 5's cycle on the marker thread; there is no new
thread and no timed wait.

1. **Initial mark** (`relocationAtInitialMark`, world stopped). A relocation
   is **planned** unless the last completed cycle found old space dense
   (marked bytes over the bytes of the blocks in use at its final mark at
   or above `planBelow`, 0.75); the first cycle always plans; either stress
   flag plans every cycle. Planned: the live-bytes-per-block array is
   zeroed and module 5's marker counts into it (`traceObject` adds each
   traced object's body size to its block; one load and one add per
   object, nothing when not planned).
2. **Final mark** (`relocationAtFinalMark`, world stopped, after module 5's
   verifier passed). Density recorded for the next plan. **Selection**:
   every in-use block with live bytes above zero and below `threshold`
   (0.5) of a block (any live bytes with `relocateEveryLiveBlock`), whose
   stamp is not this cycle's (a block an allocator took after the snapshot
   holds bodies that are not snapshot entries, and may be a context's
   current block), in block order, until the bytes to move would exceed
   `cap` (0.5) times the free blocks under the soft limit. Counted:
   candidates, selected, capped, bytes to move, expected reclaim (selected
   blocks' bytes minus bytes to move). The selected blocks are taken out of
   the block pool (`withdrawFromPool`), so no allocator puts a body in one
   before it is evacuated. **Frame pins**: every old object a running
   frame names (`forEachRunningFrameWord`: each worker that runs a
   Process, its current frame from fp to the flushed sp, the method
   among the words) gets header bit 61 and is listed.
3. **Relocation pass** (`relocatePass`, the marker inside the VM, phase
   sweeping, before the sweep). For each selected block, its bodies by
   their back references up to its used bytes; a body is moved when its
   entry is a marked snapshot entry (the mark is read first: an unmarked
   entry may be free and reallocated meanwhile) whose state word is this
   body (not a stale copy), and is not pinned. Per object
   (`relocateOne`): to-space from the relocator's own allocation context
   (a refill takes the pool lock under the soft limit; none left: the pass
   stops, counted); `relocBegin`: the marker worker's `inRelocation` set,
   CAS `off -> off + 2^32` (seq_cst), a seq_cst fence; the hazard check
   (`isHazarded`): the count of held hazard slots, and when nonzero every
   worker's two slots (seq_cst); hazarded: `relocRevert` (release), the
   block is not freed this cycle; `copyBody`: the body word by word, back
   reference included, relaxed atomic loads and stores; `relocSwitch`: one
   release store of the new offset, `inRelocation` cleared, to-space
   bumped. A block whose objects all moved goes **pending** (`addPending`)
   and the pending list is tried after every block, at the end of the
   pass and between sweep chunks (`tryFreePending`). The pass polls only
   between objects: every 64 objects or 16 KiB copied (the marker polls
   every 128 traced objects).
4. **Sweep** (module 5, unchanged): it sees the new offsets, so evacuated
   blocks hold no live body; dead snapshot entries whose bodies were left
   in an evacuated block are freed by it.
5. **Apply** (the next pause that applies, or the sweeper's own stop):
   pending blocks were freed when the pause started; `relocationAtCycleEnd`
   clears the frame pins, forgets the set (blocks left in it go back to the
   pool with the apply's rebuild) and closes the cycle's record. An abort
   (a marking cycle abandoned) does the same. A module 1 operation in phase
   sweeping finishes the sweep in its pause and applies (module 5's rule);
   the relocator, back from its park, finds the phase changed and stops.

**Every pause** (`stopWorld`, world stopped, before its work) frees every
pending block (`relocationAtPauseStart`), and after its work may run the
relocation verifier (`relocationAtPauseEnd`, below).

## Layouts

| what | where | written by | read by |
|---|---|---|---|
| state word: `off`, `off + 2^32` (RELOCATING), `new` | the entry (module 1) | allocators, pauses (plain); the relocator (CAS, release stores) | everyone, relaxed atomic loads; the post-store check's reload seq_cst |
| hazard slots `hazard0`, `hazard1` | module 3's per-worker shared line (`WorkerShared`, 128 bytes) | the worker (seq_cst publish, release clear) | the relocator (seq_cst) |
| epoch word | the same line | the worker (poll slow path, park, enter, leave) | the relocator (seq_cst) |
| global epoch E, count of held hazard slots | `RelocationShared.epoch`, `hazardsHeld`, one 128-byte line each | the relocator (seq_cst fetch-and-add); the primitives (seq_cst add, release subtract) | workers (acquire, seq_cst at enter); the relocator (seq_cst) |
| live bytes per block | `RelocatorState.blockLive`, `UInt32` per block; module 5's `MarkerState.blockLive` points at it while planned | the marker participant (marker between stops, stopper at the final mark), zeroed at the initial mark | the final mark |
| relocation set, cursor, pending list (block, epoch, time), frame-pin list, to-space context, counters, cycle records | `RelocatorState`, own lines | the marker participant inside the VM; stoppers with the world stopped | the same; the host through `inspect` |
| per-worker counters (stores redone, spins, hazards taken) | `Worker.relocation` | the worker's own thread | the host, world stopped |

The heap is mapped twice (module 1's `reserveTwice`): `heapBase + off + 2^32`
is the same memory as `heapBase + off`, so a RELOCATING state word leads to
the intact old body with no mask and no branch. ThreadSanitizer cannot see
that the two mappings alias; the protocol is covered by the model, the
tests and the ordering argument (said at the mapping, and below).

## Post-store check

`ObjectMemory.storeChecked` (and `storeByteChecked`): relaxed load of the
state word, seq_cst store of the slot through it, seq_cst reload, true when
the reload equals the first load and that had no RELOCATING bit. On a false
answer the site makes one out-of-line call: `storeConflict` (barrier sites:
`postStoreSlow`, then module 4's insertion barrier), `postStoreSlow`
directly in `storeWithBarriers` (the flag word set: already out of line)
and in `checkedStore` (SmallInteger stores into Process and Semaphore
slots), `postStoreSlowByte` for `at:put:` on a ByteArray. The slow path
spins (acquire loads, a yield every 64 spins) while RELOCATING, stores into
the body the entry leads to (seq_cst), reloads (seq_cst), and repeats until
stable; it never polls or parks. Counted per worker: stores redone, spin
episodes, spin time (total and max; the main worker's apart).

Every mutator store goes through it: `store_ivar`, `at:put:` (pointer and
byte), `globalAt:put:`, the Message stores of `doesNotUnderstand:`, the
scheduler's barriered stores (`barrierStore`), its deletion stores
(`clearingStore`) and its SmallInteger stores (`setIntSlot`, now taking the
worker). `ObjectMemory.store` is the raw store: fresh objects being
initialised (no relocation can name them: they are not snapshot entries),
collectors in a pause, the image loader, module 5's weak nil'ing in the
final mark, and the tests' "store without the check".

`store_ivar` in `interpret` (release, `just arc-check` prints it):

```
ldr  x11, [x10]             ; e1 = state word (relaxed)
add  x12, x24, x11
add  x12, x12, x9, lsl #3
stlr x3, [x12]              ; slot := v (seq_cst)
ldar x12, [x10]             ; e2 = state word (seq_cst)
tbnz x11, #0x20, slow       ; e1 RELOCATING
cmp  x12, x11
b.ne slow                   ; changed: storeConflict
tbnz w3, #0, next           ; module 4's barrier, unchanged
```

`interpret` is 794 instructions (module 5: 775), one indirect branch, one
jump table.

## Pins and hazards: the inventory

Every raw body pointer in the production interpreter, primitives and
runtime (read from `Interpreter/`, `Processes/`, `Workers/`, `Nursery/`,
`Marking/`, `Loader/`; `grep -rn 'bytesBase\|slotsBase\|heapBase'`):

| holder | points into | held across | handling | load-bearing here |
|---|---|---|---|---|
| `Regs.code`, `Regs.pc` | the running method's bytecodes (ByteArray) | instructions, sends, polls, parks | pinned for good at image build; re-derived from the method oop after every pause (`restore`) | yes |
| `Regs.lits` | the running method's literal Array | instructions | pinned for good; re-derived at every return and resume | yes |
| `SavedRegisters.pc`, a frame's caller pc (`hdr[1]`), a Process's saved pc | | | offsets, not pointers | no |
| receiver in `push_ivar`, `store_ivar` | receiver body | one instruction: state word, then the slot | none: no safepoint inside an instruction; the store has the check | no |
| `primAt`, `primAtPut`, `primGlobal` | receiver body | one access | as above | no |
| `primReplace` (38, new) | receiver and source bodies | the copy loop (`copySlots`) | hazard slots 0 and 1 | yes (a test shows the lost store) |
| `primBasicNew`, Message creation, `VM.newSemaphore`, `newArray`, Process creation | fresh objects | initialisation | young or allocated after the snapshot: never in a relocation set | no |
| the image loader | fresh objects | boot | before any VM exists | no |
| scheduler (`intSlot`, `setIntSlot`, `barrierStore`, `clearingStore`) | Process and Semaphore bodies | one access each | the check on every store | no |
| scavenge, marker, sweep, final mark, verifiers, module 1's operations | any body | a pause, or the marker thread (which is the relocator: never both at once) | none | no |
| Process stacks and frames | native memory | | not in the heap | |

**Pinned for good** (bit 60, `Image.allocatePinned` and the bytecodes): every
method, its bytecodes and literal Array, every class, every symbol, nil,
true and false, as the image creates them (the image is built before any VM
exists, so the header writes race nothing). Method dictionaries are not
pinned (lookups read them a slot at a time), nor the globals Array. Module
2's sealed classes (Class, Method, MethodDict) need nothing more: their
instances are reached through oops only. An image built with
`pinsForGood: false` (only two module 2 tests of re-derivation after a
compaction) gets no relocation (`RelocationShared.install` refuses it).

**Frame pins** (bit 61) are set at the final mark and cleared by the pause
that applies or aborts the cycle. In this interpreter nothing load-bearing
depends on them: the receiver body is never cached, frames hold oops, and
the two cached pointers are into objects pinned for good. They are
implemented, counted (1 to 2 per cycle on one worker) and tested because
ADR 0007 requires them and module 8's Context materialization will change
what a frame holds; the walk goes through one function.

**Hazard slots**: one primitive needs them (the new `replaceFrom:to:with:
startingAt:`); none of the other primitives (1 to 37) holds a body pointer
across more than one access.

## Epochs

`epochAdvance` (E acquire, the word release) at the top of every poll slow
path (`pollSlow`) and in `park`; `epochQuiesce` (quiescent, release) at the
start of `leaveVM`; `epochEnter` in `enterVM` after the worker counts as
active and before any heap access: 0 (seq_cst), E (seq_cst), the word := E
(release). `addPending` records the block with s = E and increments E
(seq_cst fetch-and-add); `tryFreePending` reads every worker's word with
seq_cst loads and frees each pending block whose s is below all of them
(`releaseEvacuatedBlock`: not in use, used 0, one fewer block in use, on
top of the pool at once). The marker worker is not a participant (it is the
one freeing). A block frees when every worker has passed a poll slow path
(every `pollEvery` = 1024 polls), parked, or left the VM since its switch;
the sweeper's apply stop frees the rest.

## The model and the code

`docs/models/relocation.md`, "Steps and names", against the production
functions. No step changed order; the model is unchanged.

| model step | production |
|---|---|
| `M store: e1 = offset (relaxed)` | `ObjectMemory.storeChecked` / `storeByteChecked`, inline at every store site (`storeWithBarrier`, `checkedStore`, `checkedStoreByte`, `storeWithBarriers`) |
| `M store: slot := v (seq_cst)` | the same: `stlr` |
| `M store: e2 = offset (seq_cst)`, compare | the same: `ldar`, `tbnz` bit 32, `cmp`, `b.ne` |
| `M store: postStoreSlow` (spin, redo, reload) | `postStoreSlow`, `postStoreSlowByte`; through `storeConflict` at barrier sites |
| `M read: offset (relaxed), slot (relaxed)` | `ObjectMemory.load`, `loadByte`: relaxed atomic loads of the state word and the slot, the address computed from the value just loaded (finding 6) |
| `M hazard: hz := o (seq_cst)`, `offset (seq_cst)` spin | `hazardAcquire` (plus the held-slot count, below) |
| `M hazard: ... through p` | `copySlots` (seq_cst stores, barriers) |
| `M hazard: hz := 0 (release)` | `hazardRelease` |
| `M poll: E (acquire)`, `epoch[M] := E (release)`, park | `epochAdvance` in `pollSlow` and `park` |
| `M leaveVM` | `epochQuiesce`, first in `leaveVM` |
| `M enterVM` (mutex, 0 seq_cst, E seq_cst, E release) | `enterVM`: the mutex section, then `epochEnter` (finding 1) |
| `R poll` | `markerPoll` from `relocatePass`, between objects only |
| `R relocate: CAS ... fence` | `relocBegin` (to-space already taken by `toSpace`: finding 4) |
| `R relocate: hz[M] (seq_cst)`, revert (release) | `isHazarded`, `relocRevert` |
| `R relocate: copy` | `copyBody` |
| `R relocate: switch (release)` | `relocSwitch` |
| `R addPending (seq_cst fetch_add)` | `addPending` |
| `R tryFreePending: epoch[M]`, free | `tryFreePending(atPause: false)`, seq_cst loads (finding 2) |
| `S requests a pause`, `S world stopped` | `stopWorld`: `relocationAtPauseStart` frees every pending block, `relocationAtPauseEnd` verifies (no entry RELOCATING) |

Findings, as built:

1. The `enterVM` 0: `epochEnter`; `enterVMStoresEpochZeroFirst` and its
   broken variant (below).
2. The seq_cst scan: `tryFreePending` loads every epoch word seq_cst.
3. "The relocator is counted stopped only after a full fence that follows
   its last switch or revert": it stops only by `park` (or `leaveVM`),
   both of which take the safepoint mutex; the stopper reads `parked`
   under the same mutex, so everything before it is visible to the stop.
4. No park and no allocation between the CAS and the switch: to-space is
   taken before `relocBegin`; the marker worker's `inRelocation` is set
   from the CAS to the switch or revert and `park` counts (checked builds
   that trap: stop) a park while it is set; perturbation inside a copy
   only yields or sleeps. `theRelocatorNeverParksWhileRelocating`.
5. Both halves seq_cst: `stlr` then `ldar`, each its own ordering.
6. Address dependency: every body address is computed from the state word
   just loaded; the state word is a relaxed atomic load, so the compiler
   cannot substitute a cached or compared value.

Deviations from the model, each still covered:

- **A count of held hazard slots** (the brief's amendment 16, not in the
  model): `hazardAcquire` publishes the slot (seq_cst), then increments the
  count (seq_cst), then loads the state word (seq_cst); the relocator,
  after its CAS and fence, reads the count (seq_cst) and scans the slots
  only when it is nonzero. If the relocator reads 0, its load precedes the
  primitive's increment in the seq_cst total order, so the primitive's
  state-word load, which follows the increment, follows the CAS and sees
  RELOCATING or the switch: the model's own Dekker case. If it reads
  nonzero it scans the slots exactly as the model's relocator does. The
  release decrement after the release clear keeps the primitive's
  accesses before a relocator that reads the count as 0 afterwards.
- **Two slots per worker** (the model has one per mutator): independent
  words, each under the model's rule.
- **The relocator polls every 64 objects or 16 KiB**, not before every
  object: still only between objects; it bounds time to safepoint and
  leaves the pass a batch per stop under a stop storm (under
  ThreadSanitizer, a test that polls the host every 0.5 ms let the pass
  move one object per stop).
- **Byte stores** (`at:put:` on a ByteArray): the same check with a
  one-byte seq_cst store; the copy reads 64-bit words with relaxed atomic
  loads. Mixed-size atomics are outside the C++ model (hardware gives
  single-copy atomicity per byte here); the argument is the word case's.

## Verifier

`verifyRelocation`, when the object memory verifies (every test, checked
builds), at the end of a pause that follows relocation work since the last
one that verified (a selection, a moved or reverted object, a freed block,
the end of a cycle); while a cycle's relocation is under way only the
collectors' and the cycle's own stops verify (scavenges, full collections,
final marks, applies), not the host's inspections; the first stop of any
kind after the cycle ends does. Recorded through module 1's `record` (trap,
or count and keep): no entry RELOCATING; every used entry
that is not pending dead has its body in the nursery region or in an
in-use block, inside the block's bodies (its used bytes, or an allocation
context's bump pointer), with a back reference naming the entry; no block
twice in the pool, no free block with used bytes; the pending list empty
(the pause freed it); no block of the relocation set in the pool.
`theVerifierCatchesABodyInAFreedBlock` frees a selected block by hand and
sees "body in block b, which is free".

## Stress flags and test switches

| flag | effect |
|---|---|
| `relocateEveryLiveBlock` (`--stress everyblock`) | every snapshot block with a live object is selected, full ones included (the cap still applies) |
| `relocateAtEveryCycle` (`everycycle`) | a relocation is planned in every cycle whatever the density; with module 5's `cycleAtEveryScavenge` (`cycle`), relocation runs continuously |

Perturbation (module 3's `perturb`) reaches the relocator between objects
and inside each copy (after the hazard check and before the switch), as
yields and sleeps only.

Test switches (`RelocationTestSwitches`): `pinRule` (frame pins honoured;
pins for good always are, see Deviations), `hazardRule`, `epochRule`,
`enterZero`, `manualRelocation` (the marker never relocates; the test calls
`VM.relocate` or the step functions `stepBegin`, `stepCopy`, `stepSwitch`,
which hold one object RELOCATING). The raw store is `ObjectMemory.store`.
`VM.setEnterWindow` installs a hook `enterVM` calls between its load of
the epoch and its store.

## Counters

`vm.relocationCounters`: cycles planned and with a selection, candidates,
blocks selected and capped, bytes to move, expected reclaim, objects and
bytes moved, blocks evacuated, objects skipped (pinned, hazarded), CAS
failures, passes stopped for space or aborted, frame pins, pending maximum,
blocks freed by epoch and at pauses with the delay from switch to free
(total and max), the pass's CPU and wall time, parks while relocating,
perturbation points inside copies, verifier runs and failures, the peak of
blocks in use at a pause; summed over the workers: stores redone, spin
episodes, spin time and maximum (and the main worker's), hazard slots taken
and waits. `vm.relocationLog`: per cycle the selection (candidates,
selected, capped, bytes to move, expected reclaim, time), frame pins,
objects and bytes moved, skips, evacuated, freed by epoch and at pauses,
wall and CPU time, stopped for space, aborted, completed. `kajo run` prints
them (`relocationReport`) with old space in use at the end and its peak.

## Measurements

All on the M2 Max (8 P + 4 E cores), macOS 27, Swift 6.4, release builds,
2026-11-03 02:45 to 03:30, with no `yes` loop and no ThreadSanitizer run
alive (`pgrep -x yes` empty); load average (1 min) 3.0 to 3.9, mostly the
8-worker kernels themselves. Module 5's `kajo` built from c6a8ef9 (the
same code as 0b8ab7e) in a worktree; this module's from `.build/bench` at
a7a2983 (the later commits change the verifier's schedule, off in these
runs, `unsafe` markings and tests). Every checksum equals module 5's and the
published one.

### Post-store check cost against module 5, interleaved

Five runs per cell, interleaved (run, kernel, workers, binary), medians
(min to max), ms, `--slice-ms 0`; `oldheapN` with `--heap 2N+64`, 4 MiB
nurseries, N = 2, oldheap's iterations N x 250 000 (module 5's matrix).

Plain `-O` builds:

| kernel | workers | module 5 | module 6 | ratio | stores redone / spins (5 runs) | cycles (median) |
|---|--:|--:|--:|--:|---|--:|
| arith | 1 | 2571.8 (2570 to 2573) | 2553.1 (2549 to 2581) | **0.993** | 0 / 0 | 0 |
| arith | 8 | 345.2 (345 to 346) | 342.4 (342 to 342) | **0.992** | 0 / 0 | 0 |
| fib | 1 | 1675.2 (1675 to 1678) | 1664.4 (1662 to 1667) | **0.994** | 0 / 0 | 0 |
| fib | 8 | 218.9 (219 to 224) | 217.0 (216 to 221) | **0.991** | 0 / 0 | 0 |
| sends | 1 | 2562.6 (2560 to 2649) | 2510.9 (2506 to 2551) | **0.980** | 0 / 0 | 0 |
| sends | 8 | 334.6 (333 to 345) | 330.1 (327 to 334) | **0.987** | 0 / 0 | 0 |
| ivars | 1 | 2066.2 (2064 to 2067) | 2077.7 (2075 to 2082) | **1.006** | 0 / 0 | 0 |
| ivars | 8 | 269.4 (269 to 282) | 270.0 (270 to 271) | **1.002** | 0 / 0 | 0 |
| storeheavy | 1 | 2238.2 (2236 to 2238) | 2373.1 (2372 to 2378) | **1.060** | 0 / 0 | 0 |
| storeheavy | 8 | 291.2 (291 to 293) | 308.8 (308 to 313) | **1.060** | 0 / 0 | 0 |
| oldheap64 | 1 | 2346.4 (2343 to 2362) | 2569.3 (2564 to 2610) | **1.095** | 0 / 0 | 2 |
| oldheap64 | 8 | 342.0 (339 to 348) | 358.9 (355 to 363) | **1.049** | 0 / 0 | 3 |
| oldheap256 | 1 | 10450.3 (10430 to 10471) | 11066.1 (11059 to 11080) | **1.059** | 0 / 0 | 6 |
| oldheap256 | 8 | 1478.2 (1473 to 1507) | 1527.0 (1515 to 1554) | **1.033** | 0 / 0 | 6 |
| oldheap512 | 1 | 22285.5 (22255 to 22339) | 23389.2 (23386 to 23420) | **1.050** | 0 / 0 | 8 |
| oldheap512 | 8 | 3140.5 (3128 to 3163) | 3182.9 (3175 to 3191) | **1.014** | 0 / 0 | 7 |

Code placement moves these numbers by several percent either way
(AGENTS.md): `arith` and `fib`, which store nothing, came out 0.7 percent
faster, and `storeheavy` 6 percent slower although its store sequence is
the one above. So the small kernels were run again in builds that align
every branch target and loop to 32 bytes (`-align-all-nofallthru-blocks=5
-align-loops=32`, both binaries), with a third binary, module 6 built with
`-DKAJO_NO_POST_STORE` (the raw store in place of the check, everything
else the same), which separates the check from the rest of the module:

| kernel | workers | module 5 | module 6 | module 6, raw store | module 6 / module 5 | check / raw store | raw store / module 5 |
|---|--:|--:|--:|--:|--:|--:|--:|
| arith | 1 | 2549.2 (2502 to 2554) | 2549.4 (2522 to 2555) | 2548.4 (2509 to 2552) | **1.000** | 1.000 | 1.000 |
| arith | 8 | 343.5 (343 to 344) | 342.6 (342 to 346) | 342.7 (342 to 346) | **0.997** | 1.000 | 0.998 |
| fib | 1 | 1669.6 (1666 to 1672) | 1659.6 (1659 to 1661) | 1665.8 (1664 to 1673) | **0.994** | 0.996 | 0.998 |
| fib | 8 | 217.5 (217 to 219) | 216.0 (216 to 218) | 216.5 (216 to 222) | **0.993** | 0.998 | 0.995 |
| sends | 1 | 2540.4 (2538 to 2549) | 2521.4 (2521 to 2522) | 2514.0 (2510 to 2540) | **0.993** | 1.003 | 0.990 |
| sends | 8 | 330.6 (330 to 332) | 329.1 (328 to 330) | 328.0 (327 to 342) | **0.995** | 1.003 | 0.992 |
| ivars | 1 | 2045.5 (2044 to 2046) | 2048.6 (2045 to 2052) | 2043.6 (2042 to 2046) | **1.002** | 1.002 | 0.999 |
| ivars | 8 | 266.7 (266 to 270) | 266.6 (266 to 268) | 266.2 (266 to 268) | **1.000** | 1.002 | 0.998 |
| storeheavy | 1 | 2222.4 (2220 to 2227) | 2229.7 (2227 to 2234) | 2220.5 (2220 to 2226) | **1.003** | 1.004 | 0.999 |
| storeheavy | 8 | 290.0 (289 to 292) | 290.0 (290 to 292) | 288.7 (288 to 290) | **1.000** | 1.005 | 0.996 |
| oldheap64 | 1 | 2343.3 (2339 to 2354) | 2568.8 (2556 to 2585) | 2362.5 (2355 to 2372) | **1.096** | 1.087 | 1.008 |
| oldheap64 | 8 | 341.7 (340 to 344) | 356.2 (354 to 362) | 342.1 (338 to 352) | **1.042** | 1.041 | 1.001 |

- **Hot stores: nothing measurable.** `storeheavy` (eight SmallInteger
  `store_ivar`s per iteration, all L1 hits) 1.003 and 1.000, `ivars`
  1.002 and 1.000 against module 5, and the check against the raw store
  0.4 to 0.5 percent; `arith`, `fib`, `sends` within 1 percent. An `stlr`
  then an `ldar` of a cached line costs nothing visible on this core, as
  in the experiment.
- **Missing stores: the expected price.** `oldheap` rewires random nodes
  of a large graph and its stores miss; the `ldar` waits for each.
  Against module 5: 9.5, 5.9 and 5.0 percent with one worker at 64, 256
  and 512 MiB, 4.9, 3.3 and 1.4 percent with eight (the experiment: 5 to
  13 with one, 5 to 7 with eight). The aligned `oldheap64` attributes it:
  8.7 percent of the 9.6 is the check (check against raw store), the rest
  placement.
- **Atomic state-word loads.** The first build was 4 to 6 percent slower
  on `arith` and `ivars` in the aligned build as well. The cause was not
  the check: with the state word a relaxed atomic load, the compiler no
  longer merged the five loads of a method's state word on a send and a
  return into one. `invoke`, `activate` and `doReturn` now load it once
  (a7a2983); after that every kernel without missing stores is within 1
  percent in the aligned builds. In the plain build `storeheavy` stays 6
  percent slower: placement (the check against the raw store is 0.4
  percent in the aligned build), so the brief's "within noise" holds in
  the aligned comparison only.
- Stores redone and spins: zero in every run (the default policy plans a
  relocation in the first cycle only on these dense heaps; it moved 8 to
  10 objects per run).

### Fragment reclaim

`fragment` (2 000 000 iterations: nodes promoted at N = 2, 5 percent of
them kept at scattered addresses, the rest dying in old space; an array
copy every 64th iteration), `--heap 240` (a 240 MiB soft limit: the first
cycle at 60 percent, as in the experiment), five interleaved runs, medians
(min to max). "Default" is the shipped policy (threshold 0.5, cap 0.5, a
relocation planned while old space is sparse); "every cycle" adds
`--stress cycle,everycycle` (a cycle at every scavenge, a relocation in
each); "every block" also selects every live block (`everyblock`, cap 0.9).
Old space at the end is the blocks in use after the run; the peak is the
most seen at a pause (for "off", from 100 ms samples).

| workers | relocation | ms | old space at the end MB | peak MB | cycles | moved MB per run | blocks evacuated | frame pins per cycle | stores redone / spins, 5 runs (max ms) | freed by epoch / at pauses, 5 runs | free delay mean / max ms | relocator CPU ms |
|--:|---|--:|---|--:|--:|--:|--:|--:|---|---|---|--:|
| 1 | off | 1631 | 240.1 (240.1 to 240.1) | 240.1 | 52 | 0 | 0 | | | | | |
| 1 | default | 1628 | **101.1** (101.1 to 101.1) | 151.3 | 1 | 7.3 | 4467 | 2.0 | 0 / 0 | 22286 / 49 | 0.011 / 0.053 | 5.0 |
| 1 | every cycle | 1639 | **18.1** (18.1 to 18.2) | 19.8 | 137 | 13.3 | 7228 | 1.9 | 0 / 0 | 36124 / 0 | 0.011 / 0.029 | 8.9 |
| 1 | every block | 1640 | 16.5 (16.4 to 16.5) | 18.1 | 137 | 1410.9 | 50060 | 1.9 | 176 / 30 (0.005) | 248599 / 44 | 0.012 / 1.189 | 239.0 |
| 8 | off | 323 | 232.3 (230.8 to 232.9) | 232.3 | 4 | 0 | 0 | | | | | |
| 8 | default | 322 | 68.0 (67.3 to 76.9) | 184.9 | 2 | 9.0 | 5346 | 13.0 | 1 / 0 | 26500 / 23 | 0.021 / 1.391 | 16.6 |
| 8 | every cycle | 324 | 75.0 (61.8 to 80.3) | 119.6 | 7 | 9.5 | 5319 | 12.6 | 6 / 3 (0.005) | 26574 / 42 | 0.022 / 0.272 | 24.2 |
| 8 | every block | 326 | 40.8 (40.7 to 63.7) | 119.9 | 6 | 180.4 | 11433 | 9.8 | 58 / 28 (0.027) | 56309 / 83 | 0.018 / 2.418 | 85.6 |

Run 1, one worker, old space in use every ~110 ms (ms: MB):

- off: 108: 16.7, 438: 67.4, 878: 135.6, 1318: 201.6, 1648: 240.1
- default: 437: 69.1, 864: 135.6, 974: 46.3, 1084: 29.4, 1303: 64.4, 1627: 101.1
- every cycle: 110: 5.6, 550: 9.5, 984: 13.3, 1424: 17.2, 1644: 18.2

- **As the experiment found** (230, 87 and 17 MB): without relocation old
  space ends at 240 MB for 12 to 16 MB live (module 5's 52 cycles free
  entries but not the blocks the kept nodes pin); with the default policy
  the first cycle (at 60 percent of the soft limit) evacuates 4467 blocks
  by moving 7.3 MB and old space drops from 136 to 29 MB, ending at 101 MB
  because the trigger is not reached again; with relocation in every cycle
  old space stays within a few MB of live, ending at 18 MB. Eight workers
  finish in 0.32 s, within two to seven cycles: 68 to 75 MB against 232.
- **The cost**: none visible in run time (1628 to 1640 ms against 1631).
  The relocator moved 1.4 GB per run (every block) for 239 ms of its CPU,
  5.9 GB per CPU second.
- **Frame pins**: 2 per cycle with one worker, 10 to 13 with eight.
- **Conflicts**: at most 176 stores redone and 30 spin episodes in five
  runs, the longest spin 0.027 ms; 2 hazard skips per 5 runs in the
  every-block runs; no CAS failure.
- **Freeing**: 99.8 percent of evacuated blocks freed by epoch, the rest at
  the next pause; mean delay from evacuation to free 0.011 to 0.022 ms,
  longest 2.4 ms.

### oldheap 256 MiB with every live block relocated in every cycle

`oldheap` at 256 MiB live (64 million iterations, rewiring random nodes),
`--heap 576`, against the stop-the-world oracle (`--gc stw`) and with
`--stress cycle,everycycle,everyblock --reloc-cap 0.9` (a cycle at every
scavenge, every live snapshot block selected in every cycle), five
interleaved runs, medians; headless, so the main worker runs no Smalltalk
and the spin column is every worker's.

| workers | collector | ms | checksum | stop-the-world fulls (max pause ms) | cycles | objects moved | moved per 10 s | MB moved | blocks evacuated | stores redone / spins, 5 runs (max ms) | freed by epoch / at pauses, 5 runs | free delay mean / max ms | relocator CPU ms | pause p50 / p99 / max ms | final mark p50 / max ms | old space at the end MB |
|--:|---|--:|---|---|--:|--:|--:|--:|--:|---|---|---|--:|---|---|--:|
| 8 | oracle | 1572 | | 2 (80.6) | | | | | | | | | | 0.957 / 80.394 / 80.636 | | 438.8 |
| 8 | every block | 1570 | equal in 5 of 5 | 0 (3.1) | 11 | 17.3 M | **111 M** | 2215 | 69254 | 6 / 3 (0.000) | 323470 / 408 | 0.034 / 4.018 | 479 | 0.818 / 2.869 / 3.138 | 0.186 / 0.834 | 321.0 |
| 1 | oracle | 11116 | | 2 (35.3) | | | | | | | | | | 0.327 / 0.753 / 35.332 | | 447.5 |
| 1 | every block | 12273 | equal in 5 of 5 | 0 (1.0) | 107 | 202.1 M | **165 M** | 25778 | 803581 | 20 / 0 | 4006805 / 3473 | 0.014 / 0.156 | 4550 | 0.357 / 0.806 / 1.036 | 0.044 / 0.477 | 270.7 |

- **Checksums equal to the oracle's in every run**, with the whole live
  heap moved 11 times (eight workers) and 107 times (one worker) per run:
  111 and 165 million objects per 10 s (the experiment: 83 million).
- **Spins: none longer than 0.0005 ms** (3 episodes in 5 runs with eight
  workers, none with one); 6 and 20 stores redone. The main worker runs
  nothing headless; its spin counters are zero, and module 9's app will
  measure it.
- **Run time**: equal with eight workers (1570 against 1572 ms; the
  oracle's two full collections of 80 ms are gone); 10 percent with one
  worker, which relocated 25.8 GB in 4.6 s of the marker's CPU on another
  core while it ran (the post-store check's 6 percent at this size is in
  it).
- No verifier failure and no park while relocating (these runs do not
  verify; the suite's versions do).

### Idle

No new thread and no timed wait (`grep -rn "timedwait\|asyncAfter\|pthread_create"
Sources/KajoVM`: module 3's Delay primitive and the two thread starts of
modules 3 and 5, as before). The relocator is the marker; its retries of
pending blocks are after each block, at the end of the pass and between
sweep chunks; the sweeper's apply stop frees the rest. Module 5's idle
tests pass unchanged (`aParkedVMDoesNotWakeItsMarker`: 0 ns of marker CPU,
0 wakeups in a parked second; `idleWorkersCostNothing`).

### Randomized programs

- In the suite: 100 seeds for each of the 14 configurations, one new:
  `relocateEveryLiveBlock` (four workers, 24 KiB nurseries, a cycle at
  every scavenge, every live snapshot block selected in every cycle, cap
  1, perturbation at 2 percent reaching the relocator between objects and
  inside copies, every verifier). Every answer is the model's; objects
  moved over the seeds nonzero; no park while relocating, no verifier
  failure. 10 seeds per configuration under ThreadSanitizer.
- `just soak` (1000 seeds per configuration, 14 configurations, release):
  seeds 1 to 1000, no failure, 24.6 s.

## Changes to modules 1 to 5

Module 1 (`ObjectMemory/`):

- `stateWord` is a relaxed atomic load (`stateWordAtomic` gives the word as
  an atomic); `load` and `loadByte` are relaxed atomic loads.
- New `storeChecked`, `storeByteChecked` (the check), `storeSlot(atState:)`,
  `storeByte(atState:)` (seq_cst stores through a known body: the redo and
  the hazard primitive), `wordAtomic`, `setWordAtomic` (the relocator's
  walk and copy). `store` and `storeByte` stay the raw, unchecked stores
  (`storeByte` now a relaxed atomic one-byte store).
- `Collector.swift`: `withdrawFromPool`, `releaseEvacuatedBlock`,
  `blockStampAtPause`, `poolBlocks`, `bodyEnds`.
- `verifyHeap` skips pending-dead entries entirely (their body may lie in
  an evacuated block already freed), not only their slots.
- `VirtualMemory`: reservations with `mmap` and `munmap` instead of
  `vm_allocate` and `vm_deallocate` (ThreadSanitizer intercepts them and
  resets its shadow; with the Mach calls it reported a race between two
  tests' side tables that only shared an address). The alias mapping is
  still `vm_map` over the `mmap`ed range.

Module 2 (`Interpreter/`, `Loader/`):

- Primitive 38, `replaceFrom:to:with:startingAt:` (`primReplace`, in
  `Relocation/Hazard.swift`); `at:put:` on bytes is checked.
- `Image` pins for good (`pinsForGood`, default true) every method, its
  bytecodes and literal Array, every class, symbol, nil, true and false.

Module 3 (`Workers/`, `Processes/`):

- `WorkerShared` gains `hazard0`, `hazard1`, `epoch` (still one line,
  checked at VM creation); `Worker` gains `relocation` (counters) and
  `inRelocation`.
- `enterVM` calls `epochEnter`, `leaveVM` `epochQuiesce`, `pollSlow` and
  `park` `epochAdvance`; `park` counts a park while relocating.
- `stopWorld`: `relocationAtPauseStart` before the work,
  `relocationAtPauseEnd` after it.
- `VMConfig.relocation`, `VMState.relocation`; `VM.init` installs
  relocation after marking, `destroy` uninstalls it.
- `setIntSlot` takes the worker and does the checked store.
- `kajo run`: `--reloc on|off`, `--stress everyblock,everycycle`,
  `--reloc-threshold`, `--reloc-cap`, `--sample-ms`; the relocation report.

Module 4 (`Nursery/`):

- `storeWithBarrier` does the post-store check (failed: one call,
  `storeConflict`, that redoes the store and runs the insertion barrier);
  `clearingStore` the same with no insertion barrier.
- `BarrierSite.arrayCopy`, and the barrier-site test's scenario through
  the primitive (caught when the site is switched off).

Module 5 (`Marking/`):

- `storeWithBarriers` does the post-store check.
- `MarkerState.blockLive`; `traceObject` counts live bytes per block while
  a relocation is planned (it now loads the state word for byte objects
  too).
- `initialMark` calls `relocationAtInitialMark`; `runFinalMark`
  `relocationAtFinalMark` after its verifier; `applyInStop` and
  `abortCycle` `relocationAtCycleEnd`; `sweepCycle` tries the pending
  blocks between chunks; `markerLoop` and the manual `VM.sweep` run
  `relocatePass` before the sweep.

## Deviations

- **`pinRule` off turns off frame pins only.** With pins for good off too
  (the experiment's switch), the broken variant moved the running method's
  bytecodes; the old block was freed by epoch and reused as to-space while
  the worker's pc still pointed into it, and ThreadSanitizer reported
  `interpret` reading what `copyBody` had written. The variant now shows
  the frame-pinned object moving and the bytecodes staying.
- **The state word, slot loads and byte accesses are relaxed atomics**
  (the brief assumed module 1's plain loads would do). A plain mutator load
  racing the relocator's CAS or its relaxed stores into a new body is a
  data race to ThreadSanitizer and to C++; on arm64 the instruction is the
  same `ldr`. It changed code generation around the dispatch loop (see
  Measurements).
- **A relocation is planned by density**, not always: the brief's
  "zeroed at the initial mark, only when a relocation is planned" needed a
  planner; the last cycle's marked bytes over in-use bytes below 0.75.
- **Selected blocks leave the block pool** at the final mark (the SPEC
  relied on stamps alone): an in-use block with a tail is in the pool, and
  an allocator taking it during the pass would put bodies in it that the
  relocator does not move.
- **No timer at all**: the relocator retries freeing after every block, at
  the end of the pass and between sweep chunks; the sweeper's apply stop
  frees what is left. The one timer the brief allowed is not needed.
- **`pinsForGood: false` images** for module 2's two compaction tests, which
  get no relocation.
- **The relocation verifier does not run at literally every pause.** At
  every pause it made a host that polls every 0.5 ms (module 5's
  marker-thread tests poll the counters through stops) stop the world most
  of the time; the utility-QoS marker then missed those tests' 3 and 5 s
  bounds under ThreadSanitizer and under load (three failures in four
  loaded runs; module 5's tree: none in two). It runs at a pause that
  follows relocation work, and during a cycle not at the host's inspection
  stops (Verifier). With it off entirely, a cycle after idling under 24
  `yes` loops took 2 to 244 ms (module 5: 25 to 180; with the verifier at
  every pause after work: 40 to 306).
- The four model deviations above (held-slot count, two slots, poll
  cadence, byte stores).

## Tests

18 test functions in `Tests/KajoVMTests/Relocation/` (223 in the suite),
one random-program configuration, one barrier site.

**Ported from experiments/concurrent-relocation** (`RelocationTests.swift`,
`RelocationKernelTests.swift`): `relocationEvacuatesSparseBlocksAndKeepsTheObjects`,
`aStoreDuringRelocatingLandsInTheNewBody`, `withoutThePostStoreCheckTheStoreIsLost`
(the raw store), `aFramePinnedObjectIsNotMoved`,
`withoutThePinRuleTheFrameObjectIsMoved`, `aHazardedObjectIsSkipped`,
`withoutTheHazardCheckThePrimitivesStoreIsLost`,
`aBlockIsNotFreedBeforeEveryWorkersEpochPasses`,
`withoutTheEpochRuleBlocksAreFreedAtOnce`, `everyPauseFreesThePendingBlocks`,
`theVerifierCatchesABodyInAFreedBlock`,
`oldheapUnderAggressiveRelocationMatchesStopTheWorld`,
`fragmentUnderAggressiveRelocationMatchesStopTheWorld` (four workers, a
marker thread, a cycle at every scavenge, every live block selected in
every cycle with cap 0.9, every verifier; checksums equal to the oracle's;
fragment's run must wrap its ring so that keepers and array copies happen,
and asserts hazard slots were taken).

**New**: `aStoreIvarDuringRelocatingLandsInTheNewBody` (the interpreter's
barrier path, with the flag line it holds: the first store is redone after
the switch, the second goes straight to the new body),
`theArrayCopyPrimitiveStoresWithItsBarrier` (two hazard slots taken and
released, the remembered-set verifier before the next scavenge),
`enterVMStoresEpochZeroFirst` and its broken variant
`withoutTheEpochZeroAtEnterTheBlockIsFreedUnderTheWorker`,
`theRelocatorNeverParksWhileRelocating` (fragment with perturbation at 5
percent reaching the relocator between objects and inside every copy:
`perturbedCopies` at least twice the objects moved, zero parks while
relocating, more than ten stops); the random-program configuration
`relocateEveryLiveBlock` (four workers, 24 KiB nurseries, a cycle at every
scavenge, every live block in every cycle, cap 1, perturbation at 2
percent; every answer the model's, objects moved summed over the seeds
must be nonzero, zero parks while relocating); the barrier site
`arrayCopy` in module 4's site test (caught when switched off).

**The enter window.** The model's finding 1 needs a load that overtakes the
entering worker's buffered epoch store, which a test cannot force. The test
puts the overtaking load in a hook `enterVM` calls between its load of the
epoch and its store of it (`VM.setEnterWindow`): the entering worker loads
the kept object's state word there and lets the relocator (the test
thread, manual mode) evacuate its block and try to free it before it goes
on. With the 0 the word reads 0 and the block stays; without it the word
still reads quiescent and the block is freed under the offset the worker
holds. It is the model's trace with the store buffer replaced by the hook.

**Rules, each checked by breaking it**:

| rule | test | how broken | fails how |
|---|---|---|---|
| post-store check | `withoutThePostStoreCheckTheStoreIsLost` | the raw store (suite) | the store went into the old body only: slot reads its old value |
| frame pins | `withoutThePinRuleTheFrameObjectIsMoved` | switch `pinRule` (suite) | the frame's object moved |
| pins for good | (none in the suite) | `pinRule` off for both bits (hand run, the first version of the variant) | ThreadSanitizer: `interpret` reads to-space `copyBody` wrote (the running bytecodes moved and their block was reused) |
| hazard check | `withoutTheHazardCheckThePrimitivesStoreIsLost` | switch `hazardRule` (suite) | the object moved; the primitive's store through its pointer lost |
| epoch rule | `withoutTheEpochRuleBlocksAreFreedAtOnce` | switch `epochRule` (suite) | blocks freed while a worker inside the VM had not polled |
| the enter 0 | `withoutTheEpochZeroAtEnterTheBlockIsFreedUnderTheWorker` | switch `enterZero` (suite) | the block freed under the entering worker's offset |
| every pause frees | `everyPauseFreesThePendingBlocks` | (positive test) | |
| no park while relocating | `theRelocatorNeverParksWhileRelocating` | a park between the copy and the switch when the flag is set (hand run) | 6 parks while relocating; module 4's verifier "old entry 1780 has its body at 4299282064, outside old space" (the alias address) and the relocation verifier "entry 1780 is RELOCATING at a pause"; no deadlock that run (no mutator happened to spin on that object) |
| verifier | `theVerifierCatchesABodyInAFreedBlock` | a selected block freed by hand (suite) | "body in block b, which is free" |

**Found during development** (each fixed, in order):

- ThreadSanitizer: the first broken pin variant moved the running method's
  bytecodes; their block was freed by epoch and reused as to-space while
  the worker's pc pointed into it (`interpret` reading what `copyBody`
  wrote). `pinRule` now turns off frame pins only.
- ThreadSanitizer: a race between two tests' side tables (an old map and a
  mark map) that only shared an address: `vm_deallocate` and
  `vm_allocate` are not intercepted, so the shadow survived. Reservations
  are `mmap` and `munmap` now.
- ThreadSanitizer: a marker-thread test's cycle did not finish in 30 s.
  The relocator polled at every object while the flag was set, and the
  test's host polls (stops) every 0.5 ms: one object per stop. It polls
  every 64 objects or 16 KiB now.
- Under load (12 `yes`): module 5's marker-thread tests missed their 3 and
  5 s bounds in 3 of 4 runs (module 5's tree: 0 of 2). The relocation
  verifier, an O(entries) walk, ran at every one of those host stops and
  kept the world stopped most of the time. It runs after relocation work
  now; 0 of 5 loaded runs failed after (Gates).
- The first build's state-word atomics cost 4 to 6 percent on `arith`,
  `ivars`, `storeheavy` in aligned builds: a send and a return loaded the
  method's state word five times (atomic loads are not merged). Once now.
- `just test-release`: a 1.6-million-iteration `fragment` under
  perturbation in a 128 MiB heap ran out of module 4's promotion reserve
  (a trap): the perturbed relocator fell behind, old space filled with
  sparse blocks, and a full collection cannot free them. A provisioning
  failure of the test, resized.
- Under load, one run's final mark took 20 s: the marker requests it and
  is the stopper, at utility QoS, starved by twelve `yes` loops at default
  QoS. Module 5's QoS policy (utility unless headroom is low) applies to
  the stopper role too; recorded under Not done.
- `just ios-check` showed 21 `setIntSlot` calls not marked `unsafe` that
  the incremental macOS build had not reported (AGENTS.md).
- Module 1's heap verifier reported pending-dead entries "in block b, which
  is not in use" when a test stopped mid-sweep after an evacuation: a dead
  snapshot entry's body stays in the block the relocator freed until the
  sweep frees the entry. It skips pending-dead entries entirely now.

### Gates (final code, 73cce59)

`swift test`: 223 tests green (91 s). Under load (12 `yes`, load average
28 to 38), three runs: green (107 to 116 s); earlier versions of the code
failed module 5's marker-thread bounds under load (Found during
development), and the final policy's runs were 3 of 3 green, plus 2 of 2
in the comparison against module 5's tree before it. `swift test
--sanitize=thread`: 223 green, **zero sanitizer reports** (577 s), run
after the last code change; the two earlier reports (the pin variant, the
address reuse) are fixed above. `just test-release` green (with
`relocateEveryLiveBlock` at 100 seeds), `just golden` (arith 2569, fib
1664, sends 2509, alloc 2808, ivars 2075, walk 3482, storeheavy 2374 ms,
all ok), `just ios-check` clean (no warning), `just arc-check` zero retain
and release, one jump table (`interpret` 794 instructions; module 5: 775),
`just model-check` 15 and 28 tests green, `just soak` above; a clean build
has no warning.

## Hot-path check

`just arc-check` (final code) adds `postStoreSlow` and `postStoreSlowByte`
(62 instructions each; calls: `sched_yield`, the clock), `storeConflict`
(30; `postStoreSlow`, `rememberSlow`), `hazardAcquire` (67), `primReplace`
(205), `copySlots` (110; `rememberSlow`, `handOver`), `epochEnter` (29, no
call), `addPending` (88), `tryFreePending` (237; the pool lock), the pass
`relocatePass` (471; `markerPoll`, `addPending`, `tryFreePending`,
`copyBody`, the pool lock) and its copy loop (`relocCopy` then, 11
instructions, no call; since the collectors review the shared `copyBody`,
10): zero `swift_retain`/`swift_release` in every one; `interpret` one
indirect branch, one jump table, and the post-store check printed from its
`store_ivar` (the sequence under "Post-store check").

## Unsafe surface

Lines with the `unsafe` keyword (comment lines excluded), counted the same
way in module 5's tree (c6a8ef9) and this one: `Relocation/` 345 (Relocator
148, RelocationHost 53, Epoch 44, Hazard 37, RelocationState 31, PostStore
26, RelocationVerifier 6, RelocationConfig 0); `ObjectMemory/` 351 to 381
(the atomic state word, the checked stores, the pool operations, `mmap`);
`Workers/` 483 to 492; `Marking/` 533 to 548; `Interpreter/` 303 to 305;
`Processes/` 236 to 254 (the checked `setIntSlot` takes the worker pointer); `Nursery/` 451 to 452; the top-level files 4 to 9
(the report's `String(format:)`). A clean build (`.build/clean-check`, removed first) has no warning; `just ios-check` neither (it found 21 unmarked `setIntSlot` calls and two unused bindings an incremental build had hidden, AGENTS.md).

The surface is the state word and body words as `Atomic` over the table and
the heap (the CAS, the switch, the copy, the checked stores), the hazard and
epoch words in the shared lines, the relocator's state behind its pointer,
the pool's arrays under its lock, and `mmap`/`munmap`/`vm_map`.
`RelocatorState`, `RelocationShared` and `EnterWindowHook` are `@unsafe`;
the configuration, the counters, the records and the host surface
(`relocate`, the step functions, the counters and the log) are safe, so
tests need none. The verifier is almost entirely safe code (6 lines).

## Not done

- A cheaper store check (ADR 0007's pre-store check with a relocator
  handshake, or skipping recently written blocks): not built; the
  post-store check's cost is measured above.
- The array copy's seq_cst stores are not shown necessary by a test: the
  young-collection model's trace needs a concurrent young collector's
  clear-then-scan, which a stop-the-world scavenge cannot race. It waits
  for module 7.
- A separate relocator thread; parallel relocation.
- Context materialization's effect on frame pins (module 8); device runs
  and the 120 Hz scenarios (module 9); module 7's handshake.
- Large objects still live in blocks and relocate like anything else.
- The stopper role at utility QoS: the marker requests and runs the final
  mark and the apply stop; under load (twelve `yes` loops) one final mark
  took 20 s. Raising the marker for the duration of a stop it requests is
  module 5's QoS policy to decide; device measurement is module 9's.
- The pass's totals are added when it ends; a long pass under load shows
  zero moved until then (per-cycle counters mid-pass would need the
  relocator to publish them).
- The planner's density threshold, the sparse threshold and the cap are
  defaults, not tuned.

## The round under load, 2026-11-08

The first weekly run's `tsan-load` gate (ThreadSanitizer, the whole suite,
twelve `yes` loops) failed `fragmentUnderAggressiveRelocationMatchesStopTheWorld`
on its `cyclesSelected >= 2`: each of the three runs completed one selecting
cycle. **Cause**: the marker was starved, not the kernel short or the heap
dense. The third run's counters read `cyclesPlanned: 2, cyclesSelected: 1`,
one cycle completed, 10 457 objects moved, no verifier failure, checksums
equal, and the one relocation pass had 0.14 s of CPU in 4.19 s of wall
time (`passCpuNs` against `passWallNs`). The second cycle had been planned
at its initial mark, while the mutators ran, but had not reached its final
mark (where selection happens) when the kernel ended and the counters were
read. Every selecting final mark selects with `relocateEveryLiveBlock`, so
too little fragmentation is ruled out. Filtered, the same test saw 9 cycles
alone and 7 under the twelve loops; the starvation needed the whole suite
beside the loops.

**Change** (tests only): `underRelocation` lets a cycle the kernel started
finish before the round is counted. After the Processes terminate it waits
for the marking phase to be idle (600 s under the sanitizer, 120 s
otherwise; not reaching idle records an issue). The marker needs no
mutator for its final mark, pass and apply, and no new cycle starts without
scavenges. The assertion, the three runs and the iteration counts are
unchanged. `theRelocatorNeverParksWhileRelocating` does not wait. Each
round prints where it stood when its kernel ended (`relocation round:`
phase, cycles, planned, selected) and the marker's CPU, so the next failure
shows which case it was.

**Costs**: unchanged. In every round measured the kernel ended with the
marker idle and the wait took under 1 ms. The filtered test under the
sanitizer took 121 s alone and 206 s under the loops before. The ten runs
after took 197 to 224 s. In the gate the fragment test finished 569 s into
the suite, where it took 620 s alone and 680 s failing before.

**Runs** on the final code, ThreadSanitizer with the filter, twelve
`gtimeout yes` loops: 10 of 10 passed, 7 or 8 selecting cycles each, the
kernel 91 to 106 s, no retry. Without the sanitizer under the loops, 3 of 3
(8 or 9 cycles, 14 s). Once under 48 loops, 5 cycles, 464 s. The `tsan-load`
gate once: 385 + 121 tests passed, 0 ThreadSanitizer reports, 3504 s
(fragment 6 cycles, oldheap 4). None of those rounds ended with a cycle
running. The debug `swift test` of the check below did: its kernels are
short (11 to 12 s). The oldheap round ended marking with 3 of 4 cycles
selected and the fragment round marking with 2 of 3; the wait finished
them in 0.31 s and 2.07 s and both counted one more selecting cycle. A
starved marker can turn that "one more" into the second.

`just check` on 9c1dc2a (Swift tier, no fuzzer owed; ThreadSanitizer 385 +
121 tests, 0 reports; `swift test` 385 + 121; 205 kernel tests):

```
2026-11-08 10:48:47 9c1dc2a check-tier swift: 2 files from origin/master...HEAD (6dbf75f...9c1dc2a) and the working tree
2026-11-08 10:48:47 9c1dc2a start clean-build (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-08 10:49:09 9c1dc2a end clean-build rc=0 22s
2026-11-08 10:49:09 9c1dc2a start swift-test (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-08 10:56:06 9c1dc2a end swift-test rc=0 417s
2026-11-08 10:56:06 9c1dc2a start tsan (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-08 11:42:55 9c1dc2a end tsan rc=0 2809s
2026-11-08 11:42:55 9c1dc2a start kernel-test (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-08 11:44:11 9c1dc2a end kernel-test rc=0 76s
2026-11-08 11:44:11 9c1dc2a start apps (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-08 11:46:05 9c1dc2a end apps rc=0 114s
2026-11-08 11:46:05 9c1dc2a start new-check (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-08 11:49:08 9c1dc2a end new-check rc=0 183s
2026-11-08 11:49:08 9c1dc2a check-tier done swift failed=0 3621s
```

## Commands

```zsh
SCRATCH=<scratch>; git worktree add $SCRATCH/m5 c6a8ef9     # module 5's last code (0b8ab7e is the same code)
(cd $SCRATCH/m5 && swift build -c release --product kajo)
swift build -c release --product kajo --scratch-path .build/bench
A2=(-Xswiftc -Xllvm -Xswiftc -align-all-nofallthru-blocks=5 -Xswiftc -Xllvm -Xswiftc -align-loops=32)
(cd $SCRATCH/m5 && swift build -c release --product kajo --scratch-path .build/bench-a2 $A2)
swift build -c release --product kajo --scratch-path .build/bench-a2 $A2
# oldheapN.kasm: oldheap64.kasm with 64 -> N and 16000000 -> N * 250000
zsh bench.sh $M5 $M6 out.txt [kernels]   # interleaved, five runs, 1 and 8 workers
zsh frag.sh frag.txt                       # fragment reclaim, --heap 240
zsh agg256.sh agg.txt                      # oldheap 256 MiB, every live block every cycle, vs --gc stw
python3 agg.py out.txt                     # medians (min to max)
for i in $(seq 12); do gtimeout 1500 yes > /dev/null & done; swift test; pkill -x yes
swift test --sanitize=thread --scratch-path .build/tsan-check
just ios-check; just arc-check; just golden; just test-release; just model-check; just soak
```

The scripts (one line per run: kernel, workers, binary or configuration,
run, then `key=value` pairs from `kajo run`):

```zsh
# bench.sh <m5 kajo> <m6 kajo> <out> [kernels]: for run 1..5, kernel, workers 1 and 8, binary m5 then m6:
#   kajo run prelude lib <kernel> --workers $w --slice-ms 0
#   oldheapN: kajo run prelude lib oldheap oldheapN --workers $w --heap $((2*N+64)) --nursery 4096 --age 2 --slice-ms 0
# frag.sh: for run 1..5, workers 1 and 8, configuration off | default | everycycle | everyblock:
#   kajo run prelude lib fragment fragmentIters --workers $w --heap 240 --slice-ms 0 --sample-ms 100
#     --reloc off | --reloc on | --stress cycle,everycycle | --stress cycle,everycycle,everyblock --reloc-cap 0.9
# agg256.sh: for run 1..5, workers 8 and 1, --gc stw then --stress cycle,everycycle,everyblock --reloc-cap 0.9:
#   kajo run prelude lib oldheap oldheap256 --workers $w --heap 576 --slice-ms 0
```
