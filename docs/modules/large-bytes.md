# Large bytes (a follow-up to module 10)

Status: built, 2026-11-06, from the brief of the same day (the owner's
answers to module 10 and to the device run of the same day). Code in
`Sources/KajoVM/ObjectMemory/Header.swift`, `ObjectMemory.swift`,
`LargeObjects.swift`, `Verifier.swift`, `Snapshot.swift`, the new
`Sources/KajoVM/ObjectModel/LongBytes.swift`, `Strings.swift`,
`Relocation/Hazard.swift` (primitive 38 over bytes),
`Loader/ImageFile.swift` and `FuzzEntry.swift`; the collector's side in
`Marking/Sweep.swift`, `InitialMark.swift`, `MarkingState.swift`,
`MarkingHost.swift`, `Nursery/YoungAllocation.swift`,
`YoungCollection/Owner.swift` and `Interpreter/InterpreterState.swift`;
the transport's in `Sources/KajoDev/ClientHost.swift`. Kernel:
`Behavior>>basicNew:`, `ByteArray>>replaceFrom:to:with:startingAt:`,
`LargeObjectTest`, `JsonText`'s comment. Shells: `scenario=photo`. The
experiment that chose the representation is `experiments/large-bytes/`.
Tests in `Tests/KajoVMTests/ObjectMemory/LongBytesTests.swift`,
`ObjectModel/LongBytesPrimitiveTests.swift`,
`Marking/FallbackPolicyTests.swift`, `ExtremeIntegerTests`,
`ImageFileTests`, the random programs and `kernel/LargeObjectTest`.

Three parts, in the brief's order; part 2, the fallbacks, was the one
that cost frames.

## What it hides

How long a byte object can be and where its length lives. Smalltalk sees
`ByteArray new: n`, `String`'s operations, `size`, `at:`, `at:put:` and
the copying primitives for any `n` up to 2 147 483 647 bytes, and
`basicNew:` names the limit when it refuses. Nothing above the object
memory learns whether the length is in the header. And, for part 2, why
the collector fell back on the devices: the policy that decides how fast
the marker runs and when an allocation waits for it.

## 1. Bytes past the count field

### The representation (the experiment's choice: a sentinel)

`experiments/large-bytes/RESULTS.md` compared the brief's two candidates
on headers laid out as the VM lays them out. A count in words for byte
objects (with the padding in three header bits, one of them moved from
another field) adds three instructions to every byte bounds check, small
objects included (`lsr`, `and`, `ubfx`, `sub`, `cmp` against today's
`ubfx`, `cmp`), and changes what the count means for every reader. **A
sentinel** adds nothing to the check: a byte object of `longBytesFrom`
(2^24 - 8 = 16 777 208) bytes or more holds `longBytesFrom | n & 7` in the
count field, and its length is its back reference's words: n = (words - 1)
* 8 when n & 7 is 0, else (words - 2) * 8 + n & 7. The field is never
greater than the length, so the existing check `i < count` never admits
an index out of bounds; it only refuses some that are in bounds, and its
failure (out of line already) asks for the true length. The odd bytes
ride in the sentinel's low three bits, so no header bit is spent (46 and
51 stay reserved). Chosen: the sentinel. A wider count field (64 MiB) was
not built: it does not reach a photo and spends the last bits.

- `Header.longBytesFrom`, `Header.isLongBytes` (bytes bit and field at or
  past it), `Header.longLength(words:)`, `Header.countField(bytes:)`,
  `Header.agrees(words:)` (the back reference agrees with the header: equal
  words for every object but a long byte object, whose words must decode
  to a length from `longBytesFrom` to the limit). `Header.bodyWords`
  asserts it is not asked of a long byte object; its readers take the
  words from the back reference (`bodyWords(backRef:)`,
  `ObjectMemory.bodyWords(entry:)`). `Header.isLarge` is true for a long
  one.
- `ObjectMemory.count(of:)` is the length for every object: one `tbz` on
  bit 47 for a pointer object, and for a byte object at or past the
  sentinel an out-of-line read of the back reference
  (`longByteCount`). Every primitive that read a count through it reads
  the length now without a change.
- **The limit** is `Header.maxByteLength`, 2 147 483 647 bytes (2 GiB -
  1): a body is one run whose head's `used` is a UInt32 (4 GiB), the back
  reference counts words in 32 bits (32 GiB), and the heap, its reserve,
  the growth and the nursery region share one 4 GiB reservation, so half
  of it is the most one object may ask for. The heap's size bounds it
  first (a heap smaller than the request refuses it softly, the kernel's
  "no room in the heap for a large object of that size"), then the device's
  memory. `basicNew:` (3) and `newString(count:)` refuse past it before
  any arithmetic on the argument (`n` first, then `n * elementBytes`), and
  the kernel names it: "cannot make an instance of ByteArray with
  2147483648 slots: the largest object has 2147483647" (of a words class,
  the elements that fit).
- **Pointer objects keep the 24-bit limit** (16 777 215 slots, 128 MiB).
  The same sentinel would lift it (slots from the back reference's
  words), but the marker's chunked scan, the scavenge's remembered scan
  and every verifier read a pointer object's slot count from the header
  in their loops (`Marker.swift`, `Scavenge.swift`, `Collect.swift`,
  `Owner.swift`, the verifiers); each would need the back reference for a
  long one, and the remembered scan of a large pointer object is already
  whole (no card table). Left as a question.

### Every reader of a byte count

