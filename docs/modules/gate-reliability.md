# Gate reliability: a close that waits for ever, a kill that misses, a thin test

## Status

Brief. The owner, 2026-11-27, to "Do you want me to fix the two
gate-reliability faults first (the unbounded `closeOnce` wait with the
kill that missed the test process, and the thin random-programs test), or
go to user-visible work now?": "Fix both first". Starting commit: the
commit of this brief (the last code commit before it is 46f7510).

## What it is

Three faults that make a gate run fail, or hang, for a reason that is not
the change under test. All three are in `docs/decisions/57-known-faults.md`
as open and not briefed.

- A. `ShellVM.closeOnce` (`Sources/KajoVM/Shell/Shell.swift:457`) calls
  `vm.terminateAll()` and then `vm.waitUntilAllTerminated()`
  (`Sources/KajoVM/Workers/VM.swift:397`), an untimed wait for
  `liveProcesses` to reach 0. One loaded sanitizer run sat there for two
  hours.
- B. The gate's `gtimeout -k 60` ended that run, and the test process was
  not killed: its parent became launchd and it was found alive nine hours
  later.
- C. `randomProgramsAgreeWithTheirModelNatively` with the configuration
  `slowedMarker` asserts that at least one stall happened over its seeds
  (`Tests/KajoVMTests/Workers/RandomPrograms.swift:772`). It failed one of
  four loaded sanitizer gate runs on 46f7510.

A and C are separate faults; B is the gate scripts'. Each gets its own
evidence and its own commit. This is not a module that makes tests pass:
a longer wait, a retry or a weaker assertion is not a fix.

## What is known

Check each before building on it. The main session read these from the
files named; it ran nothing.

### A, the close

- The sample: `~/kajo-scratch/known-faults/hang/orphan/sample-70841.txt`.
  The test thread is in
  `ProjectDirectoryToolsTests.theToolsChooseThroughTheHostAndTheirChangesLandThere`
  (`Tests/KajoCompilerTests/ProjectDirectoryTests.swift:361`), in its
  deferred `LocalTools.close()`, in `closeOnce`, in
  `waitUntilAllTerminated`. Every VM thread waits on its condition: the
  workers idle, the marker and the young collector idle. So after
  `terminateAll` at least one Process was live and nothing was running it.
- Which Process, and in which state, is not known. The sample has no
  Smalltalk frames.
- It happened on 8efdf05, which had the registry fault 46f7510 fixed (a
  refused install signalled with `Smalltalk registry:` held). Whether that
  took part is not known.
- Not reproduced: the tools shard alone under the sanitizer and twelve
  loops, 8 of 8 passed, 643 to 654 s (`~/kajo-scratch/known-faults/hang/`,
  its `rule.txt`).
- The same test failed once before, on a `class.hierarchy` with no reply
  in 30 s (decision 55). That may be the same fault seen from the other
  side, or not.
- `closeOnce` has had this wait since module 9a. Shell-close
  (`docs/decisions/47-shell-close.md`) removed a different wait, the one
  for the pending-root count after `shutdown`.
- A product's app closes its shell too. A close that waits for ever is a
  quit that hangs.

### B, the kill

- `gl_gate` in `scripts/gates-lib.sh` runs
  `gtimeout -k 60 <bound> zsh -c "<cmd>"`. The command is
  `scripts/test-bundles.sh`, which starts each shard as
  `swift test --skip-build ...` in the background and has a trap that
  sends TERM to those pids. `swift test` starts the test helper.
- Which process survived (the helper, its pid's parent chain, its process
  group) was not recorded beyond "its parent became launchd".
- `swift test` writes to a file in blocks; the hung test's output was lost
  with the kill. The sample of the leftover was the only evidence.

### C, the thin test

- The line: "Expectation failed: randomScavenges.take(config) > 0",
  `~/kajo-scratch/known-faults/check-load-1/`. For `slowedMarker` the
  tally is `rt.vm.stallLog?.all.count` summed over the seeds
  (`RandomPrograms.swift:675`).
