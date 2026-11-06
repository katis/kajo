# Module 5: concurrent marking and lazy sweep of old space

Status: built, 2026-11-03. `Sources/KajoVM/Marking/`, with the object
memory's side in `Sources/KajoVM/ObjectMemory/OldMap.swift`. Tests in
`Tests/KajoVMTests/Marking/` and two random-program configurations.

Decisions it implements: ADR 0006 (snapshot-at-the-beginning marking on one
marker thread, marks in a byte map, lazy sweep published at the next pause,
fallback to stop-the-world counted as a provisioning failure) with its
amendments (snapshot at the end of a scavenge; survivor spaces are roots,
ADR 0007; marker at utility by default, raised when headroom shrinks; the
marker waits untimed, experiments/power), and ADR 0009 section 1 for the
marker (weak slots untraced and nil'ed, ephemerons by the key rule).
Evidence: experiments/concurrent-marking (SPEC, RESULTS sections 6 to 8,
its tests), concurrent-young ("Barriers", Part 3, amendment 18 and its
IdleTests). Ported by their tests first.

## What it hides

- When an old-space cycle starts, how long it runs, and on which thread.
- What the marker reads, what it never reads (young headers), and how the
  barrier keeps the snapshot intact.
- How dead old entries and blocks are returned, and when allocators see them.
- The marker's QoS and when it changes.
- What happens when old space fills before a cycle ends.

## The snapshot set (decided here)

Module 4 kept module 1's free lists for old allocation and gave young
objects **entry stashes**; there is no chunk bitmap and no used bitmap to
copy. Decided: an **old map**, one bit per entry beside the table (module
1, `ObjectMemory/OldMap.swift`), set exactly while the entry holds an old
object. The snapshot is a copy of its words below the high water mark at
the initial mark, so taking it is O(table words): 64 entries per word,
0.02 to 0.05 ms, with the contexts' retirement, for 0.95 to 5.3
million snapshot entries (Measurements). Membership is one bit test for
the marker and the barrier; the sweep enumerates it word by word.

Rejected: a used bitmap set by every allocation. Young allocation is the
VM's hottest path, entries of one 64-entry word belong to different
stashes, so the bit would need a `fetch_or` on every eden allocation, and
the snapshot would still have to subtract the survivors. The old map only
changes when an entry becomes old or stops being old, which young
allocation never does:

| transition | where | how |
|---|---|---|
| old allocation | module 1's `place` (large objects, image loading, the oracle without a nursery) | one relaxed `fetch_or` |
| promotion | module 4's entry sweep, which already reads every entry of its stash prefix and survivor log and now also sees the promoted ones (header no longer young) | accumulated per 64-entry word, one `fetch_or` per word, outside the copy loop (AGENTS.md: no per-object atomics in copy loops) |
| full collection, compaction | module 1's `sweepEntries` | rebuilt word by word on the way (world stopped) |
| become-forward | its freed sources | `fetch_and` |
| snapshot load | `rebuildOldMap` before the loader's verifier | from the table |
| lazy sweep | the dead entries of each word | one `fetch_and` (release) per word |

Why no snapshot entry is freed or reused before the sweep: old entries are
freed only by module 1's operations (each abandons a marking cycle first,
below) and by the lazy sweep itself; the scavenge's entry sweep frees young
entries only; the sweep's freed entries go to pending runs that no
allocator sees until the apply. Module 1's heap verifier checks the old map
against the table at every pause (`old map says ...`), which is how a
missed transition would show.

## Layouts

### Side tables

| table | size | written by | read by |
|---|---|---|---|
| mark map (module 1's) | 1 byte per entry | module 1 at a stop (plain); the marker participant between stops (relaxed atomic store, one writer at a time: the marker, or the stopper at a stop, so no read-modify-write); the sweep clears live entries' bytes | the barrier slow path and the marker (relaxed loads) |
| old map | 1 bit per entry, zero-filled reservation | above | the initial mark |
| snapshot map | 1 bit per entry | the initial mark (copy); the literal test mode's grey rule; the sweep clears each word after sweeping it | the marker, the barrier slow path, the final mark, the verifiers (`pending dead`) |
| block stamps | 1 `UInt32` per block, under the pool lock | `refillBlock` writes the current cycle's stamp | the apply |

The mark map is allocated once, beside the table, by module 1: one map,
one invariant (outside a collection every byte is zero), used by the oracle
and by the concurrent marker in turn. Module 1's heap verifier allows marks
while a cycle owns the map (`markingActive`, set at the initial mark,
cleared at the apply or abort). Outside a cycle the snapshot map is zero
too: the sweep clears it, an abort clears it.

### Flag word

Word 2 of module 3's safepoint flag line (`makeFlagLine`: one 128-byte line,
the safepoint flag at word 0), so the interpreter reaches it through the
pointer it already keeps for its polls. Bit 0: marking (set by the initial
mark, cleared by the final mark and an abort; `markingAlwaysOn` never
clears it). Module 7 adds its bits; the fast path tests the whole word.
Written with the world stopped only, and only bit 0, with an atomic or and
and: storing the whole word erased module 7's count (the collectors
review's finding 4, `docs/modules/collectors-review.md`); the stop
verifier checks both halves at every stop.

### Per worker: SATB buffer (`SATBBuffer`, own 128-byte lines)

512 oops, a count, and counters (pushed, handed over, slow-path calls,
keep-alive records). Written by its worker's barrier only, and by the
stopper at an initial mark, final mark or abort.

### The marker's queue (`MarkQueue`, under the marking lock)

Items of two kinds: SATB buffers (candidates, unmarked) and grey packets
(marked, to scan), both 512-oop buffers from one free list; every buffer
ever allocated is in an `allocated` list and freed from there only. Also
the marker's `waiting` count and `shutdown`. The marking lock is a leaf: a
worker takes it under the scheduler lock (a deletion store in the
scheduler) and nothing is taken under it.

### The marker (`MarkerState`, one, own lines)

Its grey stack, the weak holders and unresolved ephemerons it met, the last
cycle it finished marking and sweeping, the sweep's cursor, word count,
stamp and per-block live map, the partial run, the cycle's work counters,
its QoS and escalation counters. Written by the marker participant inside
the VM and by the stopper with the world stopped. The marker participant
is a module 3 `Worker` outside the worker table (index `workerCount`): it
counts as active in the stop protocol while it works, parks at stops and
never joins a scavenge's parallel phase (`parkLocked` checks the index).

### VM-wide (`MarkingShared`)

