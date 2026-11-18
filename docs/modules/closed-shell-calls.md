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

## Part 1

Read and reproduced by the build agent on 2026-11-18 from 0e30cff,
swiftly's swift.org 6.4.2 toolchain first on PATH (`part1/path.txt`).
Raw outputs in `~/kajo-scratch/closed-shell-calls/part1/`. Nothing here
changes `Sources/`: part 1 adds the hand-run test and this section.

### Every member of `ShellVM` after a close

What each member touches once `close` has returned: the VM (its
`VMState` and everything hanging off it, freed by `VM.destroy`), the
image (the object memory, freed by `image.destroy`), the bridge (the
`ShellBridge`, which lives as long as the `ShellVM`), or nothing freed.
"VM object" means a Swift property of the `VM` class itself, which the
`ShellVM` still holds: readable, but it describes a VM that is gone.

| Member | Touches after close | Part 2 |
| --- | --- | --- |
| `init(image:options:callbacks:)`, `init(imageAt:…)` | nothing (comes before any close) | exempt |
| `deinit` | `close()` again: `closed` under `closeLock`, nothing freed | exempt |
| `start()` | VM (`vm.start`); already refused by `precondition(!started && !closed)`, with no message | checked (message) |
| `close()` | `closed` under `closeLock`; a second call frees nothing | exempt |
| `static now()` | nothing (the clock) | exempt |
| `openProtocol()` | bridge only (`stopsForDebugger`, `protocolOpen`) | checked (decision below) |
| `postRequest(connection:json:)` | bridge only: the request Semaphore is unregistered, so no `VMRef` call; even a post that read it before goes through `VMLife` | exempt |
| `queuedRequests` | bridge only (its lock) | exempt |
| `stopsForDebugger` (get, set) | bridge only (an `Atomic<Bool>` in the bridge) | checked (decision below) |
| `runTurn(budgetNs:minPriority:)` | VM (`vm.runMain`: worker 0, the scheduler, the safepoint) | checked |
| `checkStuck(limitNs:)` | VM (the records and the scheduler lock) | checked |
| `post(_:)` | bridge only: the event Semaphore is unregistered (as `postRequest`) | exempt |
| `queuedEvents` | bridge only | exempt |
| `spawn(_:receiver:arguments:main:priority:)` | image (`classOop`, `entryPoint` read the heap; `classIndex(named:)` is a Swift dictionary), VM (`newString`, `vm.spawn`, `inspect`) | checked |
| `hostValues(_:)` (private) | image, VM; called only by `spawn` | covered by `spawn` |
| `holds(_:)` (internal) | `held` under `heldLock` only | not a host call |
| `state(of:)` | `held`, then VM (`vm.state(of:)`: the Process's slots) | checked |
| `result(of:)` | VM, image (`vm.host`, `shellValue`) | checked |
| `failure(of:)` | VM (the error log) | checked |
| `waitUntilTerminated(_:)` | VM (the scheduler's condition) | checked |
| `terminate(_:)` | VM | checked |
| `release(_:)` | `held`, then VM (`vm.release`: the host roots) | checked |
| `liveProcessCount` | VM (`schedRead`: the scheduler's lock and state) | checked |
| `resumedProcessCount` | VM object (a Swift array of oops): nothing freed, but stale | checked |
| `isReleaseImage` | image (`om.isReleaseImage` reads the freed shared GC state) | checked |
| `nativeBindReport` | VM object (a Swift optional): nothing freed, but stale | checked |
| `nativeGenerated` | VM (`vm.config` reads `state.pointee`) | checked |
| `snapshot(to:)` | VM and image, through `spawn` and the Process calls | checked |
| `counters` | image (`om.counters`) and VM (the counter array) | checked |
| `collectorReport(seconds:)` | VM (stops, the collectors' states) | checked |
| `mainThreadCounters` | VM (worker 0's young counters) | checked |
| `pauses` | VM (the stop log) | checked |
| `threads` | VM (the worker table, the marker and collector states) | checked |
| `hopLatencies` | VM (the scheduler's ring) | checked |
| `closeObserver`, `afterShutdownForTests`, `brokenOldWaitSeconds` (internal) | nothing: test seams read by `close` | not host calls |
| `image`, `vm`, `bridge` (internal stored) | tests reach through them; after a close the suite reads only `vm.vm.life` and `vm.vm.lateSignals`, which read the life cell that outlives the VM | not host calls |
| `isStoppedForDebugger(_:)` (KajoApp's extension) | through `spawn`, `state(of:)`, `result(of:)`, `release` | covered by those |

Starting position 4 is right: `post`, `postRequest`, `queuedEvents` and
`queuedRequests` read only the bridge after the unregistering (its two
locks, its queues, and `bridge.ref`, used only when a Semaphore is
registered and then only through `VMLife`'s lock).

The brief's list of "calls that enter the VM or its image" is right but
for two: `openProtocol` and `stopsForDebugger` read only the bridge, and
`resumedProcessCount` and `nativeBindReport` read a Swift property of
the `VM` object, not freed memory. Part 2 checks all four anyway, with
the brief's rule turned round: everything is checked but the four bridge
calls that other threads make at any time (and so can always race a
close), `close`, the initializers and the clock. Each of the four is a
host bug after a close (a protocol opened on, or a setting given to, a
VM that is gone; a count of a VM that is gone) and none is called from
another thread by design, so a message serves the host better than a
quiet answer, and the table test's rule stays one sentence.

### The hand-run on 0e30cff

`Tests/KajoCompilerTests/ClosedShellCallsTests.swift`,
`aCallAfterCloseByHand`, enabled only by `KAJO_CLOSED_SHELL_CALL=<call>`:
a started shell runs `buildCounter`, is closed (`destroyed=true`), the
freed `VMState` is reused by 4096 allocations of its size and alignment
filled with 0xA5 (`DelayEndTests`' `Scribble`), and the named call is made.

Debug build, three runs of each call (`part1/debug-<call>-<n>.txt`): 9 of
9 end with "exited with unexpected signal code 11" after the line
`closed-shell-call <call>: calling after close (destroyed=true
pendingRoots=0 timersPending=0 undeliveredSignals=0)`; no run prints
"returned".

ThreadSanitizer build (`--sanitize=thread`, `TSAN_OPTIONS=abort_on_error=0`),
three runs of `liveProcessCount` (`part1/tsan-liveProcessCount-<n>.txt`):
3 of 3 report

    ==51058==ERROR: ThreadSanitizer: SEGV on unknown address 0x52d2f2d2d2d2d2d0 ...
        #2 pthread_mutex_lock
        #3 VM.schedRead<A>(_:) VM.swift:380
        #4 VM.liveProcessCount.getter VM.swift:346
    SUMMARY: ThreadSanitizer: SEGV VM.swift:380 in VM.schedRead<A>(_:)

(the scheduler's mutex pointer read from the overwritten `VMState`). One
run each of the other two calls: `runTurn` "SUMMARY: ThreadSanitizer:
SEGV VMState.swift:445 in UnsafeMutablePointer<A>.worker(_:)", `spawn`
"KajoVM/RawArray.swift:44: Precondition failed" (signal 5: a bounds
check met a garbage count), `part1/tsan-{runTurn,spawn}-1.txt`. Without
`abort_on_error=0` the first sanitizer run sat in `abort` at 100 percent
CPU for 15 minutes after the SEGV (`part1/tsan-sample.txt`) and was ended
by its bound with its output lost; the option makes the runtime exit
instead.

So starting position 1 is right: one small test shows it, and it cannot
live in the suite.

### Who else holds a `ShellVM`

- `DevTarget` (`Sources/KajoDev/Target.swift`): `run()` calls `runTurn`
  in a loop until `stop()`; `close()` is documented "after `run`
  returned, or instead of it". `kajo run --protocol` calls `run()` and
  then `close()` on the same thread. The tests' `RunningTarget.close()`
  (`Tests/KajoCompilerTests/DevProtocolTests.swift`) stops the target,
  waits for its run thread at most 30 s, ignores the wait's answer and
  closes: if the wait ever ran out, `close` would race a running
  `runTurn` on another thread, which no check can make safe (found, not
  this module's; below). The protocol server's connection threads reach
  the VM only through `postRequest`.
- `ShellRuntime` (`Sources/KajoApp/ShellRuntime.swift`): its calls are
  `runTurn` (in `turn`), `post` and `checkStuck` (in `tick` and
  `deliver`) and `start`. Its follow-up turn and its `wakeMain` turn are
  dispatched to the main queue holding the runtime weakly
  (`[weak self]`, `RuntimeLink.runtime`). The apps and the shells never
  close their VM (the shells end with `exit`). Only tests close a
  runtime's VM (`closeApp` in `AppServingTests.swift`), always at the end
  of the scope that holds the runtime; `aTurnLeftForLaterDoesNotOutlive
  ItsHost` schedules a follow-up, closes, leaves the scope and then
  awaits, so the follow-up runs and finds the runtime gone. A turn can
  reach a closed VM only if something keeps the runtime alive past its
  VM's close, which no host does. Starting position 6 is right; the
  runtime gets no check of its own.
- The hosts (`AppKitHost`, `UIKitHost`) hold no `ShellVM`: their
  display links and event handlers reach the runtime (weakly for events;
  the shells' display-link closures are `[unowned self]` on a mode that
  lives for the process).
- `ClientHost` reaches the VM only through its sink (`post`).
- KajoApp's `ShellVM.isStoppedForDebugger` calls only `spawn`, `state`,
  `result` and `release`.

### Starting positions answered from the code

1. Right (above).
4. Right (above), and the brief's list of entering calls is right but for
   `openProtocol`, `stopsForDebugger`, `resumedProcessCount` and
   `nativeBindReport` (the table).
6. Right (above).
8. Right: the fix is `Sources/KajoVM/Shell/Shell.swift` alone, and
   `Shell/` is not a core directory. `scripts/check-tier.sh --dry-run
   0e30cff` on part 1's working tree: "tier: swift", fuzzers none
   (`part1/dry-run.txt`).
