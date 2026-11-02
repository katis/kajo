# Model check: the entry state machine of concurrent relocation

Status: built (2026-11-02). `docs/VERIFICATION.md` layer 6: done before
module 6 (concurrent relocation) is written, kept beside the module and
updated when the protocol changes. Any change to the copy protocol, the
post-store check, hazard slots or epoch freeing updates `models/` in the
same commit, with the table in "Steps and names" below.

Run it:

```
cd models && swift test
```

About 7 s to build from clean and 13 s to run all 15 tests on the M2 Max
(2.3 GB resident at peak, the three-mutator configuration). Every
configuration prints its state count, longest trace and time; every
violation prints its interleaving as a numbered list of steps.

## What is modelled

ADR 0007's copy protocol as specified in
`experiments/concurrent-relocation/SPEC.md` Part 2 ("Entry state encoding",
"Copy protocol", "Pins and hazards", "Freeing old blocks: epochs"), with the
step order of the experiment's code (`swift/Sources/VMR/Relocation.swift`,
`Memory.swift`, `VM.swift`). The claims, and how the model checks each:

1. **No lost store.** A mutator store into a slot of an object that is being
   relocated is visible in the body the entry leads to after the switch,
   whatever the interleaving. Checked twice: a mutator reading a slot it
   writes must read its own last completed store, and at the end of every
   finished run each written slot, read through the entry's final offset,
   holds its writer's last completed store. Each slot has one writer, so
   "last" is well defined.
2. **No stale read.** A mutator read after the switch reads the new body,
   and a read during RELOCATING reads the intact old body; no read ever sees
   uninitialised to-space. Checked at every read: to-space starts
   `uninit`, and a read returning it is a violation. (A read that loaded the
   old offset before the switch and reads the old body after it is allowed:
   it linearizes before the switch. Reading the old body after it was freed
   is claim 4.)
3. **No hazarded move.** An object under a worker's hazard slot is never
   switched while the hazard is held. Checked at the relocator's switch: no
   mutator may be between taking its body pointer and releasing the hazard
   for that object.
4. **No premature free.** A block is freed only when no worker can still
   hold a body pointer into it. Checked at the moment of freeing (by the
   epoch rule or by a pause): no mutator is in the middle of an instruction
   holding an old-block body offset, and no thread has a store to the block
   still in its store buffer. Also checked at every access and every buffer
   drain: nothing touches the block after it is freed.
5. **No RELOCATING at a pause.** When the world is stopped no offset word in
   memory has the RELOCATING bit.

Plus **no deadlock**: a state where no thread can move and the run is not
finished is a violation. (Livelock is not checked; see "Limits".)

## The model

`models/` is its own SwiftPM package (`kajo-models`), so it never slows the
VM's build.

| file | contents |
|---|---|
| `Sources/ModelKit/MemoryModel.swift` | shared words and per-thread store buffers; the rules below (shared with the young-collection model) |
| `Sources/RelocationModel/Configuration.swift` | instructions, the four switches and three probes, the three configurations |
| `Sources/RelocationModel/Relocation.swift` | the claims, the memory layout, the state, every thread's steps |
| `Sources/ModelKit/Explorer.swift` | breadth-first search, traces, reports (generic, shared) |
| `Sources/RelocationModel/Exploration.swift` | the model on the shared explorer |
| `Tests/RelocationModelTests/RelocationModelTests.swift` | the claims hold; each rule is needed (traces in comments); probes |
| `Tests/RelocationModelTests/MemoryModelTests.swift` | litmus tests of the memory model |

**Threads.** Two mutators (three in one configuration), one relocator (R),
one stopper (S). Every step is one atomic action of one thread or one
store-buffer drain; the explorer interleaves all of them.

**Shared memory.** One offset word per object (NORMAL `old(o)`, RELOCATING
`old(o)+R`, switched `new(o)`), one hazard word and one epoch word per
mutator, the global epoch E, the old bodies (one block) and the new bodies
(to-space, initially `uninit`). An offset with R leads to the old body, as
the double mapping does in the experiment.

**Mutator instructions** (a program per mutator; a mutator holds no body
pointer between instructions, as the interpreter holds none between
bytecodes; a program still in the VM at its end leaves it):

- `store o.s := v`: load the offset (relaxed); store the slot through it
  (seq_cst); reload the offset (seq_cst); if it changed or had R,
  `postStoreSlow`: spin while R (acquire loads), store into the current body
  (seq_cst), reload (seq_cst), repeat until unchanged.
