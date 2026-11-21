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

## Part 1: measured and bounded (no fix)

Every number below names its file under `~/kajo-scratch/review-3-part-2/`.
Timings are ab.sh's aligned `-enable-testing` release builds, five runs
interleaved per row, `--slice-ms 0`, `workerCycles` beside wall time
(`scripts/bench2.sh`, `scripts/table2.py`). The machine was not idle:
`spotlightknowledged`, a system process of the owner's account, held one
core near 100 percent through the runs (load average 4 to 7 on 12 cores,
each `bench.txt` header). One thing of this module measured at a time.

### Item 1: starting position 1, right

On 8c24c05 with `barrierWord` returning `flag + 3`
(`broken/flag3-src`, `git archive` plus the one line), the native
engine's three gates pass (`native-check.sh golden`: 24 ok rows;
`kernel-test`: kernel and dev images, product and full configurations,
every test passed; `cc`: mac and ios, 0 warnings; `broken/flag3-native-*.txt`),
the layout hash is equal (`0x9d8b8adaace03dcf 0x14942b18a4940483` both
sides) and the generated store still tests word 2
(`AT(s, W_FLAG, u32 *) + 2`) while the VM sets word 3
(`broken/flag3-summary.txt`). Every native store made while marking or
while a young collection is open would skip its barrier; no gate sees it.

### Item 2: Float arithmetic

