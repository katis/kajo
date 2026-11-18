# A Delay does not outlive its VM

Briefed by the main session on 2026-11-18 (`docs/modules/delay-outlives-vm.md`,
the owner: "delay fix", then "Start") and built the same day by one build
agent from 0395be3: three commits, 82919c7 (part 1), 075d2a4 (the fix, the
last code commit) and 2eae058 (the doc), 10 files. The doc's "Part 1" and
"As built" sections hold every number; the raw files are in
`~/kajo-scratch/delay-outlives-vm/`.

## What was built

- `VMLife` in `Sources/KajoVM/Processes/External.swift`: a small
  reference-counted cell with its own `Mutex` around `ended`,
  `timersPending` and `lateSignals`, allocated apart from the VM state. The
  `VM` object, `VMState.life` and every `VMRef` and Delay timer hold it.
- Every touch of the VM from a thread it does not join (`VMRef.rootPending`,
  `signalFromOutside`, the new `timerFired`) runs inside the cell's lock.
  `VM.destroy` sets `ended` under the same lock after the final collection
  and before it frees anything, so a signal either finished before the end
  or does nothing and is counted.
- The push itself is unchanged, moved into `pushExternal`. The VM's own
  threads (finalization, the saved image's install) call it directly.
- Counters: `VMEndReport.timersPending` and `undeliveredSignals`,
  `VM.lateSignals` (readable after `destroy`), `VM.timersPending` for
  tests. None is on the run line: `destroy` runs after the line is written.
- A timer is not cancelled. A timer of an ended VM still fires at its time,
  finds the VM ended and does nothing; it holds the cell (not the VM) until
  then. Types 2's answer said "cancelled"; the effect asked for (no late
  touch of the VM) is what was built.
- The test switch `lateSignalsIgnoreEnd` is the broken variant, run by hand
  (`KAJO_BROKEN_DELAY_END=1`).
- `Tests/KajoVMTests/Processes/DelayEndTests.swift`: the reproducing test,
  a timer that fires between `shutdown` and `destroy`, a `VMRef` held past
  the end, and 16 VMs each ended at a time spread around its Delay's.

No kernel, tools or types file changed. `interpret` is identical
instruction for instruction (`work/interpret-{base,head}.txt`, 1817 lines
each).

## The brief's starting positions

1. Right, with a correction. A VM ended with a 2 s Delay pending does not
   fail by itself: under ThreadSanitizer it passed once with no report. The
   test fails only when the freed VM state is reused, so it overwrites 4096
   allocations of `VMState`'s size with 0xA5.
2. Right that the Delay's timer is the one practical path, wrong about why
   the bridge is safe. `ShellBridge.ref` is never cleared; `ShellVM.close`
   unregisters the Semaphores before `destroy`. A post racing a close with
   the pending table full could still reach a destroyed VM. The cell covers
   that path too.
3. Right: the new state is its own allocation with its own lock.
4. The cell, not cancellable timers: cancelling a GCD timer does not stop a
   handler that has begun, so a registry would need this lock and a wait as
   well.
5. Right: `arc-check` passes.
6. Right.

## Numbers

- On 0395be3 the reproducing test: signal 11 in 3 of 3 debug runs;
  "ThreadSanitizer: SEGV on unknown address 0x4b4b1b4b4b4b4b40",
  `VMRef.signalFromOutside` External.swift:30 from `startDelay`'s closure,
  in 3 of 3 sanitizer runs. The same two frames as Types 2's crash.
- The broken variant on the fix: signal 11 in 3 of 3 debug runs; the
  sanitizer's SEGV in `pushExternal` External.swift:120 under
  `VMLife.timerFired`.
- The race test's tally of 16 VMs (pending at the end, undelivered,
  delivered): 8, 1, 7 in `swift-test-load`; 3, 5, 8 in `tsan`; 7, 1, 8 in
  `tsan-load`; 8, 0, 8 in `test-release`.
- Lines naming `unsafe` in `Sources/KajoVM`: 5926 before, 5928 after.
- The aligned A/B against the base's own spread (five runs each, checksums
  the same, instructions 0.998 to 1.005): time 0.990 to 1.004 at 1 worker
  (base against base 0.992 to 1.000) and 0.943 to 1.085 at 8 (0.939 to
  1.082); cycles 0.994 to 1.003 and 0.980 to 1.020 (0.999 to 1.001 and
  0.983 to 1.021). Three rows sit past the base's own time range by at
  most 0.4 points (`alloc` 1.004, `fib` 0.990, `arith` at 8 workers 1.085).
