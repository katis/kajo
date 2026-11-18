# A closed shell refuses its host's calls

## Status

Briefed by the main session on 2026-11-18. The owner approved the follow-up
on 2026-11-18 (shell-close's question 1, `docs/decisions/47-shell-close.md`:
"brief it", after asking what it is and whether it costs performance).
Starting commit: the commit that adds this file. Not started.

## What it is

A host call on a `ShellVM` after `close` reads freed memory. This module
makes every such call stop the process at its own line with a message, and
measures that the check costs nothing a frame can see.

It is a fix in the host surface (`Sources/KajoVM/Shell/`). It adds no
feature and changes no file under the core directories.

## What is known

- `ShellVM` (`Sources/KajoVM/Shell/Shell.swift`) has about twenty calls
  that enter the VM or its image: `runTurn`, `checkStuck`, `spawn`,
  `state(of:)`, `result(of:)`, `failure(of:)`, `waitUntilTerminated`,
  `terminate`, `release`, `liveProcessCount`, `resumedProcessCount`,
  `isReleaseImage`, `nativeBindReport`, `nativeGenerated`, `snapshot(to:)`,
  `counters`, `collectorReport`, `mainThreadCounters`, `pauses`,
  `threads`, `hopLatencies`, `openProtocol`, `stopsForDebugger`. Only
  `start` and `close` read `closed`, under `closeLock` (an `NSLock`).
- Since shell-close (5240ac7) the first `close` always destroys the VM and
  the image. Before it, more than half the closes leaked, and a late call
  read memory that was stopped but still there. Now a late call is a use
  after free every time.
- No host makes such a call today. A full `swift test` logged only `post`
  (56) and `postRequest` (2) after a close. Those touch only the bridge's
  queue after the unregistering and are safe; other threads call them at
  any time, so a close can always race them.
- Who could: a host that closes one VM and opens another with a reference
  to the old one left over; a turn already scheduled when the close comes
  (`ShellRuntime` schedules its follow-up turn on the main queue holding
  itself weakly, `Sources/KajoApp/ShellRuntime.swift`); a test that reads a
  counter after `close`.
- `close` is documented as "not from inside a callback", and a host closes
  from the thread that drives the VM. Nothing states the second half.

## Starting positions

Each is the main session's belief, to be read or measured in part 1 and
answered as right or wrong.

1. The use after free is shown on the starting commit by one small test:
   a `ShellVM` is closed, the freed state is overwritten as
   `DelayEndTests`' `Scribble` does it, and `liveProcessCount` (or
   `spawn`) is called. It crashes or the sanitizer reports it. The test
   cannot live in the suite as written, since both the bug and the fix end
   the process; position 5 says how it is tested.
2. The check is one relaxed atomic load of a closed flag at the top of
   each call, and a `preconditionFailure` naming the call ("ShellVM.spawn
   after close"). It is not the lock: holding `closeLock` across a call
   would make `close` wait for a running turn and put a lock in every
   frame. If `closed` cannot become an atomic without making `ShellVM`
   awkward (`Atomic` is non-copyable; a class may hold one), say what was
   used.
3. The check catches a call made after `close` returned. It does not make
   a call safe to race with `close` on another thread, and the doc comment
   of `close` says so, with the rule that a host closes from the thread
   that drives the VM.
4. `post`, `postRequest`, `queuedEvents` and `queuedRequests` stay
   unchecked: they touch only the bridge. Part 1 confirms for each of the
   four that no line of it reads the VM or the image after the
   unregistering.
5. A precondition is tested where its failure is a value. The guard is one
   internal function that answers the refusal's message or nil, the public
   calls trap on it, and the tests call the function for every public
   call's name. One hand-run shows the real trap and its message for two
   calls (`runTurn` and `spawn`), recorded in the doc. A table test lists
   every public member of `ShellVM` and fails when a new one is neither
   checked nor on the exempt list.
6. `ShellRuntime`'s scheduled turn cannot reach `runTurn` after a close in
   any host that exists: the apps never close, and the tests' hosts drop
   the runtime with the VM. If part 1 finds a legitimate shutdown in which
   it can, that path gets a check of its own in the runtime (skip the
   turn), not a quiet answer in `runTurn`.
7. `runTurn` with the check is not slower by anything measurable: an empty
   turn timed with and without it, both orders, aligned builds, against the
   base's own spread.
8. Nothing in a core directory changes. `check-tier.sh --dry-run` says
   "tier: swift". If it says "core", stop and hand back.

## Parts

1. **Read and reproduce.** Answer positions 1, 4, 6 and 8 from the code.
   List every public and internal member of `ShellVM` with what it
   touches after a close (the VM, the image, the bridge, nothing). Show
   the use after free on the starting commit by hand (three runs, debug
   and sanitizer). Commit the doc's "Part 1" section before any fix.
2. **The check.** As positions 2 and 3, in every member part 1 lists as
   touching the VM or the image.
3. **The tests.** As position 5.
4. **The measurement.** As position 7.

## Tests

- The guard answers a refusal for every checked call after `close` and
  nil before it.
- The table test of position 5.
- `post` and `postRequest` after `close` still do nothing and trap
  nothing (shell-close's tests cover this; say which).
- The hand-run traps, their messages recorded.
- A broken variant: the check removed from one call, the table test
  failing with that call's name.
- The new suite once under the sanitizer with a dozen busy loops before
  the tier's run.

## The bar

- Every member of `ShellVM` that reads the VM or the image after a close
  is checked or named as exempt with its reason.
- The hand-run on the starting commit shows the use after free; on the
  fix it shows the message.
- An empty `runTurn` with the check is inside the base's own spread.
- The Swift tier through `just check <starting commit>`, every gate
  `rc=0`, on the final code commit; times against
  `~/kajo-scratch/shell-close/check/gates.log`.
- No new `unsafe` outside `Sources/KajoVM`; the count before and after.

## Rules of the house that bind here

- A refusal is a value at a boundary that takes Smalltalk's or the
  network's input. A call after `close` is a bug in host code; it stops.
- A rule whose broken variant traps cannot live in the suite; it is run by
  hand and its message recorded.
- Closing one escape, look beside it for the same shape: `DevTarget`,
  `ShellRuntime` and the hosts in `Sources/KajoApp/` hold a `ShellVM`;
  part 1 says whether any of them has a call of its own that outlives the
  VM.
- A rule's clause is no tighter than the measurement's own spread.
- `docs/PROCESS.md` binds in full: no push, no edit of `AGENTS.md` or
  `docs/PLAN.md`, files added by name, work files in
  `~/kajo-scratch/closed-shell-calls/`, the weekly log read before any
  gate.

## Not in this module

- Making `close` safe to race with a call on another thread.
- Any change to `post`, `postRequest`, the bridge, `VMLife` or `VM.destroy`.
- Device runs.

## Deliverables

- The doc's "Part 1" and "As built" sections, with the answers to the
  eight positions.
- The check, the tests and the measurement, in commits by part.
- `~/kajo-scratch/closed-shell-calls/check/gates.log` for the final code
  commit.
- A hand-back: commits, each position right or wrong, the member table,
  the hand-run messages, the `runTurn` numbers, the gates' table against
  the baseline, deviations, not done, found, open questions.

## Open questions

1. Should the rule "a host closes from the thread that drives the VM" be
   enforced, not only written? Recommended: no; it would need the lock
   this brief keeps out of the frame.
