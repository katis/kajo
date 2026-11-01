# Results: Smalltalk on the main thread with budgeted preemption

Built against `SPEC.md`: variant B of `../object-representation` (object
table) copied into `swift/Sources/VMP` and extended with Process-owned
64 KiB stacks, a scheduler (3 priorities × {any, main} ready queues under one
lock), Semaphores, a budget countdown in the safepoint poll, hop-to-main
with retry of the send, a lock-free MPSC external-signal queue with pending
roots, GCD `Delay`, DispatchIO file reads and a native event queue. The
AppKit app `kajo-ui` runs one scenario per launch. 14 headless tests pass,
also under ThreadSanitizer (`swift test --sanitize=thread`).

All numbers come from one `./bench.sh` run: the summary is in
`bench-output.txt` verbatim, raw lines are in `bench-raw-kernels.txt` and
`bench-raw-scenarios.txt`, and the app's stderr (stuck reports, overflow
log) is in `bench-stderr.txt`. The machine was an Apple M2 Max (8 P + 4 E
cores), macOS 27.0.1, Swift 6.4, with no thread pinning. The built-in XDR
display measured **120.00 Hz** with nothing loaded (S0: 1200 display-link
callbacks in 10.00 s, every gap 8.333 ms). Scenarios ran 3 times for 10 s
each after 1 s of warm-up; the median run is reported (ranked by missed
frames, then maximum gap), and every run's missed count is in the last
column. Kernels ran 5 interleaved times; medians are reported.

## 1. Scenarios

Definitions:

- **drops**: gaps longer than 1.5 × 8.333 ms.
- **missed**: Σ(round(gap / 8.333) − 1) over the drops.
- **cb late**: how long after its vsync timestamp the display-link callback
  ran.
- **ev lat**: from the time a synthetic event was *due* (1000/s grid) to the
  `setLabel:` primitive that shows it. This is what a user would see, and it
  includes the shell's own timer delivery lag.
- **ev post-lat**: from enqueue to `setLabel:`. This is the VM's share.
- **worst iter**: the longest main run-loop iteration (after-waiting to
  before-waiting), with the VM time and GC-park time inside it.

```
| id | refresh Hz | frames | drops | missed | gap p50 ms | gap p99 ms | gap max ms | cb late p99 ms | ev lat p50/p99/max ms | ev post-lat p50/p99 ms | worst run-loop iter ms (VM, GC park) | stuck | per-run missed |
|---|--:|--:|--:|--:|--:|--:|--:|--:|---|---|---|--:|---|
| S0 | 120.00 | 1200 | 0 | 0 | 8.333 | 8.333 | 8.333 | 0.105 | - | - | 2.546 (0.000, 0.000) | 0 | 0, 0, 0 |
| S1 | 119.90 | 1199 | 1 | 1 | 8.333 | 8.333 | 16.731 | 5.837 | 0.631 / 4.971 / 7.767 | 0.120 / 0.814 | 8.612 (0.104, 0.000) | 0 | 1, 0, 1 |
| S1n | 120.00 | 1200 | 0 | 0 | 8.333 | 8.333 | 8.333 | 0.185 | 0.620 / 5.032 / 6.815 (native) | - | 9.122 (0.001, 0.000) | 0 | 0, 0, 0 |
| S2 | 119.60 | 1196 | 2 | 4 | 8.333 | 8.333 | 26.141 | 7.256 | 2.306 / 8.458 / 24.117 | 0.269 / 1.607 | 26.045 (4.022, 0.000) | 1 | 4, 5, 3 |
| S3 | 119.60 | 1196 | 3 | 4 | 8.333 | 8.333 | 24.795 | 6.994 | 1.891 / 7.755 / 17.667 | 0.172 / 1.371 | 18.811 (4.003, 0.000) | 0 | 5, 0, 4 |
| S4 | 119.50 | 1195 | 4 | 5 | 8.333 | 8.333 | 21.123 | 6.502 | 0.637 / 8.472 / 19.070 | 0.055 / 6.867 | 20.821 (1.022, 0.000) | 0 | 5, 0, 7 |
| S5 | 120.00 | 1200 | 0 | 0 | 8.333 | 8.333 | 8.333 | 2.998 | 0.149 / 2.811 / 14.007 | 0.093 / 0.451 | 15.620 (0.965, 0.000) | 0 | 0, 0, 2 |
| S6 | 120.00 | 1200 | 0 | 0 | 8.333 | 8.333 | 8.333 | 0.178 | - | - | 4.220 (0.034, 0.000) | 0 | 0, 0, 0 |
| S7 | 12.00 | 120 | 1 | 1079 | 8.333 | 9.850 | 9001.877 | 0.104 | 8926.059 / 8998.943 / 9000.800 | 5.106 / 9.144 | 9000.812 (8999.947, 0.000) | 1 | 1079, 1079, 1080 |
```

