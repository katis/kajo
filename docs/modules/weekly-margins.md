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

## As built

Toolchain: swiftly's swift.org Swift 6.4.2 first on PATH, its `clang`,
Homebrew's Python 3.12.2 (`~/kajo-scratch/weekly-margins/env.txt`). Every
file named below without a path is under `~/kajo-scratch/weekly-margins/`.

### Part 1: the inventory (2026-11-24)

**The rules**, written before any value was read (`part1/rule.txt`, copied
`part1/rule.copy.txt` at 16:54:47, before the instrumented runs began at
17:00 and before any eee63db value was tabulated). A site is a place under
`Tests/` where a test waits against a bound or asserts a measured time,
CPU or count of wakeups against a ceiling, counted at a helper's call site.
**Never near**: reached in both measured runs, its largest value below 5
percent of its bound in both, and named in no record as having failed or
come close (the stall tests, the tools' `until`, `class.hierarchy`, the
turn overrun, `ProjectDirectoryTests`' `ready`). A site not reached, or
over 5 percent, or named, prints. **THIN**: a fraction of 0.8 or more in
any gate, a mark only.

**How it was measured.** `part1/instr/sites.py` lists every call of a
waiting helper and every inline loop, semaphore wait and ceiling under
`Tests/` on 51be5b2 (`part1/sites.tsv`). `part1/instr/instrument.py` made an
uncommitted copy of 51be5b2 (`part1/tree`, removed before the hand-back)
in which each helper (`eventually`, `waitAllTerminated`, `drive`, `run`,
`LocalTools.until` and `probe`, `StallDiag.wait` and `waitProgress`, the
shell-close `until`, `within`, and `ProtocolClient`'s `send`, `request`,
`open` and `waitForEvent`, the last in the copy's `Sources/KajoDev`) takes
its caller's `#fileID` and `#line` and records the value against the bound
in effect, each inline site records under its 51be5b2 line, the tools record
each client's longest round trip per request kind against its timeout at
their end (a scratch `ToolsProbe longestReplies`), and each test process
writes the largest fraction per site, its value, bound and count. It ran
once as `swift-test-load` and once as `tsan-load` through `gl_gate`
(`scripts/instr-gate.sh`; `part1/measure/gates.log`: rc=0 892 s and rc=0
4322 s, 484 and 198 tests each). A first attempt was stopped after a few
minutes (`part1/measure-aborted`): an inline site's 51be5b2 line could be
the same number as a helper call's line in the instrumented copy, so the
inline records were renamed with a prefix and the runs started again.
`part1/instr/join.py` maps the copy's lines back to 51be5b2's (a line diff
of the two files) and applies the rule (`part1/inventory.tsv`);
`part1/instr/classify.py` names the cases the rule did not foresee
(`part1/final.tsv`, `part1/counts.txt`). Three never-near rows were checked
by hand against the raw records (`WeakTests.swift:207`, 0.0044 s of 10 s
under the sanitizer; `ProjectDirectoryTests.swift:47`; `SafepointTests.swift:259`).

**The counts** (551 rows): **141 print**, **370 never near**, 17 in tests
no gate runs (`KAJO_MEASURE`, `KAJO_MEASURE_LONGBYTES`,
`KAJO_CLOSED_SHELL_CALL`, the two `KAJO_TOOLS_HOLD_*` steps, a probe on a
failure path), 20 rows that are not sites (a pattern's false match, or a
helper's own inner wait counted at its callers), one that is not a margin
(`Review3SmallFixesTests.swift:328`, a 0.2 s timeout the test expects to
run out) and two that print nothing (`AllocationStallTests.swift:394`, a
branch no caller reaches; `Fixtures/answers/.../AnswersProbe.class.st:34`, a
Smalltalk loop in a fixture that the Swift helper cannot see: a deviation
from the rule, said here). The 45 calls of the protocol tests' `eval`
helper share its record (`DevProtocolTests.swift:80`, 66.3 s of 300 under
the sanitizer), as `stopped(since:)`, `waitForResult` and the answers
tests' `probe` and `probeUntil` do theirs.

**What the measurement found** (largest fraction, under `tsan-load` unless
said):
- `tools.roundtrip.class.hierarchy`: **41 500 ms against the client's
  30 000 ms request timeout** (1.38) in a passing run; its `(retried)`
  label 27 500 ms (0.92). `process.frames` 21 500 (0.72), `package.list`
  16 400 (0.55). Question 3 of the last record is about this margin.
- `Review3SmallFixesTests.swift:383`, the host-timer test's wait for every
  thread of the global queue to spin: **120.0 of 120 s** (1.00): the wait
  ran out and the test passed (its assertions are on what it saw then).
- `ReserveTests.swift:106`: 94.3 of 120 s in the plain loaded run (0.79).
- `ProcessTests.swift:733` 52.5 of 120 (0.44), `VerifierFaultsTests.swift:126`
  275 of 600 (0.46), `DevelopmentAnswersTests.swift:222` (a session's open)
  13.1 of 30 (0.44), `RelocationKernelTests.swift:72` 350 of 900 (0.39),
  `ConcurrentMarkingTests.swift:309` 225 of 600 (0.38),
  `TypeCheckerTests.swift:46` 1290 of 3600 (0.36), `MainThreadTests.swift:192`
  0.081 of 0.2 ms (0.41, plain; not asserted under the sanitizer).
- Every session `open` under `tsan-load` took 7 to 13 s of its 30 or 60 s.

**Values on eee63db** (the four test gates of the last module, read only,
for the sites that print today; plain, loaded, sanitizer, loaded
sanitizer): the main-worker stall test's body 75.0, 85.0, 144.6, 204.6 s;
the full-heap test's 261.0, 376.5, 436.6, 932.8 s (both with no bound on
the body); the tag test's `ready` step 0.5, 0.7, 16.8, 25.2 s and
`definedInTag-Probes` 0.1, 0.3, 2.2, 5.0 s (against `until`'s 60 s quiet and
300 s ceiling); the longest `class.hierarchy` round trip in `tools-tags
replies` 456, 649, 18 070, 28 503 ms against 30 000; the turn overrun's CPU
max 0.036, 0.075, 1.35, 3.12 ms against 0.2 (asserted in plain builds only).

**From the list: the line, the kinds, the names.**

    kajo-margin name=<name> kind=<kind> value=<v> bound=<b> unit=<unit>

One helper per test target prints it when the wait ends, passing or failing.
Kinds: `deadline` (a clock on the whole wait, the value its time),
`quiet` (a bound on a stretch with no progress, the value the longest such
stretch), `ceiling` (a measured value an assertion bounds: a CPU time, a
round trip) and `time` (a value with no bound, `bound=-`: the stall tests'
bodies). Names are stable and say where: `stall.<diag>.<label>`,
`stall.body.<test>`, `tools.<test>.<selector><args>.quiet|.total`,
`tools.<test>.probe`, `tools.roundtrip.<kind>`, and `<area>.<test>.<what>`
for the rest. A site called many times (the random programs: 4600 calls a
run) prints only a value larger than any before it for that name in the
process, so the last line is the largest and the output stays small.

**THIN's number** (open question 1): 0.8 as recommended. The spread does
not argue for another: under `tsan-load` the largest fractions are 1.38
and 1.00 (past), then 0.92, 0.79, 0.72, and everything else is at 0.55 or
below; 0.8 marks the four that are at or past it and none of the bulk.

**Starting positions.** 1: right; one shape carries four kinds. 2: right;
every bound is printed from the variable or constant the wait uses (for
`drive` a named default, `driveSeconds`, in place of the literal 30). 3:
right; the stall tests' bodies are kind `time`, their waits `quiet`
against 120 or 600 s. 4: right, and the image side alone knows it: the
round trips are read from the clients' `latencies` by a probe at the
tools' end, the timeout from the client (no `tools/` change; the probe is in
the test fixture). 5: right: `gl_gate`'s start line now ends with
`bound=<s>s`. 6: right, with one limit: a test the sanitizer skips is a
name absent there by design; the real run (part 3) says which. 7:
right.

<details><summary>The table: every site, 51be5b2 (551 rows)</summary>

| site (51be5b2) | helper | bound plain / sanitizer (s) | kind | swift-test-load | tsan-load | verdict |
|---|---|---|---|---|---|---|
| AgentInterfaceTests.swift:61 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| AgentInterfaceTests.swift:62 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| AgentInterfaceTests.swift:63 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| AllocationStallTests.swift:146 | StallDiag.waitProgress stalled | quiet / quiet | quiet | 0.301/120 (0.003) n=2 | 5.17/600 (0.009) n=2 | prints: (named in a record; largest 0.009) |
| AllocationStallTests.swift:150 | StallDiag.waitProgress rings | quiet / quiet | quiet | 0.746/120 (0.006) n=2 | 13.7/600 (0.023) n=2 | prints: (named in a record; largest 0.023) |
| AllocationStallTests.swift:315 | loop, main worker's ring (quiet) | 120 / 600 | quiet | 0.449/120 (0.004) n=1 | 10.4/600 (0.017) n=1 | prints: (named in a record; largest 0.017) |
| AllocationStallTests.swift:393 | StallDiag.wait stalled | underThreadSanitizer ? 600 : 120 / underThreadSanitizer ? 600 : 120 | deadline | 0.071/120 (0.001) n=3 | 0.3/600 (0.001) n=3 | prints: (named in a record; largest 0.001) |
| AllocationStallTests.swift:658 | StallDiag.waitProgress terminated | underThreadSanitizer ? 600 : 120 / underThreadSanitizer ? 600 : 120 | quiet | 9.54/120 (0.080) n=1 | 68.6/600 (0.114) n=1 | prints: (named in a record; largest 0.114) |
| AllocationStallTests.swift:677 | StallDiag.waitProgress interrupts | underThreadSanitizer ? 600 : 120 / underThreadSanitizer ? 600 : 120 | quiet | 10.9/120 (0.091) n=1 | 81.5/600 (0.136) n=1 | prints: (named in a record; largest 0.136) |
| AllocationStallTests.swift:679 | StallDiag.waitProgress terminated | underThreadSanitizer ? 600 : 120 / underThreadSanitizer ? 600 : 120 | quiet | 0.000101/120 (0.000) n=1 | 0.00121/600 (0.000) n=1 | prints: (named in a record; largest 0.000) |
| AllocationStallTests.swift:697 | StallDiag.waitProgress saved | underThreadSanitizer ? 600 : 120 / underThreadSanitizer ? 600 : 120 | quiet | 0.112/120 (0.001) n=1 | 1.51/600 (0.003) n=1 | prints: (named in a record; largest 0.003) |
| AllocationStallTests.swift:701 | StallDiag.waitProgress terminated | underThreadSanitizer ? 600 : 120 / underThreadSanitizer ? 600 : 120 | quiet | 9.87e-05/120 (0.000) n=1 | 0.00022/600 (0.000) n=1 | prints: (named in a record; largest 0.000) |
| AllocationStallTests.swift:744 | StallDiag.wait stalled | underThreadSanitizer ? 600 : 120 / underThreadSanitizer ? 600 : 120 | deadline | 9.27/120 (0.077) n=1 | 118/600 (0.196) n=1 | prints: (named in a record; largest 0.196) |
| AllocationStallTests.swift:749 | StallDiag.waitProgress rings | quiet / quiet | quiet | 2.83/120 (0.024) n=1 | 79.7/600 (0.133) n=1 | prints: (named in a record; largest 0.133) |
| AllocationStallTests.swift:752 | StallDiag.wait idle | underThreadSanitizer ? 600 : 120 / underThreadSanitizer ? 600 : 120 | deadline | 2.52/120 (0.021) n=1 | 0.00081/600 (0.000) n=1 | prints: (named in a record; largest 0.021) |
| AllocationStallTests.swift:759 | StallDiag.waitProgress ringAfterIdle | quiet / quiet | quiet | 0.594/120 (0.005) n=1 | 6.74/600 (0.011) n=1 | prints: (named in a record; largest 0.011) |
| AllocationStallTests.swift:821 | StallDiag.waitProgress seen | quiet / quiet | quiet | 1.25/120 (0.010) n=2 | 2.7/600 (0.004) n=2 | prints: (named in a record; largest 0.010) |
| AllocationStallTests.swift:827 | StallDiag.waitProgress terminated | quiet / quiet | quiet | 1.48/120 (0.012) n=2 | 0.00458/600 (0.000) n=2 | prints: (named in a record; largest 0.012) |
| AllocationStallTests.swift:876 | eventually | underThreadSanitizer ? 1800 : 300 / underThreadSanitizer ? 1800 : 300 | deadline | 53.3/300 (0.178) n=2 | 133/1800 (0.074) n=2 | prints: (named in a record; largest 0.178) |
| AllocationStallTests.swift:882 | waitAllTerminated | underThreadSanitizer ? 1800 : 300 / underThreadSanitizer ? 1800 : 300 | deadline | 0.0928/300 (0.000) n=2 | 176/1800 (0.098) n=2 | prints: (named in a record; largest 0.098) |
| AppServingTests.swift:129 | client open | 30 / 30 | deadline | 0.169/30 (0.006) n=1 | 10.1/30 (0.336) n=1 | prints: (largest 0.336) |
| ConcurrentMarkingTests.swift:309 | waitAllTerminated | underThreadSanitizer ? 600 : 120 / underThreadSanitizer ? 600 : 120 | deadline | 17.5/120 (0.145) n=4 | 225/600 (0.375) n=4 | prints: (largest 0.375) |
| DevProtocolTests.swift:125 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| DevProtocolTests.swift:217 | client request | 60 / 60 | deadline | 0.104/60 (0.002) n=1 | 6.18/60 (0.103) n=1 | prints: (largest 0.103) |
| DevProtocolTests.swift:306 | client request | 60 / 60 | deadline | 0.38/60 (0.006) n=1 | 18.8/60 (0.314) n=1 | prints: (largest 0.314) |
| DevProtocolTests.swift:338 | client request | 60 / 60 | deadline | 0.524/60 (0.009) n=1 | 17.6/60 (0.293) n=1 | prints: (largest 0.293) |
| DevProtocolTests.swift:356 | client request | 60 / 60 | deadline | 0.576/60 (0.010) n=1 | 18.9/60 (0.315) n=1 | prints: (largest 0.315) |
| DevProtocolTests.swift:405 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| DevProtocolTests.swift:426 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| DevProtocolTests.swift:452 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| DevProtocolTests.swift:453 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| DevProtocolTests.swift:486 | loop, a raw reply (poll) | 60 / 60 | deadline | 0.17/60 (0.003) n=302 | 11.9/60 (0.198) n=302 | prints: (largest 0.198) |
| DevProtocolTests.swift:57 | client open | 60 / 60 | deadline | 0.204/60 (0.003) n=17 | 10.7/60 (0.178) n=17 | prints: (largest 0.178) |
| DevProtocolTests.swift:80 | (found by measurement) |  /  |  | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| DevelopmentAnswersTests.swift:222 | client open | 30 / 30 | deadline | 0.165/30 (0.005) n=1 | 13.1/30 (0.437) n=1 | prints: (largest 0.437) |
| DevelopmentAnswersTests.swift:229 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| DevelopmentAnswersTests.swift:265 | client open | 30 / 30 | deadline | 0.184/30 (0.006) n=1 | 9.53/30 (0.318) n=1 | prints: (largest 0.318) |
| DevelopmentAnswersTests.swift:272 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| DevelopmentAnswersTests.swift:354 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| DevelopmentAnswersTests.swift:372 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| DevelopmentAnswersTests.swift:377 | client request | 60 / 60 | deadline | 2.2/60 (0.037) n=1 | 5/60 (0.083) n=1 | prints: (largest 0.083) |
| DevelopmentAnswersTests.swift:389 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| DevelopmentAnswersTests.swift:391 | client eval (request) | 60 / 300 | deadline | 0.0146/3 (0.005) n=1 | 0.165/3 (0.055) n=1 | prints: (largest 0.055) |
| DevelopmentAnswersTests.swift:391 | loop, 3000 x (eval + 1 ms) | 3 (min) / 3 (min) | deadline | 0.0146/3 (0.005) n=1 | 0.165/3 (0.055) n=1 | prints: (largest 0.055) |
| DevelopmentAnswersTests.swift:395 | client request | 60 / 60 | deadline | 2.1/60 (0.035) n=1 | 4.86/60 (0.081) n=1 | prints: (largest 0.081) |
| DevelopmentAnswersTests.swift:401 | client request | 60 / 60 | deadline | 0.341/60 (0.006) n=1 | 15.9/60 (0.265) n=1 | prints: (largest 0.265) |
| DevelopmentAnswersTests.swift:403 | client request | 60 / 60 | deadline | 2.15/60 (0.036) n=1 | 5.36/60 (0.089) n=1 | prints: (largest 0.089) |
| DevelopmentAnswersTests.swift:60 | semaphore, within(seconds) | seconds / seconds | deadline | 6.16/120 (0.051) n=3 | 83.7/600 (0.140) n=3 | prints: (largest 0.140) |
| FallbackPolicyTests.swift:198 | waitAllTerminated | underThreadSanitizer ? 600 : 120 / underThreadSanitizer ? 600 : 120 | deadline | 1.66/120 (0.014) n=1 | 35.7/600 (0.060) n=1 | prints: (largest 0.060) |
| GenerationalTests.swift:405 | waitAllTerminated | underThreadSanitizer ? 600 : 120 / underThreadSanitizer ? 600 : 120 | deadline | 22.3/120 (0.185) n=2 | 215/600 (0.358) n=2 | prints: (largest 0.358) |
| LargeObjectVMTests.swift:248 | waitAllTerminated | underThreadSanitizer ? 600 : 120 / underThreadSanitizer ? 600 : 120 | deadline | 4.08/120 (0.034) n=2 | 53.5/600 (0.089) n=2 | prints: (largest 0.089) |
| LongBytesPrimitiveTests.swift:184 | waitAllTerminated | underThreadSanitizer ? 600 : 120 / underThreadSanitizer ? 600 : 120 | deadline | 23.9/120 (0.199) n=2 | 0.0417/600 (0.000) n=2 | prints: (largest 0.199) |
| MainThreadTests.swift:140 | ceiling, a turn's CPU (ms) | 20 / 100 | ceiling | 1.01/20 (0.051) n=90 | 1.14/100 (0.011) n=91 | prints: (largest 0.051) |
| MainThreadTests.swift:192 | ceiling, CPU overrun max (ms) | 0.2 / not asserted | ceiling | 0.081/0.2 (0.405) n=1 | not reached | prints: (not reached in tsan-load) |
| MarkerThreadTests.swift:116 | eventually | s / s | deadline | 1.28/5 (0.255) n=6 | 4.44/30 (0.148) n=6 | prints: (largest 0.255) |
| PhoneTransportTests.swift:100 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| PhoneTransportTests.swift:105 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| PhoneTransportTests.swift:137 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| PhoneTransportTests.swift:161 | client open | 60 / 60 | deadline | 0.16/60 (0.003) n=1 | 9.12/60 (0.152) n=1 | prints: (largest 0.152) |
| PhoneTransportTests.swift:164 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| PhoneTransportTests.swift:171 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| PhoneTransportTests.swift:200 | client open | 60 / 60 | deadline | 0.16/60 (0.003) n=1 | 9.41/60 (0.157) n=1 | prints: (largest 0.157) |
| PhoneTransportTests.swift:201 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| PhoneTransportTests.swift:267 | LocalTools.until (quiet 60 s, ceiling 300 s) holdsTokenFor: | 60/300 / 60/300 | quiet | quiet 0/60 (0.000) n=1; total 0.00164/300 (0.000) n=1 | quiet 0/60 (0.000) n=1; total 0.0752/300 (0.000) n=1 | prints: (named in a record; largest 0.000) |
| PhoneTransportTests.swift:270 | LocalTools.until (quiet 60 s, ceiling 300 s) remoteReady | 60/300 / 60/300 | quiet | quiet 0.278/60 (0.005) n=1; total 0.483/300 (0.002) n=1 | quiet 17.8/60 (0.296) n=1; total 27.1/300 (0.090) n=1 | prints: (named in a record; largest 0.296) |
| PhoneTransportTests.swift:288 | LocalTools.until (quiet 60 s, ceiling 300 s) remoteReady | 60/300 / 60/300 | quiet | quiet 0.375/60 (0.006) n=1; total 0.585/300 (0.002) n=1 | quiet 17.9/60 (0.299) n=1; total 28/300 (0.093) n=1 | prints: (named in a record; largest 0.299) |
| PhoneTransportTests.swift:290 | LocalTools.until (quiet 60 s, ceiling 300 s) remoteDebuggerReady | 60/300 / 60/300 | quiet | quiet 0.445/60 (0.007) n=1; total 0.536/300 (0.002) n=1 | quiet 20/60 (0.334) n=1; total 22.9/300 (0.076) n=1 | prints: (named in a record; largest 0.334) |
| PhoneTransportTests.swift:295 | LocalTools.until (quiet 60 s, ceiling 300 s) reconnected | 60/300 / 60/300 | quiet | quiet 1.39/60 (0.023) n=1; total 1.74/300 (0.006) n=1 | quiet 9.07/60 (0.151) n=1; total 27.5/300 (0.092) n=1 | prints: (named in a record; largest 0.151) |
| PhoneTransportTests.swift:68 | client open | 60 / 60 | deadline | 0.158/60 (0.003) n=1 | 9.63/60 (0.161) n=1 | prints: (largest 0.161) |
| PhoneTransportTests.swift:69 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| PhoneTransportTests.swift:70 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| PhoneTransportTests.swift:99 | client open | 60 / 60 | deadline | 0.197/60 (0.003) n=1 | 12.3/60 (0.204) n=1 | prints: (largest 0.204) |
| ProcessTests.swift:525 | waitAllTerminated | 60 / 60 | deadline | 0.0864/60 (0.001) n=1 | 3.74/60 (0.062) n=1 | prints: (largest 0.062) |
| ProcessTests.swift:733 | eventually | 120 / 120 | deadline | 12.7/120 (0.106) n=1 | 52.5/120 (0.437) n=1 | prints: (largest 0.437) |
| ProjectDirectoryTests.swift:357 | LocalTools.until (quiet 60 s, ceiling 300 s) ready | 60/300 / 60/300 | quiet | quiet 0.616/60 (0.010) n=1; total 1.01/300 (0.003) n=1 | quiet 1/60 (0.017) n=1; total 44.6/300 (0.149) n=1 | prints: (named in a record; largest 0.149) |
| ProjectDirectoryTests.swift:359 | LocalTools.until (quiet 60 s, ceiling 300 s) compiledThroughTheBrowser | 60/300 / 60/300 | quiet | quiet 0.042/60 (0.001) n=1; total 0.0621/300 (0.000) n=1 | quiet 0.968/60 (0.016) n=1; total 2/300 (0.007) n=1 | prints: (named in a record; largest 0.016) |
| RandomPrograms.swift:595 | waitAllTerminated | underThreadSanitizer ? 600 : 120 / underThreadSanitizer ? 600 : 120 | deadline | 9.77/120 (0.081) n=4600 | 27.5/600 (0.046) n=428 | prints: (largest 0.081) |
| RandomPrograms.swift:598 | waitAllTerminated | 60 / 60 | deadline | not reached | not reached | prints: (not reached in swift-test-load, tsan-load) |
| RandomPrograms.swift:841 | waitAllTerminated | underThreadSanitizer ? 600 : 120 / underThreadSanitizer ? 600 : 120 | deadline | 8.79/120 (0.073) n=1080 | 30.2/600 (0.050) n=100 | prints: (largest 0.073) |
| RandomPrograms.swift:844 | waitAllTerminated | 60 / 60 | deadline | not reached | not reached | prints: (not reached in swift-test-load, tsan-load) |
| RandomPrograms.swift:857 | waitAllTerminated | underThreadSanitizer ? 600 : 120 / underThreadSanitizer ? 600 : 120 | deadline | 9.34/120 (0.078) n=1047 | 55.3/600 (0.092) n=98 | prints: (largest 0.092) |
| RandomPrograms.swift:860 | waitAllTerminated | 60 / 60 | deadline | not reached | not reached | prints: (not reached in swift-test-load, tsan-load) |
| RelocationKernelTests.swift:72 | waitAllTerminated | underThreadSanitizer ? 900 : 180 / underThreadSanitizer ? 900 : 180 | deadline | 39.4/180 (0.219) n=5 | 350/900 (0.389) n=5 | prints: (largest 0.389) |
| RelocationKernelTests.swift:88 | eventually | underThreadSanitizer ? 600 : 120 / underThreadSanitizer ? 600 : 120 | deadline | 6.03/120 (0.050) n=2 | 8.71e-06/600 (0.000) n=2 | prints: (largest 0.050) |
| ReserveTests.swift:106 | waitAllTerminated | underThreadSanitizer ? 600 : 120 / underThreadSanitizer ? 600 : 120 | deadline | 94.3/120 (0.786) n=4 | 151/600 (0.252) n=4 | prints: (largest 0.786) |
| Review3SmallFixesTests.swift:383 | loop, the queue's threads spin | 120 / 120 | deadline | 55.2/120 (0.460) n=1 | 120/120 (1.000) n=1 | prints: (largest 1.000) |
| ReviewFixesPart2Tests.swift:26 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| ReviewFixesPart2Tests.swift:40 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| ReviewFixesPart2Tests.swift:439 | client open | 60 / 60 | deadline | 0.156/60 (0.003) n=1 | 9.77/60 (0.163) n=1 | prints: (largest 0.163) |
| ReviewFixesPart2Tests.swift:443 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| ReviewFixesPart2Tests.swift:51 | client send | 60 / 60 | deadline | 8.78/300 (0.029) n=1 | 336/1200 (0.280) n=1 | prints: (largest 0.280) |
| ReviewFixesPart2Tests.swift:54 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| ReviewFixesTransportTests.swift:135 | client open | 60 / 60 | deadline | 0.168/60 (0.003) n=1 | 12.1/60 (0.202) n=1 | prints: (largest 0.202) |
| ReviewFixesTransportTests.swift:136 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| ReviewFixesTransportTests.swift:144 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| ReviewFixesTransportTests.swift:158 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| ReviewFixesTransportTests.swift:199 | client open | 60 / 60 | deadline | 0.157/60 (0.003) n=1 | 9.98/60 (0.166) n=1 | prints: (largest 0.166) |
| ReviewFixesTransportTests.swift:200 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| ReviewFixesTransportTests.swift:209 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| ReviewFixesTransportTests.swift:244 | client open | 60 / 60 | deadline | 0.276/60 (0.005) n=1 | 9.53/60 (0.159) n=1 | prints: (largest 0.159) |
| ReviewFixesTransportTests.swift:246 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| ReviewFixesTransportTests.swift:35 | loop, closedByServer(within:) | seconds / seconds | deadline | 1.99/30 (0.066) n=20 | 1.95/30 (0.065) n=21 | prints: (largest 0.066) |
| ReviewFixesTransportTests.swift:87 | client open | 60 / 60 | deadline | 0.174/60 (0.003) n=1 | 11.8/60 (0.197) n=1 | prints: (largest 0.197) |
| ReviewFixesTransportTests.swift:88 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | prints: (largest 0.221) |
| ReviewFixesTransportTests.swift:95 | client send | 60 / 60 | deadline | 7.15/60 (0.119) n=1 | 258/1800 (0.143) n=1 | prints: (largest 0.143) |
| SafepointTests.swift:157 | waitAllTerminated | 60 / 60 | deadline | 0.685/60 (0.011) n=1 | 15.6/60 (0.259) n=1 | prints: (largest 0.259) |
| SafepointTests.swift:176 | waitAllTerminated | 300 / 300 | deadline | 4.37/300 (0.015) n=8 | 90.3/300 (0.301) n=8 | prints: (largest 0.301) |
| ShellTests.swift:254 | drive | 120 / 120 | deadline | 8.47/120 (0.071) n=1 | 153/600 (0.254) n=1 | prints: (largest 0.254) |
| ToolsTests.swift:380 | client open | 60 / 60 | deadline | 0.171/60 (0.003) n=1 | 7.12/60 (0.119) n=1 | prints: (largest 0.119) |
| ToolsTests.swift:384 | client send | 60 / 60 | deadline | 0.752/60 (0.013) n=1 | 16.9/60 (0.281) n=1 | prints: (largest 0.281) |
| ToolsTests.swift:391 | client request | 60 / 60 | deadline | 0.754/60 (0.013) n=1 | 18/60 (0.300) n=1 | prints: (largest 0.300) |
| ToolsTests.swift:405 | LocalTools.until (quiet 60 s, ceiling 300 s) ready | 60/300 / 60/300 | quiet | quiet 0.472/60 (0.008) n=1; total 0.772/300 (0.003) n=1 | quiet 0.999/60 (0.017) n=1; total 25.4/300 (0.085) n=1 | prints: (named in a record; largest 0.085) |
| ToolsTests.swift:411 | LocalTools.until (quiet 60 s, ceiling 300 s) compiledThroughTheBrowser | 60/300 / 60/300 | quiet | quiet 0.078/60 (0.001) n=1; total 0.0954/300 (0.000) n=1 | quiet 0.975/60 (0.016) n=1; total 1.91/300 (0.006) n=1 | prints: (named in a record; largest 0.016) |
| ToolsTests.swift:424 | LocalTools.until (quiet 60 s, ceiling 300 s) compiledTypedThroughTheBrowser | 60/300 / 60/300 | quiet | quiet 0/60 (0.000) n=1; total 0.117/300 (0.000) n=1 | quiet 0.997/60 (0.017) n=1; total 2.75/300 (0.009) n=1 | prints: (named in a record; largest 0.017) |
| ToolsTests.swift:446 | LocalTools.until (quiet 60 s, ceiling 300 s) ready | 60/300 / 60/300 | quiet | quiet 0.363/60 (0.006) n=1; total 0.646/300 (0.002) n=1 | quiet 0.999/60 (0.017) n=1; total 25.4/300 (0.085) n=1 | prints: (named in a record; largest 0.085) |
| ToolsTests.swift:448 | LocalTools.until seconds: typesProbeDefined | typesWait / typesWait | deadline | 0.248/600 (0.000) n=1 | 5.14/3600 (0.001) n=1 | prints: (named in a record; largest 0.001) |
| ToolsTests.swift:450 | LocalTools.until seconds: typesProbeShows: | typesWait / typesWait | deadline | 0.171/600 (0.000) n=1 | 5.4/3600 (0.002) n=1 | prints: (named in a record; largest 0.002) |
| ToolsTests.swift:453 | LocalTools.until seconds: typesProbeShows: | typesWait / typesWait | deadline | 0.153/600 (0.000) n=1 | 2.6/3600 (0.001) n=1 | prints: (named in a record; largest 0.001) |
| ToolsTests.swift:456 | LocalTools.until seconds: typesEventCame | typesWait / typesWait | deadline | 0.00012/600 (0.000) n=1 | 0.314/3600 (0.000) n=1 | prints: (named in a record; largest 0.000) |
| ToolsTests.swift:499 | LocalTools.until (quiet 60 s, ceiling 300 s) ready | 60/300 / 60/300 | quiet | quiet 0.378/60 (0.006) n=1; total 0.692/300 (0.002) n=1 | quiet 1/60 (0.017) n=1; total 25.6/300 (0.085) n=1 | prints: (named in a record; largest 0.085) |
| ToolsTests.swift:510 | LocalTools.until (quiet 60 s, ceiling 300 s) definedInTag: | 60/300 / 60/300 | quiet | quiet 0/60 (0.000) n=1; total 0.153/300 (0.001) n=1 | quiet 0/60 (0.000) n=1; total 4.78/300 (0.016) n=1 | prints: (named in a record; largest 0.016) |
| ToolsTests.swift:518 | LocalTools.until (quiet 60 s, ceiling 300 s) definedInTag: | 60/300 / 60/300 | quiet | quiet 0/60 (0.000) n=1; total 0.0815/300 (0.000) n=1 | quiet 0.429/60 (0.007) n=1; total 1.27/300 (0.004) n=1 | prints: (named in a record; largest 0.007) |
| ToolsTests.swift:525 | LocalTools.until (quiet 60 s, ceiling 300 s) tagProbeRemoved | 60/300 / 60/300 | quiet | quiet 0.12/60 (0.002) n=1; total 0.199/300 (0.001) n=1 | quiet 0.982/60 (0.016) n=1; total 5.21/300 (0.017) n=1 | prints: (named in a record; largest 0.017) |
| ToolsTests.swift:546 | LocalTools.until (quiet 60 s, ceiling 300 s) ready | 60/300 / 60/300 | quiet | quiet 0.471/60 (0.008) n=1; total 0.674/300 (0.002) n=1 | quiet 0.998/60 (0.017) n=1; total 25.5/300 (0.085) n=1 | prints: (named in a record; largest 0.085) |
| ToolsTests.swift:553 | LocalTools.until (quiet 60 s, ceiling 300 s) debuggerReady | 60/300 / 60/300 | quiet | quiet 0.241/60 (0.004) n=1; total 0.372/300 (0.001) n=1 | quiet 0/60 (0.000) n=1; total 12.3/300 (0.041) n=1 | prints: (named in a record; largest 0.041) |
| ToolsTests.swift:562 | LocalTools.probe (drive) | 30 / 150 | deadline | 0.153/60 (0.003) n=7 | 5.39/60 (0.090) n=106 | prints: (largest 0.090) |
| ToolsTests.swift:562 | loop, probe results 42 | 60 / 60 | deadline | 0.153/60 (0.003) n=7 | 5.39/60 (0.090) n=106 | prints: (largest 0.090) |
| TypeCheckerTests.swift:46 | client request | typesWait / typesWait | deadline | 40.2/600 (0.067) n=1 | 1.29e+03/3600 (0.357) n=1 | prints: (largest 0.357) |
| TypeCheckerTests.swift:76 | client request | 60 / 60 | deadline | 0.113/60 (0.002) n=1 | 4.01/60 (0.067) n=1 | prints: (largest 0.067) |
| VerifierFaultsTests.swift:126 | waitAllTerminated | 600 / 600 | deadline | 46.6/600 (0.078) n=3 | 275/600 (0.458) n=3 | prints: (largest 0.458) |
| roundtrip#class.define | (found by measurement) |  /  |  | class.define 70/3e+04 (0.002) n=2 | class.define 3.73e+03/3e+04 (0.124) n=2 | prints: (largest 0.124) |
| roundtrip#class.definition | (found by measurement) |  /  |  | class.definition 170/3e+04 (0.006) n=5 | class.definition 4.2e+03/3e+04 (0.140) n=5 | prints: (largest 0.140) |
| roundtrip#class.hierarchy | (found by measurement) |  /  |  | class.hierarchy 909/3e+04 (0.030) n=7 | class.hierarchy 4.15e+04/3e+04 (1.382) n=7 | prints: (named in a record; largest 1.382) |
| roundtrip#class.hierarchy (retried) | (found by measurement) |  /  |  | class.hierarchy (retried) 1.74e+03/3e+04 (0.058) n=1 | class.hierarchy (retried) 2.75e+04/3e+04 (0.916) n=1 | prints: (named in a record; largest 0.916) |
| roundtrip#class.remove | (found by measurement) |  /  |  | class.remove 113/3e+04 (0.004) n=1 | class.remove 3.04e+03/3e+04 (0.101) n=1 | prints: (largest 0.101) |
| roundtrip#class.selectors | (found by measurement) |  /  |  | class.selectors 152/3e+04 (0.005) n=5 | class.selectors 3.5e+03/3e+04 (0.117) n=5 | prints: (largest 0.117) |
| roundtrip#diagnostics | (found by measurement) |  /  |  | diagnostics 169/3e+04 (0.006) n=1 | diagnostics 6.23e+03/3e+04 (0.208) n=1 | prints: (largest 0.208) |
| roundtrip#method.compile | (found by measurement) |  /  |  | method.compile 114/3e+04 (0.004) n=4 | method.compile 4.35e+03/3e+04 (0.145) n=4 | prints: (largest 0.145) |
| roundtrip#package.list | (found by measurement) |  /  |  | package.list 329/3e+04 (0.011) n=7 | package.list 1.64e+04/3e+04 (0.545) n=7 | prints: (largest 0.545) |
| roundtrip#process.frames | (found by measurement) |  /  |  | process.frames 489/3e+04 (0.016) n=2 | process.frames 2.15e+04/3e+04 (0.716) n=2 | prints: (largest 0.716) |
| roundtrip#process.list (retried) | (found by measurement) |  /  |  | process.list (retried) 1.08e+03/3e+04 (0.036) n=1 | process.list (retried) 3.66e+03/3e+04 (0.122) n=1 | prints: (largest 0.122) |
| AllocationStallTests.swift:394 | eventually | underThreadSanitizer ? 600 : 120 / underThreadSanitizer ? 600 : 120 | deadline | not reached | not reached | prints nothing: no caller reaches it (every waitStalled passes a StallDiag): prints nothing |
| Fixtures/answers/Tests/AnswersProbe.class.st:34 | Smalltalk loop, 10000 x 1 ms Delay | 10000 tries / 10000 tries | deadline | not reached | not reached | prints nothing: a Smalltalk loop in a fixture, not measured: prints nothing (deviation) |
| Review3SmallFixesTests.swift:328 | client send | 60 / 60 | deadline | 0.21/0.2 (1.048) n=1 | 0.21/0.2 (1.052) n=1 | not a margin: not a margin: the test expects this 0.2 s timeout to run out |
| ClosedShellCallsTests.swift:22 | run (drive) | 30 / 150 | deadline | not reached | not reached | by hand: no gate runs it: KAJO_CLOSED_SHELL_CALL |
| DevProtocolTests.swift:526 | client request | 60 / 60 | deadline | not reached | not reached | by hand: no gate runs it: KAJO_MEASURE (ProtocolMeasureTests) |
| DevProtocolTests.swift:527 | client request | 60 / 60 | deadline | not reached | not reached | by hand: no gate runs it: KAJO_MEASURE (ProtocolMeasureTests) |
| DevProtocolTests.swift:531 | client request | 60 / 60 | deadline | not reached | not reached | by hand: no gate runs it: KAJO_MEASURE (ProtocolMeasureTests) |
| DevProtocolTests.swift:533 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | by hand: no gate runs it: KAJO_MEASURE (ProtocolMeasureTests) |
| DevProtocolTests.swift:535 | client request | 60 / 60 | deadline | not reached | not reached | by hand: no gate runs it: KAJO_MEASURE (ProtocolMeasureTests) |
| DevProtocolTests.swift:541 | client request | 60 / 60 | deadline | not reached | not reached | by hand: no gate runs it: KAJO_MEASURE (ProtocolMeasureTests) |
| DevProtocolTests.swift:546 | client request | 60 / 60 | deadline | not reached | not reached | by hand: no gate runs it: KAJO_MEASURE (ProtocolMeasureTests) |
| DevProtocolTests.swift:549 | client eval (request) (via DevProtocolTests.swift:80) | 60 / 300 | deadline | 1.98/60 (0.033) n=45 | 66.3/300 (0.221) n=45 | by hand: no gate runs it: KAJO_MEASURE (ProtocolMeasureTests) |
| DevProtocolTests.swift:553 | client request | 60 / 60 | deadline | not reached | not reached | by hand: no gate runs it: KAJO_MEASURE (ProtocolMeasureTests) |
| DevProtocolTests.swift:557 | client request | 60 / 60 | deadline | not reached | not reached | by hand: no gate runs it: KAJO_MEASURE (ProtocolMeasureTests) |
| DevProtocolTests.swift:560 | client request | 60 / 60 | deadline | not reached | not reached | by hand: no gate runs it: KAJO_MEASURE (ProtocolMeasureTests) |
| DevProtocolTests.swift:563 | client request | 60 / 60 | deadline | not reached | not reached | by hand: no gate runs it: KAJO_MEASURE (ProtocolMeasureTests) |
| LongBytesMeasurement.swift:116 | waitAllTerminated | 600 / 600 | deadline | not reached | not reached | by hand: no gate runs it: KAJO_MEASURE_LONGBYTES |
| PhoneTransportTests.swift:296 | LocalTools.probe (drive) | 30 / 150 | deadline | not reached | not reached | by hand: no gate runs it: a probe on the reconnect test's failure path (counted in tools.<test>.probe) |
| ToolsTests.swift:421 | LocalTools.probe (drive) | 30 / 150 | deadline | not reached | not reached | by hand: no gate runs it: KAJO_TOOLS_HOLD_INSTALL (counted in tools.<test>.probe when run) |
| ToolsTests.swift:506 | LocalTools.probe (drive) | 30 / 150 | deadline | not reached | not reached | by hand: no gate runs it: KAJO_TOOLS_HOLD_LOOP (counted in tools.<test>.probe when run) |
| AOTProductTests.swift:41 | waitAllTerminated | 60 / 60 | deadline | 0.0987/60 (0.002) n=12 | 0.0482/60 (0.001) n=12 | never near: (largest 0.002) |
| AOTProductTests.swift:50 | waitAllTerminated | 60 / 60 | deadline | 0.0717/60 (0.001) n=12 | 0.821/60 (0.014) n=12 | never near: (largest 0.014) |
| AOTProductTests.swift:64 | waitAllTerminated | 60 / 60 | deadline | 0.0431/60 (0.001) n=1 | 0.0615/60 (0.001) n=1 | never near: (largest 0.001) |
| AOTProductTests.swift:70 | waitAllTerminated | 60 / 60 | deadline | 0.0276/60 (0.000) n=1 | 0.478/60 (0.008) n=1 | never near: (largest 0.008) |
| AOTProductTests.swift:78 | waitAllTerminated | 60 / 60 | deadline | 0.0332/60 (0.001) n=1 | 0.118/60 (0.002) n=1 | never near: (largest 0.002) |
| AOTProductTests.swift:97 | waitAllTerminated | 60 / 60 | deadline | 0.091/60 (0.002) n=1 | 0.0431/60 (0.001) n=1 | never near: (largest 0.002) |
| AgentInterfaceTests.swift:159 | waitForResult (3000 x eval) (via DevProtocolTests.swift:285) | 3000 tries / 3000 tries | deadline | 0.0166/30 (0.001) n=9 | 0.349/30 (0.012) n=9 | never near: (largest 0.012) |
| AppServingTests.swift:130 | client request | 60 / 60 | deadline | 0.0124/60 (0.000) n=1 | 0.187/60 (0.003) n=1 | never near: (largest 0.003) |
| AppServingTests.swift:139 | client open | 30 / 30 | deadline | 0.000403/30 (0.000) n=1 | 0.000715/30 (0.000) n=1 | never near: (largest 0.000) |
| AppServingTests.swift:219 | loop, AfterFrames' bound fires | 120 / 120 | deadline | 0.0535/120 (0.000) n=1 | 0.0558/120 (0.000) n=1 | never near: (largest 0.000) |
| DelayEndTests.swift:102 | eventually | 10 / 10 | deadline | 8.42e-06/10 (0.000) n=16 | 3.66e-05/10 (0.000) n=16 | never near: (largest 0.000) |
| DelayEndTests.swift:122 | eventually | 120 / 120 | deadline | 5.75e-06/120 (0.000) n=16 | 2.35e-05/120 (0.000) n=16 | never near: (largest 0.000) |
| DelayEndTests.swift:38 | eventually | 10 / 10 | deadline | 0.0021/10 (0.000) n=1 | 0.00256/10 (0.000) n=1 | never near: (largest 0.000) |
| DelayEndTests.swift:50 | eventually | 120 / 120 | deadline | 1.97/120 (0.016) n=1 | 1.72/120 (0.014) n=1 | never near: (largest 0.016) |
| DelayEndTests.swift:60 | eventually | 10 / 10 | deadline | 0.0416/10 (0.004) n=1 | 0.00287/10 (0.000) n=1 | never near: (largest 0.004) |
| DelayEndTests.swift:62 | eventually | 120 / 120 | deadline | 1.54/120 (0.013) n=1 | 1.59/120 (0.013) n=1 | never near: (largest 0.013) |
| DevProtocolTests.swift:115 | client send | 60 / 60 | deadline | 0.000311/30 (0.000) n=1 | 0.000676/30 (0.000) n=1 | never near: (largest 0.000) |
| DevProtocolTests.swift:119 | client open | 30 / 30 | deadline | 0.000184/30 (0.000) n=1 | 0.000677/30 (0.000) n=1 | never near: (largest 0.000) |
| DevProtocolTests.swift:121 | client open | 30 / 30 | deadline | 0.000144/30 (0.000) n=1 | 0.000527/30 (0.000) n=1 | never near: (largest 0.000) |
| DevProtocolTests.swift:123 | client request | 60 / 60 | deadline | 0.0514/60 (0.001) n=1 | 2.76/60 (0.046) n=1 | never near: (largest 0.046) |
| DevProtocolTests.swift:187 | client request | 60 / 60 | deadline | 0.0168/60 (0.000) n=1 | 0.496/60 (0.008) n=1 | never near: (largest 0.008) |
| DevProtocolTests.swift:197 | client request | 60 / 60 | deadline | 0.0347/60 (0.001) n=1 | 1.37/60 (0.023) n=1 | never near: (largest 0.023) |
| DevProtocolTests.swift:203 | client request | 60 / 60 | deadline | 0.00813/60 (0.000) n=1 | 0.0925/60 (0.002) n=1 | never near: (largest 0.002) |
| DevProtocolTests.swift:208 | client request | 60 / 60 | deadline | 0.0474/60 (0.001) n=1 | 1.75/60 (0.029) n=1 | never near: (largest 0.029) |
| DevProtocolTests.swift:214 | client request | 60 / 60 | deadline | 0.0123/60 (0.000) n=1 | 0.64/60 (0.011) n=1 | never near: (largest 0.011) |
| DevProtocolTests.swift:219 | client request | 60 / 60 | deadline | 0.0197/60 (0.000) n=1 | 0.787/60 (0.013) n=1 | never near: (largest 0.013) |
| DevProtocolTests.swift:220 | client request | 60 / 60 | deadline | 0.0131/60 (0.000) n=1 | 0.726/60 (0.012) n=1 | never near: (largest 0.012) |
| DevProtocolTests.swift:223 | client request | 60 / 60 | deadline | 0.00652/60 (0.000) n=1 | 0.314/60 (0.005) n=1 | never near: (largest 0.005) |
| DevProtocolTests.swift:230 | client send | 60 / 60 | deadline | 0.00668/60 (0.000) n=1 | 0.1/60 (0.002) n=1 | never near: (largest 0.002) |
| DevProtocolTests.swift:232 | client request | 60 / 60 | deadline | 0.0203/60 (0.000) n=1 | 0.996/60 (0.017) n=1 | never near: (largest 0.017) |
| DevProtocolTests.swift:236 | client send | 60 / 60 | deadline | 0.0214/60 (0.000) n=1 | 0.867/60 (0.014) n=1 | never near: (largest 0.014) |
| DevProtocolTests.swift:260 | client request | 60 / 60 | deadline | 0.0504/60 (0.001) n=1 | 2.86/60 (0.048) n=1 | never near: (largest 0.048) |
| DevProtocolTests.swift:261 | client request | 60 / 60 | deadline | 0.0245/60 (0.000) n=1 | 0.847/60 (0.014) n=1 | never near: (largest 0.014) |
| DevProtocolTests.swift:263 | client request | 60 / 60 | deadline | 0.0624/60 (0.001) n=1 | 2.87/60 (0.048) n=1 | never near: (largest 0.048) |
| DevProtocolTests.swift:267 | client request | 60 / 60 | deadline | 0.00189/60 (0.000) n=1 | 0.0461/60 (0.001) n=1 | never near: (largest 0.001) |
| DevProtocolTests.swift:268 | client send | 60 / 60 | deadline | 0.00421/60 (0.000) n=1 | 0.0388/60 (0.001) n=1 | never near: (largest 0.001) |
| DevProtocolTests.swift:285 | loop, 3000 x (eval + 10 ms) | 30 (min) / 30 (min) | deadline | 0.0166/30 (0.001) n=9 | 0.349/30 (0.012) n=9 | never near: (largest 0.012) |
| DevProtocolTests.swift:310 | client request | 60 / 60 | deadline | 0.00409/60 (0.000) n=1 | 0.0965/60 (0.002) n=1 | never near: (largest 0.002) |
| DevProtocolTests.swift:311 | waitForResult (3000 x eval) (via DevProtocolTests.swift:285) | 3000 tries / 3000 tries | deadline | 0.0166/30 (0.001) n=9 | 0.349/30 (0.012) n=9 | never near: (largest 0.012) |
| DevProtocolTests.swift:315 | client request | 60 / 60 | deadline | 0.00411/60 (0.000) n=1 | 0.127/60 (0.002) n=1 | never near: (largest 0.002) |
| DevProtocolTests.swift:316 | waitForResult (3000 x eval) (via DevProtocolTests.swift:285) | 3000 tries / 3000 tries | deadline | 0.0166/30 (0.001) n=9 | 0.349/30 (0.012) n=9 | never near: (largest 0.012) |
| DevProtocolTests.swift:319 | client request | 60 / 60 | deadline | 0.0297/60 (0.001) n=1 | 1.5/60 (0.025) n=1 | never near: (largest 0.025) |
| DevProtocolTests.swift:322 | client request | 60 / 60 | deadline | 0.00517/60 (0.000) n=1 | 0.132/60 (0.002) n=1 | never near: (largest 0.002) |
| DevProtocolTests.swift:323 | waitForResult (3000 x eval) (via DevProtocolTests.swift:285) | 3000 tries / 3000 tries | deadline | 0.0166/30 (0.001) n=9 | 0.349/30 (0.012) n=9 | never near: (largest 0.012) |
| DevProtocolTests.swift:326 | client send | 60 / 60 | deadline | 0.00476/60 (0.000) n=1 | 0.077/60 (0.001) n=1 | never near: (largest 0.001) |
| DevProtocolTests.swift:328 | client request | 60 / 60 | deadline | 0.00302/60 (0.000) n=1 | 0.0906/60 (0.002) n=1 | never near: (largest 0.002) |
| DevProtocolTests.swift:330 | client request | 60 / 60 | deadline | 0.00674/60 (0.000) n=1 | 0.115/60 (0.002) n=1 | never near: (largest 0.002) |
| DevProtocolTests.swift:344 | client request | 60 / 60 | deadline | 0.0205/60 (0.000) n=1 | 1.2/60 (0.020) n=1 | never near: (largest 0.020) |
| DevProtocolTests.swift:347 | client request | 60 / 60 | deadline | 0.00821/60 (0.000) n=1 | 0.215/60 (0.004) n=1 | never near: (largest 0.004) |
| DevProtocolTests.swift:348 | waitForResult (3000 x eval) (via DevProtocolTests.swift:285) | 3000 tries / 3000 tries | deadline | 0.0166/30 (0.001) n=9 | 0.349/30 (0.012) n=9 | never near: (largest 0.012) |
| DevProtocolTests.swift:368 | client request | 60 / 60 | deadline | 0.00581/60 (0.000) n=4 | 0.0788/60 (0.001) n=4 | never near: (largest 0.001) |
| DevProtocolTests.swift:369 | client stopped (waitForEvent) (via DevProtocolTests.swift:84) | 60 / 60 | deadline | 0.0124/60 (0.000) n=16 | 0.602/60 (0.010) n=16 | never near: (largest 0.010) |
| DevProtocolTests.swift:387 | client request | 60 / 60 | deadline | 0.0343/60 (0.001) n=1 | 1.81/60 (0.030) n=1 | never near: (largest 0.030) |
| DevProtocolTests.swift:390 | client request | 60 / 60 | deadline | 0.0274/60 (0.000) n=1 | 1.68/60 (0.028) n=1 | never near: (largest 0.028) |
| DevProtocolTests.swift:391 | client request | 60 / 60 | deadline | 0.0576/60 (0.001) n=1 | 1.77/60 (0.029) n=1 | never near: (largest 0.029) |
| DevProtocolTests.swift:392 | client request | 60 / 60 | deadline | 0.0018/60 (0.000) n=1 | 0.0474/60 (0.001) n=1 | never near: (largest 0.001) |
| DevProtocolTests.swift:393 | waitForResult (3000 x eval) (via DevProtocolTests.swift:285) | 3000 tries / 3000 tries | deadline | 0.0166/30 (0.001) n=9 | 0.349/30 (0.012) n=9 | never near: (largest 0.012) |
| DevProtocolTests.swift:401 | client request | 60 / 60 | deadline | 0.0056/60 (0.000) n=1 | 0.233/60 (0.004) n=1 | never near: (largest 0.004) |
| DevProtocolTests.swift:402 | waitForResult (3000 x eval) (via DevProtocolTests.swift:285) | 3000 tries / 3000 tries | deadline | 0.0166/30 (0.001) n=9 | 0.349/30 (0.012) n=9 | never near: (largest 0.012) |
| DevProtocolTests.swift:403 | client request | 60 / 60 | deadline | 0.00769/60 (0.000) n=1 | 0.0785/60 (0.001) n=1 | never near: (largest 0.001) |
| DevProtocolTests.swift:407 | waitForResult (3000 x eval) (via DevProtocolTests.swift:285) | 3000 tries / 3000 tries | deadline | 0.0166/30 (0.001) n=9 | 0.349/30 (0.012) n=9 | never near: (largest 0.012) |
| DevProtocolTests.swift:409 | client request | 60 / 60 | deadline | 0.0038/60 (0.000) n=1 | 0.155/60 (0.003) n=1 | never near: (largest 0.003) |
| DevProtocolTests.swift:410 | client stopped (waitForEvent) (via DevProtocolTests.swift:84) | 60 / 60 | deadline | 0.0124/60 (0.000) n=16 | 0.602/60 (0.010) n=16 | never near: (largest 0.010) |
| DevProtocolTests.swift:412 | client request | 60 / 60 | deadline | 0.00579/60 (0.000) n=1 | 0.0582/60 (0.001) n=1 | never near: (largest 0.001) |
| DevProtocolTests.swift:413 | client request | 60 / 60 | deadline | 0.0128/60 (0.000) n=1 | 0.125/60 (0.002) n=1 | never near: (largest 0.002) |
| DevProtocolTests.swift:414 | client request | 60 / 60 | deadline | 0.0276/60 (0.000) n=3001 | 0.422/60 (0.007) n=3001 | never near: (largest 0.007) |
| DevProtocolTests.swift:414 | loop, 3000 x (process.list + 10 ms) | 30 (min) / 30 (min) | deadline | 0.0276/60 (0.000) n=3001 | 0.422/60 (0.007) n=3001 | never near: (largest 0.007) |
| DevProtocolTests.swift:415 | client request | 60 / 60 | deadline | 0.00742/60 (0.000) n=1 | 0.0765/60 (0.001) n=1 | never near: (largest 0.001) |
| DevProtocolTests.swift:432 | loop, 3000 x (process.list + 10 ms) | 30 (min) / 30 (min) | deadline | 0.00517/30 (0.000) n=1 | 0.106/30 (0.004) n=1 | never near: (largest 0.004) |
| DevProtocolTests.swift:433 | client request | 60 / 60 | deadline | 0.00354/60 (0.000) n=1 | 0.101/60 (0.002) n=1 | never near: (largest 0.002) |
| DevProtocolTests.swift:439 | client request | 60 / 60 | deadline | 0.00892/60 (0.000) n=1 | 0.0647/60 (0.001) n=1 | never near: (largest 0.001) |
| DevProtocolTests.swift:440 | client stopped (waitForEvent) (via DevProtocolTests.swift:84) | 60 / 60 | deadline | 0.0124/60 (0.000) n=16 | 0.602/60 (0.010) n=16 | never near: (largest 0.010) |
| DevProtocolTests.swift:442 | client request | 60 / 60 | deadline | 0.00561/60 (0.000) n=1 | 0.0807/60 (0.001) n=1 | never near: (largest 0.001) |
| DevProtocolTests.swift:445 | loop, 3000 x (process.list + 10 ms) | 30 (min) / 30 (min) | deadline | 0.00971/30 (0.000) n=1 | 0.123/30 (0.004) n=1 | never near: (largest 0.004) |
| DevProtocolTests.swift:446 | client request | 60 / 60 | deadline | 0.00821/60 (0.000) n=1 | 0.118/60 (0.002) n=1 | never near: (largest 0.002) |
| DevProtocolTests.swift:454 | waitForResult (3000 x eval) (via DevProtocolTests.swift:285) | 3000 tries / 3000 tries | deadline | 0.0166/30 (0.001) n=9 | 0.349/30 (0.012) n=9 | never near: (largest 0.012) |
| DevProtocolTests.swift:536 | client stopped (waitForEvent) (via DevProtocolTests.swift:84) | 60 / 60 | deadline | 0.0124/60 (0.000) n=16 | 0.602/60 (0.010) n=16 | never near: (largest 0.010) |
| DevProtocolTests.swift:542 | client stopped (waitForEvent) (via DevProtocolTests.swift:84) | 60 / 60 | deadline | 0.0124/60 (0.000) n=16 | 0.602/60 (0.010) n=16 | never near: (largest 0.010) |
| DevProtocolTests.swift:558 | client stopped (waitForEvent) (via DevProtocolTests.swift:84) | 60 / 60 | deadline | 0.0124/60 (0.000) n=16 | 0.602/60 (0.010) n=16 | never near: (largest 0.010) |
| DevProtocolTests.swift:561 | client stopped (waitForEvent) (via DevProtocolTests.swift:84) | 60 / 60 | deadline | 0.0124/60 (0.000) n=16 | 0.602/60 (0.010) n=16 | never near: (largest 0.010) |
| DevProtocolTests.swift:66 | semaphore, RunningTarget's run thread | 30 / 30 | deadline | 0.0453/30 (0.002) n=18 | 0.435/30 (0.015) n=18 | never near: (largest 0.015) |
| DevProtocolTests.swift:84 | (found by measurement) |  /  |  | 0.0124/60 (0.000) n=16 | 0.602/60 (0.010) n=16 | never near: (largest 0.010) |
| DevelopmentAnswersTests.swift:106 | loop, probe's Process ends | 120 / 600 | deadline | 0.0951/120 (0.001) n=24 | 3.59/600 (0.006) n=28 | never near: (largest 0.006) |
| DevelopmentAnswersTests.swift:114 | loop, probeUntil | 120 / 600 | deadline | 0.105/120 (0.001) n=4 | 4.81/600 (0.008) n=4 | never near: (largest 0.008) |
| DevelopmentAnswersTests.swift:115 | DevelopmentAnswers probe (via DevelopmentAnswersTests.swift:106) | hostBoundSeconds 120 / 600 | deadline | 0.0951/120 (0.001) n=24 | 3.59/600 (0.006) n=28 | never near: (largest 0.006) |
| DevelopmentAnswersTests.swift:181 | DevelopmentAnswers probe (via DevelopmentAnswersTests.swift:106) | hostBoundSeconds 120 / 600 | deadline | 0.0951/120 (0.001) n=24 | 3.59/600 (0.006) n=28 | never near: (largest 0.006) |
| DevelopmentAnswersTests.swift:182 | DevelopmentAnswers probe (via DevelopmentAnswersTests.swift:106) | hostBoundSeconds 120 / 600 | deadline | 0.0951/120 (0.001) n=24 | 3.59/600 (0.006) n=28 | never near: (largest 0.006) |
| DevelopmentAnswersTests.swift:191 | DevelopmentAnswers probe (via DevelopmentAnswersTests.swift:106) | hostBoundSeconds 120 / 600 | deadline | 0.0951/120 (0.001) n=24 | 3.59/600 (0.006) n=28 | never near: (largest 0.006) |
| DevelopmentAnswersTests.swift:192 | DevelopmentAnswers probe (via DevelopmentAnswersTests.swift:106) | hostBoundSeconds 120 / 600 | deadline | 0.0951/120 (0.001) n=24 | 3.59/600 (0.006) n=28 | never near: (largest 0.006) |
| DevelopmentAnswersTests.swift:214 | DevelopmentAnswers probe (via DevelopmentAnswersTests.swift:106) | hostBoundSeconds 120 / 600 | deadline | 0.0951/120 (0.001) n=24 | 3.59/600 (0.006) n=28 | never near: (largest 0.006) |
| DevelopmentAnswersTests.swift:215 | DevelopmentAnswers probeUntil (via DevelopmentAnswersTests.swift:114) | hostBoundSeconds 120 / 600 | deadline | 0.105/120 (0.001) n=4 | 4.81/600 (0.008) n=4 | never near: (largest 0.008) |
| DevelopmentAnswersTests.swift:216 | DevelopmentAnswers probe (via DevelopmentAnswersTests.swift:106) | hostBoundSeconds 120 / 600 | deadline | 0.0951/120 (0.001) n=24 | 3.59/600 (0.006) n=28 | never near: (largest 0.006) |
| DevelopmentAnswersTests.swift:223 | client request | 60 / 60 | deadline | 0.0335/60 (0.001) n=1 | 1.88/60 (0.031) n=1 | never near: (largest 0.031) |
| DevelopmentAnswersTests.swift:224 | client request | 60 / 60 | deadline | 0.0177/60 (0.000) n=1 | 0.596/60 (0.010) n=1 | never near: (largest 0.010) |
| DevelopmentAnswersTests.swift:226 | client request | 60 / 60 | deadline | 0.00612/60 (0.000) n=1 | 0.098/60 (0.002) n=1 | never near: (largest 0.002) |
| DevelopmentAnswersTests.swift:228 | loop, 20000 x (eval + 1 ms) | 20 (min) / 20 (min) | deadline | 0.0136/20 (0.001) n=1 | 0.258/20 (0.013) n=1 | never near: (largest 0.013) |
| DevelopmentAnswersTests.swift:241 | DevelopmentAnswers probe (via DevelopmentAnswersTests.swift:106) | hostBoundSeconds 120 / 600 | deadline | 0.0951/120 (0.001) n=24 | 3.59/600 (0.006) n=28 | never near: (largest 0.006) |
| DevelopmentAnswersTests.swift:267 | client request | 60 / 60 | deadline | 0.0171/60 (0.000) n=1 | 0.428/60 (0.007) n=1 | never near: (largest 0.007) |
| DevelopmentAnswersTests.swift:269 | client request | 60 / 60 | deadline | 0.0069/60 (0.000) n=1 | 0.126/60 (0.002) n=1 | never near: (largest 0.002) |
| DevelopmentAnswersTests.swift:271 | loop, 20000 x (eval + 1 ms) | 20 (min) / 20 (min) | deadline | 0.0135/20 (0.001) n=1 | 0.197/20 (0.010) n=1 | never near: (largest 0.010) |
| DevelopmentAnswersTests.swift:290 | run (drive) | 30 / 150 | deadline | 8.02e-05/30 (0.000) n=1 | 0.00159/150 (0.000) n=1 | never near: (largest 0.000) |
| DevelopmentAnswersTests.swift:291 | run (drive) | 30 / 150 | deadline | 1.04e-05/30 (0.000) n=1 | 0.000215/150 (0.000) n=1 | never near: (largest 0.000) |
| DevelopmentAnswersTests.swift:292 | run (drive) | 30 / 150 | deadline | 1.24e-05/30 (0.000) n=1 | 0.000253/150 (0.000) n=1 | never near: (largest 0.000) |
| DevelopmentAnswersTests.swift:295 | drive | hostBoundSeconds / hostBoundSeconds | deadline | 0.0687/120 (0.001) n=1 | 0.224/3000 (0.000) n=1 | never near: (largest 0.001) |
| DevelopmentAnswersTests.swift:295 | DevelopmentAnswers probe | hostBoundSeconds 120 / 600 | deadline | 0.0687/120 (0.001) n=1 | 0.224/3000 (0.000) n=1 | never near: (largest 0.001) |
| DevelopmentAnswersTests.swift:296 | DevelopmentAnswers probe (via DevelopmentAnswersTests.swift:106) | hostBoundSeconds 120 / 600 | deadline | 0.0951/120 (0.001) n=24 | 3.59/600 (0.006) n=28 | never near: (largest 0.006) |
| DevelopmentAnswersTests.swift:297 | DevelopmentAnswers probe (via DevelopmentAnswersTests.swift:106) | hostBoundSeconds 120 / 600 | deadline | 0.0951/120 (0.001) n=24 | 3.59/600 (0.006) n=28 | never near: (largest 0.006) |
| DevelopmentAnswersTests.swift:298 | run (drive) | 30 / 150 | deadline | 0.00664/30 (0.000) n=1 | 0.117/150 (0.001) n=1 | never near: (largest 0.001) |
| DevelopmentAnswersTests.swift:301 | drive | hostBoundSeconds / hostBoundSeconds | deadline | 0.000977/120 (0.000) n=1 | 0.00147/3000 (0.000) n=1 | never near: (largest 0.000) |
| DevelopmentAnswersTests.swift:301 | DevelopmentAnswers probe | hostBoundSeconds 120 / 600 | deadline | 0.000977/120 (0.000) n=1 | 0.00147/3000 (0.000) n=1 | never near: (largest 0.000) |
| DevelopmentAnswersTests.swift:311 | DevelopmentAnswers probe (via DevelopmentAnswersTests.swift:106) | hostBoundSeconds 120 / 600 | deadline | 0.0951/120 (0.001) n=24 | 3.59/600 (0.006) n=28 | never near: (largest 0.006) |
| DevelopmentAnswersTests.swift:313 | DevelopmentAnswers probe (via DevelopmentAnswersTests.swift:106) | hostBoundSeconds 120 / 600 | deadline | 0.0951/120 (0.001) n=24 | 3.59/600 (0.006) n=28 | never near: (largest 0.006) |
| DevelopmentAnswersTests.swift:314 | DevelopmentAnswers probeUntil (via DevelopmentAnswersTests.swift:114) | hostBoundSeconds 120 / 600 | deadline | 0.105/120 (0.001) n=4 | 4.81/600 (0.008) n=4 | never near: (largest 0.008) |
| DevelopmentAnswersTests.swift:315 | DevelopmentAnswers probeUntil (via DevelopmentAnswersTests.swift:114) | hostBoundSeconds 120 / 600 | deadline | 0.105/120 (0.001) n=4 | 4.81/600 (0.008) n=4 | never near: (largest 0.008) |
| DevelopmentAnswersTests.swift:320 | loop, the transcript lines | 120 / 600 | deadline | 0.013/120 (0.000) n=1 | 0.169/600 (0.000) n=1 | never near: (largest 0.000) |
| DevelopmentAnswersTests.swift:327 | DevelopmentAnswers probe (via DevelopmentAnswersTests.swift:106) | hostBoundSeconds 120 / 600 | deadline | 0.0951/120 (0.001) n=24 | 3.59/600 (0.006) n=28 | never near: (largest 0.006) |
| DevelopmentAnswersTests.swift:328 | DevelopmentAnswers probe (via DevelopmentAnswersTests.swift:106) | hostBoundSeconds 120 / 600 | deadline | 0.0951/120 (0.001) n=24 | 3.59/600 (0.006) n=28 | never near: (largest 0.006) |
| DevelopmentAnswersTests.swift:329 | DevelopmentAnswers probe (via DevelopmentAnswersTests.swift:106) | hostBoundSeconds 120 / 600 | deadline | 0.0951/120 (0.001) n=24 | 3.59/600 (0.006) n=28 | never near: (largest 0.006) |
| DevelopmentAnswersTests.swift:336 | DevelopmentAnswers probe (via DevelopmentAnswersTests.swift:106) | hostBoundSeconds 120 / 600 | deadline | 0.0951/120 (0.001) n=24 | 3.59/600 (0.006) n=28 | never near: (largest 0.006) |
| DevelopmentAnswersTests.swift:337 | DevelopmentAnswers probeUntil (via DevelopmentAnswersTests.swift:114) | hostBoundSeconds 120 / 600 | deadline | 0.105/120 (0.001) n=4 | 4.81/600 (0.008) n=4 | never near: (largest 0.008) |
| DevelopmentAnswersTests.swift:347 | client request | 60 / 60 | deadline | 0.0094/60 (0.000) n=1 | 0.273/60 (0.005) n=1 | never near: (largest 0.005) |
| DevelopmentAnswersTests.swift:349 | client request | 60 / 60 | deadline | 0.0173/60 (0.000) n=1 | 0.568/60 (0.009) n=1 | never near: (largest 0.009) |
| DevelopmentAnswersTests.swift:351 | client request | 60 / 60 | deadline | 0.00466/60 (0.000) n=1 | 0.112/60 (0.002) n=1 | never near: (largest 0.002) |
| DevelopmentAnswersTests.swift:353 | loop, 20000 x (eval + 1 ms) | 20 (min) / 20 (min) | deadline | 0.0108/20 (0.001) n=1 | 0.197/20 (0.010) n=1 | never near: (largest 0.010) |
| DevelopmentAnswersTests.swift:381 | client waitForEvent | 60 / 60 | deadline | 1.6e-05/60 (0.000) n=1 | 2.9e-05/60 (0.000) n=1 | never near: (largest 0.000) |
| DevelopmentAnswersTests.swift:386 | client request | 60 / 60 | deadline | 0.00387/60 (0.000) n=1 | 0.117/60 (0.002) n=1 | never near: (largest 0.002) |
| DevelopmentAnswersTests.swift:411 | client request | 60 / 60 | deadline | 0.00692/60 (0.000) n=1 | 0.0711/60 (0.001) n=1 | never near: (largest 0.001) |
| DevelopmentAnswersTests.swift:438 | DevelopmentAnswers probe (via DevelopmentAnswersTests.swift:106) | hostBoundSeconds 120 / 600 | deadline | 0.0951/120 (0.001) n=24 | 3.59/600 (0.006) n=28 | never near: (largest 0.006) |
| DevelopmentAnswersTests.swift:441 | DevelopmentAnswers probe (via DevelopmentAnswersTests.swift:106) | hostBoundSeconds 120 / 600 | deadline | 0.0951/120 (0.001) n=24 | 3.59/600 (0.006) n=28 | never near: (largest 0.006) |
| DevelopmentAnswersTests.swift:443 | DevelopmentAnswers probe (via DevelopmentAnswersTests.swift:106) | hostBoundSeconds 120 / 600 | deadline | 0.0951/120 (0.001) n=24 | 3.59/600 (0.006) n=28 | never near: (largest 0.006) |
| DevelopmentAnswersTests.swift:444 | DevelopmentAnswers probeUntil (via DevelopmentAnswersTests.swift:114) | hostBoundSeconds 120 / 600 | deadline | 0.105/120 (0.001) n=4 | 4.81/600 (0.008) n=4 | never near: (largest 0.008) |
| DevelopmentAnswersTests.swift:449 | DevelopmentAnswers probe (via DevelopmentAnswersTests.swift:106) | hostBoundSeconds 120 / 600 | deadline | 0.0951/120 (0.001) n=24 | 3.59/600 (0.006) n=28 | never near: (largest 0.006) |
| DistributionTests.swift:116 | loop, a lost event | 60 / 60 | deadline | 0.00301/60 (0.000) n=1 | 7.5e-07/60 (0.000) n=1 | never near: (largest 0.000) |
| FallbackPolicyTests.swift:196 | eventually | underThreadSanitizer ? 600 : 60 / underThreadSanitizer ? 600 : 60 | deadline | 0.0398/60 (0.001) n=1 | 0.0686/600 (0.000) n=1 | never near: (largest 0.001) |
| FallbackPolicyTests.swift:204 | waitAllTerminated | underThreadSanitizer ? 600 : 120 / underThreadSanitizer ? 600 : 120 | deadline | 0.206/120 (0.002) n=2 | 2.69/600 (0.004) n=2 | never near: (largest 0.004) |
| FallbackPolicyTests.swift:240 | eventually | underThreadSanitizer ? 600 : 60 / underThreadSanitizer ? 600 : 60 | deadline | 0.0622/60 (0.001) n=1 | 2.56/600 (0.004) n=1 | never near: (largest 0.004) |
| FallbackPolicyTests.swift:242 | waitAllTerminated | underThreadSanitizer ? 600 : 120 / underThreadSanitizer ? 600 : 120 | deadline | 2.78/120 (0.023) n=1 | 19.6/600 (0.033) n=1 | never near: (largest 0.033) |
| FallbackPolicyTests.swift:248 | waitAllTerminated | underThreadSanitizer ? 600 : 120 / underThreadSanitizer ? 600 : 120 | deadline | 0.351/120 (0.003) n=2 | 6.9/600 (0.011) n=2 | never near: (largest 0.011) |
| FinalMarkTests.swift:324 | eventually | 10 / 10 | deadline | 0.000862/10 (0.000) n=1 | 2e-05/10 (0.000) n=1 | never near: (largest 0.000) |
| FinalMarkTests.swift:330 | eventually | 30 / 30 | deadline | 0.000763/30 (0.000) n=1 | 0.000779/30 (0.000) n=1 | never near: (largest 0.000) |
| FinalMarkTests.swift:335 | eventually | 30 / 30 | deadline | 0.000762/30 (0.000) n=1 | 0.000951/30 (0.000) n=1 | never near: (largest 0.000) |
| FinalMarkTests.swift:34 | eventually | 10 / 10 | deadline | 8.42e-06/10 (0.000) n=1 | 1.42e-05/10 (0.000) n=1 | never near: (largest 0.000) |
| FinalMarkTests.swift:38 | eventually | 30 / 30 | deadline | 0.0145/30 (0.000) n=1 | 0.0274/30 (0.001) n=1 | never near: (largest 0.001) |
| GenerationalTests.swift:397 | waitAllTerminated | 60 / 60 | deadline | 0.0373/60 (0.001) n=2 | 0.00256/60 (0.000) n=2 | never near: (largest 0.001) |
| LongBytesPrimitiveTests.swift:259 | waitAllTerminated | underThreadSanitizer ? 600 : 120 / underThreadSanitizer ? 600 : 120 | deadline | 0.197/120 (0.002) n=1 | 12.5/600 (0.021) n=1 | never near: (largest 0.021) |
| MainOffloadTests.swift:84 | loop, runMain until no Process | 120 / 120 | deadline | 1.25e-07/120 (0.000) n=2 | 1.67e-07/120 (0.000) n=2 | never near: (largest 0.000) |
| MainThreadTests.swift:106 | waitAllTerminated | 60 / 60 | deadline | 0.000839/60 (0.000) n=1 | 0.0182/60 (0.000) n=1 | never near: (largest 0.000) |
| MainThreadTests.swift:196 | waitAllTerminated | 60 / 60 | deadline | 0.0368/60 (0.001) n=1 | 0.0605/60 (0.001) n=1 | never near: (largest 0.001) |
| MarkerThreadTests.swift:107 | ceiling, idle marker CPU (ms) | 1 / 1 | ceiling | 0/1 (0.000) n=1 | 0/1 (0.000) n=1 | never near: (largest 0.000) |
| MarkerThreadTests.swift:108 | ceiling, idle marker wakeups | 5 / 5 | ceiling | 0/5 (0.000) n=1 | 0/5 (0.000) n=1 | never near: (largest 0.000) |
| MarkerThreadTests.swift:124 | waitAllTerminated | 60 / 60 | deadline | 0.0228/60 (0.000) n=1 | 0.498/60 (0.008) n=1 | never near: (largest 0.008) |
| MarkerThreadTests.swift:175 | waitAllTerminated | underThreadSanitizer ? 600 : 60 / underThreadSanitizer ? 600 : 60 | deadline | 1.04/60 (0.017) n=1 | 18.7/600 (0.031) n=1 | never near: (largest 0.031) |
| NativeEngineTests.swift:108 | waitAllTerminated | 60 / 60 | deadline | 0.071/60 (0.001) n=2 | 1.03/60 (0.017) n=2 | never near: (largest 0.017) |
| NativeEngineTests.swift:124 | waitAllTerminated | 60 / 60 | deadline | 0.0174/60 (0.000) n=1 | 0.05/60 (0.001) n=1 | never near: (largest 0.001) |
| NativeEngineTests.swift:135 | waitAllTerminated | 60 / 60 | deadline | 0.0577/60 (0.001) n=2 | 0.903/60 (0.015) n=2 | never near: (largest 0.015) |
| NativeEngineTests.swift:152 | waitAllTerminated | 60 / 60 | deadline | 0.105/60 (0.002) n=1 | 0.0454/60 (0.001) n=1 | never near: (largest 0.002) |
| NativeEngineTests.swift:158 | waitAllTerminated | 60 / 60 | deadline | 0.0277/60 (0.000) n=1 | 0.749/60 (0.012) n=1 | never near: (largest 0.012) |
| NativeEngineTests.swift:203 | waitAllTerminated | 60 / 60 | deadline | 0.0128/60 (0.000) n=1 | 0.119/60 (0.002) n=1 | never near: (largest 0.002) |
| NativeEngineTests.swift:217 | waitAllTerminated | 60 / 60 | deadline | 0.00476/60 (0.000) n=1 | 0.115/60 (0.002) n=1 | never near: (largest 0.002) |
| NativeEngineTests.swift:262 | waitAllTerminated | 60 / 60 | deadline | 0.0171/60 (0.000) n=1 | 0.00231/60 (0.000) n=1 | never near: (largest 0.000) |
| NativeEngineTests.swift:294 | waitAllTerminated | 60 / 60 | deadline | 0.00542/60 (0.000) n=1 | 0.015/60 (0.000) n=1 | never near: (largest 0.000) |
| NativeEngineTests.swift:343 | waitAllTerminated | 60 / 60 | deadline | 0.000966/60 (0.000) n=1 | 0.00346/60 (0.000) n=1 | never near: (largest 0.000) |
| NativeEngineTests.swift:78 | waitAllTerminated | 60 / 60 | deadline | 0.0101/60 (0.000) n=1 | 0.048/60 (0.001) n=1 | never near: (largest 0.001) |
| NativeEngineTests.swift:95 | waitAllTerminated | 60 / 60 | deadline | 0.0407/60 (0.001) n=1 | 0.00107/60 (0.000) n=1 | never near: (largest 0.001) |
| ObjectModelVMTests.swift:212 | eventually | 10 / 10 | deadline | 0.0357/10 (0.004) n=2 | 0.142/10 (0.014) n=2 | never near: (largest 0.014) |
| ObjectModelVMTests.swift:382 | waitAllTerminated | underThreadSanitizer ? 600 : 60 / underThreadSanitizer ? 600 : 60 | deadline | 2.59/60 (0.043) n=1 | 7.67/600 (0.013) n=1 | never near: (largest 0.043) |
| ObjectModelVMTests.swift:461 | eventually | 10 / 10 | deadline | 0.000824/10 (0.000) n=1 | 8.89e-05/10 (0.000) n=1 | never near: (largest 0.000) |
| PhoneTransportTests.swift:104 | client open | 60 / 60 | deadline | 0.0409/60 (0.001) n=1 | 1.67/60 (0.028) n=1 | never near: (largest 0.028) |
| PhoneTransportTests.swift:111 | client send | 60 / 60 | deadline | 0.000317/30 (0.000) n=2 | 0.000949/30 (0.000) n=2 | never near: (largest 0.000) |
| PhoneTransportTests.swift:115 | client send | 60 / 60 | deadline | 0.000275/30 (0.000) n=1 | 0.000624/30 (0.000) n=1 | never near: (largest 0.000) |
| PhoneTransportTests.swift:117 | client send | 60 / 60 | deadline | 4.4e-05/30 (0.000) n=1 | 0.000126/30 (0.000) n=1 | never near: (largest 0.000) |
| PhoneTransportTests.swift:123 | client send | 60 / 60 | deadline | 0.000419/30 (0.000) n=7 | 0.00147/30 (0.000) n=7 | never near: (largest 0.000) |
| PhoneTransportTests.swift:129 | client open | 30 / 30 | deadline | 9.3e-05/30 (0.000) n=1 | 0.000475/30 (0.000) n=1 | never near: (largest 0.000) |
| PhoneTransportTests.swift:136 | client open | 60 / 60 | deadline | 0.0275/60 (0.000) n=1 | 1.63/60 (0.027) n=1 | never near: (largest 0.027) |
| PhoneTransportTests.swift:152 | loop, two refusals | 120 / 120 | deadline | 7.92e-07/120 (0.000) n=1 | 4.17e-06/120 (0.000) n=1 | never near: (largest 0.000) |
| PhoneTransportTests.swift:167 | client open | 30 / 30 | deadline | 0.000407/30 (0.000) n=1 | 0.000616/30 (0.000) n=1 | never near: (largest 0.000) |
| PhoneTransportTests.swift:170 | client open | 60 / 60 | deadline | 0.0284/60 (0.000) n=1 | 1.07/60 (0.018) n=1 | never near: (largest 0.018) |
| PhoneTransportTests.swift:185 | loop, Bonjour lists the target | 30 / 30 | deadline | 0.989/30 (0.033) n=1 | 0.965/30 (0.032) n=1 | never near: (largest 0.033) |
| PhoneTransportTests.swift:193 | loop, the targets event | 120 / 120 | deadline | 8.75e-07/120 (0.000) n=1 | 3.37e-06/120 (0.000) n=1 | never near: (largest 0.000) |
| PhoneTransportTests.swift:211 | loop, a line or lost event | 60 / 60 | deadline | 0.0338/60 (0.001) n=1 | 1.41/60 (0.023) n=1 | never near: (largest 0.023) |
| PhoneTransportTests.swift:265 | LocalTools.probe (drive) | 30 / 150 | deadline | 0.00112/30 (0.000) n=1 | 0.0302/150 (0.000) n=1 | never near: (largest 0.000) |
| PhoneTransportTests.swift:266 | LocalTools.probe (drive) | 30 / 150 | deadline | 4.62e-05/30 (0.000) n=1 | 0.000331/150 (0.000) n=1 | never near: (largest 0.000) |
| PhoneTransportTests.swift:269 | LocalTools.probe (drive) | 30 / 150 | deadline | 0.00658/30 (0.000) n=1 | 0.394/150 (0.003) n=1 | never near: (largest 0.003) |
| PhoneTransportTests.swift:287 | LocalTools.probe (drive) | 30 / 150 | deadline | 0.0315/30 (0.001) n=1 | 0.474/150 (0.003) n=1 | never near: (largest 0.003) |
| PhoneTransportTests.swift:289 | LocalTools.probe (drive) | 30 / 150 | deadline | 0.000614/30 (0.000) n=1 | 0.0396/150 (0.000) n=1 | never near: (largest 0.000) |
| PhoneTransportTests.swift:291 | LocalTools.probe (drive) | 30 / 150 | deadline | 8.58e-06/30 (0.000) n=1 | 0.000134/150 (0.000) n=1 | never near: (largest 0.000) |
| PhoneTransportTests.swift:292 | LocalTools.probe (drive) | 30 / 150 | deadline | 0.00249/30 (0.000) n=1 | 0.075/150 (0.001) n=1 | never near: (largest 0.001) |
| PhoneTransportTests.swift:297 | LocalTools.probe (drive) | 30 / 150 | deadline | 0.00234/30 (0.000) n=1 | 0.149/150 (0.001) n=1 | never near: (largest 0.001) |
| PhoneTransportTests.swift:298 | LocalTools.probe (drive) | 30 / 150 | deadline | 3.25e-05/30 (0.000) n=1 | 0.000652/150 (0.000) n=1 | never near: (largest 0.000) |
| PhoneTransportTests.swift:300 | LocalTools.probe (drive) | 30 / 150 | deadline | 3.1e-05/30 (0.000) n=1 | 0.000667/150 (0.000) n=1 | never near: (largest 0.000) |
| PhoneTransportTests.swift:303 | client open | 60 / 60 | deadline | 0.0319/60 (0.001) n=1 | 1.59/60 (0.026) n=1 | never near: (largest 0.026) |
| PhoneTransportTests.swift:304 | client request | 60 / 60 | deadline | 0.0213/60 (0.000) n=1 | 0.172/60 (0.003) n=1 | never near: (largest 0.003) |
| PhoneTransportTests.swift:306 | client request | 60 / 60 | deadline | 0.00805/60 (0.000) n=1 | 0.12/60 (0.002) n=1 | never near: (largest 0.002) |
| PhoneTransportTests.swift:46 | semaphore, the run thread's end | 30 / 30 | deadline | 1.67e-07/30 (0.000) n=11 | 3.75e-07/30 (0.000) n=11 | never near: (largest 0.000) |
| PhoneTransportTests.swift:75 | loop, two request records written | 30 / 30 | deadline | 2.9e-05/30 (0.000) n=1 | 0.000122/30 (0.000) n=1 | never near: (largest 0.000) |
| ProcessRootsTests.swift:255 | waitAllTerminated | 60 / 60 | deadline | 7.5e-06/60 (0.000) n=1 | 2.04e-05/60 (0.000) n=1 | never near: (largest 0.000) |
| ProcessRootsTests.swift:259 | waitAllTerminated | 60 / 60 | deadline | 1.45/60 (0.024) n=2 | 2.08/60 (0.035) n=2 | never near: (largest 0.035) |
| ProcessTests.swift:103 | waitAllTerminated | 60 / 60 | deadline | 0.00712/60 (0.000) n=1 | 3.72e-05/60 (0.000) n=1 | never near: (largest 0.000) |
| ProcessTests.swift:12 | waitAllTerminated | 60 / 60 | deadline | 0.00085/60 (0.000) n=1 | 0.000779/60 (0.000) n=1 | never near: (largest 0.000) |
| ProcessTests.swift:17 | eventually | 10 / 10 | deadline | 2.01e-05/10 (0.000) n=1 | 7.15e-05/10 (0.000) n=1 | never near: (largest 0.000) |
| ProcessTests.swift:186 | waitAllTerminated | 60 / 60 | deadline | 0.0258/60 (0.000) n=1 | 0.0313/60 (0.001) n=1 | never near: (largest 0.001) |
| ProcessTests.swift:248 | eventually | 10 / 10 | deadline | 0.0297/10 (0.003) n=1 | 3.07e-05/10 (0.000) n=1 | never near: (largest 0.003) |
| ProcessTests.swift:252 | waitAllTerminated | 60 / 60 | deadline | 0.000774/60 (0.000) n=1 | 0.000776/60 (0.000) n=1 | never near: (largest 0.000) |
| ProcessTests.swift:340 | eventually | 10 / 10 | deadline | 0.0473/10 (0.005) n=1 | 0.0693/10 (0.007) n=1 | never near: (largest 0.007) |
| ProcessTests.swift:344 | waitAllTerminated | 60 / 60 | deadline | 0.000755/60 (0.000) n=1 | 2.12e-05/60 (0.000) n=1 | never near: (largest 0.000) |
| ProcessTests.swift:372 | waitAllTerminated | 60 / 60 | deadline | 0.0361/60 (0.001) n=1 | 0.0322/60 (0.001) n=1 | never near: (largest 0.001) |
| ProcessTests.swift:376 | ceiling, 20 Delays of 30 ms (ms) | 60000 / 60000 | ceiling | 38.8/6e+04 (0.001) n=1 | 50.5/6e+04 (0.001) n=1 | never near: (largest 0.001) |
| ProcessTests.swift:414 | waitAllTerminated | 60 / 60 | deadline | 1.44e-05/60 (0.000) n=1 | 0.00442/60 (0.000) n=1 | never near: (largest 0.000) |
| ProcessTests.swift:419 | eventually | 60 / 60 | deadline | 1.21/60 (0.020) n=1 | 0.572/60 (0.010) n=1 | never near: (largest 0.020) |
| ProcessTests.swift:420 | eventually | 10 / 10 | deadline | 6.37e-06/10 (0.000) n=1 | 9.71e-06/10 (0.000) n=1 | never near: (largest 0.000) |
| ProcessTests.swift:460 | waitAllTerminated | 60 / 60 | deadline | 0.0218/60 (0.000) n=1 | 0.00385/60 (0.000) n=1 | never near: (largest 0.000) |
| ProcessTests.swift:465 | eventually | 60 / 60 | deadline | 1.5/60 (0.025) n=1 | 0.625/60 (0.010) n=1 | never near: (largest 0.025) |
| ProcessTests.swift:58 | waitAllTerminated | 60 / 60 | deadline | 0.026/60 (0.000) n=1 | 0.00291/60 (0.000) n=1 | never near: (largest 0.000) |
| ProcessTests.swift:597 | eventually | 10 / 10 | deadline | 0.0328/10 (0.003) n=1 | 4.5e-05/10 (0.000) n=1 | never near: (largest 0.003) |
| ProcessTests.swift:599 | eventually | 10 / 10 | deadline | 0.00281/10 (0.000) n=1 | 0.000815/10 (0.000) n=1 | never near: (largest 0.000) |
| ProcessTests.swift:600 | eventually | 10 / 10 | deadline | 5.75e-06/10 (0.000) n=1 | 2.49e-05/10 (0.000) n=1 | never near: (largest 0.000) |
| ProcessTests.swift:602 | eventually | 10 / 10 | deadline | 1.22e-05/10 (0.000) n=1 | 7.87e-05/10 (0.000) n=1 | never near: (largest 0.000) |
| ProcessTests.swift:630 | eventually | 60 / 60 | deadline | 0.00179/60 (0.000) n=1 | 0.0514/60 (0.001) n=1 | never near: (largest 0.001) |
| ProcessTests.swift:634 | waitAllTerminated | 60 / 60 | deadline | 0.00098/60 (0.000) n=1 | 0.00237/60 (0.000) n=1 | never near: (largest 0.000) |
| ProcessTests.swift:635 | eventually | 10 / 10 | deadline | 1.33e-05/10 (0.000) n=1 | 4.15e-05/10 (0.000) n=1 | never near: (largest 0.000) |
| ProcessTests.swift:722 | eventually | 10 / 10 | deadline | 0.000811/10 (0.000) n=1 | 0.489/10 (0.049) n=1 | never near: (largest 0.049) |
| ProcessTests.swift:736 | waitAllTerminated | 60 / 60 | deadline | 0.0126/60 (0.000) n=1 | 0.275/60 (0.005) n=1 | never near: (largest 0.005) |
| ProcessTests.swift:806 | waitAllTerminated | 60 / 60 | deadline | 0.0293/60 (0.000) n=1 | 1.24/60 (0.021) n=1 | never near: (largest 0.021) |
| ProcessTests.swift:808 | eventually | 10 / 10 | deadline | 2.99e-05/10 (0.000) n=1 | 4.74e-05/10 (0.000) n=1 | never near: (largest 0.000) |
| ProjectDirectoryTests.swift:342 | LocalTools.probe (drive) | 30 / 150 | deadline | 7.23e-05/30 (0.000) n=1 | 0.00345/150 (0.000) n=1 | never near: (largest 0.000) |
| ProjectDirectoryTests.swift:349 | LocalTools.probe (drive) | 30 / 150 | deadline | 0.000115/30 (0.000) n=1 | 0.000909/150 (0.000) n=1 | never near: (largest 0.000) |
| ProjectDirectoryTests.swift:352 | LocalTools.probe (drive) | 30 / 150 | deadline | 6.77e-05/30 (0.000) n=1 | 0.000443/150 (0.000) n=1 | never near: (largest 0.000) |
| ProjectDirectoryTests.swift:353 | LocalTools.probe (drive) | 30 / 150 | deadline | 0.000918/30 (0.000) n=1 | 0.0323/150 (0.000) n=1 | never near: (largest 0.000) |
| ProjectDirectoryTests.swift:355 | LocalTools.probe (drive) | 30 / 150 | deadline | 3.63e-05/30 (0.000) n=1 | 0.00059/150 (0.000) n=1 | never near: (largest 0.000) |
| ProjectDirectoryTests.swift:356 | LocalTools.probe (drive) | 30 / 150 | deadline | 0.0457/30 (0.002) n=1 | 0.545/150 (0.004) n=1 | never near: (largest 0.004) |
| ProjectDirectoryTests.swift:358 | LocalTools.probe (drive) | 30 / 150 | deadline | 0.115/30 (0.004) n=1 | 1.37/150 (0.009) n=1 | never near: (largest 0.009) |
| ProjectDirectoryTests.swift:47 | loop, a lost event | 60 / 60 | deadline | 0.00323/60 (0.000) n=3 | 0.00303/60 (0.000) n=3 | never near: (largest 0.000) |
| RandomPrograms.swift:585 | loop, offloadCollection main turns | 120 / 600 | deadline | 0.186/120 (0.002) n=200 | 1.43/600 (0.002) n=20 | never near: (largest 0.002) |
| RandomPrograms.swift:656 | loop, a cycle completed | 120 / 600 | deadline | 0.397/120 (0.003) n=200 | 0.649/600 (0.001) n=20 | never near: (largest 0.003) |
| RelocationTests.swift:164 | eventually | 10 / 10 | deadline | 0.0519/10 (0.005) n=2 | 0.0134/10 (0.001) n=2 | never near: (largest 0.005) |
| RelocationTests.swift:340 | eventually | 10 / 10 | deadline | 0.00769/10 (0.001) n=2 | 1.56e-05/10 (0.000) n=2 | never near: (largest 0.001) |
| RelocationTests.swift:87 | eventually | 10 / 10 | deadline | 0.0028/10 (0.000) n=1 | 2.59e-05/10 (0.000) n=1 | never near: (largest 0.000) |
| ReserveTests.swift:207 | waitAllTerminated | 60 / 60 | deadline | 0.216/60 (0.004) n=40 | 0.917/60 (0.015) n=40 | never near: (largest 0.015) |
| Review3SmallFixesTests.swift:330 | client waitForEvent | 120 / 120 | deadline | 0.000149/120 (0.000) n=1 | 0.00041/120 (0.000) n=1 | never near: (largest 0.000) |
| Review3SmallFixesTests.swift:390 | loop, the host timer fires | 20 / 20 | deadline | 0.0556/20 (0.003) n=1 | 0.0587/20 (0.003) n=1 | never near: (largest 0.003) |
| ReviewFixesKernelTests.swift:224 | drive | 30 / 150 | deadline | 0.0123/30 (0.000) n=1 | 3.58e-05/150 (0.000) n=1 | never near: (largest 0.000) |
| ReviewFixesKernelTests.swift:235 | drive | 30 / 150 | deadline | 0.000777/30 (0.000) n=1 | 0.0299/150 (0.000) n=1 | never near: (largest 0.000) |
| ReviewFixesPart2Tests.swift:22 | client send | 60 / 60 | deadline | 0.118/120 (0.001) n=1 | 7.03/600 (0.012) n=1 | never near: (largest 0.012) |
| ReviewFixesPart2Tests.swift:294 | client send | 60 / 60 | deadline | 0.612/120 (0.005) n=1 | 2.74/120 (0.023) n=1 | never near: (largest 0.023) |
| ReviewFixesPart2Tests.swift:295 | ceiling, a refused long line (s) | 100 / 100 | ceiling | 0.616/100 (0.006) n=1 | 2.74/100 (0.027) n=1 | never near: (largest 0.027) |
| ReviewFixesPart2Tests.swift:318 | semaphore, in the callback | 60 / 60 | deadline | 2.08e-07/60 (0.000) n=1 | 8.3e-08/60 (0.000) n=1 | never near: (largest 0.000) |
| ReviewFixesPart2Tests.swift:321 | ceiling, close beside the reader (s) | 1 / 1 | ceiling | 3.1e-06/1 (0.000) n=1 | 5.01e-06/1 (0.000) n=1 | never near: (largest 0.000) |
| ReviewFixesPart2Tests.swift:323 | loop, the descriptor closed | 60 / 60 | deadline | 1.52/60 (0.025) n=1 | 1.51/60 (0.025) n=1 | never near: (largest 0.025) |
| ReviewFixesPart2Tests.swift:37 | client send | 60 / 60 | deadline | 0.225/120 (0.002) n=1 | 0.936/600 (0.002) n=1 | never near: (largest 0.002) |
| ReviewFixesPart2Tests.swift:391 | loop, a lost event | 30 / 30 | deadline | 0.00217/30 (0.000) n=1 | 0.00307/30 (0.000) n=1 | never near: (largest 0.000) |
| ReviewFixesPart2Tests.swift:442 | client open | 60 / 60 | deadline | 0.0273/60 (0.000) n=1 | 1.27/60 (0.021) n=1 | never near: (largest 0.021) |
| ReviewFixesPart2Tests.swift:475 | semaphore x8, writers end | 600 each / 600 each | deadline | 1.25e-07/600 (0.000) n=20 | 3.34e-07/600 (0.000) n=20 | never near: (largest 0.000) |
| ReviewFixesPart2Tests.swift:489 | run (drive) | 30 / 150 | deadline | 0.00459/30 (0.000) n=1 | 0.26/150 (0.002) n=1 | never near: (largest 0.002) |
| ReviewFixesPart2Tests.swift:492 | run (drive) | 30 / 150 | deadline | 0.0302/30 (0.001) n=1 | 0.185/150 (0.001) n=1 | never near: (largest 0.001) |
| ReviewFixesPart2Tests.swift:494 | run (drive) | 30 / 150 | deadline | 0.00599/30 (0.000) n=1 | 0.145/150 (0.001) n=1 | never near: (largest 0.001) |
| ReviewFixesTransportTests.swift:121 | group wait, eight senders | 60 / 60 | deadline | 1.25e-07/60 (0.000) n=20 | 7.92e-07/60 (0.000) n=20 | never near: (largest 0.000) |
| ReviewFixesTransportTests.swift:141 | client open | 60 / 60 | deadline | 0.0281/60 (0.000) n=1 | 1.89/60 (0.031) n=1 | never near: (largest 0.031) |
| ReviewFixesTransportTests.swift:143 | loop, 3000 x (eval + 10 ms) | 30 (min) / 30 (min) | deadline | 0.0111/30 (0.000) n=1 | 0.126/30 (0.004) n=1 | never near: (largest 0.004) |
| ReviewFixesTransportTests.swift:151 | client open | 60 / 60 | deadline | 0.0215/60 (0.000) n=1 | 1.46/60 (0.024) n=1 | never near: (largest 0.024) |
| ReviewFixesTransportTests.swift:156 | client open | 60 / 60 | deadline | 0.0352/60 (0.001) n=1 | 1.49/60 (0.025) n=1 | never near: (largest 0.025) |
| ReviewFixesTransportTests.swift:157 | loop, 3000 x (eval + 10 ms) | 30 (min) / 30 (min) | deadline | 0.0105/30 (0.000) n=1 | 0.113/30 (0.004) n=1 | never near: (largest 0.004) |
| ReviewFixesTransportTests.swift:64 | loop, accepted count | 30 / 30 | deadline | 0.00189/30 (0.000) n=20 | 0.0213/30 (0.001) n=20 | never near: (largest 0.001) |
| SafepointTests.swift:201 | eventually | 10 / 10 | deadline | 7.08e-06/10 (0.000) n=1 | 1.47e-05/10 (0.000) n=1 | never near: (largest 0.000) |
| SafepointTests.swift:208 | ceiling, idle worker CPU (ms) | 1 / 1 | ceiling | 0/1 (0.000) n=9 | 0/1 (0.000) n=9 | never near: (largest 0.000) |
| SafepointTests.swift:209 | ceiling, idle wakeups | 5 / 5 | ceiling | 0/5 (0.000) n=1 | 0/5 (0.000) n=1 | never near: (largest 0.000) |
| SafepointTests.swift:219 | eventually | 30 / 30 | deadline | 0.0302/30 (0.001) n=1 | 0.0318/30 (0.001) n=1 | never near: (largest 0.001) |
| SafepointTests.swift:224 | eventually | 10 / 10 | deadline | 0.000771/10 (0.000) n=1 | 0.000786/10 (0.000) n=1 | never near: (largest 0.000) |
| SafepointTests.swift:247 | eventually | 10 / 10 | deadline | 1.24e-05/10 (0.000) n=3 | 1.4e-05/10 (0.000) n=3 | never near: (largest 0.000) |
| SafepointTests.swift:251 | eventually | 5 / 5 | deadline | 0.000743/5 (0.000) n=3 | 0.00121/5 (0.000) n=3 | never near: (largest 0.000) |
| SafepointTests.swift:256 | eventually | 5 / 5 | deadline | 0.00139/5 (0.000) n=3 | 5.02e-05/5 (0.000) n=3 | never near: (largest 0.000) |
| SafepointTests.swift:259 | ceiling, signal to done (ms) | 1000 / 1000 | ceiling | 3.22/1000 (0.003) n=3 | 13.3/1000 (0.013) n=3 | never near: (largest 0.013) |
| SafepointTests.swift:269 | eventually | 10 / 10 | deadline | 4e-06/10 (0.000) n=1 | 2.4e-05/10 (0.000) n=1 | never near: (largest 0.000) |
| SafepointTests.swift:53 | waitAllTerminated | 60 / 60 | deadline | 0.001/60 (0.000) n=2 | 1.25e-05/60 (0.000) n=1 | never near: (largest 0.000) |
| SavedProcessLoaderTests.swift:281 | waitAllTerminated | 60 / 60 | deadline | 1.09e-05/60 (0.000) n=1 | 0.000275/60 (0.000) n=1 | never near: (largest 0.000) |
| SavedProcessTests.swift:129 | waitAllTerminated | 60 / 60 | deadline | 0.0535/60 (0.001) n=1 | 0.503/60 (0.008) n=1 | never near: (largest 0.008) |
| SavedProcessTests.swift:140 | waitAllTerminated | 60 / 60 | deadline | 0.00402/60 (0.000) n=1 | 0.16/60 (0.003) n=1 | never near: (largest 0.003) |
| SavedProcessTests.swift:312 | waitAllTerminated | 60 / 60 | deadline | 0.00186/60 (0.000) n=1 | 0.0141/60 (0.000) n=1 | never near: (largest 0.000) |
| SavedProcessTests.swift:379 | waitAllTerminated | 60 / 60 | deadline | 0.000777/60 (0.000) n=1 | 0.000783/60 (0.000) n=1 | never near: (largest 0.000) |
| SavedProcessTests.swift:397 | waitAllTerminated | 60 / 60 | deadline | 0.00781/60 (0.000) n=1 | 0.0179/60 (0.000) n=1 | never near: (largest 0.000) |
| ShellCloseTests.swift:103 | run (drive) | 30 / 150 | deadline | 7.66e-05/30 (0.000) n=1 | 0.00149/150 (0.000) n=1 | never near: (largest 0.000) |
| ShellCloseTests.swift:120 | run (drive) | 30 / 150 | deadline | 0.000886/30 (0.000) n=1 | 0.00184/150 (0.000) n=1 | never near: (largest 0.000) |
| ShellCloseTests.swift:136 | run (drive) | 30 / 150 | deadline | 0.000612/30 (0.000) n=1 | 0.0773/150 (0.001) n=1 | never near: (largest 0.001) |
| ShellCloseTests.swift:164 | run (drive) | 30 / 150 | deadline | 8.28e-05/30 (0.000) n=8 | 0.00292/150 (0.000) n=8 | never near: (largest 0.000) |
| ShellCloseTests.swift:165 | run (drive) | 30 / 150 | deadline | 0.0366/30 (0.001) n=8 | 0.00707/150 (0.000) n=8 | never near: (largest 0.001) |
| ShellCloseTests.swift:73 | ShellCloseTests.until | closeWait 120 / closeWait 600 | deadline | 0.015/120 (0.000) n=1 | 0.165/600 (0.000) n=1 | never near: (largest 0.000) |
| ShellCloseTests.swift:76 | ShellCloseTests.until | closeWait 120 / closeWait 600 | deadline | 5.71e-06/120 (0.000) n=1 | 2.77e-05/600 (0.000) n=1 | never near: (largest 0.000) |
| ShellTests.swift:166 | run (drive) | 30 / 150 | deadline | 0.000551/30 (0.000) n=1 | 0.0546/150 (0.000) n=1 | never near: (largest 0.000) |
| ShellTests.swift:167 | run (drive) | 30 / 150 | deadline | 1.55e-05/30 (0.000) n=1 | 0.000154/150 (0.000) n=1 | never near: (largest 0.000) |
| ShellTests.swift:180 | run (drive) | 30 / 150 | deadline | 0.000461/30 (0.000) n=1 | 0.0146/150 (0.000) n=1 | never near: (largest 0.000) |
| ShellTests.swift:181 | run (drive) | 30 / 150 | deadline | 1.39e-05/30 (0.000) n=1 | 0.000186/150 (0.000) n=1 | never near: (largest 0.000) |
| ShellTests.swift:185 | run (drive) | 30 / 150 | deadline | 0.00014/30 (0.000) n=1 | 0.0023/150 (0.000) n=1 | never near: (largest 0.000) |
| ShellTests.swift:187 | drive | 30 / 150 | deadline | 0.000118/30 (0.000) n=1 | 0.0136/150 (0.000) n=1 | never near: (largest 0.000) |
| ShellTests.swift:190 | run (drive) | 30 / 150 | deadline | 0.000164/30 (0.000) n=1 | 0.0028/150 (0.000) n=1 | never near: (largest 0.000) |
| ShellTests.swift:193 | drive | 30 / 150 | deadline | 8.35e-05/30 (0.000) n=1 | 0.00134/150 (0.000) n=1 | never near: (largest 0.000) |
| ShellTests.swift:194 | run (drive) | 30 / 150 | deadline | 1.94e-05/30 (0.000) n=1 | 0.000424/150 (0.000) n=1 | never near: (largest 0.000) |
| ShellTests.swift:196 | run (drive) | 30 / 150 | deadline | 0.000155/30 (0.000) n=1 | 0.00294/150 (0.000) n=1 | never near: (largest 0.000) |
| ShellTests.swift:198 | drive | 30 / 150 | deadline | 6.76e-05/30 (0.000) n=1 | 0.00433/150 (0.000) n=1 | never near: (largest 0.000) |
| ShellTests.swift:207 | run (drive) | 30 / 150 | deadline | 0.000572/30 (0.000) n=1 | 0.0112/150 (0.000) n=1 | never near: (largest 0.000) |
| ShellTests.swift:219 | run (drive) | 30 / 150 | deadline | 0.0179/30 (0.001) n=1 | 0.59/150 (0.004) n=1 | never near: (largest 0.004) |
| ShellTests.swift:221 | drive | 30 / 150 | deadline | 0.000784/30 (0.000) n=1 | 0.0154/150 (0.000) n=1 | never near: (largest 0.000) |
| ShellTests.swift:233 | loop, the stuck report | 30 / 30 | deadline | 0.103/30 (0.003) n=1 | 0.104/30 (0.003) n=1 | never near: (largest 0.003) |
| ShellTests.swift:243 | run (drive) | 30 / 150 | deadline | 0.00405/30 (0.000) n=1 | 0.00512/150 (0.000) n=1 | never near: (largest 0.000) |
| ShellTests.swift:273 | run (drive) | 30 / 150 | deadline | 0.000542/30 (0.000) n=1 | 0.025/150 (0.000) n=1 | never near: (largest 0.000) |
| ShellTests.swift:274 | run (drive) | 30 / 150 | deadline | 2.79e-05/30 (0.000) n=1 | 0.000467/150 (0.000) n=1 | never near: (largest 0.000) |
| ShellTests.swift:289 | drive | 30 / 150 | deadline | 0.00828/30 (0.000) n=2 | 0.00352/150 (0.000) n=2 | never near: (largest 0.000) |
| ShellTests.swift:289 | run (drive) | 30 / 150 | deadline | 0.00828/30 (0.000) n=2 | 0.00352/150 (0.000) n=2 | never near: (largest 0.000) |
| ShellTests.swift:292 | run (drive) | 30 / 150 | deadline | 0.000421/30 (0.000) n=1 | 0.0103/150 (0.000) n=1 | never near: (largest 0.000) |
| ShellTests.swift:293 | run (drive) | 30 / 150 | deadline | 9.12e-06/30 (0.000) n=1 | 0.000164/150 (0.000) n=1 | never near: (largest 0.000) |
| ShellTests.swift:295 | drive | 30 / 150 | deadline | 9.75e-05/30 (0.000) n=1 | 0.00207/150 (0.000) n=1 | never near: (largest 0.000) |
| ShellTests.swift:301 | run (drive) | 30 / 150 | deadline | 0.000535/30 (0.000) n=1 | 0.0269/150 (0.000) n=1 | never near: (largest 0.000) |
| SymbolInterningTests.swift:186 | waitAllTerminated | underThreadSanitizer ? 3000 : 600 / underThreadSanitizer ? 3000 : 600 | deadline | 26.5/600 (0.044) n=16 | 0.504/3000 (0.000) n=16 | never near: (largest 0.044) |
| SymbolInterningTests.swift:421 | waitAllTerminated | 600 / 600 | deadline | 6.22/600 (0.010) n=2 | 17.6/600 (0.029) n=1 | never near: (largest 0.029) |
| ToolsTests.swift:198 | drive | 120 / 120 | deadline | 0.0454/120 (0.000) n=8 | 0.0289/600 (0.000) n=8 | never near: (largest 0.000) |
| ToolsTests.swift:198 | drive, the DevProtocol start | 120 / 600 | deadline | 0.0454/120 (0.000) n=8 | 0.0289/600 (0.000) n=8 | never near: (largest 0.000) |
| ToolsTests.swift:353 | loop, a lost event | 30 / 30 | deadline | 0.0269/30 (0.001) n=1 | 0.00608/30 (0.000) n=1 | never near: (largest 0.001) |
| ToolsTests.swift:369 | loop, a lost event (same end) | 30 / 30 | deadline | 0.0308/30 (0.001) n=1 | 0.015/30 (0.001) n=1 | never near: (largest 0.001) |
| ToolsTests.swift:404 | LocalTools.probe (drive) | 30 / 150 | deadline | 0.036/30 (0.001) n=1 | 0.784/150 (0.005) n=1 | never near: (largest 0.005) |
| ToolsTests.swift:408 | LocalTools.probe (drive) | 30 / 150 | deadline | 0.074/30 (0.002) n=1 | 1.22/150 (0.008) n=1 | never near: (largest 0.008) |
| ToolsTests.swift:423 | LocalTools.probe (drive) | 30 / 150 | deadline | 0.00913/30 (0.000) n=1 | 1.44/150 (0.010) n=1 | never near: (largest 0.010) |
| ToolsTests.swift:426 | LocalTools.probe (drive) | 30 / 150 | deadline | 0.000186/30 (0.000) n=1 | 0.00603/150 (0.000) n=1 | never near: (largest 0.000) |
| ToolsTests.swift:444 | LocalTools.probe (drive) | 30 / 150 | deadline | 0.000234/30 (0.000) n=1 | 0.00414/150 (0.000) n=1 | never near: (largest 0.000) |
| ToolsTests.swift:445 | LocalTools.probe (drive) | 30 / 150 | deadline | 0.0714/30 (0.002) n=1 | 0.797/150 (0.005) n=1 | never near: (largest 0.005) |
| ToolsTests.swift:447 | LocalTools.probe (drive) | 30 / 150 | deadline | 0.0572/30 (0.002) n=1 | 0.544/150 (0.004) n=1 | never near: (largest 0.004) |
| ToolsTests.swift:449 | LocalTools.probe (drive) | 30 / 150 | deadline | 0.0326/30 (0.001) n=1 | 0.362/150 (0.002) n=1 | never near: (largest 0.002) |
| ToolsTests.swift:451 | LocalTools.probe (drive) | 30 / 150 | deadline | 2.3e-05/30 (0.000) n=1 | 0.00034/150 (0.000) n=1 | never near: (largest 0.000) |
| ToolsTests.swift:452 | LocalTools.probe (drive) | 30 / 150 | deadline | 0.0173/30 (0.001) n=1 | 1.08/150 (0.007) n=1 | never near: (largest 0.007) |
| ToolsTests.swift:497 | LocalTools.probe (drive) | 30 / 150 | deadline | 0.025/30 (0.001) n=1 | 0.612/150 (0.004) n=1 | never near: (largest 0.004) |
| ToolsTests.swift:508 | LocalTools.probe (drive) | 30 / 150 | deadline | 0.047/30 (0.002) n=1 | 0.648/150 (0.004) n=1 | never near: (largest 0.004) |
| ToolsTests.swift:516 | LocalTools.probe (drive) | 30 / 150 | deadline | 0.111/30 (0.004) n=1 | 2.06/150 (0.014) n=1 | never near: (largest 0.014) |
| ToolsTests.swift:523 | LocalTools.probe (drive) | 30 / 150 | deadline | 0.00222/30 (0.000) n=1 | 0.226/150 (0.002) n=1 | never near: (largest 0.002) |
| ToolsTests.swift:534 | LocalTools.probe (drive) | 30 / 150 | deadline | 0.0206/30 (0.001) n=1 | 0.303/150 (0.002) n=1 | never near: (largest 0.002) |
| ToolsTests.swift:545 | LocalTools.probe (drive) | 30 / 150 | deadline | 0.0197/30 (0.001) n=1 | 0.593/150 (0.004) n=1 | never near: (largest 0.004) |
| ToolsTests.swift:547 | LocalTools.probe (drive) | 30 / 150 | deadline | 0.000245/30 (0.000) n=1 | 0.00606/150 (0.000) n=1 | never near: (largest 0.000) |
| ToolsTests.swift:548 | LocalTools.probe (drive) | 30 / 150 | deadline | 9.92e-06/30 (0.000) n=1 | 0.000209/150 (0.000) n=1 | never near: (largest 0.000) |
| ToolsTests.swift:554 | LocalTools.probe (drive) | 30 / 150 | deadline | 9.21e-06/30 (0.000) n=1 | 0.000185/150 (0.000) n=1 | never near: (largest 0.000) |
| ToolsTests.swift:555 | LocalTools.probe (drive) | 30 / 150 | deadline | 9.33e-06/30 (0.000) n=1 | 0.000198/150 (0.000) n=1 | never near: (largest 0.000) |
| ToolsTests.swift:558 | LocalTools.probe (drive) | 30 / 150 | deadline | 0.134/30 (0.004) n=1 | 0.467/150 (0.003) n=1 | never near: (largest 0.004) |
| ToolsTests.swift:560 | LocalTools.probe (drive) | 30 / 150 | deadline | 0.00348/30 (0.000) n=1 | 0.135/150 (0.001) n=1 | never near: (largest 0.001) |
| ToolsTests.swift:565 | LocalTools.probe (drive) | 30 / 150 | deadline | 7.7e-05/30 (0.000) n=1 | 0.00918/150 (0.000) n=1 | never near: (largest 0.000) |
| ToolsTests.swift:569 | LocalTools.probe (drive) | 30 / 150 | deadline | 0.00142/30 (0.000) n=2 | 0.0499/30 (0.002) n=2 | never near: (largest 0.002) |
| ToolsTests.swift:569 | loop, probe results again | 30 / 30 | deadline | 0.00142/30 (0.000) n=2 | 0.0499/30 (0.002) n=2 | never near: (largest 0.002) |
| ToolsTests.swift:572 | LocalTools.probe (drive) | 30 / 150 | deadline | 0.000466/30 (0.000) n=1 | 0.0127/150 (0.000) n=1 | never near: (largest 0.000) |
| ToolsTests.swift:573 | LocalTools.probe (drive) | 30 / 150 | deadline | 1.94e-05/30 (0.000) n=1 | 0.000299/150 (0.000) n=1 | never near: (largest 0.000) |
| TypeCheckerTests.swift:51 | client request | 60 / 60 | deadline | 0.025/600 (0.000) n=1 | 0.887/3600 (0.000) n=1 | never near: (largest 0.000) |
| TypeCheckerTests.swift:55 | client request | 60 / 60 | deadline | 0.00293/600 (0.000) n=1 | 0.0951/3600 (0.000) n=1 | never near: (largest 0.000) |
| TypeCheckerTests.swift:63 | client request | 60 / 60 | deadline | 0.00211/600 (0.000) n=1 | 0.0748/3600 (0.000) n=1 | never near: (largest 0.000) |
| TypeCheckerTests.swift:71 | client send | typesWait / typesWait | deadline | 0.0169/600 (0.000) n=5 | 0.479/3600 (0.000) n=5 | never near: (largest 0.000) |
| TypeCheckerTests.swift:78 | client waitForEvent | typesWait / typesWait | deadline | 5.01e-06/600 (0.000) n=1 | 2.6e-05/3600 (0.000) n=1 | never near: (largest 0.000) |
| TypeCheckerTests.swift:84 | client request | 60 / 60 | deadline | 0.00192/600 (0.000) n=1 | 0.0615/3600 (0.000) n=1 | never near: (largest 0.000) |
| TypeCheckerTests.swift:93 | client send | 60 / 60 | deadline | 0.0109/60 (0.000) n=1 | 0.123/60 (0.002) n=1 | never near: (largest 0.002) |
| TypeCheckerTests.swift:95 | client request | 60 / 60 | deadline | 0.0434/60 (0.001) n=1 | 1.67/60 (0.028) n=1 | never near: (largest 0.028) |
| WeakTests.swift:205 | eventually | 10 / 10 | deadline | 0.00201/10 (0.000) n=1 | 0.000825/10 (0.000) n=1 | never near: (largest 0.000) |
| WeakTests.swift:207 | eventually | 10 / 10 | deadline | 0.00435/10 (0.000) n=1 | 0.0014/10 (0.000) n=1 | never near: (largest 0.000) |
| WeakTests.swift:215 | eventually | 10 / 10 | deadline | 0.00673/10 (0.001) n=1 | 7.63e-05/10 (0.000) n=1 | never near: (largest 0.001) |
| WeakTests.swift:224 | waitAllTerminated | 60 / 60 | deadline | 5.13e-06/60 (0.000) n=1 | 1.24e-05/60 (0.000) n=1 | never near: (largest 0.000) |
| YoungCollectionTests.swift:110 | eventually | 10 / 10 | deadline | 0.0585/10 (0.006) n=2 | 0.000789/10 (0.000) n=2 | never near: (largest 0.006) |
| YoungCollectionTests.swift:159 | eventually | 10 / 10 | deadline | 0.0646/10 (0.006) n=2 | 2.83e-05/10 (0.000) n=2 | never near: (largest 0.006) |
| YoungCollectionTests.swift:263 | eventually | 120 / 120 | deadline | 0.00993/120 (0.000) n=1 | 0.017/120 (0.000) n=1 | never near: (largest 0.000) |
| YoungCollectionTests.swift:494 | eventually | 10 / 10 | deadline | 0.0315/10 (0.003) n=2 | 2.94e-05/10 (0.000) n=2 | never near: (largest 0.003) |
| YoungCollectionTests.swift:633 | eventually | 10 / 10 | deadline | 0.0286/10 (0.003) n=1 | 4.05e-05/10 (0.000) n=1 | never near: (largest 0.003) |
| YoungCollectionTests.swift:643 | ceiling, idle marker CPU (ms) | 1 / 1 | ceiling | 0/1 (0.000) n=1 | 0/1 (0.000) n=1 | never near: (largest 0.000) |
| YoungCollectionTests.swift:704 | eventually | 10 / 10 | deadline | 0.0571/10 (0.006) n=1 | 3.05e-05/10 (0.000) n=1 | never near: (largest 0.006) |
| YoungCollectionTests.swift:710 | eventually | 30 / 30 | deadline | 0.000704/30 (0.000) n=1 | 0.000781/30 (0.000) n=1 | never near: (largest 0.000) |
| ZeroingTests.swift:127 | waitAllTerminated | underThreadSanitizer ? 600 : 120 / underThreadSanitizer ? 600 : 120 | deadline | 0.335/120 (0.003) n=2 | 0.749/600 (0.001) n=2 | never near: (largest 0.003) |
| ZeroingTests.swift:293 | waitAllTerminated | underThreadSanitizer ? 600 : 120 / underThreadSanitizer ? 600 : 120 | deadline | 0.678/120 (0.006) n=2 | 13/600 (0.022) n=2 | never near: (largest 0.022) |
| ZeroingTests.swift:345 | waitAllTerminated | 60 / 60 | deadline | 0.0145/60 (0.000) n=2 | 0.00315/60 (0.000) n=2 | never near: (largest 0.000) |
| ZeroingTests.swift:411 | waitAllTerminated | underThreadSanitizer ? 600 : 120 / underThreadSanitizer ? 600 : 120 | deadline | 0.194/120 (0.002) n=1 | 14.5/600 (0.024) n=1 | never near: (largest 0.024) |
| roundtrip#evaluate | (found by measurement) |  /  |  | evaluate 18/3e+04 (0.001) n=1 | evaluate 219/3e+04 (0.007) n=1 | never near: (largest 0.007) |
| roundtrip#process.list | (found by measurement) |  /  |  | process.list 54/3e+04 (0.002) n=1 | process.list 1.16e+03/3e+04 (0.039) n=1 | never near: (largest 0.039) |
| roundtrip#process.retrySend | (found by measurement) |  /  |  | process.retrySend 31/3e+04 (0.001) n=1 | process.retrySend 807/3e+04 (0.027) n=1 | never near: (largest 0.027) |
| AgentInterfaceTests.swift:42 | (found by measurement) |  /  |  | 0.0333/60 (0.001) n=7 | 1.54/60 (0.026) n=7 | not a site: a helper's request, never near (0.026) |
| DevClient request timeout (tools/) | the tools' client, every request kind | 30000 ms / 30000 ms | ceiling | not reached | not reached | not a site: the tools' request timeout: printed per kind as tools.roundtrip.<kind> |
| DevProtocolTests.swift:277 | (found by measurement) |  /  |  | 0.0214/60 (0.000) n=10 | 0.73/60 (0.012) n=10 | not a site: inside a helper (stopIn), never near (0.022) |
| DevProtocolTests.swift:293 | (found by measurement) |  /  |  | 0.0317/60 (0.001) n=5 | 1.29/60 (0.022) n=5 | not a site: inside a helper (compile), never near |
| Harness.swift:37 | run (drive) | 30 / 150 | deadline | not reached | not reached | not a site: the interpreter harness's own run, no bound |
| ImageFileTests.swift:92 | run (drive) | 30 / 150 | deadline | not reached | not reached | not a site: a private run in the interpreter, no bound |
| ImageFileTests.swift:97 | run (drive) | 30 / 150 | deadline | not reached | not reached | not a site: a private run in the interpreter, no bound |
| RedefineOrderTests.swift:72 | run (drive) | 30 / 150 | deadline | not reached | not reached | not a site: a local run that waits unbounded (waitUntilAllTerminated) |
| RedefineOrderTests.swift:74 | run (drive) | 30 / 150 | deadline | not reached | not reached | not a site: a local run that waits unbounded (waitUntilAllTerminated) |
| RedefineOrderTests.swift:81 | run (drive) | 30 / 150 | deadline | not reached | not reached | not a site: a local run that waits unbounded (waitUntilAllTerminated) |
| ReviewFixesTransportTests.swift:205 | (found by measurement) |  /  |  | 0.00659/60 (0.000) n=4 | 0.0897/60 (0.001) n=4 | not a site: a request inside a loop helper, never near |
| Runtime.swift:85 | eventually | seconds / seconds | deadline | not reached | not reached | not a site: inside waitAllTerminated; counted at each call |
| SavedProcessTests.swift:58 | eventually | seconds / seconds | deadline | not reached | not reached | not a site: inside waitAllTerminated; counted at each call |
| ShellTests.swift:150 | drive | 30 / 150 | deadline | not reached | not reached | not a site: inside run(); counted at each run call |
| ToolsTests.swift:215 | (found by measurement) |  /  |  | 0.118/30 (0.004) n=8 | 1.67/150 (0.011) n=86 | not a site: the probe inside until(seconds:); counted as the until's |
| ToolsTests.swift:216 (UNMAPPED) | (found by measurement) |  /  |  | 0.0344/30 (0.001) n=8 | 0.594/150 (0.004) n=8 | not a site: the probe inside until(seconds:); counted as the until's |
| ToolsTests.swift:239 | drive | 30 / 150 | deadline | not reached | not reached | not a site: inside LocalTools.probe; counted at each probe call |
| ToolsTests.swift:239 | drive, LocalTools.probe (every probe) | 30 / 150 | deadline | not reached | not reached | not a site: inside LocalTools.probe; counted at each probe call |
| ToolsTests.swift:268 | (found by measurement) |  /  |  | 0.334/30 (0.011) n=254 | 9.51/150 (0.063) n=4607 | not a site: the probe inside until; counted in tools.<test>.probe |
| ToolsTests.swift:276 | (found by measurement) |  /  |  | 0.18/30 (0.006) n=17 | 18.4/150 (0.123) n=171 | not a site: the activity probe inside until; counted in tools.<test>.probe |

</details>

### Part 2: the line (2026-11-24)

`printMargin` and `printLargestMargin` in `Tests/KajoVMTests/Margins.swift`
and `Tests/KajoCompilerTests/Margins.swift` (one helper per test target;
`marginLine` formats, `parseMarginLine` reads back for the helper's own
test). Every site of part 1's list that prints does so through them:

- the stall tests: `StallDiag.waitProgress` (`stall.<diag>.<label>`, quiet,
  the longest quiet stretch against `quiet`), `StallDiag.wait` (deadline),
  the main-worker ring's own loop (`stall.main.ring`), and each body
  (`stall.body.<test>`, kind time) beside the old `stall-diag body` line;
- the tools: `LocalTools.until` prints `.quiet` (the longest stretch with
  no activity against 60 s) and `.total` (against 300 s) as
  `tools.<test>.<selector><args>`, the `seconds:` variant a deadline;
  `close()` prints `tools.<test>.probe` (the longest probe against
  `driveSeconds * driveScale`) and, from a new fixture probe
  `ToolsProbe longestReplies` (every `DevClient` in the image, its
  `latencies` and its `timeoutMs` read by `instVarAt:`, no `tools/`
  change), `tools.roundtrip.<kind>` against the client's request timeout;
- the protocol tests: `eval` prints `protocol.evaluate.<test>`; the direct
  `open`, `request` and `send` calls part 1 kept go through same-named
  wrappers with a `margin: #function` argument (`protocol.<kind>.<test>`);
- `eventually`, both `waitAllTerminated` and `drive` take `margin:`, nil
  by default: only the call sites part 1 kept pass a name;
- the inline sites kept (`ToolsTests` results loop, the raw reply loop,
  `closedByServer`, the host timer's queue wait, `within`, the cut-off
  unwinding's loop, the main-thread ceilings).
A site called many times prints only a new largest value for its name in
the process (`printLargestMargin`): the random programs' waits print 2 to
9 lines a gate, not 4600. Kept, not replaced (open question 4): `stall-diag
body` and `tools-tags` (named by `docs/modules/weekly-1123-failures.md`,
`allocation-stalls.md`, `verifier-faults.md` and the third review); the new
lines are added beside them. Changed: `drive`'s default 30 is now the
constant `driveSeconds` (30), so the probe line prints the same value the
wait uses.

**Not changed.** No bound, wait, timeout or assertion: `git diff 51be5b2
-- Tests` is 36 files, 464 lines added and 68 removed, and each removed
line comes back with only a `margin:` argument, a defaulted parameter, a
`t0` read beside it or a print after it (read line by line, not by a
tool). The protocol wrappers call the client's own method with the same
arguments. One thing costs more than a line: `LocalTools.close()` runs one
probe (`longestReplies`, which takes `DevClient allInstances`, one stop)
after the test's last assertion, and prints nothing if it does not end.

### Part 3: the reader (2026-11-24)

`scripts/margins.py <dir> [--previous <dir>]` (standard library only).
It reads the gates whose command is `swift test` (`swift-test`,
`swift-test-load`, `tsan`, `tsan-load`, `test-release`, `soak`,
`compiler-tests`) and any other `*.txt` with a margin line (named a gate it
does not know). A line that starts with `kajo-margin` and does not parse,
or the prefix inside another line, is UNKNOWN: counted and quoted, never a
row. Under the tables: names printed more than once (largest kept, count
said), names absent from one of the four whole-suite gates that has
output, names gone since `--previous`, gates with no output, files it could
not read. The second table is each gate's time against its bound, which
`gl_gate` now writes at the end of its start line (`bound=<s>s`; older logs
read `- (not logged)`). Exit 0 whatever it finds, 2 on a usage error.

- `weekly.sh` writes `## Margins` after the gates table, with
  `gl_weekly_previous_dir` (new in `gates-lib.sh`: the last finished
  non-quick weekly run's directory, never this run's) as `--previous`, or
  says there is none. `failed=` does not depend on it.
- `check-tier.sh` writes `margins.md` into its output and prints it after
  `check-tier done`, its exit status unchanged (open question 3, as
  recommended: one call). A change to `margins.py` owes `check-tier-test`.
- `just margins <dir> [--previous <dir>]`.
- `check-tier-test.sh` (116 checks, `work/check-tier-test-1.txt`): the
  reader over `Tests/KajoCompilerTests/Fixtures/margins/run` with
  `--previous previous` is `expected.md` byte for byte (a plain row, THIN,
  PAST, a field missing and a quoted prefix as UNKNOWN, two lines of one
  name, absent names, an empty `tsan.txt`, a missing `tsan-load.txt`,
  interleaved test output, a `gates.log` with and without bounds and a fuzz
  target line, a name gone); the sample line read as its fields; usage
  errors exit 2; the fuzz gate's start line ends `bound=3601s` and the
  reader tabulates it; `gl_weekly_previous_dir` over three logs.

**Broken variants** (by hand, `broken/`): the reader reading an UNKNOWN
line as a passing row (`reader-unknown-as-pass/variant.diff`): the fixture
check fails, `run-check.txt` ("margins.py over its fixtures differs from
expected.md": a `Broken.wait` row at 0.00 and one UNKNOWN line fewer); the
same checks pass on the head (`head-run.txt`). The helper printing a bound
the wait does not use (`helper-wrong-bound/variant.diff`: `until`'s quiet
line printing 30 for 60): **no check fails** (`run.txt`: the tag test
passes, its line says `bound=30.000`). None can as built: no test sees the
bound a wait used except through the line itself. The protection is that
each print reads the same constant or variable as the wait, which a reader
of the diff checks.

### The real run (2026-11-24, c514abf)

The tier's `swift-test` and `tsan` run again on the final commit
(`check-rerun/gates.log`, after the name fix below) and one
`swift-test-load` and `tsan-load` through `gl_gate` (`check-load/gates.log`),
copied together into `work/real/`; `scripts/margins.py work/real` is
`work/real-margins.md`. 225 margins; **no UNKNOWN line, no name absent from
a gate**. The ten largest fractions:

| margin | kind | unit | swift-test | swift-test-load | tsan | tsan-load | largest | mark |
|---|---|---|--:|--:|--:|--:|--:|---|
| tools.roundtrip.class.hierarchy | ceiling | ms | 658/30000 (0.02) x7 | 1011/30000 (0.03) x7 | 28886/30000 (0.96) x7 | 36891/30000 (1.23) x7 | 1.23 | PAST |
| hostTimer.queueSpins | deadline | s | 45.3/120 (0.38) | 51.6/120 (0.43) | 120/120 (1.00) | 120/120 (1.00) | 1.00 | PAST |
| tools.roundtrip.class.hierarchy__retried_ | ceiling | ms | 1477/30000 (0.05) | 1619/30000 (0.05) | 21692/30000 (0.72) | 28968/30000 (0.97) | 0.97 | THIN |
| tools.roundtrip.process.frames | ceiling | ms | 364/30000 (0.01) x2 | 625/30000 (0.02) x2 | 15713/30000 (0.52) x2 | 24695/30000 (0.82) x2 | 0.82 | THIN |
| reserve.promotionPastTheReserve.offload.0 | deadline | s | 82.5/120 (0.69) | 85.1/120 (0.71) | 89.7/600 (0.15) | 169/600 (0.28) | 0.71 |  |
| reserve.promotionPastTheReserve.stw.0 | deadline | s | 80.9/120 (0.67) | 74.7/120 (0.62) | 86.3/600 (0.14) | 170/600 (0.28) | 0.67 |  |
| main.turnOverrunCpu | ceiling/time | ms | 0.043/0.200 (0.21) | 0.124/0.200 (0.62) | 2.0 | 3.2 | 0.62 |  |
| reserve.promotionPastTheReserve.stw.4 | deadline | s | 71.2/120 (0.59) | 69.6/120 (0.58) | 79.5/600 (0.13) | 158/600 (0.26) | 0.59 |  |
| tools.theToolsReconnectAfterADroppedLink.remoteReady.quiet | quiet | s | 0.438/60.0 (0.01) | 0.472/60.0 (0.01) | 18.7/60.0 (0.31) | 34.6/60.0 (0.58) | 0.58 |  |
| process.gcKeepsParkedProcessStacksAlive | deadline | s | 9.1/120 (0.08) | 14.6/120 (0.12) | 47.3/120 (0.39) | 66.2/120 (0.55) | 0.55 |  |

The bar's rows, under `tsan-load`: the tag test's `ready` 9.0 s quiet of
60 (0.15) and 25.7 s total of 300 (0.09), `definedInTag:Probes` 1.2 of 60
and 5.7 of 300; `tools.roundtrip.class.hierarchy` **36 891 ms of the 30 000
ms request timeout (1.23, PAST)** in a passing run (28 886 under `tsan`, 0.96);
`stall.main.ring` 10.6 s quiet of 600 (0.02) with its body 207 s (a time);
the full-heap test has no bounded wait (`headless` runs to its end) and
prints its body only, 349, 373, 381 and 791 s. The gates' own times: 741,
3234, 825 and 4355 s against 3600, 10 800, 3600 and 10 800 (0.21 to 0.40).

The tier's first table (`check/margins.md`) named `holdsTokenFor:` with the
target's port, a new name each run; c514abf makes any argument that is not
a plain word or number `_`. That is why `swift-test` and `tsan` ran again.

### The scratch weekly run

`KAJO_WEEKLY_ROOT=~/kajo-scratch/weekly-margins/work/weekly
KAJO_WEEKLY_DEVICES=0 KAJO_WEEKLY_ONLY="check-tier-test swift-test"
scripts/weekly.sh` on c514abf (`work/weekly-run.txt`; nothing under
`~/kajo-weekly/` changed, no device touched). Its `weekly.log` was seeded
with one synthetic finished run whose directory holds the real run's four
outputs, so that `--previous` has something to read. `summary.md`
(`work/weekly/2026-11-24/summary.md`, 12 min, `failed: none`) has the
section after the gates table; its head:

    ## Margins

    Previous: .../work/weekly/2026-11-23-prev (the last finished weekly run, weekly.log).

    ### Margins the tests printed (2026-11-24)

    | margin | kind | unit | swift-test | largest | previous | mark |
    |---|---|---|--:|--:|--:|---|
    | reserve.promotionPastTheReserve.offload.0 | deadline | s | 86.5/120 (0.72) | 0.72 | 0.71 |  |
    | reserve.promotionPastTheReserve.stw.0 | deadline | s | 82.1/120 (0.68) | 0.68 | 0.67 |  |
    | reserve.promotionPastTheReserve.stw.4 | deadline | s | 73.6/120 (0.61) | 0.61 | 0.59 |  |
    | reserve.promotionPastTheReserve.offload.4 | deadline | s | 55.0/120 (0.46) | 0.46 | 0.50 |  |
    | hostTimer.queueSpins | deadline | s | 50.5/120 (0.42) | 0.42 | 1.00 |  |
    ...
    ### The gates' own times against their bounds (gates.log)

    | gate | rc | seconds | bound | fraction | mark |
    |---|---|--:|--:|--:|---|
    | check-tier-test | 0 | 7 | 900 | 0.01 |  |
    | swift-test | 0 | 740 | 3600 | 0.21 |  |

    - Printed more than once in a gate (the largest fraction kept): ...
    - No output here for: swift-test-load, tsan, tsan-load, test-release, soak, compiler-tests

The first real run is the weekly of 2026-11-30. Its `--previous` is
2026-11-23, whose outputs hold no margin line: every row's previous column
will read `new` that once.

### Gates

`scripts/check-tier.sh --dry-run origin/master` on 3f86421 named the
**Swift tier with `check-tier-test`** (42 of 43 files; `check-dry-run.txt`).
`just check origin/master` on 3f86421 (`check/gates.log`, last line
`2026-11-24 20:50:56 3f86421 check-tier done swift failed=0 4449s`):
check-tier-test 7 s, clean-build 20 (19 in the last module's
`~/kajo-scratch/weekly-1123-failures/check/gates.log`), swift-test 747
(719), tsan 3146 (3146), kernel-test 126 (126), apps 131 (132), new-check
272 (271); 4449 s against 4413. 485 and 199 tests (484 and 198: the two
helper tests), 0 sanitizer reports. The tier printed its table
(`check/margins.md`). c514abf then changed one test file (the name fix), so
`swift-test` and `tsan` ran again alone through `gl_gate`
(`check-rerun/gates.log`: rc=0 741 s, rc=0 3234 s), then `swift-test-load`
and `tsan-load` once each (`check-load/gates.log`: rc=0 825 s, 829 in the
last module; rc=0 4355 s, 4156). 485 and 199 tests in each, 0 reports.
Before the tier the changed suites ran once under ThreadSanitizer with
twelve loops (`work/tsan-changed/tsan-changed.txt`: 84 and 199 tests
passed, 0 reports), and `check-tier-test.sh` ran alone (116 checks, ok).
Against the last module's tier: `swift-test` 747 and 741 s against 719
(3 to 4 percent, the two new tests, the printing and one probe at each
tools test's end; not split further), `tsan` 3146 and 3234 against 3146.

### Deviations

- Part 1 measured with an instrumented copy and two loaded runs (about 90
  minutes), not from the eee63db outputs alone: most sites printed nothing
  there. A first attempt was stopped (`part1/measure-aborted`) when two
  site-naming schemes were seen to collide.
- The rule's "not reached prints" did not foresee tests no gate runs (17
  rows by hand: `KAJO_MEASURE` and the like): they print nothing and are
  listed as by hand. `AnswersProbe`'s Smalltalk loop is not measured and
  prints nothing. `Review3SmallFixesTests.swift:328` is not a margin (its
  0.2 s timeout is meant to run out).
- The reader's fixture test was run against the broken variant by
  extracting the margins checks from `check-tier-test.sh`
  (`broken/reader-unknown-as-pass/margins-checks.sh`), not by running the
  whole script in a copy (it needs a git checkout); the extraction ran on
  the head too.
- One test file changed after the tier (c514abf), so its two test gates ran
  again alone, as PROCESS.md allows.
- Two temporary directories the extracted checks left in `$TMPDIR` were
  removed by hand.

### Not done, not verified

- The table has not met a failing run: every gate run here passed. That a
  line is printed when a wait fails is read from the code (each print sits
  where the wait ends, before the failure is recorded), not seen.
- A printed bound that differs from the bound the wait used is caught by
  nothing (the second broken variant); a reader of the diff is the check.
- The weekly summary has run once, in a scratch root with a seeded
  previous run, two gates; the full weekly with every gate has not.
- `test-release`, `soak` and `compiler-tests` were never read with margin
  lines in them.

### Found, not this module's

- **`class.hierarchy` round trips past the client's 30 s request timeout in
  passing runs**: 41 500 ms in part 1's instrumented `tsan-load`, 36 891 ms
  in the real `tsan-load`, 28 886 under plain `tsan`. A latency longer
  than the timeout means the reply was dispatched after the timer was due;
  how a request survives that (the retried label, 29 s, suggests a send
  again) is not read here. Question 3 of the last record asked for exactly
  this number.
- `Review3SmallFixesTests`' host-timer test waits up to 120 s for every
  thread of the global queue to spin, and under the sanitizer that wait
  runs out every time (120.0 of 120 in both `tsan` runs, part 1 too) while
  the test passes on what it saw then.
- `ReserveTests`' `promotionPastTheReserve` waits use 0.6 to 0.72 of 120 s
  in plain builds, the largest plain fractions in the suite.
- `process.frames` round trips reach 24.7 s of 30 under `tsan-load`.

### Open questions (built as recommended)

1. THIN's number: 0.8. The spread gives no reason for another (part 1).
2. A thin margin does not fail the weekly run: as built, a mark in
   `summary.md`.
3. `just check` prints the table at its end: as built, one call that
   cannot change the exit status.
4. The old lines (`stall-diag body`, `tools-tags`) are kept beside the new
   ones: docs and records name them.
5. New: the `class.hierarchy` round trip past its timeout under the
   sanitizer (above). Recommended: read the weekly of 2026-11-30's row
   first, then decide question 3 of the last record with it.
6. New: the host-timer test's 120 s wait that always runs out under the
   sanitizer. Recommended: a small follow-up that says what the test needs
   of that wait.
