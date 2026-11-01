# Results: concurrent marking of old space

Built against `SPEC.md`: `../generational-gc/swift` copied into `swift/`,
with a snapshot-at-the-beginning (SATB) barrier, one or two marker threads,
a final-mark pause, a lazy sweep done in the background by the marker, a
fallback to the inherited stop-the-world collector, and a verifier that
compares the concurrent mark set with a from-scratch traversal at every
final mark. 34 headless tests pass (24 inherited, now run with concurrent
cycles at a 1 percent threshold and every verifier on, plus 10 new), also
under ThreadSanitizer (`swift test --sanitize=thread`: three consecutive
clean runs after the fix in section 6, and one more after the last change to
the barrier).

All numbers come from one `./bench.sh` run plus its `heap` part (added
afterwards, section 5). `bench-output.txt` is the report verbatim; raw lines
are in `bench-raw-kernels.txt`, `bench-raw-scenarios.txt` and
`bench-raw-pauses.txt.gz` (one line per pause and per concurrent cycle:
95 604 pauses, 11 182 cycles); `PARTS=report ./bench.sh` regenerates
`bench-output.txt`. Supplementary runs outside the bench are marked as such;
the raw lines of the C2 ones are in `bench-raw-extra-scenarios.txt`.
Machine: Apple M2 Max (8 P + 4 E cores), macOS 27.0.1, Swift 6.4, no thread
pinning, built-in display at 120.00 Hz. Nurseries 4 MiB everywhere. Old
space 64 MiB, or `2 N + 64` MiB for `oldheapN`. Kernels: 5 interleaved runs,
medians; pause and cycle distributions pooled over the 5 runs. Scenarios: 3
runs of 10 s after 1 s of warm-up, median run by missed frames then maximum
gap.

Configurations: `nomark` is the `-DNO_MARK_BARRIER` build with ADR 0005's
stop-the-world full collections; `stw` the same collector with the SATB
barrier compiled in (never on); `cm` concurrent marking with one marker
thread at QoS utility; `cm2` two markers; `force` concurrent marking with the
marking flag never cleared and a cycle started at every scavenge (the
"marking on continuously" measurement). Trigger threshold 60 percent of the
soft limit unless stated.

## Answer

- **Two short pauses: yes.** A full collection became an initial mark that
  rides on a scavenge, adding 0.004 to 0.049 ms p50 (max 0.18 ms) to it, and
  a final mark of its own: p50 0.004 to 0.013 ms with one worker and 0.10 to
  0.15 ms with eight, most of which is time to safepoint. The worst final
  mark in `cm` runs was 0.95 ms (`oldheap512`, 8 workers, a large SATB
  drain), 1.13 ms with marking forced on; in the app 0.19 ms. The
  stop-the-world full collections they replace took 33 to 41 ms at 256 MiB
  live and 66 to 81 ms at 512 MiB.
- **Scaling with old space: flat.** From 64 to 512 MiB live the initial-mark
  part grows from 0.024 to 0.035 ms p50 with one worker (snapshot copy max
  0.024 to 0.103 ms with one marker, 0.144 ms with two), the final mark stays
  at 0.010 to 0.013 ms p50 with one worker and 0.10 to 0.13 ms with eight,
  and the apply step (publishing the sweep) at the next pause grows from
  0.010 to 0.047 ms. What grows with the heap is concurrent: marking takes
  8, 34 and 70 ms of marker CPU with one worker, and 21, 81 and 161 ms of
  wall time with eight.
- **Barrier cost with marking off:** within noise on `arith`, `fib`,
  `sends` and the allocation kernels; 4.5 and 3.2 percent on `ivars` (O
  build, 1 and 8 workers) but 0.5 and -1.5 percent in the alignment-controlled
  build. The fast path is `ldrb` + `cbz`. A first version cost 20 percent on
  `ivars` in both builds through register pressure, fixed (section 3).
- **Mutator slowdown with marking on continuously** (`force`/`stw`): -2 to
  6 percent on the allocation kernels, 9 to 12 percent on `oldheap` with 8
  workers, 19 to 24 percent on `oldheap` with one worker (the marker then
  runs back to back beside it and every rewire takes the slow path) and 14
  percent on `ivars` (every store is a slow-path call). In normal `cm` runs
  marking is on 1 to 3 percent of the time on `oldheap` with one worker and
  15 to 58 percent with eight, and wall times are 0.97 to 1.05 of `stw`'s.
- **Can one marker keep up with eight workers: yes for `oldheap` (600 to
  710 MB/s promoted), `survivors30` (620 MB/s) and everything else, no for
  `alloc`'s storm (1.5 GB/s promoted into a 64 MiB old space).** There `cm`
  fell back to stop-the-world 63 times in 5 runs (13 per run, pauses up to
  13.3 ms), and the app scenarios C2 and C5 87 and 114 times in 10 s. The
  marker is not the bottleneck by throughput (6.5 ms of CPU per cycle) but
  by timing: a cycle has about one scavenge interval (11 to 15 ms) of
  headroom, and the marker at QoS utility, on the efficiency cores, together
  with the sweep, often does not finish within it. A user-initiated marker
  halves the fallbacks (34); a 256 MiB old space cuts them to 5; both
  together to 0 in 5 runs. The trigger threshold (20 to 60 percent) changed
  nothing. **Fallbacks elsewhere: 0** in every kernel and configuration
  except `alloc` with 8 workers (also 62 in `force`), and in C4 and C6.
- **Headroom:** objects promoted during marking are black and survive the
  cycle. On `oldheap512` with 8 workers that was 61 MB p50 and 258 MB max
  per cycle, on top of 657 MB in use at the trigger (soft limit 1088 MB), and
  only the next cycle frees it. Floating garbage measured by the verifier:
  up to 2.4 MB per cycle at 256 MiB live (C4), up to 21 MB in the
  allocation storm (C2).
- **120 Hz:** under a 256 MiB slowly mutating old heap, **yes**: C4 missed
  2 frames (runs: 2, 0, 3) and C6 0 (0, 1, 0), against C3's 6 (7, 5, 6)
  with stop-the-world, whose single 40 ms full collection per run drops 4 or
  5 frames by itself. No main-thread stall in C4 or C6 contains GC waiting.
  Under the allocation storm, **no, and worse than stop-the-world**: C2
  missed 7 (8, 7, 5) and C5 18 (18, 14, 22) against C1's 3 (3, 3, 2),
  because the fallbacks are longer pauses (7.9 ms p50, 11.3 ms max) than
  ADR 0005's full collections (6.4 ms p50, 8.9 ms max). With the marker at
  QoS user-initiated (supplementary, 3 runs) C2 fell back 3 to 11 times and
  missed 0, 2 and 0 frames.

## 1. Headless matrix

