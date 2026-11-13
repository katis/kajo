# Gate speed

Status: briefed 2026-11-13, from the owner's request of the same day
("figure out if we can optimize all these tests and checks, they're
getting really long. Anything overlapping?") and the owner's acceptance of
the investigation's proposals ("all sounds good, accepted"). Not built.

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
