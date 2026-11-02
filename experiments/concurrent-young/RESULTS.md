# Results: young collection without stopping the world

The VM of `../concurrent-relocation` (ADR 0007) with three ways to collect a
nursery: the inherited stop-the-world scavenge (`stw`, the `adr7`
reference), a **local** collection by the owning worker while every other
worker runs (Part 1), and an **offloaded** collection by one collector
thread while the owner flips to the other half of its eden and keeps
running (Part 2). The initial mark scans every nursery's young bodies as
roots instead of scavenging (Part 3 (a)); the forced global scavenge is kept
as `KAJO_IM=scavenge` (b). Protocol, barriers, ordering argument and every
choice: `SPEC.md`, including its "Amendments" section, which lists the rules
the code needed beyond the written spec and which bug found each.

Everything reproduces with `./bench.sh` (`PARTS="report" ./bench.sh` for the
tables only). Raw outputs beside this file: `bench-raw-kernels.txt`,
`bench-raw-scenarios.txt`, `bench-raw-pauses.txt.gz` (every stop-the-world
pause and marking cycle), `bench-output.txt` (the tables below).

**Setup.** Apple M2 Max (8 P + 4 E cores), macOS 27, Swift 6.4, release
builds, no pinning, on mains power. During the work the laptop was moved to
another socket and an external 165 Hz display (AW3423DWF) was connected; at
the user's request every scenario reported here ran with its window on the
**built-in ProMotion display at 120 Hz** (each result line records the
screen: `screen=Built-in_Retina_Display screen_max_fps=120`). Missed frames
are also counted against a fixed 120 Hz budget (`missed120`, gaps over
1.5 x 8.33 ms counted in 8.33 ms frames); on the built-in display the two
counts are the same. The matrix ran after the move; no number below comes
from before it.

**Noise.** At 8 workers wall times of the compute kernels move by up to 10
percent between configurations that run identical interpreter code (arith:
`orig`/`adr7` 1.09; ivars: `adr7b`/`adr7` 1.10 and `local`/`adr7b` 0.95).
Ratios at 8 workers below 1.10 are not distinguishable from noise in this
matrix. Pause maxima (all configurations, `adr7` included: its stop-the-world
time-to-safepoint reaches 19 ms on alloc at 8 workers against a p99 of 0.4
ms) include threads descheduled by the OS: 8 workers, the marker, the
collector and the main thread share 12 cores.

## Answers

**1. Local scavenge: yes, and it is correct.** A worker collects its own
nursery while the others run; every kernel's checksum equals the
stop-the-world run's in all 5 runs at 1 and 8 workers, the young verifier
(a from-scratch reachability walk at a forced pause after every collection)
is clean across the test suite and the scenario verifier runs, and
ThreadSanitizer reports nothing. The owning worker's own pause is its whole
collection: p50 0.4 to 2.2 ms at 8 workers, close to or below the
stop-the-world scavenge's p50 (0.2 to 3.3 ms), but nobody else stops. Its
p99 is better on some kernels (alloc 6.5 against 8.9 ms, survivors30 4.4
against 16.0) and worse on others (survivors5 12.8 against 3.9, churn 9.1
against 0.3, fragment 4.6 against 3.2), because one thread copies what eight
copied in parallel and because its rounds and its eden-reuse wait depend on
the slowest of seven running workers. Mutator cost of the barriers: 0 to 2
percent at 1 worker on every kernel (`adr7b`/`adr7` 0.98 to 1.02); at 8
workers within noise. Cost of lost parallelism
(`local`/`adr7b`): 1.00 to 1.06 at 1 worker, 0.94 to 1.17 at 8 (allocating
kernels; share 1.14). In the storm scenario the main thread missed **6
frames against 58** for the stop-the-world scavenge, and its time stopped
because another worker allocated fell from **126 ms to 36 ms** per 10 s; the
36 ms is 1371 round acknowledgements of about 27 us each.

**2. Offloaded scavenge: the main thread's pause becomes a flip.** The
owner's pause is opening the collection and switching eden halves: p50 0.005
to 0.05 ms, p99 under 0.12 ms on every kernel and worker count, max 0.07 to
2.0 ms in the matrix; the main thread's flips in the scenarios had a max of 0.03
ms (Y5o: 392 flips, 3.9 ms in 10 s). The owner's stack is scanned in its own
H1 acknowledgement, not at the flip (that would be unsound, SPEC.md point
4). But **one collector thread does not keep up with eight allocating
workers**: it is 94 to 98 percent busy, workers wait for it (alloc: 521
waits, 2.1 s summed over the run), and wall time is 1.14 to 1.69 times the
stop-the-world run at 8 workers (alloc 1.47, survivors30 1.69). At 1 worker
it is faster than everything else (alloc 0.87 of `adr7b`) because the copy
runs on a second core. The main thread in the offloaded storm (Y3) missed 5
frames, stopped 67 ms for others (1931 acknowledgements).

**3. Marking without a global scavenge** needs every young body of every
nursery scanned as a root at the initial mark (SPEC.md "Part 3"); the test
from `../concurrent-marking` that loses an object without it still fails
without the scan (`withoutTheYoungRootScanTheVerifierReportsTheLoss`). The
scan is not cheap: at 8 workers with full edens the initial mark is 2.1 to
2.8 ms p50, of which the young scan is 1.4 to 2.4 ms, against 0.9 to 3.5 ms
for the forced global scavenge (b). It is cheaper than (b) when survivors
are many (survivors30: 2.5 against 3.4 ms; alloc 2.8 against 3.3) and more
expensive when the edens are mostly dead (oldheap: 2.1 against 1.2 ms;
fragment about equal). At 1 worker (a) is 0.07 to 0.16 ms. It is now the
largest pause the main thread sees in the storm (2.4 to 2.6 ms, 13 to 19
times per 10 s in Y2/Y3).

**4. Frames.** Main-thread time stopped because another worker allocated,
per 10 s: storm 126 ms (`stw`) against 36 ms (`local`) and 67 ms
(`offload`); fragmentation ring 27 ms against 0.4 and 1.2 ms; `share` on 8
workers 113 ms (offload, all of it round acknowledgements). **The goal of
zero is not met**: the residue is round acknowledgements, which the main
thread does at its polls for every other worker's collection (27 to 35 us
each). The stop-the-world pauses the main thread still takes are the
old-space cycle's (initial mark, final mark, apply, fallback): 40 to 54 ms
per 10 s in the storm, mostly initial marks. Frames: Y0 idle 0, storm
58 / 6 / 5 (stw / local / offload), ring 27 / 12 / 19, `share` 0. The
heavy main-thread allocation scenario misses 47 to 48 frames under local and
offload, but 34 under stop-the-world with **no collector time at all on the
main thread** (its own collections cost 30 ms local, 3.9 ms offload): those
misses are the load itself (the main thread spends 23 to 37 percent of the
window in Smalltalk, display-link callbacks run 6 to 8 ms late at p99), not
the collector.

## Main-thread pause attribution per scenario

Median run of three, 10 s, built-in display at 120 Hz. "Own" is the main
worker's own young collection (local: the whole collection; offload: the
flip). Acknowledgements are rounds the main thread performed at its polls
(work: its stack scan and buffer hand-over), for its own nursery's
collections and for others'. Stops are stop-the-world pauses the main
thread was parked in, by kind. Wait time (blocked entering the VM or on a
pending stop, waiting for the collector) is kept apart; it was 0 for the
main thread in every scenario except the stop-the-world ones (where it is
the park time itself).

