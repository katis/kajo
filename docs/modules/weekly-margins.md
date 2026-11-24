# The weekly summary tabulates printed margins

## Status

Brief, 2026-11-24. Asked for by the owner: question 4 of the weekly run's
two failures (`docs/decisions/54-weekly-1123-failures.md`), answered "Yes,
as recommended" on 2026-11-24, and chosen as the next module the same day
("Weekly margins table"). Not a core module: nothing under `Sources/`
changes. Tests and scripts only; the Swift tier, with `check-tier-test`.

## What it is

Tests print times beside bounds, and nothing reads them. The main-worker
stall test printed its body's time in thirteen loaded runs, 79 to 170 s
against a 180 s deadline, and the first reader was the run that failed at
191 s. The tag test now prints its steps and round trips; a slow run of it
passes and the lines scroll by.

This module makes one reader. A test that waits against a bound prints one
line of one shape that carries the value and the bound in effect. A script
reads the test gates' outputs of a run and writes a table: each margin, its
value, its bound, the fraction used, per gate. `scripts/weekly.sh` puts the
table in `summary.md`. The weekly run of Monday 2026-11-30 is its first
real run, and question 3 of the same record (the client's 30 s request
timeout against a `class.hierarchy` of 23.5 s) is read from it.

No bound, wait, timeout or assertion changes in this module. A test fails
or passes exactly as it did.

## What is known

Check these before building on them.

- What the loaded gates print today, on eee63db
  (`~/kajo-scratch/weekly-1123-failures/check-load/swift-test-load.txt` and
  `tsan-load.txt`; read only):
  - `stall-diag body <test> s=<seconds>`, one per stall test (15 lines a
    gate). `theMainWorkerNeverStallsAndItsFallbacksNameIt` 85.0 s plain and
    204.6 s under the sanitizer; `aFullHeapFallsBackJustifiedThenRunsOutOfMemory`
    376.5 and 932.8 s. No line carries its bound, and since the stall
    tests' follow-up most bounds are quiet bounds (no progress of the
    collector for N s), so the body's time is not the quantity the bound
    is on. `StallDiag` prints `waited=` and `quiet=` on its `-ok` lines.
  - `tools-tags <step> s=<step seconds> t=<total>` and `tools-tags replies
    ...` with every round trip in ms. Under `tsan-load` the `ready` step
    took 25.2 s; `LocalTools.until` fails on 60 s of quiet or 300 s in all;
    the client's request timeout is 30 s.
  - Others that print a time or a count beside a bound somewhere in the
    test: `types-tests ... body_s=`, `types-tools body_s=`,
    `reconnect-state ...`, `host-timer ...`, `turn overrun ms wall p50=
    p99= max=` (`MainThreadTests`, failed 1 of 15 loaded runs in the last
    module), `relocation round: ...`, the interning tests' body time,
    `idle ...` lines. `grep -rn 'print("' Tests` lists about 50 printing
    sites; most are not margins.
- A test's duration as Swift Testing reports it counts the wait for a
  thread of the cooperative pool (a 0.1 s body read 408.8 s). It is not a
  margin and the reader does not use it.
- `scripts/weekly.sh` lines 114 to 138 write `summary.md`: a gates table
  from `gates.log` by `awk`, then `shell-report.py --bar` per matrix. The
  test gates' outputs are `swift-test.txt`, `swift-test-load.txt`,
  `tsan.txt`, `tsan-load.txt`, `test-release.txt`, `kernel-test.txt` and
  the native ones, in the run's directory.
- A gate has a bound of its own in `scripts/gates-lib.sh`, and `gates.log`
  has each gate's time. `tsan-load` took 4156 s in the last module.
- `swift test` to a file is block-buffered and tests run side by side, so
  lines of different tests interleave and a test's lines can be far apart.
- A change to a gate script owes `check-tier-test`, and a changed gate
  script is run once on its own before the gate run (the `status` lesson).
- `--bar` once read every value but `ok=1` as a failure. A reader names
  each value a writer can emit and counts what it does not know as
  unknown.

## Starting positions

To be measured or read in part 1. Say where one was wrong.

