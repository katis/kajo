# Review 3 (mechanical sympathy, architecture, reuse): collectors at 821f20f

Area: `Sources/KajoVM/Marking/`, `Relocation/`, `Workers/`, `Processes/`,
read whole. Read as context: `ObjectMemory/OldMap.swift`, the entry and
slot accessors of `ObjectMemory.swift`, `YoungCollection/Rounds.swift`,
`Collect.swift` 120 to 780, `Owner.swift`, the trigger in
`LargeObjects.swift`, and the module docs named under "Read". Nothing was
built or run. Every number below is quoted from a doc or is an estimate,
and says which.

## The findings, in the order I would do them

| # | id | one line | expected gain |
|--:|---|---|---|
| 1 | collectors.M1 | Every parker broadcasts one condition that every waiter sleeps on: O(N²) wakeups per stop | time to safepoint at 8 workers (86 µs measured against 0.7 at 1) down by half or more, for every stop kind; guess until the counter is read |
| 2 | collectors.M2 | A broadcast per evacuated block wakes every stalled worker, which needs 60 to 180 blocks | thousands of futile wakeups per waited-on cycle gone; the relocator stops paying a syscall per block while workers wait on it |
| 3 | collectors.M3 | The mark loop takes two dependent misses per object and issues them one at a time | up to the table's 1.8 to 2.0 times on the marker (ADR 0003's ratio) on heaps past the cache; the final mark's in-stop tracing with it; experiment first |
| 4 | collectors.M4 | The sweep reads the entry table for every live entry only to set a block-live byte the marker could have set | the sweep's cost follows the dead entries, not the snapshot; a sweep stop's 4096 words go further |
| 5 | collectors.A1 | The trigger's inputs are kept three times (two samplers, two old-entry estimates, a third caller with none) | one place to change a rule; one drift already: old allocations count in one sampler only |
| 6 | collectors.R1 | Module 6's copy protocol is written twice (the relocator, the young collector) | one implementation under the relocation model |
| 7 | collectors.R2 | "Walk a range of bodies by back reference" is written four times | one walker; two of the four already differ in their filters |
| 8 | collectors.A2 | Which words are a worker's and a Process's roots is known in three places | a new oop register is one edit, not three; no Swift array of every stack word per stop |
| 9 | collectors.M5 | `copySlots` re-decides the SATB rule per slot (6 to 8 loop-invariant loads) and is a second copy of `satbRecord` | array copies while a cycle marks; small |
| 10 | collectors.M6 | The stop log is a hand-kept ring of 65 536 records (5.8 MB) that ignores `logCapacity` | 5.4 MB of dirty memory in an app that runs for days; one ring type |
| 11 | collectors.A3 | Bit 0 of the attention word has three reasons kept by convention; the full-collection request is written from four sites in three modules | a fourth reason cannot be cleared by the next stop's release |
| 12 | collectors.M7 | Each Delay is its own GCD timer on the default-QoS global queue | Delay lateness under load, which the tests have already met; measure first |
| 13 | collectors.R3 | The marker's driver exists twice (thread loop, manual entry points); `thread_info` is wrapped four times | small |

Counts: 7 mechanical, 3 architecture, 3 reuse.

---

## collectors.M1: the park path wakes every waiter at every park

**Where**: `Sources/KajoVM/Workers/Safepoint.swift:49` (`leaveVM`), `:76-80`
and `:95-99` (`parkLocked`), `:185-188` and `:242` (`stopWorld`), `:271`
(`runParallelPhase`). The same condition is broadcast from
`YoungCollection/Rounds.swift:157`, `:303`, `:386`, `Collect.swift:100`,
`:269`, `Marking/RootScans.swift:168`, `Relocation/Epoch.swift:159`.

**What is there now**: one mutex and one condition (`safepointCond`) carry
the whole protocol. A parker does

```swift
unsafe sp.pointee.parked += 1
...
unsafe pthread_cond_broadcast(vm.pointee.safepointCond)
...
while unsafe sp.pointee.epoch == epoch { ... pthread_cond_wait(safepointCond, safepointLock) }
```

and the stopper waits on the same condition for `parked + 1 == active`.
`leaveVM` broadcasts at every leave, stop or no stop. A scavenge's
participants broadcast once each when they finish (`done += 1`).

**The cost**: with P workers to park, the stopper is woken P times and
goes back to sleep P - 1 times, and parker i is woken by each of the P - i
parks after its own: P(P - 1)/2 wakeups that find the epoch unchanged. At
8 workers that is 8 + 28 thread wakeups, each a kernel wake and a mutex
acquisition, where one is needed. Every woken thread queues on the mutex
the next parker needs to count itself. `docs/modules/symbol-interning.md`
measured the time to safepoint per stop at 0.7, 3.9, 14 and 86 µs for 1,
2, 4 and 8 workers. The workers poll at every send, so nearly none of the
86 µs is reaching a poll; it is eight threads passing one mutex with a
wake storm on it. That module removed its stop. Every other stop kind
still pays: the storm's final mark at 8 workers is 0.106 ms p50
(`concurrent-marking.md`), which is of this size; the record's
`finalTtspNs` says how much of it is the park. Under `young=stw` a
scavenge pays it twice (parks, then `done`).

**The proposal**, in two steps.

