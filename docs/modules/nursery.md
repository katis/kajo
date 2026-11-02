# Module 4: nursery

Status: built, 2026-11-02. `Sources/KajoVM/Nursery/`, with the object
memory's side in `Sources/KajoVM/ObjectMemory/Generations.swift`. Tests in
`Tests/KajoVMTests/Nursery/`, fixtures `Fixtures/kernels/nursery.kasm` and
the experiments' kernels (churn, survivors, oldheap, fragment).

Decisions it implements: ADR 0005 (generational collection with per-worker
nurseries, parallel stop-the-world scavenge, remembered set beside the
table), the age-field half of ADR 0007 (two survivor halves per nursery,
promotion after N survivals or on overflow, claim tags), and ADR 0009
sections 1 and 6 as far as the collectors go (weak slots, ephemerons and
the finalization queue, the class format word). Evidence:
experiments/generational-gc, concurrent-relocation Part 1, concurrent-young
("Header word", "Spaces per worker", "Barriers"). Ported by their tests
first.

## What it hides

- Where a young object lives, how it is allocated, when and where it is
  copied, and when it becomes old.
- The remembered set's representation and the barrier's slow path.
- How dead young entries go back to the entry allocator.
- How many participants a scavenge has and how they share work.
- Which header bits mean young, which nursery, what age, and who claimed.

## Layouts

### Header bits as used

| bits | field | written by |
|---|---|---|
| 48 | fired ephemeron: queued once, strong since | the full collector, world stopped |
| 52..55 | nursery index (young only) | the allocating worker before the oop escapes (`youngMark`), the claim CAS |
| 56 | young | the same; cleared by the promoting CAS |
| 57..59 | age: scavenges survived (young only) | the claim CAS |
| 62..63 | claim tag (young only): scavenge s uses bit 62 + (s & 1) | the claim CAS |

An old header has every young-only bit clear (promotion clears young,
nursery, age and both tags in one CAS); module 1's verifier and the
snapshot loader check it. Bits 46 and 49..51 stay reserved. Mutators never
write a published header: the allocating worker writes a young header
before the oop escapes, scavenges and full collections write headers with
the world stopped.

### Nursery region

`ObjectMemory.reserveNurseryRegion` hands out heap offsets beyond the block
range: the anonymous memory module 1's `reserveTwice` already allocated
between the heap and its alias (never a block, never aliased, so module 6's
RELOCATING alias never covers a young body). One region per worker (main,
background, host; at most 16 workers), each `stride = bytes` rounded to 128
bytes:

```
start_k                                              start_k + bytes
|<------------------- eden ------------------>|<- S0 ->|<- S1 ->|
```

S (one survivor half) = `bytes / 8` unless configured; eden = the rest,
rounded down to 128 bytes. Default 4 MiB: eden 3 MiB, halves 512 KiB. One
half is survivor-from (filled to `survFromTop`), the other survivor-to
(empty between scavenges); they flip at the end of every scavenge.

### Per worker (`Nursery/NurseryState.swift`)

| struct | written by | contents |
|---|---|---|
| `NurseryAlloc` (own 128-byte lines; the interpreter state's `young`) | the worker inside the VM; the stopper; one sweep task in a scavenge | eden `top`/`end`, `fastLimit`, `youngMark`, the entry stash, the remembered buffer, the survivor log, the survivor halves and their roles, counters |
| `ScavengeWorker` (own lines) | that worker as a participant during the parallel phase; the stopper outside it | survivor-to bump, work stack, next remembered buffer, new survivor log, weak list, `ParticipantStats` |
| `NurseryShared` (one per VM) | the stopper (`ScavengePhase`, `NurseryLog`); atomics and the packet pool during the phase | task list, claim tag, age limit, counters, scavenge log, the remembered markers, `fullRequested` |

Nothing is written by two threads through one struct (AGENTS.md).

### Remembered set

16 bits per entry beside the table (`NurseryShared.rem`, a reserved,
zero-filled region of `entryCapacity x 2` bytes): bit n set means the holder
names a young object of nursery n. Decided 16 bits rather than a byte: the
same cost in the slow path (one relaxed load, one `fetch_or`), and module 7's
per-nursery sets need no table change. Invariant: a marker is nonzero
exactly while its holder is in one remembered buffer, and only old holders
are remembered. Buffers are per worker, written only by their owner's
barrier; a scavenge reads every buffer as tasks, re-remembers the holders
that still name a young object (and promoted objects that name one) into
the participant's next buffer, and swaps the next buffers in at the end.
Module 7 will split the one buffer per worker into one per nursery.

### Entry freeing: stashes

Decided here: neither the experiment's chunk bitmaps nor a log of runs, but
**entry stashes**, a module 1 concept (`EntryStash` in
`ObjectMemory/Generations.swift`): an array of free entry indices owned by
one stash. Each nursery allocates its young objects' entries from its stash
in order, so `stash[0 ..< next]` are exactly the entries handed out since
the last scavenge: the stash is its own young log, with no extra store on
the allocation path and no load from the table (the entry's words are only
written). The entry sweep (one task per nursery) walks that prefix and the
nursery's survivor log (the survivors it holds, whose entries were handed
out in earlier cycles), frees the entries whose header is young without
this scavenge's tag (state word free, header 0), compacts them to the front
of the stash and keeps the unused entries after them. An empty stash takes
whole runs from module 1's pool (or a fresh chunk at the high water mark);
a stash past `eden / 16 + 4096` entries gives the rest back as runs.
Module 1's free-list verifier walks every stash (one owner per entry) and
module 1's sweep and compaction discard them, as they discard contexts'
lists. The runs alternative needed contiguous ranges, which become-forward
and the sweep's run builder do not keep; the bitmaps would have replaced
module 1's allocator.