What each scenario loaded (SPEC.md "Scenarios"):

- **S0**: VM booted, 7 idle workers. Display ticks still enter the VM, at
  about 1 µs per turn.
- **S1**: the UI Process handles 1000 events/s, each with about 50 µs of
  Smalltalk (`spin: 2174`, calibrated at start-up) and a `setLabel:`.
- **S1n**: an added control. The same events are handled by the shell in
  Swift (a 50 µs busy loop and the label update); no VM is involved.
- **S2**: S1 plus a main-affine `[true] whileTrue: []`.
- **S3**: S1 plus a main-affine recursion that does ~20 µs of work per level
  until the 64 KiB stack overflows, re-forked by a supervisor: 105
  overflows in 10 s.
- **S4**: S1 plus 7 background Processes running `alloc` forever.
- **S5**: S1 plus 10 000 Processes each looping `Delay 10 ms` and then
  signalling a counter.
- **S6**: 1000 background Processes looping: ~1 ms of compute, `setLabel:`
  (hops to main), `detachFromMain`.
- **S7**: S2 with the main budget disabled.

Main-thread VM time per 10 s: S1 1.35 s, S2 5.22 s, S3 5.14 s, S4 3.46 s,
S5 1.16 s, S6 0.10 s, S7 9.01 s. The frame account (4 ms of VM per frame)
held S2 and S3 at about 52 percent of the main thread.

Scenario extras (median runs):

| | |
|---|---|
| S2 | 2411 preemptions; stuck report `STUCK process=7 method=hog ms=306.72 via=shell` in every run |
| S3 | 105 stack overflows, each terminating the Process cleanly; no stuck report (each recursing Process lives about 100 ms) |
| S4 | 502 GCs; time-to-safepoint p50/p99/max 0.073 / 0.128 / 0.141 ms; stop-the-world pause p50/p99/max 6.41 / 7.74 / 8.04 ms; the main thread waited at entry for an in-progress GC 17 times, at most 7.58 ms |
| S5 | external signals **350 277/s** (ideal 1 000 000/s); counter signals 3.85 M including warm-up; scheduler lock contended on 2.55 M of 14.0 M acquisitions, **39.6 s of worker time waiting on it** in 10 s; 0 s blocked in any primitive |
| S6 | **6751 hops/s**; hop latency p50/p99/max **0.011 / 0.027 / 4.17 ms**; main-thread time per hop p50/p99 **0.96 / 4.62 µs** |
| S7 | `STUCK process=7 ms=309 via=watchdog`; the hog held the main thread for 9.0 s until the watchdog terminated it; 1079 frames missed |

## 2. Kernels against variant B

The VMs, all run in the same session:

- **B**: `orep-bench B` built from `../object-representation` into this
  package's scratch directory.
- **Pnb**: this VM with `-DNO_BUDGET` (Process stacks, scheduler, leave
  check; no countdown).
- **P0**: the countdown, but 5 ms slices off (`KAJO_SLICE_MS=0`).
- **P**: everything, with 5 ms background slices.

Variant B's published numbers (`../object-representation/RESULTS.md`,
`O`): arith 3013.8 / 406.0, fib 1550.4 / 202.5, sends 2464.6 / 331.0, alloc
2155.1 / 400.7 ms at 1 / 8 workers. This session's B agrees with them to
within 1 to 7 percent.