- `read o.s`: load the offset (relaxed); load the slot through it (relaxed).
- `hazard o.s := v` (the `arrayCopy` primitive): hazard word := o (seq_cst);
  spin until the offset (seq_cst) has no R, which gives the body pointer p;
  store v through p (relaxed, no post-store check); read it back through p;
  hazard word := 0 (release).
- `poll` (the poll slow path and `safepoint`): E (acquire); epoch word := E
  (release); park if a pause is requested.
- `leaveVM`: epoch word := quiescent (release); leave under the VM mutex.
- `enterVM`: wait under the mutex while a pause is requested; epoch word :=
  0 (seq_cst); E (seq_cst); epoch word := E (release).

**Relocator**, for each object of the one block in order: poll (park if a
pause is requested); CAS the offset `old -> old+R` (seq_cst) and fence
(seq_cst); read every hazard word (seq_cst), and on a match store `old`
back (release), mark the block skipped and go to the next object; copy slot
by slot (relaxed load, relaxed store); switch: store `new` (release). After
the last object, if nothing was skipped: `addPending` (record s = E,
E += 1, seq_cst fetch-and-add), then `tryFreePending`: read every epoch word
(acquire) and free the block if all are greater than s, else poll and try
again.

**Stopper**: may request a pause at any step (once, or twice in the
contended configuration). When every mutator in the VM is parked and the
relocator is parked (or finished, with its buffer drained), the world is
stopped: claim 5 is checked, the pending block is freed (SPEC: every pause
frees all pending blocks first), and the world is released.

### Steps and names

The model's steps against the SPEC sections, the experiment's functions and
the names module 6 will use. Module 6's brief should require that any change
to a row updates the model in the same commit.

| model step (trace prefix) | SPEC.md Part 2 | experiment | module 6 |
|---|---|---|---|
| `M store: e1 = offset (relaxed)` | Copy protocol, post-store check, line 1 | `setSlot` | store path (`setSlot`) |
| `M store: slot := v (seq_cst)` | post-store check, line 2 | `setSlot` | store path |
| `M store: e2 = offset (seq_cst)`, compare | post-store check, lines 3 to 4 | `setSlot` | store path |
| `M store: postStoreSlow: ...` (spin, redo, reload) | "Slow path" | `postStoreSlow`, `storeConflict` | `postStoreSlow` |
| `M read: offset (relaxed), slot (relaxed)` | Entry state encoding (reads need no barrier) | slot reads in `Interp.swift` | read path |
| `M hazard: hz := o (seq_cst)`, `offset (seq_cst)` spin | Pins and hazards, "Hazard slots" | `hazardAcquire` | `hazard` acquire |
| `M hazard: ... through p` | Hazard slots (accesses through p) | `arrayCopy` primitive | primitive body |
| `M hazard: hz := 0 (release)` | Hazard slots | `hazardRelease` | `hazard` release |
| `M poll: E (acquire)`, `epoch[M] := E (release)`, park | Freeing old blocks: epochs; safepoint | `advanceEpoch`, `safepoint`, `pollSlow` | `epoch` advance |
| `M leaveVM` | epochs ("leaveVM stores quiescent") | `quiesce`, `leaveVM` | `epoch` quiesce |
| `M enterVM` (mutex, 0 seq_cst, E seq_cst, E release) | epochs ("enterVM stores the current E"; the 0 is in the code only) | `enterVM` | `epoch` enter |
| `R poll` | Copy protocol (polls only between objects); Phases | `relocPass` (`gcRequested`, `markerSafepoint`) | `relocate` |
| `R relocate: CAS ... fence` | Copy protocol step 4 | `relocBegin` | `relocate` |
| `R relocate: hz[M] (seq_cst)`, revert (release) | step 5 | `hazarded`, `relocRevert` | `relocate` / `hazard` |
| `R relocate: copy` | step 6 | `relocCopy` | `relocate` |
| `R relocate: switch (release)` | step 7 | `relocSwitch` | `relocate` |
| `R addPending (seq_cst fetch_add)` | step 8; epochs | `addPending` | `epoch` |
| `R tryFreePending: epoch[M] (acquire)`, free | epochs | `tryFreePending(atPause: false)` | `epoch` |
| `S requests a pause`, `S world stopped ...` | epochs ("every pause frees"); Verifier ("no entry is RELOCATING") | `tryFreePending(atPause: true)`, `relocVerify` | pause hook |
| `drain` | (memory model) | hardware | |

