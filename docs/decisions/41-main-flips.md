# The main worker's flips under load: a matrix row

A follow-up of the main-offload module, built 2026-11-17
(`docs/modules/main-flips.md`; one sitting, final code commit 2e7d2e3, the
doc in 7cd9d58). The owner's answer to `40-main-offload.md`'s question 5 was
"Yes, build it". A measurement module: no file under the core directories
changed. Work files are in `~/kajo-scratch/main-flips/`.

## What was built

A part `mainload` in `scripts/shell-matrix.sh`, in the default parts: the
storm with the main worker allocating on every frame (`mainalloc=12000
mainwork=0` on the Mac, `mainalloc=6000 mainwork=0` on a device; `MAINALLOC`
and `MAINWORK` override), under `offload` and under the `stw` control, six
rows a matrix (153 where it had 147). `scripts/shell-report.py` has a
mainload table, two `--bar` columns over every row (main flips; main waits
for the collector with the longest), a note for every row with a wait, and
tabulates a row file it does not know as "(UNKNOWN kind)". The result line
carries `mainalloc=` and `mainwork=`. A change to `shell-matrix.sh` or
`shell-report.py` now owes `check-tier-test`, which has 8 new fixture checks
(106 in all).

## The result

The main worker waited for its collector 0 times in every launch: 262
scenario launches in part 1, 127 of them with flips and up to 220 flips a
launch, and the three after matrices, at thermal states up to serious. In
the after matrices (`part4/matrix-*`, 2e7d2e3) every `mainload` `offload`
launch on each machine: 116 flips, 0 waits, 0 frames missed, 0 young
collections on the main thread.

| machine | offloaded collection p50 / p99 ms | main turn p50 ms | busy | thermal |
|---|---|---|---|---|
| Mac | 0.95 to 0.98 / 1.63 to 1.89 | 1.56 to 1.61 | 0.095 to 0.097 | fair |
| iPad | 2.08 to 2.18 / 3.63 to 4.15 | 1.43 to 1.85 | 0.18 to 0.24 | serious |
| iPhone | 1.06 to 8.14 / 6.61 to 27.06 | 1.23 to 2.15 | 0.15 to 0.27 | serious |

Why no wait: at 116 flips a half fills in about 86 ms, and the longest p99
of an offloaded collection in any row was 29.2 ms (iPhone, part 1). Inside
the bound that keeps the main thread from being its own hog, the main worker
cannot fill a half faster than the collector empties the other. One native
block on the iPhone (`part4/native-iphone/`): 116 flips, 0 waits, the main
turn shorter (1.44 against 2.00 ms p50), nothing else changed.

## The after matrices, every row (`--bar`, run by the main session)

0 wrong checksums, 0 fallbacks, 0 unjustified fallbacks, 0 young collections
on the main thread and 0 of the host's nursery, 0 waits, on the three
machines. Main flips 357, 366 and 366 (348 of them the new rows'). Frames
missed outside the hog rows: Mac 0, iPad 0, iPhone 6, all in `young=stw`
rows with a scavenge stop of 14.8 to 19.3 ms (ring 2 and 3, the new control
row 1). One launch failed on the iPhone: golden `kasm sends workers=2
run=2` printed nothing, not its start line, and was killed at the 300 s
bound (`part4/matrix-iphone/golden-console.log`); three relaunches right
after ran with the right checksum (`part4/golden-rerun/`). It is the first
failed row in a recorded matrix and is not explained.

Old rows outside the baseline's spread (`part4/old-rows-*.md`), all in
`stw` rows or small: the Mac's `stw` ring stalls 212 to 249 (207 to 218)
with the longest 21.32 ms (17.74); the iPhone's `stw` ring longest stop
19.31 ms (14.98 to 15.78); the iPhone's `offload` storm longest stop 0.58
to 0.62 ms (0.49 to 0.54). The device rows ran at serious and were not
waited to nominal.

## The starting positions

Three of the brief's five were wrong.

1. `mainalloc=` alone reaches 100 flips only with every frame turn cut at
   the 3 ms budget; inside the bound the row also needs `mainwork=0`.
2. Held with `mainwork=0` only.
3. Wrong: no wait on the devices either.
4. Not testable: no wait happened. The columns give a wait's count, total
   and longest, not when or in which phase; that record would be in
   `YoungCollection/Owner.swift`, core code, and was not built.
5. Partly wrong: the offloaded collection is 1 to 2 ms on the devices, above
   the events rows. The heaviest-keeping load the arguments allow gave p99
   at most 12.8 ms and no wait.

The rule that chose the value is `part1/rule.txt`. It gained a second bound
(preempted turns under 10 percent) after the Mac's first table and before a
device row; the file was edited again after the device rows (its mtime is
07:55, the device files' 07:46 and 07:54), so its own time no longer shows
the order. The file says so.

## Gates

`just check feb0d43` on 2e7d2e3, the Swift tier with `check-tier-test`,
swift.org 6.4.2 first on PATH, every gate `rc=0`, 4428 s against 4078 s on
01d4580 (`~/kajo-scratch/main-flips/check/gates.log`): `tsan` 3162 s (2837),
466 and 164 tests, 0 reports; `swift-test` 741 s (722). The module adds no
Swift test. The device matrices are not in that tier and were run by the
agent through `shell-matrix.sh`.

## Deviations and not done

- `mainwork=0` and a value per machine kind (the Mac's display is 60 Hz).
- Part 2, the per-wait record: not built.
- A load that keeps more than the ring of 256: needs Smalltalk; not built.
- No `ShellTests` case; none exists per scenario argument.
- A short `check-tier-test` run overlapped one Mac block of part 1.
- The iPhone was left with the native build of the shell installed.

## Found, not the module's

- The shells' default frame load (`mainwork=60000`) fills the 3 ms turn on
  the devices: with the storm, 73 to 1266 of 1266 to 1538 frame turns were
  preempted on the iPad and 10 to 640 on the iPhone, busy fraction 0.30 to
  0.36. The old scenario rows measure a main thread near its own budget.
- The iPhone launch that printed nothing.

## Open questions

1. The per-wait record (when, how long, the collection's phase, the
   collector's QoS) needs a `RecordRing` in `YoungCollection/Owner.swift`
   and a core-tier run. Recommended: not now; build it when a row first
   shows a wait. Every matrix and every weekly now counts them.
2. The default `mainwork=60000` on the devices. Recommended: leave the old
   rows as they are so their history compares, with this note beside them;
   change it only as a module of its own.