1. In `parkLocked`, broadcast only when the count is complete
   (`parked + 1 >= active`); in the parallel phase, only when
   `done >= joined - 1`. No other waiter's condition reads `parked` or
   `done` (I listed them: `enterVM` waits for `!requested`; the
   `waitServicing` conditions are `progress`, `done[k]`, `need`,
   `ycActive && !requested`, a claimed root scan, `otherRunnersInside`).
   The stopper is then woken once, and parked workers once per stop
   instead of once per later park. One line each.
2. A condition of the stopper's own (`stopperCond`, signalled, not
   broadcast, by the completing park, by `leaveVM` when a stop is
   requested, and by the last `done`), so parked workers are woken only by
   the release. `leaveVM` keeps a broadcast of `safepointCond` only for
   the save's `otherRunnersInside` wait, or that wait gets the signal too.

**Bound first**: two counters under the mutex. Returns from the wait at
`:99` that find the epoch unchanged and no phase to join; returns from the
wait at `:187` that find `parked + 1 < active`. Print both per stop on the
run line. If they read near P²/2 and P at 8 workers, build step 1 and
re-read `ttsp mean µs`. A ready workload: `alloc` at 8 workers under
`--young stw` (a stop per scavenge), or `--stress stop`.

**Measure after**: time to safepoint p50 and p99 by stop kind at 1, 2, 4,
8 workers (`stopsByKind`), `parkNs`, `safepointContended`; in the shells'
matrix the main thread's stopped ms per 10 s on the storm rows.

**Risk and size**: step 1 is small; step 2 small to medium. The invariant
is "every wait inside the VM is a place a stop must reach" (AGENTS.md): the
request's broadcast at `:185` stays as it is. Guards: the stop verifier's
`wakeups` check, `backToBackStops...` and the `countReleasedAsParked`
variant, the young-collection model's `waits` and `wakes` steps (the model
does not model which condition; say so in the commit). Core tier.

**Confidence**: read for the code and the count of wakeups; the share of
the 86 µs is inferred (the mini has fewer performance cores than 8
workers plus the collector threads, which is part of it).

---

## collectors.M2: one broadcast per evacuated block for stalled workers that need a nursery's worth

