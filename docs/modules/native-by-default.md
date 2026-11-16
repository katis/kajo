# Native code on by default in a Release build (a follow-up of AOT 2)

## Status

Briefed 2026-11-15, not built. The owner's answer of 2026-11-15 to AOT 2's
first open question ("Must a Release build include the native module by
default?"): "On by default", against the recommendation to keep it opt-in
(`docs/decisions/37-aot-2.md`, the dated block at its end). The owner chose
this follow-up first of the three that day ("Native by default").

The decision is made. This module builds it and measures what AOT 2 left
unmeasured on the path that now becomes every Release app's. A bad number
found here is reported to the owner with its rows; it does not undo the
answer.

## What it is

A project made by `kajo new` (or by the Kajo app's New App…) has
`KAJO_NATIVE: YES`. Its Release build generates and compiles the sealed
image's native module and links it into the app, with no flag asked of the
developer. `KAJO_NATIVE=NO` turns it off, in the project or on one
`xcodebuild` line, without generating the project again. Debug builds do
not change: they run the interpreter and serve the development protocol.

Projects that already exist are not touched. Nothing rewrites a
`project.yml` a developer has.

## What is known (AOT 2, the mini, 1f7828f; check these before building on them)

- The product's configuration is `kajo aot --subset callees --cold-minsize
  --send-helper` at `-O2`: 2.59 MB of file for the Sample's image, 0.962
  of full native speed on the kernels (`docs/modules/aot-product.md`
  part 1).
- The Mac Release binary, stripped: 1 697 936 bytes with the module off,
  4 239 920 on. The app bundle 8 736 KiB off, 11 516 on. The iPhone
  binary as installed 2 109 248 and 4 956 384 bytes (parts 3 and 5).
- The module compiles in 3.7 to 4.2 s from clean and 0.11 s unchanged; a
  whole Release build with it from clean took 10 s on the Mac (part 3).
- First frame, Release, module off against on, five launches in each
  order: iPhone 110 to 114 ms against 115 to 116, iPad 240 to 243 against
  248 to 251, Mac 223 against 228. Bind 5 to 6 ms on the iPhone and the
  Mac, 9 to 10 on the iPad (part 5).
- Not measured by AOT 2: frames missed with the module on (the Sample's
  launch report counted none), any scenario with the product's
  configuration on a device, the Release build's time on a second
  machine state (a changed image).
- `scripts/build-native.sh` in a generated project does nothing unless
  `CONFIGURATION=Release` and `KAJO_NATIVE=YES`; its by-hand default is
  `${KAJO_NATIVE:-NO}`. `AppProjectSpec.native` defaults to `false`
  (`Sources/KajoGenerator/Generator.swift`), `kajo new --native` sets it
  (`Sources/kajo/main.swift`), and the Kajo app's New App…
  (`Sources/KajoShellCore/Product.swift`) builds its spec without naming
  it, so it follows the default.
- `scripts/new-check.sh` builds the Release products with the module off
  first and then again with `KAJO_NATIVE=YES` as an `xcodebuild` override
  (the rows `-native`, `-native-again`, `-native-truncated`,
  `-native-stale`); the off binaries are the section check's negative
  control.
- Each Release build after an image change leaves one more library of
  about 4 MB under `.build/kajo/native/<key>/`; nothing prunes them
  (AOT 2, "Not done").

## Starting positions (measure, then decide; say where one was wrong)

1. Frames missed do not change with the module on. Native code changes
   how fast Processes run, not when the main thread yields; but AOT 1
   taught that a faster mutator is a heavier load on every provisioning
   rule, so this is measured, not assumed.
2. The shells already answer most of the frames question: their scenario
   matrix runs with `native=1` (`EXTRA_ARGS`, `KAJO_SHELL_AOT=1`). Check
   which `kajo aot` options `apps/Shared/build-images.sh` uses for the
   shells' modules; if it is not the product's configuration, the rows it
   made for AOT 1 and AOT 2 do not speak for the default and the matrix
   is run again in the product's configuration.
3. `KajoApp` already has a `kajo-frames=` launch argument
   (`Sources/KajoApp/Application.swift`). It may be enough for the Sample
   to report frames and frames missed over a window; read it before
   adding anything.
4. A failed native step should fail the Release build with a message that
   names `KAJO_NATIVE=NO`. Find out what happens today when `kajo aot` or
   a compile fails (a failing phase, or a link against a missing library
   with Xcode's own error) before deciding the message.
5. Nothing in the repository's own apps changes: the shells are not
   generated projects and keep `native=1` as a launch argument.

## Parts

1. **Measure, build nothing.** Before any change to the generator:
   - the scenario matrix of the shell with the module in the product's
     configuration against interpreted, on the Mac at 7 workers and on the
     iPhone at 5 (the iPad if time allows), the device blocks in both
     orders, `shell-report.py --bar` over every raw row, every column;
   - the Sample made from a `dist.sh checkout`, Release, `KAJO_NATIVE=NO`
     against `YES`: frames and frames missed over a window after the first
     frame, on the Mac, the iPhone and the iPad, five launches a side in
     both orders, the thermal state on each line. If the Sample cannot
     report frames, say what is missing; the smallest addition to its
     launch report is part of this part.
   Write the rule that will read the numbers before reading them
   (`part1/rule.txt` with its time): the module on misses no more frames
   than off beyond the spread of the off launches, and first frame stays
   within 20 ms. Report against it.
2. **The default.** `AppProjectSpec.native` defaults to `true`; the
   template writes `KAJO_NATIVE: YES`; `build-native.sh`'s by-hand default
   follows; `kajo new` gains `--no-native` and keeps accepting `--native`;
   the help text and the fixture
   (`Tests/KajoCompilerTests/Fixtures/app-project`) follow. A failed
   native step fails the Release build with one line that names the
   setting (starting position 4).
3. **`new-check`.** The plain Release rows are now the native ones: the
   section present, the bind line read from a Mac launch, 0 `KajoAOT` and
   0 development symbols. The same products built with `KAJO_NATIVE=NO`
   are the off rows: no section, the binary's size printed beside the on
   one. The unchanged-second-build, truncated and stale rows stay. Each
   check keeps its positive and its negative control.
4. **The cache.** `build-native.sh` removes libraries of keys that are not
   the current one for any platform of the project, so `.build/kajo/native`
   holds one library per platform. A test or a `new-check` row shows a
   changed image leaving one, not two.
5. **The docs.** This file's "As built"; `docs/modules/aot-product.md` and
   ADR 0015 gain a dated note that the default changed (their text is not
   rewritten); `docs/modules/app-project.md` or `distribution.md` where a
   Release build's contents and sizes are described.

## Tests

- `AppProjectTests`: a spec made with no `native` argument writes
  `KAJO_NATIVE: YES`; `native: false` writes `NO`; the fixture is byte for
  byte what the generator writes. Written first; the first fails on the
  starting commit.
- The CLI: `kajo new` with no flag, with `--native` and with `--no-native`
  (the project's setting read back from the written `project.yml`).
- `new-check` is the test of the build itself. Its broken variant: a
  project with the setting forced to `NO` must fail the "plain Release has
  the section" check (run once by hand, the failing line quoted in the
  doc).
- The failed-step message: a `kajo` that exits 1 in place of the
  checkout's (a stub on the script's path, by hand) fails the build with
  the line that names `KAJO_NATIVE=NO`; quoted in the doc.

## The bar

- A project from `kajo new` with no flag builds Release for macOS, iOS and
  the iOS Simulator from clean with 0 warnings, each binary carries
  `__DATA_CONST,__kajo_native`, and the Mac launch prints `native=bound`
  with 0 declined.
- The same project with `KAJO_NATIVE=NO` on the `xcodebuild` line builds
  the three products with no section and no file under
  `.build/kajo/native/<platform>/`.
- Debug builds: unchanged products (no section, serving as before), and
  `app-roundtrip.sh mac` passes.
- Part 1's table for every row asked, with the rule's verdict. A row that
  could not be run names what blocked it.
- Release build time from clean and unchanged, module on, on the Mac
  (before: 10 s and the 0.11 s phase).
- `just new-check` passes; `just check <the brief's commit>` on the final
  code commit, the Swift tier, every gate `rc=0`, its `gates.log` quoted.
- Nothing under the core directories (`AGENTS.md` "Verification") and
  nothing under `Sources/KajoAOT/`. If part 1 shows a change there is
  needed, stop and hand back: that is another module.

## Rules of the house that bind here

- `docs/PROCESS.md`, "Constraints on every agent", in full.
- A before and after on a device is run in both orders; the thermal state
  on every line; after a device run, tabulate the bar's columns over every
  row, whatever the run was for.
- A generated project's shape is tried with a second, changed build as
  well as a clean one (AOT 2's lesson).
- "Not in the release build" is a property of the linked binary, checked
  on it; so is "in the release build".
- A hand-back quotes one run of every switch and mode the module adds
  (`--no-native`, the pruning, the failed-step message).
- Signing, accounts and prompts are the owner's: a device build that
  waits on one is reported as blocked.

## Not in this module

- Any change to the generator of native code, its options or the 0.9
  rule; narrower per-pc tables (with AOT 3).
- The kernel's tests run inside the Sample, and a native `kajo-bench`.
- The shells' default engine.
- A dmg, a tag or a release.
- Existing generated projects.

## Deliverables

- The commits, the doc's "As built" with every number naming its file
  under `~/kajo-scratch/native-by-default/`.
- `part1/rule.txt`, the raw rows and the `--bar` tables.
- `check/gates.log` of the Swift tier on the final code commit.
- The hand-back map of `docs/PROCESS.md` step 5.

## Open questions (build the recommended option; decisions only)

1. `--native` on `kajo new`: kept and accepted as the default it now is
   (recommended, so scripts that pass it keep working), or removed.
2. A failed native step: the Release build fails and names the setting
   (recommended: a Release app that is silently three times slower is
   worse than a build that says why it stopped), or the build goes on
   interpreted with a warning.
3. The cache: one library per platform (recommended), or the last few
   kept so that switching between two images does not compile again.
4. If part 1 finds frames missed with the module on in some row: keep the
   default as answered and report (recommended; the answer is the
   owner's), or hold the default until the row is explained.

## As built

Built 2026-11-16 by the build agent from 30e14bd. Every number names its
file under `~/kajo-scratch/native-by-default/` (here `part1/`, `part3/`,
`check/`). Toolchain: swiftly's swift.org 6.4.2 and its clang first on PATH
(`part1/env.txt`); a generated project's native module is compiled by Xcode
27.2's clang (`xcrun clang`); the shells' modules by the PATH clang, as
`apps/Shared/build-images.sh` has done since AOT 1.

### Part 1: measured before the generator changed

The rule was written first (`part1/rule.txt`, 2026-11-16 05:32:43 EET,
before any number of this part was read).

**Starting position 3 was wrong: the Sample could not report frames.**
`kajo-frames=` lived in `KajoAppDevelopment` (a Debug build's
`FrameMonitor`, which also reads the server's counters), so a Release app
ignored it. The smallest addition (commit b8d6459): the frames window and
`FrameAccount` move to `KajoApp` (`Sources/KajoApp/Frames.swift`,
`FrameWindow`); a Release app launched with `kajo-frames=<s>` prints
`mode=app run=frames build=release seconds=… nominal_hz=… frames=…
expected=… missed=… drops=… gap_p99_ms=… gap_max_ms=… thermal=…` after a
1 s warmup and quits; a Debug build's line is unchanged (the window's extra
fields carry `served_sessions` and `served_requests`). Nothing in
`KajoDev` moved; the Release symbol checks still read 0.

**Starting position 2 was right in fact and wrong in effect.**
`build-images.sh` runs `kajo aot` with no options, and since AOT 2 those
are the product's configuration (every shell module has an `excluded.txt`;
`.build/apps-image/aot/shell/excluded.txt` names 2251 methods; the shell
image's module is 3.0 MB against AOT 1's full ones). So AOT 1's native rows
were made with AOT 1's full configuration and no native row existed for the
product's; the matrices were run again (below).

**The shells' matrix, native=1 (product configuration) against
interpreted.** The shell built once per platform with `KAJO_SHELL_AOT=1`
and launched with and without `native=1` (`scripts/mac-matrices.sh`,
`scripts/device-matrices.sh`; 156 rows a matrix; `--bar` over every raw
row in `part1/<matrix>-bar.md`, the per-kind comparison of rule 3 by
`scripts/compare.py` in `part1/<device>-compare.md`):

| matrix | order | rows | failed | checksums not ok | frames missed (rows) | fallbacks | unjustified | stalls (longest ms) | longest stop ms | thermal |
|---|---|--:|--:|--:|---|--:|--:|---|---|---|
| Mac, 7 workers, interpreted | 1st | 156 | 0 | 0 | 1788 (3, the hog with the budget off) | 0 | 0 | 631 (20.98) | 11.75 scavenge, ring stw | 230 nominal, 41 fair |
| Mac, native | 2nd | 156 | 0 | 0 | 1786 (3, the same) | 0 | 0 | 775 (39.41) | 18.19 scavenge, ring stw | 271 fair |
| iPhone, 5 workers, interpreted | A | 156 | 0 | 0 | 3618 (6: ring stw 6, 1, 35 and the hog off) | 0 | 0 | 0 | 18.98 scavenge, ring stw | 73 nominal, 86 fair, 112 serious |
| iPhone, native | A | 156 | 0 | 0 | 3635 (6: ring stw 21, 20, 17 and the hog off) | 0 | 0 | 16 (34.93) | 25.60 scavenge, ring stw | 271 serious |
| iPhone, native | B | 156 | 0 | 0 | 3630 (7: ring stw 14, 27, 12, storm stw 1, the hog off) | 0 | 0 | 31 (25.68) | 23.88 scavenge, ring stw | 271 serious |
| iPhone, interpreted | B | 156 | 0 | 0 | 3671 (6: ring stw 29, 35, 31 and the hog off) | 0 | 0 | 0 | 22.89 scavenge, ring stw | 271 serious |
| iPad, 5 workers, interpreted | A | 156 | 0 | 0 | 3576 (3, the hog off) | 0 | 0 | 0 | 13.92 scavenge, ring stw | 223 nominal, 8 fair, 40 serious |
| iPad, native | A | 156 | 0 | 0 | 3588 (6: ring stw 3, 3, 7 and the hog off) | 0 | 0 | 0 | 17.08 scavenge, ring stw | 271 serious |
| iPad, native | B | 156 | 0 | 0 | 3591 (6: ring stw 7, 3, 5 and the hog off) | 0 | 0 | 0 | 17.29 scavenge, ring stw | 271 serious |
| iPad, interpreted | B | 156 | 0 | 0 | 3586 (6: ring stw 3, 4, 3 and the hog off) | 0 | 0 | 0 | 15.63 scavenge, ring stw | 271 serious |

(Rows `part1/mac-interp`, `mac-native`, `iphone-A-interp`, … `ipad-B-interp`;
the logs `part1/*-matrices.log`. The hog with the budget off misses 1191 to
1193 of 1200 on the devices and 595 to 596 of 600 on the Mac in every
matrix by design. The golden rows bind natively: `fib` 22 of 34 methods,
the st kernels about 1437 of 3289.)

Rule 3's verdict, per row kind (`part1/*-compare.md`):

- **Mac: met in every row kind.** 0 frames missed and 0 fallbacks outside
  the hog with the budget off, in both engines. The native matrix ran at
  thermal "fair" throughout, the interpreted one mostly nominal; native
  counts 775 allocation stalls (longest 39.41 ms; no frame missed with
  them) against 631 (longest 20.98), and 11 sweep stops (longest 0.91 ms) where the
  interpreted rows had none.
- **iPhone: not met in one row kind, storm under `young=stw`**: one frame
  (one 16.7 ms gap) in native order B run 2, behind a 13.05 ms scavenge,
  with 0 fallbacks; 0 in the other 11 storm-stw rows of both engines and in
  the weekly's three (`~/kajo-weekly/2026-11-16/matrix-iphone`). The ring
  under `young=stw` (the oracle row) missed fewer natively: 111 frames in
  six rows (max 27) against 137 (max 35) interpreted, with 0 fallbacks in
  every row (AOT 1's full configuration had 109 frames behind 2 fallbacks).
- **iPad (first matrix on the iPad): not met in one row kind, the ring
  under `young=stw`**: 28 frames in six native rows (3 to 7) against 10 in
  six interpreted (0, 0, 0 in order A, then 3, 4, 3 with the iPad at
  serious), 0 fallbacks and 0 stalls in every row; each miss is a
  stop-the-world scavenge of 14 to 17 ms (`--bar`'s longest stop column).
  Every other kind: 0 frames, 0 fallbacks.
- **Both rows that miss are the stop-the-world young mode**, whose
  scavenge on the main thread is longer than a 120 Hz frame by
  construction; no row of the product's default young mode (`offload`)
  or of `local` missed a frame on any device, in either engine. No
  fallback, no unjustified fallback and no failed launch in 1560 rows.
  The devices ran at "serious" for every native row, so the interpreted
  order-B blocks are the like-for-like comparison.

**The Sample, Release, `KAJO_NATIVE=NO` against `YES`** (a `dist.sh
checkout` of b8d6459, `part1/ck`; `kajo new` with and without `--native`
by the checkout's own `kajo`, `part1/sample-off`, `part1/sample-on`; the
Mac's builds by `xcodebuild`, the devices' through `scripts/device.sh`;
every launch `kajo-launch-report kajo-frames=10`; five launches a side, off
then on (A) and on then off (B); `scripts/sample-mac.sh`,
`scripts/sample-device.sh`; raw lines `part1/sample-mac.txt`,
`sample-iphone.txt`, `sample-ipad.txt`; table `part1/sample-table.md` by
`scripts/sample-table.py`):

| device | order | module | first frame ms median | range | frames missed per launch | bind ms |
|---|---|---|--:|---|---|---|
| Mac | A | off | 246.6 | 205.2–688.5 | 0 0 0 0 0 | – |
| Mac | A | on | 247.3 | 212.9–539.4 | 0 0 0 0 0 | 5.22–5.39 |
| Mac | B | on | 250.2 | 239.8–258.3 | 0 0 0 0 0 | 5.19–5.26 |
| Mac | B | off | 237.9 | 207.2–254.2 | 0 0 0 0 0 | – |
| iPhone | A | off | 106.3 | 101.3–124.5 | 0 0 0 0 0 | – |
| iPhone | A | on | 107.9 | 106.3–140.1 | 0 0 0 0 0 | 5.55–6.19 |
| iPhone | B | on | 118.7 | 104.3–120.6 | 0 0 0 0 0 | 5.52–6.04 |
| iPhone | B | off | 104.1 | 97.8–122.0 | 0 0 0 0 0 | – |
| iPad | A | off | 249.9 | 233.9–862.4 | 2 0 0 0 0 | – |
| iPad | A | on | 245.9 | 228.9–282.6 | 0 0 0 0 0 | 8.53–8.99 |
| iPad | B | on | 247.4 | 240.1–249.5 | 0 0 0 0 0 | 8.57–9.46 |
| iPad | B | off | 235.4 | 234.2–248.8 | 0 0 0 0 0 | – |

Each window 10.5 s: 630 frames expected on the Mac (60 Hz), 1260 on the
devices (120 Hz). Thermal 0 (nominal) on every Sample line. Every on launch
printed `native=bound methods=3290 bound=1433 unbound=1857 generated=1048
declined=0 groups=888`; an off launch prints no native line. Binaries:
iPhone 2 149 376 bytes off, 4 980 160 on (app 8 736 and 11 500 KiB); the
first launch after an install is the slowest on either side (Mac off 688.5
ms, iPad off 862.4 ms with the only 2 frames missed of the 60 launches).

Rules 1 and 2: **met on all three**. Frames: the on launches missed 0
everywhere; the off launches' maximum is 0 (Mac, iPhone) and 2 (iPad).
First frame, on minus off by order: Mac +0.7 and +12.3 ms, iPhone +1.6 and
+14.6, iPad −4.0 and +12.0, all within 20 ms. (The Sample's idle window is
what the brief asked; it carries no load of its own, so the matrices above
are where a faster mutator could show.)

**Starting position 4: what a failed step does today** (`part1/failed-step-before.log`):
with `kajo aot` exiting 1 (a stub in place of the checkout's `kajo` that
runs the real one for every other command), the old `build-native.sh`
printed `native module: generating and compiling (macosx arm64)`, the
stub's own stderr, and Xcode's `Command PhaseScriptExecution failed with a
nonzero exit code`, then `** BUILD FAILED **` (exit 65). The build stops,
and nothing says how to build without the module; a compile failure printed
`error: the native module did not compile`, libtool and lipo failures
nothing of their own.

**Verdict.** The rule's Sample items are met on the Mac, the iPhone and
the iPad. The matrices meet rule 3 on the Mac in every row and on the
devices in every row but two kinds under the stop-the-world young
collector (iPhone storm, one frame in one of six rows; iPad ring, 28 frames
in six rows against 10), both with 0 fallbacks. Nothing under the core
directories or `Sources/KajoAOT/` is needed for the default; the brief's
open question 4 applies (built: the default as answered, reported here).

### Part 2: the default (f708fbd)

- `AppProjectSpec.native` defaults to `true`
  (`Sources/KajoGenerator/Generator.swift`); the template writes
  `KAJO_NATIVE: YES` with the comment "YES (the default)"; the Kajo app's
  New App… builds its spec without naming it and follows.
- `kajo new` reads its arguments through `NewArguments.parse` (new, in
  `KajoGenerator`, so a test reads them): `--no-native` writes NO,
  `--native` is accepted as the default it is, the last of the two wins
  (open question 1, built as recommended). The usage line names
  `[--no-native]`; the help text says the module is on and how to turn it
  off. Quoted runs (`part2/cli-runs.txt`, the repository's `kajo` against
  the part 1 checkout): no flag `KAJO_NATIVE: YES`, `--native` YES,
  `--no-native` NO; `--nativ` answers `unknown option --nativ` and the usage.
- `build-native.sh`: the by-hand default is `${KAJO_NATIVE:-YES}`; every
  step of its own that can fail (`kajo` missing, `kajo aot`, the compile per
  arch, `libtool`, `lipo`) ends in one line (open question 2, built as
  recommended). Quoted from `part2/failed-step-after.log` (the stub `kajo`
  of part 1, whose `aot` exits 1, on a project from this commit's `kajo
  new`):

  ```
  native module: generating and compiling (macosx arm64)
  stub: kajo aot exits 1
  error: the native module was not built: kajo aot failed. Set KAJO_NATIVE=NO (in project.yml, or on the xcodebuild line) to build the app without it; it then runs interpreted.
  ** BUILD FAILED **
  ```

  The image's own failure keeps `build-images.sh`'s message: it would fail
  the build with the module off too, so `KAJO_NATIVE=NO` is no answer to it.
- The generated README gains a bullet: Release compiles the image's
  methods to native code, and `KAJO_NATIVE=NO` turns it off.
- Tests (`Tests/KajoCompilerTests/AppProjectTests.swift`):
  `aSpecThatDoesNotNameTheModuleTurnsItOn` (a spec with no `native`
  argument writes YES, `native: false` NO and differs in that line only;
  the script's default and its failure line) fails on the starting
  commit with four expectations (`part2/start-test.log`: 30e14bd's tree
  from `git archive` with only this test added), and
  `kajoNewTurnsTheModuleOnUnlessToldNo` (no flag, `--native`, `--no-native`
  and both orders, each written and read back from `project.yml`; the
  refusals); the fixture's `project.yml`, `README.md` and
  `scripts/build-native.sh` follow, byte for byte
  (`theOutputForAFixedInputIsTheFixtureByteForByte`). 17 of 17 in
  `AppProjectTests` and `DistributionTests` (`part2/tests.log`).

### Part 3: `new-check` (30c2298)

The plain Release rows are now the native ones and every check keeps its
pair (`scripts/new-check.sh`; run on its own, `part3/new-check.txt`,
`new-check: ok`, every build 0 warnings):

- `macos-release` (from clean, 9 s): the release symbol and string checks
  with `KajoAOT=0`, `native_section=1`, the Mac launch `native=bound
  methods=3290 bound=1433 unbound=1857 generated=1048 declined=0 groups=888
  bind_ms=5.317`; `macos-release-again` `generated_in_build=0` (1 s);
  `macos-release-truncated` rebuilt and bound; `macos-release-stale`
  `native=refused reason="its layout hash is not this VM's build" (the image
  runs interpreted)`; `macos-release-changed` (below).
- The off rows, each the same product with `KAJO_NATIVE=NO` on the
  `xcodebuild` line: `macos-release-off` `native_section=0
  binary_bytes=2236672 on_bytes=5068832 no_files=1 app_bytes=8776KiB` (on:
  11 540 KiB); `ios-release-off` 2 126 008 against 4 951 272 bytes (8 656
  and 11 412 KiB); `ios-simulator-release-off` 2 126 136 against 4 974 936;
  all three with the release checks, no section and no file under
  `.build/kajo/native/<platform>/`. The iOS and simulator on rows carry the
  section (`ios-simulator-release: platform=IOSSIMULATOR`).
- The broken variant, by hand: the same script over a project made with
  `kajo new --no-native` (`APP_PROJECT`, `part3/new-check-broken.txt`) fails
  `macos-release: FAILED a plain Release binary has no module section`,
  `ios-release: FAILED no module section`, `ios-simulator-release: FAILED
  no module section` and the bind and cache rows, and ends `new-check:
  FAILED` (exit 1). That first run also wrote two files (`.cut`, `stamp`)
  into the directory it ran from, the cache rows having no library to
  name; the script now points them into its scratch directory, and the
  run again (`part3/new-check-broken2.txt`) fails the same rows and leaves
  nothing behind.

### Part 4: the cache (f708fbd)

`build-native.sh` removes every `.build/kajo/native/<key>/` (24 hex
characters) that no platform's `libkajo_native.a` link names, after its own
link is set (open question 3, built as recommended: one library per
platform). It prints `native module: libraries of earlier builds removed:
<n>`. `new-check`'s `macos-release-changed` row edits the app's class
comment and builds: `generated_in_build=1 keys_before=1 keys_after=1
old_key_left=0 native module: libraries of earlier builds removed: 1`, and
the launch binds. A platform turned off loses its link, so its library
goes at the next on build of another platform.

**Build times on the Mac, module on** (`part2/builds-mac.txt`, a project
of this commit's `kajo new`, Release by `xcodebuild`): from clean (no
DerivedData, no `.build`) 9.47 s (AOT 2: 10 s); unchanged 5.34 s the first
time and 1.20 s after; a changed image 5.35 s (the module generated and
compiled again, one library removed); `KAJO_NATIVE=NO` afterwards 1.72 s.
The phase by hand (`part2/phase-times.txt`): 3.84 s compiling, 0.111 s
unchanged (AOT 2: 3.7 to 4.2 and 0.11).

### Debug builds and the round trip

Debug products are unchanged in what they link (`new-check`'s debug rows
as before). `scripts/app-roundtrip.sh mac` (`part3/roundtrip.txt`,
`part3/roundtrip/roundtrip-mac.txt`; the Mac shell of part 1 for the
tools): the Debug launches, the idle window (630 of 630 frames), the live
window (1890 of 1890, `served_sessions=8 served_requests=17`, the Debug
frames line in its old form through `FrameWindow`), the CLI and tools
round trips, the rebuilt app starting with the change, and the Release
app serving nothing all passed; the Release build from clean 9.2 s, 11 540
KiB. One line failed: `FAILED host=mac step=bonjour (no Sample service
seen; trying the address)`, the script then talking to the address as it
is built to. The app advertised (`serving=tcp port=58602 …
name=Sample_on_Joni’s_Mac_mini`), and `dns-sd -B _kajo-dev._tcp local` run
by hand from this session printed nothing at all, not even its header:
this session's process tree sees no Bonjour, as 9d's lesson on Local
Network privacy describes. Not this module's (nothing on the Debug or
serving path changed but the frames window).

### Part 5: the docs

This "As built"; dated notes (the text above them not rewritten) at the
end of `docs/modules/aot-product.md` and of ADR 0015, and after the round
trip's sizes in `docs/modules/distribution.md` (a Release app with the
module and without).