```
| kernel | workers | build | B ms | Pnb ms | P0 ms | P ms | Pnb/B | P0/Pnb | P/P0 | P/B | checksum | equal |
|---|--:|---|--:|--:|--:|--:|--:|--:|--:|--:|---|:-:|
| fib | 1 | O | 1550.9 | 1549.4 | 1585.0 | 1583.8 | 0.999 | 1.023 | 0.999 | 1.021 | 24682992 | yes |
| fib | 1 | align32 | 1552.2 | 1550.8 | 1586.3 | 1587.4 | 0.999 | 1.023 | 1.001 | 1.023 | 24682992 | yes |
| fib | 8 | O | 202.0 | 201.1 | 216.6 | 205.6 | 0.996 | 1.077 | 0.949 | 1.018 | 24682992 | yes |
| fib | 8 | align32 | 200.9 | 203.7 | 211.6 | 213.8 | 1.014 | 1.039 | 1.010 | 1.064 | 24682992 | yes |
| sends | 1 | O | 2474.7 | 2622.2 | 2292.1 | 2287.9 | 1.060 | 0.874 | 0.998 | 0.925 | 1066666666666668 | yes |
| sends | 1 | align32 | 2643.5 | 2638.7 | 2277.7 | 2272.6 | 0.998 | 0.863 | 0.998 | 0.860 | 1066666666666668 | yes |
| sends | 8 | O | 326.4 | 352.1 | 305.5 | 311.1 | 1.079 | 0.868 | 1.018 | 0.953 | 133333335000001 | yes |
| sends | 8 | align32 | 353.3 | 352.8 | 304.4 | 305.2 | 0.999 | 0.863 | 1.003 | 0.864 | 133333335000001 | yes |
| arith | 1 | O | 3015.8 | 3087.1 | 2753.3 | 2752.9 | 1.024 | 0.892 | 1.000 | 0.913 | 372800000 | yes |
| arith | 1 | align32 | 3013.8 | 3010.4 | 2742.8 | 2743.1 | 0.999 | 0.911 | 1.000 | 0.910 | 372800000 | yes |
| arith | 8 | O | 406.2 | 425.6 | 369.4 | 374.7 | 1.048 | 0.868 | 1.014 | 0.922 | 372800000 | yes |
| arith | 8 | align32 | 403.9 | 407.1 | 367.8 | 372.2 | 1.008 | 0.903 | 1.012 | 0.922 | 372800000 | yes |
| alloc | 1 | O | 2153.8 | 2133.7 | 1876.5 | 1875.2 | 0.991 | 0.879 | 0.999 | 0.871 | 41950911 | yes |
| alloc | 1 | align32 | 2168.1 | 2144.1 | 1863.9 | 1866.7 | 0.989 | 0.869 | 1.002 | 0.861 | 41950911 | yes |
| alloc | 8 | O | 411.4 | 406.1 | 367.0 | 359.2 | 0.987 | 0.904 | 0.979 | 0.873 | 42008248 | yes |
| alloc | 8 | align32 | 401.3 | 408.8 | 361.9 | 370.4 | 1.019 | 0.885 | 1.023 | 0.923 | 42008248 | yes |
```

Reading the table:

- **Process-owned stacks, the scheduler and the leave check (Pnb/B)** cost
  nothing measurable. In the align32 build the ratio is 0.99 to 1.02 on
  every kernel. The O build shows +2 to +8 percent on sends and arith, but
  align32 removes it, so that is code placement. This is expected by
  design: the interpreter still reads `w.stackEnd` and `w.sp`, which now
  point into the Process's segment, and the per-primitive `leave` byte
  replaced B's `moved` byte. Scheduling happens once per 5 ms slice (317 to
  575 slices per kernel run, 0 to 36 contended lock acquisitions).
- **Preemption every 5 ms (P/P0)** is within ±2 percent everywhere except
  one noisy 8-worker fib cell (0.95 and 1.01).
- **The budget countdown (P0/Pnb)** costs **+2.3 percent on fib** at 1
  worker, consistently in both builds. On sends, arith and alloc the build
  *with* the countdown is **9 to 14 percent faster**, again in both builds.
  A decrement cannot make the interpreter faster; this is a code-generation
  difference in `run` between the two builds (register allocation or
  block layout, which `-align-all-nofallthru-blocks` does not control). It
  was not dissected. The defensible statement is that the countdown's cost
  is at most about 2 percent on the most poll-dense kernel, and that
  `run`'s code generation is sensitive enough to swamp it.
- In total, the shipped configuration P is within -14 to +6 percent of
  variant B, and every checksum matches.

Kernel side counters (P, O, medians): one Process per worker, 317 to 575
slices per run, sched lock contended 0 to 36 times (≤ 0.14 ms waiting).

## 3. Budget check

