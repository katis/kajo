# The verifier's two faults

## Status

Brief, written 2026-11-21 by the main session. Not built.

The owner, 2026-11-20, on the main session's three questions of the third
review's small fixes ("agreed on questions"): the core brief for the two
faults comes before part 2 of the small fixes, and after the fix the heap
verifiers run in the release-build kernel gate only. On 2026-11-21, to
"Shall I write the brief for the two verifier faults and start its build
agent?": "Yes, brief it".

A core-tier module: the faults are in the make primitive and in the young
collector's remembered sets.

## What it is

Part 1 of the small fixes (`docs/decisions/50-review-3-small-fixes.md`)
turned the checked build's heap verifiers on where a line had switched
them off since the day it was written. They found two faults in code every
gate had passed:

1. An old object names a young object and is in no remembered set. A
   scavenge then frees the young object under the old one's reference.
2. A young object in one nursery names a young object in another nursery
   and is not remembered for it. Seen once.

This module finds each fault's cause, fixes it, and turns the verifiers on
again where the faults keep them off.

## What is known

Check each of these before building on it. Raw files are under
`~/kajo-scratch/review-3-small-fixes/`.

Fault 1:

- `kajo test <image> --verify --test
  'MakeFuzzTest>>testSeededMutationsAreRefusedOrRun'` traps `object memory
  verifier, nursery verifier, before scavenge 1: entry 33398 (old) names
  young @102257 (nursery 1) in slot 1, and is not remembered for it`. The
  main session ran it 2 of 2 on a debug build of 18ad7a9 (`verify/`).
- In the whole kernel run of a debug build it trapped 5 of 5 before
  scavenge 720, and under `--young stw` before scavenge 905
  (`part1/found-summary.txt`). Started from test 130 of the run's order
  the same pair gave `after scavenge 1: entry 28490 slot 1 names @88622, a
  freed entry` (`part1/found-bisect.txt`): the young object was freed.
- The suspect, read and not confirmed. Primitive 143 allocates its methods
  and their literal frames in old space (`LiveMethodHeap` in
  `Sources/KajoVM/ObjectModel/LiveMethods.swift`).
  `CodeReader.literal` answers `.object(v)` for "any other object (a class
  variable's Binding)" and `makeMethodObjects`
  (`Sources/KajoVM/Loader/MethodBuilding.swift`) stores it as it is. If
  `v` is young, the store into the old frame goes through `om.store`, and
  nothing remembers the holder. A Symbol, a class, an immediate take the
  same `.object` case; whether any of those can be young at a make was not
  read.
- `makeStub` and the redefine primitive (`LiveClasses.swift`) use the same
  heap. The image build uses another `MethodHeap` with nothing young.
- Not read: whether the kernel's compiler can hand the primitive a young
  literal without the fuzz test's mutations (a Binding of a class variable
  just added, a Symbol just interned, a new class). If it can, every live
  compile has had this fault since module 8d.

Fault 2:

- First gate run of part 1 (f1bc64f, `check-first-run/swift-test.txt`),
  the checked level on in every `Headless` run: in
  `aFullHeapFallsBackJustifiedThenRunsOutOfMemory`, its `young=offload`
  half: `nursery verifier, after scavenge 17: entry 148628 (young in 1)
  names young @148629 (nursery 0) in slot 0, and is not remembered for it;
  entry 149172 (young in 0) names young @149173 (nursery 1) ...`.
- Alone, with the verifiers on, the test passed
  (`part1/found2-fullheap-alone.txt`, 738 s). So: 1 of 2, in the suite's
  load only. Not repeated, not diagnosed.
- The message names "after scavenge": the check is
  `Sources/KajoVM/Nursery/NurseryVerifier.swift` line 101, reached from the
  after-scavenge verifier. The test fills a heap to out of memory through
  full collections; a full collection's promote-all and the offloaded
  collector's carried lists are both on that path. Neither is a suspect
  yet.

Where the verifiers are off because of fault 1, each by one line: `kajo
test` (`Sources/kajo/main.swift`), `KernelTestParts`
(`Tests/KajoCompilerTests/KernelImageTests.swift` line 40), `ShellVM`
(`Sources/KajoVM/Shell/Shell.swift` line 358), and the stall tests' helper
(`Tests/KajoVMTests/Marking/AllocationStallTests.swift` line 74), the last
because of fault 2.

The verifiers' cost on the kernel tests (part 1, five runs): release 1.71
times, debug 2.98 times, under the sanitizer 2.17 times.

Found 3 of part 1: with the verifiers on in every debug `ShellVM` two
tools tests failed the sanitizer gate. Part 1's second agent later found
that the reconnect test fails from a late timer and a slow reply; whether
the verifiers' time alone was the rest is open, and this module does not
turn them on in `ShellVM`.

## Starting positions

To be measured in part 1. Say where one is wrong.

1. Fault 1's cause is the young `.object` literal stored into an old
   literal frame with no barrier.
2. The compiler cannot make such a literal today without the fuzz test's
   mutation; if it can, name the Smalltalk that does it.
3. Fault 2 is a separate fault with a separate cause, not a later symptom
   of fault 1 (the stall test compiles nothing live; check that).
4. Fault 2 is reproducible in less than twelve minutes a run by a smaller
   program than the full-heap test, once the condition is known.
5. No other store path in the make, define, redefine and remove primitives
   puts a possibly young value into an old object without the barrier.

## Parts

**Part 1: find, measure, write the failing tests. No fix.** Commit it
before part 2.

- Fault 1: confirm the cause by the verifier's own message (which entry,
  which class the holder and the referent have, which slot), not by the
  suspect. Read every allocation and store of `makeMethodObjects`,
  `LiveMethodHeap`, `makeStub`, and primitives 143 to 147, 97 and 98 for
  the same shape, and list each store with "old holder, value may be
  young: yes or no, why". Answer starting position 2 with a test either
  way.
