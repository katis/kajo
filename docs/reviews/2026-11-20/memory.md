# Review: memory (object memory and the young generation) at 821f20f

Third review, 2026-11-20. Area: `Sources/KajoVM/ObjectMemory/`,
`Sources/KajoVM/Nursery/`, `Sources/KajoVM/YoungCollection/`. Nothing was
built or run. Numbers quoted from rows are from files that already exist:
`~/kajo-scratch/main-flips/part4/matrix-mac/scenarios.txt` and
`matrix-mac/mainload.txt` (Mac mini, 7 workers, 2e7d2e3) and
`~/kajo-scratch/main-flips/part4/matrix-iphone/mainload-console.log`
(iPhone, 5 workers, thermal serious). Every "expected gain" is an estimate
until its bound is measured.

## The findings, in the order I would do them

| id | one line | expected gain |
|---|---|---|
| memory.M1 | The storm tree is one eden minus one node: every storm collection finds 93.75 percent of the eden live | Correct numbers. A storm variant out of step should promote about half as much. No VM change |
| memory.M2 | `rememberSlow` does about twelve loads before it tests "already remembered", its exit in 99.99 percent of calls | 1 to 3 percent of worker time on `share`, under 1 on `ring` (estimate) |
| memory.M3 | The concurrent copy loads four range atomics per young reference, one seq_cst load per cross-nursery slot, and copies small bodies through an out-of-line atomic word loop | 2 to 5 percent of a collection's T1 (estimate) |
| memory.A1 | The product's young collector treats weak slots as strong; under always-offload no weakly held young object dies young | Unknown. A counter decides |
| memory.M4 | The entry sweep is 45 percent of a `share` collection; nobody has split its reads from its writes | Decides between "only bitmaps help" and a cheaper stash sweep |
| memory.M5 | A remembered holder is rescanned whole with one entry-table load per slot; the young records count holders, not slots; a large holder is scanned with no service point | Unknown. Two counters decide; an old-map test before the header load is the candidate |
| memory.R1 | The stop-the-world scavenger and the concurrent collector each have their own entry sweep, old-map batching, trim rule, tenuring rule and scratch state | One place to change the sweep or the tenuring rule |
| memory.A2 | The collection policy is spread over four directories; the stall ladder is written four times | One place to add a resource or change a justification rule |
| memory.M6 | `allInstances(of:)` walks the whole entry table once per class, inside a stop | A reshape of a class with S subclasses: S table walks to one old-map walk |
| memory.R2 | The walk of young bodies by back reference is written three times | One place for the "live body" rule |
| memory.A3 | Collectors open-code the header bits, the back reference and table arithmetic that `object-memory.md` says nothing outside module 1 knows | A named collector interface; fewer places to miss a format change |
| memory.M7 | Loading an image copies it three times before the heap copy; saving copies it twice | Peak memory at launch about 3 images lower; launch time unknown |
| memory.M8 | The stop-the-world scavenge copies every root word twice and scans the class table, which is never young | Small; `young=stw` and promote-all only |
| memory.M9 | A promoted object's entry keeps its place among its nursery's stash entries, which the owner rewrites every eden cycle | Guess. A counter decides |
| memory.A4 | `YoungShared.mode` has one possible value; "offloaded" has two sources | Clean-up |
| memory.R3 | Small duplicates: cache-line helpers, the fresh-entry carve, the allocate ladders, the reference and young tests | Clean-up |
| memory.M10 | Small mechanical items: `takeRun`'s scan, carving under the pool lock, `highWater` under a lock, scalar fills, Swift arrays in the sampler | Small each |

Counts: 10 mechanical, 4 architecture, 3 reuse.

## Findings

### memory.M1. The storm's tree is one eden minus one node

- **Where**: `apps/Shared/smalltalk/Shell-Bench/ShellBench.class.st:108-114`
  (`storm`), `BenchNode.class.st` (two instance variables);
  `Tests/KajoVMTests/Fixtures/kernels/allocstorm.kasm:4-8` and `alloc.kasm`
  (`class Node Object 2`, depth 12 then depth 16);
  `Sources/KajoVM/Nursery/NurseryConfig.swift:6-8, 33-35`;
  `Sources/KajoVM/Headless.swift:24-25`.
- **What is there now**: A node is 24 bytes (back reference and two slots).
  A tree of depth 16 is 131 071 nodes, 3 145 704 bytes. The default nursery
  is 4 MiB with two survivor halves of 512 KiB, so the eden is
  `(4 MiB - 1 MiB) & ~127` = 3 145 728 bytes, exactly 131 072 nodes. The
  storm allocates nothing else: one long tree of depth 12 (8 191 nodes),
  then depth-16 trees forever.
