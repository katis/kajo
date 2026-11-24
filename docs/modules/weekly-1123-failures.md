# The weekly run's two failures (2026-11-23)

## Status

Brief. The owner, 2026-11-23, to "Shall I brief a module that counts and
finds the weekly run's two failures?": "Yes, brief it". Starting commit:
the commit of this brief (the last code commit before it is 0ef3b1f).

## What it is

The weekly run of 2026-11-23 (`~/kajo-weekly/2026-11-23/`, ba8671c) ended
`failed=2` on two tests that no module had seen fail in this way:

- A. `tsan-load`: `ToolsTests.aClassDefinedIntoATagFromTheBrowserMovesWithItsTag`
  (`Tests/KajoCompilerTests/ToolsTests.swift:421`), the step
  `definedInTag: 'Probes'` never held.
- B. `swift-test-load`: `theMainWorkerNeverStallsAndItsFallbacksNameIt`
  (`Tests/KajoVMTests/Marking/AllocationStallTests.swift:285`), one Process
  still alive when the loop's deadline passed.

This module says for each one what was false and why, counts it on two
commits under a rule written first, finds a condition that brings it at
will, and fixes the fault where it is. A and B are separate faults until
part 1 says otherwise; each gets its own evidence and its own commit. It
is not a module that makes the tests pass: a longer wait, a retry or a
weaker assertion is not a fix.

## What is known

Check each before building on it. The main session read these from the
files named; it ran nothing.

### A, the tag test

- The lines (`tsan-load.txt:2740` to 2746): "definedInTag: never held:
  client #open lost nil pending 0 browsers 1 hierarchy 242 status 'defined
  ToolsTagProbe' loop errors 0 transcript #() stops 0 stops"
  (`ToolsTests.swift:253`), then the expectation at line 441, "failed
  after 378.847 seconds with 2 issues". Only the first `definedInTag:`
  failed; the test went on and recorded nothing more.
- "stops 0 stops": no Process stood at an error. This is not the shape of
  the tools test's fault (`docs/decisions/53-tools-test-fault.md`).
- The status says the browser has the define's reply.
  `ToolsProbe class>>definedInTag:`
  (`Tests/KajoCompilerTests/Fixtures/toolsprobe/ToolsProbe.class.st:377`)
  has three clauses: the class is in `Smalltalk`; `Smalltalk tagOf:` it is
  the tag; `browser model filesWritten` has `Probes/ToolsTagProbe.class.st`.
  The failure line prints none of the three, so which was false is not
  known.
- `until` waits 60 s. The test took 378.8 s. In 43 recorded passes under
  the sanitizer it took 26 to 42 s without the loops and 37 to 68 s with
  them (`~/kajo-scratch/*/check*/tsan*.txt`, `~/kajo-weekly/2026-11-16/`).
  Where the other 250 to 300 s went is not known: no step prints its time.
- The `ToolsTests` suite took 1581.7 s in that run, against 1270 to 1420 s
  in the runs the tools test's fault counted.
- The same morning the test passed `tsan` (27.0 s) and `swift-test-load`.
- It is the first `tsan-load` of this test on a commit that holds 0ef3b1f,
  outside that module's own count (0 of 3 runs of the bundle failed the
  tools test there; whether this test passed in those three is in
  `~/kajo-scratch/tools-test-fault/work/`: read it). 0ef3b1f runs
  `primDefineClass:` with `noteDefinition:` inside one `Smalltalk
  registry:` block. That is one candidate, not a finding: 1 failing run
  on one commit separates nothing.
- The earlier thin shape of this test is another one
  (`docs/decisions/43-optional-types.md`): the removal of the probe class
  refused once, "another Process holds ToolsTagProbe on its stack".

### B, the stall test

- The lines (`swift-test-load.txt:1561` to 1563, 1606, 2136):
  "Expectation failed: rt.vm.liveProcessCount == 0 ... → 1" at line 299,
  "stall-diag body theMainWorkerNeverStallsAndItsFallbacksNameIt s=191.4",
  "failed after 777.253 seconds with 1 issue". No other expectation of the
  test failed.