| reader | where | the length after this follow-up |
|---|---|---|
| allocation | `LargeObjects.tryAllocateLarge`, `initializeObject` | the field from `countField(bytes:)`; the back reference written with the whole body's words |
| eden allocation | `YoungAllocation.allocateYoungSlow` | never long: past eden's large limit it is `allocateOld` |
| the length | `ObjectMemory.count(of:)` | the field, or the back reference for a long one (out of line) |
| the special-send tier's `at:`, `at:put:` | `Special.swift` | `i <= field` unchanged; past the sentinel it fails into the send, whose primitive reads `count(of:)` |
| the special-send tier's `size` | `Special.swift` | a ByteArray whose field is at least the sentinel goes to the send (primitive 95): `cmp`, `ccmp`, `b.hi` on that arm |
| `canStore`, `hasSlot`, v1 `at` | `Dispatch.swift`, `Special.swift` | pointer objects only: unchanged |
| primitives 1, 2 (`at:`, `at:put:`), 95, 132, 133 | `Primitives.swift`, `ObjectModelPrimitives.swift`, `Strings.swift` | `count(of:)` |
| `loadByte`, `storeByte`, `storeByteChecked` | `ObjectMemory.swift` | their assertions use `count(of:)` |
| `Header.bodyWords`, `bodyBytes`, `isLarge` | `Header.swift` | asserted not long; `isLarge` true for long |
| become | `Become.swift` | each body keeps the words of its own back reference |
| reshape | `Reshape.swift` | byte objects are refused (`.byteObject`), as before |
| the sweeps and the block pool | `Collector.swift`, `Sweep.swift`, `BlockHeap` | walk by the back reference and a run's `used`, unchanged; the lazy sweep's freed bytes from `bodyWords(entry:)` |
| the marker | `Marker.swift` | a byte object is not scanned; its marked bytes from the back reference |
| the heap verifier | `Verifier.swift` | the body's bytes from the back reference for a long one, inside its run, then `agrees(words:)` |
| the nursery, marking and relocation verifiers, the relocation host | `NurseryVerifier`, `MarkingVerifier`, `RelocationVerifier`, `RelocationHost` | `bodyWords(entry:)` |
| compaction's fingerprints | `Compaction.swift` | `bodyWords(entry:)`; runs never move |
| the young collector, the scavenge, the young verifier | `Collect.swift`, `Scavenge.swift`, `YoungVerifier.swift` | young objects only: never long |
| the snapshot writer | `Snapshot.swift` | headers and bodies copied as they are |
| the loader | `Snapshot.load` then the heap verifier; `ImageFile` | the verifier's rules; the class format's `admits` reads the field (its low bits keep the length's residue for every element size) |
| strings, hash, search, UTF-8 | `Strings.swift` (120 to 136), `Symbols.swift` | `count(of:)`; past a chunk the polled loops below; 129 (`asSymbol`) refuses a long String (no Symbol is long), 135 answers nil for one, 131 repairs only shorter ones |
| `shallowCopy` (96) | `ObjectModelPrimitives.swift` | `count(of:)`, polled copy |
| primitive 38 | `Hazard.swift`, `LongBytes.swift` | new byte path, `count(of:)` |
| `basicNew:` (3), `newString(count:)` | `Primitives.swift`, `Strings.swift` | up to `maxByteLength` |
| the host's `newString([UInt8])` | `KernelPrimitives.swift` | stays at 16 MiB - 1: an unpolled copy from Swift |
| host values, file writes, the save's path, parsed floats | `text(_:)`, `symbolText`, 148, the save, 78 | `bytesIfShort(of:)`: a long one is refused (a Swift copy of it would not poll) |
| the protocol's reply (161) and request (160) | `ShellPrimitives.lineBytes`, `Server.swift` | a long String is not a line (`text` is nil for it); requests stay at 16 MiB - 1 (`RequestLimits.imageBytes`) |
| methods' bytecodes and literals, Symbols, LargeIntegers | the loader, `LiveMethods`, `Numbers` | at most one block: never long |

### No primitive over bytes keeps a stop waiting

`LongBytes.swift`: byte work over a long object runs in chunks of
`ByteWork.chunk` (256 KiB) with a poll between two chunks
(`Machine.byteWorkPoll`): it parks for a requested stop and services
module 7's rounds, as the interpreter's poll does, but never preempts (a
primitive is not a resume point). The primitive's receiver and arguments
are on its Process's stack, so they are roots at that stop; a new object
only the primitive holds (a copy, a concatenation, a fresh ByteArray
being zeroed) is a pending root while it polls. After a poll that parked,
the primitive checks its objects' lengths again (a two-way become in that
stop could have swapped a body under it) and fails if one changed. A
chunk's addresses are computed from the entry each time: a long object
is a run, which never moves, but no body pointer is kept across a poll.
Over two runs a chunk is one `memset`, `memmove` or `memcmp`; anything
smaller goes byte by byte through the entries as before. The polled work:
the zero fill of `new:` (allocation leaves a long body unzeroed,
`deferZero`, and `Machine.zeroLongBytes` zeroes it), the copies of
`,` (123), `copyFrom:to:` (127), `asString` (130, 131), `shallowCopy`
(96) and primitive 38, the comparisons 120 and 121, the hash 122, the
scalar count 126, the UTF-8 validation of 130 and 131, and the search 134
(every comparison counts as work, inside one long comparison too).

The bound is a counter, not a time: `ByteWorkCounters.longestStretch`,
the most bytes a worker did between two polls, per worker, read through
`VM.byteWorkCounters`. The test runs every polled primitive over a
ByteArray of 16 MiB + 1003 bytes and asserts it at most one chunk; the
broken variant (`VMTestSwitches.noBytePolls`) reports the whole work.

**Primitive 38 copies bytes.** It failed for byte objects and the kernel's
loop ran `at:put:` per byte. Now a byte receiver that is not a String or
Symbol takes bytes from a byte source: a copy of a chunk or less byte by
byte with the post-store check (the receiver may be an old object the
relocator moves), a longer one (between two runs) one `memmove` per chunk.
A copy within one object whose target overlaps after its source fails and
the loop runs, as before. `ByteArray>>replaceFrom:to:with:startingAt:`
names the primitive, so `copyFrom:to:`, `,` and `copyWith:` of a ByteArray
use it.

### The image format

