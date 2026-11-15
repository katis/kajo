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
