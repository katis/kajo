# Module 10: large objects

Status: built, 2026-11-05, from the brief of the same day (the owner's
answer to module 9c's first question, "Add large-object space", and the
owner's answers of 2026-11-04 to the vm-teardown follow-up). Code in
`Sources/KajoVM/ObjectMemory/LargeObjects.swift` (new) and the readers of
a body it touches in `ObjectMemory/` (`BlockHeap`, `Allocation`,
`Collector`, `Compaction`, `Verifier`, `Snapshot`, `OldMap`, `Reshape`,
`Header`, `Config`, `Generations`), `Marking/Marker.swift`,
`Relocation/Relocator.swift` and `RelocationVerifier.swift`,
`Interpreter/InterpreterState.swift` (`allocateAny`, `allocateLarge`), the
primitives that build objects of a size from Smalltalk, `Loader/ImageFile`
(format 5, the host save's refusal), `Nursery/YoungAllocation.swift` (the
VM's end) and `Sources/KajoDev/` (the request limit). The kernel loses
`LargeArray`. Tests in `Tests/KajoVMTests/ObjectMemory/LargeObjectTests.swift`,
`Tests/KajoVMTests/Marking/LargeObjectVMTests.swift`,
`Tests/KajoCompilerTests/VMEndTests.swift` and `kernel/LargeObjectTest`.

## What it hides

That the heap is cut into 32 KiB blocks. Until now no body spanned a block
(`Header.maxSlots`, 4095 slots or 32 760 bytes), and the kernel met the
limit three times (8b's sources table, 8e's symbol buckets, 9c's
2000-class image). Now `Array new: 1000000` and a 16 MB String are
ordinary objects: one entry, one header, one body, reached as every object
is. Nothing above the object memory knows a body may span blocks; the
interpreter, the barriers and the fast allocation paths are unchanged
instruction for instruction (Hot-path check). What changes is every reader
that walks blocks rather than entries.

## 1. A large object

- **Definition.** An object whose body does not fit one block: more than
  4095 slots, or more than 32 760 bytes (`Header.isLarge`, a count test).
  Its body is a **run** of contiguous blocks it owns alone: the **head**,
  where the body starts at the block's first word, and **continuations**.
  The body's first word is the back reference as for any body (entry index,
  size in words; 32 bits of words are 32 GiB), so the heap stays walkable.
  The limit is the header's count field, 24 bits: 16 777 215 slots
  (128 MiB) or bytes (16 MiB - 1, `Header.maxLargeCount`).
- **No header bit.** The brief asked to choose between the reserved header
  bit 51 and the count test: the count test, because no hot path needs to
  ask. The readers that care (verifier, sweeps, pool, compaction,
  relocator, snapshot) read the block's kind, not the header; the one that
  asks of an object (the verifier: "is this body where a large body must
  be") computes it from the count. Bit 51 stays reserved.
- **Old at birth, never moved.** A large object is allocated in old space,
  is never young and never copied by a scavenge, is never relocated (the
  relocator skips a run's blocks at selection) and never compacted
  (compaction treats a live run's blocks as it treats pinned ones: neither
  source nor destination). Its stores run the ordinary barrier: an old
  large object holding a young pointer is remembered like any old object.
- **The side table** (`BlockHeap.kind`, one byte per block): ordinary,
  head, continuation. A free block is ordinary and not in use. A run's
  head has `used` equal to the large body's bytes (past the block) and
  each continuation `used` 0, all in use; so a reader that walks a block
  from its start to its `used` walks the run's one body, and the snapshot's
  per-block bytes are the run's body, contiguous in the heap, without a
  special case. A run's blocks are never in the block pool. The kind is
  written under the pools lock (allocation) or with the world stopped
  (freeing, compaction, the loader), as `inUse` is.
- **Allocation** (`tryAllocateLarge`, out of line; `tryAllocateAny` picks
  the path by size): an entry from the context's free list, then under the
  pools lock a first fit over the block table for a stretch of free blocks
  (a free block is always in the pool, the free-list verifier's rule, so
  the stretch is taken out of the pool, its kinds set, the head last, and
  every block stamped with the current marking cycle's stamp), counted
  against the soft limit as a mutator's block refill is. The fill (nil, or
  zero for bytes; one relaxed store per word, as `initializeObject` writes
  every body) runs outside the lock on the allocating thread. When no run
  fits, the stop's policy is module 1's: a full collection, then a
  compaction (which packs the ordinary blocks below and between the runs),
  then once more; then the request fails. A large request that fails is a
  primitive failure (`Machine.allocateLarge` answers `.none` without
  recording a VM error), so `basicNew:` reports it: "cannot make an
  instance of Array with 100000000 slots: no room in the heap for a large
  object of that size", or past the count field "...: the largest object
  has 16777215". The interpreter's own allocations (push_new_array,
  closures, temp vectors, Contexts) fit a block by the bytecode verifier
  and keep `Machine.allocate`; the primitives whose size comes from
  Smalltalk or another object use `Machine.allocateAny`.
- **What it costs the frame budget.** Filling a 16 MiB body is 0.62 ms on
  the allocating thread (Measurements), and the thread does not poll while
  it fills: a stop requested meanwhile waits up to that long for it. On the
  main thread that is a thirteenth of a 120 Hz frame per 16 MiB allocated;
  a 128 MiB Array (the limit) would be about 5 ms. Nothing else on the path
  is proportional to the size: the first fit scans the block table (8192
  bytes of `inUse` for a 256 MiB heap) and the pool.
- **Marking** traces a large pointer object through its entry as any
  object. The concurrent marker scans its slots 4096 at a time
  (`traceChunk`): the rest goes back on the marker's stack as one item,
  the oop with the next chunk's number in bits 40 to 63 (an oop is an entry
  offset below 2^36), and a chunk counts 32 objects toward the marker's
  poll interval of 128. So the marker polls after at most four chunks
  (16 384 slots, 13 µs measured) however large the object. SATB keeps the
  split sound: a slot overwritten before its chunk is scanned is recorded
  by the deletion barrier, a new value is either reachable from the
  snapshot elsewhere or not a snapshot entry, and a large object never
  moves under the scan. The stop-the-world collector marks a large object
  whole (it is in a pause anyway).
- **The cycle's trigger watches large allocations.** Module 5 decides
  whether to start a marking cycle at the end of young collections; a
  Process that allocates nothing but large objects never fills a nursery,
  so old space reached its soft limit with no cycle started and fell back
  to full collections (AGENTS.md: a trigger must watch every resource a
  fallback can exhaust). After a large allocation `allocateLarge` decides
  the trigger again (`startCycleAfterLargeAllocation`) and, when it fires,
  runs the young collection a full eden would have run (module 7's local
  collection of its own nursery, or the stop-the-world scavenge), whose end
  decides the trigger and takes the snapshot as always. The new object is
  a **pending root** meanwhile: it is old, so a snapshot entry, nothing
  else holds it yet, and its worker may park for another worker's stop,
  whose roots a stop's `keeping` does not reach. The first version started
  module 7's initial-mark pause in a stop of its own, holding the object
  only in that stop's `keeping`: the random programs under
  `cycleEveryScavenge` and `markingAlwaysOn` crashed (signal 11, release)
  or reported the object missed ("entry 6401 is reachable but not marked")
  in about one run of 300 seeds in two; rooted, eight runs of 300 seeds
  were clean (Broken variants). A full collection forced by an old
  allocation is now counted as a fallback (`noteFullCollection`), as the
  scavenge's always were: before, `allocateOld`'s collections went
  uncounted.
- **Sweeping.** The eager sweep (`sweep`) and the lazy sweep's apply
  (`freeDeadBlocks`) free a block with no live body as before; a head frees
  its whole run (`freeRun`), a continuation is never freed alone (it has no
  body of its own; it goes with its head, live or dead). The lazy sweep
  frees no run allocated after its snapshot: every block of the run
  carries the cycle's stamp, which the apply already skips for a block an
  allocator took.
- **Become and reshape** go through the entry and copy nothing: a two-way
  become swaps entries and back references, so a large body stays in its
  run under the other oop; a one-way become frees the source's entry and
  its run dies at the next sweep. Reshape gives an instance whose new
  body passes a block a new run (`takeRun`, against the promotion
  reserve's limit as reshape runs after a promote-all) and leaves the old
  run dead to the next sweep; `.tooLarge` is now past the count field.
- **Fragmentation.** Runs never move, so they can leave free blocks
  between them that no longer run fits. Compaction consolidates the
  ordinary blocks around them; it cannot open a hole between two runs.
  The worst case measured is in Measurements.
- **The snapshot and the image.** Module 1's snapshot is version 4: each
  block's used word carries its kind in bits 56 to 63; a head's used bytes
  are the run's body, written and read back in one copy. The loader's
  parser checks the side table before anything is copied (a head's used is
  past one block and within the snapshot's blocks, its continuations follow
  it with used 0, no continuation outside a run, no unknown kind, no run cut
  short), and the heap verifier then checks every entry against it (no
  entry into a continuation, a large body exactly at a head, an ordinary
  one in an ordinary block). Image format **version 5**; 1 to 4 are
  refused ("made before module 10's large objects: rebuild it from its
  sources"). The snapshot fuzzer's seeds were upgraded (their format is
  unchanged but for the version words; the kinds of their blocks are 0)
  and gained `large-objects.img`, an image with a 9000-slot Array and a
  40 000-byte ByteArray; `mutatedImagesWithRunsLoadCleanOrAreRejected`
  flips bits half of the time in the block table.
- **The stop-the-world oracle** handles runs the same way: module 4's
  scavenge never sees one (nothing large is young), and the full collection
  is module 1's sweep and compaction above.
- **No new cross-thread protocol.** Run allocation takes the pools lock as
  a block refill does; runs are freed only with the world stopped (the
  sweeps' applies, compaction, the loader); the relocator's selection runs
  in the final mark's stop and skips runs; the concurrent lazy sweep frees
  entries, not blocks. The marker's chunked scan changes the order of its
  work, not the barrier or the snapshot. The models under `models/` cover
  none of these and are unchanged.

## 2. The kernel goes back to plain Arrays

- `LargeArray`, `LargeArrayTest` and `Array class >> large:` are removed;
  `OrderedCollection`, `HashedCollection` and the merge sort allocate with
  `Array new:`. `LargeObjectTest` replaces `LargeArrayTest`: an Array of
  100 000 elements (filled, sorted, copied, summed), an OrderedCollection
  of 10 000, a Set and a Dictionary of 50 000, a String of a megabyte
  concatenated and copied, a ByteArray of 100 000, `new:` past the count
  field signalling an error that names 16777215, and JSON written whole
  past 32 KiB and in pieces.
- The merge sort stays. The JSON pieces stay for the transport: a reply
  over the link still goes in 16 KiB pieces and a long received line still
  arrives in pieces (9c's design, which 9d's writer and reader use), but
  `Json write:` builds one String of any size, primitive 160's request is
  one String, and the transport's refusal of a request over 32 704 bytes is
  lifted to what one String holds (`RequestLimits.imageBytes`, 16 MiB - 1;
  the server's line limit, 9b's 1 MiB, is 16 MiB now and its JSON reader
  bounded the same).
- Contexts stay at most one block (ADR 0009's stack copy rule: a frame's
  Context is materialized from words that fit a block); the bytecode
  verifier's limits on literal frames, temp vectors and `push_new_array`
  stay `Header.maxSlots`. `Symbols.maxBucket` stays. Method dictionaries
  and class pools stay one block (their build refuses past it, as before).
  A literal String or ByteArray of a method may now be large (the make
  primitive's heap, `LiveMethodHeap.bytes`).
- The primitives that build objects of a size given to them take the new
  sizes: `basicNew:` (3), `shallowCopy`, String concatenation and
  `copyFrom:to:` (through `newString(count:)`), the host's `newString`,
  `newArray` and `newStringArray`, primitive 162's list of Processes, the file
  read of the Tonel reader (149: a file up to 16 MiB). LargeIntegers stay
  at most one block (32 760 bytes, 262 080 bits). The image build's tables
  allocate through module 1's `allocate`, which takes any size.
- AGENTS.md's 8b lesson "no object is larger than one block" and 9c's
  "a limit no input has reached" are the main session's to retire.

## 3. The two follow-ups from vm-teardown

### Old space grows for the final collection

`VM.destroy`'s `endYoungGeneration` promotes every young object; it trapped
when old space had no room. The owner decided to grow old space rather
than fail. **Built by reserving more**: the block heap's reservation holds,
after the soft limit's blocks and the promotion reserve's, the **end
growth** (`ObjectMemoryConfig.endGrowthBytes`; nil means as large as the
promotion reserve, which `NurseryConfig.reserveBytes` sizes to twice what
the nurseries hold plus a third for block tails, so the growth alone can
take every young object). The pools gain a **hard limit**, the soft limit
plus the reserve: a promotion refill stops there, a young collection's
promised room is counted below it, and the nursery's install computes its
soft limit from it. `endYoungGeneration` sets `endGrowth` in its stop
before the promote-all hook, so that promotion may take every block of the
reservation, and clears it after; `VMEndReport.grownBlocks` says how many
blocks past the hard limit the image now holds. Only a growth too small
for the young objects still traps ("...found no room in old space at the
VM's end, its growth included").

What it costs: address space only until the VM's end uses it (the memory
object is mapped twice, as the heap is, and pages are touched only when
allocated), plus the per-block side tables (`used`, `inUse`, the kind and
the stamp: 10 bytes per 32 KiB block), and room in the 4 GiB the heap,
reserve, growth and nursery region must fit together (the growth is
clamped to what is left). The snapshot loader accepts an image whose
blocks reach into the growth (an image saved after a VM grew); it checks
the snapshot's block count against the whole reservation.

`VMEndTests>>oldSpaceGrowsForTheFinalCollection`: a 16 MiB heap with a
promotion reserve of two blocks (the nursery's reserve set to one block by
its test switch), the growth what `kajo run` reserves for promotion; the
host fills old space to its soft limit with live large objects (Arrays of
5000 slots, old at birth), a VM leaves 8000 live young Arrays in its eden
and ends; the final collection promotes them into the growth
(`grownBlocks > 0`, blocks in use past the hard limit), module 1's
verifiers pass, the host saves the image, it loads with every rule and a
VM over it sums every value. With `endGrowthBytes = 0` it traps (Broken
variants).

### The host save refuses while any Process has frames

`Image.saveImage` (the host's save, after a VM ended) now throws
`ImageError.processesHaveFrames(n)` when any Process in the heap is
neither terminated nor saved by the VM's own save (special object 8's
list): "the host cannot save this image: 1 Process has frames, which
ended with the VM; save it from Smalltalk with Smalltalk snapshot: (the
VM's own save keeps Processes), or let them end first". `kajo seal` and the
image build report it as their failure. The brief's wording names
`Smalltalk saveImage`, which the kernel does not have: the VM's own save
is `Smalltalk snapshot:`, and the host save is not reachable from
Smalltalk, so the error is the host's (`kajo`, the shells, the tests) and
it names the save Smalltalk does have (Deviations).
`VMEndTests>>theHostSaveRefusesWhileAProcessHasFrames` saves an image
after a VM with no Process left (it loads) and after a VM that ended with a
Process ready to run (refused, the message names `Smalltalk snapshot:`).
The loader's own refusal of such an image ("Process ... is live but not
saved", 8c) is still tested: `ImageFileTests`' `.aProcess` corruption
encodes its image without the host's check.

## Measurements

Mac mini, M2 Pro (8 performance and 4 efficiency cores, 32 GB), macOS 27,
swift.org Swift 6.4.2, 2026-11-05.

### Allocation and free of 1 MiB and 16 MiB objects

`LargeObjectTests>>largeObjectMeasurements` (KAJO_MEASURE_LARGE=1, release
with `-enable-testing`): a 256 MiB object memory with the verifiers off,
20 times each: allocate (`tryAllocateAny`: the run, the entry, the fill),
then a full collection with the object garbage (its run freed), against
a full collection without it.

| object | allocate p50 | allocate max | collection freeing it | collection without it |
|---|--:|--:|--:|--:|
| Array of 131 071 slots (1 MiB, 33 blocks) | 0.044 ms | 0.100 ms | 0.020 ms | 0.020 ms |
| ByteArray of 1 MiB | 0.044 ms | 0.044 ms | 0.020 ms | 0.020 ms |
| ByteArray of 16 MiB - 1 (513 blocks) | 0.623 ms | 1.530 ms | 0.020 ms | 0.020 ms |
| Array of 2 097 151 slots (16 MiB) | 0.622 ms | 0.627 ms | 0.020 ms | 0.020 ms |

Allocation is the fill: 25 to 27 GB/s, one store per word. The first
allocation of a fresh range pays the page faults (the 1.53 ms maximum).
Freeing a run costs nothing measurable: the sweep frees the head's blocks
in its block loop. With the verifiers on (every test, checked builds) the
collection freeing a 16 MiB Array took 1.96 ms, all of it the heap
verifier's walk of the dead object's two million slots before the
collection (`measure-large-verify-on.txt`).

### Frames while a Process allocates and drops large objects

The macOS shell on the Mac mini's display at 120 Hz, `mode=scenario
seconds=10`, the default configuration (5 workers, 512 MiB heap, offload
young collection, concurrent marking, relocation on), three launches each,
`scenario=idle` and `scenario=large`: idle plus one background Process
running `ShellBench class >> large` (a 1 000 000-slot Array kept live
throughout, then forever a 1 MiB Array filled and checked, the last four
kept, and every sixteenth time a 16 MiB ByteArray written at both ends and
dropped). `m10/mac-shell-large.results` (the final commit's; 68d860a's
run, the same code but for tests, is in `m10/shell-68d860a/` and agrees).

| scenario | frames (of 1200) | missed | max gap | longest turn | main stopped by others per 10 s | stops per 10 s | marking cycles | longest final mark | fallbacks | peak footprint |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| idle | 1200, 1200, 1200 | 0, 0, 0 | 8.40 ms | 3.1 to 3.2 ms | 0 | 0 | 0 | | 0 | 47 MB |
| large | 1200, 1200, 1200 | 0, 0, 0 | 8.40 ms | 2.5 to 2.8 ms | 59 to 67 ms | 2220 to 2240 | 811 to 819 | 1.6 to 1.8 ms | 0 | 434 to 440 MB |

0 frames missed, the bar 9a set. The churn allocates about 1.1 GB/s of
large objects without one young collection (no scavenge ran): every cycle
was started by a large allocation (`byFloor` 810, `startCycleAfterLargeAllocation`),
81 cycles a second with the marker busy about 1.45 s of CPU per 10 s,
final marks of 0.16 ms p50 and 0.79 ms p99 (68d860a's run), the applies
0.055 ms p50, and no fallback: dead runs are freed at each apply. The main
thread was stopped 59 to 67 ms per 10 s by the 2220 to 2240 stops (initial marks, final marks, applies), never for
more than a frame's slack. That a floor-triggered cycle starts at every
large allocation once old space sits above the floor is the trigger's
rule, not a new policy; a churn of this rate keeps old space there.

### at: and at:put: on a million elements against 9c's LargeArray

The starting commit's `kajo` and kernel with `Array large: 1000000` (a
LargeArray: its `at:` and `at:put:` are sends that index a chunk) against
this module's with `Array new: 1000000` (an Array: the interpreter's
`at`/`at_put` fast paths): 20 passes of a million `at:put:` and a million
`at:` each, one worker, the bench A/B's builds and runs (below), five runs
interleaved.

| sequence | ms | per element access |
|---|--:|--:|
| LargeArray (start) | 4567 (4554 to 4577) | 114 ns |
| Array (module 10) | 1016 (1012 to 1028) | 25 ns |

4.5 times faster; both answer 10000220000000. The 25 ns is the loop's
SmallInteger arithmetic and the block's `to:do:` as much as the access.

### Marking a 1M-slot pointer object

`LargeObjectVMTests>>markingAMillionSlotArrayMeasured` (release, manual
marking, five rounds): a 1 000 000-slot Array, live, traced by the marker
four items at a time (128 units: one poll interval).

| rounds | chunks | steps of four items | longest step | the Array's whole trace |
|--:|--:|--:|--:|--:|
| 5 | 244 per round | 196 | 0.013 ms | 0.76 to 0.79 ms |

The longest stretch between two polls of the marker is 13 µs; the whole
Array costs 0.8 ms of marker time (0.8 ns a slot). Unsplit, the same
Array would be one 0.8 ms step, and the limit's 16 million slots one of
about 13 ms. Frames while the marker traces it are the shell scenario's
above (its Process keeps a 1M-slot Array live through every cycle).

### Fragmentation

`LargeObjectTests>>largeObjectFragmentation` (release): a 64 MiB heap
filled alternately with a run of two blocks (an Array of 5000 slots) and a
block of forty small objects (100 slots each), until full; then the small
objects dropped but for one in every fourth block of them; collected;
compacted; then every small object dropped.

| state | blocks in use | live | footprint / live | free blocks | longest free stretch |
|---|--:|--:|--:|--:|--:|
| full: 682 runs (26.0 MiB), 27 280 small objects | 2047 | 47.0 MiB | 1.36 | 1 | 1 |
| all but one small object in four blocks dropped, collected | 1536 | 26.2 MiB | 1.84 | 512 | 2 |
| then compacted | 1369 | 26.2 MiB | 1.64 | 679 | 2 |
| every small object dropped, collected | 1365 | 26.0 MiB | 1.64 | 683 | 2 |

The worst case: 683 free blocks (21 MiB) and no stretch of three, so a
run of three blocks (an Array of 12 288 slots) does not fit after a full
collection and a compaction, in a heap a third of whose space is free.
Compaction packs the ordinary objects into the holes (1536 to 1369 blocks
in use) but cannot open a hole between two runs. Ordinary objects use the
holes; only runs longer than the longest hole cannot. Footprint against
live bytes is 1.64 in the end: every run of two blocks is 40 KiB of body in
64 KiB of blocks, plus the hole beside it.

### The 2000-class image and 9c's scripted session

The development image with 9c's 2000 classes (`kernel/`, `tools/` and
`scripts/gen-classes.py`'s 1806 classes of 11 methods), built by the
starting commit's `kajo` and kernel and by this module's (the bench
builds), three runs interleaved (`m10/imgbuild.txt`):

| build | classes | methods | image | build time |
|---|--:|--:|--:|--:|
| 9f7941b (LargeArray) | 2005 | 22 276 | 37.8 MB | 518 ms (514 to 536) |
| module 10 (Arrays) | 2004 | 22 266 | 37.8 MB | 481 ms (477 to 499) |

(One class fewer: `LargeArray` and `LargeArrayTest` went, `LargeObjectTest`
came.) The tables the build fills (every behavior, the sources by
behavior) are plain Arrays now, 7 percent faster.

9c's scripted session on the Mac mini's display (`mode=devsession`, 12
launches as 9c and 9d ran them: three each of 2000 classes with no load
and under the storm, and of typing 200 keys with no load and under the
storm; local target; `m10/mac-shell-devsession.txt`). The session now has
9d's steps too (define and retry, a dropped link); 9c's columns are its
own tables'.

| classes | load | seconds | frames (of expected) | missed | max gap ms | longest turn ms | peak footprint MB |
|--:|---|--:|--:|--:|--:|--:|--:|
| 2000 | none | 5.3 [5.2–5.4] | 582 (632) | 51 [50–53] | 41.2 [38.0–47.1] | 14.2 [13.7–17.2] | 343 [338–345] |
| 2000 | storm | 5.1 [5.1–5.1] | 568 (611) | 44 [38–46] | 35.2 [33.9–38.1] | 13.9 [13.8–14.1] | 844 [839–862] |

The steps and requests 9c measured, against 9c's tables (no load):

| step or request | 9c | module 10 |
|---|--:|--:|
| open | 387 ms | 403 [389–404] ms |
| populate, tree pushed | 384 | 352 [341–407] |
| populate, tree on demand | 451 | 432 [351–443] |
| the tree alone, pushed / on demand | 65 / 57 | 60 / 66 |
| `package.selectors` (19 866) as a step | 706 | 443 [426–479] |
| 19 866 rows pushed | 108 | 36 [32–52] |
| ten classes and a method each | 201 | 178 [176–185] |
| an error, the debugger open | 401 | 385 [349–398] |
| `class.hierarchy` round trip p50 | 329 | 336 [336–337] |
| `package.selectors` round trip p50 | 657 | 443 [426–479] |
| `class.selectors` p50 | 4.2 | 2.8 |

The browser's population is unchanged (its time is the requests' JSON,
not the collections); `package.selectors`, whose 19 866 selectors went
through LargeArrays in the target (collected, sorted, written), is 37
percent faster with plain Arrays, and the 19 866 rows pushed into the
table 67 percent (the tools' collections are Arrays too). Typing: key to
redraw p50 7.1 ms and p99 7.4 ms with no load, 6.0 and 6.4 ms under the
storm (9c: 5.5 idle, 2.3 and 2.9 loaded; 68d860a's run of the same code
5.4 and 6.9 idle, 2.6 and 3.2 loaded, so this is launch-to-launch spread);
frames missed while typing 3 of 1257 idle and 1 of 1259 under the storm
(9c: 1 to 170 idle, 1 to 18 loaded). The 44 to 51 frames missed per
session are, as in 9c, AppKit's while the first windows open and in the
debugger and define-and-retry steps; the longest turn of the image stays
under 16 ms.

### Random programs with large objects

The generator gained a step (`case 11`, about one in fourteen operations):
an Array of 4096 to 8095 slots (a run of two blocks), an integer stored
past its first block and read back, its size, and the task's current tree
stored in its last slot and summed through it; then dropped. Every
configuration runs it, including the exhausted-reserve ones, whose heap
gains two blocks per task (each task may hold a run at once; their
garbage still does not fit). `just soak` on 7987f59: 1000 seeds under
each of the 20 configurations and the 6 resumed modes, no failing seed
(Gates). The step found the bug of the trigger's unrooted object (section
1) and a division by zero in its own first version (an Array of exactly
4096 slots).

### The kernels against the starting commit

The starting commit's `kajo` (9f7941b, from a worktree) against this
module's (f01333b), both built `-c release -Xswiftc -enable-testing` with
`-align-all-nofallthru-blocks=5 -align-loops=32`; five runs interleaved,
`--slice-ms 0`, 2026-11-05 13:54 to 13:59 (load average 3.0 to 3.8);
median (min to max) ms; every checksum equal on both sides and the
published one (`m10/bench-ab.txt`). The one commit after f01333b changes
only `allocateLarge`, out of line from every kernel's path.

| kernel | workers | 9f7941b ms | module 10 ms | m10 / start | checksum |
|---|--:|--:|--:|--:|---|
| alloc | 1 | 2942.1 (2934 to 2947) | 2937.7 (2930 to 2944) | **0.999** | 41950911 |
| alloc | 8 | 484.2 (440 to 505) | 461.2 (434 to 497) | **0.952** | 42008248 |
| arith | 1 | 2549.7 (2548 to 2560) | 2549.6 (2540 to 2553) | **1.000** | 372800000 |
| arith | 8 | 340.5 (340 to 354) | 338.9 (336 to 354) | **0.995** | 372800000 |
| fib | 1 | 1696.0 (1692 to 1701) | 1695.5 (1688 to 1702) | **1.000** | 24682992 |
| fib | 8 | 225.7 (219 to 236) | 223.6 (217 to 240) | **0.991** | 24682992 |
| ivars | 1 | 1967.3 (1966 to 1970) | 1975.1 (1972 to 1981) | **1.004** | 36383626 |
| ivars | 8 | 256.9 (252 to 285) | 259.0 (252 to 280) | **1.008** | 71714128 |
| sends | 1 | 2577.5 (2565 to 2585) | 2581.2 (2573 to 2590) | **1.001** | 1066666666666668 |
| sends | 8 | 341.5 (332 to 356) | 340.1 (335 to 352) | **0.996** | 133333335000001 |
| storeheavy | 1 | 2406.3 (2394 to 2410) | 2410.9 (2398 to 2415) | **1.002** | 512000 |
| storeheavy | 8 | 316.9 (310 to 334) | 314.7 (308 to 333) | **0.993** | 512000 |
| Smalltalk closures | 1 | 3798.1 (3789 to 3800) | 3803.1 (3801 to 3808) | **1.001** | 210210000 |
| Smalltalk closures | 8 | 506.0 (486 to 510) | 504.6 (490 to 518) | **0.997** | 209214000 |
| Smalltalk ivars | 1 | 1970.0 (1965 to 1971) | 1972.8 (1960 to 1976) | **1.001** | 36383626 |
| Smalltalk ivars | 8 | 262.8 (252 to 271) | 259.3 (253 to 281) | **0.987** | 71714128 |
| Smalltalk sends | 1 | 2312.6 (2309 to 2343) | 2278.8 (2267 to 2361) | **0.985** | 1066666666666668 |
| Smalltalk sends | 8 | 310.0 (298 to 319) | 299.5 (291 to 308) | **0.966** | 133333335000001 |

Within noise: 0.985 to 1.004 on one worker, 0.952 to 1.008 on eight with
overlapping ranges (alloc on eight: 440 to 505 against 434 to 497).
`interpret` is the same code (Hot-path check).

## Changes to earlier modules

- **Module 1**: `BlockHeap.kind` (the side table) and the run helpers;
  `Header.isLarge`, `Header.maxLargeCount`; `tryAllocateAny`,
  `tryAllocateLarge`, `takeRun`, `freeRun` (`LargeObjects.swift`);
  `allocate`'s policy takes any size; the sweep, the pool's rebuild, the
  compaction plan, the heap and free-list verifiers and the snapshot
  (version 4) know runs; `refillEntries` is internal (the large path takes
  an entry with it); `Pools` gains the hard limit, `endGrowth` and the
  large-object counters; `ObjectMemoryConfig.endGrowthBytes`; the
  loader's block count is checked against the reservation;
  `TestSwitches.runBlind`.
- **Module 4**: `allocateYoungSlow` sends anything past its eden's large
  limit or a block to `allocateOld`, which takes any size; the nursery's
  soft limit is computed from the hard limit; `endYoungGeneration` grows
  old space (section 3) and reports `grownBlocks`.
- **Module 5**: the marker splits a large object's scan (`traceChunk`,
  `MarkChunk`), `markSome` polls by work (a chunk counts 32), the cycle
  counters gain `chunksSplit`, the pools `largeTriggers`; the lazy sweep's
  apply frees runs whole; a large allocation decides the trigger; a full
  collection an old allocation forces counts as a fallback; `markStepDone`
  (a manual-mode entry for the measurement).
- **Module 6**: the selection skips runs; the relocation verifier refuses
  a run's block in the pool or the relocation set.
- **Module 7**: `reservePromotion` counts below the hard limit.
- **Module 8**: image format 5; `basicNew:` and the primitives above take
  large sizes; `LiveMethodHeap` takes a large literal; `Image.saveImage`
  throws (section 3) and `processesWithFrames`.
- **Modules 9b and 9c**: `RequestLimits.lineBytes` 16 MiB, `imageBytes`
  16 MiB - 1; `parseRequest` reads with those limits;
  `ToolsTests>>aRequestLongerThanOneHeapBlockReachesTheImage` (it was
  `aRequestTooLongForTheImageIsRefusedNotDropped`); the shells' scenario
  `large` (`ShellBench class >> large`).
- **Module 3's random programs**: the large-object step; the
  exhausted-reserve heaps.

## Deviations from the brief

- **The marker's split.** The brief asked to split the scan "if the
  marker's budget needs it". It does: unsplit, a 1M-slot Array is one
  0.8 ms step between two polls, and the limit's 16 million slots 13 ms,
  which a stop (a scavenge on the main thread) would wait for. Split, the
  longest step is 13 µs.
- **The poll counts work, not objects.** With chunks counted as one object
  each, 128 chunks (half a million slots) would pass between polls; a
  chunk counts 32.
- **The host save's error** names `Smalltalk snapshot:`, not
  `Smalltalk saveImage` (section 3): the kernel has no `saveImage`, and the
  host save is not reachable from Smalltalk.
- **The growth is reserved with the heap**, not reserved on demand at the
  VM's end: the memory object is mapped twice at creation (ADR 0007's
  alias), and a second reservation would need a second mapping every
  reader of a body would have to know.
- **The exhausted-reserve random-program configurations** gain two blocks
  per task and two more (they had the image's block and two more): with a
  run of two blocks live per task at once, three blocks could not hold the
  live data the configuration promises to fit, and with two per task only
  one seed in a thousand found no two free blocks side by side.
- **Three earlier tests got the sanitizer's bound or a repeated round**
  (Gates): `PhoneTransportTests`' wait for the end of a listener's pause
  and the protocol tests' evaluate under ThreadSanitizer, and the
  relocation kernel tests' two selecting cycles in the release suite.
- **Reshape** takes a large body's run against the promotion reserve's
  limit, not the soft limit: it runs after a promote-all in a stop, and a
  reshape that fails is all or nothing anyway.

## Tests

Swift: 340 `KajoVMTests` (312 at the start) and 84 `KajoCompilerTests`
(82), Swift Testing's count, parameterized tests once: `LargeObjectTests`
(19), `LargeObjectVMTests` (8), `ImageFileTests` (one more), `VMEndTests`
(two more).

`LargeObjectTests` (object memory): a large object is a run of blocks,
old at birth, its slots read and written past the first block, a byte
object zero-filled; the largest byte object (16 MiB - 1, 513 blocks); a
run that does not fit the soft limit is refused, not trapped; the eager
sweep frees a dead run whole and keeps a live one (and without the run
rule fails); compaction leaves runs where they are with their contents
(and without the rule moves a large body); compaction consolidates the
ordinary blocks so a run fits; the heap verifier catches six broken runs
(an entry into a continuation, a continuation of no run, a free block with
a kind, a head's used under a block, a continuation not in use, a large
body in an ordinary block) and, blind, refuses a whole heap; run blocks
never reach the pool (and blind, a continuation does); become and reshape
of a large object; a snapshot carries runs and loads them back; the
loader rejects six broken block tables; blind, a snapshot does not load;
the reservation keeps growth past the reserve and a promotion stops at the
hard limit until the end grows. Two measurements print when asked.

`LargeObjectVMTests` (a VM, manual marking): a large Array from Smalltalk
is old at birth in a run and a small one is young; the lazy sweep frees a
dead run whole, keeps a live one, and keeps one allocated while the cycle
marked (and blind, fails); the relocator never selects a run with every
live block selected (and blind, selects it); the marker traces a 1M-slot
Array in 244 or more chunks and the cycle's verifiers agree; a Process
allocating only large garbage (64 MiB of 160 KiB Arrays in a 16 MiB heap)
starts marking cycles from its allocations, under the offload policy and
the stop-the-world scavenge (6 cycles, no fallback, against 3 fallbacks
without the rule). One measurement prints when asked.

`VMEndTests`: `oldSpaceGrowsForTheFinalCollection`,
`theHostSaveRefusesWhileAProcessHasFrames` (section 3).

`ImageFileTests`: `mutatedImagesWithRunsLoadCleanOrAreRejected` (an image
with runs round-trips; 300 mutations, half in the block table, load
cleanly or are refused), a version 4 image refused, the `.aProcess`
corruption encoded without the host's check. `PrimitiveTests`: `new:`
past the count field fails, for pointers and bytes (it was "past a
block"). `ReshapeTests`: `.tooLarge` past the count field.
`ToolsTests>>aRequestLongerThanOneHeapBlockReachesTheImage`: a 40 000-byte
request evaluates in the image. `RandomPrograms`: the large-object step in
every configuration.

Kernel: `LargeObjectTest` (5 tests) replaces `LargeArrayTest` (3).

## Broken variants run by hand

Each removes one rule from the source, runs the test that must fail
without it, and restores the file (`m10/broken/<name>.txt`, the patch at
the top of each; `bin/m10-broken.py`). Every one failed; the reader's test
switch (`runBlind`) variants are in the suite as well.

| rule removed | test | how it fails |
|---|---|---|
| the eager sweep frees a run with its head only | `theSweepFreesADeadRunWholeAndKeepsALiveOne` | verifier after sweep: "run at block 1: block 2 is not a continuation in use with no used bytes; free block 2 has kind 2..." |
| the lazy sweep's apply frees a run with its head only | `theLazySweepFreesADeadRunWholeAndKeepsLiveOnes` | verifier after the applying scavenge: "block 10 of a run is in the pool; block 9 of a run..." |
| compaction keeps a live run | `compactionLeavesRunsWhereTheyAre` | compaction verifier: "entry 2: contents changed during compaction; entry 203: ..." |
| the heap verifier walks a run as one body | `theHeapVerifierCatchesABrokenRun`, `aLargeObjectIsARunOfBlocksOldAtBirth` | a whole heap refused: "block 1 has an invalid used count 80008; entry 2: offset 32768 is not the start of a body in block 1's walk" |
| the pool's rebuild leaves run blocks out | `runBlocksNeverReachThePool` | "block 3 of a run is in the pool; block 2...; block 1..." |
| the relocator skips runs | `theRelocatorNeverSelectsARun` | the run's head selected (and the to-space refill drains the pool: `noSpace`) |
| the snapshot writes each block's kind | `aSnapshotCarriesRunsAndLoadsThemBack` | "malformed snapshot: block 1 used 160008" |
| the loader copies a head's whole run | `aSnapshotCarriesRunsAndLoadsThemBack` | "snapshot breaks invariants: entry 2 slot 4095 holds none; entry 2 slot 4096 holds none; ..." |
| the marker splits a large object's scan | `theMarkerTracesAMillionSlotArrayInSteps` | `chunksSplit` 0 |
| a run is stamped with the current cycle | `theLazySweepFreesADeadRunWholeAndKeepsLiveOnes` | the run allocated while the cycle marked is freed under its live object: "relocation verifier: entry 1795: body in block 11, which is free" |
| reshape gives a large body a run | `becomeAndReshapeOfLargeObjects` | `ReshapeError.heapFull` (a block refill cannot hold the body) |
| old space grows for the final collection (`endGrowthBytes = 0`) | `oldSpaceGrowsForTheFinalCollection` | trap: "kajo: 5596 young objects found no room in old space at the VM's end, its growth included (ObjectMemoryConfig.endGrowthBytes); the image is not whole" |
| the host save refuses Processes with frames | `theHostSaveRefusesWhileAProcessHasFrames` | the image is saved (and the loader would refuse it) |
| a large allocation decides the cycle trigger | `largeAllocationsStartMarkingCycles` | no cycle; three full collections, each counted as a fallback |
| the trigger's new object is a pending root | the random programs, `markingAlwaysOn` and `cycleEveryScavenge`, 300 seeds, four runs each, release | `markingAlwaysOn` 2 of 4: "final mark of cycle 1: entry 3585 is reachable but not marked (missed)" (seeds 186, 63) |

## Unsafe surface

46 new `unsafe` sites (code lines), all in the object memory and the
marker: `LargeObjects.swift` 24 (the pools' fields under the lock, the
context's free entry), `BlockHeap.swift` 6 (the kind table: allocate,
initialize, deallocate, read, write), `Marker.swift` 5 and
`MarkingHost.swift` 5 (the chunk's push and counter, the manual-mode
entry), `Generations.swift` 2, `Allocation.swift`, `OldMap.swift`,
`FinalMark.swift` and `InitialMark.swift` 1 each. No new `@safe` type.
Counted on the clean build of the gates, which reports no strict
memory-safety warning.

## Hot-path check

`just arc-check` passes on the final commit: no retain or release in its
135 functions, `interpret` 1056 instructions with one indirect branch and
one jump table (Gates). The large path is out of line (`tryAllocateAny`,
`tryAllocateLarge`, `Machine.allocateLarge`, `traceChunk`,
`startCycleAfterLargeAllocation`) and touches no hot path's code. The
disassembly of the start commit's and this module's `-enable-testing`
release builds (`just arc-check`'s), normalized for addresses
(`m10/disasm/`):

| function | start | module 10 | difference |
|---|--:|--:|---|
| `interpret` | 1056 instructions | 1056 | none |
| `ObjectMemory.tryAllocate` | 45 | 45 | none |
| `ObjectMemory.tryAllocateBytes` | 54 | 54 | none |
| `ObjectMemory.allocate` | 39 | 39 | none |
| `ObjectMemory.place` | 35 | 35 | none |
| `Machine.allocate` | 117 | 117 | none |
| `Machine.allocateBytes` | 127 | 127 | none |
| `ObjectMemory.allocateSlow` | 76 | 75 | one `mov` fewer: `refillEntries` is internal now, not private |
| `primBasicNew` | 397 | 402 | the large branch (`allocateLarge`, a call) |
| `markSome` | 329 | 373 | the chunk's weight in the poll interval |

## Not done

- **A card table for large objects.** A remembered large object is
  scanned whole by every scavenge (and by module 7's collections), and a
  large object holding young pointers stays remembered: a 1M-slot Array
  with one young element costs every scavenge about a millisecond of
  scanning. Cards (a byte per 512 slots, set by the barrier) would bound
  it; not built and not measured beyond this estimate.
- **The stop-the-world collector marks a large object whole**: in a pause,
  so it only lengthens that pause.
- **Filling a large object does not poll** (a byte object's fill polls
  since the large-bytes follow-up, every 256 KiB; a pointer object's still
  does not): a 16 MiB fill is 0.6 ms a stop
  may wait for, a 128 MiB one about 5 ms.
- **Runs are never moved**, so fragmentation between them is permanent
  until they die (Measurements). The owner's question below.
- **LargeIntegers** stay at most one block.
- **The transport still carries long lines in pieces** both ways (since
  the large-bytes follow-up only the replies the image writes; a received
  line is one String up to 16 MiB - 1, docs/modules/large-bytes.md part 3).
- **The device**: nothing in this module ran on the iPhone (the attached
  phone was not touched; its build waits on signing since 9d).

## Open questions for the owner

1. **Is 16 MiB enough for byte objects?** The count field's 24 bits give
   16 MiB - 1 bytes (and 128 MiB of slots). A widened count field is a
   header change (bits 46 and 51 are free, so two more bits are possible
   without moving a field only if both join the count: 64 MiB of bytes,
   512 MiB of slots).
2. **Should a large object ever be relocated to fight fragmentation?** The
   worst case leaves a third of a heap free and no run of three blocks
   (Measurements). Relocating a run is a copy of up to 128 MiB under the
   post-store check, or a remapping of its pages (the memory object is
   mapped twice already); either is a module of its own.
3. **Should the transport keep sending pieces** now that one String can
   hold a line? Pieces cost a join on each side and keep each piece a
   small object; one String would be one allocation of the line's size
   (old at birth past 32 KiB).
4. **Card marking for large objects** (Not done): worth building before
   the shells keep large collections that hold young objects?

### The owner's answers (2026-11-06)

1. **16 MiB is too little** if images or photos are held in a ByteArray.
   The byte limit is to be lifted in a follow-up (how is that module's
   to measure: a count in words with the odd bytes beside it, or an
   overflow count word for large objects). Built in the large-bytes
   follow-up: a sentinel count with the length in the back reference, up
   to 2 GiB - 1 bytes (docs/modules/large-bytes.md).
2. **No relocation of runs.**
3. **The pieces**: the owner asked whether keeping them is right. The
   reason to keep them is that a line past one block as one String is old
   at birth, so every large reply becomes old-space garbage that only a
   marking cycle frees, where pieces die in a scavenge; that is an
   argument, not a measurement, and the follow-up measures both forms
   before it is settled.
4. **No card marking yet.**

Also from the device run of 2026-11-06: large churn of the kind
`scenario=large` makes is plausible in a photo or video app, so the
fallbacks it counted on the devices (3 of 6 runs, none on the Mac) are to
be tuned away for devices in the same follow-up.

## Gates

Every gate ran on 7987f59 (the code of this module; the commits after it
are this doc), Mac mini (M2 Pro), swift.org 6.4.2 (the toolchain first on
PATH), 2026-11-05 21:51 to 2026-11-06 00:05, every output in a file under
the session's `m10/`, each step logged with the commit it ran on
(`m10/gates.log`). Earlier runs stopped at a failure and every gate ran
again after the fix: run 1 (c0d2269/4209c33) at ThreadSanitizer's
`PhoneTransportTests` bound, run 2 (7781fe9) at ThreadSanitizer under
load's `AgentInterfaceTests` evaluate bound (both 9b and 9d tests' wall
clocks, given the sanitizer's bound), run 3 (f793776) at `just
test-release`'s relocation kernel test (one selecting cycle of two; 8 and
9 alone on this and the starting commit; the round is repeated now), run
4 (3d3067d) at the soak's exhaustedReserve seed 803 (no two free blocks
side by side for a run; the heap gained two blocks). Their outputs are in
`m10/run1` to `run4`.

| gate | result |
|---|---|
| `swift test` | 340 + 84 passed, 278 + 87 s |
| under load (12 busy loops) | 340 + 84 passed, 330 + 107 s |
| ThreadSanitizer | 340 + 84 passed, 0 reports, 464 + 2192 s |
| ThreadSanitizer under load | 340 + 84 passed, 0 reports, 700 + 2715 s |
| `just ios-check` | exit 0, 0 errors, 0 warnings |
| `just arc-check` | OK: no retain or release in 135 functions, `interpret` 1056 instructions, one indirect branch and one jump table |
| `just golden` | 12 of 12 checksums |
| `just test-release` | 340 + 84 passed |
| `just model-check` | 28 + 5 + 15 passed |
| `just soak` | passed: 1000 seeds under every configuration (26 lines, no failing seed), the large-object step in each; the resumed modes saving 968 to 979 of 1000 |
| `just fuzz kasm 600` | libFuzzer build ok, 2.32 million runs, no crash |
| `just fuzz snapshot 600` | libFuzzer build ok, 2.17 million runs, no crash (seeds with runs, the old corpus moved aside) |
| `just fuzz syntax 600` | libFuzzer build ok, 0.87 million runs, no crash |
| `just fuzz protocol 600` | libFuzzer build ok, 1.46 million runs, no crash |
| 9c's scripted session, 12 launches | 12 result lines, 0 failed (tables in Measurements) |
| the large-object churn (`scenario=large`, 3 launches, `idle` beside) | 0 of 1200 frames missed in all six |
| `just apps` | macOS and iOS: exit 0, 0 errors, 0 warnings |
| clean build (`--scratch-path .build/clean-check`) | exit 0, 0 errors, 0 warnings |

(340 is `KajoVMTests`, 84 `KajoCompilerTests`.) The clean build took 11 s
from an empty scratch path (the toolchain's compilation cache, as since
8e); `just ios-check` typechecks every KajoVM file with strict memory
safety from nothing and reports no warning either. The disassembly
comparison of the Hot-path check was redone on 7987f59's
`just arc-check` build. The bench A/B (Measurements) ran on f01333b; the
VM's code after it changed only `allocateLarge`'s slow path and
`allocateOld`'s fallback count, out of line from every kernel, and
`interpret` is identical.

## Commands

```zsh
swift test --filter 'LargeObjectTests|LargeObjectVMTests|VMEndTests'
KAJO_MEASURE_LARGE=1 swift test -c release -Xswiftc -enable-testing --scratch-path .build/release-tests \
  --filter 'largeObjectMeasurements|largeObjectFragmentation|markingAMillionSlotArrayMeasured'
swift run kajo test kernel.img --filter 'LargeObjectTest>>'
scripts/mac-shell.sh run out.txt mode=scenario scenario=large seconds=10      # the large-object churn
scripts/mac-shell.sh run out.txt mode=devsession classes=2000 load=none        # 9c's scripted session
KAJO_WRITE_FUZZ_SEEDS=1 swift test --filter 'mutatedImages'                     # the snapshot fuzzer's seeds
```