## Allocation (`Nursery/YoungAllocation.swift`)

`Machine.allocate`: if the worker has a nursery, `placeYoungIfRoom`
(`bytes > fastLimit || top + bytes > end || next == count` is the one
branch to the slow path; else bump `top`, take `stash[next]`, write the
body and the entry with `header | youngMark` through module 1's
`initializeObject`). The slow path (`allocateYoungSlow`, one out-of-line
call) allocates an object above `largeLimit = min(largeObjectBytes, eden /
2)` (default 8 KiB) old through module 1's context; refills an empty stash;
otherwise stops the world (parking first for another worker's stop) for a
scavenge, or a full collection when the table is out of entries, a stress
flag asks, or a scavenge requested one. `fastLimit` is 0 under
`scavengeAtEveryAllocation` and module 1's `collectAtEveryAllocation`, which
sends every allocation to the slow path at no cost to the fast path.
Image loading allocates old (it uses module 1's context before any VM
exists). Without a nursery (`bytes = 0`) every object is allocated old as in
module 3: the oracle configuration.

## The barrier (`Nursery/Barrier.swift`)

`storeWithBarrier` (`@_transparent`): the store, then

```
if v & 1 == 0:                                   // tbnz
    hv = header(v)                               // ldr
    if hv & young:                               // tbz
        if (header(o) ^ hv) & (young | nursery):  // ldr, eor, tst, b.eq
            rememberSlow(s, o, hv, site)         // one out-of-line call
```

In `interpret`'s `store_ivar` (release build): `str` of the value, then
`tbnz w11, #0` (SmallInteger), `ldr x9, [sp, #0x38]` (the table base,
spilled: the loop's register pressure), `ldr x9, [x9, x11]` (the value's
header), `tbz x9, #56`: **four instructions when the value is old or an
integer**, one of them the reload; seven more to the call when it is young.
`rememberSlow` (61 instructions, no ARC): a young holder is never
remembered (counted, `barrierYoungHolders`); else one relaxed load of the
holder's marker, and if the nursery's bit is clear a `fetch_or`; the call
that turned the marker from 0 pushes the holder on the worker's buffer.
Module 7 adds the deletion record and the flag word in the slow path only.

### Barrier sites

Every VM store of an oop that may be young into a heap object goes through
`storeWithBarrier` (`Machine.store(_:_:_:_:)`, `barrierStore(w, ...)`),
tagged with its `BarrierSite`. Plain `om.store` remains only for
SmallIntegers, nil (never young), the loader (boot: nothing young exists),
and the scavenge's own weak nil'ing. Mutation tests
(`aBarrierSiteSwitchedOff`, `Tests/KajoVMTests/Nursery/BarrierSiteTests.swift`)
switch each site off in turn (`testSwitches.skipBarrierAt`) and run
scenarios that make an old holder name a young object through it; the
remembered-set verifier before the next scavenge must report it:

| site | store | caught when off |
|---|---|---|
| `storeIvar` | interpreter `store_ivar` | yes |
| `atPut` | primitive `at:put:` | yes |
| `globalAtPut` | primitive `globalAt:put:` (globals are old) | yes |
| `hostGlobal` | `VM.setGlobal` | yes |
| `readyQueueLink` | previous tail's `next` | yes |
| `unlinkLink` | previous Process's `next` on unlink | yes |
| `processResult` | a terminated Process's `result` | yes |
| `waitingOn` | a waiting Process's `waitingOn` | yes |
| `waiterLink` | last waiter's `next` | yes |
| `lastWaiterOnWait` | Semaphore `lastWaiter` on wait | yes |
| `firstWaiterOnWait` | Semaphore `firstWaiter` (empty list) | no: `lastWaiterOnWait` remembers the same holder in the same critical section |
| `firstWaiterOnSignal` | `firstWaiter` when a signal pops | no: the young next waiter was appended through `lastWaiterOnWait` this cycle |
| `unlinkFirstWaiter`, `unlinkLastWaiter` | Semaphore ends after an unlink | no: as above |
| `exitSemaphore` | a new Process's exit Semaphore | no: the Process is young (allocated in the same primitive, no safepoint since) |
| `messageArgument`, `messageSelector`, `messageArguments` | `doesNotUnderstand:`'s Message and Array | no: fresh young holders |

Ten caught, eight not, the same split as the experiment's (6 of its 11
internal sites, plus the visible ones). The eight stay: card marking, a
reordering or module 7's per-nursery sets would make them necessary.