- Alone under the sanitizer and twelve loops it failed 0 of 5 on 46f7510
  and 0 of 5 on 7ba9643, 60 to 74 s a run against 220 s in the gate
  beside the other shards (`~/kajo-scratch/known-faults/thin/`). Alone is
  not the gate's condition.
- The interpreted twin asserts the same at line 732 and has not been seen
  to fail. Why the native one is thinner is not known (a faster mutator
  ends a small program before the slowed marker makes it stall, or fewer
  seeds, are readings).
- Recorded as thin since the third review's small fixes, part 2
  (`docs/decisions/52-review-3-small-fixes-part-2.md`).

## Starting positions

To be measured. Say where one was wrong.

1. A: the live Process is one that only a host turn can run (a
   main-affine Process, or one whose unwind needs worker 0), and the
   closing thread is the thread that would give the turn. Then the wait
   can never end, load or no load, and a forcing test is short.
2. A, the other reading: a Process's unwind block waits on something no
   one will signal after `terminateAll` (a Semaphore, a Mutex whose owner
   was terminated, a request with no reply).
3. A's fix: `close` waits while termination makes progress, and when
   nothing has changed for a bound it says which Processes are live (id,
   state, priority, the top frames), shuts down and destroys anyway, and
   `ShellCloseReport` counts them. A count above 0 fails the test that
   closed. If part 1 shows a cause that can be removed (position 1), the
   cause is removed as well; the bound stays as the net.
4. B: `gtimeout` signals its own process group and `swift test` or the
   helper is in another one. The fix is in `gates-lib.sh`: before the kill
   and after every gate, the gate's descendants are known by pid, any that
   outlives the gate is sampled into the gate's output directory, then
   killed by pid, and the gate's line in `gates.log` says `leftover=<n>`.
5. C: the stall is reached by driving, as the stall tests do
   (`setMarkerSlowdown`, `StallDiag`): the marker stays slowed until a
   stall is counted, then runs. Not by more seeds or more rounds.

## Parts

1. Measure and instrument; build nothing else.
   - A: the instrument that names the live Processes when the close has
     been quiet for a bound (it may print only, in this part). Then a
     forcing condition: try position 1 and 2 as short tests, and the tools
     shard beside the other shards under the loaded sanitizer (the gate's
     own condition) with a watcher that samples at 1500 s. Rule written
     and copied with its time before any count.
   - B: reproduce the miss with a stand-in (a test that waits for ever,
     under `test-bundles.sh` through `gl_gate` with a short bound) and
     record the survivor's pid, parent and process group.
   - C: in passing loaded sanitizer runs of the random shard beside the
     others, the stalls per seed and the seed count, interpreted and
     native; then the condition that makes the native sum 0 at will.
2. A: the fix, with its tests.
3. B: the fix, with `check-tier-test.sh`.
4. C: the fix.
5. The gates.

## Tests

- A: the forcing test of the cause part 1 finds (fails on the starting
  commit, by hang bounded by its own watchdog, or by the new report). A
  test that a close with a Process that cannot end returns within the
  bound, reports it and frees the VM. The broken variant puts the untimed
  wait back (by hand, its output kept).
- `ShellVM`'s table test (`ClosedShellCallsTests`) still passes; any new
  public member has its row.
- B: `check-tier-test.sh` has a stand-in gate whose child outlives the
  kill, and asserts the sample file, the `leftover=` field and that the
  pid is gone.
- C: the test fails at will on the starting commit under the condition
  part 1 finds, and passes under it after. The assertion `> 0` stays.

## The bar

1. A close cannot wait for ever: the bound is in the code, its test is in
   the suite, and the report names the Processes.
2. The cause of the hang is named with a forcing test, or the record says
   it is not known and what the instrument will print the next time.
3. After any gate, no process the gate started is alive; a survivor is
   sampled, killed and counted.
4. C: forced before, 0 after, counts under a rule written first.
5. The tier `just check` names on the final code commit: `failed=0`.
6. `tsan-load` three times on the final code commit: three passes. A
   failure on a test that is not this module's is counted on both commits
   under a rule written first, and said first in the hand-back.
7. Kajo's processes checked dead at the end.

## Rules of the house that bind here

