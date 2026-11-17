# The main worker's flips under load: a matrix row

## Status

Brief, 2026-11-17. Asked by the owner the same day. The question
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
