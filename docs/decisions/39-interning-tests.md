# The interning tests drive their race

A follow-up of Symbol interning, built 2026-11-16
(`docs/modules/interning-tests.md`; one sitting, final code commit 01d4580,
the doc's commit 0923e1d). The weekly run of 2026-11-16 on 30e14bd failed
`swift-test`, `swift-test-load` and `tsan` on two tests of
`Tests/KajoVMTests/ObjectModel/SymbolInterningTests.swift` and nothing else;
the owner the same day: "Ok, fix the tests next then".

## What was wrong

`workersInterningTheSameBytesAtOnceGetOneSymbol` and
`withoutTheSecondLookupTwoSymbolsOfTheSameBytesAppear` assert that two
workers raced for the same bytes, and repeated a round up to 40 times until
they had. Eight Processes were spawned one after another and each interned
the same names in order, so two of them overlapped only when a later one
caught up with the leader before the names ran out. No answer was ever
wrong and the symbol-table verifier was clean: the tests, not the VM.

## What was built

The test file alone changed. `internConcurrently` takes `gate:`; the two
tests pass `true`. Each Process runs the kasm method
`internAll:arrivals:index:`: it marks its slot of an Array the host made,
spins until every slot is marked, and then interns its names, so a round's
Processes begin together from the first name. The loop, its bound of 40
rounds, the names and every assertion are as they were (`git diff 4a3292e
01d4580 -- Tests/` shows the gate, comments and one `print` of each body's
own time). No test switch was added and nothing under `Sources/` changed.

## The numbers

30 runs of each test in each condition, one at a time, before on 4a3292e and
after on 01d4580 (`~/kajo-scratch/interning-tests/part1/table.md` and
`part3/table.md`, raw files under `part1/runs/` and `part3/runs/`). Rounds
needed, minimum/median/maximum of the 40 allowed:

| condition | case | before | after |
|---|---|---|---|
| plain | correct, fast path | 1/5/8 | 1/1/1 |
| plain | broken variant | 5/15/27 | 1/1/1 |
| twelve busy loops | correct, fast path | 1/4/6 | 1/1/3 |
| twelve busy loops | broken variant | 1/4/11 | 1/1/3 |
| ThreadSanitizer | correct, fast path | 1/1/1 | 1/1/1 |
| ThreadSanitizer | broken variant | 1/1/5 | 1/1/1 |
| ThreadSanitizer and loops | correct, fast path | 1/1/3 | 1/1/1 |
| ThreadSanitizer and loops | broken variant | 1/1.5/4 | 1/1/1 |
| beside the random programs | correct, fast path | 1/12.5/34 | 1/1/2 |
| beside the random programs | broken variant | 1/14/40, 1 run of 30 failed | 1/1/2 |

The brief's four conditions did not reproduce the weekly's failure (0 of 120
runs per test failed before). The agent added the fifth, both tests in one
`swift test` beside `randomProgramsAgreeWithTheirModel` (23 VMs at once);
there the broken variant failed once in 30 with the weekly's own line ("0
byte sequences answered by two Symbols in 40 rounds",
`part1/runs/suite/suite-3.txt`). After: 0 runs of 150 per test without the
race, the worst 3 rounds of 40. The margin that is left: under the twelve
loops the smallest count found under the lock in a passing round was 1.

Body times after, from the tests' own lines: 0.07 to 0.23 s plain, 0.67 to
1.29 s under the sanitizer, 0.85 to 1.73 s with the loops as well, 0.26 to
0.83 s beside the random programs. The 290 to 910 s Swift Testing reports
for these tests in the gates is the wait for a thread of the pool, before
and after.

The correct test can still fail: with the second lookup switched off in it
by hand (never committed) every round reports duplicates, 86 issues in
13.8 s (`part3/hand/correct-without-second-lookup.txt`).

## Gates

`just check 4a3292e` on 01d4580, the Swift tier (one file under `Tests/`),
swift.org 6.4.2 first on PATH, 4078 s, every gate `rc=0`
(`~/kajo-scratch/interning-tests/check/gates.log`); against native by
default's run on 0f3c282: clean-build 20 s (20), swift-test 722 s (771),
tsan 2837 s (3007), kernel-test 108 s (106, 249 of 249), apps 127 s (127),
new-check 264 s (264). 461 and 164 tests in both test gates, 0
ThreadSanitizer reports. In both gates each of the two tests saw its race
in round 1 (17, 58 and 27 in `swift-test`; 95, 1443 and 50 under the
sanitizer).

## Deviations and not done

- The fifth condition is a stand-in for the suite, not the suite: thirty
  full runs would take six hours.
- The loop's bound stayed a number of rounds (the brief's third starting
  position, a counter with a time bound, was not needed).
- `swift-test-load` and `tsan-load` are not in the Swift tier and did not
  run as gates. The weekly run of 2026-11-23 is the first full check of
  the fix.

## Found, not the module's

Other tests that bound a wait by a count (not changed, not measured):
`oldheapUnderAggressiveRelocationMatchesStopTheWorld` and
`fragmentUnderAggressiveRelocationMatchesStopTheWorld`
(`RelocationKernelTests.swift`, up to three runs and then `cyclesSelected
>= 2`), and `theMarkerScansTheOwedNurseriesBeforeItAsks` with
`withoutTheScansBeforeTheStopTheFinalMarkGivesUpThenOverruns`
(`FinalMarkTests.swift`, up to 20 attempts, driven by the test thread and
probably deterministic; not checked).

## Open questions

None. The brief's one question (a test switch in the core if only that could
drive the race) did not arise.
