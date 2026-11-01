# Experiment: Smalltalk on the main thread with budgeted preemption

## Question

Kajo's UI design (see the conversation recorded in this file's "Background")
runs the Smalltalk UI Process *synchronously on the main thread*, so that
event handling, model updates and view updates happen in one run-loop turn
with no asynchronous echo. Lock-up protection comes from the interpreter, not
from thread isolation: a Process that overruns its budget is suspended at a
bytecode boundary and continues elsewhere. IO never blocks a worker; it
completes by signalling a Semaphore from outside the VM.

This experiment asks whether that actually holds a display's frame rate on
this machine while the VM is abused, and what the design changes cost.

1. Does budgeted preemption keep an AppKit window at its native refresh rate
   while a Smalltalk Process on the main thread runs forever, recurses
   deeply, or allocates until the GC runs?
2. What does moving frame stacks from workers to Processes cost on the
   send-heavy kernels?
3. How fast is a Process hop from a background worker to the main thread,
   and what does an event-to-paint round trip take when the handler is
   Smalltalk?
4. Can Semaphore signalling from GCD completion handlers drive thousands of
   waiting Processes without a worker ever blocking, and what does a parked
   Process cost in memory?

## Background

Decisions so far: Swift (ADR 0001), object table (ADR 0003, proposed). The
previous conversation settled these intentions, which this experiment tests:

- The main thread is a worker the shell owns. On each event and each display
  tick the shell gives the VM the main thread for a budget and the VM runs
  UI-affine Processes on it.
- The interpreter's existing safepoint poll also checks the budget. An
  overrunning Process is suspended between bytecodes, re-queued, and the
  main thread returns to the shell.
- Frame stacks belong to Processes, not workers, so a Process can leave the
  main thread mid-method and resume on another worker.
- A UI primitive called off the main thread suspends the Process, queues it
  to the main worker, and retries there.
- Primitives never block. Completion handlers on non-VM threads push a
  Semaphore oop onto a queue; workers drain it at safepoints.
- Native callbacks into Smalltalk only enqueue an event and return.
- A Process still running on the main thread after a few hundred
  milliseconds is reported (in the real system: the debugger opens).

## Starting point

Copy variant B (object table) from `experiments/object-representation/swift/`
(`Sources/VMB`, the shared `Kasm` target, kernels, bench harness). Do not
modify that experiment. Keep the table, TLABs, mark-sweep, safepoints and the
bytecode set. Follow the Swift notes in `AGENTS.md`.

## Changes to build

### Processes with their own stacks

- A `Process` is a heap object (class index, slots: priority, state,
  waiting-on Semaphore, affinity, next link) plus a native stack segment
  owned by the VM outside the heap (a fixed 64 KiB `malloc` is fine here).
  The frame layout stays as in the slice; only where the words live changes.
- Workers run Processes. `fork` creates a Process at the forker's priority.
  `Processor yield`, `Semaphore wait`, `Semaphore signal`, `Process
  terminate` are primitives. A Process suspends at a bytecode boundary by
  saving pc, sp, fp into the Process object.
- Scheduler: ready queues per priority (3 priorities are enough), shared by
  all workers under a lock; measure its contention rather than optimising it.
  Idle workers sleep on a condition variable and are woken by signals.
- Affinity: a Process is either "any worker" or "main thread". Main-affine
  Processes live in a separate ready queue only the main worker drains.

### Budget and preemption

- The safepoint poll checks a per-worker deadline. To keep the poll cheap,
  read the clock only every N polls (pick N so the overhead is below 1
  percent on `arith`; report N and the overhead). The main worker's deadline
  is set by the shell on every entry; background workers get a time slice of
  a few milliseconds so a `fork`ed infinite loop cannot monopolise a worker
  either.
- On overrun the current Process is suspended and re-queued at the back of
  its priority. On the main thread `run(budget:)` then returns to the shell.
- The shell measures how long a main-affine Process has been running without
  completing an event; past 300 ms it logs a "stuck Process" report with the
  Process's current method. That is the stand-in for opening the debugger.

### Hop to main

- UI primitives (a small set: set a label's text, append a line to a text
  view, read a slider value) check `currentWorker.isMain`. If false, the
  Process is marked main-affine, suspended with pc pointing *at* the send so
  the primitive retries, and queued for the main worker. The main worker is
  woken via `DispatchQueue.main.async` or `performSelector` so the hop does
  not wait for the next display tick.