1. One line shape is enough: a name, a value, a bound, a unit and the
   bound's kind (a deadline on the whole step; a quiet bound, with the
   longest quiet stretch as the value; a ceiling; a count), printed by one
   helper when the wait ends, in the passing run and in the failing one.
2. The bound belongs in the line, printed from the same expression the
   wait uses, not in a table in the script. A table in a script is right
   on the day it is written.
3. The stall tests' body times have no bound any more; their margin is the
   longest quiet stretch against the quiet bound. If so the table shows
   that, and the body time is a column without a fraction.
4. A round trip is a margin against the client's request timeout, and the
   image side already knows both (`DevClient`'s latencies, `sendLimit`,
   `ToolsProbe class>>repliesNow`). The longest round trip per request
   kind is what the table needs, not every one.
5. A gate's own time against its bound in `gates-lib.sh` is a margin of
   the same kind and costs nothing to add from `gates.log`.
6. A margin that a gate did not print is found without a list of expected
   names: the same tests run in `swift-test`, `swift-test-load`, `tsan` and
   `tsan-load`, so a name present in one and absent in another is a line;
   so is a name the previous finished weekly run had and this one has not.
7. The reader can be one Python script with fixtures, as `shell-report.py`
   and `ab-table.py` are, called by `weekly.sh` and by hand on any
   directory of gate outputs (a module's `check/`).

## Parts

### Part 1: the inventory (builds nothing else)

- List every site under `Tests/` that waits against a bound: the file and
  line, the bound's expression and kind, its value plain and under the
  sanitizer, what the test prints today, and the value in the four test
  gates' outputs of eee63db (`check/` and `check-load/` of the last
  module). The list is a table in this doc. Waits whose bound is never
  near (a 120 s wait for something that takes 5 ms) are listed and marked;
  say the rule that marks them before reading the values.
- From the list: the line shape, the kinds, the names. Write the reader's
  rule for THIN (below) with its time before any table is made.
- Commit part 1 (the doc) before part 2.

### Part 2: the line

- One helper per test target prints the line. Every site of part 1's list
  that is not marked "never near" prints through it. A site that already
  prints its time keeps its old line where a doc or a script reads it
  (`stall-diag`, `tools-tags`); say which were kept and why.
- The round trips: the longest per request kind against the request
  timeout, for the tools tests that open a client. Read from the client,
  not timed from Swift.
- No bound changes. A test's result does not depend on the helper.

### Part 3: the reader

- `scripts/margins.py <dir> [--previous <dir>]`: reads every test gate's
  output in the directory, writes a Markdown table: name, kind, bound, and
  per gate the value and the fraction of the bound; the largest fraction
  first. With `--previous`, the previous run's largest fraction beside it.
  Gates' own times against their bounds as a second table.
- It lists, under the table: lines of the shape it could not parse
  (UNKNOWN, counted, quoted), names printed more than once in a gate (the
  largest value is used and the count is said), names present in one gate
  and absent in another, and names of the previous run that are gone.
- THIN: a mark on a row whose fraction passes the rule's number in any
  gate. The script's exit status is 0 whatever it finds; a file it cannot
  read is a line in the output and exit 0; a usage error is exit 2.
- `weekly.sh` writes the section `## Margins` in `summary.md` after the
  gates table, with the last finished weekly run's directory as
  `--previous` (the first run has none and says so). The weekly run's
  result (`failed=`) does not depend on it.
- `just margins <dir>`.

## Tests

- The reader's fixtures (a directory of small outputs under the scripts'
  test fixtures or `Tests/`, where `check-tier-test.sh` can run them): a
  plain row; a row over the THIN rule; a value past its bound; a line of
  the shape with a field missing (UNKNOWN, not dropped, not a pass); two
  lines of one name; a name absent from one gate; an empty gate file; a
  missing gate file; interleaved lines; `--previous` with a name gone. The
  expected output is a committed file, compared byte for byte.
- `check-tier-test.sh` runs the reader's test, and a change to
  `margins.py` chooses `check-tier-test` as a change to any gate script
  does.
- A Swift test of the helper: the line it prints parses back to the same
  name, value, bound and kind (the helper and the reader agree on the
  shape through one committed sample line that both tests read).