| id | load | young | missed | **stopped because another worker allocated** | own collections | acks own | acks for others | old-space stops (parked) | waits |
|---|---|---|--:|--:|---|---|---|---|---|
| Y0 | idle | offload | 0 | **0 ms** | none | none | none | none | 0 |
| Y1 | storm | stw | 58 | **126.0 ms** (43 scavenges) | n/a | n/a | n/a | initial 10 / 39.8 ms, final 33 / 3.6 ms, fallback 6 / 54.8 ms | 0 |
| Y2 | storm | local | 6 | **36.5 ms** (1371 acks) | 0 | 0 | 1371 / 36.5 ms | initial 19 / 49.8 ms, final 18 / 2.0 ms, apply 16 / 1.8 ms | 0 |
| Y3 | storm | offload | 5 | **67.1 ms** (1931 acks) | 0 | 0 | 1931 / 67.1 ms | initial 13 / 32.6 ms, final 4 / 0.8 ms, apply 11 / 2.0 ms, fallback 1 / 5.0 ms | 0 |
| Y4s | ring | stw | 27 | **26.9 ms** (5 scavenges) | n/a | n/a | n/a | initial 1 / 9.1 ms | 0 |
| Y4l | ring | local | 12 | **0.4 ms** (43 acks) | 0 | 0 | 43 / 0.4 ms | none in the median run | 0 |
| Y4o | ring | offload | 19 | **1.2 ms** (90 acks) | 0 | 0 | 90 / 1.2 ms | initial 1 / 1.7 ms, final 1 / 0.1 ms | 0 |
| Y5s | main allocates | stw | 34 | **0 ms** | its own scavenges: 203 at 0.01 ms p50 | n/a | n/a | none | 0 |
| Y5l | main allocates | local | 47 | **0.01 ms** | 200 / 30.1 ms, max 0.30 ms | 600 / 0.26 ms | 0 | none | 0 |
| Y5o | main allocates | offload | 48 | **0.04 ms** | 392 flips / 3.9 ms, max 0.026 ms | 1151 / 4.8 ms | 0 | none | 0 |
| Y6 | `share`, 8 workers | offload | 0 | **113.1 ms** (3602 acks) | 0 | 0 | 3602 / 113.1 ms | none | 0 |

In Y1, the 43 stop-the-world scavenges the main thread was parked in were
all requested by another worker (the main thread allocates almost nothing
there; `stw_scav_by_main=0`). In the local and offloaded storm the main
thread's own nursery never filled in the window.

The line to watch, main-thread time stopped because another worker
allocated, in ms per 10 s:

- storm: **126.0** stop-the-world, **36.5** local, **67.1** offload;
- ring: **26.9** stop-the-world, **0.4** local, **1.2** offload;
- heavy main-thread allocation: **0 / 0.01 / 0.04**;
- `share` on 8 workers: **113.1** offload.

It is not zero. With collections off the main thread, what remains is its
share of every other nursery's rounds: one acknowledgement per round per
collection, 27 to 35 us each (a stack scan of the UI Process and a buffer
swap under the safepoint mutex). The storm runs 620 (local) to 860 (offload, half
edens) collections per second with 3 rounds each (H0, H1, one drain). Plus the old-space cycle's pauses, which
are caused by everyone's promotion: 40 to 54 ms per 10 s in the storm, of
which the initial mark with its young-root scan (2.4 to 2.6 ms each) is
most.

What the frame counts say beyond that: in the storm, local and offload cut
missed frames from 58 to 6 and 5. In the ring (Y4) and under heavy
main-thread allocation (Y5) the remaining misses are not the collector: Y5s
misses 34 frames with the main thread never parked and its own scavenges at
0.01 ms, Y4 misses 12 to 27 frames with the main thread parked under 2 ms in
the local and offload runs. In those runs display-link callbacks are 6 to 8
ms late at p99 and the main thread spends 23 to 37 percent of the window in
Smalltalk (Y5) or runs beside 7 workers, a marker, a relocator and a
collector on 12 cores (Y4). Y5 under local and offload misses more than
under stop-the-world (47 and 48 against 34; run to run 43 to 61 against 18
to 35); this was not explained (see Honest notes).

The scenario verifier runs (Y3 and Y6 with `--verify`: the young verifier
after every collection, the mark verifier at every final mark, the
relocation verifier at every pause) found nothing: 444 and 4 877 young
verifications, 0 failures. They miss frames heavily, as expected (the
verifier walks the whole heap in a pause).

## Barrier cost against lost parallelism

Three builds and modes separate the two (wall-time table below, last
columns):

- **Barriers alone** (`adr7b`/`adr7`: barriers compiled in, collections
  still stop the world): 0.98 to 1.02 at 1 worker on all twelve kernels,
  including `storeheavy` (512 million SmallInteger stores, 0.997) and
  `share`, which takes the cross-nursery slow path 3 million times (1.020).
  At 8 workers the ratios scatter between 0.92 and 1.14 with no kernel
  pattern (`arith`, which stores nothing into the heap, shows 1.054). The
  flag test costs one load and a branch, as the inherited marking test did;
  the insertion barrier decides a non-young value in 3 instructions instead
  of 5. Within the noise of this matrix, the barriers cost nothing
  measurable.
- **Lost parallelism, local** (`local`/`adr7b`): 1.00 to 1.06 at 1 worker
  (one worker collects either way; the difference is the per-object copy
  protocol and the rounds); at 8 workers 1.04 (alloc), 1.12 to 1.17
  (survivors5, survivors30, fragment, churn), 1.14 (share), 0.94 (oldheap).
  Here each worker copies its own nursery with one thread instead of eight
  copying everything, and copies with a CAS, a fence and atomic word copies
  per object instead of a plain copy.
- **Lost parallelism, offload** (`offload`/`adr7b`): 0.87 to 1.02 at 1
  worker (a second core does the copying), 1.14 to 1.69 at 8 workers, where
  the one collector thread is 94 to 98 percent busy on the allocating
  kernels and workers wait for it.
- **`nobarrier`** (local with both barriers compiled out) is not a cost
  configuration in practice: it changed checksums on alloc and survivors5 at
  8 workers, as it should (in earlier matrix runs it also crashed on
  oldheap64 and fragment); where it ran correctly it is within noise of
  `local`.
- `orig`/`adr7` (the unmodified ADR 0007 VM against this VM's
  stop-the-world mode) is 0.95 to 1.05 on allocating kernels at 1 worker and
  0.80 to 1.05 at 8 (noise): the header
  layout, per-nursery remembered sets and attention word cost nothing
  visible either.

Two implementation lessons from getting here (each found by the matrix,
fixed, and the matrix rerun): the first local version ran alloc at 8
workers 2.7 times slower than stop-the-world because every copied object
scanned every worker's hazard slots with seq_cst loads (now one global count
of held hazard slots, read once per object; the scan only when it is
nonzero), and because collectors did not advance their epoch inside their
copy loops, so other collections' eden-reuse waits waited for whole copy
loops.

## Handshakes

Round latency, request to last acknowledgement (ms, p50 / p99 / max of the
per-run distributions, 8 workers): local 0.05 to 0.07 / 0.35 to 1.5 / 10 to
17; offload 0.06 to 0.08 / 0.19 to 0.67 / 2 to 16. At 1 worker (nobody else
inside the VM): p99 under 0.01 ms local. H0 and H1 each take about 0.06 to
0.10 ms p50.

