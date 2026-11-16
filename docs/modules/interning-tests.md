# The interning tests drive their race (a follow-up of Symbol interning)

## Status

Briefed 2026-11-16; built the same day in the test file alone (As built,
below). The weekly run of 2026-11-16 on 30e14bd
failed `swift-test`, `swift-test-load` and `tsan` on two tests of
`Tests/KajoVMTests/ObjectModel/SymbolInterningTests.swift` and nothing
else. The owner, the same day: "Ok, fix the tests next then".

## What it is

Two tests assert that a race was seen and wait for it by repeating a round
up to 40 times. They are changed so that the race is driven, not hoped
for: the thing each test claims happens in every run, early, on an idle
machine and a loaded one, with and without the sanitizer. No rule of the
VM changes and no assertion is weakened.

## What is known (check these before building on them)

- `workersInterningTheSameBytesAtOnceGetOneSymbol(slowAllocation: false)`,
  line 202, `ic.foundUnderLock > 0`: failed in the weekly's `swift-test`
  and `swift-test-load` ("40 rounds, 16000 inserted, 0 found under the
  lock, 0 contended"). `withoutTheSecondLookupTwoSymbolsOfTheSameBytesAppear`,
  lines 225, 229 and 230: failed in `swift-test` and `tsan` ("0 byte
  sequences answered by two Symbols in 40 rounds"). Files:
  `~/kajo-weekly/2026-11-16/{swift-test,swift-test-load,tsan,tsan-load}.txt`.
- No answer was wrong in any round and `symbolVerifierFailures` read 0 in
  the correct variant. The VM is not the suspect.
- Rounds the same tests needed in earlier gate runs that passed, from
  their own printed lines: without the sanitizer 19 and 23 rounds
  (`slowAllocation: false`), 5 and 25 (the broken variant); under the
  sanitizer 1 to 21 and 5 to 9 (`~/kajo-scratch/aot-product/check/`,
  `~/kajo-scratch/gate-speed-followup/check/`). The margin was always thin
  where the code is fastest.
- The `slowAllocation: true` case saw its race in all four weekly gates
  (5 to 35 rounds; 35 of 40 in plain `swift-test` is thin too).
- The window: a worker misses in the lookup without the lock and then
  takes `internLock` (`Machine.internSlow`,
  `Sources/KajoVM/ObjectModel/Strings.swift`). Two workers collide only
  when both miss before either inserts. Eight Processes are spawned one
  after another and each interns the same 300 names in order, so they are
  in step only by chance.
- With `internSlowAllocation` a worker lets the lock go, makes the Symbol
  outside and comes back; with `internNoSecondLookup` as well, two workers
  that both missed both insert. That pair of existing switches may give
  the broken variant its duplicate without any new code in the core.

## Starting positions (measure, then decide; say where one was wrong)

1. A change in the test file alone is enough. Candidates: a start gate so
   that every Process begins its loop at the same moment (a flag or a
   Semaphore the test signals once all are waiting); many short rounds of
   few names so that the Processes are in step again each round; the two
   existing switches together for the broken variant.
2. If no test-only change makes the unsanitized fast path collide in every
   run, a test switch that pauses a worker between its miss and the lock
   does. That is a line in `Sources/KajoVM/ObjectModel/` and
   `Workers/VMConfig.swift`: the core tier, about 3.2 hours of gates, and
   the switch off must leave `internSlow`'s release code as it is (`just
   arc-check`, the aligned A/B). Take this road only with the measurement
   that says position 1 failed.
3. The loop's bound becomes a counter with a long time bound, not a number
   of rounds: the test runs until the race was seen and fails only when a
   long stretch passes without it, printing what it saw (rounds, inserted,
   contended, the workers that ran).
4. The test's cost falls. The two tests' reported times (540 to 790 s) are
   mostly the wait for a thread of the pool; print each body's own time.

## Parts

1. **Measure, change nothing.** Each of the two tests alone, 30 runs in
   each of four conditions (plain, plain with the twelve busy loops,
   ThreadSanitizer, ThreadSanitizer with the loops): the round in which
   the race was seen, or that it was not. This is the before table and it
   says how often the tests fail on 30e14bd.
2. **Drive the race** by position 1, and by position 2 only if part 2's
   own table shows position 1 is not enough.
3. **Measure again**, the same 30 runs in the same four conditions: the
   race seen in every run, the round it was seen in, each body's time.
4. **The doc**: `docs/modules/symbol-interning.md` gains a dated section;
   this file's "As built".

## Tests

- The two tests are the module. Their assertions stay: `foundUnderLock >
  0`, `dup > 0`, the verifier's report of two Symbols, no duplicate in the
  correct variant, `internStops == 0`.
- The correct variant must still be able to fail: with the second lookup
  switched off by hand it reports a duplicate (one run quoted).
- The other tests of the file are run with the two and pass unchanged.

## The bar

- Part 3's table: 0 runs of 120 per test without the race.
- The race is seen within a quarter of whatever bound the loop keeps, in
  every run, or the bound is on time and the longest run is under a tenth
  of it.
- Each test's body time, before and after.
- `just check <the brief's commit>` on the final code commit, every gate
  `rc=0`, its `gates.log` quoted. The tier is the Swift tier if only test
  files changed; say which tier ran and why.
- No assertion removed or loosened; the diff of the test file says so by
  itself.

## Rules of the house that bind here

- `docs/PROCESS.md`, "Constraints on every agent", in full.
- A test that asserts an edge was crossed drives the system to the edge;
  a test that asserts parallelism happened is never weakened to pass when
  it did not.
- A wall-clock assertion fails under load: wait on a counter, bound the
  wait long, print where things stood when it runs out.
- A wait that runs out is a failed check before anything reads the result.
- A new test's own faults are found by the gates: run the changed file
  once under the sanitizer with the twelve loops before the tier.

## Not in this module

- Any change to the interning protocol, its model or its verifiers.
- Other tests that count rounds (name them in the hand-back if found).
- Gate times in general.

## Deliverables

- The commits; the before and after tables with their raw files under
  `~/kajo-scratch/interning-tests/`.
- `check/gates.log` on the final code commit.
- The hand-back map of `docs/PROCESS.md` step 5.

## Open questions (build the recommended option; decisions only)

1. If only a core test switch drives the fast path's race: add it and pay
   the core tier (recommended, a test that fails one weekly in a few is
   worth three hours once), or keep the `slowAllocation: false` case as a
   check of answers only and let the slow case carry the race.

## As built

Built 2026-11-16 on master from 4a3292e, swift.org's 6.4.2 first on PATH
through swiftly (`~/kajo-scratch/interning-tests/part1/runs/env.txt`).
Position 1 was enough: the change is in the test file alone (01d4580),
no switch was added, no rule of the VM changed, and the tier is the
Swift tier. Raw files are under `~/kajo-scratch/interning-tests/`
(`part1/` before, `part3/` after, `check/` the gates, `scripts/` the
drivers `runs.sh`, `suite.sh` and the table maker `table.py`).

### Part 1: before (4a3292e)

Each test alone, 30 runs in each condition, one run at a time
(`scripts/runs.sh`: `swift test --skip-build --filter <test>` on one
build per configuration; load is twelve `gtimeout 600 yes` loops started
for each run and killed by pid after it). The rounds are the tests' own
printed lines; "reported" is Swift Testing's time for the test, which
for a filtered run alone is its body (the parameterized test's two cases
run side by side and share one number). `part1/table.md`, raw files
`part1/runs/<condition>/<test>-<n>.txt`:

| condition | case | runs | race not seen | rounds min/median/max | reported s |
|---|---|--:|--:|---|---|
| plain | same bytes, slowAllocation false | 30 | 0 | 1/5/8 | 0.14/0.34/0.54 |
| plain | same bytes, slowAllocation true | 30 | 0 | 1/2/4 | (the same) |
| plain | broken variant | 30 | 0 | 5/15/27 | 0.14/0.44/0.96 |
| load | same bytes, slowAllocation false | 30 | 0 | 1/4/6 | 0.16/0.26/0.52 |
| load | same bytes, slowAllocation true | 30 | 0 | 1/2/6 | (the same) |
| load | broken variant | 30 | 0 | 1/4/11 | 0.06/0.17/0.47 |
| tsan | same bytes, slowAllocation false | 30 | 0 | 1/1/1 | 0.79/0.82/0.89 |
| tsan | same bytes, slowAllocation true | 30 | 0 | 1/1/1 | (the same) |
| tsan | broken variant | 30 | 0 | 1/1/5 | 0.48/0.51/1.82 |
| tsan-load | same bytes, slowAllocation false | 30 | 0 | 1/1/3 | 1.06/1.48/2.62 |
| tsan-load | same bytes, slowAllocation true | 30 | 0 | 1/1/2 | (the same) |
| tsan-load | broken variant | 30 | 0 | 1/1.5/4 | 0.65/0.98/2.33 |
| suite | same bytes, slowAllocation false | 30 | 0 | 1/12.5/34 | 38.56/40.61/42.77 |
| suite | same bytes, slowAllocation true | 30 | 0 | 1/5/25 | (the same) |
| suite | broken variant | 30 | **1** | 1/14/40 | (the same) |

The brief's four conditions did not reproduce the weekly's failures:
0 of 120 runs per test failed, alone the race came early, and only the
plain broken variant's 27 of 40 was thin. The weekly failed with the
whole suite beside the tests, so a fifth condition was added (a
deviation, below): `suite` runs both tests in one `swift test` beside
the VM suite's interpreted random programs
(`randomProgramsAgreeWithTheirModel`, 23 VMs at once, about six cores;
`scripts/suite.sh`, raw `part1/runs/suite/suite-<n>.txt`). There the
margin is gone: the correct variant needed up to 34 of 40 rounds and the
broken variant failed once in 30 (`suite-3.txt`: "0 byte sequences
answered by two Symbols in 40 rounds"), the weekly's failure. Its
"reported" time is the wait for the cooperative pool, not the body; the
weekly's 540 to 790 s are the same wait.

What the rounds say: the duplicates the broken variant made alone came
at the end of a round's names (`d20_270` to `d20_299` in the first trial
run), a lagging Process catching up with the leader because its lock-free
hits are faster than the leader's inserts. A round raced only when a
Process caught up before the names ran out; in the weekly's `swift-test`
the correct variant read "0 contended" in 40 rounds: no two Processes
ever overlapped.

### Part 2: the drive (01d4580)

`internConcurrently` takes `gate:`; the two tests pass `true`, every
other caller keeps the old path. Each Process runs
`internAll:arrivals:index:` (kasm, in `internAllSrc`): it marks its slot
of a host-made Array of nils, spins until every slot is marked (the last
Process to arrive opens the gate for all; a spin is a send per slot, so
it polls), then interns its names. The Processes of a round so begin
together, from the first name, whatever the spawn order and whatever
else the machine runs; with eight Processes on seven workers the eighth
arrives at the first slice end (5 ms). The loop, its bound of 40 rounds,
the names and every assertion are as they were; `git diff 4a3292e
01d4580 -- Tests/` shows only the gate, the comments and one `print` of
each body's own time (`now()` from before the Runtime to after
`rt.stop`).

Position 2 (a core switch) was not needed; position 3 (a time bound in
place of the round bound) was not needed either, because the race came
in the first rounds everywhere; position 4: the reported times were the
pool's, and each body now prints its own.

### Part 3: after (01d4580)

The same 30 runs in the same five conditions on the gated tests
(`part3/table.md`, raw `part3/runs/`):

| condition | case | runs | race not seen | rounds min/median/max | body s min/median/max |
|---|---|--:|--:|---|---|
| plain | same bytes, slowAllocation false | 30 | 0 | 1/1/1 | 0.194/0.222/0.230 |
| plain | same bytes, slowAllocation true | 30 | 0 | 1/1/1 | 0.195/0.226/0.232 |
| plain | broken variant | 30 | 0 | 1/1/1 | 0.073/0.076/0.080 |
| load | same bytes, slowAllocation false | 30 | 0 | 1/1/3 | 0.113/0.237/0.398 |
| load | same bytes, slowAllocation true | 30 | 0 | 1/1/2 | 0.136/0.206/0.303 |
| load | broken variant | 30 | 0 | 1/1/3 | 0.066/0.113/0.226 |
| tsan | same bytes, slowAllocation false | 30 | 0 | 1/1/1 | 1.072/1.121/1.225 |
| tsan | same bytes, slowAllocation true | 30 | 0 | 1/1/1 | 1.153/1.205/1.292 |
| tsan | broken variant | 30 | 0 | 1/1/1 | 0.667/0.685/0.707 |
| tsan-load | same bytes, slowAllocation false | 30 | 0 | 1/1/1 | 1.347/1.540/1.683 |
| tsan-load | same bytes, slowAllocation true | 30 | 0 | 1/1/1 | 1.289/1.581/1.730 |
| tsan-load | broken variant | 30 | 0 | 1/1/1 | 0.852/0.975/1.125 |
| suite | same bytes, slowAllocation false | 30 | 0 | 1/1/2 | 0.542/0.631/0.828 |
| suite | same bytes, slowAllocation true | 30 | 0 | 1/1/1 | 0.477/0.630/0.816 |
| suite | broken variant | 30 | 0 | 1/1/2 | 0.259/0.482/0.745 |

0 runs of 120 per test without the race in the brief's four conditions,
and 0 of 150 with the suite's; the longest is 3 rounds of 40 (under the
twelve loops), inside a quarter of the bound. How hard a run races
(the same files, the counters at the run's end, min to max): found under
the lock with slow allocation off 329 to 980 plain, 1 to 129 under the
loops, 1284 to 1566 under the sanitizer, 6 to 216 under the sanitizer
and the loops, 6 to 126 in the suite; byte sequences answered by two
Symbols in the broken variant 15 to 253, 1 to 145, 180 to 287, 9 to 111
and 1 to 39. The loaded rows' minimum of 1 is the margin left: a round
in which the OS runs only one of the released workers races little, and
the loop's next round is what covers it. Body times against the before's alone-run
times: plain and load about the same or shorter (one round instead of up
to 27), the sanitizer's about 0.3 s longer (1.1 to 1.7 s against 0.8 to
1.5: the spinning Processes under the sanitizer and the eighth Process's
first slice); in the suite 0.26 to 0.83 s of body inside a reported 36
to 40 s.

