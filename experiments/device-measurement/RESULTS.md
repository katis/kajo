# Results: the VM on an iPhone

The benchmarks of `../object-representation` (ADR 0003) and
`../concurrent-young` (ADRs 0005 to 0008) on an iPhone 17 Pro, one kernel or
scenario per app launch, driven over the cable by `bench-device.sh`.
Everything reproduces with `./bench-device.sh` (`PARTS="report"
./bench-device.sh` for the tables only). Raw lines: `results/` (one file per
part, every line with its launch time `at=`, the thermal state at start and
end, battery state and level, `phys_footprint` and its peak, and
`os_proc_available_memory`). All tables: `bench-output.txt`.

**Setup.** iPhone 17 Pro (iPhone18,1), iOS 27.0.1, 6 cores (2 performance,
4 efficiency), 120 Hz ProMotion, on the cable and charging the whole time
(battery 95 percent, state `charging` on every line, Low Power Mode off).
Release build, `-O`, whole module, Xcode 27.1, iOS 27.1 SDK, no
`-Ounchecked`, no alignment-controlled build. Signed with automatic signing
for team `BDN6M642M2` (see "What had to change"). The Mac figures compared
against are from the earlier RESULTS.md files: Apple M2 Max, 8 P + 4 E
cores, macOS 27. The Mac ran 1 and 8 workers; the phone 1, 2 and 6. Where a
phone 6-worker figure is put beside a Mac figure it is the Mac's 8-worker
one, which is not the same load: read those as "the most parallel
configuration on each machine".

## Answers

**1. Object table on device (ADR 0003): narrower where the working set per
core is small, far wider where it is not.** The cache-defeating `walk`
costs B/A **4.42** at one worker (Mac 1.46), traversal alone **7.65x** (Mac
2.02x): 522 ns per hop against 70 ns for direct pointers. At six workers the
same kernel is **1.12** (Mac 1.43 at 8), traversal 1.22x. A sweep over
worker counts (A2) shows the cost follows the size of each worker's graph,
not the total: per-worker graphs of 96 MB (A, 24 bytes a node) / 160 MB
(B, 40 bytes: body and entry) give 7.4x, 48 / 80 MB 2.3x, 32 / 53 MB and
less 1.15 to 1.3x. On
everything else the table costs what it cost on the Mac, slightly more on
sends: `sends` 1.11 / 1.12 (Mac 1.04 / 1.06), `ivars` 1.01 / 1.03 (Mac
1.00 / 1.03), `walkbuild` 1.02 / 1.09. Memory: peak `phys_footprint` on
`walk` 233 MB against 169 MB, **B/A 1.38** (Mac RSS 231 against 167 MB,
1.38). C is A within noise everywhere (C/A 0.93 to 1.05), as on the Mac.
The pause advantages of the table hold on the phone: compaction pause 11.0
against 16.6 ms (Mac 15.6 against 26), two-way become inside the pause 0.13
against 1.5 us (Mac 0.2 against 3.3).

**2. Does the VM run on iOS? Yes, with two source changes, neither in the
VM's logic.** The double mapping of ADR 0007 did not compile: `mach_vm.h`
is `#error mach_vm.h unsupported` in the iOS SDK. With the same calls from
`vm_map.h` (`vm_allocate`, `vm_map`, `mach_make_memory_entry_64`, 64-bit on
arm64) it **works unchanged at run time**: a 4 GiB + heap reservation with
the heap mapped twice, no `vm_remap` needed, no entitlement, every checksum
equal to the stop-the-world reference in all 1 044 Part B launches. pthread workers,
`pthread_attr_set_qos_class_np`, `mach_absolute_time`, `task_info`,
Synchronization's `Atomic` all work as on macOS. The memory limit is about
**3.38 GB** (`os_proc_available_memory` 3370 MB at launch plus the 8 MB
footprint, no increased-memory-limit entitlement); the largest Part B run
peaked at 749 MB (`oldheap256`, 6 workers), and a probe of `oldheap512`
peaked at 1352 MB and ran, so `oldheap256` was not a forced reduction. What
the device changes is not whether it runs but **QoS**: the marker thread at
its default utility QoS marks at 0.6 to 0.7 GB per CPU second with six
busy workers against 3.6 GB at user-initiated (question 3).

**3. Pauses and throughput on device.** Checksums equal `adr7` in every run
of every kernel, worker count and configuration (720 matrix runs, 240 QoS
runs, 72 order runs; no failed launch, no jetsam). At six workers against
the Mac's eight:

- Stop-the-world scavenge (`adr7`) p50 / p99 / max, alloc: **3.49 / 6.72 /
  13.3 ms** (Mac 3.35 / 8.90 / 20.7). Time-to-safepoint p99 0.12 ms, max
  0.22 ms (Mac 0.33 / 1.1); across kernels max 0.1 to 1.2 ms at six
  workers, and one 20.8 ms outlier at two workers.
- Local collection, owner's pause, alloc: **3.58 / 9.87 / 15.2 ms** (Mac
  1.84 / 6.53 / 24.9). One thread copies a whole nursery, and a phone
  thread on an efficiency core copies slower: local p50 is above the
  stop-the-world p50 on every allocating kernel at six workers (1.03 on
  alloc, 1.2 to 1.9 on the others, 3 on churn), unlike the Mac. Max 7 to
  23 ms across kernels (Mac 26 to 30).
- Offload flip: **0.070 / 0.132 / 1.49 ms** (Mac 0.050 / 0.096 / 0.82).
  p99 under 0.32 ms on every kernel and worker count; max up to 6.0 ms
  (oldheap256, Mac up to 2.0).
- Handshake latency at six workers, local / offload: p50 0.035 to 0.049
  ms, p99 0.8 to 2.4 / 0.10 to 0.25 ms, max 4.4 to 12.5 / 2.5 to 9.1 ms
  (Mac at 8: p50 0.05 to 0.08, p99 0.35 to 1.5 / 0.19 to 0.67, max 10 to
  17 / 2 to 16).
- Local eden-reuse wait max: **10.0 ms on almost every kernel at 2 and 6
  workers** (10.009, 10.018, 10.024, 10.048, 10.050; 13.7 on oldheap256),
  under 0.01 ms at one worker. A value pinned at 10 ms across kernels is a
  scheduler quantum, not collector work: the epoch the owner waits for is
  held by a worker descheduled for one 10 ms slice. Not chased further.
- **The collector thread does not keep up with six allocating workers**:
  76 to 96 percent busy, workers wait for it (alloc: 440 waits, 1.8 s
  summed per run), offload wall time 1.15 to 1.24 times stop-the-world on
  the allocating kernels (Mac 1.14 to 1.69 at 8). At one worker offload is again the fastest configuration on alloc
  (0.98 of adr7; 0.88 of the heat-biased stw column).
- Promotion and fallbacks, alloc at six workers: 687 / 444 / 331 MB/s
  (adr7 / local / offload, Mac 8 workers 1161 / 927 / 462); stop-the-world
  fallbacks summed over 5 runs 51 / 15 / 2. With the marker at
  user-initiated QoS local had 0.
- Initial mark p50 at six workers 1.7 to 3.0 ms (Mac 2.1 to 2.8 at 8).
- **QoS decides whether background collection keeps up.** Collector thread
  at utility instead of user-initiated: offload 1.07 to 1.61 times slower,
  collector waits 1.1 to 6.2 s per run at six workers, 3 to 18 times the
  default (survivors30 3.5 s against 0.4 s). Marker at user-initiated instead of utility: mark rate
  0.68 to 3.6 GB per CPU second on oldheap256 at six workers, marking cycle
  p50 746 ms to 72 ms, the share of the run spent marking 96.7 to 16.4
  percent (local), and the alloc fallbacks gone; wall time 0.94 to 1.16 of
  the default. On the Mac the marker's QoS was never the bottleneck; on the
  phone, with six workers busy, utility means efficiency cores.
- Barrier cost at one worker (stw against adr7, the order check after
  cooling): 0.995 to 1.022 (Mac 0.98 to 1.02). The matrix itself shows stw
  1.00 to 1.19 at one worker; that is heat, see question 5.

**4. Frames on device: 120 Hz held, and under the storm the main thread is
stopped for others less than on the Mac in every configuration.** With the phone cooled
(second pass, thermal fair), median run of three, 5 background workers:

| load | young | missed of 1200 | main stopped because another worker allocated | Mac (7 workers) |
|---|---|--:|--:|---|
| idle | offload | 0 | 0 ms | 0 missed, 0 ms |
| storm | stw | 1 | **107.7 ms** (39 scavenges) | 58 missed, 126.0 ms |
| storm | local | 0 | **24.8 ms** (1040 acks) | 6 missed, 36.5 ms |
| storm | offload | 0 | **28.7 ms** (1315 acks) | 5 missed, 67.1 ms |
| fragmentation ring | local | 0 | **1.6 ms** (130 acks) | 12 missed, 0.4 ms |
| heavy main-thread allocation | offload | 0 | **0.02 ms** | 48 missed, 0.04 ms |

The display delivered 120 Hz in every scenario (`refresh_hz` 115.9 to 120,
`screen_max_fps` 120, link duration 8.335 ms). Acknowledgements cost the
main thread 22 to 24 us each when cool, 38 to 43 us hot (Mac 27 to 35). The largest main-thread pauses
left are the old-space initial marks: 1.8 to 2.1 ms p50 under local and
offload, 3.8 ms p50 under stop-the-world. The same scenarios run right after
Part B at thermal state serious stopped the main thread for others **1.6 to
1.9 times longer** (stw 177, local 48, offload 47 ms) and missed up to 40
frames in one stop-the-world run.

**5. Thermal and power: the phone throttles within 12 minutes of
sustained load and the numbers drift by up to 13 percent.** Part A (3.5
minutes) stayed nominal; the repeated walk kernel drifted 1.03. Part B
went nominal to fair after 3 minutes and to serious after 12, and stayed
serious through the QoS matrix and the first Part C pass (about 32 minutes in all); its repeated first kernel (alloc, stw, 1 worker) went 1743 to 1968 ms,
**1.13**. Cooling from serious to nominal took 7 minutes on the cable, idle.
The matrix's 1-worker stw column is up to 19 percent slower than adr7 even
on kernels that never collect; stw ran first after each 6-worker burst, and
the same comparison after cooling, in both orders and right after a
6-worker run, is within 2 percent. So the 1-worker ratios in the Part B
table are perturbed by heat by up to about 15 percent; ratios between
configurations run back to back are what to trust, and only after a
cool-down.

