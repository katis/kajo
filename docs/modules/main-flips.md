# The main worker's flips under load: a matrix row

## Status

Built 2026-11-17 (see As built). Brief, 2026-11-17. Asked by the owner the same day. The question
(`docs/decisions/40-main-offload.md`, question 5): "Add a scenario in which
the main worker allocates enough to flip a hundred times or more a launch
(recommended; a small module in the Swift tier, three more rows a matrix),
or leave the matrix as it is." The owner: "Yes, build it".

## What it is

Since the main-offload module the main worker never collects its own
nursery: it has two eden halves, it flips to the other half when one is
full, and the young collector thread collects the full one. The one way
this policy can hold the main thread is the wait for the collector: the
main worker fills the second half before the collector has finished the
first. The matrix has never measured that. This module adds a row kind in
which the main worker allocates on every frame, enough to flip a hundred
times or more in a 10 s launch, on top of the storm, so that the flips,
the offloaded collections and the waits for the collector have samples
and the frames show what they cost.

It is a measurement module. It changes no collector code. If the row
shows a cost (a wait, a missed frame), the module records it with its
record and hands it back; it does not fix it.

## What is known

Check these before building on them.

- After matrices of the main-offload module on 5b72399
  (`~/kajo-scratch/main-offload/part5/matrix-{mac,ipad,iphone}/`): the
  events and hog rows with `events=1000` are the only rows that flip the
  main worker's nursery: `main_flips` 1 a launch on the Mac and 2 on each
  device. `main_flip_max_ms` at most 0.007, `gc_ycOffP50ms` 0.2 to 1.1,
  `main_collector_waits` 0 in every row, 0 frames missed in those rows.
- The scenario rows (storm, ring, share, idle) read `main_flips=0`;
  `gc_youngAllocMain` there is 18 000 to 36 000 words a launch.
- The frame action already runs a main-thread load:
  `ShellBench class>>mainTick:work:` (`apps/Shared/smalltalk/Shell-Bench/`),
  `alloc` pairs with every 64th kept in a ring of 256, then `work`
  iterations of arithmetic; `Scenario.swift` reads `mainalloc=` (default
  20) and `mainwork=` (default 60000). The nursery is `nursery=` in KB
  (default 4096).
- The result line has `main_flips`, `main_flip_max_ms`,
  `main_collector_waits`, `main_collector_wait_ms`,
  `main_collector_wait_max_ms`, `gc_ycOffloaded`, `gc_ycOffP50ms`,
  `gc_ycOffP99ms`, `gc_youngAllocMain`, `gc_promotedMainMB` (name to be
  checked), the frame columns and the turn columns.
- The matrix: `scripts/shell-matrix.sh`, 147 rows, the `--bar` table from
  `scripts/shell-report.py`, the weekly's `summary.md` from the same
  script. Gate times of the last core tier:
  `~/kajo-scratch/main-offload/check/gates.log` (`matrix-mac` 670 s,
  `matrix-iphone` 738 s).

## Starting positions

To be measured in part 1. Say where one was wrong.

1. `mainalloc=` alone, with no new code, can make the main worker flip a
   hundred times or more in 10 s on each of the three machines.
2. At that rate the main turn's own CPU stays under a quarter of a frame
   (the row measures the collector, not a main thread that is its own
   hog). If no value gives a hundred flips inside that bound, say what the
   bound allows and use that.
3. The wait for the collector is 0 or rare on the Mac and is seen on the
   devices, where the collector thread shares four efficiency cores or two
   performance cores with five storm workers.
4. The existing columns are enough to explain a wait: when it happened,
   how long, what the collector thread was doing. If they are not, the
   record that is missing is part 2.
5. Nothing survives from the main load but the ring of 256, so the
   offloaded collection stays near the 0.2 to 1.1 ms of the events rows.
   A second variant that keeps more (a larger ring) may be what makes the
   collector slow enough to be waited for; measure one before choosing.

## Parts

1. **Measure, build nothing.** On the starting commit, by launch
   arguments only: the storm under `offload` with `mainalloc=` at four or
   five values spanning no flips to several hundred, three runs each,
   interleaved, on the Mac, the iPad and the iPhone, each device line with
   its thermal state. A table per machine: value, flips, flip max, waits,
   wait total and max, offloaded collections with p50 and p99, main turn
   p50, p99 and max, busy fraction, frames missed, fallbacks. The same
   values under `stw` once per machine as the control (the oracle collects
   the main nursery in its scavenge stop). Decide the row's value from the
   table and write the rule that chose it before reading the frames.