The correct variant can still fail: with `noSecondLookup: true` put
into `workersInterningTheSameBytesAtOnceGetOneSymbol` by hand (never
committed), both cases fail in every round,
`part3/hand/correct-without-second-lookup.txt`: "Expectation failed:
duplicates(rt, names, answers) == 0" from round 1, then "no round saw
two workers race for the same bytes in 40 rounds" (with no second lookup
nothing is found under the lock), `symbolVerifierFailures == 0` and the
heap verifier failing; 86 issues in 13.8 s.

The other tests of the file ran with the two and passed unchanged: all
seven tests once plain (`part3/file-plain.txt`, 7 tests, passed in
29.6 s) and once under ThreadSanitizer with the twelve loops
(`part3/file-tsan-load.txt`, 7 tests, passed in 13.5 s, no
ThreadSanitizer report).

### The gates

`KAJO_CHECK_OUT=~/kajo-scratch/interning-tests/check just check 4a3292e`
on 01d4580, the Swift tier (the diff is one file under `Tests/`, which
`scripts/check-tier.sh` classes as Swift; the docs of this section were
uncommitted in the working tree while it ran and do not change the
tier), swift.org 6.4.2 first on PATH, `check/gates.log`, 4078 s, every
gate `rc=0`. Against the previous module's tier on 0f3c282
(`~/kajo-scratch/native-by-default/check/gates.log`):

