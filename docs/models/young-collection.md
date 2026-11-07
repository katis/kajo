# Model check: handshakes, epochs and entry ownership of young collection without stopping the world

Status: built (2026-11-02). `docs/VERIFICATION.md` layer 6: done before
module 7 (young collection without stopping the world) is written, kept
beside the module and updated when the protocol changes. Any change to the
rounds, the barriers, the remembered-set protocol, the epoch rule or the
deferred entry frees updates `models/` in the same commit, with the table in
"Steps and names" below. Builds on the relocation model
(`docs/models/relocation.md`): same package, same memory model and explorer
(now the shared `ModelKit` target), same conventions.

Run it:

```
cd models && swift test
```

About 10 s to build from clean. The whole package's tests (both models,
43 tests) take 21 to 31 s wall on the M2 Max depending on what else runs,
2.9 GB resident at peak (the relocation model's three-mutator
configuration); the 28 young-collection tests take 5 s in parallel and 20 s
one after another (`swift test --filter YoungCollectionModelTests
--no-parallel`), half of it the two `chain` configurations. Every configuration prints its state count, longest trace
and time; every violation prints its interleaving as a numbered list of
steps.

Module 7 is built (2026-11-03): docs/modules/young-collection.md, "The
model and the code", maps every step below to its production function. No
step changed order, so the model is unchanged; what the production code adds
beyond it (the collector thread as a round and epoch participant, deferred
frees released at stop-the-world pauses, batched acknowledgements) is argued
there under Deviations.

## What the model found

In order of how much module 7 should care. Items marked "reasoning" are
arguments the model cannot show at its abstraction; the rest have a trace
or an exhaustive result.

1. **`primArrayCopy`'s store loses a remembered holder (trace).** The
   primitive stores under a hazard slot with a relaxed store and no
   post-store check, then runs the insertion barrier, whose `remember`
   loads the remembered word with seq_cst. A seq_cst load does not wait for
   an earlier relaxed store (C++, and ARMv8: `str` then `ldar` may
   reorder). So the storer reads the membership bit as set before the
   collector's `fetch_and` clears it, the collector then reads the holder's
   slot before the store is visible, and neither re-arms the holder. This
   collection survives on the storer's stack root; the next collection of
   the nursery frees what only that holder names. SPEC point 2's argument
   ("the storer's `stlr` store, then its seq_cst load") holds only for the
   interpreter's store, which is seq_cst. Test
   `Probes.theArrayCopyStoreLosesARememberedHolder`, 95 steps. Module 7 (or
   module 4, wherever the copy primitive lands) must make those stores
   seq_cst, or put a seq_cst fence between the copy loop's stores and the
   barrier loads, with a test that fails without it.
2. **The snoop (amendment 7b) is not needed by any modelled interleaving
   once the new-half scan (7a) is on (exhaustive in two configurations, and
   reasoning).** With the scan alone both `new half` configurations hold;
   with the snoop alone a barriered store holds but the allocation's own
   initialising store (no barrier, amendment 13) loses the object
   (`Probes.theSnoopAloneMissesAnInitialisingStore`, 47 steps). The
   argument: the scan covers every new-half object allocated before the
   owner's H1 acknowledgement; anything the owner stores after that it
   obtained after its own stack scan, from a heap slot, which SATB covers
   (the slot still holds it at T1, or its overwrite was recorded). The
   experiment's own test shows either rule alone saving its case. Module 7
   should either drop the snoop with a test showing the scan suffices, or
   keep it as a documented second line; it is barrier slow-path work on
   every store while the owner's collection runs.
3. **The wake from a quiescent wait has `enterVM`'s problem without
   `enterVM`'s fix (reasoning).** `waitServicing` quiesces, waits, and on
   wake runs `advanceEpoch` (acquire load of E, release store of the word)
   under the mutex, then unlocks and returns to code that may take a body
   pointer. The model, by the shared convention, treats the unlock as a
   full fence, so it shows no window. An unlock is only a release: a later
   relaxed offset load can be satisfied before the epoch store is visible,
   while the collector's epoch scan still reads quiescent; that is the
   store-buffering shape `enterVM` closes by storing 0 (seq_cst) and
   loading E (seq_cst) first (relocation model, finding 1). Module 7's wake
   path should do what `enterVM` does.