The header the snapshot writes is unchanged in layout, but what its count
means for a byte object of 16 777 208 to 16 777 215 bytes is not (module
10's images could hold one), so module 1's snapshot is **version 5** and
the image format **version 6**; older ones are refused ("made before the
large-bytes follow-up's long byte objects: rebuild it from its sources").
The loader's rules are the heap verifier's: module 10's run walk already
requires a head's back reference to be its run's `used`, so a long
object's length cannot pass its run; the entry check now reads a long
body's bytes from the back reference, requires the body inside its run,
and `agrees(words:)` refuses a sentinel on a short body. Fixtures: a
length past its run (refused: "run at block 1: its body of 2101374 words
is not its used 16778224") and a sentinel on a short body (refused: "a
body of 112 bytes in a block of kind 0"); with
`TestSwitches.trustLongLength` (the broken variant) the first loads and
the object's length passes the end of its run. The snapshot fuzzer's
seeds were upgraded (version words only) and gained `long-bytes.img`, an
image with a ByteArray of 16 MiB + 1003 bytes; `FuzzEntry`'s heap went
from 64 blocks to 1024 (32 MiB, reserved and touched only as used) so that
seed loads. `mutatedImagesWithALongByteObjectLoadCleanOrAreRejected` flips
bits in its header's count, its back reference's words, its run's used
word and anywhere.

### The random programs and the kernel

The random programs' large-object step now also calls `nil longBytes: v`:
a ByteArray of 16 MiB + 1003 bytes, `v` stored at its end and past the
sentinel, read back, its size checked (the answer is `v` whatever the
size). Four configurations make the long one, with their heap raised to
128 MiB (4096 blocks) to hold a few at once: `oneWorker` and
`eightWorkers` (the ordinary paths), `cycleEveryScavenge` (marking and the
lazy sweep over them) and `localCollection` (module 7 beside them). The
others make a 4100-byte one: their heaps (8 MiB, or the exhausted
reserve's few blocks) cannot hold a long one, and the stress modes (a
collection at every allocation, a stop at every poll) would spend their
time zeroing. The snapshot modes use the short form. `LargeObjectTest`
gains a ByteArray past the count field (indexed past the sentinel, copied
in part and whole, an index past the end failing) and a String past it
(concatenated, cut, compared, hashed), and `new:` past the byte limit
naming 2147483647.

## 2. Fallbacks on the devices

### What ran out (before)

Every fallback now records its circumstances before the full collection
runs (`FallbackRecord`, `fallbackLog` on the run line: the cause, the
phase, the cycle's trigger, the time since the cycle started and since
the last apply, the sweep's progress, the entry table's high water and
its pool and pending runs, old entries, blocks against the soft limit,
the marker's QoS and whether the policy wanted it raised). The first
device block (981fc8f's build, 20:37 to 20:53; iPad and iPhone
interleaved, ten rounds of storm at 5 and 7 workers with and without 1000
events per second, idle and the large churn) reproduced both:

| device, row | launches | with a fallback | frames missed | full collection |
|---|--:|--:|--:|--:|
| iPad storm, 5 workers | 10 | 1 | 4 in 1 | 41 ms |
| iPad storm, 7 workers | 10 | 8 | 4 to 6 in 8 | 39 to 62 ms |
| iPhone storm, 5 workers | 10 | 0 | 0 | |
| iPhone storm, 7 workers | 10 | 10 (17 fallbacks) | 1 to 10 in 9 | 40 to 63 ms |
| iPad large churn | 10 | 9 (17) | 0 | |
| iPhone large churn | 10 | 8 (23) | 0 | |

(Thermal nominal on the iPad throughout, nominal to serious on the
iPhone.) `events=1000` does not matter: launches with and without it fell
back alike, so the morning's matrix passes, two launches per worker count,
were too few to see a rate of about a half at 7 workers and a tenth at 5.

- **The storm ran out of entries, not old space.** Every storm fallback
  was `entries/sweeping` (one `entries/swept`): the young allocation found the entry table empty
  (high water 100 percent, no free run in the pool) while the lazy sweep
  was 29 to 97 percent through the snapshot, 170 to 480 ms after the cycle
  started, holding 777 to 3169 pending runs (up to 4096 entries each)
  that no allocator sees until the apply. Old space was 71 to 74 percent
  of its soft limit, so the QoS policy, which looked only at old space
  (25 percent headroom) and only at the initial mark, never raised the
  marker: it marked and swept at utility (QoS 17) on efficiency cores,
  and with 7 busy workers on six cores it was starved (115 ms of wall time
  per 9 ms of marking CPU, sweeps of 100 to 240 ms). Cycles were started
  by the entries trigger (60 percent of the table, 10 million entries)
  while the storm promoted 8 million objects a second; the table's
  remaining 40 percent outlasted a starved sweep only sometimes.
- **The large churn ran out of old space while a cycle was marking.** The
  records taken before the collection (`old/marking/floor`): old space at
  98.7 to 99.9 percent of its soft limit, 10 to 18 ms into a cycle that had
  started 20 to 28 ms after the last apply; the trigger fired (`floor`,
  every time), but at a churn of about 1 GB/s a cycle that the marker on
  efficiency cores finished in 10 to 20 ms was sometimes not done when the
  run did not fit. Before the record was moved ahead of the collection it
  read `idle`: the full collection's hook had already finished the cycle.
- No trigger failed to start (`triggersNotStarted` 0) and no large trigger
  lost its object (`largeTriggersUnrooted` 0).

### What changed

1. **The QoS policy watches the entry table and is decided while a cycle
   runs** (`updateWantedQoS(_:oldEntries:)`, `wantsRaise`): the marker is
   raised when either old space's headroom or the entry table's (the
   estimate of old entries, which still holds the entries a sweep has
   freed until its apply) is under `escalateBelow`, decided at the initial
   mark as before and now also at the end of every module 7 young
   collection while a cycle marks or sweeps (`afterYoungCollection`, from
   the owner's own estimate, `youngOldEntries`). The apply lowers it only
   when both headrooms are above the threshold. Forced cycles count old
   entries first (`startCycleInStop` did not).
2. **An empty entry table during a sweep finishes the sweep in the stop**
   (`finishSweepInStop(_:for: .entries)`, from `youngPause`): the sweep's
   remainder and the apply, as module 1's operations do first, instead of
   module 1's full collection; counted (`sweepsForEntries`, its time
   `sweepsInStopMs`), never hidden. The allocation's retry finds the
   entries; only a second empty table is out of memory, as before.
3. **An old allocation without room finishes a pending sweep in its stop**
   (`finishSweepInStop(_:for: .oldAllocation)`, `sweepsForOld`) before
   module 1's collection, and **one that finds a cycle still marking
   waits for it** (`waitForMarkingCycle`), as does a young allocation that
   finds the entry table empty while a cycle marks (c196de8: after the
   first final block, the iPhone's one remaining storm fallback at 7
   workers came in the first cycle's marking, 376 ms in, the marker asked
   to rise but too starved at utility to reach the poll where it raises
   itself): the policy raises the marker and
   the allocating worker waits for the final mark, at most
   `MarkingConfig.allocationWaitMs` (100 ms), polling for stops and rounds
   as a long primitive does, never inside a stop, an object only the
   allocation holds a pending root meanwhile; the stop that follows
   finishes the sweep. A background worker only: the main worker does not
   wait (a frame is shorter than the bound) and falls back as before.
   Counted: `allocWaits`, their time, the longest, `allocWaitTimeouts`.
4. A first version decided the policy at every large allocation while a
   cycle ran. On the iPad it raised the marker for every cycle (747 of 749
   at user-initiated), cycles went from 520 to 750 per 10 s and the main
   thread's stopped time from 157 to 266 ms per 10 s; that block was
   stopped by hand (`dev/after2`) and the decision replaced by item 3,
   which raises the marker only for a cycle an allocation is waiting on.

No model covers these: the young-collection model's old-space collector
frees each unmarked snapshot entry in a step of its own with no pending
list, so finishing the sweep in a pause is a schedule it already
explores; the apply and the module 1 hook that finishes a sweep in a pause
are module 5's, unchanged; the wait is outside every stop and parks as a
poll does.

### After

The last block ran c196de8's build on both devices (the final code but
for f4f625c, which only moves the fallback record's read of the marker's
QoS to an atomic after ThreadSanitizer reported it; no behaviour changed),
2026-11-06 22:13 to 22:33, interleaved as the first (ten rounds: storm at
5 and at 7 workers, with and without 1000 events per second alternating,
idle, the large churn and the photo churn, the iPad then the iPhone each
round; the first row again at the end), 2.5 minutes after the previous
block; the iPad at nominal and fair, the iPhone from nominal to serious
(`dev/final2/`). The Mac's load average 1.4 to 2.5 (Swift builds ran
beside it). Main thread stopped by others, ms per 10 s, p50 [range]:

| device, row | launches | with a fallback | frames missed | stopped by others | the first block's | shells.md's rows |
|---|--:|--:|--:|--:|--:|--:|
| iPad storm, 5 workers | 10 | 0 | 0 | 53.6 [47.7–57.9] | 50.1 [46.7–58.4] | 53.3 [51.7–54.0] |
| iPad storm, 7 workers | 10 | 0 | 0 | 70.7 [62.4–75.1] | 66.6 [57.7–80.7] | 80.0 [50.7–82.9] |
| iPhone storm, 5 workers | 10 | 0 | 1 frame in 1 | 38.4 [30.4–50.3] | 35.8 [27.7–40.5] | 48.1 [44.8–49.5] |
| iPhone storm, 7 workers | 10 | 0 | 2 frames in 1 | 47.5 [31.6–67.7] | 42.4 [33.3–51.5] | |
| iPad large churn | 10 | 0 | 0 | 166.4 [162.0–175.4] | 157.7 [138.4–167.6] | 160.0 [152.7–165.5] |
| iPhone large churn | 10 | 0 | 0 | 70.8 [64.5–76.8] | 116.5 [103.7–133.0] | 117.0 [113.2–124.7] |
| iPad photo churn | 10 | 0 | 0 | 1.7 [1.4–1.9] | | |
| iPhone photo churn | 10 | 0 | 0 | 4.6 [3.2–5.5] | | |

- **No fallback in 80 launches** (the first block: 9 of 20 storm launches
  and 17 of 20 large-churn launches with one or more).
- **Three frames missed in two launches, both the iPhone at thermal
  serious, neither a fallback**: a storm at 7 workers (2 frames, gap 22
  ms) with a final mark of 20 ms and a 15.7 ms event turn, and one at 5
  workers (1 frame, gap 16.7 ms) with an 8.3 ms final mark and a 9.4 ms
  acknowledgement. No sweep was finished in a stop and no allocation
  waited in either. These are the final mark's length under the storm
  (module 9a's iPhone rows: max 7.4 to 17.3 ms with young collection on,
  "not investigated"), not this follow-up's fallbacks, which before cost
  4 to 10 frames each. (The final mark on the devices, 2026-11-07, found
  that "final mark" to be the stopper's wait for open young collections
  before its request, the world running, and the stop 0.2 to 0.5 ms; the
  frames went to the initial mark's young-root scan, a main-thread flip
  that waited with that stopper, and in local mode the main worker's own
  collections: `docs/modules/final-mark.md`.)
- **The storm needed only the policy**: the marker was raised 1 to 17
  times a launch; no allocation waited and no sweep was finished in a
  stop. **The large churn needed the rest on the iPad**: 72 to 95 waits a
  launch (the longest 3.0 ms, none timed out) and 353 to 416 sweeps
  finished in a stop (48 to 57 ms of them in all per 10 s), cycles 757 to
  761 per 10 s against 520; on the iPhone 0 to 6 waits (the longest 9.0
  ms) and 1 to 8 finished sweeps.
- **The main thread's stopped time** is within the earlier rows but for
  the iPad's large churn: 166 [162–175] against 160 [153–166] in
  shells.md and 158 [138–168] in the first block, the finished sweeps'
  stops and the shorter, more frequent cycles they bring. On the iPhone
  the large churn's fell from 117 to 71.
- The first block of the final code but one (6f051b0, 21:41 to 22:02,
  `dev/final/`) differed in one rule: the young allocation did not yet
  wait for a marking cycle. It counted one fallback in 80 launches, the
  iPhone's storm at 7 workers at serious, `entries/marking` 376 ms into
  the run's first cycle with the marker still at utility though the
  policy wanted it raised (starved, it never reached the poll where it
  raises itself); c196de8 made that allocation wait. That block also
  had an iPad large-churn launch miss 2 frames behind a 19.5 ms main-thread
  frame turn with no stop longer than a millisecond; not explained.
- At 7 workers on the iPhone (more busy threads than its two performance
  cores) no fallback remained in these ten launches. The shells' default
  of 5 workers stays.

## 3. Pieces against one String

Built behind a switch (6320513: `DevProtocol oneString:` for the replies
and events the image writes, `ClientHost.linesWhole` for the lines its
client receives, the shells' `lineform`, `replies` and `received`
options), measured, and the cheaper form kept in each direction (6f051b0
deleted the switch):

- **The image's replies (the writer)**: 100 `package.selectors` replies of
  the kernel's selectors (56 898 bytes each) from a headless target to the
  Swift client, release build, three rounds interleaved: **pieces 1181 to
  1188 ms, one String 1589 to 1597 ms**; old-space bytes allocated 18.0 MB
  against 35.1 MB, of which large objects 3.3 MB against 24.5 MB; promoted
  6.07 MB both; no marking cycle in either (a 512 MiB heap). One String is
  34 percent slower and allocates twice the old space: `Json write:`
  builds a ByteArray that grows by copying and is then copied into a
  String, all old at birth past a block, where the pieces are 16 KiB
  ByteArrays that die young. **Pieces kept.**
- **The lines the image's client receives (the reader)**: 9c's scripted
  session on the Mac mini's display, 2000 classes, no load, the image both
  target and client (a local target), three launches of each combination
  interleaved:

| replies / received | session s | `class.hierarchy` ms | `package.selectors` ms | frames missed |
|---|--:|--:|--:|--:|
| pieces / pieces | 4.93 to 5.18 | 308 to 336 | 397 to 439 | 38 to 53 |
| pieces / one String | 4.43 to 4.55 | 253 to 267 | 323 to 345 | 41 to 45 |
| one String / pieces | 5.10 to 5.29 | 317 to 330 | 431 to 462 | 39 to 50 |
| one String / one String | 4.57 to 4.64 | 254 to 273 | 355 to 382 | 40 to 45 |

  (The two sets of runs: `p3/mac-devsession.txt` and
  `mac-devsession2.txt`; one pieces/pieces launch of the second set ran
  189 s with the display asleep and is left out.) Reading a line through
  `JsonText`'s pieces costs the image more than reading one String; the
  host already holds the line whole. **One String kept** for received
  lines up to 16 MiB - 1 (what the host hands the image as one String);
  a longer line still arrives in pieces of that size. The image's
  requests and the server's requests to the image were one String
  already.
- Marking cycles per 100 large replies: none started in either form in
  the headless runs (old space far from its floor); the old-space bytes
  above are the cost they would pay. The main thread's stopped time while
  a serving shell answers them, and the same from a device, were not
  measured (Not done).

## Measurements

Mac mini, M2 Pro (8 performance and 4 efficiency cores, 32 GB), macOS 27,
swift.org Swift 6.4.2, 2026-11-06; the devices in part 2's tables. Every
raw line is in the session's scratchpad (`largebytes/`).

### Long byte objects on the Mac

`LongBytesMeasurement.longByteObjectsMeasured` (KAJO_MEASURE_LONGBYTES=1,
release with `-enable-testing`, verifiers off, one background worker, a
2.25 GiB heap; `measure/longbytes-mac.txt`). Allocation is `ByteArray
new:` through the VM (its zero fill polled), twice; `at:put:` and `at:`
are kasm loops over every byte; the copy is primitive 38 from one into
the other, while the host stops the world every 2 ms: the time each stop
took is how long the copy kept it waiting. The free is a full collection
with both dropped, against one keeping them.

| ByteArray | allocate | `at:put:` over all | `at:` over all | copy (38) | stops during the copy, p50 / max | longest stretch between polls | polls | collection keeping / freeing both |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| 16 MiB | 1.52 to 1.57 ms | 449 ms (26.7 ns/byte) | 458 ms | 3.0 ms | 0.008 / 0.008 ms | 262 144 B | 189 | 0.29 / 0.19 ms |
| 64 MiB | 4.55 ms | 1803 ms (26.9) | 1788 ms | 6.0 ms | 0.032 / 0.032 ms | 262 144 B | 765 | 0.24 / 0.21 ms |
| 256 MiB | 18.9 to 19.7 ms | 7223 ms (26.9) | 7172 ms | 18.2 ms | 0.021 / 0.026 ms | 262 144 B | 3069 | 0.23 / 0.20 ms |
| 1 GiB | 70.3 to 73.1 ms | 28 894 ms (26.9) | 28 667 ms | 57.6 ms | 0.016 / 0.093 ms | 262 144 B | 12 285 | 0.22 / 0.20 ms |
| 256 MiB, polls off (broken) | 18.1 to 20.4 ms | | | 16.1 ms | 10.1 / 10.1 ms | 268 435 456 B | 0 | 0.22 / 0.20 ms |

- Allocation is the zero fill, 14 to 15 GB/s with the first touch of every
  page; freeing a run costs nothing measurable (the sweep frees a head's
  blocks in its loop), as module 10 found.
- `at:` and `at:put:` cost the same per byte past the sentinel as below it
  (26.7 ns at 16 MiB, all below; 26.9 at 1 GiB, nearly all past): the
  special send's bounds check fails past the sentinel and the send's
  primitive answers, and the loop's arithmetic and sends dominate either
  way.
- A copy of 1 GiB (one `memmove` per 256 KiB) keeps a stop waiting at most
  0.093 ms; without the polls a copy of 256 MiB kept it 10.1 ms (one of
  1 GiB, not run so, would keep it about four times that).
- The longest stretch between two polls is one chunk in every row, the
  test's bound; with polls off it is the whole work.

### The photo churn

`scenario=photo`: one background Process allocating a 12-megapixel RGBA
photo (a ByteArray of 48 000 000 bytes, past the count field), filling it
from a 16 000-byte row (3000 copies through primitive 38), checking both
ends and dropping it, forever; the main thread's frame load and probe as
in every scenario; 5 workers, 512 MiB heap, offload young collection.

| host | launches | frames missed | main stopped by others ms/10 s | marking cycles | fallbacks | peak MB | power W |
|---|--:|--:|--:|--:|--:|--:|--:|
| Mac mini (display, 120 Hz) | 3 | 0, 0, 0 | 2.6 to 4.3 | 71 | 0 | 369 | 6.3 |
| iPad Pro | 10 | 0 in every launch | 1.4 to 1.9 | 16 | 0 | 341 | 0.10 |
| iPhone 13 Pro | 10 | 0 in every launch | 3.2 to 5.5 | 44 to 53 | 0 | 354 | 2.5 |

### The Mac's rows

The same build in the macOS shell on the Mac mini's display, three
launches each interleaved (`measure/mac-scenarios.txt`): storm at 7
workers 0 frames missed, the main thread stopped 83 to 101 ms per 10 s
(shells.md: 89 to 99), 0 fallbacks; the large churn 0 missed, 61 to 63 ms
(module 10: 59 to 67), 0 fallbacks, 1194 to 1199 cycles per 10 s
(module 10's run: 811 to 819; no sweep was finished in a stop and no
allocation waited on the Mac, so the difference is the churn's own rate,
whose 16 MiB ByteArray is now zeroed by `memset` in chunks rather than a
store per word; not separated further); idle 0 missed. The Mac's rows
stay as they were.

### Energy on the phone

The process's CPU energy (`ri_energy_nj`) and the marker thread's
(`proc_pidinfo` flavor 34), the iPhone 13 Pro, p50 of ten launches each,
the first device block against the last (both from nominal to serious,
interleaved with the iPad):

| row | power W before / after | marker mJ per 10 s before / after | marker CPU ms before / after |
|---|--:|--:|--:|
| storm, 5 workers | 4.14 / 3.96 | 234 / 249 | 785 / 745 |
| storm, 7 workers | 3.94 / 3.76 | 102 / 355 | 342 / 679 |
| large churn | 3.25 / 2.81 | 1691 / 1815 | 3281 / 3593 |

The marker runs more (it is raised while it is behind, and the storm's
cycles finish instead of being abandoned by fallbacks), a few tenths of a
joule per 10 s; the process uses less, since the full collections are gone.
Neither counts DRAM, the display or the render server.

### The kernels against the starting commit

The starting commit's `kajo` (510a391, from a worktree) against this
follow-up's (6f051b0), both `-c release -Xswiftc -enable-testing` with
`-align-all-nofallthru-blocks=5 -align-loops=32`; five runs interleaved,
`--slice-ms 0`, 2026-11-06 21:41 to 21:46 (load average 3.3 to 5.5, the
devices' block running); median (min to max) ms, every checksum equal on
both sides and the published one (`ab/bench-ab.txt`). The commits after
6f051b0 change only the allocation slow paths (the waits), out of line
from every kernel, and `interpret` is identical on the final commit too.

| kernel | workers | start ms | large bytes ms | ratio | checksum |
|---|--:|--:|--:|--:|---|
| alloc | 1 | 2928.5 (2920 to 2938) | 2950.0 (2937 to 2951) | **1.007** | 41950911 |
| alloc | 8 | 484.7 (443 to 512) | 476.3 (459 to 485) | **0.983** | 42008248 |
| arith | 1 | 2551.7 (2541 to 2554) | 2543.6 (2542 to 2559) | **0.997** | 372800000 |
| arith | 8 | 340.7 (337 to 354) | 339.8 (338 to 349) | **0.997** | 372800000 |
| fib | 1 | 1693.0 (1682 to 1701) | 1694.1 (1691 to 1703) | **1.001** | 24682992 |
| fib | 8 | 234.5 (218 to 238) | 226.5 (218 to 245) | **0.966** | 24682992 |
| ivars | 1 | 1968.1 (1960 to 1972) | 1973.7 (1964 to 1978) | **1.003** | 36383626 |
| ivars | 8 | 261.3 (252 to 275) | 260.0 (252 to 276) | **0.995** | 71714128 |
| sends | 1 | 2591.0 (2573 to 2601) | 2611.5 (2598 to 2616) | **1.008** | 1066666666666668 |
| sends | 8 | 346.4 (333 to 354) | 340.9 (335 to 364) | **0.984** | 133333335000001 |
| storeheavy | 1 | 2405.5 (2396 to 2411) | 2407.1 (2397 to 2417) | **1.001** | 512000 |
| storeheavy | 8 | 320.2 (309 to 336) | 323.9 (309 to 333) | **1.012** | 512000 |
| Smalltalk closures | 1 | 3809.2 (3797 to 3825) | 3803.0 (3780 to 3822) | **0.998** | 210210000 |
| Smalltalk closures | 8 | 500.8 (485 to 530) | 509.8 (489 to 526) | **1.018** | 209214000 |
| Smalltalk ivars | 1 | 1964.7 (1956 to 1966) | 1968.0 (1962 to 1970) | **1.002** | 36383626 |
| Smalltalk ivars | 8 | 253.1 (251 to 273) | 267.3 (252 to 273) | **1.056** | 71714128 |
| Smalltalk sends | 1 | 2280.9 (2269 to 2306) | 2295.6 (2285 to 2305) | **1.006** | 1066666666666668 |
| Smalltalk sends | 8 | 299.1 (295 to 319) | 300.4 (295 to 328) | **1.004** | 133333335000001 |

Within noise: 0.997 to 1.008 on one worker; 0.966 to 1.056 on eight with
overlapping ranges (Smalltalk ivars on eight: 251 to 273 against 252 to
273).

## Changes to earlier modules

- **Module 1**: `Header`'s sentinel and its helpers; `count(of:)` exact;
  `bodyWords(entry:)`; `tryAllocateAny`/`tryAllocateLarge`/`allocateBytes`
  take `deferZero`; the heap verifier's entry check for long bodies and
  `TestSwitches.trustCountField`, `trustLongLength`; snapshot version 5;
  `bytesIfShort(of:)`; become keeps each body's words; compaction's
  fingerprints.
- **Module 2 and 8 (primitives)**: `basicNew:` and `newString(count:)` up
  to `maxByteLength`; the special send's `size` arm; primitive 38 over
  bytes; the string primitives' polled paths; `shallowCopy`; image format
  6; `FuzzEntry`'s heap.
- **Module 3**: `InterpreterState.byteWork`, `VM.byteWorkCounters`,
  `VMTestSwitches.noBytePolls`; `Counter.triggersNotStarted`,
  `largeTriggersUnrooted`.
- **Module 4**: `youngPause` finishes a sweep for an empty table; the
  allocation counts a full collection only when one ran.
- **Module 5**: `FallbackRecord`s and the fallback counters by cause; the
  QoS policy on the entry table and while a cycle runs; `finishSweepInStop`;
  `waitForMarkingCycle` and `MarkingConfig.allocationWaitMs`; the apply's
  lowering on both headrooms; `MarkingTestSwitches.qosOnBlocksOnly`,
  `noSweepForEntries`.
- **Module 7**: `afterYoungCollection` decides the policy while a cycle
  runs; `youngOldEntries`.
- **Module 10**: the marker's and the lazy sweep's byte accounting for
  long objects; `startCycleAfterLargeAllocation` unchanged in the end.
- **Modules 9b to 9d**: a received line is one String up to 16 MiB - 1;
  the reply's pieces stay.
- **Module 3's random programs**: the long-bytes step.
- **Module 9a's shells**: `scenario=photo`; the run line's fallback,
  wait and policy keys.

## Deviations from the brief

- **The limit is 2 GiB - 1**, not "at least 1 GiB" left open: what the
  reservation and the run's 32-bit `used` allow (above).
- **The polled loops do not use module 7's blocking regions**: a blocking
  region keeps a worker out of rounds, not out of stops, and a run's
  bytes need no protection from the relocator; a poll between chunks is
  what bounds the stop.
- **Fallbacks while marking became a bounded wait, and sweeps finished in
  a stop are counted beside the fallbacks**: they are stops the main
  thread waits for (sub-millisecond on the devices' large churn), not
  full collections. The brief's "count no fallback" holds; the stops are
  reported.
- **The large allocation's own QoS decision was built and removed** (part
  2, item 4).
- **Part 3's choice is per direction**, not one form: the measurements
  disagree by direction.
- **Lines past 16 MiB - 1 still arrive in pieces**: the host's String for
  the image is bounded there (its copy does not poll).

## Tests

Swift: `KajoVMTests` and `KajoCompilerTests` (counts in Gates).

- `LongBytesTests` (object memory): a byte object at 2^24 - 9, at the
  sentinel and past it (S, S + 1, S + 7, S + 8, S + 9, 20 000 003 bytes)
  keeps its length, its field is the sentinel exactly from S on and never
  more than the length, its last byte is read and written, the heap
  verifies; the limits; a snapshot carries a long ByteArray and loads it
  back; the loader refuses a length past its run and a sentinel on a short
  body; with `trustLongLength` the first loads and its length passes the
  run (the broken variant).
- `LongBytesPrimitiveTests`: a long ByteArray is indexed past the sentinel
  through the special send and the primitives, and its size is the
  primitive's; with `trustCountField` the index past the sentinel fails
  (the broken variant); every polled primitive (`new:`, 38, 130, 122, 96,
  121, 134, 126) over 16 MiB + 1003 bytes in a running VM, the longest
  stretch between polls at most one chunk; with `noBytePolls` the whole
  work (the broken variant). Under ThreadSanitizer the per-byte loops are
  left out (a fill and a copy only): every atomic byte load is
  instrumented and the full set takes minutes.
- `FallbackPolicyTests`: the policy watches the entry table (and, with
  `qosOnBlocksOnly`, does not); it is decided while a cycle runs (and, as
  module 5 built it, is not); an empty table while sweeping finishes the
  sweep (and, with `noSweepForEntries`, falls back); an old allocation
  without room while sweeping finishes the sweep (and falls back without
  the rule); an old allocation and an empty table while marking wait for
  the cycle, the test thread marking once the wait has asked for the
  marker (and, with `allocationWaitMs` 0, fall back while marking).
- `ExtremeIntegerTests`: `basicNew:` of every kind with the old limit, one
  past it, the new limit and one past it; primitive 38 with a byte
  receiver and source, every extreme in every integer position.
- `ImageFileTests`: an image with a ByteArray of 16 MiB + 1003 bytes
  round-trips and 60 seeded mutations of its header, back reference and
  run load cleanly or are refused (and write the fuzzer's seed); a version
  5 image is refused.
- `RandomPrograms`: the long-bytes step; the relocation configuration's
  wait for its cycles (the test fix, 060116e).
- `LongBytesMeasurement` prints when asked.

Kernel: `LargeObjectTest` gains `testByteArraysPastTheCountField` and
`testStringsPastTheCountField`, and `testNewPastTheLimitSignals` the byte
limit.

## Broken variants run by hand

The brief's three are in the suite as test switches, each with the test
that fails without its rule: the bounds check that trusts the sentinel
(`TestSwitches.trustCountField`, `aLongByteArrayIsIndexedPastTheCountField`:
the index past the sentinel fails), the loader that trusts a length past
its run (`trustLongLength`, `aLoaderThatTrustsTheLengthLetsItPassTheRun`:
the image loads and the length passes the run's end), and the long
primitive that never lets a stop in (`VMTestSwitches.noBytePolls`,
`withoutPollsTheLongestStretchIsTheWholeWork`: the longest stretch is the
whole work; measured, a 256 MiB copy kept a stop waiting 10.1 ms against
0.026). Part 2's rules likewise: `qosOnBlocksOnly` (the policy as module 5
built it), `noSweepForEntries` (an empty table or no room while sweeping
falls back), `allocationWaitMs` 0 (no wait while marking). The test fix
(060116e) was checked the other way: the configuration run 20 times alone
under ThreadSanitizer with 12 busy loops selected 15 blocks every time
(`fixtest/summary.txt`); the failure it fixes was the gate run's, once in
the full suite.

## Unsafe surface

120 new lines with `unsafe` (133 added, 13 removed, comments excluded),
all in `Sources/KajoVM`: `Marking/Sweep.swift` 46 (the fallback records,
`finishSweepInStop`, the allocation's wait: the marking state's fields,
the pools' snapshot, the waits under their lock), `ObjectModel/LongBytes.swift`
35 (the polls, the pending roots, `memset`, `memmove` and `memcmp` on
the heap through offsets loaded from the entry), `Marking/MarkingHost.swift`
11 (the waits' sub-state and lock, the QoS atomic, the policy's flag),
`YoungCollection/Owner.swift` 7, `Headless.swift` 4,
`Interpreter/InterpreterState.swift` 3, `Marking/Marker.swift` 3 (the QoS
atomic), `Nursery/YoungAllocation.swift` 3, `ObjectMemory/LargeObjects.swift`
3, `Marking/InitialMark.swift` 2, `Workers/VM.swift` 2,
`ObjectMemory/ObjectMemory.swift` 1. Nothing in `KajoDev` or the shells.
The clean build of the gates reports no strict memory-safety warning.

## Hot-path check

The disassembly of the starting commit's and this follow-up's aligned
`-enable-testing` release builds (the A/B's), normalized for addresses
(`ab/disasm/`, the final commit's in `final-diff-*.txt`):

| function | start | large bytes | difference |
|---|--:|--:|---|
| `interpret` | 1320 instructions | 1320 | four `adrp` page numbers (the code after it grew), nothing else |
| `v1Instruction` | 319 | 319 | one `adrp` page number |
| `ObjectMemory.tryAllocateBytes` | 64 | 64 | none |
| `ObjectMemory.loadByte` | 5 | 5 | none |
| `ObjectMemory.storeByteChecked` | 10 | 10 | none |
| `checkedStoreByte` | 17 | 17 | none |
| `Machine.allocateBytes` | 150 | 149 | one alignment `nop` fewer |
| `specialSend` | 756 | 764 | the `size` arm's `cmp`, `ccmp`, `b.hi` for a ByteArray at the sentinel, and registers renamed around it; `at:` and `at:put:` arms unchanged |
| `primAt` | 64 | 88 | the send's primitive: `count(of:)`'s branch to the long length, inlined |
| `primAtPut` | 136 | 167 | the same |
| `primBasicNew` | 480 | 473 | the limits |

`just arc-check` on the final commit: see Gates.

## Not done

- **Pointer objects past 16 777 215 slots** (the question below).
- **The kernel's `ByteArray>>=` and `hash`** are Smalltalk loops over the
  bytes: correct for a long ByteArray and polled by the interpreter, but
  27 ns a byte; a String's compare and hash are primitives.
- **The host's conversions refuse a long String** (`bytesIfShort`): a
  view's text, a file written by 148, the save's path, a parsed number;
  the file and network primitives that fill a ByteArray were not this
  follow-up's.
- **The other polled primitives at the limit**: comparison, hash, search,
  scalar count and UTF-8 validation were run over 16 MiB + 1003 bytes (the
  test, with its stretch bound), not timed at 1 GiB; only `new:`,
  `at:`/`at:put:` and the copy were.
- **The allocation measurements on the devices** (allocate, `at:`/`at:put:`,
  copy at 16 MiB to 1 GiB): measured on the Mac only; the devices ran the
  photo scenario, which allocates, fills and drops 48 MB ByteArrays.
- **Part 3 on a device and in a serving shell**: the main thread's
  stopped time while a serving shell answers 100 large replies, and the
  round trips from a device, were not measured; the forms were decided on
  the Mac's numbers.
- **The snapshot fuzzer and the long seed**: libFuzzer reads
  `long-bytes.img` (16.8 MB) but, with no `-max_len`, generates and runs
  inputs of at most 1 MiB, so the seed runs truncated (and is refused).
  The seeded mutations of `ImageFileTests` cover it whole; `scripts/fuzz.sh`
  was not given a larger `max_len` (every input would be allowed to grow
  to 17 MB).
- **The `fallbackEntries` key of module 7's report** stays 0 (module 7
  never counted it); the marking report's `fallbacksEntries` is the count.

## Open questions for the owner

1. **The sentinel for pointer objects?** It would lift Arrays past 128 MiB
   at the cost of the back reference read in the marker's chunked scan,
   the remembered scan and the verifiers for a long one; worth it before
   card marking?
2. **The byte limit of 2 GiB - 1**, against the devices' memory (the
   iPhone's `os_proc_available_memory` was 2.1 to 3.0 GB in module 9a's
   runs): enough, or should `basicNew:` also refuse what the process
   cannot hold?
3. **The allocation's wait for a marking cycle** (100 ms, background
   workers only): the right bound, and should the main worker wait a
   frame's slack before it falls back?
4. **Part 3 by direction**: keep pieces for what the image writes and one
   String for what it reads, as measured, or one form both ways for
   simplicity?
5. **The large churn's extra stops on the iPad**: the finished sweeps make
   cycles shorter and more frequent (520 to 760 per 10 s), and the main
   thread's stopped time is 165 to 180 ms per 10 s against the 153 to 166
   of shells.md's rows; acceptable for removing the fallbacks?

## Gates

Every gate ran on f4f625c (the last commit that changes code; the commits
after it are this doc), Mac mini (M2 Pro), swift.org 6.4.2 (the toolchain
first on PATH), 2026-11-06 22:57 to 2026-11-07 01:56, no device run
meanwhile, every output in a file under the session's `largebytes/gates/`,
each step logged with its commit in `largebytes/gates.log`. The first run
(c196de8, 22:33 to 22:57, `gates/run1-c196de8/`) passed the clean build,
`swift test` and `swift test` under load, and was stopped in its
ThreadSanitizer gate: the sanitizer reported the fallback record, taken in
an allocation's stop, reading the marker's `qos` field that the marker
thread writes outside the VM at its start (random programs, `relocate`
and large-object configurations); f4f625c reads it from an atomic the
marker sets beside it, and the whole sequence ran again.

| gate | result |
|---|---|
| clean build (`--scratch-path .build/clean-check`) | exit 0, 0 errors, 0 warnings, 19 s (the toolchain's compilation cache) |
| `swift test` | 369 + 100 passed, 317 + 94 s |
| under load (12 busy loops) | 369 + 100 passed, 370 + 113 s |
| ThreadSanitizer | 369 + 100 passed, 0 reports, 504 + 2420 s |
| ThreadSanitizer under load | 369 + 100 passed, 0 reports, 739 + 2945 s |
| `just ios-check` | exit 0, 0 errors, 0 warnings |
| `just arc-check` | OK: no retain or release in 133 functions, `interpret` 1056 instructions, one indirect branch and one jump table |
| `just golden` | 12 of 12 checksums |
| `just test-release` | 369 + 100 passed |
| `just model-check` | 28 + 5 + 15 passed |
| `just soak` | passed: 1000 seeds under every configuration (27 lines, no failing seed), the long-bytes step in four; the resumed modes saving 908 to 995 of 1000 |
| `just fuzz kasm 600` | libFuzzer build ok, 2.21 million runs, no crash |
| `just fuzz snapshot 600` | libFuzzer build ok, 2.78 million runs, no crash (its seeds upgraded, `long-bytes.img` among them, read whole but run truncated to libFuzzer's default `max_len` of 1 MiB: see Not done) |
| `just fuzz syntax 600` | libFuzzer build ok, 0.98 million runs, no crash |
| `just fuzz protocol 600` | libFuzzer build ok, 1.61 million runs, no crash |
| `just apps` | macOS and iOS: exit 0, 0 errors, 0 warnings |
| `just kernel-test` | 204 tests, 204 passed |
| `just new-check` | ok: both targets in both configurations, 0 errors, 0 warnings; the Release products without the protocol |

(369 is `KajoVMTests`, 17 of them new; 100 `KajoCompilerTests`.) The
disassembly comparison (Hot-path check) is of c196de8's aligned build;
f4f625c changes only the fallback record's read, out of every path the
check covers, and its `just arc-check` passes. The bench A/B ran on
6f051b0; the code after it changed only the allocation slow paths.

## Commands

```zsh
swift test --filter 'LongBytes|FallbackPolicyTests|ExtremeIntegerTests|ImageFileTests'
KAJO_MEASURE_LONGBYTES=1 swift test -c release -Xswiftc -enable-testing --scratch-path .build/release-tests --filter longByteObjectsMeasured
swiftc -O experiments/large-bytes/bench.swift -o /tmp/lb && /tmp/lb        # the representation experiment
scripts/mac-shell.sh run out.txt mode=scenario scenario=photo seconds=10   # the photo churn
DEVICE=<udid> scripts/device.sh run out.txt mode=scenario scenario=storm workers=7 seconds=10 events=1000
KAJO_WRITE_FUZZ_SEEDS=1 swift test --filter 'mutatedImages'                # the snapshot fuzzer's seeds
```