| gate | result | s | baseline s |
|---|---|--:|--:|
| clean-build | pass | 20 | 20 |
| swift-test | pass (461 + 164 tests) | 722 | 771 |
| tsan | pass (461 + 164 tests, 0 ThreadSanitizer reports) | 2837 | 3007 |
| kernel-test | pass (249 of 249) | 108 | 106 |
| apps | pass | 127 | 127 |
| new-check | pass | 264 | 264 |

The two tests in the gates: `swift-test` 1 round each ("17 found under
the lock", "58 found under the lock", "27 byte sequences answered by two
Symbols in 1 rounds"; bodies 0.56, 0.71 and 0.46 s inside a reported
563 s), `tsan` 1 round each (95, 1443 and 50; bodies 2.06, 1.99 and
1.47 s inside a reported 288 to 344 s). The tests cost nothing
measurable in the gates; the reported times are the pool's.

### Deviations

- A fifth condition, `suite` (both tests in one `swift test` beside
  `randomProgramsAgreeWithTheirModel`), measured before and after with
  the brief's four. The four did not reproduce the weekly's failure (0
  of 120 per test), so without it the before table would not have shown
  the margin the weekly lost; it is a stand-in for the suite, not the
  suite (one full `swift test` takes 12 minutes, 30 of them six hours),
  and the weekly's full gates are the real row.
