# Gate tiers and the weekly run

Status: briefed 2026-11-07, from the owner's decision of the same day
("When is the VM done so we can move on to the application side and not
run all these hours long fuzzers for every change?"; the tiers and the
Sunday run were accepted as recommended; no paid CI). Built 2026-11-07
(dc80549 and 3f2acdd, scripts and the justfile only; "As built" below).
The LaunchAgent is written, not loaded.

## What it hides

Which gates a change owes, and where the full set runs. A developer (or an
agent) runs `just check` and gets the tier the diff asks for; the complete
set with the device matrix runs on the Mac mini once a week by launchd and
leaves its files under `~/kajo-weekly/<date>/`; nothing of it runs on
GitHub.

## The tiers (as `AGENTS.md` Verification states them)

1. **Smalltalk only** (`kernel/`, `tools/`, `apps/Shared/smalltalk`): the
   image build, `just kernel-test`, the compiler tests
   (`swift test --filter KajoCompilerTests`), `just golden`, the Mac
   shell's tests mode (`scripts/mac-shell.sh` ... `mode=tests`).
2. **Swift outside the core** (anything else that is not under the core
   directories): clean build with 0 warnings, `swift test`, ThreadSanitizer
   once alone, `just kernel-test`, `just apps`, `just new-check`, and the
   one relevant fuzzer for 120 s (`Sources/KajoDev` or the protocol:
   `protocol`; `Loader/` or kasm: `kasm`; the snapshot writer or loader:
   `snapshot`; `Sources/KajoCompiler`: `syntax`; otherwise none).
3. **Core** (`Sources/KajoVM/{ObjectMemory,Interpreter,Loader,Workers,
   Processes,Nursery,Marking,Relocation,YoungCollection,ObjectModel}`):
   all 18 gates, the aligned A/B against the merge base, `just arc-check`,
   and the device rows (`scripts/shell-matrix.sh` on the Mac and the
   iPhone).

Docs-only diffs (`docs/`, `*.md`, `experiments/*/RESULTS.md`) owe nothing;
`just check` says so and exits 0. A diff that touches two tiers owes the
higher. The tier is decided from `git diff --name-only <base>...HEAD` plus
the working tree's changes, where `<base>` is `origin/master` by default or
the argument given.

## Deliverables

