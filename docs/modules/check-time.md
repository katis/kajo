# Check time and the thin waits

## Status

Brief, 2026-11-25. Not built.

The owner, 2026-11-25: "I need you to independently get the VM and the
checks to a good shape so we can do other stuff next. I trust you with
these fiddly details, keep in mind that this needs to be reliable, but we
can't spend a whole week (hyperbole) running just checks. Go ahead and
implement and fix what is needed."

The main session reads this as two modules. This is the first: the checks
themselves. The second (`docs/PLAN.md`, the VM's known faults: the Delay
timers' queue, Symbols at eight workers, `removeSelector:`'s nil source,
the type service's recheck error) is a core module and runs its gates at
the prices this module leaves.

The owner delegated the decisions of this module. Where the brief says
"decided", the main session decided under that delegation; each one is
listed at the end so the owner can reverse it.

## What it is

Two things, in this order.

1. **The gates take less time and check the same claims.** The Swift tier
   took 4449 s and the two loaded gates 5180 s more; the core tier is
   about 3.2 hours before its devices. Nearly all of it is the two
   sanitizer gates.
2. **The waits the margins table named are no longer thin.** Six of them,
   below. A wait that is past or near its bound in a passing run fails
   some later run, and each failure has cost a module.

Nothing under `Sources/KajoVM/` or `Sources/KajoAOT/` changes. This is
not a core module. `Tests/`, `scripts/`, the `justfile` and the doc
change; `tools/`, `kernel/`, `types/` and `Sources/KajoDev` may change
only where a measurement of part 1 says a product path, not a test, is
the slow or the wrong thing, and the doc says so first.

## What is known (check these before building on them)

Gate times, `~/kajo-scratch/weekly-margins/` (`check/gates.log` on
3f86421, `check-rerun/` and `check-load/` on c514abf):

| gate | s |
|---|--:|
| check-tier-test | 7 |
| clean-build | 20 |
| swift-test | 747 (741) |
| tsan | 3146 (3234) |
| kernel-test | 126 |
| apps | 131 |
| new-check | 272 |
| swift-test-load | 825 |
| tsan-load | 4355 |

Inside the sanitizer gate (`check-rerun/tsan.txt`): the two test bundles
run one after the other. `KajoVMTests` (485 tests) passed after 979 s and
`KajoCompilerTests` (199 tests) after 2240 s; under load 1520 s and
2817 s. In the second bundle
`theKernelsTestsPassAndTheEventsAreTheProtocol` reads 2196 s (2817 s
loaded), nearly the bundle's whole length, and
`theDiagnosticsRequestAnswersItsScopesAndTheEventFollowsAChange` 1048 s
(its own margin line: 999 s of a 3600 s bound). Swift Testing's reported
durations include the wait for a thread of the cooperative pool (AGENTS.md:
"A test's reported duration is not its body's"), so 489 tests read over
300 s; only a body's own time says where the time is. In the plain gate
the first bundle is 650 s and the second 86 s; the random programs
(`randomProgramsAgreeWithTheirModel`, `...Natively`,
`...ResumeFromASnapshot`, `...ResumeAcrossEngines`) read 588 to 650 s.

The kernel's tests run as two parts in parallel VMs
(`KernelTestParts`, `KAJO_KERNEL_TEST_PARTS`). The number was set by
failures counted at five, three and two parts (decision 34); what limited
it was the process's global queue, on which the VM's Delay timers still
run. The host's own timers left that queue in the third review's small
fixes, part 1.

The margins table's first real run
(`~/kajo-scratch/weekly-margins/work/real-margins.md`, 225 margins):

| margin | gate | value / bound |
|---|---|--:|
| `tools.roundtrip.class.hierarchy` | tsan-load | 36 891 / 30 000 ms |
| the same | tsan | 28 886 / 30 000 ms |
| `hostTimer.queueSpins` | tsan, tsan-load | 120 / 120 s |
| `tools.roundtrip.class.hierarchy` (retried) | tsan-load | 28 968 / 30 000 ms |
| `tools.roundtrip.process.frames` | tsan-load | 24 695 / 30 000 ms |
| `reserve.promotionPastTheReserve.offload.0` | swift-test-load | 85.1 / 120 s |
| `main.turnOverrunCpu` | swift-test-load | 0.124 / 0.2 ms |

Failures counted and not explained (decisions 54 and 55):
`ProjectDirectoryTests.theToolsChooseThroughTheHostAndTheirChangesLandThere`
1 of 6 loaded sanitizer runs, a `class.hierarchy` with no reply in 30 s;
`MainThreadTests.aTurnOverrunsItsBudgetByAtMostAFifthOfAMillisecond` 1 of
15 loaded runs; the tag test's weekly failure, 0 of 6.

## Starting positions (candidates; say where one was wrong)

1. The sanitizer gate's time is the kernel's tests in a debug sanitizer
   build, run as two parts. More parts, or the parts as separate
   processes, would cut it most.
2. A `class.hierarchy` reply is slow because the image builds the whole
   hierarchy per request, and the 36.9 s row is one request that was sent
   again after its timeout, counted from its first send.
3. The host-timer test waits for a condition that the sanitizer build
   never makes true, and the test's claim does not need the wait.
4. `ReserveTests` runs at a size its claim does not need.
5. The turn-overrun test asserts a CPU bound with no sanitizer or load
   value where one is owed.
6. Several long VM tests run every seed or size in every tier though the
   claim is one edge.

## Parts

### Part 1: where the time is (builds nothing else)

Write the rules first, in a file with its time, committed or copied
before any number is read:

- what counts as "the same claim" when a test is made smaller or moved
  (the assertion is unchanged; the broken variant, where one exists,
  still fails at the new size, run and kept);
- what moves a test to the weekly run only (below);
- the targets (the bar).

Then measure, one thing at a time on a quiet machine:

- each test's body time in `swift-test` and `tsan`: the top fifty of each
  bundle and the sum. Use what exists (`kajo-margin kind=time` lines, the
  bodies the stall tests print); where a long test prints nothing, an
  instrumented copy in the scratch directory, not a commit;
- the build's share of each gate (the first line of test output against
  the gate's start);
- for the kernel's tests under the sanitizer: time per part, time per
  test class, and what limits the part count today. Count failures at
  two, three, four and six parts under a rule written first, as decision
  34 did, and name the limit;
- for each of the six thin waits: what the wait waits for, who makes the
  condition true, and the value in five loaded sanitizer runs of the
  smallest set of suites that has the suite's load.

Commit part 1 (the doc's tables, the rules) before part 2.

### Part 2: the gates' time

From part 1's table, largest first. The levers, each priced before it is
chosen:

- **Size by tier.** A test whose claim holds at a smaller size runs that
  size in the tiers and its full size in the weekly run, through one
  switch (`KAJO_TEST_SIZE=full`, set by `weekly.sh`; the name is yours).
  The switch has a table test: a test that reads it is listed, with the
  claim and both sizes, and a test that reads it and is not listed fails.
- **Parallel bundles and parts.** The two bundles one after another, and
  the kernel's tests in two parts, are choices. Measure the others.
- **The build.** If the sanitizer build is a large share, say what a
  second scratch path or a kept build would save and what it would risk
  (AGENTS.md: "A gate that finishes ten times faster than it used to has
  changed").
- **Sleeps.** A wait that always runs out (`hostTimer.queueSpins`) is 120 s
  of each sanitizer gate.

Decided, to build:

- Each tier runs one sanitizer gate, the loaded one (`tsan-load`), and
  one plain test gate. The Swift tier's plain gate stays `swift-test`;
  the core tier's stays `swift-test-load`. The weekly run keeps all four.
  Before building it, read every recorded gate failure of `tsan` and
  `tsan-load` in `docs/decisions/` and `~/kajo-weekly/*/gates.log` and
  count which gate found each; if `tsan` alone found a fault that
  `tsan-load` did not, stop and say so in place of building it.
- Nothing leaves the weekly run. The weekly run is where the full sizes,
  both sanitizer gates and every seed run.

### Part 3: the thin waits

Each one measured in part 1, then fixed at its cause. In the order of
their fraction:

1. `class.hierarchy` past the client's 30 s timeout in a passing run:
   first what `tools.roundtrip.class.hierarchy` measures and how the
   request passed. Then the cause: if the reply is slow, make the reply
   cheaper (the hierarchy built once per change, not per request, or the
   test asking a narrower question); the timeout does not grow.
   `process.frames` at 0.82 and the `ProjectDirectoryTests` failure are
   read against the same finding.
2. The host-timer test's 120 s wait: what it waits for, then a wait that
   ends when its condition is true or a test that does not need it.
3. `ReserveTests` at 0.59 to 0.72 of 120 s in plain builds.
4. The turn-overrun test at 0.62 of its CPU bound under load, failed 1 of
   15: the lesson on CPU bounds under the sanitizer and load applies.
5. The tag test's unexplained weekly failure: with the faster suite,
   count again in the loaded sanitizer gate (the rule and the count
   written first); a fix only for a cause that was seen.
6. Any margin THIN or PAST in the after table that was not there before.

No wait is lengthened and no assertion weakened. A wait that changes is
quiet-bounded on named activity, or ends on its condition.

### Part 4: the weekly run

- `weekly.sh` sets the full size and runs all four test gates; its
  `summary.md` says which size each gate ran at.
- A runner for the by-hand broken variants (the owner, 2026-11-23,
  approved): the variants the docs list as "by hand" that can run without
  a trap taking the machine's attention each run once in the weekly run,
  each expected to fail with its recorded message; a variant that passes
  is the failure. List the variants first (from `AGENTS.md`'s structure
  notes and `docs/modules/`); the ones that cannot be automated are named
  with the reason.

## Tests

- The size switch's table test, and one test of the switch at each size.
- `check-tier-test.sh` covers every changed tier list, the weekly's gate
  list and the runner's reading of a variant's output; its fixtures say
  what a tier ran before and after.
- Each test made smaller: its broken variant (where one exists) run at the
  new size, the failing output kept in `broken/`.
- Each thin wait: the forcing condition before and after, as the tools
  test's fault did, where one can be built; where none can, the count
  before and after under a rule written first, and the record says
  "reading".

## The bar

1. Written before the numbers: the rules of part 1.
2. The Swift tier in at most 30 minutes and the core tier's Mac gates
   (everything before the device rows) in at most 75 minutes, both from
   an empty scratch path, on this machine. If a target cannot be met
   without dropping a claim, the claim stays, the number is said and the
   next lever is named.
3. Every claim a tier checked before, it checks after, or the table says
   where it went (the weekly run) and why. The count of tests per gate
   before and after, by name: a test gone from a list is an error unless
   the table has it.
4. The after margins table of the tier's gates and of one full-size
   weekly-shaped run of the four test gates: no PAST, and each THIN named
   with its cause and what it waits for.
5. The loaded sanitizer gate five times on the final commit, `rc=0` five
   times, 0 sanitizer reports. A failure is counted and investigated,
   not run again until it passes.
6. `just check` on the final code commit, `failed=0`, and the tier's
   time beside 4449 s.
7. `scripts/weekly.sh --gates` and a quick scratch run of it
   (`KAJO_WEEKLY_ROOT` in the scratch directory, no device, nothing under
   `~/kajo-weekly/`) with the by-hand runner's section in its summary.

## Rules of the house that bind here

From `AGENTS.md`: a gate that finishes ten times faster has changed; a
test checks its claim, not everything after it; a slowdown proportional
to CPU cannot sit under a wall-clock bound; a wait for a reply is
quiet-bounded with its activity named; a wait that runs out in every
passing run is a sleep; tests run side by side share the process's
queues; a failure seen only in the full suite is reproduced with the
suite's load; a natural count after a fix is not the fix's evidence when
the count before could be 0; a fix for a failure that was not reproduced
is recorded as a reading; a changed gate script is run once on its own; a
module's tests are a cost in every later gate run; a brief's premise is
measured before it is built.

## Not in this module

- Any change under `Sources/KajoVM/` or `Sources/KajoAOT/`. If part 1
  finds that the VM's Delay timers on the global queue limit the part
  count, that is the next module's; say what it would buy.
- The device rows and the matrices.
- New tests of the product beyond what a fix here needs.
- The fuzz gate's seconds.

## Deliverables

- The doc's "As built": part 1's tables, each lever with its price and
  whether it was taken, the tests-per-gate table, the before and after
  gate times and margins, the weekly's gate list.
- The scratch directory `~/kajo-scratch/check-time/` with every raw
  output.
- The hand-back map of `docs/PROCESS.md`.

## Decided under the owner's delegation (reversible)

1. A tier runs one sanitizer gate, the loaded one; the weekly run runs
   both.
2. A test may run at a claim size in the tiers and its full size weekly.
3. The targets: 30 minutes for the Swift tier, 75 for the core tier's Mac
   gates.
4. A request timeout or a test's bound does not grow to make a margin
   wider.

## Open questions

Build the recommended option; decisions only.

1. Whether the Swift tier's plain gate should be the loaded one as well.
   Recommended: no; one loaded gate per tier.
2. Whether a THIN margin in a tier's own table should fail `just check`
   once this module leaves none. Recommended: not yet; read two weekly
   runs first.

## As built

Built 2026-11-25 to 27 by one build agent from this brief. Work
files in `~/kajo-scratch/check-time/` (written `$CT/` below). The
toolchain first on PATH: swiftly's swift.org 6.4.2 (`swift`, `clang` from
`~/.swiftly/bin`), Homebrew's `python3`; `$CT/work/env.txt`.

### Part 1: where the time is (2026-11-25 to 26)

**The rules** (`$CT/part1/rules.txt`, written 15:51 on 2026-11-25 and
copied with its time to `rules.copy.txt` before any run of this module;
one amendment at 15:56, before the run it touches, copied as
`rules.copy2.txt`). In short: (1) a test made smaller keeps its
assertions, still reaches the edge it asserts and still fails its broken
variant; a claim over every X is made smaller in a tier only where another
gate of the tier runs all of X, and under that rule a sanitizer gate may
leave a test to the weekly run when the tier's plain gate runs it whole;
(2) a test leaves a tier's gate only into the tests-per-gate table and the
weekly run, never out of the weekly run; (3) the targets of the bar, from
an empty scratch path; (4) the part count by decision 34's method, five
runs at two parts and three at three, four and six, every planned run run;
(5) the thin waits from those five runs and five runs of the plain VM
bundle under twelve loops; (6) body times from an instrumented copy.

**How it was measured.** `$CT/part1/instrument.py` makes a copy of 4f9c364
(`git archive`) whose every `@Test` body prints one `kajo-body` line when it
ends (684 bodies; no other change but the amendment's diagnostic print in
the turn-overrun test). `measure.sh` ran, one after another on the quiet
machine: one plain `swift test` and one `swift test --sanitize=thread`, each
from an empty scratch path; five runs of the VM bundle in a plain build
under twelve loops; and the compiler bundle under the sanitizer and twelve
loops five times at two parts and three times each at three, four and six
(`runs/`, `measure.log`; 23 runs, 15:53 on 2026-11-25 to 04:42 on 2026-11-26). `bodies.py`,
`groups.py` and `kclasses.py` make the tables; `runs/cpu.log` samples the
machine's CPU every 30 s.

**Where the time is: the plain gate** (`q-plain-bodies.md`): 781 s, of
which the build from an empty scratch path 26.6 s (3 percent). The VM
bundle 654.8 s (485 tests, 829 bodies summing to 7811 s), the compiler
bundle 98.1 s. The random programs are 5242 of the 7811 body seconds
(natively 1937, resumed across engines 1315, against the model 1155, from a
snapshot 835), every native seed compiled cold (an empty scratch path has
no native cache). The stall tests are 772. Under twelve busy loops the same
bundle took 705 to 725 s (five runs, `vm-load-*`): **the plain VM bundle
waits on its pool of test threads (one per core), not on the cores**, and
the random programs, started last, end it (the snapshot test under
`stopEveryPoll`, 404 s, started at 251 s). `aFailureStopsTheVMUnderTrap`
reads 545 s; it is an exit test whose `await` resumes only when a pool
thread is free, not work.

| rank | body s | test (plain, quiet) |
|--:|--:|---|
| 1 | 545.1 | VerifierTests.aFailureStopsTheVMUnderTrap (exit test: pool wait) |
| 2 | 403.6 | randomProgramsResumeFromASnapshot(stopEveryPoll) |
| 3 | 328.7 | randomProgramsResumeAcrossEngines(stopEveryPoll,true) |
| 4 | 326.3 | randomProgramsResumeAcrossEngines(stopEveryPoll,false) |
| 5 | 290.6 | randomProgramsResumeFromASnapshot(collectEveryAllocation) |
| 6 | 271.4 | randomProgramsAgreeWithTheirModel(stopEveryPoll) |
| 7 | 245.2 | randomProgramsAgreeWithTheirModel(collectEveryAllocation) |
| 8 | 234.5 | aFullHeapFallsBackJustifiedThenRunsOutOfMemory |
| 9 | 221.5 | randomProgramsAgreeWithTheirModelNatively(collectEveryAllocation) |
| 10 | 174.4 | randomProgramsResumeAcrossEngines(collectEveryAllocation,false) |

The top fifty per bundle and their sums are in `q-plain-bodies.md`.

**Where the time is: the sanitizer gate** (`q-tsan-bodies.md`): 3404 s,
of which the build 33.0 s (1 percent). The VM bundle 1185.9 s (sum of
bodies 13 305 s; the machine at 85 percent user, 10 system, 5 idle over it:
**CPU-bound**), then the compiler bundle 2173.5 s (sum 11 998 s; 44 percent
user and 49 idle over it, 17 idle in its first 860 s and 70 idle after).
The compiler bundle is the kernel's two parts (1949 and 2111 s, their test
bodies 1960 and 2117 s, ending the bundle) with the rest of the bundle done
by 1706 s, where the serialized `TypeCheckerTests` suite ends
(`theTypesPackageBuildsAndItsTestsPass` 494 s, then
`theDiagnosticsRequestAnswersItsScopesAndTheEventFollowsAChange` 1047 s).
In the VM bundle: the stall tests 3990 body seconds (30 percent; the full
heap 784, the entry-stall gate 572, the slowed marker four times about 320),
then concurrent marking 953, the relocation kernels 861, the kernel tests
under a collection at every allocation 828, the verifier faults 600, the
extreme integers 554, the native random programs 539.

The kernel's SUnit tests under the sanitizer, quiet (`q-tsan-kernel.md`;
264 tests, 4058 s):