| kernel | workers | config | wall ms | vs stw | peak RSS MB | scavenge p50 / p99 / max | full collections | full p50 / max | cycles | fallbacks (all runs) | checksum |
|---|--:|---|--:|--:|--:|---|--:|---|--:|--:|---|
| arith | 1 | nomark | 2766.4 | 1.01 | 18 | - / - / - | 0 | - | - | - | 372800000 |
| arith | 1 | stw | 2739.6 | 1.00 | 18 | - / - / - | 0 | - | - | - | 372800000 |
| arith | 1 | cm | 2743.9 | 1.00 | 18 | - / - / - | 0 | - | 0 | 0 | 372800000 |
| arith | 1 | force | 2732.6 | 1.00 | 18 | - / - / - | 0 | - | 0 | 0 | 372800000 |
| arith | 8 | nomark | 368.6 | 1.01 | 19 | - / - / - | 0 | - | - | - | 372800000 |
| arith | 8 | stw | 365.7 | 1.00 | 19 | - / - / - | 0 | - | - | - | 372800000 |
| arith | 8 | cm | 370.2 | 1.01 | 19 | - / - / - | 0 | - | 0 | 0 | 372800000 |
| arith | 8 | force | 365.3 | 1.00 | 19 | - / - / - | 0 | - | 0 | 0 | 372800000 |
| fib | 1 | nomark | 1588.3 | 1.00 | 18 | - / - / - | 0 | - | - | - | 24682992 |
| fib | 1 | stw | 1583.6 | 1.00 | 18 | - / - / - | 0 | - | - | - | 24682992 |
| fib | 1 | cm | 1586.2 | 1.00 | 18 | - / - / - | 0 | - | 0 | 0 | 24682992 |
| fib | 1 | force | 1583.6 | 1.00 | 18 | - / - / - | 0 | - | 0 | 0 | 24682992 |
| fib | 8 | nomark | 205.8 | 0.97 | 19 | - / - / - | 0 | - | - | - | 24682992 |
| fib | 8 | stw | 212.8 | 1.00 | 19 | - / - / - | 0 | - | - | - | 24682992 |
| fib | 8 | cm | 206.5 | 0.97 | 19 | - / - / - | 0 | - | 0 | 0 | 24682992 |
| fib | 8 | force | 205.8 | 0.97 | 19 | - / - / - | 0 | - | 0 | 0 | 24682992 |
| sends | 1 | nomark | 2294.5 | 1.00 | 18 | - / - / - | 0 | - | - | - | 1066666666666668 |
| sends | 1 | stw | 2298.2 | 1.00 | 18 | - / - / - | 0 | - | - | - | 1066666666666668 |
| sends | 1 | cm | 2297.1 | 1.00 | 18 | - / - / - | 0 | - | 0 | 0 | 1066666666666668 |
| sends | 1 | force | 2307.2 | 1.00 | 18 | - / - / - | 0 | - | 0 | 0 | 1066666666666668 |
| sends | 8 | nomark | 303.6 | 0.98 | 19 | - / - / - | 0 | - | - | - | 133333335000001 |
| sends | 8 | stw | 311.1 | 1.00 | 19 | - / - / - | 0 | - | - | - | 133333335000001 |
| sends | 8 | cm | 307.0 | 0.99 | 19 | - / - / - | 0 | - | 0 | 0 | 133333335000001 |
| sends | 8 | force | 310.6 | 1.00 | 19 | - / - / - | 0 | - | 0 | 0 | 133333335000001 |
| ivars | 1 | nomark | 1880.5 | 0.96 | 18 | - / - / - | 0 | - | - | - | 36383626 |
| ivars | 1 | stw | 1964.5 | 1.00 | 18 | - / - / - | 0 | - | - | - | 36383626 |
| ivars | 1 | cm | 1965.9 | 1.00 | 18 | - / - / - | 0 | - | 0 | 0 | 36383626 |
| ivars | 1 | force | 2241.6 | 1.14 | 18 | - / - / - | 0 | - | 0 | 0 | 36383626 |
| ivars | 8 | nomark | 248.0 | 0.97 | 19 | - / - / - | 0 | - | - | - | 71714128 |
| ivars | 8 | stw | 256.0 | 1.00 | 19 | - / - / - | 0 | - | - | - | 71714128 |
| ivars | 8 | cm | 263.6 | 1.03 | 19 | - / - / - | 0 | - | 0 | 0 | 71714128 |
| ivars | 8 | force | 290.7 | 1.14 | 19 | - / - / - | 0 | - | 0 | 0 | 71714128 |
| alloc | 1 | nomark | 2156.1 | 1.00 | 130 | 1.502 / 1.781 / 2.024 | 11 | 3.53 / 4.07 | - | - | 41950911 |
| alloc | 1 | stw | 2165.8 | 1.00 | 131 | 1.491 / 1.824 / 1.956 | 11 | 3.53 / 4.34 | - | - | 41950911 |
| alloc | 1 | cm | 2134.4 | 0.99 | 99 | 1.490 / 1.777 / 1.874 | 0 | - | 19 | 0 | 41950911 |
| alloc | 1 | cm2 | 2136.9 | 0.99 | 99 | 1.491 / 1.774 / 1.874 | 0 | - | 19 | 0 | 41950911 |
| alloc | 1 | force | 2274.3 | 1.05 | 37 | 1.498 / 1.667 / 1.840 | 0 | - | 240 | 0 | 41950911 |
| alloc | 8 | nomark | 493.4 | 1.05 | 172 | 3.150 / 4.623 / 5.321 | 23 | 6.82 / 8.59 | - | - | 42008248 |
| alloc | 8 | stw | 469.7 | 1.00 | 174 | 3.081 / 4.649 / 4.855 | 20 | 7.51 / 8.72 | - | - | 42008248 |
| alloc | 8 | cm | 457.0 | 0.97 | 215 | 3.006 / 4.995 / 13.964 | 13 | 7.69 / 13.31 | 13 | 63 | 42008248 |
| alloc | 8 | cm2 | 442.3 | 0.94 | 208 | 2.974 / 4.602 / 4.608 | 12 | 7.59 / 11.90 | 14 | 63 | 42008248 |
| alloc | 8 | force | 460.5 | 0.98 | 211 | 3.136 / 6.654 / 8.033 | 13 | 7.92 / 12.25 | 15 | 62 | 42008248 |
| churn | 1 | nomark | 1491.6 | 0.99 | 25 | 0.005 / 0.013 / 0.043 | 0 | - | - | - | 256000032000000 |
| churn | 1 | stw | 1513.7 | 1.00 | 25 | 0.005 / 0.013 / 0.030 | 0 | - | - | - | 256000032000000 |
| churn | 1 | cm | 1516.0 | 1.00 | 25 | 0.005 / 0.012 / 0.033 | 0 | - | 0 | 0 | 256000032000000 |
| churn | 1 | force | 1591.7 | 1.05 | 26 | 0.015 / 0.023 / 0.057 | 0 | - | 183 | 0 | 256000032000000 |
| churn | 8 | nomark | 208.3 | 1.00 | 73 | 0.213 / 0.342 / 0.389 | 0 | - | - | - | 32000032000000 |
| churn | 8 | stw | 207.6 | 1.00 | 73 | 0.206 / 0.330 / 0.335 | 0 | - | - | - | 32000032000000 |
| churn | 8 | cm | 207.7 | 1.00 | 73 | 0.208 / 0.293 / 0.346 | 0 | - | 0 | 0 | 32000032000000 |
| churn | 8 | force | 220.7 | 1.06 | 75 | 0.241 / 0.365 / 0.434 | 0 | - | 23 | 0 | 32000032000000 |
| survivors5 | 1 | nomark | 1130.2 | 0.98 | 63 | 0.152 / 0.337 / 0.443 | 0 | - | - | - | 6399993600000 |
| survivors5 | 1 | stw | 1149.7 | 1.00 | 63 | 0.156 / 0.349 / 0.496 | 0 | - | - | - | 6399993600000 |
| survivors5 | 1 | cm | 1150.7 | 1.00 | 63 | 0.160 / 0.314 / 0.512 | 0 | - | 0 | 0 | 6399993600000 |
| survivors5 | 1 | force | 1213.6 | 1.06 | 30 | 0.135 / 0.341 / 0.390 | 0 | - | 93 | 0 | 6399993600000 |
| survivors5 | 8 | nomark | 164.6 | 0.99 | 110 | 0.695 / 1.122 / 1.143 | 0 | - | - | - | 799993600000 |
| survivors5 | 8 | stw | 166.8 | 1.00 | 110 | 0.689 / 1.177 / 2.542 | 0 | - | - | - | 799993600000 |
| survivors5 | 8 | cm | 161.4 | 0.97 | 110 | 0.689 / 1.355 / 1.470 | 0 | - | 0 | 0 | 799993600000 |
| survivors5 | 8 | force | 170.0 | 1.02 | 104 | 0.646 / 1.194 / 1.244 | 0 | - | 10 | 0 | 799993600000 |
| survivors30 | 1 | nomark | 1545.7 | 0.98 | 122 | 0.523 / 0.883 / 1.188 | 2 | 2.46 / 2.59 | - | - | 38399861600000 |
| survivors30 | 1 | stw | 1573.8 | 1.00 | 122 | 0.517 / 0.930 / 1.360 | 2 | 2.46 / 2.87 | - | - | 38399861600000 |
| survivors30 | 1 | cm | 1561.4 | 0.99 | 87 | 0.488 / 0.885 / 1.064 | 0 | - | 3 | 0 | 38399861600000 |
| survivors30 | 1 | force | 1658.0 | 1.05 | 32 | 0.433 / 0.735 / 0.943 | 0 | - | 101 | 0 | 38399861600000 |
| survivors30 | 8 | nomark | 227.7 | 0.99 | 156 | 1.709 / 2.209 / 2.473 | 2 | 4.97 / 6.03 | - | - | 4799861600000 |
| survivors30 | 8 | stw | 229.7 | 1.00 | 156 | 1.721 / 2.175 / 2.241 | 2 | 4.85 / 5.37 | - | - | 4799861600000 |
| survivors30 | 8 | cm | 232.2 | 1.01 | 156 | 1.612 / 2.337 / 2.378 | 0 | - | 4 | 0 | 4799861600000 |
| survivors30 | 8 | force | 234.9 | 1.02 | 128 | 1.629 / 2.162 / 2.294 | 0 | - | 12 | 0 | 4799861600000 |
| oldheap64 | 1 | nomark | 1760.1 | 0.99 | 235 | 0.210 / 0.817 / 0.842 | 0 | - | - | - | 134190197274785 |
| oldheap64 | 1 | stw | 1772.1 | 1.00 | 235 | 0.207 / 0.804 / 0.826 | 0 | - | - | - | 134190197274785 |
| oldheap64 | 1 | cm | 1779.9 | 1.00 | 157 | 0.173 / 0.821 / 0.905 | 0 | - | 2 | 0 | 134190197274785 |
| oldheap64 | 1 | cm2 | 1796.4 | 1.01 | 157 | 0.183 / 0.806 / 0.858 | 0 | - | 2 | 0 | 134190197274785 |
| oldheap64 | 1 | force | 2113.7 | 1.19 | 101 | 0.181 / 0.867 / 1.016 | 0 | - | 133 | 0 | 134190197274785 |
| oldheap64 | 8 | nomark | 252.4 | 0.95 | 276 | 0.872 / 2.713 / 2.716 | 1 | 8.74 / 11.06 | - | - | 18609257457078 |
| oldheap64 | 8 | stw | 265.2 | 1.00 | 275 | 0.862 / 2.718 / 3.144 | 0 | 5.45 / 11.20 | - | - | 18609257457078 |
| oldheap64 | 8 | cm | 257.9 | 0.97 | 219 | 0.817 / 2.976 / 3.036 | 0 | - | 2 | 0 | 18609257457078 |
| oldheap64 | 8 | cm2 | 256.4 | 0.97 | 217 | 0.770 / 2.808 / 2.810 | 0 | - | 2 | 0 | 18609257457078 |
| oldheap64 | 8 | force | 288.8 | 1.09 | 209 | 0.809 / 2.862 / 2.996 | 0 | - | 6 | 0 | 18609257457078 |
| oldheap256 | 1 | nomark | 8003.9 | 0.99 | 675 | 0.210 / 0.841 / 1.054 | 1 | 32.88 / 36.42 | - | - | 2147037951443421 |
| oldheap256 | 1 | stw | 8057.0 | 1.00 | 676 | 0.209 / 0.805 / 0.886 | 1 | 33.26 / 33.43 | - | - | 2147037951443421 |
| oldheap256 | 1 | cm | 8034.7 | 1.00 | 423 | 0.163 / 0.814 / 0.988 | 0 | - | 5 | 0 | 2147037951443421 |
| oldheap256 | 1 | cm2 | 8063.0 | 1.00 | 422 | 0.164 / 0.828 / 1.018 | 0 | - | 5 | 0 | 2147037951443421 |
| oldheap256 | 1 | force | 9934.4 | 1.23 | 328 | 0.205 / 0.866 / 1.084 | 0 | - | 258 | 0 | 2147037951443421 |
| oldheap256 | 8 | nomark | 1102.5 | 0.98 | 714 | 0.854 / 2.801 / 3.018 | 1 | 40.54 / 41.82 | - | - | 275722747647157 |
| oldheap256 | 8 | stw | 1122.5 | 1.00 | 717 | 0.839 / 2.864 / 3.047 | 1 | 40.71 / 41.41 | - | - | 275722747647157 |
| oldheap256 | 8 | cm | 1133.4 | 1.01 | 523 | 0.571 / 2.703 / 2.857 | 0 | - | 5 | 0 | 275722747647157 |
| oldheap256 | 8 | cm2 | 1134.6 | 1.01 | 514 | 0.589 / 2.749 / 3.138 | 0 | - | 5 | 0 | 275722747647157 |
| oldheap256 | 8 | force | 1245.8 | 1.11 | 606 | 0.625 / 2.835 / 3.231 | 0 | - | 11 | 0 | 275722747647157 |
| oldheap512 | 1 | nomark | 16860.9 | 0.99 | 1255 | 0.209 / 0.814 / 0.959 | 1 | 66.11 / 67.63 | - | - | 8588142608127853 |
| oldheap512 | 1 | stw | 17074.3 | 1.00 | 1256 | 0.208 / 0.811 / 0.998 | 1 | 66.26 / 67.10 | - | - | 8588142608127853 |
| oldheap512 | 1 | cm | 17035.6 | 1.00 | 776 | 0.164 / 0.805 / 1.016 | 0 | - | 7 | 0 | 8588142608127853 |
| oldheap512 | 1 | cm2 | 17096.1 | 1.00 | 774 | 0.165 / 0.815 / 1.094 | 0 | - | 7 | 0 | 8588142608127853 |
| oldheap512 | 1 | force | 21128.4 | 1.24 | 625 | 0.200 / 0.876 / 1.151 | 0 | - | 268 | 0 | 8588142608127853 |
| oldheap512 | 8 | nomark | 2342.5 | 0.99 | 1293 | 0.862 / 2.894 / 4.343 | 1 | 79.24 / 79.71 | - | - | 1088201686370797 |
| oldheap512 | 8 | stw | 2374.1 | 1.00 | 1291 | 0.865 / 2.799 / 3.009 | 1 | 80.44 / 81.05 | - | - | 1088201686370797 |
| oldheap512 | 8 | cm | 2488.1 | 1.05 | 1106 | 0.619 / 2.776 / 10.804 | 0 | - | 6 | 0 | 1088201686370797 |
| oldheap512 | 8 | cm2 | 2438.0 | 1.03 | 934 | 0.611 / 2.837 / 4.104 | 0 | - | 6 | 0 | 1088201686370797 |
| oldheap512 | 8 | force | 2647.4 | 1.12 | 1048 | 0.611 / 2.790 / 2.915 | 0 | - | 12 | 0 | 1088201686370797 |

