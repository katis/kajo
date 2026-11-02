# Module 3: workers, safepoints, Processes, scheduler

Status: brief (2026-11-02). Becomes the description of the module as built.

Decision it implements: ADR 0004 (Smalltalk UI code on the main thread with
budgeted preemption), minus the shell. Evidence:
`experiments/ui-thread-scheduling/` (SPEC.md and RESULTS.md, the 120 Hz
scenarios), `experiments/concurrent-young/swift/Sources/VMR/Process.swift`
and its ProcessTests (the later, cleaner Process code), and
`experiments/generational-gc/` (the parked-count regression test).

Ports into `Sources/KajoVM/Workers/` (threads, safepoints, the scheduler)
and `Sources/KajoVM/Processes/` (Process and Semaphore objects, stacks,
preemption, hop, external signals). Module 2's `Interpreter` and `Stack`
become per-worker and per-Process. Tests in `Tests/KajoVMTests/Workers/`
and `Tests/KajoVMTests/Processes/`.

## What it hides

- How many OS threads run Smalltalk, how they are created, their QoS, and
  how they park and wake.
- The safepoint protocol: how every thread inside the VM is brought to a
  stop for module 1's collect and compact, and how a thread outside the VM
  stays out while a stop is in progress.
- What a Process is made of: its object, its native record, its stack, its
  saved registers, and which worker (if any) runs it.
- How a Process is preempted, suspended, resumed, moved between workers and
  terminated.
- How a thread that is not a worker (a completion handler, the shell)
  signals a Semaphore.
- Where idle workers wait, and that they wait untimed.

## What is and is not decided

**Decided by ADR 0004**: the main thread is a worker owned by the shell and
given to the VM in budgeted turns; preemption at bytecode boundaries through
the safepoint poll's countdown; frame stacks belong to Processes; a UI
primitive called off main suspends the Process, marks it main-affine and
retries the send on main; primitives never block, completions go through a
lock-free external signal queue; a stuck main-affine Process is reported
through a hook after a few hundred milliseconds.

**Decided here, and open to change behind the module**:

- Stack segments are fixed-size, one per Process, size a config value
  (default 64 KiB). Growth, segment chaining and freezing suspended
  Processes into heap contexts (`thisContext`, the debugger, snapshots of
  running Processes) wait for the object-model ADR and module 8. Nothing
  outside this module may depend on a stack being contiguous or fixed.
- Three priorities, two affinities, FIFO per queue, one scheduler lock.
  Per-worker queues with stealing are the known next step when a counter
  shows the lock contended; the queue shape is hidden.
- Process and Semaphore are well-known classes 13 and 14 in object model v0
  (Message is 12); user classes start at 15. Their slot layouts are this
  module's and are sealed from Smalltalk the way Class, Method and
  MethodDict are in module 2 (no primitive reads or writes to a Process's
  saved registers or record index).
- Background workers run at user-initiated QoS; the main worker has
  whatever QoS the shell's thread has. Smalltalk priority is not mapped to
  QoS yet. Every worker logs the QoS it actually got in a counter the tests
  read (AGENTS.md: default pthread attributes give `default`).

**Not this module**: nurseries and anything generational (module 4),
concurrent marking (5), relocation and frame pins (6), the AppKit and UIKit
shells and the display link (9). The native event ring buffer and
`nextEvent` are shell concerns; this module gives them `signalFromOutside`
and a Semaphore to wait on. The scenario app's 120 Hz measurement cannot be
re-run here; what can be measured headlessly is listed under "Done when".

## Design

### Workers

A `Worker` is one 128-byte aligned allocation per thread: the module 2
`InterpreterState` (its own lookup cache, allocation context and counters),
`current` (Process oop or 0), `isMain`, `leave`, `countdown`, `deadline`
(mach ticks), `slice`, and the safepoint fields the protocol needs. Workers
are OS threads, never Swift `Task`s. Lock-guarded state lives in separate
allocations, one per lock (scheduler, safepoint, pending roots), never as
fields of a struct another thread reads through.

The pointer to the VM is one struct (`VMState`) holding pointers to the
object memory, the worker table, and each lock's sub-state. No global
mutable state.

### Safepoint protocol