**Where**: `Relocation/Epoch.swift:153-161` (`tryFreePending`),
`Relocation/Relocator.swift:298-303` (called after every block),
`Marking/Sweep.swift:82` (after every 64 words),
`Workers/Safepoint.swift:241-242` (every stop's release),
`Marking/Pacing.swift:129-185` (the waiter's loop).

**What is there now**:

```swift
if !atPause && freed > 0 {
    unsafe pthread_mutex_lock(vm.pointee.safepointLock)
    unsafe vm.pointee.safepoint.pointee.progress &+= 1
    unsafe pthread_cond_broadcast(vm.pointee.safepointCond)
    unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
}
```

The relocator calls it after each evacuated block. A stalled worker wakes
at every change of `progress`, unlocks, asks `available()` (the pool
lock), and if the answer is still no takes the safepoint mutex twice more
and waits again (`epochQuiesce`, then `epochWake`'s two seq_cst stores).

**The cost**: a stall for promotion needs `promotionNeedBlocks`
(`Collect.swift:110-116`): the young bytes over 24 KiB usable per block,
plus one, so about 60 blocks for a 1.5 MiB eden half and about 180 for a
full 4 MiB nursery. The relocation
table in `relocation.md` has 4467 to 5346 blocks evacuated per cycle and
99.8 percent freed by epoch, a few at a time. So a waited-on cycle
broadcasts up to several thousand times, and each broadcast wakes every
stalled worker (up to 7) plus every other `waitServicing` waiter, for a
question whose answer changes once per 60 to 180 blocks. The relocator
pays a mutex and a wake syscall per block on the pass the workers are
waiting for (5 ms of CPU for the whole default pass in that table: a
syscall per block is of the same order). With no worker stalled the
relocator still takes the safepoint mutex per freed batch.

**The proposal**: (a) an atomic count of stalled workers beside
`progress`; `tryFreePending` bumps and broadcasts only when it is nonzero.
(b) Coalesce: the relocator accumulates blocks freed since its last bump
and bumps when the sum passes a threshold (32 blocks, or the smallest need
a stalled worker registered) and at every poll and at the pass's end. The
stop release keeps its bump (it is one per stop). The wait's rule is
unchanged: it still ends only by progress or by the phase going idle.

**Bound first**: add `wakes` to `StallRecord` (iterations of the loop at
`Pacing.swift:129`) and count broadcasts in `tryFreePending`. Run the
slowed ring (`--marker-slowdown 4`, the stalls doc's row) and read wakes
per stall and broadcasts per cycle. If wakes per stall is under ten, drop
this finding.

**Measure after**: the same two counters; `relocCpuNs` and `relocWallNs`
of waited-on cycles in `cycleRecs`; the slowed ring's throughput.

**Risk and size**: small. The invariant is the stalls doc's transition
table ("blocks freed outside a stop ... bumps `progress` and broadcasts"):
a coalesced bump must still come before the relocator can go idle, or a
stalled worker sleeps with blocks free. The hand-run broken variants in
that doc (no bump at release, no bump at all) are the tests; add one for
"the last partial batch is bumped at the pass's end". Core tier.

**Confidence**: read for the code path; the number of wakes per stall is
inferred from the relocation table, not measured.

---

## collectors.M3: the mark loop issues its two dependent misses one object at a time

**Where**: `Marking/Marker.swift:16-23` (`greyIfCandidate`), `:50-92`
(`traceObject`), `:140-144` (`drainStack`), `:241-274` (`markSome`);
`ObjectMemory/Generations.swift:413` (`classFormat`);
`ObjectMemory/RawArray.swift:27-39`.

**What is there now**: a depth-first stack in `MarkerState`. Per popped
object: `headerWord(o)` and `stateWord(o)` from the entry table (one
line), then every slot from the body the state word leads to. Per slot
that is a reference: one bit of the snapshot map and one mark byte, then a
push. The object just pushed is the next popped, so its entry is first
read when it is needed.

```swift
let h = om.headerWord(o)
let s = om.stateWord(o)
...
while i < n {
    unsafe greyIfCandidate(mk, om, m, om.loadAtomic(bodyOffset: s, i))
```

**The cost**: `experiments/entry-locality/RESULTS.md` ("Mark rate") says
it: "a table mark is two dependent misses per object", 117 to 141 MB/s
against 211 to 271 direct, on both machines. `MarkingConfig.finalMarkWork`
is sized from the same fact: 16 384 units "is about a millisecond on the
iPhone's efficiency cores", 61 ns a unit, one or two misses. The loop
never has two objects' misses outstanding at once, although the stack
holds the addresses of the next ones. Smaller, per object, all L1 hits:
the stack's count, capacity and base are loaded and stored through
`m.pointee` at every push and pop (the atomic stores in between may alias
them, so they do not stay in registers); `classFormat` is three dependent
loads and a bounds check (`shared → gc → classFormats` base and count),
where the scavenger hoists the base once (`Nursery/Scavenge.swift:37`);
`markedObjects`, `markedBytes` and `blockLive` are read-modify-writes in
memory.

**The proposal**: a small FIFO between the stack and the trace (the
mark-sweep prefetching design of Cher, Hosking and Vijaykumar, 2004). An
object popped from the stack enters the FIFO (16 slots) and its entry line
is touched; at half depth its state word, by then in cache, gives the body
address and the body's first line is touched; the object leaving the FIFO
is traced. Both hops then overlap with the tracing of the objects ahead.
`drainStack` (the final mark's in-stop tracing) uses the same loop. While
there: the stack as a local in `markSome` written back at polls, the
format table's base hoisted, the tallies in locals.

Swift has no prefetch intrinsic. Two ways: a real load whose value is kept
in the FIFO slot (pure Swift; the overlap is bounded by the reorder
window, smaller on efficiency cores), or a C shim with `__builtin_prefetch`
(a C target in `Package.swift`, in `scripts/dist-frameworks.yml` and under
`just ios-check`). Try the first; it changes no build.

**Bound first**: in `experiments/entry-locality`, a fourth variant of the
`walkmarkN` mark: B (the table) with the FIFO. Run it beside A, B and L on
the Mac and the phone, at user-initiated and at utility (the marker's
QoS, efficiency cores). If B with the FIFO is not at least 1.3 times B,
stop. AGENTS.md's note that the phone core overlaps little arithmetic with
an outstanding miss is about work under a miss, not about two misses
outstanding; this experiment is what tells them apart.

**Measure after**: `markCpuNs / markedObjects` per cycle from `cycleRecs`
on `oldheap` and on the ring at 600 MiB; `drainNs` over `finalWorkUnits`
in the final-mark records; the device matrix's cycle ms and marker energy.
`just arc-check` already covers `markSome` and `drainStack`.

**Risk and size**: medium. Order of tracing changes, nothing else: the
snapshot, the mark byte's single writer and the SATB argument do not
depend on depth-first order. The FIFO must be drained to the stack at
every poll that parks and at every give-up of the final mark ("what it
took stays on the marker's stack"), and `dropMarkerWork` must clear it.
Guards: the final-mark verifier, `markingAlwaysOn` random programs, the
large-object chunk tests (a chunk item passes through the FIFO like an
object). Core tier.

**Confidence**: read for the loop; the gain is inferred from the
experiment's direct-against-table ratio and is a guess until the variant
runs.

---

## collectors.M4: the sweep touches the entry table for live entries, and marks are bytes beside a bitmap

**Where**: `Marking/Sweep.swift:39-74` (the loop), `:51-53` (the live
path); `Marking/Marker.swift:63-67` (`blockLive`, counted only when a
relocation is planned); `ObjectMemory/OldMap.swift:104-119` (mark bytes);
`Marking/Sweep.swift:155` (`clearMarks`, a memset of one byte per entry).

**What is there now**: per snapshot bit the sweep loads the mark byte.
Live: it loads the entry's state word to find its block and stores 1 in
`sweepLive[block]`, then clears the mark byte in a second loop. Dead: it
writes the entry free.

```swift
if om.markRelaxed(e) != 0 {
    live |= 1 &<< b
    unsafe m.pointee.sweepLive[BlockHeap.block(ofOffset: om.stateWord(raw))] = 1
```

**The cost**: a read of the entry table (sequential, four entries a
line) and a bounds-checked store, for every live entry of the snapshot, to compute
what the marker had in a register when it traced the object (`s` in
`traceObject`). The sweep's time is then proportional to the snapshot, not
to the garbage. `sweep-stop.md` measured 140 to 145 ns per 64-entry word
in a stop and bounded the stop at 4096 words (0.6 ms) for that reason;
`concurrent-marking.md` found "the lazy sweep, not the marking, is what
falls behind". The same byte-per-entry map costs every reference the
marker, the SATB barrier and the collector's `CandidateBuffer` look at a
second random load beside the snapshot bit (1 MB of marks per million old
entries against 125 KB of bitmap; on the phone the marker at utility runs
on the efficiency cores, whose shared cache is small).

**The proposal**, two steps.

1. The marker always records block liveness when it traces an object (it
   does when a relocation is planned). The sweep's live path then reads no
   entry. Relocation runs between the two, so check the argument: a moved
   object's to-space block carries this cycle's stamp and
   `freeDeadBlocks` skips it; an evacuated block is freed by epoch and is
   no longer in use; a selected block the pass did not finish keeps the
   mark-time bit, which is conservative. A run's head block is the block
   of its state word in both.
2. Marks as a bitmap parallel to the snapshot (or one "to mark" map,
   `snapshot & ~marked`, so the candidate test is one load and the mark is
   a store to the same word: one writer at a time, as now). The sweep is
   then word arithmetic: `dead = snap & ~mark`, nothing per live entry,
   and an abort clears an eighth of the memory. This changes module 1's
   mark map too (its collector, `isPendingDead`, the verifiers).

**Bound first**: step 1 is its own bound for step 2. For step 1, a
counting run: live and dead entries visited per sweep (`entriesVisited`,
`entriesFreed` are there) and `sweepCpuNs`; a cheating build that skips
the `sweepLive` store and the state load (blocks are then never freed:
run it on a kernel that needs none, such as the storm with a large heap)
gives the ceiling.

**Measure after**: `sweepCpuNs / entriesVisited`, words per sweep stop
inside the bound, `sweepStopsPartial` against `Whole`, the entries
fallbacks on the device storm rows.

**Risk and size**: step 1 small to medium (the block-liveness argument
above wants a test: a cycle that relocates, with the final-mark and
relocation verifiers on, and a broken variant that frees a block with a
live body). Step 2 large: `ObjectMemory` is another reviewer's area, the
oracle shares the map, and the model of the sweep's one-owner rule is the
free-list verifier. Core tier.

**Confidence**: read for step 1; inferred for the size of step 2's gain.

---

## collectors.A1: the trigger's inputs are kept in three places

**Where**: `Marking/InitialMark.swift:39-52` (samples in a scavenge's
stop), `:62-82` (`countOldEntries`), `:86-97` (two rate functions);
`Marking/MarkingState.swift:627-645` (`MarkingLog.samples`,
`entrySamples`, `oldEntries`, `lastPromotedObjects`, `lastOldAllocations`,
`lastCollections`); `YoungCollection/Owner.swift:273-292`
(`sampleForTrigger`), `:296-336` (`youngEntryRate`, `youngTrigger`,
`youngOldEntries`); `YoungCollection/YoungState.swift:319-329`
(`YoungSampler`, the same six fields again);
`ObjectMemory/LargeObjects.swift:239-241`.

**What is there now**: `decideTrigger` and `updateWantedQoS` are shared.
Their inputs are not. Under `young=stw` the stopper samples promoted bytes
plus old allocated bytes, and entries as promoted objects plus old
allocations. Under `offload` the young module keeps its own sampler under
its own lock, with promoted bytes and promoted objects only, computes the
promotion rate inline, and derives old entries as marking's estimate "plus
what young collections promoted since it last changed". A large allocation
calls `decideTrigger(mk, rate: 0, oldEntries: nil, record: false)` and so
reads marking's estimate as of the last stop that counted, with no rate.

**The cost**: three views of "how full, how fast". They already differ:
old allocations (large objects, and every Symbol and every object made
through `allocateOld`) are in the stop-the-world entry rate
(`InitialMark.swift:46-47`) and not in the offloaded one
(`Owner.swift:282-283`), and under `offload` they enter the old-entry
estimate only when `countOldEntries` next runs, which is inside the
initial-mark pause the estimate is meant to ask for. A change such as
"count large allocations' entries" or "window of 16 samples" has three
places to make it and two locks to think about. `MarkingLog` is "written
with the world stopped only" by convention, and read between stops from
`Owner.swift:324` and `LargeObjects.swift:241`.

**The proposal**: one pacing state in `Marking/Pacing.swift` that owns the
samples and the estimate: `notePromotion(bytes:objects:)`,
`noteOldAllocation(bytes:)`, `sample(now:)`, `rates()`, `oldEntries()`,
behind one small lock or as atomics, with the three callers (the scavenge
stop, `afterYoungCollection`, the large allocation) calling the same
`sample` and `decide`. `YoungSampler` goes. The record fields
(`entryRate`, `oldEntriesAtStart`) read from it.

**Bound first**: a counter, not a build: on the run line, print the
old-entry estimate each decider used beside a popcount of the old map at
the same instant (one stop per run is enough), for `collections` (200 000
Symbols) under `offload`. If they agree within a percent this is reuse
only and can wait.

**Measure after**: the same pair; fallbacks by cause on the matrix; the
entry-rate rule's raises.

**Risk and size**: medium. The rule "a trigger must watch every resource a
fallback can exhaust" is the invariant; the tests are the entries-trigger
test and the sweep-stop part 3 tests. Core tier.

**Confidence**: read. Whether the drift costs a fallback anywhere is not
known; see "Bugs met on the way", item 1.

---

## collectors.R1: the copy protocol is written twice

**Where**: `Relocation/Relocator.swift:342-413` (`relocateOne`,
`relocBegin`, `relocRevert`, `relocSwitch`) and
`YoungCollection/Collect.swift:420-449` (inside `Collector.evacuate`).

**What is there now**: the collectors review made `copyBody` one function
("they were two copies of this loop"). The steps around it are still two
texts: the seq_cst CAS to RELOCATING, the seq_cst fence, `isHazarded`,
the release-store revert, the copy, the release-store switch, and the
"in copy" flag that makes a park there a counted bug (`inRelocation` in
one, `work.pointee.inCopy` in the other).

```swift
let (ok, cur) = unsafe sw.pointee.compareExchange(expected: off, desired: off | EntryState.relocatingBit,
                                                  ordering: .sequentiallyConsistent)
...
atomicMemoryFence(ordering: .sequentiallyConsistent)
if unsafe isHazarded(vm, o) {
```

**The cost**: `docs/models/relocation.md` checks one protocol; two
implementations claim it. A change to an ordering, to the fence, or a
batched variant (several CAS under one fence) would have to be made twice
and re-argued twice. They differ already in what follows a failed CAS and
a hazard (skip against retry), which is policy and can stay with each
caller.

**The proposal**: three `@inline(__always)` functions in `Relocation/`
taking the state word's atomic and a pointer to the "in copy" flag:
`copyBegin(sw, off) -> Bool`, `copyRevert(sw, off)`, `copySwitch(sw,
dst)`. Both callers keep their loops and policies.

**Bound and measure**: no gain to bound. After: `just arc-check` (both
loops are in it) and a diff of the disassembly of `Collector.evacuate`
and `relocatePass`; identical is the bar.

**Risk and size**: small; core tier because of where it lives.

**Confidence**: read.

---

## collectors.R2: the body-range walk is written four times

**Where**: `Marking/RootScans.swift:119-149` (`walkYoungRoots`),
`YoungCollection/Owner.swift:357-391` (`youngRootScan`),
`YoungCollection/Collect.swift:645-670` (`scanNewHalf`),
`Relocation/Relocator.swift:244-276` (the block walk in `relocatePass`).

**What is there now**: four loops of the same shape:

```swift
let br = om.wordAtomic(atOffset: a)
let size = BackRef.words(br)
if size == 0 { break }
let o = BackRef.entryIndex(br) &<< 4
if o != 0 && om.stateWord(o) == a { ... every slot ... }
a &+= size &<< 3
```

`youngRootScan` is `walkYoungRoots` with fresh ranges and no poll; it
runs only under the test switch `youngRootsInStop`. The filters differ:
`walkYoungRoots` and `youngRootScan` skip bytes and deferred frees and
test `o != 0`; `scanNewHalf` skips bytes only and does not test `o != 0`;
the relocator tests the snapshot and the mark first.

**The cost**: "is this body the one its entry leads to" is a rule of the
heap's layout, and a change to the back reference (large-bytes changed
what its size field means) has four readers to visit. The two that omit
checks are right for their ranges today by an argument nobody wrote next
to them.

**The proposal**: one `@inline(__always)` walker in `ObjectMemory`,
`forEachBody(from:to:) { offset, entry, words in ... }`, that answers only
bodies whose entry leads to them. `youngRootScan` becomes a call of
`walkYoungRoots`' core over fresh ranges; the other three pass their
filter in the closure.

**Bound and measure**: none to bound. After: disassembly of the four
callers (`arc-check` lists the root scans and `relocatePass`), and the
young-root-scan tests with their broken variants.

**Risk and size**: small. Core tier.

**Confidence**: read.

---

## collectors.A2: the root set is enumerated in three places, and a stop builds it as a Swift array

**Where**: `Workers/Safepoint.swift:300-345` (`gatherRoots`);
`YoungCollection/Rounds.swift:67-82` (`scanOwnStack`),
`Collect.swift:590-640` (`claimAndScanParked`, `globalRoots`);
`Relocation/Relocator.swift:136-146` (`forEachRunningFrameWord`).

**What is there now**: `gatherRoots` appends to a `[Oop]`: the queue
words, every live record's Process, its stack `[0, sp]` word by word, the
receiver and method registers of running workers, every `result`
register, the pending roots. The young collector enumerates the same
things its own way (`current`, receiver, method, `youngHeld`, not
`result`; parked stacks; queues; pending roots; the finalization queue).
The frame pins walk `fp...sp` of running workers.

**The cost**: (1) Architecture: "which words of a worker and of a record
name objects" is one fact with three texts. AGENTS.md records that the
`result` register was found as a root by a failing test; the next
register that holds an oop (the native engine's state is the candidate to
check) must be added to two enumerations with opposite rules for
`result`. (2) Mechanical: every stop that asks for roots allocates and
fills an array of every stack word of every live Process under the
scheduler lock. The initial-mark pause, each `young=stw` scavenge and the
save ask; the apply and the sweep stop do not; the final mark asks only
when it verifies. It is one append per word (a capacity check,
a store, growth by doubling) and the consumer then reads the array once.
With tens of Processes this is microseconds. With thousands of Processes
it is the stop: 1000 Processes of 100 live words are 100 000 appends and
800 KB allocated inside the pause.

**The proposal**: in `Workers/`, two enumerators that take a visitor:
`forEachWorkerRoot(w, includeResult:, visit)` and `forEachRecordRoot(i,
visit)` (the stack through the right sp), plus `forEachGlobalRoot`
(queues, pending roots). `gatherRoots` becomes a visitor that appends, for
the callers that need an array (the save, the verifiers); `initialMark`
and the scavenge take the visitor and grey or copy directly;
`scanOwnStack` and `claimAndScanParked` call the same enumerators with
their `inY` filter; the frame pins too.

**Bound first**: a counter: words gathered per stop and the gather's ns
in `StopRecord` (the `words` field exists for the pointer walks). Read it
on the dev image with the tools open and on a test with 2000 waiting
Processes. If the largest is under 20 µs, only the architecture half
remains.

**Measure after**: `rootsNs` of the initial mark in `cycleRecs`; the
scavenge's pause under `young=stw` with many Processes.

**Risk and size**: medium. The rule "a running Process's stack through
its worker's saved sp, a suspended one's through the sp saved in it:
never both, never a stale one" must live in the one enumerator. Guards:
the `flushAfterStop` and `publishBeforeClearing` variants, the result
register test, the young model's root steps. Core tier.

**Confidence**: read for the three texts; the stop cost at many Processes
is an estimate.

---

## collectors.M5: `copySlots` re-decides the barrier per slot, from its own copy of the rule

**Where**: `Relocation/Hazard.swift:160-210`; the rule it copies is
`Marking/SATB.swift:44-56`.

**What is there now**: inside the per-slot loop, while a cycle marks:

```swift
let b = unsafe mk.buffer(w.pointee.index)
unsafe b.pointee.slowCalls &+= 1
if unsafe mk.phaseNow == .marking && !mk.pointee.config.testSwitches.satbOff
    && (mk.pointee.config.testSwitches.literal || ho & Header.youngBit == 0 || youngHolderScanOwed(mk, ho)) {
```

The function's own comment says "the phase cannot change inside the loop
(it never polls), so it is decided once" for the keep-alive pass. The
SATB decision is made per slot: the buffer pointer (two loads), a counter
store, the phase (two loads, acquiring), two config loads, an acquire
load of the root-scan state. With rounds open the young deletion switch
and the test window's hook are loaded per slot too.

**The cost**: 6 to 8 loads and a store per slot that do not depend on the
slot, in the one primitive that copies up to 32 768 slots between polls.
The seq_cst slot stores between them keep the compiler from hoisting.
Only while the flag word is set. And the SATB rule (young holder, scan
owed, the test switches) has two texts; the second review's "checked and
sound" list already had to name both.

**The proposal**: decide `record` once before the loop (phase, switches,
holder young and scan not owed; reading "owed" once is conservative: it
records more). Count `slowCalls` once with `n`. Put the decision in one
`@inline(__always) func satbShouldRecord(mk, holderHeader) -> Bool` in
`SATB.swift` used by `satbRecord` and by `copySlots`.

**Bound first**: a kernel that copies arrays under `--stress alwayson`
(the marking bit never cleared), cycles per slot with and without a
cheating build that skips the block entirely. That is the ceiling.

**Measure after**: the same kernel; `collections-oc` under `alwayson`.

**Risk and size**: small. Guards: the SATB tests with `noOwedScanBarrier`
and `satbOff`, the weak-copy test. Core tier.

**Confidence**: read.

---

## collectors.M6: the stop log is a 5.8 MB ring kept by hand

**Where**: `Workers/VMState.swift:174-176` (`stops`, `stopLog = 1 << 16`),
`Workers/VM.swift:54` (allocated), `:621-626` (`VM.stops`),
`Workers/Safepoint.swift:231-239` (the append);
`Workers/RecordRing.swift` (the type it is not).

**What is there now**: `StopRecord` is 88 bytes (five `UInt64`, four
`Int`, two one-byte enums padded). The log is 65 536 of them, allocated
whole per VM, indexed `stopCount & (stopLog - 1)`. Every other collector
log is a `RecordRing` of `VMConfig.logCapacity` records, and an app sets
that to `appLogCapacity`, 4096 (`Headless.swift:84`). `VMConfig`'s comment
calls the default "the stop log's size".

**The cost**: 5.8 MB that becomes dirty memory as stops happen and stays
dirty: an app that runs for days fills it and holds 5.4 MB more than the
4096 records it asked for. On the phone that is more than a nursery. The
ring's logic exists twice. `VM.stops` answers the slots in storage order,
so after the first wrap the list is not oldest first and its count stays
at 65 536 (the run line's `stops` reads that count).

**The proposal**: `stops` as `RecordRing<StopRecord>(capacity:
config.logCapacity)` with `reserveCapacity` so the append under the
safepoint mutex never grows it; `VM.stops` is `.records`; the run line's
`stops` reads the `stops` counter, which is already kept.

**Bound and measure**: `MemoryLayout<StopRecord>.stride` printed once in a
test settles the size. After: the shells' footprint line after 100 000
stops, before and after.

**Risk and size**: small. Readers: `Headless.swift:256`, `:402`,
`Shell/Shell.swift:717`, `:739`. Core tier (the file is in `Workers/`).

**Confidence**: read; the stride is computed by hand, not printed.

---

## collectors.A3: bit 0 of the attention word and the full-collection request are shared by convention

**Where**: bit 0 set: `Workers/Safepoint.swift:181` (a stop),
`YoungCollection/Owner.swift:238` (a full collection asked outside a
stop), `Processes/SavedProcesses.swift:78` (the save's hold). Bit 0
decided at release: `Workers/Safepoint.swift:221-225`. The request:
`Marking/FinalMark.swift:232-235`, `YoungCollection/Owner.swift:233-241`,
`Nursery/Scavenge.swift:220`, `:262-265`; its encoding
`Marking/Sweep.swift:464-472`; its state `Nursery/NurseryState.swift:336`.

**What is there now**: bit 0 means "a stop is requested", and also "take
the slow path because a full collection is due" and "because a save holds
the scheduler". Each setter ORs it. The release recomputes it from the
two reasons it knows by name:

```swift
if unsafe fullCollectionDue(vm) || vm.pointee.saveHold.pointee.load(ordering: .relaxed) {
    unsafe vm.pointee.flag.pointee.bitwiseOr(1, ordering: .relaxed)
} else {
    unsafe vm.pointee.flag.pointee.bitwiseAnd(~1, ordering: .relaxed)
}
```

The request for a full collection is two stores, the info word and then
the flag, written at four sites in three modules; the encoder lives in
Marking and the state in Nursery.

**The cost**: a third reason to keep polls on the slow path must be added
to the release's list or the next stop clears it; nothing checks that.
The barrier word had the same shape (two owners, one whole-word store)
and got bit operations and a verifier in the collectors review. The
four request sites each repeat "info first, then the flag, then maybe
bit 0"; one that forgets the info is a fallback recorded with the wrong
requester.

**The proposal**: (1) `requestFullCollection(vm, cause, requester,
worker)` in Nursery, the only writer of the pair, which also sets bit 0
when called outside a stop. (2) `slowPollReasons(vm) -> Bool` beside
`stopWorld`, the one list the release reads, with a line in
`verifyBarrierWordLocked`'s neighbour that checks at every stop that bit 0
is set exactly when a reason holds.

**Bound and measure**: nothing to bound. After: the stop verifier in the
random programs.

**Risk and size**: small. Core tier.

**Confidence**: read.

---

## collectors.M7: one GCD timer per Delay, on the default-QoS global queue

**Where**: `Processes/External.swift:241-252` (`startDelay`), `:118-138`
(`pushExternal`).

**What is there now**:

```swift
DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(ms)) {
    ref.timerFired(sem, handle: h < 0 ? nil : h)
}
```

Each Delay allocates a closure context (a retain of the life cell) and a
dispatch timer. It fires on a default-QoS thread of the process-wide
pool, takes the life cell's lock, mallocs a node, pushes it, takes the
scheduler lock to wake an idle worker; the drain then takes the scheduler
lock and the pending lock and frees the node.

**The cost**: the wake of a waiting Process is scheduled at default QoS
behind every user-initiated worker and shares its queue with the rest of
the process. AGENTS.md has two measured cases: five test VMs "starved the
timers another test's client waits on", and timers of 80 ms that "fired
early under load relative to the test's own clock". On a phone with its
performance cores busy, default QoS is the efficiency cores. A Smalltalk
animation or a timeout driven by `Delay` is as late as that thread. Per
Delay: two allocations and four lock acquisitions; no leeway is given, so
no two timers coalesce.

**The proposal**: one timer source per VM on a serial queue whose QoS is
chosen (user-initiated, the workers' class), over a small heap of
deadlines under the life cell's lock; one re-arm per earliest deadline; a
leeway of a tenth of the delay, capped. The life cell's rule is unchanged
(a late fire does nothing and is counted). `pushExternal` stays.

**Bound first**: measure, do not build: a `delays` kernel that sleeps
1000 times for 16 ms on a background Process while the storm runs, and
prints the lateness p50, p99 and max, timestamped where the Process
resumes (AGENTS.md: the time it happened). On the Mac and on the phone.
If p99 lateness under the storm is under a frame, drop the QoS half and
keep only the allocation note.

**Measure after**: the same histogram; wakeups per second of the timer
thread when idle (must stay 0 with no Delay pending).

**Risk and size**: medium. Guards: `DelayEndTests`, the hand-run
`KAJO_BROKEN_DELAY_END`, the idle test (no timed wait in an idle VM: a
source with nothing armed does not wake). Core tier.

**Confidence**: read for the path; the lateness on a device is a guess.

---

## collectors.R3: the marker's driver and the thread-info helpers are repeated

**Where**: the driver: `Marking/Marker.swift:362-386` (the thread) against
`Marking/MarkingHost.swift:260-327` (`markStep`, `markStepDone`,
`finalMark`, `sweep`, `sweepStep`) and
`Relocation/RelocationHost.swift:122-141`; the "relocate first, as the
marker thread does" block is at `Marker.swift:365-376`,
`MarkingHost.swift:304-307` and `:319-322`. The helpers:
`thread_info(THREAD_EXTENDED_INFO)` at `MarkingHost.swift:167-181` and
`:354-367` (the same body twice in one file), `Workers/VM.swift:570-584`,
`YoungCollection/YoungHost.swift:351`; `proc_pidinfo` declared at
`Marking/FinalMarkRecord.swift:13-14` and `Workers/VM.swift:674-675`, its
buffer parsed at `FinalMarkRecord.swift:28-50` and `VM.swift:592-617`.

**The cost**: the order "scan young roots, mark, final mark, relocate,
sweep, apply" is the cycle. The tests drive a second text of it; a step
added to the thread (the young-root scans were) must be added to each
manual entry point by hand, and one that is forgotten is a test of a
cycle the product does not run.

**The proposal**: `markerStep(vm, mk, .mark(limit) | .finalMark |
.relocate | .sweep(words))`, called by the thread loop and by the manual
entry points inside one `asMarker { }` bracket; one
`threadCPU(port) -> (cpuNs, curpri, basepri, runState)?` and one
`threadCounts(tid)` in `Workers/`.

**Risk and size**: small. Swift tier would do but the files are core.

**Confidence**: read.

---

## Read and found good

- **The SATB slow path** (`SATB.swift`): one out-of-line call, the young
  holder leaves after four loads, the buffer is per worker on its own
  line, the hand-over is one leaf lock and signals only when the marker
  waits. Nothing to change beyond M5's shared predicate.
- **The snapshot** (`InitialMark.swift:212-221`): a word copy with a
  popcount; measured at 0.02 to 0.05 ms.
- **The post-store check and its slow path** (`PostStore.swift`,
  `ObjectMemory.swift:240-255`): as the model has it; the slow path is one
  call; spins yield every 64.
- **The relocation copy loop**: per object one CAS, one fence, one load of
  the hazard count; the slot scan only when a slot is held. AGENTS.md's
  lesson names this cost; the pass still moved 5.9 GB per CPU second in
  `relocation.md`, so I do not propose batching the fence. The poll is
  every 64 objects or 16 KiB.
- **Epoch words** (`Epoch.swift`): one line per worker, the scan is seq_cst
  as the model asks, once per freed batch.
- **The final mark's passes**: bounded before the commit point; the weak
  pass is the owner's documented limit (review-fixes item 21); the
  selection walks blocks, not entries.
- **Per-worker lines**: `WorkerShared`, the SATB buffers, the flag line and
  every atomic of `MarkingShared` are `lined`. The cost is the other way
  (eight 128-byte allocations for single atomics the marker reads together
  at a poll), which is per 128 objects and not worth a finding.
- **The marker's poll**: a flag load, three atomics, the QoS check; the
  slowdown switch is one relaxed load.
- **The marker's wait** is untimed and every transition signals under the
  marking lock; the stall's wait is untimed with its transitions listed in
  the doc.
- **QoS**: the stopper's raise, the policy's raise at collections, the
  stalled worker's override of the marker are each one syscall at a rare
  point. Nothing found.
- **`RecordRing`**: no allocation once full. It grows by doubling until
  then, under whatever lock its owner holds (the safepoint mutex for the
  young log); `reserveCapacity` in `init` would remove a dozen reallocations
  per process. Too small for a finding.
- **The scheduler**: one lock, heap-linked queues, about ten checked
  stores per switch. `workers.md` lists per-worker queues as not done
  "with its contention counted". No doc has a number for `schedContended`
  from a program that signals in a loop at 8 workers; that measurement
  (AGENTS.md: "anything a program can do in a loop is measured at 8
  workers") should come before any design. `schedLock` also does an atomic
  add on the shared counter block at every acquisition; per-worker plain
  counters summed on read, as the interpreter's are, would take that off
  the shared lines when the measurement is made.
- **External signals**: lock-free push, the wake under the scheduler lock
  as the lesson requires.
- **Saved Processes, debugging, stack growth**: cold paths; nothing
  mechanical. `saveInStop` gathers roots twice (before and after its
  collection), which is right.

## Not read

- `YoungCollection/Collect.swift` 1 to 119, `Mutator.swift`,
  `YoungState.swift` beyond the sampler, `YoungHost.swift`,
  `YoungConfig.swift`, `YoungVerifier.swift`; all of `Nursery/`
  (`Scavenge.swift` only by grep); `ObjectMemory/` beyond `OldMap.swift`,
  the accessors and the pool readers my files call (`Instances.swift` not
  read). The young collector's epoch wait (`waitEpoch`, a yield spin) and
  the cost of polls while a round is open are in those files and are not
  judged here.
- Of the docs: `concurrent-marking.md` (layouts, sweep, triggers,
  measurements, deviations), `relocation.md` (measurements),
  `final-mark.md` (part 4 and the headings), `allocation-stalls.md` (the
  wait, liveness), `workers.md` (protocol, measurements, not done),
  `symbol-interning.md` (the matrix), `sweep-stop.md` and
  `image-processes.md` by headings, `delay-outlives-vm.md` through the
  plan's row and AGENTS.md. `docs/models/relocation.md` and `save-hold.md`
  were not re-read; I relied on the code's citations of them. The decision
  records were read through AGENTS.md's list and `30-review-fixes.md` by
  grep.
- No test file, no script, no disassembly.

## Bugs met on the way

1. `YoungCollection/Owner.swift:323-336` and `:273-292`: under `offload`
   the old-entry estimate and the entry rate leave out old allocations
   until the next initial-mark pause recounts
   (`Marking/InitialMark.swift:62-82`, called from `Owner.swift:345`). A
   program that makes old objects without promoting (Symbols, large
   objects) can pass the entries floor unseen by `youngTrigger`. The
   large-allocation trigger (`LargeObjects.swift:239-241`) reads the same
   stale estimate. Not traced to a failure; see A1 for the check.
2. `Workers/VM.swift:621-626`: after 65 536 stops `VM.stops` is not oldest
   first and `stops.count` saturates; `Headless.swift:402-405` prints that
   count as `stops`. See M6.