- The test runs a main-affine ring of 400 000 iterations (100 000 under
  the sanitizer) with the marker 16 times slower, driven by the test
  thread in 2 ms turns, until no Process lives or 180 s pass (900 s under
  the sanitizer). 191.4 s of body says the deadline ran out with the ring
  unfinished.
- The body's time in every `swift-test-load` on file (the plain build
  with twelve loops), oldest module first: 108.9, 124.1, 137.9, 117.4,
  120.9, 138.2, 110.4, 78.9, 130.9, 128.3, 141.2 in module gate runs; the
  weekly run of 2026-11-16 170.4; of 2026-11-23 191.4. In the weekly
  runs' plain `swift-test`: 97.1 and 148.4. The margin to 180 s was 5
  percent a week before it ran out.
- The marker's slowdown is proportional to CPU, and the deadline is wall
  clock. AGENTS.md has this lesson from the stall tests' follow-up, which
  moved the other stall tests to waits on the collector's progress
  (`StallDiag.waitProgress`). This test kept its deadline and prints
  nothing of where it stood when the deadline passed.
- Whether the body grows with the commits (a slower main worker, more
  full collections, more tests beside it in the suite) or with the load
  of the run it was in is not known.

## Starting positions

To be measured. Say where one was wrong.

1. A is a fault that is seen only under the sanitizer with load because a
   step is slow there, not because the sanitizer changes behaviour.
2. In A the false clause is the files' list, not the class or its tag.
3. A's 378 s hold a step that took minutes before `definedInTag:` was
   first asked, and that step is the fault or its cause.
4. A does not come from 0ef3b1f. (The main session has no evidence either
   way; the count decides.)
5. B is a deadline that ran out and nothing else: with no deadline the
   ring ends and every other expectation holds.
6. B's body grew with the suite beside it (more tests since the stall
   tests' follow-up), not with a slower VM: alone and unloaded its time
   is the same on the starting commit as on the stall tests' commit.
7. A and B have no common cause beyond a loaded machine.

## Parts

### Part 1: say what was false, count, force. Fix nothing.

Committed on its own before part 2.

For A:
- The failure line of a tools test's `until` says what the awaited probe
  saw. For `definedInTag:` that is each clause: the class present or not,
  its tag, the paths in `filesWritten`, and the browser's last reply's
  kind. Do it once for every `until` (a probe that can explain itself),
  not for this step alone, if that is small; say what you chose.
