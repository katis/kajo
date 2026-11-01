# Spec: Processes, budgeted preemption, hop-to-main, external signals

Written before the code. Everything not stated here is as in
`../object-representation/SPEC.md`, variant B (object table, TLABs, block
heap, non-moving mark-sweep, safepoints, bytecodes, frames, lookup cache).
Where DESIGN.md left a choice, the simpler option is taken and listed under
"Choices".

## Package shape

One SwiftPM package in `swift/`:

- `Kasm`: the `.kasm` assembler, copied from `../object-representation`
  unchanged, plus kernel path lookup for this experiment.
- `VMP` (VM with Processes): variant B's sources copied (symlinks resolved)
  and extended. Compile flag `NO_BUDGET` removes the per-poll countdown so
  its cost can be isolated.
- `uts-bench`: headless executable. `uts-bench kernel <name> <workers>`
  runs a kernel as Processes and prints one `key=value` line; `uts-bench
  clock` measures the clock read.
- `kajo-ui`: the AppKit app. `kajo-ui <S0..S7> [--seconds 10] [--out file]`
  runs one scenario, prints one `key=value` line and appends it to `--out`.
- `VMPTests`: Swift Testing, headless; a fake main worker is a pthread.

Removed from variant B because nothing here uses them and they would need
Process-aware derived-pointer fixups: compaction, become, bulk forward,
reshape, snapshot (and `Frames.swift`, the pc fixups for moving GC). The GC
is non-moving, so frames may hold raw pcs into bytecode bodies across
suspension, and the `moved`/`resync` mechanism is gone from the hot path.

## Process object and native stack

New builtin classes `Process` (index 12) and `Semaphore` (13); user classes
start at 14.

```
Process (13 slots)                       Semaphore (3 slots)
  0 priority    SmallInteger 0..2          0 excessSignals  SmallInteger
  1 state       0 ready 1 running          1 firstWaiter    Process | nil
                2 waiting 3 terminated     2 lastWaiter     Process | nil
  2 waitingOn   Semaphore | nil
  3 affinity    0 any worker, 1 main thread
  4 next        Process | nil (ready queue or semaphore list link)
  5 rec         SmallInteger index of the native record
  6 sp  7 pc  8 fp  9 hdr   saved registers, SmallInteger-tagged addresses
 10 result      what the bottom method returned
 11 exitSem     Semaphore | nil, signalled once on termination
 12 id          SmallInteger, for reports
```