| class | s | | test | s |
|---|--:|---|---|--:|
| CompilerTest | 1733.3 | | CompilerTest>>testALongChainIsWalkedByALoop | 879.1 |
| LiveCompileTest | 876.1 | | LiveCompileTest>>testEveryMethodMakesAsInstalled | 873.3 |
| LargeObjectTest | 389.5 | | CompilerTest>>testEveryMethodCompilesAsTheBootstrapDid | 847.0 |
| ClassFuzzTest | 331.7 | | ClassFuzzTest>>testSeededSpecificationsAreRefusedOrAccepted | 280.4 |
| TypeSyntaxTest | 254.0 | | TypeSyntaxTest>>testTypesCompileToNothing | 247.3 |
| TonelTest | 210.1 | | TonelTest>>testTheReaderReadsWhatTheWriterWrote | 182.3 |
| DevelopmentTest | 102.3 | | LargeObjectTest>>testStringsPastTheCountField | 127.4 |

Three tests are 2600 of the 4058 s, each one Smalltalk test that no split
divides; `TypeSyntaxTest>>testTypesCompileToNothing` (247 s) is missing
from `KernelTestParts.measuredSeconds` and was weighed as 0.32 s.

**The part count** (rule 4; `count-parts.md`): the compiler bundle under
the sanitizer and twelve loops.