- **Clock**: `mach_absolute_time`, read in ticks (5.19 ns per read here;
  `clock_gettime_nsec_np` is 9.53 ns). Deadlines are kept in ticks, so the
  hot path never converts.
- **N = 1024** polls between clock reads. The hot path is
  `ldr; subs; str; b.eq` on the per-worker countdown in front of variant
  B's `ldrb; tbz` on `gcRequested` (from `otool -tV` of `run`: two
  `pollSlow` call sites, one jump table, no `swift_retain`/`swift_release`).
- **N sweep** (arith, 1 worker, 5 ms slices, O build): N = 64, 256, 1024
  and 4096 all give 2752 to 2761 ms. N does not matter, because the clock
  read is amortised to under 0.1 ns per poll even at N = 64; the cost is the
  countdown itself. The sweep reports "−10.6 %" against NO_BUDGET, which is
  the code-generation effect from section 2, not a speedup.
- **Overhead**: +2.3 percent on fib (P0/Pnb, both builds). On arith,
  DESIGN.md's reference kernel, it is unmeasurable because the sign is
  wrong. The "<1 percent on arith" target is therefore met only vacuously.
  Measured preemption granularity: a 1 ms main budget produced turns of at
  most 1.1 ms (S1), and a 3 ms tick budget at most 3.09 ms (S2).

## 4. Memory per parked Process (S5)

RSS was 85.52 MB before forking and 260.75 MB with 10 000 Processes
cycling through their Delays, which is **17.94 KB per parked Process**.
Breakdown:

- the 64 KiB `malloc`ed stack, of which only the first 16 KiB page is ever
  touched by a shallow loop;
- the Process object, 128 B (16 B entry plus 112 B body);
- its Semaphore, 48 B;
- a 72 B native record (in a preallocated table);
- the pending-root slot and GCD's timer for the outstanding `Delay`.

Virtual reservation is 640 MB for the stacks. Total RSS at the end of S5
was 261.45 MB.

## 5. What went wrong when the design met AppKit (and the machine)

**Worst main-thread stalls and their causes** (median runs):

| id | worst run-loop iteration | VM inside it | cause |
|---|--:|--:|---|
| S0 | 2.5 ms | 0 | AppKit/CA, VM idle |
| S1 | 8.6 ms | 0.10 ms | not the VM. The native control S1n shows the same 9.1 ms and the same event-latency tail (p99 5.0 vs 5.0 ms) |
| S2 | 26.0 ms | 4.0 ms | 22 ms outside the VM, unidentified (below) |
| S3 | 18.8 ms | 4.0 ms | as S2 |
| S4 | 20.8 ms | 1.0 ms | as S2; separately, GC pauses of up to 8 ms land on the main thread (entry wait max 7.58 ms, VM post-latency p99 6.9 ms) |
| S5 | 15.6 ms | 0.97 ms | as S2 |
| S6 | 4.2 ms | 0.03 ms | — |
| S7 | 9000.8 ms | 8999.9 ms | the hog: no preemption |

Findings:

1. **The budget held wherever the VM was the cause.** No main-thread turn
   exceeded its budget by more than about 0.1 ms, except when a GC was
   running (S4: a 1 ms event turn took 7.8 ms). With preemption, a
   main-affine infinite loop (S2) and deep recursion (S3) cost 4 and 4
   missed frames in 1200 (0.3 %). Without it (S7) the window froze for 9 s
   and missed 1079 frames. The control works as intended.
2. **The remaining drops are not explained by VM time.** In S2 to S5 the
   worst iterations held 1 to 4 ms of VM work but lasted 16 to 26 ms. S1n,
   the same event load without the VM, had none, and S0 and S6 had none.
   What these scenarios share is a main thread that is busy about 13 to 52
   percent of the time with 1000 timer-driven turns a second. Candidates,
   none confirmed:
   - Core Animation commit or text layout coinciding with a turn (`setLabel:`
     1000/s; the stuck report appends to an `NSTextView`);
   - the OS descheduling the main thread while 7 background workers spin
     (S4, S5);
   - DispatchSource timer coalescing.

   The next step would be to read the stall from an Instruments trace
   rather than infer it.
3. **The latency floor is the main run loop, not Smalltalk.** A 1 ms
   `DispatchSourceTimer` (`.strict`, main queue) fired only ~635 times a
   second and was late by up to 5 to 8 ms at p99 even with no VM (S1n). The
   VM's share of event latency was 0.12 ms p50 and 0.81 ms p99 (S1). The
   first version stamped events at enqueue and therefore hid S7's 9 s
   freeze completely; events must carry the time they happened, as
   `NSEvent.timestamp` does.