## What had to change to run on iOS

1. **`mach_vm.h` is unsupported in the iOS SDK.** The double mapping in
   `Sources/VMR/Blocks.swift` (`mapTwice`) used `mach_vm_allocate` and
   `mach_vm_map`. The device copy uses `vm_allocate` and `vm_map` from
   `vm_map.h` with the same arguments (on arm64 `vm_address_t` and
   `vm_size_t` are 64 bits). `mach_make_memory_entry_64` with
   `MAP_MEM_NAMED_CREATE` compiled and worked as is. It reserves `relocBit
   + heap` (4 GiB plus up to 576 MiB) of address space and maps the heap at
   the start and at +4 GiB; the app has no extended-virtual-addressing
   entitlement and did not need one. This is the only change inside a VM
   source file; the diff is 11 lines, in place in the file with a "DEVICE
   CHANGE" comment.
2. **Kernel files were found through `#filePath`**, a path on the Mac.
   `Sources/Kasm/KernelFiles.swift` is a merge of both experiments'
   `KernelFiles.swift` with `experimentsDir` as a variable the app sets to
   the bundled copy, and a `kernelFlavor` switch, because the two
   experiments' `kernelSources` share a name and differ in behaviour. A
   build phase copies every `experiments/*/kernels/*.kasm` the two need
   into the app bundle, in the repository's layout.
3. **One package for five VMs.** `swift/` is a SwiftPM package whose
   targets are per-file symlinks to the original sources (`VMA`, `VMB`,
   `VMC`, `VMR`, and `VMRNB` = VMR with `-DNO_YOUNG_BARRIER`, the `adr7`
   build), except the two files above. `Kasm.swift` is identical in both
   experiments, so one Kasm module serves all of them. Nothing under
   `../object-representation`, `../concurrent-relocation` or
   `../concurrent-young` was modified.
4. **The shells.** `app/Sources/Scenario.swift` is concurrent-young's
   `kajo-ui` ported from AppKit to UIKit: the turn scheduling, frame
   account, event timer, run-loop observer, watchdog and result line are
   that file's; the window, views and output are new. The display link is a
   `CADisplayLink` on the main run loop with `preferredFrameRateRange`
   80 to 120, `CADisableMinimumFrameDurationOnPhone` in Info.plist, and a
   view moved on every callback so ProMotion never throttles. Headless runs
   execute on a `Thread` with a 16 MiB stack at user-initiated QoS while
   the main thread draws a status view; scenarios load their image after
   the first frame. Every result line goes to stdout and to Documents.
5. **Signing.** The brief named team `A7ZJ8ZA2F7`; that is a leftover
   certificate in the Mac's keychain with no account behind it, and
   `xcodebuild -allowProvisioningUpdates` failed with it. Xcode's signed-in
   account is team `BDN6M642M2` (same person, profiles valid to 2027); the
   project and `bench-device.sh` use it. The phone already trusted that
   developer, so no trust prompt appeared.

Nothing else broke: pthread QoS classes, `mach_absolute_time`, `task_info`
(`TASK_VM_INFO` for `phys_footprint`), `getrusage`, `Synchronization`, and
the dispatch timers of the shell behave as on macOS. No watchdog kill, no
jetsam, no crash in about 1 330 launches (one cool-down probe failed to
launch and the next one minute later succeeded).

## Part A: object representation

Medians of 5 interleaved runs, 1 and 6 workers; `compact` and `become` at
6 workers (1 operating, 5 running fib), as the Mac ran them at 8.

### Part A: object representation (median of 5 runs)

| kernel | w | A ms | B ms | C ms | B/A | C/A | Mac B/A (w=1/8) | Mac C/A | checksums | runs | failed |
|---|--:|--:|--:|--:|--:|--:|--:|--:|---|--:|--:|
| walk | 1 | 1190.0 | 5259.2 | 1148.1 | 4.42 | 0.96 | 1.46 | 0.98 | equal | 5 | 0 |
| walk | 6 | 275.6 | 308.0 | 284.9 | 1.12 | 1.03 | 1.43 | 1.0 | equal | 5 | 0 |
| walkbuild | 1 | 579.6 | 592.0 | 580.0 | 1.02 | 1.00 | 0.98 | 1.0 | equal | 5 | 0 |
| walkbuild | 6 | 217.9 | 237.5 | 218.3 | 1.09 | 1.00 | 1.03 | 0.97 | equal | 5 | 0 |
| sends | 1 | 1233.9 | 1365.3 | 1246.1 | 1.11 | 1.01 | 1.04 | 1.0 | equal | 5 | 0 |
| sends | 6 | 466.9 | 521.8 | 489.3 | 1.12 | 1.05 | 1.06 | 1.0 | equal | 5 | 0 |
| ivars | 1 | 944.0 | 956.4 | 921.8 | 1.01 | 0.98 | 1.0 | 1.0 | equal | 5 | 0 |
| ivars | 6 | 374.4 | 386.4 | 376.4 | 1.03 | 1.01 | 1.03 | 1.0 | equal | 5 | 0 |

### Traversal only: walk minus walkbuild (ms), phone against Mac

| w | A | B | C | B/A | C/A | Mac A | Mac B | Mac C | Mac B/A |
|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| 1 | 610.4 | 4667.2 | 568.1 | 7.65 | 0.93 | 909.7 | 1834.6 | 878.4 | 2.02 |
| 6 | 57.7 | 70.5 | 66.6 | 1.22 | 1.15 | 91.8 | 188.8 | 96.0 | 2.06 |

### A2: walk against worker count (per-worker graph 2^22/n nodes), median of 3

| w | nodes per worker | A walk | B walk | B/A walk | A traversal | B traversal | B/A traversal | ns per hop A / B | B footprint peak MB |
|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| 1 | 4194304 | 1170.7 | 4974.5 | 4.25 | 591.1 | 4381.6 | 7.41 | 70.5 / 522.3 | 233 |
| 2 | 2097152 | 630.8 | 1010.0 | 1.60 | 280.4 | 655.9 | 2.34 | 66.9 / 156.4 | 234 |
| 3 | 1398101 | 395.1 | 437.7 | 1.11 | 88.0 | 116.6 | 1.32 | 31.5 / 41.7 | 234 |
| 4 | 1048576 | 444.0 | 679.2 | 1.53 | 178.1 | 395.1 | 2.22 | 84.9 / 188.4 | 235 |
| 5 | 838860 | 305.6 | 325.9 | 1.07 | 67.2 | 77.6 | 1.15 | 40.1 / 46.3 | 235 |
| 6 | 699050 | 292.1 | 312.6 | 1.07 | 56.3 | 69.8 | 1.24 | 40.3 / 49.9 | 236 |

The A2 sweep is not in DESIGN.md; it was added when the 1- and 6-worker
results differed by a factor of four. Every worker builds and walks its own
graph of 2^22/n nodes, so the total heap is the same at every n and only the
per-thread working set shrinks. The table's cost falls with it, from 7.4x
traversal at 96 / 160 MB per thread to 1.15 to 1.3x at 32 / 53 MB and less.
That points at per-core translation or cache reach (B touches two pages per hop, a body and an entry, in two separate regions;
A touches one), not at total
memory or bandwidth. It is a hypothesis: no performance counters were read.
The 4-worker row is worse than 3 and 5 for both variants and was not
explained; the kernel's wall time is its slowest worker, and with 4 workers
on 2 performance cores the stragglers sit on efficiency cores.

### Phone against Mac, absolute (A ms; Mac M2 Max `O` build, phone w=6 against Mac w=8)

| kernel | w | phone A | Mac A | phone/Mac |
|---|--:|--:|--:|--:|
| walk | 1 | 1190.0 | 1978.1 | 0.60 |
| walk | 6 | 275.6 | 235.7 | 1.17 |
| walkbuild | 1 | 579.6 | 1068.4 | 0.54 |
| walkbuild | 6 | 217.9 | 143.9 | 1.51 |
| sends | 1 | 1233.9 | 2380.9 | 0.52 |
| sends | 6 | 466.9 | 313.2 | 1.49 |
| ivars | 1 | 944.0 | 2184.3 | 0.43 |
| ivars | 6 | 374.4 | 287.1 | 1.30 |

