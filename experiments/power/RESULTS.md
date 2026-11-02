# Results: what the VM costs in energy on the phone

Built against `DESIGN.md` and `SPEC.md`. Everything reproduces with
`SCRATCH=<dir> ./bench-device.sh`; every table below comes from
`./report.py` over the raw lines in `results/` (all tables:
`bench-output.txt`). Every phone line carries its launch time, thermal state
at start and end, battery state and level, Low Power Mode, footprint, and
the energy, CPU and wakeup telemetry of SPEC.md "Telemetry".

**Setup.** iPhone 17 Pro (iPhone18,1, 2 P + 4 E cores), iOS 27.0.1, on the
cable, battery `full` (100 percent) on every line, Low Power Mode off,
screen on (idle timer disabled), Release build `-O` whole module, Xcode
27.1, team `BDN6M642M2`, one configuration per launch, configurations
interleaved run by run. The phone was `nominal` at the end of **every** line
of every matrix (255 result lines including cool-down probes, 0 failed launches); cool-downs before
each matrix never had to wait. The Mac was in interactive use and only
built, signed and drove the phone.

## Energy readout: `ri_energy_nj` works, `ri_billed_energy` is the wrong field

`proc_pid_rusage(RUSAGE_INFO_V6)` for the app's own pid on iOS 27
(`results/dev-hello.txt`, 3 launches):

| launch | idle second: ri_energy_nj mJ | busy second: ri_energy_nj mJ | busy ri_penergy_nj mJ | idle ri_billed_energy mJ | busy ri_billed_energy mJ | busy P GHz |
|--:|--:|--:|--:|--:|--:|--:|
| 1 | 29.2 | 1779.5 | 1776.6 | 9.2 | 0.6 | 4.16 |
| 2 | 22.0 | 1779.6 | 1776.8 | 17.3 | 0.5 | 4.16 |
| 3 | 29.1 | 1763.6 | 1761.8 | 20.9 | 0.5 | 4.15 |

`ri_energy_nj` is populated and grows with work: one second of a busy loop
on a P core at 4.15 GHz is 1.76 to 1.78 J, the idle second (launch work on
the main thread) 22 to 29 mJ. **`ri_billed_energy`, which the brief named,
does not measure this process's work**: it went down from 9 to 21 mJ to
0.5 mJ when the process got busy. It is energy billed to the process for
work others did on its behalf (vouchers). Every energy figure here is
`ri_energy_nj` (process) or the per-thread `energy_nj` of
`proc_pidinfo(PROC_PIDTHREADCOUNTS)` (a private flavor, SPEC.md). Both are
**CPU energy only**: no DRAM, no display, no render server. Nothing here had
to fall back to cycles.

## Answers

**1. The slow regime is not the phone saving energy. It costs about 1.4 to
1.5 times more energy per hop and 2.7 times the time.** On `walk22` on the
object table, one worker, the slow launches ran 611 ns per hop at 0.82 W
(309 nJ/hop), the fast ones 225 ns per hop at 1.54 W (205 nJ/hop): the
fast regime does more work per joule as well as per second. In the slow
regime the P core runs at a higher clock (4.08 against 3.78 GHz) with
half the IPC (0.69 against 1.79); the core is not saving power, it is
waiting longer for every miss and burning static power meanwhile. A
spinning companion always gives the fast regime (13 of 13 launches) but
costs 2.9 W itself: 857 nJ/hop for the process, 4 times the fast regime.
**A companion in a `wfe` loop gives the fast regime in 13 of 13 launches
for 0.30 W**: 283 nJ/hop for the process (the same energy as the slow
regime, at 3.7 times the speed), 234 nJ/hop for the worker alone. Timers at
100 Hz to 10 kHz and a utility-QoS spin do not prevent the slow regime
(slow launches: 100 Hz 3 of 5, 1 kHz 3 of 5, 10 kHz 8 of 13, utility spin
3 of 5; alone 11 of 13). A second
worker doing the same walk is always fast (5 of 5) at 254 nJ/hop. The chase
microbenchmark without the VM was never slow in this session (85 to 92 ns
per hop, 44 nJ/hop), so the regime did not reproduce outside the VM here;
there a `wfe` companion **slowed** the chase 2.1 times. See Part 1 for what
this means for ADR 0003.