`vs stw` is the median wall time over `stw`'s. Checksums agree across every
configuration and build. The compute kernels never collect; `churn` and
`survivors5` never reach the 60 percent threshold in `cm` (they start
cycles only in `force`). Two scavenge pauses of 10.8 and 14.0 ms in `cm`
(`oldheap512` and `alloc`, 8 workers) are coordination: 0.6 and 3.9 ms of
copying, the rest between participants, the same rare descheduling ADR
0005's experiment saw.

| kernel | workers | config | cycles (all runs) | initial p50 / p99 / max | of which mark p50 / max | final p50 / p99 / max | final ttsp p50 | final drain max | marking p50 / max | marker CPU p50 | SATB entries / cycle p50 | fallbacks |
|---|--:|---|--:|---|---|---|--:|--:|---|--:|--:|--:|
| arith | 1 | cm | 0 | | | | | | | | | 0 |
| arith | 1 | force | 0 | | | | | | | | | 0 |
| arith | 8 | cm | 0 | | | | | | | | | 0 |
| arith | 8 | force | 0 | | | | | | | | | 0 |
| fib | 1 | cm | 0 | | | | | | | | | 0 |
| fib | 1 | force | 0 | | | | | | | | | 0 |
| fib | 8 | cm | 0 | | | | | | | | | 0 |
| fib | 8 | force | 0 | | | | | | | | | 0 |
| sends | 1 | cm | 0 | | | | | | | | | 0 |
| sends | 1 | force | 0 | | | | | | | | | 0 |
| sends | 8 | cm | 0 | | | | | | | | | 0 |
| sends | 8 | force | 0 | | | | | | | | | 0 |
| ivars | 1 | cm | 0 | | | | | | | | | 0 |
| ivars | 1 | force | 0 | | | | | | | | | 0 |
| ivars | 8 | cm | 0 | | | | | | | | | 0 |
| ivars | 8 | force | 0 | | | | | | | | | 0 |
| alloc | 1 | cm | 95 | 1.520 / 1.782 / 1.814 | 0.015 / 0.056 | 0.007 / 0.017 / 0.021 | 0.006 | 0.001 | 0.6 / 1.4 | 0.6 | 0 | 0 |
| alloc | 1 | cm2 | 95 | 1.526 / 1.812 / 1.845 | 0.015 / 0.049 | 0.008 / 0.017 / 0.017 | 0.007 | 0.001 | 0.6 / 0.6 | 0.6 | 0 | 0 |
| alloc | 1 | force | 1200 | 1.498 / 1.667 / 1.840 | 0.005 / 0.030 | 0.006 / 0.013 / 0.022 | 0.005 | 0.004 | 0.4 / 0.7 | 0.4 | 0 | 0 |
| alloc | 8 | cm | 64 | 3.121 / 4.531 / 4.880 | 0.031 / 0.121 | 0.108 / 0.173 / 0.173 | 0.102 | 0.001 | 7.5 / 13.0 | 6.5 | 0 | 63 |
| alloc | 8 | cm2 | 67 | 3.199 / 4.409 / 4.423 | 0.035 / 0.121 | 0.112 / 0.155 / 0.158 | 0.103 | 0.001 | 5.9 / 12.3 | 8.4 | 0 | 63 |
| alloc | 8 | force | 76 | 3.091 / 4.304 / 6.654 | 0.034 / 0.094 | 0.108 / 0.144 / 0.150 | 0.106 | 0.001 | 4.0 / 16.7 | 3.7 | 0 | 62 |
| churn | 1 | cm | 0 | | | | | | | | | 0 |
| churn | 1 | force | 915 | 0.015 / 0.023 / 0.057 | 0.004 / 0.024 | 0.004 / 0.013 / 0.017 | 0.004 | 0.001 | 0.0 / 0.1 | 0.0 | 0 | 0 |
| churn | 8 | cm | 0 | | | | | | | | | 0 |
| churn | 8 | force | 115 | 0.241 / 0.365 / 0.434 | 0.023 / 0.039 | 0.117 / 0.181 / 0.183 | 0.115 | 0.025 | 0.2 / 4.8 | 0.0 | 0 | 0 |
| survivors5 | 1 | cm | 0 | | | | | | | | | 0 |
| survivors5 | 1 | force | 465 | 0.135 / 0.341 / 0.390 | 0.005 / 0.018 | 0.006 / 0.013 / 0.018 | 0.006 | 0.004 | 0.2 / 0.7 | 0.2 | 0 | 0 |
| survivors5 | 8 | cm | 0 | | | | | | | | | 0 |
| survivors5 | 8 | force | 49 | 0.632 / 1.244 / 1.244 | 0.019 / 0.052 | 0.113 / 0.179 / 0.179 | 0.100 | 0.007 | 5.3 / 25.3 | 4.8 | 0 | 0 |
| survivors30 | 1 | cm | 15 | 0.587 / 1.036 / 1.036 | 0.011 / 0.049 | 0.008 / 0.013 / 0.013 | 0.007 | 0.000 | 0.3 / 0.3 | 0.2 | 0 | 0 |
| survivors30 | 1 | force | 505 | 0.433 / 0.735 / 0.943 | 0.005 / 0.016 | 0.006 / 0.011 / 0.021 | 0.005 | 0.005 | 0.2 / 0.6 | 0.2 | 0 | 0 |
| survivors30 | 8 | cm | 20 | 1.536 / 2.102 / 2.102 | 0.023 / 0.090 | 0.118 / 0.143 / 0.143 | 0.107 | 0.002 | 8.6 / 20.2 | 8.1 | 0 | 0 |
| survivors30 | 8 | force | 61 | 1.629 / 2.162 / 2.294 | 0.020 / 0.088 | 0.119 / 0.175 / 0.195 | 0.105 | 0.006 | 6.1 / 10.5 | 5.8 | 0 | 0 |
| oldheap64 | 1 | cm | 10 | 0.191 / 0.275 / 0.275 | 0.024 / 0.040 | 0.010 / 0.017 / 0.017 | 0.009 | 0.001 | 8.4 / 8.6 | 8.3 | 4224 | 0 |
| oldheap64 | 1 | cm2 | 10 | 0.198 / 0.317 / 0.317 | 0.029 / 0.054 | 0.006 / 0.009 / 0.009 | 0.004 | 0.002 | 5.9 / 8.4 | 10.9 | 2684 | 0 |
| oldheap64 | 1 | force | 664 | 0.180 / 0.833 / 1.014 | 0.006 / 0.062 | 0.010 / 0.024 / 0.036 | 0.008 | 0.016 | 7.9 / 10.0 | 7.8 | 4004 | 0 |
| oldheap64 | 8 | cm | 10 | 0.593 / 1.037 / 1.037 | 0.037 / 0.092 | 0.104 / 0.162 / 0.162 | 0.095 | 0.067 | 20.6 / 69.6 | 18.7 | 69933 | 0 |
| oldheap64 | 8 | cm2 | 10 | 0.563 / 0.946 / 0.946 | 0.030 / 0.106 | 0.133 / 0.157 / 0.157 | 0.114 | 0.024 | 17.0 / 18.9 | 31.1 | 54142 | 0 |
| oldheap64 | 8 | force | 33 | 0.564 / 2.862 / 2.862 | 0.024 / 0.051 | 0.127 / 0.284 / 0.284 | 0.104 | 0.179 | 19.5 / 115.0 | 18.1 | 67708 | 0 |
| oldheap256 | 1 | cm | 25 | 0.193 / 0.305 / 0.305 | 0.021 / 0.090 | 0.013 / 0.032 / 0.032 | 0.010 | 0.018 | 34.3 / 37.6 | 34.0 | 14519 | 0 |
| oldheap256 | 1 | cm2 | 25 | 0.196 / 0.272 / 0.272 | 0.023 / 0.065 | 0.008 / 0.042 / 0.042 | 0.005 | 0.037 | 23.4 / 27.0 | 43.0 | 8938 | 0 |
| oldheap256 | 1 | force | 1290 | 0.211 / 0.866 / 1.075 | 0.014 / 0.044 | 0.011 / 0.039 / 0.055 | 0.009 | 0.040 | 34.1 / 49.5 | 33.8 | 14445 | 0 |
| oldheap256 | 8 | cm | 24 | 0.571 / 1.066 / 1.066 | 0.036 / 0.112 | 0.131 / 0.591 / 0.591 | 0.108 | 0.585 | 80.7 / 340.2 | 72.2 | 250458 | 0 |
| oldheap256 | 8 | cm2 | 25 | 0.560 / 1.232 / 1.232 | 0.037 / 0.106 | 0.117 / 0.507 / 0.507 | 0.098 | 0.379 | 68.9 / 201.6 | 126.3 | 205745 | 0 |
| oldheap256 | 8 | force | 52 | 0.589 / 2.793 / 2.862 | 0.035 / 0.090 | 0.131 / 1.127 / 1.135 | 0.108 | 1.044 | 78.9 / 407.6 | 72.8 | 251944 | 0 |
| oldheap512 | 1 | cm | 35 | 0.214 / 0.362 / 0.362 | 0.035 / 0.104 | 0.010 / 0.024 / 0.024 | 0.007 | 0.019 | 71.1 / 76.1 | 70.4 | 27374 | 0 |
| oldheap512 | 1 | cm2 | 35 | 0.208 / 0.350 / 0.350 | 0.033 / 0.125 | 0.009 / 0.046 / 0.046 | 0.005 | 0.037 | 42.6 / 49.4 | 81.4 | 15188 | 0 |
| oldheap512 | 1 | force | 1339 | 0.236 / 0.878 / 0.938 | 0.023 / 0.053 | 0.010 / 0.039 / 0.067 | 0.008 | 0.048 | 70.1 / 88.5 | 69.5 | 27528 | 0 |
| oldheap512 | 8 | cm | 30 | 0.596 / 1.036 / 1.036 | 0.049 / 0.162 | 0.131 / 0.954 / 0.954 | 0.113 | 0.838 | 161.3 / 679.3 | 146.9 | 456251 | 0 |
| oldheap512 | 8 | cm2 | 30 | 0.580 / 1.110 / 1.110 | 0.049 / 0.178 | 0.146 / 0.328 / 0.328 | 0.117 | 0.181 | 141.0 / 372.1 | 252.1 | 370826 | 0 |
| oldheap512 | 8 | force | 64 | 0.637 / 2.859 / 2.915 | 0.048 / 0.077 | 0.135 / 0.801 / 0.802 | 0.109 | 0.721 | 162.3 / 692.6 | 148.6 | 468027 | 0 |

