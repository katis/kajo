# The weekly margins: a test's wait prints its value and bound

Built 2026-11-24 by one build agent from `docs/modules/weekly-margins.md`
(the owner, 2026-11-24: question 4 of the weekly run's two failures, "Yes,
as recommended", then "Weekly margins table"). Commits 4d4db5b (part 1, the
inventory), 986c3fa (part 2, the line), 3f86421 (part 3, the reader),
c514abf (the final code commit: a margin's name holds no address) and
fc16971 (the doc). Work files in `~/kajo-scratch/weekly-margins/`. Nothing
under `Sources/` changed.

## What was built

- One line shape, printed when a wait ends, passing or failing:
  `kajo-margin name=<name> kind=<deadline|quiet|ceiling|time> value=<v>
  bound=<b> unit=<unit>`. A helper in each test target prints it
  (`Tests/KajoVMTests/Margins.swift`, `Tests/KajoCompilerTests/Margins.swift`;
  both tested against one committed sample line).
- Part 1's inventory (`part1/final.tsv`, `counts.txt`; the table is in the
  module's doc): 551 rows under `Tests/`. 141 print through the helper, 370
  are "never near" (below 5 percent of the bound in both loaded runs and
  named in no record; the rule, `part1/rule.txt`, 16:54, before any value),
  17 are in tests no gate runs, 20 are not sites, 2 print nothing and 1 is
  a timeout the test expects to run out. The inventory was measured with an
  uncommitted instrumented copy of 51be5b2, one `swift-test-load` and one
  `tsan-load` (`part1/measure/gates.log`).
- The round trips: `ToolsProbe class>>longestReplies` gives the longest
  round trip per request kind that the image's clients keep, against the
  largest request timeout; `LocalTools.close()` prints them
  (`tools.roundtrip.<kind>`).
- `scripts/margins.py <dir> [--previous <dir>]` (`just margins`): a table,
  largest fraction first, a cell per gate; THIN at 0.8, PAST at 1; a second
  table of the gates' own times against their bounds (`gl_gate` now writes
  `bound=<n>s` on its start line); under it the UNKNOWN lines, names printed
  more than once, names absent from a gate and names of the previous run
  that are gone. Exit 0 whatever it finds.
- `weekly.sh` writes `## Margins` in `summary.md` with the last finished
  weekly run as `--previous`; `check-tier.sh` writes `margins.md` and
  prints it. Neither changes an exit status.

## The real run

`work/real-margins.md`, from the four test gates of c514abf: 225 margins, no
UNKNOWN line, no name absent from a gate. The main session made the table
again from the same inputs and it was byte for byte the same.

| margin | gate | value / bound | fraction |
|---|---|---|--:|
| `tools.roundtrip.class.hierarchy` | tsan-load | 36 891 / 30 000 ms | 1.23 |
| `hostTimer.queueSpins` | tsan, tsan-load | 120 / 120 s | 1.00 |
| `class.hierarchy` (retried) | tsan-load | 28 968 / 30 000 ms | 0.97 |
| `tools.roundtrip.process.frames` | tsan-load | 24 695 / 30 000 ms | 0.82 |
| `reserve.promotionPastTheReserve.offload.0` | swift-test-load | 85.1 / 120 s | 0.71 |
| `main.turnOverrunCpu` | swift-test-load | 0.124 / 0.2 ms | 0.62 |
| the reconnect test's `remoteReady`, quiet | tsan-load | 34.6 / 60 s | 0.58 |

The bar's rows under `tsan-load`: the tag test's `ready` 9.0 of 60 s quiet
and 25.7 of 300 s in all; `stall.main.ring` 10.6 of 600 s quiet with a body
of 207 s; the full-heap test has no bounded wait and prints its body's time
only (349, 373, 381 and 791 s in the four gates).

## Gates

`~/kajo-scratch/weekly-margins/check/gates.log`: `2026-11-24 20:50:56
3f86421 check-tier done swift failed=0 4449s` (4413 s for the last module).
check-tier-test 7 s, clean-build 20, swift-test 747, tsan 3146, kernel-test
126, apps 131, new-check 272, each `rc=0`. c514abf changed one test file
after that run, so `swift-test` (741 s) and `tsan` (3234 s) ran again alone
on it (`check-rerun/gates.log`), and `swift-test-load` (825 s) and
`tsan-load` (4355 s) once each (`check-load/gates.log`), all `rc=0`. 485
and 199 tests in each, 0 sanitizer reports. The other gates of the tier did
not run on c514abf; it changes `Tests/KajoCompilerTests/ToolsTests.swift`
only.

The main session read the gate logs, the test counts, the scripts' diff and
every changed line under `Tests/` (36 files, 464 lines added, 68 removed:
each removed line comes back with a `margin:` argument, a defaulted
parameter or a print beside it; `drive`'s default 30 is the constant
`driveSeconds`, 30), and ran `check-tier-test.sh` (116 checks, ok) and
`margins.py` over the real run.

## Starting positions

All seven right. Position 6 has a limit: a test the sanitizer skips is
absent from the sanitizer gates by design (none in the real run).

## Deviations

- Part 1 measured with an instrumented copy; eee63db's outputs alone had
  no values for most sites. A first attempt was stopped when two naming
  schemes collided (`part1/measure-aborted`).
- `LocalTools.close()` runs one probe after a test's last assertion
  (`DevClient allInstances`, one stop): more than a line of output.
- The reader's broken variant was run from the margins checks taken out of
  `check-tier-test.sh`, not through the whole script.
- The scratch weekly run's `weekly.log` was seeded with one synthetic
  finished run so that `--previous` had something to read. `~/kajo-weekly/`
  was not written.

## Not done, not verified

- No failing run was seen: that a failing wait prints its line is read
  from the code.
- Nothing checks that a printed bound is the bound the wait used. The
  broken variant (`broken/helper-wrong-bound/`) fails no check.
- The full weekly run has not run with the section; `test-release`, `soak`
  and `compiler-tests` outputs were never read with margin lines in them.
- The 17 sites in tests no gate runs print nothing.

## Found, not this module's

- A `class.hierarchy` round trip of 36.9 s (41.5 s in part 1's run) against
  the client's 30 s request timeout in passing `tsan-load` runs. How the
  request passed is not read; a "(retried)" row beside it is at 29.0 s.
  This is the number question 3 of `54-weekly-1123-failures.md` waits for.
- The host-timer test's wait for every thread of the global queue to spin
  runs its whole 120 s in every sanitizer run and the test passes.
- `ReserveTests` uses 0.59 to 0.72 of its 120 s bound in plain builds, the
  largest plain fractions of the suite.

## Open questions

1. THIN is 0.8 of a bound, a mark only. Recommended: as built.
2. A thin margin fails no gate and no weekly run. Recommended: as built.
3. `just check` prints the table at a tier's end. Recommended: as built.
4. The old `stall-diag body` and `tools-tags` lines stay beside the new
   line. Recommended: as built.
5. The `class.hierarchy` round trip past the request timeout. Recommended:
   a small module that first says what the number measures (a late reply
   kept, or a request sent again) and how the request passed, before any
   change to the timeout.
6. The host-timer test's wait that always runs out under the sanitizer.
   Recommended: a small follow-up that says what the wait is for and
   bounds it by what it waits for.
