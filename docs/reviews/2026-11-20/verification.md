# The third review (2026-11-20): verification

Area: the verification machinery itself. `Tests/`, `scripts/`, the
`justfile`, `models/`, the fuzz drivers. Read only; nothing was built or
run. Every number below is from an existing output and names its file.
`$S` is `~/kajo-scratch`.

The three gate logs the numbers come from:

- Swift tier, ec0a6ef, 4740 s: `$S/test-waits/check/` (`gates.log`,
  `swift-test.txt`, `tsan.txt`).
- Smalltalk tier, cf36665, 534 s: `$S/types-3/check/smalltalk/`.
- Core tier, 075d2a4, 11 835 s: `$S/delay-outlives-vm/check/`.

## The findings, in the order I would do them

| id | one line | expected gain |
|---|---|---|
| verification.M1 | The gates run an interpreter no product ships (`-Onone`) | 55 to 65 % of the Swift tier, 40 to 50 % of the core tier |
| verification.A1 | "Checked build" is three defaults; `Headless` turns one off | the precondition of M1; one meaning of "checked" |
| verification.M2 | The two test bundles run in series | 400 to 900 s per sanitizer gate |
| verification.M3 | Two kernel-test parts; weights kept by hand | up to 1000 s per sanitizer gate, after M2 |
| verification.M4 | Stall tests run two VMs in series per body and spin a core | 300 to 500 s of the sanitized VM bundle, after M2 and M3 |
| verification.M5 | The kernel's 258 tests run four times in the Smalltalk tier | 150 to 250 s of 534 |
| verification.M6 | Builds repeated across gates (`new-check`'s checkout, `arc-check`, the A/B base) | 150 to 300 s of a core run |
| verification.A2 | No gate output says which test took the time | makes the next gate-speed module a script |
| verification.R1 | Wait loops written per file; the bound `600 : 120` 35 times | one rule in one place |
| verification.R2 | No shared test support: two sanitizer probes, three fake view hosts | a change to the view protocol touches one fake |
| verification.R3 | The gate lists live in four places | a new gate is one line |
| verification.R4 | Broken variants: 73 switches, 3 named by no test, hand runs in docs only | "a switch nobody ran" becomes a failing test |
| verification.R5 | `RandomConfig` is one enum and seven lists and switches | a configuration without a verifier is visible |
| verification.R6 | One row format, eight parsers | a field rule changed once |
| verification.R7 | The golden table four times; device constants four times | a kernel added once |
| verification.R8 | 47 kernel image builds in the compiler bundle | CPU only, about 30 builds |
| verification.A3 | The weekly's refusal is a list of process names | no window in which a weekly starts beside a gate |

## Where the gate time goes

| tier | total s | the sanitizer gates | debug `swift test` | all other gates |
|---|--:|--:|--:|--:|
| Swift (ec0a6ef) | 4740 | 3490 (74 %) | 714 | 536 |
| core (075d2a4) | 11 835 | 3015 + 4128 (60 %) | 830 (loaded) | 3862 |
| Smalltalk (cf36665) | 534 | none | 81 (`compiler-tests`) | 453 |

Three facts explain most of it.

1. **The gates run the interpreter at `-Onone`.** The same 255 to 258
   kernel tests on 075d2a4, test-seconds summed over the two parts:

   | build | part 1 | part 2 | against release |
   |---|--:|--:|--:|
   | release (`test-release.txt`) | 4.4 | 2.5 | 1 |
   | debug, loaded (`swift-test-load.txt`) | 92.9 | 98.6 | 28 |
   | debug + sanitizer (`tsan.txt`) | 1871 | 2047 | 568 |
   | debug + sanitizer, loaded (`tsan-load.txt`) | 2470 | 2667 | 744 |

   The sanitizer does not multiply the VM. It multiplies the unoptimized
   VM: about 25 times on top of about 23 (unloaded debug on ec0a6ef is
   77.1 + 82.0 s). The whole VM bundle without the random programs takes
   8.8 s in release, and `soak` runs 1000 seeds in every configuration
   in 61.7 s (`soak.txt`). The debug VM bundle takes 619 s and its long
   pole is the random programs at 100 seeds (354.6 s for one snapshot
   mode's 100 seeds, `swift-test.txt`). No shipped product holds the
   `-Onone` VM: apps link the prebuilt Release frameworks
   (`Package.swift:20-23`).

2. **The suite is CPU-bound, three to four threads per core.** The
   stall tests print the load average: 26 to 38 through the sanitized VM
   bundle and 42 to 45 through the plain one, on 12 cores
   (`stall-diag ... load=` in `tsan.txt` and `swift-test.txt`). So
   running things side by side only helps where cores are idle.

3. **Cores are idle in one place.** Under the sanitizer the compiler
   bundle is two serial threads (the kernel tests in two parts, 1906 and
   2057 s in `$S/test-waits/check/tsan.txt`) for about 2000 s after
   everything else in it has ended. It starts only when the VM bundle
   (1312 s there, 860 s on 075d2a4) has finished: the two bundles are two
   test runs, one after the other (`swift-test.txt:2311-2313`).

Inside the sanitized kernel parts three tests are 2517 of 3963 s:
`LiveCompileTest>>testEveryMethodMakesAsInstalled` 854,
`CompilerTest>>testALongChainIsWalkedByALoop` 834,
`CompilerTest>>testEveryMethodCompilesAsTheBootstrapDid` 829
(`tsan.txt`, the `kernel test part` lines). Inside the sanitized VM
bundle the fifteen allocation-stall bodies sum to 5190 s
(`stall-diag body` lines), the longest
`aFullHeapFallsBackJustifiedThenRunsOutOfMemory` at 997.6 s.

## The five changes that cut the most gate time

None removes a test, a seed, a verifier or a fuzz second. The first
changes the build mode the checks run in and is the owner's call.

| # | change | finding | evidence | expected |
|---|---|---|---|---|
| 1 | The test gates and `kajo test` gates on a checked optimized build (`-O`, `DEBUG` defined, assertions kept) | M1 | kernel tests 6.9 s release, 191 s debug, 3918 s sanitized | Swift tier 4740 to about 1500 to 2100 s; core 11 835 to about 5500 to 6800 s |
| 2 | The two test bundles at the same time | M2 | 860 + 2139 s in series, ten cores idle for 2000 s | 400 to 900 s per sanitizer gate |
| 3 | The kernel tests in more than two parts, weighed from the last run, the every-method tests sliced | M3 | parts of 1906 and 2057 s; three tests are 2517 s | compiler bundle 2160 to about 900 to 1300 s under the sanitizer |
| 4 | The stall tests: two runs per body as two cases; the slowed marker waits instead of spinning | M4 | bodies 998, 766, 763 s, each two runs in series | VM bundle 1312 to about 800 to 1000 s under the sanitizer |
| 5 | The kernel's tests once per mode in the Smalltalk tier; the checkout's prebuilt parts cached | M5, M6 | 148 of `tools-test`'s 157 s repeat `kernel-test`; 164 of `new-check`'s 267 s is the checkout | 150 to 250 s of 534; 100 to 160 s of each Swift and core run |

2, 3 and 4 only pay together: with 2 alone the gate is as long as the
kernel parts, with 3 alone as long as both bundles in series. With 1
built, 2 to 4 are worth a fifth of what they are worth now.

---

## verification.M1: the gates run an interpreter no product ships

**Where**: `scripts/gates-lib.sh:45-48` (`swift-test`, `swift-test-load`,
`tsan`, `tsan-load`), `:66-70` (`kernel-test`, `build-image`, `dev-image`,
`tools-test`, all `swift run kajo`), `:71` (`compiler-tests`);
`justfile:82-83`.

**What is there now.** Every test gate but `test-release` and `soak`
builds for debugging:

```
swift-test)      spec_cmd="swift test" ;;
tsan)            spec_cmd="swift test --sanitize=thread --scratch-path .build/tsan-check"; spec_timeout=10800 ;;
kernel-test)     spec_cmd="just kernel-test" ;;      # swift run kajo test
```

The interpreter, the collectors and the verifiers are compiled `-Onone`
and, in two gates, instrumented by ThreadSanitizer on top.

**The cost.** Per bytecode. The table above: the kernel tests take 6.9 s
of test time in release, 159 to 191 s in debug and 3918 to 5137 s under
the sanitizer. The Mac shell's Release build runs the same 258 tests in
11.2 s against 117.0 s for `swift run kajo test`
(`$S/types-3/check/smalltalk/mac-tests-rows.txt`, `kernel-test.txt`).
At `-Onone` every register of the interpreter is a memory slot, so the
sanitizer instruments each bytecode's loads and stores; at `-O` most of
them are registers and are not instrumented. That is why the sanitizer
costs 25 times here. The debug suite, twice under the sanitizer and once
loaded, is 7973 s of the core tier's 11 835.

What the `-Onone` build adds over an optimized one is small and can be
kept (see A1): `checkedBuild` (three defaults), 19 `assert` calls
(`grep -rn 'assert(' Sources`), and the standard library's debug
preconditions (`unsafelyUnwrapped` and the unsafe buffer bounds). The
lesson "a check runs in the mode the product builds in" points the other
way: today the sanitizer never sees the optimized code, where the
compiler merges and hoists loads.

**The proposal.** One build configuration, "checked optimized":

```
swift test -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG \
    -Xswiftc -assert-config -Xswiftc Debug --scratch-path .build/checked
```

and the same with `--sanitize=thread --scratch-path .build/tsan-checked`.
`swift-test`, `swift-test-load`, `tsan`, `tsan-load`, `compiler-tests`
use it; `kernel-test`, `tools-test`, `build-image` and `dev-image` run
the `kajo` of that build. `test-release` stays as the unchecked release
run. The `-Onone` runs (`swift test`, `swift test --sanitize=thread`)
stay in the weekly run. Under the fast sanitizer the seed counts that
`underThreadSanitizer` cuts to 10 and 2 (`RandomPrograms.swift:705`,
`:880`, `:904`) can go back to 100 and 40, which is more coverage, not
less.

**How to bound it first.** Two runs, no code change:
(a) the first command above, and (b) the same with
`--sanitize=thread`, each once on the idle mini, into a scratch
directory. Read: wall time per bundle, the kernel parts' seconds, test
counts, sanitizer reports. Then the check that the sanitizer still sees
races at `-O`: run the hand-run variants that are races by construction
(`KAJO_BROKEN_DELAY_END=1`, with `TSAN_OPTIONS=abort_on_error=0`) under
(b) and read the report. If (b) is not at least three times shorter than
`tsan`, stop.

**After.** `gates.log` times against `$S/test-waits/check/gates.log`;
the kernel test ids compared as gate speed did (`compare-ids.py`).

**Risk and size.** Medium. Four tests size their work by `checkedBuild`
(`ProcessTests.swift:314`, `:687-688`, `SafepointTests.swift:30`, `:129`)
and assert that parallelism or a stop happened; a fast checked build
needs the large counts, so `checkedBuild` there becomes "slow build".
`KernelTests.swift:31` skips the golden kernels in a checked build; it
should not skip in a fast one. Stall tests and the reconnect test are
tuned to today's speeds (the lesson on a faster mutator and every
provisioning rule); expect one round of thin tests. A release build is
about 90 s against 20 (`test-release.txt`: "Build complete! (91,32
secs)"). Guarded by: the suite itself, `tsan` in the weekly at `-Onone`.
Owes the Swift tier (scripts) and `check-tier-test`. It is a change in
what a tier runs, so it is the owner's decision, as plain `swift-test`
leaving the core tier was.

**Confidence**: the measured ratios are read. The sanitizer's cost at
`-O` (I assume 5 to 15 times) is a guess until run (b) is made.

## verification.A1: "checked build" is three defaults, and `Headless` turns one off

**Where**: `Sources/KajoVM/ObjectMemory/Config.swift:6-10`, `:81-82`;
`Sources/KajoVM/Workers/VMConfig.swift:53`;
`Sources/KajoVM/Headless.swift:315`, `:328`;
`Tests/KajoVMTests/Processes/Runtime.swift:25`, `:34-35`.

**What is there now.** `checkedBuild` is `DEBUG`. It sets three
defaults: `ObjectMemoryConfig.verify`, `onVerifyFailure` and
`VMConfig.verifyStops`. `Headless.configs` then overwrites the first:

```swift
config.verify = options.verify      // Headless.Options.verify = false
config.onVerifyFailure = .trap
```

The test fixture goes the other way and turns the verifiers on in every
build (`vc.verifyStops = true  // ... in release builds too`,
`c.verify = verify`).

**The cost.** Three places know what "checked" means and they disagree.
`docs/VERIFICATION.md` layer 1 says a debug build runs every verifier at
every pause. For everything that goes through `Headless` (`kajo test`,
`kajo run`, the `kernel-test` and `tools-test` gates, `KernelTestParts`,
the shells) a debug build runs the heap verifiers at no pause unless
`--verify` is given. So the 3918 sanitized seconds of kernel tests buy,
over a release build, only the stop verifiers and `-Onone` itself. A
change that would touch all three: adding a verifier that must be on in
"checked" runs.

**The proposal.** One value, `VerificationLevel` (`off`, `stops`,
`all`), with one default per build and one place that applies it to
`ObjectMemoryConfig`, `VMConfig`, `YoungConfig.verify` and
`verifySymbols`. `Headless.Options`, `Runtime` and `ShellVM` take the
level. `kajo test` and `kajo run` print it on the run line
(`verify=all`), so a gate's output says what it checked. Decide, as the
owner, whether the kernel-test gates run at `all`: the unfiltered run
has 47 pauses (`kernel-test.txt`, the `gc` summary), so the cost is
small.

**How to bound it.** `kajo test --verify` once in the release build:
the added seconds over the plain release run.

**Risk and size.** Small. `Headless.swift` and the three config files
are outside the core directories except `ObjectMemory/Config.swift` and
`Workers/VMConfig.swift`, which make it a core-tier change; keeping the
defaults there and only adding the level in `Headless` keeps it in the
Swift tier. Guarded by `verifiersAreOneFlagAway` and
`verifiersRunAtEveryPauseWhenEnabled`.

**Confidence**: read.

## verification.M2: the two test bundles run in series

**Where**: `scripts/gates-lib.sh:45-48`; the outputs
`$S/test-waits/check/swift-test.txt:2311-2313`, `tsan.txt`.

**What is there now.** `swift test` runs `KajoVMTests` to its end and
then `KajoCompilerTests`:

```
✔ Test run with 471 tests in 0 suites passed after 1312.032 seconds.
◇ Test run started.
...
✔ Test run with 185 tests in 32 suites passed after 2161.954 seconds.
```

**The cost.** Per sanitizer gate. The compiler bundle's 2140 to 2830 s
is two CPU-bound threads for all but its first minutes; ten cores wait.
The VM bundle before it (860 to 1312 s; 1285 s loaded) saturates twelve.
On 075d2a4: `tsan` 860.6 + 2139.1 s, `tsan-load` 1284.5 + 2826.4 s.

**The proposal.** Build once (`swift build --build-tests` with the
gate's flags), then start `swift test --skip-build --filter
'^KajoVMTests\.'` and `--filter '^KajoCompilerTests\.'` together, each
into its own output file, and wait for both. The gate's result is both
statuses; `gates.log` gets a line per bundle as the fuzz gate has a line
per target (`gl_fuzz_lines`). Two SwiftPM processes on one scratch path
wait on its lock, so try `--ignore-lock` first, on two one-test filters.

**How to bound it.** The expected time is not the longer bundle. While
they overlap the two kernel parts are 2 runnable threads among about 35,
so they move at a fraction of a core. `tsan-load` gives the measured
case of twelve equal competitors: parts of 2470 and 2667 s against 1871
and 2047. I expect 2400 to 2700 s for `tsan` against 3015 to 3490. One
run of the two commands side by side under the sanitizer gives the
number and says whether the stall tests and the reconnect test hold;
then three loaded runs, as every dense-suite change has needed.

**Risk and size.** Small in the scripts (`gates-lib.sh`, one gate
script, `check-tier-test.sh`). The risk is the thin tests the lessons
list: more load on the VM bundle's stall tests and on
`theToolsReconnectAfterADroppedLink`. Both already pass under twelve
busy loops. Owes the Swift tier and `check-tier-test`.

**Confidence**: read for the serial order and the times; inferred for
the gain.

## verification.M3: two kernel-test parts, weighed by a table kept by hand

**Where**: `Tests/KajoCompilerTests/KernelImageTests.swift:82` (the
count), `:90-118` (`measuredSeconds`), `:120-135` (the split).

**What is there now.** The kernel's tests run as two VMs. The split
weighs 27 tests by sanitizer seconds measured once on 3cf22fe:

```swift
static let measuredSeconds: [String: Double] = [
    "LiveCompileTest>>testEveryMethodMakesAsInstalled": 697.9,
    ...
```

Any other test weighs 0.32 s, or 150 s when tagged `<slow>`.

**The cost.** Per sanitizer gate the compiler bundle is as long as its
longer part: 2057 s (`tsan.txt`). Three tests are 2517 s of the two
parts' 3963, so with two parts each part holds at least one of them and
400 to 1200 s of the rest. The table has drifted:
`TypeSyntaxTest>>testTypesCompileToNothing` takes 242 s under the
sanitizer and is not in it; `testARemovedClassStillNamedIsKept` is
listed at 95.8 and takes 26.5; the three long tests are listed at 585 to
698 and take 829 to 854. The parts are still within 8 percent of each
other, by luck of where the errors fell.

**The proposal.** Three steps, each a measurement first.

1. Weights from the last run. Each part already prints one line per
   test with its seconds. Write them to
   `.build/kernel-test-times/<plain|tsan>.json` at the part's end and
   read that file in `weight`; fall back to the committed table when
   there is none. A new slow test is balanced from the second run on.
2. The measurement the owner asked for (record 36): three and five
   parts over several loaded sanitizer runs, now that a resent request
   has its full timeout. With five parts the longest part is the longest
   test, about 860 s.
3. Only if 2 passes: slice the two every-method tests (gate speed's
   open question 5, answered "no" at two parts because slicing did not
   shorten the longest part then; at five parts it does). The chain
   test is one compile and cannot be sliced.

**How to bound it.** The numbers exist: the sum over the parts is
3963 s; five parts cannot beat 854 s (the longest test) and the bundle's
other tests need the first 600 s or so (`TonelRoundTripTests`, 594 s in
gate speed's record). So the bound is 2160 to about 900 to 1300 s.

**Risk and size.** Small for step 1 (test file only; the standing
assertion `theKernelTestPartsAreExactlyTheUnfilteredRun` already covers
any split). Step 2 is machine time: about an hour a run. Step 3 adds
kernel test ids and owes the Smalltalk tier. The known hazard is the
reconnect test under more VMs (`KernelImageTests.swift:72-81`).

**Confidence**: read.

## verification.M4: the stall tests run two VMs in series per body, and the slowed marker spins a core

**Where**: `Tests/KajoVMTests/Marking/AllocationStallTests.swift:213`
(`for young in ["stw", "offload"]`), `:241` and `:253` (relocation off,
then on), `:793` and `:795` (the entry gate, correct then broken),
`:741` and `:745`; `Sources/KajoVM/Marking/Marker.swift:218-237`
(`markerSlowdownSpin`).

**What is there now.** Three of the four longest bodies under the
sanitizer are two independent runs, one after the other:

```
stall-diag fullheap stw s=494.7 ...
stall-diag fullheap offload s=502.9 ...
stall-diag body aFullHeapFallsBackJustifiedThenRunsOutOfMemory s=997.6
stall-diag body fragmentationIsToldFromAFullHeap s=766.0
stall-diag body anEntryStallGateThatIgnoresTheTableFallsBackUnjustified s=762.8
```

And the marker's slowdown is a busy loop on the thread's CPU clock:

```swift
while clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) < end {
    for _ in 0..<256 { x = x &* 6364136223846793005 &+ 1442695040888963407 }
```

**The cost.** Per sanitizer gate. The VM bundle ends when
`aFullHeap...` ends (1312 s in `tsan.txt`; record 34 calls it "the
sanitized suite's length"). The fifteen stall bodies hold a thread of
the test pool for 5190 s in all. A marker slowed 16 or 64 times burns up
to a core for as long as it is slowed, on a machine at load 32; the
tests slowed for their whole run are 882 s
(`aSlowedMarkerPacesTheMutator`, four cases), 766 s, 763 s and 362 s of
body.

**The proposal.**

1. `aFullHeap...` takes the young mode as an argument, as
   `aRingLikeLoadStallsInsteadOfFallingBack` does. The fragmentation
   test and the entry-gate test run their two VMs on two `TestThread`s
   and assert after both joined. No assertion changes. The same shape as
   gate speed's change 5 (the compilers' limit cases in parallel).
2. The two "not done" items of record 36 stand:
   `aSlowedMarkerPacesTheMutator` and `fragmentationIsToldFromAFullHeap`
   slowed for their whole run.
3. Measure first: a slowdown that waits instead of spinning. Time the
   wall clock of the marker's work since its last poll (parked time
   excluded, as now) and sleep `N - 1` times that. Under load the work
   interval stretches and the sleep with it, so the ratio to the
   mutators holds, and no core burns. The counter `markerSlowSpins` and
   the tests that assert it stay.

**How to bound it.** For 1 the bound is the output above: 998 to about
500 s for the longest body. For 3: `slowSpinS` is already printed by
`StallDiag.full`; sum it over one sanitized run. That sum is the CPU the
change frees.

**Risk and size.** 1 is small (one test file; Swift tier). 3 changes a
test switch's code in `Marking/` and owes the core tier; do it with the
next core change. A sleeping marker is a timed wait, allowed only
because it is a test switch; say so at the wait. Guarded by the stall
tests' own assertions and the `slowedMarker` random configuration.

**Confidence**: read for 1. Inferred for 3 (I did not measure the
spinner's share).

## verification.M5: the kernel's 258 tests run four times in the Smalltalk tier

**Where**: `scripts/check-tier.sh:139` (the tier's gates),
`scripts/gates-lib.sh:66`, `:70-72`.

**What is there now.** The Smalltalk tier runs `kernel-test` (`swift run
kajo test`, 258 tests, 117.0 s of tests), `tools-test` (`kajo test
dev.img`, 351 tests, 157.3 s), `compiler-tests` (the whole compiler
bundle, where `KernelTestParts` runs the 258 again, 77 + 82 s) and
`mac-shell-tests` (the 258 in the Release shell, 11.2 s).

**The cost.** Per Smalltalk-tier run, 534 s. Of `tools-test`'s 157.2 s
of tests, 148.3 s are the kernel's 258 tests again, in the development
image; the 93 tests of its own take 8.9 s (computed from the two NDJSON
files in `$S/types-3/check/smalltalk/`). Three of the four runs use the
`-Onone` interpreter. The Swift and core tiers run `kernel-test` after
the suite has run the same tests in parts (120 s each run).

**The proposal.** Without M1: `golden` already builds the release
`kajo`; run it first and run `kernel-test` and `tools-test` with that
binary. About 12 and 17 s of tests against 117 and 157. With M1 they use the
checked optimized `kajo` and nothing else changes. Keep all four runs:
they are four hosts (the CLI in one VM, the development image, the
suite's parts, the shell). What goes is the slow build under two of
them.

**How to bound it.** The Mac shell's row is the bound: 11.2 s for the
258 tests in a Release build.

**Risk and size.** Small (two lines of `gates-lib.sh`, the test of the
lists). What a debug `kajo test` checks that a release one does not is
`verifyStops` and the assertions (A1); with A1's level printed on the
run line the gate can ask for it. Owes the Swift tier and
`check-tier-test`.

**Confidence**: read.

## verification.M6: builds repeated across gates

**Where and what.**

1. `scripts/new-check.sh:44` calls `scripts/dist.sh checkout`, which
   builds the release CLI in a fresh scratch path (`dist.sh:71`,
   `--scratch-path $work/cli`, 55 s) and three framework slices
   (`dist.sh:88-97`, 36 + 35 + 34 s) in a `mktemp` directory, every run:
   164 of the gate's 267 s (`$TMPDIR/kajo-new-check/checkout-dist.log`,
   run of 2026-11-19 22:33). The last two Swift-tier runs changed files
   under `Tests/` and `tools/` only; the frameworks' inputs were the
   same bytes.
2. `scripts/check-hot-path-arc.sh:36` builds `-c release -Xswiftc
   -enable-testing` into `.build/release-testing`; `justfile:67` and
   `:71` build the same flags into `.build/release-tests`. Two full
   release builds of one configuration per core run (`arc-check` 63 s
   cold, `test-release` 91 s of build).
3. `scripts/ab.sh:26` builds the base commit's aligned release binary on
   every run (about 90 s of the gate's 332), though a module's runs share
   one base.
4. `scripts/native-check.sh` compiles the kernel image's generated C at
   `-O2` for macOS in `kernel-test` (`:40`) and again in `cc` (`:106`),
   in both configurations.

**The cost.** Per Swift or core run: 108 to 164 s for 1. Per core run:
about 60 s for 2, 90 s for 3, 20 to 30 s for 4.

**The proposal.** 1: keep `Prebuilt/` and the CLI in
`.build/prebuilt-cache/<key>/`, the key a digest of `Sources/`,
`Package.swift`, `scripts/dist-frameworks.yml`, the dist script, and
the `swift` and `xcodebuild` versions; a hit copies and prints `prebuilt:
cache hit <key>`, a miss builds as now. The flags check
(`dist.sh:100-113`) runs on a miss and its `FLAGS.txt` travels with the
cache. 2: `arc-check` reads the objects of `.build/release-tests`. 3:
`ab.sh` keeps base builds by commit under `.build/ab-base/<sha>/`. 4:
`cc` reuses `kernel-test`'s macOS objects when they were compiled with
the warning flags.

**How to bound it.** The step times are in `checkout-dist.log` and
`gates.log` already.

**Risk and size.** Small each. The lesson "a gate that finishes ten
times faster has changed" binds: every hit prints its key, and the
weekly run sets the caches off. `new-check` exists to prove that a
checkout builds from clean, so its cache must miss whenever any input
byte differs. Owes the Swift tier.

**Confidence**: read.

## verification.A2: no gate output says which test took the time

**Where**: `Tests/KajoVMTests/Marking/AllocationStallTests.swift:353-356`
(`bodyTimer`); `Tests/KajoVMTests/ObjectModel/SymbolInterningTests.swift`
(its own body print); `KernelImageTests.swift:196-199`.

**What is there now.** Swift Testing's per-test time includes the wait
for a pool thread (the lesson: a 0.1 s body read 408.8 s). In
`tsan.txt`, 339 of the VM bundle's 466 result lines report between 700
and 1138 s. Three
files print their bodies' own time, each its own way, with the test's
name typed by hand:

```swift
let endBody = bodyTimer("aStalledProcessTakesAnInterrupt")
defer { endBody() }
```

**The cost.** To find where a gate's time goes one needs a serial run
(gate speed made one: 2170 s) or guesses. This review could rank only
the stall tests, the kernel tests and the snapshot random programs,
because only they print. A test renamed keeps its old name in its line.

**The proposal.** One trait, `.bodyTime`, a `TestScoping` trait that
times the body and prints `body <test id> <case> <seconds>`. Applied to
every `@Test` by a one-time mechanical edit (the VM tests are free
functions, so a suite trait does not reach them). Then
`scripts/gate-times.py <gate output>` prints the tests by body time and
their sum per file. `bodyTimer` and the two hand-written prints go.

**How to bound it.** None needed; the cost is one clock read per test.

**Risk and size.** Small, wide (about 650 `@Test` lines). Owes the
Swift tier.

**Confidence**: read for what is there. I did not check that the
toolchain's Swift Testing has `TestScoping`; if not, a helper called as
the first line does the same.

## verification.R1: wait loops written per file

**Where**: one helper in the VM tests,
`Tests/KajoVMTests/Processes/Runtime.swift:108-115` (`eventually`), and
`StallDiag.wait` and `waitProgress`
(`AllocationStallTests.swift:495`, `:529`). In the compiler tests:
`ShellTests.swift:135` (`drive`), `ShellCloseTests.swift:20` (`until`),
`ToolsTests.swift:162` and `:178` (`until`, twice), `:238-239`, `:255`,
`:410-419`; `DevelopmentAnswersTests.swift:102-118` (`probe`,
`probeUntil`), `:228`, `:271`, `:353`, `:391`;
`DevProtocolTests.swift:284-290`, `:414`, `:432`, `:445`;
`PhoneTransportTests.swift:73-75`, `:151-152`, `:184-185`, `:192-193`,
`:210-211`; `ProjectDirectoryTests.swift:46-47`;
`DistributionTests.swift:115-116`;
`ReviewFixesTransportTests.swift:63-64`, `:143`, `:157`;
`ReviewFixesPart2Tests.swift:322-323`, `:390-391`;
`AppServingTests.swift:218-219`. The bound itself: `underThreadSanitizer
? 600 : 120` 31 times, `600 : 60` 4 times, and `hostBoundSeconds`,
`closeWait` and `driveScale` as three more spellings
(`DevelopmentAnswersTests.swift:46`, `ShellCloseTests.swift:18`,
`ShellTests.swift:130`).

**What is there now.** About thirty loops of one shape:

```swift
let end = ShellVM.now() + 30_000_000_000
while ShellVM.now() < end && !events.withLock({ $0.contains { $0.kind == .lost } }) { usleep(2000) }
```

with bounds of 30, 60 and 120 s, `3000 x 10 ms`, `20000 x` a turn, and
poll intervals of 200 µs to 10 ms. Some scale under the sanitizer, most
do not.

**The cost.** The lessons hold three rules for a wait (long everywhere,
a sanitizer value of its own, a failed wait is a recorded issue before
anything reads the result). Each loop restates them or does not. Two
modules were spent on waits that were too short (the listener's report,
the Bonjour event). A change of the rule, say 120 to 300 s, touches
forty lines in fifteen files, and the ones without a sanitizer value
are the next thin tests: `PhoneTransportTests.swift:73` and `:184` wait
30 s in every build.

**The proposal.** One function in a shared support file (R2):
`wait(_ what: String, _ bound: WaitBound = .mustCome, turns: ShellVM? =
nil, _ cond: () -> Bool) -> Bool`. `.mustCome` is 120 s and 600 under
the sanitizer; the function records the issue with `what` when the bound
runs out; with `turns` it runs main turns between polls (what `drive`
and `LocalTools.until` do). `eventually`, `drive`, the `until`s and
`probeUntil` become calls of it.

**How to bound it.** Not a speed change. After: `grep -c 'usleep' Tests`
falls from 76 to about ten, and no test file holds a number of seconds.

**Risk and size.** Medium by count, small by content. A wait that was
30 s and becomes 120 s changes no passing run. Owes the Swift tier.

**Confidence**: read (every site listed was read at the line).

## verification.R2: no shared test support

**Where**: `Tests/KajoVMTests/Processes/Runtime.swift:103`
(`underThreadSanitizer`) and
`Tests/KajoCompilerTests/PhoneTransportTests.swift:313`
(`compilerTestsUnderThreadSanitizer`, the same `dlsym` line);
`ShellTests.swift:25-106` (`TestShell`), `ToolsTests.swift:49-106`
(`ToolsShell`), `AppServingTests.swift:42-74` (`PropertyPlatform`).

**What is there now.** The two test targets share no code, so the
sanitizer probe is written twice. The compiler tests hold three fake
view hosts. All three keep "views as property tables by handle" and
answer `create`, `set` and `get` the same way; they differ in what else
they take (`frame`, `add`, `call`), in what a `get` of an unset property
answers (`.nil` in two, `.int(0)` or `""` in `ToolsShell`), and in
whether an unknown op is `nil` or `.nil`.

**The cost.** The view protocol (ADR 0010) has two real hosts and three
fakes. The lesson on `ViewWrapperTest` ("a test that assumes the
headless host fails on every real one") is this drift seen from the
other side: each fake is a host with its own rules. A new op, or a rule
such as "a refused kind raises a clean Error", is written into three
fakes or tested against one.

**The proposal.** A target `KajoTestSupport` (under `Tests/`, a
dependency of both test targets): `underThreadSanitizer`, `now`, the
wait of R1, `TestThread`, `Flag`, the body-time trait of A2, and one
`FakeViewHost` with the three fakes' abilities as options (record
calls, count ops, defaults for unset properties). `PropertyPlatform`
becomes a thin `ShellPlatform` adapter over it.

**How to bound it.** Not a speed change. The check is that the three
suites pass on the one fake.

**Risk and size.** Medium. The fakes' different answers to an unset
`get` are relied on by the tools' tests; they become an option, not a
silent merge. Owes the Swift tier.

**Confidence**: read.

## verification.R3: the gate lists live in four places

**Where**: `scripts/check-tier.sh:139-150` (the tiers),
`scripts/weekly.sh:38-39` (the weekly's list),
`scripts/check-tier-test.sh:80-91` (the same lists as literal strings),
`scripts/gates-lib.sh:43-86` (the definitions); the gate scripts that
owe the test, `check-tier.sh:114` and `check-tier-test.sh:92`; and
`AGENTS.md` "Verification", which lists the core gates twice.

**What is there now.** A gate is defined once (`gl_spec`) and listed by
hand in each tier, in the weekly and in the test:

```
core="clean-build swift-test-load tsan tsan-load ios-check arc-check golden native-golden ..."
check_gates "$core" Sources/KajoVM/Marking/Marker.swift
```

**The cost.** The lessons record two drifts of exactly these lists:
`check-tier-test.sh` failed for a module after AOT 1 added three gates,
and the weekly ran short of the core tier for the same reason. Adding a
gate today touches `gl_spec`, `check-tier.sh`, `weekly.sh`, two strings
in the test and the doc. The test's literal copies detect a change; they
do not say which list is right.

**The proposal.** One ordered table in `gates-lib.sh`: gate, the tiers
that run it (`smalltalk swift core weekly`), and its condition
(`always`, `fuzzers`, `models`, `gate-script`). `check-tier.sh` and
`weekly.sh` filter it. `check-tier-test.sh` then checks properties, most
of which it has already: the weekly is a superset of every tier, `soak`
follows `test-release`, a gate script owes the test. The list of gate
scripts becomes "every script the table or `gl_spec` names". `just check
--dry-run --tier core` prints the list for the docs.

**Risk and size.** Small; scripts only; owes `check-tier-test` and the
Swift tier. Run the changed scripts once alone first (the lesson on
`status`).

**Confidence**: read.

## verification.R4: broken variants have no list

**Where**: the six switch structs, 73 fields:
`Sources/KajoVM/ObjectMemory/Config.swift:108` (10),
`Workers/VMConfig.swift:111` (15), `Nursery/NurseryConfig.swift:102`
(6), `Marking/MarkingConfig.swift:92` (22),
`Relocation/RelocationConfig.swift:54` (5),
`YoungCollection/YoungConfig.swift:106` (15); `AOTOptions.broken*`; the
environment switches `KAJO_BROKEN_DELAY_END`
(`DelayEndTests.swift:28`), `KAJO_BROKEN_SHELL_CLOSE`
(`ShellCloseTests.swift:32`), `KAJO_CLOSED_SHELL_CALL`
(`ClosedShellCallsTests.swift:17`); and variants "run by hand" named in
comments (`ProcessRootsTests.swift:125`, `FinalMarkTests.swift:275`,
`VMEndTests.swift:147`) and in module docs.

**What is there now.** A broken variant is a field, a test that sets it,
and, when it traps or races, a paragraph in a module doc with the
command. Three fields are named in no test file:
`VMTestSwitches.noPendingRoots` (run by hand,
`ProcessRootsTests.swift:125`), `MarkingTestSwitches.youngRootsInStop`
and `MarkingTestSwitches.stallRelocation` (the last is set by
`Headless` from `--stall-reloc`).

**The cost.** The lessons: "a switch nobody ran is a switch nobody
tested", and the model switch that explored the same states on and off.
Nothing lists the hand-run variants, so nothing runs them after the
module that wrote them; a refactoring can make one pass and no gate
says so. To answer "is every rule's broken variant still failing" one
reads sixty module docs.

**The proposal.** Two parts, both in the project's own style.

1. A table test over the source, as `ClosedShellCallsTests` has for
   `ShellVM`: it reads the six structs' fields and asserts each is
   either set by a test (the file and test named in the table) or
   listed as by-hand with its command and the message it must produce.
   A new switch without a row fails.
2. `scripts/broken-variants.sh`: the by-hand rows, each in its own
   process, each expected to fail its named check or to die with its
   recorded message (`TSAN_OPTIONS=abort_on_error=0` where the lesson
   says so). Run by the weekly, not by a tier.

**How to bound it.** Count first: how many by-hand variants there are
and how long each takes. A grep over `Tests/` finds six; the module
docs hold the rest (the register flush, pins for good, the generator's).

**Risk and size.** Small for 1 (one test file). Medium for 2: some
variants need a special build (`-D` flags, a field edited by hand) and
stay prose; the table says so. Owes the Swift tier.

**Confidence**: read for the counts (a script over the six structs and
`Tests/`). I did not count the hand runs in the module docs.

## verification.R5: `RandomConfig` is one enum and seven lists and switches

**Where**: `Tests/KajoVMTests/Workers/RandomPrograms.swift:337-488`
(`workers` `:376`, `longBytes` `:395`, the `verify` list `:398-401`, the
heap `:409-410`, the configure switch `:423-475`), `:628-695` (what must
have happened), `:727-729` (which configurations must tally), and
`SnapshotMode` `:793-819`.

**What is there now.** A configuration is a case of an enum; its
properties are spread over seven places, most of them a list or a
switch with a default:

```swift
let verify = [.oneWorker, .eightWorkers, .perturbed, .noNursery, ...].contains(self)
...
default: 8          // workers
...
default: break      // configure, and the post-run check
```

`SnapshotMode.configure` restates four of the same setups
(`stopEveryPoll`, `preemptEveryPoll`, `perturbed`,
`collectEveryAllocation`).

**The cost.** A new configuration compiles with every default: eight
workers, no verifier, no "the stress happened" check. Six of the 23
configurations run with `verify: false`. For three the reason is
written (`:816-818`: where every poll or allocation collects). For
`plainBytecodes`, `tinyEntryChunks` and `preemptEveryPoll` no comment
says why. I cannot tell from the file whether that is meant; that is
the finding.

**The proposal.** One struct per configuration (`workers`,
`heapBlocks`, `verify` with a reason when false, `configure`, `happened`
as a closure over the counters, `mustTally`), the enum's cases mapping
to values in one table. `SnapshotMode` takes its four setups from the
same table. A field without a default cannot be forgotten.

**Risk and size.** Small; one file. The configurations' behaviour must
not change: compare `soak`'s line per configuration before and after
(seeds, failing `[]`). If the three unverified configurations turn out
to be an omission, turning their verifiers on is a separate commit with
its soak. Owes the Swift tier.

**Confidence**: read.

## verification.R6: one row format, eight parsers

**Where**: Python: `scripts/shell-report.py:54-69` (`lines`),
`scripts/perf-report.py:82-88` (`parse_line`), `scripts/ab-table.py:17`,
`scripts/remote-report.py:12-16` (`fields`),
`scripts/devsession-report.py:8-12` (`fields`). zsh:
`scripts/native-check.sh:42` (`field`), `scripts/ab.sh:48` (`f`),
`scripts/golden.sh:16-17` and `:26-27`. `med` is written four times
(`shell-report.py:79`, `remote-report.py:18`, `devsession-report.py:14`,
`ab-table.py:23`) with three range formats.

**What is there now.** Every result line of `kajo run`, the shells and
the scripts is `key=value` words. Each reader splits it itself:

```python
kv = dict(t.split("=", 1) for t in line.split() if "=" in t)      # ab-table: last wins
d.setdefault(k, v)                                                # shell-report, perf-report: first wins
re.finditer(r'(\w+)=(\{.*\}(?= thermal=)|\S+)', line)             # remote-report: a JSON value
```

**The cost.** The readers already disagree on a repeated key (first or
last) and on a value with spaces (two regexes, each tied to which field
follows). The lesson on `ok=-1` was a reader that did not know a
writer's value. A new field with a brace or a space is fixed in one
script and read wrong by four.

**The proposal.** `scripts/rows.py`: `parse(line)`, `read(path)`,
`num`, `med(rows, key, fmt)`, imported by the five scripts; and one
zsh function `kv <line> <key>` in a small sourced file for the three
shell scripts. Say in one place what a repeated key means.

**Risk and size.** Small. `PerfReportTests` and `check-tier-test.sh`'s
`--bar` fixtures guard two of the five; `shell-report.py` owes
`check-tier-test`. Owes the Swift tier.

**Confidence**: read (`perf-report.py` beyond its parser was only
outlined).

## verification.R7: the golden table four times, the devices four times

**Where**: the kernels and checksums: `scripts/golden.sh:13`, `:22`;
`scripts/native-check.sh:63`, `:74`;
`Tests/KajoVMTests/Loader/Fixtures.swift:21-31`;
`Sources/KajoShellCore/Modes.swift:29`; the names again in
`scripts/shell-matrix.sh:62`, `:65` and `scripts/ab.sh:19`. The devices:
`scripts/check-tier.sh:162`, `scripts/device.sh:33`,
`scripts/device-rows.sh:22-23`, `scripts/link-probe.sh:27`; the team in
`device.sh:34`, `new-check.sh:62`, `app-roundtrip.sh:74`. Small copies:
the Bonjour browse (`device.sh:101`, `app-roundtrip.sh:138`,
`remote-session.sh:87`), the wait for `serving=tcp`
(`link-probe.sh:46`, `remote-session.sh:45`, `:51`,
`app-roundtrip.sh:158`), the xcodebuild status-errors-warnings function
(`apps-check.sh:11-21`, `new-check.sh:68-78`, `dist.sh:88-97`), the
process-tree kill (`gates-lib.sh:166-170`, `fuzz-gate.sh:39`,
`device-rows.sh:29`).

**What is there now.** The same line in two scripts:

```
for pair in arith:372800000 fib:24682992 sends:1066666666666668 alloc:41950911 ivars:36383626 walk:9016009025388544 storeheavy:512000 closures:210210000 floats:7499750000; do
```

The Swift table in `Fixtures.swift` has eight of the nine (no
`storeheavy`).

**The cost.** A kernel added, or a checksum changed with a kernel's
size, is four edits and two name lists. The lists already differ by one
kernel. A second iPhone is four edits.

**The proposal.** `Tests/KajoVMTests/Fixtures/kernels/golden.txt` (name,
kind, checksum), read by the two scripts, by `Fixtures.swift` and, at
build time or through a small generated Swift file, by `Modes.swift`.
`scripts/devices.sh`, sourced: the labels, the identifiers, the team,
`dd_for <udid>`, `browse_kajo`, `wait_line <file> <pattern> <bound>`,
`xcb <log> <args...>` and `kill_tree`.

**Risk and size.** Small. `golden`, `native-golden`, the matrix and
`goldenKernelChecksums` guard the table. The device scripts are not
gates; run each changed one once (the lesson). Owes the Swift tier, and
`check-tier-test` for `gates-lib.sh`.

**Confidence**: read for every site but `app-roundtrip.sh`,
`remote-session.sh` and `link-probe.sh`, of which only the cited lines
were read.

## verification.R8: 47 kernel image builds in the compiler bundle

**Where**: `grep -n 'KernelBuild.build(' Tests`: 47 calls in 20 files.
The plain kernel again: `KernelImageTests.swift:205`, `:287`, `:288`,
`:290`, `LiveInstallTests.swift:57`, `SignatureTests.swift:136`,
`TypeCheckerTests.swift:132`. The development image again:
`ToolsTests.swift:39`, `:191`, `TypeCheckerTests.swift:26`. Twelve
globals of the shape `let xImage = try! KernelBuild.build(sources(in:
[kernelDirectory, xFixtureDirectory])).image`.

**What is there now.** `kernelImage` keeps the bytes and drops the
build's result, so a test that wants the warnings or the counts builds
again:

```swift
let kernelImage: [UInt8] = { try! KernelBuild.build(KernelBuild.sources(in: [kernelDirectory])).image }()
...
@Test func theKernelBuildsWithoutWarnings() throws {
    let r = try KernelBuild.build(KernelBuild.sources(in: [kernelDirectory]))
```

Every fixture image compiles all 174 kernel class files to add a few
classes.

**The cost.** About 35 distinct builds per bundle run, each the whole
kernel through the bootstrap compiler and the kernel's initialization
in a VM. `build-image` takes 3 s with its `swift run` in debug
(`gates.log`); under the sanitizer I expect a minute each. It is CPU,
not wall time, while the kernel parts bound the bundle; after M3 the
serialized suites that build images (`TonelRoundTripTests`, 594 s in
gate speed's record) are the next long pole.

**The proposal.** Keep the whole `KernelBuild.Result` in the global
(`kernelBuild.image`, `.warnings`, `.classes`); the tests at `:205` and
`SignatureTests.swift:136` read it. Later, and only with a measurement
that says the builds matter: `KernelBuild.extend(_ base:, with:)` that
loads the kernel image and compiles a fixture's files into it.

**How to bound it.** The body-time lines of A2 for the image-building
tests in one sanitized run. If their sum is under 300 s, stop at the
first step.

**Risk and size.** The first step is small. `extend` is a second way to
build an image and so a second thing that can drift from the build; it
needs a byte-for-byte test against the whole build.

**Confidence**: read for the call sites; the sanitizer cost per build
is a guess.

## verification.A3: the weekly's refusal is a list of process names

**Where**: `scripts/weekly.sh:49-58`; the other list,
`docs/PROCESS.md:132-135`.

**What is there now.** The weekly run starts unless a process named
`kajo`, `swift-build`, `swift-test`, `xcodebuild`, `swift-package`,
`swiftpm-testing*`, `KajoShell`, `Kajo`, `Sample` or `yes` runs outside
its group. The hand-back's list in `PROCESS.md` has three more names
(`fuzz-*`, `clang`, `gtimeout`).

**The cost.** Two lists of one fact, already different, and the
refusal's list has holes. A `just check` of another session is, for
whole gates, none of the names: the fuzz gate's 600 s (`fuzz-kasm` and
the others), `native-cc` (`clang`), `ios-check` (the compiler's
frontend), and the device rows' 860 s (`xcrun devicectl`; nothing of
Kajo runs on the Mac). The list was already found short once (gate
speed: swiftly's names).

**The proposal.** A lock, not a list. `gl_init` takes
`~/kajo-weekly/machine.lock` (a directory made with `mkdir`, holding the
pid and the command; stale when the pid is dead) and `gl_cleanup`
releases it. `check-tier.sh` and `weekly.sh` both go through `gl_init`,
so both hold it; the weekly refuses when it is held. The name list
stays as a second net for runs outside the gate scripts.

**Risk and size.** Small; `gates-lib.sh` and `weekly.sh`;
`check-tier-test.sh` gets a case (a held lock refuses, a stale one does
not). Owes `check-tier-test` and the Swift tier.

**Confidence**: read.

---

## What I read and found good

- `scripts/gates-lib.sh`: one gate is one definition with a bound and
  an output check; a fuzz gate cannot pass on the fallback driver; every
  step of the matrix gate counts. Nothing to add but R3 and A3.
- `scripts/fuzz-gate.sh` with `check-tier-test.sh`'s stand-ins: the
  kill paths are tested, not assumed.
- `KernelTestParts`: the parts are computed from what the runner lists,
  and a standing test asserts they are the unfiltered run. The split
  cannot lose a test. Only its weights are by hand (M3).
- `NativeCache`: keyed by everything clang reads; 586 and 82 hits, 0
  misses in the last runs. Nothing is compiled per test any more.
- The models share one explorer (`models/Sources/ModelKit/Explorer.swift`)
  and one memory model; each model is an `ExplorableModel`. `model-check`
  is 35 s. No finding.
- The four fuzz drivers are a dozen lines each over `FuzzEntry` and
  `FuzzDriver`. No finding.
- Fixed sleeps in tests: I counted 76 `usleep` and `sleep` calls. The
  ones that are not poll intervals sum to under ten seconds a suite run
  (the idle-wake windows of 1 s are the claim itself). Sleeps are not
  where the time goes.
- `StallDiag.waitProgress`: a wait that ends on the collector's own
  progress. It is the best wait in the tree; R1's helper should be able
  to carry it.
- The fixture chain `Runtime` to `nurseryRuntime`, `markingRuntime`,
  `relocRuntime`, `youngRuntime`: each adds one decision. No finding.

## What I did not read

- The bodies of the suites, except `RandomPrograms.swift`,
  `AllocationStallTests.swift`, `KernelImageTests.swift` and the helper
  files (`Support.swift` of both targets, `Runtime.swift`,
  `Harness.swift`, `Fixtures.swift`, `NativeSupport.swift`, the four
  module supports). The other suites were read by `grep` (waits, sleeps,
  image builds, switches, bounds) and at the cited lines.
- `Tests/KajoVMTests/Native/NativeCache.swift` past line 80,
  `NativeCacheTests.swift`.
- `models/` beyond the explorer, the package file and the four
  `explore` entry points: no model's states or tests.
- `scripts/perf-report.py` past its parser, `link-probe.py`,
  `gen-classes.py`, `canonical-tonel.sh`, `release.sh`,
  `dist.sh:200-365`, and `app-roundtrip.sh`, `remote-session.sh`,
  `link-probe.sh` except the cited lines.
- `Sources/KajoVM/**/Fuzz*.swift` (`FuzzDriver`, `FuzzEntry`).
- `docs/modules/allocation-stalls.md` and `interning-tests.md` (their
  records, 33 to 39, were read instead), `gate-tiers.md`.
- The device matrices' rows; `apps/`.

## Measurements this report asks for

1. M1: the suite once in the checked optimized build, once more with
   the sanitizer; a hand-run race variant under the second.
2. M2: the two bundles side by side under the sanitizer, once idle,
   three times loaded.
3. M3: three and five kernel parts, several loaded sanitizer runs.
4. M4: the sum of `slowSpinS` over one sanitized run.
5. A1: `kajo test --verify` in release against plain.
6. A3 and the device rows: whether the device matrix can run beside the
   fuzz gate (the Mac only streams the console during it; 860 s and
   666 s that never overlap today). `docs/PROCESS.md` forbids it, with
   no reason given there; I did not make it a finding.

## Bugs met on the way

- `Tests/KajoVMTests/Marking/AllocationStallTests.swift:371-376`:
  `processTask()` divides `pti_total_user + pti_total_system` by 1e9 as
  if they were nanoseconds. On Apple silicon they are probably Mach
  time units (125/3 ns). The `procCpu=` of every `stall-diag` line
  reads 0.22 to 0.28 cores on a machine whose load is 32 to 45; times
  41.67 it is 9 to 12 cores. Diagnostics only.
- `scripts/weekly.sh:52-54`: the refusal does not see a gate run that
  is inside its fuzz gate, `native-cc`, `ios-check` or the device rows
  (A3).
- `Tests/KajoCompilerTests/KernelImageTests.swift:90-118`: the weights
  table no longer matches the tests (M3). Balance only, no coverage.
- `scripts/shell-matrix.sh:9` says the default parts are "golden
  scenarios events hog mainload drift"; `:36` starts with `drift` too.
  A comment.