4. **The remembered-word load's order is masked by the post-store check
   (exhaustive, and reasoning).** With `remember`'s load weakened to
   relaxed, the model still holds: the interpreter store's post-store check
   reloads the offset word with seq_cst between the store and the barrier,
   and in this model (as on ARMv8, where `ldar` orders later loads) the
   relaxed load cannot pass it. C++ does not promise that: a relaxed load
   after a seq_cst load of another location is not in the total order. The
   brief's negative fails only with the reload taken out
   (`claim6WithARelaxedRememberedWordLoadAHolderIsLost`); with the reload
   out and both orders seq_cst it holds (`Probes.
   theSeqCstStoreAndLoadAloneKeepTheHolder`), which is SPEC point 2's
   argument on its own. Keep the seq_cst load; do not lean on the reload.
5. **SPEC says `blockingEnd` services rounds opened meanwhile; the code does
   not (reasoning).** Harmless: rounds opened during the region were
   acknowledged by proxy with the stack scanned. The model follows the code.
6. **Stopping after one drain round is unsound, and the model can show it**
   (`chain`, 63 steps): a record a worker makes after acknowledging the
   first drain round is published only in the second. "First round that
   copied nothing" holds. The brief's other alternative, "first round that
   found nothing new", cannot be told apart from "copied nothing" here: a
   record is new to the collection exactly when visiting it copies an
   object, since marking is the copy.
7. Nothing questionable found in H0 (including its clearing of deletion
   records made before it), H1, T1's order, termination, the epoch rule,
   blocking regions keeping their epoch, quiescent waiters (amendment 14),
   or amendment 17's ownership rule: with every switch on, every
   configuration holds with no deadlock.

## What is modelled

ADR 0008's protocol as specified in `experiments/concurrent-young/SPEC.md`
("Handshakes", "Part 1: local collection", "Ordering and soundness", "Part
2: offloaded collection", amendments 7, 9, 10, 14, 16 and 17), with the step
order of the experiment's code (`swift/Sources/VMR/Young.swift`,
`Memory.swift`, `VM.swift`, `Interp.swift`). A collection is a concurrent
mark of Y_k whose action on a marked object is the copy: the model has marks
and edges, not bodies, except for the body pointers of claim 4.

The claims, and how the model checks each:

1. **No lost object.** At the entry sweep, an unmarked Y_k object that any
   worker can reach (from registers and global roots, through slot words in
   memory and stores still in a buffer) is a violation. Any use of a free
   entry by a worker is one too.
2. **The barrier-on round is necessary.** With H0 off (the flag is raised at
   the open and H1 is the only round) the explorer must find SPEC point 4's
   interleaving with store buffers disabled. It does, step for step (below).
3. **Termination is sound.** When the collector decides to stop marking,
   every Y_k object a worker can reach must be marked. Checked at the
   decision; a violation ends its path, so negatives for claims 2, 6 and 7
   switch this check off (`terminationCheck`) to run on to the free itself.
4. **No premature reuse.** In configurations with body pointers, a load
   takes a pointer from the object's offset word (old body or copy) in one
   step and reads through it in a later one. When the collector reuses the
   old eden (after the epoch rule), no worker may hold a pointer into an old
   body, and no read may go through one afterwards.
5. **Exactly one owner per entry state.** A deferred entry is
   `deferred(k)`: used, dead, in no young log. The nursery's deferred free
   of an entry that is no longer `deferred(k)` is a violation (the
   old-space collector freed it, and maybe a worker reused it), and so is
   the old-space sweep freeing a snapshot entry that is already free or
   that a worker reused since the snapshot.
6. **Remembered-set re-arm.** Shown end to end: a holder lost from the
   remembered set in one collection makes the next collection of the
   nursery free what only it names (claim 1).