2. **The record, only if position 4 was wrong.** A per-wait record on the
   result line (bounded, a `RecordRing`): when in the window, how long,
   the collection's phase and the collector thread's QoS. Shell code and
   `Headless.swift`'s report only; if it needs a change under the core
   directories, say so in the hand-back and stop before making it.
3. **The row kind.** A part `mainload` in `shell-matrix.sh`: the storm
   with the chosen `mainalloc=`, `young=offload` and `young=stw`, RUNS
   runs (six rows a matrix by default; the question said three, the `stw`
   control is the other three; say so). In the default parts, in
   `device-rows.sh` and the weekly if they name parts. `shell-report.py`:
   the rows in a table of their own, and in `--bar` two columns, main
   flips and waits for the collector (count and longest ms), over every
   row; a row kind the report does not know is counted as unknown, never
   dropped.
4. **The after matrices** on the three machines with `--bar` over every
   row, beside the weekly of 2026-11-16 and the main-offload after
   matrices for the old rows.
5. **The doc**: "As built" in this file, numbers with their files.

## Tests

- `shell-report.py`'s own test (or a new one beside the scripts' tests)
  reads a fixture with `mainload` rows and asserts the two `--bar`
  columns and the table; a fixture row with a non-zero wait asserts it is
  shown, not folded into 0.
- `scripts/check-tier-test.sh` passes; a changed gate script runs once on
  its own before the gate run.
- A `ShellTests` case, if the shells' modes have one per scenario
  argument, that `mainalloc=` reaches the frame action (the headless host
  counts allocations on worker 0).
- No test asserts a flip count on a wall clock. If a test needs flips, it
  runs until the counter has seen them.

## The bar

- On each machine the `mainload` `offload` rows show at least 100 flips a
  launch, or the doc says why the bound of position 2 allows fewer.
- Every row of the after matrices: 0 failed launches, 0 wrong checksums, 0
  unjustified fallbacks; 0 young collections on the main thread and 0 of
  the host's nursery in every `offload` row, the new rows included.
- The old 147 rows' bar columns are those of the main-offload after
  matrices within the spread of three runs; a difference is named with
  its row.
- Waits for the collector and frames missed in the new rows are reported
  as measured, with the launch's thermal state. A wait or a missed frame
  is a finding, not a failure of the module.
- The tier's gates pass on the final code commit in one log.

## Rules of the house that bind here

- A row that is meant to show a cost is checked to reach the cost.
- A device comparison is read with each block's thermal state; wait for
  nominal between blocks or interleave the rows.
- A hand-back answers the question asked; tabulate the bar's columns over
  every row.
- A summary that classifies a field lists the field's every value first.
- Event latency follows the main thread's busy fraction; report it with
  every percentile.
- A changed gate script is run once on its own before the gate run.
- Read the line of code that prints a field before saying what it
  measures.

## Not in this module

- Any change to the collectors, the nursery's size or the policy.
- A fix for a wait or a missed frame the row shows.
- The native engine's matrix beyond what the weekly already runs with
  `EXTRA_ARGS`; one `native=1` block of the new rows on one device is
  enough to say whether the faster mutator changes the picture.
- The 7-worker iPhone measurement of the final mark.

## Deliverables

The row kind in the matrix scripts and the reports, the tables of parts 1
and 4 under `~/kajo-scratch/main-flips/`, this doc as built, the tier's
`gates.log`.

## Open questions

Build the recommended option; decisions only.

1. One variant or two. Recommended: one (the storm with the chosen
   `mainalloc=`), unless part 1 shows that only a load that keeps more
   makes the collector wait; then that one instead, not both.
2. The weekly's time. Six rows are about 90 s a machine. Recommended:
   in the default parts, so every matrix has them.

## As built

Built 2026-11-17 from feb0d43. Toolchain: swift.org 6.4.2 (swiftly, first
on PATH) for `kajo` and the gates, Xcode 27.2 for the shells. Work files
under `~/kajo-scratch/main-flips/` (named below relative to it); the Mac
shell and the device shells were built into `dd-mac`, `dd-ipad`,
`dd-iphone` and `dd-iphone-native` there. No file under the core
directories changed.

