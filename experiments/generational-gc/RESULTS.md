# Results: a generational nursery on the object table VM

Built against `SPEC.md`: `../ui-thread-scheduling/swift` copied into
`swift/` and given per-worker nurseries, a stop-the-world parallel
scavenge, a write barrier with a remembered set, chunk-bitmap entry
allocation, and a test-only verifier. 24 headless tests pass (14 inherited,
run here generationally with 256 KiB nurseries and the verifier on, plus 10
new), also under ThreadSanitizer (`swift test --sanitize=thread`, three
consecutive clean runs after the fixes in section 7).

All numbers below come from one `./bench.sh` run. The summary is
`bench-output.txt` verbatim; raw lines are in `bench-raw-kernels.txt`,
`bench-raw-scenarios.txt` and `bench-raw-pauses.txt.gz` (one line per
pause, 56 129 pauses, gzipped); `PARTS=report ./bench.sh` regenerates
`bench-output.txt` from them. Machine: Apple M2 Max (8 P + 4 E cores), macOS 27.0.1,
Swift 6.4, no thread pinning, built-in display at 120.00 Hz. Old space is
64 MiB everywhere, as in the earlier experiments. Kernels: 5 interleaved
runs, medians; pause distributions are pooled over the 5 runs of a
configuration. Scenarios: 3 runs of 10 s after 1 s of warm-up, median run
by missed frames then maximum gap.

