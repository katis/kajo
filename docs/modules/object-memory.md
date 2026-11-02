# Module 1: object memory

Status: brief, 2026-11-02. Becomes the module's description as it lands.

## What it hides

How an oop reaches an object, how an object is laid out, where objects live
and how dead ones are reclaimed when the world is stopped. Nothing outside
this module computes a body address, reads a header bit, or knows that an
entry table exists (ADR 0003). Later modules add nurseries, concurrent
marking and relocation *inside* this module's boundary; the layout they need
is reserved now so they do not change it.

## Decisions carried in (do not reopen)

- **Oops** are 64-bit tagged words: SmallInteger or object reference, the
  reference being an offset into the entry table (ADR 0003, variant B).
  Take the tag scheme and entry encoding from `experiments/object-representation/SPEC.md`
  "Oop encodings" (B) as refined by `experiments/concurrent-young/SPEC.md`
  "Header word" and `experiments/concurrent-relocation/SPEC.md` (entry
  state word: offset, RELOCATING = offset + 2^32, free). Reserve the state
  values and the header bits (nursery index, young, age, pins, claim tag,
  mark) even though this module only uses class, size, bytes, mark and the
  two pins. Document the final layout in this file; it replaces the open
  items in `docs/CONTEXT.md`.
- **Entries** are 16 bytes: state word (body offset) and header word. The
  class is read from the entry, one load from the oop.
- **Blocks** are 32 KiB in a heap reserved once with `vm_allocate`/`vm_map`,
  never `mach_vm.h`; the second mapping of the heap that ADR 0007 needs is
  created now with a comment saying ThreadSanitizer cannot see it alias
  (AGENTS.md).
- **Mark bits live in a side byte map** beside the entry table, never set by
  mutators in headers (AGENTS.md).
- **Entry allocation** from per-worker chunks; body allocation from
  per-worker blocks (both from object-representation B). Workers do not
  exist yet: the module takes an allocator context per caller, which module
  3 will hand to each worker.
- **Stop-the-world collector**: mark from a root set, sweep entries and
  blocks lazily or eagerly (eager here; lazy is module 5), compaction that
  moves bodies and rewrites only the entry (ADR 0003), `become:` two-way and
  bulk one-way, class reshape with instance enumeration, frame pins and
  permanent pins honoured by compaction.
- **Snapshot**: save and load the whole object memory at a new base with no
  relocation of oops (ADR 0003); the loader validates every entry and block
  invariant on load and is the first fuzz target (module 2 adds the fuzz
  harness; write the loader so that is trivial).
- **Verifiers**, on in debug and one flag away in release: from-scratch
  reachability against the collector's result; every used entry points into
  a live block at an aligned body whose header agrees with the entry; free
  entries are in exactly one free list; block free space accounts; after
  compaction every live body moved as planned and no slot was rewritten.
- **Stress flags**: collect at every allocation; one-block heap; tiny entry
  chunks.
- **Counters**: allocations, collections, bytes moved, entries swept, pins
  honoured, verifier runs and failures.
- **Strict memory safety**: every raw pointer operation is `unsafe`. Expect
  this to be the slow part of the port; do not turn the setting off.

## Interface (sketch; refine while writing tests)

An `ObjectMemory` reached through a pointer, holding pointers to separately
allocated sub-states (one per lock, per AGENTS.md); an `AllocContext` per
caller; `allocate(class:slots:)`, `allocateBytes(class:count:)`;
`classOf`, `slotCount`, `isBytes`; `load(oop, slot)`, `store(oop, slot,
value)` as the single store path (module 4's barrier hooks in here);
`becomeForward`, `becomeExchange`, `reshape(class, newSlots)`,
`allInstances(class)`; `collect(roots:)`, `compact(roots:)`; `pin`/`unpin`;
`snapshot(to:)`, `load(from:)`; `verify()`; `counters`. Roots are a
registry of external root slots plus whatever the caller passes; interpreter
stacks arrive with module 3.

## Tests to port now

From `experiments/object-representation/swift/Tests` (the B variant) and the
later lineage where they touch only the object memory:
`oopsAreTaggedAndNonZero`, `headerPackingAndSizes`,
`gcKeepsSurvivorsAndReclaimsGarbage`, `twoWayBecomeSwapsIdentities`,
`bulkForwardRedirectsEveryReference`, `reshapeAddsAnInstanceVariable`,
`snapshotRoundTripAtANewBase`, the compaction tests without live frames
(`compactionMovesMethodsUnderLiveFrames` waits for module 3 but its
"moves bodies, rewrites no slots" half is ported now), the pin tests from
concurrent-relocation that need no interpreter, and the entry-reuse and
deferred-free lessons from concurrent-young's diagnosis as invariant checks
in the verifier (an entry is owned by exactly one reclaimer).

New tests: every verifier must have a test that corrupts one thing and sees
the verifier fail; every stress flag has a test that runs the suite's
allocation-heavy tests under it; the loader rejects a snapshot with each
invariant broken.

## Tests that wait

`smallProgramRuns`, `kernelsAssemble`, `interpreterSeesBecome` (module 2);
`operationsWhileOtherWorkersRun`, `compactionMovesMethodsUnderLiveFrames`
(module 3); everything generational, concurrent and young (modules 4 to 7).

## Done when

Tests green under load and under ThreadSanitizer (single-threaded module,
but the allocator contexts are exercised from several threads in one test);
`just ios-check` passes; `swift build -c release` has zero `swift_retain`
or `swift_release` in the allocation and store paths (check the
disassembly and record the method); this file describes the module as
built; AGENTS.md's project structure lists it.
