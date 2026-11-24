# The weekly run's two failures (2026-11-23): two test waits on a clock

Built 2026-11-23 to 24 by one build agent from
`docs/modules/weekly-1123-failures.md` (the owner, 2026-11-23: "Yes, brief
it"). Commits eeb07bb (part 1), eba1c21 (its doc), dd7f4e9 (A), eee63db (B,
the final code commit), b7bedcb (the doc). Work files in
`~/kajo-scratch/weekly-1123-failures/`. No product code changed: three
files under `Tests/`.

## What it was

The weekly run on ba8671c failed `tsan-load` on
`aClassDefinedIntoATagFromTheBrowserMovesWithItsTag` (A) and
`swift-test-load` on `theMainWorkerNeverStallsAndItsFallbacksNameIt` (B).
Neither failure was reproduced without forcing. Both tests held a
wall-clock bound over a step whose time is the CPU the step is given.

## B, the stall test

- What was false: "rt.vm.liveProcessCount == 0 → 1", the body 191.4 s
  against the loop's 180 s deadline.
- The body's time, five or ten runs a setting (`work/btimes/summary.txt`,
  rule `part1/rule-B.txt` with two amendments written before their runs):
  alone 16.8 to 17.8 s; alone with twelve loops 21.3 to 24.2 s; in the
  VM tests' bundle with twelve loops 78.7 to 137.5 s (median 119.3). On
  723b3fe, the stall tests' follow-up: 16.8 to 17.1, 22.2 to 24.6, 47.4 to
  122.0 (median 117.3). The body did not grow with the commits. It is the
  main worker's share of a core (0.34 to 0.51 in the bundle) and its own
  two full collections (2.4 s alone, 13 to 30 s each in the bundle).
- With no deadline, by hand: the ring ended and every expectation held in
  four of four runs (79.9 to 125.9 s). No plain-build run passed 180 s
  again; past 180 s the ring was seen to end only under the sanitizer
  (199.4 to 275.2 s in six runs).
- The fix (eee63db): the loop ends when the ring ends and fails when the
  collector's progress stands still for 120 s (600 s under the
  sanitizer), the other stall tests' rule. The ring's length and every
  assertion are unchanged. It prints where it stood either way.
- After: 5 of 5 alone with loops, 5 of 5 in the bundle with loops, once
  under the sanitizer with loops. Broken variants by hand (`broken/`): the
  ring on a background worker fails the no-stall check; a main worker
  never driven fails after "stall-diag main QUIET quiet=120.1".

## A, the tag test

- What was false is a reading, not a quote. The weekly run's line printed
  none of the probe's three clauses. It did say the browser had the
  define's reply when the line was printed, nothing pended and no Process
  stood at an error, and every later check of the test passed. That fits
  a reply dispatched after the 60 s wait ended.
- The count, rule written first (`part1/rule-A.txt`, 17:27 on
  2026-11-23): the whole package under the sanitizer with twelve loops,
  three runs a side, about 74 minutes a run. eeb07bb 0 of 3; eeb07bb with
  381f57c's kernel 0 of 3. The rule said beforehand that this cannot say
  whether 0ef3b1f caused the failure, and it cannot. The test's steps were
  the same on both sides: 45.8 to 47.5 s in all, `ready` 25 to 27 s, the
  define's round trip 3.4 to 3.7 s.
- The forcing condition: `KAJO_TOOLS_HOLD_LOOP=70000` holds the tools'
  event loop before the define's reply is dispatched. It gives the weekly
  run's shape: the first wait fails and everything after passes. Its
  line names the false clause, "files #()", with "pending
  #(#('class.define' 60008))". Forced: 3 of 3 fail before the fix, 0 of 3
  after (`part2/forced-A/summary.txt`). This shows that the new wait
  bears a held loop. It does not show that the weekly run's loop was held.
- The fix (dd7f4e9), its need written first (`part2/claims.txt`):
  `LocalTools.until` fails on 60 s with no request pending and no reply
  dispatched, or after 300 s in all. The 60 s is the old bound; a step
  with a request pending may now take up to 300 s. Broken variant by
  hand: without the pending clause the forced run fails again.
- Part 1 (eeb07bb): an `until` failure line says why it ended, the wait,
  the probes, the longest probe and each clause from a `...Why` companion
  probe; the tag test prints each step's time and every round trip.

## Starting positions

1 right as far as the forcing shows; 2 right for the forced run only; 3
not shown (the weekly run has no step times; in counted runs the long
step is `ready`); 4 not decided; 5 right, past 180 s under the sanitizer
only; 6 right; 7 right.

## Gates

`check/gates.log`: `2026-11-24 07:47:11 eee63db check-tier done swift
failed=0 4413s` (4646 s on 6fb8c5d): clean-build 19 s, swift-test 719,
tsan 3146, kernel-test 126, apps 132, new-check 271. The two gates that
failed the weekly run, once each through `gl_gate`
(`check-load/gates.log`): swift-test-load `rc=0` 829 s, tsan-load `rc=0`
4156 s. 484 and 198 tests in each, 0 sanitizer reports. In them the stall
test's body was 75.0, 144.6, 85.0 and 204.6 s and the tag test took 1.3,
27.3, 1.9 and 45.7 s.

The main session read the whole diff, both gate logs, the rules' and the
claims' times, the count's and the forcing's summaries and the broken
variants' failing lines. It ran nothing again.

## Deviations

- The count ran the whole package, not the compiler tests' bundle.
- B's part 2 edit was drafted minutes before `claims.txt` was written;
  nothing was built from it before.
- One short-lived file was written to `/tmp` in part 1 and removed.

## Not done, not verified

- A did not fail without forcing. The weekly run's false clause and where
  250 to 300 s of its 378.8 s went are not known. With the new wait such a
  run passes; its step times and round trips are printed and nothing
  reads them.
- B was not seen past 180 s in a plain build.
- The other `until` probes have no `...Why` companion and print "why
  none".

## Found, not this module's

- Under the sanitizer with the suite's load the browser's first
  `class.hierarchy` took 23.5 s of the client's 30 s request timeout in
  every counted run. In one of six it ran out and
  `ProjectDirectoryTests.theToolsChooseThroughTheHostAndTheirChangesLandThere`
  failed `ready` ("class.hierarchy got no reply within 30000 ms").
- `MainThreadTests.aTurnOverrunsItsBudgetByAtMostAFifthOfAMillisecond`
  failed once in fifteen runs of the VM tests' bundle with twelve loops
  (`work/btimes/S3-base-5.txt`).

## Open questions

1. A tools test's wait goes on while a request pends, to 300 s.
   Recommended: as built.
2. The stall test waits on the collector's progress with its ring's
   length kept. Recommended: as built.
3. The client's 30 s request timeout against a 23.5 s `class.hierarchy`
   under the loaded sanitizer. Recommended: read the round trips the tag
   test prints in the next weekly run before changing the timeout or the
   request.
4. (The main session's.) The weekly summary could tabulate every body
   time and round trip a test prints against its bound, so that a
   shrinking margin or a slow step in a passing run is seen. Recommended:
   a small later module.

## The owner's answers (2026-11-24, "Yes, as recommended")

1. A tools test's wait goes on while a request pends, to 300 s. As built.
2. The stall test waits on the collector's progress with its ring's length
   kept. As built.
3. The client's 30 s request timeout is not changed now. The round trips
   the tag test prints are read in the next weekly run (2026-11-30) first.
4. The weekly summary tabulating every body time and round trip a test
   prints against its bound is a small later module. Approved, not built:
   a row of `docs/PLAN.md`.
