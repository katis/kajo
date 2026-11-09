# The first launch's gap

A measurement follow-up to the shells (module 9a) and the gate tiers.
Briefed 2026-11-09 by the main session as a bug follow-up (the fourth
occurrence; the owner's standing rule is that small bug follow-ups need no
decision).

## What is wrong

The first idle launch of a freshly built Mac shell misses hundreds of
frames of its 1200 and no later launch of the same binary misses any:
595 behind a 4.97 s gap (the interpreter module, 2026-11-07), 428 behind
3.6 s (the gate-tiers quick run), 335 (the first weekly run, 2026-11-08),
344 (the sweep-stop gate) and 272 (the collections-speed gate, 2026-11-09).
In every case the row's `stops` are 0 and its longest stop 0.0 ms, so the
VM stopped nothing; the gap is somewhere between the display link's frames
with the main thread not running Smalltalk. `AGENTS.md`'s lesson reads the
first idle row beside its gap and stop count until this is explained; the
weekly summary and every `--bar` carry the row as a miss.

The idle scenario is the first row `shell-matrix.sh` runs after
`xcodebuild`; the binary is new to the system (Gatekeeper's and XProtect's
first-launch assessment, the dyld closure, the code-signature validation
of a 45 MB app, the image bundles' first read) and the shell's own first
work (bundled image load, the checkout copy of the product mode does not
run in `mode=scenario`, the display-sleep assertion, the App Nap activity)
all happen once. Which of them takes 3 to 5 s is unknown; nothing in the
VM is suspected, and the brief names no suspect: the trace decides
(`AGENTS.md`: "A constant wait is found by a trace, not by its suspects").

## Parts

1. **Where in the launch the gap sits.** The Mac shell's scenario mode
   gets the sample's launch trace (`kajo-launch-report`'s shape:
   `launch step=<name> ms=` per step from process start, already in
   `Sources/KajoApp/Application.swift`), extended with the measurement's
   own steps (image loaded, VM started, first frame, measurement window
   start, first frame of the window) and a per-frame record of the window's
   gaps over 100 ms with their position in the window (ms from its start)
   and what the main thread was doing (the last Smalltalk turn's end, the
   last view call, whether a display-link callback came). Reproduce: build
   the shell from clean (`scripts/mac-shell.sh`'s build, or `just apps`),
   run the idle row once, read the trace; repeat with five fresh builds
   (change nothing, clean the derived data, build again) and five re-runs
   of each binary. The table: build, launch (first or later), frames
   missed, gap ms, where the gap sits (before the window, at its start,
   inside it), the step that spans it.

2. **What the system does to a new binary in that time.** Beside the
   trace read the unified log for the launch (`log show` bounded to the
   launch's seconds, predicates on the shell's pid and on `syspolicyd`,
   `XprotectService`, `amfid`, `trustd`, `dyld`, `taskgated`,
   `RunningBoard`), and the process's own state in the gap (`sample` of
   the pid for 2 s started 1 s into the launch, or `spindump` if the
   sampling needs no privilege; nothing with `sudo`). Say which it is:
   the system's one-time assessment of the binary, a block in the shell's
   own launch (a name lookup, a bundle read, a first-time cache), or a
   gap in the display link itself. If it is the system's, say what the
   shell could do about it (nothing is an acceptable answer) and whether
   a notarized and stapled binary (the dmg's) shows the same gap: the
   dist checkout's app (`scripts/dist.sh` builds one unsigned-for-
   distribution if no identity is usable; use what `.build/dist/0.1/stage`
   already holds, or build the app alone) launched the same way, if it
   can run the scenario mode, else say so.

3. **The warm-up launch.** `shell-matrix.sh` runs one idle launch of the
   freshly built shell before its first row and does not record it as a
   row (a `warmup` line in the raw file so the summary can count it, never
   in the tables or `--bar`); `device-rows.sh` and the weekly's matrices
   inherit it through the script. If part 2 finds a cause the shell can
   remove, remove it as well, with its own before-and-after row; the
   warm-up stays either way, because the system's first-launch work is
   outside the shell. `shell-report.py` reads the `warmup` line and prints
   it beside the summary (frames missed, gap) so the effect stays visible.
   `scripts/check-tier-test.sh` and the weekly's summary are unchanged
   unless a reader needed the new line's shape; if so, the fixture.

4. **Measure.** Five fresh builds through the changed `shell-matrix.sh`,
   the idle row's frames missed and gap on every one (the bar: 0 frames
   missed in the first recorded idle row of every build), the warm-up
   line's own numbers, and the iPhone's matrix once through
   `device-rows.sh` to show the warm-up runs there and costs one launch
   (its first row has never shown the gap; say whether the warm-up line
   on the phone misses frames). No A/B: nothing under `Sources/KajoVM`
   changes, the tier is Swift outside the core (`KajoShellCore`,
   `KajoApp`, scripts), which `just check` picks itself.

## Bar

- The table of part 1 over at least five fresh builds and their re-runs,
  the step that spans the gap named, the system's part of it read from
  the log (part 2), with the finding stated as one of the three cases.
- `shell-matrix.sh` runs a warm-up launch that is not a row; the first
  recorded idle row misses 0 frames in five of five fresh builds on the
  Mac; `shell-report.py` shows the warm-up line's numbers; `--bar` and
  the tables are unchanged in shape for the existing raw files
  (`scripts/check-tier-test.sh` passes, the weekly summary of
  `~/kajo-weekly/2026-11-08/` re-rendered by `shell-report.py` reads the
  same as before).
- The iPhone matrix once with the warm-up, 0 fallbacks and the usual rows.
- The Swift tier passes on the final code commit through `just check`
  with its `gates.log` quoted; nothing under `Sources/KajoVM` changes (if
  something must, stop and say what).
- `AGENTS.md`'s lesson on the first idle row is for the main session to
  amend; the module doc says what the lesson should now say.

## Open questions for the owner (build the recommended option, list the question)

1. Should the warm-up launch be a row of its own kind in the weekly
   summary (so the first-launch cost is tracked week to week) or only
   a line in the raw file? Recommended: a line in the raw file and one
   number in the summary's header, not a row.
2. If the gap is the system's assessment of a new binary, should the
   release's dmg be launched once on the mini after notarization as a
   smoke test, with the first-launch time recorded in the release notes?
   Recommended: yes, as a line `scripts/release.sh` prints, built later
   with the release module's next change, not here.