**2. Below about 50 MB/s the collector's QoS does not matter for energy,
because everything, the main thread included, runs on efficiency cores. At
150 MB/s and up, utility QoS costs more energy and misses frames.** Energy
per MB allocated, process: 1.5 to 2.2 mJ/MB at 2 to 50 MB/s for all four
configurations, within 10 percent of each other, stop-the-world cheapest by
5 to 12 percent; 4.1 to 4.7 at 100 MB/s, 5.5 to 6.5 at 150, 7.7 to 9.6 at
200, where the P cores take over and every joule costs 20 to 50 times more
per CPU second. **Utility QoS never fell back to stop-the-world** (0 fallbacks
in all 60 concurrent launches), but **it first missed frames at 150 MB/s**
(10 frames in 1 of 3 launches; 0 at 100 MB/s; 1 and 19 frames in 2 of 3 at
200 MB/s), and at 200 MB/s it cost 9.6 mJ/MB against 8.0 for
user-initiated: the collector on E cores is cheap (248 mJ per CPU second
against 2534 on P) but takes 3.9 times the CPU time, and the main thread
waits for it (159 waits, 128 ms per run) and itself costs 13 J more. The
cheap split is **`conc-mixed`: young collector user-initiated, marker
utility**: at 150 and 200 MB/s its energy is user-initiated's within 1
percent, it never missed a frame, and the marker costs 0.029 J per cycle
on E cores against 0.13 to 0.15 J on P. Collector plus marker CPU is 13 to
16 percent of the mutator's at user-initiated QoS, 14 to 54 percent at
utility. Stop-the-world misses 4 to 7 frames per run from 100 MB/s on (its
full collections, 30 ms), and at 1 to 10 MB/s its scavenges take 4.5 to 5.3
ms p50 because the main thread then runs on an E core at a low clock.

**3. An idle VM does not stay idle: the marker thread wakes the phone 132
times a second.** VM up, every worker parked, no UI: 131.6 package-idle
wakeups and 214 interrupt wakeups per second, 2 ms of CPU per second, all of
it on the marker thread; without the VM, and with the VM built without
concurrent marking (no marker thread), 0.0 and 0.1. The cause is
`markerLoop` in `Concurrent.swift`: it waits on its condition variable with
a 1 ms timeout (`pthread_cond_timedwait_relative_np`, to retry freeing
evacuated blocks) even when there is nothing pending. At user-initiated
QoS the timer coalesces less and the marker alone produces 582 wakeups per
second. The energy is tiny (0.11 mW of CPU energy) but the wakeups are what
keep a phone's package out of deep idle. The 120 Hz tick with an empty
Smalltalk turn costs the same as the display link without entering the VM
(17.5 against 17.0 ms of CPU per second, 0.90 against 0.89 mW, 216.5
against 216.9 wakeups per second); without the marker it is 78 idle and 120
interrupt wakeups per second, the link's own. With 2 MB/s of allocation
the young collector adds 5.7 ms of CPU per second and no wakeups beyond the
marker's.

## Part 1: the slow regime and the price of waking the cluster

