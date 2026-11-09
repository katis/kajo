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

## As built (2026-11-09)

Built on master from 5ff1cd4: d4fc4eb (the trace), cda1177 (the fix and
the warm-up). Nothing under `Sources/KajoVM`, `kernel/` or `tools/`
changed. The raw files are kept outside the repository (the main
session's scratchpad `firstlaunch/`: `traces/`, `logs/`, `after/`,
`iphone/`, `check/`).

### The finding

**It is not the first launch of a new binary, and it is the display, not
the shell: the system turned the display off inside the window.** The
brief's premise that the idle row is the first launch after `xcodebuild`
does not hold: `shell-matrix.sh` runs 3 drift and 108 golden launches (36
per round) first, and the gapped row is the first *scenario* launch
after them. The golden launches declare user activity (which wakes the
display) but held no display assertion, and the Mac mini's user had been
idle past the display-sleep time. With nothing holding the display,
powerd asked for the display off whenever a launch exited ("Time to turn
off display", every 12 to 15 s in the gapped runs, 30 s in others), the
next launch's user activity woke it again, and the display cycled off and
on through the whole golden phase (`pmset -g log`: 5 offs in b2's 74 s
golden prefix; the weekly run of 2026-11-08 and both gate runs of that
day cycle every 12 to 13 s). The first scenario launch takes its
`PreventUserIdleDisplaySleep` assertion at its link's start, but an off
powerd had already asked for between the last golden launch and it
landed in its window anyway, the assertion notwithstanding (b2:
requested at 03:37:44.540 as the last golden launch exited, the request
answered with error 1010, WindowServer's "Will Sleep" and `Display 2
setEnabled:0` at 03:37:52.27 with the assertion 7 s old). From then on
every scenario launch releases a display assertion when it exits, which
turns on powerd's own `delayDisplayOff` and bridges the gap to the next
launch, so no later launch of the matrix sees an off: the row's "only the
first launch" was the matrix's order, and "freshly built" a coincidence
of every gate starting its matrix after a build.

Of the brief's three cases it is the third, **a gap in the display link
itself**: the link delivered nothing because the display was off. The
main thread was free throughout: the `screens-sleep` notification
reached the main queue at 6500.3 ms of the window, the gap began at
6496.4 ms and ran to the window's end (3503.6 ms, 419 frames), the
callback lateness never passed 1.75 ms and the longest turn was 3.19 ms,
with no stop. The three historic gapped rows match: in every one `pmset
-g log` has "Display is turned off" inside the launch, 8 s after it took
its assertion (2026-11-08 04:54:22, 18:20:11 and 21:47:52), and on again
at the next launch's start.

The system's first-launch work on a new binary is real but is not this
gap: b1's first launch (display asleep, no launch before it) spent 392 ms
before `main` against 5 to 6 ms in every later launch, with amfid,
XprotectService and syspolicyd working on the new binary in those
milliseconds (the log of `b1-l1`), all of it before the window, which
missed nothing. A notarized and stapled binary was not launched: none
exists on the mini (no Developer ID, no notary profile), and the cause is
the display's power state, not the binary's assessment, so any binary
launched after the golden phase would see it.

### Part 1: the trace and the table

The Mac shell's `main`, `applicationDidFinishLaunching` and the scenario
mode write `launch step=<name> ms=<ms from process start>` with
`kajo-launch-report` among the arguments (main, did-finish-launching,
host-ready, mode-start, image-opened, vm-started, window-opened,
load-started, link-started, first-tick, window-start, window-first-frame,
window-end). Every display-link gap over 100 ms from the link's start to
the window's end is recorded (`FrameGaps`, `Sources/KajoShellCore/
FrameGaps.swift`): where it sits (before, start, inside, after the
window, ms from the window's start), its length, the lateness of the
callback that ended it (a gap still open at the window's end is recorded
as open), the last turn's end and the last view call before it, the
turns in it, and, when tracing (`kajo-launch-report` or `trace=1`), a
10 ms main-queue heartbeat's beats and longest silence in it and the
system's notifications (activation, screen parameters, occlusion, screens
and system sleep and wake, space) with their times; written as `trace
gap` and `trace event` lines after the window, never during it. The
result line gains `gaps100` and `gap_max_at_ms` (appended; every reader
is by key).

A gapped launch (b2, launch 1; `traces/b2-l1.out`):

```
launch step=main ms=6.4
launch step=did-finish-launching ms=97.4
launch step=host-ready ms=142.0
launch step=mode-start ms=162.3
launch step=image-opened ms=192.5
launch step=vm-started ms=192.6
launch step=window-opened ms=211.2
launch step=load-started ms=211.2
launch step=link-started ms=212.0
launch step=first-tick ms=246.6
launch step=window-first-frame ms=1217.4
launch step=window-start ms=1221.8
launch step=window-end ms=11272.3
trace event=inactive-at-link at_window_ms=-999.3 process_ms=212.0
trace event=screens-sleep at_window_ms=6500.3 process_ms=7711.5
```

The step that spans the gap is the window itself (from its first frame
to its end): every launch step finished in 1.2 s, the gap opened 6.5 s
into the window. (b2 ran before the open-gap record existed, so no
`trace gap` line closes it; the row's `gap_max_at_ms=6496.4` and
`gap_max_ms=3503.634` place it.)

Five fresh builds (`rm -rf` of the DerivedData, `scripts/mac-shell.sh
build`) and re-runs of the idle row (`workers=7 seconds=10`), the first
launch of each after the matrix's own prefix (drift and one round of
golden, `RUNS=1`) but for b1; offs from `pmset -g log`:

| build | prefix | display offs in the prefix | launch 1: missed, max gap ms, where | launches 2 to 6: missed, max gap ms |
|---|---|--:|---|---|
| b1 | none (display asleep, woken by launch 1) | - | 0, 8.4 | 0, 8.4 in each |
| b2 | drift + 36 golden | 5 | **419, 3503.6, inside from 6.50 s to the end; display off at 03:37:52 inside it** | 0, 8.4 in each |
| b3 | drift + 36 golden | 2 | 8, 69.8 (`sample` running in the launch; no off in it) | 0, 8.4 in each |
| b3 again (b3r) | drift + 36 golden | 2 | 0, 8.4 (no off in it) | 0, 8.4 (one re-run) |
| b4, the fix | drift + 36 golden | **0** | 0, 8.4 | 0, 8.4 in each |
| b5, fix disabled | drift + 36 golden | 2 | 0, 8.4 (no off in it) | 0, 8.4 in each |
| weekly 2026-11-08 | drift + 108 golden | every 12 to 15 s | 335, 2803.8; off at 04:54:22 inside it | 0 |
| gate 2026-11-08-final | drift + 108 golden | every 12 to 13 s | 353, 2947.5; off at 18:20:11 inside it | 0 |
| gate 2026-11-08-final2 | drift + 108 golden | every 12 to 13 s | 344, 2873.1; off at 21:47:52 inside it | 0 |

Without the fix the gap needs an off to fall inside the window, so it
depends on the cycle's phase: with the 12 to 15 s cycle of the historic
runs and b2 every first scenario launch met one; with the 30 s cycle of
b3 to b5 none did. With the fix the display never went off in a prefix
or a matrix.

### Part 2: what the system did

`logs/b2-l1.log` (`log show` bounded to the launch, powerd, WindowServer,
syspolicyd, XprotectService, amfid, trustd, taskgated, runningboardd,
dyld and the shell):

```
03:37:44.540 powerd  Time to turn off display - kerAssertionBits 16. ...
03:37:44.560 powerd  Display request 967 failed with error code 1010
03:37:44.789 powerd  Process Kajo.95476 Created PreventUserIdleDisplaySleep "Kajo shell measurement"
03:37:52.262 WindowServer  [ Display:Power ] Broadcast: Will Sleep
03:37:52.274 WindowServer  Display 2 setEnabled:0
03:37:52.324 powerd  Process Kajo.95476 Summary PreventUserIdleDisplaySleep ... age:00:00:07
03:37:55.850 powerd  TurnedOn InternalPreventDisplaySleep "com.apple.powermanagement.delayDisplayOff"
```

The `sample` of b3's first launch (3 s from 8 s in, `logs/b3-l1.sample`)
shows the main thread in `nextEventMatchingMask` waiting on its run loop;
that launch met no off, so it shows the shell's own idle state, not the
gap's. Nothing with privileges was run. The Claude Code harness holds a
`caffeinate -i` assertion (system sleep, not the display) which powerd
lists beside the shell's; it does not hold the display.

What the shell can do: hold the display for the whole life of every
measurement launch. Since cda1177 the Mac shell's `main` creates a
`PreventUserIdleDisplaySleep` assertion ("Kajo shell launch") before it
declares user activity whenever a `mode=` argument is present, released
when the process exits; the product (no `mode=`) holds none. The golden
launches then release an assertion at exit like the scenario launches,
powerd's `delayDisplayOff` bridges the gaps between launches, and no off
is asked for. Its before-and-after row: b2's first idle launch after the
prefix, 419 missed with 5 offs in the prefix, against b4's, 0 missed
with 0 offs, neither with a warm-up.

### Part 3: the warm-up

`shell-matrix.sh` runs one idle launch (`tag=warmup`, the matrix's
workers and seconds) before its first part into `warmup.txt`, `WARMUP=0`
leaves it out; the Mac and the devices (through `device-rows.sh`) and the
weekly inherit it. It is a file of its own rather than a line inside an
existing raw file, so no reader of the existing files changes: the
tables and `--bar` read the same five files as before, and
`shell-report.py` prints, before its tables and before the bar, one line
`warm-up launch (not a row): missed N of E, max gap X ms at Y ms of the
window, gaps over 100 ms N` when the file exists. The weekly summary
shows it through `--bar` under each matrix's heading. On every existing
raw directory (the weekly's three matrices of 2026-11-08 and the gate's
`2026-11-08-final2`) both outputs are byte for byte those of 5ff1cd4's
script; `scripts/check-tier-test.sh` passes (36 checks). The warm-up
alone would not have removed this gap (it runs before the golden phase,
the gap came after it); it stays for the system's first-launch work
(b1's 392 ms before `main`), which is outside the shell.

### Part 4: the rows

Five fresh builds of cda1177 through the changed `shell-matrix.sh`
(`RUNS=1`, parts drift, golden and scenarios: the warm-up, 3 drift, 36
golden and 10 scenario launches each, `after/a1` to `a5`):

| build | warm-up: missed, max gap ms | first recorded idle row: missed, max gap ms | display offs inside the matrix | bar (all rows) |
|---|---|---|--:|---|
| a1 | 0, 8.4 | 0, 8.4 | 0 | 193 missed, all in ring under `young=stw` (9 counted fallbacks) |
| a2 | 0, 8.4 | 0, 8.4 | 0 | 185, the same row (8) |
| a3 | 0, 8.4 | 0, 8.4 | 0 | 185, the same row (8) |
| a4 | 0, 8.4 | 0, 8.4 | 0 | 220, the same row (10) |
| a5 | 0, 8.4 | 0, 8.4 | 0 | 184, the same row (8) |

The four offs `pmset` logged in that hour all fell 4 s after a matrix
ended, during the next build.

The iPhone 13 Pro once through `scripts/device-rows.sh` on cda1177
(`RUNS=3`, 5 workers, built and installed in 20 s with no prompt,
`iphone/`): the warm-up ran first and cost one launch (157 launches for
156 rows); its line, `missed 0 of 1200, max gap 8.366 ms at 4505.4 ms of
the window, gaps over 100 ms 0`, thermal nominal; the first recorded
idle row 0 missed (thermal fair). The bar over every row: 0 launches
failed, 0 checksums not ok, 0 fallbacks, the usual misses only: the ring
under `young=stw` 1, 4 and 5 frames behind scavenges of 13.7 to 14.6 ms,
and the hog with the budget off 1192 each (the control); 38 of 42
scenario rows ended at thermal serious. The phone's first row has never
shown the gap and its warm-up shows none either; the phone's display
power was not traced (the cause found is the mini's).

### The gates

`just check` on cda1177, the final code commit (the Swift tier, picked
by the diff; no fuzzer owed, nothing under the core), with the module
doc uncommitted in the working tree; 394 + 121 Swift tests, the same
under ThreadSanitizer with 0 reports, 211 kernel tests, both shells from
clean with 0 warnings, `new-check` passing:

```
2026-11-09 04:32:02 cda1177 check-tier swift: 7 files from origin/master...HEAD (5ff1cd4...cda1177) and the working tree
2026-11-09 04:32:02 cda1177 start clean-build (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-09 04:32:24 cda1177 end clean-build rc=0 22s
2026-11-09 04:32:24 cda1177 start swift-test (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-09 04:39:10 cda1177 end swift-test rc=0 406s
2026-11-09 04:39:10 cda1177 start tsan (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-09 05:23:55 cda1177 end tsan rc=0 2685s
2026-11-09 05:23:55 cda1177 start kernel-test (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-09 05:25:07 cda1177 end kernel-test rc=0 72s
2026-11-09 05:25:07 cda1177 start apps (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-09 05:27:03 cda1177 end apps rc=0 116s
2026-11-09 05:27:03 cda1177 start new-check (swift: Apple Swift version 6.4.2 (swift-6.4.2-RELEASE))
2026-11-09 05:30:07 cda1177 end new-check rc=0 184s
2026-11-09 05:30:07 cda1177 check-tier done swift failed=0 3485s
```

### What the first-idle-row lesson in AGENTS.md should now say

"A frame gap with no stop, no long turn and a free main thread may be the
display's. The first idle row's 272 to 595 missed frames were the Mac
mini's display turned off by powerd inside the window: the golden
launches before it woke the display without holding it, so with the user
idle powerd asked for an off at every exit, and one landed in the first
scenario window though that launch held a display assertion from its
link's start. Every measurement launch holds `PreventUserIdleDisplaySleep`
from `main`; read `pmset -g log` beside any gap no stop explains, and the
gap records (`gaps100`, `gap_max_at_ms`, `trace gap`) say where it sat.
The matrix's warm-up launch is not a row."

### Deviations

- The brief's premise (the first launch after `xcodebuild`) was wrong;
  the table adds the matrix's prefix, which is what reproduces the gap,
  and b1 as the premise's own case (no gap).
- The warm-up line is a file of its own (`warmup.txt`) rather than a line
  inside an existing raw file, so no existing reader needed a change.
- Part 4 ran the matrix's drift, golden and scenarios parts once
  (`RUNS=1`) per build, not the full three-round matrix: the first
  recorded idle row is the scenarios' first, and the gap followed the
  golden phase.
- A cause the shell could remove was found and removed (the brief
  allowed it); it is the display assertion from `main`, in
  `apps/KajoShell-macOS/Sources/MacShell.swift`. The sample app
  (`KajoApplication`) is unchanged: its measurement mode already holds an
  activity with `idleDisplaySleepDisabled` from its link's start and it
  has no golden phase.
- A two-second `swift build` typecheck ran during b2's second and third
  launches (both 0 missed); nothing else ran during a launch.
- The `sample` was taken in a launch that met no off.

### Not done

- No notarized binary was launched (none exists).
- Why powerd's off cycle was 12 to 15 s in some runs and 30 s in others
  was not traced; the fix does not depend on it.
- The iPad was not run (not needed).

### Open questions for the owner

1. Should the warm-up launch be a row of its own kind in the weekly
   summary or only a line? Built as recommended: its own raw file and
   one line before each matrix's bar in the summary, not a row. Now that
   the cause was the display, should the warm-up stay at all?
   Recommended: yes, as the brief says, for the binary's own first
   launch (392 ms before `main`).
2. Should the release's dmg be launched once on the mini after
   notarization as a smoke test with the first-launch time in the release
   notes? Recommended: yes, later with the release module; its premise
   here (the system's assessment as the gap) did not hold, so it is a
   smoke test only.