The phone runs this interpreter about twice as fast as the M2 Max on one
thread (ivars 0.43, sends 0.52 of the Mac's time) and 1.2 to 1.5 times
slower with six workers against eight.

### Peak memory per variant (MB, median): phys_footprint peak / getrusage maxrss

| kernel | w | A | B | C | B/A footprint |
|---|--:|--:|--:|--:|--:|
| walk | 1 | 168.8 / 186 | 232.9 / 250 | 168.8 / 186 | 1.38 |
| walk | 6 | 171.5 / 189 | 235.8 / 253 | 171.5 / 189 | 1.37 |
| walkbuild | 1 | 168.8 / 186 | 233.0 / 250 | 168.8 / 186 | 1.38 |
| walkbuild | 6 | 171.5 / 189 | 235.8 / 253 | 171.6 / 189 | 1.37 |
| sends | 1 | 8.4 / 26 | 8.6 / 26 | 8.4 / 26 | 1.02 |
| sends | 6 | 11.2 / 29 | 11.7 / 29 | 11.2 / 29 | 1.04 |
| ivars | 1 | 8.4 / 26 | 8.6 / 26 | 8.5 / 26 | 1.02 |
| ivars | 6 | 11.2 / 29 | 11.7 / 29 | 11.2 / 29 | 1.04 |
| compact | 6 | 99.3 / 117 | 107.9 / 125 | 99.3 / 117 | 1.09 |
| become | 6 | 214.0 / 231 | 79.7 / 97 | 214.0 / 231 | 0.37 |

(`become`: A's clones leave the old bodies behind until the next GC, so A
peaks higher there; this is the kernel, not a representation cost.)

### become: 2^20 live objects, 10 000 two-way becomes, one bulk becomeForward of 100 000 (6 workers: 1 operating + 5 running fib; medians)

| variant | 2-way becomes | fwd path | op us/become | pause us/become | wall us/become | bulk op ms | bulk pause ms | GC before ms | GC after ms | ttsp us/stop | checksum |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|---|
| A | 10000 | 9797 | 1.542 | 11.2 | 14.5 | 1.453 | 1.508 | 7.315 | 9.542 | 9.641 | 351987991216163 |
| B | 10000 | 0 | 0.131 | 7.946 | 9.710 | 4.900 | 4.946 | 5.213 | 6.063 | 7.830 | 351987991216163 |
| C | 10000 | 9797 | 1.579 | 10.6 | 13.4 | 1.535 | 1.578 | 7.274 | 9.499 | 9.052 | 351987991216163 |

### compact: 2^21 allocated, every other one dead (6 workers: 1 operating + 5 running fib; medians)

| variant | GC mark ms | GC sweep ms | cmp mark ms | plan ms | update ms | move ms | entry sweep ms | compaction pause ms | slots updated | checksum |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|---|
| A | 5.326 | 3.710 | 4.151 | 6.074 | 3.009 | 3.662 | 0.000 | 16.6 | 2098235 | 551323236844800 |
| B | 6.404 | 1.459 | 5.380 | 0.000 | 0.000 | 4.119 | 1.374 | 11.0 | 0 | 551323236844800 |
| C | 5.103 | 3.652 | 4.262 | 5.844 | 3.644 | 3.796 | 0.000 | 17.5 | 2098231 | 551323236844800 |

## Part B: collector

4 MiB nurseries, `KAJO_GC=cm KAJO_AGE=2`, 5 interleaved runs, 1, 2 and 6
workers. `stw` is the barrier build with the stop-the-world scavenge (the
Mac matrix's `adr7b`); `adr7` the `-DNO_YOUNG_BARRIER` build, the checksum
reference. The thermal column is the worst state at the end of any run in
the row; most rows reached serious (question 5).

### Wall time, ms (median of runs), 4 MiB nurseries; checksum gate against adr7

| kernel | w | adr7 | stw | local | offload | checksums | stw/adr7 | local/stw | offload/stw | peak footprint MB (max of cfgs) | thermal end (worst) |
|---|--:|--:|--:|--:|--:|---|--:|--:|--:|--:|---|
| alloc | 1 | 1864.5 | 2069.6 | 2054.1 | 1821.2 | equal | 1.110 | 0.993 | 0.880 | 229 | serious |
| alloc | 2 | 1280.4 | 1245.8 | 1453.6 | 1549.8 | equal | 0.973 | 1.167 | 1.244 | 238 | serious |
| alloc | 6 | 965.7 | 944.7 | 910.8 | 1150.7 | equal | 0.978 | 0.964 | 1.218 | 267 | serious |
| churn | 1 | 969.5 | 1080.1 | 978.3 | 955.7 | equal | 1.114 | 0.906 | 0.885 | 26 | serious |
| churn | 2 | 603.1 | 616.7 | 627.8 | 628.6 | equal | 1.023 | 1.018 | 1.019 | 32 | serious |
| churn | 6 | 382.7 | 369.0 | 399.8 | 457.9 | equal | 0.964 | 1.083 | 1.241 | 55 | serious |
| survivors5 | 1 | 738.1 | 791.9 | 729.8 | 701.5 | equal | 1.073 | 0.922 | 0.886 | 68 | serious |
| survivors5 | 2 | 462.3 | 454.0 | 472.3 | 464.9 | equal | 0.982 | 1.040 | 1.024 | 75 | serious |
| survivors5 | 6 | 320.1 | 341.5 | 335.0 | 361.7 | equal | 1.067 | 0.981 | 1.059 | 99 | serious |
| survivors30 | 1 | 1056.3 | 1167.8 | 1055.0 | 998.1 | equal | 1.106 | 0.903 | 0.855 | 95 | serious |
| survivors30 | 2 | 655.1 | 647.1 | 721.2 | 767.3 | equal | 0.988 | 1.115 | 1.186 | 103 | serious |
| survivors30 | 6 | 509.7 | 506.6 | 531.5 | 616.6 | equal | 0.994 | 1.049 | 1.217 | 172 | serious |
| oldheap64 | 1 | 1287.7 | 1495.8 | 1317.1 | 1268.1 | equal | 1.162 | 0.881 | 0.848 | 164 | serious |
| oldheap64 | 2 | 820.8 | 782.3 | 921.1 | 953.4 | equal | 0.953 | 1.177 | 1.219 | 178 | serious |
| oldheap64 | 6 | 557.3 | 533.6 | 633.7 | 648.2 | equal | 0.957 | 1.188 | 1.215 | 272 | serious |
| oldheap256 | 1 | 6222.6 | 6246.0 | 6252.0 | 6097.1 | equal | 1.004 | 1.001 | 0.976 | 440 | serious |
| oldheap256 | 2 | 4290.8 | 4320.7 | 4404.5 | 4376.9 | equal | 1.007 | 1.019 | 1.013 | 456 | serious |
| oldheap256 | 6 | 2672.0 | 2704.8 | 2948.1 | 3126.6 | equal | 1.012 | 1.090 | 1.156 | 749 | serious |
| fragment | 1 | 774.5 | 865.6 | 807.2 | 761.7 | equal | 1.118 | 0.933 | 0.880 | 286 | serious |
| fragment | 2 | 493.1 | 507.1 | 537.4 | 527.9 | equal | 1.028 | 1.060 | 1.041 | 292 | serious |
| fragment | 6 | 337.4 | 336.0 | 385.4 | 409.7 | equal | 0.996 | 1.147 | 1.219 | 334 | serious |
| storeheavy | 1 | 1327.6 | 1573.8 | 1316.9 | 1330.2 | equal | 1.185 | 0.837 | 0.845 | 20 | serious |
| storeheavy | 2 | 830.4 | 857.5 | 832.1 | 832.9 | equal | 1.033 | 0.970 | 0.971 | 20 | serious |
| storeheavy | 6 | 448.7 | 431.6 | 476.4 | 477.8 | equal | 0.962 | 1.104 | 1.107 | 21 | serious |
| ivars | 1 | 1063.3 | 1227.2 | 1062.2 | 1060.9 | equal | 1.154 | 0.866 | 0.864 | 20 | serious |
| ivars | 2 | 671.8 | 658.1 | 656.4 | 654.3 | equal | 0.980 | 0.997 | 0.994 | 20 | serious |
| ivars | 6 | 378.7 | 391.2 | 417.5 | 434.0 | equal | 1.033 | 1.067 | 1.109 | 21 | serious |
| sends | 1 | 1421.0 | 1555.4 | 1372.8 | 1421.2 | equal | 1.095 | 0.883 | 0.914 | 20 | serious |
| sends | 2 | 880.8 | 856.8 | 862.7 | 874.3 | equal | 0.973 | 1.007 | 1.020 | 20 | serious |
| sends | 6 | 500.3 | 506.4 | 563.3 | 583.5 | equal | 1.012 | 1.112 | 1.152 | 21 | serious |
| fib | 1 | 900.1 | 1031.5 | 899.4 | 908.3 | equal | 1.146 | 0.872 | 0.881 | 20 | serious |
| fib | 2 | 570.0 | 552.1 | 558.7 | 566.0 | equal | 0.969 | 1.012 | 1.025 | 20 | serious |
| fib | 6 | 336.3 | 347.9 | 338.1 | 343.2 | equal | 1.034 | 0.972 | 0.986 | 20 | serious |
| arith | 1 | 1354.4 | 1402.3 | 1387.8 | 1428.9 | equal | 1.035 | 0.990 | 1.019 | 20 | serious |
| arith | 2 | 889.9 | 920.9 | 877.1 | 907.9 | equal | 1.035 | 0.952 | 0.986 | 20 | serious |
| arith | 6 | 576.9 | 539.2 | 608.4 | 570.4 | equal | 0.935 | 1.128 | 1.058 | 20 | serious |

### Pauses (ms, p50 / p99 / max)

adr7: the stop-the-world scavenge (every worker stopped). local: the owner's whole collection. offload: the flip.

| kernel | w | adr7 scavenge | adr7 ttsp | local own | offload flip | local hs latency | offload hs latency | local eden wait max | offload coll waits (n, ms) | offload collector busy % |
|---|--:|---|---|---|---|---|---|--:|---|--:|
| alloc | 1 | 1.583 / 2.071 / 6.316 | 0.000 / 0.019 / 0.027 | 2.032 / 2.345 / 6.264 | 0.064 / 0.083 / 0.549 | 0.000 / 0.003 / 0.017 | 0.003 / 0.014 / 0.515 | 0.006 | 0, 0.0 | 59.7 |
| alloc | 2 | 2.124 / 3.098 / 22.110 | 0.008 / 0.024 / 20.819 | 3.029 / 3.465 / 20.881 | 0.080 / 0.132 / 0.538 | 0.005 / 0.045 / 6.844 | 0.012 / 0.098 / 4.277 | 10.029 | 84, 65.5 | 90.0 |
| alloc | 6 | 3.489 / 6.718 / 13.316 | 0.065 / 0.118 / 0.222 | 3.579 / 9.868 / 15.227 | 0.070 / 0.132 / 1.491 | 0.035 / 1.313 / 8.211 | 0.043 / 0.248 / 3.940 | 10.018 | 440, 1835.0 | 96.0 |
| churn | 1 | 0.015 / 0.025 / 0.493 | 0.000 / 0.000 / 0.003 | 0.080 / 0.139 / 0.308 | 0.004 / 0.015 / 0.194 | 0.000 / 0.001 / 0.003 | 0.002 / 0.013 / 0.594 | 0.005 | 0, 0.0 | 3.8 |
| churn | 2 | 0.033 / 0.072 / 0.659 | 0.006 / 0.015 / 0.171 | 0.145 / 0.430 / 10.484 | 0.011 / 0.040 / 0.378 | 0.004 / 0.022 / 7.045 | 0.007 / 0.049 / 2.898 | 10.010 | 2, 0.4 | 10.0 |
| churn | 6 | 0.144 / 0.249 / 0.331 | 0.058 / 0.097 / 0.182 | 0.431 / 3.705 / 7.207 | 0.004 / 0.032 / 1.319 | 0.036 / 0.786 / 4.377 | 0.036 / 0.095 / 2.886 | 5.709 | 87, 95.2 | 80.9 |
| survivors5 | 1 | 0.282 / 0.447 / 1.651 | 0.000 / 0.000 / 0.005 | 0.479 / 0.596 / 0.905 | 0.017 / 0.027 / 0.043 | 0.000 / 0.001 / 0.003 | 0.003 / 0.014 / 0.130 | 0.006 | 0, 0.0 | 10.7 |
| survivors5 | 2 | 0.485 / 0.734 / 1.852 | 0.006 / 0.014 / 0.027 | 0.668 / 1.078 / 1.947 | 0.023 / 0.054 / 1.466 | 0.004 / 0.024 / 0.376 | 0.013 / 0.043 / 3.876 | 0.218 | 0, 0.0 | 22.0 |
| survivors5 | 6 | 1.400 / 9.492 / 12.207 | 0.047 / 0.088 / 0.096 | 1.854 / 8.063 / 19.108 | 0.015 / 0.068 / 1.857 | 0.036 / 1.325 / 12.490 | 0.034 / 0.113 / 6.014 | 13.327 | 39, 62.2 | 86.5 |
| survivors30 | 1 | 0.784 / 1.044 / 1.189 | 0.000 / 0.003 / 0.006 | 1.173 / 1.428 / 2.444 | 0.051 / 0.073 / 0.359 | 0.000 / 0.001 / 0.040 | 0.003 / 0.016 / 3.085 | 0.006 | 0, 0.0 | 23.3 |
| survivors30 | 2 | 1.188 / 1.666 / 2.262 | 0.007 / 0.016 / 0.054 | 1.741 / 3.186 / 5.296 | 0.068 / 0.121 / 0.175 | 0.006 / 0.660 / 0.935 | 0.013 / 0.046 / 0.706 | 0.847 | 0, 0.0 | 41.2 |
| survivors30 | 6 | 3.171 / 10.152 / 12.700 | 0.064 / 0.115 / 0.140 | 3.930 / 10.495 / 13.988 | 0.069 / 0.225 / 2.197 | 0.043 / 1.309 / 7.835 | 0.045 / 0.242 / 4.452 | 10.048 | 154, 419.9 | 96.2 |
| oldheap64 | 1 | 0.255 / 1.001 / 4.414 | 0.000 / 0.011 / 0.383 | 0.357 / 1.124 / 3.146 | 0.011 / 0.021 / 0.356 | 0.000 / 0.005 / 0.011 | 0.002 / 0.016 / 0.450 | 0.006 | 0, 0.0 | 8.2 |
| oldheap64 | 2 | 0.385 / 1.113 / 10.978 | 0.007 / 0.017 / 0.695 | 0.571 / 1.560 / 13.671 | 0.020 / 0.055 / 0.226 | 0.005 / 0.035 / 9.340 | 0.014 / 0.045 / 5.885 | 10.031 | 9, 2.2 | 17.6 |
| oldheap64 | 6 | 1.036 / 10.998 / 14.548 | 0.065 / 0.203 / 0.568 | 1.598 / 10.148 / 21.066 | 0.014 / 0.067 / 5.522 | 0.039 / 2.373 / 10.679 | 0.040 / 0.124 / 2.530 | 10.025 | 75, 202.8 | 76.4 |
| oldheap256 | 1 | 0.263 / 0.890 / 3.916 | 0.000 / 0.017 / 0.834 | 0.366 / 1.064 / 4.870 | 0.011 / 0.018 / 0.087 | 0.000 / 0.004 / 0.017 | 0.003 / 0.010 / 0.578 | 0.006 | 1, 0.0 | 6.9 |
| oldheap256 | 2 | 0.441 / 1.397 / 10.006 | 0.009 / 0.030 / 1.023 | 0.584 / 1.517 / 8.670 | 0.020 / 0.060 / 2.617 | 0.005 / 0.030 / 2.268 | 0.016 / 0.042 / 6.029 | 1.071 | 27, 11.1 | 14.7 |
| oldheap256 | 6 | 1.079 / 8.994 / 13.912 | 0.080 / 0.215 / 1.155 | 1.994 / 11.194 / 22.822 | 0.018 / 0.318 / 6.039 | 0.045 / 1.287 / 9.942 | 0.049 / 0.138 / 9.111 | 13.704 | 383, 1089.5 | 79.3 |
| fragment | 1 | 0.523 / 0.746 / 2.570 | 0.000 / 0.042 / 0.121 | 0.656 / 1.055 / 3.549 | 0.016 / 0.030 / 0.593 | 0.000 / 0.003 / 0.006 | 0.003 / 0.014 / 0.511 | 0.006 | 0, 0.0 | 16.3 |
| fragment | 2 | 0.738 / 1.294 / 9.066 | 0.007 / 0.040 / 1.712 | 1.179 / 2.545 / 14.512 | 0.022 / 0.054 / 3.153 | 0.005 / 0.444 / 6.143 | 0.012 / 0.055 / 4.252 | 10.009 | 0, 0.0 | 31.2 |
| fragment | 6 | 1.877 / 7.438 / 11.392 | 0.051 / 0.108 / 0.191 | 2.780 / 7.849 / 20.538 | 0.020 / 0.173 / 2.443 | 0.042 / 1.628 / 9.047 | 0.038 / 0.124 / 3.728 | 10.024 | 106, 161.5 | 93.9 |
| storeheavy | 1 | - | - | 0.000 / 0.000 / 0.000 | 0.000 / 0.000 / 0.000 | 0.000 / 0.000 / 0.000 | 0.000 / 0.000 / 0.000 | 0.000 | 0, 0.0 | 0.0 |
| storeheavy | 2 | - | - | 0.000 / 0.000 / 0.000 | 0.000 / 0.000 / 0.000 | 0.000 / 0.000 / 0.000 | 0.000 / 0.000 / 0.000 | 0.000 | 0, 0.0 | 0.0 |
| storeheavy | 6 | - | - | 0.000 / 0.000 / 0.000 | 0.000 / 0.000 / 0.000 | 0.000 / 0.000 / 0.000 | 0.000 / 0.000 / 0.000 | 0.000 | 0, 0.0 | 0.0 |

### Collection activity (medians), 4 MiB

| kernel | w | cfg | collections | promoted MB/s | fallbacks (sum over runs) | initial mark p50 / max ms | marking % | old MB end | peak footprint MB |
|---|--:|---|--:|--:|--:|---|--:|--:|--:|
| alloc | 1 | adr7 | 320 | 398 | 0 | 1.745 / 2.137 | 1.1 | 37.4 | 194 |
| alloc | 1 | local | 320 | 361 | 0 | 0.160 / 0.201 | 1.2 | 37.4 | 229 |
| alloc | 1 | offload | 640 | 527 | 0 | 0.191 / 0.255 | 1.7 | 23.7 | 100 |
| alloc | 2 | adr7 | 161 | 295 | 0 | 2.757 / 3.593 | 1.1 | 29.6 | 185 |
| alloc | 2 | local | 320 | 510 | 0 | 0.617 / 1.071 | 5.2 | 12.2 | 230 |
| alloc | 2 | offload | 640 | 609 | 0 | 0.797 / 1.164 | 4.5 | 12.0 | 126 |
| alloc | 6 | adr7 | 72 | 687 | 51 | 4.885 / 10.178 | 3.4 | 23.3 | 192 |
| alloc | 6 | local | 312 | 444 | 15 | 2.452 / 4.459 | 14.8 | 31.2 | 217 |
| alloc | 6 | offload | 635 | 331 | 2 | 2.997 / 4.066 | 13.7 | 31.2 | 254 |
| churn | 1 | adr7 | 244 | 0 | 0 | 0.000 / 0.000 | 0.0 | 0.1 | 26 |
| churn | 1 | local | 244 | 0 | 0 | 0.000 / 0.000 | 0.0 | 0.0 | 26 |
| churn | 1 | offload | 488 | 0 | 0 | 0.000 / 0.000 | 0.0 | 0.0 | 26 |
| churn | 2 | adr7 | 124 | 0 | 0 | 0.000 / 0.000 | 0.0 | 0.1 | 31 |
| churn | 2 | local | 244 | 0 | 0 | 0.000 / 0.000 | 0.0 | 0.0 | 32 |
| churn | 2 | offload | 488 | 0 | 0 | 0.000 / 0.000 | 0.0 | 0.0 | 32 |
| churn | 6 | adr7 | 67 | 0 | 0 | 0.000 / 0.000 | 0.0 | 0.2 | 50 |
| churn | 6 | local | 240 | 0 | 0 | 0.000 / 0.000 | 0.0 | 0.0 | 55 |
| churn | 6 | offload | 486 | 0 | 0 | 0.000 / 0.000 | 0.0 | 0.0 | 55 |
| survivors5 | 1 | adr7 | 124 | 34 | 0 | 0.000 / 0.000 | 0.0 | 24.9 | 64 |
| survivors5 | 1 | local | 124 | 34 | 0 | 0.000 / 0.000 | 0.0 | 24.9 | 68 |
| survivors5 | 1 | offload | 248 | 35 | 0 | 0.000 / 0.000 | 0.0 | 25.0 | 68 |
| survivors5 | 2 | adr7 | 63 | 53 | 0 | 0.000 / 0.000 | 0.0 | 24.5 | 70 |
| survivors5 | 2 | local | 124 | 52 | 0 | 0.000 / 0.000 | 0.0 | 24.5 | 74 |
| survivors5 | 2 | offload | 248 | 54 | 0 | 0.000 / 0.000 | 0.0 | 25.4 | 75 |
| survivors5 | 6 | adr7 | 33 | 75 | 0 | 0.000 / 0.000 | 0.0 | 24.2 | 93 |
| survivors5 | 6 | local | 120 | 69 | 0 | 0.000 / 0.000 | 0.0 | 23.1 | 99 |
| survivors5 | 6 | offload | 246 | 67 | 0 | 0.000 / 0.000 | 0.0 | 24.1 | 98 |
| survivors30 | 1 | adr7 | 134 | 139 | 0 | 0.800 / 1.081 | 0.1 | 31.7 | 90 |
| survivors30 | 1 | local | 134 | 139 | 0 | 0.074 / 0.234 | 0.2 | 31.7 | 94 |
| survivors30 | 1 | offload | 269 | 147 | 0 | 0.103 / 0.213 | 0.1 | 32.5 | 95 |
| survivors30 | 2 | adr7 | 69 | 222 | 0 | 1.194 / 2.163 | 0.7 | 36.3 | 97 |
| survivors30 | 2 | local | 134 | 203 | 0 | 0.266 / 0.676 | 1.2 | 37.7 | 103 |
| survivors30 | 2 | offload | 268 | 190 | 0 | 0.354 / 0.536 | 0.7 | 35.7 | 103 |
| survivors30 | 6 | adr7 | 30 | 284 | 10 | 3.942 / 5.114 | 7.6 | 27.2 | 168 |
| survivors30 | 6 | local | 132 | 262 | 0 | 1.815 / 2.560 | 19.7 | 33.8 | 154 |
| survivors30 | 6 | offload | 270 | 235 | 1 | 2.018 / 2.837 | 17.9 | 35.3 | 152 |
| oldheap64 | 1 | adr7 | 184 | 144 | 0 | 0.407 / 0.439 | 2.7 | 82.8 | 162 |
| oldheap64 | 1 | local | 184 | 141 | 0 | 0.154 / 0.169 | 6.3 | 82.8 | 164 |
| oldheap64 | 1 | offload | 368 | 146 | 0 | 0.132 / 0.139 | 6.3 | 83.1 | 164 |
| oldheap64 | 2 | adr7 | 93 | 225 | 0 | 0.696 / 0.707 | 4.5 | 80.1 | 172 |
| oldheap64 | 2 | local | 184 | 201 | 0 | 0.608 / 0.779 | 8.8 | 80.3 | 171 |
| oldheap64 | 2 | offload | 368 | 194 | 0 | 0.311 / 0.522 | 8.4 | 81.6 | 172 |
| oldheap64 | 6 | adr7 | 42 | 333 | 0 | 1.880 / 3.480 | 53.2 | 133.2 | 269 |
| oldheap64 | 6 | local | 180 | 284 | 0 | 2.134 / 2.553 | 69.4 | 124.8 | 237 |
| oldheap64 | 6 | offload | 366 | 282 | 0 | 1.772 / 2.173 | 60.1 | 72.8 | 238 |
| oldheap256 | 1 | adr7 | 736 | 120 | 0 | 0.364 / 0.483 | 5.6 | 299.6 | 435 |
| oldheap256 | 1 | local | 736 | 119 | 0 | 0.092 / 0.536 | 7.4 | 299.6 | 438 |
| oldheap256 | 1 | offload | 1472 | 122 | 0 | 0.077 / 0.168 | 7.5 | 298.8 | 439 |
| oldheap256 | 2 | adr7 | 372 | 173 | 0 | 0.729 / 0.816 | 8.8 | 296.6 | 448 |
| oldheap256 | 2 | local | 736 | 169 | 0 | 0.545 / 0.781 | 11.2 | 294.4 | 448 |
| oldheap256 | 2 | offload | 1472 | 170 | 0 | 0.266 / 0.529 | 10.9 | 296.4 | 449 |
| oldheap256 | 6 | adr7 | 153 | 278 | 5 | 2.180 / 5.528 | 24.4 | 421.1 | 742 |
| oldheap256 | 6 | local | 733 | 251 | 0 | 2.603 / 4.077 | 96.7 | 426.0 | 678 |
| oldheap256 | 6 | offload | 1469 | 237 | 3 | 1.747 / 2.307 | 27.7 | 419.8 | 747 |
| fragment | 1 | adr7 | 137 | 295 | 0 | 0.591 / 0.768 | 28.0 | 228.9 | 280 |
| fragment | 1 | local | 137 | 283 | 0 | 0.061 / 0.133 | 75.1 | 228.9 | 285 |
| fragment | 1 | offload | 275 | 301 | 0 | 0.086 / 0.170 | 82.2 | 229.8 | 286 |
| fragment | 2 | adr7 | 69 | 460 | 0 | 0.880 / 1.074 | 29.3 | 227.4 | 285 |
| fragment | 2 | local | 136 | 421 | 0 | 0.147 / 0.405 | 72.6 | 227.1 | 291 |
| fragment | 2 | offload | 274 | 432 | 0 | 0.287 / 0.381 | 82.1 | 228.5 | 292 |
| fragment | 6 | adr7 | 36 | 670 | 0 | 2.209 / 2.759 | 37.6 | 231.3 | 323 |
| fragment | 6 | local | 138 | 583 | 0 | 1.661 / 2.643 | 84.5 | 229.2 | 325 |
| fragment | 6 | offload | 276 | 557 | 0 | 1.915 / 2.020 | 73.7 | 228.9 | 323 |
| storeheavy | 1 | adr7 | 0 | 0 | 0 | 0.000 / 0.000 | 0.0 | 0.0 | 20 |
| storeheavy | 1 | local | 0 | 0 | 0 | 0.000 / 0.000 | 0.0 | 0.0 | 20 |
| storeheavy | 1 | offload | 0 | 0 | 0 | 0.000 / 0.000 | 0.0 | 0.0 | 20 |
| storeheavy | 2 | adr7 | 0 | 0 | 0 | 0.000 / 0.000 | 0.0 | 0.0 | 20 |
| storeheavy | 2 | local | 0 | 0 | 0 | 0.000 / 0.000 | 0.0 | 0.0 | 20 |
| storeheavy | 2 | offload | 0 | 0 | 0 | 0.000 / 0.000 | 0.0 | 0.0 | 20 |
| storeheavy | 6 | adr7 | 0 | 0 | 0 | 0.000 / 0.000 | 0.0 | 0.0 | 21 |
| storeheavy | 6 | local | 0 | 0 | 0 | 0.000 / 0.000 | 0.0 | 0.0 | 21 |
| storeheavy | 6 | offload | 0 | 0 | 0 | 0.000 / 0.000 | 0.0 | 0.0 | 21 |

### QoS: collector (offload) and marker thread QoS, 2 and 6 workers (medians)

Defaults (main matrix): collector user-initiated, marker utility. `_ycu`: collector utility. `_cmh`: marker user-initiated.

| kernel | w | cfg | ms | vs default | collector busy % | coll waits (n, ms) | fallbacks (sum) | marking % | initial p50 ms | flip/own p99 ms | checksum vs adr7 |
|---|--:|---|--:|--:|--:|---|--:|--:|--:|--:|---|
| alloc | 2 | offload | 1549.8 | - | 90.0 | 84, 65.5 | 0 | 4.5 | 0.797 | 0.132 | equal |
| alloc | 2 | offload_ycu | 2171.4 | 1.401 | 98.3 | 635, 2541.8 | 0 | 5.2 | 1.383 | 0.100 | equal |
| alloc | 2 | offload_cmh | 1714.7 | 1.106 | 91.3 | 142, 142.1 | 0 | 3.9 | 0.941 | 0.148 | equal |
| alloc | 2 | local | 1453.6 | - | 0.0 | 0, 0.0 | 0 | 5.2 | 0.617 | 3.465 | equal |
| alloc | 2 | local_cmh | 1367.6 | 0.941 | 0.0 | 0, 0.0 | 0 | 2.2 | 0.685 | 3.585 | equal |
| alloc | 6 | offload | 1150.7 | - | 96.0 | 440, 1835.0 | 2 | 13.7 | 2.997 | 0.132 | equal |
| alloc | 6 | offload_ycu | 1588.6 | 1.381 | 92.3 | 622, 5815.2 | 0 | 9.5 | 2.684 | 0.121 | equal |
| alloc | 6 | offload_cmh | 1334.5 | 1.160 | 95.8 | 488, 2461.0 | 0 | 11.2 | 3.550 | 0.177 | equal |
| alloc | 6 | local | 910.8 | - | 0.0 | 0, 0.0 | 15 | 14.8 | 2.452 | 9.868 | equal |
| alloc | 6 | local_cmh | 1048.2 | 1.151 | 0.0 | 0, 0.0 | 0 | 21.1 | 2.835 | 10.887 | equal |
| churn | 2 | offload | 628.6 | - | 10.0 | 2, 0.4 | 0 | 0.0 | 0.000 | 0.040 | equal |
| churn | 2 | offload_ycu | 765.9 | 1.218 | 22.5 | 7, 26.3 | 0 | 0.0 | 0.000 | 0.012 | equal |
| churn | 2 | offload_cmh | 661.0 | 1.052 | 9.9 | 0, 0.0 | 0 | 0.0 | 0.000 | 0.043 | equal |
| churn | 2 | local | 627.8 | - | 0.0 | 0, 0.0 | 0 | 0.0 | 0.000 | 0.430 | equal |
| churn | 2 | local_cmh | 656.9 | 1.046 | 0.0 | 0, 0.0 | 0 | 0.0 | 0.000 | 0.291 | equal |
| churn | 6 | offload | 457.9 | - | 80.9 | 87, 95.2 | 0 | 0.0 | 0.000 | 0.032 | equal |
| churn | 6 | offload_ycu | 565.2 | 1.234 | 79.2 | 473, 911.4 | 0 | 0.0 | 0.000 | 0.031 | equal |
| churn | 6 | offload_cmh | 492.4 | 1.075 | 72.6 | 34, 33.9 | 0 | 0.0 | 0.000 | 0.030 | equal |
| churn | 6 | local | 399.8 | - | 0.0 | 0, 0.0 | 0 | 0.0 | 0.000 | 3.705 | equal |
| churn | 6 | local_cmh | 443.9 | 1.110 | 0.0 | 0, 0.0 | 0 | 0.0 | 0.000 | 5.486 | equal |
| survivors5 | 2 | offload | 464.9 | - | 22.0 | 0, 0.0 | 0 | 0.0 | 0.000 | 0.054 | equal |
| survivors5 | 2 | offload_ycu | 554.3 | 1.192 | 50.9 | 3, 4.6 | 0 | 0.0 | 0.000 | 0.031 | equal |
| survivors5 | 2 | offload_cmh | 486.0 | 1.045 | 21.9 | 0, 0.0 | 0 | 0.0 | 0.000 | 0.060 | equal |
| survivors5 | 2 | local | 472.3 | - | 0.0 | 0, 0.0 | 0 | 0.0 | 0.000 | 1.078 | equal |
| survivors5 | 2 | local_cmh | 507.8 | 1.075 | 0.0 | 0, 0.0 | 0 | 0.0 | 0.000 | 1.464 | equal |
| survivors5 | 6 | offload | 361.7 | - | 86.5 | 39, 62.2 | 0 | 0.0 | 0.000 | 0.068 | equal |
| survivors5 | 6 | offload_ycu | 440.7 | 1.218 | 93.2 | 240, 1115.3 | 0 | 0.0 | 0.000 | 0.064 | equal |
| survivors5 | 6 | offload_cmh | 369.7 | 1.022 | 83.5 | 30, 45.7 | 0 | 0.0 | 0.000 | 0.050 | equal |
| survivors5 | 6 | local | 335.0 | - | 0.0 | 0, 0.0 | 0 | 0.0 | 0.000 | 8.063 | equal |
| survivors5 | 6 | local_cmh | 341.4 | 1.019 | 0.0 | 0, 0.0 | 0 | 0.0 | 0.000 | 5.959 | equal |
| survivors30 | 2 | offload | 767.3 | - | 41.2 | 0, 0.0 | 0 | 0.7 | 0.354 | 0.121 | equal |
| survivors30 | 2 | offload_ycu | 840.0 | 1.095 | 91.4 | 105, 149.9 | 0 | 3.9 | 1.305 | 0.097 | equal |
| survivors30 | 2 | offload_cmh | 788.0 | 1.027 | 42.2 | 0, 0.0 | 0 | 0.5 | 0.391 | 0.122 | equal |
| survivors30 | 2 | local | 721.2 | - | 0.0 | 0, 0.0 | 0 | 1.2 | 0.266 | 3.186 | equal |
| survivors30 | 2 | local_cmh | 818.8 | 1.135 | 0.0 | 0, 0.0 | 0 | 0.6 | 0.298 | 3.554 | equal |
| survivors30 | 6 | offload | 616.6 | - | 96.2 | 154, 419.9 | 1 | 17.9 | 2.018 | 0.225 | equal |
| survivors30 | 6 | offload_ycu | 995.4 | 1.614 | 92.3 | 262, 3531.4 | 0 | 17.7 | 2.080 | 0.117 | equal |
| survivors30 | 6 | offload_cmh | 624.2 | 1.012 | 96.1 | 161, 455.0 | 0 | 12.9 | 2.094 | 0.152 | equal |
| survivors30 | 6 | local | 531.5 | - | 0.0 | 0, 0.0 | 0 | 19.7 | 1.815 | 10.495 | equal |
| survivors30 | 6 | local_cmh | 514.2 | 0.967 | 0.0 | 0, 0.0 | 0 | 3.4 | 2.033 | 9.962 | equal |
| oldheap64 | 2 | offload | 953.4 | - | 17.6 | 9, 2.2 | 0 | 8.4 | 0.311 | 0.055 | equal |
| oldheap64 | 2 | offload_ycu | 1022.9 | 1.073 | 32.2 | 40, 109.1 | 0 | 8.3 | 0.552 | 0.025 | equal |
| oldheap64 | 2 | offload_cmh | 936.4 | 0.982 | 17.3 | 6, 4.1 | 0 | 5.6 | 0.356 | 0.052 | equal |
| oldheap64 | 2 | local | 921.1 | - | 0.0 | 0, 0.0 | 0 | 8.8 | 0.608 | 1.560 | equal |
| oldheap64 | 2 | local_cmh | 944.3 | 1.025 | 0.0 | 0, 0.0 | 0 | 5.8 | 0.693 | 1.724 | equal |
| oldheap64 | 6 | offload | 648.2 | - | 76.4 | 75, 202.8 | 0 | 60.1 | 1.772 | 0.067 | equal |
| oldheap64 | 6 | offload_ycu | 732.4 | 1.130 | 75.2 | 345, 1294.2 | 0 | 40.2 | 2.255 | 0.045 | equal |
| oldheap64 | 6 | offload_cmh | 681.3 | 1.051 | 74.1 | 47, 193.0 | 0 | 12.2 | 1.341 | 0.085 | equal |
| oldheap64 | 6 | local | 633.7 | - | 0.0 | 0, 0.0 | 0 | 69.4 | 2.134 | 10.148 | equal |
| oldheap64 | 6 | local_cmh | 601.9 | 0.950 | 0.0 | 0, 0.0 | 0 | 9.7 | 2.354 | 6.832 | equal |
| oldheap256 | 2 | offload | 4376.9 | - | 14.7 | 27, 11.1 | 0 | 10.9 | 0.266 | 0.060 | equal |
| oldheap256 | 2 | offload_ycu | 4739.7 | 1.083 | 27.1 | 172, 488.1 | 0 | 10.7 | 0.461 | 0.024 | equal |
| oldheap256 | 2 | offload_cmh | 4537.8 | 1.037 | 14.2 | 24, 6.2 | 0 | 7.6 | 0.277 | 0.059 | equal |
| oldheap256 | 2 | local | 4404.5 | - | 0.0 | 0, 0.0 | 0 | 11.2 | 0.545 | 1.517 | equal |
| oldheap256 | 2 | local_cmh | 4449.4 | 1.010 | 0.0 | 0, 0.0 | 0 | 7.8 | 0.580 | 1.592 | equal |
| oldheap256 | 6 | offload | 3126.6 | - | 79.3 | 383, 1089.5 | 3 | 27.7 | 1.747 | 0.318 | equal |
| oldheap256 | 6 | offload_ycu | 3682.0 | 1.178 | 68.7 | 1409, 6167.2 | 0 | 49.7 | 2.586 | 0.051 | equal |
| oldheap256 | 6 | offload_cmh | 3113.6 | 0.996 | 73.0 | 262, 917.1 | 0 | 16.0 | 1.803 | 0.079 | equal |
| oldheap256 | 6 | local | 2948.1 | - | 0.0 | 0, 0.0 | 0 | 96.7 | 2.603 | 11.194 | equal |
| oldheap256 | 6 | local_cmh | 2859.5 | 0.970 | 0.0 | 0, 0.0 | 0 | 16.4 | 2.722 | 8.654 | equal |
| fragment | 2 | offload | 527.9 | - | 31.2 | 0, 0.0 | 0 | 82.1 | 0.287 | 0.054 | equal |
| fragment | 2 | offload_ycu | 664.5 | 1.259 | 83.1 | 100, 98.9 | 0 | 80.2 | 0.518 | 0.033 | equal |
| fragment | 2 | offload_cmh | 576.8 | 1.093 | 28.9 | 0, 0.0 | 0 | 73.5 | 0.293 | 0.063 | equal |
| fragment | 2 | local | 537.4 | - | 0.0 | 0, 0.0 | 0 | 72.6 | 0.147 | 2.545 | equal |
| fragment | 2 | local_cmh | 596.3 | 1.110 | 0.0 | 0, 0.0 | 0 | 64.9 | 0.331 | 2.368 | equal |
| fragment | 6 | offload | 409.7 | - | 93.9 | 106, 161.5 | 0 | 73.7 | 1.915 | 0.173 | equal |
| fragment | 6 | offload_ycu | 635.9 | 1.552 | 90.4 | 269, 2196.2 | 0 | 56.6 | 1.649 | 0.061 | equal |
| fragment | 6 | offload_cmh | 439.7 | 1.073 | 93.4 | 105, 156.5 | 0 | 56.3 | 1.437 | 0.068 | equal |
| fragment | 6 | local | 385.4 | - | 0.0 | 0, 0.0 | 0 | 84.5 | 1.661 | 7.849 | equal |
| fragment | 6 | local_cmh | 396.8 | 1.030 | 0.0 | 0, 0.0 | 0 | 64.3 | 1.298 | 6.372 | equal |
| storeheavy | 2 | offload | 832.9 | - | 0.0 | 0, 0.0 | 0 | 0.0 | 0.000 | 0.000 | equal |
| storeheavy | 2 | offload_ycu | 991.2 | 1.190 | 0.0 | 0, 0.0 | 0 | 0.0 | 0.000 | 0.000 | equal |
| storeheavy | 2 | offload_cmh | 948.1 | 1.138 | 0.0 | 0, 0.0 | 0 | 0.0 | 0.000 | 0.000 | equal |
| storeheavy | 2 | local | 832.1 | - | 0.0 | 0, 0.0 | 0 | 0.0 | 0.000 | 0.000 | equal |
| storeheavy | 2 | local_cmh | 1002.7 | 1.205 | 0.0 | 0, 0.0 | 0 | 0.0 | 0.000 | 0.000 | equal |
| storeheavy | 6 | offload | 477.8 | - | 0.0 | 0, 0.0 | 0 | 0.0 | 0.000 | 0.000 | equal |
| storeheavy | 6 | offload_ycu | 455.7 | 0.954 | 0.0 | 0, 0.0 | 0 | 0.0 | 0.000 | 0.000 | equal |
| storeheavy | 6 | offload_cmh | 502.1 | 1.051 | 0.0 | 0, 0.0 | 0 | 0.0 | 0.000 | 0.000 | equal |
| storeheavy | 6 | local | 476.4 | - | 0.0 | 0, 0.0 | 0 | 0.0 | 0.000 | 0.000 | equal |
| storeheavy | 6 | local_cmh | 492.1 | 1.033 | 0.0 | 0, 0.0 | 0 | 0.0 | 0.000 | 0.000 | equal |

The QoS rows ran at thermal serious, the default rows partly at fair; the
"vs default" ratio is therefore biased against the QoS variants by a few
percent. The effects that matter (collector waits up 3 to 18 times at
utility; marking cycles 1.4 to 11 times shorter with a user-initiated marker,
10 times on the old heaps at six workers)
are far outside that.

### Run-order check: 1 worker, stw against adr7 (median ms of 3)

| kernel | adr7 first: adr7 / stw | stw first: stw / adr7 | right after a 6-worker offload run: stw / adr7 |
|---|---|---|---|
| fib | 862.2 / 866.5 | 864.3 / 845.5 | 871.0 / 859.9 |
| ivars | 1006.7 / 1008.2 | 1011.1 / 1008.2 | 1015.9 / 1013.1 |
| alloc | 1795.3 / 1806.8 | 1810.5 / 1813.7 | 1835.6 / 1844.4 |

## Part C: scenarios

10 s after 1 s warm-up, 3 runs, 5 background workers (the Mac used 7 on 12
cores; the phone has 6). D0 = Y0 idle, D1 = Y1 storm under the
stop-the-world scavenge, D2 = Y2 storm local, D3 = Y3 storm offload, D4 =
Y4l fragmentation ring local, D5 = Y5o heavy main-thread allocation offload.
The first pass ran straight after Part B, the phone at thermal state
serious; the second after it had cooled to nominal (it warmed to fair
within the first scenarios). Phone awake, app in the foreground, launched
by `devicectl`; nothing in the frame records suggests an interruption (no
gap over 100 ms in any run; the worst, 98 ms, is a stop-the-world storm
run at thermal serious).

### Part C again after cooling to nominal (median run by missed120, then max gap; 10 s at 120 Hz)

| id | Mac id | young | delivered Hz | frames | missed120 | max gap ms | cb late p99 ms | **main stopped because another worker allocated, ms** | main own n / ms / max | main acks other n / ms | main old-space stops (n, ms) | stw pauses (kind n p50/max ms) | thermal start/end | peak footprint MB |
|---|---|---|--:|--:|--:|--:|--:|--:|---|---|---|---|---|--:|
| D0 | Y0 | offload | 120 | 1200 | 0 | 8.37 | -0.87 | **0.00** | 0 / 0.00 / 0.000 | 0 / 0.00 | - | - | fair/fair | 26 |
| D1 | Y1 | stw | 120 | 1198 | 1 | 16.67 | 2.89 | **107.68** | 0 / 0.00 / 0.000 | 0 / 0.00 | scav 39, 107.68; initial 13, 52.21; final 27, 1.83; fallback 3, 18.40 | scav 826 2.81/4.05; initial 336 3.84/5.10; final 337 0.06/0.12; fallback 39 6.14/8.38 | fair/fair | 229 |
| D2 | Y2 | local | 120 | 1200 | 0 | 8.37 | 0.40 | **24.81** | 0 / 0.00 / 0.000 | 1040 / 24.81 | initial 25, 49.44; final 25, 2.15; apply 39, 4.80 | initial 325 1.84/2.86; final 325 0.07/0.20; apply 324 0.08/0.15; fallback 5 7.09/8.20 | fair/fair | 344 |
| D3 | Y3 | offload | 120 | 1200 | 0 | 8.34 | 0.42 | **28.67** | 0 / 0.00 / 0.000 | 1315 / 28.67 | initial 6, 13.42; final 5, 0.64; apply 6, 0.99 | initial 165 2.10/2.39; final 165 0.06/0.12; apply 166 0.08/0.16 | fair/fair | 422 |
| D4 | Y4l | local | 120 | 1200 | 0 | 8.34 | -0.67 | **1.62** | 0 / 0.00 / 0.000 | 130 / 1.62 | - | initial 3 5.80/6.65; final 3 0.04/0.08; apply 3 0.05/0.05 | fair/fair | 250 |
| D5 | Y5o | offload | 120 | 1200 | 0 | 8.37 | -0.45 | **0.02** | 613 / 4.68 / 0.017 | 0 / 0.00 | - | - | fair/fair | 28 |

#### All runs: missed120 / max gap ms / main stopped for others ms / thermal end

- D0: 0 / 8.4 / 0.0 / nominal, 0 / 8.4 / 0.0 / fair, 0 / 8.4 / 0.0 / fair
- D1: 1 / 16.7 / 96.0 / nominal, 0 / 8.4 / 75.5 / fair, 1 / 16.7 / 107.7 / fair
- D2: 0 / 8.3 / 18.7 / nominal, 0 / 8.4 / 24.8 / fair, 1 / 16.7 / 24.2 / fair
- D3: 0 / 8.3 / 27.3 / nominal, 0 / 8.3 / 28.7 / fair, 0 / 8.3 / 25.6 / fair
- D4: 0 / 8.3 / 1.6 / fair, 0 / 8.3 / 1.6 / fair, 0 / 8.3 / 1.7 / fair
- D5: 0 / 8.4 / 0.0 / fair, 0 / 8.3 / 0.0 / fair, 0 / 8.4 / 0.0 / fair

#### Collector activity in the scenarios (median run)

| id | collections | own pause p50/p99/max ms | hs latency p50/p99/max ms | coll waits n / ms | collector busy % | fallbacks | promoted MB | vm_main_ms | worst iter ms |
|---|--:|---|---|---|--:|--:|--:|--:|--:|
| D0 | 0 | 0.003/0.023/0.023 | 0.000/0.000/0.000 | 0 / 0.0 | 0.0 | 0 | 0.0 | 0.9 | 0.97 |
| D1 | 0 | 0.000/0.000/0.000 | 0.000/0.000/0.000 | 0 / 0.0 | 0.0 | 39 | 0.0 | 4005.8 | 12.85 |
| D2 | 3245 | 4.400/6.701/7.578 | 0.028/0.216/1.550 | 0 / 0.0 | 0.0 | 5 | 9116.5 | 1343.0 | 8.82 |
| D3 | 4539 | 0.071/0.114/0.702 | 0.034/0.358/1.351 | 3851 / 16376.3 | 95.7 | 0 | 6029.4 | 1257.0 | 3.90 |
| D4 | 214 | 4.393/11.781/24.736 | 0.010/3.098/8.845 | 0 / 0.0 | 0.0 | 0 | 356.7 | 2486.7 | 6.48 |
| D5 | 613 | 0.007/0.013/0.023 | 0.007/0.085/0.309 | 0 / 0.0 | 1.5 | 0 | 0.0 | 6318.9 | 5.70 |

### Part C: scenarios, first pass (right after Part B, thermal serious) (median run by missed120, then max gap; 10 s at 120 Hz)

| id | Mac id | young | delivered Hz | frames | missed120 | max gap ms | cb late p99 ms | **main stopped because another worker allocated, ms** | main own n / ms / max | main acks other n / ms | main old-space stops (n, ms) | stw pauses (kind n p50/max ms) | thermal start/end | peak footprint MB |
|---|---|---|--:|--:|--:|--:|--:|--:|---|---|---|---|---|--:|
| D0 | Y0 | offload | 120 | 1200 | 0 | 8.37 | -0.86 | **0.00** | 0 / 0.00 / 0.000 | 0 / 0.00 | - | - | serious/serious | 27 |
| D1 | Y1 | stw | 119 | 1194 | 6 | 19.29 | 4.41 | **177.38** | 0 / 0.00 / 0.000 | 0 / 0.00 | scav 49, 177.38; initial 21, 118.15; final 29, 2.77; fallback 1, 11.64 | scav 553 3.84/14.24; initial 265 5.51/7.97; final 265 0.09/0.18; fallback 10 9.80/11.63 | serious/serious | 228 |
| D2 | Y2 | local | 120 | 1196 | 4 | 25.00 | 2.40 | **48.25** | 0 / 0.00 / 0.000 | 1130 / 48.25 | initial 26, 93.14; final 25, 5.71; apply 23, 4.43 | initial 203 3.57/5.23; final 201 0.11/0.24; apply 201 0.13/0.24; fallback 3 14.95/17.69 | serious/serious | 257 |
| D3 | Y3 | offload | 120 | 1200 | 0 | 8.37 | 1.81 | **46.66** | 0 / 0.00 / 0.000 | 1230 / 46.66 | initial 2, 7.77; final 5, 1.95; apply 10, 2.49 | initial 106 3.57/3.82; final 105 0.10/0.18; apply 105 0.11/0.20 | serious/serious | 326 |
| D4 | Y4l | local | 120 | 1200 | 0 | 8.37 | -0.57 | **2.39** | 0 / 0.00 / 0.000 | 184 / 2.39 | initial 1, 2.61 | initial 3 4.98/6.76; final 3 0.11/0.18; apply 3 0.06/0.07 | serious/serious | 248 |
| D5 | Y5o | offload | 120 | 1200 | 0 | 8.37 | -0.45 | **0.03** | 678 / 4.90 / 0.018 | 0 / 0.00 | - | - | serious/serious | 28 |

#### All runs: missed120 / max gap ms / main stopped for others ms / thermal end

- D0: 0 / 8.9 / 0.0 / serious, 0 / 8.3 / 0.0 / serious, 0 / 8.4 / 0.0 / serious
- D1: 5 / 18.3 / 173.1 / serious, 6 / 19.3 / 177.4 / serious, 40 / 98.4 / 203.3 / serious
- D2: 18 / 29.0 / 30.0 / serious, 0 / 8.3 / 33.3 / serious, 4 / 25.0 / 48.2 / serious
- D3: 1 / 16.4 / 39.5 / serious, 0 / 8.3 / 43.9 / serious, 0 / 8.4 / 46.7 / serious
- D4: 0 / 8.4 / 2.4 / serious, 0 / 8.3 / 1.9 / serious, 0 / 8.4 / 1.6 / serious
- D5: 0 / 8.4 / 0.0 / serious, 0 / 8.4 / 0.0 / serious, 0 / 9.2 / 0.0 / serious

#### Collector activity in the scenarios (median run)

| id | collections | own pause p50/p99/max ms | hs latency p50/p99/max ms | coll waits n / ms | collector busy % | fallbacks | promoted MB | vm_main_ms | worst iter ms |
|---|--:|---|---|---|--:|--:|--:|--:|--:|
| D0 | 0 | 0.004/0.018/0.018 | 0.000/0.000/0.000 | 0 / 0.0 | 0.0 | 0 | 0.0 | 0.8 | 0.28 |
| D1 | 0 | 0.000/0.000/0.000 | 0.000/0.000/0.000 | 0 / 0.0 | 0.0 | 10 | 0.0 | 4385.3 | 14.20 |
| D2 | 1958 | 7.369/10.312/17.559 | 0.046/0.430/3.457 | 0 / 0.0 | 0.0 | 3 | 5629.9 | 2358.7 | 18.89 |
| D3 | 2833 | 0.112/0.170/3.446 | 0.051/0.573/2.468 | 2697 / 20187.5 | 95.4 | 0 | 3784.3 | 1689.0 | 4.96 |
| D4 | 216 | 4.584/8.816/12.144 | 0.010/1.976/3.693 | 0 / 0.0 | 0.0 | 0 | 360.0 | 2804.6 | 6.53 |
| D5 | 678 | 0.007/0.014/0.019 | 0.007/0.086/0.210 | 0 / 0.0 | 1.5 | 0 | 0.0 | 6463.5 | 4.31 |

What the device shows beyond the Mac: in the cooled pass every scenario but
the stop-the-world storm missed at most one frame in three runs, and the
heavy main-thread allocation that missed 48 frames on the Mac missed none
although the main thread spent 6.3 s of the 10 s window in Smalltalk
(`vm_main_ms`; Mac 23 to 37 percent). Why the Mac missed frames there and
the phone does not was not investigated. The "stopped because another worker allocated" line
falls from 108 ms (stw) to 25 and 29 ms (local, offload), 4.3 and 3.8 times,
against 3.5 and 1.9 times on the Mac; offload does relatively better here, probably because one collector
thread serves 5 allocating workers instead of 7. Under heat the same line nearly doubles in every configuration.

## Drift, thermal state, memory

### Drift (first kernel of each matrix repeated at start and end, median ms; thermal at end of each run)

- Part A, walk on A, 1 worker: start 1155.7 (nominal,nominal,nominal), end 1188.0 (nominal,nominal,nominal,nominal,nominal,nominal), end/start 1.028
- Part B, alloc stw, 1 worker: start 1743.3 (nominal,nominal,nominal), end 1967.6 (serious,serious,serious), end/start 1.129
- Part B QoS, alloc stw, 1 worker: start 1994.3 (serious,serious,serious), end 1952.1 (serious,serious,serious), end/start 0.979
- Part C, D2 storm local: missed120: start 1.0 (serious,serious,serious), end 1.0 (serious,serious,serious), end/start 1.000
- Part C, D2 storm local: main stopped for others ms: start 30.4 (serious,serious,serious), end 30.3 (serious,serious,serious), end/start 0.997

### Thermal and battery over each part

- Part A: 159 launches over 3 min; thermal samples nominal 318; first seen (min) nominal 0.0; battery charging, level 0.95 to 0.95; available memory at start 3370 to 3370 MB
- Part B: 726 launches over 20 min; thermal samples fair 674, nominal 206, serious 572; first seen (min) fair 3.0, nominal 0.0, serious 12.0; battery charging, level 0.95 to 0.95; available memory at start 3370 to 3370 MB
- Part B QoS: 246 launches over 7 min; thermal samples serious 492; first seen (min) serious 0.0; battery charging, level 0.95 to 0.95; available memory at start 3370 to 3370 MB
- Part C: 24 launches over 5 min; thermal samples serious 48; first seen (min) serious 0.0; battery charging, level 0.95 to 0.95; available memory at start - to - MB
- Part C after cool-down: 18 launches over 4 min; thermal samples fair 27, nominal 9; first seen (min) fair 0.8, nominal 0.0; battery charging, level 0.95 to 0.95; available memory at start - to - MB
- cool-down probes: 13 launches over 15 min; thermal samples fair 14, nominal 4, serious 6; first seen (min) fair 4.1, nominal 7.2, serious 1.0; battery ?/charging, level 0.95 to 0.95; available memory at start 3370 to 3370 MB
- run-order check: 72 launches over 2 min; thermal samples fair 22, nominal 122; first seen (min) fair 1.6, nominal 0.0; battery charging, level 0.95 to 0.95; available memory at start 3370 to 3370 MB

Memory limit: `os_proc_available_memory()` read 3370 MB at every launch
with an 8 MB footprint, so the app's limit is about 3.38 GB. Peak
`phys_footprint`: Part A 236 MB (B, walk); Part B 749 MB (oldheap256, 6
workers; 168 MB for alloc, 323 MB for fragment); Part C 422 MB (storm,
offload). The scenario storm under offload holds the most memory because
the collector lags and edens wait for it.

## Recommendation on ADR 0003

**More measurement before accepting, and keep the table.** The device
confirms ADR 0003's costs on ordinary code (sends 1.11, ivars 1.01,
footprint 1.38x, the same as the Mac) and its benefits (compaction and
become pauses shorter by a third, which ADRs 0007 and 0008 have since built
their whole concurrent collector on: the entry switch is the relocation and
young-copy mechanism). It also shows that the predicted "wider, not
narrower" is true and much worse than predicted in one regime: one thread
chasing pointers through a structure of 100 MB or more pays 4.4x for the
whole kernel and 7.4x per hop, against 1.45 / 2.0 on the Mac.
Below about 50 MB per thread it is 1.1 to 1.3x, narrower than the Mac. Heap offsets (C)
would remove that cost and nothing else that is measured here, and would
discard the mechanism ADRs 0006 to 0008 rely on. The next measurement
should decide whether the bad regime matters: (1) the concurrent marker is
the program that does this traversal on every cycle, so measure its mark
rate per MB through the table against a direct-pointer marker on the
device, on a 200 MB old heap (the existing marker already marks at 3.9 GB
per CPU second on the phone against 6.8 on the Mac on oldheap64 at one
worker, although the phone runs the interpreter twice as fast; how much of
that is utility QoS and how much the table is not separated); (2) try entry locality (entries allocated in
body order, or a per-block entry region) and 16 KiB-aligned table chunks to
see whether the per-hop cost falls to the 2x of the Mac; (3) a
development-sized image (50 to 200 MB) under a realistic single-threaded
traversal (`allInstances`, a snapshot writer). If (2) closes the gap,
accept B. If it does not and (1) shows the marker paying the same 4x, then
revise: the table's memory cost was the expected risk on a phone; its
cache-reach cost is the one this experiment found.

## What the device changes about ADRs 0007 and 0008

- **Most maxima moved down, not up.** Stop-the-world scavenge max 11 to
  15 ms on the allocating kernels (Mac 4.6 to 24), time-to-safepoint max
  0.1 to 1.2 ms at 6 workers (Mac up to 19), local own-pause max 7 to 23 ms
  (Mac 22 to 30), handshake max 2.5 to 12.5 ms (Mac 2 to 17). The offload
  flip is the exception: p99 0.07 to 0.32 ms, max up to 6 ms (Mac p99 under
  0.12, max 2). The one 20.8 ms time-to-safepoint outlier was at two
  workers.
- **Local collection's median pause got worse** relative to stop-the-world
  (1.1 to 1.9 times its p50 at six workers): one copying thread is slow when
  it lands on an efficiency core. ADR 0008's split (background workers
  collect locally) stands, but its owner pause on a phone is 3.6 ms p50 on
  the storm, a third of a 120 Hz frame for whichever worker owns it.
