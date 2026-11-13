# Gate speed

Status: briefed 2026-11-13, from the owner's request of the same day
("figure out if we can optimize all these tests and checks, they're
getting really long. Anything overlapping?") and the owner's acceptance of
the investigation's proposals ("all sounds good, accepted"). Built
2026-11-13 (see "As built"); the final gate run is recorded below.

## What it hides

How long a tier takes. With one exception, decided by the owner and named
below, nothing a tier verifies changes: the same tests, the same seeds, the
same kernel tests under the sanitizer, the same fuzz time per target. The
module removes work that is done twice and runs side by side what was run
one after another.

## Where the time goes (measured)

The core tier's totals over the last seven modules, in seconds: 12 197,
12 253, 12 558, 13 216, 15 458, 17 957 (AOT 1) and 19 659 (the allocation
stalls, a18696a). That last run, per gate:

| gate | s | gate | s |
|---|---|---|---|
| clean-build | 23 | model-check | 22 |
| swift-test | 1329 | soak | 480 |
| swift-test-load | 1447 | fuzz-kasm | 642 |
| tsan | 4677 | fuzz-snapshot | 604 |
| tsan-load | 5889 | fuzz-syntax | 604 |
| ios-check | 17 | fuzz-protocol | 604 |
| arc-check | 47 | apps | 123 |
| golden | 73 | kernel-test | 108 |
| native-golden | 99 | new-check | 254 |
| native-kernel-test | 46 | ab | 331 |
| native-cc | 30 | matrix-mac | 776 |
| test-release | 591 | matrix-iphone | 843 |

The debug suite four times is 13 342 s of the 19 659; the four fuzzers
2454; the matrices 1619; `test-release` and `soak` 1071. The latest Swift
tier (40ce930) took 6147 s, of which `swift-test` 1103 and `tsan` 4526.

What the investigation measured on 5635bc3 with the mini idle
(2026-11-13; the gate outputs of the stalls run and a serial run of the VM
bundle):

- Under ThreadSanitizer one test,
  `KernelImageTests.theKernelsTestsPassAndTheEventsAreTheProtocol`, which
  runs all 249 kernel SUnit tests in one VM, takes 3081 s in `tsan` and
  3719 s in `tsan-load` (111 s in a plain build). It is serial inside, so
  the rest of the suite finishes long before it and the gate waits for one
  thread. Of its about 103 s plain, three kernel tests are 67:
  `LiveCompileTest>>testEveryMethodMakesAsInstalled` 23.7 s,
  `CompilerTest>>testEveryMethodCompilesAsTheBootstrapDid` 23.3 s and
  `CompilerTest>>testALongChainIsWalkedByALoop` 19.9 s.
- `LiveInstallTests.installingWorksInADevelopmentImageAndIsForbiddenInTheSameImageSealed`
  (923 s in `tsan`, 1254 s in `tsan-load`) first runs `--filter
  LiveCompileTest` on the same development `kernelImage` the full run
  above has already run it on, then seals the image and runs two filters
  in the sealed one. The first part is the same tests on the same image a
  second time.
- The four fuzz gates run one after another, 600 s each plus their
  builds: 2454 s. (The development answers' gate once ran the four at the
  same time for 601 s each, at 0.92 to 2.99 million runs.)
- `test-release` runs the random programs (about 490 s of its 591), and
  `soak`, the next gate but one, runs the same tests in the same build
  with `KAJO_SEEDS=1000`: 1000 interpreter seeds where `test-release` ran
  100, the same 100 native seeds per configuration (`min(count, 100)`)
  and the same resume-across-engines seeds (40).
- `bothCompilersRefuseAtEveryEncodingLimit` is 300.7 of the compiler
  bundle's 304 s in a plain build: eight cases through one probe VM, one
  after another.
- The VM bundle run serially (`swift test --no-parallel --filter
  '^KajoVMTests\.'`) is 2169.8 s for 445 tests against 800 to 1017 s of
  wall in parallel. The random programs are 1687 of it and the native
  ones 1400 (`randomProgramsAgreeWithTheirModelNatively` 976.5,
  `randomProgramsResumeAcrossEngines` 423.9); 389 of the other tests are
  under a second. The native random programs at 10 seeds, serial: 94.9 s,
  40 clang compiles of 40 different sources of about 1.0 MB each, 66.7 s
  of it inside clang (1.7 s a compile at `-O1`). Every suite run of a
  gate run compiles the same generated C again.
- `scripts/weekly.sh` does not run `native-golden`, `native-kernel-test`,
  `native-cc` or the aligned A/B, which the core tier has had since AOT 1
  and the gate tiers: the weekly "full set" is short of the core tier.
- `scripts/check-tier-test.sh` is run by no gate (AGENTS.md: it had
  failed for a module before anyone noticed).

## The owner's decisions (2026-11-13)

1. The changes of the next section are built as one module.
2. Plain `swift-test` leaves the **core** tier. The core tier keeps
   `swift-test-load`, `tsan` and `tsan-load` (the same suite under twelve
   busy loops, under the sanitizer, and under both), and the Swift tier
   and the weekly run keep plain `swift-test`. This is the one change in
   what a tier runs.
3. Not built, because each trades coverage: fewer native seeds in debug
   builds, the golden rows once in the tier's matrices, sampling the
   every-method kernel tests under the sanitizer, a shorter fuzz time.

## The changes

Part 1 of each is a measurement on the starting commit, as always: what
the thing costs now, per piece, in the build mode where it hurts (the
sanitizer for the first, a plain build for the others). The numbers above
are the main session's; repeat the one you are about to attack and write
what you found before you build. If a premise does not hold (one case of
eight is the whole 300 s, one kernel test is the whole sanitizer hour),
say so and build what the measurement asks for.

### 1. The kernel's tests under the sanitizer, in parallel VMs

`theKernelsTestsPassAndTheEventsAreTheProtocol` becomes several VMs that
run at the same time, each over a part of the kernel's test classes, on
the same `kernelImage`. Rules:

- The union of the parts is exactly the tests the unfiltered run runs, by
  test id and not by count, and a standing assertion says so cheaply in
  every build mode (for example a mode of the runner that lists the tests
  a filter selects without running them, so the test can compare the
  unfiltered list with the union of the parts' lists; or the parts
  computed from that list). A test class added to `kernel/` tomorrow is
  in a part without anyone editing a list. `report.total > 100` holds for
  the union.
- Every part is still a whole run by the event protocol: every assertion
  the test makes today about the events (one JSON object a line, the
  kinds, `v == 1`, `ts`, `run.started` first, `started == total`, test
  event times sorted) is made of every part.
- The parts run in parallel under Swift Testing (the suite is
  `.serialized` today; the parts cannot be). Each VM has a 256 MiB heap;
  say how many run at once under the sanitizer and what the process's
  memory peak is.
- How the parts are chosen (one class a part, classes grouped by measured
  time, several `--filter` patterns in one run) is yours to decide from
  the measurement. `TestRunner>>runFilter:tag:` takes one glob today and
  `Sources/kajo/Test.swift` passes one `--filter`; a change there is a
  kernel change and brings the Smalltalk tier's gates with it.
- If one kernel test is then most of the longest part under the sanitizer
  (the two every-method tests are the candidates), it may be split into
  several test methods that each cover a slice of the methods, with a
  test that the slices are disjoint and cover every method. The same
  methods are compiled and compared as today; no sampling.
- `LiveInstallTests` stops running `--filter LiveCompileTest` on the
  development image (the full run does) and keeps everything it does in
  the sealed image and the flag's round trip. If it relied on the first
  run to prove the image is a development image where installing works,
  it says where that is now proved.
- The other `KernelImageTests` (`filterAndTagSelectTests`,
  `failuresCarryTheMessageAndTheFrames`,
  `theTranscriptIsAnEventWithItsProcess`) and every other test that runs
  kernel tests in a VM: list them with their sanitizer times, and leave
  alone what is not a duplicate.

The evidence: the list of kernel test ids with their results from the
unfiltered run on the starting commit and from the parts on the final
commit, in a plain build and under the sanitizer, compared by a script
(249 of 249 the same ids, all passed), and `tsan` and `tsan-load` in the
final gate run with their new times and 0 reports.

### 2. The four fuzzers at the same time

One gate runs the four libFuzzer targets side by side: the four builds
first, one after another (they share `.build/fuzz`), then the four
binaries at once, each in its own run directory with its own output file
(`fuzz-<target>.txt` as today), each for its own full `GL_FUZZ_SECS`.
The gate fails when any target fails, crashes, or lacks its own
`libFuzzer build: ok` line (the fallback driver is never counted), and
`gates.log` still has a line per target with its status and its number of
runs, so a reader finds each target as before. The Swift tier's one or
several owed fuzzers go through the same gate with the list of targets
it owes. `scripts/fuzz.sh <target> <seconds>` keeps working alone.

Coverage is time per target and it is unchanged, but the runs in that time
are the measure: the sequential runs were 0.86 to 3.39 million per 600 s
per target. Report each target's runs side by side with its last three
sequential counts (the gate outputs of earlier modules are in
`.build/check/` if still there; the numbers are in AGENTS.md's decisions
paragraph otherwise). A target that falls below 0.8 of its sequential
count runs longer by the same factor, and the doc says so.

### 3. A disk cache of compiled native test modules

`NativeTest.compile` (`Tests/KajoVMTests/Native/NativeSupport.swift`)
keeps the dylib it built, keyed by a digest of everything clang reads and
is told: the source (and any header it includes), the output of `clang
--version` for the clang found on PATH, and the whole argument list
(`-fsanitize=thread` included). A hit loads the cached dylib; a miss
compiles, writes beside the cache under a temporary name and renames into
place. Rules:

- The cache is under the package's `.build/` (one place for every scratch
  path, so `test-release`, `soak` and the debug runs share it where their
  keys agree), `KAJO_NATIVE_CACHE=<dir>` moves it and
  `KAJO_NATIVE_CACHE=off` turns it off.