- Broken variants, by hand, output kept in `broken/`: the reader counting
  an UNKNOWN line as a pass row (the fixture test fails); the helper
  printing a bound other than the one the wait used (name the check that
  fails, or say none can and why).
- One real run: the reader over the tier's own `swift-test.txt` and
  `tsan.txt`, and over one `swift-test-load` and one `tsan-load` run made
  for this purpose; the table goes in the doc.
- `weekly.sh` run once in a mode that makes a `summary.md` in the scratch
  directory (`KAJO_WEEKLY_ROOT`, `KAJO_WEEKLY_QUICK` or `KAJO_WEEKLY_ONLY`;
  read the script for what each does, and check first that nothing is
  written under `~/kajo-weekly/`). Quote the section.

## The bar

1. Every site of part 1's list prints through the helper or is marked
   "never near" with the rule; the count of each is in the doc.
2. `margins.py` over the four test gates of the final commit gives a table
   with no UNKNOWN line and no name absent from a gate that ran its test.
3. The table has the tag test's steps against `until`'s two bounds, the
   longest `class.hierarchy` round trip against the request timeout, the
   main-worker stall test and the full-heap test, each with its fraction,
   under `tsan-load`.
4. The fixture test passes and fails with the broken variant.
5. `summary.md` from the scratch weekly run has the section.
6. No bound, wait or assertion differs from the starting commit: `git
   diff` over `Tests/` shows only added printing, said in the hand-back
   with the diff's size.
7. The Swift tier `failed=0`, with `check-tier-test` in it; the test
   gates' times against the last module's `gates.log`
   (`~/kajo-scratch/weekly-1123-failures/check/gates.log`).

## Rules of the house that bind here

- A margin printed by a passing test is read by a tool or by nobody.
- A summary that classifies a field lists the field's every value first;
  what it does not know is counted as unknown.
- A changed gate script is run once on its own before the gate run;
  `status`, `path` and `argv` are zsh's.
- A test script no gate runs is wrong by the next module.
- A test's reported duration is not its body's.
- A failure message prints every clause of the condition it waited for.
- Read the line of code that prints a field before saying what it
  measures.
- A count from a script is checked on three rows by hand before a doc
  quotes it.
- A rule that decides is written, and copied with its time, before its
  numbers.
- A new test's own faults are found by the gates: run the changed test
  files once under the sanitizer with twelve busy loops before the tier.
- `swift test` writes to a file in blocks; wait for the process.
- Fixing one class of bound, grep for the class.

## Not in this module

- Changing any bound, the client's request timeout or `class.hierarchy`.
- Failing a gate or the weekly run on a thin margin.
- The two tests found by the last module (`ProjectDirectoryTests`, the
  turn-overrun test), the tag test's unexplained weekly failure, the VM's
  Delay timers, the runner for the by-hand broken variants.
- Margins of the shells' matrices and the device rows (`--bar` reads
  those).
- Anything under `Sources/`.

## Deliverables

- This doc with "As built": part 1's table, the line's shape, the THIN
  rule with its time, the real run's table, what was kept of the old
  lines, deviations, not done, found.
- The helper and its uses under `Tests/`; `scripts/margins.py` with its
  fixtures and test; `weekly.sh` and `check-tier-test.sh` changed;
  `justfile`'s `margins`.
- `~/kajo-scratch/weekly-margins/`: `part1/` (the rule with its time),
  `broken/`, `work/` (the loaded runs, the scratch weekly run), `check/`.

## Open questions

Build the recommended option; decisions only.

1. THIN's number. Recommended: a fraction of 0.8 in any gate, as a mark
   only. Part 1 may show another number fits the spread better; say it.
2. Should a thin margin fail the weekly run? Recommended: no; the summary
   shows it and the main session reads the summary.
3. Should `just check` print the table at the end of a tier? Recommended:
   yes if it is one call and cannot change the tier's exit status;
   otherwise by hand through `just margins`.
4. The old lines (`stall-diag body`, `tools-tags`): kept beside the new
   one or replaced? Recommended: kept where a doc, a record or a script
   names them; the new line is added.