| parts | runs | failed | bundle s | longest kernel part s | `TypeCheckerTests` chain s |
|--:|--:|--:|--:|--:|--:|
| 2 | 5 | 0 | 2836 to 2926 | 2713 to 2739 | 2300 |
| 3 | 3 | 0 | 2551 to 2577 | 2317 | 2393 |
| 4 | 3 | 0 | 2589 to 2663 | 1912 | 2561 |
| 6 | 3 | 0 | 2698 to 2710 | 1809 (one test) | 2632 |

No count failed: the reconnect test passed in all 14 runs, its quiet stretch
28.4 to 35.1 s of 60. Decision 34's limit (five kernel VMs starving the
host's timers on the global queue) is gone with the host's timers since the
third review's small fixes, part 1. **What limits the count now is the CPU
and one serial chain, not a failure**: under load each kernel test alone
takes twice its quiet time (the long chain 1809 s at six parts against 879
quiet), so more parts make each part slower, and from four parts on the
bundle ends with the serialized `TypeCheckerTests` suite (the types
package's tests 780 to 907 s, then the diagnostics test 1355 to 1536 s).
Three runs with 0 failures are a reading, not a rate (rule 4c). The Delay
timers on the global queue (the next module's) were not seen to limit
anything here.

**The build's share**: 26.6 s of the plain gate, 33.0 s of the sanitizer
gate, from empty scratch paths; under 4 percent of either.

**The six thin waits** (rule 5: the five two-part runs above for the
compiler bundle's, the five plain VM-bundle runs under twelve loops for
the VM bundle's; each value from its `kajo-margin` line, `thin.py`):

| wait | what it waits for | who makes it true | five loaded values | bound |
|---|---|---|---|--:|
| `tools.roundtrip.class.hierarchy` | the browser's first request's reply, from the send to its dispatch in the tools' event loop | the image's protocol Process computes it on a background worker; the test's thread turns the main worker that dispatches it | 35.4, 37.2, 37.0, 36.8, 41.7 s (sanitizer); 35 to 42 in all 14 runs | 30 s |
| the same, `(retried)` | the same request sent again after the reconnect test's dropped link, counted from its first send | as above, after the outage | 25.9, 29.5, 28.2, 29.7, 32.3 s | 30 s |
| `tools.roundtrip.process.frames` | the debugger's frames reply | the protocol Process | 21.0, 23.7, 23.6, 21.4, 23.0 s | 30 s |
| `hostTimer.queueSpins` | one of the test's own spinner blocks to start on the global queue | GCD, when it starts a thread for the queue | 120.0 s in every run but one (0.017 s at four parts) | 120 s |
| `reserve.promotionPastTheReserve.*` | the four rings to end | the four background workers, a fixed amount of work | 101.8, 98.7, 106.5, 96.3, 93.7 s (largest of the four cases, plain, twelve loops; 76.5 to 78.5 quiet) | 120 s |
| `main.turnOverrunCpu` | (a ceiling) the largest CPU overrun of 300 turns | the main worker's deadline check, every 1024 polls | 0.075, 0.073, 0.082, 0.049, 0.078 ms | 0.2 ms |

The tag test's `ready` in the same runs: 8.7 to 10.5 s quiet of 60, 25.1
to 26.1 s in all of 300. The turn-overrun diagnostic (rule 6d): in every
run the three largest overruns were turns with one slice, preempted at the
deadline, no stop, no park, CPU time equal to wall (1.03 to 1.08 ms of a
1 ms budget): the overrun is the time from the deadline to the next deadline
check. The failing run of decision 54 (0.38 ms) was not seen again.

**Which sanitizer gate found each failure** (the brief's condition for
"one sanitizer gate a tier"): every `end tsan` or `end tsan-load` line with
a non-zero status in `~/kajo-weekly/*/gates.log` and every module's
`gates.log` under `~/kajo-scratch/`, each failing test read from the gate's
own output (`$CT/part1/notes.md`): 19 failing gate runs, 0 sanitizer
reports in every one. One was a product fault, decision 53's (a method seen
before its source), and both gates found it (`tsan` on 2c13ed3, where
`tsan-load` passed; `tsan-load` 2 of 2 on aeecb55). Every other failure
was a test's own fault (a timer or a wait on a clock, an edge not reached,
a thin race test). Three of those were seen under `tsan` and never under
`tsan-load`: the ring stall's edge not reached (b478aaf, fixed in decision
36), the random programs' scavenge check under `exhaustedReserve` (aeecb55,
thin on its starting commit too, decision 52) and the interning race test
(30e14bd, which plain `swift-test` failed too, decision 39). **No fault of
the product was found by `tsan` alone.** The decision is built.

