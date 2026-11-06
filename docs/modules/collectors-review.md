# Follow-up: the collectors review

Status: built, 2026-11-06, from the brief of the same day: nine findings of
an external, multi-agent review of `Sources/KajoVM/{ObjectMemory,Nursery,
Marking,Relocation,YoungCollection}` at d70cda2 (the bench baseline; the
Swift sources of 78d4659, where this work started, are the same). Six are
bugs, three are duplication. Every bug is fixed with a test that fails
without the fix (or, for a broken variant that traps, a hand run recorded
below), and each was followed by a look beside it for the same shape;
what that found is in each section. Code in `Sources/KajoVM/` (the
primitives that read slots, `Relocation/Hazard.swift`, `Marking/`,
`Workers/RecordRing.swift` (new), the logs of `Nursery/`, `Marking/`,
`Relocation/`, `YoungCollection/` and `Workers/`, `ObjectMemory/Reshape.swift`,
`ObjectMemory/ObjectMemory.swift` and `VirtualMemory.swift`,
`Loader/Image.swift`, `Loader/FuzzEntry.swift`, `Headless.swift`),
`Sources/KajoShellCore/` (the apps' log capacity) and
`apps/KajoShell-macOS/Sources/DevViews.swift` (since module 11a
`Sources/KajoApp/AppKitViews.swift`). Tests in
`Tests/KajoVMTests/Marking/WeakMarkingTests.swift`,
`ObjectModel/ExtremeIntegerTests.swift`,
`YoungCollection/BarrierWordTests.swift`, `Workers/LogRingTests.swift`,
`Workers/RandomPrograms.swift` (a configuration),
`ObjectMemory/ReshapeOrderTests.swift`, `ObjectMemory/ReservationTests.swift`,
`Tests/KajoCompilerTests/RedefineOrderTests.swift` and a changed
`CompilerTests` case.

## 1. A lost object through the array copy, and beside it

### The mechanism

Confirmed as the brief describes it. Primitive 38
(`replaceFrom:to:with:startingAt:`, `primReplace` and its loop `copySlots`)
takes a weak source: a weak class is of kind variable, so it passes
`!om.isBytes(src)`. The loop recorded the receiver's overwritten value
(SATB) and remembered young values, and read the source with a plain
relaxed load. While a cycle marks, the marker never traces weak slots
(module 5), so a referent held only weakly at the snapshot that a program
copies out of a WeakArray into an object the marker has already scanned,
or into a new object it never traces, stays unmarked: the verifier
reports it missed, or (when nothing strong reaches it) the sweep frees it
under a live weak slot of the new object. `at:` and the symbol table's
lookups had the keep-alive read barrier (`weakReadBarrier`); nothing else
did. The standalone interpreter's branch has no VM and so no marking;
nothing to fix there.

### What was built

`keepAliveRead` (`Marking/SATB.swift`): one relaxed load of the barrier
word and, when it is set, `weakReadBarrier` (format, slot index, phase).
`at:` calls it as before; so do now `instVarAt:` (91), `slotAt:` (117),
`shallowCopy` (96, for a weak receiver: its copy is weak and new, and the
final mark never nils a new object's weak slots) and the symbol table's
bucket growth. `copySlots` decides once per call (the loop never polls, so
the phase cannot change inside it): while a cycle marks it calls
`copyKeepAlive` out of line, which returns at once unless the source is
weak and otherwise records the referent of every weak slot the copy will
read, before the copy. The copy loop itself is the starting commit's. A
slot another worker overwrites between that pass and the copy holds a value
the other worker obtained, so it is marked, new, or kept alive by that
worker's own barriered read. The first version checked each slot inside
the loop (one compare per slot); with a cycle marking that cost the copy 7
percent (352 against 330 ms), and the pass removed it (Measurements). The
test switch `noWeakKeepAlive` turns every one of these off.

### The tests

- `aWeakReferentCopiedOutDuringMarkingIsKeptAlive` (the marking suite,
  beside module 5's `aWeakReferentReadDuringMarkingIsKeptAlive`, four
  arguments): a referent A held only weakly at the snapshot is read during
  marking and ends in H, a holder the marker has scanned, through
  `replaceFrom:to:with:startingAt:`, `instVarAt:`, `slotAt:`, or inside a
  `shallowCopy` of the weak bag. With the barrier A survives the cycle and
  the verifier misses nothing; with `noWeakKeepAlive` every route loses A
  (missed by the verifier, or freed under the copy's slot). At the starting
  code all four fail with the barrier on.
- `aSymbolCopiedIntoAGrownBucketDuringMarkingIsKeptAlive`: four Symbols
  fill a new bucket; a cycle starts and marks; a fifth Symbol of the same
  bucket grows it while the cycle marks. Without the barrier the grown
  bucket names freed entries after the sweep (fails at the starting
  code).

### Beside it: every read of a slot a program could make weak

A program makes an object weak by its class (`weak` format: the indexed
slots are weak, named slots strong). Every primitive and VM path that
reads an indexed slot of an object and hands the value on:

| path | reads a weak slot? | status |
|---|---|---|
| `at:`, `basicAt:` (primitive 1) | yes | barrier (module 5) |
| `instVarAt:` (91) | yes, named and indexed | **fixed**: barrier |
| `slotAt:` (117, any object) | yes | **fixed**: barrier |
| `shallowCopy` (96) | yes, into a new weak copy | **fixed**: barrier on a weak receiver |
| `replaceFrom:to:with:startingAt:` (38) | yes, the source | **fixed**: the copy loop's check |
| the symbol table's lookups (`asSymbol`, `Symbol lookup:`, interning) | yes | barrier (module 8b) |
| the symbol table's bucket growth (`insertSymbol`) | yes, into a new bucket | **fixed**: barrier (found beside the copy) |
| `valueWithArguments:` (84), `perform:withArguments:` (89), `valueWithReceiver:arguments:` (85) | no: the argument must be an `Array` (`isArray`: class index exactly Array, not weak) | covered |
| the debugger's `primResend:` (156) | no: `Array` only | covered |
| `at:put:`, `instVarAt:put:` and every store | no read handed on; the overwritten value is recorded (SATB) | covered |
| `Context tempAt:` (101), `BlockClosure copiedValueAt:` (116) | no: Contexts and closures are not weak | covered |
| `become:` (8), `becomeForward`, reshape and redefine (146), class removal (147) | in a stop after module 4's hook, which abandons marking | covered |
| the snapshot writer and the save primitive (142) | the same hook first | covered |
| ephemeron keys and values (`instVarAt:` on an ephemeron) | not weak slots: an unfired ephemeron whose key is unmarked at the final mark fires and is traced, key included, so a key read during marking survives the cycle | covered |
| the define, redefine and remove specifications, the make primitive's code graph (143), pragma arguments | `Array` (or the code class) only | covered |
| `emitEvent:fields:` (140), the view hop's arguments (150), the protocol's replies (161) | `Array` only, and the values become Swift values, not oops | covered |
| the protocol's `inspect` (`DevSession`) | in Smalltalk, named slots through `slotAt:` and indexed ones through `basicAt:` (primitive 1); a handle holds its object strongly | covered (`slotAt:` by the fix above) |
| module 7's young collections | weak slots are strong in a young collection (v0) | covered |
| the stop-the-world scavenge, module 1's collection | the world is stopped | covered |
| the host (`vm.inspect`, `setGlobal`) | a host read in a stop that the host stores back is not a Smalltalk path; `setGlobal` records the overwritten value only | not changed (no host code does it) |

## 2. A trap from Smalltalk: arithmetic before the bounds check

### The mechanism

Confirmed. `primReplace` computed `stop - start + 1`, and later
`from + n - 1`, with trapping arithmetic before checking the bounds;
SmallIntegers are 62-bit, so `replaceFrom: SmallInteger minVal to:
SmallInteger maxVal with: x startingAt: 1` overflowed Int64 and the VM
died with SIGTRAP. Beside it, `basicNew:` of a word class (`words16`,
`words32`, `words64`) multiplied the count by the element size before
checking the count: `W64 new: SmallInteger maxVal` trapped the same way.

### What was built

`primReplace` checks `start` in 1 to count + 1, `stop` in start - 1 to
count, then computes `n` (0 to count) and checks `from` against the
source's count less `n`; the answers are the same as before for every
argument that did not trap (an empty range at a valid start answers the
receiver whatever `from` is). `basicNew:` checks the count against the
count field's limit before multiplying.

### The audit

Every primitive that takes a SmallInteger argument, read for arithmetic
or a trapping conversion (`UInt64(_:)`, `Int32(_:)`, `UInt8(_:)`) before
the argument is validated: `at:` and `at:put:` (1, 2), `basicNew:` (3,
**fixed**), `//` and `\\` (6, 7: `|a| < 2^62`, so no quotient or product
overflows), `globalAt:` and `globalAt:put:` (14, 15), `delay:signal:`
(25), the array copy (38, **fixed**), the integer operations (40 to 57:
`+`, `-` exact in Int64 for 62-bit operands, `*` with
`multipliedReportingOverflow`, the shift bounded at 2^16), `timesTwoPower:`
(73, bounded at 4096), `Character value:` (77), `instVarAt:` and
`instVarAt:put:` (91, 92), the Context and closure slots (101, 102, 116),
`slotAt:` and `classAt:` (117, 118), the String primitives (124 to 136:
`Int(truncatingIfNeeded:) &- 1` and checks before any sum), the view
release (152), the debugger's interrupt kind (155, compared before
converting), the test primitive `slowPeek:` (39), the class definition
primitives' counts (145 to 147, checked non-negative first), and the
host's `ClientHost` timer (bounded at an hour). The interpreter's inline
`add`, `sub` and `mul` use the reporting-overflow operations. Two traps
from Smalltalk were found in the Mac shell's view wrappers, the host side
of primitive 150: `setRowCount` allocated an array of any count (a
SmallInteger maxVal is an allocation failure, a trap), and `setPosition`
passed any divider index to `NSSplitView`; both now refuse what they cannot
hold (a primitive failure). There are no stream primitives; the
LargeInteger primitives go through `BigInt`.

### The tests

- `everyPrimitiveAnswersExtremeIntegerArguments`: 840 calls, every
  primitive above that takes an integer (and receivers of the kinds it
  takes: an Array, a ByteArray, a String, the word classes, a Context, a
  closure, the integers themselves), with minVal, maxVal, -1, 0 and the
  receiver's count + 1 in every integer argument, all combinations; every
  call must answer (the fallback answers nil). At the starting code the
  test process dies with SIGTRAP (signal 5); with only one of the two
  fixes it still does, either way.
- The syntax fuzzer's make-and-run mode runs each made method a second
  time with an extreme SmallInteger (minVal, maxVal, -1 or 0, chosen by
  the bytecodes' length) for every argument, and the syntax corpus gains
  three method seeds that reach primitives 2 and 38 and the arithmetic
  with such arguments (`extreme-*.st`); `compiledMethodsAreMadeAndRunThroughThePrimitive`
  runs them.

## 3. Unbounded logs

### The mechanism

Confirmed: every scavenge (`NurseryLog.records`), young collection and
round (`YoungLog.records`, `.rounds`, the first under the safepoint
mutex), marking cycle (`MarkingLog.records`) and relocation cycle
(`RelocatorState.records`) appended a record to a Swift array nothing
trimmed, and so did every main-thread hop (`SchedulerState.hopLatencies`,
under the scheduler lock). A scavenge record also held two Swift arrays.
The promotion samples (`MarkingLog.samples`, module 7's sampler) are
bounded by `MarkingConfig.rateWindow` already; the stop log is a ring of
65 536 (module 3); the per-collection work lists are emptied by each
collection; the shell's event queue holds only events the image has not
taken (frames are posted only when the image asked for them). One more
unbounded list: the object memory's recorded verifier reports, kept for
every failure in `.record` mode (the release default).

### What was built

`RecordRing` (`Workers/RecordRing.swift`): the last `capacity` records;
the storage grows by appending until full and then overwrites in place,
so an append under a mutex never allocates once the ring is full; readers
copy the records out into a new array, so an overwrite never copies the
storage either; records are plain values (the scavenge record now holds
the participants' sums), so an overwrite releases nothing. Beside each
ring, running totals of what the reports sum, average or take the
maximum of (`ScavengeTotals`, `CycleTotals`, `YoungTotals`, the relocation
cycles that selected a block) and the dropped count. The capacity is
`VMConfig.logCapacity`, 65 536 by default (the stop log's size): every
record of the measurement runs (a 10 s shell scenario, the bench, the
soak) is kept, so their reports read what they read before. The shells'
demo and developer modes, apps that run for days, take
`Headless.Options.appLogCapacity` (4096; `logs=` overrides). `kajo run`'s
report and the shells' `gc_` keys take sums and means from the totals and
percentiles from the records kept, and print `scavLogDropped`,
`cycleLogDropped`, `relocLogDropped`, `ycLogDropped` and
`roundLogDropped`. The marking log's current cycle is a sequence number
into its ring. Recorded verifier reports stop at a thousand (the counter
counts every failure).

### The tests

- `aRecordRingKeepsTheLastRecordsAndStopsGrowing`: 1003 records into five
  slots keep the last five in order, drop 998, and the storage's
  allocated capacity does not grow after the ring is full, also after a
  reader copied the records out.
- `theScavengeAndCycleLogsKeepTheirCapacityAndTotalEveryRecord` (a
  capacity of 8, stop-the-world scavenges, twelve cycles and a churn): the
  scavenge log holds 8 consecutive records ending at the last scavenge,
  the totals count every scavenge and the dropped count is the rest; the
  cycle log holds the last 8 completed cycles and drops 4; the reports'
  `scavLogDropped` and `cycleLogDropped` say so.
- `theYoungCollectionAndRoundLogsKeepTheirCapacityAndTotalEveryRecord`
  (local young collections): the same for collections and rounds.

## 4. Marking erased module 7's bits of the barrier word

### The mechanism

Confirmed. Module 5 stored the whole word (`store(BarrierBits.marking)` at
the initial mark and at install under `markingAlwaysOn`, `store(0)` at the
final mark, the abort and the uninstall) while module 7 keeps a count in
bits 1 and up (+2 per open collection, +2 for the VM under the young
stress flag `barrierAlwaysOn`). Under that flag the first initial mark set
the word to 1 and the final mark to 0: from the first cycle on, a store
took the young deletion barrier's slow path only while a collection was
open, which is the case the flag exists to go beyond. At the VM's end
young's uninstall (first) subtracted 2 from 0 or 1 and wrapped, before
marking's uninstall stored 0.

**No schedule lets a marking store land while a collection is open**, so
the bug never lost a deletion record: marking writes the word only in
stops (the initial mark, the final mark, the abort) and at the VM's
install and end (no worker running); `stopWorld` waits, under the
safepoint mutex, until `ycActive` is 0 before it sets `requested`
(`waitForCollectionsLocked`), and `openYoungCollection` waits, under the
same mutex, while a stop is wanted or requested. The young-collection
model (`docs/models/young-collection.md`) has the barrier word as module
7's count only; marking's bit is not in it, and its note now says why
(the stop and the opening exclude each other under the mutex, which the
model does have as `stwWanted`).

### What was built

Marking sets and clears bit 0 alone (`markingBarrierOn`/`Off`, an atomic
`or` and `and`), so even an overlap could not erase the count. The stop
verifier (`verifyBarrierWordLocked`, every stop with `verifyStops`)
checks that bits 1 and up equal the open collections (none at a stop) plus
the stress flag, and that bit 0 is set exactly while a cycle marks (or
under `markingAlwaysOn`). A counter, `deletionBarrierCalls` (module 7's
worker counters), counts the stores that took the young slow path.

### The tests

- `markingKeepsModule7sCountInTheBarrierWord`: under `barrierAlwaysOn`
  the word is 2, 3 while a cycle marks, 2 after it and after a cycle
  abandoned by module 1's collect, and stores after the cycle take the
  young slow path (the counter grows). At the starting code: 1, then 0,
  and the counter does not move.
- `theStopVerifierChecksTheBarrierWord`: a stray count bit set by hand is
  reported at the next stop.
- The random programs' new configuration `youngBarrierAlwaysOn` (local
  young collections, the stress flag, a marking cycle at every scavenge,
  perturbation, four workers): every seed's stores took the young slow
  path, cycles ran, and every run asserts no stop verifier failure (an
  assertion every configuration now has). At the starting code the
  configuration fails it (10 seeds run by hand).

## 5. Reshape listed instances before the old-space hook

### The mechanism

Confirmed in module 1's `prepareReshape`: it listed every instance with
`allInstances` and then ran `prepareOldSpaceOperation`, whose promote-all
scavenge frees the dead young instances (and whose applied lazy sweep
frees the dead old ones); the plan then read a freed entry's header and
`commitReshape` gave the freed entry a body. The redefine primitive (146)
cannot reach it today: `redefine` runs the hook itself (LiveClasses.swift,
before the running-frame rule) before anything lists instances, and
nothing between that and `prepareReshape` makes an instance of a class
being reshaped (it makes methods, dictionaries and pools) or a pending
sweep (the marker cannot sweep while the world is stopped), so nothing the
second hook frees was listed. Module 1's own `reshape` (the host's, and the tests') was
reachable.

### What was built

`prepareReshape` runs the hook before it lists anything; the checks that
follow still throw before anything a program can see changes (a
promote-all and the apply of a finished sweep are not such changes).

### Beside it

The other module 1 operations run the hook before they read what it may
free (`collect`, `compact`, `trySnapshot`, the class removal). Two read
before it, safely: `becomeExchange` checks its two arguments, which are
on the caller's stack (roots); `becomeForward` builds its table from its
arguments, and its one VM caller (redefine) has run the hook already and
passes every root.

### The tests

- `aReshapeWithDeadYoungInstancesReshapesOnlyTheLiveOnes`: 100 live and
  20 dead young Pairs, module 1's reshape in a stop: 100 reshaped, all
  old with three slots. At the starting code the test process dies with
  SIGSEGV (signal 11).
- `aRedefinitionWithDeadYoungInstancesAndAPendingSweepReshapesOnlyTheLiveOnes`
  (KajoCompilerTests): a class defined at run time with three live
  instances, a fourth made old and dropped, a cycle whose sweep frees it
  left pending, two dead young instances, then the redefine primitive:
  three instances reshaped, no verifier failure. Passes at the starting
  code too (the path above).

## 6. Reservations leaked on a partial failure

### The mechanism

Confirmed: `ObjectMemory.init` released only the heap when the entry
table, the mark bytes or the old map failed to reserve, so the entry table
(16 bytes per entry, up to 64 GiB of address space) and the mark bytes
leaked. The other initializers that reserve hold one reservation each
(`BlockHeap` its aliased range, `EntryBitmap`, the nursery's remembered
words, module 7's scan words, module 5's snapshot map; the last three trap
on failure). `VirtualMemory.reserveTwice` kept its range and memory entry
on an unreachable path (a zero address after a successful `mmap`).
Beside it: `Image(memory:)` throws when the heap or the entry table cannot
hold the well-known objects, and every caller passes a memory nothing else
names (`Image(memory: ObjectMemory(config))`), so that memory leaked whole.

### What was built

The initializer releases what it reserved, in reverse order, before it
rethrows; `reserveTwice` releases on its last failure too; the Image owns
the memory it is given and destroys it when its boot fails. A test probe,
`ObjectMemoryConfig.reservations` (`ReservationProbe`), records every
reservation and release the object memory makes and can refuse the n-th.

### The tests

`aFailedReservationReleasesTheOnesBeforeIt` (the first to the fourth
refused: none left reserved; with the starting code's release logic the
third leaves the entry table and the fourth the entry table and the mark
bytes), `anObjectMemoryReleasesEveryReservation`,
`anImageWhoseBootFailsReleasesItsMemory` (an entry table of 64: four
reservations, none left; without the Image's release four left).

## 7 to 9. Duplication

- **7**: the young allocation's slow path sizes a body with
  `ObjectMemory.bodyBytes`; the inline fast paths keep their literals.
- **8**: one pair of cache-line helpers, `lined` and `unlined`
  (`Workers/VMState.swift`), for modules 3 to 7. There were four copies:
  the brief's three and module 3's `boxed`, which rounded a value larger
  than a line up to one line only, so its last line could be shared;
  `lined` rounds up to whole lines.
- **9**: one copy loop, `copyBody` (`Relocation/Relocator.swift`), for the
  relocator and module 7's collector. In the aligned release build the
  loop is the same five instructions (`ldr`, `str`, `add`, `cmp`, `b.lo`)
  for both; the relocator's old `relocCopy` loaded the heap base from the
  relocation state in its prologue, `copyBody` gets it in a register, and
  the relocator's two call sites pass the object memory in `x0` to `x2`
  (`relocatePass` 544 and `relocateOne` 146 instructions before and
  after). `Collector.evacuate` grew from 373 to 381 instructions: eight
  register moves around the `sched_yield` of its claim spin, a cold path;
  the copy and the per-object path are unchanged. `just arc-check` names
  `copyBody` under the relocator's object now.

## Measurements

### The kernels against the starting commit

d70cda2's `kajo` (from a worktree) against 402cf28's (the last code
commit), both built `-c release -Xswiftc -enable-testing` with
`-align-all-nofallthru-blocks=5 -align-loops=32`; five runs interleaved,
the order alternating by run, `--slice-ms 0`, 2026-11-06 08:51 to 08:54
(load average 14 falling to 11: Spotlight's updater ran throughout);
median (min to max) ms; every checksum equal on both sides, and the
published kernels' equal to the published ones. `arraycopy` is a kernel of this review (160 000
copies of a 1024-slot Array with `replaceFrom:to:with:startingAt:`,
split between workers; not committed, in the gate outputs' `bench/`):
plain with `--gc stw` (no marking), and `arraycopy-marking` with
`--stress cycle,alwayson` (the barrier word's marking bit always set, so
every copied slot takes the SATB branch; no cycle starts, since the kernel
allocates nothing after its setup).

| kernel | workers | d70cda2 ms | now ms | now / start | checksum |
|---|--:|--:|--:|--:|---|
| fib | 1 | 1686.1 (1682 to 1692) | 1687.7 (1685 to 1690) | **1.001** | 24682992 |
| fib | 8 | 225.0 (218 to 234) | 223.9 (222 to 238) | **0.995** | 24682992 |
| arith | 1 | 2525.8 (2522 to 2534) | 2531.8 (2526 to 2538) | **1.002** | 372800000 |
| arith | 8 | 343.2 (337 to 355) | 347.3 (337 to 351) | **1.012** | 372800000 |
| sends | 1 | 2580.6 (2560 to 2602) | 2569.0 (2565 to 2572) | **0.996** | 1066666666666668 |
| sends | 8 | 351.3 (340 to 359) | 339.1 (331 to 360) | **0.965** | 133333335000001 |
| ivars | 1 | 1961.6 (1958 to 1965) | 1958.9 (1956 to 1960) | **0.999** | 36383626 |
| ivars | 8 | 263.1 (252 to 279) | 261.0 (252 to 271) | **0.992** | 71714128 |
| storeheavy | 1 | 2390.4 (2390 to 2396) | 2393.2 (2384 to 2395) | **1.001** | 512000 |
| storeheavy | 8 | 309.3 (307 to 334) | 319.2 (313 to 338) | **1.032** | 512000 |
| alloc | 1 | 2931.3 (2924 to 2950) | 2902.5 (2900 to 2920) | **0.990** | 41950911 |
| alloc | 8 | 489.9 (476 to 514) | 500.7 (474 to 549) | **1.022** | 42008248 |
| survivors30 | 1 | 1938.7 (1937 to 1975) | 1943.4 (1942 to 1954) | **1.002** | 38399861600000 |
| survivors30 | 8 | 305.4 (289 to 319) | 315.3 (292 to 324) | **1.032** | 4799861600000 |
| arraycopy | 1 | 202.5 (202 to 211) | 203.5 (202 to 208) | **1.005** | 524800 |
| arraycopy | 8 | 34.0 (32 to 38) | 32.8 (31 to 36) | **0.965** | 4198400 |
| arraycopy-marking | 1 | 319.1 (312 to 321) | 313.2 (310 to 321) | **0.982** | 524800 |
| arraycopy-marking | 8 | 48.5 (45 to 54) | 44.9 (45 to 52) | **0.926** | 4198400 |

One worker 0.990 to 1.005, eight workers 0.926 to 1.032, every pair of
ranges overlapping except `alloc` on one worker, where the new binary is
the faster (2900 to 2920 against 2924 to 2950): within noise. `storeheavy`
on eight workers, 1.032, overlaps (313 to 338 against 307 to 334); the
store path's code is unchanged (Hot path).

### The array copy with a cycle marking

`kajo run` cannot hold a cycle in its marking phase, so a release test
(`measureTheArrayCopyUnderMarking`, the same kernel on one worker, the
marker stepped by hand so the phase stays `marking` for the whole run, run
in a worktree of each commit and not committed) measured it: ten runs of
each binary, interleaved, 2026-11-06 08:55 (load average 10):

| | d70cda2 ms | 402cf28 ms | ratio |
|---|--:|--:|--:|
| no cycle | 203.6 (197 to 210) | 202.6 (201 to 209) | 0.995 |
| a cycle marking | 327.6 (317 to 338) | 331.1 (324 to 336) | 1.011 |

Marking itself costs the copy about 60 percent (the SATB record of every
overwritten slot, as before); this review adds nothing measurable to it.
The first version, with the weak check inside the loop (67fdfff),
measured 352.4 against 330.0 ms (1.068) in the same harness, which is why
the check became a pass of its own (402cf28).

## Broken variants run by hand

Each on the final code with one fix taken out, by hand (the suite cannot
hold a trap):

| variant | run | result |
|---|---|---|
| `primReplace`'s bounds as at d70cda2 | `everyPrimitiveAnswersExtremeIntegerArguments` | the test process dies, signal 5 (SIGTRAP, the arithmetic overflow) |
| `basicNew:`'s multiplication before the check | the same | signal 5 |
| `prepareReshape` lists before the hook (d70cda2's `Reshape.swift`) | `aReshapeWithDeadYoungInstancesReshapesOnlyTheLiveOnes` | signal 11 (SIGSEGV) |
| marking stores the whole barrier word (d70cda2's four marking files) | `markingKeepsModule7sCountInTheBarrierWord`; 10 seeds of `youngBarrierAlwaysOn` | the word is 1 then 0, the young slow path stops, the stop verifier fails; every seed run fails `stopVerifierFailures == 0` |
| `ObjectMemory.init` releases only the heap | `aFailedReservationReleasesTheOnesBeforeIt` | the third and fourth refusals leave reservations |
| the Image does not destroy its memory | `anImageWhoseBootFailsReleasesItsMemory` | four reservations left |
| no keep-alive in the copy, `instVarAt:`, `slotAt:`, `shallowCopy`, bucket growth (d70cda2's sources) | the two new marking tests | every route loses its referent |

## Unsafe surface

`unsafe` in `Sources/KajoVM`: 5074 at d70cda2, 5095 now (139 on added
lines, 118 on removed ones: the ring's owners, the barrier word's helpers
and verifier, the reservations' release, the copy's pass; the removed
copies of the cache-line helpers). None in `KajoShellCore` changed (21),
none in the apps. Counted with `git grep -o -w unsafe` over the sources
(comments included); the clean build has 0 warnings (Gates).

## Hot path

From the aligned `-enable-testing` release binaries of the A/B:

- **`interpret`** is the same code: 1320 instructions, four lines
  differing only in an `adrp` page number.
- **The array copy**: `copySlots` 284 to 300 instructions, all sixteen in
  its prologue (the phase test and the call to the pass); its per-slot loop
  is the same instruction sequence. `primReplace` 297 to 257 (the bounds
  checked one by one).
- **`copyBody`** 10 instructions, the same five-instruction loop the
  relocator's `relocCopy` and the collector's `copyBody` each had;
  `relocatePass` 544 and `relocateOne` 146 instructions before and after;
  `Collector.evacuate` 373 to 381, the eight in the cold `sched_yield` of
  its claim spin.
- **`weakReadBarrier`** 81 to 87 (out of line, as before); `at:` calls it
  through the inlined `keepAliveRead`, the same test as before.
- **The young collection's log append** is out of line (`logCollection`,
  as `logRound` was), so no ring code is in a collection's path.
- `just arc-check` passes (Gates): no retain or release on the checked
  paths, one jump table; it names `copyBody` under the relocator's object.

## Changes to earlier modules

- Module 1: `prepareReshape`'s order; `ObjectMemory.init`'s release;
  `ReservationProbe` and `ObjectMemoryConfig.reservations`;
  `VirtualMemory.reserve`/`release` and `reserveTwice` take the probe; the
  recorded verifier reports stop at 1000.
- Module 3: `lined`/`unlined` replace `boxed`/`unbox`; the hop latencies
  are a ring; `VMConfig.logCapacity`; the stop verifier checks the barrier
  word.
- Module 4: `ScavengeRecord` holds sums; `NurseryLog` a ring and totals;
  `bodyBytes` in the slow path.
- Module 5: `markingBarrierOn`/`Off`; `keepAliveRead`; `MarkingLog` a ring,
  `CycleTotals`, the current cycle by sequence number.
- Module 6: `copySlots`' keep-alive pass; `primReplace`'s bounds;
  `copyBody` replaces `relocCopy`; the relocation log a ring.
- Module 7: `YoungLog`'s rings and `YoungTotals`; `deletionBarrierCalls`;
  `logCollection`.
- Module 8: `instVarAt:`, `slotAt:`, `shallowCopy` and the symbol bucket
  growth keep weak referents alive; `basicNew:`'s check; the Image owns
  the memory it boots in; the make-and-run fuzz mode's extreme argument.
- Module 9a/9c: the shells' demo and developer modes keep 4096 records;
  the Mac shell's `setRowCount` and `setPosition` refuse what they cannot
  hold.
- `kajo run`'s report: the sums from the totals and the `...LogDropped`
  keys.

## Deviations from the brief

- **The array copy's keep-alive is a pass before the copy**, not a test
  inside the loop: the first version's per-slot check cost the copy 7
  percent with a cycle marking. The pass reads a weak source twice while a
  cycle marks; every other copy runs the starting commit's loop.
- **Finding 1's audit found one more lost-object path** (the symbol
  table's bucket growth) and **finding 2's two more traps**, in the Mac
  shell's view wrappers rather than in a primitive; finding 6's look beside
  it found the Image's boot.
- **There was no `barrieron` configuration in the soak**: the random
  programs had none, so `youngBarrierAlwaysOn` is new, and with it the
  assertion of no stop verifier failure in every configuration.
- **Finding 8 had four copies**, not three: module 3's `boxed` is folded in
  (it rounded a larger value to one line only).
- **The apps' capacity applies to the demo and developer modes** only; the
  scenario, tests, golden, `devsession` and `serve` modes are measurement
  runs and keep the default, so `scripts/shell-report.py` reads what it
  read.
- **Finding 9's sharing changed the relocator's call sites** (the object
  memory passed in three registers instead of the relocation state in
  one); both functions keep their instruction counts and the loop is the
  same, so the brief's condition held and the sharing stays.

## Not done

- The shell's event queue is not bounded: it holds the events the image
  has not taken, and an image that never takes them (no event loop, with
  frame events asked for) grows it. A bound needs a policy for what to
  drop that the image can see; it is not a collector log.
- Host code that reads a weak slot in a stop (`vm.inspect`) and stores
  the value back is not barriered; no host code does.
- The phase-marking array copy was measured with the marker stopped by
  hand (a test), not in a shell scenario.

## Open questions for the owner

1. The shells' apps keep the last 4096 records of each log (about 2 MB in
   all) and the measurement modes 65 536. Is 4096 the right size for an
   app that runs for days, or should the developer UI keep more (its
   collectors view, when it has one, reads them)?
2. The random programs now assert no stop verifier failure in every
   configuration. The stop verifiers' other check (no parker left its park
   while the stop's work ran) was already counted but never asserted
   there; it held in every run so far. Keep the assertion general?
3. The syntax fuzzer's make-and-run mode runs each made method twice now
   (3, then an extreme SmallInteger), and the gate's run made 0.64 million
   inputs in 600 s against 0.89 to 2.26 million before. Keep both runs, or
   run one, choosing 3 or an extreme value per input?

### The owner's answers (2026-11-06)

1. Not answered as asked; the owner asked what the records are. The main
   session's recommendation stands until a tool reads them: 4096 in the
   apps, since the totals lose nothing.
2. **Keep the assertion** in every configuration.
3. **Keep both runs.**

## Gates

Run by one script on d1ecb7d (402cf28's code; the commits after it are
docs only), Mac mini M2 Pro, swift.org Swift 6.4.2 first on PATH, Xcode for the
apps, 2026-11-06 08:55 to 11:36; full output in one file per gate and the
commit each ran on in `gates.log`. "Load" is twelve `gtimeout 1500 yes`
busy loops (they end after 25 minutes, so the last 27 minutes of the
ThreadSanitizer run under load, the compiler tests, ran without them).

| gate | result |
|---|---|
| clean build (`swift build --scratch-path .build/clean-check`) | pass: 0 warnings (12 s from an empty scratch path: the toolchain's compilation cache, as in 8e; the strict-memory-safety typecheck of `just ios-check` below has 0 warnings) |
| `swift test` | pass: 352 tests (KajoVMTests) and 85 in 16 suites (KajoCompilerTests) |
| `swift test` under load | pass: 352 and 85 |
| `swift test --sanitize=thread` | pass: 352 and 85, 0 ThreadSanitizer reports |
| the same under load | pass: 352 and 85, 0 ThreadSanitizer reports |
| `just ios-check` | pass: 0 warnings |
| `just arc-check` | pass: 133 functions with no retain or release, one jump table |
| `just golden` | pass: 9 kasm and 3 Smalltalk kernels, every checksum |
| `just test-release` | pass: 352 and 85 |
| `just model-check` | pass: 28, 5 and 15 tests (three targets) |
| `just soak` | pass: 1000 seeds under each of the 21 configurations (`youngBarrierAlwaysOn` included) and the 6 resumed modes, failing none |
| `just fuzz kasm 600` | pass: libFuzzer build ok, 2 463 440 runs, no crash |
| `just fuzz snapshot 600` | pass: libFuzzer build ok, 2 353 403 runs, no crash |
| `just fuzz syntax 600` | pass: libFuzzer build ok, 641 710 runs, no crash (each made method now runs twice, the second time with an extreme argument; earlier gates ran 0.89 to 2.26 million) |
| `just fuzz protocol 600` | pass: libFuzzer build ok, 1 546 465 runs, no crash |
| `just apps` | pass: macOS and iOS, 0 errors, 0 warnings |
| `just kernel-test` | pass: 202 of 202 |

## Commands

```zsh
# the new tests
swift test --filter 'aWeakReferent|aSymbolCopied|everyPrimitiveAnswersExtreme|BarrierWord|RecordRing|KeepTheirCapacity|aReshapeWithDeadYoung|aRedefinitionWithDeadYoung|aFailedReservation|anObjectMemoryReleases|anImageWhoseBoot'
KAJO_SEEDS=100 KAJO_RANDOM_ONLY=youngBarrierAlwaysOn swift test --filter randomProgramsAgreeWithTheirModel
# the A/B: a worktree at d70cda2, both binaries aligned
A2=(-Xswiftc -enable-testing -Xswiftc -Xllvm -Xswiftc -align-all-nofallthru-blocks=5 -Xswiftc -Xllvm -Xswiftc -align-loops=32)
(cd $S/start && swift build -c release --product kajo --scratch-path .build/bench-a2 $A2)
swift build -c release --product kajo --scratch-path .build/bench-review1 $A2
zsh bench.sh $S/start/.build/bench-a2/release/kajo .build/bench-review1/release/kajo bench-ab.txt 5; python3 agg.py bench-ab.txt
#   bench.sh: for run 1..5, kernel, workers 1 and 8, both binaries (order alternating by run):
#   kajo run prelude lib <kernel> --workers $w --slice-ms 0; arraycopy with --gc stw or --stress cycle,alwayson
# the copy with a cycle marking: measureTheArrayCopyUnderMarking in a worktree of each commit
KAJO_MEASURE_COPY=1 swift test -c release --scratch-path .build/copy-measure $A2 --filter measureTheArrayCopyUnderMarking
zsh gates.sh    # every gate, outputs and the commit each ran on in files
```
