# A Delay does not outlive its VM

## Status

Briefed by the main session on 2026-11-18. The owner approved the follow-up
on 2026-11-18 (Types 2's question 2, `docs/decisions/45-types-2.md`) and
chose it as the next module ("delay fix"). Not started. Starting commit:
the head of master when the owner says start.

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