### Part 1: measured by launch arguments (feb0d43)

`scripts/part1.sh`, `part1w.sh` and `part1-all.sh` ran the storm under
`young=offload` with `mainalloc=` at five or six values, three runs
interleaved, then each value once under `young=stw` (the control); the Mac
at 7 workers on its 60 Hz display, the iPad Pro and the iPhone 13 Pro at 5
workers and 120 Hz. Raw rows in `part1/{mac,ipad,iphone}.txt` (the
default `mainwork=60000`) and `part1/*-work0*.txt` (`mainwork=0`); every
table, per launch with its thermal state, in `part1/tables.md`
(`scripts/part1-summary.py`; the Mac's `mainwork=0` rows merge one probe
run with three later ones).

The rule was written before any device row was run
(`part1/rule.txt`, 07:37; the device blocks started 07:42): the smallest
`mainalloc` whose every `offload` run flips 100 times or more in the window
while (a) the frame turn's p50 stays under a quarter of the nominal frame
(Mac 4.17 ms, devices 2.08 ms) and (b) the frame action finishes in its
turn (preempted turns under 10 percent of turns); first with the default
`mainwork`, then with `mainwork=0`; a value per machine kind, since the
flips follow the frame rate (600 frames a launch on the Mac, 1200 on the
devices). (b) was added after the Mac's first table showed every turn cut
at the 3 ms budget from 12000 pairs on, which (a) at 60 Hz did not catch.
The rule reads no frames, waits or thermal state.

Medians over the `offload` runs (part1/tables.md has the ranges, the
`stw` control and every value):

| machine | mainwork | mainalloc | flips | waits | offloaded p50 / p99 ms | frame turn p50 / p99 ms | preempted of turns | busy frac | missed | thermal |
|---|--:|--:|--:|--:|---|---|---|--:|--:|---|
| Mac | 60000 | 8000 | 77 | 0 | 0.84 / 2.03 | 2.57 / 3.02 | 53 of 771 | 0.155 | 0 | nominal |
| Mac | 60000 | 12000 | 113 | 0 | 0.96 / 2.27 | 3.02 / 3.06 | 633 of 634 | 0.181 | 0 | nominal |
| Mac | 0 | 12000 | 116 | 0 | 0.95 / 1.87 | 1.57 / 2.20 | 16 of 783 | 0.095 | 0 | nominal, fair |
| Mac | 0 | 24000 | 220 | 0 | 1.27 / 2.30 | 3.01 / 3.06 | 633 of 633 | 0.181 | 0 | nominal |
| iPad | 60000 | 20 | 0 | 0 | - | 3.01 / 3.06 | 673 of 1371 | 0.346 | 0 | nominal |
| iPad | 60000 | 12000 | 114 | 0 | 2.74 / 4.42 | 3.03 / 3.08 | 1265 of 1265 | 0.363 | 0 | nominal, fair |
| iPad | 0 | 6000 | 116 | 0 | 2.11 / 3.25 | 1.77 / 2.79 | 13 of 1459 | 0.229 | 0 | fair |
| iPad | 0 | 12000 | 187 | 0 | 2.82 / 9.36 | 3.03 / 3.08 | 1265 of 1265 | 0.364 | 0 | fair |
| iPhone | 60000 | 20 | 0 | 0 | - | 2.19 / 3.02 | 40 of 1327 | 0.260 | 0 | nominal to serious |
| iPhone | 60000 | 6000 | 91 | 0 | 1.61 / 8.57 | 3.02 / 3.06 | 1266 of 1266 | 0.362 | 0 | nominal to serious |
| iPhone | 0 | 6000 | 116 | 0 | 1.63 / 7.98 | 1.83 / 2.64 | 27 of 1330 | 0.227 | 0 | serious |
| iPhone | 0 | 16000 | 186 | 0 | 2.69 / 11.17 | 3.03 / 3.09 | 1266 of 1266 | 0.364 | 0 | serious |

