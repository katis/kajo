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
