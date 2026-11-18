# A closed shell frees its VM

## Status

Briefed by the main session on 2026-11-18. The owner approved the follow-up
on 2026-11-18 (the Delay fix's question 4,
`docs/decisions/46-delay-outlives-vm.md`: "Yes, brief it"). Starting commit:
the commit that adds this file. Not started.

## What it is

`ShellVM.close` waits for something that cannot happen and then leaks the VM
and its image. This module makes `close` free the VM at once, and adds the
test that fails without the change.

It is a fix in the host surface (`Sources/KajoVM/Shell/`). It adds no
feature and changes no file under the core directories.

## What is known

- `ShellVM.close(timeoutSeconds:)` (`Sources/KajoVM/Shell/Shell.swift`)
  terminates every Process, calls `vm.shutdown()`, unregisters the bridge's
  two Semaphores, and then polls `vm.pendingRootCount` every 5 ms for up to
  3 s. If the count is still above the finalization root's, it returns
  without `vm.destroy()` and `image.destroy()`.
- A pending root is released by the drain of its signal. After `shutdown`
  no worker drains. So the count cannot fall, and every close with a Delay,
  an event's signal or a request's signal pending waits the whole 3 s and
  leaks.
- The wait's reason is in its comment: "they would signal a freed VM". Since
  the Delay fix (075d2a4) that is no longer true. Every `VMRef` call and
  every Delay timer runs under `VMLife`'s lock, and `VM.destroy` ends the
  VM under that lock before it frees anything. `VMEndReport` counts
  `timersPending` and `undeliveredSignals`.
- Who calls `close`: `ShellVM.deinit`, `DevTarget` in
  `Sources/KajoDev/Target.swift` (four calls), `kajo` (`target.close()`),
  and tests through `DevTarget`. The apps' hosts hold their `ShellVM` for
  the life of the process.
- The Delay fix's hand-back also found that `ShellVM`'s other host calls
  (`spawn`, `liveProcessCount` and the rest) do not check `closed`. That is
  not this module (below).

## Starting positions

Each is the main session's belief, to be read or measured in part 1 and
answered as right or wrong.

1. The leak is shown on the starting commit by one small test: a started
   `ShellVM` with one Process waiting on a long Delay is closed. `close`
   takes its whole timeout and the VM is not destroyed. The test must not
   assert on wall-clock time; it reads what `close` did (position 3).
2. With the wait removed, `close` is safe against every thread that can
   still reach the VM: a Delay's timer, a bridge post from the host or
   from `ClientHost`'s timer, a protocol request. Each either ran before
   the end or is refused by `VMLife`. Part 1 lists each path and says
   which lock or which line of `close` covers it.
3. `close` has no way to say what it did, so the leak was invisible for
   months. It answers a report: whether the VM was destroyed, and the
   `VMEndReport`'s `timersPending` and `undeliveredSignals`. The report is
   a `Sendable` value with no oop in it. `deinit` ignores it.
4. The `timeoutSeconds` parameter has no use left and goes. Every caller
   passes none (check this).
5. Nothing in `Processes/`, `Workers/` or any other core directory needs
   to change. If something there does, stop and say so before changing it:
   the module would then owe the core tier.
6. A `DevTarget` closed with a request in flight, and one closed while its
   client's reconnect timer is pending, still pass their tests; several of
   those tests have been closing through the 3 s wait without knowing.
   Expect some tests to get faster. Report the suite's time against the
   baseline.

## Parts

1. **Read and reproduce.** Answer positions 1, 2, 4 and 5 from the code.
   Write the reproducing test and show it failing on the starting commit
   (three runs). Count how many closes in the existing suites take the
   leaking path today (a temporary counter or log line, removed after),
   and say how many VMs a full `swift test` run leaks. Commit the doc's
   "Part 1" section and the test before any fix.
2. **The fix.** `close` destroys at once after `shutdown` and the
   unregistering. The comment is rewritten to say what is true.
3. **The report.** As position 3, unless part 1 finds a better way to
   make the outcome visible.
4. **The callers.** `DevTarget` and `kajo` read the report where it is
   useful (a development target may log undelivered signals; decide and
   say). No caller may depend on the old wait.

## Tests

- The reproducing test: fails on the starting commit, passes after.
- A close with an event posted and not yet taken, and a close with a
  protocol request queued: destroyed, the counts as expected.
- A close racing posts from another thread (a gate start, as the interning
  tests do it), under the sanitizer in the gates: no report, every post
  either taken or refused.
- `close` twice, and `close` then `deinit`: destroyed exactly once.
- A broken variant: the old wait put back by a test switch or an
  environment variable, failing the reproducing test's named check (it
  does not trap, so it can be a switch in the suite if that is cheap;
  otherwise by hand with its output recorded).