4. **Budgets cannot be honoured across a GC.** Stop-the-world pauses in S4
   were 6.4 ms p50 and 8.0 ms max on a 64 MiB heap with 7 allocating
   workers, i.e. most of a 120 Hz frame. The main thread either parks
   inside its turn or waits at `enterVM`. Time-to-safepoint was tiny (0.07
   ms p50), so the protocol is fine; the pause is the mark and sweep.
   A main-thread budget needs an incremental or concurrent collector, or a
   main thread that can run without joining the stop.
5. **Places where the budget cannot be honoured at all**:
   - primitives (a UI hook into AppKit runs unbounded inside a turn);
   - the GC;
   - the first turn after the budget is switched off (S7).

   The countdown check also runs only at sends and backward jumps, so a
   long straight-line method or a long primitive delays it.
6. **With the budget off, only an off-main observer can see the stall.** The
   shell's stuck check needs the main thread. S7 reported through a GCD
   watchdog (`via=watchdog`) and recovered only because the interpreter
   still checks an interrupt flag in the countdown slow path. So "budget
   disabled" still needs the countdown: the debugger stand-in depends on
   it.
7. **Swift 6 isolation at the shell boundary crashed the app.** A closure
   written inside a `@MainActor` method is inferred main-actor isolated.
   When GCD ran the watchdog closure on a background queue, Swift 6's
   runtime check trapped (SIGTRAP; macOS showed "quit unexpectedly"). Every
   callback the shell gives to GCD or to VM threads must be built in
   nonisolated code. The VM's own hooks are `@convention(c)` pointers that
   call `MainActor.assumeIsolated`, which is correct only because the VM
   calls them on the main worker.
8. **Entering and leaving the VM thousands of times a second exposed a heap
   bug.** Retiring the TLAB on every `leaveVM` wasted a fresh block per
   main-thread turn or host call. With a sweep that reuses only completely
   empty blocks, this ran a 2 MiB test heap out of memory. Fix: keep TLABs
   across leave/enter and retire every worker's TLAB inside the stop.
   Allocation retry after another worker's GC also needed more than
   variant B's three attempts.
9. **ThreadSanitizer found three problems.**
   - Mutating different fields of one `VMCore` struct under different
     locks is a Swift exclusivity race, because each `vm.pointee.x += 1`
     is a modifying access of the whole pointee. Every lock now guards its
     own separately allocated struct (`SyncState`, `SchedState`,
     `PendingState`, `IOState`, `EventQueueState`, one pointer per sample
     buffer).
   - `runSlice` wrote `Process.state` and `runningOn` outside the
     scheduler lock, while `terminate` read them under it.
   - A test read a global without synchronisation.

   AGENTS.md's "everything hangs off one VM state struct" needs the
   qualifier "of pointers, one per lock".
10. **The scheduler lock is the S5 bottleneck.** 10 000 Delay loops reached
    350 k signals/s against an ideal 1 M/s. The 7 workers spent 39.6 s of
    the 70 worker-seconds waiting on the one lock. Workers never blocked
    in a primitive, so DESIGN.md's "must be 0" holds. Each external signal
    also costs a GCD timer and a `malloc`ed node. Frame rate was
    unaffected (0 missed in the median run).
11. **Hop-to-main is cheap.** A hop costs 11 µs p50 / 27 µs p99 from
    suspension to resumption on main (via coalesced
    `DispatchQueue.main.async`), and about 1 µs of main-thread time. The
    retry-the-send rule worked unchanged in AppKit; the test checks that
    the primitive ran exactly once, on main.
12. **Re-entrancy did not occur** in these scenarios: UI primitives only set
    a label or append text. A primitive that spins a nested run loop (a
    modal panel, `NSAlert.runModal`) would re-enter `runMain` on the same
    worker. `runMain` is not re-entrant and the shell has no guard yet.
13. **Display-link behaviour.** `link.timestamp` is quantised to vsync, so
    gaps are exact multiples of 8.333 ms and a drop is a skipped callback.
    `preferredFrameRateRange` 80 to 120 kept ProMotion at 120 Hz in every
    scenario. The window was frontmost throughout; an occluded or inactive
    window was not tested.

