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

## As built

Built by a build agent from 07fcad1, Saturday 2026-11-21. Toolchain: the
swift.org 6.4.2 release through swiftly, first on PATH
(`~/kajo-scratch/verifier-faults/env.txt`). Raw files are under
`~/kajo-scratch/verifier-faults/` (`part1/`, `work/`, `broken/`,
`check/`).

### Part 1: the two causes

**Fault 1.** Reproduced on 07fcad1 itself, debug build, `kajo test
start.img --verify --test 'MakeFuzzTest>>testSeededMutationsAreRefusedOrRun'`:
rc 133, "nursery verifier, before scavenge 1: entry 33422 (old) names
young @102276 (nursery 1) in slot 1, and is not remembered for it"
(`part1/f1-start.err`). The verifier's message now says what each entry
is (`describeEntry` in `Nursery/NurseryVerifier.swift`: class index and
name, old or young with nursery, age and claim tag, slots, the read-only
and pinned bits, the remembered word, the lists naming it, and for a
body a scavenge kept and placed in another nursery, from where in which
scavenge; then the scavenge counters). The same run with it
(`part1/f1-instr.err`):

    entry 33422 (old) names young @102276 (nursery 1) in slot 1 ...
    [holder: Array (class 7), old, 4 slots, read-only, pinned, remembered 0x0 listed 0x0;
     referent: OrderedCollection (class 237), young in 1 age 0 tag 0, 3 slots, remembered 0x0 listed 0x0;
     (scavenges 0, promote-all 0, full collections 0, ...)]

The holder is a read-only, pinned Array, which is what a made method's
literal frame is (`makeMethodObjects` pins it and sets it read-only), and
the referent is the fuzz test's stranger `#(1 2) asOrderedCollection`,
young in the nursery of the worker that ran the test. Starting position 1
is right: `LiveMethodHeap.pointers` allocates with the worker's old
context (`om.allocate(m.state.pointee.context, ...)`, `tryAllocateAny`:
old space), and `makeMethodObjects` stores the literal with `om.store`,
the raw store, which runs no barrier. The main session's three readings
were right; `om.store` is the raw store (no post-store check, no
barrier).

Every store of the make, define, redefine, remove and install
primitives, with "old holder, value may be young":