`cycles` counts every cycle started, including aborted ones. The initial
pause is the whole pause (its scavenge included); `of which mark` is the
snapshot copy plus root scan. `final` excludes the verifier, which is off
here. `force` keeps the marking flag set between cycles.

## 2. Scenarios

Median run of 3 (by missed frames, then max gap); pauses of the median run, ms.

| id | gc | frames | missed | gap max | worst run-loop iter (VM, GC park, GC enter/leave wait) | scavenges | scav p50 / p99 / max | full / fallback | full max | cycles | initial p50 / max | final p50 / max | marking ms p50 | per-run missed |
|---|---|--:|--:|--:|---|--:|---|---|--:|--:|---|---|--:|---|
| C0 | cm | 1200 | 0 | 8.333 | 0.847 (0.000, 0.000, 0.000) | 0 | - / - / - | 0 / 0 | - | 0 | 0.000 / 0.000 | 0.000 / 0.000 | 0.000 | 0, 0, 0 |
| C1 | stw | 1197 | 3 | 19.130 | 13.890 (6.451, 0.000, 6.012) | 711 | 2.677 / 3.681 / 9.304 | 405 / 0 | 8.925 | - | - / - | - / - | - | 3, 3, 2 |
| C2 | cm | 1192 | 7 | 17.664 | 12.326 (8.457, 0.000, 8.267) | 878 | 2.759 / 3.758 / 5.729 | 0 / 87 | 11.298 | 546 | 2.873 / 5.729 | 0.083 / 0.174 | 3.973 | 8, 7, 5 |
| C3 | stw | 1194 | 6 | 43.417 | 39.710 (39.348, 0.000, 39.182) | 536 | 0.262 / 0.381 / 0.450 | 1 / 0 | 39.997 | - | - / - | - / - | - | 7, 5, 6 |
| C4 | cm | 1198 | 2 | 19.206 | 19.068 (1.019, 0.000, 0.000) | 526 | 0.230 / 0.335 / 0.445 | 0 / 0 | - | 6 | 0.297 / 0.445 | 0.101 / 0.116 | 44.842 | 2, 0, 3 |
| C5 | cm | 1181 | 18 | 22.211 | 16.548 (10.075, 6.010, 3.020) | 826 | 2.796 / 3.645 / 3.888 | 0 / 114 | 11.672 | 496 | 2.973 / 3.869 | 0.086 / 0.166 | 4.464 | 18, 14, 22 |
| C6 | cm | 1200 | 0 | 8.333 | 12.551 (0.679, 0.000, 0.000) | 535 | 0.236 / 0.362 / 0.398 | 0 / 0 | - | 7 | 0.305 / 0.371 | 0.113 / 0.121 | 51.131 | 0, 1, 0 |

Pauses pooled over all three runs, ms:

| id | scavenges | scav p50 / p99 / max | initial (incl. scavenge) p50 / p99 / max | final p50 / p99 / max | stw full p50 / max | fallback p50 / max | ttsp p99 / max | pauses > 4 ms | world stopped % (per run) |
|---|--:|---|---|---|---|---|---|--:|---|
| C0 | 0 | - / - / - | - / - / - | - / - / - | - | - | - / - | 0 |  |
| C1 | 2137 | 2.695 / 3.643 / 9.304 | - / - / - | - / - / - | 6.38 / 8.92 | - | 0.118 / 0.167 | 1216 | 44.9, 44.8, 44.5 |
| C2 | 2622 | 2.411 / 3.758 / 4.507 | 2.920 / 3.723 / 10.728 | 0.083 / 0.141 / 0.174 | - | 7.85 / 11.30 | 0.140 / 0.201 | 280 | 31.0, 31.1, 31.6 |
| C3 | 1601 | 0.257 / 0.395 / 0.615 | - / - / - | - / - / - | 41.61 / 41.83 | - | 0.127 / 0.156 | 3 | 1.8, 1.8, 1.8 |
| C4 | 1601 | 0.233 / 0.365 / 1.460 | 0.295 / 0.530 / 0.530 | 0.106 / 0.162 / 0.162 | - | - | 0.125 / 0.146 | 0 | 1.2, 1.3, 1.3 |
| C5 | 2483 | 2.417 / 3.563 / 6.390 | 2.897 / 3.744 / 5.718 | 0.086 / 0.150 / 0.188 | - | 8.17 / 11.67 | 0.145 / 0.198 | 383 | 32.1, 33.0, 32.7 |
| C6 | 1594 | 0.236 / 0.383 / 1.044 | 0.301 / 0.415 / 0.415 | 0.113 / 0.150 / 0.150 | - | - | 0.137 / 0.182 | 0 | 1.3, 1.3, 1.3 |

Scenario extras (median runs):

- **C0**: build_wait_s=0.00, turns=1207, vm_main_ms=1.64, max_turn_ms=0.019, max_turn_kind=tick, max_turn_gcpark_ms=0.000, max_turn_gcenter_ms=0.000, main_enter_waits=0, main_enter_wait_max_ms=0.000, churn100us=2679, markers=1, marker_qos=utility, mark_cpu_ms_total=0.000, sweep_cpu_ms_total=0.000, marked_mb_p50=0.000, promoted_during_mb_max=0.000, old_start_mb_p50=0.0, old_after_mb_p50=0.0, satb_entries=0, old_mb=0.063, rss_mb=103.48
- **C1**: build_wait_s=0.00, turns=7876, vm_main_ms=4185.16, max_turn_ms=9.141, max_turn_kind=event, max_turn_gcpark_ms=0.000, max_turn_gcenter_ms=8.953, ev_lat_p50_ms=1.204, ev_lat_p99_ms=8.916, ev_lat_max_ms=12.512, main_enter_waits=1010, main_enter_wait_max_ms=8.953, churn100us=2681, promoted_mb=14710.994, survival_pct=83.32, markers=1, marker_qos=utility, old_mb=39.969, rss_mb=272.94
- **C2**: build_wait_s=0.00, turns=8510, vm_main_ms=2986.64, max_turn_ms=11.393, max_turn_kind=event, max_turn_gcpark_ms=0.000, max_turn_gcenter_ms=11.313, ev_lat_p50_ms=0.600, ev_lat_p99_ms=8.415, ev_lat_max_ms=11.615, main_enter_waits=924, main_enter_wait_max_ms=11.313, churn100us=2558, promoted_mb=18296.027, survival_pct=83.75, markers=1, marker_qos=utility, mark_cpu_ms_total=1736.037, sweep_cpu_ms_total=1216.781, marked_mb_p50=17.372, promoted_during_mb_max=19.848, old_start_mb_p50=43.4, old_after_mb_p50=18.3, satb_entries=0, old_mb=63.250, rss_mb=285.59
- **C3**: build_wait_s=0.10, turns=9442, vm_main_ms=646.67, max_turn_ms=39.348, max_turn_kind=event, max_turn_gcpark_ms=0.000, max_turn_gcenter_ms=39.182, ev_lat_p50_ms=0.090, ev_lat_p99_ms=3.779, ev_lat_max_ms=41.106, main_enter_waits=142, main_enter_wait_max_ms=39.182, churn100us=2630, promoted_mb=573.099, survival_pct=3.94, markers=1, marker_qos=utility, old_mb=570.781, rss_mb=797.36
- **C4**: build_wait_s=0.10, turns=8541, vm_main_ms=600.06, max_turn_ms=1.019, max_turn_kind=event, max_turn_gcpark_ms=0.000, max_turn_gcenter_ms=0.000, ev_lat_p50_ms=0.099, ev_lat_p99_ms=4.359, ev_lat_max_ms=17.406, main_enter_waits=100, main_enter_wait_max_ms=0.278, churn100us=2636, promoted_mb=562.251, survival_pct=3.94, markers=1, marker_qos=utility, mark_cpu_ms_total=284.893, sweep_cpu_ms_total=28.010, marked_mb_p50=256.082, promoted_during_mb_max=3.157, old_start_mb_p50=346.6, old_after_mb_p50=260.1, satb_entries=939939, old_mb=344.500, rss_mb=550.16
- **C5**: build_wait_s=0.00, turns=8445, vm_main_ms=4323.55, max_turn_ms=11.219, max_turn_kind=tick, max_turn_gcpark_ms=0.000, max_turn_gcenter_ms=11.219, ev_lat_p50_ms=0.788, ev_lat_p99_ms=9.051, ev_lat_max_ms=15.666, main_enter_waits=795, main_enter_wait_max_ms=11.219, churn100us=2517, promoted_mb=17199.017, survival_pct=82.26, markers=1, marker_qos=utility, mark_cpu_ms_total=1637.507, sweep_cpu_ms_total=1085.624, marked_mb_p50=17.115, promoted_during_mb_max=20.973, old_start_mb_p50=42.8, old_after_mb_p50=18.0, satb_entries=0, old_mb=56.250, rss_mb=287.06
- **C6**: build_wait_s=0.10, turns=9761, vm_main_ms=607.93, max_turn_ms=0.679, max_turn_kind=event, max_turn_gcpark_ms=0.000, max_turn_gcenter_ms=0.000, ev_lat_p50_ms=0.090, ev_lat_p99_ms=3.861, ev_lat_max_ms=11.602, main_enter_waits=122, main_enter_wait_max_ms=0.371, churn100us=2578, promoted_mb=571.911, survival_pct=3.94, markers=2, marker_qos=utility, mark_cpu_ms_total=681.304, sweep_cpu_ms_total=27.590, marked_mb_p50=256.082, promoted_during_mb_max=2.188, old_start_mb_p50=346.3, old_after_mb_p50=259.8, satb_entries=992733, old_mb=266.219, rss_mb=549.16

