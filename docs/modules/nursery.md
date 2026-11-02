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

## Measurements

All on the M2 Max (8 P + 4 E cores), macOS 27, Swift 6.4, release builds,
2026-11-02 23:13 to 23:31, after `pkill -x yes` (none left). Load average
(1 min) 3 to 7, falling from a ThreadSanitizer run; Firefox, Warp and this
agent the busiest other processes at 3 to 9 percent of a core. Kernels
through `kajo run`.

### Barrier and allocator, interleaved against module 3

Module 3's `kajo` built from `a1ab495` in a worktree (`swift build -c
release --product kajo`), this module's from `.build/bench` (`swift build
-c release --product kajo --scratch-path .build/bench`), one worker,
default options (1 GiB heap, 5 ms slices, 4 MiB nurseries, N = 2), run
alternately with module 4 without a nursery (`--nursery 0`) as a third
column, five runs each, medians (min to max), ms:

| kernel | module 3 | module 4 | ratio | module 4, no nursery | what it measures |
|---|--:|--:|--:|--:|---|
| ivars | 2075.6 (2074.2 to 2078.8) | 1925.7 (1921.5 to 1928.6) | **0.928** | 1926.6 (1918.2 to 1928.2) | the barrier on SmallInteger stores (`store_ivar`, never young) |
| churn | 2109.4 (2103.9 to 2174.9) | 2050.4 (2040.1 to 2059.4) | **0.972** | 2090.0 (2082.7 to 2091.9) | eden allocation, nothing survives (244 scavenges) |
| alloc | 2495.7 (2487.8 to 2508.4) | 2697.7 (2686.6 to 2701.3) | 1.081 | 2421.0 (2409.3 to 2424.3) | allocation plus copying: trees survive (320 scavenges, 662 MB copied) |
| fib | 1688.3 (1686.0 to 1692.5) | 1653.2 (1645.6 to 1654.1) | 0.979 | 1646.3 | no stores, no allocation: code placement alone |

- **Barrier**: module 4 is 7 percent *faster* than module 3 on ivars, and
  equal with and without a nursery: the barrier's fast path (four
  instructions, one a reload) is below the code-placement effect, which
  moves fib by 2 percent in the same direction. The brief's bound (at most
  3 percent) holds; the experiment's 2 percent on this kernel is not
  visible here.
- **Allocator**: churn, all eden allocation and scavenges of dead objects,
  is 2.8 percent faster than module 1's bump in module 3 and 1.9 percent
  faster than module 4's own old path. alloc is 8 percent slower at 4 MiB
  because its depth-16 trees survive and are copied (twice at N = 2: 167
  MB into survivor spaces, 495 MB promoted, one full collection), as the
  experiment found (1.13x); at 16 MiB it takes 2427 ms (0.97x).

### Headless matrix

`matrix.sh` (below): the six kernels, 1 and 8 workers, nurseries 1, 4 and 16
MiB, N = 1 and 2, five runs per cell, `--slice-ms 0`, old space 64 MiB
(oldheap64 192, fragment 256, as the experiments). Medians of the five runs
(the pause columns are the median of each run's p50 and p99 and the max of
the maxima); "slowest" is the worker that parked last in the run with the
longest scavenge (-1: none had to, one worker); promoted MB/s over the run;
copy MB/s per participant is bytes copied over participants' busy time.
Every checksum is the experiments' published one.

| kernel | w | nursery KiB | N | ms | checksum | scavenges | p50 | p99 | max | slowest | promoted MB/s | survived MB | overflow MB | fulls | copy MB/s/participant | load |
|---|--:|--:|--:|--:|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| churn | 1 | 1024 | 1 | 2021.4 | 256000032000000 | 976 | 0.019 | 0.029 | 0.096 | -1 | 0 | 0.0 | 0.0 | 0 | 375 | 3.1 |
| churn | 1 | 1024 | 2 | 2020.8 | 256000032000000 | 976 | 0.019 | 0.027 | 0.097 | -1 | 0 | 0.0 | 0.0 | 0 | 416 | 3.0 |
| churn | 1 | 4096 | 1 | 2017.9 | 256000032000000 | 244 | 0.074 | 0.095 | 0.203 | -1 | 0 | 0.0 | 0.0 | 0 | 313 | 3.0 |
| churn | 1 | 4096 | 2 | 2018.7 | 256000032000000 | 244 | 0.074 | 0.096 | 0.112 | -1 | 0 | 0.0 | 0.0 | 0 | 273 | 2.8 |
| churn | 1 | 16384 | 1 | 2022.3 | 256000032000000 | 61 | 0.301 | 0.372 | 0.561 | -1 | 0 | 0.0 | 0.0 | 0 | 126 | 2.8 |
| churn | 1 | 16384 | 2 | 2023.7 | 256000032000000 | 61 | 0.303 | 0.396 | 0.502 | -1 | 0 | 0.0 | 0.0 | 0 | 100 | 2.7 |
| churn | 8 | 1024 | 1 | 287.5 | 32000032000000 | 123 | 0.196 | 0.264 | 0.332 | 8 | 0 | 0.0 | 0.0 | 0 | 288 | 2.7 |
| churn | 8 | 1024 | 2 | 289.0 | 32000032000000 | 124 | 0.198 | 0.275 | 0.295 | 3 | 0 | 0.1 | 0.0 | 0 | 260 | 2.8 |
| churn | 8 | 4096 | 1 | 273.4 | 32000032000000 | 30 | 0.348 | 0.531 | 0.598 | -1 | 0 | 0.0 | 0.0 | 0 | 138 | 2.8 |
| churn | 8 | 4096 | 2 | 276.9 | 32000032000000 | 31 | 0.347 | 0.528 | 0.544 | 6 | 0 | 0.0 | 0.0 | 0 | 100 | 2.8 |
| churn | 8 | 16384 | 1 | 275.2 | 32000032000000 | 7 | 0.984 | 1.762 | 2.389 | 2 | 0 | 0.0 | 0.0 | 0 | 95 | 3.5 |
| churn | 8 | 16384 | 2 | 274.8 | 32000032000000 | 7 | 0.995 | 1.667 | 1.750 | 2 | 0 | 0.0 | 0.0 | 0 | 80 | 3.5 |
| survivors5 | 1 | 1024 | 1 | 1311.1 | 6399993600000 | 497 | 0.080 | 0.130 | 0.210 | -1 | 20 | 0.0 | 0.0 | 0 | 856 | 3.5 |
| survivors5 | 1 | 1024 | 2 | 1319.4 | 6399993600000 | 497 | 0.096 | 0.169 | 0.300 | -1 | 20 | 21.3 | 4.8 | 0 | 1235 | 3.4 |
| survivors5 | 1 | 4096 | 1 | 1296.9 | 6399993600000 | 124 | 0.205 | 0.356 | 0.660 | -1 | 20 | 0.0 | 0.0 | 0 | 1624 | 3.3 |
| survivors5 | 1 | 4096 | 2 | 1303.0 | 6399993600000 | 124 | 0.269 | 0.456 | 0.693 | -1 | 20 | 24.4 | 1.7 | 0 | 2089 | 2.9 |
| survivors5 | 1 | 16384 | 1 | 1300.6 | 6399993600000 | 31 | 0.855 | 1.371 | 1.751 | -1 | 20 | 0.0 | 0.0 | 0 | 1494 | 2.9 |
| survivors5 | 1 | 16384 | 2 | 1302.3 | 6399993600000 | 31 | 1.232 | 2.129 | 2.428 | -1 | 19 | 26.1 | 0.0 | 0 | 1756 | 2.9 |
| survivors5 | 8 | 1024 | 1 | 197.0 | 799993600000 | 64 | 0.407 | 0.653 | 0.688 | 7 | 141 | 0.0 | 0.0 | 0 | 359 | 3.7 |
| survivors5 | 8 | 1024 | 2 | 201.4 | 799993600000 | 65 | 0.454 | 0.583 | 0.696 | 4 | 136 | 21.0 | 6.7 | 0 | 501 | 3.7 |
| survivors5 | 8 | 4096 | 1 | 185.6 | 799993600000 | 16 | 0.754 | 1.058 | 1.153 | 5 | 149 | 0.0 | 0.0 | 0 | 626 | 3.7 |
| survivors5 | 8 | 4096 | 2 | 189.4 | 799993600000 | 16 | 0.966 | 1.225 | 3.830 | -1 | 140 | 24.2 | 2.7 | 0 | 783 | 4.0 |
| survivors5 | 8 | 16384 | 1 | 183.8 | 799993600000 | 3 | 2.627 | 2.815 | 3.991 | 7 | 127 | 0.0 | 0.0 | 0 | 662 | 4.0 |
| survivors5 | 8 | 16384 | 2 | 187.6 | 799993600000 | 3 | 3.500 | 4.197 | 4.389 | 8 | 76 | 23.1 | 0.0 | 0 | 716 | 4.0 |
| survivors30 | 1 | 1024 | 1 | 1870.8 | 38399861600000 | 540 | 0.152 | 0.198 | 0.315 | -1 | 83 | 0.0 | 0.0 | 4 | 2148 | 3.9 |
| survivors30 | 1 | 1024 | 2 | 1905.3 | 38399861600000 | 540 | 0.208 | 0.267 | 0.480 | -1 | 81 | 70.5 | 84.0 | 4 | 2251 | 3.7 |
| survivors30 | 1 | 4096 | 1 | 1857.3 | 38399861600000 | 136 | 0.485 | 0.728 | 1.062 | -1 | 83 | 0.0 | 0.0 | 4 | 2743 | 3.5 |
| survivors30 | 1 | 4096 | 2 | 1887.7 | 38399861600000 | 136 | 0.695 | 0.894 | 1.382 | -1 | 81 | 70.3 | 83.4 | 4 | 2778 | 3.1 |
| survivors30 | 1 | 16384 | 1 | 1885.8 | 38399861600000 | 35 | 2.290 | 3.375 | 3.802 | -1 | 80 | 0.0 | 0.0 | 4 | 2388 | 2.8 |
| survivors30 | 1 | 16384 | 2 | 1906.0 | 38399861600000 | 35 | 2.999 | 4.403 | 5.212 | -1 | 78 | 69.2 | 82.2 | 4 | 2577 | 2.9 |
| survivors30 | 8 | 1024 | 1 | 317.9 | 4799861600000 | 84 | 0.536 | 0.689 | 0.751 | 7 | 494 | 0.0 | 0.0 | 4 | 921 | 3.2 |
| survivors30 | 8 | 1024 | 2 | 315.7 | 4799861600000 | 82 | 0.638 | 0.828 | 0.848 | 4 | 495 | 76.4 | 80.9 | 4 | 1033 | 3.2 |
| survivors30 | 8 | 4096 | 1 | 297.0 | 4799861600000 | 20 | 1.319 | 1.549 | 1.678 | 7 | 511 | 0.0 | 0.0 | 4 | 1215 | 3.2 |
| survivors30 | 8 | 4096 | 2 | 307.8 | 4799861600000 | 20 | 1.711 | 2.430 | 2.521 | 4 | 478 | 72.1 | 79.6 | 4 | 1245 | 3.6 |
| survivors30 | 8 | 16384 | 1 | 313.5 | 4799861600000 | 6 | 5.302 | 5.956 | 6.051 | 4 | 467 | 0.0 | 0.0 | 4 | 1128 | 3.6 |
| survivors30 | 8 | 16384 | 2 | 299.9 | 4799861600000 | 5 | 7.327 | 7.399 | 7.513 | 7 | 433 | 67.1 | 79.5 | 2 | 1124 | 3.6 |
| alloc | 1 | 1024 | 1 | 2927.2 | 41950911 | 1295 | 0.337 | 0.406 | 0.673 | -1 | 344 | 0.0 | 0.0 | 30 | 2381 | 3.3 |
| alloc | 1 | 1024 | 2 | 3009.1 | 41950911 | 1295 | 0.396 | 0.471 | 0.589 | -1 | 334 | 167.8 | 838.9 | 30 | 2372 | 3.1 |
| alloc | 1 | 4096 | 1 | 2942.1 | 41950911 | 335 | 1.347 | 1.577 | 1.959 | -1 | 342 | 0.0 | 0.0 | 30 | 2370 | 2.7 |
| alloc | 1 | 4096 | 2 | 2873.9 | 41950911 | 331 | 1.299 | 1.448 | 1.585 | -1 | 273 | 167.8 | 779.5 | 22 | 2360 | 2.6 |
| alloc | 1 | 16384 | 1 | 2472.4 | 41950911 | 83 | 1.635 | 1.859 | 2.051 | -1 | 102 | 0.0 | 0.0 | 6 | 2284 | 2.5 |
| alloc | 1 | 16384 | 2 | 2447.0 | 41950911 | 81 | 1.648 | 1.870 | 2.339 | -1 | 29 | 167.8 | 68.9 | 2 | 2276 | 2.5 |
| alloc | 8 | 1024 | 1 | 833.6 | 42008248 | 227 | 0.836 | 1.199 | 1.335 | 8 | 1208 | 0.0 | 0.0 | 38 | 1366 | 3.1 |
| alloc | 8 | 1024 | 2 | 881.2 | 42008248 | 236 | 0.922 | 1.250 | 1.343 | 2 | 1143 | 205.7 | 802.1 | 38 | 1322 | 3.1 |
| alloc | 8 | 4096 | 1 | 747.7 | 42008248 | 63 | 3.184 | 3.904 | 4.386 | 3 | 1320 | 0.0 | 0.0 | 32 | 1224 | 3.6 |
| alloc | 8 | 4096 | 2 | 595.8 | 42008248 | 51 | 2.405 | 3.992 | 4.596 | 8 | 913 | 167.7 | 476.6 | 16 | 1207 | 3.9 |
| alloc | 8 | 16384 | 1 | 472.1 | 42008248 | 15 | 3.946 | 4.890 | 4.965 | 7 | 512 | 0.0 | 0.0 | 8 | 1160 | 3.9 |
| alloc | 8 | 16384 | 2 | 338.1 | 42008248 | 10 | 3.386 | 4.248 | 4.655 | 7 | 56 | 158.6 | 17.6 | 0 | 1146 | 4.7 |
| oldheap64 | 1 | 1024 | 1 | 2376.6 | 134190197274785 | 736 | 0.057 | 0.175 | 0.242 | -1 | 82 | 0.0 | 0.0 | 0 | 4888 | 4.4 |
| oldheap64 | 1 | 1024 | 2 | 2377.2 | 134190197274785 | 736 | 0.077 | 0.189 | 0.206 | -1 | 82 | 96.4 | 98.6 | 0 | 5411 | 4.0 |
| oldheap64 | 1 | 4096 | 1 | 2361.4 | 134190197274785 | 184 | 0.226 | 0.658 | 0.702 | -1 | 83 | 0.0 | 0.0 | 0 | 4934 | 3.8 |
| oldheap64 | 1 | 4096 | 2 | 2384.6 | 134190197274785 | 184 | 0.306 | 0.750 | 0.795 | -1 | 82 | 96.5 | 98.6 | 0 | 5446 | 3.6 |
| oldheap64 | 1 | 16384 | 1 | 2375.1 | 134190197274785 | 46 | 0.958 | 2.706 | 2.766 | -1 | 82 | 0.0 | 0.0 | 0 | 4862 | 3.4 |
| oldheap64 | 1 | 16384 | 2 | 2422.5 | 134190197274785 | 46 | 1.294 | 3.071 | 3.104 | -1 | 80 | 96.5 | 98.6 | 0 | 5284 | 3.2 |
| oldheap64 | 8 | 1024 | 1 | 350.6 | 18609257457078 | 95 | 0.339 | 0.980 | 1.022 | 2 | 556 | 0.0 | 0.0 | 0 | 1768 | 3.1 |
| oldheap64 | 8 | 1024 | 2 | 356.7 | 18609257457078 | 95 | 0.399 | 0.983 | 1.059 | 8 | 544 | 89.4 | 105.5 | 0 | 2548 | 3.2 |
| oldheap64 | 8 | 4096 | 1 | 333.6 | 18609257457078 | 23 | 0.847 | 2.464 | 2.509 | 4 | 576 | 0.0 | 0.0 | 0 | 1720 | 3.2 |
| oldheap64 | 8 | 4096 | 2 | 340.4 | 18609257457078 | 23 | 0.984 | 2.391 | 2.566 | 4 | 552 | 94.0 | 98.2 | 0 | 2370 | 3.6 |
| oldheap64 | 8 | 16384 | 1 | 326.6 | 18609257457078 | 5 | 2.719 | 5.801 | 5.987 | 4 | 511 | 0.0 | 0.0 | 0 | 1807 | 3.6 |
| oldheap64 | 8 | 16384 | 2 | 329.6 | 18609257457078 | 5 | 3.040 | 5.297 | 5.679 | 8 | 438 | 82.2 | 84.5 | 0 | 2426 | 3.6 |
| fragment | 1 | 1024 | 1 | 2962.1 | 2212269504696 | 549 | 0.107 | 0.163 | 0.371 | -1 | 81 | 0.0 | 0.0 | 0 | 4489 | 3.4 |
| fragment | 1 | 1024 | 2 | 3013.7 | 2212269504696 | 549 | 0.132 | 0.215 | 0.354 | -1 | 80 | 71.9 | 167.9 | 0 | 4596 | 3.5 |
| fragment | 1 | 4096 | 1 | 2951.6 | 2212269504696 | 137 | 0.445 | 0.698 | 0.790 | -1 | 81 | 0.0 | 0.0 | 0 | 4261 | 3.3 |
| fragment | 1 | 4096 | 2 | 2978.1 | 2212269504696 | 137 | 0.545 | 0.817 | 0.921 | -1 | 80 | 71.8 | 167.6 | 0 | 4485 | 3.9 |
| fragment | 1 | 16384 | 1 | 2917.7 | 2212269504696 | 34 | 1.243 | 1.587 | 1.877 | -1 | 48 | 0.0 | 0.0 | 0 | 3894 | 3.9 |
| fragment | 1 | 16384 | 2 | 2901.1 | 2212269504696 | 34 | 1.189 | 1.614 | 2.288 | -1 | 24 | 71.3 | 67.6 | 0 | 4314 | 3.5 |
| fragment | 8 | 1024 | 1 | 399.7 | 329790469548 | 70 | 0.546 | 0.691 | 0.737 | 3 | 600 | 0.0 | 0.0 | 0 | 1381 | 3.3 |
| fragment | 8 | 1024 | 2 | 406.2 | 329790469548 | 70 | 0.626 | 0.832 | 0.844 | 6 | 587 | 73.4 | 166.4 | 0 | 1545 | 3.7 |
| fragment | 8 | 4096 | 1 | 389.6 | 329790469548 | 17 | 1.754 | 2.005 | 2.033 | 5 | 603 | 0.0 | 0.0 | 0 | 1270 | 3.7 |
| fragment | 8 | 4096 | 2 | 393.6 | 329790469548 | 17 | 2.179 | 2.450 | 2.847 | 8 | 588 | 71.3 | 164.3 | 0 | 1335 | 4.0 |
| fragment | 8 | 16384 | 1 | 372.9 | 329790469548 | 4 | 3.815 | 3.887 | 4.095 | 1 | 350 | 0.0 | 0.0 | 0 | 1340 | 4.0 |
| fragment | 8 | 16384 | 2 | 375.7 | 329790469548 | 4 | 4.455 | 5.352 | 6.015 | 4 | 176 | 67.1 | 63.6 | 0 | 1251 | 4.0 |


Against the experiments:

- **churn at 8 workers**: p99 0.26 ms at 1 MiB, **0.53 ms at 4 MiB**
  (expected under 0.4; the experiment had 0.32), 1.67 at 16 MiB. Nothing
  is copied: the pause is the time to safepoint (0.09 ms p50) and the entry
  sweep, which **reads every entry allocated since the last scavenge**: 0.073
  ms of a 0.074 ms pause on one worker (131 000 entries per 4 MiB nursery),
  0.19 ms p50 of 0.35 on eight, where eight sweeps share the memory
  bandwidth. The experiment's chunk bitmaps swept 64 entries per word read
  (0.019 ms at 8 workers). A finding against the stash design (Deviations):
  the bitmap would win back about 0.17 ms per churn scavenge at 8 workers,
  behind the same module boundary.
- **survivors30 at 4 MiB, 8 workers**: p99 1.55 ms at N = 1 and 2.43 at
  N = 2 (expected near 2; the experiment 2.26 at N = 1, 4.86 at N = 2 in
  concurrent-relocation): close.
- **alloc at 4 MiB, 8 workers**: N = 1 promotes 1320 MB/s, N = 2 913 MB/s
  (477 MB of it overflow) and 16 full collections against 32; at 16 MiB
  N = 2 promotes 56 MB/s. Most trees promote at N = 1 and far fewer at
  N = 2, and survivor-space size, not N, is the lever (ADR 0007).
- **Copy rate per participant** halves from one participant to eight
  (alloc 2.3 GB/s to 1.2; oldheap64 4.9 to 1.8), as ADR 0005 recorded.
- **Survivor overflow** dominates promotion at N = 2 in the survivor
  kernels at 1 and 4 MiB (survivors30: 80 MB overflow against 70 MB
  survived), as in concurrent-relocation.
- **Full collections**: survivors30 needs 4 (64 MiB old space), alloc 16 to
  38 at 1 and 4 MiB and 0 at 16 MiB with N = 2; oldheap64 and fragment
  none.

### Randomized programs

- In the suite: 100 seeds per configuration, eleven configurations (10, and
  2 under `stopEveryPoll` and `scavengeEveryAllocation`, under
  ThreadSanitizer). No failure.
- `just soak` (1000 seeds per configuration): seeds 1 to 1000, all eleven,
  no failure, 25 s. `just soak 2000 1001`: seeds 1001 to 3000, no failure,
  49 s.
- No seed failed. The generator found one bug before any seed was recorded
  (the stop-at-every-poll livelock under ThreadSanitizer, in Deviations);
  the configuration under ThreadSanitizer is its regression test.

### Idle

`idleWorkersCostNothing`: 0 ns of CPU on every one of ten workers and 0
condition-variable returns, in debug, under load and under
ThreadSanitizer. No thread was added and `grep -rn "timedwait\|asyncAfter"
Sources/KajoVM` still finds only the Delay primitive.

### Gates (final code)

`swift test`: 184 tests green (60 s). Under load (12 `yes`, load average
44): green. `swift test --sanitize=thread`: green, no ThreadSanitizer
report (285 s). `just test-release`, `just golden` (arith 2568, fib 1659,
sends 2546, alloc 2694, ivars 1923, walk 3900 ms, all ok), `just
ios-check` clean, `just arc-check` zero retain and release, one jump
table; a clean build has no warning; `just fuzz snapshot 20` (191 452
inputs, libFuzzer, no crash) on the regenerated version 2 seed.

### Commands

`git worktree add $SCRATCH/m3 a1ab495 && (cd $SCRATCH/m3 && swift build -c
release --product kajo)`; `swift build -c release --product kajo
--scratch-path .build/bench`; then, with no `yes` running:

```zsh
#!/bin/zsh
# Interleaved A/B: module 3 (a1ab495) against module 4, five runs each.
K=/Users/katis/code/kajo/Tests/KajoVMTests/Fixtures/kernels
M3=$SCRATCH/m3/.build/release/kajo
M4=/Users/katis/code/kajo/.build/bench/release/kajo
for kernel in ${=KERNELS:-ivars alloc churn}; do
  files=($K/prelude.kasm $K/lib.kasm $K/$kernel.kasm)
  for r in 1 2 3 4 5; do
    a=$($M3 run $files --workers 1 | tr ' ' '\n' | grep -E '^(ms|checksum)=' | tr '\n' ' ')
    b=$($M4 run $files --workers 1 | tr ' ' '\n' | grep -E '^(ms|checksum|scavenges)=' | tr '\n' ' ')
    c=$($M4 run $files --workers 1 --nursery 0 | tr ' ' '\n' | grep -E '^(ms|checksum)=' | tr '\n' ' ')
    echo "$kernel run=$r m3: $a | m4: $b | m4-nonursery: $c | load=$(sysctl -n vm.loadavg)"
  done