- **The collector thread does not keep up with six allocating workers**
  (76 to 96 percent busy, offload 1.15 to 1.24 times slower); same verdict
  as the Mac. It does keep up with the main thread alone (D5: 1.5 percent
  busy, flips 0.007 ms p50, 0.023 ms max). ADR 0008's "collector thread for
  the main thread" holds on device.
- **QoS is a design input on a phone, not a detail.** The marker at
  utility was ten times slower at completing a cycle with six busy workers
  and caused the fallbacks; the collector at utility made workers wait 4 to
  20 times longer. Both ADR 0006's utility marker and ADR 0008's
  user-initiated collector need revisiting on device: the marker should be
  user-initiated at least while promotion is high.
- **The eden-reuse wait has a 10 ms floor at 2 and 6 workers**, a scheduler
  quantum; the epoch rule waits for a descheduled worker. It was a
  6 to 14 ms tail on the Mac too; here it is the same 10 ms in every
  kernel, which makes the cause clearer.
- **Heat matters as much as the collector.** Main-thread time stopped for
  others nearly doubled between a cool and a hot phone. Any frame budget
  must be stated with a thermal state.

## Honest notes

- **Not done.** No ThreadSanitizer or verifier run on device (the verifier
  scenarios Y3/Y6 `--verify` were not repeated); no `share` kernel or Y6;
  no Y4s/Y5s baselines or Y4o/Y5l; no 16 MiB nursery extras or the
  initial-mark (a)/(b) comparison; no `orig` or `nobarrier` column; no
  alignment-controlled build; no performance counters (the walk hypothesis
  is unverified); `arith`, `fib`, `alloc` and the `reshape`/`snapshot` ops
  were not in Part A (the brief did not list them).
