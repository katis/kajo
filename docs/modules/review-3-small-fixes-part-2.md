# The third review's small fixes, part 2

## Status

Brief, written 2026-11-21 by the main session. Not built.

The owner, 2026-11-20, after the third review (`docs/reviews/2026-11-20/`):
"Small safe fixes"; and "agreed on questions" (the verifier's faults first,
then this part). On 2026-11-21, to "Shall I brief part 2 of the small fixes
and start its build agent?": "Yes, brief it".

A core-tier module. Part 1 (`docs/decisions/50-review-3-small-fixes.md`)
held the items outside the core directories; the verifier's two faults
(`docs/decisions/51-verifier-faults.md`) came between.

## What it is

Six small items of the review that lie under the core directories. Two are
gaps a check should close (the native layout's hash, the test switches no
test names), one is a cost with a known mechanism (Float arithmetic), one
is a cost to bound before it is built (the barrier's slow path), one is a
counter that decides whether a later module exists (weak slots in the
concurrent young collector), and one is a tidy-up of what "checked" means
(one verification level).

## What is known

Each item points at its finding; read the finding whole before the code.
The reviewers built and measured nothing: every number in a finding is an
estimate or a quote, and every line reference is checked before it is built
on. The main session read the findings and, of the code, only
`rememberSlow` (`Nursery/Barrier.swift:65-81`, as the finding quotes it) on
ac3b752.

1. **`interpreter.A2`: layout facts the hash does not cover.** The layout
   hash is the SHA-256 of `NativeLayout.constants`. The generator writes
   numbers that do not come from them: the barrier word as `W_FLAG + 2`
   (`barrierWord(flag)` of the marking module), frame slots as `h[0]` to
   `h[4]`, `hdr[4]`, `hdr + 4 + depth`, `hdr[5 + i]`, and the C structs
   `KGroup`, `KResume`, `KModule` mirrored by hand on the Swift side. If
   the barrier word moves, the hash does not change and native stores skip
   the SATB barrier.
2. **`interpreter.M1`: Float arithmetic takes the integer path first.**
   `Machine.arith` calls `integerArith`, which sends every pair that is not
   two SmallIntegers to `largeArith`; for SmallInteger op Float that builds
   a `BigInt` (a Swift array: a `malloc` and a `free`) before the float is
   seen. Every float special send also saves and restores the registers
   around a computation that cannot pause when the result is a SmallFloat.
   `floats`: 2998.8 ms interpreted, 2683.1 ms native (`docs/modules/aot.md`,
   AOT 1's commit; measure again).
3. **`memory.M2`: the barrier's slow path tests "already remembered"
   last.** About twelve loads and a counter write before the `ldar` that
   ends 99.9 percent of the calls. The finding's quoted rows: `share` at 7
   workers `gc_barrierSlow=419 219 415` in 10 s for `gc_ycHolders=60 258`;
   `ring` 164 650 141 for 193 913. The gain is an estimate.
4. **`memory.A1`: weak slots are strong in the concurrent young
   collector.** The stop-the-world scavenge does not trace a weak object's
   indexed slots; the concurrent collector does
   (`YoungCollection/Collect.swift`, "Weak and ephemeron slots are strong
   here (v0)"). Since the main worker always offloads, a product run has no
   stop-the-world scavenge in steady state, so a young object held only
   weakly is promoted and dies in a marking cycle. The symbol table's
   buckets are weak. How many objects this is, nobody has counted.
5. **`verification.R4`: broken variants have no list.** Six switch structs,
   73 fields by the reviewer's count (more now: the verifier's faults added
   two to `NurseryTestSwitches`). Three fields are named in no test file:
   `VMTestSwitches.noPendingRoots`, `MarkingTestSwitches.youngRootsInStop`,
   `MarkingTestSwitches.stallRelocation` (the last set by `Headless` from
   `--stall-reloc`).
6. **`verification.A1`, the rest: one `VerificationLevel`.** Part 1 made
   `Headless.Options.verify` a `Bool?`; the verifier's faults set the
   levels per build (on in a release build's kernel tests and stall tests
   and in every `kajo test` not told otherwise; the debug kernel gates say
   `--no-verify`; `ShellVM` off). What "checked" means is still decided in
   several places: `ObjectMemoryConfig.verify`, `onVerifyFailure`,
   `VMConfig.verifyStops`, `YoungConfig.verify`, `verifySymbols`, the test
   fixture's `Runtime`, `Headless.configs`, `ShellVM`.

A test known to be thin, not this module's:
`theToolsDevelopTheImageTheyRunIn` failed the sanitizer gate of the
verifier's faults (1 of 2 on that module's starting commit, 0 of 2 on its
head, 0 of 1 on a9a09f2). A failure of that test with "nil does not
understand #beginsWith:" is read as that.

## Starting positions

To be measured in part 1. Say where one is wrong.

1. Moving the barrier word (`flag + 3` in a scratch tree) fails no gate
   today: the native golden and kernel gates pass and the hash is equal.
2. `SmallInteger op Float` allocates on the special-send path; no float
   operation whose result is a SmallFloat needs a save.
3. More than 99 percent of `rememberSlow`'s calls on `share` and `ring`
   leave at the remembered-bit test.
4. A cheating build that returns at the top of `rememberSlow` for an old
   holder gains more than 1 percent on `share` or `ring`. Not known; this
   decides item 3.
5. `weakOnlyCopies` is near zero in the kernel tests and a visible share of
   `ycPromoted` in a load that interns and drops Symbols. Not known.
6. The three switches no test names are still read by product code, and
   each one's broken variant still fails as its module's doc says.
7. One level can replace the scattered defaults without changing what any
   gate verifies today.

## Parts

**Part 1: measure and bound. No fix.** Commit it before part 2.

- Item 1: run starting position 1's broken variant by hand in a scratch
  tree (`git archive`), keep its output.
- Item 2: `floats` in both engines, aligned, five interleaved runs, the
  base against itself first for the spread; count the allocations on the
  path (a counting build or the disassembly; say which).
- Item 3: the cheating build (unsound, never committed), headless, aligned,
  five interleaved runs on `share` and `ring` and the kernels, cycles as
  well as time. Write the rule before the numbers and commit it or copy it
  with its time: build item 3 only if the ceiling is at or above 1 percent
  of cycles on `share` or `ring` and outside the base's own spread.
- Item 4: the counter `weakOnlyCopies` (objects first copied through a weak
  object's indexed slot, in `scanHolder` and `drainGrey`), on the run line
  and in the shells' rows. It stays in the product; it is this module's
  whole answer to item 4. Run the kernel tests, the tools' scripted session
  (`mode=devsession`), `collections` at 1 and 8 workers, and one program
  written to intern and drop Symbols. Report it beside `ycPromoted`.
- Item 5: the table of every switch field, each with the test that sets it
  or "by hand" with its command and the message it must give; the by-hand
  ones counted and timed.
- Item 6: the table of every place that decides a verifier's default or
  overrides it, and what every gate verifies today (read `verify=` and
  `verifies=` from each gate's own output).

**Part 2: the fixes.**

- Item 1: the barrier word's offset becomes a constant of
  `NativeLayout.constants`, computed from the Swift declaration, and the
  generator emits it; every frame index is emitted from `Frame.*`; the
  tables file gains `_Static_assert`s of `sizeof` and `offsetof` for the
  three structs with the Swift side's numbers on the right, so `native-cc`
  fails when a mirror disagrees. The emitted code is otherwise the same
  text. The hash changes: say what holds an old hash (the native test
  cache, a generated app's build) and that each refuses or rebuilds.
- Item 2: in `specialFastPath` and primitives 60 to 69, before any save:
  when one operand is a SmallFloat and the other a SmallFloat or a
  SmallInteger, compute; when the result is a SmallFloat or a Boolean,
  write it and return with no save and no restore. Box only through the
  existing path. `integerArith` calls `largeArith` only when one side is a
  LargeInteger. The new path neither allocates nor polls. The dispatch
  loop's own code does not change.
- Item 3: only under part 1's rule. Then: the remembered-bit test first,
  the `ldar` still seq_cst, the counter after the test or the early exit
  counted in a field of its own, `skipSite` tested only where the bit is
  about to be set. The protocol does not change; if it must, stop.
- Item 4: nothing more than the counter.
- Item 5: a table test over the source, as `ClosedShellCallsTests` has for
  `ShellVM`: it reads the six structs' fields and fails for a field with
  no row. The three unnamed switches get a test, or a by-hand row with
  the command run once and its output kept, or are removed if nothing
  reads them.
- Item 6: one `VerificationLevel` (`off`, `stops`, `all`), one default per
  build, one function that applies it to every config that has a verifier
  switch. `Headless.Options`, the test `Runtime` and `ShellVM` take the
  level. The run line prints it (`verify=off|stops|all`; `verifies=N`
  stays). Every gate verifies after this module exactly what it verified
  before, shown by part 1's table read again.

## Tests

Before the code where possible.

- Item 1: a test that the hash covers the barrier word's offset (change the
  constant through a test seam, the hash changes); the broken variant by
  hand after the fix (`native-cc` or the bind refuses it), output in
  `broken/`.
- Item 2: every arithmetic and comparison selector on SmallFloat with
  SmallFloat, SmallInteger with SmallFloat both ways, a result that must
  box, NaN, infinities, signed zero, a SmallInteger past 2^53, division by
  zero: the answers equal to the starting commit's on a table of seeded
  operands (the old path is the oracle; keep it reachable through a test
  switch for this comparison). `ExtremeIntegerTests` still passes. A test
  that the fast path allocates nothing.
- Item 3, if built: the barrier-site mutation tests and `checkRemembered`
  as they are; a test that the early exit is counted.
- Item 4: the counter reads above 0 on a program that holds a young object
  only through a weak slot across a concurrent young collection, and 0
  under `--young stw`.
- Item 5: the table test fails with a field added and no row (shown by
  hand).
- Item 6: `verifiersAreOneFlagAway` and
  `verifiersRunAtEveryPauseWhenEnabled` as they are; a test of each level's
  effect on each config.
- New Swift tests run once under ThreadSanitizer with twelve busy loops
  before the tier.

## The bar

1. Starting position 1's broken variant fails a named gate after the fix.
2. `floats` in both engines, before and after, aligned, with the spread;
   the checksums equal; no allocation on the SmallFloat path.
3. Item 3: the rule's file with its time before the numbers, the ceiling,
   and built or not built by the rule.
4. `weakOnlyCopies` beside `ycPromoted` for the four loads.
5. Every switch field has a row; the three are tested, by hand with their
   output, or gone.
6. Part 1's table of what each gate verifies, equal before and after.
7. The core tier green on the final code commit (`just check ac3b752`, the
   dry run says "tier: core"). The aligned A/B: no kernel slower outside
   the base's own spread; `interpret` identical instruction for
   instruction, or every differing instruction explained from the
   disassembly; `just arc-check`.
8. `shell-report.py --bar` over both matrices, every column, against
   `~/kajo-scratch/verifier-faults/check/`.
9. Gate times against that run's `gates.log`, and what the new tests cost.

## Rules of the house that bind here

From `AGENTS.md`'s lessons, read each whole:

- "Bound an optimization with a cheating build before building it."
- "A rule's clause is no tighter than the measurement's own spread" and "A
  file's time is proof of order only until the file is edited."
- "A slow path called from the interpreter loop must be one out-of-line
  call with nothing of the current instruction live across it", "A bigger
  dispatch loop costs register allocation before it costs instructions",
  "Twenty-four instructions in the dispatch loop are enough to move its
  registers", "Inlining moves ARC".
- "Placement decides single A/Bs even with the alignment flags."
- "Swift's `case a, b, c where cond` applies the condition to `c` only":
  check that an A/B switch switches.
- The young-collection model's findings on the barrier's seq_cst load, and
  "A barrier belongs to the slot".
- "A primitive checks its bounds one by one before any arithmetic on its
  arguments."
- "A rule every member of a type must keep is kept by a test that reads the
  source."
- "A switch nobody ran is a switch nobody tested" and "A broken variant's
  test reads a value the variant defines."
- "A check that one line switches off is no check" and "A verifier's cost
  is per build, and so is its level."
- "A summary that classifies a field lists the field's every value first":
  `verify=` gains a value; every reader of it (the gates' checks,
  `KernelTestParts`, `shell-report.py`) is listed and changed in the same
  commit.
- "A changed gate script is run once on its own before the gate run."
- "A module's tests are a cost in every later gate run."

## Not in this module

- Porting the weak pass to the concurrent young collector (`memory.A1`'s
  proposal past the counter): a module of its own with a model, if the
  counter says so.
- `scripts/broken-variants.sh` and the weekly run of the by-hand variants
  (`verification.R4`, part 2 of its proposal).
- The VM's Delay timers on a queue of their own; the verifiers in
  `ShellVM`; the reconnect test's margins; the tools test that fails under
  the sanitizer.
- The review's larger levers and its gate-time findings.
- A pure `vt` entry for float arithmetic in the native engine.

## Deliverables

- The fixes, the counter, the tests.
- This file's "As built": part 1's tables and rule, each number with its
  file, the starting positions right or wrong, deviations, not done, found.
- The core tier's `gates.log`.

## Open questions

Build the recommended option; bring the decision back.

1. `weakOnlyCopies`: at what share of `ycPromoted` is the weak pass worth
   its module? Recommended: bring the four numbers; the owner decides.
2. Item 3 under the rule but with a gain only on `ring` or only at 8
   workers: recommended, build it, since the protocol does not change.
3. The by-hand variants in the weekly run: recommended, a later module;
   bring the count and the time of each from part 1.
4. `verify=stops` as the release build's default for `kajo run`:
   recommended no change in this module (every default as today).

## As built

Built by one build agent from 2026-11-21 on 8c24c05; toolchain swift.org
6.4.2 (swiftly), first on PATH (`~/kajo-scratch/review-3-part-2/env.txt`).
Work files in `~/kajo-scratch/review-3-part-2/`.

### Item 3: the rule, written before its numbers

Committed here before the bound ran (the file
`part1/rule-item3.txt`, written 2026-11-21 21:43:24, is the same text):

```
The third review's small fixes, part 2, item 3 (memory.M2): the rule, written
before any number of the cheating build was run. Copied with its time
(cp -p) and committed in the module doc before the bound runs.

Builds. ab.sh's aligned builds (-c release -enable-testing
-align-all-nofallthru-blocks=5 -align-loops=32, product kajo) of
  base  = 8c24c05 (git archive), and
  cheat = 8c24c05 with one line at the top of rememberSlow
          (Nursery/Barrier.swift): an old holder returns at once
          (`if headerWord(o) & youngBit == 0 { return }`). Unsound; never
          committed.

Loads. Headless `kajo run ... --slice-ms 0`, the defaults otherwise (gc cm,
young offload, reloc on, nursery 4096 KiB):
  share = prelude.kasm lib.kasm sharestorm.kasm (module 7's matrix load)
  ring  = prelude.kasm lib.kasm fragmentIters.kasm fragment.kasm
plus ab.sh's kernels (alloc arith fib ivars sends storeheavy st-closures
st-ivars st-sends), each at 1 and 8 workers.

Runs. Five runs, the sides interleaved within each run (A then B per
kernel and worker count). First the base against itself (the same base
binary on both sides): the spread. Then base against cheat.

Measure. Per row (load, workers): the median over the five runs of
workerCycles and of ms per side; the ratio cheat/base of the medians; the
per-run ratios. Checksums equal between the sides in every run (a row whose
checksum differs or whose run fails is void and said).

Spread. For each row, base-vs-base: S = max over runs of |1 - per-run cycles
ratio|, and the median ratio's distance from 1.

Decision. Build item 3 if and only if, for share or ring at 1 or 8 workers,
  (a) the cheat's median cycles ratio is at or below 0.99 (a ceiling of at
      least 1 percent of cycles), and
  (b) 1 - that ratio is greater than the row's base-vs-base S.
Cycles decide; time is reported beside them. A gain on one row only (ring
only, or 8 workers only) satisfies the rule (the brief's open question 2,
recommended: build).

If the cheat cannot run share or ring (it is unsound: a lost young object
may crash a run or change its checksum), that row is void for the cheat and
the bound is taken instead from a sound cheat B on the same base: the
remembered-bit test moved to the top of rememberSlow (load young state,
nursery, the remembered word seq_cst, return if set), no counter and no
skipSite before it: the fix's own order without its counter. Same rule (a)
and (b) on B. This is said in the doc as a deviation.
```