Supplementary (outside the bench, `bench-raw-extra-scenarios.txt`): C2 with
`KAJO_CM_QOS=high` (marker at QoS user-initiated), 3 runs: missed 0, 2, 0;
fallbacks 3, 11, 11 (p50 7.7 to 8.2 ms, max 9.5 ms); 612 to 618 cycles;
final mark max 0.20 ms.

Reading the scenarios:

- **C0 is clean** (0 missed in every run).
- **C1 reproduces ADR 0005's G2**: 405 full collections at 6.4 ms p50 and
  8.9 ms max (G2: 389 at 6.5 and 7.8), 3, 3 and 2 missed frames (G2: 3, 2,
  2), world stopped 45 percent of the time (G2: 44 to 45).
- **C3 reproduces stop-the-world on a large heap**: one full collection
  per 10 s, 40 to 42 ms, each costing 4 to 5 frames; the run loop's worst
  iteration is that pause, measured as GC enter wait.
- **C4 and C6: concurrent marking removes it.** 6 to 7 cycles per 10 s,
  initial pause 0.30 ms p50 (max 0.53 ms, almost all of it a scavenge),
  final mark 0.11 ms p50 (max 0.16 ms), world stopped 1.3 percent, no pause
  above 4 ms. Two markers (C6) marked 256 MiB in 51 ms of wall time against
  45 with one, using 2.4 times the CPU (section 5). The missed frames in C4
  (2 and 3 in two runs) and C6 (1 in one run) come from run-loop iterations
  of 15 to 19 ms that contain 0 to 1 ms of VM work and no GC wait. Seven
  further C4 runs (supplementary) missed nothing; their worst iterations
  were 6.7 to 13.2 ms with 0.3 to 0.8 ms of VM work. In four of them the
  shell's remaining main-thread work was also timed: `checkStuck` peaked at
  0.05 ms and the event timer handler at 0.62 ms. The stalls are outside the
  VM, the collector and the shell's own code; not dissected further.
- **C2 and C5: the allocation storm overwhelms the cycle.** About 500 to
  550 cycles in 10 s, 87 (C2) and 114 (C5) fallbacks, every one with the
  cycle still sweeping (stderr). Fallback pauses are longer than C1's full
  collections because old space is further over the limit when they
  happen. World stopped 31 to 33 percent, against C1's 45: less stopped
  time, but longer worst pauses, so more missed frames.
- **Time to safepoint** p99 stayed at 0.12 to 0.15 ms, max 0.20 ms.

**Verifier on in scenario runs** (`--verify`, one run each, not in the
tables above):

| id | missed frames | cycles | verifier runs | missed objects | floating garbage MB max | final p50 / max without verifier | verifier max ms | fallbacks |
|---|--:|--:|--:|--:|--:|---|--:|--:|
| C2 | 19 | 378 | 401 | 0 | 21.417 | 0.085 / 0.164 | 6.579 | 120 |
| C4 | 30 | 6 | 6 | 0 | 2.376 | 0.110 / 0.120 | 42.559 | 0 |

Neither run found an object the concurrent marker missed: 401 comparisons
(counted over the whole process) under the allocation storm and 6 under the
256 MiB heap. The verifier's traversal takes up to 43 ms inside the final
pause at 256 MiB, so those runs drop frames by design. Floating garbage
(marked, unreachable at the final mark) was at most 21.4 and 2.4 MB per
cycle.

## 3. Barrier cost and mutator slowdown

`stw/nomark`: the SATB fast path compiled in, marking never on. `force/stw`: marking flag on all the time and cycles back to back.

| kernel | workers | build | nomark | stw | stw/nomark | force | force/stw | SATB slow-path calls (force) |
|---|--:|---|--:|--:|--:|--:|--:|--:|
| arith | 1 | O | 2766.4 | 2739.6 | 0.990 | 2732.6 | 0.997 | 1092 |
| arith | 1 | align32 | 2746.2 | 2746.6 | 1.000 | - | - | - |
| arith | 8 | O | 368.6 | 365.7 | 0.992 | 365.3 | 0.999 | 1163 |
| arith | 8 | align32 | 370.4 | 371.8 | 1.004 | - | - | - |
| fib | 1 | O | 1588.3 | 1583.6 | 0.997 | 1583.6 | 1.000 | 636 |
| fib | 1 | align32 | 1593.7 | 1586.4 | 0.995 | - | - | - |
| fib | 8 | O | 205.8 | 212.8 | 1.034 | 205.8 | 0.967 | 696 |
| fib | 8 | align32 | 213.1 | 209.5 | 0.983 | - | - | - |
| sends | 1 | O | 2294.5 | 2298.2 | 1.002 | 2307.2 | 1.004 | 927 |
| sends | 1 | align32 | 2301.8 | 2305.5 | 1.002 | - | - | - |
| sends | 8 | O | 303.6 | 311.1 | 1.025 | 310.6 | 0.998 | 1026 |
| sends | 8 | align32 | 307.5 | 311.3 | 1.012 | - | - | - |
| ivars | 1 | O | 1880.5 | 1964.5 | 1.045 | 2241.6 | 1.141 | 144044440 |
| ivars | 1 | align32 | 1913.1 | 1922.4 | 1.005 | - | - | - |
| ivars | 8 | O | 248.0 | 256.0 | 1.032 | 290.7 | 1.136 | 144034165 |
| ivars | 8 | align32 | 257.8 | 253.9 | 0.985 | - | - | - |
| alloc | 1 | O | 2156.1 | 2165.8 | 1.004 | 2274.3 | 1.050 | 41951484 |
| alloc | 8 | O | 493.4 | 469.7 | 0.952 | 460.5 | 0.980 | 42009147 |
| churn | 1 | O | 1491.6 | 1513.7 | 1.015 | 1591.7 | 1.052 | 48000638 |
| churn | 1 | align32 | 1490.9 | 1518.4 | 1.018 | - | - | - |
| churn | 8 | O | 208.3 | 207.6 | 0.997 | 220.7 | 1.063 | 48000737 |
| churn | 8 | align32 | 207.0 | 207.0 | 1.000 | - | - | - |
| survivors5 | 1 | O | 1130.2 | 1149.7 | 1.017 | 1213.6 | 1.056 | 32813800 |
| survivors5 | 8 | O | 164.6 | 166.8 | 1.013 | 170.0 | 1.019 | 32816958 |
| survivors30 | 1 | O | 1545.7 | 1573.8 | 1.018 | 1658.0 | 1.054 | 36876440 |
| survivors30 | 8 | O | 227.7 | 229.7 | 1.009 | 234.9 | 1.023 | 36882698 |
| oldheap64 | 1 | O | 1760.1 | 1772.1 | 1.007 | 2113.7 | 1.193 | 38579487 |
| oldheap64 | 8 | O | 252.4 | 265.2 | 1.051 | 288.8 | 1.089 | 38578085 |
| oldheap256 | 1 | O | 8003.9 | 8057.0 | 1.007 | 9934.4 | 1.233 | 154319280 |
| oldheap256 | 8 | O | 1102.5 | 1122.5 | 1.018 | 1245.8 | 1.110 | 154318546 |
| oldheap512 | 1 | O | 16860.9 | 17074.3 | 1.013 | 21128.4 | 1.237 | 308639049 |
| oldheap512 | 8 | O | 2342.5 | 2374.1 | 1.013 | 2647.4 | 1.115 | 308637513 |

- **Marking off** (`stw/nomark`): `arith`, `fib`, `sends` and the
  allocation kernels are within 0.95 to 1.05 in both builds, the noise of
  the 8-worker runs. `ivars` stores a SmallInteger into an ivar in its inner
  loop: 1.045 and 1.032 in the O build, 1.005 and 0.985 aligned. `churn`:
  1.015 and 1.018. So the fast path costs up to about 2 to 4 percent on a
  store-dense loop and nothing measurable elsewhere. Code: `ldrb w8, [x19,
  #0x8]; cbz w8` before a plain `str` (relaxed atomic slot stores compile to
  the same `str` as before).