The rule chose: with the default `mainwork` no value on any machine (the
Mac's 113 flips at 12000 came with every frame turn cut at the budget; on
the iPad the default frame action alone, `mainalloc=20`, is cut in 73 to
1266 of its turns). With `mainwork=0`: **12000 pairs a frame on the Mac
(116 flips in every run) and 6000 on the devices (116 in every run on
both)**, the turn's p50 1.57, 1.77 and 1.83 ms. These are
`shell-matrix.sh`'s defaults (`MAINALLOC`, `MAINWORK`).

Fallbacks 0, unjustified 0, frames missed 0 in every part-1 `offload` row;
one `stw` row missed one frame (iPhone, 6000 pairs, `mainwork=60000`,
serious). A check-tier-test run (light, seconds) overlapped the Mac's
`mainwork=0` block; its one outlier, an offloaded p99 of 15.13 ms at
16000 pairs, may be that run's.

### The starting positions

1. **Wrong as stated.** `mainalloc=` alone reaches 100 flips (Mac 113 at
   12000, iPad 114 and iPhone 119 at 12000) only with every frame turn cut
   at the 3 ms budget: the main thread is then its own hog. Inside the
   bound it needs `mainwork=0` too.
2. **Wrong with the default `mainwork`, held with `mainwork=0`.** The
   default frame action (60000 iterations of arithmetic) already takes
   1.5 ms on the Mac and fills the iPad's 3 ms turn; with `mainwork=0` the
   row's values keep the turn's p50 at 1.57 ms (Mac, a quarter is 4.17),
   1.77 and 1.83 ms (devices, a quarter is 2.08).
3. **Wrong.** The main worker waited for its collector 0 times in every
   row of part 1, part 3's run alone, the after matrices and the native
   block (262 scenario launches, 127 of them with flips, up to 220 a
   launch), window and whole run, on every machine and at every thermal
   state up to serious; the iPhone's collector ran 4 to 17 percent of its
   CPU on performance cores (`collector_p_frac` of its flipping `offload`
   rows). At 116 flips in 10 s a half fills in about 86 ms; the highest
   p99 of the offloaded collection in any row was 29.2 ms (iPhone, part 1,
   default `mainwork`, 6000 pairs, fair). A wait needs the collector off the
   CPU for most of a half's fill time, not a slower copy.
4. **Not tested, and the record is in the core.** No wait happened, so no
   wait needed explaining. The columns give a launch's count, total and
   longest in the window (`main_collector_*`) and the whole run
   (`gc_ycMainCollectorWait*`); they do not say when in the window, the
   collection's phase or what the collector thread was doing. A per-wait
   record has to be taken where the wait is timed,
   `Sources/KajoVM/YoungCollection/Owner.swift` (the `done[k]` wait before
   a flip), a core directory. Part 2 was therefore not built; open
   question 1.