- A cached file that does not load is removed, compiled again and
  counted; it never fails or passes a test by itself.
- It is bounded (AGENTS.md: a log nothing trims is a leak): a size or an
  age past which the oldest files go, decided from the measured size of a
  full suite's modules, trimmed where it cannot race with a reader in
  another process (two `swift test` runs never overlap in a gate run, but
  a developer's might).
- Tests: a changed source misses, a changed flag misses, the same source
  and flags hit and load, a truncated cached file is replaced, two
  threads compiling the same source at once both get a module.
- The suite prints once at its end how many modules were hits, misses and
  replaced, so a gate's output says whether clang ran. A gate run whose
  generator changed is cold in its first run of each flag set and warm
  after; say what each suite run of the final gate run counted.

`native-cc`, `native-golden` and `native-kernel-test` do not use this
cache; they compile the images' real modules every time.

### 4. `test-release` without the random programs

`just test-release` skips `randomPrograms*`, and `soak` runs them in the
same build with every seed `test-release` would have used and more. Check
all five `randomPrograms*` tests' seed rules in
`Tests/KajoVMTests/Workers/RandomPrograms.swift` against `KAJO_SEEDS=1000
KAJO_SEED_BASE=1` before relying on that (the main session read three:
`randomSeedCount`, the native test's `min(count, 100)` and the
resume-across-engines 40), and put the rule where it cannot rot:
`check-tier-test.sh` fails when a gate list holds `test-release` without
`soak`, and the recipe's comment says why.

### 5. The compilers' limit cases in parallel

`bothCompilersRefuseAtEveryEncodingLimit`
(`Tests/KajoCompilerTests/ReviewFixesPart2Tests.swift`) runs its cases at
the same time, each with a probe VM of its own: the same eight cases in a
plain build and the same four under the sanitizer, the same two
assertions per case (the bootstrap accepts or refuses as listed; the two
compilers agree). Measure each case first.

### 6. The weekly run is the full set again

`scripts/weekly.sh` gains `native-golden`, `native-kernel-test`,
`native-cc` and `ab`, and takes change 2's fuzz gate. It keeps plain
`swift-test` (the weekly is the full set). The A/B needs a base the
weekly does not have: recommended, the commit of the last weekly run that
finished, read from `~/kajo-weekly/weekly.log`, and when there is none or
it is HEAD the gate is skipped with a line saying so in `gates.log` and
`summary.md`, never a failure and never silently. `summary.md` shows the
new gates and each fuzz target.

### 7. Plain `swift-test` out of the core tier

By the owner's decision. `check-tier.sh`'s core list, its header comment,
`check-tier-test.sh`'s literal lists and `docs/modules/gate-tiers.md`'s
"As built" pointer to this doc follow.

### 8. The gate scripts' own test is a gate

`scripts/check-tier-test.sh` runs as a gate of the Swift tier (and so of
the core tier) whenever the diff touches `scripts/check-tier.sh`,
`scripts/gates-lib.sh`, `scripts/weekly.sh`, the script itself or a new
script of this module, the way `model-check` runs when `models/` changed.
It gains checks for everything above: the new core list, the fuzz gate's
failure when one of four targets fails or lacks its build line (with
stand-ins, as the matrix gate's check has), `test-release` implying
`soak`, and the weekly's list being a superset of the core tier's but for
the device rows' form.

## Rules of the house that bind here

- A gate that finishes much faster than it did has changed; the hand-back
  says what each faster gate ran, before and after, from the gates' own
  output files: test counts with every difference explained (a
  parameterized test counts once whatever its cases), kernel test ids,
  seeds per configuration, fuzz runs per target, modules compiled.
- A changed gate script is run once on its own before the gate run, the
  weekly script included: one quick weekly run of the gates this module
  adds or changes (`KAJO_WEEKLY_QUICK=1`, `KAJO_WEEKLY_ONLY`,
  `KAJO_WEEKLY_ROOT` in a scratch directory, `KAJO_WEEKLY_DEVICES=0`),
  under `env -i` with exactly the LaunchAgent plist's environment, as the
  gate-tiers module did. Sunday's run at 02:00 is the first real one.
- In zsh `status`, `path` and `argv` are not yours to assign.
- No wait loop on `pgrep -f <name>`; waits are on a pid or a file and
  bounded. Concurrent children of a gate are all killed by `gl_cleanup`
  and by a timeout; a test of the fuzz gate shows no fuzzer outlives a
  killed gate.
- A wall-clock assertion fails under load. Nothing here asserts a
  duration; durations are reported.
- A test that asserts parallelism happened runs long enough to see it;
  none is needed here.
- Nothing under `Sources/KajoVM` is expected to change. If a change there
  turns out to be needed, stop and say why in the hand-back before
  building it.

## Deliverables

1. The measurements of part 1 for each change, in "As built".
2. Changes 1 to 8 with their tests.
3. `check-tier-test.sh` passing, with its new checks, and run by a gate.
4. The coverage table: for every gate whose time changed, what it ran
   before and after.
5. The final gate run on the final code commit: the new core tier forced
   (`just check --tier core <base>`, the device rows through
   `scripts/device-rows.sh` as the tier does), plus every gate the diff's
   own tiers owe that the new core tier does not hold (plain
   `swift-test`; the Smalltalk tier's `build-image`, `dev-image`,
   `tools-test`, `compiler-tests` and `mac-shell-tests` if `kernel/`
   changed), quoted from `gates.log`, with each gate's time beside the
   table above and the total against 19 659 s. The aligned A/B runs as
   part of it and is expected at parity (no VM source changes); say what
   it read.
6. The quick weekly run of the changed gates, quoted.
7. This doc's "As built", "Deviations", "Not done" and "Open questions"
   (each with a recommendation), written by you; the Status line updated.

## The bar

- Every gate of the final run passes; ThreadSanitizer 0 reports alone and
  under load.
- The same 249 kernel tests (by id) run and pass under the sanitizer and
  under load; the same seeds; the same fuzz seconds per target with runs
  at 0.8 or more of the sequential counts (or the time raised).
- The core tier's total is reported against 19 659 s. The estimate was
  about 3 hours; no number is a bar, the coverage rows are.
- `interpret` and the hot paths are untouched (no file under
  `Sources/KajoVM`); `just arc-check` passes as part of the run.

## Estimates (the investigation's, to be replaced by measurements)

| change | per core run |
|---|---|
| 1 the kernel's tests in parallel VMs, the duplicate run gone | about -5000 s |
| 2 fuzzers side by side | about -1800 s |
| 3 the module cache | -1000 to -2000 s (less with plain `swift-test` gone) |
| 4 `test-release` without the random programs | about -500 s |
| 5 the limit cases in parallel | about -400 s over the suite runs |
| 6 the weekly's gap | +500 s weekly |
| 7 plain `swift-test` out of the core tier | -1329 s |

## Open questions

None for the owner at the brief. The agent's choices that the owner may
want to see (how the kernel's tests are divided, the cache's bound, the
weekly's A/B base) are written as open questions with what was built.

## As built

Built 2026-11-13 on 3cf22fe (the starting commit and the `just check`
base) with the toolchain first on PATH, swift.org's Swift 6.4.2
(`swift-6.4.2-RELEASE`) through swiftly, and swiftly's `clang`, on the
Mac mini (M2 Pro, 12 cores, 32 GiB). Nothing under `Sources/KajoVM`
changed. Commits: 9df8d34 (the runner), 8651da1 (the tests), 33bbba8 (the
scripts), then this doc.

A note on evidence: the agent's scratch directory under `/private/tmp` was
emptied at 12:44 the same day, taking the morning's raw outputs and the
earlier modules' gate outputs with it. Every number below says where it
comes from: a file under `/Users/jonikatajamaki/kajo-scratch/gate-speed/`
(written after the loss, `$GS` below), the final gate run, or "quoted"
(from the brief's baseline, or from the morning's measurement whose file
is gone; those are not presented as backed by a file).

| file | what changed |
|---|---|
| `kernel/SUnit/TestRunner.class.st` | `casesFilter:tag:tests:` (the selection, now also by a set of exact names), `listFilter:tag:tests:` (a `test.listed` event per selected test and `run.listed` with the total, nothing run), `runFilter:tag:tests:`; `runFilter:tag:` unchanged for its callers (DevSession, the shells, the tools) |
| `kernel/System/Smalltalk.class.st` | `test:` reads `--test <Class>>selector>` (repeatable, exact) and `--list` |
| `Sources/kajo/Test.swift`, `main.swift` | `kajo test --test <name>... --list` |
| `Tests/KajoCompilerTests/KernelImageTests.swift` | `KernelTestParts`, `KernelTestPartsTests` (change 1) |
| `Tests/KajoCompilerTests/LiveInstallTests.swift` | the duplicate run gone (change 1) |
| `Tests/KajoCompilerTests/ReviewFixesPart2Tests.swift` | the limit cases as arguments (change 5) |
| `Tests/KajoCompilerTests/ShellTests.swift` | `drive`'s bounds with a sanitizer value (below) |
| `Tests/KajoVMTests/Native/NativeCache.swift` (new), `NativeSupport.swift`, `NativeCacheTests.swift` (new) | the disk cache (change 3) |
| `justfile` | `test-release` skips `randomPrograms` (change 4) |
| `scripts/fuzz.sh`, `scripts/fuzz-gate.sh` (new) | `--build` and `--run`; the fuzz gate (change 2) |
| `scripts/gates-lib.sh` | the gates `fuzz` and `check-tier-test`, a `gates.log` line per fuzz target, `gl_skip`, `gl_weekly_ab_base` |
| `scripts/check-tier.sh` | the core list without plain `swift-test` (change 7), `fuzz` for the four, `check-tier-test` when a gate script changed (change 8) |
| `scripts/weekly.sh` | the full set (change 6), `--gates`, the A/B's base or a skip, the summary's note column, the refusal by swiftly's process names |
| `scripts/check-tier-test.sh` | 36 checks to 96 |

### 1. The kernel's tests in parallel VMs

Part 1, measured on 3cf22fe with the mini idle through `kajo test --heap
256` (the `Headless.test` the suite calls, its events kept). Plain:
`$GS/before-kernel-plain.ndjson` (249 tests, 102.1 s, 1:44 wall), built
from `git archive 3cf22fe` in `$GS/before-src`. Under the sanitizer the
morning's run (09:13:49 to 10:03:01, 2921.5 s of tests, peak footprint
1.41 GB) is quoted; after the loss it was run again from the same archive,
`$GS/before-kernel-tsan.ndjson` with `.run` and `.err` (12:48:31 to
13:38:29, 249 of 249 passed, 2967.8 s of tests, the three long tests 689.0,
681.9 and 661.3 s, peak footprint 1.39 GB, 0 sanitizer reports). The
per-test sanitizer seconds of the morning run are the weights in
`KernelTestParts.measuredSeconds`:

| test | plain s | sanitizer s |
|---|--:|--:|
| LiveCompileTest>>testEveryMethodMakesAsInstalled | 23.7 | 697.9 |
| CompilerTest>>testEveryMethodCompilesAsTheBootstrapDid | 23.3 | 691.4 |
| CompilerTest>>testALongChainIsWalkedByALoop | 19.7 | 584.5 |
| ClassFuzzTest>>testSeededSpecificationsAreRefusedOrAccepted | 5.7 | 152.8 |
| TonelTest>>testTheReaderReadsWhatTheWriterWrote | 4.6 | 138.0 |
| LargeObjectTest>>testStringsPastTheCountField | 4.5 | 123.7 |
| the other 21 tests of 5 s or more under the sanitizer | | 533.1 |
| the other 222 tests | | 71.5 (0.32 each) |

The sanitizer costs 26 to 32 times a plain build, test for test (one
exception, ClassFuzzTest's reshapes at 18.6). Three tests are 1974 s of
2921; the other 246 are 948 s. The premise held: one serial VM was the
sanitizer gates' long pole (3081 s in `tsan`, 3719 in `tsan-load`,
quoted from the brief).

Built:

- The runner lists: `kajo test --list` (and `Smalltalk class>>test:`
  with `--list`) emits a `test.listed` event per selected test (name,
  class, selector, tags) and `run.listed` with the total, and runs
  nothing. `--test <Class>>selector>` (repeatable) selects by exact name,
  so a part names its tests and no glob can catch a neighbour's.
- `KernelTestParts` lists the kernel image's tests once per test process
  and splits them into 5 parts: heaviest first, each to the lightest
  part, weighed by the sanitizer seconds above for the 27 tests of 5 s or
  more there, 0.32 s for any other test and 150 s for an unknown one
  tagged `<slow>`. The table decides the balance only: a new or renamed
  test is in a part all the same. Five because the three long tests take
  a part each and the other 246 fit in two of about 474 sanitizer
  seconds; more parts add VMs without shortening the longest.
- `KernelTestPartsTests.theKernelsTestsPassAndTheEventsAreTheProtocol(_:)`
  is the old test as five cases in a suite without `.serialized`, so they
  run at the same time; each is a whole run by the event protocol over
  its part with every assertion the old test made (exit 0, all passed, one
  JSON object a line, the kinds a subset of the v1 kinds and the required
  ones present, `gc` among them since every run ends with the gc summary,
  `v == 1`, `ts`, `run.started` first, `started == total`, the test events'
  times sorted), plus that it ran exactly its part's names, each once.
  `total > 100` became `total == names.count` per part; the union's count
  is asserted by the next test. Each case prints `kernel test part i/5
  <outcome> <Class>>selector> <s> s` per test and a summary line, so a
  gate's output names every id with its outcome.
- `KernelTestPartsTests.theKernelTestPartsAreExactlyTheUnfilteredRun`,
  the standing assertion (a few seconds plain, 118 s under the sanitizer):
  the unfiltered list has more than 100 tests with distinct names and
  `run.listed`'s total; for each part the runner's own selection of its
  `--test` names is exactly that part; the parts are disjoint and their
  union is the unfiltered list; the split is deterministic; a filter and
  names compose and never add.
- `LiveInstallTests` no longer runs `--filter LiveCompileTest` on the
  development `kernelImage`: the parts run every LiveCompileTest on that
  image, the test asserts the list holds at least nine of them (its old
  count) and says where they run, and keeps the seal, the flag through a
  load and a save, `testTheReleaseFlag` and `ClassVariableTest` in the
  sealed image.
- The every-method tests are not split. With the parts, the longest part
  is one of them; the chain test, one compile, is 585 s on its own and
  `TonelRoundTripTests`, a serialized suite of the same bundle, took 594 s
  in the stalls gate (quoted). Splitting would save at most about 100 s
  per sanitizer gate for eight new kernel test ids: an open question.
- Found when the parts first ran under the sanitizer: the compiler
  bundle's first quarter hour is busier with five VMs, and
  `ShellTests.theKernelsViewTestsPassAgainstTheShell`'s 120 s `drive` ran
  out at 138 s (it took 30 to 57 s before). `drive`'s bounds, waits for
  something that must come, are five times longer under the sanitizer
  (`driveScale`); the assertions are unchanged. The compiler bundle then
  passed under the sanitizer and twelve busy loops (1480 s, 0 reports, the
  test 32.7 s; the morning's file is gone, the final run's `tsan-load` is
  the record).

Other tests that run kernel tests in a VM, none a duplicate of the
unfiltered run, left alone: `KernelImageTests.filterAndTagSelectTests`,
`failuresCarryTheMessageAndTheFrames` and
`theTranscriptIsAnEventWithItsProcess` (images of their own),
`theImageRoundTripsThroughLoadAndSave` (`ReflectionTest` in the image
saved twice), `LiveInstallTests`' sealed part,
`ToolsTests.theDevelopmentImageBuildsAndTheToolsTestsPass` (the tools'
tests), `AppProjectTests.theGeneratedAppCompilesWithTheKernelAndItsTestPasses`,
`DevelopmentAnswersTests.kajoTestReportsAndEndsAForkedProcessError`,
`SnapshotScenarioTests.kajoTestRefusesAnImageWithSavedProcessesAndRunResumesIt`
and `ShellTests.theKernelsViewTestsPassAgainstTheShell` (ViewTest against
a shell host). Their sanitizer seconds in the stalls gate (quoted, file
gone): 6.7, 27.1, 26.9, 13.5, about 25, 272.9, 89.2, 91.4, under 10 and
56.5.

### 2. The four fuzzers at the same time

Part 1 (quoted, the files are gone): the four one-target gates of the
stalls run took 642, 604, 604 and 604 s; their runs in 600 s were, for
the review fixes part 2, AOT 1 and the stalls run: kasm 2 223 005,
2 190 093, 2 196 708; snapshot 3 138 165, 3 531 582, 3 387 640; syntax
865 147, 857 319, 856 218; protocol 1 810 269, 1 836 868, 1 855 288. Each
libFuzzer process is one thread, so four on twelve cores should keep
their rates; the final gate's runs are the measurement (below).

Built: `scripts/fuzz.sh --build <target>` builds and prints the
"libFuzzer build: ok" line (or the fallback's), recording the binary and
its kind in `.build/fuzz-run/<target>/build.txt`; `--run <target>
<seconds>` runs what was built; with neither it does both, as before.
`scripts/fuzz-gate.sh <seconds> <out> <target>...` builds the targets one
after another, then runs them side by side, each for the full seconds in
its own run directory into `<out>/fuzz-<target>.txt` (the old gate's
file), each under its own `gtimeout` (seconds + 900), and prints
`fuzz-gate: <target> rc=<status> build=<ok|fallback|failed> runs=<n>
<s>s`; it exits 1 unless every target built with libFuzzer and ran to
status 0. It traps INT, TERM and HUP and kills every run's tree, because
each run's `gtimeout` is a process group of its own that a signal to the
gate's group does not reach (the broken variant without the trap, run by
hand: both stand-in fuzzers alive after the script was killed). The gate
`fuzz` runs it over `GL_FUZZ_TARGETS` (all four by default, the Swift
tier's owed ones there), bound `GL_FUZZ_SECS + 3600`, checks every
target's summary line and its file's "libFuzzer build: ok", and writes a
`gates.log` line per target before its own end line, e.g. `end
fuzz-protocol rc=0 61s runs=125702 build=ok` (the lost quick run).

### 3. A disk cache of compiled native test modules

Part 1: the investigation's serial native random programs at 10 seeds
compiled 40 different sources of about 1.0 MB, 66.7 of 94.9 s in clang
(quoted from the brief). The first plain suite with the cache, cold,
printed `1335 misses` for 569 files, 195 MiB (quoted, file gone): the
random programs' configurations start together and generate the same
seed's C at the same moment, so without a lock per key every one of them
compiled it; the in-memory cache by source never stopped that either. A
cold sanitizer suite added 65 misses and 33 MiB (quoted).

Built (`Tests/KajoVMTests/Native/NativeCache.swift`): `NativeTest.compile`
asks `NativeCache.shared`, keyed by a 128-bit digest (`nativeDigest`) of
the source (one file whose only includes are the system's), the clang's
identity (its path, `--version`, the SDK path and build version from
`xcrun`, read once per clang per process) and the whole argument list,
`-fsanitize=thread` included. A hit loads the cached dylib and touches its
date; a miss compiles to `<key>.dylib.tmp-<pid>-<serial>` beside it and
renames into place; a file that does not load is removed, compiled again
and counted as replaced. Threads of one process asking for one key wait
for the first one's compile. The cache is `.build/native-test-cache/`;
`KAJO_NATIVE_CACHE=<dir>` moves it, `KAJO_NATIVE_CACHE=off` restores the
old behaviour (a temporary dylib per compile, removed after loading). The
bound, from the measured sizes: at a process's first use temporaries
older than an hour go, and past 2 GiB the oldest dylibs go until under
1.5 GiB, never one used within the hour (about nine generator changes'
worth of gate runs). At exit one line: `native test cache: <h> hits, <m>
misses, <r> replaced, <t> trimmed at start; <n> files, <MiB> MiB in <dir>`.

Tests (`NativeCacheTests.swift`): a changed source misses, a changed flag
misses, the same source and flags hit and load (the descriptor's word read
back), a truncated file under the key is replaced, eight threads of two
caches over one directory (two processes' worth) all get their module
with at most one compile per source per cache and no temporary left, and
the trim takes the oldest first and never a file used within the hour.
The race test found a bug of the first version: the temporary's serial was
per cache, so two caches in one process wrote one temporary (`errno 2` at
the rename); it is per process now.

`native-cc`, `native-golden` and `native-kernel-test` do not use the
cache.

### 4. `test-release` without the random programs

Part 1 (quoted): in the stalls run `test-release` was 591 s, its VM
bundle's 489.7 s of wall bound by
`randomProgramsAgreeWithTheirModelNatively`; `soak`, two gates later in
the same `.build/release-tests` build, 480 s. The five tests' seed rules
in `Tests/KajoVMTests/Workers/RandomPrograms.swift` outside the
sanitizer, without and with `KAJO_SEEDS=1000 KAJO_SEED_BASE=1`:

| test | test-release | soak |
|---|---|---|
| `randomProgramsAgreeWithTheirModel` | `randomSeedCount` 100 | 1000 |
| `randomProgramsAgreeWithTheirModelNatively` | `min(randomSeedCount, 100)` 100 | `min(1000, 100)` 100 |
| `randomProgramsAreDeterministic` | seeds 42 and 43, no count | the same |
| `randomProgramsResumeFromASnapshot` | 100 | 1000 |
| `randomProgramsResumeAcrossEngines` | `KAJO_NATIVE_SEEDS` or 40 | 40 |

Every count starts at `KAJO_SEED_BASE` or 1, so the soak's seeds include
test-release's in every configuration, and `randomPrograms` names exactly
these five functions in the package.

Built: `just test-release` adds `--skip randomPrograms`, its comment says
why, and `check-tier-test.sh` fails when any gate list (each tier's, the
weekly's) holds `test-release` without `soak` after it, or when the
justfile stops splitting the random programs by `--skip` and `--filter`.

### 5. The compilers' limit cases in parallel

`bothCompilersRefuseAtEveryEncodingLimit(_:)` takes an
`EncodingLimitCase` (name, source, whether the bootstrap accepts it): the
same eight plain and four under the sanitizer, each case making the two
assertions (the bootstrap accepts or refuses as listed; the two compilers
agree through a probe VM of its own) and printing `encoding limit <name>:
<s> s`. A parameterized test counts once. The premise was half right: the
cases are independent, but the two `selectors4094/4095` cases are nearly
all of the time, so in parallel the test takes about one of them (see
`$GS/limits-serial.txt` and `$GS/limits-parallel.txt`, plain, on
8651da1's form, which prints each case: one after another
(`--no-parallel`) 286.8 s for the test, keywordSend 1.6 and 0.2, copying
0.6 and 0.6, chain 4.6 and 2.5, selectors 138.2 and 138.3; side by side
147.5 s, every case slower from sharing the cores and the test as long as
its longest, selectors4095 at 147.5; the brief's 300.7 s for the serial
test is quoted). Their cost is the kernel
compiler's `BytecodeGenerator>>literalIndex:`, a linear search of the
literal frame per literal, so 4094 selectors are about 8.4 million
comparisons: a finding, not this module's.

### 6. The weekly run is the full set again

`scripts/weekly.sh`'s gates: `check-tier-test clean-build swift-test
swift-test-load tsan tsan-load ios-check arc-check golden native-golden
native-kernel-test native-cc test-release model-check soak fuzz apps
kernel-test new-check ab`, then `matrix-mac` and the attached devices
(`scripts/weekly.sh --gates` prints them and exits). The A/B's base is
`gl_weekly_ab_base`: the commit of the last weekly run whose `weekly
start` line has `quick=0` and a `weekly done` after it (a quick run tests
the plumbing, not a week's code); with none, or when it is HEAD,
`gl_skip` writes `skip ab: <why>` and `end ab rc=skip 0s` and the summary
shows `skipped` with the reason. On Sunday 2026-11-15 the base read from
`~/kajo-weekly/weekly.log` will be a024a90. The summary's table has a
note column (each fuzz target's runs and build, a skip's reason).

Found and fixed in the same script: the refusal names `swift-build` and
`swift-test`, but under swiftly `swift build` and `swift test` run as
`swift-package` and the tests in `swiftpm-testing-helper` (`ps`:
`swiftpm-testing-`), so at 10:18:36 a weekly started beside this module's
running suite instead of refusing (the morning's file is gone).
`swift-package` and `swiftpm-testing*` count now, and `check-tier-test.sh`
starts a compiled program named `swift-package` in a process group of its
own and expects the refusal naming it (a copy of `/bin/sleep` is killed
for its signature and a link keeps the name `sleep`).

### 7. Plain `swift-test` out of the core tier

By the owner's decision: `check-tier.sh`'s core list and header,
`check-tier-test.sh`'s lists, and a pointer in `gate-tiers.md`'s As
built. The Swift tier and the weekly keep it.

### 8. The gate scripts' own test is a gate

`check-tier-test` (bound 900 s) runs first in the Swift and core tiers
when the diff touches `scripts/check-tier.sh`, `check-tier-test.sh`,
`gates-lib.sh`, `weekly.sh`, `fuzz.sh` or `fuzz-gate.sh`, and always in
the weekly. The script grew from 36 to 96 checks: the new lists (core
without `swift-test`, `fuzz` for the four, `check-tier-test` first for
each gate script and not for another script), the fuzz gate's targets per
tier, `test-release` followed by `soak` in every list and the justfile's
split, the weekly's list a superset of the core tier's with every
conditional gate (the device rows as `devices`) and plain `swift-test`,
the A/B base over made-up logs (finished, HEAD, quick, unfinished, empty),
the refusal beside a `swift-package`, and the fuzz gate with stand-ins for
`fuzz.sh`: four good targets pass with four `gates.log` lines, a failing
target fails it, one without "libFuzzer build: ok" fails it, and a gate
killed through `gl_cleanup` or by a TERM to its script alone leaves no
stand-in alive.

### The quick weekly run and the switches

The changed gates through the weekly script, on b09d8fc, under `env -i`
with exactly the LaunchAgent's environment (`$GS/weekly-quick/command.txt`
holds the command line: `HOME`, `USER`, `LOGNAME`, `SHELL`, `TMPDIR`, the
plist's `PATH` and swiftly variables, `KAJO_WEEKLY_QUICK=1
KAJO_WEEKLY_DEVICES=0 KAJO_WEEKLY_ROOT=$GS/weekly-quick
KAJO_WEEKLY_ONLY='check-tier-test native-golden native-kernel-test
native-cc test-release soak fuzz ab'`), with a copy of
`~/kajo-weekly/weekly.log` in the root so the A/B found its base (a024a90,
the 2026-11-08 run): 13:52 to 14:05, every gate passed
(`$GS/weekly-quick/2026-11-13-quick/gates.log` and `summary.md`):
check-tier-test 7 s, native-golden 141, native-kernel-test 47, native-cc
31, test-release 35 (444 + 162 tests, 11 cache hits), soak 65 (1000
interpreter seeds and 100 native per configuration, 655 hits and no
miss: the soak's 480 s were clang's), the fuzz gate 120 s with kasm
194 648, snapshot 302 741, syntax 57 159 (113 s: its kernel image is
built at the start) and protocol 158 511 runs in 60 s each, ab 322 s
against a024a90 (`ab/table.md`). The run did not log which base it used,
so the weekly now writes `ab base <commit>: the last finished weekly run's
commit (<weekly.log>)` (f9b9390; a run with nothing else,
`$GS/weekly-base/`, shows the line). The skip path:
`KAJO_WEEKLY_ONLY=ab` with an empty root (`$GS/weekly-skip/`) wrote `skip
ab: no base: ...` and the summary row `| ab | skipped | 0s | no base: ...
|` (that root was in the lost scratchpad; the A/B base test of
`check-tier-test.sh` covers the same rule).

One run of each new switch, in `$GS/switches/`: `kajo-test-list.txt`
(`--list` 249 tests listed; `--list --test A --test B` two `test.listed`
and `run.listed` total 2; `--test A --test B` two passed),
`native-cache-switch.txt` (`KAJO_NATIVE_CACHE=off` prints the off line and
compiles to a temporary; `=<dir>` 0 hits 1 miss, then 1 hit 0 misses;
the default 1 hit in `.build/native-test-cache`), `fuzz-sh.txt`
(`fuzz.sh protocol 5` both halves, `--build kasm` with its `build.txt`,
`--run kasm 5`), `weekly-gates.txt` (`weekly.sh --gates`),
`check-tier-test.txt` (96 checks, ok). The fuzz gate is run by the final
run; its broken variants by `check-tier-test.sh`.

Found by that check run: the refusal test's stand-in, compiled by the
swiftly `clang` on PATH, found `unistd.h` only when the calling
environment named the SDK (it passed in the morning and failed at 13:50);
it is built by Apple's `/usr/bin/clang` now (b09d8fc).

## Coverage

(Filled from the final run below.)

## The final gate run

(Pending.)

## Deviations

- The kernel's tests are divided by a table of measured sanitizer seconds
  for the 27 tests of 5 s or more (the brief allowed classes grouped by
  measured time); coverage never reads it.
- The every-method tests are not split (above).
- `drive`'s bounds in the compiler tests got a sanitizer value, a test
  change outside the brief's list, needed because the parts make the
  bundle busier.
- The weekly's refusal names swiftly's process names (a bug found, fixed
  in a script this module changes).
- `kajo test` gained `--test` and `--list` beside the kernel's.

## Not done

- The kernel compiler's quadratic `literalIndex:` (the two 140 s limit
  cases) is recorded, not fixed.
- `TonelRoundTripTests` (a serialized suite of 594 s under the sanitizer)
  now bounds the compiler bundle with the every-method parts; not touched.

## Open questions

1. Split the every-method kernel tests into slices (by a hash of
   `Class>>selector`) to take about 100 s off each sanitizer gate, at the
   price of eight new test ids? Recommended: not now; the bundle's other
   floors are within that.
2. The cache's bound, 2 GiB with an hour's protection: keep? Recommended:
   keep.
3. The weekly's A/B base, the last finished non-quick weekly run's commit:
   keep? Recommended: keep (Sunday's run reads a024a90).
4. Fix the kernel compiler's `literalIndex:` (a dictionary beside the
   frame) as a follow-up? Recommended: yes, small, and the selectors
   limit cases would drop from 140 s to seconds.