A Process is in at most one list at a time (a ready queue or one
semaphore's waiters), so one `next` slot serves both.

**Native record** (`ProcRec`, a fixed table of 32 768 in raw memory, free
list under the scheduler lock): the process oop (a GC root while the
Process lives), its stack segment `base`/`end`, `runningOn` (worker index
or -1), and timing fields (hop start, runnable-since, stuck-reported).

**Stack segment**: `malloc(64 KiB)` = 8192 words per Process, not
initialised (only `[base, sp]` is ever scanned, and every word in it was
pushed). Freed on termination. The frame layout is the slice's: receiver,
args, temps, then `hdr[0..3]` = method, return pc, caller fp, caller hdr;
the bottom frame's `hdr[2]` is the `hostFP` sentinel.

**Suspension** happens only at a bytecode boundary and writes `sp`, `pc`,
`fp`, `hdr` into slots 6..9; resumption reads them back and re-derives
`lits` from `hdr[0]`. Saved pc conventions:

| leave point | saved pc | saved sp |
|---|---|---|
| poll at a backward jump | the jump target | unchanged |
| poll at a `send` | the `send` bytecode itself (rewind 3) | unchanged, receiver and args still pushed |
| poll at an arithmetic/compare fallback send | the special bytecode (rewind 1) | unchanged |
| completing primitive that blocks (`wait`, `yield`) | after the send | args popped, result (receiver) pushed |
| UI primitive off main (hop) | the `send` bytecode (rewind 3) | unchanged, so the send is *retried* on main |

**Leaving the interpreter.** A suspending path saves the Process, sets
`w.leave` (a reason code) and hands `run` registers whose pc points at a
one-byte VM-global code array holding opcode `0x1B leave`, which returns
from `run`. The check after a primitive call is one byte load (`w.leave !=
0`), which replaces variant B's `moved` check at the same place. Returning
from the bottom frame terminates the Process.

**Stack overflow**: `activate` finding no room for the frame terminates the
Process with reason `overflow`, logs it, and counts it. Its exit Semaphore
is signalled as for a normal termination. (A real system would grow the
stack or open a debugger; see RESULTS.md.)

## Workers

A `Worker` (padded to 128-byte lines) points at the stack of the Process it
is running (`stack`, `stackEnd`, `sp`), so the interpreter is unchanged.
Additional fields: `current` (Process oop or 0), `isMain`, `leave`,
`countdown`, `pollEvery`, `deadline` (mach ticks), `slice`, `fp`.

- **Background workers**: pthreads. Loop: honour a pending GC; take the
  highest-priority Process from the "any" ready queues; run it until it
  leaves; repeat. With nothing ready, leave the VM (`active -= 1`), sleep on
  the scheduler condition variable, re-enter the VM (waits while a GC is in
  progress) and drain the external queue.
- **Main worker**: owned by the shell. `runMain(vm, budgetNs, minPriority)`
  enters the VM, drains the external queue, runs main-affine Processes from
  the main ready queues (priority order, at or above `minPriority`) until
  the queues are empty or the budget is spent, and leaves the VM. While the
  shell is outside `runMain` the main worker is not counted as active, so it
  never delays a GC; entering during a GC blocks until the GC ends (measured
  as "enter wait").

**Enter/leave protocol** (extends the slice's safepoint protocol, same
mutex): `enter` waits while `gcRequested`, then `active += 1`; `leave` does
`active -= 1` and broadcasts so a waiting GC requester re-checks `parked + 1
>= active`. A worker never holds the scheduler lock while parked or while
allocating, so the two locks never nest the wrong way.

## Scheduler

- Ready queues: 3 priorities × 2 affinities, each a head/tail pair of oops
  in the VM struct (GC roots), linked through `Process.next`. FIFO per
  priority; higher priority first. Priorities: 0 background, 1 normal,
  2 UI (the UI Process).
- One scheduler lock (`pthread_mutex`) protects the queues, Semaphore lists
  and `Process.state`. Every acquisition tries `trylock` first; when that
  fails, the wait is timed and counted (`schedContended`, `schedWaitNs`).
  That is the contention measurement; nothing is optimised.
- Making a Process ready: append to its queue. "Any" queue: if a worker is
  idle, `pthread_cond_signal`. Main queue: `wakeMain` hook (below).
- `fork` (primitive) allocates the Process and its stack *before* taking
  the lock, builds the bottom frame `receiver selector: arg`, and enqueues
  it at the forker's priority (or an explicit one).
- `Processor yield`: suspend, append to the back of its own queue.
- `Semaphore wait`: `excessSignals > 0` → decrement and continue; else
  suspend and append to the Semaphore's waiters.
- `Semaphore signal`: first waiter → ready (FIFO); else `excessSignals += 1`.
- `Process terminate`: the current Process terminates; a ready or waiting
  one is unlinked and terminated; one running on another worker gets a
  terminate request honoured at its next budget check.
- Termination: record result, state 3, free the stack and record, signal
  `exitSem`.

## Budget and preemption

The safepoint poll at sends and backward jumps becomes:

```
countdown -= 1
if countdown == 0 || gcRequested { pollSlow }      // NO_BUDGET: gcRequested only
```

`pollSlow` parks for a GC if requested; if the countdown expired it resets
it to `N`, reads the clock (`mach_absolute_time`, ticks; deadline is kept in
ticks so no conversion on the hot path), drains the external signal queue
if it is non-empty, and if `now >= deadline` (or a terminate request is
pending) suspends the Process and leaves. A preempted Process goes to the
back of its priority's queue.

- **N**: chosen by measurement on `arith` (bench sweeps `KAJO_POLL_N`);
  default **1024**. At ~3 to 40 ns per poll that is a clock read every 3 to
  40 us, well under any budget used here.
- **Main deadline**: set by the shell on every `runMain` entry.
- **Background time slice**: 5 ms, set when a worker starts a Process.
  `KAJO_SLICE_MS=0` disables it (kernel cost isolation).
- **Budget disabled** (S7): main deadline = never. The countdown and the
  slow path still run, so an external stop can still terminate the hog.

## Shell turns and the frame account

The shell gives the VM the main thread in *turns*: on every display-link
tick, on every native event, and on every `wakeMain`. Each turn's budget is
`min(turnBudget, frameRemaining)` where:

- tick turn budget 3 ms, event and wake turns 1 ms;
- `frameRemaining` starts each frame (display tick) at **4 ms** of the
  ~8.3 ms frame and is reduced by the time every turn actually took;
- when `frameRemaining` is spent, turns still run with a 0.5 ms budget but
  only UI-priority (2) Processes (`minPriority = 2`), so event handling is
  never starved by a background main-affine hog.

**Stuck report**: each Process's record holds `runnableSince`, set when it
becomes ready from a wait (or is created) and cleared when it waits or
terminates. After each turn the shell checks the main worker's queue and
current Process; a main-affine Process runnable for more than **300 ms**
gets one report: `STUCK process=<id> method=<selector> ms=<age>`. With the
budget disabled the shell never regains the thread, so the app also runs
the same check from an off-main watchdog thread (which is how S7 reports).

## Hop to main

UI primitives: `setLabel:` (SmallInteger, shown in the label), `appendLine:`
(SmallInteger, appended to the text view), `sliderValue` (answers the
slider's value). Each checks `w.isMain`:

- **on main**: call the shell hook (C function pointer, `@MainActor` code on
  the other side), answer its result.
- **off main**: set `affinity = main`, record `hopStart`, suspend with
  `pc` rewound to the `send` and the stack untouched, append to the main
  ready queue at the Process's priority, call `wakeMain`, leave. The main
  worker later runs the same `send` again; this time `isMain` holds and the
  primitive runs. A primitive therefore must not have side effects before
  its affinity check.
- `wakeMain`: a hook set by the shell. The app's hook coalesces with an
  atomic flag and does `DispatchQueue.main.async { turn(.wake) }`, so the
  hop does not wait for the next display tick. Tests install a hook that
  signals the fake main thread's condition variable.
- `Processor detachFromMain` (primitive): `affinity = any`, suspend, append
  to the "any" queue. S6 uses it to go back to the background after each
  update.
- Measured: hop latency (`hopStart` to the main worker resuming the
  Process) and main time per hop (resume on main to leaving main).

## External signals

- **Queue**: lock-free MPSC Treiber stack of `malloc`ed nodes `{sem oop,
  root handle, next}`; producers CAS-push, the consumer takes the whole list
  with one `exchange(nil)` and reverses it to FIFO. No ABA (the consumer
  never pops single nodes). `signalFromOutside(vm, sem, handle)` is callable
  from any thread, takes no lock, touches no heap memory, then wakes a
  worker: `pthread_cond_signal` if a background worker is idle, and
  `wakeMain` if the main worker is the only one that could drain it (the app
  always has background workers).
- **Pending roots**: a primitive that starts an operation registers its
  Semaphore in a root table (capacity 65 536, free list, own mutex) and
  passes the handle to the completion handler. The table is scanned as GC
  roots. Draining signals the Semaphore and frees the handle.
- **Draining**: at budget checks (every N polls), when a worker becomes
  idle or wakes, and at the start of every main turn. Only workers inside
  the VM drain, so signalling is ordinary `Semaphore signal`.
- **IO primitives**: `nil delay: ms signal: sem` (GCD `asyncAfter` on a
  global queue), `nil readFile: aSymbol signal: sem` (DispatchIO reads the
  whole file into a native buffer, answers a handle) and `nil ioResult:
  handle` (copies the bytes into a ByteArray on the VM thread; completion
  handlers never touch the heap). Each starts the operation and returns;
  the Process then waits on its Semaphore. No primitive blocks.
- **Events**: the shell appends `{kind, value, enqueueTicks}` to a native
  ring buffer (65 536 entries, mutex) and calls `signalFromOutside` on the
  event Semaphore (global slot 1, a permanent root). The UI Process loops
  `eventSem wait. ev := nil nextEvent. ...handle...`. `nextEvent` pops one
  event and stores its enqueue time in the main worker as "current event";
  `setLabel:` records `now - currentEvent` as the event-to-view latency.

## GC roots

Host roots, globals, special selectors, class table (as before), plus:
ready-queue heads/tails, every live `ProcRec`'s process oop, every live
stack `[base, sp]` (running: the worker's flushed `sp`; suspended: the saved
`sp` slot), the pending-root table. Workers flush `sp/pc/hdr/fp` at every
park point and before every primitive. A worker clears its `current` and
the record's `runningOn` *before* it publishes a suspended Process to a
queue, so no stack is ever scanned through a stale `sp`.

## Primitives added (`kernels/lib.kasm`)

| # | selector | |
|--:|---|---|
| 20 | `Object fork:with:priority:main:exit:` | answers the new Process |
| 21 | `UndefinedObject yield` | |
| 22 | `Semaphore wait` | |
| 23 | `Semaphore signal` | |
| 24 | `Process terminate` | |
| 25 | `UndefinedObject delay:signal:` | GCD timer |
| 26 | `UndefinedObject readFile:signal:` | DispatchIO; answers a handle |
| 27 | `UndefinedObject ioResult:` | ByteArray |
| 28 | `UndefinedObject nextEvent` | SmallInteger `kind << 32 | value`, or nil |
| 29 | `UndefinedObject setLabel:` | UI, hops |
| 30 | `UndefinedObject appendLine:` | UI, hops |
| 31 | `UndefinedObject sliderValue` | UI, hops |
| 32 | `UndefinedObject detachFromMain` | |
| 33 | `UndefinedObject activeProcess` | |
| 34 | `UndefinedObject workerId` | for tests |
| 14, 15 | `globalAt:`, `globalAt:put:` | kept from B |

`Semaphore new` is Smalltalk (`basicNew`, then `excessSignals := 0`).

## Scenarios (the app)

Window 480×320 pt: a 60×60 layer rotating forever via `CABasicAnimation`
(render-server driven, so it animates even when the main thread stalls), a
label, a text view (trimmed to its last 200 lines), a slider. Frames: an
`NSView.displayLink` (`CADisplayLink`, macOS 14+) in common modes with
`preferredFrameRateRange` 120/120; each callback records `link.timestamp`.
Nominal interval = `1 / NSScreen.maximumFramesPerSecond`; a drop is a gap
> 1.5× nominal; "missed frames" = Σ round(gap / nominal) − 1 over drops.
The reported refresh rate is frames / measured seconds. One second of
warm-up, then 10 s measured. Seven background workers in every scenario.
Heap 64 MiB. VM time per frame capped by the frame account above.

| id | load | parameters |
|---|---|---|
| S0 | none | VM booted, workers idle, display ticks still enter `runMain` |
| S1 | UI Process (main, priority 2) | events from a 1 ms `DispatchSourceTimer` on the main queue, catch-up so exactly 1000/s are enqueued; each handler spins ~50 us (calibrated at start-up) and calls `setLabel:` with a counter |
| S2 | S1 + hog | `nil hog` forked main-affine at priority 1: `[true] whileTrue: []` |
| S3 | S1 + deep | a main-affine supervisor forks `deep: 0` with an exit Semaphore, waits, repeats; `deep:` spins ~20 us per level (so a descent of ~1000 levels takes ~20 ms, many budgets) and recurses until the 64 KiB stack overflows |
| S4 | S1 + alloc | 7 background Processes run `alloc`'s `run: 0 of: 8` forever (prelude + `alloc.kasm` loaded by path) |
| S5 | S1 + delays | 10 000 background Processes: `[nil delay: 10 signal: s. s wait. counter signal] repeat`; RSS sampled before forking and after all are parked |
| S6 | hops | 1000 background Processes: `[spin ~1 ms. nil setLabel: k. nil detachFromMain] repeat` |
| S7 | S2, budget disabled | the hog holds the main thread; an off-main watchdog reports it stuck and terminates it 9 s into the measured window so the app can finish |

Every scenario reports: frames, refresh rate, drops, missed frames, gap
p50/p99/max; worst run-loop iteration on main (a `CFRunLoopObserver` on
after-waiting/before-waiting) with the VM time, GC park time and GC enter
wait inside it; turns, VM time on main; event latency p50/p99/max (S1-S5,
S7); stuck reports; and per-scenario extras: S3 overflows, S4 GC count,
time-to-safepoint and pause p50/p99/max, S5 signals/s, RSS delta per parked
Process, scheduler lock contention, worker blocked time, S6 hop latency and
main time per hop p50/p99.

## Kernels

`fib`, `sends`, `arith`, `alloc` from `../vm-language-bench/kernels/` by path,
loaded after the prelude and this experiment's `lib.kasm`; heap 64 MiB. `n`
background workers, `n` Processes forked by the host, each running `nil run:
i of: n`; wall time from first fork to last termination. Builds: `O` and
`O` + `NO_BUDGET`, both also with `align32` (LLVM
`-align-all-nofallthru-blocks=5`), against variant B's `orep-bench B` built
from `../object-representation/swift` into this package's scratch directory
(that tree is not modified). Same session, interleaved, 5 runs, medians.

## Choices (where DESIGN.md left one open)

- No blocks in the bytecode set: `fork` takes a receiver, a selector and one
  argument.
- One scheduler lock for queues and Semaphores; one `next` link.
- Priority only orders the ready queues; a newly ready higher-priority
  Process does not preempt a running lower one (it waits for a budget
  check, a yield or a wait).
- The main worker drains only main-affine queues; background workers only
  "any" queues.
- External signals are drained at budget checks, not every poll, so the hot
  path keeps a single shared flag (`gcRequested`).
- All non-terminated Processes are GC roots via their record (a Process
  waiting on an unreachable Semaphore is never collected).
- Event entries are native structs, not heap objects.
- `Delay` uses `DispatchQueue.global().asyncAfter` (a GCD timer per wait).
- The budget-disabled switch affects the main worker only.
