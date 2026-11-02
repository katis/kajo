# Module 1: object memory

Status: built, 2026-11-02. `Sources/KajoVM/ObjectMemory/`, tests in
`Tests/KajoVMTests/ObjectMemory/`. Ported from experiments/object-representation
(variant B) with the final layouts of experiments/concurrent-young and
concurrent-relocation.

## What it hides

How an oop reaches an object, how an object is laid out, where objects live
and how dead ones are reclaimed while the world is stopped. Nothing outside
this module computes a body address, reads a header bit, or knows that an
entry table exists (ADR 0003). Later modules add nurseries, concurrent
marking and relocation inside this boundary; the layout they need is
reserved here so they do not change it.

## Layouts

### Oop (64-bit tagged word)

| low bits | meaning |
|---|---|
| `...xxx1` | SmallInteger, 63-bit two's complement, value = raw >> 1 (range -2^62 ... 2^62 - 1) |
| `...0000`, nonzero | object reference: the byte offset of its entry in the table, entry index x 16 |
| `0` | `Oop.none`: no object (an empty class-table slot); never in a heap slot |
| `0010 0100 0110 1000 1010 1100 1110` | reserved for future immediates (Character, SmallFloat64); invalid today, rejected by the verifier and the loader |

Entry 0 is reserved, so no reference is 0.

### Entry (16 bytes, in the entry table)

| word | contents |
|---|---|
| 0 | state word |
| 1 | header word (0 in a free entry) |

State word:

| state | value | used by |
|---|---|---|
| used | body offset from the heap base; < 2^32, a multiple of 8 | module 1 |
| RELOCATING | body offset + 2^32 (reads go through the heap alias) | **reserved** for module 6; never present in module 1, the verifier and loader reject it |
| free | bit 63 set; bits 0..62 the oop of the next free entry in the same list, 0 at the end | module 1 |

The class is in the header, so a send reads the class with one load from
the oop. Entries above the high water mark were never used and are zero.

### Header word (in the entry)

| bits | field | module 1 |
|---|---|---|
| 0..21 | class index (0 is never a class) | used |
| 22..45 | count: slots, or bytes for a byte object | used |
| 46 | mark, full collection | **reserved**: module 1 marks in a side byte map |
| 47 | byte object | used |
| 48..51 | unused | **reserved** |
| 52..55 | nursery index | **reserved** for module 4 |
| 56 | young | **reserved** for module 4 |
| 57..59 | age | **reserved** for module 4 |
| 60 | pinned for good: never moved | used |
| 61 | frame pin: not moved until unpinned | used |
| 62..63 | scavenge claim tag | **reserved** for module 4 |

Every reserved bit is zero in every header module 1 writes; the verifier
and the loader reject a header with one set. Header bits are written only
with the world stopped.

### Body (in a block)

| word | contents |
|---|---|
| 0 | back reference: bits 0..31 entry index, bits 32..63 body size in words (this word included) |
| 1.. | slots, or bytes rounded up to words |

A body is live iff its entry is used and the entry's state word is this
body's offset. A body whose back reference names entry 0 or an entry that
points elsewhere is dead but still walkable: the heap walks by back
references alone. Bodies never span blocks, so an object has at most 4095
slots or 32 760 bytes.

### Heap and blocks

- One reservation of `2^32 + heapBytes` with `vm_allocate`, holding one
  memory object (`mach_make_memory_entry_64`) mapped with `vm_map` at the
  base and again at base + 2^32: the alias module 6's RELOCATING state
  reads through. `mach_vm.h` is never used. ThreadSanitizer cannot see the
  two mappings alias; the comment at `VirtualMemory.reserveTwice` says so.
  The heap is at most 4 GiB.
- Blocks of 32 KiB. Per block: bytes used and in use. A block held by an
  allocation context has a stale `used` until the context is retired;
  every reader of `used` runs with the contexts retired.
- The block pool holds every free block and every in-use block with at
  least 4 KiB of tail, lowest index on top; a context continues an in-use
  block at its `used`.
- The entry table is a fixed reservation (`entryCapacity` x 16 bytes) and
  never grows. The mark map is one byte per entry beside it.

### Allocation context

128-byte aligned, one per caller (module 3: one per worker): bump region
(`top`, `end`) in a private block, the head of a private free-entry list,
and allocation counters. Contexts on different threads never share a cache
line.

## Interface (internal; tests use `@testable import`)