7. **The owner's new eden half.** Shown as claim 1: with neither the
   new-half scan nor the snoop, the collector frees an object only a
   new-half object holds.

Plus **no deadlock**: a state where no thread can move and the run is not
finished is a violation. Livelock is not checked.

## The model

| file | contents |
|---|---|
| `Sources/ModelKit/MemoryModel.swift` | the shared memory model (moved from `RelocationModel`), with the extension below |
| `Sources/ModelKit/Explorer.swift` | the shared breadth-first explorer, generic over `ExplorableModel` |
| `Sources/YoungCollectionModel/Configuration.swift` | instructions, the switches, the nine configurations |
| `Sources/YoungCollectionModel/YoungCollection.swift` | claims, memory layout, state, every thread's steps |
| `Tests/YoungCollectionModelTests/YoungCollectionModelTests.swift` | the claims hold; each rule is needed (traces in comments); probes; the memory-model extension |

**Threads.** Two or three workers (participants: they acknowledge rounds,
hold registers, have epoch words); in `local` each worker owns the nursery
of its index and collects it inside its `collect` instruction; in `offload`
worker 0 owns nursery 0 and flips, and a collector thread C (not a
participant) collects. An old-space collector O takes the initial-mark
snapshot and sweeps, or runs a full collection; it is also the stopper.
Every step is one atomic action of one thread or one store-buffer drain.

**Shared memory** (the memory model's words): per object its slot words,
its remembered word (bit n: member of nursery n's set; bit 8 + n: pending,
amendment 9), its header's slot count (1, or 0 once a dead holder's free is
deferred, amendment 10) and its offset word (old body or copy); the
barrier word; `collecting[n]` per nursery; an epoch word per worker; the
global epoch E. Under the mutex, outside the memory model: each nursery's
round number, kind, `need`, acknowledgements, handed roots and buffers,
recorded new-half range, carried, next-carried and deferred lists; each
object's entry state (free, old, young in n, deferred in n), whether it is
in Y and marked; `ycActive` and `stwWanted`.

The model's barrier word is module 7's count (bits 1 and up of the VM's
word, one per open collection here). Module 5's marking bit (bit 0) is not
modelled: marking sets and clears it only in stops, every stop waits until
no collection is open (`waitForCollectionsLocked`) and no collection opens
while a stop is wanted or requested, so a marking write never lands while
a collection is open. Since the collectors review (finding 4) marking
writes bit 0 alone with an atomic or and and, so even a stop that did
overlap could not erase the count; before, it stored the whole word, and
the stress flag `barrierAlwaysOn`'s count was lost at the first cycle. The
stop verifier checks the word at every stop.

**Worker instructions** (a program per worker; a worker holds no body
pointer between instructions; a worker still in the VM at its end leaves):

- `load r := x.s`: one relaxed load of the slot; with body pointers, first
  the offset word (relaxed) and then the slot through the pointer.
- `store x.s := r` (the interpreter, `storeWithBarriers`): barrier word
  (relaxed); if nonzero, the young deletion barrier (old value relaxed,
  `collecting[n]` acquire, push on `del[n]`) and the snoop's condition; the
  snoop's `remember` (before the store, as in `preStoreSlow`); the store
  (seq_cst); the post-store check's reload of the offset word (seq_cst);
  the insertion barrier: if the value is young in another nursery than the
  holder, `remember` = load of the remembered word (seq_cst), and if the
  bit is clear `fetch_or` and push on `rem[n]` if this call set it.
- `arrayCopy x.s := r` (`primArrayCopy`'s per-slot body): the same with a
  relaxed store and no reload.
- `drop r`; `poll`: service every owed round (each one mutex step: H0 clears
  `del[k]`; H1 scans the registers for Y_k, publishes `rem[k]` and
  `del[k]`, and the offload owner records its new-half range; a drain
  round publishes), then advance the epoch word (E acquire, word release).
- `alloc r := o`: into a free entry, young in the worker's nursery (in
  offload, in the new half: not in Y), slot 0 initialised with a plain
  relaxed store and no barrier (amendment 13).
