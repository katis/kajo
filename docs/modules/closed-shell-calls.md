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

## As built

Built by the build agent on 2026-11-18 from 0e30cff, swiftly's swift.org
6.4.2 toolchain first on PATH. Commits: 7f34d15 (part 1), e1506f1 (part
2, the check), 5ce3d0e (part 3, the tests; the last code commit) and
this section. Raw files in `~/kajo-scratch/closed-shell-calls/`
(`part1/`, `work/`, `broken/`, `check/`, `scripts/`). Only
`Sources/KajoVM/Shell/Shell.swift`, the new test file and this doc
changed: no core directory. `scripts/check-tier.sh --dry-run 0e30cff` on
5ce3d0e: "tier: swift", fuzzers none.

### What was built

- `ShellVM.closed` is an `Atomic<Bool>` (a `let` in the class; a class
  holds a non-copyable `Atomic` without becoming awkward, so starting
  position 2's fallback was not needed). `close` reads and sets it under
  `closeLock` as before; every checked member reads it with one relaxed
  load and no lock. Relaxed because the check is for calls ordered after
  the close by the caller's own synchronization (the same thread, or a
  join); it is not a protocol against a racing close.
- `refusal(_:)` (internal) answers "ShellVM.<call> after close" or nil:
  the one place the rule and its message live. `checkOpen(_:)` (private,
  `@inline(__always)`) is the load and a branch; the message is built in
  `refuse` (`@inline(never)`), which calls `fatalError` with the
  member's own file and line. `fatalError`, not `preconditionFailure`,
  so the message is printed in a release build too.
- 24 public members check, each with its own name: `start` (its old
  message-less `precondition(!closed)` replaced; "ShellVM.start twice"
  for the other half), `openProtocol`, `stopsForDebugger` (get and set),
  `runTurn`, `checkStuck`, `spawn`, `state`, `result`, `failure`,
  `waitUntilTerminated`, `terminate`, `release`, `liveProcessCount`,
  `resumedProcessCount`, `isReleaseImage`, `nativeBindReport`,
  `nativeGenerated`, `snapshot`, `counters`, `collectorReport`,
  `mainThreadCounters`, `pauses`, `threads`, `hopLatencies`. Exempt, with
  their reasons in the table test: the two initializers, `close`, `now`,
  `post`, `postRequest`, `queuedEvents`, `queuedRequests`.
- `close`'s comment and the class comment say what the check does and
  does not do (starting position 3), with the rule that a host closes
  from the thread that drives the VM.
- `ShellRuntime`, `DevTarget` and the hosts are unchanged (part 1:
  nothing of theirs outlives the VM in any host that exists).

Machine code (aligned release builds, `work/bench/runTurn-{base,fix}.s`):
`runTurn` gained `ldrb w8, [x20, #0x40]` and `tbnz w8, #0, <cold>` before
the call to `runMainTurn`; the trap's block sits after the return. No
`swift_retain` or `swift_release` on either side.

### Tests

`Tests/KajoCompilerTests/ClosedShellCallsTests.swift`:

- `theGuardRefusesEveryCheckedCallAfterClose`: `refusal` answers nil for
  every listed name while open and "ShellVM.<name> after close" for
  every checked one after; after the close `post`, `postRequest`,
  `queuedEvents`, `queuedRequests` and a second `close` work and trap
  nothing (`lateSignals` 0). shell-close's
  `aCloseWithAnEventNotTakenFreesItsVM`, `aCloseWithARequestQueuedFrees
  ItsVM` and `aCloseRacingPostsIsDecidedByTheLocks` keep covering posts
  after and during a close.