```swift
ObjectMemory(config) throws(ObjectMemoryError)     // destroy() releases it
om.makeContext() -> AllocContext; om.destroyContext(ctx); om.retire(ctx); om.retireAllContexts()

// allocation
om.tryAllocate(ctx, classIndex:, slots:, fill:) -> Oop            // .none: collect, then retry
om.tryAllocateBytes(ctx, classIndex:, count:) -> Oop               // zeroed
om.allocate(ctx, classIndex:, slots:, fill:, extraRoots:) -> Oop?  // collects, then compacts; single-threaded
om.allocateBytes(ctx, classIndex:, count:, extraRoots:) -> Oop?

// access: the single load and store paths
om.classIndex(of:), om.count(of:), om.isBytes(_:), om.header(_:)
om.load(o, i), om.store(o, i, v), om.loadByte(o, i), om.storeByte(o, i, b)

// roots and classes
om.addRoot(v) -> RootHandle, om.root(h), om.setRoot(h, v), om.removeRoot(h)
om.registerClass(oop) -> classIndex, om.classOop(i), om.setClassOop(i, oop)

// stop-the-world operations
om.collect(extraRoots:)                    // mark-sweep
om.compact(extraRoots:)                    // mark, slide, sweep entries
om.becomeExchange(a, b) throws(BecomeError)
om.becomeForward(from, to:, extraRoots: &roots) throws(BecomeError)
om.reshape(classIndex:, namedSlots:, layout: [Int?], fill:) throws(ReshapeError) -> Int
om.allInstances(of: classIndex) -> [Oop]
om.pinForGood(o), om.pinForFrame(o), om.unpinFrame(o), om.isPinned(o)

// snapshots
om.snapshot() -> [UInt8], om.snapshot(toFile:)
ObjectMemory.load(snapshot: [UInt8], config:) throws(SnapshotError)   // the fuzz entry point
ObjectMemory.load(contentsOfFile:, config:)

// verification and telemetry
om.verifyHeap(), om.verifyFreeLists(), om.verifyMarks(extraRoots:), om.verifyCompaction(plan, before)
om.counters, om.verifierReports
```

Roots are the class table, the root registry and whatever the caller
passes as `extraRoots` (module 3 passes interpreter stacks). Marking reads
them; only `becomeForward` rewrites them, since oops never change.

**Thread rules.** Allocation through distinct contexts runs on any threads
at once; the pools (free blocks, entry runs, high water mark, the context
list) are guarded by one `os_unfair_lock` in its own allocation. Loads and
stores of distinct objects run concurrently. Everything else runs with the
world stopped; until module 3 brings safepoints, the caller guarantees it.
`ObjectMemory` and `AllocContext` are `@unchecked Sendable` for that reason.

## How it works

- **Allocation fast path**: bump `top` by the body size, pop the private
  entry list, write the back reference, fill the slots, write the header
  and state word. If the block or the list is exhausted, one out-of-line
  call (`allocateSlow`) refills the block (retiring the old one) or takes
  an entry run from the pool, else carves a chunk at the high water mark.
  None left: `.none`, and the caller collects.
- **Mark**: from the roots into the side mark map, with an explicit stack in
  malloc'ed memory. Never touches headers.
- **Sweep** (eager): one table scan frees unmarked entries, unmarks the rest,
  and threads every free entry into runs of `entryChunk` for the pool;
  contexts' private lists are discarded (their entries are free in the
  table and land in the new runs). Blocks with no live body become free.
- **Compaction**: sliding and block-respecting. Plan: walk in-use blocks in
  order, give each live body the lowest destination that fits in a block.
  Every destination is at or below its source, so moves run in plan order
  with `memmove`. Only entries are rewritten; no slot anywhere changes. A
  block holding a pinned live body is neither source nor destination. The
  tail of the last destination block returns to the pool.
- **`allocate` policy**: on failure, mark-sweep and retry, then compact and
  retry, then `nil`.
- **Two-way become** swaps the two entries and the two back references; pins
  follow their bodies. **Bulk one-way become** scans every used entry's
  slots, the registry, the class table and the caller's roots once, then
  frees the sources' entries; identical pairs are skipped, chains refused.
- **Reshape** gives every instance a new body under the same oop: new slot
  j is old named slot `layout[j]` or `fill`, the indexed part follows. All
  new bodies are allocated before any entry is repointed, so a full heap
  changes nothing (`heapFull`). Byte and pinned instances are refused.
  Updating the class's own instance size is the caller's job.