The configuration, the snapshot map, the buffers, the queue with its lock
and condition, the marker state and worker, the cycle log (`MarkingLog`,
written with the world stopped: counters, cycle records, the promotion
samples, the snapshot's word count), and atomics read outside stops: the
phase, the cycle number (bumped at an initial mark and at an abort), the
QoS the policy wants, the marker's wait count, shutdown.

### Pending runs and dead entries (module 1)

The sweep threads each dead entry into a run (state word free with the next
link, header 0) and hands every run to `pools.pendingRuns` at the end of
each 4096-entry chunk, before it polls: at every stop each free entry is in
exactly one list, which module 1's free-list verifier checks
(`pending run i`). Module 1's sweep discards them (their entries are free
in the table and land in its new runs). While a sweep is pending
(`setPendingDead`), a used entry in the snapshot with a clear mark byte is
**pending dead**: module 1's heap verifier and module 4's scavenge verifier
skip its slots, which may name entries the sweep already freed. A swept
word is cleared in the snapshot map, so nothing it held is pending dead
afterwards.

## The barrier

Module 4's `storeWithBarrier`, now in concurrent-young's shape:

```
if barrierWord(flag) != 0 { storeWithBarriers(s, o, i, v, site); return }   // one load, one branch
store; module 4's insertion barrier, unchanged
```

`storeWithBarriers` (one out-of-line call, scalars, nothing of the
instruction live across it): the SATB record, the store (relaxed atomic),
module 4's insertion barrier with its `rememberSlow` call. The SATB record
returns if no cycle is marking (the phase, one acquire load: so
`markingAlwaysOn` runs the slow path between cycles and records nothing),
if the holder's header is young (created after the snapshot, or a survivor
scanned as a root), if the old value is not a reference, not a snapshot
entry, or already marked; else it pushes the old value. A full buffer is
handed over under the marking lock (perturbation point) and the worker
takes an empty one.

Deletion sites: every store that may overwrite a reference in an old
object. Module 4's barrier sites all go through `storeWithBarrier`; the
scheduler's eight stores of nil over `next`, `waitingOn`, `lastWaiter` went
through module 1's plain store and now go through `clearingStore` (the flag
test, then `storeWithBarriers` or the plain store). Stores of
SmallIntegers over SmallInteger slots (Process registers, ids), the
loader, initialising stores into fresh objects and the collectors' own
weak nil'ing stay plain.

**Weak keep-alive.** The marker never traces weak slots, and a mutator can
read a referent through one (`at:`) and store it anywhere: SATB records
overwritten values, not loads, so without more the referent would be swept
under a live reference (a test shows it, below). `primAt` tests the flag
word after its load; set, it calls `weakReadBarrier`, which records the
value like an overwritten one when the receiver's format is weak, the slot
one of its weak slots and a cycle marking. Since the collectors review
(`docs/modules/collectors-review.md`, finding 1) every other primitive that
reads such a slot and hands the value on does the same (`instVarAt:`,
`slotAt:`, `shallowCopy`, the symbol table's bucket growth, through
`keepAliveRead`), and the array copy's loop checks its source once per
call. Ephemeron keys need no such
barrier: a marked ephemeron's key is always marked by the final mark (fired
or traced), and every value a mutator can store anywhere is a marked or a
new object.

### Instruction counts (release, `just arc-check`'s build)

| site | module 4 (9922977) | module 5 |
|---|---|---|
| `store_ivar` in `interpret`, old value or SmallInteger | 25 instructions: decode and slot check 13, store 4, barrier 4 (`tbnz`, `ldr` of the spilled table base, `ldr`, `tbz`), next 4 | 25: decode and slot check 13 (the table base is spilled here now), flag 2 (`ldr w11, [x28, #0x8]; cbz`, a taken branch), store 4, barrier 3 (`tbnz`, `ldr`, `tbz`), next 3 |
| `at:put:` (`primAtPut`) | 64 | 74; the flag test is 3 (`ldr` of the flag line from the state, `ldr w, [x, #8]`, `cbz`) |
| VM-internal stores (`makeReadyLocked`, `dequeueLocked`) | 88, 50 | 98, 74; the same 3-instruction test |
| `at:` (`primAt`) | 40 | 54 (the keep-alive test) |
| `interpret` | 752, one jump table | 775, one jump table |
| `ObjectMemory.store` | 5 | 5 (the relaxed atomic store is a plain `str`) |
| `storeWithBarriers` | | 104 (calls: `rememberSlow`, `handOver`) |

The slow path is one call with nothing of the instruction live across it:
in `store_ivar` the registers it clobbers are moved around the call and the
loop resumes at the shared epilogue.

## The cycle

Phases: idle, marking, sweeping, swept. They change only with the world
stopped, except sweeping to swept, which the sweeper stores when done.

### Initial mark (`initialMark`, behind `afterScavenge`)

At the end of module 4's stop-the-world scavenge, in its stop, when no
cycle runs and no full collection is due, and a trigger fires (below).
Module 7 replaces the caller (an initial-mark pause that scans every
nursery instead of scavenging); `initialMark` takes the roots as given.

1. Retire every allocation context (a context that continues a
   pre-snapshot block must refill, and the refill stamps the block) and set
   the block stamp to the new cycle's number.
2. Copy the old map into the snapshot map below the high water mark.
3. Reset the SATB buffers and the queue (with `markingAlwaysOn` they hold
   records of nothing), drop the marker's lists, take the mark map.
4. Mark the roots grey: module 3's stop roots (the same array the scavenge
   used) and module 1's (class table, registry, finalization queue). The
   remembered set is not a root.