Not modelled: copy-protocol steps 1 to 3 (the walk by back references, the
pin skip, to-space allocation), pins, the selection of the relocation set,
the sweep and the apply.

## Memory model

`MemoryModel.swift`, in prose:

- **Shared memory is one array of words**, read and written atomically. A
  store, once it leaves its thread, is visible to every thread at once: the
  model is multicopy atomic, as ARMv8 and x86 are.
- **Every store goes into the issuing thread's store buffer**, whatever its
  order. A load reads the thread's own newest buffered store to that address
  if there is one (forwarding), else shared memory. A load can therefore
  overtake its thread's earlier stores to other addresses: store-to-load
  reordering, the reordering that breaks Dekker-style protocols such as the
  post-store check and the hazard check.
- **seq_cst stores and loads form one total order**: a seq_cst load is
  enabled only when its thread has no seq_cst store buffered. A release
  store followed by an acquire or a seq_cst load, and a seq_cst store
  followed by an acquire load, may still be reordered, as C++ allows.
- **Buffers drain one store at a time**, as separate steps interleaved with
  everything else. A release or seq_cst store drains only when it is the
  oldest entry (everything before it becomes visible first). A relaxed store
  may drain ahead of older entries to other addresses (relaxed stores
  reorder with each other and may pass an earlier release store), never
  ahead of an older store to the same address (coherence).
- **seq_cst read-modify-writes, seq_cst fences and the VM mutex are full
  fences**: enabled only with an empty buffer, then act on shared memory. The
  relocator's CAS and its following fence are therefore one step; the fence
  adds nothing the CAS does not already do in this model.
- The stopper's `gcRequested` and park/unpark are modelled as atomic actions
  under the mutex.
- **Extension (2026-11-02, for `docs/models/young-collection.md`)**:
  `Memory(sequentiallyConsistent: true)` has no store buffers; every store
  reaches shared memory at its step. The relocation model does not use it.
  `readModifyWrite` is a helper for the full-fence rule above.

**Litmus tests** (`MemoryModelTests.swift`) pin the abstraction down:

| shape | allowed by the model |
|---|---|
| store buffering, release stores / acquire loads | yes (both read 0) |
| store buffering, seq_cst store / acquire load | yes |
| store buffering, release store / seq_cst load | yes |
| store buffering, seq_cst / seq_cst | no |
| message passing, release flag | no |
| message passing, relaxed flag | yes |
| two stores to one address read out of order | no |
| independent reads of independent writes (IRIW) | no (multicopy atomic) |

### Limits

This is not a full ARMv8 or C++ model. It mixes the two on purpose: C++
rules for which orderings pair (so it does not credit ARMv8's `stlr` +
`ldar` with more than Swift promises), hardware rules for visibility.

- **No load-to-load or load-to-store reordering.** Loads happen in program
  order at the instant of their step. This gives address dependencies for
  free: the mutator's relaxed load of the offset followed by a load through
  it is ordered, which is SPEC's "RCU / consume" argument. The model assumes
  it; it cannot check it.
- **Multicopy atomic.** No IRIW-style disagreement between threads about the
  order of independent stores, which C++ allows for anything weaker than
  seq_cst. A protocol argument that needs the C++ total order S where the
  code uses acquire is not caught (see "What the model found", item 2).
- **No speculation, no compiler reordering** beyond what the orderings allow.
- **One cycle, one block, one hazard slot per mutator, bounded programs.**
  No second relocation of the same object, no reuse of a freed block, no ABA
  across cycles.
- **Safety only.** Deadlocks (no step possible, run unfinished) are found;
  livelocks and starvation are not.
- **Hash compaction.** The visited set keeps a 64-bit fingerprint per state,
  not the state. A collision would prune a state unexplored; with 5.2
  million states the chance of any collision is about 10^-6.

## Results

Each configuration explored completely. "Longest trace" is the largest
number of steps from the start to any reached state on a shortest path
(breadth-first depth). Times are with the model library compiled `-O` in a
debug build of the package (see "Choices"); `-Onone` times in parentheses.