Two counts under the safepoint mutex: `active` (workers inside the VM) and
`parked` (active workers waiting at a safepoint). A stop requester sets the
flag module 2's poll reads, waits until `parked + 1 == active`, does its
work (module 1's collect or compact, with every stack and every worker's
saved registers as roots), clears the flag, broadcasts. `enter` waits while
a stop is requested, then `active += 1`; `leave` does `active -= 1` and
broadcasts.

Rules carried from the experiments, each with its test:

- A worker released from one stop is not counted as parked for the next
  (generational-gc's regression test; two stops back to back).
- Workers flush `sp`, `pc`, `fp`, `hdr` to the saved form at every park
  point and before every primitive that can pause; the collector scans a
  stack only through a saved `sp`.
- A worker clears `current` and the record's `runningOn` before it
  publishes a suspended Process to a queue, so no stack is scanned through
  a stale `sp` and no stack is scanned twice as "running" and "suspended".
- Wait time at enter, leave and park is counted separately from work time
  (counters `enterWaitNs`, `parkWaitNs`, `stopNs`).
- Idle workers wait untimed on the scheduler condition variable. No timed
  wait anywhere in this module; a Delay is a one-shot GCD timer that
  signals from outside, not a VM wakeup. Test: a VM with eight idle workers
  and no Processes accrues under 1 ms of CPU per worker over a second and
  wakes at most a handful of times (count condition-variable returns).
  Before removing any timeout, audit every transition the wait depends on
  for a signal under the lock, and test that work after idling completes
  within a bound.

### Processes and stacks

Process slots (v0): priority, state (ready, running, waiting, terminated),
waitingOn, affinity, next (one link slot: a Process is in at most one list),
record index, saved sp, pc, fp, hdr as SmallIntegers (module 2's offsets
and word indices, never addresses), result, exitSem, id. Semaphore:
excessSignals, firstWaiter, lastWaiter.

The native record table (fixed capacity, free list under the scheduler
lock): process oop (a root while the Process lives), stack base and end,
`runningOn`, `runnableSince`, `hopStart`, `stuckReported`. A stack is one
segment; only `[base, sp]` is ever scanned. Freed on termination.

Suspension happens only at a bytecode boundary and writes the saved
registers; resumption reads them back and re-derives the two cached bases
from the method (module 2's `restore`). Saved-pc conventions as in the
scheduling SPEC: poll at a backward jump saves the target; poll at a send
rewinds to the send so it is re-executed; a completing primitive that
suspends (wait, yield) saves after the send with the result pushed; a hop
rewinds to the send so the primitive is retried on main. A primitive that
can hop must have no side effects before its affinity check.

Leaving the interpreter: a suspending path saves, sets the worker's `leave`
reason, and hands back registers whose pc is module 2's leave code.
Returning from the bottom frame terminates the Process and stores its
result. Stack overflow terminates the Process with a `VMError` of kind
`stackOverflow` delivered to the exit Semaphore's waiter as the result (an
error object in v0: the `VMError` record kept in the Process's record and
readable from the host), counted; it never kills the VM.

### Scheduler

Ready queues 3 × 2 as head and tail oops in the scheduler sub-state (roots),
linked through `next`. `fork` allocates the Process and its stack before
taking the lock and builds the bottom frame. `yield`, `wait`, `signal`,
`terminate`, `detachFromMain` as in the scheduling SPEC. A ready "any"
Process wakes one idle background worker; a ready main-affine Process calls
the `wakeMain` hook.

Every lock acquisition tries `trylock` first and counts the contended ones
and the wait time; nothing is optimised until a counter says so.

### Budget and preemption

The poll becomes `countdown -= 1; if countdown == 0 || flag { pollSlow }`,
one out-of-line call with nothing of the instruction live across it. The
slow path parks for a stop if one is requested, resets the countdown to N
(default 1024, config), reads `mach_absolute_time`, drains the external
queue if non-empty, and if the deadline has passed or a terminate request
is pending suspends the Process to the back of its queue and leaves. The
main deadline is set at every turn; background slices default to 5 ms.

The host surface: `runMain(budgetNs:minPriority:)` on the shell's thread
(enter, drain, run main-affine Processes at or above `minPriority` until
empty or spent, leave), `signalFromOutside(sem, handle)` from any thread,
hooks `wakeMain` and `stuck`, and `checkStuck(limitNs:)` for the shell to
call after a turn. Hooks are plain C-convention function pointers plus a
context pointer, set before any worker starts, so no closure built in
`@MainActor` context is ever run on a VM thread. The frame account (how
much of a frame the shell gives the VM) is the shell's, not this module's.

### External signals and pending roots

The MPSC Treiber stack of malloc'ed nodes, consumer takes all with one
exchange and reverses, as in the scheduling SPEC. The pending-root table
(own mutex) holds Semaphores that started operations; a handle names a
slot; draining signals and frees. Primitives in v0: `delay:signal:` (GCD
`asyncAfter`, one-shot). File IO waits for module 8's object model (no
ByteArray yet in the kernel).