- Each step of this test prints its own time (as the stall tests print
  their body's), so that a slow run says where its minutes went.
- A rule, written and copied with its time before any counted run: the
  condition (the `tsan-load` gate's own for the compiler tests' bundle,
  or a smaller set with the suite's load: say which and why), the two
  commits (the starting commit and 381f57c, the commit before the tools
  test's fault changed the kernel; each from `git archive` with the new
  failure line patched in), the runs a side, interleaved, and how the
  counts will be read. A run of the bundle under the sanitizer and twelve
  loops takes about 48 minutes.
- A condition that brings the failure at will (a switch or a wait at one
  place, as `KAJO_TOOLS_HOLD_INSTALL` was), with its counts on both
  commits. If no condition is found, say what was tried and what each
  try showed.

For B:
- When the deadline passes, the test prints where it stood: the ring's
  progress if the program can say it, the turns run and their slices,
  the marker's cycles, the fallbacks by cause and requester, the main
  worker's share of a core, the load (the fields `StallDiag` prints for
  the other stall tests are the model).
- The body's time, five runs each, interleaved, on the starting commit
  and on the stall tests' follow-up's commit (find it in
  `docs/decisions/34-gate-speed.md`): the test alone unloaded, alone with
  twelve loops, and in the `KajoVMTests` bundle with twelve loops. The
  base against itself first for the spread. Read the table already on
  file (above) against it.
- The same with no deadline at all (by hand, not committed): does the
  ring end, in how long, and do the other expectations hold?

Part 1's hand-in is two short sections in this doc: for each test, what
was false, the counts, the condition, and each starting position right or
wrong.

### Part 2: fix each fault where it is

Decided from part 1.

- A fault in Smalltalk (`kernel/`, `tools/`, `types/`) or in the hosts
  outside the core is fixed there, with a test that fails on the starting
  commit, or a forced condition's counts before and after when no test
  can hold it.
- A fault in a test is fixed in the test, and the doc says why the test
  was wrong and what its claim needs. For B the house rule is the stall
  tests' own: a wait on the collector's progress that fails on a long
  quiet stretch and prints where it stood, or a smaller load if the claim
  needs less (the claim is "the main worker never stalls and its
  fallbacks name it", not a ring of a given length). Write down which the
  claim needs before changing anything.
- A cause under the core directories (`Sources/KajoVM/{ObjectMemory,
  Interpreter,Loader,Workers,Processes,Nursery,Marking,Relocation,
  YoungCollection,ObjectModel,Native}`, `Sources/KajoAOT`) is not fixed
  here: part 1's evidence is the deliverable for that test, and the
  module goes on with the other.

## Tests

- A: the forcing condition is a test where it can be one (a kernel or
  tools test that fails on the starting commit), otherwise a hand-run
  switch with its output kept. Each broken variant of a fix is run by
  hand and its failing output kept in `broken/`.
- B: the changed test passes five of five alone with twelve loops and in
  the bundle with twelve loops, and once under the sanitizer with twelve
  loops; its broken variant (the claim made false: a stall forced on the
  main worker, or a fallback charged to a stall) still fails, by hand.
- Every new or changed test runs once under ThreadSanitizer with the
  twelve loops before the tier.
- Each new test is said to fail on the starting commit, or to pass there.

## The bar

1. For A and for B: the clause or condition that was false, quoted from a
   failing run's own output.
2. A's count on both commits under the rule written first, and what the
   count can and cannot say.
3. A condition that brings each failure at will, with counts before and
   after the fix; or, for one not found, what was tried.
4. B's body times in the three settings on two commits, with the spread.
5. No wait lengthened without the claim's need written first; no retry;
   no assertion weakened.
6. `scripts/canonical-tonel.sh --check` lists nothing.
7. The tier `just check` names for the final commit, `failed=0`, and the
   changed tests once under the sanitizer with twelve loops.
8. The hand-back quotes one run of every switch and diagnostic added.

## Rules of the house that bind here

From AGENTS.md's lessons: a failure message prints every clause of the
condition it waited for; print a stopped Process's frames before naming a
suspect, and a brief's suspect is one candidate; a failure seen only in
the full suite is reproduced with the suite's load, not with busy loops
alone; a gate failure on a test the module did not write is counted on
both commits under a rule written first; a thin test is counted with the
head's own rate beside the start's; a natural count after a fix is not
the fix's evidence when the count before could be 0; a slowdown
proportional to CPU cannot sit under a wall-clock bound; a test checks
its claim, not everything that happens after it; a test's reported
duration is not its body's; a wall-clock assertion fails under load; an
inner wait longer than the outer one renames the failure; a rule is
committed or copied with its time before its numbers; `swift test`
writes to a file in blocks.

## Not in this module

- The core. The Delay timers' queue, the by-hand variants' runner, the
  reconnect test's margins, Symbols at eight workers, `removeSelector:`'s
  nil source and the type service's recheck error are other rows.
- The devices.
- The weekly run's script.

## Deliverables

- This doc with "As built": part 1's two sections, part 2, the gates,
  deviations, not done, found and not this module's, the open questions.
- The commits: part 1; A's fix; B's fix; the doc.
- Work files in `~/kajo-scratch/weekly-1123-failures/`.

## Open questions

Build the recommended option; bring the decisions back.

1. If A's count does not separate the two commits and no condition is
   found: recommended, keep part 1's diagnostics, record the counts and
   stop A there.
2. If B's ring is only slow: recommended, keep the ring's length and
   wait on progress, unless part 1 shows the claim is decided long
   before the ring ends, in which case end the test when the claim is
   decided.

## As built

Toolchain: swiftly's swift.org Swift 6.4.2 first on PATH, its `clang`
(`~/kajo-scratch/weekly-1123-failures/env.txt`). Every file named below
without a path is under `~/kajo-scratch/weekly-1123-failures/`.

### Part 1, A: the tag test (2026-11-23 and 24)

**The failure lines** (eeb07bb). `LocalTools.until` now says how long it
waited, how many probes ran and the longest, and each clause of its
condition from the probe's `...Why` companion (`ToolsProbe class>>explains:`
finds it): `definedInTagWhy:` (the class present, its tag against the one
wanted, the paths of the browser's `filesWritten`, its status), `readyWhy`
and `tagProbeRemovedWhy`, each followed by `replies:` (the milliseconds
since the define was sent, every pending request with its kind and age,
the define's replies and the last replies with their round trips). Chosen:
the general mechanism in `until` and companions for the three conditions
of this test and `ready`, which every tools test waits on; the other
`until` conditions have none and print "why none". The tag test prints
each step's time (`tools-tags <step> s= t=`) and, at its end, every reply
the client keeps with its round trip (`tools-tags replies`).

**What was false.** The weekly run's line printed none of the clauses, so
which one was false cannot be read from it, and no counted run failed
(below). What the line does say: after the 60 s the browser's status was
`'defined ToolsTagProbe'` with nothing pending, no stop stood, and every
check after the wait passed: the listing that requires
`Probes/ToolsTagProbe.class.st` on disk, the file's text, the move and the
removal. The client's request timeout is 30 s on a host timer, and the
reply is only dispatched by the tools' event loop, behind whatever the loop
was dispatching before it. The reading that fits every one of these is a
reply dispatched late: written by the host and answered by the target in
time, seen by the browser only at the end of the wait.

**The condition** (`KAJO_TOOLS_HOLD_LOOP=<ms>`, by hand): the next
`defineInTag:` first sends a `package.list` request whose reply holds the
event loop that long (a Delay in its dispatch), so the define's reply,
answered and written at once, is dispatched after it. With 70 000 ms, plain
build, eeb07bb (`part1/forced-A/plain-start-1.txt`):

    definedInTag: never held: waited 60.0 s, 3702 probes, longest 0.0 s; why class true tag #Probes want #Probes files #() status '' defineSentMs 60010 pending #(#('class.define' 60008)) defineReplies 0 ...

and the test went on exactly as the weekly's did: only that `until`
failed, the listing, the text, the move and the removal passed (the
define's round trip read 74 682 ms at the end). The false clause in the
forced run is the files list (`files #()`): the class and its tag are in
the image, the reply is not yet in the browser. Once in plain, before the
fix: 1 of 1 fails; the fix's counts are in part 2.

**The count** (rule written first: `part1/rule-A.txt`, copied
`rule-A.copy.txt` at 17:27:30): the whole package under ThreadSanitizer
with twelve loops, eeb07bb against eeb07bb with 381f57c's kernel, three
runs a side interleaved (`work/acount/run-{start,old}-{1,2,3}.txt`,
`summary.txt`): **start 0 of 3, old 0 of 3** failed the tag test; 0
sanitizer reports. The count separates nothing, as the rule said it would
at a rate near 1 in 15. In every run the test took 45.8 to 47.5 s; its
steps were the same on both sides: started 4.5 to 5.1 s, **ready 25.1 to
27.0 s** (the browser's first `class.hierarchy`, 23.5 s round trip),
the first define 4.6 to 5.7 s (its round trip 3.4 to 3.7 s), the move 1.0
to 2.2 s, the removal 5.0 to 5.5 s.

One run (old 3) failed another tools test with the new line,
`theToolsChooseThroughTheHostAndTheirChangesLandThere` (ProjectDirectoryTests:357):

    ready never held: waited 60.0 s, 985 probes, longest 17.0 s; why client true state #open browsers 1 hierarchy 0 defineSentMs -1 pending #() defineReplies 0 replies 1 last #(#('package.list' 19445)); client #open ... status 'class.hierarchy got no reply within 30000 ms'

Under the suite's load one probe took 17 s, a `package.list` round trip
19.4 s and the browser's first `class.hierarchy` ran out the client's own
30 s timeout. It is the same family as A (a step whose time is the tools'
share of the CPU) but a different failure: the request failed, so no wait
could have passed it. Counted: old 1 of 3, start 0 of 3; not this module's.

**Starting positions.** 1: right as far as can be shown: the forced
condition is a slow step and fails only this step, and the loaded runs show
steps of 25 s against the 60 s clock; the sanitizer changes no behaviour
that was found. 2: right for the forced run (`files #()`); not shown for the
weekly's run. 3: not shown: in the counted runs the long step before
`definedInTag:` is `ready` (25 to 27 s), and the weekly's 378.8 s has no
step times. 4: not decided by the count (0 of 3 on each side); nothing in
the forced reading involves 0ef3b1f's registry block (the define's round
trip was 3.4 to 3.7 s on both kernels). 7: right: B's cause (below) is the
main worker's share of a core in a loaded bundle, A's the tools' event
loop's; a loaded machine is all they share.

### Part 1, B: the main-worker stall test

**What was false**: `rt.vm.liveProcessCount == 0` → 1 at the loop's end,
body 191.4 s against the 180 s deadline (`swift-test-load.txt:1561`, 1606);
no other expectation failed. The test now prints where it stood when its
loop ends, whether it ended or not (`stall-diag main ...`: the turns, the
main worker's share of a core, its stops, the promotion, the collector's
counters, the fallbacks by cause and requester). In the loaded VM bundle
(`work/btimes/S3-*.txt`) the ring ran at a share of 0.34 to 0.51 of a core
and spent 30.8 to 61.4 s in its own stops, almost all of them the reserve's
two full collections (13 to 30 s each against 2.4 s alone); two fallbacks,
both by the main worker, in every run.

**Times** (rule `part1/rule-B.txt`, 17:28:07, amendments 1 and 2 before
their runs; bodies in seconds, `work/btimes/summary.txt`):

| setting | start against itself (10) | start (5) | 723b3fe (5) |
|---|---|---|---|
| S1 alone, unloaded | 16.8 to 17.8, median 17.0 (5.9 %) | 16.8 to 17.2 | 16.8 to 17.1 |
| S2 alone, twelve loops | 21.3 to 24.2, median 22.6 (12.9 %) | 22.2 to 24.1 | 22.2 to 24.6 |
| S3 VM bundle, twelve loops | 100.8 to 137.5 (5 runs) | 78.7 to 132.5 | 47.4 to 122.0 |

S3 over its ten start runs: 78.7 to 137.5, median 119.3; 723b3fe's median
117.3. The same in every setting within the base's own spread. The
whole package under the sanitizer with twelve loops (A's count): 199.4 to
275.2 s against its 900 s bound. On file: 78.9 to 141.2 in module runs,
170.4 and 191.4 in the two weekly runs (the whole package, after
`swift-test` on a warm machine).

**No deadline** (by hand, `part1/nodl.diff`): the VM bundle with twelve
loops 96.9 and 113.3 s, the whole package with twelve loops 125.9 and
79.9 s: the ring ended and every other expectation held in all four, two
fallbacks by the main worker each; none passed 180 s. Past 180 s the
evidence is the sanitizer build's six runs (199 to 275 s), which ended
with every expectation holding.

**Starting positions.** 5: right (the ring ends and nothing else fails;
past 180 s shown in the sanitizer build only). 6: right: alone and
unloaded the body is 17.0 s on both commits; it is the bundle beside it
that takes it to 47 to 138 s, through the main worker's share of a core
and its full collections' length.

Found, not this module's: `MainThreadTests.aTurnOverrunsItsBudgetByAtMostAFifthOfAMillisecond`
failed once in the ten start runs of S3 (`work/btimes/S3-base-5.txt`,
`found-overrun.txt`: `cpuOverruns.last! <= 0.2` false).

### Part 2: each fault in the test that held it (2026-11-24)

What each claim needs was written before any part 2 build or run
(`part2/claims.txt`, copied 04:37:52; B's test edit was drafted in the
working tree a few minutes before it, from part 1's numbers, and nothing
was built or run from it before the file). Both faults are in tests: a
wall-clock bound on a step whose time is a share of the CPU. Nothing under
the core directories, `kernel/`, `tools/` or `types/` changed.

**A** (dd7f4e9). `LocalTools.until` no longer puts a 60 s clock on the
whole step. It fails on a quiet stretch of 60 s, in which the local client
had no request pending and dispatched no reply (`ToolsProbe class>>activity`:
replies dispatched times 1000 plus requests pending, read at most once a
second), or after 300 s in all, and its line says which (`never held
(quiet, activity N)` or `(ceiling, ...)`). A pending request is ended by
the client's own 30 s timeout on a host timer, so a request that never
comes back still ends the wait within 60 s of the timeout; the 300 s bound
is for an event loop that never dispatches at all, "long everywhere" for
a thing that must come. A tools test whose until waits on a remote client
(no local one: activity -1) keeps the 60 s rule as it was. The 60 s quiet
bound, every assertion and every other wait are unchanged; nothing
retries.

Forced condition (`KAJO_TOOLS_HOLD_LOOP=70000`, plain, the tag test alone,
`part2/forced-A/`): before (eeb07bb's tree) **3 of 3 failed**, after
(the working tree at dd7f4e9's content) **0 of 3**, each about 78 s, the
first define's step 74.7 s. The broken variant (the pending clause left
out, `broken/A-nopending/variant.diff`, `run.txt`) fails as before:

    definedInTag: never held (quiet, activity 3001): waited 60.0 s, 3679 probes, longest 0.0 s; why class true tag #Probes want #Probes files #() ... pending #(#('class.define' 60049)) ...

The new test code fails on the starting commit in the sense that the
starting commit's `until` fails the forced condition 3 of 3; with no
forcing it passes there (0 of 3 counted runs, part 1). A natural count
after the fix is no evidence (the count before was 0 of 3).

**B** (eee63db). The loop ends when the ring does and fails only when the
collector has counted nothing (`StallDiag.progress`: stops, cycles,
stalls, young collections, read at most every 100 ms) for 120 s, 600 s
under the sanitizer, printing `stall-diag main QUIET quiet=...` and where
it stood; the ring's length and every assertion are unchanged. Passes
(bodies, `work/btimes/summary.txt` `after-*`): alone with twelve loops 5
of 5 (17.8 to 23.3 s), in the VM bundle with twelve loops 5 of 5 (69.6 to
127.6 s), and under ThreadSanitizer with twelve loops with the changed
tools suites (`part2/tsan/changed-load.txt`: 22 tests in 4 suites passed,
0 reports; B's body 74.6 s, the tag test 33.5 s). Broken variants by hand
(`broken/`): the ring on a background worker (`B-background`) fails
`(s?.all.count ?? 1) == 0` with 4 stalls; the main worker never driven
(`B-quiet`) fails `ended` after `stall-diag main QUIET quiet=120.1`. Both
are said to pass on the starting commit only in the plain sense: it has
no progress wait to test.

### Gates

`scripts/check-tier.sh --dry-run origin/master` on eee63db named the
**Swift tier** (3 of 4 files: the two test files and the probe fixture;
`check-dry-run.txt`). `just check origin/master` on eee63db
(`check/gates.log`, last line `2026-11-24 07:47:11 eee63db check-tier done
swift failed=0 4413s`): clean-build 19 s, swift-test 719 s (744 on 6fb8c5d,
the last Swift tier), tsan 3146 s (3352), kernel-test 126 s, apps 132 s,
new-check 271 s; in all 4413 s against 4646 s. Test counts 484 and 198 in
each test gate, 0 sanitizer reports. The Swift tier has no loaded gate, so
`swift-test-load` and `tsan-load` ran once each on eee63db through
`gl_gate` (`check-load/gates.log`): swift-test-load rc=0 829 s (951 s in
the weekly run), tsan-load rc=0 4156 s (3709 s in the weekly run), 484 and
198 tests each, 0 reports; B's body 85.0 and 204.6 s, the tag test 1.9 and
45.7 s. `scripts/canonical-tonel.sh --check` lists nothing.

### Deviations

- The count used the whole package (both bundles, as the gate), not the
  compiler tests' bundle alone: about 74 minutes a run against 48.
- S3's base against itself is five runs before the A/B's five of the
  start (ten in all), as the rule allowed.
- The no-deadline runs moved from twenty-four loops alone to the bundle
  and the whole package (amendments 1 and 2, written before their runs):
  twelve loops alone took the body to 22 s only. None passed 180 s.
- B's part 2 edit was drafted minutes before `part2/claims.txt` was
  written; nothing was built from it before.

### Not done

- A was never seen to fail naturally here (0 of 6 counted runs), so the
  weekly run's false clause is a reading (a reply dispatched late), not a
  quote; the forced condition and its 3 of 3 against 0 of 3 are the
  evidence. Which step took the weekly run's other 250 to 300 s is not
  known; the next natural failure prints each step's time and each clause.
- B's body was not measured past 180 s in a plain build (the four
  no-deadline runs ended at 79.9 to 125.9 s); past it, only the sanitizer
  build's runs (199.4 to 275.2 s) show the ring ending with every
  expectation holding.
- Every other `until` condition of the tools tests has no `...Why`
  companion yet (they print "why none").

### Found, not this module's

- Under the sanitizer with the suite's load the browser's first
  `class.hierarchy` took 23.5 s of the client's 30 s request timeout in
  every counted run (the tag test's `ready`, 25 to 27 s), and in one run
  (old 3, 381f57c's kernel) it ran out:
  `ProjectDirectoryTests.theToolsChooseThroughTheHostAndTheirChangesLandThere`
  failed `ready` with "class.hierarchy got no reply within 30000 ms". Counted
  1 of 3 on old, 0 of 3 on start. No wait can pass a request that failed;
  the request's 30 s under the sanitizer is a margin to decide.
- `MainThreadTests.aTurnOverrunsItsBudgetByAtMostAFifthOfAMillisecond`
  failed once in fifteen VM-bundle runs with twelve loops on the start
  (`work/btimes/S3-base-5.txt`).

### Open questions (built as recommended)

1. A's count did not separate the two commits, but a condition was found,
   so question 1's case did not arise as written: part 1's diagnostics are
   kept and the fix is in the test's wait (a quiet stretch, not a clock).
   Recommended: keep it.
2. B's ring is only slow (part 1: the main worker's share of a core and
   its own full collections; the same on 723b3fe). Built as recommended:
   the ring's length kept, the loop waits on the collector's progress. The
   claim is not decided early: its two fallbacks are the reserve's, and no
   stall must happen anywhere in the ring.
3. New: should the client's 30 s request timeout get a sanitizer value, or
   the opening `class.hierarchy` be made cheaper, given the 23.5 s round
   trips above? Recommended: count the round trip in the next weekly run
   (the tag test now prints it) before deciding.