- **Heat contaminates Part B.** The matrix ran continuously for 20 minutes
  and spent most of it at fair or serious. Ratios inside a row (configs run
  back to back) are sound; absolute times and 1-worker ratios against the
  first config of each row are biased by up to about 15 percent. A cooled,
  shorter matrix (fewer runs with cool-downs) would be the fix; the order
  check is the evidence that the bias is heat.
- **Worker placement is uncontrolled.** Six workers on six cores means
  every run puts four on efficiency cores; which ones is the scheduler's
  choice. Tails and the local own-pause median depend on it.
- **The A2 4-worker row** and why B pays 7x and not 2x per hop at one
  worker are unexplained beyond the hypothesis above.
- **Launch overhead was about one second**, so about 1 330 launches took
  about an hour; device iteration was fast, not slow.

## Deviations from DESIGN.md

1. **Team `BDN6M642M2`**, not `A7ZJ8ZA2F7` (see "What had to change", 5).
2. **xcodegen** (installed with Homebrew) generates the project from
   `app/project.yml`; the generated `KajoDeviceBench.xcodeproj` is
   committed. The VMs are a SwiftPM package of symlinks in `swift/`
   (not in the layout of DESIGN.md), and `bench-device.sh` needs
   coreutils' `timeout`.
3. **Two source changes**, recorded above. The app does not depend on the
   original packages by path as DESIGN.md says, because both packages
   resolve kernels through `#filePath` and both define a module named
   `Kasm`; the symlinked package is the same source.
