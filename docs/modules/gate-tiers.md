# Gate tiers and the weekly run

Status: briefed 2026-11-07, from the owner's decision of the same day
("When is the VM done so we can move on to the application side and not
run all these hours long fuzzers for every change?"; the tiers and the
Sunday run were accepted as recommended; no paid CI).

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
