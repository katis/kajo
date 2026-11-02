# Module 3: workers, safepoints, Processes, scheduler

Status: built, 2026-11-02. `Sources/KajoVM/Workers/` (threads, safepoints,
the poll, the run loops, the host surface) and `Sources/KajoVM/Processes/`
(Process and Semaphore layouts, records, queues, suspension, primitives,
external signals). Tests in `Tests/KajoVMTests/Workers/` and
`Tests/KajoVMTests/Processes/`, fixture `Fixtures/kernels/processes.kasm`.

Decision it implements: ADR 0004 (Smalltalk UI code on the main thread with
budgeted preemption), minus the shell. Evidence: experiments/
ui-thread-scheduling (SPEC.md, RESULTS.md, the 120 Hz scenarios),
concurrent-young's Process.swift and ProcessTests, generational-gc's
parked-count regression test. Ported by their tests first.

## What it hides

- How many OS threads run Smalltalk, how they are created, their QoS, and
  how they park and wake.
- The safepoint protocol: how every thread inside the VM is brought to a
  stop for module 1's collect, compact and become, and how a thread outside
  the VM stays out while a stop is in progress.
- What a Process is made of: its object, its native record, its stack, its
  saved registers, and which worker (if any) runs it.
- How a Process is preempted, suspended, resumed, moved between workers and
  terminated.
- How a thread that is not a worker (a completion handler, the shell)
  signals a Semaphore.
- Where idle workers wait, and that they wait untimed.

## Layouts

### Worker (`Workers/Worker.swift`)

One allocation per worker, 128-byte aligned and padded to whole 128-byte
lines (`Worker.bytes`):

| field | |
|---|---|
| `interp` | module 2's `InterpreterState`, **at offset 0**: the interpreter's state pointer is the worker pointer (`workerOf(s)`, a cast), so the loop and the send path are unchanged and the slow paths reach the worker with no load |
| `index`, `isMain`, `vm` | 0 is the main worker; `vm` is nil for module 2's standalone `Interpreter` |
| `dummy` | 16 nil words: the registers a worker leaves with once its Process is published |
| `current`, `record` | the Process it runs and its record index (`.none`, -1 between Processes) |
| `leave` | why the Process left: preempted, suspended, terminated |
| `deadline` | Mach ticks; the budget check preempts at or after it |
| `pollEvery`, `minPriority`, `freshSlice` | |
| `parkNs`, `stopNs`, `enterWaitNs`, `leaveWaitNs` | wait time, kept apart from work (AGENTS.md) |
| `seenEpoch` | the last stop whose pause this worker's lookup cache has seen |
| `rng`, `thread` | perturbation generator; the pthread, if the VM made one |

Only its own thread writes a worker, and only while inside the VM; a
stopper reads the registers of parked workers (ordered by the safepoint
mutex). What other threads read lives in a separate line per worker
(`WorkerShared`: the terminate request, the QoS the thread got, its Mach
thread port), atomics only.

`InterpreterState` gained `countdown` (polls to the next budget check) and
`sendLength` (the instruction a running primitive came from, for a hop);
`ExitReason` gained `.suspended`.

### VM (`Workers/VMState.swift`)

`VMState` is one struct reached through a pointer: the object memory, the
image, the configuration, the worker table, and one separately allocated
sub-state per lock, each lock and condition beside (never inside) what it
guards:

| lock | guards | conditions |
|---|---|---|
| safepoint mutex | `SafepointState`: `active`, `parked`, `requested`, `epoch`, `wakeups`, `lastParker`, the stop log | one, broadcast |
| scheduler mutex | `SchedulerState` (idle count, shutdown, live count, ids, record free list, hop latencies), the ready queues, the record table, every Process's state, priority, affinity, next, saved registers and every Semaphore's slots | `schedCond` (idle background workers), `doneCond` (the last termination) |
| pending mutex | `PendingState` and the pending-root slots | |
| host mutex | the host worker (host calls, one at a time) | |
| errors mutex | `ErrorLog`: the VMError of each Process that failed, by id | |

Plus the safepoint flag every poll reads (`Atomic<UInt32>`, its own
allocation), the external queue head (`Atomic<UInt>`, its own line) and the
counters (relaxed atomics, none on the hot path). No global mutable state.

Workers: 0 is the **main worker** (the shell's thread, inside the VM only
during a turn), 1...N the **background workers** (pthreads at
user-initiated QoS), N+1 the **host worker** (host calls under the host
mutex; it never runs a Process).

### Process and Semaphore (`Processes/ProcessLayout.swift`)

Well-known classes 13 and 14 (Message is 12; user classes start at 15).
Both are sealed through `Image.isStructural`: `at:`, `at:put:`, `basicNew`,
`become:` fail on them and the loader refuses `push_ivar`/`store_ivar` in
their methods, so no Smalltalk code reads or forges a saved register or a
record index.