| Where | Store | Holder | May the value be young? |
|---|---|---|---|
| `makeMethodObjects` (143, `makeStub`) | literal frame slot `om.store(litArray, i, v)` | fresh, old (`LiveMethodHeap`) | **yes** for a top-level literal `CodeReader.literal` answers `.object(v)` as "any other object": an instance of a class that is not sealed (an ordinary object, a Binding, a collection). No for the rest of `.object`: immediates; nil, true, false (image objects, old); a Symbol (made by `internSlow` in the old context or loaded); a Behavior (Class, Metaclass and Behavior are sealed: made only by the image build or primitive 145, old) |
| `makeMethodObjects` | literal Array element `om.store(a, i, v)` | fresh, old | no: an element is an immediate, nil, true, false, a Symbol, a Behavior, or a fresh byte object or Array (old); any other object in an Array is refused ("an element of class N in a literal Array") |
| `makeMethodObjects` | Pragma arguments `om.store(args, i, v)`, Pragma selector, arguments, method | fresh, old | no: the arguments are literal-Array elements (as above), the selector a Symbol, the rest made here |
| `makeMethodObjects` | method slots (bytecodes, literals, selector, class, counts) | fresh, old | no: made here, a Symbol or nil, a Behavior, SmallIntegers |
| `makeStub` (in 146) | the stub's literal: the stub selector | fresh, old | no: a Symbol, checked |
| `defineClass` (145) | class and metaclass slots, the pool, each Binding's key | fresh, old | no: the superclass a registered class, the name and keys Symbols (checked), the rest made here; no promote-all needed |
| `redefine` (146) | dictionary keys and methods, pool elements (the Bindings Smalltalk made), instance sizes | fresh, old | no: `prepareOldSpaceOperation` (module 4's promote-all) runs before any of them, and every allocation after it is old |
| `redefine` (146) | the dictionaries and pools into the classes | old | stored with the barrier (`m.store`, `.installMethod`) |
| `removeClass` (147), `freeObsoleteClasses` (163) | method dictionaries, pool, name, superclass, thisClass | old | stored with the barrier; the values are nil, Symbols and classes, after a promote-all |
| `installInDictionary` (97, 98) | new dictionary's keys and methods | fresh, old | no: Symbols and CompiledMethods (sealed: made only by 143 and the image build, old) |
| `installInDictionary` | the dictionary into the class | old | stored with the barrier |

So one store has the fault: the literal frame slot of a made method, for
a literal that is neither an immediate, nil, true, false, a Symbol nor a
Behavior, and only when nothing promoted it first (the redefine path
promotes everything before it makes its methods). Starting position 5 is
right.

Starting position 2 is right: the kernel's compiler puts only classes and
class variables' Bindings in a literal frame as objects
(`Compiler>>gen:in:on:value:`, `#global` and `#classVariable`). A class
is old. A Binding is made old by primitive 145 (a new class's pool), or
made in Smalltalk (`Smalltalk undeclaredBinding:in:`, `Binding new`, young)
by a redefinition that adds a class variable, which hands it to primitive
146; 146 promotes everything before it makes the recompiled methods and
the pool, so no method made from the compiler's output names a young
Binding. The test `aClassVariableAddedLiveLeavesNoYoungLiteral` defines
a class live, adds a class variable, compiles a method against each and
scavenges with the verifiers on: it passes on the part 1 commit. Only a
CompiledCode whose literals a program changed after compiling (as
`MakeFuzzTest` does) reaches the fault. A closure is refused (BlockClosure
is sealed: `aClosureLiteralIsRefused`).

**Fault 2.** The message names a young holder and a young referent in two
nurseries, the referent's entry next to the holder's. Read in
`placeKept` (`Nursery/Scavenge.swift`): when a nursery has no room for a
body the scavenge kept (the promotion reserve's fallback), the body goes
to another nursery with that nursery's index, and "every holder
remembered for the first nursery is remembered for the second too". Two
kinds of holder are in no list: the young objects of the first nursery
that name the body (a holder of its own nursery needs no bit until the
body leaves), and the body itself, which `drain` remembered for every
nursery but its own first one, so its references to objects of its first
nursery are unremembered once it lies in another. Under the
stop-the-world young mode only old holders are remembered (module 4), so
only the offloaded mode has the fault.

The rare path (a nursery that cannot hold its own kept bodies) is driven
by the new test switch `keptAcrossNurseries`: the last nursery with kept
bodies places them all in the others (its bodies lie in its own space,
the destinations past the others' own placed bodies, so no move
overlaps). With it, a load whose ring nodes are a young Pair naming
another young Pair made just before it (`twinRingSrc`), no promotion
reserve and a tight heap fails the verifier in the offloaded mode in 22 s
(`part1/f2-forced-instr.txt`, 612 failures):

    nursery verifier, after scavenge 131: entry 11474 (young in 0) names young @11473 (nursery 1) in slot 1,
    and is not remembered for it [holder: Pair (class 59), young in 0 age 0 tag 2, ...,
    kept and moved from nursery 3 to 0 in scavenge 131;
    referent: Pair (class 59), young in 1 age 0 tag 2, ..., kept and moved from nursery 3 to 1 in scavenge 131; ...]

The same shape as the gate's line (adjacent entries, two nurseries, after
a scavenge). The full-heap test's program is a chain of young Arrays each
naming the one before, run to out of memory, where promotion finds no
block. Starting position 3 is right: fault 2 has its own cause, and the
full-heap test compiles nothing (its kasm is loaded before the VM runs).
Starting position 4 is right with the switch: 22 s against twelve
minutes. Without the switch the plain ring load (`reserveLoadSrc`, whose
nodes name no young object) moved 2306 bodies across and failed nothing.

**Fault 2 under the suite's load.** Three runs of `swift test --filter
AllocationStallTests` on the part 1 build with the stall helper verifying
(`KAJO_STALL_VERIFY=1`), by the rule written before them
(`part1/rule-fault2.txt`; raw `part1/f2-suite-{1,2,3}.txt`). Each run
trapped in the full-heap test's offloaded half with the shape of the
gate's line, and each line names the referent "kept and moved":

| Run | stw half: kept, moved across | offloaded half: the trap |
|---|---|---|
| 1 | 311 132, 312 | after scavenge 27: entry 153933 (young in 1) names young @153932 (nursery 0), referent kept and moved from nursery 1 to 0 in scavenge 27; 544 moved across so far |
| 2 | 282 625, 0 | after scavenge 27: entry 148627 (young in 1) names young @148628 (nursery 0), the same |
| 3 | 522 407, 0 | after scavenge 21: entry 148628 (young in 1) names young @148629 (nursery 0), the same; the gate's own pair of entries |

So fault 2 is seen 3 of 3 in that set, not 1 of 2 as the gate suggested:
the run alone (`review-3-small-fixes/part1/found2-fullheap-alone.txt`)
passed, and the suite's neighbours decide whether a nursery runs out of
room for its own kept bodies. Deviation from the rule: runs 2 and 3 had
other work of this module beside them (builds, the five verified kernel
runs), so their load is the suite's and more.

Part 1's tests, each run on the part 1 commit (07fcad1 with the
instrumentation, the test switch and the unused barrier site; no fix):

| Test | Part 1 commit |
|---|---|
| `aMadeMethodsYoungLiteralIsRememberedAndSurvivesAScavenge` (kinds 1 to 4: an ordinary object, a Binding, an OrderedCollection, a Set) | fails, each kind: "before scavenge 1: entry E (old) names young @Y (nursery 1) in slot 0 ... [holder: Array (class 7), old, 1 slots, read-only, pinned ..." |
| `withoutTheBarrierTheVerifierNamesTheLiteralFrame` (switch `skipBarrierAt = .methodLiteral`) | passes (the fault is there either way) |
| `aClassVariableAddedLiveLeavesNoYoungLiteral` | passes (starting position 2) |
| `aClosureLiteralIsRefused` | passes |
| `keptBodiesPlacedInAnotherNurseryStayRemembered` (stw, offload) | stw passes; offload fails, 142 to 612 verifier failures a run, every one naming a body "kept and moved" |

(`part1/tests-part1.txt`, `part1/f2-forced-instr.txt`.) The kernel tests
are in `Tests/KajoCompilerTests/VerifierFaultsKernelTests.swift` over the
probe class `Fixtures/verifier-faults/Tests/MakeYoungProbe.class.st`; the
VM test in `Tests/KajoVMTests/Nursery/VerifierFaultsTests.swift`. The
stall tests' helper verifies when `KAJO_STALL_VERIFY` is set (part 1
only, for the counted runs), and its full-heap line prints `keptObjects`,
`keptAcross`, `verify` and `verifies`.

### Part 2: fault 1 fixed with the barrier (37a55b7)

Option (a). `MethodHeap` gained `storeLiteral(_:_:_:)`, the one store of
`makeMethodObjects` that part 1's table marks "yes": the make primitive's
`LiveMethodHeap` stores each literal into the new frame with the barrier
(`Machine.store`, the new site `BarrierSite.methodLiteral`), the image
build's `ImageMethodHeap` keeps the raw store (no VM, nothing young). Every
other store of `makeMethodObjects` stays raw: its values are old or
immediate. `makeStub` goes through the same function.

Why (a) and not (b), from what the verifiers require: the nursery verifier
requires of an old holder of a young object exactly its remembered bit for
that nursery and a list that names it; nothing about read-only or pinned
holders. The holder's read-only bit is set after the store, and nothing
that handles a remembered holder writes its header or its slots: the
barrier's slow path and the scavenge's prep write the remembered word, a
side table beside the entry table (`remMarker`); `scanRemembered` and the
young collector read the holder's slots and never store into them (oops
never change; a copy rewrites the entry). The mark verifier asks nothing
of the remembered set. (b), making the literal old before the store, has
no single-object promotion to use: it would be a promote-all scavenge
inside the make stop at every make that has such a literal. The barrier
adds nothing to the hot store path: the make primitive runs in a stop and
the store it changes is not in `interpret`, whose disassembly is
unchanged (Gates).

No new way to write a verified method: the store happens before the frame
is made read-only and pinned, as before, through the same slot.

### Part 3: fault 2 fixed in placeKept (70c8d8c)

After the moves across nurseries, with young holders remembered across
nurseries (module 7's configurations), `placeKept` scans again every young
object of each nursery that lost a body (its survivor log: the survivors
copied into it and the kept bodies placed in it) and every moved body,
sets the remembered bits of the other nurseries each one names, and lists
a holder whose word it turned from zero with the first participant's
holders, which go to the carried lists right after. A local correction
of one stopper step that runs only after a scavenge that kept something
and moved a body across: no protocol changes, no model step changes (the
young-collection model has no kept bodies; `docs/models/young-collection.md`
is unchanged). The counter `keptAcrossHolders` (on the run line beside
`keptAcross`) counts the holders the scan remembered; the test switch
`keptAcrossWithoutRescan` is the broken variant.

### Part 4: the verifiers on again

| Where | Before (07fcad1) | After |
|---|---|---|
| `kajo test` (`Sources/kajo/Test.swift`) | off unless `--verify` | the build's level: on in a debug build, off in a release build |
| `KernelTestParts` (`runKernelTests`) | off | on in a release build, off in a checked build (the owner's answer: the release kernel gate only) |
| the stall tests' helper | off | the build's level (on in `swift test` and the sanitizer gates) |
| `ShellVM` | off unless the host asks | unchanged |
| gate `kernel-test` (debug `kajo test`) | off (the default) | `--no-verify` (the owner's answer) |
| gate `tools-test` (debug `kajo test dev.img`) | off (the default) | `--no-verify` |
| gate `native-kernel-test` (release `kajo test --native`) | off | off (the release build's level) |
| gate `test-release` (release `swift test`, its kernel parts) | off | **on** |