## The scavenge (`Nursery/Scavenge.swift`)

A stop (module 3's `stopWorld`) whose work is `scavenge(vm, w, roots:)`.
Every nursery is collected; the stopper and every worker parked at the stop
take part (module 3's `parkLocked` joins the stop's **parallel phase** while
it is open: `runParallelPhase` opens it, takes part, closes it and waits for
everyone who joined). Workers outside the VM do not take part; their
nurseries are processed by whoever takes the tasks.

**Roots**: module 3's stop roots (every Process stack through its saved sp,
running workers' receiver and method registers, `result` registers, ready
queue words, pending roots, what the stopper keeps) plus module 1's (class
table, registry, finalization queue), as values: oops never change, so no
root and no slot is ever rewritten; only entries and the copied bodies are
written. Plus the remembered holders.

**Phases**: prep (stopper: claim tag, age limit, root and remembered tasks
of 4096 words and 256 holders, survivor-to bumps, the verifier before);
copy (each participant takes tasks with one `fetch_add`, scanning root
words or remembered holders, then drains its own stack; work sharing below);
the copy barrier (`inCopy == 0`); the entry sweep (one task per nursery, as
above); join; then the stopper nils weak slots, swaps remembered buffers and
survivor logs, flips survivor halves, resets edens, runs the verifier after,
and requests a full collection if old space is past its soft limit.

**Claiming** (`Nursery/Claim.swift`): one CAS on the header. Scavenge s uses
tag bit 62 + (s & 1). The winner computes age + 1: below N, not
`promoteAll`, and room in its own survivor-to: survive (age + 1, the
winner's nursery index, this tag, the other cleared); else promote (young,
nursery, age and both tags cleared), an **overflow promotion** when only the
room was missing. A participant that loses or finds the tag set reads the
decision from the header (young means survived). No pass clears tags.
`ClaimCell` runs the same rule on a plain word for the tests.

**Copying**: the winner bumps its survivor-to or its promotion block (module
1's `bumpPromotion` through the participant's own allocation context,
taking reserve blocks), copies the body (a word loop up to 128 bytes,
`memcpy` above), writes the new offset into the entry, logs a survivor's
entry in its survivor log, and pushes a pointer object on its stack.
Scanning a copied object scans every slot of an ordinary or ephemeron
object and only the named slots of a weak one (and lists it for the weak
pass); a promoted object that names a young one is remembered for the next
scavenge.

**Work sharing**: the experiment's. Every 1024 objects a participant whose
stack holds 8 or more exports the bottom half (up to 256 oops) as a packet
to a mutex-guarded pool of 64 if another participant is idle and the pool
is empty; a participant out of tasks takes packets, and an idle one re-enters
`inCopy` (only from a nonzero count) before taking one, so `inCopy == 0`
means no packet is left and no copy is in flight. Copy rate per participant
is reported (`ScavengeRecord.copiedBytesPerParticipant`, `busyNsPerParticipant`;
`kajo run` prints `copyMBsPerParticipant`).