| Process slot | |
|---|---|
| 0 priority | 0 background, 1 normal, 2 UI |
| 1 state | 0 ready, 1 running, 2 waiting, 3 terminated |
| 2 waitingOn | the Semaphore, or nil |
| 3 affinity | 0 any worker, 1 main |
| 4 next | the one list it is in (a ready queue or one Semaphore's waiters) |
| 5 record | its record index; -1 once terminated |
| 6 sp, 7 pc, 8 fp, 9 hdr | saved registers as SmallIntegers: word indices and the bytecode offset (module 2's form, never addresses). pc is -1 before the first run |
| 10 result | what the bottom method returned |
| 11 exitSem | signalled once on termination, or nil |
| 12 id | unique in a VM, for reports and the error log |

Semaphore: `excessSignals`, `firstWaiter`, `lastWaiter`.

### Records, stacks, queues

The record table (`ProcessRecord`, fixed capacity, default 32 768, free
list under the scheduler lock): the Process oop (a root while live), the
stack's `base` and `end`, `runningOn` (worker index or -1),
`runnableSince` (ticks; 0 while waiting), `hopStart`, `stuckReported`,
`terminateRequested`.

A stack is one malloc'ed segment per Process, `stackWords` (default 8192 =
64 KiB), not initialised: only `[0, sp]` is ever read. Freed at
termination. Nothing outside the module depends on it being contiguous or
of fixed size.

Ready queues: 3 priorities x 2 affinities, head and tail words in one
array under the scheduler lock (0 = empty), linked through `next`, FIFO per
queue, higher priority first. The main worker takes only main-affine
Processes, background workers only "any" ones.

### The frame (module 2's, one word longer)

ADR 0009 section 3 reserves `hdr[4]` for the frame's materialized Context.
Activation writes nil there; nothing reads it yet. `Frame.headerWords` is 5,
so the activation check (`sp + temps + headerWords + maxStack + 1 <
stackEnd`) counts it, and the operand stack starts at `hdr[5]`. The
stack-depth verifier's `maxStack` is the operand depth only and did not
change; saved registers are word indices and did not change.

```
fp[0]               receiver
fp[1 ... argc]      arguments
fp[1 + argc ...]    temps, nil
hdr[0]              method
hdr[1]              caller pc       SmallInteger: bytecode offset
hdr[2]              caller fp       SmallInteger: word index; 0 = the bottom
hdr[3]              caller hdr      SmallInteger: word index
hdr[4]              context         nil (ADR 0009)
hdr[5 ...]          operand stack
```

## The safepoint protocol (`Workers/Safepoint.swift`)

Two counts under the safepoint mutex: `active` (workers inside the VM) and
`parked` (active workers waiting at a safepoint).

- `enterVM`: wait while a stop is requested, then `active += 1`; flush the
  lookup cache if a stop happened since this worker last looked. Answers
  the wait.
- `leaveVM`: `active -= 1`, broadcast. The worker holds no Process and no
  heap reference afterwards and writes nothing of its own struct until it
  enters again.
- `park` (a poll that found the flag set; registers saved): if a stop is
  requested, `parked += 1`, record itself as the last parker, broadcast,
  wait until the epoch changes, count the wakeup. It does **not** decrement
  `parked`.
- `stopWorld(w, retry:, keeping:, work)`: if another stop is requested,
  park for it, then answer false (`retry: false`: an allocation tries its
  context again first) or try again. Else set `requested` and the flag,
  wait until `parked + 1 == active`, unlock, run `work` with the world
  stopped (roots gathered on demand), run the verifiers, relock, clear the
  flag, **zero `parked`**, bump the epoch, log the stop, broadcast.

Roots of a stop (`gatherRoots`, under the scheduler lock): the ready queue
words; every live record's Process, and its stack `[0, sp]` through the
worker's saved sp if `runningOn` names one, else through the sp saved in
the Process (never both, never a stale one); the receiver and method
registers of running workers; every worker's `result` register while it
holds a value; the pending roots; what the stopper keeps. Module 1 adds the
class table and its registry (the host's roots).

Verifiers at every stop (`verifyStops`, on in checked builds and in every
test):

- **stop verifier**: no parker may return from a park while a stop's work
  runs (the wakeup count is the same before and after). This is what the
  parked-count bug violates.
- **schedule verifier**: every worker's `current` names a record that
  names that worker back, and every record with `runningOn` names a worker
  running its Process.

Both count failures and trap under module 1's `.trap` policy.

Rules carried from the experiments, each with its test:

| rule | test | fails without it |
|---|---|---|
| a worker released from one stop is not counted as parked for the next | `backToBackStopsDoNotLetReleasedWorkersRun` | switch `countReleasedAsParked`: the stop verifier counts parkers waking during a stop (in the suite) |
| registers are flushed before a poll parks or stops; a stack is scanned only through a saved sp | `registersAreFlushedBeforeEveryStop` | switch `flushAfterStop`: the Array held only on the operand stack is collected, and the next stop traps in module 1's mark ("marking a reference to a free entry @512"); run by hand, since a trap ends the test process |
| a worker clears `current` and `runningOn` before it publishes a suspended Process | `aSuspendedProcessIsPublishedAfterClearingCurrent` | switch `publishBeforeClearing` (publish, unlock, perturbed window, then clear unconditionally, as the experiment's code did): the schedule verifier counts failures (in the suite) |
| the `result` register is cleared when its Process terminates | `theResultRegisterIsClearedAtTermination` | switch `keepResultRegister`: the dead Cell survives a collection (in the suite) |
| Processes are roots through their records | `processesAreRootsThroughTheirRecords` | |
| resume re-derives the cached bases from the method | `resumeReDerivesBasesAfterACompaction` | |
| pending roots keep Semaphores alive | `pendingRootsSurviveACollection` | |

Inside the module the publish order is also enforced by construction:
suspension writes the saved registers, detaches and publishes in one
critical section, and `detachLocked` only clears a `runningOn` that still
names its own worker.

## Saved-pc conventions

| leave point | saved pc | saved sp |
|---|---|---|
| poll at a backward jump | the jump target | unchanged |
| poll at a send (or a special-selector fallback send) | the send itself (rewound by its length: 3, or 1) | unchanged; receiver and arguments still pushed |
| a completing primitive that suspends (`wait`, `yield`, `detachFromMain`) | after the send | arguments popped, the result pushed |
| hop (a shell call off main) | the send (rewound by `sendLength`) | unchanged: the send is retried on main |
| first run | -1: word 0 holds the method; the worker activates it as the host would | 1 + argc |

A primitive that can hop has no side effect before its affinity check.

## Leaving the interpreter

A suspending path saves, writes the Process's saved registers, detaches,
publishes the Process, sets `exit = .suspended` and the worker's `leave`,
and answers registers whose pc is module 2's leave code and whose stack
pointers are the worker's dummy words (`leavingWithoutStack`): once the
Process is published another worker may run it, so this one never touches
its stack again. `primitiveSend` checks `exit == .suspended` right after
every primitive call (one load). The loop returns on the leave code;
`runSlice` then terminates the Process if it returned (`.returned`, or
`.running` for a primitive at the bottom), failed (`.error`) or was
terminated (`leave == .terminated`).

A VMError (stack overflow included) terminates only its Process: its result
is nil, the VMError is kept by Process id (`vm.error(of:)`), the exit
Semaphore is signalled, and `processErrors` (and `stackOverflows`) count
it. It never stops the VM.

## Scheduler (`Processes/Scheduling.swift`)

- `fork` (primitive 20, and `VM.spawn` from the host) allocates the Process
  and its stack before taking the lock, fills the slots, takes a record,
  and makes it ready (waking an idle background worker or calling
  `wakeMain`).
- `yield`: back of its own queue. `wait`: an excess signal is taken, else
  the Process goes to the end of the Semaphore's waiters (FIFO).
  `signal`: the first waiter becomes ready, else `excessSignals += 1`.
- `terminate`: a ready or waiting Process is unlinked and terminated now; a
  running one (by its state, whatever its record says) gets a request,
  honoured at its next budget check or suspension; the current one ends at
  once; a terminated one is left alone. Termination stores the result,
  frees the record and the stack and signals the exit Semaphore.
- `detachFromMain`: affinity any, back of the "any" queue.
- Every lock acquisition tries first and counts contended acquisitions and
  their wait (`schedContended`, `schedWaitNs`, `safepointContended`,
  `pendingContended`).

## Budget and preemption (`Workers/Poll.swift`)

The poll at every send and backward jump is now

```
countdown -= 1
if countdown == 0 || flag != 0 { pollAndSend / pollAtJump }   // one out-of-line call
```

The slow path (`pollSlow`) flushes the registers, parks if a stop is
requested, and when the countdown is out (the budget check): resets it to
`pollEvery` (1024), maybe perturbs, drains the external queue if it is not
empty, honours a terminate request, and preempts the Process (to the back
of its queue, the send rewound) when `mach_absolute_time() >= deadline`.
Background slices are 5 ms (`sliceNs`, 0 = none); the main deadline is set
by every turn.

`arm64` of the hot path (release build of `just arc-check`): at a send the
poll is `ldr; subs; str; b.eq` on the countdown (`[x19, #0x130]`), then
`ldr` of the flag pointer from the state, `ldr; cbz` of the flag; at a
backward jump the flag pointer stays in a register (`ldr w9, [x25]; cbz`).
`interpret` is 731 instructions (710 in module 2) with one indirect branch
and one jump table.

## Host surface (`Workers/VM.swift`, internal)

```swift
VM(image:config:); vm.start(); vm.shutdown(); vm.destroy()
vm.hooks = VMHooks(context:, wakeMain:, stuck:, shell:)   // C function pointers, before start
vm.ref.signalFromOutside(sem, handle:)                     // any thread (VMRef is Sendable)
vm.runMain(budgetNs:minPriority:) -> TurnStats             // the shell's thread: one turn
vm.checkStuck(limitNs:)                                    // the shell, after a turn
vm.spawn(receiver:selector:arguments:priority:main:exit:keep:) -> Oop?
vm.state(of:), vm.result(of:), vm.error(of:), vm.release(_:)
vm.signal(_:), vm.terminate(_:), vm.terminateAll(), vm.newSemaphore(), vm.newArray(_:)
vm.collect(), vm.compact(), vm.become(_:_:), vm.withWorldStopped(_:), vm.inspect(_:)
vm.global(_:), vm.setGlobal(_:_:), vm.excessSignals(_:), vm.waiterCount(_:)
vm.liveProcessCount, vm.waitUntilAllTerminated(), vm.runOneSlice(worker:budgetNs:)  // tests
vm.counters, vm.stops, vm.hopLatencies, vm.workerQoS(_:), vm.workerCPUNanoseconds()
```

`TurnStats`: `ns`, `cpuNs` (the thread's CPU time), `enterWaitNs`,
`leaveWaitNs`, `parkNs`, `stopNs`, `slices`, `preempted`; `pausedNs` sums
the waits. Every host call enters the VM on the host worker, so host code
never reads the heap outside the VM. The hooks: `wakeMain(ctx)` (a
main-affine Process became ready), `stuck(ctx, id, selector, ms)` (once per
Process), `shell(ctx, kind, value) -> Int64` (primitive 29 on main). They
are set before any worker starts.

## External signals and pending roots (`Processes/External.swift`)

`signalFromOutside` pushes a malloc'ed node `{sem, handle, next}` onto a
Treiber stack with one CAS loop, touches no heap, then takes the scheduler
mutex just long enough to signal an idle background worker (and calls
`wakeMain` when there are no background workers). A worker inside the VM
drains it with one exchange, reverses it to FIFO and signals each
Semaphore, at budget checks, at the start of every turn and slice, and when
an idle worker wakes. The pending-root table (65 536 slots, free list, own
mutex) roots a Semaphore while an operation that will signal it is
outstanding; draining frees the slot. A drained Semaphore that is no longer
a used Semaphore entry is counted (`staleExternalSignals`), not signalled.

`delay:signal:` (primitive 25) is a one-shot `DispatchQueue.global().
asyncAfter`. It is the only `asyncAfter` in the module, and nothing in the
module uses `pthread_cond_timedwait`.

## Primitives (`Processes/ProcessPrimitives.swift`)

| # | selector | checks |
|--:|---|---|
| 20 | `fork:with:priority:main:exit:` | argc 5; selector a Symbol whose method exists for the receiver, has no primitive and takes at most one argument; priority nil (the forker's) or 0...2; main true or false; exit nil or a Semaphore. Fails when the record table is full |
| 21 | `yield` | argc 0 |
| 22 | `Semaphore wait` | receiver a Semaphore |
| 23 | `Semaphore signal` | receiver a Semaphore |
| 24 | `Process terminate` | receiver a Process |
| 25 | `delay:signal:` | ms a SmallInteger 0...2^31-1; a Semaphore; fails when the pending table is full |
| 26 | `newSemaphore` | argc 0 |
| 29 | shell call (`setLabel:` in the tests) | argc 1; on main the `shell` hook, off main a hop; fails at the bottom of a Process |
| 32 | `detachFromMain` | argc 0 |
| 33 | `activeProcess` | argc 0 |
| 34 | `workerId` | argc 0 |

Every one fails outside a VM (module 2's standalone interpreter).

## Stress flags and perturbation

| flag | effect |
|---|---|
| `preemptEveryPoll` (`--stress preempt`) | countdown 1; every poll but the first of a slice preempts |
| `stopEveryPoll` (`--stress stop`) | countdown 1; every poll stops the world and collects |
| `Perturbation(seed:, probability:, maxSleepUs:)` | at budget checks, parks, fork, signal and wait, a worker yields or sleeps up to `maxSleepUs` with that probability, from a per-worker generator seeded from `seed` |

Module 1's flags (`every`, `tiny`, `oneblock`) apply unchanged; with
workers a collection at every allocation is a stop at every allocation.

## kajo run

`kajo run <files> --workers N [--slice-ms 5] [--stress ...]` forks one
Process per worker running `nil run: i of: N` on N background workers,
waits for all of them, and prints the sum of their answers, the time from
the first fork to the last termination, the counters, the QoS each worker
got, the stops with pause p50, p99, max and the slowest participant (the
worker that parked last in the longest stop), and the scheduler counters.

## Unsafe surface

653 lines with `unsafe` in `Workers/` and `Processes/` (comments excluded):
Scheduling 147, VM 129, Run 110, Safepoint 105, External 45, Poll 39,
ProcessPrimitives 25, VMState 25, Worker 24, VMConfig 5, ProcessLayout 0.
Almost all of it is one kind: the VM, worker and record pointers
(`UnsafeMutablePointer<VMState>`, `<Worker>`, `<ProcessRecord>`) passed
and dereferenced, plus the pthread calls, the stacks' malloc, the Treiber
nodes and `thread_info`. `VMState`, `Worker`, `SafepointState`,
`ProcessRecord` and `VMHooks` are `@unsafe`; `VM`, `VMRef` and
`StopContext` are `@safe` wrappers, so `Headless` uses the VM without any
(its 2 are `String(format:)`'s C varargs in the stop report) and the tests
need none. ProcessLayout, the configuration and
the counters' snapshot are safe code. A clean build had 82 unmarked sites
that the incremental builds never re-reported; every one is marked now.

Module 2's counts changed with it: Send 126 to 135, Dispatch 82 to 84,
InterpreterState 22 to 37 (the stop paths), Interpreter 44 to 34 (it
allocates a Worker now). Module 1: unchanged.

## Changes to modules 1 and 2

Module 1: no code change. Its `allocate` (collect, then compact, inline)
now runs inside a stop, called by the stopper with every root;
`retireAllContexts` is called by the tests before they verify.

Module 2 (each change the brief asked for, or the ADR 0009 frame word):

- `ObjectModel.swift`: Process 13 and Semaphore 14 well-known, their
  instance sizes; `firstUserClass` is 15. `ImageTests.
  tooManyClassesAndMethodsAreRejected` counts from 15.
- `Image.isStructural` includes Process and Semaphore (sealed).
- `Stack.swift`, `Send.swift`: `Frame.context = 4`, `headerWords = 5`, nil
  written at activation (ADR 0009 section 3).
- `InterpreterState`: `countdown`, `sendLength`, `ExitReason.suspended`; it
  is the first field of a `Worker` instead of its own allocation. `Machine.
  collect`, `compact`, `become` and `allocateSlow` go through `stopWorld`
  inside a VM (an allocation that finds another stop in progress parks for
  it and tries its context again before stopping the world itself);
  `Machine.argument(_:of:)` reads arguments past the second.
- `Interpreter` (the standalone runner of module 2's tests) allocates a
  `Worker` with no VM and its own flag; its polls behave as before (the
  test switch collects).
- `Send.swift`: the poll counts down (`countdown -= 1; if countdown == 0 ||
  flag`); `pollAndSend` and `pollAtJump` flush the registers
  (`flushForPoll`), call `pollSlow`, and leave without touching the stack
  (`leavingWithoutStack`) when the Process left the worker;
  `primitiveSend` records `sendLength` and checks `exit == .suspended`
  after every primitive.
- `Dispatch.swift`: backward jumps poll through `pollDue` (the countdown
  and the flag).
- `Primitives.swift`: 20...34 go to `processPrimitive`.
- `Headless.run` runs through a VM: one Process per worker; `Options`
  gained `vmStress` and `sliceMs`, `Outcome` gained `report`. `kajo run`
  accepts `--workers N`, `--slice-ms`, `--stress preempt,stop`.
  `HeadlessTests` refuses 0 workers instead of 2 and gained
  `headlessRunOnFourWorkers`.

## Measurements

All on the M2 Max (8 P + 4 E cores), macOS 27, Swift 6.4, release builds,
2026-11-02 20:51 to 20:55, load average 3.6 to 4.3 (1 min) with Firefox,
Warp and this agent the busiest other processes. Kernels through `kajo
run` with the default 1 GiB heap and 5 ms background slices.

### The countdown, interleaved against module 2

Module 2's `kajo` built from the brief's commit (`daa921a`, a worktree in a
scratch directory, `swift build -c release --product kajo`), run
alternately with this module's (`--workers 1`: the kernel as one Process on
one background worker), five runs each, same session:

| kernel | module 2 median (min to max) | module 3 median (min to max) | ratio |
|---|--:|--:|--:|
| **fib** | **1667.7** (1665.1 to 1672.5) | **1714.1** (1712.9 to 1724.0) | **1.028** |
| arith | 2435.3 (2431.1 to 2595.0) | 2429.5 (2429.0 to 2468.8) | 0.998 |
| sends | 2467.8 (2460.1 to 2684.8) | 2545.1 (2531.6 to 2576.4) | 1.031 |
| alloc | 2477.6 (2476.9 to 2508.8) | 2528.0 (2511.7 to 2543.3) | 1.020 |
| ivars | 2004.4 (1999.1 to 2006.7) | 2101.3 (2092.9 to 2108.8) | 1.048 |
| walk | 3515.2 (3446.9 to 3550.2) | 3540.3 (3455.2 to 3571.2) | 1.007 |

fib costs 2.8 percent against module 2 measured in the same session (its
1642 ms of the module 2 doc was 1667.7 today; against that old figure
1714.1 would be 4.4 percent, which is the session, not the code). It
includes everything the module adds to a run, not only the countdown: the
Process, its 5 ms slices (336 preemptions in a fib run) and the
`exit == .suspended` load after every primitive. The other kernels move
between -0.2 and +4.8 percent; the experiments saw code placement move
these kernels by up to 14 percent in either direction with the countdown
alone (ui-thread-scheduling RESULTS section 2), so these are reported, not
tuned. Every checksum is the published one; `just golden` the same day:
arith 2420.7, fib 1681.4, sends 2532.8, alloc 2482.4, ivars 2065.4, walk
3471.4 ms, all ok.

### Eight workers

`--workers 1` against `--workers 8`, interleaved, five runs each:

| kernel | 1 worker | 8 workers | speedup | stops (8) |
|---|--:|--:|--:|---|
| fib | 1686.2 | 226.8 | **7.43** | 0 |
| arith | 2437.5 | 344.6 | **7.07** | 0 |
| sends | 2553.0 | 339.8 | **7.51** | 0 |
| ivars | 2081.8 | 274.4 | **7.59** | 0 |
| walk | 3539.5 | 407.7 | 8.68 | 0 |
| alloc | 2524.7 | 417.4 | **6.05** | 2 per run, pause 35.4 to 36.7 ms each, about 70 ms per run |

Every worker reported QoS 25 (`QOS_CLASS_USER_INITIATED`). The compute
kernels scale 7.1 to 7.6x. `alloc` scales 6.05x: of the 102 ms it is above
an ideal 8x (315.6 ms), 70 ms are its two stop-the-world collections, each
one worker marking and sweeping a 1 GiB heap alone while seven are parked
(the single-thread marking time); the slowest participant to park differed
from run to run (workers 2, 4, 5, 8, 2). walk's 8-worker run is not the
same work as its 1-worker run (its checksum differs: each worker walks its
own part of the graph), so its 8.7x is not a speedup; nor are sends',
ivars' and alloc's 8-worker checksums the single-worker ones (they are the
experiments' 8-worker checksums where those were published: sends
133333335000001, alloc 42008248).

### Idle

`idleWorkersCostNothing`: eight background workers and no Process, one
second: 0 ns of CPU on every worker (the probe is microsecond grained; the
test proves it reads real time with a 50 ms spin) and 0 condition-variable
returns, in debug, release, under load and under ThreadSanitizer.
`workAfterIdlingCompletesPromptly`: after 200 ms idle, an external signal
from a non-VM thread completes its waiter within the test's 1 s bound:
0.13 to 1.1 ms alone (the test polls every 0.5 ms), 7 to 10 ms under
ThreadSanitizer. `grep -rn
"timedwait\|asyncAfter" Sources/KajoVM` finds only the Delay primitive.

### Turns

`aTurnOverrunsItsBudgetByAtMostAFifthOfAMillisecond`: an infinite loop at
normal priority on the main worker, 300 turns of 1 ms while three
background workers allocate (so stops land inside turns). Overrun past the
budget with the turn's stop and entry waits taken out:

| run | wall p50 / p99 / max ms | CPU p50 / p99 / max ms | turns with a stop |
|---|---|---|--:|
| debug, alone | 0.010 / 0.046 / 0.054 | 0.009 / 0.022 / 0.033 | 18 |
| release, alone | -0.889 / -0.751 / 0.004 | -0.881 / -0.743 / -0.004 | 299 |
| debug, with the rest of the suite | 0.021 / 5.0 / 10.7 | -0.002 / 0.030 / 0.042 | 9 |
| debug, suite under 12 `yes` (load 40) | 0.019 / 12.4 / 15.0 | 0.011 / 0.034 / 0.035 | 8 |

(In release every turn met a stop, whose time counts toward the deadline,
so turns end early.) The VM's own overrun stays under 0.05 ms everywhere;
the wall tail under load is the OS descheduling the thread (AGENTS.md).

## Tests

32 test functions in this module (153 in the suite): 31 in
`Tests/KajoVMTests/Processes/` and `Workers/`, plus
`headlessRunOnFourWorkers`.

Gates on 2026-11-02, the final code: `swift test` green; under load (12
`yes`, load average 40) green; `swift test --sanitize=thread` green with
no ThreadSanitizer report (251 s); `just test-release` green; `just golden`
all ok; `just ios-check` clean; `just arc-check` zero retain and release on
every checked path and the dispatch loop one jump table (below); a clean
build has no warning.

**Ported from ui-thread-scheduling**: `forkRunsToCompletion`,
`smalltalkForkAndExitSemaphore`, `yieldInterleavesOnOneWorker`,
`semaphoreWaitAndSignal`, `budgetPreemptsAnInfiniteLoop`,
`processMigratesBetweenWorkersMidMethod`, `externalSignalFromANonVMThread`,
`delayWaitUsesAGCDTimerAndPendingRoot`,
`stackOverflowTerminatesTheProcessAndSignalsExit` (plus: only the
overflowing Processes end, and the VMError is readable),
`hopToMainRetriesTheUIPrimitiveOnMain`,
`mainAffineHogIsPreemptedAndReportedStuck` (stuck reported once),
`gcKeepsParkedProcessStacksAlive`, `manyProcessesOnManyWorkers`. New for
the brief's list: `semaphoreWaitersAreFIFO`, `terminateInEachState`
(ready, waiting, running elsewhere, itself, already terminated),
`pendingRootsSurviveACollection`, `tenThousandParkedProcesses`.

**From concurrent-young** (its ProcessTests are the same tests; its rules
became these): `resumeReDerivesBasesAfterACompaction`,
`theResultRegisterIsClearedAtTermination` (with the rule off the dead Cell
survives), `processesAreRootsThroughTheirRecords`,
`aSuspendedProcessIsPublishedAfterClearingCurrent` (with the rule off the
schedule verifier fires).

**From generational-gc**: `backToBackStopsDoNotLetReleasedWorkersRun`
(with the rule off the stop verifier fires).

**Module 2's waiting list**: `operationsWhileOtherWorkersRun` (become,
compaction and reshape of a class with live instances, in stops, while
seven workers allocate and compute; every checksum right),
`kernelsOnEightWorkersMatchTheirModels` (the six kernels scaled down, eight
Processes on eight workers, against the Swift models).

**New**: `registersAreFlushedBeforeEveryStop`, `idleWorkersCostNothing`,
`workAfterIdlingCompletesPromptly`, `backgroundWorkersRunAtUserInitiatedQoS`,
`aTurnOverrunsItsBudgetByAtMostAFifthOfAMillisecond`,
`randomProgramsAgreeWithTheirModel`, `randomProgramsAreDeterministic`,
`headlessRunOnFourWorkers`.

**Rules checked by switching them off**: parked count, publish order and
the result register in the suite (each a parameterized test whose broken
case must see the failure); the register flush by hand (with
`flushAfterStop` the run trapped in module 1's mark, "marking a reference
to a free entry @512"; the crash report is from 19:33 that day).

### Randomized programs (`Workers/RandomPrograms.swift`)

A seed gives a root and 2 to 6 task Processes: allocate, store, load one
or two levels deep, drop, nest Arrays, publish through a global Array,
garbage loops (backward jumps poll), yield, signal the next task in a
first half and wait on its own Semaphore in a second (so no schedule
deadlocks), then a deterministic join (the root waits on every exit
Semaphore and sums answers and published trees). A Swift model of the same
program computes the answer. Seven configurations: one worker, eight,
module 1's collect-at-every-allocation and tiny entry chunks, this
module's `stopEveryPoll` and `preemptEveryPoll`, and perturbation (seeded
from the program's seed, 2 percent, up to 30 us); each run also checks
that the stress happened (stops, preemptions, stress collections) and the
heap verifiers at the end.

- In the suite: 100 seeds per configuration (10, and 2 under
  `stopEveryPoll`, when ThreadSanitizer is detected), 18 s in debug.
- `just soak` (1000 seeds per configuration, release with
  `-enable-testing`), run once: seeds 1 to 1000, all seven configurations,
  no failure, 18.3 s. Also `just soak 2000 1001`: seeds 1001 to 3000, no
  failure, 35.9 s.
- No seed failed. The generator found one bug before any seed was
  recorded: `preemptEveryPoll` hung every program (deviation above); the
  configuration itself is now its regression test.

### Hot-path check

`just arc-check` (2026-11-02, final code) adds `pollSlow`,
`stopIfStressed`, `park`, `enterVM`, `leaveVM`, `requeueCurrent`,
`suspendLocked`, `suspendAfterPrimitiveLocked`, `finishSuspend`,
`detachLocked`, `makeReadyLocked`, `dequeueLocked`, `waitSemaphore`,
`signalSemaphore`, `signalLocked`, `terminateCurrent`, `runSlice` (resume
and the first activation) and `drainExternal` to module 1's and 2's lists:
zero `swift_retain`/`swift_release` in all of them; `interpret` one
indirect branch and one jump table.

## Deviations

- **The wakeup in `signalFromOutside` takes the scheduler mutex.** The
  push is lock-free and touches no heap, as the SPEC says; signalling the
  idle workers' condition under its mutex is what keeps their untimed wait
  from missing the signal (the predicate is checked under that mutex). The
  experiment did the same.
- **Fork does not build the bottom frame.** It stores the method in word 0
  of the new stack with pc -1; the worker activates it on the first run as
  the host would (`invoke`), so a primitive method, an overflow at the
  first activation, and the activation's own checks happen on a worker in
  the ordinary way. Smalltalk's fork takes a method of at most one argument
  (as the experiment's); `VM.spawn` from the host takes up to 16, which is
  how `kajo run` gives each worker `run: i of: n` without `kernel:`
  (`kernel:` stays in `processes.kasm` for Smalltalk-side forks).
- **The VMError of a failed Process is kept in a VM-wide log by Process
  id**, not in its record: records are freed at termination. Its result is
  nil; `vm.error(of:)` reads the error. There is no error object in the
  heap yet (v0 has no class for it).
- **Each worker flushes its own lookup cache** when it sees that a stop
  happened (at the end of a park and at enter), instead of the stopper
  writing every worker's cache: no thread writes another worker's struct.
- **Verifiers at every stop**: the stop verifier (no park returns during a
  stop's work) and the schedule verifier (records and workers agree), on in
  checked builds. Not in the brief; they are how the parked-count and
  publish-order rules fail without crashing.
- **`detachLocked` clears `runningOn` only while it still names the
  worker**, a defence on top of the publish-order rule. The test switch
  clears it unconditionally, as the experiment's bug did.
- **`terminate` decides by the Process's state**: a running Process always
  gets a request, even if its record names no worker (found when the
  broken-order test terminated a Process whose `runningOn` the bug had
  cleared, and freed its record under the worker running it).
- **`preemptEveryPoll` lets the first poll of a slice pass.** "Deadline
  now" at every poll livelocks: a Process preempted at a send is resumed at
  that send, polls, and is preempted again (found by the randomized
  programs, which hung under the flag).
- **Stress flags set `pollEvery` to 1**; perturbation runs at budget checks
  (every poll under the stress flags), parks, fork, signal and wait.
- **One shell-call primitive (29)** with a generic `shell(ctx, kind,
  value)` hook stands for the UI primitives; the experiment's 30 and 31,
  `readFile:signal:` (26 there; `newSemaphore` is 26 here), `ioResult:` and
  `nextEvent` are not here. A hop at the bottom of a Process (forking a
  shell call directly) fails, since there is no send to retry.
- **The turn bound is asserted on the turn's CPU time.** Wall-clock
  overruns include the OS descheduling the thread, which the suite under
  load does constantly; the wall figures are reported beside it. Under
  ThreadSanitizer the bound is reported only.
- **The flush-before-stop rule's broken variant is run by hand**: with the
  rule off the next stop traps in module 1's mark in a checked build, which
  ends the test process.
- **`VM.destroy` requires every Delay to have fired** (a GCD timer firing
  after it would touch freed memory). Nothing cancels a Delay yet.
- **The main worker's QoS is logged at every turn** (it has no thread of
  its own to log at start).

## Not done

- The shell, the display link, the native event ring and `nextEvent`, the
  120 Hz scenarios and event latency (module 9); the frame account belongs
  to the shell.
- File IO primitives (`readFile:signal:`, `ioResult:`): no ByteArray IO in
  the kernel yet (module 8).
- Stack growth, segment chaining, freezing suspended Processes into heap
  Contexts (ADR 0009's materialization; the frame word is reserved).
- Per-worker queues with stealing: one scheduler lock, with its contention
  counted.
- Smalltalk priority mapped to QoS.
- Cancelling a Delay; `VM.destroy` with timers outstanding.
- A re-entrancy guard for a nested run loop entering a turn (ADR 0004).
- Loading kasm into a running VM (loads happen before the VM is made).
- `aFramePinnedObjectIsNotMoved` (module 6); everything generational and
  concurrent (modules 4 to 7).
