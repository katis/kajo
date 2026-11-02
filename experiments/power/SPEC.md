# Spec: what the power experiment adds

Everything not stated here is as in `../device-measurement/` (the device
app pattern, its DESIGN.md and RESULTS.md), `../entry-locality/SPEC.md`
(the sized walk kernels on variant B) and `../concurrent-young/SPEC.md` (VMR,
the collector modes and their environment switches).

## Package shape

`swift/` is one SwiftPM package (`Package.swift`, product `PowerAll`):

| target | what | source |
|---|---|---|
| `Kasm` | assembler and kernel lookup | `Kasm.swift` symlinked to concurrent-young (identical to object-representation's); `KernelFiles.swift` a recorded copy (below) |
| `VMB` | object-representation's object table (variant B) | per-file symlinks; `Runner.swift` -> entry-locality's recorded copy (workers at user-initiated QoS), so B runs exactly as entry-locality ran it |
| `VMR` | concurrent-young's object memory | per-file symlinks to `../device-measurement/swift/Sources/VMR/` (its `Blocks.swift` is the vm_map copy for iOS) |
| `PowerC` | `wfe` and `yield` as C functions (`__asm__`) | new |
| `PowerKit` | telemetry, companion, pacer, chase | new |
| `PowerVM` | the Part 2/3 VM driver (`Session`) | new |
| `PowerKitTests`, `PowerVMTests` | tests of the above | new |
| `VMRTests` | concurrent-young's VMR suite | per-file symlinks, run against this VMR |

`KernelFiles.swift` = device-measurement's merged copy with three changes:
`experimentsDir` defaults to the repository path from `#filePath` (so `swift
test` finds kernels; the app overrides it with the bundle), the
object-representation flavor is entry-locality's (sized walks `walkN`,
`walkbuildN` over `entry-locality/kernels`), and `walkNxR` = `walkN` with R
traversals instead of 2. `powerSources(oldheapMB:replaceEvery:)` loads
concurrent-young's base, concurrent-marking's `oldheap.kasm` and
`kernels/power.kasm`.