- `flip` (offload) and `collect` (local): wait while `stwWanted` or the
  nursery's collection is active (servicing rounds, quiescent); worker 0,
  the main worker, waits while `stwWanted` only after it has opened one
  collection since O set it (`mainOpensWhileWanted`, the final mark on the
  devices; cleared at O's stop); under the
  mutex set `collecting[k]`, raise the barrier word, `ycActive += 1`, Y_k :=
  every object young in k. `flip` queues k for C; `collect` runs it.
- `waitDone` (offload): the wait at the start of the owner's next flip.
- `slowPeek r := x.s`: `blockingBegin` (service owed rounds, then
  `blocking` under the mutex; the epoch word is kept), take the body
  pointer, read through it, `blockingEnd`.
- `leaveVM`: one mutex hold: owed rounds, epoch word quiescent, outside,
  registers dropped. `enterVM`: mutex, epoch 0 (seq_cst), E (seq_cst),
  epoch E (release).

Every wait inside the VM services owed rounds, then quiesces its epoch word
under the mutex and blocks (amendment 14); on wake it stores the current E
under the mutex. Servicing a round from a wait also advances the epoch, as
`serviceHandshakes` does.

**Collector** (`ycCollect`, run by the owner in `local`, by C in
`offload`): open H0 and wait; open H1 and wait (runRound: workers outside
the VM or in a blocking region are acknowledged by proxy, a blocking one
with its registers scanned); T1: the new-half range's slots as roots
(offload), the carried holders, then everything handed (roots, remembered
holders, deletion records), then drain the gray stack; then drain rounds,
each followed by the handed work and a drain, until one copies nothing.
`scanHolder`: `fetch_and(~member k)` (seq_cst, a full fence), the header's
slot count, each slot (relaxed) classified, and `keepForNext` (`fetch_or`
pending) if it names Y_k. `classify` copies (marks) an unmarked Y_k object
behind a full fence (the offset CAS and fence of the copy), switching its
offset word (release) when the configuration has body pointers; a copied
object naming a young object of another nursery is remembered for it
(`rememberFor`). Finish under the mutex (`collecting[k]` and the barrier
word down), `foldCarried` per next-carried holder (`fetch_or` member,
`fetch_and ~pending`), the entry sweep (marked survive; an unmarked one
with a nonzero remembered word gets slot count 0 (release), word 0
(seq_cst) and a deferred free; the rest are freed), E `fetch_add`
(seq_cst) giving s, the epoch wait (every epoch word, acquire, until all
exceed s; a participant collector services rounds and advances its own
word meanwhile), reuse of the old eden, the deferred frees (`exchange(0)`:
nonzero keeps the entry for the next collection, zero frees it), done
under the mutex. A participant collector services other collections'
rounds in its round wait and its epoch wait.

**Old-space collector O** (claim 5): sets `stwWanted` (no collection
opens), then stops the world in one step once `ycActive == 0` and every
worker is at a safepoint with its buffer drained. The snapshot is every old
entry, and with amendment 17 off also every deferred entry; the snapshot
entries reachable at the pause are marked (the marker's result, not its
work). The lazy sweep frees each unmarked snapshot entry, one per step. A
full collection frees, in its pause, every unreachable old entry (and with
amendment 17 off, every deferred one).

### Steps and names

The model's steps against the SPEC sections, the experiment's functions and
the names module 7 should use (proposed: module 7 has no brief yet; these
follow the production names in `Sources/KajoVM`, `storeWithBarrier`,
`rememberSlow`, `pollSlow`, `enterVM`, `leaveVM`). Module 7's brief should
require that any change to a row updates the model in the same commit.

| model step (trace text) | SPEC.md | experiment (`VMR/`) | module 7 (proposed) |
|---|---|---|---|
| `W flip` / `W collect: opens nursery k's collection` | Part 1 step 1; Part 2 | `ycOpen`, `ycLocal`, `ycFlip` | `openYoungCollection` |
| `... opens H0 / H1 / drain (round r, need n); X by proxy` | Handshakes | `runRound`, `roundWork(scan: blocking)` | `openRound` |
| `... acknowledges H0 of nursery k: clears del` | Handshakes, H0; Changes 4 | `serviceHandshakes`, `roundWork` (`Round.h0`) | `serviceRounds` |
| `... acknowledges H1: stack scan finds ..., publishes ..., records new half` | H1; amendment 7a | `roundWork`, `scanOwnStack`, `publish` | `serviceRounds`, `scanStackForNursery` |
| `... waits: epoch := quiescent` / `wakes: epoch := E` | Handshakes (wait loops); amendment 14 | `waitServicing` (`quiesce`, `advanceEpoch`) | `waitServicing` |
| `poll: E (acquire), epoch := E (release)` | Part 1 step 6 | `pollSlow`, `advanceEpoch` | `pollSlow`, `advanceEpoch` |
| `store ...: barrierWord (relaxed)` | Barriers, flag word | `store_ivar` in `Interp.swift` | `storeWithBarrier` |
| `store ...: old ... collecting[k] (acquire): del[k] += v` | Barriers, young deletion barrier | `preStoreSlow` | `storeWithBarrier` slow path |
| `store ...: snoop: ... remember` | amendment 7b | `preStoreSlow` (offload snoop) | `storeWithBarrier` slow path |
| `store ...: x.s := v (seq_cst)`, `post-store check` | Ordering 5; ADR 0007 | `setSlotAndBarrier` | `storeWithBarrier` |
| `arrayCopy ...: x.s := v (relaxed)` | Hazard slots (ADR 0007) | `primArrayCopy` | copy primitive |
| `store ...: rem[x] (seq_cst)`, `fetch_or rem[x] ... rem[k] += x` | Barriers, insertion barrier; Ordering 2 | `barrier`, `remember` | `rememberSlow` |
| `alloc` | amendment 13 | allocation, `retireTlab` | allocation |
| `slowPeek: blockingBegin`, `blockingEnd` | Blocking regions | `blockingBegin`, `blockingEnd`, `primSlowPeek` | `blockingBegin`, `blockingEnd` |
| `leaveVM`, `enterVM` | Handshakes; epochs | `leaveVM`, `enterVM` | `leaveVM`, `enterVM` |
| `... H1 complete; T1, carried ...` | Part 1 step 3 | `ycCollect` (`afterH1`, `claimParked`, `globalRoots`) | `collectYoung` |
| `new half: N.s0 -> v` | amendment 7a | `scanNewHalf` | `scanNewHalf` |
| `scanHolder H: fetch_and rem`, `header`, `s0`, `keepForNext` | step 3; Changes 5; amendments 9, 10 | `scanHolder`, `keepForNext` | `scanHolder` |
| `takes handed`, `visits root / deletion record`, `copies X` | step 3 | `takeHanded`, `processHanded`, `visit`, `classify`, `evacuate` | `processHanded`, `evacuate` |
| `drain: X.s0 -> v, rememberFor j` | step 3 | `drain`, `rememberFor` | `drainGray` |
| `stops marking` / `another drain round` | step 4; Ordering 3 | `ycCollect` loop (`secondHandshake`) | `collectYoung` |
| `finish: collecting[k] := 0` | step 5 | `ycCollect` (finish) | `collectYoung` |
| `foldCarried` | amendment 9 | `foldCarried` | `foldCarried` |
| `sweep: ... free deferred` / `entry freed` | step 5; amendment 10 | `sweepCollection` | `sweepYoungLog` |
| `s = E, E := s + 1`, `epoch wait`, `old eden may be reused` | step 6; Ordering 7 | `ycCollect`, `epochWait` | `waitEpoch` |
| `deferred H: exchange rem 0` | step 6; amendments 10, 17 | `ycCollect` (deferred loop) | `freeDeferred` |
| `collection done` | step 5 | `ycCollect` (`done[k]`) | `collectYoung` |
| `O requests a stop`, `O initial mark`, `O full collection` | Stops and collections; amendment 17 | `stopWorld`, `initialMark`, `markSweep` | stop, `initialMark`, full collection |
| `O sweep` | amendment 17 | `sweepWork` | lazy sweep |
| `drain` | (memory model) | hardware | |

Not modelled: Process records, scan words, resumes and `claimParked`
(a worker's stack is its registers; leaving the VM drops them); global root
writes; promotion and the age (every marked object survives young);
survivor-space overflow; the copy protocol's RELOCATING state, hazard
revert and post-store slow path (the relocation model covers them); the
hazard-slot count of amendment 16; triggers; parallel or nested
collections on C (amendment 11); the stop-the-world scavenge (amendment
12).

## Memory model

The relocation model's, unchanged in its rules (`docs/models/relocation.md`
"Memory model", and its litmus tests), now in `ModelKit` and shared. One
extension, written down in both documents:

- **`sequentiallyConsistent`**: with it, every store is performed on shared
  memory at the instant of its step, with no buffer and nothing to drain.
  Every execution is then an interleaving of atomic steps. Claim 2's
  negative runs under it, so its failure is the protocol's and not the
  memory model's. Tested in `SequentiallyConsistentMemory`.
- A helper, `readModifyWrite`, for the existing rule that a seq_cst
  read-modify-write is a full fence (enabled only with the thread's buffer
  empty). Tested there too.

Mutex steps (round open and acknowledgement, collection open and finish,
waits and wakes, `blockingBegin`/`End`, `leaveVM`, `enterVM`'s first step,
O's pause) are full fences, as in the relocation model: enabled only with
the thread's buffer empty, writes performed at once. Finding 3 is the place
where that convention is generous.

### Limits

- Small: two or three workers, one to three objects of zero or one slot,
  one or two nurseries, one or two collections per nursery. A loss that
  needs a longer chain or more participants is not found.
- Not a full ARMv8 or C++ model (see the relocation document's limits):
  loads in program order, multicopy atomic, no speculation. Findings 3 and
  4 are where that matters.
- Marks, not bodies. Holder and copy bodies are not addressed; a collector
  reading a stale holder's slots through a reused body (amendment 10's
  bus error) is out of reach. Claim 4 covers workers' body pointers only.
- The old-space marker is abstract: its marks are "reachable at the
  pause", not the SATB marking of ADR 0006.
- Safety and deadlock only. A collector's epoch wait is a spin in the code;
  here it re-scans only after a word it read changed, so a wait that can
  never succeed is a deadlock the explorer reports, and a spin that would
  have repeated the same reads is not explored again.
- Hash compaction: 64-bit fingerprints (Swift's `Hasher`). Under 10^-7
  chance of any collision at the largest configuration (780,050 states).

## Results

Each configuration explored completely. "Longest trace" is the
breadth-first depth. Times with the model library compiled `-O` in a debug
build, one test at a time, with another agent's build running on the
machine; they are indicative.

| configuration | states | transitions | longest trace | finished states | time |
|---|--:|--:|--:|--:|--:|
| local: W collects nursery 0; A loads X from G; B cuts G's slot between polls | 94,718 | 325,311 | 82 | 8 | 0.57 s |
| local, sequentially consistent | 18,975 | 48,162 | 71 | 8 | 0.09 s |
| chain: G -> X -> Z, cut on both sides of the first drain round | 780,050 | 2,772,169 | 111 | 19 | 5.2 s |
| remembered: two collections; M stores X into the remembered G; A reads G | 82,261 | 278,040 | 121 | 4 | 0.49 s |
| new half (offload): W allocates N, stores X into N, publishes N in G; A reads and cuts | 34,093 | 98,409 | 97 | 7 | 0.18 s |
| new half, initialising store | 27,688 | 80,018 | 86 | 6 | 0.14 s |
| epochs (offload, body pointers): M reads Q through pointers, in a blocking region, leaves and re-enters; W waits for done | 9,120 | 24,863 | 71 | 2 | 0.04 s |
| ownership, snapshot and sweep: nurseries 0 and 1 local, H deferred and re-armed, O snapshot and sweep | 213,969 | 594,806 | 155 | 6 | 1.87 s |
| ownership, full collection | 170,836 | 449,005 | 154 | 6 | 1.47 s |

All claims hold in all nine; no deadlock. The two ownership rows are the
final mark on the devices' (2026-11-07, docs/modules/final-mark.md):
worker 0 is the main worker and may open one collection while O wants its
stop (`mainOpensWhileWanted`, on by default); with module 7's rule, every
opener waiting while a stop is wanted, they had 171,691 and 128,527
states and hold as well (`withTheMainWorkersOpenWhileAStopIsWanted` runs
both). The change is liveness only, as expected: O stops only once
`ycActive` is 0 (`worldCanStop`), so a collection the main worker opens
while O waits is one more collection O waits for, never one a stop
interleaves. The same follow-up moved the young-root scan out of the
initial mark's stop and bounded the final mark's tracing; neither is
modelled here (O's marking is its result, "the snapshot entries reachable
at the pause are marked", not its work), and the module doc says why each
is sound and which tests show each rule. The ownership configurations
reach witness states (4 and 2): runs in which the deferred entry was kept
across a pause, freed by its nursery and reused by a worker, so the rule's
case happened and nothing broke.

### Negative tests

Each turns one rule off, finds the claim it protects broken, and has the
shortest violating trace in a comment above it in
`YoungCollectionModelTests.swift`.

| switch | configuration | claim broken | how (shortest trace) |
|---|---|---|---|
| `barrierOnRound` off, sequentially consistent | local | 1 (and 3) | SPEC point 4 exactly: B loads the barrier word (0); W opens and H1 is the only round; W and A acknowledge (A's stack is empty); A loads X from G; B stores nil into G without a record; B acknowledges; T1 reads nil from G; nothing copies X; the sweep frees it while A holds it. 40 steps. With store buffers too (`Probes`). |
| `termination = .afterT1` | local | 3 | B cuts G's slot after its H1 acknowledgement and before T1 reads it; the record waits in B's buffer for a drain round that never comes; A holds X. 35 steps. |
| `termination = .afterOneDrainRound` | chain | 3 | A takes X and then Z; B cuts G (recorded, drain round 1 copies X) and, after acknowledging that round, cuts X's slot before the collector scans X; the record of Z is published only in a second round. 63 steps. |
| `epochRule` off | epochs | 4 | M takes a pointer into Q's old body inside its blocking region; C copies Q, sweeps, bumps E and reuses the old eden while M still holds it. 50 steps. |
| `blockingRegionsKeepEpoch` off | epochs | 4 | M's blocking region publishes quiescent; the epoch wait passes with M holding a pointer into Q's old body. 54 steps. |
| `waitersAreQuiescent` off | epochs | deadlock | W waits for its collection with epoch 0; C's epoch wait needs W's word above 0. Amendment 14's deadlock. 66 steps. |
| `deferredEntriesBelongToTheirNursery` off | ownership, snapshot | 5 | Amendment 17's bug as diagnosed: W1 scans H from its carried list and keeps it (pending); W0's sweep defers H; W1's `foldCarried` re-arms it; W0 keeps it; O's snapshot includes H; W0's next collection frees it; W0 allocates into it; O's sweep frees the live object. 143 steps. Also found: the sweep frees H first and the nursery frees it again (140 steps). |
| same | ownership, full collection | 5 | The full collection frees the deferred H; W0's next collection frees it again. 139 steps. |
| `rememberLoadOrder = .relaxed`, `postStoreReload` off | remembered | 1 | M's relaxed load of G's remembered word overtakes its buffered store of X into G and sees the bit; W's `fetch_and` clears it and reads G's slot as nil; G is not kept; X survives on M's stack; the second collection frees X while G names it. 95 steps. |
| `newHalfScan` and `snoop` off | new half | 1 | W stores X into N (same nursery, no insertion barrier) and drops X; W's H1 scan finds only N, not in Y; C frees X. 52 steps. |

**Probes** (beyond the brief's switches):

| probe | result |
|---|---|
| relaxed remembered-word load, reload on | holds (finding 4) |
| reload off, seq_cst load | holds: SPEC point 2's argument alone |
| `arrayCopy` store, everything on | claim 1, 95 steps (finding 1) |
| new-half scan only (both new-half configurations) | holds (finding 2) |
| snoop only, barriered store | holds |
| snoop only, initialising store | claim 1, 47 steps (finding 2) |
| single round with store buffers | claim 3 (and 1) |

## Choices

- **Breadth-first, shortest traces, hash compaction**: as the relocation
  model. The State is fingerprinted with Swift's `Hasher` over the
  synthesized `Hashable`; fast enough at these sizes (under a million
  states), so no hand-written fingerprint.
- **The explorer and the memory model moved to a `ModelKit` target**, shared
  by both models; the brief asked to reuse them, and copying would have let
  them drift. The relocation model is unchanged in behaviour (same state
  counts). `@inlinable` on the memory model and the transition types keeps
  the cross-module calls specialised; the relocation model's largest
  configuration went from 12.4 s to 13.5 s on a quieter machine.
- **One configuration per question**, not one configuration for all
  claims: each stays small enough to explore in seconds, and each negative
  runs on the configuration that shows its rule.
- **Claims 2, 6, 7 are checked through claim 1**: the brief states them as
  "show the loss". Their negatives switch the termination check off so the
  path reaches the free (`terminationCheck`); the doc and the trace comments
  name both.
- **Claim 6 needs two collections.** Within one collection the storer's
  stack root always keeps the value; the lost holder costs the next one.
- **Claim 3's alternatives**: "no drain rounds" and "one drain round" are
  modelled; "found nothing new" is the same as "copied nothing" here
  (finding 6).
- **Processes are not modelled.** A worker's stack is its registers, scanned
  at its H1 acknowledgement (or by proxy in a blocking region); `leaveVM`
  drops them, since outside the VM a worker holds no reference and the
  stack it ran belongs to a parked Process. A first version kept them and
  reported a false loss.
- **Globals are old objects only**; their writes would need
  `recordDeletedRoot`, not modelled.
- **No promotion**: every marked object survives young, so it stays in Y for
  the next collection (what claim 6 needs). Promoted-object rules (Ordering
  5, 6) are not modelled.
- **Granularity**: a round acknowledgement (mutex, work, mutex) is one step,
  since the worker runs no Smalltalk meanwhile; `advanceEpoch`'s load and
  store are one step (the store is buffered, so its delay is still
  explored); the deletion barrier's load of the old value and of
  `collecting[n]` are one step; the sweep's load of a dead entry's
  remembered word and its two deferring stores are one step; `foldCarried`'s
  two RMWs are one step. Everything a protocol argument names as separate
  (the store, the reload, the remembered load, the `fetch_or`, the
  collector's `fetch_and`, header load and each slot load) is its own step.
- **`leaveVM` is one mutex step** (owed rounds, quiesce, outside), as in the
  code; a first version split it and deadlocked a round.
- **A local collector services other rounds only in its waits** (round
  wait, epoch wait), not every 256 objects or per handed buffer as the code
  does; that removes interleavings of acknowledgement timing, not states
  the protocol can reach otherwise.
- **`waitDone`** stands for `ycFlip`'s wait for the previous collection,
  without opening a second one.
- **The epoch wait blocks** until a word it read changes (see Limits), so
  amendment 14's deadlock is reported as a deadlock and not as a spin.
- **Witness states** (`isWitness`, counted by the explorer) show that the
  ownership configurations reach the case the rule is for.
- **`violationsByMessage`**: the explorer keeps the shortest trace per
  distinct message as well as per claim, so claim 5's two shapes each have
  a trace.