5. Scan every survivor (every nursery's survivor log) as a root: every
   slot, weak and ephemeron slots included (their referents live this
   cycle). Unless `literal` or `noSurvivorRoots`.
6. Queue the grey stack as packets, set the flag word's marking bit, store
   the cycle number and the phase under the marking lock and broadcast.

### The marker (`markerLoop`, `markSome`)

Waits on the marking condition until a cycle is marking that it has not
finished marking, or sweeping that it has not swept; then enters the VM
as the marker worker, takes the QoS the policy wants, and works:

- **Marking**: pop the stack and trace; with the stack empty, perturb, poll
  and take a queue item (an SATB buffer's entries are marked if they are
  unmarked snapshot entries; a grey packet's are pushed). A poll every 128
  traced objects and between items: park if the safepoint flag is set,
  never joining a scavenge; take the wanted QoS; answer false if the cycle
  number or the phase changed (an abort): the marker drops its lists.
  Tracing reads the header and state word (stable: an old snapshot
  object), then each slot with a relaxed atomic load; a slot naming an
  unmarked snapshot entry is marked and pushed. A weak object's named slots
  only (listed); an unfired ephemeron whose key is an unmarked snapshot
  entry is listed and not traced (traced at once if its key is marked or
  is not a snapshot entry). With the stack and the queue empty: perturb,
  record its QoS, and request the final mark (it is the stopper).
- **Sweeping** (below), then a stop of its own to apply, unless
  `sweepNeverApplies` or a pause already applied.

The marker never reads anything young: everything it reads it reached
through a snapshot entry's slot or a record, and it reads only snapshot
entries (the filter is in `greyIfCandidate`; the verifier checks no
non-snapshot entry is ever marked).

### Final mark (`runFinalMark`), world stopped

1. Clear the flag word's marking bit (not with `markingAlwaysOn`).
2. Drain: every worker's partial buffer, every queued item, the marker's
   stack, to the end.
3. Filter the remembered set: a holder in a worker's remembered buffer
   that is an unmarked snapshot entry is dead and about to be freed; it
   leaves the buffer and its marker is cleared.
4. Ephemerons: those whose key is now marked (or not a snapshot entry)
   have their slots traced, to a fixpoint (tracing can mark another key);
   the rest are fired: module 1's `queueForFinalization` (header bit 48,
   the queue, the Semaphore due its signal after the stop) and all their
   slots traced, key included, so key and value survive this cycle. A
   fired ephemeron is strong from then on.
5. Weak slots: in every weak object the marker traced, a slot naming an
   unmarked snapshot entry becomes nil.
6. The verifier (checked builds, every test; below). On a failure the
   cycle is abandoned, nothing is freed, and a full collection is
   requested (counted).
7. Phase sweeping, the sweep's cursor and live-block map reset, the
   pending-dead skip on, broadcast.

The pause's cost is the drain (what mutators recorded since the marker's
last item, and their partial buffers), the remembered buffers' length, the
listed weak holders' and ephemerons' slots, and the verifier. Each is
timed in the cycle's record.

### Lazy sweep (`sweepCycle`) and apply (`applyInStop`)

The marker, after the final mark, walks the snapshot map in chunks of 64
words (4096 entries), polling between chunks. Per set bit: marked, the
entry is live (its block marked live; its mark byte cleared after the word,
since a live entry stops being a snapshot entry when the word is cleared);
unmarked, it is freed into the current run, its old-map bit cleared with
the word's others. Each run is handed to the pending list before the poll.
At the end the phase is swept.

The apply runs at the next scavenge or full collection (before its own
work), in any module 1 operation's hook, or in a stop the sweeper requests
right after sweeping (`StopKind.apply`): retire every context, free every
in-use block with no live body that no allocator took since the snapshot
(its stamp is not this cycle's), rebuild the block pool, publish the
pending runs, end the cycle (the QoS decision for the next one is made
here). Allocation never waits for a sweep; promotion uses module 4's
reserve.

### Abort and module 1's operations

Module 1's collect, compact, become (both), forward, reshape and snapshot
first run module 4's promote-all hook; that hook now first calls
`markingBeforeOldSpaceOperation`: a marking cycle is **abandoned** (flag
off, marks and snapshot map cleared, buffers and queue discarded, the
cycle number bumped so the marker drops its lists at its next poll), a
sweeping cycle's sweep is **finished in that pause** and applied, a swept
one applied. Nothing is freed twice: an entry the sweep freed is in a
pending run or the allocators' runs, never also in module 1's sweep's
input as used.

### Triggers and the predictor (`afterScavenge`, `decideTrigger`)

At the end of every scavenge (world stopped) the stopper records a
promotion sample: cumulative bytes promoted (module 4's counter) plus old
bytes allocated by contexts, with the time. The rate is taken over the last
8 samples. A cycle starts when none runs and no full collection is due and:

- `cycleAtEveryScavenge` is set (forced), or
- old space in use is at least `floor` of the soft limit (0.6), or
- the predictor: from 20 percent of the soft limit on, the headroom divided
  by the promotion rate (the predicted time to fill) is less than
  `safetyFactor` (2) times the last completed cycle's duration (before any
  cycle: old space in use over 1 GB/s).

Every decision records the rate and the prediction; each cycle's record
keeps them with its trigger.

### Fallback

Module 4's rule stands: a scavenge that leaves old space past its soft
limit requests module 1's full collection in a stop of its own (the next
poll or the next scavenge request). With concurrent marking configured that
collection, and one forced by a full entry table, is a **fallback**:
counted by the phase it found (idle, marking, sweeping or swept) and
reported in every `kajo run` line; it abandons a marking cycle or finishes
a sweep through the hook above. A verifier failure at a final mark is a
fallback of its own kind.

### QoS policy

The marker thread starts at utility (`pthread_attr_set_qos_class_np`). At
every scavenge end and at every forced cycle the stopper compares headroom
(free fraction of the soft limit) with `escalateBelow` (0.25): below it,
the policy wants user-initiated. The apply wants utility again when the
cycle ends with headroom at or above the threshold. The marker applies
what the policy wants with `pthread_set_qos_class_self_np` at its next
poll and when it starts and ends a work period, and counts each change
(`qosEscalations`, `qosLowerings`); every cycle's record logs the QoS it
marked at (`qos_class_self` when it requested the final mark).

### The untimed wait and its audit