| configuration | states | transitions | longest trace | finished states | time |
|---|--:|--:|--:|--:|--:|
| standard: 2 mutators, 2 objects x 1 slot, 1 pause | 128,209 | 431,442 | 58 | 72 | 0.2 s (5.5 s) |
| contended: 2 mutators storing into both objects, 2 slots, 2 pauses | 484,461 | 1,641,337 | 68 | 284 | 1.0 s (13.4 s) |
| three mutators: standard plus M2, 2 slots | 5,245,416 | 23,110,302 | 74 | 272 | 12.2 s (141 s) |
| postStoreCheck off | 144,163 | 494,385 | 57 | 72 | 0.4 s |
| hazardCheck off | 146,389 | 501,940 | 54 | 56 | 0.4 s |
| epochRule off | 87,567 | 291,340 | 55 | 48 | 0.2 s |
| seqCstStoreReload off | 196,539 | 704,101 | 58 | 72 | 0.5 s |
| probe: enterVM without the 0 | 123,263 | 415,028 | 56 | 72 | 0.3 s |
| probe: relaxed switch | 226,167 | 765,765 | 62 | 72 | 0.5 s |
| probe: relocator polls while RELOCATING | 137,180 | 458,457 | 60 | 72 | 0.3 s |

The configurations (`Configuration.swift`):

- **standard**: M0 `store o0`, `poll`, `read o0`. M1 `hazard o1`,
  `leaveVM`, `enterVM`, `read o1`.
- **contended**: M0 `store o0.s0`, `poll`, `store o1.s0`, `read o0.s1`.
  M1 `store o0.s1`, `hazard o1.s1`, `poll`, `read o1.s0`. Two mutators
  store into one object at once; M0 stores into o1 while M1 may hold it
  under its hazard, so a store meets a revert.
- **three mutators**: standard with two slots per body plus M2
  `store o1.s1`, `read o0`; M2 never polls.

All five claims hold in all three; no deadlock.

### Negative tests

Each turns one rule off in the standard configuration, finds the claim it
protects broken, and has the shortest violating trace in a comment above it
in `RelocationModelTests.swift`. In short:

| switch off | claim broken | how (shortest trace) |
|---|---|---|
| `postStoreCheck` | 1 | M0 loads `old(o0)` and stores 1, buffered. R CASes, copies the slot (0) and switches. M0's store drains into the old body after the copy; M0 reads 0 from the new body. 17 steps. |
| `hazardCheck` | 3 (and 1) | M1 publishes its hazard and takes p into `old(o1)`; R moves o0, then CASes o1, copies and switches it while M1 holds p. 13 steps. Without the claim-3 check the store through p is lost (claim 1, 30 steps). |
| `epochRule` | 4 | M0 loads `old(o0)`; R moves both objects and frees the block at once while M0 is about to store through its offset. 19 steps. |
| `seqCstStoreReload` | 1 | M0 stores 1 (release, buffered) and its acquire reload overtakes the store, reads `old(o0)` and finishes. R CASes, copies 0, switches; the store drains into the old body; M0 reads 0. 18 steps. The AGENTS.md lesson, reproduced. |

Neither half alone is enough either: with the store seq_cst and the reload
acquire, or the store release and the reload seq_cst, claim 1 fails the same
way (checked by hand-editing the orders; not kept as tests). On ARMv8 the
second (`stlr` + `ldar`) would hold in hardware, but Swift's atomics do not
promise it.

**Probes** (not the brief's switches; they give claims 2 and 5 negative
evidence and test rules the brief did not name):

| probe | claim broken | how |
|---|---|---|
| `enterPublishesZeroFirst` off | 4 | M1 re-enters, reads E = 0 and stores epoch 0 (release, buffered), loads `old(o1)`. R moves o1, adds the block pending with s = 0, reads M1's epoch word as still quiescent (the 0 is in M1's buffer) and frees the block under M1's pointer. 42 steps. |
| `switchOrder` relaxed | 2 (and 1) | the switch drains before the copy's store; M0 reads `uninit` from the new body. 17 steps. |
| `relocatorPollsOnlyBetweenObjects` off | 5 and deadlock | R parks right after its CAS; the world stops with o0 RELOCATING (24 steps). Or M0's post-store check sees R and spins in `postStoreSlow` while R waits in the pause for M0 to park: deadlock (19 steps). |

## What the model found

In order of how much module 6 should care. Items 2 and 6 are arguments,
not traces: the model cannot show them.

1. **The `enterVM` 0 is load-bearing and only in the code.** SPEC.md says
   "`enterVM` stores the current E"; the experiment's `enterVM` first
   stores 0 (seq_cst) and then the epoch, with a comment explaining why.
   Without the 0 the explorer frees a block under an entering worker's body
   pointer (probe above). Module 6's brief and SPEC should state the 0, and
   module 6 needs a test that fails without it.