- Fault 2: instrument first. The verifier's line says too little: add to
  it, or to a record beside it, what each entry is (class, age, which
  collection last copied it, whether it is in a carried list, whether a
  promote-all or a full collection ran since the last scavenge). Then find
  the condition under the suite's load, not busy loops, on the smallest
  set of suites that shows it; write the rule for the counted runs before
  them. If it is not seen again in the count the rule allows, say so with
  the counts and what was ruled out; do not guess a fix.
- Write the tests that fail on the starting commit.

**Part 2: fix fault 1.** The choice is the agent's, from part 1's table,
between (a) the barrier's own slow path for the store, so the holder is
remembered like any other old object, and (b) making the literal old
before the store. The verifier decides which is right: what the nursery
verifier and the mark verifier require of an old, read-only, pinned
holder. A method is read-only: check that the remembered-set scan and the
later clear of the remembered mark do not store through the read-only
check or trap on it.

**Part 3: fix fault 2**, when part 1 found its cause. If part 1 did not,
this part is the instrumentation left in place and a counter, and the
stall helper's verifier stays off with the reason beside it.

**Part 4: the verifiers on again.** `kajo test` and `KernelTestParts` at
the build's own level (`verify: nil`); the stall helper when fault 2 is
fixed. The gate that means to verify reads `verify=on` and `verifies=N`
with N above 0 from the run's own line. By the owner's answer the kernel
gate that verifies is the release-build one: say what each kernel gate
(debug, release, sanitizer) does after this module and what it costs
against the baseline. `ShellVM` stays off.

## Tests

Before the code where possible.

- The make primitive with a young literal of each kind part 1's table
  marks "may be young", then a scavenge, with the verifiers on: fails on
  the starting commit with the verifier's message, passes after.
- The same through `makeStub` and a redefine, if the table marks them.
- `MakeFuzzTest` with `--verify` in the kernel gate.
- Fault 2's reproduction, if found.
- Broken variants: the fix taken out fails the new test with the
  verifier's line (a test switch, since a verifier fails it); kept in
  `broken/` when run by hand.
- The random programs gain a live-compile step only if part 1 shows the
  compiler can make a young literal on its own.
- Every new Swift test runs once under ThreadSanitizer with twelve busy
  loops before the tier.

## The bar

1. Each fault has its cause named from the verifier's message and a record,
   or "not found" with the counts.
2. A test for fault 1 fails on the starting commit and passes on the head.
3. `kajo test <image> --verify` passes whole, debug and release, five runs
   of five each, `verifies` above 0 on each line.
4. The lines that switched the verifiers off for fault 1 are gone, and the
   one for fault 2 is gone or has its reason beside it.
5. The core tier is green on the final code commit: `just check
   1318518`, the dry run says "tier: core". The aligned A/B shows no
   kernel outside the base's own spread (the make primitive is not a hot
   path; `interpret` must be identical instruction for instruction, shown
   by the disassembly diff).
6. `shell-report.py --bar` over the Mac and iPhone matrices: every column
   read, against the last core run's rows
   (`~/kajo-scratch/main-offload/check/`).
7. The kernel tests' gate times with their before, per gate.

## Rules of the house that bind here

From `AGENTS.md`'s lessons, read each whole:

- "Read the `verify:` message before naming the suspect."
- "A fallback counter names the symptom; a fallback record names the
  cause" and "Instrument first, then brief".
- "A failure seen only in the full suite is reproduced with the suite's
  load, not with busy loops."
- "A gate failure on a test the module did not write is counted on both
  commits under a rule written first."
- "A barrier belongs to the slot, not to the primitive that first needed
  it": the table of part 1 is this rule applied to stores.
- "Every entry state between generations needs exactly one owner."
- "Closing one escape, look beside it for the same shape."
- "A primitive that clears a protection bit checks every reason the bit
  was set", and the sealed-classes paragraph: the fix adds no way to write
  a verified method.
- "A header-bit test in the store path costs about two cycles per store":
  the fix adds nothing to the hot store path.
- "A check that one line switches off is no check."
- "A test that routes around a trap with a configuration switch is hiding
  a bug."
- "A module's tests are a cost in every later gate run": say what the new
  tests and the verifiers cost each gate.
- The young-collection model (`docs/models/young-collection.md`) is
  updated in the same commit as any change to its protocol.

## Not in this module

- Part 2 of the small fixes (`interpreter.A2`, `memory.A1`, `memory.M2`,
  `interpreter.M1`, `verification.R4`, one `VerificationLevel`).
- The VM's Delay timers on a queue of their own: awaiting the owner.
- The verifiers in `ShellVM` and the tools tests.
- The reconnect test's remaining margins.
- Any change of the collector's design. If a fault's fix needs one, stop
  and hand back with the evidence.

## Deliverables

- The fixes and their tests, the verifiers on as part 4 says.
- This file's "As built": part 1's table of stores, each number with its
  file, the starting positions right or wrong, what the gates cost before
  and after, found, deviations, not done.
- The core tier's `gates.log`.

## Open questions

Build the recommended option; bring the decision back.

1. If the compiler can make a young literal on its own, is fault 1 a
   release-note item (a live compile could lose an object since module
   8d)? Recommended: say what a program must do to hit it and how often
   the kernel's tests do; the owner decides the wording.
2. If fault 2 is not found in the counted runs: recommended, leave the
   instrumentation and a counter in, keep the stall helper's verifier off
   with the reason, and hand it to the weekly run's output.
3. The verifiers in the debug kernel gate as well as the release one, if
   the cost is under a minute: recommended no, by the owner's answer; give
   the number.