From `AGENTS.md`'s lessons: a wait is checked for who can make its
condition true; an operation that can fail quietly answers what it did; a
gate's kill is checked by pid for the test process, and a leftover is
evidence before it is a leftover; a failure seen only in the full suite is
reproduced with the suite's load; a test that asserts an edge was crossed
drives the system to the edge; a slowdown proportional to CPU cannot sit
under a wall-clock bound; a wait loop on `pgrep -f` waits for itself; a
changed gate script is run once on its own before the gate run; `status`,
`path` and `argv` are zsh's; a fix for a failure that was not reproduced
is recorded as a reading; idle threads wait untimed (the close's bound is
a wait on the closing thread only while it closes; no VM thread gains a
timed wait).

## Not in this module

- The turn profile by phase.
- The Delay queue, the Symbol table, anything of decision 57 that is
  closed.
- A tier size for the VM tests under the sanitizer.
- Anything user-visible beyond the close's report.

## Deliverables

The commits; this doc's "As built"; the forcing tests; the changed gate
scripts with their test; the raw outputs under
`~/kajo-scratch/gate-reliability/`.

## Open questions

Build the recommended option; bring the decisions back.

1. When the close's bound runs out: destroy anyway and report
   (recommended), or leak the VM and report.
2. The bound: quiet time with no Process ending (recommended, 5 s plain;
   a sanitizer value of its own if a measurement asks for one), or a
   clock on the whole close.
3. A change in `Sources/KajoVM/Workers/` makes this a core module (the
   matrices, the A/B). Recommended: keep the change in `Shell/` if the
   wait can be bounded from there with what `VM` already offers; if it
   cannot, take the core tier and say so.
4. A leftover after a gate: fails the gate (recommended), or is a line
   only.
5. The lost block-buffered output: leave it, with the sample as the
   evidence (recommended), or run the shards under a pseudo-terminal.

## As built

Built 2026-11-27 by one build agent from 71f2706, swift.org 6.4.2 through
swiftly first on PATH (`swift` and `clang` both
`~/.swiftly/bin`). Work files and every raw output:
`~/kajo-scratch/gate-reliability/`.

### Part 1: measured, instrumented, reproduced (before any fix)

**A, the close.** The instrument: `Sources/KajoVM/Shell/CloseWait.swift`.
`VM.liveProcesses()` reads every live Process inside the VM under the
scheduler lock (id, state, priority, affinity, the worker running it,
whether a termination is requested, the class of what it waits on, its top
eight frames), and `waitUntilAllTerminatedReporting(quietNs:)` replaces the
close's untimed wait: still unbounded in this part, it wakes on the done
condition or every 20 ms on the closing thread only, and after 5 s with no
termination and no change in the live count prints the live Processes on
stderr once (`kajo-close-wait`). `KAJO_CLOSE_TRACE=1` prints each close's
wait (`kajo-close-trace waited=<ms>`).

How the host terminates (read in `Processes/Scheduling.swift`): a ready or
waiting Process ends at once, with no unwinding; a running one is asked to
and ends at its next budget check, every 1024 polls. `VM.terminateAll` takes
one snapshot of the live records and terminates those. A Process made after
the snapshot is terminated by nobody.

Five shapes (`Tests/KajoCompilerTests/CloseWaitTests.swift`), each a close on
a thread of its own with a watchdog of 120 s, under `part1/A/rule.txt`
(17:52:11, copied with its time), five plain runs on a scratch tree of
71f2706 with only the test file added (`part1/A/start.out`, `start/`) and
five on the instrumented tree (`head.out`, `head/`):

| shape | start: close did not return | head |
|---|--:|--:|
| Processes waiting for ever, one inside a Mutex (position 2) | 0 of 5 | 0 of 5 |
| main-affine Processes, one never run, one waiting (position 1) | 0 of 5 | 0 of 5 |
| a running Process forking waiters in rounds of 50 | **5 of 5** | 2 of 5 |
| a running Process forking main-affine Processes | 1 of 5 | 1 of 5 |
| a Mutex held by a Process the close terminates, waiters forked late | 3 of 5 | 1 of 5 |