- **The first version cost 20 percent** on `ivars` with marking never on,
  aligned or not (1.201 and 1.204 with one worker, single runs). The SATB
  call came before an inline store, so the holder and value were live across
  a call, and the register allocator moved the object table and heap bases
  out of registers for the whole interpreter loop: every `push_ivar` then
  reloaded them from the stack. Passing fewer arguments did not help; making
  the marking path one out-of-line call that does the record, the store and
  the generational barrier did (`storeWhileMarking`; SPEC.md "SATB
  barrier"). The lesson for the VM core: in the interpreter loop, a slow
  path must leave nothing of the instruction live after its call.
- **Marking on** (`force/stw`): -2 to 6 percent on `alloc`, `churn` and
  the survivors kernels; `ivars` 14 percent (144 million slow-path calls,
  each returning at the holder test because the holder is young); `oldheap`
  9 to 12 percent with 8 workers and 19 to 24 percent with 1, where cycles
  run back to back (258 to 268 cycles per run) and every rewire takes the
  slow path. In ordinary `cm` runs marking is on 1 to 3 percent of the time
  with one worker and 15 to 58 percent with eight (`oldheap`), and `cm/stw`
  is 0.97 to 1.05.
- **SATB volume**: 4 000 to 27 000 entries per cycle with one worker and
  70 000 to 456 000 with eight (`oldheap`); every other kernel recorded
  none, because their overwritten values are young or nil. The entries are
  `oldheap`'s rewired node links and replaced spine slots that the marker
  had not reached yet.

## 4. Pause breakdown and scaling with old-space size

| kernel | workers | config | stw full p50 / max | initial p50 / max | scavenge part p50 | snapshot p50 / max | root scan p50 / max | root words p50 | final p50 / p99 / max | final ttsp p50 / max | drain p50 / max | drained entries max | apply p50 / max |
|---|--:|---|---|---|--:|---|---|--:|---|---|---|--:|---|
| oldheap64 | 1 | stw | - | - / - | - | - / - | - / - | - | - / - / - | - / - | - / - | - | - / - |
| oldheap64 | 1 | cm | - | 0.191 / 0.275 | 0.172 | 0.013 / 0.024 | 0.009 / 0.016 | 150 | 0.010 / 0.017 / 0.017 | 0.009 / 0.015 | 0.001 / 0.001 | 509 | 0.010 / 0.013 |
| oldheap64 | 1 | cm2 | - | 0.198 / 0.317 | 0.176 | 0.016 / 0.032 | 0.011 / 0.022 | 150 | 0.006 / 0.009 / 0.009 | 0.004 / 0.006 | 0.001 / 0.002 | 398 | 0.010 / 0.021 |
| oldheap64 | 8 | stw | 5.45 / 11.20 | - / - | - | - / - | - / - | - | - / - / - | - / - | - / - | - | - / - |
| oldheap64 | 8 | cm | - | 0.593 / 1.037 | 0.481 | 0.025 / 0.040 | 0.019 / 0.061 | 402 | 0.104 / 0.162 / 0.162 | 0.095 / 0.142 | 0.011 / 0.067 | 2682 | 0.013 / 0.017 |
| oldheap64 | 8 | cm2 | - | 0.563 / 0.946 | 0.437 | 0.016 / 0.034 | 0.017 / 0.074 | 399 | 0.133 / 0.157 / 0.157 | 0.114 / 0.138 | 0.010 / 0.024 | 2913 | 0.012 / 0.017 |
| oldheap256 | 1 | stw | 33.26 / 33.43 | - / - | - | - / - | - / - | - | - / - / - | - / - | - / - | - | - / - |
| oldheap256 | 1 | cm | - | 0.193 / 0.305 | 0.162 | 0.013 / 0.077 | 0.008 / 0.015 | 150 | 0.013 / 0.032 / 0.032 | 0.010 / 0.018 | 0.001 / 0.018 | 501 | 0.022 / 0.027 |
| oldheap256 | 1 | cm2 | - | 0.196 / 0.272 | 0.168 | 0.014 / 0.051 | 0.010 / 0.017 | 150 | 0.008 / 0.042 / 0.042 | 0.005 / 0.011 | 0.001 / 0.037 | 510 | 0.022 / 0.029 |
| oldheap256 | 8 | stw | 40.71 / 41.41 | - / - | - | - / - | - / - | - | - / - / - | - / - | - / - | - | - / - |
| oldheap256 | 8 | cm | - | 0.571 / 1.066 | 0.420 | 0.021 / 0.058 | 0.015 / 0.059 | 403 | 0.131 / 0.591 / 0.591 | 0.108 / 0.151 | 0.018 / 0.585 | 3043 | 0.030 / 0.036 |
| oldheap256 | 8 | cm2 | - | 0.560 / 1.232 | 0.425 | 0.021 / 0.064 | 0.015 / 0.046 | 398 | 0.117 / 0.507 / 0.507 | 0.098 / 0.130 | 0.018 / 0.379 | 2915 | 0.032 / 0.045 |
| oldheap512 | 1 | stw | 66.26 / 67.10 | - / - | - | - / - | - / - | - | - / - / - | - / - | - / - | - | - / - |
| oldheap512 | 1 | cm | - | 0.214 / 0.362 | 0.175 | 0.027 / 0.091 | 0.008 / 0.015 | 150 | 0.010 / 0.024 / 0.024 | 0.007 / 0.015 | 0.001 / 0.019 | 501 | 0.037 / 0.048 |
| oldheap512 | 1 | cm2 | - | 0.208 / 0.350 | 0.172 | 0.025 / 0.108 | 0.007 / 0.017 | 150 | 0.009 / 0.046 / 0.046 | 0.005 / 0.012 | 0.001 / 0.037 | 510 | 0.037 / 0.042 |
| oldheap512 | 8 | stw | 80.44 / 81.05 | - / - | - | - / - | - / - | - | - / - / - | - / - | - / - | - | - / - |
| oldheap512 | 8 | cm | - | 0.596 / 1.036 | 0.461 | 0.038 / 0.103 | 0.014 / 0.068 | 402 | 0.131 / 0.954 / 0.954 | 0.113 / 0.145 | 0.014 / 0.838 | 2771 | 0.047 / 0.057 |
| oldheap512 | 8 | cm2 | - | 0.580 / 1.110 | 0.448 | 0.035 / 0.144 | 0.015 / 0.065 | 403 | 0.146 / 0.328 / 0.328 | 0.117 / 0.169 | 0.025 / 0.181 | 3095 | 0.048 / 0.067 |

- **Initial mark.** The pause is a scavenge (0.16 to 0.18 ms with one
  worker, 0.42 to 0.48 ms with eight) plus the snapshot copy of the entry
  bitmap and block map (0.013 to 0.038 ms p50, max 0.024 to 0.144 ms,
  growing with the table's high-water mark) plus the root scan (0.007 to
  0.019 ms p50, 150 to 403 root words: the class table, globals, symbols
  and a few Process stacks). Time to safepoint is inside the scavenge part.
- **Final mark.** With one worker 0.006 to 0.013 ms p50, nearly all of it
  stopping. With eight workers 0.10 to 0.15 ms p50, of which 0.095 to 0.117
  ms is time to safepoint and 0.010 to 0.025 ms the drain. Its tail is the
  drain: the max grows with the heap (0.16, 0.59 and 0.95 ms at 64, 256 and
  512 MiB with 8 workers) because the partial SATB buffers (up to 512
  entries per worker) can name not yet marked subgraphs. Two markers
  reached the final mark with less left (max 0.33 ms at 512 MiB).
- **Apply.** Publishing a finished sweep (freeing dead blocks, rebuilding
  the free-block list, adding chunks to the entry pool) happens in the next
  pause of any kind: 0.010, 0.022 and 0.037 ms p50 with one worker at 64,
  256 and 512 MiB. It is linear in the number of blocks.
- **Stop-the-world for comparison**: 33 ms at 256 MiB and 66 ms at 512 MiB
  with one worker, 41 and 80 ms with eight.

## 5. Marker throughput, fallbacks and headroom

Promotion rate: promoted MB over wall time (median run). Headroom: old space at the final mark minus at the initial mark.

| kernel | workers | config | promotion MB/s | cycles done / aborted | marked MB p50 | marking ms p50 / max | marker CPU ms p50 | marker MB per CPU s | sweep CPU ms p50 | sweep to apply ms p50 | promoted during marking MB p50 / max | old at start MB p50 | headroom used MB p50 / max | freed MB p50 | fallbacks |
|---|--:|---|--:|---|--:|---|--:|--:|--:|--:|---|--:|---|--:|--:|
| alloc | 1 | cm | 337 | 95 / 0 | 3.0 | 0.6 / 1.4 | 0.6 | 5266 | 2.14 | 8.7 | 0.0 / 0.0 | 39.2 | 0.0 / 0.0 | 36.0 | 0 |
| alloc | 1 | cm2 | 337 | 95 / 0 | 3.0 | 0.6 / 0.6 | 0.6 | 5235 | 2.14 | 8.8 | 0.0 / 0.0 | 39.2 | 0.0 / 0.0 | 36.0 | 0 |
| alloc | 8 | cm | 1540 | 11 / 53 | 18.3 | 7.5 / 13.0 | 6.5 | 2961 | 3.93 | 7.2 | 0.0 / 23.7 | 44.3 | 0.0 / 23.9 | 24.0 | 63 |
| alloc | 8 | cm2 | 1575 | 17 / 50 | 21.8 | 5.9 / 12.3 | 8.4 | 2304 | 5.63 | 11.1 | 0.0 / 20.6 | 46.5 | 0.0 / 20.8 | 24.0 | 63 |
| churn | 1 | cm | 0 | 0 / 0 | - | - / - | - | - | - | - | - / - | - | - / - | - | 0 |
| churn | 8 | cm | 0 | 0 / 0 | - | - / - | - | - | - | - | - / - | - | - / - | - | 0 |
| survivors5 | 1 | cm | 22 | 0 / 0 | - | - / - | - | - | - | - | - / - | - | - / - | - | 0 |
| survivors5 | 8 | cm | 162 | 0 / 0 | - | - / - | - | - | - | - | - / - | - | - / - | - | 0 |
| survivors30 | 1 | cm | 95 | 15 / 0 | 1.1 | 0.3 / 0.3 | 0.2 | 4878 | 1.78 | 15.2 | 0.0 / 0.0 | 39.5 | 0.0 / 0.0 | 38.3 | 0 |
| survivors30 | 8 | cm | 620 | 20 / 0 | 12.8 | 8.6 / 20.2 | 8.1 | 1637 | 4.86 | 11.6 | 0.0 / 12.4 | 45.0 | 0.0 / 12.5 | 32.3 | 0 |
| oldheap64 | 1 | cm | 105 | 10 / 0 | 64.0 | 8.4 / 8.6 | 8.3 | 7674 | 1.28 | 6.4 | 0.0 / 0.0 | 115.5 | 0.0 / 0.0 | 51.0 | 0 |
| oldheap64 | 1 | cm2 | 104 | 10 / 0 | 64.0 | 5.9 / 8.4 | 10.9 | 5604 | 1.27 | 8.7 | 0.0 / 0.0 | 115.5 | 0.0 / 0.0 | 51.0 | 0 |
| oldheap64 | 8 | cm | 714 | 10 / 0 | 64.0 | 20.6 / 69.6 | 18.7 | 2546 | 3.29 | 11.7 | 7.8 / 13.6 | 119.4 | 8.1 / 13.8 | 54.7 | 0 |
| oldheap64 | 8 | cm2 | 721 | 10 / 0 | 64.0 | 17.0 / 18.9 | 31.1 | 2138 | 3.32 | 14.2 | 7.8 / 8.0 | 119.7 | 8.0 / 8.2 | 54.7 | 0 |
| oldheap256 | 1 | cm | 93 | 25 / 0 | 256.1 | 34.3 / 37.6 | 34.0 | 7473 | 3.70 | 18.4 | 1.0 / 1.0 | 345.7 | 1.0 / 1.0 | 88.0 | 0 |
| oldheap256 | 1 | cm2 | 92 | 25 / 0 | 256.1 | 23.4 / 27.0 | 43.0 | 5985 | 3.72 | 14.1 | 1.0 / 1.0 | 345.7 | 1.0 / 1.0 | 88.0 | 0 |
| oldheap256 | 8 | cm | 657 | 24 / 0 | 256.1 | 80.7 / 340.2 | 72.2 | 3179 | 9.26 | 21.3 | 31.1 / 119.2 | 351.8 | 31.3 / 119.8 | 93.1 | 0 |
| oldheap256 | 8 | cm2 | 655 | 25 / 0 | 256.1 | 68.9 / 201.6 | 126.3 | 1864 | 9.32 | 20.6 | 23.5 / 77.2 | 351.1 | 23.8 / 77.6 | 92.9 | 0 |
| oldheap512 | 1 | cm | 87 | 35 / 0 | 512.3 | 71.1 / 76.1 | 70.4 | 7255 | 6.96 | 10.9 | 3.0 / 3.0 | 653.1 | 3.0 / 3.0 | 138.0 | 0 |
| oldheap512 | 1 | cm2 | 87 | 35 / 0 | 512.3 | 42.6 / 49.4 | 81.4 | 6285 | 6.97 | 17.8 | 1.0 / 2.0 | 653.1 | 1.0 / 2.0 | 138.0 | 0 |
| oldheap512 | 8 | cm | 598 | 30 / 0 | 512.3 | 161.3 / 679.3 | 146.9 | 2534 | 17.22 | 28.2 | 61.3 / 257.8 | 656.9 | 61.7 / 259.0 | 140.7 | 0 |
| oldheap512 | 8 | cm2 | 611 | 30 / 0 | 512.3 | 141.0 / 372.1 | 252.1 | 1743 | 17.14 | 24.4 | 52.7 / 137.6 | 656.5 | 53.1 / 138.2 | 140.3 | 0 |

### Threshold, marker QoS and old-space size

`-h256`: 256 MiB old space instead of 64. `qoshigh`: marker at QoS user-initiated instead of utility.

| kernel | config | wall ms | cycles | fallbacks (all runs) | stw fulls (median) | full or fallback pause max | final max | marking ms p50 | marker CPU ms p50 |
|---|---|--:|--:|--:|--:|--:|--:|--:|--:|
| alloc | cm | 457.0 | 13 | 63 | 13 | 13.31 | 0.173 | 7.5 | 6.5 |
| alloc | cm-h256 | 373.0 | 4 | 5 | 1 | 12.18 | 0.157 | 11.0 | 7.2 |
| alloc | cm-qoshigh | 418.8 | 22 | 34 | 6 | 11.59 | 0.171 | 3.8 | 3.7 |
| alloc | cm-qoshigh-h256 | 369.8 | 5 | 0 | 0 | - | 0.160 | 3.5 | 3.4 |
| alloc | cm-t20 | 451.2 | 14 | 64 | 13 | 12.59 | 0.152 | 5.3 | 4.7 |
| alloc | cm-t30 | 440.7 | 15 | 63 | 12 | 12.34 | 0.188 | 4.5 | 3.9 |
| alloc | cm-t40 | 427.2 | 14 | 55 | 11 | 10.39 | 0.169 | 4.6 | 4.1 |
| alloc | cm-t50 | 452.4 | 14 | 63 | 13 | 11.83 | 0.179 | 5.2 | 5.0 |
| alloc | stw-h256 | 399.8 | - | 0 | 3 | 16.95 | - | - | - |
| survivors30 | cm | 232.2 | 4 | 0 | 0 | - | 0.143 | 8.6 | 8.1 |
| survivors30 | cm-t20 | 227.8 | 12 | 0 | 0 | - | 0.200 | 5.1 | 4.6 |
| survivors30 | cm-t30 | 235.4 | 9 | 0 | 0 | - | 0.178 | 5.3 | 4.7 |
| survivors30 | cm-t40 | 227.4 | 6 | 0 | 0 | - | 0.152 | 6.4 | 5.6 |
| survivors30 | cm-t50 | 225.9 | 4 | 0 | 0 | - | 0.155 | 4.5 | 3.5 |
| oldheap256 | cm | 1133.4 | 5 | 0 | 0 | - | 0.591 | 80.7 | 72.2 |
| oldheap256 | cm-qoshigh | 1123.5 | 5 | 0 | 0 | - | 0.219 | 44.5 | 43.1 |

### oldheap mutation rates

| kernel | workers | config | build ms | mutate ms | rewires/s | replaced MB/s | live MB (sweep) |
|---|--:|---|--:|--:|--:|--:|--:|
| oldheap64 | 1 | stw | 66.9 | 1703.8 | 1173823 | 71.7 | - |
| oldheap64 | 1 | cm | 67.5 | 1711.4 | 1168665 | 71.3 | 64.0 |
| oldheap64 | 8 | stw | 13.1 | 252.4 | 7923695 | 483.7 | - |
| oldheap64 | 8 | cm | 13.3 | 242.8 | 8238905 | 503.0 | 64.0 |
| oldheap256 | 1 | stw | 267.0 | 7790.0 | 1026953 | 62.7 | - |
| oldheap256 | 1 | cm | 270.2 | 7767.5 | 1029937 | 62.9 | 256.1 |
| oldheap256 | 8 | stw | 50.1 | 1070.3 | 7474231 | 456.3 | - |
| oldheap256 | 8 | cm | 50.8 | 1081.7 | 7395562 | 451.5 | 256.1 |
| oldheap512 | 1 | stw | 538.0 | 16536.3 | 967568 | 59.1 | - |
| oldheap512 | 1 | cm | 538.3 | 16497.8 | 969828 | 59.2 | 512.3 |
| oldheap512 | 8 | stw | 100.7 | 2273.8 | 7036816 | 429.6 | - |
| oldheap512 | 8 | cm | 101.1 | 2387.9 | 6700397 | 409.1 | 512.3 |

- **Marker throughput.** With one worker a marker scans 4.9 to 7.7 GB of
  old objects per CPU second (`oldheap` 7.3 to 7.7: its nodes are 14-slot
  arrays, mostly nil, allocated contiguously; `alloc`'s 24-byte nodes 5.3;
  `survivors30` 4.9). With eight workers running it drops to 1.6 to 3.2
  GB/s: at QoS utility the marker runs on the efficiency cores, and the
  workers compete for memory bandwidth. At QoS user-initiated `oldheap256`
  marked in 44.5 ms instead of 80.7 ms (wall), and the final-mark maximum
  fell from 0.59 to 0.22 ms. Core placement is not observable from user
  space; these are CPU and wall times.
- **Two markers** shortened marking by 13 to 40 percent but used 1.2 to 1.8
  times the CPU, and with eight workers marked at 1.7 to 2.1 GB per CPU
  second against 2.5 to 3.2 for one. For `oldheap` one marker already keeps
  up, so the second only adds CPU. For `alloc` it changed nothing (63
  fallbacks either way).
- **Keeping up.** Against `oldheap`'s 600 to 710 MB/s of promotion with 8
  workers one marker finished every cycle, with 0 fallbacks in 64 cycles,
  and used at most 258 MB of headroom (512 MiB). Against `alloc` with 8
  workers (1.5 GB/s promoted into 64 MiB, live data about 20 MB) 53 of 64
  cycles were aborted. The stderr lines show every fallback happened while
  the cycle was sweeping: marking (6.5 ms CPU) fits a scavenge interval;
  marking plus sweeping (3.9 ms CPU) plus waiting for the next pause to
  publish the sweep often does not. Sweep cost is proportional to the
  snapshot (every entry that was old when marking started), not to garbage.
- **Allocation never waited for a block to be swept** (by construction:
  mutators allocate young, promotion uses the promotion reserve, and freed
  blocks are published at the next pause). The cost of that choice shows up
  as fallbacks: old space stays full until a pause publishes the sweep.
- **Thresholds** from 20 to 60 percent changed neither `alloc`'s fallbacks
  (55 to 64) nor `survivors30`'s (0); lower thresholds only run more cycles.
- **Old-space sizing** decides the storm: with 256 MiB `cm` fell back 5
  times in 5 runs and was 18 percent faster than `cm` at 64 MiB; with 256 MiB
  and a user-initiated marker, 0 fallbacks. `stw` at 256 MiB needed 3 full
  collections per run, of up to 17 ms.
- **Memory**: `cm` used less peak RSS than `stw` on `oldheap` (`oldheap512`:
  776 against 1256 MB with one worker, 1106 against 1291 with eight) and
  with one worker on `alloc` and `survivors30`, because cycles start at 60
  percent while the stop-the-world collector waits for the soft limit. With
  eight workers on `alloc` it used more (215 against 174 MB): the promotion
  reserve fills before each fallback.

## 6. What the verifier and the tests caught

**The verifier** (mark sets compared with a from-scratch traversal at every
final mark) ran in every test, in a threaded `oldheap` test with cycles at
every scavenge (one and two markers), and in the two verifier scenario runs
(C2 and C4 with `--verify`: 407 comparisons). It never reported a missed
object except where a test switched off a rule on purpose. The inherited
scavenge verifier (remembered-set invariant, no reference to a freed entry)
ran at every scavenge of every test, across lazy sweeps, and found nothing
after the changes below.

**The tests**, each written to fail without the rule it covers:

1. `satbKeepsAValueOverwrittenDuringMarking` /
   `withoutSATBTheVerifierReportsTheMissedObject`: an old list reachable at
   the snapshot only through an old holder is moved into a young Array
   (never scanned by the marker) and the holder's slot cleared. With SATB
   the list survives two cycles; with the SATB slow path disabled the
   verifier reports the missed objects (100 list cells).
2. `literalProtocolNeedsItsGreyPromotionRule`: DESIGN.md's protocol as
   written (initial mark without a scavenge, promoted objects pushed grey).
   A young object alive at the snapshot holds the only reference to an old
   list; it is promoted while marking. With the grey rule the list
   survives; without it the verifier reports the list missed.
3. `designLiteralProtocolLosesATargetOfADeadYoungObject`: **DESIGN.md's
   protocol is unsound**, even with its grey rule. The young object's
   target is copied into an already scanned old object over `nil` (no SATB
   record) and the young object is dropped; it dies unpromoted, is never
   greyed, and the old list is missed. This is why the snapshot is taken at
   the end of a scavenge: `snapshotAfterAScavengeKeepsTheTargetOfAYoungObject`
   runs the same sequence with this experiment's protocol, nothing missed,
   contents intact.
4. `objectsPromotedDuringMarkingSurviveTheCycle`: promoted objects are not
   snapshot entries, so no sweep of this cycle can free them.
5. `filteringRemovesADeadHolderFromTheRememberedSet`: a dead snapshot
   object made remembered during marking leaves the remembered set at the
   final mark; otherwise the next scavenge would scan a freed entry.
6. `sweepFreesEntriesAndBlocksAndTheyAreReused`,
   `oldSpaceFillingDuringACycleFallsBackToAFullCollection` (a 4 MiB old space
   and a marker that never runs: the cycle is aborted, a full collection
   runs, the data is intact) and
   `oldheapUnderConcurrentMarkingMatchesStopTheWorld` (4 workers, cycles at
   every scavenge, one and two markers, checksums equal to stop-the-world).

**During development:**

- **ThreadSanitizer found one real race**: the sweeper read a dead entry's
  header and then freed its bitmap bit with a relaxed `fetch_and`, and a
  worker took the bit with a relaxed `exchange` and rewrote the entry. With
  no happens-before between them the sweeper's read could even return the
  new header on arm64. Fixed with release on the sweeper's `fetch_and` and
  acquire on the worker's `exchange`.
- The first barrier slow path had no holder test and ran 15 million times
  in one `alloc` run for stores into fresh objects. With the snapshot taken
  when nothing is young, a young holder's old values are never snapshot
  edges, so the slow path now returns at the holder's young bit.
- The register-pressure cost of the barrier (section 3).
- Two inherited tests got wider wall-clock limits (timer latency 5 s
  instead of 1 s, a 60 s wait instead of 20 s): under ThreadSanitizer, with
  marker threads and a cycle at nearly every scavenge in the parallel test
  run, GCD timers starve; both pass alone within the old limits. One
  inherited expectation (verifier runs equal pause records) now excludes
  final-mark pauses, which contain no scavenge.

## 7. Honest notes

**What was hard:**

1. **DESIGN.md's initial mark is unsound** with a nursery (section 6, test
   3). Young objects alive at the snapshot belong to the snapshot graph, and
   their death deletes edges without any barrier. The fix costs nothing
   because the initial mark rides on a scavenge that happens anyway; the
   promotion rule then becomes unnecessary (promoted objects are black by
   not being in the snapshot).
