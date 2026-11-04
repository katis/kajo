# ADR 0004: Smalltalk UI code runs on the main thread, with budgeted preemption

Date: 2026-11-01
Status: accepted (owner, 2026-11-04, on module 9a's Mac mini and iPhone 13 Pro measurements, `docs/modules/shells.md`)

## Context

Two of Kajo's goals pull against each other. Native UI should feel right,
which means an event handler sets a value and reads it back in the same
moment, with no asynchronous echo between model and view. And it must be
hard to lock up the UI by accident, which argues for keeping Smalltalk off
the main thread entirely. A snapshot-and-diff design on a VM thread gives the
second and loses the first: it is the React pattern, with its stale getters,
late echoes and jumping cursors.

The alternative is to run the UI Process synchronously on the main thread
and move the lock-up protection into the interpreter. The experiment in
`experiments/ui-thread-scheduling/` built that on the object table VM and
measured it against a 120 Hz AppKit window. See its RESULTS.md.

## Decision

- **The main thread is a VM worker owned by the shell.** On each event and
  each display tick the shell gives the VM the main thread for a budget, and
  the VM runs main-affine Processes on it. Smalltalk event handlers therefore
  run synchronously in the run-loop turn that delivered the event.
- **Preemption at bytecode boundaries.** The safepoint poll also counts down
  to a clock read; a Process that overruns its budget is suspended between
  bytecodes and re-queued. Background workers get time slices the same way,
  so a forked infinite loop cannot monopolise a worker either.
- **Frame stacks belong to Processes, not workers.** A Process can leave the
  main thread mid-method and resume on another worker.
- **Hop to main.** A UI primitive called off the main thread suspends the
  Process, marks it main-affine, and retries the send on the main worker.
- **Primitives never block.** IO starts an operation and the Process waits on
  a Semaphore. Completions on non-VM threads push the Semaphore's oop onto a
  lock-free queue that workers drain at safepoints. Native callbacks into
  Smalltalk only enqueue an event and return.
- **A stuck main-affine Process is reported** after a few hundred
  milliseconds. In the real system this opens the debugger.
- **Targets are UIKit and AppKit**, imperative toolkits that suit direct
  Smalltalk wrappers around native views. SwiftUI is not a target.

## Evidence

Display measured at 120.00 Hz. Median of three 10 s runs.

| scenario | frames missed of 1200 | max gap | notes |
|---|---|---|---|
| idle | 0 | 8.3 ms | |
| 1000 events/s handled in Smalltalk | 1 | 16.7 ms | event latency p50 0.63 ms, p99 5 ms, the same tail as a native handler |
| plus an infinite loop on the main thread | 4 | 26 ms | 2411 preemptions, stuck report fired at 306 ms |
| plus deep recursion | 4 | 25 ms | 105 stack overflows, each terminated cleanly |
| plus 7 workers forcing GCs | 5 | 21 ms | 502 collections, pause p50 6.4 ms, max 8.0 ms |
| plus 10,000 Processes on timers | 0 | 8.3 ms | 350k signals/s, no worker blocked, 18 KB per parked Process |
| 1000 background Processes hopping to main | 0 | 8.3 ms | hop p50 11 us, p99 27 us |
| infinite loop with the budget off | 1079 | 9 s | the control |

The cost of Process-owned stacks and the scheduler on the headless kernels
was not measurable. The budget countdown costs about 2 percent on fib and
appeared as a speedup on other kernels, which is a code-placement effect.

## Reasons

- The thesis held wherever the VM was the cause. No main-thread turn overran
  its budget by more than about 0.1 ms except across a GC pause.
- The feel is preserved by construction. Handlers are synchronous; set then
  get is consistent; there is no diff layer.
- Lock-up is bounded rather than impossible: one budget slice, plus the
  longest primitive, plus the longest GC pause. The control scenario shows
  what the bound is worth: 9 seconds of freeze without it.
- Hopping is cheap enough that programmers can write sequential code that
  starts on any worker and touches the UI at the end.

## Costs and open problems

- **GC pauses are the prerequisite.** A 6 to 8 ms stop-the-world pause
  against an 8.3 ms frame lands on the main thread either inside a turn or
  while it waits to enter. This design needs a collector whose pauses fit in
  a frame: a generational nursery first, concurrent compaction later (ADR
  0003 chose the table partly for this). Until then, frame drops under heavy
  allocation are expected.
- **Unexplained stalls.** Under load a few 16 to 26 ms stalls occurred with
  only 1 to 4 ms of VM time inside them. Likely the AppKit run loop or the
  window server; an Instruments trace is the next step. A native handler
  showed the same latency tail, so this is not Smalltalk's doing, but it is
  not understood.
- **Primitives must be bounded.** Preemption cannot interrupt a primitive, so
  the primitive table is reviewed for this and long operations are written
  in Smalltalk or poll the budget.
- **Stacks.** Fixed 64 KiB segments cost 18 KB of resident memory per parked
  Process. A real system needs growable or segmented stacks and freezing of
  long-suspended Processes into heap contexts, which is the same mechanism
  the debugger needs for `thisContext`.
- **Scheduler lock.** At 350k signals per second the shared ready-queue lock
  became the limit. Per-worker queues with stealing are the obvious next
  step, not needed yet.
- **Re-entrancy guard.** A nested run loop, such as a modal panel, could
  re-enter a VM turn. Not handled in the experiment.
- **Shared mutable state.** Processes truly run in parallel, so the kernel's
  collection classes must be designed for it. This is a kernel decision
  still to be made.

## Consequences

- The VM exposes `run(onMainFor budget:)`, a main-affine ready queue, an
  external signal queue, and an event queue. The shell owns the run loop and
  the display link.
- Every IO primitive is asynchronous with Semaphore completion. There is no
  blocking primitive, and no `async`/`await` in Smalltalk.
- Events must carry the time they happened, not the time they were enqueued,
  or stalls become invisible to the measurement.
- Swift code that builds closures for GCD or VM threads must not do so inside
  `@MainActor` methods; Swift 6 traps when such a closure runs elsewhere.

## Built (module 3, 2026-11-02)

`Sources/KajoVM/Workers/` and `Processes/` (docs/modules/workers.md) build
this decision headlessly, without a shell: the main worker is worker 0,
given to the VM in turns (`VM.runMain(budgetNs:minPriority:)`); Processes
own 64 KiB stacks and move between workers mid-method; the safepoint poll
counts down to a clock read every 1024 polls and preempts at bytecode
boundaries; a shell-call primitive called off main hops (the Process
becomes main-affine and the send is retried on main); primitives never
block (Delay is a one-shot GCD timer signalling from outside through a
lock-free queue and pending roots); a main-affine Process runnable for too
long is reported once through a C hook (`checkStuck`). Hooks are C
function pointers set before any worker starts.

Headless numbers (M2 Max, release):

- **Budget**: an infinite loop at normal priority on the main worker,
  1 ms turns, with stops landing inside them: the VM's overrun past the
  budget (CPU time, stops and entry waits taken out) at most 0.042 ms in
  every run, including the debug suite under a load average of 40; alone,
  the wall-clock overrun was at most 0.054 ms (debug). Under load the wall
  tail reached 15 ms: the OS descheduling the thread, not the VM.
- **Cost**: fib 2.8 percent slower than module 2 measured interleaved in
  the same session (1714.1 against 1667.7 ms, medians of five), including
  the Process, its slices and the countdown; the other kernels -0.2 to +4.8
  percent, within the code-placement spread the experiment saw.
- **Scaling**: eight workers run the compute kernels 7.1 to 7.6x faster
  and `alloc` 6.05x, the remainder being two single-threaded
  stop-the-world collections per run (35 to 37 ms pauses on a 1 GiB heap).
- **Idle**: eight idle workers use no measurable CPU and wake zero times
  in a second.
- **Hop**, **stuck report**, **10,000 parked Processes**, **stack
  overflow** terminating one Process only: tested, not timed.

Still waiting for the shell (module 9): the 120 Hz scenarios, event
latency and frames missed, the frame account (how much of a frame the
shell gives the VM), the native event queue and `nextEvent`, the
re-entrancy guard for nested run loops, and the measurement of hop latency
and stalls on a real main thread. Still waiting for the collector
(modules 4 to 7): pauses that fit in a frame; today a stop lands on the
main worker as before (turns report it separately).

## Device (9a) (2026-11-04)

Module 9a built the native shells (docs/modules/shells.md): the main
thread given to the VM in turns from the real run loop (a wakeup, a native
event, every display refresh with 4 ms of the frame for the VM), the event
queue and a Smalltalk event loop on the main thread, view wrappers behind
a hop primitive (ADR 0010), the stuck report as a shell callback. First
the macOS shell on the Mac mini's display (a 120.00 Hz panel,
M2 Pro), 10 s windows, three runs, medians with ranges, a probe view moved
by Smalltalk every frame and module 7's main-thread load (`mainTick:work:`)
in every frame:

| scenario | frames missed of 1200 | max gap | notes |
|---|--:|--:|---|
| idle | 0 | 8.4 ms | |
| 1000 events/s handled in Smalltalk | 0 | 8.4 ms | latency p50 0.057 ms, p99 3.21 (3.15 to 3.44), max 4.8: from when the event was due to the view call that showed it |
| the same under the allocation storm, 7 workers, offload | 0 | 8.4 ms | p50 0.043, p99 2.08, max 5.0 |
| infinite loop on main, normal priority, with 1000 events/s | 0 | 8.4 ms | 2414 preemptions, stuck report at 306 ms (304 to 308), event p99 3.0 ms |
| infinite loop with the budget off (the control) | 1193 | 9005 ms | |
| storm, ring, share at 7 workers under every young mode | 0, but the ring under the stop-the-world scavenge: 6 (5 to 7) | 8.4 ms (16.7) | ADR 0008's note |

Against the experiment's table above (an M2 Max): event latency p50 0.06 against 0.63 ms and p99 3.2 against 5,
the hog's frames 0 against 4 with the same 306 ms report, the storm 0
against 5 missed frames. The thesis holds on a real run loop on the Mac.
The p99 of 2 to 3 ms is the same idle, under the storm and with the hog,
so it does not grow with the VM's work; whether it is the 1 ms event
timer's lateness or the frame turns it waits behind was not separated.