`walk22x4` (entry-locality's `walk22` with 4 traversals) on variant B,
1 worker at user-initiated QoS; per hop = (walk22x4 - median walkbuild22 of
the same companion) / (4 x 2^22), for time and energy. "Process" energy
includes the companion; "worker" subtracts the companion thread's own
energy. Main matrix (`results/dev-p1.txt`, 5 interleaved runs):

| configuration | ns/hop median | slow launches | nJ/hop process | nJ/hop worker | companion W | process W | P share | IPC |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| alone (idle cluster) | 496.9 | 3 of 5 | 288.1 | 288.1 | - | 0.92 | 1.000 | 0.81 |
| companion spinning (user-initiated) | 152.9 | 0 of 5 | 728.4 | 221.8 | 2.90 | 4.78 | 0.997 | 2.61 |
| companion timer 10 kHz | 218.7 | 2 of 5 | 225.5 | 221.0 | 0.03 | 1.47 | 0.999 | 1.83 |
| companion timer 1 kHz | 519.4 | 3 of 5 | 302.2 | 300.5 | 0.00 | 0.90 | 0.999 | 0.78 |
| companion timer 100 Hz | 608.6 | 3 of 5 | 284.2 | 284.0 | 0.00 | 0.79 | 0.999 | 0.67 |
| companion spinning at utility QoS | 613.5 | 3 of 5 | 433.3 | 318.5 | 0.19 | 1.01 | 0.504 | 1.17 |
| companion in a `wfe` loop | 252.9 | 0 of 5 | 307.8 | 228.2 | 0.30 | 1.72 | 0.999 | 0.73 |
| second worker, own graph (2 x 2^22) | 168.5 | 0 of 5 | 253.7 | 253.7 | - | 3.62 | 0.997 | 2.00 |

The regime is per launch and bimodal, so the medians above mix regimes.
Per launch, sorted by ns/hop, with each launch's process energy per hop:

| configuration | ns/hop per launch | nJ/hop process, same launches |
|---|---|---|
| alone | 184, 226, 497, 587, 607 | 224, 185, 288, 297, 305 |
| spin | 150, 152, 153, 162, 174 | 762, 728, 732, 691, 532 |
| timer 10 kHz | 157, 179, 219, 504, 614 | 225, 224, 199, 326, 347 |
| timer 1 kHz | 212, 236, 519, 601, 615 | 225, 190, 302, 325, 312 |
| timer 100 Hz | 225, 227, 609, 627, 649 | 185, 164, 290, 302, 284 |
| spin at utility | 229, 263, 614, 641, 655 | 205, 213, 433, 440, 445 |
| wfe | 170, 252, 253, 255, 255 | 235, 311, 326, 304, 308 |
| second worker | 167, 168, 168, 172, 191 | 254, 253, 254, 258, 187 |

**Energy per hop, slow regime against fast** (all single-worker launches of
the main matrix whose companion did not keep the cluster awake: alone,
timers, utility spin; split at 300 ns/hop):

| regime | launches | ns/hop | nJ/hop process | process W | P GHz | IPC |
|---|--:|--:|--:|--:|--:|--:|
| slow | 14 | 611.1 | 308.6 | 0.82 | 4.08 | 0.69 |
| fast | 11 | 224.8 | 204.7 | 1.54 | 3.78 | 1.79 |

**Slow-regime frequency** (added after the main matrix: `results/dev-p1x.txt`,
8 more interleaved runs of alone, 10 kHz timer, `wfe` and spin; together
with the main matrix):

| configuration | launches | slow | ns/hop fast / slow (medians) | nJ/hop process fast / slow | nJ/hop worker, all |
|---|--:|--:|---|---|--:|
| alone | 13 | 11 | 205 / 622 | 205 / 293 | 291 |
| timer 10 kHz | 13 | 8 | 157 / 592 | 226 / 340 | 309 |
| timer 1 kHz | 5 | 3 | 224 / 601 | 208 / 312 | 301 |
| timer 100 Hz | 5 | 3 | 226 / 627 | 175 / 291 | 284 |
| spin at utility | 5 | 3 | 246 / 641 | 209 / 440 | 319 |
| wfe | 13 | 0 | 170 / - | 283 / - | 234 |
| spin | 13 | 0 | 149 / - | 857 / - | 271 |

In the supplementary run every alone launch (8 of 8) was slow and the
10 kHz timer was slow 6 of 8, against 3 of 5 and 2 of 5 in the main matrix:
the regime also drifts over tens of minutes, independent of heat (nominal
throughout). Read the frequencies as "timers do not reliably help"; the
`wfe` and spin rows are 13 of 13 fast in both matrices.

Companions (medians over the walk launches):

| companion | QoS | wakeups or iterations per s | mean lateness us | CPU ms per s | its energy mW |
|---|---|--:|--:|--:|--:|
| spin | user-initiated | 1.9e9 | - | 998 | 2876 |
| timer 10 kHz | user-initiated | 9991 | 22 | 13 | 26 |
| timer 1 kHz | user-initiated | 1000 | 203 | 2 | 3 |
| timer 100 Hz | user-initiated | 100 | 1997 | 0 | 0 |
| spin at utility | utility (E cores) | 8.5e8 | - | 985 | 188 |
| wfe | user-initiated (P core) | 748 907 | - | 999 | 298 |

The `wfe` loop is scheduled as a running thread (it shows 100 percent CPU
time and holds a P core) but the core is clock-gated between events; the
generic timer's event stream ends each wait after about 1.3 us. A timer
companion sleeps in the scheduler between wakeups and, judging by the
result, lets the cluster drop again within microseconds.

**Chase, no VM** (`results/dev-p1chase.txt`, 256 MB, 2^25 timed hops, energy
over the hops only):

| companion | ns/hop (per launch) | nJ/hop process (per launch) | nJ/hop without the companion | process W | IPC |
|---|---|---|--:|--:|--:|
| none | 87.4 (85, 85, 87, 88, 92) | 43.7 (43, 43, 44, 44, 45) | 43.7 | 0.50 | 0.010 |
| spin | 82.1 (82, 82, 82, 82, 82) | 375.5 (368 to 376) | 68.7 | 4.57 | 1.500 |
| wfe | 181.7 (179, 181, 182, 190, 203) | 119.9 (118 to 131) | 72.0 | 0.66 | 0.000 |

The chase never entered the slow regime in this session (entry-locality saw
91 to 218 ns at 256 MB), so it cannot confirm the regime without the VM; it
does show the P core waiting on DRAM at 0.5 W, and that a `wfe` companion
**doubles** a pure DRAM chase's latency. Why is not known (the sibling
core's event-stream wakeups and the shared L2, presumably); a `wfe`
companion is not a free lunch for every workload.

**Recommendation for ADR 0003, condition 2: reword it; do not close it as
"accept".** The slow regime is not power saving: per hop it costs 1.4 to 1.5
times the CPU energy and 2.7 times the time of the fast regime, so a phone
in it is losing on both counts. It is reached by a single latency-bound
thread with the other P core idle, which is the main thread running
Smalltalk while workers idle. The cheap way out measured here is a
companion thread in a `wfe` loop on the other P core while a traversal-heavy
turn runs: 0.30 W, never slow in 13 launches, process energy per hop equal
to the slow regime's at 3.7 times the speed. A spinning companion is
excluded (4 times the energy). Timers and utility spins do not work. The
ADR should say: the 2x table cost per miss holds when the cluster is awake;
a shell may hold it awake with a `wfe` companion only for the duration of
long latency-bound work (measure the work first; the `wfe` companion slowed
a pure DRAM chase 2x); and energy, not just time, should be the measure.
What sets the regime (fabric or memory clock) is still unnamed; counters
were not read.

## Part 2: collector energy at realistic allocation rates

One main worker on the main thread allocating at a fixed rate in 120 Hz
display-link turns (generational-gc's survivors shape at 10 percent kept,
keepers die after 65 536 more are kept), a 200 MiB old heap behind it
mutated slowly (8 pointer stores and 64 OHPoints per frame, one 32 KiB
group replaced per second), 768 MiB heap, 4 MiB nursery, age 2, no
background workers; 30 s windows after 3 s of warm-up, 3 interleaved runs
(`results/dev-p2.txt`; 100 and 150 MB/s added afterwards in
`results/dev-p2x.txt`).

**Energy per MB allocated (the decision table), mJ/MB, process, medians:**

| MB/s | stw | conc-high | conc-utility | conc-mixed |
|--:|--:|--:|--:|--:|
| 1 (60 s) | 2.51 | - | 2.65 | - |
| 2 | 1.98 | 2.22 | 2.08 | 2.05 |
| 10 | 1.54 | 1.64 | 1.60 | 1.62 |
| 50 | 1.62 | 1.79 | 1.74 | 1.74 |
| 100 | 4.23 | 4.72 | 4.60 | 4.09 |
| 150 | 5.52 | 5.95 | 6.47 | 5.92 |
| 200 | 7.70 | 7.97 | 9.61 | 8.15 |

The VM threads alone (main + collector + marker, per-thread energy) are
within 0.1 mJ/MB of the process at every cell. Per configuration (medians;
fallbacks and missed frames summed over the 3 runs; pause = stop-the-world
scavenge for `stw`, the offload flip on the main worker otherwise):

| MB/s | cfg | energy J | main CPU s / J | collector CPU s / P share / J | marker CPU s / P share / J | cycles done | fallbacks | main pause p50 / p99 / max ms | missed120 (sum, max) | old HWM MB |
|--:|---|--:|---|---|---|--:|--:|---|---|--:|
| 2 | stw | 0.12 | 1.83 / 0.12 | - | - | 0 | - | 5.109 / 5.799 / 5.799 | 0, 0 | 211 |
| 2 | conc-high | 0.14 | 1.74 / 0.12 | 0.17 / 0.00 / 0.008 | 0.24 / 0.00 / 0.013 | 0 | 0 | 0.077 / 0.136 / 0.136 | 0, 0 | 211 |
| 2 | conc-utility | 0.13 | 1.72 / 0.12 | 0.17 / 0.00 / 0.008 | 0.08 / 0.00 / 0.004 | 0 | 0 | 0.076 / 0.148 / 0.148 | 0, 0 | 211 |
| 2 | conc-mixed | 0.13 | 1.72 / 0.11 | 0.17 / 0.00 / 0.008 | 0.08 / 0.00 / 0.004 | 0 | 0 | 0.078 / 0.152 / 0.152 | 0, 0 | 211 |
| 10 | stw | 0.48 | 6.43 / 0.48 | - | - | 0 | - | 4.581 / 5.608 / 5.797 | 0, 0 | 248 |
| 10 | conc-high | 0.52 | 6.10 / 0.46 | 0.78 / 0.00 / 0.041 | 0.24 / 0.00 / 0.012 | 0 | 0 | 0.088 / 0.121 / 0.141 | 0, 0 | 248 |
| 10 | conc-utility | 0.51 | 6.04 / 0.46 | 0.77 / 0.00 / 0.041 | 0.08 / 0.00 / 0.004 | 0 | 0 | 0.088 / 0.122 / 0.134 | 0, 0 | 248 |
| 10 | conc-mixed | 0.51 | 6.01 / 0.46 | 0.78 / 0.00 / 0.042 | 0.08 / 0.00 / 0.004 | 0 | 0 | 0.088 / 0.133 / 0.137 | 0, 0 | 248 |
| 50 | stw | 2.55 | 16.35 / 2.54 | - | - | 0 | - | 2.145 / 3.299 / 3.716 | 0, 0 | 434 |
| 50 | conc-high | 2.83 | 14.53 / 2.57 | 1.89 / 0.00 / 0.234 | 0.18 / 0.00 / 0.015 | 0 | 0 | 0.046 / 0.067 / 0.109 | 0, 0 | 434 |
| 50 | conc-utility | 2.74 | 15.33 / 2.50 | 2.02 / 0.00 / 0.230 | 0.07 / 0.00 / 0.005 | 0 | 0 | 0.050 / 0.069 / 0.105 | 0, 0 | 434 |
| 50 | conc-mixed | 2.75 | 15.16 / 2.51 | 1.98 / 0.00 / 0.229 | 0.07 / 0.00 / 0.005 | 0 | 0 | 0.050 / 0.068 / 0.095 | 0, 0 | 434 |
| 100 | stw | 13.32 | 14.72 / 13.31 | - | - | 1 full | - | 0.983 / 3.254 / 3.574 | 17, 7 | 657 |
| 100 | conc-high | 14.86 | 12.36 / 13.42 | 1.60 / 1.00 / 1.306 | 0.25 / 0.93 / 0.127 | 1 | 0 | 0.042 / 0.060 / 0.067 | 0, 0 | 461 |
| 100 | conc-utility | 14.47 | 12.50 / 13.83 | 3.89 / 0.00 / 0.600 | 0.18 / 0.00 / 0.031 | 1 | 0 | 0.042 / 0.060 / 0.074 | 0, 0 | 462 |
| 100 | conc-mixed | 12.89 | 15.36 / 11.69 | 2.16 / 0.66 / 1.158 | 0.19 / 0.00 / 0.031 | 1 | 0 | 0.044 / 0.063 / 0.092 | 0, 0 | 462 |
| 150 | stw | 26.05 | 13.79 / 26.04 | - | - | 1 full | - | 0.664 / 0.807 / 0.949 | 12, 4 | 657 |
| 150 | conc-high | 28.11 | 12.74 / 25.37 | 1.63 / 0.99 / 2.461 | 0.29 / 0.93 / 0.259 | 2 | 0 | 0.030 / 0.042 / 0.052 | 0, 0 | 461 |
| 150 | conc-utility | 30.56 | 12.61 / 29.42 | 5.54 / 0.00 / 1.067 | 0.26 / 0.00 / 0.060 | 2 | 0 | 0.029 / 0.042 / 0.061 | 10, 10 | 463 |
| 150 | conc-mixed | 27.97 | 13.76 / 25.43 | 1.71 / 1.00 / 2.474 | 0.28 / 0.00 / 0.058 | 2 | 0 | 0.031 / 0.044 / 0.054 | 0, 0 | 463 |
| 200 | stw | 48.53 | 14.51 / 48.51 | - | - | 2 full | - | 0.510 / 0.720 / 0.781 | 18, 6 | 657 |
| 200 | conc-high | 50.21 | 13.28 / 45.32 | 1.74 / 0.99 / 4.412 | 0.31 / 0.95 / 0.461 | 3 | 0 | 0.023 / 0.034 / 0.052 | 0, 0 | 462 |
| 200 | conc-utility | 60.55 | 12.96 / 58.73 | 6.73 / 0.00 / 1.672 | 0.33 / 0.00 / 0.088 | 3 | 0 | 0.022 / 0.033 / 0.070 | 20, 19 | 463 |
| 200 | conc-mixed | 51.34 | 14.04 / 46.72 | 1.71 / 1.00 / 4.504 | 0.36 / 0.00 / 0.087 | 3 | 0 | 0.024 / 0.036 / 0.050 | 0, 0 | 463 |

Per launch (fallbacks / missed120 / cycles done), concurrent configurations
and stw, where anything happened: stw 100 MB/s 0/7/0, 0/5/0, 0/5/0; 150
0/4/0 x 3; 200 0/6/0 x 3. conc-utility 150: 0/0/2, 0/0/2, 0/10/2; 200:
0/1/3, 0/19/3, 0/0/3. Every other concurrent launch 0 fallbacks, 0 missed.
The main thread's P-core share was 0.000 to 0.002 at 1 to 50 MB/s and 1.0
at 150 and 200 MB/s in every configuration.

Collector and marker CPU against the mutator, and what a CPU second costs
(medians, mJ):

| MB/s | cfg | (coll + marker) / main CPU | main per CPU s | collector per CPU s | marker per CPU s | collector waits (n, ms) | collector busy % |
|--:|---|--:|--:|--:|--:|---|--:|
| 2 | conc-high | 0.237 | 66 | 49 | 52 | 20, 4.1 | 0.6 |
| 2 | conc-utility | 0.143 | 66 | 48 | 50 | 132, 91.1 | 0.6 |
| 50 | conc-high | 0.142 | 179 | 120 | 80 | 16, 5.3 | 6.3 |
| 50 | conc-utility | 0.135 | 164 | 114 | 74 | 132, 94.5 | 7.3 |
| 100 | conc-high | 0.150 | 1081 | 803 | 515 | 8, 1.3 | 5.2 |
| 100 | conc-utility | 0.319 | 1107 | 155 | 172 | 132, 85.9 | 13.0 |
| 150 | conc-high | 0.151 | 2006 | 1512 | 889 | 16, 3.5 | 5.3 |
| 150 | conc-utility | 0.460 | 2272 | 193 | 227 | 134, 161.3 | 18.3 |
| 200 | conc-high | 0.154 | 3412 | 2534 | 1508 | 8, 1.4 | 5.8 |
| 200 | conc-utility | 0.543 | 4544 | 248 | 267 | 159, 127.5 | 22.9 |
| 200 | conc-mixed | 0.147 | 3323 | 2637 | 244 | 6, 1.1 | 5.7 |

(All rates and conc-mixed: `bench-output.txt`.) Marker energy per completed
marking cycle: 0.127 to 0.153 J at user-initiated (on P, 93 to 95 percent),
0.029 to 0.031 J at utility (on E), the same marked graph. No cycle started
below 100 MB/s in 30 s: the old heap stayed under the 60 percent threshold.

What the table says:

- **Energy is set by the clock the scheduler picks, not by the collector.**
  At 1 to 50 MB/s the whole app runs on E cores at 50 to 180 mJ per CPU
  second; at 150 to 200 MB/s the main thread moves to P and costs 2 to 4.5 J
  per CPU second. Energy per MB is flat at 1.5 to 2.5 mJ/MB up to 50 MB/s
  and rises 3 to 5 times from 100 MB/s on. The collector's and marker's own energy is
  9 to 15 percent of the total at user-initiated, 3 to 9 percent at utility.
- **At low rates the collector's QoS is irrelevant**: user-initiated
  collector and marker also ran on E cores (P share 0.00), and the four
  configurations differ by at most 0.2 mJ/MB. Stop-the-world is the
  cheapest by 5 to 12 percent (no barrier slow paths, no second thread),
  but its scavenge pauses on an E core are 4.5 to 5.3 ms p50 at 1 to 10
  MB/s (the offload flip is 0.08 ms) and its full collections miss 4 to 7
  frames per run from 100 MB/s on.
- **At 150 MB/s and up, a utility collector does not keep up cheaply.** It
  never fell back, but the main thread waits for it (130 to 160 waits a
  run, 86 to 161 ms; the user-initiated collector 8 to 20 waits, 1 to 5 ms)
  and missed frames in 3 of 6 launches at 150 and 200 MB/s. The energy it
  saves on its own thread (1.7 against 4.4 J at 200 MB/s) is lost on the
  main thread (58.7 against 45.3 J), which spends longer at a high clock.
  The 0.0 utility-QoS frames missed at 100 MB/s and 10 at 150 MB/s place the
  threshold between 100 and 150 MB/s on this kernel.
- **The marker belongs at utility.** conc-mixed equals conc-high in energy
  within 1 to 2 percent at 150 and 200 MB/s and beats it by 13 percent at
  100 MB/s, never missed a frame, and its marker spends 0.03 J per cycle
  instead of 0.13 to 0.15. Marking at utility ran at 2.9 to 3.4 GB per CPU
  second against 5.9 to 8.8 at user-initiated, and kept up at every rate
  measured (0 fallbacks).

**Recommendation for ADRs 0006 and 0008 (QoS on device):** young collector
at user-initiated, marker at utility, on device. Not "utility unless
headroom shrinks" for the young collector: its cost at low rates is the
same at either QoS because the scheduler puts it on E cores anyway, and at
high rates utility costs frames and energy. The marker at utility is
cheaper per cycle and kept up here, but this heap promoted at most 28
MB/s; the ADR 0006 headroom rule still applies, so the marker should be
raised to user-initiated when a cycle's promotion approaches the headroom
(not measured here). The 1 MB/s cross-check (60 s): stw 2.51, conc-utility
2.65 mJ/MB, 0.16 and 0.17 J per minute, no cycles, no frames missed; the
quiet app's collector costs 7 mJ per minute on E cores.

## Part 3: idle

60 s windows, 3 launches each, Part 2's Session with 5 background workers
(`results/dev-p3.txt`; the two `stw` rows added afterwards in
`results/dev-p3x.txt` with `KAJO_GC=stw KAJO_YOUNG=stw`, i.e. no marker or
collector thread). Per second of window, medians:

| mode | idle wakeups/s | interrupt wakeups/s | CPU ms/s | energy mW | main CPU ms/s | marker CPU ms/s | collector CPU ms/s | bg workers CPU ms/s | other threads CPU ms/s | frames/s |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| no VM | 0.0 | 0.1 | 0.02 | 0.00 | 0.00 | - | - | - | 0.00 | - |
| VM parked (offload + cm) | 131.6 | 213.9 | 1.98 | 0.11 | 0.01 | 1.96 | 0.00 | 0.000 | 0.00 | - |
| VM parked, stw (no marker) | 0.0 | 0.1 | 0.02 | 0.00 | 0.01 | - | - | 0.000 | 0.00 | - |
| display link only, VM never entered | 216.9 | 342.5 | 17.04 | 0.89 | 12.37 | 2.39 | 0.00 | 0.000 | 1.90 | 120.0 |
| tick: empty VM turn per frame | 216.5 | 343.2 | 17.54 | 0.90 | 12.73 | 2.39 | 0.00 | 0.000 | 1.90 | 120.0 |
| tick, stw (no marker) | 78.0 | 120.0 | 14.83 | 0.79 | 12.53 | - | - | 0.000 | 1.87 | 120.0 |
| tick + 2 MB/s, conc-utility | 208.2 | 347.9 | 64.77 | 4.12 | 54.47 | 2.42 | 5.72 | 0.000 | 1.61 | 120.0 |
| tick + 2 MB/s, conc-high | 582.0 | 909.4 | 70.63 | 4.35 | 55.08 | 7.65 | 5.64 | 0.000 | 1.01 | 120.0 |

Threads that ran (first launch, ms of CPU over 60 s): parked
`main:5.1, marker:128.4, t/p47:1.9`; parked stw `main:0.4, t/p47:0.1`;
tick + 2 MB/s at user-initiated `main:3470, coll:356, marker:488,
t/p47:111` (`t/p47` is a UIKit/GCD thread, priority 47). The five
background workers used 0.000 ms in every window: they sleep on their
condition variable as intended. The young collector sleeps when idle
(0.00 ms/s parked).

- **The marker thread is the only periodic VM activity, and it is
  periodic by construction.** `markerLoop` (`concurrent-young/.../Concurrent.swift`)
  waits with `pthread_cond_timedwait_relative_np` and a 1 ms timeout in its
  idle loop (so the first marker can retry freeing evacuated blocks every
  millisecond). Removing the marker thread (stw) removes every VM wakeup.
  Fix (for the production core, not done here): wait untimed when
  `pendingCount == 0`, and time the wait only while blocks are pending.
- **The UI tick costs nothing measurable beyond the display link**:
  entering and leaving the VM 120 times a second adds 0.5 ms of CPU per
  second and no wakeups. ADR 0004 needs no change for idle cost.
- **Allocation at 2 MB/s** adds 37 ms of main-thread CPU per second (the
  Smalltalk work itself) and 5.7 ms of young collector; with the marker at
  user-initiated, the marker's 1 ms waits coalesce less and triple the
  wakeups.

## Thermal checks

| matrix | first configuration at the start / end | end/start | thermal at line ends |
|---|---|--:|---|
| `dev-p1.txt` | walk22x4 alone, 4744 ms / 10755 ms | 2.27 | nominal 82 |
| `dev-p1x.txt` | walk22x4 alone, matrix runs 10.3 to 11.6 s / end 11.8 s | - | nominal 33 |
| `dev-p2.txt` | stw 2 MB/s, 125.8 / 124.5 mJ | 0.99 | nominal 50 |
| `dev-p2quiet.txt` | stw 1 MB/s, 158.2 / 156.8 mJ | 0.99 | nominal 7 |
| `dev-p3.txt` | no VM, 0.1 / 0.1 mJ | 1.00 | nominal 19 |
| `dev-p2x.txt`, `dev-p3x.txt` | (no drift repeat) | - | nominal 24, nominal 6 |

The phone never left `nominal`; every cool-down probe (16) found it nominal
at once. The Part 1 "drift" of 2.27 is the regime (fast launch at the
start, slow at the end), not heat. Energy repeats within 1 percent.

## Unplugged cross-check: not done

The cross-check needs someone to pull the cable. The app has the mode
(`part=unplugged`: launched over the cable, it waits for
`UIDevice.batteryState == .unplugged`, settles 20 s, then runs walk22x4 and
walkbuild22 alone and with a spinning companion, twice, in one process).
It was launched at the end of the session with a 15-minute wait; nobody
unplugged the phone, so it timed out after 900 s at `battery=full`
(`results/dev-unplugged.txt`). Every line above
ran on the cable with the battery `full`, where the phone runs from the
adapter; whether the regime frequency or the energies move on battery is
open.

## Deviations and honest notes

**Not done.**
- The unplugged cross-check (above): needs a human; the mode exists and
  was armed once.
- Performance counters, Instruments: not used, as the brief says. The cause
  of the slow regime (fabric or memory clock) stays unnamed.
- Marker QoS escalation under shrinking headroom was not measured; the
  heaviest run promoted 28 MB/s and no cycle fell back.
- No fix of the marker's timed wait was tried (it would need a recorded
  copy of `Concurrent.swift`); the stw control names the thread instead.

