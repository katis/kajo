# A Delay does not outlive its VM

## Status

Briefed by the main session on 2026-11-18. The owner approved the follow-up
on 2026-11-18 (Types 2's question 2, `docs/decisions/45-types-2.md`) and
chose it as the next module ("delay fix"). Starting commit 0395be3.
Built by the build agent on 2026-11-18 (part 1 82919c7, the fix 075d2a4;
"Part 1" and "As built" below), verified and recorded by the main session
the same day (`docs/decisions/46-delay-outlives-vm.md`).

## What it is

A one-shot timer armed by `Delay>>wait` signals its VM after the VM has
ended. This module makes the end of a VM safe against every signal that is
still on its way, and adds the test that fails without the fix.

It is a fix in the VM core. It adds no feature.

## What is known

- `startDelay` (`Sources/KajoVM/Processes/External.swift`, primitive
  called from `Processes/ProcessPrimitives.swift:51`) takes a pending root
  for the Semaphore, then hands a `VMRef` to
  `DispatchQueue.global().asyncAfter`. Nothing keeps a handle to the
  timer, so nothing can cancel it.
- `VMRef` is a raw `VMPointer`. Its comment says "Valid until the VM is
  destroyed". `VM.destroy()` (`Workers/VM.swift`) says "Outstanding Delays
  must have fired". No code checks either sentence.
- When the timer fires after `destroy`, `signalFromOutside` reads
  `vm.pointee.externalHead` and locks `vm.pointee.schedLock` in freed
  memory. Types 2's first gate run died there under the sanitizer:
  "ThreadSanitizer: SEGV External.swift:30 in VMRef.signalFromOutside"
  (`~/kajo-scratch/types-2/check-1-aborted/tsan.txt`, commit 44d4738). A
  test VM had ended minutes before a 600 s Delay fired.
- The bug is as old as module 3's external signals. Every test and
  headless run that ends a VM with a Delay pending can hit it; an app's VM
  lives for the process and does not.
- Other code hands a `VMRef` or its use to another thread:
  `Shell/ShellBridge.swift` (four `signalFromOutside` calls behind an
  optional `ref`), `Sources/KajoDev/ClientHost.swift:436` (the `timer` op,
  which posts through the bridge), `Nursery/Finalization.swift` and
  `Processes/SavedProcesses.swift` (from VM threads). `VM.ref` is public to
  the package and the tests use it from their own threads.
- A pending root is released by the drain. A signal that is never
  delivered leaves its root in the table; at the VM's end that no longer
  matters, but the table's count is read by tests.
- The lesson of 11a applies ("an `unowned` reference is a lifetime claim
  every asynchronous path must keep"), and so does "a signal queued for
  another thread holds what it will signal".

## Starting positions

Each is the main session's belief, to be measured or read in part 1 and
answered as right or wrong.

1. The crash is reproduced on the starting commit by one small test: a VM
   with one Process waiting on a Delay of about 2 s is shut down and
   destroyed at once, and the test then waits 4 s. It crashes or the
   sanitizer reports it, in at most a few runs.
2. The Delay's timer is the only path by which a thread the VM does not
   join can reach a destroyed VM. The bridge's `ref` is cleared before the
   VM ends, and the client host's timer goes through the bridge. If this is
   wrong, the other path is part of this module.
3. The fix needs nothing in the interpreter, the collectors or the
   scheduler's hot paths: a small state of its own, with its own lock,
   allocated beside the VM state (the rule of one sub-state per lock), that
   a late timer can consult safely after the VM's memory is gone. So the
   state a timer holds must not live in the VM's own allocation.
4. Two shapes are possible. (a) A liveness cell: each timer's closure
   holds a small reference-counted cell with a lock and an `ended` flag; it
   signals under the lock only while the VM lives; the VM's end sets the
   flag under the lock. (b) A registry of cancellable timers that the end
   cancels and then waits out. The main session expects (a) to be enough
   and simpler, because cancelling does not stop a block that has begun.
   The agent decides from the code and says why.
5. `just arc-check` still passes: `startDelay` is a primitive's slow path,
   out of line, and whatever Swift object it allocates stays out of the
   paths the check covers ("inlining moves ARC").
6. No kernel, tools or types file needs to change.

## Parts

1. **Read and reproduce.** List every place where a thread the VM does not
   join can hold a way to the VM (the list above is the start), and for
   each say what ends it before `destroy`. Write the reproducing test and
   record its failure on the starting commit (the message, how many runs).
   Commit the doc's "Part 1" before any fix.
2. **The fix.** After `destroy` returns, no late signal touches the VM's
   memory. Between `shutdown` and `destroy` a signal is still taken (its
   node is freed by `destroy` as today). The two comments ("Valid until",
   "must have fired") are rewritten to say what is now true.
3. **A counter.** The number of timers still pending when the VM ended is
   in `VMEndReport` and, if a run line is the natural place, on the run
   line. A fallback or a dropped signal that is not a counter is one no
   test sees.
4. **The pending root.** Decide and say what happens to the pending root
   of a timer that will never deliver. Any test that reads the pending
   table's count must still mean what it meant.
5. **Other paths**, only if part 1 found one that can reach a destroyed
   VM. Otherwise this part is the sentence that says none was found, with
   the reading that shows it.

## Tests

- The reproducing test, in the suite, passing after the fix: a VM ended
  with a Delay pending, the test alive past the timer's time, the counter
  reading 1. It uses 1.5 s or more for the timer ("1.5 s is the floor for
  a timer a test waits on") and asserts no wall-clock bound beyond waiting
  past the timer.
- A timer that fires between `shutdown` and `destroy`.
- A timer that fires at the same moment as `destroy`: many VMs, each ended
  at a time chosen around its Delay's time, started at a gate where that
  helps, under the sanitizer. The lock, not luck, must decide.
- Delays that fire normally still signal: the existing Process and Delay
  tests, and the kernel's Delay tests (in `ProcessTest`), unchanged and
  passing.
- A saved image's Delays still re-arm (module 8c's tests).
- The broken variant is the fix switched off. It crashes or is a sanitizer
  report, so by the house rule it is run by hand, not kept in the suite;
  the message is recorded in the doc. If a variant exists that fails a
  named check instead (the counter), it goes in the suite as a test switch.
- The new tests are run once under the sanitizer with a dozen busy loops
  before the gate run meets them.

## The bar

- The reproducing test fails on the starting commit and passes after.
- The Types 2 crash cannot happen: a 600 s Delay armed in a test VM that
  then ends does nothing when it fires. This is shown by a short Delay,
  not by waiting 600 s.
- `interpret` and the send, primitive and allocation paths are unchanged:
  `just arc-check` passes, and the aligned A/B against the starting commit
  is inside the base-against-base spread.
- An idle VM still has no timed wait and no new thread.
- The core tier through `just check <starting commit>` on the final code
  commit: every gate `rc=0`, the gate times read against Types 2's
  `gates.log` and, for the core-only gates, against
  `~/kajo-scratch/main-offload/check/gates.log`, the latest core-tier log.
- The device rows are the matrix as it is. No new device row is asked for;
  an app's VM does not end.

## Rules of the house that bind here

- One sub-state per lock, and the lock lives beside the struct it guards.
- No global mutable state in the VM.
- `unsafe` stays inside the core, and each new one is written out. The
  count before and after comes from a clean build.
- A wait is untimed or is bounded on something that must come; no timed
  wait is added to an idle VM.
- A report made under a lock is called after the unlock.
- A Darwin call added under strict memory safety is typechecked with
  `just ios-check` and `just apps` before the long run.
- The model packages are not touched unless the fix changes a protocol
  they model; if it does, the model changes in the same commit.

## Not in this module

- Cancelling a Delay whose waiter was terminated while the VM lives. Its
  timer fires and signals a Semaphore nobody waits on; that is harmless
  and stays.
- Giving the type checker's request its bounded wait back.
- Any change to `Delay` in the kernel.
- The pending table's capacity.

## Deliverables

- The code and tests, committed by file name in small commits.
- This doc with "Part 1" and "As built": the list of paths, the fix chosen
  and why, the counter, the pending root's fate, the broken variant's
  message, the `unsafe` count before and after, the gate log, deviations,
  not done, found, open questions.
- The raw outputs in `~/kajo-scratch/delay-outlives-vm/`.

## Open questions

1. A liveness cell or cancellable timers (starting position 4). The
   agent's to decide and justify.
2. Whether `destroy` should refuse, by precondition, a VM with timers
   pending, as its comment has always asked. Recommended: no. A host
   cannot know, and the counter says it.
3. Whether a host should be able to read the count of pending timers
   before it ends a VM. Recommended: only if a test needs it.

## Part 1

Built by the build agent from 0395be3 on 2026-11-18, swiftly's swift.org
6.4.2 toolchain first on PATH. Raw outputs in
`~/kajo-scratch/delay-outlives-vm/part1/`.

### Every way a thread the VM does not join can reach the VM

Read from `grep -rn "VMRef\|signalFromOutside\|\.ref\b\|asyncAfter\|startDelay\|rootPending"`
over `Sources` and `Tests`, and every `DispatchQueue`, `pthread_create`
and `Thread` in `Sources/KajoVM`. The VM joins its background workers,
the marker and the young collector in `shutdown`; everything below is
outside that.

| Path | Who holds the way to the VM | What ends it before `destroy` on 0395be3 |
| --- | --- | --- |
| `startDelay`'s timer (`Processes/External.swift:151`) | a GCD block holding a `VMRef` (a raw `VMPointer`) | nothing. It fires at its time, whatever the VM's state. **Reaches a destroyed VM.** |
| `VM.ref` held by the shell's bridge (`Shell/Shell.swift:321`, `Shell/ShellBridge.swift:27`): `post`, `putBack`, `postRequest`, `putBackRequest` from any thread (native callbacks, the client host's connection threads, a server's connection threads) | `ShellBridge.ref`, set once and **never cleared** | `ShellVM.close` clears the bridge's two Semaphores (`unregister`, `unregisterProtocol`) under the bridge's locks before `destroy`, so a later post finds no Semaphore and takes neither `rootPending` nor `signalFromOutside`. A post that read its Semaphore before that holds a pending root, and `close` then waits for the pending count (below). Only if the table was full (`rootPending` answered -1) could such a post's signal pass `close`'s wait and land after `destroy`: a path, but one that needs a full pending table. |
| The client host's `timer` op (`Sources/KajoDev/ClientHost.swift:436`) | a GCD block holding the `ClientHost`, whose sink holds the `ShellVM` (`Sources/KajoAppDevelopment/Serving.swift:167`) | it reaches the VM only through the bridge's `post`: the row above. |
| `Nursery/Finalization.swift:15`, `Processes/SavedProcesses.swift:443` | a `VMRef` made and used at once on a VM thread (after a stop; at the load) | the VM's own threads: joined, or the host inside `VM.init`/`destroy`. Not a late path. |
| Tests: `ProcessTests.externalSignalFromANonVMThread`, `SafepointTests` | `rt.vm.ref` on a `TestThread` | joined before `rt.stop()`. |
| `ShellCallbacks` (`wakeMain`, `release`, `views`) | VM to host, not host to VM | not a way into the VM. |

So starting position 2 is right that the Delay's timer is the one path
that reaches a destroyed VM in practice, and wrong in its reason: the
bridge's `ref` is never cleared. What protects the bridge is `close`
clearing its Semaphores, plus a wait whose own failure mode is a leak.
`ShellVM.close` waits up to 3 s for the pending count to fall to the
finalization root's, but after `shutdown` no worker drains external
signals, so the count never falls: every `close` with a Delay, an event
or a request still pending waits 3 s and leaks the VM and its image
(found, not this module's; open question 4 below).

The fix (part 2) puts the check on the way itself (`VMRef`), so the
bridge's rare path and any future holder of `VM.ref` are covered by the
same lock as the timer.

### The reproducing test

`Tests/KajoVMTests/Processes/DelayEndTests.swift`,
`aDelayPendingWhenTheVMEndsDoesNotTouchIt`: one Process waits on a 2 s
Delay (the pending table holds its Semaphore: count 1), the VM is shut
down and destroyed at once (`Runtime.stop`), then 4096 allocations of
`VMState`'s size and alignment are filled with `0xA5` and held while the
test waits 4 s.

On 0395be3:

| Build | Runs | Result | File |
| --- | --- | --- | --- |
| ThreadSanitizer, without the overwrite | 1 | passed, no report | `repro-tsan-run1.txt` |
| debug, with the overwrite | 3 | 3 of 3 signal 11 | `repro-debug-run{1,2,3}.txt` |
| ThreadSanitizer, with the overwrite | 3 | 3 of 3 "ThreadSanitizer: SEGV on unknown address 0x4b4b1b4b4b4b4b40 ... #1 VMRef.signalFromOutside(_:handle:) External.swift:30, #2 closure #1 in startDelay(_:ms:sem:) External.swift:152", register x19 = 0xa5a5a5a5a5a5a5a5 | `repro-tsan-run{2,3,4}.txt` |

The frames are Types 2's (`~/kajo-scratch/types-2/check-1-aborted/tsan.txt`,
the same two lines). Starting position 1 is right with one correction:
ThreadSanitizer does not report the late read as such (the freed state
still holds the old values, the read succeeds and the push lands in freed
memory); it crashes when the memory has been reused, as in Types 2's run
minutes later. The test reuses it on purpose, and then fails in every
build, every run.

## As built

Built by the build agent on 2026-11-18 from 0395be3: part 1 in 82919c7,
the fix and its tests in 075d2a4 (the final code commit; this doc after). Toolchain: swiftly's swift.org 6.4.2
first on PATH (every gate line names it). Raw outputs in
`~/kajo-scratch/delay-outlives-vm/` (`part1/`, `work/`, `broken/`,
`check/`).

### The fix: a liveness cell (open question 1)

`VMLife` (`Processes/External.swift`) is a `final class` with a
`Mutex` around `ended`, `timersPending` and `lateSignals`, allocated by
`VM.init` apart from the VM state and held by three owners: the `VM`
object (so its counts stay readable after `destroy`), the VM state
(`VMState.life`, for `startDelay`), and every `VMRef` and every Delay
timer's closure. Every touch of the VM from a thread the VM does not join
runs inside `whileLive` (signals and `rootPending`) or `timerFired` (a
Delay's timer) under the cell's lock; `VM.destroy` calls `end()` right
after the final collection and before it frees anything, which sets
`ended` under the same lock. So a signal that holds the lock when the end
comes finishes first (its node is freed by `destroy` with the others, as
before), and every later one sees `ended`, touches nothing and is counted.
The push itself moved unchanged into `pushExternal`; the VM's own threads
(`signalFinalization`, the saved-image load) call it directly, since a VM
thread runs only while the VM lives.

Why the cell and not cancellable timers: cancelling a GCD timer
(`DispatchSourceTimer.cancel`) does not stop a handler that has begun, so a
registry would still need a lock the end takes and the handler holds, plus
a wait for handlers in flight: the cell's lock is that lock, and with it
the registry, the cancel and the wait add nothing to safety. The cell keeps
`asyncAfter` (no new thread, no timed wait, no source per Delay) and is one
allocation per VM. Its cost: an ended VM's timer still runs at its time and
holds the cell (a few dozen bytes) until then; a 600 s Delay keeps a
dispatch timer for 600 s after its VM. The owner's answer to Types 2's
question 2 said "cancelled": the timers are neutralised, not cancelled;
said here so the owner can ask for the registry if the armed GCD timers
matter.

Lock order: the cell's lock, then the scheduler and pending-root mutexes,
never the reverse (`startDelay` takes it on a VM thread holding no lock).
The host's `wakeMain` hook runs under it, as it ran inside
`signalFromOutside` before; the shells' hooks only schedule a turn.

The two comments are rewritten: `VMRef` "may outlive the VM: after
`VM.destroy` its calls do nothing but count", `destroy` "Delays may still
be pending ... a timer that comes later does nothing and is counted".

### The counters (part 3)

`VMEndReport.timersPending` (timers armed and not fired when the VM
ended) and `VMEndReport.undeliveredSignals` (external signals queued after
the last drain, freed by `destroy`), both set by `VM.destroy` whatever the
VM's nurseries. `VM.lateSignals` (the cell's count of refused signals,
roots and timers, readable after `destroy`) and `VM.timersPending` (tests
only: open question 3 answered "only if a test needs it"; the shell's
host surface does not get it). Not on the run line: `kajo run` and `kajo
test` call `destroy` in a `defer` after the line is written, and nothing
of a Delay is the run's measurement.

One run (`work/tests-debug-1.txt`, `aDelayPendingWhenTheVMEndsDoesNotTouchIt`
asserts them): `end.timersPending == 1`, `end.undeliveredSignals == 0`,
then `vm.lateSignals == 1` once the timer fired. The race test's lines in the gates:
`delay-race vms=16 pendingAtEnd=8 undelivered=1 delivered=7`
(`swift-test-load`), `pendingAtEnd=3 undelivered=5 delivered=8` (`tsan`),
`pendingAtEnd=7 undelivered=1 delivered=8` (`tsan-load`),
`pendingAtEnd=8 undelivered=0 delivered=8` (`test-release`).

### The pending root (part 4)

A timer that will never deliver keeps its Semaphore's pending root until
`destroy` frees the table, as a signal queued after `shutdown` always has:
the final collection treats it as a root (the Semaphore stays in the
image, reachable from none of the image's roots, for the next VM's
collector), and `pendingRootCount` read before the end still counts it. Nothing
reads the table after the end, so no count changes meaning:
`delayWaitUsesAGCDTimerAndPendingRoot` and `pendingRootsSurviveACollection`
pass unchanged, and the reproducing test asserts the count 1 before the
end.

### Other paths (part 5)

None reaches a destroyed VM after the fix, and the one theoretical bridge
path is closed by the same check: the bridge's `ref` (never cleared) is a
`VMRef`, whose `rootPending` answers -1 and whose `signalFromOutside`
does nothing once the VM has ended (`aVMRefHeldPastTheEndIsRefused`).
`ShellVM.close`, `ShellBridge` and `ClientHost` are unchanged.

### Tests

`Tests/KajoVMTests/Processes/DelayEndTests.swift` (and `Runtime.stop`
answers the end report, with `shutdown: false` for a test that shut down
itself):

| Test | Claim | Starting commit | After |
| --- | --- | --- | --- |
| `aDelayPendingWhenTheVMEndsDoesNotTouchIt` | a 2 s Delay pending at the end, the freed state overwritten: the timer fires into nothing; `timersPending` 1, `lateSignals` 1 | signal 11 3/3 debug, ThreadSanitizer SEGV External.swift:30 3/3 (part 1) | passes debug, sanitizer, sanitizer under load |
| `aTimerFiringBetweenShutdownAndDestroyIsTaken` | a timer between `shutdown` and `destroy` is queued and freed: `undeliveredSignals` 1, nothing late | (the API did not exist) | passes |
| `aVMRefHeldPastTheEndIsRefused` | `signalFromOutside` and `rootPending` after the end, from another thread too: -1, counted 3 | (would touch freed memory) | passes |
| `aTimerAndTheEndAtTheSameMomentAreDecidedByTheLock` | 16 VMs, each ended by its own thread (started at a gate) at 150 ms before to 300 ms after its 1.5 s Delay: per VM `lateSignals == timersPending`, at most one of pending and undelivered | | passes; debug 8 pending at the end, 8 delivered; sanitizer under twelve loops 6 pending, 1 undelivered, 9 delivered (`work/tsan-load-1.txt`) |
| `brokenVariantALateTimerTouchesTheFreedVM` | the fix switched off (`VMTestSwitches.lateSignalsIgnoreEnd`), by hand only (`KAJO_BROKEN_DELAY_END=1`) | | debug signal 11 3/3 (`broken/debug-run{1,2,3}.txt`); sanitizer "ThreadSanitizer: SEGV on unknown address 0x4b4b1b4b4b4b4b40 ... #1 pushExternal(_:_:handle:) External.swift:120, #2 closure #1 in VMRef.timerFired(_:handle:), #4 closure #1 in VMLife.timerFired(_:)" (`broken/tsan-run1.txt`) |

The race test asserts agreement and not that every outcome occurred (a
GCD timer under the sanitizer and load can be seconds late, and then every
VM ends first); it prints its tally (`delay-race ...`), and both runs above
saw the lock decide both ways. No variant fails a named check instead of
crashing (without the check the timer's push is itself the
use-after-free), so the broken variant is a test switch run by hand, the
house rule for trapping variants.

The new tests ran once under ThreadSanitizer with twelve busy loops before
the tier (`work/tsan-load-1.txt`, `scripts/tsan-load.sh`: 29 tests with
`ProcessTests` and the saved-Process tests, 0 reports). The kernel's
`ProcessTest>>testDelay` and module 8c's re-arm tests run in the gates
unchanged.

### Starting positions

1. Right, with a correction: the 2 s Delay test crashes only when the freed
   memory is reused (part 1); ThreadSanitizer does not see the late read.
   With the reuse: 3 of 3 in each build.
2. Right that the timer is the one path in practice; wrong that the
   bridge's `ref` is cleared (it never is). The bridge is protected by
   `close` clearing its Semaphores, and a post racing a close with a full
   pending table could reach a destroyed VM. The fix covers both.
3. Right: nothing in the interpreter, the collectors or the scheduler's
   hot paths; the cell is its own allocation with its own lock, outside the
   VM state's memory.
4. (a) chosen, for the reason above.
5. Right: `just arc-check` passes ("OK: no retain or release on the
   checked paths; the dispatch loop is one jump table", `check/arc-check.txt`);
   `interpret` 1403 instructions, one indirect branch, one jump table;
   `drainExternal` 154 instructions, ARC 0, the same line as in earlier
   modules' runs. `startDelay` is `@inline(never)`.
6. Right: no kernel, tools or types file changed.

### Unsafe surface

Lines naming `unsafe` in `Sources/KajoVM`: 5926 on 0395be3, 5928 on
075d2a4 (`part1/unsafe-lines-0395be3.txt`, `work/unsafe-lines-075d2a4.txt`;
`git diff 0395be3 075d2a4`: 19 added, 17 removed, nearly all the push
moving into `pushExternal`). The new ones are `registerPending` and
`pushExternal` inside the cell's closures, `VMState.life` read in
`startDelay`, and the two moved callers. `VMLife` itself has no `unsafe`;
no new `@safe` type but `VMLife` (a class holding a `Mutex`). The clean
build and `just ios-check` (strict memory safety, Swift 6 mode) report 0
warnings and 0 errors (`check/clean-build.txt`, `check/ios-check.txt`).

### Gates

`KAJO_CHECK_OUT=~/kajo-scratch/delay-outlives-vm/check just check 0395be3`
on 075d2a4, the core tier, 20 gates (no gate script changed, so no
`check-tier-test`): every gate `rc=0`, `check-tier done core failed=0
11835s` (`check/gates.log`).

| Gate | 075d2a4 | a89dd0e (core) | 7ac2711 (Swift) |
| --- | --: | --: | --: |
| clean-build | 20 | 19 | 20 |
| swift-test-load | 830 | 811 | (swift-test 696) |
| tsan | 3015 | 2898 | 3017 |
| tsan-load | 4128 | 3653 (rc=1) | - |
| ios-check | 17 | 17 | - |
| arc-check | 63 | 6 | - |
| golden | 77 | 77 | - |
| native-golden | 167 | 162 | - |
| native-kernel-test | 72 | 70 | - |
| native-cc | 39 | 37 | - |
| test-release | 126 | 121 | - |
| model-check | 35 | 52 | - |
| soak | 64 | 61 | - |
| fuzz (4 x 600 s) | 666 | 666 | (2 x 120 s) 125 |
| apps | 139 | 125 | 133 |
| kernel-test | 122 | 108 | 119 |
| new-check | 268 | 264 | 268 |
| ab | 332 | 329 | - |
| matrix-mac | 795 | 670 | - |
| matrix-iphone | 860 | 738 | - |

`arc-check` rebuilt its release build because core files changed (a89dd0e's
6 s was a cached build). `tsan-load` is 475 s longer than a89dd0e's,
which failed and is no clean baseline; the matrices run 153 rows since
main flips (a89dd0e's ran 147). The new tests' bodies take 2 to 4.5 s each
(their reported durations in the parallel suites, 325 to 1104 s, are the
cooperative pool's wait, AGENTS.md); 0 ThreadSanitizer warnings in `tsan`
and `tsan-load`; the suites 471 and 176 tests passed in each test gate;
`kajo test` 255 of 255 (`ProcessTest>>testDelay` among them, 29 ms);
`SnapshotScenarioTests` (the saved image's `delay` scenario re-arms)
passed. Fuzzers: kasm 2 073 186, snapshot 3 101 768, syntax 750 708,
protocol 1 728 061 runs in 601 s each, "build=ok" on each line.

**The aligned A/B** (`check/ab/table.md`, base 0395be3) against the base
against itself (`work/ab-base-base/table.md`, the same script run from a
worktree of 0395be3, removed afterwards):

| | 1 worker | 8 workers |
| --- | --- | --- |
| head / base, time | 0.990 to 1.004 | 0.943 to 1.085 |
| base / base, time | 0.992 to 1.000 | 0.939 to 1.082 |
| head / base, cycles | 0.994 to 1.003 | 0.980 to 1.020 |
| base / base, cycles | 0.999 to 1.001 | 0.983 to 1.021 |

Not every row is inside the base's own range, by at most 0.4 points:
at one worker `alloc` 1.004 (cycles 1.003, instructions 1.000) is 0.4
points over the base's highest (1.000), `fib` 0.990 and `st-closures`
0.991 under its lowest (0.992); at 8 workers `arith` 1.085 (cycles 1.017,
instructions 1.003) is 0.3 points over the base's highest time ratio
(1.082), and inside its cycles range. Instruction ratios 0.998 to 1.005
on every row. With `interpret` identical (below) and nothing of the
change on a kernel's path (no kernel arms a Delay), the agent reads these
as the spread of five runs, not a cost; said so the owner can ask for
more runs. Checksums the same in every row.
`interpret` in the A/B's own objects (`Dispatch.o` of both builds,
`otool -tV` with addresses stripped, `work/interpret-{base,head}.txt`):
1817 lines each, identical instruction for instruction.

**The matrices** (`check/matrix-mac.txt`, `check/matrix-iphone.txt`,
`shell-report.py --bar` over every raw row, as the gate ran them, blocks
back to back, neither interleaved nor cooled):

| | rows | launches failed | checksums not ok | frames missed (rows) | fallbacks | unjustified | stalls (longest ms) | sweep stops | young on main | main flips | main waits | longest stop ms | longest wait for a safepoint ms |
| --- | --: | --: | --: | --- | --: | --: | --- | --: | --: | --: | --: | --- | --- |
| Mac | 153 | 0 | 0 | 1785 (3, the hog rows with the budget off, by design) | 0 | 0 | 652 (21.61) | 0 | 0 | 357 | 0 | 15.52 scavenge, ring `young=stw` | 0.72 finalMark, w6/poll |
| iPhone 13 Pro | 153 | 0 | 0 | 3584 (5: 3 hog rows 1191 to 1193, and the ring under `young=stw` runs 2 and 3, 5 and 3 frames, thermal serious) | 0 | 0 | 0 | 0 | 0 | 366 | 0 | 18.08 scavenge, storm mainload `young=stw` | 2.32 scavenge, marker/poll |

a89dd0e's bar for the same columns: the Mac 147 rows, 1786 frames in 3
hog rows, 658 stalls (28.93), longest stop 11.62; the iPhone 147 rows,
3588 frames in 6 rows, longest stop 17.03. Thermal states on the iPhone's
lines: 238 nominal, 330 fair, 122 serious (the device warmed over the
matrix; every frame missed outside the hog rows was at serious).

### The idle VM

No thread and no wait is added: the timers are the GCD timers they were,
the cell's lock is taken only by a signal, a timer's arming and firing,
and the end. An idle VM's threads wait as before.

### Deviations

- The reproducing test overwrites the freed VM state (part 1): without it
  the test passes on the starting commit under ThreadSanitizer, so the
  brief's test alone does not fail.
- `VMRef` checks the cell for every call, not only the Delay's timer: the
  bridge's rare path is closed by the same lock (part 5 needed no code of
  its own).
- `Runtime.stop` answers the end report and takes `shutdown:`.
- The bar's "inside the base-against-base spread": two rows of eighteen
  sit 0.3 and 0.4 points past it in time (above), with `interpret`
  identical and the cycle ratios inside at 8 workers.

### Not done

- The run line carries no Delay counter (above).
- `ShellVM.close` still waits up to 3 s and leaks (found, below).

### Found, not this module's

- `ShellVM.close` waits up to 3 s for the pending count to fall to the
  finalization root's, but no worker drains after `shutdown`, so the count
  never falls: every `close` with a Delay, an event or a request still
  pending waits 3 s and leaks the VM and its image. With the cell the wait
  protects nothing (open question 4). Its comment ("they would signal a
  freed VM") is no longer true.
- `ShellVM`'s host calls (`spawn`, `liveProcessCount`, `post`'s queue
  aside) do not check `closed`; a host that calls one after `close` reads
  a freed VM. No host does today.

### Open questions

1. Decided: the cell (above).
2. `destroy` does not refuse a VM with timers pending (as recommended): a
   host cannot know, and `VMEndReport.timersPending` says it.
3. `VM.timersPending` exists for the tests only; no host surface reads it
   (as recommended).
4. New: should `ShellVM.close` stop waiting for the pending count and
   destroy at once? Recommended: yes, in a small follow-up with a test
   that closes a shell with a Delay pending and reads that the VM was
   freed; the wait leaks every such VM and the cell makes it unnecessary.