## 6. What a real system needs that this skipped

- **Growable stacks.** 64 KiB fixed segments overflow at roughly 1000
  frames (S3: 105 terminations in 10 s). A real system needs stack growth
  or segment chaining, plus an overflow that opens a debugger instead of
  killing the Process.
- **Freezing suspended Processes into contexts.** Saved frames are raw words
  holding tagged native addresses (return pc, caller fp/hdr). That works
  with a non-moving GC, but a debugger, a snapshot, or a compacting GC
  needs them turned into heap contexts or fixed up (variant B's
  `Frames.swift` pc fixups were removed here).
- **Priorities mapped to QoS.** Background workers are default-QoS pthreads
  on any core; nothing maps Smalltalk priority to QoS or keeps the UI
  Process's helpers off E-cores. A newly ready higher-priority Process
  does not preempt a running lower one.
- **A debugger instead of a log line.** The stuck report fires reliably
  (shell after 300 ms; watchdog when the shell has no thread). Opening a
  debugger needs a frozen context and a way to resume or unwind.
- **A scheduler that scales.** Per-worker run queues with work stealing, an
  atomic idle count instead of taking the lock in `signalFromOutside`, and
  a timer wheel instead of one GCD timer per `Delay`.
- **A collector that respects a frame budget.** Incremental or concurrent
  marking, or at least a main thread that can keep running UI-only work
  during a stop (see 5.4).
- **A re-entrancy guard** for nested run loops, and event coalescing.

## 7. Recommendation input

On this machine the core thesis holds for the VM's own behaviour.
Running the UI Process synchronously on the main thread, with
budgeted preemption at bytecode boundaries, kept a 120 Hz AppKit window
within 0 to 5 missed frames in 1200 while Smalltalk spun forever on the
main thread (S2), recursed into stack overflow (S3), allocated on seven
other workers (S4), or ran 10 000 IO-waiting Processes (S5). Without the
budget, the same S2 load froze the window for 9 s (S7). No main-thread turn
overran its budget by more than ~0.1 ms except across a GC. Hopping a
Process to main took 11 µs median and ~1 µs of main-thread time. Moving
stacks into Processes and adding the scheduler cost nothing measurable on
the kernels. The budget countdown cost at most ~2 percent (fib); its sign
elsewhere was dominated by code generation. A parked Process cost ~18 KB of
RSS.

Caveats:

- Stop-the-world pauses (6 to 8 ms here) do land on the main thread and
  break the budget, so the thesis needs a pause-bounded collector.
- The handful of remaining drops (16 to 26 ms stalls with only 1 to 4 ms of
  VM time in them) were not explained.
- The single scheduler lock caps external signalling at ~350 k/s.
- Main-thread event latency is bounded below by AppKit's run loop (p99
  ~5 ms for a 1 ms timer), not by the VM.
- `run`'s code generation moves kernel times by ±10 percent between
  builds.
- One machine, a Mac rather than an iOS device, synthetic events, and a
  window that was always frontmost.

## Deviations from DESIGN.md and SPEC.md

- **S1n** was added: a native-handler control for S1, needed to attribute
  latency and stalls.
- **Event timestamps** are the event's due time, not its enqueue time (see
  5.3). Both latencies are reported.
- **S7's hog** is terminated by an off-main watchdog 9 s into the measured
  window, through the interpreter's interrupt check, so the app can finish.
  The countdown keeps running with the budget off; only the main deadline
  is disabled.
- **Removed from variant B**: become, bulk forward, reshape, compaction,
  snapshot, and the pc fixups for moving GC. The GC is non-moving, so saved
  frames keep raw pcs.
- **TLABs survive `leaveVM`** and every worker's TLAB is retired inside the
  stop. Allocation retries up to 32 collections instead of 3.
- **Lock-guarded state** lives in separate allocations per lock (5.9).
- **`fork` takes one argument**, because there are no blocks. Kernels run
  through `nil kernel: i * 256 + n`, which unpacks into `run: i of: n`
  (one extra frame per worker).
- **The frame account**: 4 ms of VM per frame; tick turns 3 ms; event and
  wake turns 1 ms; 0.5 ms UI-priority-only turns once the account is spent.
  These are this experiment's choices, not tuned values.
- **`readFile:`/DispatchIO** is covered by a unit test only; no scenario
  uses it.