**Changed from the brief.**
- **Energy field.** `ri_billed_energy` does not measure the process's own
  work on iOS 27 (table at the top); `ri_energy_nj` does and is used
  throughout. Both, plus `ri_serviced_energy` and `ri_penergy_nj`, are on
  every line.
- **Survival shape**: generational-gc's `survivors.kasm` at 10 percent kept
  (rewritten as `power.kasm`'s per-frame `pwFrame:`), not `share.kasm` or
  the storm: it is parameterised, promotes into old space (11 percent of
  young bytes promoted at 200 MB/s) and has a deterministic checksum.
- **Old heap** built by oldheap.kasm's `ohBuild:of:` and mutated per frame
  by its `ohMutate:iters:` (64 iterations, 256 every 120th frame so one
  group is replaced per second), not concurrent-marking's own realistic
  scenario loop, which mutates in 100 000-iteration batches.
- **walk22x4** (4 traversals instead of 2) so the traversal dominates the
  launch; per hop subtracts the median `walkbuild22` of the same companion
  (as entry-locality subtracted walkbuildN).
- **Second worker** = `walk23x4` at 2 workers (each builds and walks its own
  2^22-node graph), not two independent processes.
- **Part 2 stw** runs `KAJO_GC=stw` (stop-the-world full collections; no
  marker thread), so it carries neither marker energy nor marker wakeups.
- **Part 1 runs**: 5 interleaved runs (the brief asked 3) plus 8 more for
  four configurations, because the regime is bimodal.

**Added beyond the brief.**
- Per-thread, per-core-type CPU time and energy from
  `proc_pidinfo(PROC_PIDTHREADCOUNTS = 34)`, a private flavor (SPEC.md).
  It gives the collector's and marker's P-core share and their own energy
  directly instead of by attribution, and the companion's energy. If Apple
  changes the record layout the fields go to `tc_ok=0`; they were 1 on
  every line.
- The `wfe` companion (a C target, `PowerC`), the chase with `wfe`, the
  slow-regime frequency matrix (`dev-p1x.txt`), 100 and 150 MB/s
  (`dev-p2x.txt`), the no-marker idle control (`dev-p3x.txt`), the "display
  link only" and "no VM" idle baselines.
- `ThreadCPU`'s thread classification by thread-id order at Runtime start
  (no VM source changed); `vm_threads=` reports `unexpected:0` on every line.

**Recorded copies and symlinks.** `swift/Sources/Kasm/KernelFiles.swift` is
a copy of device-measurement's with the changes in its header (default
`experimentsDir` from `#filePath`, entry-locality's sized walks, `walkNxR`,
`powerSources`). `ProcUsage.swift` is derived from entry-locality's (energy,
wakeup and QoS fields added). Every VMB, VMR and Kasm.swift file and every
VMRTests file is a symlink; nothing outside `experiments/power/` was
modified.