- **Snapshot**: version 1, little-endian. Header (magic `KAJOOM`, version,
  block size, block count B, high water H, class table length C, root count
  R), the class table, the registry, `used` per block, the used bytes of
  each block, the table `[0, H)`. Saving retires contexts and drops frame
  pins. Loading reserves a new heap and table (so the base differs), copies
  bytes, and relocates nothing. The loader checks the geometry (with every
  count bounded by the length before it is used and the exact length
  required), that entry 0 and class 0 are empty and that no frame pin is
  set, then runs the heap verifier and rejects any issue; only then does it
  rebuild the free-entry runs and the block pool.

## Verifiers

On in debug builds at every pause; one flag away in release
(`config.verify`). A failure traps with a report in checked builds
(`onVerifyFailure: .trap`) or is counted and kept (`.record`).

| verifier | checks | corruption tests |
|---|---|---|
| `verifyHeap` | every used entry: no RELOCATING, aligned, inside the heap, in an in-use block, inside its `used`, back reference names it, size agrees with the header, is the start of a body in the block walk, no reserved header bit, registered class, every slot a SmallInteger or a reference to a used entry; free entries have header 0; no mark outside a collection; every in-use block walks exactly to `used`, every free block has none; class table and roots valid | 21 (`theHeapVerifierCatches`) |
| `verifyFreeLists` | every free entry in exactly one list (pool run or context list), lists hold only free entries, no cycle; every free block in the pool once; an in-use pool block has a tail. The "one owner per entry" rule is concurrent-young's deferred-free lesson | 9 (`theFreeListVerifierCatches`) |
| `verifyMarks` | from-scratch reachability against the mark map, both directions | 2 |
| `verifyCompaction` | every live body where the plan put it (or where it was if unplanned), header and every body word unchanged (fingerprints) | 4 (`theCompactionVerifierCatches`) |
| loader | everything in `verifyHeap` plus geometry, entry 0, class 0, frame pins | 28 (`theLoaderRejects`) and 3000 seeded mutations (`mutatedSnapshotsLoadCleanOrAreRejected`) |

Pauses run them as: collect (heap and free lists, marks, heap and free
lists), compact (heap and free lists, marks, compaction, heap and free
lists), become, forward and reshape (heap and free lists after), snapshot
(before). Debug builds also `assert` every load and store (used entry,
pointer object, index in range).

## Stress flags

`config.stress`, parsed from `KAJO_STRESS` form by `StressFlags(parsing:)`:

| flag | effect |
|---|---|
| `collectAtEveryAllocation` (`every`) | `allocate` runs a full, verified collection before every allocation |
| `oneBlockHeap` (`oneblock`) | the heap is one block: every allocation burst ends in a compaction |
| `tinyEntryChunks` (`tiny`) | entry chunks of 2: every other allocation refills |

`allocationHeavyScenariosUnderStress` runs the allocation-heavy scenarios
(list among garbage, byte objects, compaction, become, reshape, snapshot)
under each flag and all three; `gcKeepsSurvivorsAndReclaimsGarbage` also
runs under the one-block heap and tiny chunks.

## Counters

`om.counters`: allocations, allocated bytes, allocation failures, entry and
block refills (per context, summed), collections, compactions, stress
collections, entries swept, blocks freed, objects and bytes moved, pins
honoured, becomes, forwarded objects and references, reshaped objects,
snapshots saved, verifier runs and failures.

## Test-only switches

`config.testSwitches.ignorePins`: compaction moves pinned bodies, so
`withoutThePinRuleThePinnedObjectMoves` shows the rule matters.

## Unsafe surface

211 `unsafe` sites (code lines only), all in `Sources/KajoVM/ObjectMemory`:
Allocation 53, ObjectMemory 48, Collector 19, Roots 16, BlockHeap 15,
Snapshot 13, Verifier 11, Become 11, VirtualMemory 9, RawArray 8,
Compaction 6, Reshape 2. They are raw loads and stores through the table and
heap bases, `pointee` accesses of the shared sub-states, `memcpy` and
`memmove` of bodies, and the `vm_*` calls. Seven structs holding pointers are
marked `@safe` (they encapsulate the storage behind the thread rules
above). Oop, Header, the entry and back-reference encodings, the
configuration, the counters and the snapshot parser are safe code.

## Hot-path check

