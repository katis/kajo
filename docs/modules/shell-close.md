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
