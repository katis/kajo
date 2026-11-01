# ADR 0004: Smalltalk UI code runs on the main thread, with budgeted preemption

Date: 2026-11-01
Status: proposed

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
