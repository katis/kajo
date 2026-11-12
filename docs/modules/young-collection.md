# Module 7: young collection without stopping the world

Status: built, 2026-11-03. `Sources/KajoVM/YoungCollection/` (2 370 lines),
with the object memory's side in `ObjectMemory/` (the aliased nursery
region, atomic header loads, the deferred-free bit), module 4's remembered
sets and survivor spaces reshaped in `Nursery/`, and hooks in modules 3, 5
and 6. Tests in `Tests/KajoVMTests/YoungCollection/` and four random-program
configurations.

Decisions it implements: ADR 0008 with its amendments (the main worker's
nursery is collected by the young collector thread after a flip of eden
halves; background workers collect their own; the initial mark scans every
nursery as roots; the stop-the-world scavenge stays as the oracle; the
collector at user-initiated, the marker at utility) and the findings of
`docs/models/young-collection.md`, each a requirement here (table under "The
model and the code"). Evidence: experiments/concurrent-young (SPEC with its
amendments, RESULTS, DIAGNOSIS-parallel-scavenge), ported by its tests.

## Modes and policy

`VMConfig.young.mode` (`kajo run --young`):

| mode | nursery 0 (main) | background and host nurseries |
|---|---|---|
| `stw` | module 4's stop-the-world scavenge of every nursery (the oracle) | the same |
| `local` | collected by the main worker itself | each by its owner |
| `offload` (the default, the policy) | two eden halves; a full half is flipped to the young collector thread | each by its owner |

Without a nursery, or when the object memory was made without
`nurseryRegionBytes` (the nursery region mapped twice), the mode is `stw`.
In a VM the test drives (`start` not called) the collector thread does not
run and an offloaded nursery's owner runs the collection itself right after
its flip (counted, `offloadedInline`). Threads and QoS: background workers
user-initiated (module 3), the young collector user-initiated
(`collectorQoS`, logged as `collectorQoS`), the marker utility unless
headroom is low (module 5), and every stopper outside the worker table (the
marker requesting a final mark or an apply, the collector requesting an
initial mark, a verifier stop or a fallback) raised to user-initiated for
its stop and restored after (counted, `stopperQoSRaises`): the role, not the
thread, decides. This settles module 6's open item: under twelve
default-QoS busy loops a final mark took 20 s because the marker, the
stopper, stayed at utility.

## Layouts