What bounds it is the slowest participant reaching a poll: a worker in a
send or backward jump polls within microseconds; a worker inside its own
collection services rounds every 256 copied objects, between published
buffers and in all its waits; the main thread in an AppKit call is in a
blocking region and acknowledged by proxy. The tail is not one cause: the
last acknowledger of the worst round differs between runs and kernels
(`hs_worst_by` names five different workers across the five alloc runs),
and the stop-the-world scavenge has the same kind of tail in its
time-to-safepoint (alloc at 8 workers: p99 0.41 ms, max 19.2 ms). Both are
threads descheduled by the OS with twelve threads on twelve cores; on
lighter kernels both are under 2 ms. No primitive in these kernels is long;
a long primitive without a blocking region would bound the latency by its
duration.

**Second-handshake iterations.** Every collection needed exactly one drain
round after H1 on every kernel but `share` (2.00 rounds, the minimum), and
`share` 2.5 to 2.7 rounds on average, at most 3: the deletion records that
its exchanges produce during a collection (5 229 per local run, 42 224 per
offloaded run) arrive in the first drain round and are copied there.

**Eden-reuse wait (epoch rule, Part 1).** p50 0.03 to 0.06 ms, p99 0.2 to
2.5 ms, max 6 to 14 ms at 8 workers; under 0.01 ms at 1 worker. The final
round is itself a safepoint passage for every running worker, so the wait
is normally already satisfied; what remains is workers descheduled or
outside a poll for longer (the same tail as above). It shows up in the max,
not the median; two edens per worker would remove it from the local
collector's pause and is what offload does.

## Initial mark: young-root scan (a) against forced global scavenge (b)

From the extras (`localb`, `offloadb`), 8 workers, 5 runs (table
"Initial-mark pause" below): (a) p50 2.1 to 2.8 ms, of which the young-root
scan is 1.4 to 2.4 ms; (b) p50 0.9 to 3.5 ms, of which the scavenge is 0.6
to 2.7 ms. (a) wins when much survives (survivors30 2.4 against 3.4 ms),
loses when the edens hold mostly garbage (oldheap 1.4 to 2.1 against 0.9 to
1.2 ms), and ties on fragment. The young scan walks every live and dead body
in every active eden half and survivor-from (up to 28 MiB at 8 workers) on
the stopper alone; DESIGN.md asked for it in parallel and it is not
(Deviations). Option (b) keeps a stop-the-world scavenge in the system,
which is what the other two parts remove.

## Barriers in the arm64 code

`otool -tV` of the release `cy-bench`, `run`'s `store_ivar` and the inlined
store (SPEC.md "Barriers"):

```
ldr   x8, [x27, #0x140]        ; barrierWord (old marking | collections)
cbz   x8, fast                 ; nonzero: one call, storeWithBarriers
...
stlr  x3, [x11]                ; the store (post-store check, ADR 0007)
ldar  x10, [x10]
tbnz  x9, #0x20, conflict
cmp   x10, x9
b.ne  conflict
tbnz  w3, #0x0, done           ; insertion barrier: SmallInteger
ldr   x3, [x3, x28]            ;   value's header
tbz   x3, #0x38, done          ;   not young: done (3 instructions)
ldr   x8, [x8]                 ;   holder's header
eor   x8, x8, x3
tst   x8, #0x1f0000000000000   ;   young bit and nursery index
b.eq  done                     ;   same nursery: done (7 instructions)
bl    remember
```