- Run the new suite once under the sanitizer with a dozen busy loops
  before the tier's run.

## The bar

- The reproducing test fails on the starting commit and passes on the fix.
- No `close` in any suite leaves a VM undestroyed (the part 1 count reads
  0 after the fix).
- The Swift tier through `just check <starting commit>`, every gate
  `rc=0`, on the final code commit. `Sources/KajoVM/Shell/` is not a core
  directory; `check-tier.sh --dry-run` on the diff must say "tier: swift".
  If it says "core", stop and report.
- `swift-test` and `tsan` times against
  `~/kajo-scratch/types-2/check/gates.log` (the last Swift-tier run), with
  what the new tests cost and what the removed waits saved.
- No new `unsafe` outside `Sources/KajoVM`; the count of lines naming
  `unsafe` before and after.

## Rules of the house that bind here

- A wait is checked for who can make its condition true (the lesson this
  module comes from).
- A descriptor closed twice closes someone else's: `close` stays
  idempotent and the test asserts exactly one destroy.
- A wall-clock assertion fails under load. No test asserts that `close`
  was fast.
- A hand-back quotes one run of every switch and mode the module adds.
- `docs/PROCESS.md` binds in full: no push, no edit of `AGENTS.md` or
  `docs/PLAN.md`, files added by name, work files in
  `~/kajo-scratch/shell-close/`, the weekly log read before any gate.

## Not in this module

- Checks of `closed` in `ShellVM`'s other host calls (the second finding).
  It is an open question below.
- Any change to `VMLife`, `startDelay` or `VM.destroy`.
- A counter on the run line.
- Device runs. No device path changes: the apps never close their VM.

## Deliverables

- The doc's "Part 1" and "As built" sections, with the answers to the six
  positions.
- The fix, the report and the tests, in commits by part.
- `~/kajo-scratch/shell-close/check/gates.log` for the final code commit.
- A hand-back: commits, each position right or wrong, the leak count
  before and after, the gates' table against the baseline, deviations,
  not done, found, open questions.

## Open questions

1. Should `ShellVM`'s host calls refuse after `close`? Recommended: decide
   after this module, when `close` is known to free the VM every time; a
   call after it then reads freed memory for certain, and a precondition
   with a message is the smallest answer.
2. Should a development target log undelivered signals at its close?
   Recommended: no line unless the count is above zero.

## Part 1

Built by the build agent from 5778e78 on 2026-11-18, swiftly's swift.org
6.4.2 toolchain first on PATH. Raw outputs in
`~/kajo-scratch/shell-close/part1/`.

### The reproducing test

`Tests/KajoCompilerTests/ShellCloseTests.swift`,
`aShellClosedWithADelayPendingFreesItsVM`: a started shell (two workers)
runs `(Delay forSeconds: 60) wait` on a background worker; once the Delay's
timer is armed (`VM.timersPending == 1`, a bounded wait for something that
must come) the shell is closed. The check reads the VM's life cell, held by
the test before the close: `VMLife`'s `ended` is set by `VM.destroy` and by
nothing else, and the cell outlives the VM, so the test reads what `close`
did without a clock and without touching freed memory. On 5778e78 it fails
3 runs of 3 (`repro-run{1,2,3}.txt`):

    Expectation failed: life.snapshot.ended
    ↳ close left the VM undestroyed
    Test aShellClosedWithADelayPendingFreesItsVM() failed after 4.715 seconds with 1 issue.

(4.700 and 4.712 s in the other two: the 3 s wait is in each.)

### How many closes leak today

A temporary log line in `close` (`part1/instrumentation.diff`, not
committed; `KAJO_CLOSE_LOG`) wrote each close's outcome, its pending count
and its caller, and every host call made after `close` had begun. One full
`swift test` on 5778e78 with it (`swift-test-before.txt`,
`close-log-before.txt`; 471 and 177 tests, the new test the only failure):