`app/` is an xcodegen project (`KajoPower`, bundle
`dev.katajamaki.kajo.power`, team `BDN6M642M2`); a build phase copies every
kernel directory the two flavors need into the bundle (`cp -L`, so
entry-locality's symlinked kernels are copied as files).

## Telemetry (every result line)

- `ProcUsage` (`proc_pid_rusage`, `RUSAGE_INFO_V6`, own pid), sampled at
  both ends of the measured interval: `cpu_ms`, `p_frac` (CPU time on P
  cores), `p_ghz`/`e_ghz`, `ipc`, `runnable_ms`, **`energy_mj`
  (`ri_energy_nj`)**, `penergy_mj` (`ri_penergy_nj`), `billed_mj`
  (`ri_billed_energy`), `serviced_mj` (`ri_serviced_energy`), `idle_wkups`
  (`ri_pkg_idle_wkups`), `intr_wkups` (`ri_interrupt_wkups`), CPU time per QoS
  class (`qos_ui_ms`, `qos_in_ms`, `qos_def_ms`, `qos_ut_ms`, `qos_other_ms`).
  The brief named `ri_billed_energy`; on iOS 27 it is not this process's
  energy (it moves with work done on the process's behalf by others: 0.5 mJ
  for a second of busy loop, 21 mJ for an idle second during launch).
  `ri_energy_nj` is: 22 to 29 mJ idle, 1764 to 1780 mJ for one second of a
  busy loop on a P core (`results/dev-hello.txt`). Energy below means
  `ri_energy_nj`: CPU energy attributed to the process's threads, not DRAM,
  not the display, not the render server.
- `ThreadCPU` (`task_threads` + `thread_info(THREAD_EXTENDED_INFO)` +
  `THREAD_IDENTIFIER_INFO`): every thread's CPU ns, name and priority, by
  64-bit thread id.
- `ThreadCounts` (`proc_pidinfo(pid, 34 = PROC_PIDTHREADCOUNTS, tid)`, a
  flavor from xnu's private `proc_info_private.h`): per thread and per
  performance level (level 0 = P cores) instructions, cycles, CPU time and
  **energy in nJ**. Fields `<role>_cpu_ms`, `<role>_p_frac`,
  `<role>_energy_mj`, `<role>_penergy_mj`, `<role>_ipc`, `<role>_tc_ok`.
- VM thread roles: `Session` snapshots the task's threads before and after
  `Runtime(...)`; the new thread ids, ascending, are the young collector (if
  `offload`), the markers, then the background workers (Runtime.start's
  creation order). `vm_threads=coll:n,marker:n,bg:n,unexpected:n` reports
  the split; `unexpected` > 0 would mean another thread appeared meanwhile.
  No VM source changed.
- Thermal state at start and end, battery state and level, Low Power Mode,
  `phys_footprint` and its peak, `os_proc_available_memory`.

## Part 1

`part=1 kernel=walk22x4|walkbuild22|walk23x4|walkbuild23 workers=1|2
comp=...`: `VMB.benchLine` (entry-locality's runner: build the graph of
2^N / workers nodes per worker, traverse it R times) with a companion thread
started 20 ms before and stopped after. `walk23x4` with 2 workers = two
workers each walking its own 2^22-node graph, the brief's "second worker".

Per hop (report.py): `(E(walk22x4) - median E(walkbuild22)) / (4 x 2^22)`
for each launch of a configuration, the build median taken over the same
configuration's `walkbuild22` launches; the same for time. Energy per hop is
given for the whole process and for the worker alone (process minus the
companion's own `comptc_energy_mj`).

Companion (`PowerKit/Companion.swift`), a pthread at user-initiated unless
stated: `spin` (a loop of the `yield` hint, no memory traffic), `spinut`
(the same at utility QoS), `t10000`/`t1000`/`t100` (`mach_wait_until` on
absolute deadlines at that rate, nothing else), `wfe` (a loop of the `wfe`
instruction: it waits for an event or the generic timer's event stream,
which on this phone ends a wait about every 1.3 us). It reports its own CPU
time (`CLOCK_THREAD_CPUTIME_ID`), its wakeups or iterations, its mean
lateness (timers), the QoS it ran at, and its own per-level counts and
energy (`comptc_*`).

`part=1c size=256 hops=N comp=...`: a random single cycle (Sattolo) over
256 MiB of 64-byte nodes, warmed up for 2^22 hops, `ProcUsage` sampled
around the N timed hops only.

## Part 2

`part=2 rate=R seconds=30 cfg=... KAJO_*=...`: `Session` with a 768 MiB
heap, 4 MiB nursery, no background workers, `KAJO_AGE=2`, the collector
configuration from the environment:

| cfg | KAJO_GC | KAJO_YOUNG | KAJO_YC_QOS | KAJO_CM_QOS |
|---|---|---|---|---|
| stw | stw | stw | - | - |
| conc-high | cm | offload | initiated | high |
| conc-utility | cm | offload | utility | utility (default) |
| conc-mixed | cm | offload | initiated | utility (default) |

Setup (before the display link): `nil pwSetup: 200` builds oldheap.kasm's
200 MiB graph (6400 groups of 256 nodes of 14 slots) on the main worker,
then one full collection promotes it.

Frames: a `CADisplayLink` at 120 Hz on the main run loop (a view moved every
callback, as device-measurement did, so ProMotion does not throttle). Every
callback runs one turn on the main worker: `spawn(nil pwFrame: arg)` then
`runMain`, repeated until no Process is alive. `arg` = points x 2^20 +
mutation x 256 + 10:

- `points` from the `Pacer`: (rate - the mutation's own allocation) x
  elapsed / 24 bytes, minus what was already issued, capped at 4 frames'
  worth (a longer stall is forgotten and counted in `pacer_capped`);
- each PPoint (24 body bytes + a 16-byte entry) is kept with probability
  10 percent (deterministically, counter mod 100 < 10) in a store of 1024 x
  64 slots that is replaced when full: generational-gc's `survivors.kasm`
  shape at 10 percent, keepers live until 65 536 more are kept;
- `mutation` = 64 oldheap iterations (one OHPoint churned each, every 8th a
  pointer store into an old node), 256 every 120th frame (one 32 KiB group
  replaced, so one group per second becomes old garbage).

The measured window starts `warmup` (3 s) after the link starts; the line
reports the window's actual length (`window_s`) and the allocation the frames
issued (`alloc_mb_s`, body bytes). Frames missed: gaps between link
timestamps over 1.5 x 8.33 ms, counted in 8.33 ms frames (`missed120`).
Main-worker turn time (`turn_*`), own pauses (`main_own_*`: offload flips),
the stop-the-world scavenges (`pause_*`, `scavenges`), cycles, fallbacks and
the rest from concurrent-young's `gcSummary` and `ycSummary` over the
window's records; `old_hwm_mb` sampled after every turn.

## Part 3

`part=3 mode=... seconds=60`, Part 2's Session with 5 background workers:

| mode | VM | display link | per tick |
|---|---|---|---|
| novm | none | none | - |
| parked | up, every worker idle | none | - |
| link | up | 120 Hz, view moved | nothing (VM never entered) |
| tick | up | 120 Hz, view moved | `runMain` with nothing ready: enter, leave |
| tickalloc | up | 120 Hz, view moved | Part 2's frame at 2 MB/s |

`threads=` lists every thread that used at least 0.01 ms of CPU in the
window, by role (`main`, `coll`, `marker`, `bg1..5`) or `t[name]/p<priority>`.

## Unplugged

`part=unplugged wait=M seq=kernel/comp,... reps=K`: launched over the cable,
the app waits up to M minutes for `UIDevice.batteryState == .unplugged`,
settles 20 s, then runs the sequence K times in one process, one line each,
appended to Documents/unplugged.txt (pulled later).

## Tests (`swift test` on the Mac)

PowerKitTests: the energy and CPU readout grow with a 300 ms busy loop;
`ThreadCPU` finds a new spinning thread and agrees with its own clock;
`ThreadCounts` sees 200 to 400 ms of a 300 ms spinner; the timer companion
wakes at its rate with little CPU; the utility companion reports its QoS;
the `wfe` companion runs and stops; the Pacer delivers the rate, catches up a
missed frame, caps and forgets a long stall; the chase follows its links.

PowerVMTests (serialized: the collector configuration is in the
environment): stop-the-world frames allocate and keep exactly their share
(points, keepers and the checksum of x); the keeper store is replaced at
65 536; mutation runs on the old heap; an offload Session identifies one
collector and one marker and the collector does the young collections;
background workers are identified; `walkNxR` parses and its checksum scales
with R on VMB.
