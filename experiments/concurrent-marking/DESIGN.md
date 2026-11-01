# Experiment: concurrent marking of old space

## Question

ADR 0005's nursery made full collections rarer, not shorter. They still
stop the world for 5 to 9 ms on a 64 MiB old space and would stop it for
tens of milliseconds on a realistic one. ADR 0004 cannot be accepted until
old-space collection has bounded pauses.

This experiment marks old space concurrently with the mutators and sweeps it
lazily, so that a full collection costs two short pauses instead of one long
one. It asks:

1. How short are the initial-mark and final-mark pauses, and do they stay
   short as old space grows to a few hundred MiB?
2. What does the marking barrier cost the mutators when marking is off, and
   how much do they slow down while marking is on?
3. Can one marker thread, preferably on the efficiency cores, keep up with
   eight workers allocating and promoting, and what happens when it cannot?
4. How much memory headroom does concurrent collection need (floating
   garbage, promotion during marking)?
5. Does the main thread now hold 120 Hz under the allocation storm, and
   under a large, slowly mutating old heap?

## Starting point

Copy `experiments/generational-gc/swift/`. Do not modify that experiment or
the earlier ones. Keep the nursery, parallel scavenge, remembered set,
budget, Processes and the AppKit scenario app. The old-space collector is
what changes. Follow the Swift notes in `AGENTS.md`, in particular: side
tables rather than header bits for marks set from the hot path, host code
never reads heap objects outside the VM, and keep wait time separate from
work time in every measurement.

## The collector

### Marking discipline: snapshot at the beginning

Use a snapshot-at-the-beginning (SATB) deletion barrier, as Shenandoah does.
Everything reachable when marking starts is kept; objects allocated during
marking are black; the barrier preserves the snapshot by recording the *old*
value of any pointer field that is overwritten while marking is on. SATB
needs no rescan of stacks at the end, which is what keeps the final pause
short with thousands of Processes. Say in SPEC.md why incremental update was
not chosen, in two sentences.

### Barrier

- The generational barrier already runs on every pointer store into a heap
  object: `store_ivar`, `at:put:`, and the VM-internal sites listed in the
  previous experiment's RESULTS.md. Extend the same slow path: when marking is
  on and the overwritten value is an old, unmarked object, push it onto the
  worker's SATB buffer. The fast path must stay one test of a per-worker
  "marking on" byte plus what the generational barrier already does.
- Mark state lives in a byte map or bitmap beside the entry table, one entry
  per object, never in the header word. The marker sets marks with atomic
  operations; the barrier reads them.
- Provide a build flag that compiles the marking barrier out so its cost can
  be isolated on `ivars`, `sends`, `fib`, `arith` and `churn`.

### Phases

1. **Initial mark pause.** Stop the world. Flip "marking on" for every
   worker. Scan roots: every Process stack's used part, the class table,
   globals, external-signal roots, the event queue, and the remembered set
   is *not* a root for old marking (it points old to young). Grey the
   roots' old targets. Release the world. Report the pause and its breakdown
   between stopping and scanning.
2. **Concurrent mark.** One marker thread (a second as an option; report
   both) drains the grey set, following old-to-old references only. Young
   objects are ignored by the marker; they are the scavenger's job.
   Mutators' SATB buffers are handed over when full and drained by the
   marker. Run the marker at a lower QoS than the workers and report which
   cores it ran on if that can be observed, otherwise report its CPU time.
3. **Scavenges during marking.** This is the hard interaction. A young
   object promoted while marking is on must be treated as grey, not black:
   the scavenge pushes every promoted object onto the grey set, because the
   old objects it points to may be unmarked. Objects allocated directly in
   old space while marking is on are allocated black and their initial
   contents are young or nil, so they need nothing. Write a test that
   constructs the case where this matters and fails without the rule.
4. **Final mark pause.** Stop the world. Flip marking off. Drain every
   worker's remaining SATB buffer and the grey set to completion. Report the
   pause and how much of it was draining versus stopping.