**Weak slots**: not traced by the scavenge. After the join the stopper
looks at every weak object scanned this scavenge (young survivors and
promotions, and remembered old holders): a weak slot naming an entry the
sweep freed becomes nil; an old weak holder still naming a young object is
remembered. Ephemerons are strong in a scavenge (v0 rule below).

**Promotion reserve**: old space has a soft limit (`heapBytes`) and a
reserve beyond it (`reserveBytes`) that only promotion may take
(`refillBlock(reserve:)`). `NurseryConfig.reserveBytes(workers:)` sizes it
at twice everything the nurseries hold, plus a third for block tails, plus
two blocks per participant; a VM whose object memory has less lowers the
soft limit instead (and refuses to start when that leaves nothing).
Promotion that still finds no block traps with a counted report
(`reserveExhaustions`): a provisioning failure, never hidden.

**Full collections**: never inside a scavenge's pause. A scavenge that
leaves old space past its soft limit sets `fullRequested` and keeps the
safepoint flag up when it releases the world; the next poll's slow path, or
the next scavenge request (upgraded), runs a full collection in a stop of
its own. Every module 1 operation that needs nothing young (collect,
compact, become, forward, reshape, snapshot) first runs a **promote-all**
scavenge in its own stop, through a hook module 1 calls
(`beforeOldSpaceOperation`), with the operation's roots or the stop's.

## Weak slots, ephemerons and formats (ADR 0009 sections 1 and 6, v0)

- **Format word**: the class table has a format word beside it
  (`ClassFormat`: named slots, weak, ephemeron), set by the loader from the
  kasm directive `class <Name> <Super> <instSize> [weak | ephemeron]` and
  saved in snapshots (version 2).
