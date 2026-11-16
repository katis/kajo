# The interning tests drive their race (a follow-up of Symbol interning)

## Status

Briefed 2026-11-16, not built. The weekly run of 2026-11-16 on 30e14bd
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