### Part 3: the thin waits (2026-11-26)

**A product path, said first.** `session.open`'s answer counted the
protocol's requests with `DevProtocol describe size`: it made the whole
description (every request's arguments and comment) to answer one number.
Timed in the image (`$CT/work/rt/serves-*.txt`, the instrumented copy's
`ToolsProbe class>>timeOpen`): a fresh image's first `info` 4117 ms under
the sanitizer and 142 ms plain, later ones 534 and 18; with the count taken
from the kinds table, 87 ms (sanitizer). `DevProtocol class>>requestCount`
(`kernel/Development/DevProtocol.class.st`) answers it; `DevSession>>info`
uses it. This is the one change under `kernel/`; the files are canonical
(`scripts/canonical-tonel.sh --check`, `$CT/work/canonical-1.txt`).

**1. `class.hierarchy`.** What `tools.roundtrip.<kind>` measures (read in
`DevClient>>receive:`): from the request's send to the reply's dispatch in
the tools' event loop, which runs on the main worker the test's thread
turns. How a 36.9 s round trip passed a 30 s timeout: the timeout is a timer
event of the same loop, and the reply's line event reached the image's
queue first; the loop dispatched the line, cancelled the timer, and the
dispatch came late. Measured with a copy whose `LocalTools` prints when
each request reaches the server, when the image delivers its reply and
when the client host hands the reply's line to the image
(`$CT/scripts/rt.py`, `$CT/work/rt/run1.txt`: the compiler bundle under the
sanitizer and twelve loops, 2-part kernel tests, starting commit). In
`theToolsDevelopTheImageTheyRunIn`: the browser sends `session.open`, then
`package.list` and `class.hierarchy` at once; the session's reply came after
8.95 s, the package list's 1.6 s later, the hierarchy's 6.0 s after that
(16.0 s from its send), its line reached the image 15 ms later, and the
client dispatched it 8.2 s after that (24.2 s). Over the five tools tests
the hierarchy's reply reached the image after 15.5 to 25.2 s and was
dispatched after 23.8 to 39.3 s. Alone and quiet under the sanitizer
(`ToolsProbe class>>timeServes`): the hierarchy's work 1.15 s and its JSON
2.3 s more, the package list 0.31 s; the session's answer 4.1 s, nearly all
the description it did not need. So the reply was slow first because the
session's answer before it was, and the round trip ran past the timeout
because the dispatch waited for the tools' main worker, not because a reply
came late.
- The fix: the session's answer above, the reply's own work unchanged
  (3.5 s quiet under the sanitizer, under 0.12 s plain; building the
  hierarchy once per change would save its 1.15 s and not its JSON).
- The margin: `LocalTools` now prints `tools.reply.<kind>`, when the reply
  reached the image against the client's timeout (`ReplyArrivals` in
  `Tests/KajoCompilerTests/ToolsTests.swift`), beside the round trips. No
  timeout changed.
- `process.frames` (21 to 25 s round trips, 0.70 to 0.84): the same
  measurement, read in the final runs below.
- The `ProjectDirectoryTests` failure of decision 54 (a `class.hierarchy`
  with no reply in 30 s): the same request in the same position (the first
  hierarchy after `session.open`); its test was the slowest of the five here
  (25.2 s to the image, 39.3 s to the dispatch).