Forced under the rule: the forking waiters. In every hang the instrument
named only Processes made after the snapshot: 35, 6 and 1 waiters
`waiting ... waitingOn=Semaphore frames=[UndefinedObject>>[] <
BlockClosure>>forkedValue]`, 11 `ready ... main ... (not started)`, and one
`waiting ... frames=[Mutex>>[] < BlockClosure>>ensure: < Mutex>>critical: <
...]` behind a Mutex whose owner the close had terminated inside its
critical block. Starting positions 1 and 2 are wrong as causes on their own:
the host ends a waiting or a main-affine Process at once, turn or no turn.
They take part only with a Process made after the snapshot (a main-affine
one no turn will run, a waiter on a Mutex left held). The tools' path has
that shape: `DevProtocol serve` forks a request Process per request, which
takes the protocol's lock first, and a request Process forks the reaper.
Which Process the hung tools test waited for is still not known: a flood of
300 requests in ten shells closed while the protocol took them returned 10
of 10 (`part1/A/protocol-head-run1.txt`, plain, no load).

**B, the kill.** A stand-in package (`work/hangpkg`: a suite `ToolsTests`
whose one test sleeps for ever and writes its pid, parent and process group)
under the real `scripts/test-bundles.sh` (`KAJO_SWIFT` names
`scripts/hang-swift.sh`, the real swift over that package) through
`gates-lib.sh`'s own `gl_gate` with a bound of 60 s
(`scripts/b-repro.sh`, `part1/B/start.out`): the gate ended rc=124 at 60 s,
and the test helper (`swiftpm-testing-helper`) was alive afterwards with
parent 1 and its own process group (`pid=72358 ppid=72343 pgid=72358`
when it started under `swift test` 72343; after the gate `72358 1 72358`).
Starting position 4 is right: `swift test` starts the helper in a process
group of its own, and `gtimeout` signals its own group only. The survivor
was killed by pid.