done
```

```zsh
#!/bin/zsh
# The headless matrix (docs/modules/nursery.md "Measurements"): module 4's
# kajo, five runs per cell, one key=value line each.
K=/Users/katis/code/kajo/Tests/KajoVMTests/Fixtures/kernels
M4=/Users/katis/code/kajo/.build/bench/release/kajo
RUNS=${RUNS:-5}
for kernel in ${=KERNELS:-churn survivors5 survivors30 alloc oldheap64 fragment}; do
  case $kernel in
    churn) files=($K/churn.kasm); heap=64 ;;
    survivors5) files=($K/survivors.kasm $K/survivors5.kasm); heap=64 ;;
    survivors30) files=($K/survivors.kasm $K/survivors30.kasm); heap=64 ;;
    alloc) files=($K/alloc.kasm); heap=64 ;;
    oldheap64) files=($K/oldheap.kasm $K/oldheap64.kasm); heap=192 ;;
    fragment) files=($K/fragment.kasm $K/fragmentIters.kasm); heap=256 ;;
  esac
  for w in 1 8; do for nur in 1024 4096 16384; do for age in 1 2; do for r in $(seq $RUNS); do
    line=$($M4 run $K/prelude.kasm $K/lib.kasm $files --workers $w --heap $heap --nursery $nur --age $age --slice-ms 0 2>&1)
    echo "kernel=$kernel workers=$w nursery=$nur age=$age run=$r load=$(sysctl -n vm.loadavg | awk '{print $2}') $line"
  done; done; done; done
done
```

The table is the medians of the five lines per cell (a small Python
aggregation of the key=value lines). The churn sweep figures come from
three more runs of `kajo run prelude lib churn --workers 1|8 --heap 64
--slice-ms 0` with the report's `sweepP50ms` and `ttspP50ms`.

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
  module 1 run builder and become-forward do not keep. Measured cost: the
  sweep reads each young entry, about 0.07 ms per 4 MiB nursery of
  24-byte objects, which is nearly all of a churn scavenge and makes churn's
  8-worker p99 0.53 ms against the brief's 0.4 (the experiment's bitmaps:
  0.32). A finding, not fixed here.
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
- Chunk bitmaps for the entry sweep: the stash sweep reads every young
  entry and is most of a churn scavenge's pause (Measurements); the
  experiment's bitmaps swept 64 entries per word. Behind the module
  boundary (`sweepNursery`, `EntryStash`).
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