**Tests.** `swift test` in `swift/` on the Mac (default, no
ThreadSanitizer): PowerKitTests 11 and PowerVMTests 7 pass every time.
The symlinked VMRTests suite (72 tests) **passes when run on its own**
(`swift test --filter VMRTests`, 2 of 2) but **failed both full `swift
test` runs** on one test, `sharedYoungObjectsAreClaimedOnceByParallelScavengers`
(`verifyFailures == 0` fails: the young verifier found an error after
parallel scavenges). Run alone that test failed 1 of 20 times in this
package and 0 of 23 in concurrent-young's own package; concurrent-young's
full suite passed 2 of 2. The difference between the runs that fail is CPU
contention (the three test targets run concurrently in a full `swift
test`); the source is concurrent-young's VMR through device-measurement's
`Blocks.swift` (its only change is `vm_map` for `mach_vm_map`). This looks
like a schedule-dependent bug in the stop-the-world parallel scavenge that
the original suite does not expose under its usual load. It was not
investigated further; it does not touch any number above (the Part 2 stw
configuration uses that scavenge with one participant).

**Things that should make a reader careful.**
- Energy is CPU energy attributed to the process. DRAM energy is not in it,
  and a latency-bound walk is exactly the workload where DRAM and fabric
  energy matter; the slow-against-fast comparison in Part 1 could change
  sign if the fast regime's higher fabric clock costs more outside the CPU
  than the 100 nJ/hop it saves inside. Not measurable from the process.