Configurations: `nobar` is the `-DNO_BARRIER` build (no barrier,
non-generational: the previous experiment's collector with this
experiment's entry allocator); `bar0` has the barrier compiled in with
nursery 0 (it runs on every store and never fires); `g1`, `g4`, `g16` are
generational with 1, 4 and 16 MiB per worker.

## Answer

- **Pause target (p99 under 2 ms, max under 4 ms, 8 workers allocating):
  not met in general.** It is met for every kernel with 1 MiB nurseries
  and for the low-survival kernels (`churn` at every size, `survivors5` up
  to 4 MiB). It is missed whenever the promoted volume per scavenge is
  large: `alloc` at 4 and 16 MiB (p99 4.4 and 4.9 ms), `survivors30` at
  4 MiB (p99 2.3, max 4.2 ms) and 16 MiB (p99 4.9 ms), `survivors5` at
  16 MiB (p99 3.1 ms), and in the app scenarios G2, G4 and G5 (p99 3.5 to
  3.6 ms; G3 had p99 1.8 ms but one 4.7 ms outlier). Scavenge pauses grow
  with the bytes each participant must copy (about 1.1 ms per MiB per
  participant with 8 participants). And every workload that keeps
  promoting still needs full collections (p50 4.7 to 7.4 ms, max about
  9 ms, 10 to 14 ms in the few cases where one is forced into a
  scavenge's pause), which the generational design does not shorten.
- **Write barrier:** within noise on `arith`, `fib`, `sends` and the
  allocation kernels; about +2 percent on single-worker `ivars` in both
  builds (1.022 and 1.021). The fast path is a `tbnz` plus two
  `ldrb`/`tb(n)z`.
- **Main thread under the allocation storm:** the generational collector
  did not fix the earlier storm at 4 MiB. G1 (non-generational) missed 1
  frame (runs: 4, 0, 1), G2 (4 MiB) 2 (3, 2, 2), G4 (4 MiB plus allocation
  on the main thread) 5 (5, 6, 4). `alloc`'s depth-16 trees (3 MiB live
  while being built) survive a 4 MiB nursery at 80 to 85 percent, so the
  world was stopped 44 percent of the time in G2 against 34 percent in G1.
  With 16 MiB nurseries (G5) survival fell to 20 percent, the world was
  stopped 17 percent of the time and no frame was missed in any run; the
  survivor workload (G3) also missed none.

## 1. Headless matrix

O build; medians of 5 runs; pauses pooled over the runs, ms. Allocation
kernels only (compute kernels: `bench-output.txt`).

| kernel | workers | config | wall ms | vs nobar | scavenges | pause p50 | p99 | max | promoted MB | survival % | remset mean | entry sweep p50 | max | fulls | full max | checksum |
|---|--:|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|---|
| alloc | 1 | nobar | 1905.7 | 1.00 | 0 | - | - | - | - | - | - | - | - | 15 | 3.91 | 41950911 |
| alloc | 1 | bar0 | 1909.3 | 1.00 | 0 | - | - | - | - | - | - | - | - | 15 | 4.09 | 41950911 |
| alloc | 1 | g1 | 2252.3 | 1.18 | 960 | 0.362 | 0.441 | 0.607 | 960.0 | 100.0 | 6 | 0.001 | 0.005 | 15 | 3.99 | 41950911 |
| alloc | 1 | g4 | 2145.2 | 1.13 | 238 | 1.447 | 1.752 | 1.896 | 706.0 | 74.2 | 8 | 0.004 | 0.014 | 11 | 4.35 | 41950911 |
| alloc | 1 | g16 | 1919.9 | 1.01 | 59 | 1.533 | 1.876 | 1.957 | 176.0 | 18.6 | 8 | 0.016 | 0.022 | 2 | 4.09 | 41950911 |
| alloc | 8 | nobar | 385.8 | 1.00 | 0 | - | - | - | - | - | - | - | - | 19 | 7.89 | 42008248 |
| alloc | 8 | bar0 | 375.8 | 0.97 | 0 | - | - | - | - | - | - | - | - | 19 | 7.60 | 42008248 |
| alloc | 8 | g1 | 526.0 | 1.36 | 177 | 0.683 | 1.240 | 1.534 | 859.7 | 100.0 | 34 | 0.004 | 0.042 | 19 | 10.17 | 42008248 |
| alloc | 8 | g4 | 490.4 | 1.27 | 31 | 2.973 | 4.422 | 4.561 | 697.4 | 79.8 | 38 | 0.016 | 0.052 | 21 | 8.32 | 42008248 |
| alloc | 8 | g16 | 306.6 | 0.79 | 7 | 3.246 | 4.875 | 4.875 | 155.2 | 17.8 | 33 | 0.055 | 0.145 | 5 | 8.19 | 42008248 |
| churn | 1 | nobar | 1540.3 | 1.00 | 0 | - | - | - | - | - | - | - | - | 11 | 3.53 | 256000032000000 |
| churn | 1 | bar0 | 1550.9 | 1.01 | 0 | - | - | - | - | - | - | - | - | 11 | 3.49 | 256000032000000 |
| churn | 1 | g1 | 1508.5 | 0.98 | 732 | 0.002 | 0.007 | 0.024 | 0.0 | 0.0 | 0 | 0.001 | 0.011 | 0 | - | 256000032000000 |
| churn | 1 | g4 | 1507.1 | 0.98 | 183 | 0.005 | 0.015 | 0.032 | 0.0 | 0.0 | 0 | 0.004 | 0.013 | 0 | - | 256000032000000 |
| churn | 1 | g16 | 1511.1 | 0.98 | 45 | 0.019 | 0.050 | 0.053 | 0.0 | 0.0 | 0 | 0.015 | 0.024 | 0 | - | 256000032000000 |
| churn | 8 | nobar | 236.4 | 1.00 | 0 | - | - | - | - | - | - | - | - | 11 | 3.99 | 32000032000000 |
| churn | 8 | bar0 | 234.6 | 0.99 | 0 | - | - | - | - | - | - | - | - | 11 | 4.17 | 32000032000000 |
| churn | 8 | g1 | 216.1 | 0.91 | 94 | 0.162 | 0.246 | 0.281 | 0.0 | 0.0 | 0 | 0.006 | 0.022 | 0 | - | 32000032000000 |
| churn | 8 | g4 | 207.2 | 0.88 | 24 | 0.202 | 0.316 | 0.318 | 0.0 | 0.0 | 0 | 0.019 | 0.069 | 0 | - | 32000032000000 |
| churn | 8 | g16 | 203.4 | 0.86 | 5 | 0.269 | 0.343 | 0.343 | 0.0 | 0.0 | 0 | 0.058 | 0.125 | 0 | - | 32000032000000 |
| survivors5 | 1 | nobar | 1164.9 | 1.00 | 0 | - | - | - | - | - | - | - | - | 6 | 3.27 | 6399993600000 |
| survivors5 | 1 | bar0 | 1172.5 | 1.01 | 0 | - | - | - | - | - | - | - | - | 6 | 3.02 | 6399993600000 |
| survivors5 | 1 | g1 | 1159.1 | 1.00 | 372 | 0.067 | 0.151 | 0.189 | 25.0 | 6.7 | 1005 | 0.003 | 0.013 | 0 | - | 6399993600000 |
| survivors5 | 1 | g4 | 1150.5 | 0.99 | 93 | 0.194 | 0.373 | 0.417 | 25.0 | 6.7 | 1000 | 0.012 | 0.022 | 0 | - | 6399993600000 |
| survivors5 | 1 | g16 | 1157.9 | 0.99 | 23 | 0.933 | 1.489 | 1.619 | 24.8 | 6.7 | 963 | 0.023 | 0.043 | 0 | - | 6399993600000 |
| survivors5 | 8 | nobar | FAILED (5/5 runs: out of memory) | | | | | | | | | | | | | |
| survivors5 | 8 | bar0 | FAILED (5/5 runs: out of memory) | | | | | | | | | | | | | |
| survivors5 | 8 | g1 | 167.1 | - | 47 | 0.375 | 0.638 | 0.662 | 26.3 | 7.1 | 7850 | 0.008 | 0.038 | 0 | - | 799993600000 |
| survivors5 | 8 | g4 | 158.0 | - | 12 | 0.652 | 1.125 | 1.154 | 26.0 | 7.2 | 7447 | 0.019 | 0.062 | 0 | - | 799993600000 |
| survivors5 | 8 | g16 | 158.0 | - | 2 | 1.931 | 3.081 | 3.081 | 20.6 | 8.1 | 4096 | 0.060 | 0.085 | 0 | - | 799993600000 |
| survivors30 | 1 | nobar | 1518.6 | 1.00 | 0 | - | - | - | - | - | - | - | - | 6 | 3.51 | 38399861600000 |
| survivors30 | 1 | bar0 | 1529.6 | 1.01 | 0 | - | - | - | - | - | - | - | - | 6 | 3.41 | 38399861600000 |
| survivors30 | 1 | g1 | 1579.2 | 1.04 | 403 | 0.154 | 0.247 | 0.363 | 147.6 | 36.6 | 965 | 0.002 | 0.008 | 2 | 2.93 | 38399861600000 |
| survivors30 | 1 | g4 | 1571.2 | 1.03 | 100 | 0.531 | 1.013 | 1.093 | 146.3 | 36.6 | 962 | 0.009 | 0.028 | 2 | 2.56 | 38399861600000 |
| survivors30 | 1 | g16 | 1543.2 | 1.02 | 25 | 1.008 | 2.937 | 3.121 | 53.6 | 13.4 | 911 | 0.028 | 0.045 | 0 | - | 38399861600000 |
| survivors30 | 8 | nobar | 237.2 | 1.00 | 0 | - | - | - | - | - | - | - | - | 8 | 5.52 | 4799861600000 |
| survivors30 | 8 | bar0 | 239.7 | 1.01 | 0 | - | - | - | - | - | - | - | - | 8 | 5.32 | 4799861600000 |
| survivors30 | 8 | g1 | 251.4 | 1.06 | 60 | 0.575 | 0.834 | 3.197 | 149.7 | 37.2 | 6777 | 0.011 | 0.034 | 2 | 10.13 | 4799861600000 |
| survivors30 | 8 | g4 | 234.7 | 0.99 | 13 | 1.651 | 2.264 | 4.194 | 144.3 | 36.9 | 6932 | 0.020 | 0.069 | 2 | 5.44 | 4799861600000 |
| survivors30 | 8 | g16 | 215.7 | 0.91 | 3 | 2.461 | 4.858 | 4.858 | 42.8 | 11.3 | 5461 | 0.058 | 0.270 | 0 | - | 4799861600000 |

`vs nobar` is the median wall time over `nobar`'s. Compute kernels never
allocate enough to scavenge (`arith`, `fib`, `sends` and `ivars` rows are
in `bench-output.txt`; every one is within 0.99 to 1.05 of `nobar` and has
no collection). `survivors5` with 8 workers ran out of memory in every
non-generational run (section 7, item 6); with a 512 MiB old space it
completes in 164.7 ms with 375 MiB of old space in use, against 158.0 ms
and 26 MiB promoted with 4 MiB nurseries in 64 MiB. Checksums agree across
every configuration and build.

Survival here is promoted bytes over young bytes. `survivors30` promotes
37 percent because the store's chunk arrays survive too; at 16 MiB stores
are dropped before their first scavenge, so it falls to 11 to 13 percent.

## 2. Scenarios

Median run of 3 (by missed frames, then max gap); pauses of the median run, ms.

| id | Hz | frames | drops | missed | gap max | worst run-loop iter (VM, GC park, GC enter wait) | scavenges | pause p50 / p99 / max | fulls | full p50 / max | ttsp p50 / p99 / max | main enter waits (max) | ev lat p50 / p99 / max | survival % | per-run missed |
|---|--:|--:|--:|--:|--:|---|--:|---|--:|---|---|---|---|--:|---|
| G0 | 120.00 | 1200 | 0 | 0 | 8.333 | 3.603 (0.000, 0.000, 0.000) | 0 | - / - / - | 0 | - / - | - / - / - | 0 (0.000) | - / - / - | - | 0, 0, 0 |
| G1 | 119.90 | 1199 | 1 | 1 | 17.314 | 14.684 (7.389, 0.000, 0.000) | 0 | - / - / - | 491 | 6.814 / 8.986 | - / - / - | 31 (8.097) | 0.950 / 8.985 / 13.610 | - | 4, 0, 1 |
| G2 | 119.80 | 1198 | 1 | 2 | 22.394 | 16.028 (6.771, 0.000, 6.195) | 725 | 2.649 / 3.642 / 4.196 | 389 | 6.534 / 7.841 | 0.073 / 0.120 / 0.132 | 768 (7.691) | 1.328 / 8.884 / 14.798 | 84.73 | 3, 2, 2 |
| G3 | 120.00 | 1200 | 0 | 0 | 8.333 | 9.403 (5.191, 5.055, 0.000) | 610 | 1.309 / 1.789 / 1.911 | 119 | 4.767 / 5.678 | 0.071 / 0.118 / 0.170 | 480 (5.599) | 0.116 / 5.331 / 9.268 | 36.21 | 0, 0, 0 |
| G4 | 119.50 | 1195 | 4 | 5 | 20.985 | 16.535 (10.502, 0.000, 2.431) | 721 | 2.601 / 3.567 / 5.132 | 397 | 6.530 / 8.207 | 0.073 / 0.126 / 0.163 | 661 (7.517) | 1.692 / 9.034 / 17.502 | 82.23 | 5, 6, 4 |
| G5 | 120.00 | 1200 | 0 | 0 | 8.333 | 10.981 (6.451, 0.000, 6.170) | 264 | 2.663 / 3.622 / 3.754 | 149 | 6.464 / 7.935 | 0.070 / 0.115 / 0.123 | 300 (7.687) | 0.270 / 7.298 / 10.943 | 19.52 | 0, 0, 0 |

Pauses pooled over all three runs, ms:

| id | scavenges | pause p50 | p99 | max | scavenges > 4 ms | ttsp p50 | p99 | max | fulls | full p50 | max | coord % | copy % | remset % | sweep % |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| G1 | 0 | - | - | - | 0 | - | - | - | 1474 | 6.77 | 8.99 | - | - | - | - |
| G2 | 2162 | 2.624 | 3.615 | 11.791 | 4 | 0.073 | 0.120 | 0.161 | 1193 | 6.50 | 14.34 | 8.9 | 90.5 | 0.0 | 0.6 |
| G3 | 1826 | 1.312 | 1.827 | 4.696 | 1 | 0.070 | 0.119 | 0.170 | 350 | 4.82 | 5.86 | 13.0 | 45.7 | 39.6 | 1.5 |
| G4 | 2168 | 2.590 | 3.525 | 5.132 | 3 | 0.073 | 0.124 | 0.163 | 1191 | 6.48 | 8.21 | 8.8 | 90.6 | 0.0 | 0.6 |
| G5 | 785 | 2.670 | 3.606 | 3.930 | 0 | 0.071 | 0.120 | 0.221 | 438 | 6.61 | 7.94 | 8.4 | 89.6 | 0.0 | 1.9 |

World stopped per 10 s (from `bench-raw-pauses.txt`, all three runs
agree within 0.4 points): G1 33.4 to 33.8 percent (491 full collections),
G2 44.4 to 44.7 percent (717 to 725 scavenges plus 389 to 405 full
collections), G3 13.7 to 13.9 percent, G4 44.3 to 44.4 percent, G5 16.3 to
16.6 percent.

Scenario extras (median runs):

- **G0**: turns=1206, vm_main_ms=0.97, max_turn_ms=0.014, max_turn_kind=tick, max_turn_gcpark_ms=0.000, max_turn_gcenter_ms=0.000, churn100us=2634, old_mb=0.063, rss_mb=103.38
- **G1**: turns=7621, vm_main_ms=3574.00, max_turn_ms=8.904, max_turn_kind=event, max_turn_gcpark_ms=0.000, max_turn_gcenter_ms=0.000, events_posted=10050, events_handled=10050, ev_post_lat_p50_ms=0.055, ev_post_lat_p99_ms=7.290, timer_late_p99_ms=7.306, churn100us=2547, old_mb=64.000, rss_mb=205.53
- **G2**: turns=7705, vm_main_ms=4143.43, max_turn_ms=7.760, max_turn_kind=event, max_turn_gcpark_ms=0.000, max_turn_gcenter_ms=7.691, events_posted=10054, events_handled=10053, ev_post_lat_p50_ms=0.113, ev_post_lat_p99_ms=6.638, timer_late_p99_ms=7.858, churn100us=2616, promoted_mb=15198.587, remset_mean=34.2, brk_coord=0.198, brk_copy=2.428, brk_rem=0.001, brk_sweep=0.014, parts_mean=7.1, esweep_p50=0.014, esweep_max=0.045, old_mb=20.344, rss_mb=270.42
- **G3**: turns=8990, vm_main_ms=1491.71, max_turn_ms=5.599, max_turn_kind=tick, max_turn_gcpark_ms=0.000, max_turn_gcenter_ms=5.599, events_posted=10050, events_handled=10050, ev_post_lat_p50_ms=0.054, ev_post_lat_p99_ms=3.881, timer_late_p99_ms=4.562, churn100us=2671, promoted_mb=5575.950, remset_mean=5695.8, brk_coord=0.169, brk_copy=0.609, brk_rem=0.542, brk_sweep=0.020, parts_mean=7.1, esweep_p50=0.020, esweep_max=0.075, old_mb=20.094, rss_mb=244.09
- **G4**: turns=7263, vm_main_ms=5367.11, max_turn_ms=10.502, max_turn_kind=event, max_turn_gcpark_ms=0.000, max_turn_gcenter_ms=2.431, events_posted=10049, events_handled=10049, ev_post_lat_p50_ms=0.218, ev_post_lat_p99_ms=6.774, timer_late_p99_ms=8.519, churn100us=2650, promoted_mb=15083.489, remset_mean=34.2, brk_coord=0.202, brk_copy=2.360, brk_rem=0.001, brk_sweep=0.014, parts_mean=7.2, esweep_p50=0.014, esweep_max=0.046, old_mb=40.313, rss_mb=273.89
- **G5**: turns=8372, vm_main_ms=1937.98, max_turn_ms=7.688, max_turn_kind=tick, max_turn_gcpark_ms=0.000, max_turn_gcenter_ms=7.687, events_posted=10049, events_handled=10049, ev_post_lat_p50_ms=0.054, ev_post_lat_p99_ms=4.728, timer_late_p99_ms=6.171, churn100us=2564, promoted_mb=5554.508, remset_mean=34.5, brk_coord=0.202, brk_copy=2.407, brk_rem=0.001, brk_sweep=0.048, parts_mean=7.1, esweep_p50=0.048, esweep_max=0.170, old_mb=53.406, rss_mb=392.47

Reading the scenarios:

- **G0** is clean (0 missed in every run), so the measurement is sound.
- **G1 reproduces the earlier drops**: 4, 0 and 1 missed frames against
  S4's 5, 0 and 7, with full-collection pauses of 6.8 ms p50 and 9.0 ms max
  (S4: 6.4 and 8.0).
- **G2 is not better than G1.** Each scavenge promotes 80 to 85 percent of
  about 24 MiB, so old space fills every two scavenges and a full
  collection follows (389 of them against G1's 491, each about as long).
  Scavenges add 1.9 s of stopped time per 10 s on top.
- **G5 and G3 hold 120 Hz** in all runs. Their pauses still exceed a
  quarter of a frame (G5 scavenges p99 3.6 ms; full collections up to
  7.9 ms), but less often, and the main thread reached every vsync.
- **G4** adds a churn burst of about 100 µs after every event on the main
  thread (about 2 600 Points per event). The main worker then fills its own
  nursery and is inside a turn during more pauses; it missed 4 to 6 frames.
- **Time to safepoint** stayed at 0.07 ms p50 and 0.12 ms p99 (max
  0.22 ms) in every scenario; the stop protocol is not the problem.
- **Worst main-thread stalls** were 9 to 16 ms in every loaded scenario.
  Some contain 6 to 8.7 ms of measured waiting at `enterVM` for a pause in
  progress (G2, G5). Others show 7 to 10.5 ms of "VM" time with no
  measured GC wait (G1, G4). That is a measurement gap, not Smalltalk:
  `enterVM` and `leaveVM` take the safepoint mutex before the measured
  wait starts, and a stopper holds that mutex for the whole of a
  mark-sweep (and a scavenge's prep and finish), so blocking on it counts
  as VM time. The inherited instrumentation has the same gap.
- **Rare scavenge outliers** (G2: 4 of 2 162 above 4 ms, worst 11.8 ms; G4:
  3 of 2 168, worst 5.1 ms; G3: 1 of 1 826, 4.7 ms) are coordination, not
  copying: in the worst one the
  critical participant copied for 2.3 ms and the remaining 9.5 ms are
  between participants (one thread descheduled after it finished, with
  7 workers, the main thread and AppKit's threads on 12 cores).

## 3. Pause scaling and breakdown

| kernel | workers | scavenges | pause p50 | p99 | max | participants | promoted KiB / scavenge | coord % | roots % | remset % | copy % | entry sweep % | ttsp p50 ms | mean busy / pause |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| alloc | 1 | 1190 | 1.462 | 1.793 | 1.845 | 1.0 | 3038 | 0.3 | 0.1 | 0.0 | 99.3 | 0.4 | 0.000 | 1.00 |
| alloc | 2 | 605 | 1.572 | 2.080 | 3.837 | 2.0 | 6034 | 2.7 | 0.1 | 0.0 | 96.8 | 0.4 | 0.009 | 0.92 |
| alloc | 4 | 303 | 1.874 | 2.734 | 2.933 | 4.0 | 11817 | 5.2 | 0.1 | 0.0 | 94.1 | 0.5 | 0.025 | 0.86 |
| alloc | 8 | 153 | 3.092 | 4.458 | 5.681 | 7.9 | 22746 | 9.1 | 0.1 | 0.0 | 90.1 | 0.7 | 0.090 | 0.82 |
| churn | 1 | 915 | 0.005 | 0.016 | 0.046 | 1.0 | 0 | 25.7 | 5.5 | 0.0 | 2.0 | 66.8 | 0.000 | 0.83 |
| churn | 2 | 460 | 0.021 | 0.044 | 0.073 | 2.0 | 0 | 60.2 | 2.7 | 0.0 | 0.8 | 36.2 | 0.008 | 0.28 |
| churn | 4 | 230 | 0.054 | 0.101 | 0.119 | 4.0 | 0 | 79.1 | 2.6 | 0.0 | 0.4 | 17.9 | 0.025 | 0.13 |
| churn | 8 | 119 | 0.211 | 0.327 | 0.371 | 7.5 | 0 | 88.4 | 1.5 | 0.0 | 0.2 | 9.9 | 0.096 | 0.07 |
| survivors30 | 1 | 500 | 0.528 | 1.084 | 1.317 | 1.0 | 1499 | 0.8 | 0.2 | 45.4 | 52.1 | 1.5 | 0.000 | 0.99 |
| survivors30 | 2 | 254 | 0.700 | 1.361 | 1.565 | 2.0 | 2961 | 3.0 | 0.3 | 43.3 | 51.7 | 1.7 | 0.009 | 0.96 |
| survivors30 | 4 | 125 | 1.007 | 1.502 | 2.054 | 4.0 | 5878 | 5.4 | 0.3 | 46.9 | 46.0 | 1.4 | 0.023 | 0.91 |
| survivors30 | 8 | 62 | 1.667 | 2.045 | 2.056 | 8.0 | 11640 | 11.7 | 0.2 | 43.0 | 43.8 | 1.3 | 0.092 | 0.84 |

The breakdown is a share of the summed scavenge pause time. `coord` is
time to safepoint, prep, finish, waking participants, imbalance and the
copy barrier; `roots`, `remset` and `copy` are the critical participant's
(longest copy time) root scanning, remembered-set scanning and transitive
copying; `entry sweep` is the longest sweep. `mean busy / pause` is the
average participant's busy time over the pause.

- **`alloc`** (75 percent survival) is all copying: each participant
  promotes about 3 MiB whatever the worker count, and the pause still grows
  from 1.46 to 3.09 ms p50. Per-participant copy throughput halves from 1
  to 8 participants (about 2.1 to 1.0 GB/s per thread). Imbalance is not
  the main cause: with work sharing the average participant is busy for
  82 percent of the pause at 8 workers. Pretouching all heap pages and
  raising worker QoS made no measurable difference (single runs, within
  noise; not kept). The likely causes are memory-system contention and
  E-cores among the participants; not dissected.
- **`churn`** (nothing survives) has nothing to copy: 0.005 ms with one
  worker, 0.21 ms with eight, 88 percent of it coordination (time to
  safepoint alone is 0.096 ms p50). This is the floor of a stop-the-world
  young collection on this machine with 8 workers.
- **`survivors30`**: the remembered set is 43 to 47 percent of every pause
  at every worker count. Each scavenge remembers about 6 900 holders (the
  store's 64-slot chunk arrays, striped on purpose) and scans all their
  slots: remembering whole objects means scanning every slot of a holder
  for one young value.
- Entry sweep is 0.4 to 1.7 percent of a pause that copies anything, and
  most of `churn`'s nearly empty one (section 6).

## 4. Barrier cost

| kernel | workers | build | nobar | bar0 | bar0/nobar | g4 | g4/nobar | barrier slow-path calls (g4) |
|---|--:|---|--:|--:|--:|--:|--:|--:|
| arith | 1 | O | 2764.2 | 2764.8 | 1.000 | 2768.9 | 1.002 | 0 |
| arith | 1 | align32 | 2780.5 | 2768.0 | 0.996 | 2769.3 | 0.996 | 0 |
| arith | 8 | O | 370.4 | 372.5 | 1.006 | 367.3 | 0.992 | 0 |
| arith | 8 | align32 | 369.5 | 373.4 | 1.011 | 371.5 | 1.005 | 0 |
| fib | 1 | O | 1608.7 | 1607.9 | 1.000 | 1604.0 | 0.997 | 0 |
| fib | 1 | align32 | 1608.0 | 1607.6 | 1.000 | 1604.7 | 0.998 | 0 |
| fib | 8 | O | 207.6 | 211.9 | 1.021 | 213.1 | 1.026 | 0 |
| fib | 8 | align32 | 209.2 | 208.4 | 0.996 | 209.9 | 1.003 | 0 |
| sends | 1 | O | 2320.1 | 2315.7 | 0.998 | 2316.4 | 0.998 | 0 |
| sends | 1 | align32 | 2324.8 | 2320.7 | 0.998 | 2321.7 | 0.999 | 0 |
| sends | 8 | O | 308.8 | 311.8 | 1.010 | 306.3 | 0.992 | 0 |
| sends | 8 | align32 | 311.1 | 315.4 | 1.014 | 308.3 | 0.991 | 0 |
| ivars | 1 | O | 1869.7 | 1910.2 | 1.022 | 1912.5 | 1.023 | 0 |
| ivars | 1 | align32 | 1869.8 | 1908.9 | 1.021 | 1911.3 | 1.022 | 0 |
| ivars | 8 | O | 244.1 | 246.6 | 1.010 | 254.0 | 1.041 | 0 |
| ivars | 8 | align32 | 247.4 | 252.3 | 1.020 | 251.2 | 1.015 | 0 |
| alloc | 1 | O | 1905.7 | 1909.3 | 1.002 | 2145.2 | 1.126 | 2099 |
| alloc | 1 | align32 | 1900.7 | 1920.4 | 1.010 | 2179.1 | 1.146 | 2100 |
| alloc | 8 | O | 385.8 | 375.8 | 0.974 | 490.4 | 1.271 | 2078 |
| alloc | 8 | align32 | 374.2 | 374.7 | 1.001 | 495.3 | 1.324 | 2142 |
| churn | 1 | O | 1540.3 | 1550.9 | 1.007 | 1507.1 | 0.978 | 0 |
| churn | 1 | align32 | 1541.5 | 1548.3 | 1.004 | 1506.9 | 0.978 | 0 |
| churn | 8 | O | 236.4 | 234.6 | 0.992 | 207.2 | 0.876 | 0 |
| churn | 8 | align32 | 242.4 | 237.1 | 0.978 | 203.9 | 0.841 | 0 |
| survivors5 | 1 | O | 1164.9 | 1172.5 | 1.007 | 1150.5 | 0.988 | 749873 |
| survivors5 | 1 | align32 | 1166.2 | 1174.9 | 1.007 | 1146.7 | 0.983 | 749873 |
| survivors5 | 8 | O | FAILED | FAILED | - | 158.0 | - | 728148 |
| survivors5 | 8 | align32 | FAILED | FAILED | - | 157.1 | - | 728694 |
| survivors30 | 1 | O | 1518.6 | 1529.6 | 1.007 | 1571.2 | 1.035 | 3082032 |
| survivors30 | 1 | align32 | 1545.7 | 1529.0 | 0.989 | 1569.6 | 1.015 | 3082541 |
| survivors30 | 8 | O | 237.2 | 239.7 | 1.011 | 234.7 | 0.989 | 2879102 |
| survivors30 | 8 | align32 | 236.5 | 243.6 | 1.030 | 233.8 | 0.989 | 2907086 |

`arith`, `fib` and `sends` store nothing into heap objects in their loops;
their `bar0/nobar` ratios are 0.996 to 1.021, noise of the 8-worker runs
included.
`ivars` stores SmallIntegers into ivars in its inner loop: `bar0/nobar` is
1.022 (O) and 1.021 (align32) with one worker, the only consistent
signal, so the barrier's first test (`v & 1`) costs about 2 percent on a
store-dense loop. The allocation kernels stay within 0.974 to 1.030 in
`bar0`; `g4` changes them for collector reasons, not the barrier (`churn`
gets 2 to 16 percent faster, `alloc` 13 to 32 percent slower).

The barrier's slow path (old holder, young value) ran 2 100 times in
`alloc` and 0.75 to 3.1 million times in the survivors kernels; its cost is
inside their wall times above.

## 5. Barrier sites

13 store sites write an oop that may be a young heap object into a heap
object and carry the barrier. Two are visible to Smalltalk, eleven are
VM-internal (all in `Process.swift`, marked `// barrier site:`).

| # | site | store | needed? | caught when removed |
|--:|---|---|---|---|
| 1 | interpreter `store_ivar` | any ivar | yes | yes (`oldHolderOf...`, `aFullCollection...`) |
| 2 | primitive `at:put:` | any indexed slot | yes | yes |
| 3 | `appendLocked` | tail Process `next` (ready queue) | yes | yes |
| 4 | `unlinkLocked` | previous Process `next` (ready queue or waiter list) | yes | yes |
| 5 | `finishLocked` | Process `result` | yes | yes |
| 6 | `primWait` | Process `waitingOn` | yes (old Process, young Semaphore) | yes |
| 7 | `primWait` | last waiter's `next` | yes | yes |
| 8 | `primWait` | Semaphore `lastWaiter` | yes | yes |
| 9 | `primWait` | Semaphore `firstWaiter` (list was empty) | redundant: site 8 remembers the same holder in the same critical section | no |
| 10 | `signalLocked` | Semaphore `firstWaiter` (pop) | redundant: a young waiter was appended this cycle through site 8 | no |
| 11 | `primTerminate` | Semaphore `firstWaiter` (unlink) | redundant, as 10 | no |
| 12 | `primTerminate` | Semaphore `lastWaiter` (unlink) | redundant, as 10 | no |
| 13 | `createProcess` | Process `exitSem` | redundant: the Process was allocated in the same primitive with no safepoint since, so it is young | no |

**VM-internal count: 11 sites** (all in `Process.swift`), plus the two
Smalltalk-visible ones. Removing each one in turn (mutation testing,
`schedulerStoresIntoOldObjectsAreBarriered` and
`oldHolderOfAYoungObjectIsRememberedAndTheYoungOneSurvives`): the 2
Smalltalk-visible and 6 of the 11 internal sites fail the tests through
the verifier's remembered-set check. The other 5 cannot fail: with
object-granularity remembering, another barriered store into the same
holder in the same critical section (or the holder being young) already
covers them. They are kept, because card marking or a reordering would
make them necessary.

Not barriered, by design (SPEC.md "Write barrier"): stores of SmallIntegers
and of `nil` (Process state, priority, affinity, saved registers, record
index, id, Semaphore counts, list terminators), initialising stores into a
fresh object, the native root arrays scanned at every scavenge (globals,
class table, ready-queue heads and tails, the pending-root table, host
roots, symbol roots, Process records and stacks), and image building (the
boot worker allocates old). DESIGN.md's "event queue" and "class table
updates" are native arrays here, so they need no barrier.

## 6. Entry churn

| kernel | workers | config | entries alloc / scavenge | freed / scavenge | entry sweep p50 / max ms | sweep share % | table hwm (entries) | fresh chunks | bits per word taken | word takes |
|---|--:|---|--:|--:|---|--:|--:|--:|--:|--:|
| alloc | 1 | nobar | - | - | - / - | - | 2801664 | 683 | 64.0 | 655537 |
| alloc | 1 | g1 | 43690 | 0 | 0.001 / 0.005 | 0.3 | 2764800 | 674 | 63.9 | 656486 |
| alloc | 1 | g4 | 174762 | 45159 | 0.004 / 0.014 | 0.3 | 2764800 | 674 | 64.0 | 655854 |
| alloc | 1 | g16 | 699050 | 568715 | 0.016 / 0.022 | 1.3 | 3284992 | 801 | 64.0 | 655825 |
| alloc | 8 | nobar | - | - | - / - | - | 2813952 | 686 | 64.0 | 656962 |
| alloc | 8 | g1 | 210787 | 0 | 0.004 / 0.042 | 0.9 | 3014656 | 735 | 63.9 | 657950 |
| alloc | 8 | g4 | 1232352 | 241662 | 0.016 / 0.052 | 0.7 | 3125248 | 762 | 63.9 | 657096 |
| alloc | 8 | g16 | 5354566 | 4400241 | 0.055 / 0.145 | 2.1 | 7086080 | 1729 | 64.0 | 656557 |
| churn | 1 | nobar | - | - | - / - | - | 2801664 | 683 | 64.0 | 500013 |
| churn | 1 | g1 | 43690 | 43688 | 0.001 / 0.011 | 48.2 | 53248 | 12 | 63.9 | 500996 |
| churn | 1 | g4 | 174762 | 174760 | 0.004 / 0.013 | 68.3 | 184320 | 44 | 64.0 | 500241 |
| churn | 1 | g16 | 699050 | 699048 | 0.015 / 0.024 | 75.8 | 708608 | 172 | 64.0 | 500052 |
| churn | 8 | nobar | - | - | - / - | - | 2809856 | 685 | 64.0 | 500059 |
| churn | 8 | g1 | 339116 | 339098 | 0.006 / 0.022 | 4.3 | 368640 | 89 | 63.9 | 501533 |
| churn | 8 | g4 | 1333153 | 1333135 | 0.019 / 0.069 | 10.5 | 1413120 | 344 | 64.0 | 500170 |
| churn | 8 | g16 | 5493308 | 5493288 | 0.058 / 0.125 | 23.7 | 5595136 | 1365 | 64.0 | 500029 |
| survivors5 | 1 | nobar | - | - | - / - | - | 2740224 | 668 | 63.9 | 250548 |
| survivors5 | 1 | g1 | 42938 | 40756 | 0.003 / 0.013 | 4.3 | 860160 | 209 | 18.9 | 846423 |
| survivors5 | 1 | g4 | 171756 | 163031 | 0.012 / 0.022 | 5.1 | 983040 | 239 | 22.5 | 711363 |
| survivors5 | 1 | g16 | 686896 | 652000 | 0.023 / 0.043 | 2.5 | 1449984 | 353 | 40.8 | 392513 |
| survivors5 | 8 | g1 | 335989 | 318850 | 0.008 / 0.038 | 2.5 | 1150976 | 280 | 30.5 | 526202 |
| survivors5 | 8 | g4 | 1334345 | 1266320 | 0.019 / 0.062 | 2.7 | 2105344 | 513 | 50.4 | 317586 |
| survivors5 | 8 | g16 | 5338353 | 5063652 | 0.060 / 0.085 | 2.7 | 5832704 | 1423 | 60.9 | 262913 |
| survivors30 | 1 | nobar | - | - | - / - | - | 2543616 | 620 | 63.4 | 253430 |
| survivors30 | 1 | g1 | 39739 | 27685 | 0.002 / 0.008 | 1.3 | 2134016 | 520 | 27.3 | 589884 |
| survivors30 | 1 | g4 | 159064 | 110821 | 0.009 / 0.028 | 1.5 | 2195456 | 535 | 27.6 | 582014 |
| survivors30 | 1 | g16 | 636260 | 565759 | 0.028 / 0.045 | 2.1 | 2342912 | 571 | 35.4 | 454593 |
| survivors30 | 8 | nobar | - | - | - / - | - | 2469888 | 602 | 59.2 | 271590 |
| survivors30 | 8 | g1 | 264880 | 184455 | 0.011 / 0.034 | 1.9 | 2306048 | 562 | 27.9 | 576602 |
| survivors30 | 8 | g4 | 1208590 | 841816 | 0.020 / 0.069 | 1.4 | 2707456 | 660 | 40.9 | 393328 |
| survivors30 | 8 | g16 | 4946211 | 4510118 | 0.058 / 0.270 | 3.0 | 5873664 | 1433 | 58.1 | 276690 |

- **The table did not become the bottleneck.** Entries are never
  renumbered and there is no bulk reset, yet the sweep after a scavenge
  costs 0.001 to 0.06 ms p50 and at most 0.27 ms, 0.3 to 5 percent of
  any pause that copies something. It touches only the bitmap words taken
  since the last scavenge (one word per 64 young entries), never the
  entries themselves. `churn` frees 1.33 million entries per 8-worker
  scavenge at 4 MiB in 0.019 ms p50.
- **Allocation got cheaper, not dearer.** A worker takes a whole bitmap
  word (64 entries) at a time and allocates with `ctz`; `churn` runs 2 to
  14 percent faster generationally than `nobar`.
- **Survivors fragment the bitmap.** With 5 to 30 percent survival a word
  taken yields 19 to 41 free entries instead of 64 at 1 MiB, so there are
  up to 3.4 times more word takes (846 000 against 250 000). Still cheap,
  but it is the first sign of the scattered-survivor problem ADR 0003
  predicted.
- **The table grows with nursery capacity, not with live data.** Every
  young object needs an entry, so the table's high-water mark tracks the
  objects that fit in all nurseries: 5.6 million entries (90 MB of table)
  for `churn` with 8 x 16 MiB, 7.1 million for `alloc`, against 2.8
  million non-generationally. With 24-byte bodies the table needs two
  thirds of the nursery's size again in entries. On a phone that is the
  real cost.

## 7. Honest notes

**What was hard, and what broke:**

1. **Promotion on first survival meets medium-lived data.** `alloc` builds
   a 3 MiB tree per worker; at 1 and 4 MiB most of the nursery is the tree
   under construction, survival is 74 to 100 percent, and the nursery only
   adds copying in front of the full collections. It is 13 to 36 percent
   slower than non-generational at 1 and 4 MiB; at 16 MiB it is level with
   one worker and 21 percent faster with eight. The same happens to the app storm (G2).
2. **Old space smaller than the nurseries.** Seven 16 MiB nurseries hold
   112 MiB of young data against a 64 MiB old space, so even 20 percent
   survival triggers a full collection every two scavenges (G5: 149 in
   10 s). Old space has to be sized with the nurseries.
3. **A scavenge stacked on a mark-sweep** made 9 to 14 ms pauses and frame
   drops in the first scenario runs. The full collection now gets its own
   pause, requested 1 ms after the scavenge at a budget check, and
   predictively (when another scavenge like the last would cross the soft
   limit). With 1 MiB nurseries the "far over the limit" fallback still
   combines them sometimes (`survivors30` g1: full max 10.1 ms).
4. **The inherited stop protocol had a latent bug.** A parked worker
   decremented `parked` when it woke, so a stop requested immediately
   after another (the pending full collection) counted released, running
   workers as parked and collected under them. It crashed with "live body
   in a nursery". Fix: the stopper zeroes `parked` when it releases the
   world. A regression test catches the old protocol in about one run of
   three.
5. **ThreadSanitizer found four things**, each fixed: (a) the test that
   shares young objects between workers first did it through plain slot
   stores, a Smalltalk-level race and unsafe publication on arm64; it now
   uses a Semaphore as a mutex. (b) Writing a counter field of the shared
   GC struct under the packet lock was a Swift access race on the whole
   struct, as AGENTS.md warns; the counts live behind their own pointer.
   (c) An idle worker updated its own `Worker` struct after waking but
   before re-entering the VM, while a stopper retired that worker's
   buffers: workers may touch their own struct only inside the VM. (d)
   TSan records a failed compare-and-swap as an atomic write, so the
   winner's later plain load of the same header was reported; the load is
   now atomic (a plain `ldr` on arm64).
6. **The non-moving old space fragments.** `survivors5` with 8 workers
   keeps 5 percent of its Points, scattered one per 20 across blocks, and
   the non-generational sweep frees only completely empty blocks: it pinned
   375 MiB and ran out of a 64 MiB heap in every run. Generationally the
   survivors are copied together and the same run needs 26 MiB.
7. **Host-side reads became unsafe.** With a non-moving heap the shell read
   Process slots outside the VM under the scheduler lock (`checkStuck`,
   `processState`). Young bodies now move, so these enter the VM.
8. **Per-participant copy throughput halves at 8 participants** (section
   3), so pause time is about promoted bytes per participant times a rate
   that degrades with parallelism. Work sharing fixed the imbalance but not
   the rate.
9. **Remembered whole objects** make a large holder expensive: one young
   value in a 64-slot array costs a 64-slot scan, and `survivors30` spends
   43 percent of its pauses there.
10. **GC waits on the main thread are under-attributed** (section 2): time
   blocked on the safepoint mutex in `enterVM`/`leaveVM` counts as VM time.
   Frame counts are unaffected; the stall attribution is.

**What the object table bought.** Promotion never updates a reference:
the oop is the same before and after, so a scavenger claims an object
with one CAS clearing the young bit in its header, copies the body and
writes the new offset into the entry. A loser does nothing. There is no
forwarding pointer, no reference fix-up pass and no "scan the copy to
redirect slots" step; `drain` only looks for more young objects. Raw
pointers the interpreter keeps (pc, literals) point into methods, which
are always old.

**What a real system needs next:**

- **An age field or survivor spaces.** Promote after N survivals instead of
  one. For `alloc`'s 3 MiB trees, keeping objects young for one more
  scavenge would let most trees die before promotion: far fewer full
  collections, at the cost of copying survivors more than once (scavenge
  pauses would not shrink) and a survivor reserve per worker. It is the
  fix for G2, not for the pause target.
- **Concurrent or incremental old-space marking.** Full collections of 5
  to 9 ms remain in every workload that promotes, and they are now the
  frame-droppers. A generational nursery reduces how often they run; only
  a concurrent marker bounds them. The object table gives a single word per
  object for publishing moves, which helps a concurrent compactor later.
- **Compaction of old space.** Non-moving old space with whole-block
  reclamation pins blocks (item 6); promotion compacts young survivors
  but old garbage still fragments old blocks.
- **Large-object handling.** Every object up to 32 KiB is allocated young
  and copied when it survives; large arrays should be allocated old.
- **Card marking or slot remembering** for large holders (item 9).
- **A bounded pause per participant.** Since pause time tracks promoted
  bytes per participant, a nursery size chosen by observed survival (or a
  pause target) would keep pauses inside a budget; fixed 4 and 16 MiB
  nurseries do not.
- **The main thread outside the stop.** The main thread waits at
  `enterVM` or parks inside its turn for the whole pause. A main thread
  that can keep running UI-only work during a scavenge (it holds no young
  references the scavenge needs, or its stack is scanned first) would take
  pauses off the frame path entirely.
- **An entry table sized for the nursery** (section 6).

## 8. Recommendation input

On this machine a generational nursery on the object table works and is
cheap where the generational hypothesis holds. With 8 workers allocating
short-lived objects (`churn`) a young collection takes 0.2 to 0.3 ms
(p99 0.34 ms, mostly time to safepoint), the entry table is swept in tens
of microseconds without bulk reset or renumbering, allocation got faster,
and the write barrier costs about 2 percent on a store-dense loop and
nothing measurable elsewhere. Correctness rests on a verifier that checks
the remembered-set invariant and exactly-once promotion inside every test
pause, and ThreadSanitizer is clean. But **the stated pause target was not
met**: p99 under 2 ms and max under 4 ms held only for 1 MiB nurseries and
for low-survival kernels, while `alloc` and `survivors30` at 4 or 16 MiB
and the app scenarios G2, G4 and G5 had scavenge p99s of 2.3 to 4.9 ms,
because pause time follows promoted bytes per participant and parallel
copying scaled poorly (about 1 GB/s per participant at 8). Full
collections (p50 5 to 7 ms, max about 9 ms, 10 to 14 ms in rare combined
pauses) remain in every workload that promotes. Against the earlier storm, 4 MiB nurseries made the main
thread no better (G2: 2 missed frames, world stopped 44 percent of the
time, against 1 and 34 percent non-generationally); 16 MiB nurseries (G5)
and a 30 percent survivor workload (G3) held 120 Hz in every run.
Caveats: one machine (a Mac, not an iPhone); synthetic kernels; a fixed
64 MiB old space smaller than the nurseries; promotion on first survival
by design; no thread pinning, with participants possibly on E-cores; the
scenario window was frontmost; and the full-collection spacing (1 ms) and
nursery sizes were chosen, not tuned. Read together with ADR 0004, the
nursery removes most pause time for short-lived garbage but does not by
itself make pauses frame-safe: that needs at least an age policy for
medium-lived data, nurseries sized by observed survival, and a concurrent
old-space marker, or a main thread that does not wait for the stop.

## Deviations from DESIGN.md and SPEC.md

- **Remembered marker**: a byte map beside the table, not a header bit. A
  mutator setting a bit in a published header races with every other
  worker's plain header loads (TSan; also a real data race in the Swift
  memory model).
- **Entry sweep** covers the bitmap words taken since the last scavenge
  (the young log), not whole chunks. Fully and partially free chunks both
  go back to the global pool.
- **Claiming**: CAS on the header word clearing the young bit; any
  participant may promote any young object, not only its own nursery's.
  **Work sharing** (exported packets) was added after the first
  measurements.
- **Promotion reserve** (16 x nursery beyond the 64 MiB soft old space)
  instead of promotion-failure handling.
- **Full collections** get their own pause, requested 1 ms after the
  scavenge that predicts old space will overflow; a scavenge stacked on a
  mark-sweep was the first design. The full collection is a scavenge
  followed by the unchanged single-threaded mark-sweep (not shortened, as
  DESIGN.md asked).
- **Stop protocol**: the inherited `parked` accounting was fixed (section
  7, item 4).
- **G1** runs the barrier build with nursery 0 (the barrier never fires;
  section 4 shows it costs nothing on `alloc`), not the `NO_BARRIER` build.
- **G4**: "churn between events" is a burst of about 100 µs of Point
  allocation (calibrated at start-up) after every event, not an endless
  loop, so the main thread's occupancy stays near the other scenarios'
  instead of turning G4 into the earlier hog scenario.
- **`survivors5` non-generational with 8 workers** ran out of memory at
  64 MiB in every run; it is reported as failed, plus one extra
  configuration with a 512 MiB old space.
- **Survival** of the survivors kernels is measured, not nominal (7 and 37
  percent at 1 and 4 MiB, lower at 16 MiB).
- **`ivars`** is read from `../object-representation/kernels/`.
- **Pause scaling** was run for `alloc`, `churn` and `survivors30` at
  4 MiB with 1, 2, 4 and 8 workers.
- **Host helpers** (`processState`, `checkStuck`, kernel result ids) enter
  the VM.
- Not done: no age field, concurrent marking, compaction, or large-object
  space (non-goals); no Instruments trace of the remaining main-thread
  stalls; no device measurement.