2. **A concurrent reader changes the mutator's stores.** Every slot store
   became a relaxed atomic (free on arm64), the entry bitmap became atomic
   where the sweeper and allocators meet, and the snapshot bitmap exists
   mainly so that neither the marker nor the barrier ever reads the header
   of an object a mutator may be initialising.
3. **The interpreter loop is sensitive to call sites.** One extra call in
   `store_ivar` cost 20 percent through register allocation.
4. **The lazy sweep is the weak point under heavy promotion.** It sweeps
   the whole snapshot and publishes at the next pause; under the storm the
   cycle is still sweeping when old space fills.

**What broke:** the allocation-storm scenarios got worse (C2 7 missed
frames, C5 18) than stop-the-world (C1 3), because fallback pauses are
longer than planned full collections. Concurrent collection needs old-space
headroom proportional to promotion rate times cycle time; ADR 0005's 64 MiB
old space beside 28 MiB of nurseries promoting 1.5 GB/s does not have it.

**What a real system needs next:**

- **Old-space sizing and pacing.** Size old space by promotion rate times
  cycle time, and start cycles by predicted time to fill rather than a fixed
  percentage (the threshold sweep showed a percentage does not help).
  Pacing (allocating workers do marking or sweeping work when the marker
  falls behind) would turn fallbacks into bounded slowdowns.
