# The first launch's gap

The first launch's gap, built 2026-11-09 (`docs/modules/first-launch.md`, a
bug follow-up; nothing under `Sources/KajoVM`, `kernel/` or `tools/`): the
brief's premise did not hold, the gapped row was not the new binary's first
launch but the matrix's first scenario launch after its 3 drift and 108
golden launches, and the cause was the Mac mini's display turned off by
powerd inside the window (the brief's case three, a gap in the display link
itself): a golden launch declares user activity, which wakes the display,
but holds no display assertion, so with the user idle past the display-sleep
time powerd asked for the display off at every golden exit and the display
cycled off and on through the golden phase (every 12 to 15 s in the weekly
and gate runs); the off asked for as the last golden launch exited landed in
the first scenario window (b2: "Time to turn off display" at 03:37:44.540,
WindowServer's `Display 2 setEnabled:0` at 03:37:52.27 while the scenario's
own `PreventUserIdleDisplaySleep` assertion, taken when its link started,
was 7 s old; the gap opened at 6496.4 ms of the window and ran 3503.6 ms to
its end, 419 frames, the `screens-sleep` notification on the main queue at
6500.3 ms, callback lateness at most 1.75 ms, longest turn 3.19 ms, 0
stops), and every later launch missed none because a scenario launch
releases a display assertion at exit, which turns on powerd's
`delayDisplayOff`; the three historic gapped rows each have "Display is
turned off" inside their launch in `pmset -g log`; the system's first-launch
work on a new binary is real but separate, 392 ms before `main` (amfid,
XprotectService, syspolicyd) against 5 ms on later launches, all before the
window; built: the scenario mode's launch trace (`kajo-launch-report` prints
`launch step=` from `main` to `window-end`; every display-link gap over 100
ms recorded with its place in the window, the callback's lateness, the last
turn and view call before it; a 10 ms main-queue heartbeat and the system's
notifications when tracing; `gaps100` and `gap_max_at_ms` on the result
line; `Sources/KajoShellCore/FrameGaps.swift`), every `mode=` launch of the
Mac shell holds `PreventUserIdleDisplaySleep` from `main` until exit (the
product mode holds none; no setting changed), `shell-matrix.sh` runs one
idle warm-up launch into `warmup.txt` before its first row (`WARMUP=0`
leaves it out) and `shell-report.py` prints its numbers on a line of their
own before the tables and `--bar`, never as a row (the weekly summary
inherits it; both readers' output on the 2026-11-08 matrices byte for byte
unchanged); measured: part 1 over five fresh builds with the matrix's own
prefix, b2 419 frames missed behind 5 display offs in the prefix and b4 with
the fix 0 missed and 0 offs, neither with a warm-up (b3 and b5 without the
fix met no off in their first window, the off cycle being 30 s there against
12 to 15; not traced); part 4 five fresh builds of cda1177, every warm-up
and every first idle row 0 of 1200 with 0 display offs during any matrix,
the only misses the ring under `young=stw` (184 to 220 frames, 8 to 10
counted soft-limit fallbacks); the iPhone matrix at 5 workers with the
warm-up (157 launches for 156 rows, the warm-up 0 of 1200 at thermal
nominal) 0 fallbacks, the ring under `young=stw` 1, 4 and 5 frames behind
13.7 to 14.6 ms scavenges as before; `just check` on cda1177, the Swift
tier, every gate in 3485 s (394 + 121 tests, ThreadSanitizer 0 reports in
2685 s, 211 kernel tests, apps, new-check); not done: no notarized dmg
launched (none exists), the 12 to 15 against 30 s off cycle, the iPad; its
two open questions built as recommended (the warm-up a line, kept for the
binary's own 392 ms; a release smoke test later with the release module).
