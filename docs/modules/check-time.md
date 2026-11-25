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