**C, the thin test.** Instrumented with prints in
`Tests/KajoVMTests/Workers/RandomPrograms.swift`: every slowedMarker seed's
stalls with its engine and time, and each test's start and take. The first
exploration (`part1/C/explore-1.txt`, plain, both tests side by side as in
the random shard, 10 seeds each) found the cause, which is neither of the
brief's readings: `randomScavenges` is one tally keyed by the
configuration's name, shared by `randomProgramsAgreeWithTheirModel` and
`randomProgramsAgreeWithTheirModelNatively`, which Swift Testing runs side
by side. The interpreted test's take read 83 (its own 52 and the native's
first five seeds' 31) and the native's take 19. Whichever ends first empties
the key and the other sums only its seeds after that; the native fails when
its seeds after the interpreted take stalled 0 times. Alone (the known
faults' count) nothing takes from it. Starting position 5 is wrong: nothing
has to be driven; the seeds stall.

Counted under three rules, each written and copied before its runs
(`part1/C/rule.txt` 17:56:58, `rule-2.txt` 18:16:55, `rule-3.txt`): native
seeds 81 to 84 stall 3, 0, 0, 0 (`explore-native100.txt`), and the
interpreted twin's seed count places its take inside the native's run.

| condition | start: native fails | head | the native alone on start |
|---|--:|--:|--:|
| F: KAJO_SEEDS=3 | 2 of 5 | 1 of 5 | 0 of 3 |
| F2: KAJO_SEEDS=7 | 0 of 5 | 0 of 5 | 0 of 3 |
| F3: KAJO_SEEDS=5 | 3 of 5 | 4 of 5 | 0 of 3 |

No condition reached the rules' "forced" (4 of 5 on start); rule 3 said no
fourth would be tried. The race is shown by the prints:
`part1/C/head/run-5.txt` (native seed 81 added 3, the interpreted take read
8 nine milliseconds later, the native take 0) and `f2-head/run-1.txt` (the
other direction: the native take read 19, the interpreted take 2). Under F2
the interpreted test is the one at risk, which is why it was never seen to
fail: its later seeds stall.

The loaded sanitizer run of part 1 (`part1/tsan-load/`, the gate's own
`tsan-load` through `gl_gate` on 22fb102 with the forcing tests in the tree
and the sampling watcher, `KAJO_CLOSE_TRACE=1`): rc=1 in 2620 s, 0
sanitizer reports; the forcing test of the forking waiters hung its close
(the instrument named 20 waiters forked after the snapshot), the watcher
sampled only the VM and compiler shards' long runs, and the tools shard did
not hang. 89 closes waited p50 1.0 ms, p99 143 ms, at most 253 ms: a quiet
bound of 5 s needs no sanitizer value of its own. A second failure in it is
fault C's other direction: the interpreted
`randomProgramsAgreeWithTheirModel` with `exhaustedReserveOffload` read
"taken > 0" false. The native test's first `take` of a configuration
empties the interpreted test's sum of the same configuration while it runs;
a reading (no print for that configuration), the same shared key.

### Part 2: A, the close (its own commit)

`ShellVM.close` no longer calls `VM.terminateAll` and the untimed
`waitUntilAllTerminated`. `VM.terminateAllAndWait(quietNs:)`
(`Shell/CloseWait.swift`, the closing thread only) terminates in rounds:
each round takes the live records and terminates every one in one entry
into the VM (`terminateLive`, so no collection frees a Process between the
snapshot and its termination), then waits up to 20 ms on the done condition.
A Process made after a round is terminated by the next. It ends when none
is alive, or when for the quiet bound (`ShellVM.closeQuietSeconds`, 5 s) no
Process has ended and the live count has not changed; then it answers the
Processes still alive, the shell prints them on stderr ("kajo: close gave up
after 5.0 s with no Process ending; N alive, destroyed anyway"), shuts down
and destroys anyway. `ShellCloseReport` gained `liveProcesses` (a
`ShellLiveProcess` each: id, state, priority, main affinity, worker,
termination requested, what it waits on, top frames) and `lateProcesses`
(made after the first round, terminated by a later one). In the test bundle
a report naming a live Process records an issue for the test that closed
(`ShellVM.liveAtCloseHook`, installed by `openShell` and `LocalTools`;
`expectsLiveAtClose` exempts the bound's own test). No VM thread gained a
timed wait; nothing under the core directories changed.

The same one-snapshot-and-an-untimed-wait was at two ends of a headless run
(`kajo test` after its entry point answered, and a resumed image's run in
`Headless.swift`); both now call `VM.endAllProcesses`, the same rounds and
bound, which says on stderr what it gave up on.

Not bounded: `VM.shutdown` joins the worker threads, and a worker held in a
host callback (primitive 164's client op, a blocking region) is joined when
the callback returns. The bound's test shows it: the close gave up at 0.5 s
and returned at 3.0 s, when its callback let go.

Tests (`Tests/KajoCompilerTests/CloseWaitTests.swift`): the five shapes now
assert the close returns, destroys and leaves no Process alive; plain, 14 of
14 with `ShellCloseTests` and `ClosedShellCallsTests`
(`work/after/A-tests-1.txt`): "forking waiters: 0.028 s ... lateProcesses=4
liveProcesses=0", and the bound's test
`aCloseWithAProcessThatCannotEndGivesUpAndSaysWhich`: "close-bound: 3.014 s
destroyed=true ... liveProcesses=1; process 1 running priority=1 runningOn=1
terminateRequested frames=[]". The broken variant (`KAJO_BROKEN_CLOSE_WAIT=1`,
`ShellVM.brokenUntimedWait`, the starting code's wait, by hand,
`broken/A-untimed-wait.txt`): "forking waiters: close did not return in 120
s; 32 live: process 164 waiting priority=1 runningOn=-1 waitingOn=Semaphore
frames=[UndefinedObject>>[] < BlockClosure>>forkedValue]; ...". Starting
position 3 is built with the cause removed (rounds) and the bound as the net.

### Part 3: B, the kill (its own commit)

`gl_gate` (`scripts/gates-lib.sh`) runs each gate with
`KAJO_GATE_TAG=kajo-gate-<gate>-<pid>-<time>-<random>` in its environment,
which every process it starts inherits whatever its parent or process group
becomes. After the gate `gl_leftovers` finds the live processes that carry
the tag (`ps -wwE`, seen twice 2 s apart so an exiting one is not counted),
writes a `leftover <gate> pid= ppid= pgid= command=` line to `gates.log`,
samples each into `<out>/leftover-<gate>-<pid>.txt`, kills it by pid (TERM,
KILL after 10 s), and the end line ends `leftover=<n>`. A leftover fails a
gate that passed (open question 4, as recommended). `gl_cleanup` (a tier or
weekly run interrupted) does the same for the gate running. The block-
buffered output is left as it is (question 5): the sample is the evidence.

The reproduction again with the fix (`work/after/B.out`): "leftover
hang-standin pid=83882 ppid=1 pgid=83882 command=.../swiftpm-testing-helper
...", "end hang-standin rc=124 67s leftover=1", the sample file written, and
nothing of the stand-in alive afterwards. `scripts/check-tier-test.sh` has
the stand-in (a child that leaves for a session of its own and sleeps):
killed at the bound, a gate that exits 0 and leaves it, and a gate that
leaves nothing; 136 checks ok (`work/after/check-tier-test.txt`). The same
three checks against the starting `gates-lib.sh`
(`broken/B-start-gates-lib.txt`): all three fail ("end leftover-killed
rc=124 3s" with no count; the child was killed by the test's own cleanup).

Before the tier, through `gl_gate` on d4126d4 (`work/pre/gates.log`):
`ios-check` rc=0 16 s leftover=0 ("warnings=0 errors=0"; the close's wait
adds `pthread_cond_timedwait_relative_np`), `apps` rc=0 140 s leftover=0
(xcodebuild leaves nothing tagged behind).

### Part 4: C, the thin test (its own commit)

The native engine's random programs keep their own tally,
`randomScavengesNative`, beside the interpreter's `randomScavenges`;
`runRandom` adds to the one of its engine and each test takes only its
own. The assertion `> 0` is unchanged; nothing is driven, no seed added.
After (`work/after/`, plain, the conditions of part 1's three rules):

| condition | native fails after | interpreted fails after | the native alone |
|---|--:|--:|--:|
| F | 0 of 5 | 0 of 5 | |
| F2 | 0 of 5 | 0 of 5 | |
| F3 | 0 of 5 | 0 of 5 | 0 of 3 (passes 3 of 3) |

The native take now reads its own seeds' sum (F3: 4, 5, 3, 5, 4, against 0
in the failing runs before). The same fix covers the interpreted
`exhaustedReserveOffload` failure of the part-1 loaded run (the native's
first take of a configuration no longer empties the interpreter's). Under
the bar's item 4, F3 is the condition of record: 3 of 5 before on 71f2706
(not "forced" by the rule's 4 of 5), 0 of 5 after.

### The gates (part 5)

`scripts/check-tier.sh --dry-run origin/master` on 9dd2536
(`check-dry-run.txt`): "tier: swift", chosen by 10 of 11 files (the doc the
eleventh), fuzzers none. `KAJO_CHECK_OUT=~/kajo-scratch/gate-reliability/check
just check origin/master` on 9dd2536 (`check/gates.log`): "check-tier done
swift failed=0 3494s", every gate rc=0 and leftover=0, swift.org 6.4.2
(`check-env.txt`):

| gate | s | check time's Swift tier (1a68580) |
|---|--:|--:|
| check-tier-test | 30 | 7 |
| clean-build | 20 | 18 |
| swift-test | 305 | 453 |
| tsan-load | 2612 | 2643 |
| kernel-test | 127 (271 of 271) | 125 |
| apps | 128 | 141 |
| new-check | 272 | 269 |

`check-tier-test` is 23 s longer by the three leftover checks (each
leftover is sampled for 5 s and seen twice 2 s apart). Each test gate's
bundles: 486 + 3 + 2 + 168 + 39 tests (the compiler shard 162 before; the
six close tests). 0 "WARNING: ThreadSanitizer"; no THIN or PAST margin.

The bar's three loaded sanitizer runs on 9dd2536 (`check-load-1..3/`, each
through `gl_gate` with the sampling watcher, `scripts/three-load.sh`):

| run | rc | s | reports | THIN or PAST | slowedMarker takes (interpreted, native) | leftover |
|---|--:|--:|--:|--:|---|--:|
| the tier's | 0 | 2612 | 0 | 0 | 54, 58 | 0 |
| check-load-1 | 0 | 2580 | 0 | 0 | 48, 52 | 0 |
| check-load-2 | 0 | 2669 | 0 | 0 | 58, 67 | 0 |
| check-load-3 | 0 | 2659 | 0 | 0 | 57, 52 | 0 |

In all four the only "close gave up" line is the bound's own test's (0.5
s, one Process). The watcher sampled only the VM and compiler shards' long
runs (four a run). After them nothing of Kajo was alive (`kajo`,
`swift-build`, `swift-test`, `swift-package`, `swiftpm-testing-helper`,
`xcodebuild`, `KajoShell`, `Sample`, `yes`, `fuzz-*`, `clang`, `gtimeout`).

### Starting positions

1. Wrong as a cause on its own: the host ends a ready or waiting
   main-affine Process at once; one takes part only when it is made after
   the snapshot (forking main: 1 of 5 before).
2. Wrong on its own for the same reason (the host does not unwind; a
   waiter is ended at once). Right as a part: a Mutex left held by a
   Process the close terminated inside its critical block, waited on by a
   Process made after the snapshot (held mutex: 3 of 5 before).
3. Built, with the cause removed as well (termination in rounds) and the
   bound as the net; 5 s plain, no sanitizer value (the longest close under
   the loaded sanitizer waited 253 ms in all).
4. Right: the helper `swiftpm-testing-helper` runs in a process group of its
   own and was orphaned to launchd. Built with a tag in the environment
   instead of a walk of descendants, since the parent link is gone by the
   time the gate ends.
5. Wrong: the stalls happen; a second test emptied the tally. Nothing is
   driven.

### Decisions (open questions, built as recommended)

1. The bound runs out: the close destroys anyway and reports (as
   recommended), and in the test bundles a report with a live Process
   fails the test that closed.
2. The bound is quiet time with no Process ending, 5 s (as recommended);
   no sanitizer value, from the measurement above.
3. The change stayed in `Shell/` (and `Headless.swift`, not a core
   directory): tier swift (as recommended). `VM.terminateAll` and
   `VM.waitUntilAllTerminated` are unchanged; the rounds are built from
   what `VM` already offers (`terminateProcess` in one host entry).
4. A leftover fails the gate (as recommended).
5. The block-buffered output is left as it is (as recommended).

### Deviations

- The close's fix removes the cause by terminating again in rounds. It is
  not a retry of something that may fail: each round terminates Processes
  no earlier round could have seen, and the wait still ends on a quiet
  bound. Said here because the prompt forbids an added retry.
- `kajo test`'s and a resumed run's ends got the same rounds and bound
  (`VM.endAllProcesses`): the same one-snapshot-and-untimed-wait, found by
  grepping for the class of the fault. Not in the brief.
- Fault C had a second instance the brief did not name: the interpreted
  `exhaustedReserveOffload` failed in the part-1 loaded run for the same
  shared tally; the one fix covers both.
- The part-1 commit's `CloseWait.swift` used `String(format:)`, which
  strict memory safety warns about on a clean build; the A commit removed
  it. Only the final commit's clean build was gated (0 warnings).
- C's forcing reached 3 of 5 before, under the third rule written; not the
  rules' "forced" (4 of 5).

### Not done

- Which Process the hung tools test waited for on 8efdf05 is not known.
  The mechanism the forcing tests show (a Process made after the snapshot,
  a Mutex left held) is that test's shape, but its run was not reproduced.
  If a close gives up again, the line "kajo: close gave up ..." on stderr
  and the report's `liveProcesses` name each Process with its frames.
- `VM.shutdown`'s join of a worker held in a host callback is not bounded.
- `VM.endAllProcesses`'s give-up line was never printed by a run (no
  headless run gave up).

### Found, not this module's

- `VM.terminateAll` itself still takes one snapshot; its other callers
  (tests' cleanup after a failure in `RandomPrograms.swift`) wait with
  their own bounds.
- `check-tier-test` takes 30 s now against 7 s: the three leftover checks
  sample a process for 5 s each time and wait 2 s to see it twice.