A counting build of 8c24c05 (`part1/count-src`: counters at
`largeArith`'s entry, at `bigInt`'s SmallInteger branch, which builds the
`BigInt`'s Swift array, and before `floatArith` in `arith`; not
committed) over `floats` (30 M iterations, 1 worker), the same in both
engines (`part1/count-floats.txt`, `count-floats-native.txt`, the native
run with a module the counting build generated; the base's module was
refused, "its layout hash is not this VM's build", since the counters
moved the worker's fields):

| counter | interpreter | native |
|---|---|---|
| special sends answered by the tier | 120 000 000 | (same) |
| `largeArith` entered | 120 000 000 | 120 000 000 |
| `BigInt` arrays built (a `malloc` and a `free` each) | 30 000 000 | 30 000 000 |
| `floatArith` reached | 120 000 000 | 120 000 000 |
| floats boxed | 0 | 0 |

Every float special send (4 an iteration) takes the out-of-line
LargeInteger tier first; every SmallInteger times SmallFloat (1 an
iteration) allocates a Swift array there. Starting position 2 right: the
SmallInteger-op-Float path allocates; and no operation of `floats`
needs a save (none boxes, none polls), though all of them save.

The base against itself, `floats` (`part1/floats-self-interp/`,
`floats-self-native/`):

| engine | workers | cycles B/A median | per-run range | ms A / B |
|---|---|---|---|---|
| interpreter | 1 | 1.0011 | 0.9945..1.0040 | 3193.6 / 3196.3 |
| interpreter | 8 | 1.0314 | 0.7194..1.4607 | 458.2 / 548.9 |
| native | 1 | 0.9920 | 0.9892..1.0057 | 2901.3 / 2877.0 |
| native | 8 | 0.9768 | 0.8308..1.3826 | 412.5 / 399.4 |

At 8 workers the base is not comparable with itself (a run's ratio from
0.72 to 1.46): eight threads `malloc` and `free` a `BigInt` array 30 M
times between them.

### Item 3: the bound, and not built

The rule is above, committed (5e10684) before any of these numbers ran.

The base against itself (`part1/self/table.md`) and the brief's cheating
build, an old holder returning at the top of `rememberSlow`
(`part1/cheat/table.md`):

| row | base vs base: median, S | cheat: median cycles ratio |
|---|---|---|
| share, 1 | 1.0007, 0.0016 | 0.9917 |
| share, 8 | 0.9947, 0.0257 | void: 5 of 5 runs failed (one "doesNotUnderstand #check", four with no line) |
| ring, 1 | 1.0001, 0.0220 | void: 5 of 5 "doesNotUnderstand #at:put: in fragStep:i:" or no line |
| ring, 8 | 0.9875, 0.0287 | void: 5 of 5 failed |

The cheat is unsound and three of its four rows lost objects, as the rule
foresaw; share at 1 worker gains 0.83 percent, under (a). By the rule the
bound is then cheat B, the remembered-bit test moved to the top of
`rememberSlow` with no counter and no `skipSite` before it, sound
(`part1/cheatb/table.md`, checksums equal in every run):

| row | cheat B median cycles ratio (exact) | (a) at or below 0.99 | (b) 1 - ratio above S |
|---|---|---|---|
| share, 1 | 0.99369 | no | (0.0063 against 0.0016) |
| share, 8 | 0.98996 | yes | no: 0.0100 against 0.0257 |
| ring, 1 | 0.99516 | no | no |
| ring, 8 | 1.00071 | no | no |

No row meets (a) and (b). **Item 3 is not built.** The other kernels under
cheat B are within their own spread (the 8-worker rows of that run were
noisier in time than the base's own run; cycles decide). Starting
position 4 (a gain above 1 percent outside the spread) wrong: the bound is
under the spread.

Starting position 3, right: cheat B's own counter counts only the calls
that pass its early exit. Per run of 3 M iterations (run 1 of each row,
`part1/cheatb/bench.txt`): share at 1 worker 4 369 399 calls, 1 past the
test; share at 8, 35 998 634 and 4 006 (0.011 percent); ring at 1 and 8,
2 000 000 and 2 023 and 2 024 (0.10 percent). More than 99.89 percent of
the calls leave at the remembered-bit test.

### Item 4: `weakOnlyCopies`

The counter is built (this commit): objects the concurrent young
collector first copied through a weak object's indexed slot, counted in
`scanHolder` and `drainGrey` by the tally's copy count before and after
`classify` of each weak slot (`classifyWeak`, out of line; the strong
slots' loop is unchanged; the weak bit is one load of the class formats
table per object, read once per collection). On the run line as
`weakOnlyCopies`, in the shells' rows as `gc_weakOnlyCopies`, in `kajo
test`'s summary line and the devsession line beside `ycPromoted`. It is an
upper bound on objects held only weakly: a referent first reached through a
weak slot and then through a strong one is counted.

| load | weakOnlyCopies | ycPromoted | file (`part1/weak/`) |
|---|---|---|---|
| kernel tests (`kajo test`, release, 262 passed) | 0 | 923 895 | `kernel-test.err` |
| tools' scripted session (`mode=devsession`, Mac shell, Release) | 2 | 1 370 041 | `devsession.txt` |
| `collections`, 1 worker | 0 | 600 009 | `collections-1.txt` |
| `collections`, 8 workers | 0 | 4 800 072 | `collections-8.txt` |
| a million Symbols interned and dropped, 1 worker | 0 | 0 | `symbols-1.txt` |
| the same split over 8 workers | 0 | 0 | `symbols-split-8.txt` |

Starting position 5 half wrong. Near zero in the kernel tests, right. In
a load that interns and drops Symbols the counter is 0 and so is
`ycPromoted`: a Symbol is made old (an old allocation under the intern
lock, `docs/modules/symbol-interning.md`), so the symbol table's weak
buckets never name a young object, and memory.A1's example does not
arise. The weak pass for the concurrent collector would buy, on these
loads, two objects in 1.37 million promoted.

The test: `weakOnlyCopiesCountsWhatOnlyAWeakSlotHeld`
(`Tests/KajoVMTests/YoungCollection/WeakOnlyCopiesTests.swift`): a weak
bag whose slot takes a fresh object every iteration; the counter reads
above 0 under offload (30 at 2 M iterations, `work/weakonly-test.txt`; the
committed test runs 500 000 to keep its debug time near 3 s)
and the young report is absent under `--young stw`.

### Item 5: the switch table

75 fields in the six structs today (`part1/switches-raw.txt`,
`scripts/switches.py`; the reviewer counted 73, the verifier's faults
added two). For each, the first test that sets it (a `.field` assignment
or a key path; `part1/switch-tests.txt`, `scripts/switch-tests.py`).
Seventy-one are set by a test. Four are set by none:

| field | read by | today |
|---|---|---|
| `VMTestSwitches.noPendingRoots` | `startDelay` (`Processes/External.swift`) | named in no test and no doc |
| `MarkingTestSwitches.youngRootsInStop` | `initialMark` (`Marking/InitialMark.swift`) | module 7's in-pause scan kept as a switch (`final-mark.md`); no test |
| `MarkingTestSwitches.stallRelocation` | the relocator's pass (`Relocation/Relocator.swift`), set from `--stall-reloc` and the shells' `stallreloc=` | an option, not a broken variant |
| `YoungTestSwitches.mainWaitsForWantedStops` | `openYoungCollection` | its test's comment says "run by hand" (the reviewer's grep counted the comment) |

Starting position 6 right: all four are read by product code. The broken
variants whose bad value runs only by hand, each run once on 8c24c05 in
`broken/byhand-src` (a debug build, 39 s from the cache;
`broken/byhand-times.txt`):

| variant | command | what it gave | time |
|---|---|---|---|
| `flushAfterStop` | `registersAreFlushedBeforeEveryStop` with `arguments: [true]` | trap, "Assertion failed: marking a reference to a free entry: @1536" (`Collector.swift:213`), as `workers.md` says | 2 s |
| `mainWaitsForWantedStops` | the switch set in `theMainWorkerOpensOneCollectionWhileAStopIsWanted` | "Expectation failed: openedInside" and "opensWhileWanted == 1" after 30 s, as its comment says | 31 s |
| `lateSignalsIgnoreEnd` | `KAJO_BROKEN_DELAY_END=1 swift test --filter brokenVariantALateTimerTouchesTheFreedVM` | the test process "exited with unexpected signal code 11", as `delay-outlives-vm.md` says | 3 s |
| `stallRelocation` (an option) | `kajo run fragment --workers 8 --heap 64 --marker-slowdown 32 --stall-reloc plain\|reserve\|skip` | each value reaches its own counter: plain 0 reserve cycles and 0 skipped, reserve 6 and 0, skip 0 and 10 (with 4 fallbacks, the variant part 4 discarded); checksums equal | 5 s each |

Files: `broken/byhand-*.txt`, `part1/stallreloc-*.txt`. Three by-hand
variants of switch fields, 36 s together after a 39 s build; the other
by-hand variants (the generator's `AOTOptions.broken*`, the
environment-switched shell variants, the trapping pins) are outside the
six structs and are not counted here (open question 3).

### Item 6: what decides "checked", and what every gate verifies

Every place that sets a verifier's default or overrides it, on 8c24c05:

| place | what it decides |
|---|---|
| `ObjectMemory/Config.swift:81-82` | `verify = checkedBuild`; `onVerifyFailure = checkedBuild ? .trap : .record` |
| `Workers/VMConfig.swift:53` | `verifyStops = checkedBuild` (the stop and schedule verifiers) |
| `Workers/VMConfig.swift:58` | `verifySymbols = false` in every build (tests turn it on) |
| `YoungCollection/YoungConfig.swift:58` | `verify = false` in every build (a heap walk after every collection) |
| `Headless.swift:23, 324, 337-338` | `verifies = verify ?? checkedBuild`; young and object-memory verifiers from it; `.trap`; `verifyStops` left at the build's default |
| `Shell/Shell.swift:358` | a `ShellVM` with no word from its host: `verify = false` |
| `kajo/main.swift:135`, `kajo/Test.swift:37` | `--verify`, `--no-verify` |
| `Tests/.../Runtime.swift:25, 34-35` | `verifyStops = true` in every build; `verify` (default true); `.record` |
| other fixtures | `SavedProcessTests` (as `Runtime`), `makeMemory`, `makeImage`, `largeMemory`, `ImageTests` (object memory only), `FuzzEntry` (on, trap), `KernelTestParts` and the stall tests' helper (`verify = !checkedBuild`), `VerifierFaultsKernelTests` (on), `RedefineOrderTests` (`verifyStops`) |

What each gate verifies, read from the last core run's own outputs
(`~/kajo-scratch/verifier-faults/check/`, 2c13ed3) and the code each
runs:

| gate | build | stop verifiers | heap verifiers | printed |
|---|---|---|---|---|
| `kernel-test` (`--no-verify`) | debug | on (the checked default) | off | `verify=off verifies=0` |
| `tools-test` (`--no-verify`, Smalltalk tier) | debug | on | off | `verify=off` |
| `test-release`, `KernelTestParts` | release | off | on (object memory, young) | `verify=on verifies=734`, `1099` |
| `swift-test-load`, `tsan`, `tsan-load`, `KernelTestParts` | debug | on | off | `verify=off verifies=0` (2 parts each) |
| the same gates, `Runtime` tests | both | on | object memory on unless a test says `false`; young as each test sets | (not printed) |
| `native-kernel-test`, `native-golden`, `golden` | release | off | off | `verify=off verifies=0` (`kajo test`), not printed (`kajo run`) |
| `soak` (the random programs) | release | on (`Runtime`) | per configuration | (not printed) |
| the matrices (shells, `ShellVM`) | Release apps | off | off | (not printed) |

Starting position 7 is decided in part 2: three levels cannot express
"heap verifiers without the stop verifiers", which is what `test-release`
runs today; see part 2's item 6.

## Part 2: the fixes

### Item 1: the layout facts the hash did not cover

- `barrierWordIndex` (`Marking/MarkingState.swift`) is the barrier word's
  index in the flag line; `barrierWord` adds it, and `NativeLayout.constants`
  carries it as `FLAG_BARRIER_WORD`. The generated store tests
  `AT(s, W_FLAG, u32 *) + FLAG_BARRIER_WORD`.
- Every frame index the generator writes comes from `Frame` (`h[...]`,
  `hdr[...]`, `hdr + ...`, the overflow bounds); `Frame`'s indices became
  `package` for it. The emitted text of these is unchanged.
- The tables file asserts the three structs against their Swift mirrors:
  `_Static_assert(sizeof(...))` and one `__builtin_offsetof` per field for
  `KResume`, `KGroup` and `KModule` (27 lines), the right-hand sides from
  `ResumeOffset` (new: the literal 16 and 8 in `nativeResume` became
  `ResumeOffset.stride` and `.pc`), `GroupOffset` and `ModuleOffset` (now
  `package`, with `size = 112`). A mirror that disagrees fails the C compile,
  so `native-cc` and every native gate that compiles a module.
- `NativeLayout.hash(of:)` is the hash over any list, the tests' seam.

The generated code of `storeheavy`, base against head
(`work/gen-diff/diff.txt`): the new constant, the hash
(`0xeb14e5e6cf9e2e48 0x20e9cddd47cfccb2` against
`0x9d8b8adaace03dcf 0x14942b18a4940483`), the barrier line and the 27
asserts; nothing else differs. The worker's offsets did not move (the
float path's counters, item 2, are after the native state).

What holds an old hash: the native test cache (`.build/native-test-cache`)
is keyed by the generated source, which now differs, so each module is
compiled again; a module built by an older VM is refused whole at bind
("its layout hash is not this VM's build", shown below); a generated app
generates its module in its build phase with the checkout's `kajo`, so a
module from an older checkout is likewise refused at bind and the app runs
interpreted until it is built again (not exercised here beyond `just
new-check`'s fresh builds). None needs a hand step.

Tests: `theLayoutHashCoversTheBarrierWordsPlace` (the constant is
`barrierWord`'s own distance; a changed constant changes the hash) and
`theGeneratedCodeNamesTheBarrierWordAndAssertsTheMirrors`
(`Tests/KajoVMTests/Native/NativeLayoutTests.swift`). Neither can run on
8c24c05 (the constant, the seam and the mirrors' enums are new).

### Item 2: Float arithmetic answered before the save

- `smallFloatArith(op, a, b, true, false)` (`ObjectModel/Numbers.swift`):
  a SmallFloat with a SmallFloat or a SmallInteger; the four operations and
  six comparisons; a SmallFloat or a Boolean answer, else 0 (another
  operand, a result that must box, a zero divisor, `//`, `\\`, the bit
  operations). The same arithmetic as `floatArith`. No allocation, no poll.
- `specialFastPath` calls it before its `numeric` test and its `save`; an
  answer is written over the operands and the registers are re-derived with
  `regsAt` (the bases from the frame's method, no restore). Primitives 60
  to 69 do the same in `primitiveSend` before its save
  (`floatPrimitiveQuick`). Every other case takes the old path unchanged.
- `integerArith` enters `largeArith` only when one side is a
  LargePositiveInteger or LargeNegativeInteger object (`isLargeInteger`, one
  class test); before, every pair that was not two SmallIntegers did.
- The dispatch loop is unchanged (below).
- Counters: `smallFloatAnswers` (the path's answers) and `largeArithCalls`
  (entries of the LargeInteger tier) in `Worker.floatPath`, placed after
  the native state so no offset the interpreter or a native module reads
  moves (a first version in `InterpreterCounters` moved `W_COUNTDOWN` and
  every native offset by 16 bytes; seen in the generated-code diff and
  moved). On the run line with `specialSendTier` and `floatsBoxed`, which
  were counted and not printed (interpreter.A3, these two only).
- Test switch `noSmallFloatPath` (`TestSwitches`): the old path, for the
  oracle.

`floats`, base 8c24c05 against head c46df34, aligned, five interleaved
runs, each side's own native module (`work/floats-ab/`):

| engine | workers | cycles B/A | per-run range | ms base | ms head | checksums |
|---|---|---|---|---|---|---|
| interpreter | 1 | 0.4274 | 0.4238..0.4291 | 3207.6 | 1367.2 | equal |
| interpreter | 8 | 0.3517 | 0.3376..0.3961 | 589.3 | 182.7 | equal |
| native | 1 | 0.3854 | 0.3824..0.3864 | 2925.7 | 1127.5 | equal |
| native | 8 | 0.3605 | 0.3557..0.3807 | 434.8 | 153.8 | equal |

The base's own spread was 0.9945..1.0040 at 1 worker and 0.72..1.46 at 8
(part 1); the head's 8-worker rows are tight, since no thread allocates.
`floats` now takes 2.3 times less in the interpreter and 2.6 times less
natively at 1 worker.

`interpret`, base against head in these aligned builds
(`work/interpret-diff.txt`): 1816 lines each, 4 differ, each an `adrp`
page number (the jump table's and a constant pool's page, moved by the
binary's layout: `adrp x26, 552` against `549` and three like it); no
instruction differs. `just arc-check` passed (`work/arc-check.txt`):
`interpret` 1403 instructions, one jump table, ARC 0 on every checked path,
`specialSend` 789 instructions and `primitiveSend` 491 with ARC 0.

Tests (`Tests/KajoVMTests/ObjectModel/SmallFloatPathTests.swift`):
`theSmallFloatPathAnswersAsTheOldPath` runs every special arithmetic and
comparison selector and primitives 60 to 69 over a seeded table (SmallFloats
with signed zero, large and small magnitudes and random bit patterns that
encode; SmallIntegers 0, 1, -1, 2^53, 2^53 + 1, the extremes, randoms;
both orders) on two harnesses, the path on and the switch on: 35 464
answers over 1 612 pairs, 0 differ, `smallFloatAnswers` 27 315 and 0 with
the switch (`work/new-tests-debug.txt`). NaN and the infinities do not
encode as SmallFloats; a result that must box, a zero divisor and `//`
take the old path on both sides. `theSmallFloatPathAllocatesNothing`:
`floats`' step 100 000 times allocates 0 objects, enters `largeArith` 0
times, boxes 0, and all 300 000 float special sends are the path's.
`ExtremeIntegerTests`, `floatArithmeticOnTheSpecialSends`,
`FusionTests` and the LargeInteger tests pass. Neither new test can run on
8c24c05 (the switch and the counters are new); part 1's counting build is
the evidence of before.

### Item 3: not built

Under part 1's rule (above). The open question 2's case did not arise.

### Item 4: the counter

Nothing beyond part 1's counter. `weakOnlyCopiesCountsWhatOnlyAWeakSlotHeld`
runs 200 000 iterations with a 1 MiB nursery: 12 collections, 12
weak-only copies, 1.0 s in debug, 27 s under the sanitizer with twelve busy
loops (`work/tsan-new-weakonly.txt`; at 500 000 with the default nursery it
cost 90 s there).

### Item 5: the switch table

`Tests/KajoVMTests/SwitchTableTests.swift`: `switchTable` has one row per
field of the six structs, each `.test(file, function)` (the file under
`Tests/` names `.field` and holds the function), `.byHand(doc, what it
gives)` (the doc names the field) or `.option(flag, doc)` (`kajo` has the
flag). `everySwitchHasARow` reads the six structs from the source and
fails for a field with no row or a row with no field; it found this
module's own new `noSmallFloatPath` before its row existed.
`aFieldWithoutARowIsNamed` checks the check over a changed list. 76 fields,
76 rows.

The three unnamed switches: `noPendingRoots` has a test,
`withoutPendingRootsTheSemaphoresAreLostToACollection` (`ProcessTests`):
with Delays not registered, the pending table holds none, the collections
free the Semaphores and all 20 timers find theirs gone (counted stale, the
external queue's check). `youngRootsInStop` has a test,
`withYoungRootsInStopTheInitialMarkScansInItsStop` (`FinalMarkTests`):
nothing owed after the initial mark, the marker scans none, the cycle loses
nothing. Both pass on 8c24c05 (`broken/start-tests-run.txt`): they test
switches that existed. `stallRelocation` is an `.option` row
(`--stall-reloc`, run by hand in part 1). `mainWaitsForWantedStops`, which
the reviewer missed, is a `.byHand` row (run in part 1).

### Item 6: one verification level

`VerificationLevel` (`Workers/VMConfig.swift`, public): `off`, `stops`,
`all`; `build` is `all` in a checked build and `off` in a release build;
`withoutHeap` is `stops` checked and `off` release. `apply(&vc, &om)` sets
`verifyStops` (at `stops` and `all`), `ObjectMemoryConfig.verify` and
`YoungConfig.verify` (at `all`). The configurations' own defaults are
written from `build` (`verifyStops`, `ObjectMemoryConfig.verify`); the
young verifier's default stays off in every build (its own reason, a heap
walk after every collection). `verifySymbols` is not a level (off in every
build, set by the tests that intern); `onVerifyFailure` is the host's
policy, not a level.

- `Headless.Options.verify` is a `VerificationLevel?` (nil: the build's);
  `level` replaces `verifies`; `configs` applies it. `kajo run` and `kajo
  test`: `--verify` is `all`, `--no-verify` is `withoutHeap` (what a
  `--no-verify` debug run verified before: the stop verifiers, which
  `Headless` left at the checked default), `--verify-level off|stops|all`
  is new. The run line, `kajo test`'s line and the `gc` summary print the
  level's name: `verify=off|stops|all` (was `on|off`).
- `ShellVM`: a host that says nothing gets `withoutHeap` (was `false`,
  which left the stop verifiers at the build's default: the same).
- The test `Runtime` takes `verify: VerificationLevel = .all` and applies
  it; its one exception, said beside it: the young verifier stays off
  unless `configure` turns it on, as before. Call sites that passed `false`
  pass `.stops` (what `false` meant there: the fixture always set
  `verifyStops`).
- Readers of `verify=` changed in the same commit: `KernelTestParts`
  (`checkedBuild ? "stops" : "all"`), `aHeadlessRunReportsItsVerifierLevel`
  (`all`, `off`, `stops` and `all` by name), the stall tests' helper and
  `VerifierFaultsKernelTests`. No gate script and no report script reads
  the field (`scripts/` searched); `check-tier-test` is not owed.

**Deviation (starting position 7, wrong).** Three levels cannot say
"heap verifiers without the stop verifiers", which `test-release` ran
(`KernelTestParts` and the stall tests' helper in a release build:
`verify = true` set the heap verifiers, and `verifyStops` stayed at the
release default, off). With one level that gate now runs at `all`: the
stop and schedule verifiers join the heap verifiers there. Every other
gate verifies exactly what it did. The stop verifiers "cost nothing
measurable" (AGENTS.md); the gate's time is read below. A fourth level for
the old combination would keep the letter of the bar and lose the point of
one level; the owner may say otherwise (open question 5).

Tests: `eachLevelSetsEveryVerifierSwitch` (each level through `apply` and
through `Headless.configs`) and `theBuildsLevelIsTheConfigurationsDefault`
(`Tests/KajoVMTests/VerificationLevelTests.swift`);
`verifiersAreOneFlagAway` and `verifiersRunAtEveryPauseWhenEnabled` as they
are.

### Broken variants after the fix

Each run by hand from `git archive` of c46df34 plus one line, output in
`broken/`:

| variant | what it gave | gate it fails |
|---|---|---|
| `barrierWord` returns `flag + 3` by hand (the constant left at 2) | `theLayoutHashCoversTheBarrierWordsPlace`: "the constant is not barrierWord's own distance" (`after-a-tests.txt`) | every gate that runs the VM suite (`swift-test-load`, `tsan`, `tsan-load`, `test-release`) |
| `barrierWordIndex = 3` (moved through the constant) | the head's module refused at bind: `nativeRefused=its_layout_hash_is_not_this_VM's_build`, `nativeBound=0`, the run interpreted with its checksum (`after-b-stale.txt`); the variant's own module names `FLAG_BARRIER_WORD 3` under a new hash (`after-b-gen/`) | none should: the generator follows the constant |
| `ResumeOffset.pc = 4` (a mirror that disagrees) | `native-check.sh cc`: "static assertion failed due to requirement '__builtin_offsetof(KResume, pc) == 4': KResume.pc: the Swift mirror's offset", rc 1 (`after-c-native-cc.txt`) | `native-cc` (and every native gate that compiles a module) |
| a field `aSwitchWithNoRow` added to `VMTestSwitches` | `everySwitchHasARow`: "VMTestSwitches.aSwitchWithNoRow: no row" (`after-a-tests.txt`) | the suite's gates |

Starting position 1's variant fails a named gate after the fix (the bar's
item 1).

### One run of every flag, level and counter this module adds

From `work/quotes.txt` (the head's release build):

```
kajo run alloc.kasm --workers 2 (default): checksum=41959102 verifies=0 verify=off
kajo run alloc.kasm --workers 2 --verify: checksum=41959102 verifies=332 verify=all
kajo run alloc.kasm --workers 2 --no-verify: checksum=41959102 verifies=0 verify=off
kajo run alloc.kasm --workers 2 --verify-level off: checksum=41959102 verifies=0 verify=off
kajo run alloc.kasm --workers 2 --verify-level stops: checksum=41959102 verifies=0 verify=stops
kajo run alloc.kasm --workers 2 --verify-level all: checksum=41959102 verifies=332 verify=all
kajo run --verify-level on: --verify-level: off, stops or all, not on
kajo run floats.kasm: checksum=7499750000 ms=1418.2 specialSendTier=120000000 smallFloatAnswers=120000000 largeArithCalls=0 floatsBoxed=0
kajo test kernel.img (default): kajo test: verify=off verifies=0 weakOnlyCopies=0 ycPromoted=923895
kajo test kernel.img --verify-level stops: kajo test: verify=stops verifies=0 weakOnlyCopies=0 ycPromoted=923895
kajo test kernel.img --verify: kajo test: verify=all verifies=2123 weakOnlyCopies=0 ycPromoted=923895
```

The test switch `noSmallFloatPath`: `smallFloatAnswers` 27 315 with the
path and 0 with the switch on the same table (`work/new-tests-debug.txt`).
The new tests once under ThreadSanitizer with twelve busy loops: 12 of 12
passed, 0 reports (`work/tsan-new.txt`, `tsan-new-weakonly.txt`).