- **A cheaper sweep.** Sweep in parallel with the marker or by the
  allocators, publish freed blocks without waiting for a pause (a lock-free
  free-block list), or sweep only blocks that may hold garbage.
- **An age field.** `alloc`'s trees are medium-lived: promoted, then dead
  within a cycle. Most of the storm's old-space traffic would never be
  promoted with two or three scavenges of aging.
- **Compaction of old space.** Space is reclaimed only in whole blocks;
  `oldheap` replaces whole groups oldest first so that garbage empties
  blocks. Scattered garbage would pin blocks, as it did in ADR 0005's
  `survivors5` run.
- **Large objects** (up to 32 KiB still go through the nursery).
- **The marker on a phone's efficiency cores.** Here QoS utility (likely
  the E-cores) almost halved marking speed under load, and the storm's
  fallbacks halved at QoS user-initiated. A phone has fewer, slower
  efficiency cores and thermal limits; the marker's QoS is a real decision,
  and the device measurement ADR 0003 waits for should include it.
- **Two markers are not worth it** at these heap sizes: more CPU for the
  same result. A second thread could instead be the sweeper.
- **The final mark's time to safepoint** (0.1 ms with 8 workers) is now
  most of the pause; the drain could be shortened further by asking
  mutators to flush their SATB buffers before the marker requests the stop.

## 8. Recommendation input

On this machine SATB concurrent marking with a lazy sweep, on the
generational object-table VM, turns a full collection into two short
pauses: an initial mark that adds 0.004 to 0.049 ms p50 (at most 0.18 ms) to
a scavenge that was happening anyway, and a final mark of 0.004 to 0.013 ms
p50 with one worker and 0.10 to 0.15 ms p50 with eight, at most 0.95 ms in
the matrix and 0.19 ms in the app. These do not grow measurably from 64 to
512 MiB of live old data, where the stop-the-world collector's pause grew
from 5 to 11 ms to 66 to 81 ms. The barrier costs about 2 to 4 percent on a
store-dense loop when marking is off and nothing measurable elsewhere;
mutators slow down -2 to 14 percent with marking on continuously and 8
workers, and up to 24 percent with one worker on a pointer-rewiring kernel.
One marker at QoS utility kept up with eight workers promoting up to 710
MB/s into a large old heap with **0 fallbacks** in every such run, and the
main thread held 120 Hz under a 256 MiB slowly mutating heap (C4: 2 missed
frames of 1200 in the median run, none attributable to the collector; C3
with stop-the-world: 6). It did **not** keep up with ADR 0005's allocation
storm (1.5 GB/s promoted into a 64 MiB old space): **63 fallbacks in 5
headless runs, 87 and 114 per 10 s in the app**, each a 7 to 13 ms
stop-the-world pause, so that scenario dropped more frames (7 and 18) than
stop-the-world (3). A 256 MiB old space and a user-initiated marker removed
those fallbacks headless (0 in 5 runs). Caveats: one machine (a Mac, not an
iPhone); synthetic kernels, and `oldheap`'s graph is easy to mark (mostly
nil slots, contiguous groups); no thread pinning, marker placement inferred
from QoS; fixed 4 MiB nurseries and promotion on first survival;
whole-block reclamation only, with a kernel shaped to suit it; the
threshold and old-space sizes were chosen, not tuned; the remaining missed
frames under the large heap are unexplained but contain no VM or GC time.
Read with ADR 0004 and 0005: concurrent marking bounds old-space pauses
well below a frame at every heap size tried, provided old space has
headroom for the promotion rate. Without that headroom it degrades to
stop-the-world collections, which must be counted and treated as a sizing
failure.

## Deviations from DESIGN.md

- **Initial mark at the end of a scavenge**, not a pause of its own; its
  reported length includes that scavenge, with the mark part separately.
  DESIGN.md's protocol loses objects (section 6, test 3).
- **Promoted objects are black, not grey** (the snapshot bitmap makes them
  so). DESIGN.md's grey rule is implemented in a test-only literal mode and
  tested there; the test that "fails without the rule" is in that mode.
- **The SATB barrier skips young holders** and runs before every store of a
  pointer slot, including VM-internal stores of `nil` over a pointer (6 more
  sites in `Process.swift`, marked `SATB site`), which the generational
  barrier did not need.
- **Lazy sweep by marker 0 in the background**, published at the next
  pause (an apply step of 0.01 to 0.05 ms inside an existing pause; nothing
  about sweeping stops the world by itself).
- **Mark state** is a byte map, and a snapshot bitmap of the entry table
  was added beside it.
- **Markers take part in the stop protocol** (they park without joining
  scavenges); DESIGN.md did not say how markers and scavenges interact.
- **`oldheap`**: iterations scale with size (N x 250 000) and a whole group
  is replaced every 4096 iterations (32 768 in the app); its mutation rate
  is 59 to 72 MB/s per worker headless and about 57 MB/s in total in the
  app.
- **Matrix additions and omissions**: `cm2` only for `alloc` and `oldheap`;
  `force` as the "marking on continuously" measurement; alignment control
  (`align32`) only for the compute kernels and `churn`, where the barrier's
  fast path is the question. Extras: thresholds, marker QoS, a 256 MiB old
  space for `alloc` (the `heap` part, run after the main bench).
- **Scenario timing**: C3, C4 and C6 wait for the 256 MiB heap to be built
  (0.1 s) before the 1 s warm-up. The main thread's enter and leave waits
  now include blocking on the safepoint mutex (ADR 0005's runs counted that
  as VM time). The `checkStuck` and timer-handler timings and the corrected
  `marking_pct` (it counted aborted cycles to the end of the window; the
  report no longer uses it for scenarios) were added after the bench run.
- **Peak RSS** comes from the headless runs; scenario lines report the
  current RSS at the end.
- Not done: compaction, an age field, large objects (non-goals), pacing,
  iOS.
