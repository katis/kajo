# Check time and the thin waits

Built 2026-11-25 to 2026-11-27 by one build agent from
`docs/modules/check-time.md` (the owner, 2026-11-25: "independently get the
VM and the checks to a good shape... this needs to be reliable, but we
can't spend a whole week (hyperbole) running just checks"; the decisions
were delegated to the main session and are listed below so that the owner
can reverse them). Commits 3429c70 (part 1, measurement only), 83e8611 (a
kernel fix), 292b202 (parts 2 to 4), 749fc70, 0ae993f, a880ce0, 1a68580
(the final code commit) and e07df44 (the doc). Work files in
`~/kajo-scratch/check-time/`. Nothing under `Sources/` changed; `kernel/`
changed in two methods.

## What was built

- `scripts/test-bundles.sh`: a test gate builds once and runs the suite as
  shards side by side, each a `swift test --skip-build` of its own: the VM
  tests, the random programs, the resumed random programs and the compiler
  tests, and then alone, as a second phase, the tests that talk to a
  target (ToolsTests, PhoneTransportTests, ProjectDirectoryTests,
  DebuggerProtocolTests, DevelopmentAnswersTests). The four test gates
  (`swift-test`, `swift-test-load`, `tsan`, `tsan-load`) run through it.
- One sanitizer gate a tier, the loaded one. The Swift tier is
  `clean-build swift-test tsan-load kernel-test apps new-check`; the core
  tier has no plain `tsan`. The weekly run keeps both.
- `KAJO_TEST_SIZE=full` (`Tests/*/TestSize.swift`, `sized`,
  `.weeklyUnderSanitizer`, the table `sizedTests`, and a table test that
  fails on an id with no row and a row with no reader). The weekly run
  exports it. A tier leaves it unset, and then the tier's sanitizer gate
  does not run three kernel tests (`CompilerTest>>testEveryMethodCompilesAsTheBootstrapDid`,
  `LiveCompileTest>>testEveryMethodMakesAsInstalled`,
  `CompilerTest>>testALongChainIsWalkedByALoop`) and two Swift tests (the
  diagnostics request, the types package's tests). The plain gate of every
  tier runs all five; the weekly run runs them under the sanitizer.
- The kernel's tests run as three parts (two before).
- `scripts/broken-variants.sh` and the weekly gate `broken-variants`: the
  seven by-hand variants that need no source change (delay-end,
  shell-close, three closed-shell calls, and the two forcing conditions
  that must pass), each once, each compared with its record. The variants
  that need a source patch are not automated; the doc lists them.
- The weekly `summary.md` has `## Test sizes` and the by-hand section.
- `DevProtocol class>>requestCount`: `session.open`'s answer counted the
  requests by building the whole description; a fresh image's first open
  went from 4117 to 87 ms under the sanitizer.

## What was measured (`part1/`, rules written first: `rules.txt`)

- Plain suite 781 s: the VM bundle 655 s quiet, bound by its pool of test
  threads, not by the cores. Sanitizer suite 3404 s: the VM bundle 1186 s
  and CPU-bound, the compiler bundle 2174 s and 49 percent idle; three
  kernel tests were 2600 of the kernel tests' 4058 s.
- Kernel-test parts: 0 failures at 2, 3, 4 and 6 parts; three was shortest.
- Which sanitizer gate found each past failure: 19 failing runs, one
  product fault (decision 53), found by both gates. So the loaded gate
  alone loses no past finding.

## The gates (all on 1a68580)

| gate | now (s) | before (s) |
|---|--:|--:|
| Swift tier, whole | 3656 | 4449 |
| swift-test | 453 cold, 303 to 307 warm | 747 |
| tsan-load (tier size) | 2643; five more: 2529 to 2614 | 4355 |
| tsan (full size) | 3003 | 3146 |
| tsan-load (full size) | 3796 | 4355 |
| swift-test-load (full size) | 357 | 825 |

`check/gates.log` ends `check-tier done swift failed=0 3656s`. The five
loaded sanitizer runs (`check-load-1..5/`) are all rc=0 with 0 reports.
The full-size run (`check-full/`) is rc=0 in its four gates. No margins
table has a THIN or PAST row. Tests per gate
(`work/tests-per-gate-final.md`): 0 names gone at full size; the tier's
`tsan-load` leaves out the five above. `check-tier-test`: 133 checks.

**The targets were not met.** Swift tier 61 minutes against 30. The core
tier's Mac gates about 97 minutes against 75, and that is an estimate, not
a run (10 841 s in the weekly run of 2026-11-23). The next lever is a tier
size for the VM tests under the sanitizer (the stall tests are 30 percent
of that shard); it was not taken.

## The thin waits

1. `class.hierarchy` (the approved row): the 36 to 42 s was a round trip
   measured to the dispatch, which the 30 s timeout does not race; the
   reply itself arrived after 16 to 25 s, behind `session.open`. Fixed by
   `requestCount`; arrivals are printed as `tools.reply.*` (7.5 to 8.0 s of
   30 in the five final runs).
2. The host-timer test (the approved row): the 120 s wait for a spinner to
   start was not needed, the canary carries the claim; removed, and the
   broken variant still fails. Why GCD starts no thread there is not
   established.
3. `ReserveTests`: a clock on a fixed amount of work; it waits on the
   collector's progress now (forced: 4 of 4 failed before, 4 of 4 pass).
4. The turn-overrun test: 1 failure in 100 forced runs (0.219 ms); the
   failing turn acknowledged a young round. That is the VM's and is not
   fixed; the test prints its three largest turns.
5. The tag test: 0 of 5 under its rule; one different failure (a class
   removal refused because another Process held the class on its stack).
   No cause seen; the failure line says more now.
6. Made by the new layout and fixed: the reconnect test's frames reply
   past 30 s beside the VM tests (hence the second phase),
   `gcKeepsParkedProcessStacksAlive` and `keptAcrossRun` (wait on progress).

## Decided under the owner's delegation (the owner may reverse each)

1. A tier runs one sanitizer gate, the loaded one.
2. A tier's sanitizer gate leaves five slow tests to the weekly run. This
   goes against the owner's word of 2026-11-13 not to sample the
   every-method kernel tests under the sanitizer: they are not sampled,
   but in a tier they run in the plain gates only.
3. The Swift tier's plain gate stays unloaded.
4. A THIN margin still fails no gate.
5. The VM tests keep their full size under the sanitizer in every tier,
   so the targets stay unmet until two weekly runs have been read.
6. No timeout and no test bound grew.

## Found, not this module's

- A frames reply compiles every frame's method again (12 s quiet under the
  sanitizer, 28 to 49 s beside the VM tests).
- A main turn that acknowledges a young round can overrun its budget
  (0.219 ms against 0.2).
- A class removal is refused while a listing request or the type service
  holds the class on its stack, and the refusal names no Process.
- `ProjectDirectoryTests.eachTargetWritesOnlyIntoItsOwnDirectory` failed
  once (full-size `swift-test-load` on 0ae993f), not reproduced.

## Not verified

The core tier as a real run; `broken-variants` in a real weekly run; the
cause of the tag probe's refusal and of the turn overrun; whether
`swift-test` from an empty scratch path always pays a cold native cache.
The module cost about 35 machine-hours of gates.