5. **Partly wrong.** At the row's values the offloaded collection's p50 is
   0.95 ms on the Mac, 2.1 on the iPad and 1.6 on the iPhone, above the
   events rows' 0.2 to 1.1 on the devices: the ring's chains made since
   the last collection survive. A load that keeps more than the ring was
   not built (part 1 builds nothing; it is a Smalltalk change); the most
   the arguments can keep, every one of the 256 slots replaced every
   frame (16384 pairs a frame and more: the Mac's 16000 to 32000, the
   devices' 12000 and 16000), raised the p50 to 1.1 to 1.3, 2.8 to 3.3
   and 2.4 to 2.7 ms, p99 at most 11.6 ms on the iPad and 12.8 on the
   iPhone, with no wait. One variant (open question 1 of the brief: as
   recommended).

### Part 2: not built

See starting position 4.

### Part 3: the row kind (2e7d2e3)

- `scripts/shell-matrix.sh`: the part `mainload`, in the default parts
  before the closing drift: the storm with `mainalloc=$MAINALLOC
  mainwork=$MAINWORK` under `young=offload` and `young=stw`, RUNS runs
  each interleaved, into `mainload.txt`. Six rows a matrix by default:
  the question said three; the `stw` control is the other three. Defaults
  12000 and 0 on the Mac, 6000 and 0 on a device. `device-rows.sh` and
  `weekly.sh` name no parts and needed no change; the weekly's matrices
  get the rows (the brief's question 2, as recommended).
- `Sources/KajoShellCore/Scenario.swift`: the scenario's result line
  carries `mainalloc=` and `mainwork=`, so a row says its load.
- `scripts/shell-report.py`: the mainload rows in a table of their own
  (medians by young mode and load) and a per-launch table (flips, waits
  with total and longest, offloaded collections with p50 and p99, the
  frame turn's p50, p99 and max, busy fraction, frames missed, fallbacks,
  thermal state at start and end); `--bar` gains two columns over every
  row, main flips and main waits for the collector with the longest (rows
  without the fields read "?"), a note for every row with a wait (with its
  thermal state) and for every row whose whole-run count exceeds the
  window's; a `*.txt` file of result rows the report does not know is
  named and tabulated as "<name> (UNKNOWN kind)", never dropped.
  `row_name` names `mainalloc` and `mainwork`.
- `scripts/check-tier.sh`: `shell-matrix.sh` and `shell-report.py` owe
  check-tier-test (a script's own test runs in the tier that changes it).
  `scripts/check-tier-test.sh`: both are in its list of gate scripts, and
  eight new checks read `--bar` and the report over fixture rows (two
  `offload` mainload rows, one with 3 waits, 4.5 ms, longest 2.25, and one
  more in the whole run; an `stw` row; a golden row; an unknown file).
  Broken variants (`part3/`): the starting commit's `shell-report.py`
  fails 6 of the 8 (`broken-starting-commit.txt`); one that folds the
  waits into 0 fails 2 (`broken-folded.txt`); the head passes 8
  (`section-head.txt`). `check-tier-test: 106 checks, ok`
  (`part3/check-tier-test.txt`).
- The changed scripts were run alone before the matrices: `RUNS=1
  WARMUP=0 shell-matrix.sh mac part3/alone-mac mainload` (two rows, 116
  flips, 0 waits) and both reports over it.
- No `ShellTests` case: the shells' modes have no test per scenario
  argument (`Tests/KajoCompilerTests/ShellTests.swift` drives a test shell,
  not `mode=scenario`).

### Part 4: the after matrices (2e7d2e3)

`RUNS=3`, every default part, raw rows in
`part4/matrix-{mac,ipad,iphone}/`, `shell-report.py --bar` in each
`bar.md`, the tables in `report.md`; the Mac 08:01 to 08:13, the iPad 08:14
to 08:29, the iPhone 08:29 to 08:47 (`part4/devices.log`), through
`shell-matrix.sh mac` and `device-rows.sh`. 153 rows each (147 and the six
mainload rows).

| matrix | rows | failed | checksums not ok | frames missed outside hog (rows) | fallbacks | unjustified | young on the main thread | host's nursery | main flips (mainload) | waits for the collector | longest stop |
|---|--:|--:|--:|---|--:|--:|--:|--:|---|--:|---|
| Mac | 153 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 357 (348) | 0 | 11.55 ms (`stw` ring scavenge) |
| iPad | 153 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 366 (348) | 0 | 13.76 ms (`stw` ring scavenge) |
| iPhone | 153 | **1** | 0 | 6 in 3 rows (`stw` ring 2 and 3, `stw` mainload 1) | 0 | 0 | 0 | 0 | 366 (348) | 0 | 19.31 ms (`stw` ring scavenge) |

The hog rows missed 1787, 3577 and 3576 frames by design.

The mainload rows, per launch (`report.md`, "mainload"):

| machine | young | run | flips | waits (total, longest ms) | offloaded (p50 / p99 ms) | frame turn p50 / p99 / max ms | busy frac | missed | thermal start/end |
|---|---|--:|--:|---|---|---|--:|--:|---|
| Mac | offload | 1 | 116 | 0 (0, 0) | 127 (0.98 / 1.89) | 1.57 / 2.22 / 2.43 | 0.095 | 0 of 600 | fair/fair |
| Mac | offload | 2 | 116 | 0 (0, 0) | 127 (0.96 / 1.69) | 1.56 / 2.12 / 2.34 | 0.095 | 0 of 600 | fair/fair |
| Mac | offload | 3 | 116 | 0 (0, 0) | 127 (0.95 / 1.63) | 1.61 / 2.29 / 2.46 | 0.097 | 0 of 600 | fair/fair |
| Mac | stw | 1-3 | 0 | 0 | - | 1.40-1.46 / 4.01-4.43 / 4.65-5.23 | 0.113-0.116 | 0 of 600 | fair/fair |
| iPad | offload | 1 | 116 | 0 (0, 0) | 127 (2.08 / 3.63) | 1.43 / 2.10 / 2.49 | 0.179 | 0 of 1200 | serious/serious |
| iPad | offload | 2 | 116 | 0 (0, 0) | 127 (2.11 / 4.15) | 1.73 / 2.32 / 2.92 | 0.202 | 0 of 1200 | serious/serious |
| iPad | offload | 3 | 116 | 0 (0, 0) | 127 (2.18 / 4.06) | 1.85 / 2.91 / 3.06 | 0.239 | 0 of 1200 | serious/serious |
| iPad | stw | 1-3 | 0 | 0 | - | 1.60-2.29 / 6.13-8.71 / 7.90-10.00 | 0.242-0.327 | 0 of 1200 | serious/serious |
| iPhone | offload | 1 | 116 | 0 (0, 0) | 127 (1.06 / 6.61) | 1.23 / 1.59 / 2.11 | 0.151 | 0 of 1200 | serious/serious |
| iPhone | offload | 2 | 116 | 0 (0, 0) | 127 (5.24 / 19.95) | 2.08 / 3.02 / 3.06 | 0.253 | 0 of 1200 | serious/serious |
| iPhone | offload | 3 | 116 | 0 (0, 0) | 127 (8.14 / 27.06) | 2.15 / 3.05 / 3.07 | 0.271 | 0 of 1200 | serious/serious |
| iPhone | stw | 1-3 | 0 | 0 | - | 1.93-2.22 / 8.54-9.45 / 10.72-12.02 | 0.329-0.351 | 0, 1, 0 of 1200 | serious/serious |

- **The bar's first item is met**: 116 flips in every `offload` mainload
  row on all three machines, inside the bound.
- **Waits for the collector: 0** in every row of the three matrices (the
  window and the whole run); no frame missed in an `offload` mainload row.
  The iPhone's `offload` rows ran at serious with the offloaded collection
  at a p99 of up to 27 ms (run 3), against about 86 ms for a half to fill.
- **Thermal**: each device's mainload rows came at the end of its matrix
  and all six read serious at start and end, on both devices; the `offload`
  and `stw` rows are interleaved inside the block, so they compare at one
  state; the blocks did not wait for nominal. The Mac's were at fair.
- **0 young collections on the main thread and 0 of the host's nursery**
  in every `offload` row of the three matrices, the new rows included.

The old rows against the main-offload after matrices (5b72399,
`~/kajo-scratch/main-offload/part5/matrix-*`), per row kind, ranges over
three runs (`part4/old-rows-{mac,ipad,iphone}.md`,
`scripts/old-rows.py`): every `offload` row reads as before (0 missed, 0
fallbacks, 0 stalls, the same flips: events and hog 1 a launch on the
Mac, 2 on the devices). Outside the baseline's spread, all in the oracle:
- Mac, ring under `stw`: stalls 212 to 249 a launch (before 207 to 218),
  the longest 21.32 ms (16.07 to 17.74).
- iPhone, ring under `stw`: the longest stop 19.31 ms (14.98 to 15.78);
  frames missed 0 to 3 (1 to 6).
- iPhone, storm under `offload`: the longest stop 0.58 to 0.62 ms (0.49 to
  0.54).
- iPhone, golden: one launch failed (below).
Against the weekly of 2026-11-16 (156 rows with the removed mode): frames
missed outside the hog rows Mac 0 (weekly 0), iPad 0 (2), iPhone 6 (10),
all `stw`.

**The failed launch** (iPhone, `mode=golden kind=kasm kernel=sends
workers=2 run=2`, 08:31:44): the app was launched and printed nothing, not
even its start line, until `device.sh`'s 300 s bound killed it (`App
terminated due to signal 15`, `part4/matrix-iphone/golden-console.log`
line 401). Three relaunches of the same row right after the matrix ran
(1898, 1527 and 1579 ms, the same checksum: `part4/golden-rerun/`). It is
the first `FAILED` row in any matrix under `~/kajo-weekly/` or
`~/kajo-scratch/`. The module changed nothing a golden launch runs but the
scenario's result line.

**One `native=1` block** (iPhone, 08:49 to 08:52, a `KAJO_SHELL_AOT=1`
build in `dd-iphone-native`, the console says `native=loaded
shell.img.native.dylib`): the six mainload rows natively, interleaved with
the same six interpreted on the same install, all at serious
(`part4/native-iphone/{native,interp}/`). Native: 116 flips, 0 waits, the
offloaded collection 2.14 / 13.14 ms, the frame turn 1.44 / 2.11 ms, busy
0.177, 0 missed; interpreted: 116, 0, 1.68 / 6.35, 2.00 / 2.67, 0.236, 0.
The faster mutator shortens the main turn and leaves the flips (set by the
allocation per frame) and the waits as they were. The iPhone keeps this
build installed; `device-rows.sh` and the weekly build and install their
own.

### Gates

`KAJO_CHECK_OUT=~/kajo-scratch/main-flips/check just check feb0d43` on
2e7d2e3 (the code commit; this doc followed): the Swift tier, chosen by
`Sources/KajoShellCore/Scenario.swift` and the four scripts, with
check-tier-test first because `check-tier.sh` and `check-tier-test.sh`
changed (and, from this commit on, because `shell-matrix.sh` and
`shell-report.py` did); no fuzzer owed. Every gate `rc=0` in one log,
4428 s against 4078 s for the last Swift-tier run
(`~/kajo-scratch/interning-tests/check/gates.log`, 01d4580):
check-tier-test 6 s (not in that run), clean-build 20 s (20), swift-test
741 s (722; 466 and 164 tests pass), tsan 3162 s (2837; 466 and 164 tests
pass, 0 sanitizer reports; the module adds no Swift test, so the 325 s are
the run's own spread or load, not the module's cost), kernel-test 106 s
(108; 249 of 249), apps 128 s (127; 0 errors, 0 warnings on both),
new-check 265 s (264; ok). The device matrices are not in this tier; part
4's ran on the same commit before the gates.

### Deviations

- The row sets `mainwork=0` as well as `mainalloc=`: the brief named
  `mainalloc=` only; with the default `mainwork` no value met the bound
  of starting position 2 on any machine (the rule's step 2).
- The value is per machine kind (12000 pairs on the Mac, 6000 on a
  device), not one value: the Mac's display runs at 60 Hz and the
  devices' at 120, so the same pairs a frame flip half as often on the
  Mac.
- The bound gained (b), "the frame action finishes in its turn", after the
  Mac's first table and before any device row (`part1/rule.txt`).
- Part 2 was not built (starting position 4).
- The device blocks did not wait for nominal: each device's mainload rows
  ran at serious, `offload` and `stw` interleaved.
- No `ShellTests` case (the brief's conditional; no test per scenario
  argument exists).

### Not done

- A per-wait record (open question 1).
- A load that keeps more than the ring of 256 (starting position 5; no
  launch argument makes one).
- The iPhone's failed golden launch is not explained.

### Found, not the module's

- The shells' default frame action (`mainwork=60000`) fills the iPad's 3 ms
  turn: in the part-1 rows the storm with the default load had 73 to 1266
  of its 1266 to 1538 frame turns cut at the budget on the iPad and 10 to
  640 on the iPhone, busy 0.30 to 0.36 (`part1/tables.md`, `mainalloc=20`).
  The old scenario rows therefore measure a main thread that is close to
  its own hog on the devices; no frame was missed.
- One iPhone golden launch printed nothing in 300 s and was killed by the
  bound (part 4), the first such row in any recorded matrix; three
  relaunches ran.

### Open questions (decisions only)

1. The per-wait record (when in the window, the collection's phase, the
   collector thread's state) needs a `RecordRing` where the wait is timed,
   `Sources/KajoVM/YoungCollection/Owner.swift`, a core change and a core
   tier run. Recommended: not now; the wait has read 0 in every row, and
   the mainload rows now count it in every matrix and every weekly; build
   the record when a row first shows a wait.
2. The shells' default `mainwork=60000` puts the old scenario rows' main
   thread at its turn budget on the iPad. Recommended: leave the old rows
   as they are (their history compares), and note it beside the iPad's
   scenario rows; change it only as its own small module if the owner
   wants the old rows to measure a main thread with headroom.