5. **Lazy sweep.** Unmarked old objects are freed by the worker that next
   takes their block for allocation, or by the marker thread in the
   background, whichever is simpler. Freed entries return to the chunk
   bitmaps as the nursery sweep does. Nothing about sweeping may stop the
   world. Report the sweep's total CPU time and whether allocation ever
   waited for a block to be swept.

### Triggers and fallback

- Start a concurrent cycle when old space passes a threshold (say 60 percent
  of its capacity, tunable). Report the threshold used.
- If old space fills before the cycle finishes, fall back to a stop-the-world
  full collection, count it, and report it loudly. The number of fallbacks
  under each workload is a primary result; zero is the target.

### Verification

- A debug mode that, at the final-mark pause, runs a stop-the-world mark
  from scratch and compares the mark sets. Any object the concurrent marker
  missed is a bug. Run every test and at least one scenario run with this
  verifier on, and say so.
- A test suite that covers: a pointer overwritten during marking whose old
  target is otherwise unreachable survives the cycle (SATB works); a
  promoted object's old targets survive (phase 3 rule); allocation during
  marking; marking across many scavenges; the fallback path; ThreadSanitizer
  clean.

## Kernels

Reuse `arith`, `fib`, `sends`, `ivars`, `alloc`, `churn`, `survivors` by
path reference. Add:

- **oldheap**: builds a long-lived graph of a configurable size (test 64,
  256 and 512 MiB of live old data) and then runs a mutation loop that
  rewires pointers inside it at a steady rate while churning young garbage,
  so that marking happens against a large heap with an active SATB barrier.
  Report live bytes, mutation rate, and the pauses.

Headless matrix: each kernel × {stop-the-world full collections as in ADR
0005, concurrent marking} × {1, 8 workers}, 5 runs, median, with 4 MiB
nurseries throughout. Report wall time, cycles, initial-mark and final-mark
pause p50/p99/max, marking duration, marker CPU time, mutator slowdown
during marking (wall time of the kernel with marking forced on continuously
versus off), SATB buffer volume, fallbacks, and peak RSS. Control alignment.

## Scenarios in the AppKit app

Reuse the frame measurement. 10 s each, 3 runs, median run:

| id | scenario |
|---|---|
| C0 | idle |
| C1 | alloc storm on 7 workers, stop-the-world full collections (the ADR 0005 result, reproduced) |
| C2 | C1 with concurrent marking |
| C3 | `oldheap` at 256 MiB live on 7 workers, stop-the-world |
| C4 | C3 with concurrent marking |
| C5 | C2 plus allocation on the main thread between events |
| C6 | C4 with two marker threads |

Report frames missed, max gap, every pause kind's distribution, fallbacks,
and the worst main-thread stall with the VM time inside it, wait time
separated from work time.

## RESULTS.md must contain

1. The headless matrix and the scenario table.
2. Barrier cost with marking off, and mutator slowdown with marking on.
3. Pause breakdowns for initial and final mark, and how they scale with old
   space size (64, 256, 512 MiB).
4. Marker throughput versus allocation and promotion rate, fallback counts,
   and the memory headroom the cycle needed.
5. The verifier's findings, if any, and what the SATB and promotion tests
   caught during development.
6. Honest notes: what was hard, what broke, what a real system needs next
   (compaction of old space, an age field, large objects, marker on
   efficiency cores on a phone).
7. A recommendation paragraph with caveats; the ADR is decided afterwards.

## Layout

```
experiments/concurrent-marking/
  DESIGN.md
  SPEC.md          mark byte map, SATB buffer protocol, phase protocol,
                   promotion-during-marking rule, lazy sweep, triggers,
                   fallback, verifier, parameters
  kernels/         oldheap.kasm
  swift/           the copied package, extended
  bench.sh
  RESULTS.md
```

## Non-goals

Compaction of old space, an age field, concurrent scavenging, iOS, UIKit.