### External signals

- A lock-free MPSC queue of Semaphore oops. `signalFromOutside(oop)` is
  callable from any thread. A pending Semaphore is registered as a GC root
  until signalled. Workers drain the queue at safepoints; an idle worker is
  woken when the queue goes non-empty.
- IO primitives for the experiment: `Delay wait:` via a GCD timer,
  `File readAll:` via DispatchIO, and `HTTP get:` is out of scope. Each
  starts the operation, returns, and the Process waits on its Semaphore.
- Native events: the AppKit app enqueues events (synthetic clicks, slider
  changes, keystrokes) into a VM event queue backed by a Semaphore; the UI
  Process loops on `nextEvent` and handles each. Handler latency is measured
  from enqueue to the primitive that updates the view.

## The app and the measurements

A small AppKit app (`swift run` can launch it; it will put a window on
screen) with a view animated natively by Core Animation, so frame delivery
is observable independently of Smalltalk, plus a label and a text view that
Smalltalk updates. A `CADisplayLink` on the window (macOS 14+) or
`CVDisplayLink` records every frame timestamp. A frame is dropped when the
gap exceeds 1.5x the nominal interval. Report nominal refresh rate, frames
observed, drops, and the p50/p99/max frame gap for each scenario. Each
scenario runs for 10 seconds. Run every scenario three times and report the
median run. Scenarios:

| id | scenario | what it tests |
|---|---|---|
| S0 | idle: window animating, VM booted, no Processes running | the measurement itself |
| S1 | 1000 synthetic events/s handled by the UI Process, each doing ~50 us of Smalltalk and updating the label | synchronous handling at load; report event-to-view latency p50/p99 |
| S2 | S1 plus a `fork`ed main-affine Process running `[true] whileTrue: []` | budget preemption; the stuck report must fire |
| S3 | S1 plus a main-affine Process recursing until the stack is exhausted, repeatedly | preemption inside deep recursion; stack overflow handling |
| S4 | S1 plus 7 background workers running the `alloc` kernel in a loop, forcing GCs | safepoint pauses hitting the main thread; report time-to-safepoint and stop-the-world distributions |
| S5 | S1 plus 10,000 Processes each in a loop of `Delay wait: 10ms` then signal a counter | external signalling at volume; report signals/s, worker time blocked (must be 0), RSS per parked Process |
| S6 | 1000 background Processes each computing ~1 ms then updating the label | hop-to-main; report hop latency p50/p99 and main-thread time per hop |
| S7 | S1 with budget disabled | the control: what the drops look like without preemption, so S2's result means something |

Also run the `fib`, `sends`, `arith` and `alloc` kernels headless, 1 and 8
workers, in this VM and compare with variant B's numbers in
`../object-representation/RESULTS.md`. The difference is the cost of
Process-owned stacks, the scheduler, and the budget check. Report each
separately if they can be isolated with flags; at least report the total.

## RESULTS.md must contain

1. The scenario table above, filled in, with the display's actual refresh
   rate stated.
2. The kernel comparison against variant B.
3. Budget check: N, the clock used, and its measured overhead.
4. Memory per parked Process and total RSS in S5.
5. Everything that went wrong in the design when it met AppKit: re-entrancy
   surprises, run-loop interactions, places the budget could not be
   honoured (long primitives, GC pauses), and how long the worst main-thread
   stall was in each scenario and what caused it.
6. Honest notes on what a real system would need that this skipped: growable
   stacks, freezing suspended Processes into contexts, priorities mapped to
   QoS, debugger instead of a log line.
7. A recommendation paragraph: does the thesis hold, with what caveats.

## Layout

```
experiments/ui-thread-scheduling/
  DESIGN.md
  SPEC.md            Process object layout, scheduler and queue protocol,
                     budget mechanism, hop and external-signal protocols,
                     scenario parameters; written first
  kernels/           new .kasm files for the UI Process, scenarios and IO
  swift/             one package: VM module, Kasm, an AppKit app executable,
                     a headless bench executable, tests
  bench.sh           runs scenarios and kernels, prints tables
  RESULTS.md
```

## Non-goals

Growable or segmented stacks, generational GC, a real debugger, iOS, UIKit,
networking, text editing, anything in SwiftUI. Keep the AppKit side minimal:
one window, one animated layer, one label, one text view, one slider.
