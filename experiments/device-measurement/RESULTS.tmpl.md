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

{{Part A: object representation}}

{{Traversal only}}

{{A2: walk against worker count}}

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

{{Phone against Mac, absolute}}

The phone runs this interpreter about twice as fast as the M2 Max on one
thread (ivars 0.43, sends 0.52 of the Mac's time) and 1.2 to 1.5 times
slower with six workers against eight.

{{Peak memory per variant}}

(`become`: A's clones leave the old bodies behind until the next GC, so A
peaks higher there; this is the kernel, not a representation cost.)

{{become: 2^20 live objects}}

{{compact: 2^21 allocated}}

## Part B: collector

4 MiB nurseries, `KAJO_GC=cm KAJO_AGE=2`, 5 interleaved runs, 1, 2 and 6
workers. `stw` is the barrier build with the stop-the-world scavenge (the
Mac matrix's `adr7b`); `adr7` the `-DNO_YOUNG_BARRIER` build, the checksum
reference. The thermal column is the worst state at the end of any run in
the row; most rows reached serious (question 5).

{{Wall time, ms (median of runs), 4 MiB nurseries}}

{{Pauses (ms, p50 / p99 / max)}}

{{Collection activity (medians), 4 MiB}}

{{QoS: collector (offload) and marker thread QoS}}

The QoS rows ran at thermal serious, the default rows partly at fair; the
"vs default" ratio is therefore biased against the QoS variants by a few
percent. The effects that matter (collector waits up 3 to 18 times at
utility; marking cycles 1.4 to 11 times shorter with a user-initiated marker,
10 times on the old heaps at six workers)
are far outside that.

{{Run-order check}}

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

{{Part C again after cooling to nominal}}

{{Part C: scenarios, first pass}}

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

{{Drift}}

{{Thermal and battery over each part}}

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