- `everyPublicMemberIsCheckedOrExempt`: reads `Shell.swift`, lists the
  class's public members (32: 24 checked names, 7 exempt names, two
  initializers) and requires each to be checked, with
  `checkOpen("<its name>")` once per accessor, or exempt; a listed name
  that is not declared fails, and so does a public member of an
  `extension ShellVM` anywhere under `Sources/` that is not on the
  delegating list (one: KajoApp's `isStoppedForDebugger`).
- `aCallAfterCloseByHand` (part 1's), by hand only.

The broken variants, by hand on the source the table test reads
(`broken/`; nothing rebuilt, the file restored and compared byte for
byte):

- the check removed from `liveProcessCount` (`broken/broken.diff`,
  `broken/broken-run1.txt`):

      ✘ Test everyPublicMemberIsCheckedOrExempt() recorded an issue at ClosedShellCallsTests.swift:162:17: Expectation failed: checks == accessors
      ↳ ShellVM.liveProcessCount is listed as checked but calls checkOpen("liveProcessCount") 0 times for 1 accessors

- a new public member `workerCount` with no check
  (`broken/broken-run2-newmember.txt`):

      ↳ ShellVM.workerCount is neither checked nor exempt: check it with checkOpen("workerCount") or say why it is exempt

### The hand-run on the fix

Debug build, `KAJO_CLOSED_SHELL_CALL=<call> swift test --filter
aCallAfterCloseByHand` (`work/fix-handrun-{runTurn,spawn}.txt`):

    closed-shell-call runTurn: calling after close (destroyed=true pendingRoots=0 timersPending=0 undeliveredSignals=0)
    KajoVM/Shell.swift:530: Fatal error: ShellVM.runTurn after close

    closed-shell-call spawn: calling after close (destroyed=true pendingRoots=0 timersPending=0 undeliveredSignals=0)
    KajoVM/Shell.swift:563: Fatal error: ShellVM.spawn after close

(lines 530 and 563 are the `checkOpen` lines of the two members).

### The empty turn (starting position 7)

`scripts/bench/` in the scratch directory (not committed): a small
package over each tree's `KajoVM` (0e30cff exported with `git archive`,
and e1506f1), both `-c release -enable-testing` with
`-align-all-nofallthru-blocks=5 -align-loops=32`; the kernel image, two
background workers, nothing main-affine ready; per launch 100 000 warm-up
turns then 5 × 1 000 000 `runTurn(budgetNs: 1_000_000)`, the mean per
turn; five rounds, base and fix alternating which goes first; two blocks
back to back (`work/bench/turns.txt`, `turns2.txt`, `table.txt`; thermal
state 0 on every line, 0 slices):

| Block | Base median (range) ns | Fix median (range) ns | Fix / base |
| --- | --- | --- | --- |
| 1 | 302.70 (300.80 to 305.06, 1.4 %) | 304.51 (304.04 to 305.75) | 1.006 |
| 2 | 305.80 (299.54 to 306.91, 2.4 %) | 303.68 (301.26 to 305.73) | 0.993 |

Over both blocks the medians are 304.68 (base) and 304.18 ns (fix). The
difference changes sign between blocks and stays inside the base's own
spread (1.4 to 2.4 percent, 4 to 7 ns); the check is two instructions
off the critical path of a turn that costs about 300 ns. Starting
position 7 is right.

### The full suite after the fix

One full `swift test` on the working tree of e1506f1 plus the tests
(`work/swift-test-fix.txt`): 471 and 184 tests, all pass. No existing
test calls a checked member after `close` (a call would have trapped
with its message); none had to be reordered. The new suite with
shell-close's under ThreadSanitizer with twelve busy loops
(`work/tsan-load-newsuite.txt`): 8 tests pass, 0 "WARNING:
ThreadSanitizer".

### Unsafe

Lines naming `unsafe` (`grep -rw unsafe … | wc -l`): `Sources/KajoVM`
5928 before and after (`Shell/` 88 both), outside `Sources/KajoVM` 154
before and after. (shell-close's doc gave 5929 for the same tree with a
different count; this count is `grep -rw`.)

### Gates

`~/kajo-scratch/closed-shell-calls/check/gates.log`: the Swift tier on
5ce3d0e, swift.org 6.4.2, "check-tier done swift failed=0 4287s"; every
gate `rc=0`. No fuzzer: the diff touches no reader a fuzzer covers.

| Gate | 5240ac7 (shell-close) | 5ce3d0e |
| --- | --- | --- |
| clean-build | 20 s | 21 s |
| swift-test | 728 s | 716 s |
| tsan | 3156 s | 3030 s (0 "WARNING: ThreadSanitizer") |
| kernel-test | 121 s | 120 s |
| apps | 137 s | 131 s |
| new-check | 268 s | 269 s |
| fuzz (protocol) | 168 s | not in the tier this time |
| total | 4598 s | 4287 s |

Test counts: 471 and 184 in both test gates (181 compiler tests before:
the three new ones; the hand-run is disabled). The compiler bundle took
84.1 s in swift-test (83.7 before) and 2129.2 s under the sanitizer
(2108.9); the VM bundle 628.2 (630.7) and 876.5 s (1034.8). The new
suite took 14.8 s and 151.7 s as Swift Testing reports it (pool waits
included); its two tests' bodies are 1.7 s and 0.04 s alone
(`work/closedtests-1.txt`). The lower totals are the tier without a
fuzzer and the VM bundle's spread, not this module.

### Starting positions

1. Right (part 1).
2. Right: one relaxed atomic load at the top of each call and a trap
   naming it; the lock is not taken. `fatalError` in place of
   `preconditionFailure` (above).
3. Right, and written in `close`'s comment.
4. Right (part 1). The brief's list of entering calls included four
   that read only the bridge or a Swift property of the `VM` object; they
   are checked anyway (part 1's decision).
5. Right, built as written; the table test also reads the extensions.
6. Right: no runtime check.
7. Right (above).
8. Right: "tier: swift".

### Deviations

- `fatalError` rather than `preconditionFailure`, so the message survives
  a release build; the trap names the member's line, not the guard's.
- `openProtocol`, `stopsForDebugger`, `resumedProcessCount` and
  `nativeBindReport` are checked though they touch no freed memory: the
  exempt list is exactly the brief's four plus `close`, the initializers
  and the clock.
- The sanitizer hand-run needs `TSAN_OPTIONS=abort_on_error=0`: without
  it the runtime's `abort` after the SEGV spun for 15 minutes.
- The sanitizer hand-run ran `liveProcessCount` three times and the other
  two calls once each; debug ran each of the three calls three times.

### Not done

- Nothing makes a call safe against a racing `close` (not this module).

### Found, not this module's

- `RunningTarget.close()` (`Tests/KajoCompilerTests/DevProtocolTests.swift`)
  waits for its run thread at most 30 s, ignores the answer and closes:
  if the wait ran out, `close` would race a `runTurn` already running on
  that thread, a use after free no check can catch. It has not been seen
  to run out. Recommended: record an issue when the wait runs out and
  leak the target rather than close it under a running turn.

### Open questions

1. Should the rule "a host closes from the thread that drives the VM" be
   enforced, not only written? Recommended: no, as the brief says; the
   check catches every call after `close` returned on the closing thread
   or after a join, and enforcing the rest would put a lock or a thread
   check in every frame.