### Randomized programs and schedule perturbation

This is where `docs/VERIFICATION.md` layers 4 and 5 start.

- A test-side generator emits kasm programs from a seed: allocate, store,
  load, drop, exchange through globals, fork, yield, wait and signal, with a
  deterministic join so the checksum is independent of the schedule. Each
  seed runs on one worker, on eight workers, and under the stress flags
  (collect at every allocation, tiny entry chunks, and the new ones below).
  Checksums and `verifyHeap` must agree. A hundred seeds in the suite, a
  thousand in `just soak`; a failing seed is committed as a named test.
- A `perturb` stress flag, seeded: at poll slow paths, at park points and
  in `fork`, `signal` and `wait`, inject a yield or a short sleep with a
  probability drawn from the seed. The flag is how later modules widen the
  windows of their protocols; here it must at least shake the scheduler and
  the safepoint protocol.
- New stress flags: `preemptEveryPoll` (countdown 1, deadline now) and
  `stopEveryPoll` (every poll slow path requests a stop).

### kajo run

`--workers N` is accepted. The kernels' `run:of:` forks per worker as the
experiments did (`nil kernel:` unpacking stays in the fixtures). `kajo run`
reports per-worker QoS, stops, pause p50, p99 and max with the slowest
participant named, and the scheduler counters.

## Tests to port, and tests that wait

Port first, before reading the experiments' code:

- `experiments/ui-thread-scheduling/swift/Tests/VMPTests/ProcessTests.swift`:
  fork and join, yield order, Semaphore FIFO, terminate in each state,
  preemption of an infinite loop on a fake main thread, hop to main and
  back, stuck report once, external signals from a non-VM thread, pending
  roots surviving a collection, 10,000 parked Processes, stack overflow
  terminates one Process only.
- `experiments/concurrent-young/swift/Tests/VMRTests/ProcessTests.swift`:
  the non-generational ones (resume re-derives bases after a compaction,
  the `result` register, Processes as roots through records, publish after
  clearing `current`).
- `experiments/generational-gc`: a worker released from one stop is not
  parked for the next.
- Module 2's waiting list: `operationsWhileOtherWorkersRun` (become,
  compact, reshape while seven workers allocate), and the kernels on eight
  workers against their single-worker checksums.

Wait: `aFramePinnedObjectIsNotMoved` (module 6), everything generational
and concurrent (4 to 7), the 120 Hz scenarios and event latency (9).

## Done when

- Tests green in debug, under load (a dozen `yes` loops), and under
  ThreadSanitizer; `just ios-check` clean; `just arc-check` extended to the
  poll slow path, `pollSlow` itself, resume and suspend, with zero retain
  and release, and the dispatch loop still one jump table.
- The countdown costs at most 3 percent on `fib` against module 2's
  1642 ms, measured interleaved, five runs each; the other five kernels
  reported with their spread (code placement moves them by ±10 percent;
  say so rather than tune).
- `kajo run --workers 8` scales the compute kernels at least 7x and `alloc`
  at least 5x on the M2 Max, as the language experiment did, with the
  single-thread marking time named as the remainder.
- The idle test above passes: eight idle workers, under 1 ms CPU each per
  second, no timed wait in the module (grep for `timedwait` and
  `asyncAfter` finds only the Delay primitive).
- A hundred randomized seeds green under every stress flag in the suite;
  a thousand in `just soak`, run once and recorded.
- Preemption test: an infinite loop at normal priority on the fake main
  thread never makes a turn overrun its budget by more than 0.2 ms except
  across a stop, with the stop time reported separately.
- `docs/modules/workers.md` rewritten as the description of what was
  built, `docs/CONTEXT.md` gains Worker, Safepoint, Process, Semaphore,
  Turn, Hop, External signal, and ADR 0004 gets a "Built" note with the
  headless numbers and what still waits for the shell.