| what | where | written by | read by |
|---|---|---|---|
| attention word: bit 0 a stop, bits 1.. twice the open rounds | module 3's flag line, word 0 (the poll's word) | stoppers (`fetch_or`/`fetch_and` of bit 0), round openers and last acknowledgers (±2) | every poll (one relaxed load, unchanged) |
| barrier word: bit 0 marking, bits 1.. twice the open collections (plus 2 under `barrierAlwaysOn`) | the flag line, word 2 (module 5) | module 5's pauses (bit 0 only, `fetch_or`/`fetch_and`, since the collectors review); collection open and finish (±2) | every pointer store (one relaxed load, unchanged); the stop verifier |
| handshake per nursery: active, round, kind, `need`, acked per participant, handed roots and buffers, the owner's new-half range | `YoungShared.hs[k]`, own lines | under the safepoint mutex | the same |
| per nursery: `collecting`, `afterH1`, `afterT1`, `done`, `seq`, Y's ranges | atomics in `YoungShared` | the collection (open, finish) | the deletion barrier, resumers, the collector |
| round serial | `YoungShared.roundSerial`, own line | round openers (under the mutex) | the poll slow path (acquire): the mutex only when a round opened since |
| Process scan words | 8 bytes per nursery and record, a reservation (`scanWords`) | owners at H1, resumers, the collector at T1, creation (`youngNewRecordLocked`) | the same (CAS) |
| remembered word: bit n member of nursery n's set, bit 16 + n pending | module 4's table beside the entries, now 32 bits | barriers (seq_cst load, `fetch_or`), collectors (`fetch_and`, pending, fold), sweeps | the same |
| remembered and deletion buffers, 16 + 16 per owner | `NurseryShared.buffers[owner]` (workers, the marker's unused slot, the collector) | the owner's barrier; published at acknowledgements (by proxy under the mutex) | collections, stop-the-world scavenges |
| survivor spaces, survivor log, carried list, deferred list, the collected half's stash, the collection's survivor-to bump, next log, next carried | `NurserySurvivors` per nursery (module 4, moved out of `NurseryAlloc`) | whoever collects the nursery, or a stopper | the same |
| eden: `top`, `end`, `edenStart` (the half being allocated in), `half` | `NurseryAlloc` | the owner | the owner; a proxy (outside or blocking owner) under the mutex |
| collector work: grey stack, roots, published buffers, `inCopy`, `busy`, `seenSerial` | `CollectorWork` per participant | that thread | that thread |
| counters per participant | `YoungWorkerCounters` | that thread | the host after the threads stopped |
| log (collections, rounds, fallbacks, verifier runs, young-root scans, collector CPU) | `YoungLog` | under the safepoint mutex | the host |
| global epoch E, held-hazard count | `VMState.epoch`, `VMState.hazardsHeld` (moved from module 6, shared) | collections and the relocator (`fetch_add`), primitives | everyone |

Participants of rounds are the workers of the table and the young collector
thread (it publishes the buffers its copies remember into, `rememberFor`);
module 5's marker is not one. Participants of epochs are the same: the
collector reads young and old bodies between its polls, so collections and
the relocator wait for its word too.

## The collection

`collectOwnNursery` (the owner at its allocation slow path, registers
flushed, the slow path's kept oop in `youngHeld`), `openYoungCollection`,
`collectYoung`, in `Owner.swift` and `Collect.swift`:

1. **Open** (mutex): wait, servicing rounds and parking, while a stop is
   wanted or requested; Y := the eden part `[edenStart, top)` and
   survivor-from; offload: swap the stash with the nursery's second stash,
   flip to the other half (`top` and `end` of the new half), queue for the
   collector thread; `seq += 1`, `collecting[k]` (release), barrier word +2,
   `ycActive += 1`.
2. **H0, H1** (`runRound`): participants inside and not in a blocking region
   are counted in `need`; the attention word +2 and a broadcast; the others
   acknowledged by proxy under the mutex (a blocking one's flushed stack
   scanned). H0's work clears the participant's deletion buffer for k; H1's
   scans its stack (`scanOwnStack`: the current Process from its base to the
   flushed sp, `current`, receiver and method registers, `youngHeld`; the
   host worker also the root registry), marks its Process scanned, publishes
   its buffers for k, and for an offloaded owner records the new half
   allocated so far. `afterH1[k]` is set between the two rounds.
3. **T1**: under the scheduler lock `afterT1[k]`, every parked live record
   not yet scanned for this collection claimed (CAS on its scan word), live
   Processes and ready-queue words in Y as roots; then the claimed stacks,
   the pending roots and the finalization queue; the new-half range
   (offload); the carried holders (`scanHolder`); everything handed
   (`processHanded`: roots, remembered buffers' holders, deletion records);
   the grey stack (`drainGrey`).
4. **Drain rounds** until the first that copied nothing.
5. **Finish** (mutex): `collecting[k]` off, the barrier word -2, the
   handshake inactive.
6. **Fold** pending bits into membership (`foldCarried`), **sweep** the young
   log (`sweep`), flip the survivor halves, carried := next carried.
7. **Epoch**: E `fetch_add` (seq_cst) gives s; `waitEpoch` until every
   participant's word passed s (the collector advances its own and services
   rounds meanwhile); then the deferred frees (`freeDeferred`).
8. **Done** (mutex): `ycActive -= 1`, `done[k]` (release), the record; a
   local owner then resets its eden (`top = edenStart`): the eden-reuse
   wait is step 7.
9. **After** (`afterYoungCollection`): old space past its soft limit sets
   module 4's full-collection request and the stop bit (a fallback,
   counted); marking idle and the trigger met (module 5's rule on this
   module's own promotion samples) requests an initial-mark pause; the young
   verifier at a stop when due.

**Evacuation** (`Collector.evacuate`, one collector per nursery): survive
(age + 1 below N and room in this nursery's survivor-to) or promote (a block
of the collector's own allocation context through module 4's reserve); the
header compare-and-swap writes the decision (survive: age + 1, both claim
tags cleared; promote: young, nursery, age, tags cleared) before module 6's
protocol on the state word: CAS to RELOCATING (seq_cst), a seq_cst fence,
the held-hazard count and, when nonzero, the slots (hazarded: revert,
wait, retry), the word copy (`copyBody`, relaxed atomics), the switch
(release). A young body may be RELOCATING now, so the nursery region lies in
the heap's doubly mapped memory (module 1's change). Promoted entries join
the old map at the sweep.

**Classify** a value for collection k: not young or a deferred free: 0;
young in another nursery j: 2 + j (a copied holder is then remembered for
j, `rememberFor`, into the collector's own buffer); young in k outside Y
(survivor-to, the owner's new half): 1; in Y: evacuated.

**Remembered holders** (`scanHolder`): `fetch_and(~bit k)` (seq_cst); bit
was clear: skip (a duplicate, a stale name of a freed holder); a byte
object, a deferred free or a holder young in k: nothing; else its slots
(relaxed loads through its state word, a RELOCATING one through the alias)
classified; if one is young in k after this collection: `keepForNext`
(pending bit `fetch_or`; the call that set it lists the holder in next
carried; amendment 9).

**The sweep** of the young log (the collected eden's stash prefix and the
survivor log): not young: promoted, into the old map; body in survivor-to:
survived; dead with a remembered word of 0: freed into the stash; dead with
a nonzero word (a remembered holder that stale lists may name, or that
another collection may re-arm): slot count 0 and the deferred bit, its word
cleared (seq_cst), on the nursery's deferred list (amendment 10). After the
epoch a deferred entry whose word was re-armed meanwhile (`exchange(0)`
answers nonzero) waits for the nursery's next collection; the others are
freed and handed out next (`pushNext`).

## Barriers

`storeWithBarrier`'s fast path is unchanged (`interpret` is 794
instructions, one jump table, the post-store check's sequence as in module
6). The flag word nonzero sends the store to `storeWithBarriers`: module
5's SATB record if bit 0; module 7's young deletion record if bits 1..
(`youngDeletionBarrier`: the old value, relaxed through the state word; if
it is young, not a deferred free, and its nursery is `collecting`
(acquire), pushed on this worker's deletion buffer for that nursery); the
store with the post-store check; the insertion barrier. `rememberSlow`
(the insertion barrier's slow path) remembers any holder that is not young
in the value's nursery (young holders of another nursery included, in the
young modes; module 4's rule in `stw`), loading the remembered word with
seq_cst after a seq_cst store at every site. The array copy primitive's
stores were already seq_cst (module 6); it now also makes the young
deletion record of each overwritten value. The snoop of amendment 7b is not
built (the model's finding 2): the new-half scan alone covers the owner's
fresh allocation, and `withoutNewHalfScanTheValueIsLost` keeps it honest.

## Processes

`youngResumeCheck` in `runSlice` (only when the barrier word says a
collection runs): before a worker runs a parked Process, for each collection
past `afterH1` whose seq its record's scan word lacks, the worker wins the
word and scans the parked stack (handing the roots to the collection), or
waits while the collector holds it. `youngNewRecordLocked` in
`createProcess`: a new record counts as scanned for every collection past
T1. T1 claims every parked unscanned record under the scheduler lock.

## Stops and collections

No stop interleaves a collection: `stopWorld` first parks for any requested
stop, then (`waitForCollectionsLocked`) counts itself in `stwWanted` and
waits, servicing rounds (the collector thread also runs its queue), until
`ycActive` is 0; openers wait while `stwWanted` or a stop is pending (the
main worker, since the final mark on the devices, only for a pending stop
and for `stwWanted` once it has opened one collection under it). So at
every pause no entry is RELOCATING, every nursery is quiescent, and the
young-root scan finds every young body in an active eden or survivor-from.
A stop-the-world scavenge (the oracle, `vm.scavenge()`, module 1's
promote-all) takes every remembered list (each holder once; young holders
dropped, amendment 12), copies, remembers for every nursery each holder
that names one of its young objects (young survivors for the other
nurseries too, in the young modes), puts them on the nurseries' carried
lists, and releases every deferred free (nothing names one any more: the
nursery's own free, at the pause).

## The initial mark

In the young modes the cycle starts with `initialMarkPause` (no scavenge):
module 5's bookkeeping, then `initialMark`, whose survivor scan is replaced
by `youngRootScan`: every nursery's eden (or current half) `[edenStart,
top)` and survivor-from walked by back references, every slot of a body
whose entry leads to it greyed. Since the final mark on the devices
(2026-11-07, `docs/modules/final-mark.md`) the pause only records those
ranges and marks each nursery's scan owed; the marker, the nursery's
collector before it moves anything, or a scavenge's stop does the walk,
and until then the SATB barrier records stores into that nursery's young
holders (`youngRootsInStop` is module 7's in-pause scan, kept as a test
switch). The snapshot is the old map, which never
holds a young entry or a deferred free: amendment 17's exclusion is
structural (counted: `snapshotExclusions`). `vm.startCycle()` still
scavenges first (the oracle path); `vm.startYoungCycle()` is the pause
without.

## Blocking regions

`blockingBegin` services owed rounds, then marks the worker blocking (under
the mutex); inside, rounds are acknowledged by proxy with its flushed stack
scanned, and its epoch word is kept. Users: the shell call (primitive 29,
around the hook) and the test primitive 39 `slowPeek:`. `blockingEnd`
clears the mark (rounds opened meanwhile were acknowledged by proxy: the
model's finding 5).

## Waits

`waitServicing` (mutex held) is every wait inside the VM: owed rounds first,
then the collector thread's queue (not inside its own collection), then a
requested stop's park; then the epoch word quiescent, an untimed
`pthread_cond_wait` on the safepoint condition, and the wake: 0 (seq_cst),
E (seq_cst), the word (release), as `enterVM` (`epochWake`, the model's
finding 3). Every transition a waiter depends on broadcasts the condition
under the mutex: a round opened, a round's last acknowledgement, a
collection done, a stop requested (a waiter inside the VM must park), a
requester leaving `stwWanted`, a stop released (module 3), a participant
leaving. The
young collector thread waits untimed on its own condition between
collections (a queued collection and shutdown signal it). The epoch wait
inside a collection spins with yields (a 20 µs sleep every 64 spins); it
runs only while a collection is open.

## The model and the code

`docs/models/young-collection.md`, "Steps and names", against the production
functions. No step changed order; the model is unchanged (`just
model-check`: 15 and 28 tests green). Where the code does more than one model
step at once, or something the model does not have, it is under Deviations.

| model step | production |
|---|---|
| `W flip` / `W collect: opens nursery k's collection` | `collectOwnNursery` → `openYoungCollection` (offload: the stash swap and the half flip in the same mutex hold) |
| `... opens H0 / H1 / drain (round r, need n); X by proxy` | `runRound` (`roundWork(scan: blocking)` for the proxies) |
| `... acknowledges H0 of nursery k: clears del` | `serviceRounds` → `roundWork(.h0)` |
| `... acknowledges H1: stack scan finds ..., publishes ..., records new half` | `serviceRounds` → `roundWork(.h1)` → `scanOwnStack`, `publish` |
| `... waits: epoch := quiescent` / `wakes: epoch := E` | `waitServicing`: `epochQuiesce`, `pthread_cond_wait`, `epochWake` (0, E, the word: finding 3) |
| `poll: E (acquire), epoch := E (release)` | `pollSlow` → `epochAdvance` |
| `store ...: barrierWord (relaxed)` | `storeWithBarrier` (inline at every site) |
| `store ...: old ... collecting[k] (acquire): del[k] += v` | `storeWithBarriers` → `youngDeletionBarrier` → `youngDeletionRecord` |
| `store ...: snoop: ... remember` | not built (finding 2) |
| `store ...: x.s := v (seq_cst)`, `post-store check` | `ObjectMemory.storeChecked` (module 6) |
| `arrayCopy ...: x.s := v (relaxed)` | `copySlots`: seq_cst (`storeSlot(atState:)`), the young deletion record; the relaxed variant only under the test switch (finding 1) |
| `store ...: rem[x] (seq_cst)`, `fetch_or rem[x] ... rem[k] += x` | `rememberSlow` (seq_cst load, finding 4) |
| `alloc` | `placeYoung` → `initializeObject` (relaxed atomic stores, amendment 13) |
| `slowPeek: blockingBegin`, `blockingEnd` | `blockingBegin`, `blockingEnd`, `primSlowPeek` (39) |
| `leaveVM`, `enterVM` | `leaveVM` → `youngLeaveLocked` (owed rounds by proxy, outside, one mutex hold); `enterVM` → `youngEnterLocked` then `epochEnter` |
| `... H1 complete; T1, carried ...` | `collectYoung`: `claimAndScanParked`, `globalRoots`, `visitRoots`, the carried loop |
| `new half: N.s0 -> v` | `Collector.scanNewHalf` |
| `scanHolder H: fetch_and rem`, `header`, `s0`, `keepForNext` | `Collector.scanHolder`, `Collector.keepForNext` |
| `takes handed`, `visits root / deletion record`, `copies X` | `Collector.processHanded`, `classify`, `evacuate` |
| `drain: X.s0 -> v, rememberFor j` | `Collector.drainGrey`, `Collector.rememberFor` |
| `stops marking` / `another drain round` | `collectYoung` (the drain loop: the first round that copied nothing) |
| `finish: collecting[k] := 0` | `collectYoung` (finish, under the mutex) |
| `foldCarried` | `Collector.foldCarried` |
| `sweep: ... free deferred` / `entry freed` | `Collector.sweep` |
| `s = E, E := s + 1`, `epoch wait`, `old eden may be reused` | `collectYoung` (`fetch_add`), `waitEpoch`; the owner's `top = edenStart` (local), the next flip (offload) |
| `deferred H: exchange rem 0` | `Collector.freeDeferred` |
| `collection done` | `collectYoung` (done, under the mutex) |
| `O requests a stop`, `O initial mark`, `O full collection` | `stopWorld` → `waitForCollectionsLocked`; `initialMarkPause` → `initialMark` (`youngRootScan`); `fullCollection` (promote-all, then `releaseDeferred`) |
| `O sweep` | module 5's `sweepCycle` (snapshot entries only: never a deferred free) |

Findings, as built:

1. The array copy's stores are seq_cst (module 6 had made them so);
   `theArrayCopyStoreIsSeenByTheCollector` and its broken variant
   `withRelaxedArrayCopyStoresTheHolderIsLost` (test switch
   `arrayCopyOrdering`).
2. The snoop is dropped; `withoutNewHalfScanTheValueIsLost`.
3. The quiescent wake stores 0 first (`epochWake`);
   `aQuiescentWakeStoresEpochZeroFirst` and its broken variant (switch
   `quiescentWakeZero`).
4. The remembered-word load stays seq_cst (`rememberSlow`).
5. `blockingEnd` services nothing (as the experiment's code).
6. Drain rounds until one copies nothing; `withoutTheSecondHandshake...`.
7. H0, H1, T1's order, termination, the epoch rule, blocking regions keeping
   their epoch, quiescent waiters, deferred ownership: as modelled, each with
   its test.

## Deviations

From the model, each with the argument it is still covered:

- **Deferred frees at a stop-the-world scavenge or a full collection.** The
  model's full collection leaves a deferred entry used and its nursery frees
  it at its next collection. Here every stop-the-world scavenge (and so
  module 1's operations, which promote everything first) releases every
  deferred entry at its pause, through the nursery's own list
  (`releaseDeferred`), and module 1's sweep never sees one. Covered: the
  pause has no collection open (stops wait for collections), every worker is
  at a safepoint holding no body pointer (the epoch rule is met), and the
  scavenge's prep has taken every remembered list, dropping young holders
  (amendment 12), so nothing names the entry: it is the model's
  `exchange(0)` reading 0 after an epoch, done once by the one owner.
  `aFullCollectionLeavesADeferredEntryFreeToItsNursery` checks one free and
  no double free; its broken variant (the pause frees and the list keeps the
  entry) fails with "entry 2561 is twice in the free lists (stash 8)".
- **The snapshot is module 5's old map**, which never holds a young entry,
  so amendment 17's exclusion needs no subtraction; the broken variant puts
  the deferred entries in by hand.
- **The young collector thread is a round participant** (the model's C is
  not): its copies remember holders for other nurseries into its own
  buffers (`rememberFor`; the experiment pushed onto the other nursery's
  carried list, which here its owner may be collecting), published at those
  nurseries' rounds. It holds no stack; its H1 only publishes. Outside the
  VM between collections it is acknowledged by proxy. It is also an epoch
  participant: it reads other nurseries' young holders and old holders
  between its polls, which collections and the relocator must not free
  under it (the model has no relocator and no second nursery read by C).
- **`leaveVM` quiesces before it acknowledges owed rounds by proxy** (the
  model does both in one mutex step): the leaving worker holds no body
  pointer from its quiesce on, and the rounds are acknowledged under the
  mutex before it counts as outside.
- **Acknowledgements are batched**: every round owed is taken in one mutex
  hold, worked on outside it, acknowledged in one more. At most one round
  per collection is open, so this is consecutive single acknowledgements
  with no Smalltalk between them, which the model's granularity already
  merges.
- **The poll's fast path for nothing owed** (`roundSerial`): a participant
  whose serial is current skips the mutex; a round opened after its read is
  seen at its next poll (the attention word stays nonzero until it
  acknowledges). The budget is checked at every 64th slow poll while rounds
  are open.
- **Service points**: a collector services rounds and advances its epoch
  every 256 copied objects, every 256 roots or holders, every 4096 swept
  entries, between published buffers and in its waits (the model only in
  waits: interleavings of acknowledgement timing, not new states).
- **Stale names in remembered lists are allowed.** A dead holder whose word
  another collection had just cleared is freed (not deferred) by its
  nursery's sweep while a list of another nursery still names it; the
  scan's bit test skips it, or scans the entry's new occupant, which is
  correct either way. The young-mode remembered-set check therefore checks
  that every holder of a young object has its bit and every bit is listed,
  not that every list entry is a used holder with its bit (the
  stop-the-world configuration keeps module 4's strict check).

From the brief:

- **The fallback when a stop is wanted** waits (servicing rounds, parking in
  the stop) and then collects locally, as the experiment did; it does not
  run a stop-the-world scavenge in a stop of its own (that would add a
  whole-heap pause right after the one being waited for). Counted as the
  opener's stop wait (`stopWaitNs`). The stop-the-world scavenge remains the
  oracle and what module 1's operations run.
- **Weak and ephemeron slots are strong in a young collection** (v0): a
  young weak referent lives until a stop-the-world scavenge or a full
  collection nils it; module 4's weak pass runs only in the stop-the-world
  scavenge. Listed under Not done.
- **Primitive 35 `scavenge`** collects the caller's own nursery without
  stopping the world in the young modes (the host's `vm.scavenge()` is still
  the stop-the-world scavenge): the random programs call it between every
  task's halves, so every program collects while its other tasks run.
- **The young verifier is not on by default in checked builds**: a heap
  walk at a stop after every collection starved the long kernel tests under
  ThreadSanitizer (the first run spent most of its 108 CPU minutes in it),
  the lesson module 6 recorded for its verifier. The young-collection tests
  run it after every collection, the random programs' young configurations
  too, the shared-objects test after every fourth.
- **The trigger** between stops samples young promotion (bytes and objects)
  only, not old allocations of large objects (their contexts' counters are
  written without a lock); the floor still sees occupancy.
- **The header claim** is a compare-and-swap whose failure is counted
  (`claimFailures`, always 0: one collector per nursery writes Y's headers).
- **Released deferred entries are handed out next** (`pushNext`), so a
  double free shows at once in the tests.
- `collectAtEveryHalf` sets 64 KiB halves; `roundAtEveryPoll` opens a drain
  round after every 16 copies (my reading of "a round at every poll": every
  poll of every participant during a collection services one).

## Verifiers

- **The young verifier** (`verifyYoungInStop`, at a stop of kind `verify`
  after every `verifyEvery`-th collection when `young.verify` is on, and
  `VM.verifyYoung()`): a from-scratch walk from every root (the stop's and
  module 1's); every reachable entry is used, not a deferred free, not
  RELOCATING; a young body lies in its nursery's eden (or current half) or
  survivor-from; an old body outside the nursery region; then module 4's
  remembered-set check at a pause (young-mode rules: every holder of a young
  object of nursery n that is old or young in another nursery has bit n,
  every bit n is listed in one of n's lists, no pending bit at a pause).
- **Module 4's scavenge verifiers** keep running at every stop-the-world
  scavenge in checked builds; they skip deferred frees.
- **Module 5's mark verifier** at every final mark (snapshot entries only:
  never a deferred free, except under the test switch).
- **Module 6's relocation verifier** after relocation work; it skips
  deferred frees. **Module 1's** `verifyHeap` skips them too (and checks
  they are young).

Every verifier skips a deferred free by the one rule, the header's deferred
bit, set by the sweep that defers it in the same step as the slot count 0.

## Stress flags, test switches, counters

| flag (`--stress`) | effect |
|---|---|
| `collectAtEveryHalf` (`everyhalf`) | offload: 64 KiB eden halves |
| `roundAtEveryPoll` (`everypoll`) | a drain round after every 16 copies: every poll during a collection services one |
| `barrierAlwaysOn` (`barrieron`) | the flag word's young bits never clear (the barrier's cost with a collection running); before the collectors review the first marking cycle cleared them (finding 4), and the random programs' `youngBarrierAlwaysOn` configuration now checks the slow path is taken |

Module 3's `perturb` reaches the collector (every service point: between
256 objects, between buffers, in the sweep) and every acknowledgement
(before its work). Test switches (`YoungTestSwitches`): `youngDeletionBarrier`,
`secondHandshake`, `crossNurseryBarrier`, `handshakeStackScan`, `epochRule`,
`carryHolders`, `newHalfScan`, `deferredOwnership`, `quiescentWakeZero`,
`arrayCopyOrdering`, `youngRoots`, and the hook (points 0 before H0, 1 after
H1, 3 after T1's work, 2 after the sweep). `VM.setCopyWindow` and module 6's
`VM.setEnterWindow` are the two windows.

Counters (`vm.youngCounters`, `vm.youngLog`, `vm.roundLog` (the last
`VMConfig.logCapacity` of each since the collectors review; `vm.youngTotals`
the sums, maxima and dropped counts),
`vm.youngWorkerCounters(i)`, `kajo run`'s young and main lines):
collections by mode (local, offloaded, offloaded but run by the owner),
rounds per collection and every round's latency with its last acknowledger,
each collection's phases (H0, H1, T1, drain rounds, sweep, epoch wait,
total, CPU), objects and bytes survived, promoted and overflowed, holders
scanned, deletion records, cross-nursery holders remembered by copies,
carried holders, entries freed, deferred and freed after the epoch or kept,
deferred frees released at pauses, hazard retries, new-half words, header
claim failures, snapshot exclusions, fallbacks by cause, young-root scans
(count, total and max time, words), the collector's CPU, QoS and wakeups;
per participant: acknowledgements of its own and other nurseries' rounds
(count, time, max) and the polls that found none owed, own collections and
flips (count, time, max), waits for the collector, eden-reuse waits (count,
time, max), waits for a stop and for collections before a stop, resume
scans, blocking regions. Module 3's `stopperQoSRaises` counts stoppers
raised for their stop; module 5's records keep the marker's QoS per cycle.

## Measurements

All on the M2 Max (8 P + 4 E cores), macOS 27, Swift 6.4, release builds,
2026-11-03 06:55 to 07:30, with no `yes` loop and no other test run alive;
module 6's `kajo` from 4e5de49 in a worktree, this module's from 714211d
(`.build/bench`, `.build/bench-a2`). Five interleaved runs, medians (min to
max).

### Barrier cost against module 6 (aligned builds)

Both binaries built with `-align-all-nofallthru-blocks=5 -align-loops=32`;
`--slice-ms 0`. "Bits on" is this module with `--stress barrieron` (the flag
word's young bits never clear: every pointer store takes the out-of-line
path with the young deletion check, as while a collection runs, with no
collection's work).

| kernel | workers | module 6 ms | module 7 ms | module 7, young barrier bits on, ms | module 7 / module 6 | bits on / module 7 |
|---|--:|--:|--:|--:|--:|--:|
| ivars | 1 | 2069.8 (2059 to 2210) | 2080.3 (2056 to 2108) | 2429.9 (2415 to 2456) | **1.005** | 1.168 |
| ivars | 8 | 271.8 (268 to 278) | 270.9 (266 to 280) | 318.1 (314 to 322) | **0.997** | 1.174 |
| storeheavy | 1 | 2260.2 (2238 to 2270) | 2260.7 (2242 to 2285) | 4240.9 (4189 to 4267) | **1.000** | 1.876 |
| storeheavy | 8 | 294.3 (293 to 310) | 291.4 (290 to 319) | 560.3 (549 to 567) | **0.990** | 1.923 |
| arith | 1 | 2575.9 (2562 to 2598) | 2578.0 (2565 to 2609) | 2580.8 (2563 to 2596) | **1.001** | 1.001 |
| arith | 8 | 343.9 (343 to 349) | 342.7 (342 to 345) | 342.6 (342 to 345) | **0.997** | 1.000 |
| fib | 1 | 1672.2 (1666 to 1681) | 1679.3 (1675 to 1705) | 1684.5 (1668 to 1757) | **1.004** | 1.003 |
| fib | 8 | 218.8 (216 to 246) | 219.6 (218 to 230) | 218.5 (217 to 233) | **1.004** | 0.995 |
| sends | 1 | 2542.3 (2527 to 2593) | 2585.2 (2576 to 2592) | 2565.7 (2561 to 2966) | **1.017** | 0.992 |
| sends | 8 | 334.4 (330 to 636) | 338.9 (336 to 444) | 341.6 (341 to 569) | **1.013** | 1.008 |

- **No collection running: within noise of module 6** on `ivars` (1.005 and
  0.997) and `storeheavy` (1.000 and 0.990); `arith` and `fib`, which store
  nothing, 1.001 to 1.004; `sends` 1.013 to 1.017 (it stores nothing into
  the heap either: placement). The store's fast path is the same
  instructions (`interpret` 794 instructions, one jump table, module 6's
  post-store sequence).
- **With the young bits on** every pointer store is an out-of-line call
  (`storeWithBarriers`: the deletion check's load of the old value, its
  header and `collecting[n]`, the store and its check): `ivars` 1.17,
  `storeheavy` 1.88 to 1.92 (eight SmallInteger stores per iteration, all
  through the call). A real collection keeps the bits up only while it
  runs: in the storm at eight workers a nursery's collection runs about 1.2
  ms p50, and with eight nurseries some collection runs most of the time;
  the matrix's run times below include that.

### The headless matrix of experiments/concurrent-young

`kajo run` with the main thread as the shell's: one frame every 8.33 ms,
each a main-affine `mainTick:work:` (mainload.kasm) run in turns of at most
a frame: storm and ring and share with 20 Pairs and 60 000 loop iterations
per frame (about a quarter of each frame inside the VM), the heavy
main-thread case with 8 000 Pairs and nothing else, its background workers
idle (idle.kasm, five seconds). Storm is alloc with 320 trees per worker
(allocstorm.kasm), ring is fragment (`--heap 240` with one worker, 2 million
iterations; `--heap 600` with eight, 16 million: 240 MiB ran the promotion
reserve out with eight workers, in every mode), share is share.kasm with 3
million iterations per worker (sharestorm.kasm); 4 MiB nurseries, N = 2,
concurrent marking and relocation on (the defaults), `--slice-ms 0`.
**Every checksum equals the stop-the-world oracle's in every run** (5 of 5
per cell).

"Stopped for others" is the main worker's time per 10 s parked in stops
(stop-the-world scavenges, the cycle's pauses), acknowledging rounds of
other nurseries' collections (and polls that took the mutex and found none
owed), and waiting for collections before a stop or for a pending stop.
"Own" is its own collections (local), flips and waits for the collector
(offload); in `stw` its own scavenges are its stop time.

| scenario | workers | mode | ms:0 | =checksum | mainStoppedOthersMsPer10s | mainParkMsPer10s | mainAcksOther:0 | mainAckOtherMeanUs | mainAckMaxMs:3 | mainStopMsPer10s | mainStoppedOwnMsPer10s | mainFlipMaxMs:3 | mainOwnMaxMs:3 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| storm | 1 | stw | 2810 (2792-2834) | 41950911 | 386.5 (360.7-487.1) | 386.5 (360.7-487.1) | 0 | - | 0.000 | 0.0 | 0.0 | 0.000 | 0.000 |
| storm | 1 | local | 2918 (2918-2926) | 41950911 | 4.1 (3.4-4.8) | 0.7 (0.0-1.6) | 168 (157-177) | 5.8 (5.3-6.7) | 0.018 (0.017-0.023) | 0.0 | 0.0 | 0.000 | 0.000 |
| storm | 1 | offload | 2918 (2910-2926) | 41950911 | 4.7 (3.7-7.3) | 1.3 (0.4-4.0) | 170 (165-174) | 5.8 (5.6-6.1) | 0.019 (0.018-0.078) | 0.0 | 0.0 | 0.000 | 0.000 |
| storm | 8 | stw | 3260 (3235-3380) | 335607288 | 707.6 (665.1-750.6) | 707.6 (665.1-750.6) | 0 | - | 0.000 | 0.0 | 0.0 | 0.000 | 0.000 |
| storm | 8 | local | 3453 (3193-3502) | 335607288 | 133.6 (122.3-274.0) | 7.7 (0.0-134.6) | 1467 (1330-1538) | 29.1 (27.6-33.2) | 1.106 (0.907-3.363) | 0.0 | 0.0 | 0.000 | 0.000 |
| storm | 8 | offload | 3464 (3344-3694) | 335607288 | 129.4 (112.3-290.4) | 6.6 (0.6-161.9) | 1496 (1379-1551) | 27.9 (27.6-31.1) | 0.801 (0.415-2.136) | 0.0 | 0.0 | 0.000 | 0.000 |
| ring | 1 | stw | 1643 (1626-1660) | 2212269504696 | 83.0 (75.5-106.4) | 83.0 (75.5-106.4) | 0 | - | 0.000 | 0.0 | 0.0 | 0.000 | 0.000 |
| ring | 1 | local | 1651 (1643-1684) | 2212269504696 | 2.5 (2.4-3.0) | 0.0 | 77 (74-85) | 5.5 (5.1-5.8) | 0.016 (0.011-0.018) | 0.0 | 0.0 | 0.000 | 0.000 |
| ring | 1 | offload | 1660 (1643-1676) | 2212269504696 | 3.3 (2.4-3.7) | 0.8 (0.0-1.2) | 73 (71-79) | 5.4 (5.2-6.1) | 0.017 (0.013-0.018) | 0.0 | 0.0 | 0.000 | 0.000 |
| ring | 8 | stw | 2775 (2766-2799) | 17698143198236 | 2273.3 (2110.9-2398.6) | 2273.3 (2110.9-2398.6) | 0 | - | 0.000 | 0.0 | 0.0 | 0.000 | 0.000 |
| ring | 8 | local | 2326 (2301-2377) | 17698143198236 | 206.4 (169.5-228.8) | 22.9 (6.7-33.5) | 1018 (965-1025) | 43.9 (32.1-48.0) | 4.032 (2.583-4.239) | 0.0 | 0.0 | 0.000 | 0.000 |
| ring | 8 | offload | 2343 (2301-2385) | 17698143198236 | 184.6 (158.4-220.1) | 24.8 (3.8-39.4) | 995 (895-1120) | 35.6 (33.4-43.9) | 1.759 (1.237-3.728) | 0.0 | 0.0 | 0.000 | 0.000 |
| heavymain | 1 | stw | 5001 (5001-5003) | 0 | 0.0 | 0.0 | 0 | - | 0.000 | 41.5 (33.0-48.3) | 0.0 | 0.000 | 0.000 |
| heavymain | 1 | local | 5002 (5001-5002) | 0 | 0.0 (0.0-0.0) | 0.0 | 0 | - | 0.081 (0.014-0.124) | 0.0 | 87.8 (81.2-95.7) | 0.000 | 2.178 (2.148-2.505) |
| heavymain | 1 | offload | 5002 (5000-5002) | 0 | 0.0 (0.0-0.0) | 0.0 | 0 | - | 0.052 (0.035-0.115) | 0.0 | 7.6 (6.3-8.0) | 0.015 (0.012-0.026) | 0.000 |
| heavymain | 8 | stw | 5002 (5001-5002) | 0 | 0.0 | 0.0 | 0 | - | 0.000 | 42.3 (33.6-50.2) | 0.0 | 0.000 | 0.000 |
| heavymain | 8 | local | 5002 (5001-5002) | 0 | 0.0 (0.0-0.0) | 0.0 | 0 | - | 0.050 (0.010-0.055) | 0.0 | 91.3 (85.7-97.4) | 0.000 | 2.233 (2.133-3.962) |
| heavymain | 8 | offload | 5002 (5001-5008) | 0 | 0.0 (0.0-0.0) | 0.0 | 0 | - | 0.050 (0.042-0.102) | 0.0 | 7.7 (6.4-8.1) | 0.021 (0.012-0.122) | 0.000 |
| share | 1 | stw | 785 (776-793) | 4500001500512 | 10.5 (3.6-23.6) | 10.5 (3.6-23.6) | 0 | - | 0.000 | 0.0 | 0.0 | 0.000 | 0.000 |
| share | 1 | local | 776 (776-793) | 4500001500512 | 2.4 (1.8-2.6) | 0.0 | 39 (32-43) | 4.8 (4.4-4.9) | 0.013 (0.012-0.016) | 0.0 | 0.0 | 0.000 | 0.000 |
| share | 1 | offload | 785 (776-785) | 4500001500512 | 2.2 (1.6-2.9) | 0.0 | 39 (30-45) | 4.4 (4.1-5.1) | 0.012 (0.011-0.014) | 0.0 | 0.0 | 0.000 | 0.000 |
| share | 8 | stw | 885 (885-893) | 876000012004096 | 138.9 (131.1-153.8) | 138.9 (131.1-153.8) | 0 | - | 0.000 | 0.0 | 0.0 | 0.000 | 0.000 |
| share | 8 | local | 951 (943-952) | 876000012004096 | 194.6 (168.8-211.4) | 0.0 | 588 (523-621) | 32.0 (28.8-32.3) | 0.718 (0.091-0.974) | 0.0 | 0.0 | 0.000 | 0.000 |
| share | 8 | offload | 951 (951-959) | 876000012004096 | 203.2 (176.1-204.1) | 0.0 | 601 (553-620) | 32.0 (29.7-34.8) | 0.404 (0.195-2.670) | 0.0 | 0.0 | 0.000 | 0.000 |

Young collections (rounds' request-to-last-acknowledgement latency with
the slowest participant of the worst round in each run, a collection's
total time per mode, the eden-reuse wait summed over the workers, module 5's
fallbacks, cycles, the initial mark's young-root scan):

| scenario | workers | mode | ackP50ms:3 | ackP99ms:3 | ackMaxMs:3 | =ackSlowest | ycLocalP50ms:3 | ycLocalP99ms:3 | ycOffP50ms:3 | ycOffP99ms:3 | scavP50ms:3 | scavP99ms:3 | edenWaits:0 | edenWaitMs:1 | edenWaitMaxMs:3 | fallbacks:0 | cycles:0 | youngRootScanMeanMs:3 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| storm | 1 | stw | - | - | - | - | - | - | - | - | 1.376 (1.357-1.403) | 1.697 (1.599-1.735) | - | - | - | 0 | 3 (2-3) | - |
| storm | 1 | local | 0.000 | 0.017 (0.016-0.019) | 0.028 (0.025-0.047) | 0 | 1.698 (1.689-1.713) | 1.925 (1.897-1.965) | - | - | - | - | 320 | 0.8 (0.6-0.9) | 0.043 (0.038-0.043) | 0 | 3 | 0.104 (0.101-0.108) |
| storm | 1 | offload | 0.000 | 0.017 (0.017-0.018) | 0.025 (0.024-0.082) | 0 | 1.693 (1.678-1.710) | 1.901 (1.873-1.972) | - | - | - | - | 320 | 0.7 (0.6-0.9) | 0.043 (0.042-0.048) | 0 | 3 | 0.104 (0.101-0.109) |
| storm | 8 | stw | - | - | - | - | - | - | - | - | 2.299 (2.275-2.397) | 3.807 (3.527-3.894) | - | - | - | 0 (0-1) | 12 (11-12) | - |
| storm | 8 | local | 0.038 (0.037-0.038) | 0.301 (0.251-0.317) | 2.382 (1.770-3.850) | 0,2,5,7,8 | 1.199 (1.079-1.451) | 2.942 (2.903-3.145) | - | - | - | - | 2553 (2552-2553) | 90.3 (88.1-94.8) | 1.091 (0.777-5.424) | 1 | 8 (5-11) | 2.415 (1.802-2.452) |
| storm | 8 | offload | 0.038 (0.037-0.038) | 0.309 (0.296-0.346) | 2.276 (1.760-3.128) | 2,3,7 | 1.176 (1.158-1.550) | 3.034 (2.826-3.129) | - | - | - | - | 2553 (2552-2553) | 87.3 (84.5-90.0) | 0.809 (0.518-0.879) | 1 | 8 (7-10) | 2.341 (2.112-2.658) |
| ring | 1 | stw | - | - | - | - | - | - | - | - | 0.539 (0.529-0.549) | 0.909 (0.706-1.040) | - | - | - | 0 | 1 | - |
| ring | 1 | local | 0.000 | 0.016 (0.015-0.017) | 0.022 (0.016-0.028) | 0 | 0.689 (0.685-0.716) | 0.986 (0.946-1.063) | - | - | - | - | 137 | 0.4 (0.3-0.5) | 0.040 (0.039-0.042) | 0 | 1 | 0.057 (0.057-0.058) |
| ring | 1 | offload | 0.000 | 0.016 (0.015-0.020) | 0.023 (0.018-0.026) | 0 | 0.688 (0.685-0.702) | 0.962 (0.891-1.045) | - | - | - | - | 137 | 0.4 (0.3-0.5) | 0.043 (0.038-0.045) | 0 | 1 | 0.058 (0.057-0.058) |
| ring | 8 | stw | - | - | - | - | - | - | - | - | 6.843 (6.739-6.880) | 9.549 (9.404-10.238) | - | - | - | 0 | 8 | - |
| ring | 8 | local | 0.112 (0.079-0.167) | 0.869 (0.830-1.094) | 4.039 (2.584-4.482) | 0,2,6 | 2.427 (2.375-2.528) | 5.049 (4.659-5.982) | - | - | - | - | 1096 | 159.4 (148.1-167.5) | 0.904 (0.853-2.017) | 0 | 11 (10-12) | 2.542 (2.245-2.639) |
| ring | 8 | offload | 0.089 (0.066-0.156) | 0.885 (0.810-0.959) | 3.737 (1.935-4.386) | 0,1,3 | 2.517 (2.341-2.618) | 4.447 (4.082-5.246) | - | - | - | - | 1096 | 150.0 (125.1-184.6) | 1.022 (0.808-4.908) | 0 | 11 (10-12) | 2.684 (2.329-2.884) |
| heavymain | 1 | stw | - | - | - | - | - | - | - | - | 0.518 (0.401-0.584) | 1.146 (1.119-1.863) | - | - | - | 0 | 0 | - |
| heavymain | 1 | local | 0.002 (0.002-0.003) | 0.008 (0.008-0.020) | 0.082 (0.015-0.126) | 0 | 1.063 (1.009-1.149) | 2.174 (2.141-2.500) | - | - | - | - | 36 | 0.0 (0.0-0.0) | 0.003 (0.001-0.004) | 0 | 0 | - |
| heavymain | 1 | offload | 0.016 (0.014-0.018) | 0.057 (0.046-0.124) | 0.104 (0.052-0.741) | 0 | - | - | 0.811 (0.632-0.973) | 2.006 (1.628-3.458) | - | - | 0 | 0.0 | 0.000 | 0 | 0 | - |
| heavymain | 8 | stw | - | - | - | - | - | - | - | - | 0.495 (0.417-0.632) | 1.147 (1.127-1.271) | - | - | - | 0 | 0 | - |
| heavymain | 8 | local | 0.003 (0.002-0.003) | 0.013 (0.009-0.048) | 0.052 (0.034-0.057) | 0 | 1.150 (1.040-1.183) | 2.229 (2.127-3.957) | - | - | - | - | 36 | 0.0 (0.0-0.0) | 0.003 (0.002-0.004) | 0 | 0 | - |
| heavymain | 8 | offload | 0.015 (0.013-0.018) | 0.055 (0.046-0.062) | 0.066 (0.057-0.136) | 0 | - | - | 0.770 (0.760-0.878) | 1.944 (1.747-2.418) | - | - | 0 | 0.0 | 0.000 | 0 | 0 | - |
| share | 1 | stw | - | - | - | - | - | - | - | - | 0.067 (0.065-0.071) | 0.138 (0.125-0.257) | - | - | - | 0 | 0 | - |
| share | 1 | local | 0.000 | 0.015 (0.013-0.016) | 0.019 (0.018-0.027) | 0 | 0.196 (0.195-0.197) | 0.272 (0.263-0.273) | - | - | - | - | 68 | 0.2 (0.1-0.3) | 0.042 (0.038-0.043) | 0 | 0 | - |
| share | 1 | offload | 0.000 | 0.016 (0.013-0.017) | 0.018 (0.018-0.023) | 0 | 0.196 (0.195-0.198) | 0.277 (0.271-0.279) | - | - | - | - | 68 | 0.2 (0.2-0.2) | 0.040 (0.037-0.043) | 0 | 0 | - |
| share | 8 | stw | - | - | - | - | - | - | - | - | 0.446 (0.444-0.450) | 0.605 (0.542-0.782) | - | - | - | 0 | 0 | - |
| share | 8 | local | 0.041 (0.040-0.042) | 0.268 (0.224-0.302) | 1.432 (1.105-1.907) | 2,4,7 | 0.467 (0.459-0.477) | 1.280 (1.166-1.479) | - | - | - | - | 544 | 21.0 (20.8-21.7) | 0.326 (0.178-0.680) | 0 | 0 | - |
| share | 8 | offload | 0.041 (0.041-0.042) | 0.305 (0.186-0.379) | 1.412 (1.217-2.681) | 0,5,6,8 | 0.466 (0.460-0.471) | 1.234 (1.182-1.589) | - | - | - | - | 544 | 21.4 (20.9-22.5) | 0.494 (0.226-0.642) | 0 | 0 | - |

What the matrix says:

- **Storm, eight workers: the main worker stopped 708 ms per 10 s for
  others under stop-the-world, 134 (local) and 129 (offload)**: 5.3 and
  5.5 times lower (the brief expected 2 to 4), in pieces of 28 to 29 µs
  (about 1 500 acknowledgements per 10 s; the longest 0.8 to 1.1 ms p50
  over runs). The experiment measured 126 against 36 and 67 ms in its
  AppKit app; this driver keeps the main thread inside the VM about a
  quarter of every frame, so it acknowledges more rounds and parks in every
  scavenge it is inside for. The residue besides acknowledgements is the
  cycle's pauses (initial marks with the young-root scan, 2.3 to 2.4 ms
  each; final marks; applies), 7 ms per 10 s median, up to 162 in the run
  that had a fallback.
- **Ring, eight workers: 2 273 against 206 and 185 ms per 10 s** (11
  times); acknowledgements 36 to 44 µs (the ring's stacks and buffers are
  larger).
- **Heavy main-thread allocation**: the main worker's own collection is
  0.04 ms p50 as a stop-the-world scavenge (its own stop: 42 ms per 10 s),
  1.1 ms locally (88 to 91 ms per 10 s: one thread copies, three rounds,
  the epoch), and **a flip of 0.015 to 0.021 ms max under offload (7.6 to
  7.7 ms per 10 s)**, with the collector thread doing the 0.8 ms
  collections. Offload is what keeps a main-thread allocation burst off the
  frame.
- **Share, eight workers: worse than stop-the-world for the main worker**:
  195 and 203 against 139 ms per 10 s, all acknowledgements (590 to 600 at
  32 µs): the kernel's collections are many and cheap (0.47 ms p50) and the
  stop-the-world scavenges short (0.45 ms p50, 0.6 ms p99), so one
  acknowledgement per round costs the main thread more than parking in a
  few short stops. The experiment saw the same (share offload 113 ms per
  10 s, all acknowledgements). With one worker every scenario is 3 to 100
  times lower than stop-the-world.
- **Run times**: storm and share at eight workers 6 to 7 percent slower
  than stop-the-world (local and offload alike: one thread copies each
  nursery, with module 6's protocol per object, against eight copying
  everything in a stop), ring 16 percent faster, one worker within 4
  percent.
- **Rounds**: p50 0.04 ms at eight workers (0.09 to 0.11 on the ring), p99
  0.3 (0.9 on the ring), max 1.4 to 4.0 ms; the slowest participant of the
  worst round differs between runs (workers 0 to 8: the main worker, every
  background worker, no one cause), as the experiment found. With one
  background worker every round's p99 is under 0.02 ms.
- **Collections**: local p50 1.2 ms (storm), 2.4 ms (ring), 0.47 ms
  (share), p99 3, 5, 1.3 ms at eight workers; the offloaded main-thread
  nursery 0.8 ms p50, 2 ms p99. Eden-reuse waits: 2 553 per storm run,
  90 ms summed over eight workers (35 µs mean, 1.1 ms max); none for the
  offloaded nursery (its next flip finds the collection done).
- **Fallbacks**: one full collection per storm run at eight workers in the
  young modes (0 to 1 under stop-the-world): the entry table filling during
  a cycle (the entries trigger, `fallbacks` counts it); none elsewhere.
  Before the trigger counted young promotions every eight-worker storm had
  three to five (Found during development).
- **The young-root scan** at the initial mark: 0.06 to 0.10 ms with one
  nursery busy, 2.3 to 2.7 ms mean with eight (ADR 0008's budget: 2 to 3 ms
  for eight 4 MiB nurseries; single-threaded, Not done).

### Idle

`aParkedVMDoesNotWakeItsYoungCollector`: in a parked second the young
collector used 0 ns of CPU and woke 0 times, the marker 0 ns and 0 times;
the collector's QoS is user-initiated (25). `grep -rn
"timedwait\|asyncAfter" Sources/KajoVM`: module 3's Delay only. The
collector thread waits untimed on its own condition between collections.

## Changes to modules 1 to 6

Module 1 (`ObjectMemory/`):

- `headerWord` is a relaxed atomic load (`headerAtomic` gives the word as an
  atomic): a young collector decides a header while mutators read class and
  count. `initializeObject` writes the body, header and state word with
  relaxed atomic stores (amendment 13).
- Header bit 49 is the deferred-free bit (`Header.deferredBit`,
  `isDeferredFree`); reserved bits are 46, 50, 51. `verifyHeap` skips a
  deferred free (and checks it is young).
- `ObjectMemoryConfig.nurseryRegionBytes`: the block heap's reservation maps
  that many bytes twice after the blocks (`BlockHeap.extraBytes`), and
  `reserveNurseryRegion` puts the nursery region there (`nurseryRegionAliased`);
  without it the region is plain memory as before (and the mode is `stw`).
- `EntryStash.pushNext`; `forEachRegisteredRoot`; `forEachFinalizedLocked`.

Module 2: primitive 39 `slowPeek:` (tests, in `YoungCollection/Mutator.swift`).

Module 3 (`Workers/`, `Processes/`):

- The safepoint flag is the attention word: stops set and clear bit 0 with
  `fetch_or`/`fetch_and`; `pollSlow` parks for bit 0 and services rounds for
  bits 1.., checking the budget at every 64th such poll.
- `SafepointState` gains `inside`, `blocking` (per participant),
  `stwWanted`, `ycActive`; `enterVM` and `leaveVM` call `youngEnterLocked`
  and `youngLeaveLocked` in their mutex hold; `stopWorld` waits for
  collections (`waitForCollectionsLocked`) and raises a stopper outside the
  worker table to user-initiated for its stop (`stopperQoSRaises`);
  `parkLocked` is internal; new stop kinds `initialMark`, `verify`.
- `VMState`: the global epoch, the held-hazard count and the enter window
  moved here from module 6 (`epoch`, `hazardsHeld`, `enterWindow`),
  `epochsOn`, `young`; `WorkerShared` lines for the marker and the collector
  too.
- `Worker.youngHeld` (the allocation slow path's kept oop, an H1 root).
- `runSlice` runs the resume scan; `createProcess` sets a new record's scan
  words; primitive 29's shell call is a blocking region.
- `TurnStats.youngNs`, `acks`; `VMConfig.young`; `VM.start` and `shutdown`
  start and join the young collector thread.

Module 4 (`Nursery/`):

- The remembered word is 32 bits (bit n member, bit 16 + n pending);
  buffers are per owner and nursery (`NurseryAlloc.buffers`,
  `NurseryShared.buffers`, 16 remembered and 16 deletion each, the marker's
  and the collector's slots included); every nursery has a carried list.
- Survivor state (`survivorStart`, `survTo`, `survFromTop`, `survLog`) moved
  to `NurserySurvivors` with the carried and deferred lists and the second
  stash; `NurseryAlloc` gains `edenStart` as a var (the current half),
  `edenBase`, `halves`, `half`, `halfBytes`, `rememberYoungHolders`.
- `rememberSlow`: a young holder of another nursery is remembered in the
  young modes; the remembered-word load is seq_cst.
- The scavenge takes every list (each holder once, young holders dropped:
  amendment 12), remembers into carried lists by bit, remembers young
  survivors for other nurseries in the young modes, gives a participant
  outside the worker table (the marker, the collector) a scavenge state with
  no survivor-to (it promotes), and releases deferred frees
  (`releaseDeferred`).
- The nursery verifier: young-mode remembered-set rules (Deviations), skips
  deferred frees, `verifyRememberedAtPause`.
- `NurseryConfig.regionBytes`; primitive 35 collects the caller's nursery in
  the young modes; `promoteAllForOldSpace` maps a stopper outside the table.

Module 5 (`Marking/`):

- `initialMark` runs the young-root scan instead of the survivor scan in
  the young modes (and the deferred-entries test switch);
  `decideTrigger(rate:oldEntries:record:)`; `countOldEntriesAtPause`; the
  old-entry estimate counts young promotions.
- `storeWithBarriers` makes the young deletion record; the final mark
  filters every owner's and nursery's list; `markerPoll` parks only for
  bit 0.

Module 6 (`Relocation/`):

- `epochAdvance`, `epochQuiesce`, `epochEnter` work whenever an epoch is
  kept (relocation or young collection), for the workers and the young
  collector (`isEpochParticipant`); `epochWake` (new); `minParticipantEpoch`
  (`tryFreePending` uses it, so the relocator also waits for the
  collector). `hazardAcquire`/`Release` use the VM's count;
  `isHazarded(vm, o)`.
- `copySlots` makes the young deletion record and has the ordering test
  switch and window.
- The relocation verifier skips deferred frees.

Tests of modules 1 to 6 changed: the header-bit and heap-verifier tests
(bit 50 is the reserved one now), the nursery verifier's needle ("in no
list"), and the tests that test module 4's stop-the-world rules set
`young.mode = .stw` (`deadYoungEntriesAreFreedAndReused`,
`aPromotedHolderOfASurvivorIsRemembered`, module 5's
`survivorsAreRootsAtTheInitialMark` and `withoutFilteringTheScavenge...`);
`gcKeepsParkedProcessStacksAlive`, `aParkedProcessStackIsScanned` and
`aFullCollectionWorksAfterPromotions` count young collections too; the turn
overrun test subtracts the turn's young collection time like its copying
in stops; the random programs' tiny-nursery tallies count young
collections.

## Tests

`Tests/KajoVMTests/YoungCollection/` (27 test functions), the
shared-objects test in every mode (`GenerationalTests`), four random-program
configurations. The suite has 250 tests (module 6: 223).

**Ported from experiments/concurrent-young** (YoungTests, IdleTests), each
rule with the test that fails without it, through `YoungTestSwitches`:

| rule | passes | broken variant (switch) | fails how |
|---|---|---|---|
| young deletion barrier | `youngDeletionBarrierKeepsAValueTakenAfterH0` | `withoutTheYoungDeletionBarrierTheValueIsLost` (`youngDeletionBarrier`) | young verifier: "reachable entry 1537 is free" |
| second handshake | (same) | `withoutTheSecondHandshakeTheDeletionRecordIsNeverSeen` (`secondHandshake`) | "reachable entry 1537 is free" |
| cross-nursery barrier | `aYoungHolderInAnotherNurseryIsRememberedAndScanned` | `withoutTheCrossNurseryBarrierTheValueIsLost` (`crossNurseryBarrier`) | "reachable entry 1537 is free" |
| handshake stack scan | `aRunningWorkersStackIsScannedAtH1` | `withoutTheHandshakeStackScanTheValueIsLost` (`handshakeStackScan`) | "reachable entry 1537 is free" (the Process is terminated instead of sending to it) |
| epoch rule | `edenIsReusedOnlyAfterEveryWorkersEpoch` (the collection cannot finish while `slowPeek:` holds its address; it reads 42) | `withoutTheEpochRuleAPrimitiveReadsAReusedEden` (`epochRule`) | the collection finishes while the address is held; after the churn the primitive reads something else |
| carried holders | `aRememberedHolderIsCarriedAcrossLocalCollections` | `withoutCarryingTheHolderTheSurvivorIsLost` (`carryHolders`) | "reachable entry 1389 is free" |
| offload, cross-nursery holder | `anOffloadedCollectionFindsACrossNurseryHolder` | | |
| new-half scan | `theOwnersNewHalfObjectsAreScannedAtT1` | `withoutNewHalfScanTheValueIsLost` (`newHalfScan`) | "reachable entry 1537 is free" |
| deferred ownership, snapshot | `aDeferredEntryFreeIsNotASnapshotEntry` | `withoutDeferredOwnershipTheSnapshotHoldsAReusedEntry` (`deferredOwnership`) | mark verifier: "entry 2561 is reachable but not marked (missed)" |
| deferred ownership, full collection | `aFullCollectionLeavesADeferredEntryFreeToItsNursery` | `withoutDeferredOwnershipAFullCollectionFreesAnEntryTwice` (`deferredOwnership`) | free-list verifier: "entry 2561 is twice in the free lists (stash 8)" |
| shared objects, every mode | `sharedYoungObjectsAreClaimedOnceByParallelScavengers(stw, local, offload)` | | |
| idle | `aParkedVMDoesNotWakeItsYoungCollector` (0 ns and 0 wakeups in a parked second, marker too; collector QoS user-initiated), `offloadedCollectionsCompleteAfterIdling` | | |

**New**:

| rule | passes | broken variant | fails how |
|---|---|---|---|
| array copy store ordering (finding 1) | `theArrayCopyStoreIsSeenByTheCollector` | `withRelaxedArrayCopyStoresTheHolderIsLost` (`arrayCopyOrdering`) | young verifier at the next stop: "entry 1537 (old) names young @1388 (nursery 1) in slot 1, and is not remembered for it" |
| the quiescent wake's 0 (finding 3) | `aQuiescentWakeStoresEpochZeroFirst` (the smallest participant word in the window is 0) | `withoutTheZeroAQuiescentWakeLetsTheEpochPass` (`quiescentWakeZero`) | the window sees the word quiescent: a collection's check would pass |
| young-root scan (Part 3) | `theYoungRootScanGreysWhatYoungObjectsName` | `withoutTheYoungRootScanTheVerifierReportsTheLoss` (`youngRoots`) | mark verifier: missed > 0 (module 5's lost object) |

The two window tests replace a store buffer by a hook, as module 6's enter
window did: the array copy's window (`VM.setCopyWindow`) holds the store
(broken: after the barrier's load; seq_cst: after the store and the load)
until the collector has scanned its holders (hook point 3); the wake's
window is module 6's enter-window hook, called by `epochWake` between its
load of the epoch and its store, where the test reads what a collector's
epoch check would see. The second is a protocol-level test: a full
interleaving would need the waking participant to hold up a collection whose
rounds need it.

**Random programs** (`randomProgramsAgreeWithTheirModel`): the fourteen
earlier configurations now run under the default offload policy (background
local collections: the `scavenge` primitive collects the caller's nursery);
new: `stwScavenge` (the oracle), `localCollection`, `offloadCollection` (even
tasks forked onto the main worker, driven by the test thread's turns), and
`roundEveryPoll`; 24 KiB nurseries, perturbation at 2 percent reaching the
collector and the acknowledgements, the young verifier after every
collection. A hundred seeds each in the suite, ten under ThreadSanitizer, a
thousand in `just soak`.

**Found during development** (each fixed):

- The collector thread's own acknowledgement looked up its participant
  index in the worker table (a crash at H1): `participantWorker`.
- The test hooks' context outlived by its owner: a use after free (test).
- A Swift `Array` in the batched acknowledgement put ARC on the path:
  `RawArray<OwedRound>`.
- Under the first ThreadSanitizer run: two test threads acted as worker 0
  at once (the new-half test let the collector run worker 0 before the test
  thread had returned from its flip's `leaveVM`): the test now waits for the
  return. And the young verifier after every collection made the run take
  108 CPU minutes: off by default.
- The turn-overrun test (module 3) failed in the full suite: while rounds
  are open every poll reaches the slow path, which took the mutex every
  time (8 ms per budget window): the round serial; and the budget is now
  checked at the attention polls too.
- The remembered-set verifier's strict list checks (module 4) reported
  stale names of freed holders in young modes: relaxed (Deviations).
- Released deferred entries went to the end of the stash, so the tests'
  reuse never happened: handed out next.
- The young trigger used module 5's stale old-entry estimate, so at eight
  workers a storm filled the entry table (a full collection, counted as a
  fallback) with no cycle: young promotions now count.
- The suite hung once (a random program with relocation): the marker's
  final mark had requested its stop while two workers waited inside the VM
  for the stop it wanted (`stwWanted`); the request did not broadcast, so
  they never woke to park (lldb: requested, stopper 6, active 3, parked
  0). Every transition a wait inside the VM depends on now broadcasts:
  the stop's request and a requester leaving `stwWanted`.
  `aStopWakesAnOpenerThatWaitsForIt` exercises it (the broken variant, both
  broadcasts removed, hung in 1 of 3 hand runs: the interleaving is a race
  the test makes likely, not certain).
- `theRelocatorNeverParksWhileRelocating` (module 6) counted stops that
  scavenges used to make: it runs module 4's scavenges now.
- Round latency p50 was 0.5 ms with the acknowledgement path taking the
  mutex twice per round: batched, plus service points in the sweep and
  between roots and holders (0.04 ms after, with no load).

## Gates

All on the final code (the last code change is the
random programs' cycle tally, after the stop-request broadcast), in this
order: `swift test` 250 tests green (82 s); under load (twelve `yes`) 250
green (107 s); `swift test --sanitize=thread` with twelve `yes` 250 green,
**zero sanitizer reports** (687 s); `swift test --sanitize=thread` 250
green, **zero sanitizer reports** (486 s). Full outputs kept in the scratch
directory. Earlier loaded sanitizer run (before the tally change): zero
reports, one failure (the cycle configuration's tally under load, fixed
since). `just ios-check` clean (no warning), `just arc-check` (below),
`just golden` (arith 2595, fib 1695, sends 2588, alloc 2918, ivars 2108,
walk 3876, storeheavy 2435 ms, all ok), `just test-release` 250 green,
`just model-check` 15 and 28 tests green, `just soak` 1000 seeds in each
of the 18 configurations, no failure (25 s). A clean build
(`.build/clean-check`) has no warning.

## Hot-path check

`just arc-check` (final code) adds module 7's paths: `storeWithBarriers`
with every bit (178 instructions; the young deletion record inlined),
`serviceRounds` (724), `runRound` (729), `waitServicing` (162 to 180, four
specializations), `youngEnterLocked` (31), `youngLeaveLocked` (188),
`blockingBegin` (66), the collector's `Collector.evacuate` (250),
`copyBody` (10, no call), `Collector.drainGrey` (269), `scanHolder` (134),
`processHanded` (291), `sweep` (427), `freeDeferred` (126), `waitEpoch`
(88), `youngResumeCheck` (237), `primSlowPeek` (74): zero
`swift_retain`/`swift_release` in every one; `interpret` 794 instructions,
one indirect branch, one jump table, module 6's post-store sequence
unchanged in `store_ivar`. (`runRound` appends the round's record to the
log's Swift array under the mutex: no ARC, an occasional reallocation.)

## Unsafe surface

Lines with the `unsafe` keyword (comment lines excluded) after a clean
build, against module 6's tree (4e5de49): `YoungCollection/` 844 (Collect
321, Rounds 172, YoungHost 151, Owner 133, Mutator 39, YoungState 16,
YoungVerifier 12, YoungConfig 0); `ObjectMemory/` 381 to 394 (atomic header
loads and initialising stores, the aliased region); `Workers/` 492 to 518;
`Nursery/` 452 to 530 (per-owner buffers, survivor state, the scavenge's
list taking); `Marking/` 548 to 556; `Relocation/` 345 to 363; `Processes/`
254 to 257; `Interpreter/` 305 unchanged. The surface is the module's state
behind raw pointers (handshakes, flags, ranges, scan words, buffers), the
header and state words as atomics during the copy, the body copy, and the
safepoint mutex and condition; `YoungShared`, `Handshake`, `CollectorWork`,
`Collector` and `OwedRound` are `@unsafe`; the configuration (`@safe` test
switches holding the hook), the counters, the records and the host surface
are safe, so the tests need none.

## Not done

- The 120 Hz scenarios, event latency and missed frames with the shell, and
  the device runs of the mixed QoS policy (module 9). The headless main
  thread here is a driver loop, not AppKit: its "stopped" figures are the
  VM's share, not frames.
- Weak and ephemeron slots in young collections are strong (a young weak
  referent dies at the next stop-the-world scavenge or full collection);
  module 4's weak pass is not ported to the concurrent collector.
- The young-root scan at the initial mark is single-threaded (1.1 ms mean
  at eight 4 MiB nurseries in the storm, 2.7 ms in the ring; ADR 0008's
  budget 2 to 3 ms); making it parallel is not built. (Since the final
  mark on the devices, 2026-11-07, it is not in the pause at all: the
  pause records each nursery's ranges and the marker or the nursery's
  collector scans them outside it, `docs/modules/final-mark.md`.)
- Acknowledgements on the main worker cost 28 to 38 µs each (a stack scan
  and a buffer hand-over under the safepoint mutex), accepted for v0 and
  measured (Measurements).
- Nursery sizing from observed survival; more than one young collector
  thread.
- The model was not extended: the collector thread as a round and epoch
  participant, the deferred release at stop-the-world pauses and the
  batched acknowledgements are argued under Deviations, not model checked.
- The epoch wait inside a collection spins with yields (and a 20 µs sleep
  every 64 spins); it is not a timed wait on a condition and never runs
  while idle, but it is not event-driven either.
- The single safepoint mutex carries every round, acknowledgement, wait and
  stop; under eight allocating workers it is contended (counted as module
  3's `safepointContended`). Splitting it is not done.

## Commands

```zsh
S=<scratch>; git worktree add $S/m6 4e5de49
(cd $S/m6 && swift build -c release --product kajo)
A2=(-Xswiftc -Xllvm -Xswiftc -align-all-nofallthru-blocks=5 -Xswiftc -Xllvm -Xswiftc -align-loops=32)
(cd $S/m6 && swift build -c release --product kajo --scratch-path .build/bench-a2 $A2)
swift build -c release --product kajo --scratch-path .build/bench
swift build -c release --product kajo --scratch-path .build/bench-a2 $A2
zsh barrier.sh $S/m6/.build/bench-a2/release/kajo .build/bench-a2/release/kajo barrier.txt 5
zsh matrix.sh .build/bench/release/kajo matrix.txt 5
python3 agg.py matrix.txt scenario,workers,mode <keys>
for i in $(seq 12); do gtimeout 1500 yes > /dev/null & done; swift test; pkill -x yes
swift test --sanitize=thread --scratch-path .build/tsan-check
just ios-check; just arc-check; just golden; just test-release; just model-check; just soak
```

The scripts (one line per run with `key=value` pairs from `kajo run`):

```zsh
# matrix.sh <kajo> <out> [runs]: for run, scenario, workers 1 and 8, mode stw local offload:
#   storm:     prelude lib allocstorm mainload        --main-ms -1 --main-alloc 20 --main-work 60000
#   ring:      prelude lib fragment fragmentIters[8] mainload --heap 240|600 (1|8 workers) --main-ms -1 --main-alloc 20 --main-work 60000
#   heavymain: prelude lib idle mainload              --main-ms 5000 --main-alloc 8000 --main-work 0
#   share:     prelude lib sharestorm mainload        --main-ms -1 --main-alloc 20 --main-work 60000
#   each: kajo run <files> --workers W --young M --slice-ms 0
# barrier.sh <m6> <m7> <out> [runs]: for run, kernel ivars storeheavy arith fib sends, workers 1 and 8:
#   m6; m7; m7 --stress barrieron   (kajo run prelude lib <kernel> --workers W --slice-ms 0)
```

- Allocation stalls (allocation stalls, 2026-11-12: docs/modules/allocation-stalls.md): `openYoungCollection(belowSoftLimit:)` promises a background owner room below the soft limit only and the owner stalls when refused; `afterYoungCollection` requests no full collection past the soft limit where a marker thread runs.