The flag test is the inherited `marking` test moved from the worker to the
VM struct: one load and one branch. The insertion barrier decides in 3
instructions for a non-young value (the common case; the inherited barrier
loaded the holder's header first and needed 5) and 7 for a young one. The
young deletion barrier, the snoop and the SATB record all live in the one
out-of-line `storeWithBarriers`/`preStoreSlow`. No `swift_retain` or
`swift_release` in `run`, `storeWithBarriers`, `preStoreSlow`, `remember`,
`storeConflict`, `postStoreSlow`, `allocSlow`, `serviceHandshakes` or
`ycResumeCheck`.

## What the verifier and ThreadSanitizer caught

Every one of these was a real bug in the first version of the code, not a
test artefact, and each now has a rule in SPEC.md ("Amendments") and, where
it is a protocol rule, a test that fails without it.

- **Young verifier: reachable entries freed under offload**
  (`sharedYoungObjectsAreClaimedOnce...` with `KAJO_TEST_YOUNG=offload`).
  Objects the owner allocated in its new eden half between the flip and the
  snapshot held the only reference to a Y object and nobody scanned them.
  Fixed by the new-half scan plus the snoop (amendment 7); three tests.
- **Young verifier / relocation verifier: bodies reused under live
  entries.** Dead remembered holders whose free was deferred had their old
  bodies reused while stale lists still scanned them (amendment 10), and a
  carried list grew to 51 356 copies of 2 holders because clear-then-rearm
  defeated deduplication (amendment 9).
- **ThreadSanitizer: bus error in `classify`** from the same stale-holder
  reuse, and a nested collection on the collector thread (it drained its
  queue from inside its own round wait) that corrupted its trace stack
  (amendment 11).
- **ThreadSanitizer data races:** the stop-the-world scavenge reading a
  young holder's new body while another participant was still copying it
  (amendment 12; a real bug on hardware, not only a report); a collector
  reading the header of an object a mutator was initialising with plain
  stores (amendment 13; harmless on arm64 through the address dependency,
  fixed with relaxed atomic stores that compile to the same instructions).
- **Deadlocks found by hanging runs, not tools:** a collector's epoch wait
  against workers waiting for that collector (amendment 14); the collector
  thread requesting a stop that waits for collections only it can run; a
  stop request that did not wake workers waiting on the condition variable.
- **The checksum gate and the relocation verifier: the collector thread as
  a stop-the-world stopper.** Offload with the forced global scavenge (b)
  crashed, then lost objects in 2 of 20 alloc runs: the collector thread
  can request a stop (initial mark, fallback), and the scavenge used its id
  as a nursery and worker index, dropped the holders it re-remembered, and
  left its promotion buffer open across the fallback's mark-sweep, which
  freed the block under it ("body in free block"). 0 of 30 after the fix.
  This affected plain offload too whenever the collector requested a
  fallback; the matrix was rerun.
- **The matrix: performance bugs.** The first local runs were 2.7 times
  slower than stop-the-world on alloc at 8 workers (hazard-slot scan per
  copied object; collectors not advancing their epoch inside copy loops), and
  offload scanned 39 million remembered holders on alloc (the snoop
  remembered every same-nursery store during a collection, not only stores
  of values in Y). Fixed and rerun.
- **The young verifier's own blind spot:** a stale `result` register kept a
  dead object alive and made two "without the rule" tests pass when they
  should fail (amendment 8). Tests that are supposed to fail are what found
  it.

The final suite: 72 tests, green in `local`, `offload` and `stw` modes, and
under ThreadSanitizer in `local` and `offload` with 0 reports (final runs: 72 tests in 360 s and 451 s). As in ADR
0007, ThreadSanitizer cannot see that an access through the heap's alias
mapping and one through the base address are the same memory.

## Tables

Generated by `report.py` from the raw files (`bench-output.txt`). Pause columns: p50 / p99 / max in ms; for distributions over the 5 runs, the median of the per-run p50 and p99 and the max of the per-run maxima. "local own" is the owning worker's whole collection, "offload flip" the owner's pause, "adr7 scavenge" every worker's pause.

### Wall time, ms (median of runs), nursery 4 MiB; checksum against adr7

| kernel | w | orig | adr7 | adr7b | local | offload | nobarrier | checksums | barrier adr7b/adr7 | local/adr7b | offload/adr7b | orig/adr7 |
|---|--:|--:|--:|--:|--:|--:|--:|---|--:|--:|--:|--:|
| arith | 1 | 2884.3 | 2863.8 | 2904.4 | 2837.0 | 2889.1 | 2864.9 | equal | 1.014 | 0.977 | 0.995 | 1.007 |
| arith | 8 | 437.1 | 400.0 | 421.5 | 408.4 | 418.0 | 408.1 | equal | 1.054 | 0.969 | 0.992 | 1.093 |
| fib | 1 | 1673.8 | 1664.3 | 1690.3 | 1690.7 | 1688.3 | 1650.9 | equal | 1.016 | 1.000 | 0.999 | 1.006 |
| fib | 8 | 232.2 | 238.8 | 256.5 | 273.8 | 241.9 | 247.9 | equal | 1.074 | 1.067 | 0.943 | 0.972 |
| sends | 1 | 2443.7 | 2390.7 | 2403.4 | 2413.7 | 2395.9 | 2371.5 | equal | 1.005 | 1.004 | 0.997 | 1.022 |
| sends | 8 | 348.5 | 361.1 | 345.4 | 344.3 | 339.9 | 341.8 | equal | 0.957 | 0.997 | 0.984 | 0.965 |
| ivars | 1 | 2017.8 | 2024.9 | 2006.0 | 2007.1 | 2026.6 | 2022.0 | equal | 0.991 | 1.001 | 1.010 | 0.996 |
| ivars | 8 | 297.9 | 278.5 | 307.4 | 290.4 | 281.2 | 293.6 | equal | 1.104 | 0.945 | 0.915 | 1.070 |
| storeheavy | 1 | 1943.6 | 1920.8 | 1915.1 | 1913.6 | 1922.1 | 1910.8 | equal | 0.997 | 0.999 | 1.004 | 1.012 |
| storeheavy | 8 | 283.9 | 287.0 | 284.7 | 282.5 | 295.3 | 284.6 | equal | 0.992 | 0.992 | 1.037 | 0.989 |
| alloc | 1 | 2547.8 | 2475.6 | 2469.3 | 2544.7 | 2148.0 | 2535.6 | equal | 0.997 | 1.031 | 0.870 | 1.029 |
| alloc | 8 | 521.3 | 548.2 | 521.4 | 541.5 | 766.3 | 494.5 | DIFF nobarrier | 0.951 | 1.039 | 1.470 | 0.951 |
| churn | 1 | 1602.7 | 1586.2 | 1618.7 | 1642.7 | 1628.2 | 1628.3 | equal | 1.020 | 1.015 | 1.006 | 1.010 |
| churn | 8 | 248.4 | 240.3 | 269.8 | 315.7 | 361.3 | 297.7 | equal | 1.123 | 1.170 | 1.339 | 1.034 |
| survivors5 | 1 | 1273.8 | 1289.3 | 1265.4 | 1300.1 | 1248.0 | 1293.5 | equal | 0.981 | 1.027 | 0.986 | 0.988 |
| survivors5 | 8 | 195.3 | 243.6 | 224.1 | 249.9 | 321.9 | 238.0 | DIFF nobarrier | 0.920 | 1.115 | 1.436 | 0.802 |
| survivors30 | 1 | 1803.4 | 1767.5 | 1781.7 | 1889.1 | 1676.6 | 1802.3 | equal | 1.008 | 1.060 | 0.941 | 1.020 |
| survivors30 | 8 | 305.1 | 318.3 | 294.6 | 340.8 | 498.7 | 347.0 | equal | 0.926 | 1.157 | 1.693 | 0.959 |
| oldheap64 | 1 | 2414.5 | 2384.0 | 2384.1 | 2467.6 | 2408.3 | 2450.5 | equal | 1.000 | 1.035 | 1.010 | 1.013 |
| oldheap64 | 8 | 345.9 | 358.8 | 409.9 | 384.4 | 467.5 | 411.8 | equal | 1.142 | 0.938 | 1.141 | 0.964 |
| fragment | 1 | 1172.2 | 1201.0 | 1175.2 | 1205.9 | 1112.7 | 1201.5 | equal | 0.979 | 1.026 | 0.947 | 0.976 |
| fragment | 8 | 220.5 | 210.1 | 224.3 | 257.9 | 319.0 | 269.2 | equal | 1.068 | 1.150 | 1.422 | 1.050 |
| share | 1 | - | 679.5 | 693.3 | 691.3 | 708.8 | 676.3 | equal | 1.020 | 0.997 | 1.022 | - |
| share | 8 | - | 109.9 | 110.8 | 126.3 | 139.9 | 118.9 | equal | 1.008 | 1.140 | 1.263 | - |

### Wall time, ms (median of runs), nursery 16 MiB; checksum against adr7

| kernel | w | orig | adr7 | adr7b | local | offload | nobarrier | checksums | barrier adr7b/adr7 | local/adr7b | offload/adr7b | orig/adr7 |
|---|--:|--:|--:|--:|--:|--:|--:|---|--:|--:|--:|--:|
| alloc | 1 | 2171.1 | 2131.2 | 2145.9 | 2213.4 | 2056.3 | 2162.1 | equal | 1.007 | 1.031 | 0.958 | 1.019 |
| alloc | 8 | 355.2 | 339.3 | 365.3 | 370.9 | 408.8 | 363.1 | equal | 1.077 | 1.015 | 1.119 | 1.047 |
| survivors30 | 1 | 1676.2 | 1647.7 | 1663.3 | 1685.8 | 1637.2 | 1669.4 | equal | 1.009 | 1.014 | 0.984 | 1.017 |
| survivors30 | 8 | 300.4 | 271.4 | 278.6 | 262.3 | 266.0 | 255.2 | equal | 1.027 | 0.941 | 0.955 | 1.107 |

### Pauses of the allocating worker (ms, p50 / p99 / max), 4 MiB unless stated

adr7: the stop-the-world scavenge, every worker stopped. local: the owning worker's whole collection. offload: the flip.

| kernel | w | nursery | adr7 scavenge | local own | offload flip | local hs latency | offload hs latency | local rounds mean/max | offload rounds mean/max | local eden wait max | offload coll waits (n, ms) | offload collector busy % |
|---|--:|--:|---|---|---|---|---|---|---|--:|---|--:|
| alloc | 1 | 4 | 1.506 / 2.639 / 5.863 | 1.670 / 2.024 / 6.964 | 0.050 / 0.073 / 0.413 | 0.001 / 0.004 / 0.033 | 0.005 / 0.068 / 5.087 | 2.00 / 2 | 2.00 / 2 | 0.005 | 6, 12.5 | 38.7 |
| alloc | 8 | 4 | 3.349 / 8.903 / 20.698 | 1.837 / 6.526 / 24.871 | 0.050 / 0.096 / 0.815 | 0.057 / 0.350 / 10.563 | 0.060 / 0.217 / 6.312 | 2.00 / 2 | 2.00 / 2 | 6.378 | 521, 2078.9 | 93.9 |
| churn | 1 | 4 | 0.009 / 0.023 / 0.115 | 0.103 / 0.206 / 0.426 | 0.005 / 0.012 / 0.175 | 0.000 / 0.005 / 0.012 | 0.004 / 0.194 / 4.074 | 2.00 / 2 | 2.00 / 2 | 0.004 | 2, 9.7 | 5.1 |
| churn | 8 | 4 | 0.216 / 0.337 / 5.005 | 0.378 / 9.146 / 26.468 | 0.005 / 0.032 / 1.121 | 0.058 / 0.991 / 13.960 | 0.067 / 0.291 / 8.463 | 2.00 / 2 | 2.00 / 2 | 14.052 | 14, 19.4 | 62.3 |
| survivors5 | 1 | 4 | 0.457 / 1.113 / 4.848 | 0.696 / 1.097 / 2.899 | 0.016 / 0.028 / 0.046 | 0.001 / 0.005 / 0.009 | 0.005 / 0.476 / 5.792 | 2.00 / 2 | 2.00 / 2 | 0.004 | 2, 1.6 | 11.3 |
| survivors5 | 8 | 4 | 1.736 / 3.929 / 23.990 | 1.210 / 12.817 / 27.495 | 0.015 / 0.068 / 1.181 | 0.069 / 1.144 / 17.039 | 0.084 / 0.672 / 10.595 | 2.00 / 2 | 2.00 / 2 | 13.668 | 211, 550.9 | 97.7 |
| survivors30 | 1 | 4 | 1.020 / 1.904 / 5.269 | 1.407 / 4.540 / 6.307 | 0.047 / 0.065 / 0.240 | 0.001 / 0.005 / 0.010 | 0.005 / 0.461 / 4.238 | 2.00 / 2 | 2.00 / 2 | 0.004 | 1, 4.8 | 19.8 |
| survivors30 | 8 | 4 | 3.194 / 15.991 / 18.245 | 2.186 / 4.446 / 26.755 | 0.048 / 0.100 / 0.851 | 0.066 / 0.795 / 10.289 | 0.070 / 0.247 / 16.107 | 2.00 / 2 | 2.00 / 2 | 7.216 | 214, 1216.7 | 96.0 |
| oldheap64 | 1 | 4 | 0.279 / 0.814 / 1.350 | 0.408 / 0.956 / 1.405 | 0.011 / 0.020 / 0.470 | 0.001 / 0.006 / 0.023 | 0.007 / 0.580 / 5.873 | 2.00 / 2 | 2.00 / 2 | 0.005 | 2, 4.7 | 6.9 |
| oldheap64 | 8 | 4 | 0.867 / 5.255 / 16.020 | 0.813 / 4.793 / 30.474 | 0.011 / 0.054 / 2.048 | 0.062 / 1.466 / 13.188 | 0.074 / 0.303 / 9.973 | 2.00 / 2 | 2.00 / 2 | 7.374 | 60, 256.6 | 73.3 |
| fragment | 1 | 4 | 0.693 / 1.469 / 24.072 | 0.841 / 1.535 / 30.278 | 0.016 / 0.023 / 0.275 | 0.001 / 0.005 / 0.194 | 0.007 / 0.134 / 4.521 | 2.00 / 2 | 2.00 / 2 | 0.004 | 1, 4.3 | 16.8 |
| fragment | 8 | 4 | 2.025 / 3.150 / 4.568 | 1.807 / 4.613 / 25.427 | 0.016 / 0.058 / 0.274 | 0.074 / 0.592 / 12.761 | 0.071 / 0.185 / 11.264 | 2.00 / 2 | 2.00 / 2 | 12.152 | 239, 763.3 | 94.6 |
| share | 1 | 4 | 0.017 / 0.035 / 0.079 | 0.081 / 0.110 / 0.634 | 0.005 / 0.011 / 0.026 | 0.001 / 0.005 / 0.012 | 0.005 / 0.188 / 2.273 | 2.00 / 2 | 2.97 / 3 | 0.004 | 0, 0.0 | 4.9 |
| share | 8 | 4 | 0.310 / 0.384 / 1.445 | 0.429 / 0.959 / 22.435 | 0.005 / 0.034 / 0.075 | 0.060 / 0.336 / 12.170 | 0.065 / 0.210 / 1.914 | 2.69 / 3 | 2.53 / 3 | 7.603 | 0, 0.0 | 50.5 |
| alloc | 1 | 16 | 1.708 / 2.348 / 7.841 | 2.387 / 2.746 / 6.396 | 0.196 / 0.281 / 0.721 | 0.001 / 0.007 / 0.017 | 0.008 / 0.102 / 2.706 | 2.00 / 2 | 2.00 / 2 | 0.004 | 0, 0.0 | 17.8 |
| alloc | 8 | 16 | 4.709 / 6.011 / 15.250 | 3.259 / 5.094 / 7.451 | 0.033 / 0.391 / 1.051 | 0.064 / 0.634 / 3.486 | 0.071 / 0.402 / 21.860 | 2.00 / 2 | 2.00 / 2 | 2.731 | 4, 11.2 | 91.6 |
| survivors30 | 1 | 16 | 0.895 / 2.068 / 4.641 | 1.491 / 3.249 / 4.041 | 0.083 / 0.163 / 0.237 | 0.001 / 0.005 / 0.007 | 0.007 / 0.302 / 2.958 | 2.00 / 2 | 2.00 / 2 | 0.001 | 0, 0.0 | 7.1 |
| survivors30 | 8 | 16 | 9.315 / 11.303 / 12.951 | 2.175 / 5.608 / 52.574 | 0.057 / 0.226 / 1.003 | 0.065 / 0.482 / 21.078 | 0.072 / 0.282 / 16.833 | 2.00 / 2 | 2.00 / 2 | 16.112 | 0, 0.0 | 49.4 |

### Barrier and collection activity (medians of runs), 4 MiB

| kernel | w | cfg | collections | promoted MB/s | fallbacks | del records | cross-nursery holders (barrier) | holders scanned | resume scans | initial mark p50 / max ms |
|---|--:|---|--:|--:|--:|--:|--:|--:|--:|---|
| alloc | 1 | adr7 | 320 | 299 | 0 | 0 | 0 | 0 | 0 | 1.698 / 1.966 |
| alloc | 1 | local | 320 | 291 | 0 | 0 | 0 | 0 | 0 | 0.162 / 0.352 |
| alloc | 1 | offload | 640 | 447 | 0 | 0 | 0 | 661 | 0 | 0.179 / 0.310 |
| alloc | 8 | adr7 | 56 | 1161 | 8 | 0 | 0 | 0 | 0 | 4.349 / 9.677 |
| alloc | 8 | local | 313 | 927 | 2 | 0 | 32 | 223 | 2 | 2.818 / 7.072 |
| alloc | 8 | offload | 640 | 462 | 0 | 0 | 15 | 346 | 5 | 2.655 / 8.219 |
| churn | 1 | adr7 | 244 | 0 | 0 | 0 | 0 | 0 | 0 | 0.000 / 0.000 |
| churn | 1 | local | 244 | 0 | 0 | 0 | 0 | 0 | 0 | 0.000 / 0.000 |
| churn | 1 | offload | 488 | 0 | 0 | 0 | 0 | 0 | 0 | 0.000 / 0.000 |
| churn | 8 | adr7 | 35 | 0 | 0 | 0 | 0 | 0 | 0 | 0.000 / 0.000 |
| churn | 8 | local | 240 | 0 | 0 | 0 | 0 | 0 | 1 | 0.000 / 0.000 |
| churn | 8 | offload | 486 | 0 | 0 | 0 | 0 | 0 | 3 | 0.000 / 0.000 |
| survivors5 | 1 | adr7 | 124 | 19 | 0 | 0 | 0 | 0 | 0 | 0.000 / 0.000 |
| survivors5 | 1 | local | 124 | 19 | 0 | 0 | 0 | 124492 | 0 | 0.000 / 0.000 |
| survivors5 | 1 | offload | 248 | 20 | 0 | 0 | 0 | 273535 | 0 | 0.000 / 0.000 |
| survivors5 | 8 | adr7 | 20 | 108 | 0 | 0 | 0 | 0 | 0 | 0.000 / 0.000 |
| survivors5 | 8 | local | 120 | 99 | 0 | 0 | 0 | 112015 | 1 | 0.000 / 0.000 |
| survivors5 | 8 | offload | 248 | 80 | 0 | 0 | 0 | 244332 | 5 | 0.000 / 0.000 |
| survivors30 | 1 | adr7 | 134 | 83 | 0 | 0 | 0 | 0 | 0 | 1.193 / 3.260 |
| survivors30 | 1 | local | 134 | 77 | 0 | 0 | 0 | 150184 | 0 | 0.095 / 0.229 |
| survivors30 | 1 | offload | 269 | 88 | 0 | 0 | 0 | 470301 | 0 | 0.149 / 0.253 |
| survivors30 | 8 | adr7 | 21 | 446 | 0 | 0 | 0 | 0 | 0 | 4.051 / 8.862 |
| survivors30 | 8 | local | 128 | 400 | 0 | 0 | 0 | 121307 | 0 | 2.497 / 3.445 |
| survivors30 | 8 | offload | 265 | 283 | 0 | 0 | 13004 | 295720 | 7 | 2.387 / 2.695 |
| oldheap64 | 1 | adr7 | 184 | 78 | 0 | 0 | 0 | 0 | 0 | 0.436 / 0.521 |
| oldheap64 | 1 | local | 184 | 75 | 0 | 0 | 0 | 832 | 0 | 0.146 / 0.159 |
| oldheap64 | 1 | offload | 368 | 77 | 0 | 522 | 0 | 770 | 0 | 0.142 / 1.115 |
| oldheap64 | 8 | adr7 | 29 | 514 | 0 | 0 | 0 | 0 | 0 | 1.502 / 1.575 |
| oldheap64 | 8 | local | 183 | 471 | 0 | 73 | 0 | 2946 | 0 | 2.133 / 2.397 |
| oldheap64 | 8 | offload | 367 | 391 | 0 | 7687 | 0 | 4825 | 5 | 1.361 / 1.530 |
| fragment | 1 | adr7 | 137 | 190 | 0 | 0 | 0 | 0 | 0 | 0.618 / 1.155 |
| fragment | 1 | local | 137 | 189 | 0 | 0 | 0 | 2775 | 0 | 0.071 / 0.236 |
| fragment | 1 | offload | 275 | 206 | 0 | 0 | 0 | 4021 | 0 | 0.093 / 0.838 |
| fragment | 8 | adr7 | 21 | 1087 | 0 | 0 | 0 | 0 | 0 | 3.150 / 4.568 |
| fragment | 8 | local | 136 | 868 | 0 | 0 | 0 | 2464 | 1 | 2.837 / 3.001 |
| fragment | 8 | offload | 272 | 702 | 0 | 0 | 0 | 5195 | 3 | 2.521 / 5.283 |
| share | 1 | adr7 | 68 | 0 | 0 | 0 | 0 | 0 | 0 | 0.000 / 0.000 |
| share | 1 | local | 68 | 0 | 0 | 0 | 3000000 | 134 | 0 | 0.000 / 0.000 |
| share | 1 | offload | 137 | 0 | 0 | 47883 | 3000000 | 9313 | 0 | 0.000 / 0.000 |
| share | 8 | adr7 | 10 | 1 | 0 | 0 | 0 | 0 | 0 | 0.000 / 0.000 |
| share | 8 | local | 64 | 1 | 0 | 5229 | 3346186 | 263 | 0 | 0.000 / 0.000 |
| share | 8 | offload | 136 | 1 | 0 | 42224 | 3174203 | 1343 | 0 | 0.000 / 0.000 |

### Initial-mark pause, 8 workers: (a) young-root scan vs (b) forced global scavenge (ms, p50 / max over runs; scan part p50)

| kernel | local (a) | local (b) | offload (a) | offload (b) | (a) young-scan part p50 / max | (b) scavenge part p50 |
|---|---|---|---|---|---|---|
| alloc | 2.818 / 7.072 (13 cycles) | 3.272 / 4.197 (11 cycles) | 2.655 / 8.219 (9 cycles) | 3.506 / 7.448 (11 cycles) | 2.301 / 5.521 | 2.123 |
| survivors30 | 2.497 / 3.445 (4 cycles) | 3.352 / 4.581 (4 cycles) | 2.387 / 2.695 (3 cycles) | 3.409 / 5.185 (3 cycles) | 2.121 / 3.042 | 2.659 |
| oldheap64 | 2.133 / 2.397 (2 cycles) | 1.208 / 1.324 (2 cycles) | 1.361 / 1.530 (2 cycles) | 0.934 / 1.106 (2 cycles) | 1.353 / 1.972 | 0.626 |
| fragment | 2.837 / 3.001 (2 cycles) | 2.618 / 3.196 (2 cycles) | 2.521 / 5.283 (2 cycles) | 2.536 / 2.987 (2 cycles) | 2.423 / 3.732 | 1.417 |
| share | - | - | - | - | - | - |

### Scenarios (median run by missed120, then max gap; 10 s)

| id | young | display Hz | frames | missed (display) | missed120 | max gap ms | worst iter ms | main stopped for others ms | main own n / ms / max | main coll waits n / ms | main acks own n / ms | main acks other n / ms | main stops by kind (n, ms) | stw pauses (kind n p50/max ms) |
|---|---|--:|--:|--:|--:|--:|--:|--:|---|---|---|---|---|---|
| Y0 | offload | 120 | 1200 | 0 | 0 | 8.33 | 2.02 | 0.00 | 0 / 0.00 / 0.000 | 0 / 0.00 | 0 / 0.00 | 0 / 0.00 | - | - |
| Y1 | stw | 114 | 1142 | 58 | 58 | 33.91 | 27.96 | 125.96 | 0 / 0.00 / 0.000 | 0 / 0.00 | 0 / 0.00 | 0 / 0.00 | scav 43, 125.96; initial 10, 39.76; final 33, 3.59; fallback 6, 54.77 | scav 683 2.52/25.10; initial 296 3.63/21.52; final 283 0.10/9.68; fallback 103 6.90/18.13 |
| Y2 | local | 119 | 1194 | 6 | 6 | 20.48 | 16.88 | 36.46 | 0 / 0.00 / 0.000 | 0 / 0.00 | 0 / 0.00 | 1371 / 36.46 | initial 19, 49.84; final 18, 2.03; apply 16, 1.76 | initial 242 2.60/3.75; final 240 0.10/1.01; apply 237 0.11/1.92; fallback 7 6.79/10.31 |
| Y3 | offload | 120 | 1195 | 5 | 5 | 18.54 | 13.51 | 67.12 | 0 / 0.00 / 0.000 | 0 / 0.00 | 0 / 0.00 | 1931 / 67.12 | initial 13, 32.64; final 4, 0.76; apply 11, 2.00; fallback 1, 4.98 | initial 137 2.44/2.76; final 138 0.11/0.17; apply 137 0.11/0.17; fallback 3 5.00/6.26 |
| Y4l | local | 119 | 1188 | 12 | 12 | 22.20 | 14.80 | 0.37 | 0 / 0.00 / 0.000 | 0 / 0.00 | 0 / 0.00 | 43 / 0.37 | - | initial 3 2.39/4.69; final 3 0.03/0.04; apply 3 0.02/0.04 |
| Y4o | offload | 118 | 1181 | 19 | 19 | 20.52 | 15.15 | 1.17 | 0 / 0.00 / 0.000 | 0 / 0.00 | 0 / 0.00 | 90 / 1.17 | initial 1, 1.71; final 1, 0.07 | initial 3 1.71/1.91; final 3 0.08/0.15; apply 3 0.05/0.14 |
| Y4s | stw | 117 | 1172 | 27 | 27 | 22.32 | 14.52 | 26.85 | 0 / 0.00 / 0.000 | 0 / 0.00 | 0 / 0.00 | 0 / 0.00 | scav 5, 26.85; initial 1, 9.14 | scav 33 3.59/12.95; initial 3 2.61/9.14; final 3 0.06/0.06 |
| Y5l | local | 115 | 1153 | 47 | 47 | 21.36 | 14.88 | 0.01 | 200 / 30.14 / 0.296 | 0 / 0.00 | 600 / 0.26 | 0 / 0.00 | - | - |
| Y5o | offload | 115 | 1152 | 48 | 48 | 21.31 | 13.33 | 0.04 | 392 / 3.94 / 0.026 | 0 / 0.00 | 1151 / 4.84 | 0 / 0.00 | - | - |
| Y5s | stw | 117 | 1166 | 34 | 34 | 20.54 | 10.89 | 0.00 | 0 / 0.00 / 0.000 | 0 / 0.00 | 0 / 0.00 | 0 / 0.00 | - | scav 203 0.01/0.04 |
| Y6 | offload | 120 | 1199 | 0 | 0 | 9.56 | 12.86 | 113.10 | 0 / 0.00 / 0.000 | 0 / 0.00 | 0 / 0.00 | 3602 / 113.10 | - | - |

### Scenario runs: all three, missed120 / max gap ms

- Y0: 0 / 8.3, 0 / 8.3, 1 / 18.5
- Y1: 72 / 35.6, 58 / 33.9, 48 / 29.2
- Y2: 6 / 20.5, 14 / 19.1, 3 / 19.2
- Y3: 5 / 18.5, 13 / 18.8, 0 / 8.3
- Y4l: 10 / 22.8, 12 / 22.2, 30 / 20.5
- Y4o: 19 / 20.5, 18 / 24.0, 34 / 20.2
- Y4s: 45 / 27.7, 27 / 22.3, 20 / 20.2
- Y5l: 47 / 21.4, 43 / 22.9, 49 / 20.1
- Y5o: 42 / 22.8, 61 / 22.1, 48 / 21.3
- Y5s: 35 / 21.8, 34 / 20.5, 18 / 19.9
- Y6: 7 / 20.3, 0 / 8.3, 0 / 9.6

### Collector activity in the scenarios (median run)

| id | collections | own pause p50/p99/max ms | hs latency p50/p99/max ms | hs worst by worker | rounds mean/max | coll waits (all workers) n / ms | collector busy % | fallbacks | promoted MB |
|---|--:|---|---|--:|---|---|--:|--:|--:|
| Y0 | 0 | 0.007/0.012/0.012 | 0.000/0.000/0.000 | 0 | 0.00 / 0 | 0 / 0.0 | 0.0 | 0 | 0.0 |
| Y1 | 0 | 0.000/0.000/0.000 | 0.000/0.000/0.000 | -1 | 0.00 / 0 | 0 / 0.0 | 0.0 | 103 | 0.0 |
| Y2 | 6189 | 1.573/7.133/34.179 | 0.048/0.391/25.982 | 7 | 2.00 / 2 | 0 / 0.0 | 0.0 | 7 | 7145.2 |
| Y3 | 8582 | 0.051/0.094/0.611 | 0.052/0.220/10.297 | 2 | 2.00 / 2 | 6994 / 21400.8 | 95.5 | 3 | 5139.8 |
| Y4l | 217 | 2.059/24.445/26.392 | 0.011/1.268/2.000 | 6 | 2.01 / 3 | 0 / 0.0 | 0.0 | 0 | 358.8 |
| Y4o | 431 | 0.021/0.213/1.137 | 0.014/0.254/1.210 | 4 | 2.00 / 2 | 0 / 0.0 | 6.7 | 0 | 359.2 |
| Y4s | 0 | 0.000/0.000/0.000 | 0.000/0.000/0.000 | -1 | 0.00 / 0 | 0 / 0.0 | 0.0 | 0 | 0.0 |
| Y5l | 200 | 0.112/0.266/0.296 | 0.002/0.006/0.010 | 0 | 2.00 / 2 | 0 / 0.0 | 0.0 | 0 | 0.0 |
| Y5o | 392 | 0.009/0.018/0.026 | 0.008/0.045/0.323 | 0 | 2.00 / 2 | 0 / 0.0 | 1.5 | 0 | 0.0 |
| Y5s | 0 | 0.000/0.000/0.000 | 0.000/0.000/0.000 | -1 | 0.00 / 0 | 0 / 0.0 | 0.0 | 0 | 0.0 |
| Y6 | 11203 | 0.006/0.038/0.981 | 0.053/0.149/5.226 | 1 | 2.72 / 3 | 131 / 451.3 | 42.3 | 0 | 17.5 |

### Verifier runs

- Y3 --verify: verifyFailures=0 young_verify_runs=444 cm_verify_runs=77 reloc_verify=674 missed120=515
- Y6 --verify: verifyFailures=0 young_verify_runs=4877 cm_verify_runs=0 reloc_verify=4877 missed120=10

## Honest notes

**What was hard.** Not the copying: the object table makes a concurrent
copy of a young object the same entry switch ADR 0007 already had, and the
post-store check carried over unchanged. The hard part was the roots, and
every hole was found by a test or the verifier, not by thinking: the
single-handshake protocol of DESIGN.md is unsound under sequential
consistency (SPEC.md point 4), "the picking worker's scan" misses a Process
parked at H1 and resumed early, the offloading owner's own new eden half
holds unscanned roots between its flip and the snapshot, stale remembered
lists can name entries freed and reallocated by another nursery's
collection, and a clear-then-rearm remembered bit loses its deduplication.
Fourteen amendments to a spec that looked complete. Most of the bugs listed
under "What the verifier and ThreadSanitizer caught" were found only because
each "without the rule" test must fail and the young verifier walks
reachability from scratch; the checksum gate found the last one.

**What disappointed.**
- **Zero main-thread time for others' allocation is not reached.** Round
  acknowledgements cost the main thread 36 to 113 ms per 10 s under load:
  every collection of every nursery needs every running worker at three
  polls. Cheaper rounds (fewer of them: H0 merged into the previous
  collection's last drain round when collections run back to back; or a
  per-worker "nothing to report" fast path) are the obvious next work. Each
  is a correctness argument first.
- **The initial mark became the main-thread pause.** 2.4 to 2.6 ms per
  cycle in the storm, 1.4 to 2.4 ms of it the single-threaded young-root
  scan. It was not parallelised (DESIGN.md asked for "in parallel").
- **One collector thread cannot serve eight allocating workers.** 94 to 98
  percent busy, 1.14 to 1.69 times the wall time. Offload is the right
  shape for the main thread and the wrong one for background workers; a
  mixed policy (main thread offloads, background workers collect locally)
  was not built.
- **Local copying per object is expensive.** A seq_cst CAS, a fence and
  atomic word copies per object made a single collector copy at roughly
  half the per-thread rate of the stop-the-world scavenge, until the
  hazard-slot scan was taken off the per-object path. It is still one
  thread per nursery where the scavenge had eight per collection.
- **Pause tails.** Local p99 and every maximum depend on the slowest of all
  running threads, including threads the OS descheduled. The
  stop-the-world scavenge has the same dependency (its time-to-safepoint),
  but local collection multiplies the number of handshakes by about ten.
- **Unexplained:** Y5 (heavy main-thread allocation, idle workers) misses
  more frames under local and offload (43 to 61) than under stop-the-world
  (18 to 35) although the main thread's own collection costs 3 to 30 ms per
  10 s and nothing else stops it. Candidates not measured: the barrier slow
  path the main thread takes while its own nursery is being collected (the
  flag word is nonzero for the whole collection, so every pointer store
  goes out of line), and the collector or round traffic competing for the
  main thread's core. Y4's misses are likewise not the collector and were
  not chased.
- **Matrix noise** at 8 workers is plus or minus 10 percent on compute
  kernels; the barrier-cost conclusion rests on the 1-worker column.

**What a real system needs next.**
- Fewer, cheaper rounds; or rounds whose acknowledgement does not take the
  global safepoint mutex.
- A parallel young-root scan at the initial mark, or a different snapshot
  rule (for example: grey only old objects named by young objects that
  survive their next collection, which moves the work into collections).
- Local collection for background workers, offload for the main thread.
- Blocking regions for every primitive that can block (only the UI
  primitives and the test primitive have one here); without them a long
  primitive bounds every handshake.
- The `nobarrier` crashes show how much the protocol leans on both barriers;
  a checked build that verifies the remembered-set invariant at random
  points would catch a missed barrier site long before a lost object does.

## Recommendation (ADR input)

Adopt **collection of a nursery without stopping the world**, with a
**collector thread for the main thread's nursery** and **local collection
by the owner for background workers** (the second combination is not
measured; each half is). Conditions and caveats:

- The protocol is sound only with all of: a barrier-on round (H0) before any
  stack scan, Process scan words, per-nursery remembered sets with the
  cross-nursery insertion barrier, the young deletion barrier, drain rounds
  until one copies nothing, the epoch rule before eden reuse, and (when the
  owner keeps allocating) the new-half scan plus the snoop. Each has a test
  that loses an object without it; keep them and the young verifier in the
  suite.
- Expect the main thread to pay for other workers' collections in round
  acknowledgements (about 30 us each, tens of ms per 10 s under a storm)
  instead of in stop-the-world scavenges (126 ms per 10 s). That is a 2 to
  4 times reduction in this storm, not elimination, and it is spread over
  many short interruptions instead of 2.5 to 25 ms pauses: storm frames
  missed fell from 58 to 5 or 6.
- The initial mark must scan young objects as roots; budget 2 to 3 ms with
  eight 4 MiB nurseries until that scan is parallel or moved out of the
  pause.
- One collector thread is not enough for many allocating workers; size the
  offload to the main thread.
- All tails depend on OS scheduling of every VM thread; measure on device
  before trusting any maximum here.

## Deviations from DESIGN.md

1. **Protocol changes** (SPEC.md "Changes to DESIGN.md's protocol" and
   "Amendments"): a barrier-on round H0 before the root handshake; no stack
   scan at the offloading owner's flip (its stack is scanned in its H1
   acknowledgement); Process scan words instead of "the picking worker's
   scan"; deletion buffers cleared at H0; remembered holders cleared before
   the scan with pending bits during a pass; deferred frees of dead
   remembered young holders with a zero slot count; the new-half scan and
   the snoop for offload; blocking regions; stops wait for collections, and
   the collector thread runs its queue while it waits.