**The iPhone 13 Pro** (2026-11-04, after the owner signed Xcode in to the
team; `scripts/shell-matrix.sh device`, the iOS shell on the phone's
ProMotion panel at 120.0 Hz, 5 background workers, the same windows, runs
and loads; **thermal serious** for every row but the first run of idle and
storm, the phone uncooled between parts):

| scenario | frames missed of 1200 | max gap | notes |
|---|--:|--:|---|
| idle | 0 | 8.4 ms | the main thread on efficiency cores (P share 0.00), turns up to 3.3 ms, 0.016 W |
| 1000 events/s handled in Smalltalk | 0 | 8.4 ms | latency p50 0.242 ms, p99 3.49 (3.47 to 3.49), max 4.0 |
| the same under the allocation storm, 5 workers, offload | 0 | 8.3 ms | p50 0.100, p99 2.90, max 6.2 (6.1 to 8.3) |
| infinite loop on main, normal priority, with 1000 events/s | 0 | 8.4 ms | 2411 preemptions, stuck report at 304 ms (303 to 304), event p99 3.16 ms |
| infinite loop with the budget off (the control) | 1192 | 9004 ms | the display link delivered 1 Hz |
| storm, ring, share at 5 workers under every young mode | 0, but the ring under the stop-the-world scavenge: 2 (1 to 4) | 8.4 ms (16.7, 25 once) | ADR 0008's note |

The thesis holds on the phone's run loop as on the Mac's: the budget keeps
an infinite loop on main from costing a frame, every event is handled in
the turn that delivered it, and the stuck report comes at the limit. What
differs: the event p50 is four times the Mac's (0.24 to 0.29 against 0.06
ms) with the p99 about the same (2.9 to 3.5 against 2.1 to 3.2); the frame
load took 3.6 to 3.7 s of the main thread per 10 s (the Mac 2.2 to 2.4),
the longest turn under load 3 to 8 ms with young collection on, up to 10
ms under the storm's stop-the-world scavenges and 16 to 19 ms under the
ring's, which are its two missed frames. Under load the main thread ran 88 to 100 percent on performance
cores; idle it ran on efficiency cores and still made every frame. Not
built: the re-entrancy guard (the shells run no modal loop).

## Built (module 9b, 2026-11-04): the debugger lands

The stuck report and an unhandled error now reach a debugger instead of
only a report. While the development protocol serves (ADR 0011), an
unhandled error stops its Process: it waits on a Semaphore with its stack
intact until a client acts (no timeout in development; a release image
never stops), and a client may also stop a running or waiting Process
(`process.suspend`). A stopped main-affine Process just waits, so the
main thread's turns and every other Process go on: on the macOS shell the
event loop's own Process was stopped for the whole 10 s window while the
window kept all 1200 frames (0 missed in three runs) and the target
answered 182 protocol requests at 1.4 ms p50, and after it was let go it
handled the events that had queued (`docs/modules/development-protocol.md`,
"The macOS shell: a stopped event loop"). The frame's Context slot this
ADR reserved is what the stopped Process's Contexts are made from; the
budgeted preemption's poll is where stepping is decided (ADR 0012), so the
interpreter's paths are unchanged. The stuck report itself still only
reports; a stuck main-affine Process can be suspended for the debugger
through the protocol.