- **The cost**: Each eden cycle holds one tree plus one node. The phase of
  the tree build at the moment the eden fills moves by one node a
  collection, so it stays where the long tree put it: 8 191 nodes into the
  eden. At every collection of a background worker's nursery the eden holds
  the last 8 190 nodes of a dead tree and the first 122 882 nodes of the
  tree being built. 93.75 percent of the eden is live, every time. 512 KiB
  survive and die before the next collection; the rest overflows into old
  space and is garbage one tree later. The existing rows confirm it:
  - Mac, `scenario=storm young=offload workers=7`
    (`matrix-mac/scenarios.txt`): 848 302 396 young allocations (18 195
    of them the main worker's) are 6 472 trees' worth; `gc_ycLocal=6470`.
    One collection per tree. Survivors per collection: 141 337 122
    objects of 24 bytes over 6 470 collections is 0.49999 MiB, the
    512 KiB half filled every time. Promoted per collection: 2.29 MB. So
    2.7 to 2.8 MiB of each 3 MiB eden is copied (the model says 2.8125).
  - iPhone, storm with `mainalloc` (`matrix-iphone/mainload-console.log`):
    253 079 899 background allocations are 1 930.9 trees' worth;
    `gc_ycLocal=1930`. `gc_ycOverflowMB=4128.967` of
    `gc_ycPromotedMB=4128.972`.
  So the storm rows under `offload` measure one phase of one resonance. A
  long tree of another depth, or 25 more bytes of eden, gives another
  number: at a phase near 0 a collection would promote nothing; out of step
  the mean is half a tree. ADR 0007's lesson ("survivor-space size decides,
  not N"; "4 to 16 MiB cut promotion 15x") was measured on this kernel: at
  16 MiB the eden holds four trees and the same one partial tree is live,
  2.95 MB of 12 MiB, which predicts about 10x by itself. The `young=stw`
  rows are in step at the start and drift apart as workers run at different
  speeds, so `offload` against `stw` on storm (promoted bytes, run time,
  fallbacks) compares a locked run with a partly unlocked one. Every policy
  tuned on the storm (the marker's QoS, the stalls, the sweep stop, the
  entries trigger) was tuned at this phase.
- **The proposal**: Change no VM code. Keep the row; name it as the worst
  case it is. Add a storm variant out of step with any eden: alternate
  depths 15 and 16, or give `BenchNode` a third slot, or build a small
  random-depth tree between the large ones (same change in
  `allocstorm.kasm` for the headless matrix). Add a line to ADR 0007's
  Built notes and to `docs/modules/nursery.md` Measurements that the
  4 MiB figures are at a locked phase.
- **How to bound it first**: No build. `kajo run prelude lib allocstorm
  --workers 8 --nursery 4096` against `--nursery 4160` and `--nursery
  4032`, five interleaved runs. Read `ycPromotedMB`, `ycOverflowMB`,
  `ycLocalP50ms`, `cycles`. If the resonance is what the arithmetic says,
  a 1.5 percent change of nursery size moves promotion by tens of percent.
  Then the same with the long tree at depth 11 and 13 (phase 3 and 12.5
  percent of the eden).
- **Risk and size**: Touches no invariant. A changed fixture kernel has a
  published checksum (`scripts/golden.sh`); a new kernel beside the old one
  avoids that. Smalltalk tier for the shells' variant, Swift tier if a
  fixture is added. Small.
- **Confidence**: read (the arithmetic and both sources), and the
  `offload` rows agree to three digits. That the `young=stw` rows drift
  out of step is inferred from their lower copy volume (12.8 GB copied
  for 887 million allocations on the Mac's `mainload` control row,
  against 18.9 GB for 847 million under `offload`); I did not trace it.

### memory.M2. The barrier's slow path tests "already remembered" last

- **Where**: `Sources/KajoVM/Nursery/Barrier.swift:64-81` (`rememberSlow`),
  called from `Barrier.swift:38-45` and `Marking/SATB.swift:27-32`.
- **What is there now**: The inline barrier calls `rememberSlow` whenever a
  young value is stored into a holder that is not young in the same
  nursery. An old holder that already has its remembered bit takes the call
  on every such store. The function then runs, in this order:
  ```swift
  guard let a = unsafe s.pointee.young, let n = unsafe workerOf(s).pointee.vm?.pointee.nursery else { return }
  if unsafe site == a.pointee.skipSite { return }
  unsafe a.pointee.barrierSlowCalls &+= 1
  let om = unsafe s.pointee.om
  if unsafe om.headerWord(o.raw) & Header.youngBit != 0 && !a.pointee.rememberYoungHolders { ... }
  ...
  if unsafe r.pointee.load(ordering: .sequentiallyConsistent) & bit != 0 { return }
  ```
- **The cost**: About twelve loads (state to worker to VM to nursery to
  `rem`; `skipSite`; the three words of `om`; the holder's header;
  `rememberYoungHolders`), one read-modify-write of a counter in memory and
  the `ldar`, plus the call. The Mac rows: `share` at 7 workers has
  `gc_barrierSlow=419 219 415` in 10 s for `gc_ycHolders=60 258`; `ring`
  has 164 650 141 for 193 913. So 99.9 percent and more of the calls leave
  at the last line. That is 42 million calls a second on `share`, 0.75 per
  young allocation.
- **The proposal**: Keep the `rem` base in `NurseryAlloc` (second line,
  beside `rememberYoungHolders`). In the young-collection configuration
  (`rememberYoungHolders` true) the holder's header is not needed at all.
  Order: load `a`, load `a.rem`, `ldar` the word, test the bit, return.
  Count after the test, or count the early exit in its own field. The
  `ldar` stays seq_cst (the model's findings 1 and 4). `skipSite` is a test
  switch: test it only on the path that is about to set the bit.
- **How to bound it first**: A cheating build that returns at the top of
  `rememberSlow` when the holder is old (unsound, a benchmark only, never
  committed) gives the ceiling on `share` and `ring`, headless, aligned,
  five runs. If the ceiling is under 1 percent, stop.
- **After**: `share` and `ring` run time and `workerCycles` per iteration;
  the aligned A/B over the kernels (`storeheavy` and `ivars` must not move:
  the inline path is unchanged).
- **Risk and size**: The remembered-set protocol is unchanged (same load,
  same ordering, same `fetch_or`). Guarded by `checkRemembered`
  (`NurseryVerifier.swift`), the barrier-site mutation tests and the young
  model. `NurseryAlloc` gains a field: check that the fast-path fields stay
  in the first 64 bytes. Core tier. Small.
- **Confidence**: read; the gain is an estimate.

### memory.M3. Per-reference and per-slot work in the concurrent copy

- **Where**: `Sources/KajoVM/YoungCollection/Collect.swift:365-378`
  (`classify`), `:506-513` (`rememberFor`), `:519-543` (`drainGrey`),
  `:447` with `Relocation/Relocator.swift:397-403` (`copyBody`);
  `YoungCollection/Rounds.swift:33-43` (`inY`).
- **What is there now**: Three things run per reference or per slot that
  could run per collection or per object.
  1. `classify` reads the Y range of the nursery for every young reference
     of nursery k it meets:
     ```swift
     let r = unsafe y.range(k)
     let inY = unsafe (off >= r[0].load(ordering: .relaxed) && off < r[1].load(ordering: .relaxed))
         || (off >= r[2].load(ordering: .relaxed) && off < r[3].load(ordering: .relaxed))
     ```
     `y.range(k)` is a load through `y`, then up to four atomic loads the
     compiler may not merge. The range is written once, at the opening, by
     `openYoungCollection`, before `Collector.init` runs.
  2. `drainGrey` calls `rememberFor(o, j)` for every slot that names a
     young object of another nursery; each call starts with a seq_cst load
     of `o`'s remembered word. The stop-the-world scavenger collects the
     bits of all slots and makes one `fetch_or` per object
     (`Scavenge.swift:510-517, 575-579`).
  3. Every body, 24 bytes or 8 KiB, is copied by an out-of-line call to
     `copyBody`: one relaxed atomic load and store per word, which the
     compiler neither pairs nor vectorizes.
- **The cost**: The copy is where a local collection's time goes. Storm on
  the Mac: T1 1.58 ms of a 1.95 ms collection; on the iPhone 5.9 of 7.0 ms,
  1 930 local collections in 10 s on four background workers, 434 MB/s.
  Item 1 is five L1 loads and four compares per young reference. Item 2 is
  one `ldar` per cross-nursery slot instead of at most one per object.
  Item 3 is a call per object.
- **The proposal**: (1) Four `let`s in `Collector` (`yLo`, `yHi`, `sLo`,
  `sHi`) read once in `init`; `classify` compares against them. `inY` keeps
  its loads (mutators call it for collections they did not open) but takes
  `om` as a parameter instead of loading three words through `y` per word
  scanned. (2) In `drainGrey` collect `1 << j` over the object's slots and
  call one `rememberFor(o, bits:)` after the loop: one seq_cst load, one
  `fetch_or` when a bit is new, one append per new bit. (3) An inline word
  loop for bodies up to 128 bytes, as `Scavenger.evacuate` has
  (`Scavenge.swift:444-453`), with the same relaxed atomic accesses;
  `copyBody` for the rest.
- **How to bound it first**: A build with (1) and (3) only (both are sound;
  it is a real candidate, not a cheat). Headless `allocstorm` and `share`
  at 1 and 8 workers, aligned, five runs: `ycCopyMBs`, `ycT1P50ms`,
  `ycCpuP50ms`. (2) shows only where copies name other nurseries:
  `ycCrossRemembered` is 5 in storm and 1 in share on the Mac rows, so
  measure it on a kernel that shares young objects across workers, or
  leave it.
- **Risk and size**: (1) rests on "the range does not change while the
  collection is open"; it is written under the safepoint mutex at the
  opening and by nobody else (`Collect.swift:64-68`). (2) keeps the
  ordering of each atomic. (3) keeps module 6's copy protocol word for
  word; the relocation and young models do not change. Guarded by the
  young verifier, the random programs' young configurations, `just
  arc-check`. Core tier. Small.
- **Confidence**: read. The gain is an estimate: the Mac's concurrent copy
  rate (1 548 MB/s, one collector) is already above the stop-the-world rate
  per participant (1 313 MB/s), so the protocol's atomics are not the gap
  the experiment saw.
- **Checked and kept**: the fence after the state-word CAS
  (`Collect.swift:430`) is needed. The copy's loads are relaxed, and on
  ARMv8 a relaxed load may pass an earlier release store or CAS; the fence
  is what orders the copy after the CAS against a mutator's seq_cst slot
  store. `docs/models/relocation.md` says "the fence adds nothing the CAS
  does not already do in this model": that sentence is about the model's
  memory, where every read-modify-write is a full fence. It would help to
  say so beside the fence.

### memory.A1. Two lifetime rules for weak slots; the product runs the weaker one

- **Where**: `Sources/KajoVM/YoungCollection/Collect.swift:473-491`
  (`scanHolder` scans every slot), `:515-543` (`drainGrey`: "Weak and
  ephemeron slots are strong here (v0)"); against
  `Nursery/Scavenge.swift:532-551` (`scanSlots` stops at the named slots of
  a weak object) and `:811-848` (`processWeakSlots`).
- **What is there now**: The stop-the-world scavenge does not trace a weak
  object's indexed slots and nils the ones whose young referent died. The
  concurrent young collector traces them. `young-collection.md` lists it
  under Not done: "a young weak referent dies at the next stop-the-world
  scavenge or full collection".
- **The cost**: Since the main worker always offloads, a product run has no
  stop-the-world scavenge in steady state (`gc_scavenges=0` in every
  `offload` row). So a young object held only weakly is copied to a
  survivor half, copied again to old space at its second collection, and
  freed by a marking cycle: two copies, an old entry, a mark, a sweep, in
  place of dying in the eden. The symbol table's buckets are weak
  (`ObjectModel/Symbols.swift`), so every Symbol made and dropped takes
  that road; so does every entry of a weak registry or cache. The rule is
  also one that the oracle and the product implement differently, which is
  what an oracle is there to prevent.
- **The proposal**: First the counter (below). If it is not near zero:
  port the weak pass. The collector has the class formats
  (`om.gc.pointee.classFormats`, stable outside a stop only if no class is
  defined meanwhile; class definition runs in a stop and stops wait for
  open collections, so the table is stable for one collection). A weak
  holder's indexed slots are not classified; the holder goes on a per
  collection weak list; after the last drain round and before the sweep,
  each listed slot whose referent is in Y and was not copied becomes nil
  with a checked store, under the same hazard and deletion rules as a
  mutator's store. This needs the young model extended (a weak read during
  a collection needs a keep-alive barrier, as module 5's does).
- **How to bound it first**: A counting build: in `scanHolder` and
  `drainGrey`, when the holder's format is weak, count the objects first
  copied through an indexed slot (`weakOnlyCopies`). Run the kernel tests,
  the tools' scripted session (`mode=devsession`) and `collections`. A
  count near zero closes the question; a count that is a visible share of
  `ycPromoted` opens the module.
- **Risk and size**: A new protocol step beside mutators: model first
  (`docs/models/young-collection.md`), the lost-object test before the
  code. Core tier. Medium to large. The counter alone is small.
- **Confidence**: read for the difference; guess for its size.

### memory.M4. The entry sweep: reads or writes?

- **Where**: `Sources/KajoVM/YoungCollection/Collect.swift:689-755`
  (`Collector.sweep`), `Nursery/Scavenge.swift:644-701` (`sweepNursery`).
- **What is there now**: For every entry the collected eden handed out, the
  concurrent sweep loads the header, the state word and the remembered word
  (a second table), and for a dead entry stores a free state word and a
  zero header. The next eden cycle stores both words again when it
  allocates the entry. The sweep's body is a nested function called per
  entry with its counters captured by reference.
- **The cost**: Known in kind (`nursery.md`: 0.073 ms per 4 MiB nursery on
  one worker; the chunk bitmaps are the settled alternative). The rows
  give its share under `offload`: `share` on the Mac, sweep p50 0.199 ms of
  a 0.438 ms collection (T1 is 0.043 ms); storm 0.226 of 1.95 ms; iPhone
  storm 0.46 of 7.0 ms. Per sweep about 2 MB of entries read, 0.5 MB of
  stash read and written, 0.5 MB of remembered words read, and 2 MB of
  entries written. What is not known is how the time divides between the
  reads and the 2 MB of stores.
- **The proposal**: Measure the split before choosing. If the stores are
  most of it: a dead young entry that goes back to its own stash need not
  be marked free in the table at once. "A stash's entries are free in the
  table" is read at stops only (module 1's `sweepEntries`, the free-list
  verifier, `rebuildOldMap`, the snapshot), so each of those could mark
  the stashes' entries free first, O(stash), in its stop. If the reads are
  most of it, only the bitmaps help and this closes.
- **How to bound it first**: A cheating build that skips the two stores
  for dead entries (it breaks module 1's sweep, so run `share` with
  `--verify` off, where no full collection runs: `gc_cycles=0` in that
  row). Read `ycSweepP50ms`. Not committed.
- **Risk and size**: The proposal changes an entry state with many readers
  (AGENTS.md: "every entry state between generations needs exactly one
  owner ... list every reader of the entry table and every verifier's skip
  rule"). Readers to list: `sweepEntries`, `rebuildOldMap`,
  `verifyHeap`, `verifyFreeLists`, `checkYoungBodies`, `processWeakSlots`
  (it tests `isFree` of a dead referent), the snapshot writer and loader,
  `trimStash`, `releaseDeferred`. Core tier. Medium. The bound is small.
- **Confidence**: read for the work per entry; inferred for where the time
  goes.

### memory.M5. Remembered holders: a table hop per slot, no slot counter, no service point

- **Where**: `Sources/KajoVM/YoungCollection/Collect.swift:473-491`
  (`scanHolder`), `:365-378` (`classify`); `Nursery/Scavenge.swift:393-399`
  (`scanWord`), `:555-569` (`scanRemembered`);
  `YoungCollection/YoungState.swift:80-120` (`YoungRecord` has `holders`,
  no slots).
- **What is there now**: A remembered holder is scanned whole at every
  collection of the nursery it is remembered for. For each slot that is a
  reference, the scan loads the referent's header from the entry table to
  learn that it is old. `scanHolder` runs one holder from first slot to
  last with no `servicePoint()` inside.
- **The cost**: One dependent load per reference slot into a 16-byte entry
  that is anywhere in the table. For a holder whose slots name old objects
  that is one likely cache miss per slot, per collection, to copy nothing.
  The owner's answer of 2026-11-06 was "no card marking yet", from an
  estimate of about a millisecond for a million slots; that estimate
  priced the slot scan, not the header load behind each slot. Since module
  10 a holder may have 16 777 215 slots, and it is scanned between two
  service points: every other collection's round and every stop that waits
  for open collections waits for that scan. The stop-the-world path counts
  `remSlots`; the concurrent path, the product's, counts nothing per slot,
  so no `offload` row can say how much of T1 this is.
- **The proposal**: In order. (1) Two counters in `CollectionTally` and
  the run line: slots scanned through remembered holders, and references
  whose header was loaded and found old (nil, true and false apart).
  (2) A service point every 4 096 slots inside `scanHolder` (the holder is
  old; the scan holds no body pointer across the point if it re-reads the
  state word after it). (3) If (1) shows the old share is large: test the
  old map before the header load. One bit per entry, 128 times denser than
  the table; a set bit means old, so the entry is not touched. A clear bit
  falls through to the header as now, so a just-promoted object (its bit
  is set at the sweep) is still read right. Cards for large holders remain
  the owner's "not yet".
- **How to bound it first**: (1) is the bound: read the two counters on
  `ring` (193 913 holders in 10 s on the Mac row), on the shells'
  `scenario=large` (a million-slot Array with young elements stored into
  it) and on the collections benchmark's OrderedCollection part with a
  million adds (its backing Array is a large object once past 4 095
  slots). For (3), a cheating build is the real change; compare T1.
- **Risk and size**: (3) rests on "an old-map bit is set only while the
  entry holds an old object" (verified by `verifyHeap`'s old-map check;
  the bit is cleared before a freed entry is published). (2) must re-read
  the holder's state word after the point (module 6 may move it). Guarded
  by the young verifier and the random programs. Core tier. (1) and (2)
  small, (3) small to medium.
- **Confidence**: read for the code; guess for the size until (1) exists.

### memory.R1. Two young collectors, two of everything

- **Where**:
  - entry sweep: `Nursery/Scavenge.swift:644-701` and
    `YoungCollection/Collect.swift:689-755`;
  - old-map batching `noteOld`: `Scavenge.swift:627-636` and
    `Collect.swift:694-702`;
  - the stash trim rule `edenBytes / 16 + 4096`: `Scavenge.swift:697` and
    `Collect.swift:751`;
  - the tenuring rule (age + 1 below the limit and room in survivor-to,
    else promote; promote-all): `Nursery/Claim.swift:31-42` and
    `Collect.swift:389-407`;
  - per-collection scratch (survivor-to bump, the survivors' log, the
    holders kept): `ScavengeWorker.survCur/survLog/nextRem`
    (`NurseryState.swift:99-118`) and
    `NurserySurvivors.survCur/nextLog/nextCarried` (`:88-92`);
  - the survivor flip: `Scavenge.swift:201-205` and `Collect.swift:213-216`;
  - the header address: `Scavenger.headerAtomic` (`Scavenge.swift:385-387`)
    repeats `ObjectMemory.headerAtomic`.
- **What is there now**: Module 4's scavenge and module 7's collection are
  two programs over the same nursery state. They share `EntryStash`,
  `bumpPromotion` and (since the collectors review) `copyBody` is shared
  with the relocator, but not with the scavenger.
- **The cost**: Two places drift. They already have: weak slots
  (memory.A1), and the bits of a multi-nursery holder are one `fetch_or`
  in one and a seq_cst load per slot in the other (memory.M3). A change
  named in the docs as "behind the module boundary", the chunk bitmaps for
  the entry sweep, would be written twice. So would a tenuring rule that
  reads observed survival (ADR 0007's next item).
- **The proposal**: Three shared pieces, each `@inline(__always)` with the
  per-collector predicate passed in. (1) `sweepYoungLog(stash:, log:,
  isDead:, onOld:)`: the loop over `stash[0, next)` and the survivor log,
  the in-place compaction, the old-map word batching, the trim. The two
  predicates differ ("young without this scavenge's tag" against "young,
  not in survivor-to, remembered word zero, else deferred") and stay with
  their collectors. (2) `tenure(header:, ageLimit:, promoteAll:, room:)`
  answering survive or promote; each collector builds its own header from
  the answer. (3) One name for the trim rule.
- **How to bound it first**: Not a speed change. Compare the disassembly
  of both sweeps before and after (the STW one is under `just arc-check`'s
  eye only through its callers; add both).
- **Risk and size**: Both verifiers (`verifyAfterScavenge`,
  `verifyYoungInStop`), the free-list verifier and the random programs in
  both young modes guard it. Core tier. Medium.
- **Confidence**: read.

### memory.A2. The collection policy lives in four directories

- **Where**:
  - `Nursery/YoungAllocation.swift:59-176` (`allocateYoungSlow`: two stall
    blocks, the stop, the out-of-memory rule), `:182-321` (`youngPause`,
    `fullCollection`, `leavesNoHeadroom`, `runDueFullCollection`,
    `justifiedFullCollection`), `:411-434` (`endYoungGeneration`, the VM's
    end);
  - `Interpreter/InterpreterState.swift:263-330` (`allocateOld`: its own
    stall block and stop);
  - `YoungCollection/Owner.swift:18-123` (`collectOwnNursery`,
    `stallForPromotion`, `scavengeForReserve`), `:224-270`
    (`afterYoungCollection`: the soft-limit request, the trigger, the QoS
    decision, the verifier);
  - `ObjectMemory/LargeObjects.swift:239-257`
    (`startCycleAfterLargeAllocation`: takes a `VMPointer`, reads the
    marker's phase, calls `collectOwnNursery` and `stopWorld`);
  - "did a full collection run in my stop" is inferred from a counter read
    before and after in `YoungAllocation.swift:164, 172`,
    `InterpreterState.swift:304, 327` and `Marking/Pacing.swift:117, 142`
    (two different accessors: `om.counters.collections`, which takes the
    pool lock and sums every context, and `om.gc.pointee.counters`).
- **What is there now**: The ladder "try; stall for the collector; if the
  stall was justified, one full collection; then the out-of-memory rule"
  is written at four sites: entries and promotion in `allocateYoungSlow`,
  old space in `allocateOld`, promotion in `stallForPromotion`. Each has
  its own `justified` flag and its own `defer { stallFallbackDone }`.
- **The cost**: The lessons list has eight entries about these fallbacks
  (a trigger must watch every resource; a fallback must not ask for itself
  again; a waiter waits for the pass that frees what it needs; and more).
  Each was a fix at one or two of these sites. A new resource to stall on,
  or a change of the justification rule, touches all four and the three
  counter comparisons. And `ObjectMemory/`, which `object-memory.md` says
  hides the heap and knows no VM, holds a function that knows workers,
  marking and young collection.
- **The proposal**: One file, `Workers/` or a new `Collection/`, that owns
  "what an allocation does when it finds no room": one function
  `retryWithCollector(vm, w, resource, held:, available:, fallback:)` that
  holds the ladder and the `justified` state, called by the three
  allocation slow paths. `fullCollection`, `runDueFullCollection`,
  `justifiedFullCollection`, `endYoungGeneration` and
  `startCycleAfterLargeAllocation` move there. A stop's work answers what
  it did (an enum: scavenged, swept, full, nothing) in place of the
  counter comparisons.
- **How to bound it first**: Not a speed change. The run line's fallback
  and stall counters by cause and requester must read the same on the
  three matrices before and after.
- **Risk and size**: The stall tests (`AllocationStallTests.swift`), the
  full-heap tests and the random programs' `slowedMarker` and
  no-reserve configurations guard it; `unjustifiedFallbacks` is the
  verifier. Core tier. Medium.
- **Confidence**: read.

### memory.M6. `allInstances(of:)` is a full table walk per class, in a stop

- **Where**: `Sources/KajoVM/ObjectMemory/Reshape.swift:21-33`
  (`allInstances(of:)`), used at `Reshape.swift:75` (once per request),
  `ObjectModel/LiveClasses.swift:521, 696, 697, 764` and
  `Loader/ImageFile.swift:130, 141`; against
  `ObjectMemory/Instances.swift:26-51` (`walkInstances(of:)`).
- **What is there now**: `allInstances(of:)` reads the state word and the
  header of every entry below the high water mark and appends matches to a
  Swift array. `prepareReshape` calls it once per class of the request
  (the class and each subclass). `LiveClasses.swift:764` calls it twice
  per candidate in a `filter`. `walkInstances` does the same job in one
  pass over the old map's words for a set of classes, skipping 64 free
  entries per zero word, and is valid in the same state (after the
  promote-all hook, which `prepareReshape` has already run).
- **The cost**: 16 bytes read per entry per class: 20 MB per class for the
  1.25-million-entry table the image build once left. Adding an instance
  variable to a class with S subclasses is S walks inside one stop, on the
  target the developer is looking at. S is hundreds for a class near the
  root.
- **The proposal**: `prepareReshape` builds one flag table for all its
  requests and makes one `walkInstances` pass, appending to per-request
  lists. The same for the remove and candidate checks in `LiveClasses`
  (count, do not list: "has instances" needs the first hit only, which
  `walkInstances` supports by answering false from `visit`). Keep
  `allInstances(of:)` for callers outside the hook's state, or remove it
  if none is left.
- **How to bound it first**: Time the stop of a redefinition that adds an
  instance variable to `Object`-near classes in the development image (the
  stop record's work time, kind of the define primitive's stop) and count
  the calls. The walk's own cost is the count times the table size.
- **Risk and size**: `walkInstances` requires nothing young and no pending
  sweep; `prepareReshape` is already there. The live-class tests and the
  kernel's class tests guard it. Core tier for `Reshape.swift`. Small.
- **Confidence**: read. The stop's length is an estimate.

### memory.R2. The young-body walk is written three times

- **Where**: `Sources/KajoVM/YoungCollection/Owner.swift:362-383`
  (`youngRootScan`'s `walk`), `Marking/RootScans.swift:117-145`
  (`walkYoungRoots`), `YoungCollection/Collect.swift:645-670`
  (`scanNewHalf`); a fourth, simpler one in
  `Nursery/NurseryVerifier.swift:224-233`.
- **What is there now**: Each walks a range of young bodies by back
  reference: read the back reference, stop at zero words, take the entry
  index, accept the body if the entry's state word is this offset, skip
  bytes and deferred frees, visit each slot, step by the body's words.
  The three differ in small ways: `scanNewHalf` has no `o != 0` test and
  no deferred test; `walkYoungRoots` polls every 256 bodies.
- **The cost**: The rule "a body is live iff its entry leads to it" and
  the body format are module 1's, and three files of two other modules
  each hold a copy. The review fixes' lesson ("an object still being
  built is hidden from every heap walk by one mechanism") is the kind of
  change that has to find all of them.
- **The proposal**: One `ObjectMemory.forEachLiveBody(from:to:every:poll:,
  _ visit: (entry, bodyOffset, header) -> Void)`, `@inline(__always)`,
  beside `BackRef`. The three callers pass their slot loop.
  `youngRootScan` (Owner.swift) now runs only under the test switch
  `youngRootsInStop` (`InitialMark.swift:253-256`); it can become
  `walkYoungRoots` with a poll that always answers true.
- **How to bound it first**: Not a speed change; the disassembly of
  `walkYoungRoots` must keep its shape.
- **Risk and size**: The marking verifier (the lost-object test of the
  young roots) and the young model's new-half test guard it. Core tier.
  Small.
- **Confidence**: read.

### memory.A3. What the collectors know of module 1's layout

- **Where**: `docs/modules/object-memory.md:10-15` ("Nothing outside this
  module computes a body address, reads a header bit, or knows that an
  entry table exists"). Against it: `(h & Header.countMask) &>>
  Header.countShift` open-coded on 17 lines in 8 files (7 lines in my
  area) though `Header.count` exists; `(h & Header.nurseryMask) &>>
  Header.nurseryShift` on 8 lines though `Header.nurseryIndex` exists;
  `om.table + ...` and `om.heapBase + ...` in `Nursery/Scavenge.swift`
  (7 lines) and `YoungCollection/Mutator.swift:117`; the test "a word that
  names an entry" (`v & Oop.objectTagMask != 0 || v == 0`, or its
  negation) written out in 19 files outside `Oop.swift`; `BackRef` decoded
  in `YoungCollection` and `Marking` (memory.R2).
- **What is there now**: The collectors read raw header words for speed
  and decode them in place.
- **The cost**: The lesson "once immediates beyond SmallInteger exist,
  every 'is this a reference' test is the full low-nibble pattern; six
  insertion-barrier sites tested `raw & 1`" is this cost, paid once. The
  next header or tag change (bits 46 and 51 are free; the large-objects
  record mentions widening the count) meets the same spread. The doc's
  sentence is no longer true, so a reader cannot rely on it.
- **The proposal**: A small "collector's view" in `ObjectMemory/`, all
  `@inline(__always)` on raw words so nothing gets slower:
  `Oop.isReferenceWord(_ raw:)`, `Header.slotCount(raw:)`,
  `Header.youngNursery(raw:) -> Int` (and the mask form the barrier uses),
  `om.bodyPointer(atState:)`, with `forEachLiveBody` (memory.R2). Replace
  the open-coded forms in the three directories. Correct the sentence in
  `object-memory.md` to name this view as the boundary.
- **How to bound it first**: `just arc-check` and a disassembly diff of
  `interpret`, `evacuate` (both), `classify` and `scanWord`: identical
  instructions expected.
- **Risk and size**: No behaviour change. Core tier (it touches the core
  directories). Small to medium by line count.
- **Confidence**: read (counts by `grep`).

### memory.M7. An image is copied three times on its way into the heap

- **Where**: `Sources/KajoVM/ObjectMemory/Snapshot.swift:253-257`
  (`Data(contentsOf:)`, then `[UInt8](data)`), `:262` (the loader takes
  `[UInt8]`), `:323-333` (`memcpy` into the heap);
  `Loader/ImageFile.swift:179` (`Array(b[tableEnd...])`, a copy of all but
  the header); `Shell/Shell.swift:376` (`[UInt8](data)`). Saving:
  `Snapshot.swift:202` (one `[UInt8]` of the whole image), `:243-249`
  (`Data(snapshot())`, a second copy, then the write).
- **What is there now**: The snapshot interface is `[UInt8]` in and out.
  A launch holds the file's `Data`, the `[UInt8]` of it, the slice's copy
  and then the heap: three transient copies. After the copy the loader
  runs the whole heap verifier, the image rules and every method's
  verification.
- **The cost**: For an image of N bytes, 3 N of dirty anonymous memory at
  the peak before the heap's own N, on the device where the footprint
  counts, and three passes of `memcpy`. The image is 2.5 to 20 MB today.
  The launch trace has an "image loaded" step; its share of launch is not
  in any doc I found.
- **The proposal**: `load(snapshot: UnsafeRawBufferPointer)` over a
  read-only `mmap` of the file (or `Data` with `.mappedIfSafe`), with the
  `[UInt8]` entry kept as a thin wrapper for the fuzz target. The parser
  already bounds every read by the length. `ImageFile.load` passes a
  sub-range, not a copy. Saving writes the header, the blocks and the
  table to the file descriptor in pieces (`writev` or a few `write`s) in
  place of building one array.
- **How to bound it first**: Read the launch trace (`kajo-launch-report`)
  for "image loaded" on the iPhone with the 2000-class image
  (`KAJO_SHELL_CLASSES`) and the process's peak footprint at that step.
  If the step is a few milliseconds and the peak is no concern, record it
  and close.
- **Risk and size**: The loader is a trust boundary and fuzzed: the
  snapshot fuzzer's corpus must pass unchanged and `just fuzz snapshot`
  must build with coverage ("libFuzzer build: ok"). A mapped file that
  changes under the loader is a new hazard: map private. Core tier
  (`Loader/`, `ObjectMemory/`). Medium.
- **Confidence**: read for the copies; the launch share is not measured.

### memory.M8. The stop-the-world scavenge's roots

- **Where**: `Sources/KajoVM/Workers/Safepoint.swift:300-345`
  (`gatherRoots` appends every stack word of every Process to a Swift
  array), `Nursery/Scavenge.swift:39-51` (copies the object words into
  `ph.roots`, adds module 1's roots, cuts tasks),
  `ObjectMemory/Collector.swift:219-226` (`forEachRoot`: the class table
  first). Against `YoungCollection/Collect.swift:627-640` ("The class
  table and the image's objects are old").
- **What is there now**: Each stack word is appended to a Swift array,
  copied to a raw array, then scanned: three passes and two growing
  allocations in the stop's serial part. Then every class table word is
  scanned as a root: a header load each. Classes are allocated old
  (`Loader/Image.swift:82-83, 313-314` pinned, and
  `LiveClasses.swift:266-297` through module 1's `allocate` in the
  definition's stop), so no class root is ever young. The concurrent collector knows this and
  skips the table; the scavenge does not.
- **The cost**: Per stop-the-world scavenge: two copies of the roots and
  one header load per class (about 1 000 for the kernel, 4 000 for the
  2000-class image). `nursery.md`'s "0.073 of 0.074 ms is the entry sweep"
  was measured with fixture kernels of a few classes. Under `offload` the
  scavenge runs only as the promote-all of module 1's operations and as
  the reserve's fallback, so this is the `young=stw` rows' and the
  developer operations' cost, not the product's steady state.
- **The proposal**: (1) Drop the class table from the scavenge's roots,
  and make the rule checked where it is made: `setClassOop` asserts the
  class is old (a stop-only path). The before-scavenge verifier keeps
  walking it. (2) Root tasks point at the stacks in place
  (`ScavengeTask(words: base, count: sp + 1)`): stacks do not move in a
  stop and roots are values, never rewritten. `gatherRoots` stays for the
  callers that want an array.
- **How to bound it first**: `ScavengeRecord.prepNs` and `critRootsNs` on
  `young=stw` with the kernel image and a deep-stack program, against
  `workNs`. They exist already; nobody has printed them for the kernel
  image.
- **Risk and size**: (1) rests on "class objects are never young"; the
  young verifier would catch a young class after the fact, the new assert
  before. (2) must keep the `result` register and the `keeping` roots
  (lessons: interpreter registers are roots). The random programs under
  `young=stw` guard both. Core tier. Small.
- **Confidence**: read; the cost for a real image is not measured.

### memory.M9. Old entries live among their nursery's stash entries

- **Where**: `Sources/KajoVM/Nursery/Scavenge.swift:656-675` and
  `YoungCollection/Collect.swift:704-746` (a promoted entry is left out of
  the stash; its neighbours go back in); `Nursery/YoungAllocation.swift:
  41-50` (`placeYoung` writes the entry of `stash[next]`).
- **What is there now**: An oop is its entry's offset, so a promoted
  object keeps the entry its nursery gave it. That entry's 16 bytes sit in
  a cache line with the nursery's other stash entries (3 or 7 others).
  The owner rewrites those on every eden cycle: two stores each at the
  sweep, two at the next allocation.
- **The cost**: The header of an old object is read at every send to it
  (its class). When another worker sends to a promoted object, the line
  with its header is invalidated up to four times per neighbour per eden
  cycle by the worker that made it. That is a coherence miss on the
  reader's send path. It needs objects promoted by one worker and used by
  another; `share` and the main thread's use of background results fit.
- **The proposal**: None yet. If the counter shows it: the sweep keeps
  out of the stash the free entries that share a line with an old entry,
  and gives them to the pool for old allocation (large objects, pinned
  ones), so lines become all young or all old. The price is table
  density; the image-size lesson (the size follows the high water mark)
  says to measure that too.
- **How to bound it first**: A counter in the sweep: of the entries it
  frees, how many share a 64-byte line with an entry whose header is old.
  And a headless `share` run with the stashes refilled only from fresh
  entries at the high water mark (a cheating build: promoted entries then
  have no young neighbours for a while) against a normal run, cycles per
  iteration.
- **Risk and size**: The entry-ownership rule again (memory.M4's list of
  readers). Core tier. Medium if built.
- **Confidence**: guess. I read the mechanism; I did not find a number
  that shows the effect.

### memory.A4. One mode, two "offloaded" flags

- **Where**: `Sources/KajoVM/YoungCollection/YoungState.swift:340` (`let
  mode: YoungMode`), `:421-423` (`isOffloaded`), `Owner.swift:184`,
  `YoungHost.swift:22` (`install` returns when the mode is `stw`);
  `Handshake.offloaded` (`YoungState.swift:55`), set at
  `Collect.swift:93`, read at `Collect.swift:163, 211, 266`;
  `Rounds.swift:173-174, 211-212` (two locals never used).
- **What is there now**: Since the main worker always offloads,
  `YoungShared` exists only under `offload`, so `pointee.mode == .offload`
  is always true where it is tested. Whether nursery k is offloaded is
  answered by `y.isOffloaded(k)` in three places and by `h.offloaded` in
  three others. `serviceRounds` allocates nothing for `roots` and `pubs`
  but declares and frees them.
- **The cost**: A reader has to prove the two flags agree. They do today
  (the opener copies one into the other), also in the single-thread test
  configuration and under the broken variant `mainCollectsItsOwnNursery`.
- **The proposal**: Remove `YoungShared.mode` (the host's `youngMode`
  answers `.offload` when `young` is not nil). Keep `Handshake.offloaded`
  as the one fact of a collection in flight and `isOffloaded` as the one
  policy question asked at an opening. Remove the two dead locals.
- **How to bound it first**: Nothing to measure.
- **Risk and size**: `MainOffloadTests.swift` and the model's
  `ownershipOffloaded` configurations guard it. Core tier. Small.
- **Confidence**: read.

### memory.R3. Small duplicates

- **Where and what**:
  - `Nursery/NurseryState.swift:408-413` (`atomicLine`) is
    `lined(Atomic(v))` (`Workers/VMState.swift:499`), which
    `YoungHost.swift:49-58` uses. `ObjectMemory/Allocation.swift:29-39`
    (`makeContext`) hand-rolls the same 128-byte allocation. The
    collectors review recorded "one pair of cache-line helpers".
  - The carve of fresh entries at the high water mark:
    `Allocation.swift:236-247` (links them) and
    `Generations.swift:339-349` (lists them).
  - `Collector.swift:37-52` and `:56-72` (`allocate`, `allocateBytes`):
    the collect, compact, retry ladder twice.
  - `Owner.swift:311-313` computes a rate inline; `:300` calls
    `sampleRate` for the same rule on the other sample list.
- **The cost**: Each is two places for one rule. The carve is the one
  with a mechanical side (memory.M10).
- **The proposal**: `lined` moves to a file both `ObjectMemory/` and
  `Workers/` may use and replaces the other two; one `carveEntries(n,
  _ each:)`; one generic ladder taking the try as a closure; `sampleRate`
  for both rates.
- **Risk and size**: None beyond the gates. Core tier. Small.
- **Confidence**: read.

### memory.M10. Small mechanical items

One paragraph each; none is worth a module alone.

- **`takeRun` scans from block 0 under the pool lock**
  (`ObjectMemory/LargeObjects.swift:108-122`, then a filter of the whole
  free list at `:129-137`). A 4 GiB reservation is 131 072 blocks; the
  shells' 600 MiB heap 19 200. Every large allocation pays the scan past
  all blocks in use while every refill and every promotion refill waits.
  A "lowest free block" hint kept by `releaseEvacuatedBlock`, the sweeps
  and `takeRun` removes the prefix. Bound: time `takeRun` in the `photo`
  and `large` scenarios (a counter of blocks scanned per call).
- **Fresh entries are written under the pool lock**
  (`Allocation.swift:239-243`, `Generations.swift:342-347`): 4 096
  entries, 64 KiB, on pages never touched, so the first-touch page faults
  happen with the lock held. The header store is redundant (entries above
  the high water mark are zero). The stash's carve could bump the mark
  under the lock and write the state words after it, since the entries
  are the stash's alone from the bump on; check `verifyFreeLists` and the
  lazy sweep's bound first.
- **`highWater` takes the pool lock** (`ObjectMemory.swift:347-351`), and
  `isUsedReference` calls it (`:342-345`). In release it runs per external
  signal (`Processes/External.swift:222`), six times per method made, and
  across the image rules at load. The mark only grows; a relaxed atomic
  mirror would do for a bound check.
- **Fills are one relaxed atomic store per word**
  (`Allocation.swift:145-150`). The measured 0.62 ms for a 16 MiB object
  is one store a cycle. The atomics are there for ThreadSanitizer and the
  C++ rules, with reason. For byte objects past a block and below
  `longBytesFrom` (which `zeroLongBytes` already handles with `memset`),
  the same polled `memset` would cut the fill four to eight times; say
  beside it why a plain write to an unpublished body is sound and what
  the sanitizer build does.
- **Swift arrays on a worker's allocation slow path**
  (`YoungCollection/Owner.swift:287-290, 296-301, 308-309`): the trigger's
  samples are `[(ns, promoted)]` with `append` and `removeFirst`, copied
  out under the lock and mapped into a new array, at every young
  collection, on the background worker that collected. `RecordRing` or a
  fixed tuple buffer has no allocation and no ARC.
- **`epochAdvance` stores every time** (`Relocation/Epoch.swift:37-41`,
  called from `Collector.servicePoint`). While a collector spins in
  `waitEpoch` reading every participant's word, each unconditional store
  takes the line back. A compare with the word's own last value before
  the store keeps the line shared when the epoch did not move. Bound:
  `ycEpochWaitP50ms` is 0.04 to 0.05 ms, so expect little.

## Known items the existing rows speak to (not findings)

- **Survivor sizing** (ADR 0007's next item). On the storm rows 96 to 100
  percent of promoted bytes are survivor overflow on both machines. That
  is memory.M1's lock, not evidence about real programs. Measure sizing on
  a workload that is out of step before deciding anything from it.
- **Chunk bitmaps against stashes** (settled as a known cost). The share
  of the sweep under `offload` was not in the docs: 45 percent of a
  `share` collection, 11 percent of a storm collection on the Mac.
- **Card marking for large objects** ("no card marking yet"). No
  `offload` row can speak to it until memory.M5's slot counter exists.
- **The acknowledgement on the main thread**: 23.8 µs mean on the Mac,
  24.9 on the iPhone, 12.8 ms per 10 s on the iPhone's storm row. Small
  against the frame; I found nothing to add.

## Read and found good

- The young allocation fast path (`YoungAllocation.swift:28-50`): five
  loads from the first 64 bytes of `NurseryAlloc`, no load from the entry
  table, one out-of-line call. The stash is its own young log, so the
  path has no extra store.
- Per-writer state is in its own 128-byte lines (`lined`), and the hot
  fields of `NurseryAlloc` come first. The pool lock is beside `Pools`,
  not in it, and is an unfair lock (priority inheritance matters when the
  marker at utility holds it).
- `isHazarded` is one seq_cst load of a count unless a primitive holds a
  hazard (`Relocation/Hazard.swift:57-67`): the per-object hazard scan
  the experiment paid for is gone.
- The fence after the offset CAS is needed and correct (memory.M3,
  "Checked and kept").
- Promotion takes its body before the claim and gives it back on a lost
  claim (`Scavenge.swift:420-436`); the old-map bits of promoted entries
  are set one `fetch_or` per word, outside the copy loop.
- `RawArray` keeps ARC out of every collector loop I read. The round and
  collection logs are rings.
- The young collector thread and the stalled workers wait untimed. The
  only timed waits in the area are the 20 µs sleep inside `waitEpoch`
  (inside a collection only) and the test primitive's.
- A small scavenge is the stopper's alone (`soloYoungBytes`), so parked
  workers are not woken to copy nothing.
- `walkInstances` and `walkPointers` read the old map by words and compare
  eight slots a step.

## Files not read, or read in part

- `ObjectMemory/Verifier.swift:289-427` (`verifyFreeLists`,
  `verifyMarks`): the signatures only. `ObjectMemory/Snapshot.swift:1-169`
  (the layout parser): not read.
- Context, read in part: `Workers/VMState.swift` (the `WorkerShared` and
  `SafepointState` heads and `lined`), `Workers/Safepoint.swift`
  (`gatherRoots` only), `Marking/SATB.swift` (the store slow path),
  `Marking/RootScans.swift:105-150`, `Relocation/Epoch.swift`,
  `Relocation/Hazard.swift:57-67`, `Relocation/Relocator.swift:393-413`,
  `Interpreter/InterpreterState.swift:185-330`. `Workers/Poll.swift`,
  `Marking/Pacing.swift` and `Marking/Sweep.swift` were not read.
- Docs: `object-memory.md` whole; `nursery.md`, `young-collection.md`,
  `large-objects.md` by their Layouts, Measurements, Deviations and Not
  done sections; `main-offload.md` by its headings only;
  `docs/models/young-collection.md` and `docs/models/relocation.md` by
  search (the fence, the memory rules); ADRs 0007 and 0008 in the parts
  on survivors and per-object cost, ADRs 0002 to 0006 not opened; records
  10, 14, 17, 33, 40 and 41 (the first screen of each).
- Tests were not read.

## Bugs met on the way

None that loses an object or a store. Two things to look at:

- `Sources/KajoVM/YoungCollection/Collect.swift:473-491`: `scanHolder`
  has no service point inside one holder. Since module 10 a remembered
  Array may have 16 777 215 slots. While a collector scans it, it
  acknowledges no round and advances no epoch, so other nurseries'
  collections and any stop waiting for open collections wait for the
  whole scan. The same shape as the second review's F2 (primitive 38 over
  a large pointer object never polls). See memory.M5 (2).
- `Sources/KajoVM/YoungCollection/Rounds.swift:173-174, 211-212`: `roots`
  and `pubs` are declared and freed and never used (memory.A4).