**2. The host-timer test.** The wait was for one of the test's own spinner
blocks to start on the global queue, before queuing the canary behind them.
GCD made the condition true; in the suite it started no thread for the
default global queue for 45 s in a plain bundle and past 120 s under the
sanitizer in 13 of 14 runs (`spinning=0 of 48` at the end in the five
two-part runs). A sample of the process 9.3 s into the wait (plain,
`$CT/work/gcd/sample-44146.txt`) shows 71 threads and none of that queue:
the cooperative pool's 12, the VM workers, overcommit queues. A small
program (`$CT/work/gcd/gcd.swift`) with 12 cooperative tasks or 12 threads
spinning started a global-queue block in 2 to 6 ms, so the pool alone does
not explain it; why GCD starts none in the suite is not established. The
test's claim does not need it: the canary queued behind 48 spinners and not
run is the evidence that the queue is full, and the test passed on that
alone in every one of those runs. The wait is removed (and its margin line,
`hostTimer.queueSpins`, with it). Its broken variant at the new shape (the
host's timers back on the global queue, `$CT/broken/hosttimer/variant.diff`)
fails: "the timer did not fire while the global queue was full", fired at
20 001 ms (`broken/hosttimer/run.txt`). Plain alone the test now takes
0.47 s.

**3. `ReserveTests`.** The wait was for four rings of a fixed length to
end, under a 120 s clock on the whole wait: a clock on CPU-proportional
work. The four background workers make it true. The wait now ends when the
rings end and fails only when the collector counts nothing (no stop, no
young collection) for 120 s, 600 under the sanitizer: `StallDiag.waitProgress`,
the stall tests' rule; the rings, the heap and every assertion are as they
were. Its margin is now `stall.reserve.<mode>.<reserve>.terminated` (quiet).
Forced (`$CT/scripts/ecore-load.sh`: the test held on the efficiency cores
with eight busy loops there too, `$CT/work/reserve/`): before, all four
cases ran out at 120.0 s and failed ("Processes still live", wrong sums);
after, all four passed in 139 to 193 s with the longest quiet stretch 4.2 s.
Plain and alone the new wait's quiet stretches are 0.26 to 0.62 s.

**4. The turn-overrun test.** It asserts that the largest CPU overrun of 300
turns is at most 0.2 ms. The starting position was that the bound needs a
load value; it was not changed (decided: no bound grows). What was seen:
on the efficiency cores (`taskpolicy -b`, three runs) the overrun is smaller
(0.033 to 0.053 ms), so the core type is not it. Alone under twelve loops,
100 runs (`$CT/work/turn/loop.txt`): 99 passed (median of the maxima 0.072
ms), one failed at 0.219 ms. Its largest turn: one slice, preempted at the
deadline, no stop, no park, CPU equal to wall (1.237 ms), and one young
round acknowledged in the turn (17 µs of young time, subtracted). Over the
300 largest turns of those runs, turns with an acknowledgement passed 0.1
ms in 8 of 66, turns without in 7 of 234 (largest 0.151). A reading: a turn
in which the main worker acknowledges a young round can run past its
deadline check by more than its reported young time. That is the VM's (a
core module's): found, not fixed. The test now prints every field of its
three largest turns, in its failure message too, so the next failure names
its case.

**6. Waits the new layout made thin.** The tier's first run on 292b202
(`$CT/292b202-check/gates.log`, `check-tier done swift failed=1 3087s`)
failed `tsan-load` on `theToolsReconnectAfterADroppedLink`:
"remoteDebuggerReady never held (quiet, activity -1): waited 60.0 s", and
its table had two marks that part 1's had not: that wait at 60.0 of 60
(PAST; 22 to 31 s in part 1's 14 runs, 40.7 in the candidate run) and
`process.gcKeepsParkedProcessStacksAlive` at 105 of 120 s (THIN; 66 before).
Both are the suite's shards running side by side: the compiler tests no
longer have the machine to themselves after the VM tests. Not run again
until it passed; investigated:
- `remoteDebuggerReady`: the test drives only a remote client, and
  `ToolsProbe class>>activity` counted the local one, so the wait's quiet
  clause saw -1 throughout: a 60 s clock on the remote target's work. Now
  `activity` counts every client in the image. Forced (the test alone under
  the sanitizer, held on the efficiency cores with eight loops there,
  `$CT/work/reconnect/`): before, the tier's line exactly ("quiet, activity
  -1", 60.9 s); after, the wait sees the remote client (activity 3000) and
  still fails, and its new companion probe (`remoteDebuggerReadyWhy`) says
  why: "debuggers 1 lastIsRemote true state #stopped frames 0 remote true open
  true pending 0 replies 3", the remote's `class.hierarchy` reply after 70 s.
  The debugger opened and its frames request is gone without a reply: under
  that forcing the remote's `process.frames` ran past the client's 30 s
  timeout. A by-hand try that counted the remote VM's counters as activity
  was backed out: they change for as long as a request pends there (the
  request reaper's Delay), so the quiet clause became the 300 s ceiling. So
  this wait's thinness is the remote's replies under load, the same shape
  as item 1. The second tier run on 749fc70 (`$CT/749fc70-check/`, 3119 s)
  failed the same way naturally, with the clauses: "debuggers 1 lastIsRemote
  true state #stopped frames 0 ... pending 0 replies 3". The protocol tests'
  own `process.frames` waits say what a frames reply costs: 12 s quiet under
  the sanitizer and 0.4 s plain, 15 to 22 s in part 1's loaded runs and 28
  to 36 s in these two (`protocol.process.frames.*`): the first frames reply
  of a stop compiles every frame's method again to find its variables
  (`DebugStop>>variablesOf:`, `Compiler class>>frameVariablesOf:`), and with
  the VM tests beside it that passes the tools' 30 s request timeout. The
  timeout does not grow, and making the frames reply cheaper is a change to
  how a frame's variables are found (the next lever, an open question). Built
  instead: the tools' three suites (`ToolsTests`, `PhoneTransportTests`,
  `ProjectDirectoryTests`) run after the other shards, alone, as a second
  phase of `scripts/test-bundles.sh` (0ae993f), the load they passed under
  in part 1. The tier on 0ae993f passed (`$CT/0ae993f-check/gates.log`,
  `check-tier done swift failed=0 3634s`, no THIN or PAST), and the five
  loaded runs on it (`$CT/0ae993f-check-load-{1..5}/`) passed 5 of 5 (2478 to
  2565 s, 0 reports) with two marks new: the protocol tests' frames waits
  (`DebuggerProtocolTests`, `DevelopmentAnswersTests`) at 33 to 49 s of 60
  (0.82 once; 21 to 22 s in part 1), the same frames reply; and
  `verifierFaults.keptAcrossRun.*` at 0.80 to 0.85 of a 600 s clock on four
  rings of fixed length. So the frames tests joined the second phase, and
  `keptAcrossRun` waits on the collector's progress (quiet 600 s, as item 3;
  its broken variant's test, `withoutTheRescanTheVerifierNamesAMovedBody`,
  still passes by seeing the failures).

**5. The tag test.** The tier on a880ce0 (`$CT/a880ce0-check/`, stopped
after it: `tsan-load` `rc=1` at 2755 s, the other gates `rc=0`) failed
`aClassDefinedIntoATagFromTheBrowserMovesWithItsTag` at its last step:
"tagProbeRemoved never held (quiet, activity 15000): waited 141.9 s ... status
'ClassDefinitionError: another Process holds ToolsTagProbe on its stack: try
again when it has let go'", its round trips holding two `class.hierarchy`
of 35.9 and 49.9 s. The VM refused the removal because a Process had the
class on its stack (`Sources/KajoVM/ObjectModel/LiveClasses.swift`), and
the line names no Process. Two Processes in that image hold classes on
their stacks for long: a `class.hierarchy` request while it lists the
classes, and the type service's checks, which the browser's first class
selection starts (the whole image, then each change). A fix that waited for
the browser's pending requests was built and measured, then backed out: it
waited 39 s in a plain run behind the type checker's first whole-image
diagnostics request (`$CT/work/tag/after-forced-*.txt`), and its forcing
condition (a refresh asked just before the removal) did not fail without it
in three plain runs (`$CT/broken/tag-unsettled/`), so neither its cause nor
its evidence was seen. Built (1a68580): the failure line now says what may
hold the class (`tagProbeRemovedWhy`: the requests the image is running,
the type service's state and passes). The count under the rule written
first (`$CT/work/rule-tag.txt`): the five loaded runs below. A reading: the
weekly run's failure of 2026-11-23 was at another step (`definedInTag:`).
This is a different failure of the same test, and with the type service
holding a changed class while it rechecks it, the tools' own removal can be
refused in a real session too; found, not fixed.

1a68580 is the final code commit and every run below is on it.
- `gcKeepsParkedProcessStacksAlive` waited for two churners of fixed length
  under a 120 s clock on the whole wait; it now waits on the collector's
  progress (`StallDiag.waitProgress`, quiet 120 s), as item 3.
- `tools.roundtrip.<kind>` is printed as a time (no bound): it runs to the
  dispatch, which the timeout does not race (item 1). `tools.reply.<kind>`
  is the ceiling against the timeout.


### Part 4: the weekly run (2026-11-26)

- `scripts/weekly.sh` exports `KAJO_TEST_SIZE=full` for every gate and
  keeps all four test gates (`swift-test`, `swift-test-load`, `tsan`,
  `tsan-load`). Its `summary.md` has a `## Test sizes` section: the
  variable, and per gate the `kajo-test-size size=... sized=...` line its
  suite printed (`TestSizeTests` prints it in every run). A tier leaves the
  variable unset; `check-tier-test.sh` checks that only the weekly sets it.
- `scripts/broken-variants.sh <out> [name...]`, the gate `broken-variants`
  (weekly only, after `ab`): the by-hand variants that need no source change,
  each once as its doc says to run it, each judged against its recorded end:

  | name | how it runs | expected |
  |---|---|---|
  | delay-end | `KAJO_BROKEN_DELAY_END=1`, `brokenVariantALateTimerTouchesTheFreedVM` | fails: "exited with unexpected signal code 11" |
  | shell-close | `KAJO_BROKEN_SHELL_CLOSE=1`, `aShellClosedWithADelayPendingFreesItsVM` | fails: "close left the VM undestroyed" |
  | closed-shell-runTurn, -spawn, -liveProcessCount | `KAJO_CLOSED_SHELL_CALL=<call>`, `aCallAfterCloseByHand` | fails: "Fatal error: ShellVM.<call> after close" (the fix's trap) |
  | tools-hold-install | `KAJO_TOOLS_HOLD_INSTALL=1500`, `theToolsDevelopTheImageTheyRunIn` | passes (the forcing condition the fix bears) |
  | tools-hold-loop | `KAJO_TOOLS_HOLD_LOOP=70000`, `aClassDefinedIntoATagFromTheBrowserMovesWithItsTag` | passes (likewise) |

  A variant expected to fail that passes, or fails without its message, is
  the runner's failure; so is a forcing condition that fails. `--list`
  names them, `--judge` judges one output (what `check-tier-test.sh`
  tests with six cases). `summary.md` has a `## By-hand broken variants`
  section with the runner's lines.
- **Not automated, and why.** Every other variant in the "Broken variants
  run by hand" sections of `allocation-stalls.md`, `aot.md`,
  `app-project.md`, `collectors-review.md`, `developer-ui.md`,
  `development-answers.md`, `development-protocol.md`, `final-mark.md`
  (`mainWaitsForWantedStops`, whose wait is shortened in the source for
  the run), `image-processes.md`, `kernel-image.md`, `kernel-live.md`,
  `large-bytes.md`, `large-objects.md`, `live-classes.md`,
  `object-model.md`, `phone-transport.md`, `reserve-and-depth.md`,
  `review-3-small-fixes-part-2.md`, `types-1.md`, `types-2.md`,
  `types-3.md`, `verifier-faults.md` and `vm-teardown.md` is a change to the
  source: a line removed, two calls reordered, a check skipped, a wait
  shortened. Broken variants are never committed, so a runner has nothing to
  apply; they stay by hand, as recorded. The broken variants that are test
  switches already run in every suite (`SwitchTableTests` lists them).

### Part 2: the gates' time (2026-11-26)

Each lever priced from part 1 before it was taken, then measured together
(`$CT/work/cand1/gates.log`, the working tree on 3429c70 with the levers
built and the types package not yet moved: `tsan-load` 2022 s against
4355, `swift-test` 287 s against 747, 0 sanitizer reports, every test
passed):

| lever | price (part 1) | taken |
|---|---|---|
| the suite as shards side by side (`scripts/test-bundles.sh`: one build; the VM tests but the random programs, the random programs but the resumed ones, the resumed ones, the compiler tests, each a `swift test --skip-build --ignore-lock` of its own) | the plain VM bundle waits on its pool (655 s quiet, 705 to 725 s loaded); under the sanitizer the bundles ran one after the other (1186 + 2174 s quiet) with the second at 49 percent idle | yes, in all four test gates: `swift-test` 287 s (747), the shards 241, 283, 267 and 243 s; later (part 3, item 6) the tools' suites and the frames tests became a second phase, alone: `tsan-load` 2529 to 2614 s on the final commit |
| a tier's sanitizer gate leaves three kernel tests to the weekly run (`KernelTestParts.weeklyUnderSanitizer`; `swift-test` and `kernel-test` run them whole) | 2600 of the kernel tests' 4058 s (quiet); each longer alone (879 s quiet, 1809 s loaded) than any part could be | yes (rule 1d) |
| the diagnostics test weekly under the sanitizer (`.weeklyUnderSanitizer`) | 1047 s quiet, 1355 to 1536 s loaded, the end of the serialized `TypeCheckerTests` chain | yes (rule 2a) |
| the types package's tests weekly under the sanitizer | 494 s quiet; 1132 s of SUnit body and 1532 s in all in the candidate run, the end of the compiler shard | yes, after the candidate run (rule 2a; the Smalltalk tier's `tools-test` runs the same tests) |
| three kernel-test parts | 2551 to 2577 s against 2836 to 2926 at two (rule 4c: the shortest) | yes; the weights refreshed from part 1 (`TypeSyntaxTest`'s 247 s had weighed 0.32) |
| a kept or second scratch path for the build | the builds are 26.6 and 33.0 s of the gates from an empty scratch path | no: under 4 percent, and a kept build is a gate that may have changed |
| the host-timer test's sleep | 120 s of one test thread in every sanitizer run | yes (part 3) |
| the VM tests under the sanitizer at a tier size | the stall tests are 3990 of the VM bundle's 13 305 body seconds (30 percent), and the VM shard ends the candidate gate (1766 s) | no: their sanitizer runs guard the collectors' protocols, which a core-tier diff changes; a size the core tier runs too would weaken exactly those runs. The next lever, an open question |

### The tests per gate (the bar, item 3)

`$CT/scripts/tests-per-gate.py` reads a gate's output for every Swift
test that passed, failed or was skipped (by function name; 676 names before)
and every kernel test the parts ran (264). `$CT/work/tests-per-gate-tier.md`:

| gate | before (c514abf) | after, tier (0ae993f) | after, full size (`check-full/`) |
|---|---|---|---|
| `swift-test` | 676 + 264 kernel | 678 + 264 | 678 + 264 |
| `tsan` (the Swift tier's before) / `tsan-load` (after) | 676 + 264 | 676 run, 7 skipped (5 before) + 261 kernel | 678 + 264 (`tsan`, `tsan-load`) |
| `swift-test-load` | 676 + 264 | (core tier) | 678 + 264 |

New in every gate: `TestSizeTests.everySizedTestHasARow` and
`theSwitchReadsItsVariable`. Gone from a tier's sanitizer gate, each in the
size switch's table (`sizedTests`, `Tests/KajoCompilerTests/TestSize.swift`)
and run in the tier's plain gate and the weekly run's four:

| test | claim | where it runs |
|---|---|---|
| `TypeCheckerTests.theDiagnosticsRequestAnswersItsScopesAndTheEventFollowsAChange` | the diagnostics request answers its scopes after a whole-image check; the event follows a change | tiers: plain only (47 s); weekly: all four |
| `TypeCheckerTests.theTypesPackageBuildsAndItsTestsPass` | the types package builds; its 33 SUnit tests pass | tiers: plain only (29 s); weekly: all four; the Smalltalk tier's `tools-test` runs the same tests |
| `CompilerTest>>testEveryMethodCompilesAsTheBootstrapDid` (kernel) | every method compiles as the bootstrap did | tiers: `swift-test` and `kernel-test` whole; weekly: all four |
| `LiveCompileTest>>testEveryMethodMakesAsInstalled` (kernel) | every method made by the make primitive is as installed | the same |
| `CompilerTest>>testALongChainIsWalkedByALoop` (kernel) | a chain of 120 000 sends compiles by loops | the same |

Nothing left the weekly run: its four test gates at full size hold every
name of before (`check-full/`, 0 gone in each).

### The starting positions

1. Half right. The sanitizer gate's end was the kernel's two parts, but
   behind them the two bundles ran one after the other (1186 + 2174 s quiet)
   with the second half idle; more parts did not cut it (2551 to 2710 s at
   three to six parts against 2836 to 2926 at two: under load the parts
   share the CPU, and from four parts the serialized type-checker suite
   ends the bundle). What cut it: the shards side by side and five tests
   left to the weekly run under the sanitizer.
2. Wrong. The 36.9 s row was not a request sent again: `(retried)` is a
   label of its own. It was a first send whose reply reached the image in
   16 to 25 s and was dispatched later; the slow thing before the reply was
   `session.open`'s answer (4.1 s of a fresh image's first open quiet under
   the sanitizer, 9 s loaded), and the hierarchy's own work is 3.5 s quiet
   under the sanitizer. The timeout races the arrival, not the dispatch.
3. Right that the claim does not need the wait; "never makes true" is
   nearly so: past 120 s in 13 of 14 sanitizer runs (0.017 s once), 45 to 59
   s plain. Why GCD starts no thread for the queue in the suite is not
   established.
4. Wrong. The reserve test's claim needed no smaller size: its wait was a
   clock on a fixed amount of work. It waits on the collector's progress;
   the rings are the same length.
5. Partly. The test has a sanitizer exemption already; a load value would
   have widened the bound (decided against). Reproduced alone under twelve
   loops, 1 failure in 100: the failing turn acknowledged a young round.
   The VM's, handed on.
6. Wrong for the plain gate: the random programs' seeds are a claim over
   every seed (rule 1d keeps them whole where no other tier gate runs them),
   and the plain VM bundle was waiting on its pool of test threads, not on
   its seeds (shards cut it from 655 to 241 to 283 s a shard). Under the
   sanitizer the long VM tests were kept (part 2's table).

### Decided under the owner's delegation, as built

1. A tier runs one sanitizer gate, the loaded one; the weekly run keeps
   `tsan` and `tsan-load` (`check-tier.sh`, `weekly.sh`). The condition was
   checked first (part 1): no fault of the product was found by `tsan`
   alone.
2. A test may run at a claim size in the tiers and its full size weekly:
   `KAJO_TEST_SIZE=full`, exported by `weekly.sh` only; `sized(_:tier:full:)`
   and `.weeklyUnderSanitizer(_:)` in `Tests/KajoCompilerTests/TestSize.swift`,
   with the table test `TestSizeTests`. Three rows, all of them "under the
   sanitizer in the weekly run only" (the VM tests read no size).
3. The targets: not met (below), the claims kept.
4. No request timeout and no test's bound grew. Waits that changed are
   quiet-bounded on the collector's progress (reserve, the parked stacks,
   the verifier faults' rings) or removed (the host timer's); the tools'
   activity counts every client.

### Not done, not verified

- The targets of the bar, item 2, are not met (the gates, below). The next
  lever is named in part 2's table: a tier size for the VM tests under the
  sanitizer (the stall tests are 30 percent of the VM bundle's sanitizer
  time), or a Swift-tier-only selection of them, both a coverage decision.
- The core tier was not run; its Mac gates' time is an estimate from the
  weekly run of 2026-11-23 for the gates this module did not touch and from
  this module's runs for `swift-test-load` and `tsan-load` (below). The
  device rows were not touched.
- "From an empty scratch path": the tiers ran with `.build` removed
  (`$CT/dotbuild-kept/` holds the one found there at the start, moved
  aside, not deleted); the toolchain's compilation cache outside the
  repository was left as it was.
- Why GCD starts no thread for the default global queue in the suite is
  not established (part 3, item 2).
- The turn-overrun test's 1 failure in 100 under load is the VM's (a young
  round acknowledged in the turn); not fixed here.
- The tag test's refused removal (part 3, item 5): which Process held the
  class is not known; the line says more from now on.
- `scripts/broken-variants.sh` ran once on its own and once in the scratch
  weekly run; never in a real weekly run.

### Found, not this module's

- A frames reply compiles every frame's method again to find its
  variables: 12 s quiet under the sanitizer and 0.4 s plain for a doIt's
  stop, 28 to 49 s with the VM tests beside it, against the tools' 30 s
  request timeout (part 3, item 6). The tools' suites and the frames tests
  run in a phase of their own because of it.
- `session.open`'s answer made the whole protocol description to count it
  (fixed here, part 3, item 1); the first `protocol.describe` of an image
  still pays 3.6 s under the sanitizer once.
- A turn that acknowledges a young round can run past its deadline check
  by more than its reported young time (part 3, item 4): 1 in 100 runs of
  the turn-overrun test alone under twelve loops, 0.219 ms against 0.2.
- The VM refuses a class removal while any Process holds the class on its
  stack; a listing request or the type service's recheck does for seconds
  (minutes under the sanitizer), so the browser's own removal can be
  refused "try again" in a real session.
- `ProjectDirectoryTests.eachTargetWritesOnlyIntoItsOwnDirectory` failed
  once, in the full-size `swift-test-load` on 0ae993f (`$CT/0ae993f-check-full/`):
  the C target's reply line was not among the host's events after its
  connection's end. Not reproduced, not looked into further; it passed in
  every other run here.

### Gates

`scripts/check-tier.sh --dry-run origin/master` on 1a68580: **the Swift
tier with `check-tier-test`**, no fuzzer, no model check
(`$CT/check-dry-run.txt`; 19 files, 16 chose it, `kernel/` the other
tier's). `KAJO_CHECK_OUT=$CT/check just check origin/master` from an empty
scratch path (`$CT/check/gates.log`, last line `2026-11-26 18:48:55 1a68580
check-tier done swift failed=0 3656s`):

| gate | s (1a68580) | before (3f86421, weekly margins) |
|---|--:|--:|
| check-tier-test | 7 | 7 |
| clean-build | 18 | 20 |
| swift-test | 453 (from empty: the native cache cold; 303 to 307 warm) | 747 |
| tsan (before) / tsan-load (after) | 2643 | 3146 (`tsan`); `tsan-load` 4355 on c514abf |
| kernel-test | 125 | 126 |
| apps | 141 | 131 |
| new-check | 269 | 272 |
| **the tier** | **3656** | **4449** |

`check-tier-test.sh`: 133 checks (116 before). 676 Swift tests run, 7
skipped, 261 kernel tests in `tsan-load`; 678 and 264 in `swift-test`; 0
sanitizer reports; the tier's margins table (`$CT/check/margins.md`): no
THIN, no PAST, the largest 0.60 (`relocation.runKernel.true.stw`, 538 of
900 s).

**The five loaded sanitizer runs** (`$CT/check-load-{1..5}/gates.log`,
through `gl_gate`): `rc=0` 2529, 2595, 2592, 2604 and 2614 s; 0 sanitizer
reports in each; no THIN and no PAST in any run's table. The first phase
ended at 1880 to 1961 s, the tools' phase took 645 to 659 s. The tag test
0 of 5 (rule `$CT/work/rule-tag.txt`): `tagProbeRemoved` 4.1 to 4.6 s, the
whole test 29.6 to 31.4 s. The thin waits in them: `tools.reply.class.hierarchy`
7.5 to 8.0 s of 30 (0.25 to 0.27; its round trip, now a time, beside it);
`tools.reply.session.open` 0.40 to 0.48 s; `tools.reply.process.frames`
6.4 to 6.6 s; the protocol tests' frames waits 11.5 to 12.2 s of 60 (0.20);
the reconnect test's `remoteDebuggerReady` quiet 1.4 to 3.8 s of 60; the
reserve's quiet stretches 7.8 to 14.8 s of 600; `keptAcrossRun`'s 13 to 18
s of 600; the parked stacks' 14 to 21 s of 120; `main.turnOverrunCpu` (a
time under the sanitizer) 0.93 to 2.49 ms.

**Everything that moved to the weekly run still passes** (`$CT/check-full/`,
`KAJO_TEST_SIZE=full`, through `gl_gate`): `swift-test` `rc=0` 307 s,
`swift-test-load` 357, `tsan` 3003, `tsan-load` 3796; 678 Swift and 264
kernel tests in each, every name of before (`$CT/work/tests-per-gate-final.md`),
`kajo-test-size size=full sized=3` in each, 0 reports, no THIN and no PAST
(`$CT/check-full/margins.md`, the weekly-shaped table of the bar's item 4;
the largest 0.58, the long chain over the protocol under `tsan-load`).

**The targets** (the bar, item 2): the Swift tier from an empty scratch
path in 3656 s against 1800: not met. The core tier's Mac gates, estimated:
this module's `swift-test-load` (357 s) and `tsan-load` (2587 s, the five
runs' mean) and the other Mac gates' times of the weekly run of 2026-11-23
(2863 s: clean-build 20 to matrix-mac 745) come to about 5807 s against
4500: not met; the same gates came to 10 841 s in that weekly run with
`tsan` and the old `tsan-load`. Not run as a tier here. The next lever is
part 2's last row.

**The weekly run.** `scripts/weekly.sh --gates`:
`check-tier-test clean-build swift-test swift-test-load tsan tsan-load
ios-check arc-check golden native-golden native-kernel-test native-cc
test-release model-check soak fuzz apps kernel-test new-check ab
broken-variants matrix-mac devices`. A quick scratch run on 1a68580
(`KAJO_WEEKLY_ROOT=$CT/work/weekly KAJO_WEEKLY_DEVICES=0 KAJO_WEEKLY_QUICK=1
KAJO_WEEKLY_ONLY="check-tier-test swift-test broken-variants"`,
`$CT/work/weekly/2026-11-27-quick/summary.md`, 7 min, `failed: none`;
nothing under `~/kajo-weekly/` changed, no device touched):

    | check-tier-test | pass | 7s |  |
    | swift-test | pass | 304s |  |
    | broken-variants | pass | 107s |  |

    ## Test sizes

    KAJO_TEST_SIZE=full for every gate. The size each suite printed:

    - swift-test: 1 kajo-test-size size=full sized=3

    ## By-hand broken variants (scripts/broken-variants.sh)

        broken-variant: delay-end expect=fail rc=1 5s ok
        ...
        broken-variant: tools-hold-loop expect=pass rc=0 79s ok
        broken-variants: 7 run, 0 not as recorded

Before the tier the changed suites ran once under the sanitizer with twelve
loops (`$CT/work/tsan-changed/`: 31 tests passed, 0 reports) and the
changed scripts each once on their own (`check-tier-test.sh`,
`$CT/work/check-tier-test-1.txt`; `broken-variants.sh`,
`$CT/work/broken-variants-1.txt`).

**Runs that failed on the way**, each investigated, none run again until it
passed: the tier on 292b202 (`$CT/292b202-check/`, `failed=1`, the
reconnect test, `remoteDebuggerReady` with activity -1), on 749fc70
(`$CT/749fc70-check/`, `failed=1`, the same with the clauses), on a880ce0
(`$CT/a880ce0-check/`, `tsan-load` `rc=1`, the tag test's refused removal;
the run stopped there); the full-size `swift-test-load` on 0ae993f
(`ProjectDirectoryTests`, found above). The tier on 0ae993f passed in 3634
s and its five loaded runs 5 of 5.

**The module's own gate time**: about 35 hours of the machine from
2026-11-25 15:53 to 2026-11-27 00:36 (part 1's 23 runs 12.8 h, the
experiments of part 3 about 5 h, five tier runs 4.8 h, two sets of five
loaded runs 7.3 h, two full-size sets 4.0 h, the rest under an hour;
`measure.log` and every `gates.log` under `$CT`).

### Deviations

- `kernel/` changed (`DevProtocol class>>requestCount`, `DevSession>>info`),
  a product path part 3's measurement named, said first in part 3.
- The tools' suites and the frames tests run in a second phase of the
  suite, not side by side with the rest: the side-by-side layout made the
  frames reply pass the tools' timeout (part 3, item 6).
- Five extra waits were changed beyond the six thin ones (the parked
  stacks, the verifier faults' rings, the reconnect test's activity, the
  turn test's printing, the tag test's clauses), each made thin by the new
  layout or by a failure here.
- The core tier was estimated, not run.
- The by-hand variants' runner covers the seven variants that need no
  source change; the rest are named, not automated.
- The first tier runs found what the layout broke; the module's final
  code commit is 1a68580, the third commit after the first tier.

### Open questions (built as recommended)

1. The Swift tier's plain gate stays unloaded. Recommended: as built, one
   loaded gate a tier.
2. A THIN margin in a tier's table does not fail `just check`.
   Recommended: not yet; read two weekly runs first.
3. New: the owner's decision of 2026-11-13 kept "sampling the every-method
   kernel tests under the sanitizer" out of gate speed; here, under the
   delegation, a tier's sanitizer gate leaves those three tests to the
   weekly run (the plain gates of every tier run them whole). Recommended:
   keep, as built.
4. New: the targets are not met (61 and about 97 minutes against 30 and 75).
   The next lever is a tier size for the VM tests under the sanitizer,
   either everywhere (weakens the core tier's sanitizer runs of the
   collectors) or in the Swift tier only (a third size). Recommended: neither
   now; read the next weekly runs at these prices first.
5. New: the frames reply's cost (every frame's method compiled again, 12 s
   quiet under the sanitizer) as a small module: cheaper, the second phase
   could go (about 650 s of every sanitizer gate). Recommended: yes, after
   the core module.
