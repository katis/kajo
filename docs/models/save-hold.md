# Model check: the save's hold on the scheduler (module 8c)

Status: built (2026-11-04), with module 8c (docs/modules/image-processes.md,
"The save"). `models/Sources/SaveHoldModel/`, tests in
`models/Tests/SaveHoldModelTests/`, on the shared explorer (`ModelKit`).
Any change to how a save quiesces the scheduler updates the model in the
same commit.

```
cd models && swift test --filter SaveHold
```

## What it models

A saver on worker 0 runs its own Process inside the VM. Other workers run
Processes of a few instructions each, taken from one ready queue.

| step | production |
|---|---|
| S holds the scheduler (lock) | `saveImageWithProcesses`: `sched.saveHold = true` under the scheduler lock |
| S sets the mirror and the flag | `vm.saveHold` (relaxed atomic), the flag's bit 0 |
| S's wait ends, it unlocks | `waitServicing { otherRunnersInside }` under the safepoint mutex |
| S requests the stop | `stopWorld` (module 3) |
| S's stop finds a Process running: retry | `anotherProcessRuns` in the stop's work |
| S saves, releases the hold, ends the stop | `saveInStop`, the hold cleared in the stop |
| S broadcasts the idle condition (lock) | `pthread_cond_broadcast(schedCond)` under the scheduler lock |
| W enters / dequeues / leaves | `enterVM`, `dequeueLocked` (refuses while held), the background loop's idle wait (waits while held) |
| W parks at a poll | `pollSlow` → `park` |
| W poll sees the hold: P back to ready | `pollSlow`: `requeueCurrent` as a preemption |
| W runs an instruction (hold read stale or current) | the mirror read without the lock may be late once |

Mutex-protected state is sequentially consistent in the model; the only
lock-free read is the mirror, which a poll may see one write late.

## Claims

1. **Clean save.** When the saver saves, no other Process is running on a
   worker: each is ready (its registers in its Process, at a poll) or
   finished.
2. **Every Process finishes.** No deadlock between the saver's wait and the
   stops, and no idle worker sleeps through the release (lost wakeup).

## Results

| configuration | states | longest trace | result |
|---|--:|--:|---|
| 2 workers, 2 Processes of 2 instructions | 1203 | 22 | both claims hold |
| 3 workers, 3 Processes of 1 instruction | 9827 | 27 | both claims hold |

Each rule off finds its claim broken (the shortest trace is printed by the
test):

| rule off | claim broken |
|---|---|
| the check in the stop, with dequeue ignoring the hold | 1: a worker entered between the end of the wait and the request, dequeued, and was caught mid-slice |
| the poll that puts a held Process back, the wait and the check | 1: the stop alone catches Processes mid-slice (why a stop, as module 8a's install has it, is not enough) |
| the broadcast on release | 2: a worker that went to sleep while the scheduler was held never runs the Processes put back |

What the model does not show: with dequeue refusing while held (the
production rule), the stop's check never fires in the model; it stays as a
verifier (`snapshotRetries` counts it). The model's Processes are finite,
so "the saver waits only until each running Process reaches a poll" is a
liveness argument, not a checked claim: every Process polls at its next
send or backward jump.