- **Weak**: the indexed slots (past the named ones) are not traced. The
  scavenge nils those that named a dead young object at its end; module 1's
  mark-sweep (and compaction's mark) nils those whose referent is unmarked.
- **Ephemeron**: slot 0 is the key. Module 1's mark defers an unfired
  ephemeron whose key is unmarked; ephemerons whose keys get marked are
  traced; when only ephemerons are left, all remaining ones are **fired**
  (header bit 48), queued in the finalization queue (a root) and traced, so
  key and value survive that collection. A fired ephemeron is strong: it is
  queued once.
- **Finalization**: after a stop whose collection fired ephemerons, the
  registered Semaphore (primitive 36 `finalizationSemaphore:`, rooted in
  module 3's pending-root table) is signalled through module 3's external
  queue. A Process takes each with primitive 37 `nextMourner` and sends it
  `mourn` (the tests' kasm does). Finalizers never run on a collector thread.
- **v0 rule**: the scavenge treats an ephemeron's slots as strong, so a
  young key's finalization waits for the first full collection.

## Verifiers (`Nursery/NurseryVerifier.swift`)

At every scavenge in checked builds (`config.verify`), through module 1's
`record` (trap, or count and keep):

| when | checks |
|---|---|
| before | remembered set: every old holder of a young object is marked for its nursery and in exactly one buffer; every buffered holder old, used and marked; no marker without a buffer. Every young body lies in its header's nursery, in eden or survivor-from. It counts the young objects reachable from the roots, the buffers and every old object, and records every weak slot naming a young object |
| after | copied objects = reachable young objects (each claimed once); no root or slot names a freed entry (no reference from old space to a dead young object); no reachable young entry was freed; every young body in its nursery's survivor-from, with this scavenge's tag and an age in 1 ..< N, and in that nursery's survivor log; edens empty; the remembered set again; weak slots nil exactly when their referent died; module 1's free-list verifier (one owner per entry, stashes included) |

Module 1's verifiers keep running at full collections and gained: a young
body must lie in the nursery region with a matching back reference; an old
header has no young-only bit; the finalization queue and the nil object are
valid roots; stashes in the free-list walk; weak slots and ephemerons in
the mark verifier.

Corruption tests: `theNurseryVerifierCatches` (a young object in the wrong
nursery, a marker with no buffer, an old holder not remembered, a survivor
out of its log), module 1's `theHeapVerifierCatches` (young outside the
nursery region, young-only bits in an old header), and the rule tests
below.

## Stress flags and test switches

| flag | effect |
|---|---|
| `tinyNurseries` (`--stress tinynursery`) | 64 KiB eden, 8 KiB survivor halves |
| `promoteAll` (`promoteall`) | every scavenge promotes everything |
| `scavengeAtEveryAllocation` (`scavenge`) | a scavenge before every young allocation |

Module 1's `collectAtEveryAllocation` sends young allocation through a full
collection too. Test switches (`NurseryTestSwitches`): `skipBarrierAt`,
`dropCarriedHolders`, `forgetPromotedHolders`, `sameClaimTag`,
`keepDeadWeakSlots`.

## Counters

`vm.nurseryCounters`: scavenges, promote-all scavenges, promoted, survived
and overflow objects and bytes, young bytes scavenged, remembered holders
and slots scanned, entries swept and freed, weak slots nil'ed, full
collections requested and run, verifier runs, scavenge time, young and
large allocations, barrier slow-path calls and young holders, stash refills.
`vm.scavengeLog`: per scavenge prep, copy wall, sweep wall, finish, verify
and work time, participants, the slowest participant (longest busy time)
with its roots and remembered split, the longest sweep, bytes and busy time
per participant, packets. Module 3's stop records gained a kind (scavenge,
full, other), so pause p50, p99 and max per kind come from the stops (time
to safepoint included). Module 1's counters gained `weakSlotsNiled` and
`ephemeronsQueued`; `reserveExhaustions` counts promotion refills that found
no block.

## Primitives

| # | selector | |
|--:|---|---|
| 35 | `scavenge` | a scavenge in a stop of its own |
| 36 | `finalizationSemaphore:` | a Semaphore, rooted in the pending table |
| 37 | `nextMourner` | the oldest queued ephemeron, or nil |

All fail outside a VM. (The experiments' `oldheap.kasm` used 37 for a
no-op timing hook; the fixture copy makes it a plain method.)

## Changes to modules 1 to 3

Module 1 (`ObjectMemory/`):

- `Header`: bits 48 (fired ephemeron), 52..56, 57..59 and 62..63 are used;
  accessors `isYoung`, `age`, `nurseryIndex`, `claimTag`, `youngIn(nursery:)`,
  `isFiredEphemeron`; `youngOnlyMask`, `youngNurseryMask`. Reserved now: 46
  and 49..51. `EncodingTests` and the reserved-bit corruptions of
  `VerifierTests` and `SnapshotTests` use bit 49 or 50 instead of 56.
- `ObjectMemoryConfig.reserveBytes`: blocks past `heapBytes` (the soft
  limit) for promotion only. `Pools` gained `blocksInUse`,
  `softLimitBlocks`, `reserveExhausted` and the registered stashes;
  `refillBlock(reserve:)` refuses a free block to a mutator at the soft
  limit; `allocateBody(reserve:)`; `rebuildBlockPool` recounts blocks in use.
- New `Generations.swift`: `EntryStash` (register, refill from the pool,
  trim), `bumpPromotion`/`promotionRefill`, `reserveNurseryRegion`,
  `ClassFormat` and the format table, `nilObject`, the finalization queue
  (its own allocation under the pool lock), `takeFinalizationSignal`, and
  the hook `beforeOldSpaceOperation` that collect, compact, become,
  forward, reshape and snapshot call first (promote-all).
- `initializeObject` factored out of `place` (shared with eden allocation).
- `mark`: weak slots, ephemerons, the finalization queue as a root;
  counters `weakSlotsNiled`, `ephemeronsQueued`. The sweep discards stashes.
- Verifiers: young bodies in the nursery region, no young-only bit in an
  old header, the queue and nil as roots, stashes in the free-list walk,
  weak and ephemeron rules in `verifyMarks`.
- Snapshot version 2: class formats, finalization queue, nil object;
  version 1 is refused; the fuzz seed was regenerated. The loader allows
  blocks up to `heapBytes + reserveBytes`.
- `RawArray`: `last`, `removeFirst`, `truncate`, `baseAddress`;
  `init(repeating:count:)` fills in one call (it appended one at a time).

Module 2 (`Interpreter/`, `Loader/`):

- `InterpreterState.young` (the worker's nursery); `Machine.allocate` and
  `allocateBytes` try eden first; `allocateSlow` dispatches to
  `allocateYoungSlow` or `allocateOld` (module 3's old path, renamed);
  `pauseCount` and `afterPause` are internal.
- Barrier sites: `store_ivar` in `Dispatch.swift`, `at:put:` and
  `globalAt:put:`, the Message and its Array in `doesNotUnderstand`.
- Primitives 35 to 37 go to `nurseryPrimitive`.
- The kasm `class` directive takes `weak` or `ephemeron`; the loader sets
  every class's format and the object memory's nil.
- `interpret` grew from 731 to 752 instructions; still one jump table.

Module 3 (`Workers/`, `Processes/`):

- `VMConfig.nursery`; `VM.init` installs the nurseries, `destroy` removes
  them. `VMState.nursery`, `VMState.finalization`.
- `SafepointState`: the parallel phase (`phaseOpen`, `phaseSeq`, `joined`,
  `done`, `parts`), the current `stopper` and the stop's `kind` (in
  `StopRecord`). `parkLocked` joins an open phase; `runParallelPhase` and
  `markStop` are new; `StopContext` carries the time to safepoint.
- `stopWorld` keeps the safepoint flag up while a full collection is due
  and signals the finalization Semaphore after a collection that fired
  ephemerons; `pollSlow` runs a due full collection after a park.
- The scheduler's stores of Processes and Semaphores go through
  `barrierStore(w, ...)`: `makeReadyLocked`, `signalLocked`,
  `finishLocked` and `unlinkLocked` take the worker.
- `VM.setGlobal` stores through the barrier on the host worker; `host` and
  `machine` are internal (module 4's host calls use them).
- `Worker.collectorNs` and `TurnStats.collectorNs`: a parked worker's
  time in a scavenge's parallel phase.
- `unregisterPending` is internal.
- `pollSlow`: the first budget check of a slice never preempts (see
  Deviations).
- `Headless.Options` gained `nurseryKB`, `survivorKB`, `age`,
  `nurseryStress`; `kajo run` gained `--nursery`, `--survivor`, `--age` and
  the stress words `tinynursery`, `promoteall`, `scavenge`; the run line
  reports the nursery (below).
- Tests: `Runtime` sizes the reserve from the nursery and loads
  `nursery.kasm`; `gcKeepsParkedProcessStacksAlive` counts scavenges with
  collections; `aTurnOverruns...` takes the main worker's scavenge work out
  of its CPU overrun; the random programs scavenge between each task's
  halves and run four more configurations.

## Deviations

- **Entry stashes instead of either option the brief offered** (see
  "Entry freeing"): the stash is its own young log, costs the allocation
  path one load and one store (as module 1's list pop does), touches only
  what was allocated since the last scavenge, and keeps module 1's
  one-owner rule checkable. A run log needed contiguous runs, which the
  module 1 run builder and become-forward do not keep.
- **The promotion reserve is twice the nurseries plus a third**, not equal
  to their sum: a scavenge that leaves old space past its soft limit may be
  followed by another before the full collection it requested runs, and a
  promote-all needs room for everything young while old space is already
  over; bodies of up to 8 KiB waste block tails. It is address space (the
  blocks are only touched when used). A VM whose object memory has a
  smaller `reserveBytes` lowers its soft limit instead.
- **A due full collection upgrades the next scavenge request** (the
  experiment did the same): the upgraded stop is a full collection's pause
  (promote-all plus mark-sweep), never a scavenge with a mark-sweep added.
- **Promote-all runs before every module 1 operation that needs nothing
  young**, not only collect and snapshot: compact, become (both), reshape
  too. A young object swapped by become or reshaped would otherwise break
  the remembered set or the nursery's ownership. It runs in the same stop
  as the operation (a promote-all and then the operation), through a hook.
- **The remembered marker is 16 bits per entry**, one bit per nursery, with
  one buffer per worker (module 7 splits the buffers per nursery).
- **One barrier slow path for every store, VM stores included, with a site
  tag**: the tag is a constant argument to the slow call, free on the fast
  path, and lets the mutation tests switch each site off.
- **The scavenge's weak pass runs at the stopper after the sweep** (weak
  objects are rare): a weak slot is nil'ed when its referent's entry was
  freed by this scavenge, which is exactly "a young object that died".
- **The main worker copies when it is parked in a scavenge.** The brief
  said it waits for the stop like every other worker; parked workers take
  part in the parallel phase, so the main worker does too. Its share is
  reported (`TurnStats.collectorNs`) and module 3's turn test takes it out
  of the CPU overrun. ADR 0008 (module 7) takes it off the pause.
- **Not every scavenge is parallel.** A scavenge with nothing young and
  nothing remembered is skipped (a promote-all right after a scavenge); one
  with under 64 KiB young and under one remembered task is the stopper's
  alone. Waking nine parked workers for a few objects cost more than the
  copy (and made a stop at every poll under ThreadSanitizer far slower).
  Every scavenge above that is shared by every parked worker, as the ADR
  says.
- **A slice's first budget check never preempts** (module 3's rule for
  `preemptEveryPoll`, now general). Found by the random programs under
  ThreadSanitizer: with a stop at every poll each stop (a promote-all and a
  mark-sweep on nine workers) outlasted the 5 ms slice, so a resumed
  Process was preempted at the very send it had been rewound to, again and
  again: 187 169 stops in 600 s without finishing a program that takes 321
  stops in debug. With the rule: 419 stops, 1.5 s.
- **The random programs changed**: each task scavenges between its halves
  (`nil scavenge`), since the programs allocate tens of KiB and would not
  otherwise scavenge even with tiny nurseries. Seeds give new programs, but
  the generator is still deterministic and the model unchanged.
- **The tiny-nursery random configurations use 24 KiB nurseries** (20 KiB
  eden), below the `tinyNurseries` flag's 80 KiB, for the same reason.
- **`kajo run` refuses a nursery with more than 14 background workers**
  (16 nurseries, 4 header bits), and `--nursery 0` runs without one.
- **The experiments' oldheap and fragment kernels needed two changes**:
  `ohBuilt` (primitive 37 there, a timing hook) is a plain method, and
  `replaceFrom:to:with:startingAt:` (primitive 38, arrayCopy, absent here)
  has a Smalltalk body the failing primitive falls back to.

## Tests

31 test functions in `Tests/KajoVMTests/Nursery/` (184 in the suite).

**Ported from generational-gc** (`GenerationalTests.swift`):
`youngSurvivorKeepsItsOopAndContents` (now: survives with age 1 in a
survivor space, then promoted at N = 2, oop and contents unchanged),
`oldHolderOfAYoungObjectIsRememberedAndTheYoungOneSurvives`,
`theVerifierCatchesAStoreThatSkipsTheBarrier`,
`aYoungObjectReachableOnlyFromAnotherNurseryIsPromotedOnce`,
`sharedYoungObjectsAreClaimedOnceByParallelScavengers`,
`deadYoungEntriesAreFreedAndReused`, `aParkedProcessStackIsScanned`,
`aFullCollectionWorksAfterPromotions`,
`schedulerStoresIntoOldObjectsAreBarriered`. The parked-count test was
module 3's. Where a test reasons about promotion on first survival it runs
with N = 1.

**Ported from concurrent-relocation Part 1** (`AgeTests.swift`):
`theAgeFieldPromotesAtNAndNotBefore`, `nOfOnePromotesOnFirstSurvival`,
`survivorOverflowPromotesEarly`, `anOldHolderOfASurvivorStaysRemembered`,
`aPromotedHolderOfASurvivorIsRemembered`, `aFullCollectionPromotesTheSurvivors`;
new for the claim tag: `theClaimTagAlternatesAndALoserReadsTheDecision`,
`survivorToFullPromotesAndPromoteAllIgnoresTheAge`,
`aSurvivorIsCopiedByTheNextScavenge`.

**New** (`WeakTests.swift`, `BarrierSiteTests.swift`,
`NurseryVerifierTests.swift`): weak slots nil'ed by a scavenge and by a
full collection, an old weak referent kept by a scavenge, the dangling
weak slot the verifier reports; an ephemeron whose key dies is queued once,
its value traced and the finalization Process run, and one whose key lives
is not queued; large objects allocated old; a snapshot after promote-all
has nothing young; snapshot version 2 keeps formats, the queue and nil, and
the loader refuses a young header and an unknown format bit; the barrier
sites switched off one by one; the nursery verifiers' corruption tests;
module 1's two new heap corruptions.

**Rules found by a failing test, each checked by breaking it (all in the
suite, parameterized `[false, true]` or by site)**:

| rule | test | switch | fails how |
|---|---|---|---|
| every barrier site that can matter | `aBarrierSiteSwitchedOff` (18 sites) | `skipBarrierAt` | the remembered-set verifier before the next scavenge, for the 10 sites in the table |
| a remembered holder is carried while it names a survivor | `anOldHolderOfASurvivorStaysRemembered` | `dropCarriedHolders` | the next scavenge's verifier: old holder not remembered |
| a promoted holder of a survivor is remembered | `aPromotedHolderOfASurvivorIsRemembered` | `forgetPromotedHolders` | the same |
| the claim tag alternates | `aSurvivorIsCopiedByTheNextScavenge` | `sameClaimTag` | the survivor looks claimed, is not copied; the verifier finds it lost |
| weak slots of dead young objects become nil | `withoutNilingTheVerifierReportsADanglingWeakSlot` | `keepDeadWeakSlots` | the after-verifier: a slot names a freed entry |

Tests that break a rule stop at the first scavenge whose verifier failed
(`checkedScavenge`): the scavenge after a missed barrier frees a reachable
entry, and a program that went on would crash on it (the first version of
the site test did, with SIGTRAP).

**Waiting**: everything concurrent (modules 5 to 7), `aFramePinnedObjectIsNotMoved`
(module 6), the 120 Hz scenarios and the device matrix (module 9).

### Randomized programs

Module 3's seven configurations now run with 512 KiB nurseries (N = 2;
the programs allocate tens of KiB, and a small nursery keeps the promotion
reserve, which every full collection walks, small), and module 4 adds `noNursery` (the oracle: module 3's behaviour),
`tinyNurseries` (24 KiB nurseries, one worker, verifiers on),
`promoteAll` (the same nurseries promoting everything, eight workers) and
`scavengeEveryAllocation` (eight workers). Every program scavenges between
each task's halves. Each answer must equal the Swift model's, which equals
the no-nursery oracle's; each configuration checks that its stress happened.

## Not done

- Everything concurrent: marking (5), relocation (6), young collection
  without stopping the world and the per-nursery remembered buffers (7).
  The main worker still copies in a scavenge.
- Nursery sizing from observed survival; per-worker sizes; the 16-worker
  limit of the 4-bit nursery index.
- Card marking (whole holders are rescanned: the survivors kernels spend a
  large share of every pause on remembered holders).
- Ephemerons in the scavenge (v0 treats them as strong) and the concurrent
  marker's ephemeron rule (5).
- A large-object space: large objects are ordinary old objects up to one
  block; nothing bigger exists yet.
- Device runs (module 9's app).
- The arrayCopy primitive the experiments' fragment kernel used (the
  fixture falls back to a Smalltalk loop).
- `VM.destroy` with ephemerons still queued just drops the queue.

## Unsafe surface

432 lines with `unsafe` in `Nursery/` (code lines, counted after a clean
build with no warning): Scavenge 228, NurseryState 64, YoungAllocation 64,
NurseryVerifier 27, NurseryHost 23, Finalization 14, Barrier 12, Claim 0,
NurseryConfig 0. Module 1's new `Generations.swift` has 66 (stashes, the
promotion bump, the finalization queue's own allocation), and its other
files went from 211 to 251 (the reserve, stashes and weak marking; 317
in `ObjectMemory/` in all). The surface
is the raw pointers to the per-worker and VM-wide nursery state, the
header word read and compare-and-swapped as `Atomic<UInt64>` in the table,
the remembered markers as `Atomic<UInt16>` over a zero-filled reservation,
the body copy, and the pthread calls of the packet pool. `NurseryAlloc`,
`ScavengeWorker`, `ScavengePhase`, `NurseryShared`, `Scavenger`,
`PacketPool`, `ScavengeTask` and module 1's `EntryStash` are `@unsafe`;
the host surface (`VM.scavenge`, `nurseryCounters`, `space(of:)`, ...) and
the claim rule (`ClaimCell`) are safe, so tests need none. A clean build
warned on 97 unmarked sites the incremental builds never reported.

## Hot-path check

`just arc-check` (2026-11-02, final code) adds `rememberSlow`,
`Scavenger.evacuate`, `drain`, `scanRemembered`, `sweepNursery`,
`exportPacket`, `takePacket`, `participateInScavenge` and
`ObjectMemory.promotionRefill` to modules 1 to 3's list (updated for the
signatures module 4 changed): zero `swift_retain`/`swift_release` in every
one; `interpret` 752 instructions, one indirect branch and one jump table.
The eden allocation is inlined into `Machine.allocate` (143 instructions,
no ARC; its only calls are the two slow paths). `rememberSlow` is 61
instructions; `evacuate` 209 (its calls: `promotionRefill`, `memcpy`, the
arrays' growth); `participateInScavenge` 1170 (the copy and drain loops
inlined).