2. **The `adr7` reference is not "the copied VM unchanged".** The header
   layout (24-bit slot count, nursery index), per-nursery remembered sets,
   the attention word and the stop-the-world scavenge's per-nursery
   re-remembering are in every configuration. An extra `orig` column runs
   the unmodified `../concurrent-relocation` `cr-bench` (not on `share`,
   which it does not know); `orig`/`adr7` is within noise.
3. **Overlapping local collections** are supported (no lock), so there is no
   lock wait to report; DESIGN.md allowed either.
4. **Two edens** are the halves of the inherited eden (no extra memory,
   twice the collections) and exist only in offload; local collection
   waits for the epoch instead (the wait is reported).
5. **Part 3 (a) is not parallel**: the stopper scans every nursery alone.
6. **The epoch-rule test** uses a blocking-region primitive (`slowPeek:`,
   number 39) that holds a raw body pointer, not a hazard slot: with the
   round protocol a hazard-slot holder delays the copy itself, and the epoch
   rule only matters for a pointer held across rounds, which only a
   blocking region allows.
7. **Scenarios**: Y4s and Y5s (the Y4 and Y5 loads under stop-the-world)
   were added after the first run to attribute their misses; Y5 uses R6's
   C5 load (about 100 us of Point churn after each event) without the storm.
   Scenarios ran on the built-in 120 Hz display after the machine was moved
   to an external 165 Hz display (user's request); `missed120` is reported
   beside the display count.
8. **Matrix**: `oldheap` is `oldheap64`; no alignment-controlled builds (the
   earlier experiments' align32 control was not repeated); pause
   distributions over runs are the median of per-run p50 and p99 and the
   max of maxima, not pooled samples.
9. **Tests**: threaded inherited tests run under `KAJO_TEST_YOUNG=local`
   (default) or `offload` (both run green, and both under ThreadSanitizer),
   with the young verifier after every fourth collection (every collection
   made one inherited test exceed its 60 s limit under ThreadSanitizer).
   Five inherited assertions were adapted, each commented in place: two
   that counted stop-the-world scavenges, an age test's "not remembered"
   (a stop-the-world survivor can now land in another nursery and be
   remembered correctly), a budget test's 20 ms bound (now excluding
   collector stops and the main worker's own collection), and a
   termination counter that is bumped after the termination is published.
10. **Verifier**: `KAJO_VERIFY=all` reports "names free entry" for dead
    objects in the inherited post-scavenge verifier; the unmodified ADR 0007
    VM reports the same on alloc at 8 workers (211 in one run), so it is the
    inherited verifier checking unreachable objects. The reachability-based
    young verifier reports none, and now also runs after stop-the-world
    scavenges.
11. **Commits** are not one per part: Parts 1 to 3 landed together, followed
    by commits for the fixes the verifier, ThreadSanitizer and the matrix
    found, then scenarios and results.
12. **Collector QoS**: `user-initiated` (SPEC.md); `utility` and
    `interactive` exist as `KAJO_YC_QOS` but were not measured.