`just arc-check` (`scripts/check-hot-path-arc.sh`) builds with
`swift build -c release -Xswiftc -enable-testing --scratch-path .build/release-testing`
(a plain release build dead-strips every internal function, since nothing
public calls them yet), then disassembles each function on the allocation
and store paths with `xcrun objdump -d -r --disassemble-symbols=<symbol>`
and fails on any `swift_retain` or `swift_release`. Result on 2026-11-02:
all 15 functions (`tryAllocate`, `tryAllocateBytes`, `allocate`, `place`,
`allocateSlow`, `refillBlock`, `refillEntries`, `allocateBody`, `retire`,
`load`, `store`, `loadByte`, `storeByte`, `lockPools`, `unlockPools`) have
zero; `tryAllocate` is 56 instructions whose only call is `allocateSlow`;
`load` and `store` are 5 instructions each.

## Decisions made while building

- **Entry word order** is state word, then header (the brief's order;
  experiment B had the header first).
- **Free entries** are marked by bit 63 of the state word, which carries
  the next link, and a zero header. A free entry is recognisable from
  either word; the verifier checks they agree.
- **Marks live only in the side byte map**, so header bit 46 is reserved
  and unused in this module.
- **In-use blocks with a tail are reused**, not only empty ones (the
  experiment reused only empty blocks). The compaction tail needs this, and
  the one-block heap is unusable without it.
- **A block holding a pinned live body stays whole** in a compaction:
  nothing moves into or out of it. Simpler than compacting around pins and
  pins are rare.
- **The class table belongs to the object memory**: it is a root, it
  travels in the snapshot, and the verifier and loader require every
  instance's class index to be registered, so the interpreter can index the
  table without a check.
- **The fill value is passed to allocation**: the object memory does not
  know `nil`.
- **Reshape is general** (a layout map plus the indexed part, all or
  nothing, refusing byte and pinned instances) rather than the
  experiment's "add one instance variable". It does not touch the class
  object.
- **Bulk forward refuses chains** instead of following them; the
  experiment followed forwarding entries transitively.
- **No safepoints yet**: the world-stopped operations trust the caller, and
  `allocate` collects inline for a single-threaded caller. Module 3
  replaces that with a safepoint request around `tryAllocate`.
- **Stores are plain stores**; module 4 (barrier) and module 6 (post-store
  check, seq_cst) change `store` at its one site.
- **The table never grows** and objects larger than a block are refused
  with a precondition.

Strict memory safety forced no design change. What it changed is local:
`mach_task_self_` is read through one accessor (the macOS SDK imports it as
an unsafe global, the iOS SDK does not, so `unsafe` was required on one and
a warning on the other), and the snapshot parser was written over
`[UInt8]` with bounds checks so that only the two `memcpy`s are unsafe.
ThreadSanitizer, not strict memory safety, forced one: the pool lock moved
out of the `Pools` struct, because reading it through `pools.pointee` was
an access to the whole struct racing with writes made under the lock.

## Tests

60 test functions, 125 cases. Green under load (12 `yes` processes) and
under `swift test --sanitize=thread`, also under load.

Ported: `oopsAreTaggedAndNonZero` (split into the encoding test and
`referencesAreEntryOffsetsInsideTheTable`), `headerPackingAndSizes`,
`gcKeepsSurvivorsAndReclaimsGarbage`, `twoWayBecomeSwapsIdentities`,
`bulkForwardRedirectsEveryReference`, `reshapeAddsAnInstanceVariable`,
`snapshotRoundTripAtANewBase`, the "moves bodies, rewrites no slots" half of
`compactionMovesMethodsUnderLiveFrames` (`compactionMovesBodiesAndRewritesNoSlots`),
concurrent-relocation's pin tests without the interpreter
(`aPinnedObjectIsNotMovedByCompaction`, `withoutThePinRuleThePinnedObjectMoves`),
`theVerifierCatchesABodyInAFreedBlock` (as `theHeapVerifierCatches(offsetInFreeBlock)`),
and concurrent-young's entry-ownership lesson as the free-list verifier and
its tests.

Waiting: `smallProgramRuns`, `kernelsAssemble`, `interpreterSeesBecome`
(module 2); `operationsWhileOtherWorkersRun`, the live-frames half of
`compactionMovesMethodsUnderLiveFrames`, `aFramePinnedObjectIsNotMoved`
with a real frame (module 3); everything generational, concurrent and young
(modules 4 to 7). The libFuzzer target for the loader is module 2's.