The marker waits with `pthread_cond_wait` only; there is no timer anywhere
in the module (`grep -rn "timedwait\|asyncAfter" Sources/KajoVM` still
finds only module 3's Delay primitive). Its conditions are "phase marking
and not yet marked this cycle" and "phase sweeping and not yet swept this
cycle", plus shutdown. Every transition that can make one true changes
under the marking lock with a broadcast:

| transition | where | signal |
|---|---|---|
| phase -> marking, cycle number bumped | `initialMark`, step 6 | broadcast under the lock |
| phase -> sweeping | `runFinalMark`, step 7 | broadcast under the lock |
| shutdown | `stopMarkerThread` | broadcast under the lock |
| queue grows | `handOver` | signal if waiting (not a wait condition: the marker drains the queue while marking) |
| an abort (cycle bumped, phase idle), sweeping -> swept, the apply, the marker's own `markedCycle` and `sweptCycle` | | none needed: each only makes a condition false |

Two tests guard it (below): a parked VM's marker costs under 1 ms of CPU
and at most 5 wakeups in a second, and marking after idle periods
completes within a bound, so a lost wake cannot hide behind a timer. Both
were broken by hand (below).

## Verifiers

At every final mark in checked builds and in every test (`config.verify`),
through module 1's `record` (trap, or count and keep):

- **From scratch** (`verifyFinalMark`): a traversal of everything reachable
  from the stop's roots and module 1's, young and old, with the collectors'
  weak and ephemeron rules (weak slots are not edges; an unfired
  ephemeron's slots are edges once its key is reached), compared with the
  mark set. A reachable unmarked snapshot entry is **missed** (counted; the
  cycle is abandoned and a full collection requested); a marked unreachable
  one is **floating garbage** (objects and bytes counted per cycle); a
  marked entry that is not a snapshot entry is reported (the marker read
  what it must never read).
- Module 1's heap verifier at every pause it runs in checks the old map
  against the table, allows marks while a cycle owns the map, and skips
  pending-dead entries' slots; its free-list verifier walks the pending
  runs.
- Module 4's scavenge verifier keeps running at every scavenge and skips
  pending-dead entries (in the remembered-set check, in the reachable-young
  count and in the after-scavenge "names a freed entry" check), as the
  experiment's did.

Corruption test: `theMarkingVerifierReportsAMarkedNonSnapshotEntry` (a mark
set by hand on an object promoted during marking). Every broken-rule test
below fails through this verifier or module 4's.

## Stress flags and test switches

| flag | effect |
|---|---|
| `cycleAtEveryScavenge` (`--stress cycle`) | a cycle starts at every scavenge that finds none running |
| `markingAlwaysOn` (`alwayson`) | the flag word's marking bit is never cleared: every pointer store takes the slow path, which records nothing between cycles |
| `sweepNeverApplies` (`neverapply`) | no scavenge and no sweeper applies a finished sweep; only a fallback's hook does |

Perturbation (module 3's `perturb`) reaches the marker between queue items
and before the final-mark request, and the mutators at buffer handovers.

Test switches (`MarkingTestSwitches`, never used outside tests): `satbOff`,
`literal` (the textbook protocol: initial mark in a pause of its own, no
scavenge, young objects at the snapshot unscanned, no young-holder test),
`literalGrey` (its promotion rule: promoted objects join the snapshot marked
and grey), `noSurvivorRoots`, `noRememberedFilter`, `noWeakKeepAlive`; and
`markerThread = false`: no marker thread, the test drives `startCycle`,
`markStep(n)`, `finalMark` and `sweep` from its own thread, interleaved with
Smalltalk on chosen workers (`runOneSlice`).

## Counters

`vm.markingCounters`: cycles (by floor, predictor, forced; completed),
initial and final mark time, applies and apply time, objects and bytes
marked, marker CPU, sweep time, entries and blocks freed, SATB entries
pushed and buffers handed over, barrier slow-path calls, keep-alive
records, fallbacks (by phase: idle, marking, sweeping or swept; verifier),
aborts, sweeps finished in a pause, remembered holders filtered, weak slots
nil'ed, ephemerons queued, verifier runs, missed, floating bytes, QoS
escalations and lowerings, the marker's wait returns, and the promotion
rate and predicted time to fill at the last trigger decision.
`vm.cycleLog` (the last `VMConfig.logCapacity` cycles since the collectors
review, `vm.cycleTotals` the sums and the dropped count): per cycle the trigger with old space in use, the soft limit,
the rate and the prediction; the initial mark's split (snapshot copy, root
scan, survivor scan) and snapshot entries; the final mark's pause and split
(time to safepoint, drain and entries drained, filter, ephemerons, weak,
verifier); marker CPU and wall time, objects and bytes marked, SATB volume,
the marker's QoS; sweep wall and CPU time, entries, bytes and blocks freed;
apply time; duration; floating garbage; aborted or completed. Module 3's
stop records gained the kinds `finalMark` and `apply`. `kajo run` prints
them (`markingReport`).

## Measurements

All on the M2 Max (8 P + 4 E cores), macOS 27, Swift 6.4, release builds,
2026-11-03 00:30 to 01:00, after `pkill -x yes` (none left, `pgrep -x yes`
empty) and with no ThreadSanitizer run alive. Load average (1 min) 2 to 5,
mostly the 8-worker kernels themselves (the busiest other processes:
this agent, Warp, under 10 percent of a core). Module 4's `kajo` built
from 9922977 in a worktree; this module's from `.build/bench`. Every
checksum is the published one.

### Barrier cost with marking off, interleaved against module 4

One worker, default options (1 GiB heap, 4 MiB nurseries, N = 2), five
runs each, medians (min to max), ms. `m5 stw` is module 5 with marking not
configured (`--gc stw`): the flag word exists and is never set either way.

| kernel | module 4 | module 5 | ratio | module 5, `--gc stw` |
|---|--:|--:|--:|--:|
| ivars | 1966.7 (1966.1 to 1994.0) | 1995.0 (1992.9 to 2000.1) | **1.014** | 1994.6 (1991.3 to 1996.5) |
| fib | 1601.8 (1600.7 to 1605.8) | 1625.9 (1624.1 to 1631.3) | 1.015 | 1623.2 (1620.7 to 1624.2) |
| alloc | 2687.2 (2680.9 to 2693.2) | 2725.4 (2713.5 to 2734.1) | 1.014 | 2730.6 (2713.1 to 2737.8) |

The bound (at most 3 percent on `ivars`) holds: 1.4 percent, and `fib`,
which stores nothing, moved by the same 1.5 percent (code placement:
`interpret` grew by 23 instructions). `alloc`'s 1.4 percent includes
`place`'s old-map `fetch_or` on its large objects and the entry sweep's
per-word `fetch_or` for promotions.

### Mutator slowdown with the flag word never cleared

Module 5 default against `--stress alwayson` (every pointer store takes
`storeWithBarriers`, which records nothing between cycles) and
`--stress alwayson,cycle` (marking continuously: a cycle starts at every
scavenge), `--slice-ms 0`, five interleaved runs, medians, ms:

| kernel | workers | default | alwayson | slowdown | alwayson,cycle | slowdown | cycles |
|---|--:|--:|--:|--:|--:|--:|--:|
| ivars | 1 | 1991.7 | 2239.2 | 12.4 % | 2232.6 | 12.1 % | 0 (nothing promotes) |
| ivars | 8 | 265.8 | 294.0 | 10.6 % | 293.5 | 10.4 % | 0 |
| oldheap64 (192 MiB) | 1 | 2345.8 | 2492.8 | 6.3 % | 2607.1 | 11.1 % | 177 |
| oldheap64 | 8 | 341.5 | 360.3 | 5.5 % | 374.8 | 9.8 % | 9 |
| alloc | 1 | 2802.5 | 2865.2 | 2.2 % | 2896.1 | 3.3 % | 320 |
| alloc | 8 | 410.9 | 427.2 | 4.0 % | 441.7 | 7.5 % | 23 |

(`alloc` rows re-run after the entry-table trigger, load 6 to 9 from the
runs themselves.) The experiment's force mode cost 9 to 12 percent on its
large-heap kernel with 8 workers and up to 24 with one; here 9.8 and 11.1
percent. `ivars` with the flag on pays the out-of-line call on every
SmallInteger store: the slow path is the price of a cycle, not of
marking work.

### Headless matrix (`matrix.sh`)

`oldheap` at 64, 256 and 512 MiB of live old data, old space 2N + 64 MiB,
4 MiB nurseries, N = 2, `--slice-ms 0`, stop-the-world oracle (`--gc stw`)
against concurrent marking, five interleaved runs per cell, medians (the
maxima are the max over the five runs); floating garbage from one more
concurrent run per cell with `--verify` (the final-mark verifier on, which
makes the final mark a full traversal and the run 4 to 17 times slower, so
it marks more, and more dies while it marks). Load average 2.1 to 5.5.

| live | w | stw ms | cm ms | stw fulls, max ms | final p50 / max ms | final ttsp p50 | initial mark added p50 / max ms | scav p50 stw / cm | cycles | fallbacks | marker CPU per cycle ms | apply p50 ms | floating MB (verified run, all cycles) | marker QoS per cycle |
|---|--:|--:|--:|---|---|--:|---|---|--:|--:|--:|--:|--:|---|
| 64 MiB | 1 | 2355.2 | 2355.3 | 0 | 0.014 / 0.018 | 0.014 | 0.123 / 0.137 | 0.316 / 0.301 | 2 | 0 | 9.6 | 0.025 | 0.95 | utility x2 |
| 64 MiB | 8 | 336.3 | 346.2 | 0 | 0.112 / 0.155 | 0.113 | 0.555 / 0.825 | 0.947 / 0.897 | 3 | 0 | 16.3 | 0.030 | 56.7 | utility; one run had one user-initiated cycle |
| 256 MiB | 1 | 10481.1 | 10447.5 | 2, 35.8 | 0.013 / 0.056 | - | 0.084 / 0.161 | 0.328 / 0.294 | 6 | 0 | 38.4 | 0.041 | 8.1 | utility x6 |
| 256 MiB | 8 | 1514.8 | 1483.4 | 2, 44.3 | 0.143 / 0.234 | - | 0.567 / 0.935 | 0.954 / 0.823 | 6 | 0 | 69.9 | 0.055 | 114.9 | utility |
| 512 MiB | 1 | 22300.5 | 22247.6 | 2, 69.2 | 0.010 / 0.037 | 0.008 | 0.094 / 0.198 | 0.327 / 0.292 | 8 | 0 | 78.0 | 0.070 | 21.5 | utility x8 |
| 512 MiB | 8 | 3195.3 | 3159.3 | 2, 86.3 | 0.128 / 0.839 | 0.092 | 0.597 / 0.940 | 0.965 / 0.857 | 7 | 0 | 150.5 | 0.083 | 806.5 | utility; one run had one user-initiated cycle |

- **Final mark**: 0.11 to 0.14 ms p50 with 8 workers at every size, not
  growing with heap size (the expectation: under 0.2 ms), nearly all of it
  time to safepoint (0.09 to 0.11 ms); 0.010 to 0.014 ms with one worker.
  The worst maximum, 0.84 ms at 512 MiB, is one run's descheduled worker.
  The drain is 0.012 to 0.014 ms p50 at 8 workers.
- **The oracle grows**: stop-the-world full collections of 36, 44, 69 and
  86 ms at 256 and 512 MiB (none at 64: the 192 MiB old space never filled),
  against the expected 5 to 80 ms.
- **Initial mark**: its addition to the scavenge is 0.08 to 0.12 ms p50 with
  one worker and 0.56 to 0.60 with eight. The split (separate runs): the
  snapshot copy with the contexts' retirement 0.02 to 0.05 ms for 0.95 to
  5.3 million entries, the roots 0.001 to 0.011 ms, the survivor scan 0.06
  to 0.08 ms on one worker and 0.52 to 0.53 ms on eight (eight 512 KiB
  survivor halves, scanned by the stopper alone: ADR 0007's "up to 1.3 ms
  with 8 workers"). The experiment's 0.05 ms had no survivor spaces.
- **Throughput**: concurrent is as fast as or faster than stop-the-world
  (up to 2 percent faster at 256 and 512 MiB with 8 workers, where the
  oracle's two fulls stop everyone); 3 percent slower at 64 MiB with 8.
- **Floating garbage**: the verified runs' sums over all cycles; at 512 MiB
  with 8 workers the verifier makes each final mark 150 ms, during which
  eight workers replace groups, so the figure is an upper bound for this
  kernel, not what an unverified run carries.
- **Triggers**: every cycle here started by the floor except one by the
  predictor in a 64 MiB run (3 cycles: 2 floor, 1 predictor); the predictor
  fires earlier in the storm (below).

### Allocation storm (`storm.sh`)

`alloc` on 8 workers, `--slice-ms 0`, five interleaved runs, medians:

| old space | N | stw ms | cm ms | promoted MB/s (cm) | stw fulls (max ms) | cm cycles (done) | by floor / predictor | fallbacks (marking / sweeping / idle) | final p50 / max ms | cycle ms | marker QoS (user-initiated cycles) |
|---|--:|--:|--:|--:|---|---|---|---|---|--:|---|
| 64 MiB | 1 | 709.6 | 670.5 | 1498 | 32 (18.2) | 20 (13) | 19 / 1 | 21 (6 / 9 / 6) | 0.116 / 0.157 | 15.1 | 12 to 13 of 13 to 15 |
| 64 MiB | 2 | 605.3 | 425.5 | 778 | 20 (20.3) | 9 (9) | 7 / 3 | 1 (0 / 1 / 0) | 0.106 / 0.146 | 15.9 | 3 to 4 of 8 to 12 |
| 256 MiB | 1 | 574.2 | 500.4 | 1981 | 6 (43.2) | 7 (6) | 1 / 6 | 2 (0 / 2 / 0) | 0.114 / 0.168 | 46.9 | 0 (3 escalations, during sweeps) |
| 256 MiB | 2 | 455.5 | 404.6 | 1048 | 2 (29.8) | 3 (3) | 1 / 1 | **0** | 0.106 / 0.157 | 42.3 | 0 |

- **The marker kept up with about 1 GB/s of promotion with zero fallbacks
  given a 256 MiB old space** (N = 2), against the brief's 600 MB/s with
  256 MB of headroom. At 2 GB/s (N = 1) two fallbacks per run remain, both
  found sweeping: the lazy sweep, not the marking, is what falls behind,
  as the experiment found.
- A 64 MiB old space at 1.5 GB/s cannot be served: 21 fallbacks per run
  against 32 full collections for the oracle; at N = 2 one.
- **The predictor**: in the 256 MiB storm it started 6 of 7 cycles (N = 1)
  before the floor; in the 64 MiB storm the floor starts nearly all,
  because one scavenge's promotion is a large share of the headroom. A
  fixed floor alone would have started the 256 MiB cycles later.
- **QoS policy**: with a 64 MiB old space the marker marked at
  user-initiated in most cycles; with 256 MiB never. Escalations that came
  during a sweep do not show in the per-cycle log, which records the QoS
  at the final-mark request.

### Idle

`aParkedVMDoesNotWakeItsMarker` (3 background workers, marker thread, one
second parked): **0 ns of marker CPU and 0 wakeups** (bounds: under 1 ms,
at most 5). `markingCompletesPromptlyAfterIdling`: two cycles each started
after 300 and 200 ms idle finished (marked, swept, applied) in 1.6 and 1.7
ms (bound 3 s). Broken by hand, each fails: with a 1 ms timed wait in
`markerLoop` the parked test fails both bounds; without the initial mark's
broadcast the post-idle cycle never finishes (`ms != nil` fails).
`grep -rn "timedwait\|asyncAfter" Sources/KajoVM` finds only module 3's
Delay primitive.

### Randomized programs

- In the suite: 100 seeds for each of the 13 configurations, two of them
  new: `cycleEveryScavenge` (4 workers, 24 KiB nurseries, a cycle at every
  scavenge, every verifier) and `markingAlwaysOn` (the same with the flag
  word never cleared and perturbation reaching the marker). 10 seeds each
  under ThreadSanitizer. No failure; every run checks `missed == 0` and
  that cycles completed.
- `just soak` (1000 seeds per configuration, 13 configurations, release):
  seeds 1 to 1000, no failure, 25.5 s.
- A hand run with the block stamp switched off (a sweep then frees a block
  that promotion continued after the snapshot): the two marking
  configurations failed in 30 seeds (every few seeds) at the heap
  verifier `Runtime.stop` runs at teardown; the suite's other marking
  tests passed. The
  random programs are that rule's test.

## Changes to modules 1 to 4

Module 1 (`ObjectMemory/`):

- New `OldMap.swift`: `EntryBitmap` (the old map, and the type of module
  5's snapshot map), `rebuildOldMap`, the mark map's relaxed atomic access
  (`markAtomic`, `markRelaxed`, `setMarkRelaxed`), `setMarkingActive`,
  `clearMarks`, pending runs (`addPendingRun`, `publishPendingRuns`), block
  stamps (`setBlockStamp`, `freeDeadBlocks`), `queueForFinalization`, the
  pending-dead skip (`setPendingDead`, `isPendingDead`).
- `MemoryShared.oldMap`; `Pools.pendingRuns`, `blockStamps`, `stampNow`;
  `CollectorState.pendingDead`, `markingActive`.
- `store` is a relaxed atomic store (still 5 instructions, a plain `str`);
  `loadAtomic(bodyOffset:_:)` for the marker.
- `place` sets the entry's old-map bit (`ObjectMemory.place` 46 to 51
  instructions, `tryAllocate` 56 to 61); `refillBlock` stamps the block.
- `sweepEntries` rebuilds the old map and discards the pending runs;
  `becomeForward` clears its sources' bits; the snapshot loader rebuilds
  the map before its verifier.
- `verifyHeap`: the old map against the table, marks allowed while a cycle
  owns the map, pending-dead entries' slots skipped. `verifyFreeLists`: the
  pending runs.

Module 2 (`Interpreter/`):

- `store_ivar` calls `storeWithBarrier` with the flag line it already holds
  (`interpret` 752 to 775 instructions, one jump table).
- `primAt` tests the flag word and calls `weakReadBarrier` (since the
  collectors review through `keepAliveRead`, as the other readers of a
  weak slot do).
- The standalone `Interpreter` allocates the flag line (`makeFlagLine`).

Module 3 (`Workers/`, `Processes/`):

- `VMConfig.marking`; `VMState.marking`; `VM.init` installs marking after
  the nurseries and allocates the flag line, `start` starts the marker
  thread, `shutdown` stops it after the workers, `destroy` uninstalls it.
- `parkLocked` joins a scavenge's parallel phase only for workers of the
  worker table (the marker never joins).
- `StopKind` gained `finalMark` and `apply`.
- The scheduler's stores of nil over `next`, `waitingOn` and `lastWaiter`
  go through `clearingStore` (a deletion the SATB barrier must see).
- `Headless.Options` gained `gc`, `markingStress`, `floor`, `safetyFactor`,
  `escalateBelow`; `kajo run` gained `--gc cm|stw`, `--floor`, `--safety`,
  `--escalate-below` and the stress words `cycle`, `alwayson`,
  `neverapply`; the run line has the marking report.
- Tests: `backToBackStopsDoNotLetReleasedWorkersRun`'s broken variant does
  not run under ThreadSanitizer; the random programs gained two
  configurations.

Module 4 (`Nursery/`):

- `storeWithBarrier` tests the flag word first and sends the whole store to
  `storeWithBarriers` when it is set; a variant takes the flag line;
  `clearingStore` is new.
- The entry sweep sets the old map's bits of promoted entries
  (`noteOld`, per word).
- `youngPause` calls `beforeScavenge` (apply a finished sweep) and
  `afterScavenge` (the trigger and the initial mark) around the scavenge
  with one root array, and counts fallbacks (`noteFullCollection`) for full
  collections forced by space; `runDueFullCollection` counts them too.
- The promote-all hook before module 1's operations first calls
  `markingBeforeOldSpaceOperation`.
- The nursery verifiers skip pending-dead entries.

## Deviations

- **The snapshot set is an old map, not a used bitmap** (above): set when
  an entry becomes old, never on young allocation; the brief's used bitmap
  would have put an atomic on every eden allocation and still needed the
  survivors subtracted.
- **The flag word lives in module 3's safepoint flag line** (word 2), not as
  a field of the VM struct: the interpreter already keeps that line's
  pointer in a register for its polls, so the test in `store_ivar` is one
  load and one branch with no extra register.
- **A keep-alive read barrier on `at:` of weak slots** (not in the brief).
  The marker does not trace weak slots, and SATB records overwritten values,
  not loads: a referent held only weakly at the snapshot, read through its
  weak slot and stored into a scanned object, was swept under a live
  reference. `aWeakReferentReadDuringMarkingIsKeptAlive` shows the loss with
  the barrier off. It costs `at:` one flag test.
- **Survivors' weak and ephemeron slots are scanned strongly at the initial
  mark**: weak objects that are young at the snapshot are never listed by
  the marker, so their referents must not be freed this cycle. Their weak
  semantics apply from the cycle in which they are old.
- **The sweeper requests its own apply stop as soon as it finishes**, unless
  a scavenge or a full collection applied first. "If no pause comes" cannot
  be decided without a timer, and the module has none; a cycle therefore
  ends with a stop of its own (time to safepoint plus 0.02 to 0.05 ms of
  apply) whenever no scavenge happens to come first. Host stops (`inspect`,
  `withWorldStopped`) do not apply, so tests can watch the phase.
- **A module 1 operation finishes a sweep instead of abandoning it.** Only a
  marking cycle is abandoned; once the sweep has freed entries into pending
  runs, abandoning it would leave entries owned twice or freed twice. The
  operation's pause finishes the sweep and applies it (counted,
  `sweepsInPause`); a marking cycle is cheap to abandon.
- **Become, reshape, compaction and snapshot abandon a marking cycle too**,
  not only full collections: become swaps bodies under the marker (a
  scanned object would get unscanned slots), forward frees entries the
  snapshot names, compaction moves bodies.
- **Mark bytes are set with a relaxed store, not an exchange**: one marker
  participant writes marks at a time (the marker between stops, the
  stopper inside one), so there is no read-modify-write to lose.
- **An entry-table trigger**: a cycle also starts when the estimated old
  entries reach the floor fraction of the entry table. `alloc` filled the
  16.7 M-entry table before its blocks reached the floor, and the result
  was a fallback with no cycle ever started.
- **The predictor is consulted from 20 percent of the soft limit on** and,
  before any cycle has finished, assumes 1 GB/s of marking. Below 20
  percent a cycle is cheap whenever it starts, and in tests with tiny
  heaps the rate over a few fast scavenges was enormous.
- **On a verifier failure in a build that records** the cycle is abandoned
  (nothing freed) and a full collection requested, counted as a fallback
  of its own kind.
- **The marker participant is a module 3 `Worker` outside the worker
  table**, so module 3's enter, leave, park and stop work for it unchanged;
  `parkLocked` excludes it from a scavenge's parallel phase by its index.
- **The textbook grey rule (test mode) adds promoted objects to the
  snapshot, marked and grey**, so the marker scans them as snapshot entries.
- **The ported tests release their Processes.** The host keeps every
  spawned Process rooted, and a terminated Process's `result` slot holds
  what the method answered (the list the test means to drop), so the
  experiment's "dead" objects were reachable.
- **Module 3's broken back-to-back-stops variant is skipped under
  ThreadSanitizer.** With its rule off a released worker runs inside the
  next stop, a data race by construction, and the sanitizer reported it
  once in this module's final run (never in module 4's). The stop verifier
  still shows the bug in every other build.
- **Concurrent marking is on by default** whenever a nursery is
  (`MarkingConfig.enabled`); `--gc stw` (or `enabled = false`) is the
  oracle. Every existing test now runs with a marker thread where it
  starts its VM.
- **`oldheapUnderConcurrentMarkingMatchesStopTheWorld` runs twice**, with
  cycles at every scavenge and with the flag word never cleared as well;
  the experiment's second run (two markers) is not built.

## Tests

21 test functions in `Tests/KajoVMTests/Marking/` (205 in the suite), plus
the two random-program configurations.

**Ported from experiments/concurrent-marking** (`ConcurrentMarkingTests.swift`):
`satbKeepsAValueOverwrittenDuringMarking`,
`withoutSATBTheVerifierReportsTheMissedObject`,
`objectsPromotedDuringMarkingSurviveTheCycle`,
`literalProtocolNeedsItsGreyPromotionRule`,
`designLiteralProtocolLosesATargetOfADeadYoungObject`,
`snapshotAfterAScavengeKeepsTheTargetOfAYoungObject`,
`filteringRemovesADeadHolderFromTheRememberedSet`,
`sweepFreesEntriesAndBlocksAndTheyAreReused`,
`oldSpaceFillingDuringACycleFallsBackToAFullCollection`,
`oldheapUnderConcurrentMarkingMatchesStopTheWorld` (cycles at every
scavenge, and with the flag word never cleared too). Promotion on first
survival (N = 1) where the experiment reasoned with it.

**From concurrent-young's IdleTests** (`MarkerThreadTests.swift`):
`aParkedVMDoesNotWakeItsMarker`, `markingCompletesPromptlyAfterIdling`
(without relocation, which is module 6's).

**New**: `aWeakSlotIsNiledAtTheFinalMarkExactlyWhenItsReferentDied`,
`anEphemeronWhoseKeyIsReachableOnlyThroughItIsQueuedOnceAndItsValueTraced`,
`anEphemeronWhoseKeyIsReachableElsewhereIsNotQueued`,
`aWeakReferentReadDuringMarkingIsKeptAlive`,
`theMarkingVerifierReportsAMarkedNonSnapshotEntry`,
`theMarkerIsRaisedWhenHeadroomShrinksAndLoweredWhenItRecovers` (through the
counters and each cycle's logged QoS), `survivorsAreRootsAtTheInitialMark`,
`withoutFilteringTheScavengeReadsAFreedHolder`,
`aSweepThatNeverAppliesFallsBack`; the random-program configurations
`cycleEveryScavenge` and `markingAlwaysOn`.

**Rules, each checked by breaking it**:

| rule | test | how broken | fails how |
|---|---|---|---|
| SATB records overwritten values | `withoutSATBTheVerifierReportsTheMissedObject` | switch `satbOff` (suite) | final-mark verifier: 100 list cells missed |
| the snapshot is taken at the end of a scavenge | `designLiteralProtocolLosesATargetOfADeadYoungObject` | switch `literal` (suite) | missed |
| the textbook protocol needs its grey rule | `literalProtocolNeedsItsGreyPromotionRule` | `literalGrey = false` (suite) | missed |
| survivors are roots (ADR 0007) | `survivorsAreRootsAtTheInitialMark` | switch `noSurvivorRoots` (suite) | missed |
| the final mark filters dead remembered holders | `withoutFilteringTheScavengeReadsAFreedHolder` | switch `noRememberedFilter` (suite) | module 4's scavenge verifier after the sweep |
| a weak referent read during marking is kept | `aWeakReferentReadDuringMarkingIsKeptAlive` | switch `noWeakKeepAlive` (suite) | missed |
| the marker marks only snapshot entries | `theMarkingVerifierReportsAMarkedNonSnapshotEntry` | a mark set by hand (suite) | "marked but not a snapshot entry" |
| a refill stamps its block | random programs, marking configurations | the stamp line commented out (hand run) | teardown heap verifier |
| the marker waits untimed | `aParkedVMDoesNotWakeItsMarker` | a 1 ms timed wait (hand run) | CPU and wakeup bounds |
| every wait condition is signalled | `markingCompletesPromptlyAfterIdling` | the initial mark's broadcast removed (hand run) | the cycle never finishes |

**Waiting**: relocation and frame pins (module 6:
`aFramePinnedObjectIsNotMoved`, the relocation half of
`markingCompletesPromptlyAfterIdling`), local and offloaded young
collection and the young-root initial mark (module 7), the 120 Hz
scenarios C0 to C6 and the device QoS measurement (module 9), two markers
(not built).

### Gates (final code)

`swift test`: 205 tests green (77 s). Under load (12 `yes`, load average
26): green (104 s). `swift test --sanitize=thread`: 205 green (518 s); the
run reported two data races, both in module 3's
`backToBackStopsDoNotLetReleasedWorkersRun` with its rule switched off (a
released worker runs inside the next stop: the race that variant exists
to show; module 4's sanitizer runs never hit the window). That variant no
longer runs under the sanitizer (deviation below); re-run, clean. Every
marking test under the sanitizer on its own: clean (360 s). `just
test-release` green, `just golden` (arith 2597, fib 1678, sends 2561,
alloc 2805, ivars 2042, walk 3456 ms, all ok), `just ios-check` clean,
`just arc-check` zero retain and release, one jump table, `just soak`
(above); a clean build has no warning.

## Unsafe surface

Lines with `unsafe` (code lines, a clean build with no warning):
`Marking/` 558: MarkingHost 102, InitialMark 101, Marker 101, FinalMark 92,
Sweep 80, SATB 35, MarkingState 19, MarkingVerifier 3, MarkingConfig 0.
Module 1's new `OldMap.swift` 25 (and 8 more in its other files:
`ObjectMemory/` 318 to 351); `Nursery/` 433 to 451, `Workers/` 480 to 483,
`Processes/` 228 to 236 (the deletion stores), `Interpreter/` 302 to 303.
The surface is the pointers to the marking state and the marker worker,
the SATB buffers and queue under the marking lock, the snapshot and old
maps as `Atomic<UInt64>` words over zero-filled reservations, the mark map
as `Atomic<UInt8>` over module 1's bytes, the relaxed atomic slot loads,
and the pthread calls. `MarkingShared`, `SATBBuffer`, `MarkItem`,
`MarkQueue`, `MarkerState` and `MarkerThread` are `@unsafe`; the host
surface (`startCycle`, `markStep`, `finalMark`, `sweep`, the counters and
the log), the configuration and the records are safe, so tests need none.
The verifier is almost entirely safe code (3 lines).

## Hot-path check

`just arc-check` (final code) adds `storeWithBarriers` (104 instructions;
calls `rememberSlow`, `handOver`), `handOver` (58), `weakReadBarrier` (73),
`takeBufferLocked`, `markSome` (317; the trace loop with `traceObject` and
`greyIfCandidate` inlined), `markerPoll` (59), `drainStack` (200),
`takeItem`, `popItem`, `returnBuffer`, `sweepCycle` (288) and
`applyInStop`: zero `swift_retain`/`swift_release` in every one;
`interpret` 775 instructions, one indirect branch, one jump table. The
apply calls `isUniquelyReferenced` on the cycle log's array (a pause, not
a hot path). Instruction counts of the store sites are in "The barrier".

## Not done

- Pacing (mutators doing marking or sweeping work when the marker falls
  behind); a faster sweep (the storm's remaining fallbacks are found
  sweeping): sweeping in parallel, or publishing freed blocks without a
  pause.
- Two markers (the queue and packet shape allow it).
- A parallel or deferred survivor scan: it is the initial mark's cost at 8
  workers (0.52 ms).
- The apply's block-pool rebuild is O(blocks) in a pause (0.03 to 0.09 ms
  at these sizes).
- Device measurement of the QoS policy and its escalation (module 9's
  app); the per-cycle log records the QoS at the final-mark request only,
  not changes during a sweep.
- Full collections that `allocateOld` (large objects) runs when old space
  has no block are not counted as fallbacks.
- An ephemeron whose key was reachable only through it at the snapshot is
  fired even if a mutator read the key through it during the cycle; its
  finalization is early, never unsafe.
- The predictor was measured on these kernels only; its window (8
  scavenges), safety factor (2) and lower bound (20 percent) are guesses.
- Relocation (6), young collection without stopping the world and its
  initial mark (7).

## Commands

```zsh
SCRATCH=<scratch>; git worktree add $SCRATCH/m4 9922977
(cd $SCRATCH/m4 && swift build -c release --product kajo)
swift build -c release --product kajo --scratch-path .build/bench
# oldheap at 256 and 512 MiB: oldheap64.kasm with 64 -> N and 16000000 -> N * 250000
SCRATCH=$SCRATCH zsh ab.sh        # barrier A/B against module 4
SCRATCH=$SCRATCH zsh alwayson.sh  # flag never cleared, marking continuously
SCRATCH=$SCRATCH zsh matrix.sh    # the oldheap matrix
SCRATCH=$SCRATCH zsh storm.sh     # the alloc storm
python3 agg.py label,kernel,workers ms,checksum,... matrix.txt   # medians (min-max)
for i in $(seq 12); do gtimeout 900 yes > /dev/null & done; swift test; pkill -x yes
swift test --sanitize=thread --scratch-path .build/tsan-check
just ios-check; just arc-check; just golden; just test-release; just soak
```

The scripts (each prints one `key=value` line per run with the load
average):

```zsh
# ab.sh
K=/Users/katis/code/kajo/Tests/KajoVMTests/Fixtures/kernels
M4=$SCRATCH/m4/.build/release/kajo; M5=/Users/katis/code/kajo/.build/bench/release/kajo
for kernel in ivars fib alloc; do files=($K/prelude.kasm $K/lib.kasm $K/$kernel.kasm)
  for r in 1 2 3 4 5; do
    echo "label=m4 kernel=$kernel run=$r $($M4 run $files --workers 1)"
    echo "label=m5 kernel=$kernel run=$r $($M5 run $files --workers 1)"
    echo "label=m5stw kernel=$kernel run=$r $($M5 run $files --workers 1 --gc stw)"
  done; done
# alwayson.sh: per kernel (ivars, oldheap64 --heap 192, alloc), workers 1 and 8,
#   five runs of: $M5 run $files --workers $w --heap $heap --slice-ms 0 [--stress alwayson|alwayson,cycle]
# matrix.sh: per N in 64 256 512, workers 1 and 8, five runs of
#   $M5 run prelude lib oldheap oldheapN --workers $w --heap $((2*N+64)) --slice-ms 0 --gc stw|cm,
#   then one with --gc cm --verify
# storm.sh: per old space 64 and 256, N 1 and 2, five runs of
#   $M5 run prelude lib alloc --workers 8 --heap $heap --age $N --slice-ms 0 --gc stw|cm
```