- The Mac's matrix: 153 rows, 0 failed, 0 fallbacks, 1785 frames missed in
  the 3 hog rows only, 652 stalls (longest 21.61 ms), longest stop 15.52 ms
  (ring, `stw`, scavenge), longest wait for a safepoint 0.72 ms.
- The iPhone's matrix: 153 rows, 0 failed, 0 fallbacks, 3584 frames missed
  (the 3 hog rows, and 5 and 3 frames in two ring `stw` rows at thermal
  "serious"), longest stop 18.08 ms (storm mainload, `stw`, scavenge),
  longest wait for a safepoint 2.32 ms (the marker at a poll). Thermal
  fields over the run: 238 nominal, 330 fair, 122 serious.

## Gates

`~/kajo-scratch/delay-outlives-vm/check/gates.log`: the core tier on
075d2a4, swift.org 6.4.2, every gate `rc=0`, "check-tier done core
failed=0 11835s". `check-tier-test` did not run (no gate script changed).
`tsan` 3015 s, `tsan-load` 4128 s (the first clean `tsan-load` since
a89dd0e's failed one at 3653 s), `swift-test-load` 830 s, the matrices 795
and 860 s (153 rows against a89dd0e's 147). The fuzzers 601 s each with
"build=ok". The new tests' bodies take 2 to 4.5 s each.

## Verified by the main session

- `git log 0395be3..HEAD` (three commits), `git status --short` clean, the
  diff's 10 files; `AGENTS.md` and `docs/PLAN.md` untouched.
- The fix's diff read whole: the lock order (the cell, then the scheduler
  and pending mutexes), `end` before any free, `state.deinitialize`
  releasing the state's reference to the cell.
- `gates.log` line by line; 0 "WARNING: ThreadSanitizer" in `tsan.txt` and
  `tsan-load.txt`; the "delay-race" lines; `arc-check`'s OK line.
- `part1/repro-tsan-run1.txt` and `broken/tsan-run1.txt`: the SEGV lines
  and frames as quoted.
- `check/ab/table.md` read whole.
- `shell-report.py --bar` run again over `check/matrix-mac` and
  `check/matrix-iphone`: the columns as above.
- `swift test --filter DelayEndTests` on 2eae058: 4 passed, the broken
  variant skipped, "delay-race vms=16 pendingAtEnd=7 undelivered=0
  delivered=9" (`verify/delay-end-tests.txt`).
- `ShellVM.close` (`Sources/KajoVM/Shell/Shell.swift`) read: it does wait
  on the pending count after `shutdown` and return without `destroy`.

Not verified by the main session: the base-against-base A/B table (its
worktree is removed; the numbers are the agent's), the 3 of 3 reproduction
on 0395be3 (read in the files, not rerun), the `unsafe` line counts.

## Deviations

- The reproducing test overwrites the freed state; the brief's test alone
  passes on the starting commit.
- `VMRef` checks the cell on every call, not only for the Delay.
- `Runtime.stop` (the tests' helper) answers the end report and takes
  `shutdown:`.
- Three A/B rows sit up to 0.4 points past the base's own time spread,
  with `interpret` identical.

## Not done

- No counter on the run line.
- `ShellVM.close` is unchanged (found, below).

## Found, not this module's

- `ShellVM.close` waits up to 3 s for the pending-root count to fall, but
  no worker drains after `shutdown`, so it never falls: every close with a
  Delay, an event or a request pending waits 3 s and leaks the VM and its
  image. With the cell the wait protects nothing.
- `ShellVM`'s host calls do not check `closed`; a host calling one after
  `close` would read a freed VM. No host does today.

## Open questions

1. Cell or cancellable timers. Decided by the agent: the cell.
2. Should `destroy` refuse a VM with timers pending? Not built, as the
   brief recommended: a host cannot know, and the counter says it.
3. Should a host read the pending-timer count? For tests only, as the
   brief recommended.
4. New: should `ShellVM.close` destroy at once instead of waiting and
   leaking? Recommended: yes, a small follow-up with a test that closes a
   shell with a Delay pending and reads that the VM was freed.

## The owner's answer (2026-11-18)

Question 4: "Yes, brief it". Briefed the same day as
`docs/modules/shell-close.md` (a row of `docs/PLAN.md`). The main session's
report of the hand-back called the follow-up a core-tier change; it is not:
`Sources/KajoVM/Shell/` is outside the core directories and
`check-tier.sh --dry-run` gives the Swift tier. Questions 1 to 3 stand as
built.