4. **Part A**: `compact` and `become` only at 6 workers (they need busy
   workers to stop; the Mac ran them only at 8). Added: the A2 worker sweep.
5. **Part B**: the configuration called `stw` is the Mac's `adr7b`; `adr7`
   is the no-barrier build, as on the Mac. QoS sub-matrix on the eight
   allocating kernels at 2 and 6 workers only, 5 runs, three variants
   (collector utility under offload; marker user-initiated under local and
   offload); the default rows are the main matrix's. Added: the run-order
   check (72 runs) after a cool-down. Pause distributions over runs are the
   median of per-run p50 and p99 and the max of maxima, as on the Mac.
   Fallbacks are summed over the 5 runs (the Mac table showed medians).
6. **Part C**: 5 background workers instead of 7. Run twice: the first
   pass (the one the brief's ordering produced) at thermal serious, the
   second after cooling; the cooled one is the headline. Drift for Part C
   repeats D2 (storm, local), not D0, since idle cannot drift.
7. **Drift** is 3 runs of the first kernel at the start and the end of each
   part. Part A's end runs were launched by hand after an edit to
   `bench-device.sh` during the run broke bash's reading of the script
   (bash reads a running script incrementally); the 150 matrix runs were
   complete, only the 3 drift-end launches were affected.
8. **`oldheap256`** ran as specified; the limit did not force a reduction.