- `scripts/check-tier.sh [base]`: prints the tier and the files that chose
  it, then runs the tier's gates one after another, each into
  `<out>/<gate>.txt` with a `gates.log` line per start and end naming the
  commit, the toolchain and the exit status (the pattern of the final-mark
  module's `gates.sh`: `date commit start/end name rc=.. Ns`); exit status
  non-zero if any gate failed; `KAJO_CHECK_OUT` chooses the output
  directory (default `.build/check/<date>/`, gitignored); `--tier core|swift|smalltalk|none`
  overrides the decision; `--dry-run` prints what would run. `just check
  [base]` runs it.
- `scripts/weekly.sh`: the full set for the weekly run: refuses to start
  (exit 0, one line in the log) when anything of Kajo is running (a
  `kajo`, `swift-build`, `swift-test`, `xcodebuild`, `KajoShell`, `Sample`
  or `yes` process of this user, excluding its own process group); runs
  on `master` as checked out (it does not pull or change the tree; it
  says in the log if the tree is dirty and goes on); writes to
  `~/kajo-weekly/<YYYY-MM-DD>/`: the 18 gates with their load loops
  (`swift test` and ThreadSanitizer alone and under twelve `gtimeout 1500
  yes` loops, the four fuzzers one after another at 600 s each), `just
  arc-check`, then `scripts/shell-matrix.sh` on the Mac and on the iPhone
  (both devices if the iPad is attached: `xcrun devicectl list devices`
  decides), then a `summary.md` with one line per gate (pass/fail, time)
  and the matrices' frames-missed, fallbacks and longest-stop tabulation
  over every raw row (reuse `scripts/shell-report.py`), ending with a
  `weekly done` line; every wait bounded (`gtimeout`); kills its load
  loops and the shells it started on exit (a trap); never runs a device
  build when `codesign` would prompt: it tries once and, if `codesign`
  sits at 0 percent CPU for 60 s, kills it, writes the fact and skips the
  device rows.
- `scripts/launchd/dev.katajamaki.kajo.weekly.plist`: a user LaunchAgent
  for Sunday 02:00 running `scripts/weekly.sh` with `PATH` set so the
  swiftly toolchain is first (as the shell's is), `StandardOutPath` and
  `StandardErrorPath` under `~/kajo-weekly/launchd.log`; `just
  weekly-install` copies it to `~/Library/LaunchAgents/` and prints the
  `launchctl bootstrap gui/$(id -u) ...` command without running it (the
  owner or the main session loads it; agents do not change the machine);
  `just weekly-status` shows `launchctl print` for it; `just weekly`
  runs `scripts/weekly.sh` by hand.
- Releases: `scripts/release.sh <tag>` builds the Release `kajo` CLI and
  the development image on the mini, writes a tarball and its SHA-256,
  and prints the `gh release create` command (nothing is uploaded by the
  script itself in this module; the dmg is the distribution module's).
- `justfile` recipes `check`, `weekly`, `weekly-install`, `weekly-status`.
- The doc as built, with: the tier a sample diff of each kind decided
  (shown by `--dry-run`), one real run of tier 1 and tier 2 (the latter
  on this module's own diff, which is scripts only, so its tier is "Swift
  outside the core" without a fuzzer; say what ran), the time each took,
  and a `weekly.sh` run in a quick mode (`KAJO_WEEKLY_QUICK=1`: fuzzers at
  60 s, one matrix run instead of three, Mac only) proving the plumbing
  end to end with its `summary.md` quoted.

## The bar

- `just check` on a docs-only diff exits 0 in under a second saying so.
- `just check` on a Smalltalk-only diff runs exactly tier 1; on a Swift
  change outside the core exactly tier 2 with the right fuzzer; on a core
  change tier 3 (`--dry-run` for that one, and the doc shows the list).
- `weekly.sh` refuses when a Kajo process runs, and in quick mode finishes
  with a `summary.md` whose tabulation agrees with the raw rows.
- No change under `Sources/`, `kernel/` or `tools/`; nothing of this
  touches the VM.
- The LaunchAgent is not loaded by the agent.

## Not in this module

The dmg, notarization and the xcframework (the distribution module); any
GitHub Actions workflow (none; no paid CI).

## As built

Built 2026-11-07 by scripts only: nothing under `Sources/`, `kernel/` or
`tools/` changed and nothing of it touches the VM.

| file | what it does |
|---|---|
| `scripts/check-tier.sh [--dry-run] [--tier t] [--paths f\|-] [base]` | decides the tier, prints it with the files that chose it and the gates, runs them; `just check [args]` |
| `scripts/gates-lib.sh` | how one gate runs: its command line, bound (`gtimeout`), load loops and output check; the `gates.log` lines; sourced by `check-tier.sh` and `weekly.sh` |
| `scripts/check-tier-test.sh` | the decision's test: 36 checks of tiers, fuzzers and gate lists over sample paths, from `--dry-run` |
| `scripts/weekly.sh` | the weekly run; `just weekly` |
| `scripts/launchd/dev.katajamaki.kajo.weekly.plist` | the LaunchAgent, with `__HOME__` and `__REPO__` that `just weekly-install` fills in; `just weekly-status` |
| `scripts/device-rows.sh <udid> <out>` | a device's rows: the build with the codesign watchdog, `shell-matrix.sh device`, the report and the bar |
| `scripts/ab.sh <base> <out>`, `scripts/ab-table.py` | the aligned A/B of the core tier: the base exported with `git archive` against the working tree |
| `scripts/shell-report.py --bar <dir>` | the bar's columns over every raw row (below) |
| `scripts/release.sh <tag>` | the release tarball; `just release-tarball <tag>` (`just release` was already `swift build -c release`) |

### The decision

The files are `git diff --name-only <base>...HEAD`, `git diff --name-only
HEAD` (staged and unstaged) and the untracked files that are not ignored;
`<base>` is `origin/master` or the argument. Each file asks for one tier
by the first pattern it matches, and the diff owes the highest:

| tier | patterns (zsh `case`, in this order) |
|---|---|
| core | `Sources/KajoVM/(ObjectMemory\|Interpreter\|Loader\|Workers\|Processes\|Nursery\|Marking\|Relocation\|YoungCollection\|ObjectModel)/*` |
| smalltalk | `kernel/*`, `tools/*`, `apps/Shared/smalltalk/*` |
| swift | `Tests/*` before `*.md` (since the review fixes, part 2: a Markdown fixture is read byte for byte by a test); both diffs run with `--no-renames`, so a rename is judged by its old path and its new one; a matrix gate fails when its matrix, its report or its bar fails, and `--bar` over no rows exits 1 |
| none | `docs/*`, `*.md` (so `experiments/*/RESULTS.md`, `AGENTS.md`) |
| swift | everything else: `Sources/` outside the core (`KajoVM/Shell/`, `KajoVM/Headless.swift` among them), `Tests/`, `Package.swift`, `scripts/`, `justfile`, `apps/` but its Smalltalk, `models/`, `experiments/` code |

The fuzzers a swift-tier diff owes, 120 s each (one per file kind, the
union over the diff's files, in the order first met):

| fuzzer | files |
|---|---|
| protocol | `Sources/KajoDev/*`, `Sources/fuzz-protocol/*`, `Tests/KajoVMTests/Fixtures/fuzz/protocol/*` |
| syntax | `Sources/KajoCompiler/*`, `Sources/fuzz-syntax/*`, `Tests/KajoVMTests/Fixtures/fuzz/syntax/*` |
| kasm | `Sources/fuzz-kasm/*`, `Tests/KajoVMTests/Fixtures/fuzz/kasm/*` |
| snapshot | `Sources/fuzz-snapshot/*`, `Tests/KajoVMTests/Fixtures/fuzz/snapshot/*` |
| all four | `scripts/fuzz.sh` |

The kasm parser, the snapshot writer and the loader all live in
`Sources/KajoVM/Loader/`, a core directory, so a change to them is tier 3
and runs every fuzzer at 600 s; the brief's "`Loader/` or kasm" and "the
snapshot writer or loader" rows of tier 2 are reached only through the
fuzz targets and their seeds.

The gates of each tier, in the order they run:

| tier | gates |
|---|---|
| none | nothing: "nothing owed: docs only", exit 0 |
| smalltalk | `build-image` (`kajo build-image`), `dev-image` (`--with tools`), `kernel-test`, `tools-test` (`kajo test dev.img`, the kernel's and the tools' tests), `compiler-tests` (`swift test --filter KajoCompilerTests`), `golden`, `mac-shell-tests` (`mac-shell.sh build`, then `mode=tests`; passes on a result line with failed=0 errored=0 vm_error=0) |
| swift | `clean-build` (0 warnings, 0 errors), `swift-test`, `tsan` (once, alone), `kernel-test`, `apps`, `new-check`, `fuzz-<t>` per the table, and `model-check` when `models/` changed |
| core | the 18 gates of the final-mark module (`clean-build`, `swift-test`, `swift-test-load`, `tsan`, `tsan-load`, `ios-check`, `arc-check`, `golden`, `test-release`, `model-check`, `soak`, the four fuzzers at 600 s, `apps`, `kernel-test`, `new-check`), `ab` against the merge base, `matrix-mac` and `matrix-iphone` (`shell-matrix.sh`, RUNS 3) |

Every gate's output is `<out>/<gate>.txt`; a fuzz gate fails without the
"libFuzzer build: ok" line (AGENTS.md: the fallback driver is not a fuzz
gate), `clean-build` and `ios-check` fail on any compiler warning or error
in their output. The load loops are twelve `gtimeout 1500 yes`, replaced as
they end, counted and killed by their own parent only, never another
`yes` of the user.

### Sample diffs (`--dry-run`)

Real commits' file lists through `--paths`, 2026-11-07 (outputs in the
session's `gatetiers/dry-run/`):

| commit | files | tier | fuzzers | gates |
|---|---|---|---|---|
| 8c3e80f (distribution.md brief) | `docs/PLAN.md`, `docs/modules/distribution.md` | none | - | none: "nothing owed: docs only", exit 0 |
| ae1b0d6 (plainBytecodes position) | `kernel/CompiledMethod.class.st` | smalltalk | - | 7 |
| ad0b433 (the devices investigation's instruments) | 10, `Sources/KajoDev/Server.swift` and `Sources/KajoShellCore/` | swift | protocol | 7 |
| c657344 (the parser's chains) | `Sources/KajoCompiler/Syntax.swift` and two tests | swift | syntax | 7 |
| e417519 (interpreter speed, part 3) | `Sources/KajoVM/Interpreter/Dispatch.swift` | core | all four at 600 s | 21 |
| this module (dc80549 against origin/master) | 11 scripts and the justfile | swift | none | 6 |

The core tier's list as `--dry-run` prints it (`<out>` the output
directory; the A/B's base is the merge base with `origin/master`):

```
gates (21), output in <out>:
  clean-build: rm -rf .build/clean-check && swift build --scratch-path .build/clean-check (check: clean) [bound 3600s]
  swift-test: swift test [bound 3600s]
  swift-test-load: swift test (under twelve gtimeout 1500 yes loops) [bound 3600s]
  tsan: swift test --sanitize=thread --scratch-path .build/tsan-check [bound 10800s]
  tsan-load: swift test --sanitize=thread --scratch-path .build/tsan-check (under twelve gtimeout 1500 yes loops) [bound 10800s]
  ios-check: just ios-check (check: clean) [bound 3600s]
  arc-check: just arc-check [bound 3600s]
  golden: just golden [bound 3600s]
  test-release: just test-release [bound 3600s]
  model-check: just model-check [bound 3600s]
  soak: just soak [bound 3600s]
  fuzz-kasm: just fuzz kasm 600 (check: libfuzzer) [bound 2400s]
  fuzz-snapshot: just fuzz snapshot 600 (check: libfuzzer) [bound 2400s]
  fuzz-syntax: just fuzz syntax 600 (check: libfuzzer) [bound 2400s]
  fuzz-protocol: just fuzz protocol 600 (check: libfuzzer) [bound 2400s]
  apps: just apps [bound 3600s]
  kernel-test: just kernel-test [bound 3600s]
  new-check: just new-check [bound 3600s]
  ab: scripts/ab.sh 8c3e80f <out>/ab [bound 7200s]
  matrix-mac: scripts/mac-shell.sh build && { RUNS=3 scripts/shell-matrix.sh mac <out>/matrix-mac; scripts/shell-report.py <out>/matrix-mac > <out>/matrix-mac/report.md; scripts/shell-report.py --bar <out>/matrix-mac; } [bound 21600s]
  matrix-iphone: RUNS=3 scripts/device-rows.sh 00008110-001855C63642801E <out>/matrix-iphone [bound 25200s]
```

`scripts/check-tier-test.sh` asserts the decision over 36 cases (each
core directory, `KajoVM/Shell/` and `Headless.swift` as swift, mixed
diffs owing the higher tier, each fuzzer, the gate list of each tier, and
the docs-only exit) in about a second.

### Tier 1, one real run

`KAJO_CHECK_OUT=… scripts/check-tier.sh --tier smalltalk` on dc80549 (the
tier forced: this module's own diff asks for swift), Mac mini (M2 Pro),
swift.org 6.4.2 first on PATH, 2026-11-07 20:36:57 to 20:42:52, **355 s**:

| gate | result | time |
|---|---|--:|
| build-image | 171 classes, 2078 methods, 5.1 MB | 3 s |
| dev-image | 199 classes, 2442 methods, 6.1 MB | 3 s |
| kernel-test | 205 of 205 | 74 s |
| tools-test | 235 of 235 (the kernel's and the tools') | 85 s |
| compiler-tests | 115 tests in 20 suites | 93 s |
| golden | every checksum ok | 68 s |
| mac-shell-tests | total=205 passed=205 failed=0 errored=0 vm_error=0 | 29 s |

### Tier 2, on this module's own diff

`just check` on 3f2acdd, the final code commit, with no arguments: the
files are `origin/master...HEAD` (8c3e80f...3f2acdd), 11 of them, all
scripts and the justfile, so tier swift with no fuzzer; 2026-11-07 23:18:47
to 2026-11-08 00:19:28, **3641 s** (61 min), nothing else running:

| gate | result | time |
|---|---|--:|
| clean-build | exit 0, warnings=0 errors=0 (the toolchain's compilation cache) | 23 s |
| swift-test | 385 + 115 passed | 398 s |
| tsan | 385 + 115 passed, 0 reports | 2820 s |
| kernel-test | 205 of 205 | 76 s |
| apps | macOS and iOS exit 0, 0 errors, 0 warnings | 111 s |
| new-check | ok | 213 s |

ThreadSanitizer is 77 percent of the tier; tier 2 is an hour whatever the
diff, tier 1 six minutes.

### The A/B

`scripts/ab.sh` ran once for real, small (`RUNS=1 KERNELS="fib sends
st-sends" WORKERS=1`, base 8c3e80f against 3f2acdd's tree, which has the
same Swift code): 115 s with both aligned builds, ratios 1.001, 1.001 and
1.004, cycles per send 58.1 / 58.3, 69.7 / 70.0 and 116.6 / 116.5,
checksums the same. The full A/B (5 runs, 9 kernels, 1 and 8 workers) is
the core tier's and did not run here.

### The weekly run in quick mode

`KAJO_WEEKLY_QUICK=1 scripts/weekly.sh` on dc80549, run under `env -i`
with exactly the LaunchAgent's environment (its `PATH` and swiftly
variables, `HOME`, `USER`, `LOGNAME`, `SHELL`, `TMPDIR`), into
`~/kajo-weekly/2026-11-07-quick/`, 20:43 to 23:07 (144 min). Its
`summary.md`:

```
| gate | result | time |
|---|---|--:|
| clean-build | pass | 24s |
| swift-test | pass | 405s |
| swift-test-load | pass | 543s |
| tsan | pass | 2973s |
| tsan-load | pass | 3572s |
| ios-check | pass | 17s |
| arc-check | pass | 7s |
| golden | pass | 68s |
| test-release | pass | 19s |
| model-check | pass | 21s |
| soak | pass | 72s |
| fuzz-kasm | pass | 63s |
| fuzz-snapshot | pass | 63s |
| fuzz-syntax | pass | 83s |
| fuzz-protocol | pass | 63s |
| apps | pass | 113s |
| kernel-test | pass | 76s |
| new-check | pass | 214s |
| matrix-mac | FAIL (rc=1) | 276s |

## matrix-mac (every raw row of matrix-mac/*.txt; full tables in matrix-mac/report.md)

| file | rows | launches failed | checksums not ok | rows missing frames | frames missed | rows with no frames | rows falling back | fallbacks | longest stop ms |
|---|--:|--:|--:|--:|--:|--:|--:|--:|---|
| drift | 6 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| golden | 36 | 0 | 24 | 0 | 0 | 0 | 0 | 0 | - |
| scenarios | 10 | 0 | 0 | 2 | 690 | 0 | 1 | 23 | 183.09 (full) |
| events | 2 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.35 (initialMark) |
| hog | 2 | 0 | 0 | 1 | 1193 | 0 | 0 | 0 | 0.00 (other) |
| all | 56 | 0 | 24 | 3 | 1883 | 0 | 1 | 23 | 183.09 (full, scenarios: ... scenario=ring young=stw ...) |

(then one line per row that missed, fell back or failed, the fallback records in full)

failed: matrix-mac

weekly done 2026-11-07 23:07:44 (144 min)
```

The one failure was the tabulation's, not the matrix's: `--bar` counted a
golden row's `ok=-1` (2 and 6 workers, where no checksum is published) as
a bad checksum; fixed in 3f2acdd (only `ok=0` or an error counts). Read
with the fix the same rows give 0 checksums not ok and pass. Every other
number agrees with the raw rows, counted again with `awk` over the files
(scenarios 10 rows, 690 frames missed in 2 rows, 23 fallbacks; hog 1193 in
1 row; events, drift and golden 0; no `FAILED`). The misses are the known
ones: the ring under the stop-the-world young mode (23 counted soft-limit
fallbacks, compacting full collections up to 183 ms; the interpreter-speed
module's open question), the matrix's first idle launch (428 frames, the
unexplained first-launch gap that module saw as 595), and the hog with the
budget off, which misses by design. The ThreadSanitizer outputs hold 0
reports; the fuzzers each printed "libFuzzer build: ok" (0.05 to 0.33
million runs in 60 s). `arc-check` (7 s) and `test-release` (19 s, 385 +
115 tests) were fast because their release scratch paths were built.

The device step, proved separately with the fix (`KAJO_WEEKLY_QUICK=1
KAJO_WEEKLY_DEVICES=1 KAJO_WEEKLY_ONLY="matrix-mac matrix-iphone"`, the
same environment, a scratch root, 3f2acdd, 23:08 to 23:18): `devicectl`
listed both devices (`devices: ipad iphone`), the iPhone was built, signed
(no prompt) and installed in 49 s and its matrix ran once (56 launches,
329 s); summary:

```
| matrix-mac | pass | 276s |
| matrix-iphone | pass | 329s |

matrix-mac  all | 56 | 0 | 0 | 2 | 1524 | 0 | 1 | 30 | 186.86 (full, ring young=stw)
matrix-iphone all | 56 | 0 | 0 | 1 | 1192 | 0 | 0 | 0 | 13.44 (scavenge, ring young=stw)
```

(the iPhone's one row missing frames is the hog with the budget off).

### The LaunchAgent

`scripts/launchd/dev.katajamaki.kajo.weekly.plist`, as `just
weekly-install` writes it on the mini (`plutil -lint` OK):

```
Label                  dev.katajamaki.kajo.weekly
ProgramArguments       /bin/zsh /Users/jonikatajamaki/code/kajo/scripts/weekly.sh
WorkingDirectory       /Users/jonikatajamaki/code/kajo
EnvironmentVariables   PATH /Users/jonikatajamaki/.swiftly/bin:/opt/homebrew/bin:/opt/homebrew/sbin:
                            /Users/jonikatajamaki/.cargo/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
                       SWIFTLY_HOME_DIR, SWIFTLY_BIN_DIR, SWIFTLY_TOOLCHAINS_DIR
StartCalendarInterval  Weekday 0, Hour 2, Minute 0
ProcessType            Interactive
RunAtLoad              false
StandardOutPath        /Users/jonikatajamaki/kajo-weekly/launchd.log
StandardErrorPath      /Users/jonikatajamaki/kajo-weekly/launchd.log
```

To load it (the owner or the main session; no agent does):

```
just weekly-install
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.katajamaki.kajo.weekly.plist
just weekly-status        # launchctl print gui/$(id -u)/dev.katajamaki.kajo.weekly
launchctl bootout gui/$(id -u)/dev.katajamaki.kajo.weekly       # to unload
```

A plist in `~/Library/LaunchAgents/` is loaded at the next login even
without `bootstrap`, so `just weekly-install` is itself the decision; it
was not run in this module.

`weekly.sh` refuses at once with one line in `~/kajo-weekly/weekly.log`
(exit 0) when a `kajo`, `swift-build`, `swift-test`, `xcodebuild`,
`KajoShell`, `Sample` or `yes` process of the user runs outside its own
process group, matched by exact executable name (`ps -o ucomm`), so the
owner's node, updater and game server never match. Tested: a `yes` in
another session refused it (`weekly refused: Kajo is running: yes(33380)`),
a `yes` in its own process group did not.

### Deviations from the brief

- Tier 1 also builds the development image and runs its tests
  (`dev-image`, `tools-test`): `tools/` is tier 1 and its SUnit tests live
  only in that image.
- Tier 2 adds `just model-check` when `models/` changed; the brief's tier 2
  would otherwise run nothing that reads the models.
- Several fuzzers when the diff touches several readers' files (the union),
  and all four for `scripts/fuzz.sh`.
- The tier-2 fuzzers for kasm and snapshot are reachable only through
  their fuzz targets and seeds; the readers themselves are under
  `Loader/`, a core directory (above).
- `KAJO_CHECK_OUT`'s default directory is one per day; a second run the
  same day appends to its `gates.log` and replaces the gate files.
- The quick weekly run writes `<date>-quick/`, so it is never mistaken for
  a Sunday's; `KAJO_WEEKLY_ONLY`, `KAJO_WEEKLY_DEVICES` and
  `KAJO_WEEKLY_ROOT` were added to prove the device step apart.
- `arc-check` runs once, among the 18, not again after them.
- The release recipe is `just release-tarball <tag>`: `just release` was
  already the release build.
- The device rows' DerivedData are per device (the iPhone's
  `$TMPDIR/kajo-shell-ios`, the iPad's `$TMPDIR/kajo-shell-ipad`, as the
  earlier modules used).

### Not done

- The LaunchAgent is not loaded and `just weekly-install` was not run.
- No full weekly run (fuzzers at 600 s, three matrix runs, both devices);
  the first is the first Sunday after loading.
- The codesign watchdog's skip path never fired: the iPhone build signed
  without a prompt, and no test simulates a waiting `codesign`.
- `scripts/release.sh` was not run (it refuses a dirty tree and wants a
  tag); `scripts/ab.sh` ran only as described under "The A/B".
- The iPad's rows in the weekly run were not run (the brief asks for the
  iPhone; both are found and listed).
- A display asleep at 02:00 delivers no frames; the summary counts rows
  with no frames but nothing wakes the display.

### Open questions for the owner

1. Wake the display for the Sunday matrix (`caffeinate -u -t 5` before
   the matrix, or a `pmset repeat wakeorpoweron` at 01:55)? Built: nothing
   wakes it; rows with no frames are counted in the summary.
2. A diff touching two tiers owes the higher, as briefed; a swift change
   with a Smalltalk one then skips `golden` and the Mac shell's tests mode.
   Union the lower tier's gates? Built: the higher only.
3. `experiments/` code (not `RESULTS.md`) is tier 2 as briefed although
   nothing in the root package builds it. Make it tier none? Built: tier 2.
4. Should `check-tier.sh` refuse, like `weekly.sh`, while another Kajo
   run is going? Built: it does not; two gate runs at once measure each
   other.

### This module's gates

This module's own diff is tier 2 without a fuzzer, and its gates are the
tier 2 run above, made by its own `scripts/check-tier.sh` on 3f2acdd: every
gate passed. `scripts/check-tier-test.sh` passes 36 of 36. The docs-only
case on the real diff: `just check 3f2acdd` with this doc committed on top
(fad3bdf) printed `tier: none`, the one file and "nothing owed: docs
only", exit 0 in 0.10 s.