- The slow regime drifts over tens of minutes: the alone configuration
  was slow in 3 of 5 launches in the main matrix and 8 of 8 in the
  supplementary one, both at nominal. Frequencies of 5 to 13 launches are
  indications; the 13-of-13 results for `wfe` and spin are the robust ones.
- Part 2 rates are body bytes of 24-byte PPoints; each also takes a
  16-byte table entry, so the heap traffic is 1.67 times the stated rate.
- The display link was asked for 120 Hz with a moving view, as in
  device-measurement; a static app may run its link slower and pay less.
- The 1 kHz companion was late by 203 us on average and the 100 Hz one by
  2 ms: timer coalescing, so those configurations wake less precisely than
  their names say (the measured rates are 1000 and 100 per second).
- Medians of 3 for Part 2; the 200 MB/s conc-utility frames missed are 1,
  19 and 0 in its three launches: whether utility misses frames at a given
  rate is a probability, not a threshold.
- Battery was `full` on every line (adapter power); see the unplugged note.

## 2026-11-02: Part 3 idle after the untimed marker wait

concurrent-young SPEC.md amendment 18: the marker waits untimed unless
evacuated blocks are pending (the timed 1 ms wait was the only periodic VM
activity above). The app rebuilt with it, `PARTS="build p3fix"`
(`results/dev-p3fix.txt`), parked and tick at conc-utility and conc-high
(marker and young collector at user-initiated), 60 s windows, 3 launches
each, interleaved, every line at nominal. Per second of window, medians:

| mode | cfg | idle wakeups/s before | after | interrupt wakeups/s before | after | CPU ms/s before | after | energy mW before | after | marker CPU ms/s after |
|---|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| VM parked | conc-utility | 131.6 | 0.08 | 213.9 | 0.11 | 1.98 | 0.02 | 0.11 | 0.00 | 0.000 |
| VM parked | conc-high | - | 0.05 | - | 0.10 | - | 0.02 | - | 0.00 | 0.000 |
| tick | conc-utility | 216.5 | 76.4 | 343.2 | 120.0 | 17.54 | 14.71 | 0.90 | 0.78 | 0.000 |
| tick | conc-high | - | 79.0 | - | 120.0 | - | 14.39 | - | 0.75 | 0.000 |

"Before" is the Part 3 table; parked and tick were not measured at
conc-high then (the 582 wakeups/s were tick + 2 MB/s at conc-high). The
after rows equal the no-marker floor (`stw` rows: parked 0.0, tick 78.0
idle wakeups/s): the marker thread exists (`vm_threads=...marker:1`) and
ran 0.000 ms in all 12 windows; it no longer appears in `threads=`. A
parked VM now costs nothing measurable; the tick's remaining wakeups are
the display link's.
