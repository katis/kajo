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
  and splits them into 2 parts (5 at first; see "The reconnect test"):
  heaviest first, each to the lightest part, weighed by the sanitizer seconds above for the 27 tests of 5 s or
  more there, 0.32 s for any other test and 150 s for an unknown one
  tagged `<slow>`. The table decides the balance only: a new or renamed
  test is in a part all the same. Five parts (the three long tests one
  each, the other 246 in two of about 474 sanitizer seconds) would have
  made the longest part the longest test, but the measurement below put
  the count at two parts of about 1460 sanitizer seconds each;
  `KAJO_KERNEL_TEST_PARTS=<n>` overrides it.
- `KernelTestPartsTests.theKernelsTestsPassAndTheEventsAreTheProtocol(_:)`
  is the old test as one case per part in a suite without `.serialized`,
  so they run at the same time; each is a whole run by the event protocol over
  its part with every assertion the old test made (exit 0, all passed, one
  JSON object a line, the kinds a subset of the v1 kinds and the required
  ones present, `gc` among them since every run ends with the gc summary,
  `v == 1`, `ts`, `run.started` first, `started == total`, the test events'
  times sorted), plus that it ran exactly its part's names, each once.
  `total > 100` became `total == names.count` per part; the union's count
  is asserted by the next test. Each case prints `kernel test part i/n
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
`clang` first on PATH, did not find `unistd.h` at 13:50 where it had
passed in the morning. The cause was the session's environment, not
swiftly: after the agent's session was restarted its PATH put Homebrew's
LLVM (`/opt/homebrew/opt/llvm/bin/clang`, which knows no SDK) before
`~/.swiftly/bin` (the commit message of b09d8fc blames swiftly's clang;
that is wrong). The stand-in is built by Apple's `/usr/bin/clang` now
(b09d8fc), which finds the SDK by itself. The same PATH failed the first
final run's three native gates (below).

### The final runs that failed, and why

Three runs of `just check --tier core 3cf22fe` failed before the one
recorded under "The final gate run":

1. On f9b9390 at 14:07 (`$GS/check-run1/`): every gate that ran passed
   but `native-golden`, `native-kernel-test` and `native-cc`, which failed
   at the link (`ld: library 'System' not found`): the restarted agent
   session's PATH put Homebrew's LLVM first. Stopped during `ab`; every
   later run sets swiftly first (`env.txt` in each run's directory).
2. On ba7d92c at 17:23 (`$GS/check-run2/`, 10 157 s): every gate passed
   but `tsan` and `tsan-load`, each on
   `PhoneTransportTests.theToolsReconnectAfterADroppedLink`. 94ea552 then
   gave the tools tests' 60 s `until` five times longer under the
   sanitizer, which was the wrong answer (see below; reverted in e49f340).
3. On 94ea552 at 20:22 (`$GS/check-run3/`): `swift-test-load` failed on
   `AllocationStallTests.aStalledProcessTakesAnInterrupt` and `tsan` on the
   reconnect test again (after 345 s), and the run was stopped.

#### The reconnect test

`ToolsProbe class>>remoteState` (e49f340) prints the remote client for the
failure message. Three runs of the compiler bundle alone under the
sanitizer on e49f340 with five parts (`$GS/reconnect/bundle-{1,2,3}.txt`)
failed all three, and said:

| run | remote state | reconnects | requests sent again | outage (loss to new session) | answered |
|---|---|--:|--:|--:|---|
| 1 | open | 1 | 2 | 24.3 s | the process list, not the hierarchy |
| 2 | open | 1 | 0 | 31.7 s | neither |
| 3 | still reconnecting after 60 s | 0 | 0 | none | neither, both still pending |

A request's 30 s timeout counts from its first send and is not re-armed
when it is sent again, so an outage near 30 s fails it; and in run 3 not
even the 1 s backoff timer had fired in a minute. Both timers are
`ClientHost`'s `DispatchQueue.global().asyncAfter` events, so the timers
themselves were late: the bundle with five kernel VMs running beside it
starves the global queue's work. Alone under the sanitizer the test passes
in 94 s (`$GS/reconnect/swiftly-{1,2}.txt`, `brew-1.txt`). The number of
parts is the lever (`$GS/reconnect/summary-parts.txt`, the compiler bundle
under the sanitizer with `KAJO_KERNEL_TEST_PARTS`):

| parts | runs | the reconnect test failed | compiler bundle s |
|--:|--:|--:|--:|
| 5 | 8 (the three final runs' two sanitizer gates, three bundle runs) | 6 | 1033 to 1162 |
| 3 | 2 | 1 (outage 21.3 s, the hierarchy request timed out) | 1427, 1439 |
| 2 | 1 | 0 | 1837 |
| 1 | 1 | 0 | 3149 |

Built: two parts (228c62f). The race itself, a request's timeout counting
from its first send across a reconnect, is the tools' and is an open
question.

#### `aStalledProcessTakesAnInterrupt`

Counted under twelve busy loops (`$GS/stall/`):

| what | runs | failed |
|---|--:|--:|
| that one test filtered, head (e49f340's VM tests) | 5 | 0 |
| that one test filtered, `git archive 3cf22fe` | 5 | 0 |
| the VM bundle, head with the cache (`vm-head-1`, `-2`, `vm-on-3` to `-7`) | 7 | 1 (`aSaveWaitsForAStallAndItsImageLoads`, `vm-head-1.txt`) |
| the VM bundle, head with `KAJO_NATIVE_CACHE=off` | 2 | 0 |
| the VM bundle, 3cf22fe | 3 | 0 |
| `swift-test-load` of the three final runs | 3 | 1 (`aStalledProcessTakesAnInterrupt`, run 3) |

Both failures are allocation-stall tests that wait for a stall to end
under a marker slowed 16 times (`markerSlowdown`), each past its 120 s
bound. They never failed filtered, nor on 3cf22fe, nor with the cache off,
but 2 failures in 10 loaded runs against 0 in 5 is not a cause. The one
thing of this diff that reaches the VM bundle is the native cache: with it
the bundle runs in about 750 s instead of 1100 under load, so the native
random programs' VMs (up to 8 workers each, no longer waiting on clang)
overlap the slowed-marker tests more densely. Recorded as found, for the
main session; nothing under `Sources/KajoVM` and no bound was changed.

The fourth final run failed `swift-test-load` on the same test (638 s),
so the gates' count is 2 of 4. Six more loaded VM-bundle runs on 228c62f
with the cache, meant to stop at the first stall failure and sample the
test process once a minute (`$GS/tools/stall-sample.sh`,
`$GS/stall/sampled-{1..6}.txt`, `summary-sampled.txt`), all passed, so
with the cache the loaded bundle failed a stall test in 3 of 17 runs
(gates 2 of 4, the filtered runs 1 of 13) against 0 of 3 on 3cf22fe and
0 of 2 with the cache off. No thread samples exist: `sample` refuses the
test process ("cannot examine process ... try running with sudo", the
helper is not debuggable without root), and `sudo` is not this agent's.

## The final gate run

The fourth run, `KAJO_CHECK_OUT=$GS/check scripts/check-tier.sh --tier
core 3cf22fe` with swiftly first on PATH (`$GS/check/env.txt`), on
bf47868, whose code is 228c62f's (the commits above it are this doc):
05:20 to 08:36 on 2026-11-14, 11 758 s, every gate passing but
`swift-test-load` (`$GS/check/gates.log`). The baseline is the stalls
run's per-gate seconds as the brief records them (quoted; that run's
files are gone):

| gate | before (a18696a, quoted) | after (bf47868) |
|---|--:|--:|
| check-tier-test | not a gate | 6 |
| clean-build | 23 | 19 |
| swift-test | 1329 | not in the core tier |
| swift-test-load | 1447 | 958 (failed, below) |
| tsan | 4677 | 3063 |
| tsan-load | 5889 | 4258 |
| ios-check | 17 | 16 |
| arc-check | 47 | 6 |
| golden | 73 | 72 |
| native-golden | 99 | 99 |
| native-kernel-test | 46 | 47 |
| native-cc | 30 | 30 |
| test-release | 591 | 62 |
| model-check | 22 | 21 |
| soak | 480 | 66 |
| fuzz-kasm, -snapshot, -syntax, -protocol | 642 + 604 + 604 + 604 | one gate, 608 |
| apps | 123 | 124 |
| kernel-test | 108 | 108 |
| new-check | 254 | 253 |
| ab | 331 | 326 |
| matrix-mac | 776 | 772 |
| matrix-iphone | 843 | 844 |
| total | 19 659 | 11 758 |

`swift-test-load` failed on
`AllocationStallTests.aStalledProcessTakesAnInterrupt` (the test ran 638
s; its 120 s wait for the interrupts ran out), as in the third run; the
main session took that test over (see its heading above), and every other
gate's result is from this run. ThreadSanitizer: 0 reports in `tsan` and
`tsan-load`. `arc-check` at 6 s is a warm release build of the same
scratch path. The aligned A/B against 3cf22fe (`$GS/check/ab/table.md`),
with no VM source changed: 0.991 to 1.010 at 1 worker and 0.963 to 1.027
at 8 (the usual 8-worker spread). The matrices' bars
(`$GS/check/matrix-mac.txt`, `matrix-iphone.txt`): no launch failed, no
checksum off, 0 fallbacks; the Mac's frames missed only in the three hog
rows with the budget off (by design), 706 stalls (longest 21.36 ms); the
iPhone's in the hog rows and the ring under `young=stw` (2, 5 and 7 frames
behind scavenges of 15.6 to 18.3 ms), as in earlier modules.

## Coverage

From the gates' own files; "before" is the brief's baseline where its
files are gone, said so.

| gate | before | after (`$GS/check/`) |
|---|---|---|
| swift-test-load | 444 + 161 tests (the stalls run; 445 since 40ce930's StopsByKindTests) | 449 + 162: +4 `NativeCacheTests`, +1 `theKernelTestPartsAreExactlyTheUnfilteredRun`; the kernel test is one parameterized test as before, the limit test one parameterized test as before; 1 failed (above) |
| tsan | 444 + 161 | 449 + 162, all passed, 0 reports |
| tsan-load | 444 + 161 | 449 + 162, all passed, 0 reports |
| test-release | 444 + 161 with the random programs | 444 + 162: the five `randomPrograms*` skipped (449 - 5), no `random programs` line in the file |
| soak | 5 tests | 5 tests, 64 s, `$GS/seeds-table.md`: 1000 seeds in each of 28 interpreter configurations and both snapshot modes' 1000 per mode, 100 in each of 23 native configurations, 40 in each of 12 across-engines cases, all from 1 |

Kernel test ids, compared by `$GS/tools/compare-ids.py` against the
starting commit's unfiltered runs: `$GS/before-kernel-plain.ndjson` (plain)
against `$GS/check/swift-test-load.txt`, and `$GS/before-kernel-tsan.ndjson`
(sanitizer) against `$GS/check/tsan.txt` and `tsan-load.txt`: 249 ids
each, each once, all passed, the same set, in every comparison. The parts
in this run: 134 and 115 tests (79.6 and 87.4 s plain, 1475 and 1725 s
under the sanitizer, 1938 and 2231 s under load).

Seeds: test-release ran 100 per interpreter configuration and 100 per
native one, 40 across engines (the rule table above; the 2026-11-08
weekly's `test-release.txt` on a024a90 shows the 100s for the
configurations of that time); the soak runs each of them with at least as
many from the same base (`$GS/seeds-table.md`, the soak column of this run).

Fuzz runs in 600 s, side by side, against the last three sequential runs
(quoted above): kasm 2 059 697 (0.94 of the stalls run's 2 196 708),
snapshot 3 316 649 (0.98), syntax 793 865 (0.93), protocol 1 764 906
(0.95), each with "libFuzzer build: ok". No target fell below 0.8, so no
time was raised.

Native test modules: this run's suites compiled nothing (the cache was
warm from the earlier runs): `swift-test-load` 571 hits, `tsan` 71,
`tsan-load` 67, `test-release` 11, `soak` 627, 0 misses and 0 replaced
each. A cold run is the first final run's (`$GS/check-run1/`):
`swift-test-load` 944 hits and 569 misses (one compile per key: the
first cold suite without the lock per key compiled 1335), `tsan` 23 hits
and 65 misses, and `tsan-load` 67 hits.

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

- No final run passed every gate: the fourth, on this module's final
  code, failed `swift-test-load` on `aStalledProcessTakesAnInterrupt`
  (recorded as found; the main session took it over). Its other gates
  are the record. The gates the diff's own tiers owe beyond the core tier
  ran after it on 6f45187 (code as 228c62f) into `$GS/check-extra/`
  (`gates.log`): the Smalltalk tier forced (`build-image`, `dev-image`,
  `kernel-test`, `tools-test`, `compiler-tests`, `golden`,
  `mac-shell-tests`) and plain `swift-test`, every one passing.
- The quick weekly run's skip path was in the lost scratchpad; the A/B
  base rule is covered by `check-tier-test.sh`.

- The kernel compiler's quadratic `literalIndex:` (the two 140 s limit
  cases) is recorded, not fixed.
- `TonelRoundTripTests` (a serialized suite of 594 s under the sanitizer)
  now bounds the compiler bundle with the every-method parts; not touched.
- Found, not this module's: `scripts/native-check.sh` and
  `NativeTest.clang` take the first `clang` on PATH; with Homebrew's LLVM
  first (as in this session after its restart) `native-golden`,
  `native-kernel-test` and `native-cc` fail at the link (`ld: library
  'System' not found`), while the suites' native tests pass because
  `swift test` hands its helper the SDK. The weekly's plist puts swiftly
  first, so Sunday's run is not affected; whether the scripts should ask
  `xcrun` for the SDK is the owner's call.

## Open questions

1. The tools' request timeout across a reconnect: `DevClient` arms a
   request's 30 s timeout at its first send and does not re-arm it when
   the request is sent again on the new session, so an outage near 30 s
   fails a request the reconnect was about to answer (the reconnect
   test's failures above, outages of 21 to 32 s under the sanitizer with
   five kernel parts beside it). Re-arm the timeout when a request is
   sent again (a `tools/` change and its test)? Recommended: yes, as a
   follow-up; with two parts the test passed in every run since.
2. Two kernel parts leave the compiler bundle under the sanitizer at about
   1840 s (1060 at five, 3300 before). Keep two, or make the bundle's
   timers independent of its load (the global-queue timers of
   `ClientHost`) and go back to five? Recommended: keep two until 1 is
   built, then measure five again.
3. The cache's bound, 2 GiB with an hour's protection: keep? Recommended:
   keep.
4. The weekly's A/B base, the last finished non-quick weekly run's commit:
   keep? Recommended: keep (Sunday's run reads a024a90).
5. Split the every-method kernel tests into slices? With two parts each
   part holds one of them and the long chain, so slicing no longer
   shortens the longest part much. Recommended: no.
6. Fix the kernel compiler's `literalIndex:` (a dictionary beside the
   frame) as a follow-up? Recommended: yes, small, and the selectors
   limit cases would drop from 140 s to seconds.

## The agreed follow-ups (2026-11-15)

The owner agreed on 2026-11-15 to open questions 1 and 6 as recommended.
Both are built on top of 7ec1bca; `$GF` is
`~/kajo-scratch/gate-speed-followup/`. Toolchain: swiftly's 6.4.2 first
on PATH (as `$GF/check/env.txt` records for the gate run).

### 1. The tools' request timeout across a reconnect (06e0d08)

`DevClient` armed a request's 30 s timeout at its first send and never
again, so a request sent again on a new session after a dropped link had
whatever was left of the first send's 30 s, the outage included (the
reconnect test's failures above, outages of 21 to 32 s). Built:

- The timeout counts from the request's latest send. `reopened` cancels
  the timer armed at the earlier send and arms a new one
  (`armTimeoutFor:`) as it sends the request again. While the link is
  down the earlier send's timer keeps running, so an outage still counts
  against the send before it: a request waiting through an outage longer
  than its timeout fails then, as before, and the client goes on
  reconnecting.
- A request is sent at most `DevClient class>>sendLimit` times (4, its
  first send included). At the next new session after its fourth send it
  fails ("got no reply in 4 sends across dropped links: not sent again")
  instead of being sent a fifth time. So a request that is never answered
  ends in every case: its timer fires within 30 s of a send unless a
  reconnect re-arms it, a reconnect re-arms it at most three times, and
  `close` or a refused session ends it at once as before. Without the
  limit a link that dropped every 20 s would have kept such a request
  alive for as long as the link flapped.
- The requests' timers go through `requestTimerAfter:do:` and
  `cancelRequestTimer:` (`UIEventLoop` in the product), which
  `FakeDevClient` overrides to record (`requestTimers`,
  `fireRequestTimer:`), so a test fires a timeout without waiting for one.
  The reconnect timers stay on `after:do:` and `cancelTimer:`, and the
  existing tests' assertions on them are unchanged.

Tests (`tools/Tests/DevClientTest.class.st`):
`testARequestSentAgainHasItsTimeoutReArmed` (the first send's timer is
still armed through the outage; after the reconnect exactly one timer is
armed for the request and it is not the first one; the reply lands; the
re-armed timer fails an unanswered request), `testARequestTimesOutDuringAnOutage`
and `testARequestNeverAnsweredEndsAfterItsSendLimit`. No clock is read:
every timer is fired by the test. With the new test and fake files over
7ec1bca's `DevClient` (`$GF/item1/devclient-7ec1bca.txt`) all three fail:
the re-arm test with "Expected 1 but was 0" (the old client arms its
timeouts on `UIEventLoop` directly and never again, so no request timer
exists to re-arm; headless, where `UIEventLoop after:do:` answers nil
without a host, the old client's requests had no timeout at all), the
outage test on the missing timer and the limit test on the missing
`sendLimit`. On 06e0d08: 16 of 16 (`$GF/item1/devclient-head.txt`).
`canonical-tonel.sh --check` first listed the three edited files
(`$GF/item1/canonical-check.txt`); `canonical-tonel.sh` rewrote them into
the image's method order before the commit, and the check after items 1
and 2 printed nothing and exited 0 (`$GF/item2/canonical-check.txt`).

### 2. The kernel compiler's `literalIndex:` (5bfbb7b)

Measured first, a debug build, the limit test one case after another
(`swift test --filter bothCompilersRefuseAtEveryEncodingLimit
--no-parallel`, `$GF/item2/limits-serial-before.txt`): keywordSend 1.6 and
0.2 s, copying 0.6 and 0.6, chain 4.5 and 2.5, selectors4094 137.4 and
selectors4095 138.2, 285.6 s in all. The two selectors cases are a method
of 4094 (4095) unary sends to distinct selectors; the kernel compiler's
`BytecodeGenerator>>literalIndex:` searched the whole literal frame with
`literal:sameAs:` for each literal, 4094 x 4095 / 2, about 8.4 million
calls of a method of several sends each. Where the time is was read off
the fix: replacing only the search took the cases from 137.4 and 138.2 s
to 4.9 and 4.8 s (the first build, `$GF/item2/` before the threshold), so
about 133 s of each was the search and what remains is the bootstrap's
compile and the probe VM's.

Built: past 32 literals the generator keeps buckets of literal indices by
`BytecodeGenerator class>>literalKey:` (the literal's class with its
value, an Array's size, a Float's spelling, a method or pragma by class
alone), built once from the frame in its order when the frame passes 32;
within a bucket `literal:sameAs:` still decides. Every pair that
`literal:sameAs:` calls the same has the same key (same class; Arrays of
one size; Floats of one spelling; otherwise `=`, whose `hash` agrees for
every literal class the compiler makes: SmallInteger, the LargeIntegers,
Float, Character, String, Symbol, ByteArray, Array, Binding by identity),
and a bucket holds indices in frame order, so the answer is the index the
whole search found and no method's bytes change. Up to 32 literals the
frame is searched whole as before: a first build with buckets for every
frame made the long chain test (one literal, 120 000 sends) 19.9 to 23.3 s,
the bucket's key and hash costing more than one comparison.

After (`$GF/item2/limits-serial-after.txt`): keywordSend 1.6 and 0.2 s,
copying 0.6 and 0.6, chain 4.6 and 2.5, selectors 5.0 and 4.8, 20.0 s in
all against 285.6. Side by side, as the suite runs it, the test is as long
as its longest case, about 5 s against 147.5. Unchanged: the kernel's
`CompilerTest` 9 of 9, `testEveryMethodCompilesAsTheBootstrapDid` 23.5 s
against 23.5 and `testALongChainIsWalkedByALoop` 20.1 against 19.9
(`$GF/item2/compilertest-before.txt`, `compilertest-after.txt`; the
before run is 7ec1bca's kernel built by `git archive`), the compilers'
corpus test passes (`corpus-after.txt`), and `canonical-tonel.sh --check`
passes (`canonical-check.txt`). Under ThreadSanitizer the limit test runs
only the four small cases and gains nothing; the gates' gains are below.

### Three kernel-test parts, measured again

Open question 2's measurement, recorded as a number and nothing changed
(the kernel's tests stay at two parts): the compiler bundle under the
sanitizer with the twelve loops and `KAJO_KERNEL_TEST_PARTS=3`, on 723b3fe
with item 1 built (`KAJO_KERNEL_TEST_PARTS=3 swift test --sanitize=thread
--scratch-path .build/tsan-check --filter KajoCompilerTests` under
`$GF/tools/loaded.sh`, `$GF/parts3/out.txt`): one run, 162 of 162 passed
in 1905 s, `theToolsReconnectAfterADroppedLink` among them in 105.7 s.
Gate speed's own runs at three parts failed that test once in two (1427
and 1439 s, unloaded) and two parts under load took 2380 s. One run is not
a rate; it says three parts can pass the reconnect test under load now.

### The gates of the follow-ups

On 723b3fe, the final code commit (the commits above it are docs), with
swiftly's 6.4.2 first on PATH (each `gates.log` line names it; the driver
is `$GF/tools/gates.sh`). Nothing under `Sources/` changed, so no `unsafe`
line was added. Every gate passed:

| gate | s | before (s, where) | tests |
|---|--:|---|---|
| Swift tier (`$GF/check/gates.log`) | 3959 | | |
| clean-build | 20 | 19 (b478aaf, `symbol-interning/check`) | |
| swift-test | 731 | 839 (6fc183e, `gate-speed/check-extra`) | 456 + 162 passed |
| tsan | 2725 | 2969 (c98d981, `symbol-interning/check2`) | 456 + 162 passed, 0 reports |
| kernel-test | 106 | 107 (b478aaf) | 249 of 249 |
| apps | 125 | 129 (b478aaf) | |
| new-check | 252 | 253 (b478aaf) | |
| Smalltalk tier forced (`$GF/check-st/gates.log`) | 405 | | |
| build-image, dev-image | 3, 2 | 4, 2 (6f45187, `gate-speed/check-extra`) | |
| kernel-test | 105 | 104 | 249 of 249 |
| tools-test | 119 | 120 | 295 of 295 (292 + the three new) |
| compiler-tests | 71 | 154 | 162 passed |
| golden | 72 | 72 | |
| mac-shell-tests | 33 | 34 | 249 of 249 |
| tsan-load, `gates-lib.sh`'s own definition (`$GF/check-tsanload/gates.log`) | 3777 | 3934 (c98d981) | 456 + 162 passed, 0 reports |

What the changes bought, from the gates' own files: the compiler bundle
in plain `swift test` took 68.3 s against 159.3 (6fc183e) and the
Smalltalk tier's `compiler-tests` 71 against 154 s, the limit test no
longer waiting 147 s for the selectors cases; under the sanitizer the
limit test runs only its small cases, so the compiler bundle is as long
as before (1792 s in `tsan` against 1796, 2298 in `tsan-load` against
2304), bounded by the kernel's tests in two parts. The VM bundle under the
sanitizer took 922 s in `tsan` against 1154 and 1463 in `tsan-load`
against 1614, the full-heap test no longer its longest (bodies 565.1 and
559.8 s against 691.9 and 1059.7; allocation-stalls.md's section has the
rest). The three new tools tests take milliseconds.

### Deviations, not done, open questions (the follow-ups)

- Deviation: item 1 adds a send limit (four sends) beside the re-arm, so
  that a request never answered ends even on a link that keeps dropping
  within its timeout; the brief asked only for the re-arm and that such a
  request must still end.
- Deviation: item 2 keeps the whole-frame search up to 32 literals; the
  buckets alone made the long chain test 17 percent slower in the first
  build.
- Not done: the limit test still runs only its four small cases under
  ThreadSanitizer; the selectors cases would now take seconds there too,
  but the chain cases (a method of 32 760 bytes) were not measured under
  the sanitizer and the split was left as it is.
- Not done: the kernel's tests stay at two parts (the brief's rule); the
  three-parts run above is one run.
- Open question: four sends as the limit? Recommended: keep; with the
  backoff (1, 2, 4 s) and a 30 s timeout per send it bounds a request at
  about two minutes of a flapping link.
- Open question: go back to three or five kernel parts now that a resent
  request has its full timeout? Recommended: measure five parts in a few
  loaded sanitizer runs before changing anything; one run at three
  passed.