- The before's body times are Swift Testing's reported times of the
  tests run alone (the tests printed no body time before); in the
  `suite` rows the before has no body time, only the pool's.
- The gate is in `internConcurrently` behind `gate:`, used only by the
  two tests; the other callers (the re-interning test, the growth test)
  keep their ungated path, and `internAllSrc` gained one method every
  test of the file loads.

### Not done

- `swift-test-load` and `tsan-load` are not gates of the Swift tier and
  did not run as gates; the `load` and `tsan-load` rows above run the
  two tests under the same twelve loops, alone, and the file once under
  the sanitizer and the loops. The next weekly runs both.
- No run of the full suite under the loops was made outside the gates.

### Found, not this module's

Other tests that bound a loop by a count while waiting for something to
happen (not changed, not measured):
- `oldheapUnderAggressiveRelocationMatchesStopTheWorld` and
  `fragmentUnderAggressiveRelocationMatchesStopTheWorld`
  (`Tests/KajoVMTests/Relocation/RelocationKernelTests.swift`,
  `underRelocation`): repeat the kernel up to three runs until two
  selecting cycles were seen, then assert `cyclesSelected >= 2`; its own
  comment records one release-suite run that completed one. A test that
  asserts the collector kept up, bounded by a run count.
- `theMarkerScansTheOwedNurseriesBeforeItAsks` and
  `withoutTheScansBeforeTheStopTheFinalMarkGivesUpThenOverruns`
  (`Tests/KajoVMTests/Marking/FinalMarkTests.swift`,
  `finalMarksWithOwedScans`): up to 20 `markStep`/`finalMark` attempts
  before asserting the sweeping phase; the steps are driven by the test
  thread, so this looks deterministic, but it was not checked.
- The fixed-round stress tests `noWriteRunsAfterItsConnectionsClose`
  (`ReviewFixesTransportTests.swift`, 20 rounds),
  `noClientWriteRunsAfterItsConnectionIsReleased` (20) and the install
  race (10) in `ReviewFixesPart2Tests.swift` assert that nothing bad
  happened, not that a race was seen; a quiet machine makes them weaker
  checks, not failures.

### Open questions

1. The brief's question (a core switch if only it could drive the fast
   path's race) did not arise: the test-only gate drove it in every run.
   Nothing awaits the owner from this module.