- 61 closes: 27 destroyed (none of them waited: their pending count was
  already at the finalization root's), **34 leaked**, the new test's one
  included. So a full `swift test` leaks **33 VMs and their images** on
  5778e78, each after a 3 s wait: 102.1 s of waiting in all (spread over
  parallel tests).
- The 33 by caller: `DevTarget.close` 27 (the tests' `RunningTarget` and
  `TCPTarget`), the tools tests' `LocalTools.close` 4, `closeApp` (a
  development app's runtime) 1, and
  `aQueuedShellSignalRootsItsSemaphoreUntilItIsDrained` 1 (a VM never
  started, with two signals queued on purpose).
- What held them: only 2 had a Delay's timer pending. A second run of five
  leaking tests that also named the pending roots (`close-log-detail.txt`)
  found every leftover root a Semaphore and, in every one of the five, an
  external signal queued and never drained: a signal pushed after the
  workers' last drain (a request, an event, a lost connection), whose
  root only a drain could release. So the leak is not rare and not about
  Delays: almost every development target the suite closes leaks.
- Host calls after `close` had begun: 56 `post`s (the tools tests'
  `ClientHost` sink, its connections' `lost` events and timers) and 2
  `postRequest`s (a `DevTarget` connection thread after `server.stop`).
  Both touch only the bridge (the Semaphores are unregistered, so no root
  and no signal) and are safe after the VM is freed. No `runTurn`,
  `checkStuck`, `spawn`, Process call, `liveProcessCount` or counters read
  came after a close. So no test leans on the leaked VM staying readable.

### Every way a thread can still reach the VM during and after `close`

The VM's own threads (background workers, the marker, the young
collector) are joined by `shutdown`. What is left:

| Path | Covered by |
| --- | --- |
| A Delay's timer (`startDelay`'s GCD block, holding a `VMRef`) | `VMLife`: `timerFired` runs under the cell's lock; before the end it pushes a signal (freed by `destroy`, counted `undeliveredSignals`), after it does nothing (counted `lateSignals`); `destroy` answers `timersPending`. |
| `ShellVM.post`, `postRequest` and the bridge's `putBack`s from any thread (native callbacks, `ClientHost`'s sink and its `timer` op's GCD block, a `ProtocolServer` connection thread) | The bridge's locks, then `VMLife`. A post that read its Semaphore before `close`'s `unregister`/`unregisterProtocol` (which take the same bridge locks) takes its root through `VMRef.rootPending` and signals through `signalFromOutside`, both under the cell's lock: before the end they work on a live VM (the root and the node die with it), after it they are refused and counted. A post after the unregistering finds no Semaphore and touches only the bridge's queue. The bridge itself lives as long as the `ShellVM`, which the poster holds. |
| `pushExternal`'s `wakeMain` hook (context: the bridge, unretained), for a VM with no background worker | It runs inside `VMLife`'s lock, so only while the VM lives, and `close` runs on a `ShellVM` that is alive. On 5778e78 a leaked VM kept its timers able to reach this hook after the `ShellVM` and its bridge were freed; `ShellVM` always has a background worker (`--workers` is at least 1), so the branch was not taken, but the fix removes the leaked VM that made it possible. |
| `ClientHost`'s connections and `ProtocolServer`'s threads | They reach the VM only through `post` and `postRequest` (the row above). `DevTarget.close` stops the server before `vm.close`. |
| `ShellVM`'s other host calls (`runTurn`, `spawn`, the Process calls, counters) from another thread | Not covered (the brief's "not in this module", open question 1). After the fix a call after `close` reads freed memory for certain; on 5778e78 it read a leaked VM most of the time. The suite makes none (above). |
| The shells' `ShellRuntime` turns scheduled on the main queue | They hold the runtime weakly (`RuntimeLink.runtime`), and the apps never close their VM; tests that close a runtime's VM (`closeApp`, the development answers' tests) made no turn after the close in the run above. |

So starting position 2 is right: with the wait gone, every path that can
still run either finished before the end or is refused by `VMLife`.

### The starting positions

1. Right. One small test shows it and reads what `close` did through the
   life cell, not the clock.
2. Right (the table above), with one path that is not covered and is not
   this module's: host calls after `close`.
3. To be built (part 3): today nothing says what `close` did; the leak was
   found by reading the code.
4. Right: no caller passes `timeoutSeconds` (`grep -rn timeoutSeconds
   Sources Tests apps`: only the declaration and its two uses).
5. Right: `VM.destroy` already answers the `VMEndReport` with
   `timersPending` and `undeliveredSignals`, and the fix is in
   `Sources/KajoVM/Shell/Shell.swift` alone. `check-tier.sh --dry-run
   5778e78` on part 1's working tree: "tier: swift".
6. Wrong about the size: not "several" but 33 of the suite's 61 closes
   wait the 3 s and leak, 27 of them `DevTarget`s. To be measured after
   the fix.

## As built

Built by the build agent on 2026-11-18 from 5778e78, swiftly's swift.org
6.4.2 toolchain first on PATH. Commits: 35e0aab (part 1), 5240ac7 (parts 2
to 4, the last code commit), and this section. Raw files in
`~/kajo-scratch/shell-close/` (`part1/`, `work/`, `broken/`, `check/`).
Only `Sources/KajoVM/Shell/Shell.swift`, `Sources/KajoDev/Target.swift`,
`Sources/kajo/main.swift`, the new test file and the docs changed: no core
directory, no kernel, tools or types file. `check-tier.sh --dry-run
5778e78` on 5240ac7: "tier: swift", fuzzers: protocol (the diff touches
`Sources/KajoDev`).

### What was built

- `ShellVM.close()` (the `timeoutSeconds` parameter is gone; no caller
  passed one) terminates every Process, waits for them, shuts the VM down,
  unregisters the bridge's two Semaphores and calls `vm.destroy()` and
  `image.destroy()` at once. The comment says why that is safe now
  (`VMLife`), not that timers "would signal a freed VM".
- `ShellCloseReport` (public, `Sendable`, `Equatable`, no oop):
  `destroyed`, `pendingRoots` (left besides the finalization root's when
  the VM ended: what the old wait waited for), `timersPending` and
  `undeliveredSignals` (from `VM.destroy`'s `VMEndReport`). A second
  `close` answers `destroyed: false` with zero counts. Printed:
  `destroyed=true pendingRoots=1 timersPending=1 undeliveredSignals=0`
  (the reproducing test's line).
- The callers: `deinit` ignores the report. `DevTarget.close()` answers it
  (`@discardableResult`); its three failure paths in `init` ignore it.
  `kajo run --protocol` prints `kajo: closed with N signals undelivered
  (<report>)` on stderr only when `undeliveredSignals` is above zero (open
  question 2's recommended answer, built); a Delay pending at the end is a
  sleeping Process's normal state and prints nothing. One run (`work/
  serve-std{out,err}.txt`): `kajo run kernel.img --protocol <socket>`,
  SIGTERM, exit 0, no line (nothing undelivered). No caller depended on
  the old wait (part 1: no host call but `post` and `postRequest` came
  after a close).
- Three internal seams for the tests in `ShellVM`: `closeObserver` (sees
  every close's report, `deinit`'s included), `afterShutdownForTests`
  (runs inside the first close after `shutdown`, before the unregistering:
  the window the old wait was for) and `brokenOldWaitSeconds` (the broken
  variant: the old wait and leak put back).

### Tests

`Tests/KajoCompilerTests/ShellCloseTests.swift`, five tests:

- `aShellClosedWithADelayPendingFreesItsVM`, the reproducing test: fails
  on 5778e78 3 runs of 3 ("close left the VM undestroyed", part 1),
  passes on 5240ac7 with the report above.
- `aCloseWithAnEventNotTakenFreesItsVM`: an event posted before the loop
  exists (no root): `destroyed=true` and zeros; an event posted after
  `shutdown` with the loop's Semaphore registered: one root, one signal
  undelivered; a post after the close is refused nothing (it touches only
  the bridge, `lateSignals` 0).
- `aCloseWithARequestQueuedFreesItsVM`: the same for a protocol request.
- `closeTwiceThenDeinitDestroysOnce`: the observer reads `[true, false,
  false]` for close, close, deinit, and `[true]` for a shell dropped
  without a close.
- `aCloseRacingPostsIsDecidedByTheLocks`: 8 rounds, 4 posters (events and
  requests, both Semaphores registered) and the closer start at a gate;
  the posters go on 200 posts past the close. Every round destroys and
  its undelivered signals are at most its posts. Tallies: plain
  `rounds=8 posters=4 posts=35034 pendingRoots=441 undelivered=441
  late=0`; under the sanitizer with twelve busy loops `posts=125988
  pendingRoots=8821 undelivered=8821 late=0`, 0 sanitizer warnings
  (`work/tsan-load-closetests.txt`, all five pass). No round produced a
  late (refused) signal: the window between a post's reading its
  Semaphore and the end is a few instructions wide; the refusal itself is
  `DelayEndTests.aVMRefHeldPastTheEndIsRefused`'s.

The broken variant by hand (`broken/broken-run1.txt`):
`KAJO_BROKEN_SHELL_CLOSE=1 swift test --filter aShellClosedWithADelay`
fails the named check, as on 5778e78:

    Expectation failed: life.snapshot.ended
    ↳ close left the VM undestroyed
    ↳   life.snapshot → State(ended: false, timersPending: 1, lateSignals: 0)

It is not in the suite: it leaks a VM by construction.

### The leak count after

The same temporary log line (`work/after-instrumentation.diff`, not
committed) over one full `swift test` on the fix (`work/swift-test-after.txt`,
`work/close-log-after.txt`; 471 and 181 tests, all pass): 111 `close`
calls, 74 of them first closes, **74 destroyed, 0 leaked** (before: 61
closes, 34 leaked). The other 37 are `deinit`s after a close and the two
tests' second closes, each `destroyed=false`. Of the 74: 30 had nothing
left; 29 had one Delay pending (`timersPending=1`), 23 of them
`DevTarget`s; the rest had signals undelivered, up to 12 597 in the race
test's rounds.

Found while reading those 29: the Delay a closing development target
holds is `DevProtocol`'s reaper (`reapEndedRequests`, a 100 ms Delay in a
loop while any request is pending). On 5778e78 it fired inside the 3 s
wait, its signal was queued with no worker left to drain it, and that
undrained signal's root is what part 1's detail run found in every
leaking target: the reaper, not the requests, made almost every
development target leak.

### Unsafe

Lines naming `unsafe`: `Sources/KajoVM` 5929 before and after (the fix
adds none; `Shell/` 88 both), outside `Sources/KajoVM` 154 before and
after.

### Gates

`~/kajo-scratch/shell-close/check/gates.log`: the Swift tier on 5240ac7,
swift.org 6.4.2, "check-tier done swift failed=0 4598s"; every gate
`rc=0`: clean-build 20 s, swift-test 728 s, tsan 3156 s (0 "WARNING:
ThreadSanitizer"), kernel-test 121 s, apps 137 s, new-check 268 s, fuzz
168 s (protocol only, 373 349 runs, "build=ok"). Against 7ac2711's Swift
tier (`~/kajo-scratch/types-2/check/gates.log`, 4384 s): swift-test 728
against 696 s, tsan 3156 against 3017 s. Split by bundle: the
KajoCompilerTests run (where every `close` is) took 83.7 s against 81.9
in swift-test (181 tests against 176) and 2108.9 s against 2085.4 under
the sanitizer (2139.1 on 075d2a4, the same code as 5778e78); the rest of
both gates' growth is the KajoVMTests run (630.7 against 613.4 s, 1034.8
against 918.4 s under the sanitizer; 860.6 on 075d2a4), which this
module does not touch and which gained the Delay fix's tests since
7ac2711. The five new tests' bodies take 1.9 to 3.2 s each alone
(`work/close-tests-1.txt`); the durations the gates print (12 to 16 s,
138 s under the sanitizer) are Swift Testing's, pool waits included. The
removed waits were 33 times 3 s (102 s of waiting spread over parallel
tests); in the measured wall time they show as the compiler bundle
holding level (93.0 s on 5778e78 with the new test, `part1/swift-test-
before.txt`, 86.7 and 83.7 s after) while it gained five tests.

The gates' race tallies: swift-test `posts=1028726 pendingRoots=86541
undelivered=86541 late=0`; tsan `posts=110875 pendingRoots=2104
undelivered=2103 late=1`: one post took its root before the end and was
refused at its signal, the path the table in part 1 gives to `VMLife`.

### Deviations

- Parts 2 to 4 are one commit (5240ac7): the fix, the report and the
  callers change the same function's signature together.
- The reproducing test reads the VM's life cell, which the brief did not
  name: on 5778e78 `close` answers nothing, so the cell is the one
  witness that needs no new API and touches no freed memory.
- The race test asserts "destroyed" and "undelivered at most posts"; an
  exact account of every post (drained, freed, refused) would need
  counters in the bridge, which the brief did not ask for.
- The broken variant is an internal property set by the reproducing test
  under `KAJO_BROKEN_SHELL_CLOSE=1`, run by hand: in the suite it would
  leak a VM and the leak count would no longer read 0.

### Not done

- `ShellVM`'s host calls still do not check `closed` (open question 1).
- No counter on the run line (not in this module).

### Found, not this module's

- `DevProtocol`'s reaper Delay is what a closing development target
  holds (above); harmless now, but it is a 100 ms wake-up while any
  request pends.
- Before the fix, a timer of a leaked VM could reach `pushExternal`'s
  `wakeMain` branch with the `ShellVM`'s bridge already freed; the
  branch needs a VM with no background worker, which `ShellVM` cannot
  make, so it was never taken.

### Open questions

1. Should `ShellVM`'s host calls refuse after `close`? Recommended: yes,
   now that `close` always frees: a `precondition(!closed)` with a message
   in each call that enters the VM (`runTurn`, `checkStuck`, `spawn`, the
   Process calls, counters, `snapshot`), and `post`/`postRequest` left as
   they are (they touch only the bridge after a close, which the suite
   does 58 times).
2. Should a development target log undelivered signals at its close?
   Built as recommended: `kajo` prints a line only when the count is above
   zero; `DevTarget` itself logs nothing and answers the report.