2. **`tryFreePending` reads the epoch words with acquire, but the enter
   argument needs them in the seq_cst order.** The argument is: "a
   relocator that read the quiescent value before the 0 incremented the
   epoch before this load". Under C++ rules, the worker's store of 0 and its
   load of E are seq_cst, the relocator's fetch-and-add of E is seq_cst, but
   its acquire load of the epoch word is not in the total order S, and
   nothing makes the store of 0 happen before it. C++ allows that load to
   still return quiescent after the worker read the old E, and then the
   block is freed under a pointer the worker loaded. On ARMv8 and x86
   (multicopy atomic) it cannot happen, and this model is multicopy atomic,
   so it passes. Making the epoch-word loads in `tryFreePending` seq_cst (or
   putting a seq_cst fence before the scan) makes the argument hold as
   written, off the hot path, at no measurable cost. Recommended for
   module 6.
3. **A relocator that ends its pass with a revert still buffered is not yet
   "between objects".** The model's first run reported an entry RELOCATING
   at a pause: the relocator had reverted the last object (a release store)
   and finished, and the stopper counted it as stopped before the revert was
   visible. In the experiment the relocator only stops by taking the VM
   mutex, which drains it, so the bug is the model's, but the SPEC's reason
   for claim 5 ("the relocator polls only between objects") silently relies
   on that fence. Module 6 should say it: the relocator is counted stopped
   only after a full fence that follows its last switch or revert.
4. **"Polls only between objects" is a liveness rule before it is a
   verifier rule.** A relocator that could park between the CAS and the
   switch or revert deadlocks with any mutator spinning in
   `postStoreSlow` or in the hazard wait, neither of which polls. The same
   holds for anything that can park inside an object: to-space allocation
   (step 3, a TLAB refill) must stay before the CAS, as it is in the
   experiment's `relocateOne`. Worth a sentence and an assertion in module 6.
5. **Both the store and the reload of the post-store check must be
   seq_cst**, each on its own; see the negative tests above.
6. **Reads of the new body rest on address dependency.** The model gives
   load-to-load order for free, so it cannot check SPEC's RCU/consume
   argument for the mutator's relaxed offset load followed by the body load.
   Hardware respects the dependency; the compiler does not promise to keep
   it. Module 6 must compute the body address from the loaded offset and
   never from a value the compiler could substitute (a cached or compared
   offset).
7. Nothing questionable found in the post-store check, the hazard protocol,
   the switch or the epoch rule as specified: with every switch on, every
   configuration holds with no deadlock.

## Choices

- **Breadth-first, not depth-first.** The brief asked for depth-first.
  Breadth-first gives the shortest violating interleaving for each claim,
  which is what a human reads into a test; "longest trace" is reported as
  the breadth-first depth.
- **Hash compaction**: the visited set holds 64-bit fingerprints (TLC does
  the same). Collision chance under 10^-6 at the largest configuration.
- **The model library is compiled `-O` even in debug builds** (an
  `unsafeFlags` setting in `models/Package.swift`; the package is never a
  dependency). Without it the whole `swift test` takes 141 s in debug,
  dominated by the three-mutator configuration; with it, 13 s. The brief's
  "under a minute in debug" is read as "plain `swift test`".
- **All stores are buffered, seq_cst ones included**; a seq_cst load waits
  for its thread's seq_cst stores. This is weaker than draining at every
  seq_cst operation (the brief's suggestion) and closer to C++ and ARMv8.
- **One hazard slot per mutator** (SPEC has two per worker); one primitive
  holds one object here.
- **One block for all old bodies**, as the brief says; a hazard skip on
  either object keeps the block.
- **The relocator is not an epoch participant**: it is the one freeing, and
  holds body pointers only inside the copy of one object.
- **Freeing takes effect at once** in global memory, without the free-list
  publication; strict, since any later access is then a violation.
- **The copy's load and store are one step.** Nobody else reads or writes
  the new body before the switch, so splitting them adds states and no
  behaviour.
- **The pointer a mutator "holds"** for claim 4 is the register of an
  instruction between loading the offset and its last use of the body: store
  and slow-path store issue, read, the two accesses through a hazard
  pointer. Interpreter-cached pointers are pinned objects, which are not
  relocated and not modelled.
- **Three probes beyond the four switches**: the `enterVM` 0, the switch's
  order, and polling while RELOCATING. They cost a second each and give
  claims 2 and 5 negative tests.
- **Third-mutator configuration**: full size (5.2 million states) fits the
  time budget with the optimised library, so it was not shrunk.
