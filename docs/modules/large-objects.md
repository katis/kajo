# Module 10: large objects

Status: briefed 2026-11-05, from the owner's answer of the same day to
module 9c's first question ("Add large-object space") and the owner's
answers of 2026-11-04 to the vm-teardown follow-up (grow old space for the
final collection; the host save refuses while Processes have frames).

## What it hides

That the heap is cut into 32 KiB blocks. Since module 1 no body spans a
block (`Header.maxSlots` 4095 slots, 32 760 bytes), and the kernel has met
the limit three times: 8b's sources table, 8e's symbol buckets, and 9c's
2000-class image, where `OrderedCollection` stopped at 2048 elements, a
protocol reply over a block could not be written and a request over a
block could not reach the image. 9c answered in the kernel (`LargeArray`,
a merge sort, JSON lines in pieces, a refused request). The owner chose
the VM's answer: an object of any size up to the header's count field, so
`Array new: 1000000` and a 10 MB String are ordinary objects and the
kernel's collections are plain Arrays again.

## 1. A large object

- **Definition.** An object whose body does not fit one block: more than
  4095 slots, or more than 32 760 bytes. Its body is a **run** of
  contiguous blocks owned by that one body; the body's first word carries
  the entry index and the size in words as every body does, so the heap
  stays walkable. The header's count field has 24 bits: the limit is
  16 777 215 slots (128 MiB) or bytes (16 MiB); a request past it fails as
  an allocation failure the kernel reports (`new:` signals an error naming
  the limit), never a trap.
- **Old at birth, never moved.** A large object is allocated in old space
  (ADR 0007's consequence "large objects outside the nursery"), is never
  young, and is never relocated or compacted: relocation and compaction
  skip runs. Decide whether the mark is the reserved header bit 51
  (`large`) or the count test, and say why; a bit is justified only if a
  hot path needs it. Its stores run the ordinary barrier (an old object
  holding young pointers is remembered as any old object).
- **Allocation** is a slow path under the pools lock: first fit over the
  block table for a run of free blocks; when none, request the full
  collection and retry once, then fail. Filling 16 MiB with nil on the
  allocating thread is about a millisecond: say what it costs the frame
  budget (ADR 0004) and keep the fill out of the fast path.
- **The side table** says what each block is: free, ordinary, the head of
  a run, a continuation of a run. The verifier, the sweep, compaction,
  the snapshot and the oracle walk runs as one body and refuse an entry
  that points into a continuation.
- **Marking** traces a large pointer object through its entry as any
  object; the concurrent marker's work granularity must not stall on a
  128 MiB body (measure a 1M-slot Array under marking; split the scan if
  the marker's budget needs it). **Sweeping** frees a dead run whole,
  under the lazy sweep's accounting. **Become and reshape** go through
  the entry and need no copy; `Reshape`'s `.tooLarge` refusal goes where
  the new size fits the limit.
- **Fragmentation.** Runs never move, so they can pin space between them.
  Compaction consolidates the ordinary blocks around them. Measure the
  worst case you can make (alternating large and small live objects, then
  free the small) and report footprint against live bytes.
- **The snapshot and the image.** A run is written as its body with its
  size and read back into a run; the loader verifies the side table, the
  size and that no entry points into a continuation. Image format
  **version 5**; 1 to 4 are refused as before. The snapshot fuzzer covers
  runs; `fuzzFoundInputsNeverTrap` gains any input it finds.
- **The stop-the-world oracle** (module 4's scavenge, the full collection)
  handles runs the same way; the model-checked protocols are unchanged
  unless run allocation or freeing against the concurrent sweep or
  relocation adds a cross-thread protocol: then the model is extended in
  the same commit (`models/`).

## 2. The kernel goes back to plain Arrays

- `LargeArray` and `Array class >> large:` are removed; `OrderedCollection`,
  `HashedCollection` and `SequenceableCollection` allocate with `new:`.
  `LargeArrayTest` becomes a test that a 100 000-element Array, a Set and
  a Dictionary of 50 000 work, and that `new:` past the limit signals.
- The merge sort stays. The JSON pieces stay for the transport (a reply
  over the link still goes in 16 KiB pieces, which 9d's writer wants), but
  `Json write:` may build one ByteArray of any size, primitive 160's
  request may be one String, and the transport's refusal of a request over
  32 704 bytes is lifted to 9b's 64 MiB bounded reader.
- Contexts stay at most one block (ADR 0009's stack copy rule); say so.
  `Symbols.maxBucket` may stay.
- Primitives that build objects (`new:`, `ByteArray new:`, String
  concatenation, `copyFrom:to:`, `Array large:`'s callers, the image
  build's tables, the Tonel reader) take the new sizes; the 8b lesson
  "no object is larger than one block" in AGENTS.md is for the main
  session to retire.

## 3. Measurements

- Allocation and free of 1 MiB and 16 MiB objects (time, and frames on the
  Mac shell's `scenario=idle` while a Process allocates and drops large
  objects: 0 frames missed is the bar, as 9a's rows).
- `at:` and `at:put:` throughput on a 1M-element Array against 9c's
  `LargeArray` (its `at:` was a send).
- The 2000-class image build time and 9c's scripted session (`mode=
  devsession`, 12 launches: browser population and `package.selectors`
  with plain Arrays) against 9c's tables.
- Marking a 1M-slot pointer object: the marker's longest step, frames.
- The fragmentation case above.
- `just soak` with random programs that allocate large objects (extend the
  generator), every configuration; `just bench` A/B against the commit you
  start from, within noise, `interpret` unchanged.

## 4. Two decided follow-ups from vm-teardown

- **Old space grows for the final collection.** `VM.destroy`'s
  `endYoungGeneration` promotes every young object; today it traps when
  old space has no room. The owner decided: grow old space (within the
  reservation, or by reserving more; say which and what it costs) rather
  than fail; a test fills the nursery and ends the VM.
- **The host save refuses while any Process has frames**, with an error
  the kernel can show (`Smalltalk saveImage` answers it); a test saves
  with a parked Process and sees the refusal, then with none and sees the
  image.

## Rules

- Zero ARC on hot paths, one jump table; the large path is a slow path
  and touches no hot path's code: `just arc-check` and the disassembly
  diff show it.
- Every reader of a body (verifier, sweep, marker, snapshot, oracle,
  compaction, relocation, become, reshape, the loader) handles runs; a
  broken variant per reader shows its test fails without it.
- `.strictMemorySafety()` marked and counted. Tests assert on CPU or work,
  never wall-clock.
- Image version 5; the loader's refusal message names the module.

## Deliverables

Runs in the block heap with the side table, allocation, sweep, marking,
snapshot and verifier; relocation and compaction skipping them; the kernel
without `LargeArray`; the lifted transport limit; the two follow-ups; the
measurements; the random programs with large objects; the snapshot fuzzer
over runs; the as-built doc replacing this file; ADR 0003's Built (10) note
(the body layout) and ADR 0007's (large objects outside the nursery, never
moved); `docs/CONTEXT.md` terms.

## Not in this module

A separate large-object heap outside the block reservation; large young
objects; Contexts past one block; the header's count field widened.

## Open questions this module will put to the owner

Whether 16 MiB is enough for byte objects (a widened count field is a
header change); whether a large object should ever be relocated to fight
fragmentation; whether the transport should keep sending pieces now that
one String can hold a line.
