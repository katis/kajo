# Experiment: what the VM costs in energy on the phone

## Question

Kajo apps run on battery. Every collector decision so far was made on a
time budget (a 120 Hz frame, a cycle completing before old space fills).
This experiment puts an energy budget beside it and asks three things on the
iPhone 17 Pro:

1. **Is the slow regime a power state, and what does waking the cluster
   cost?** `experiments/entry-locality` found that a single latency-bound
   thread on an idle performance cluster runs 2.5 to 4x slower per miss, and
   that a thread spinning on the other P core removes that. A spinning thread
   is not acceptable in a phone app. Measure the energy per unit of work in
   both regimes and find whether anything cheaper than a spin (a timer-driven
   wake at some rate, a `WFE`-style wait, a lower QoS companion, nothing)
   changes the regime. If the slow regime is simply the phone saving power
   while the thread waits on memory, say so; then the right answer is to
   accept it, and ADR 0003's second condition closes.
2. **What does the concurrent collector cost in energy, and where should
   its threads run?** ADR 0006 and 0008 put the marker and the young
   collector at user-initiated QoS on device because at utility QoS they land
   on efficiency cores and may not keep up under the allocation storm. A
   phone app is not an allocation storm most of the time. For realistic
   allocation rates, measure energy per MB allocated and per cycle for:
   stop-the-world (the oracle), concurrent with collector and marker at
   user-initiated, and concurrent at utility. Find the allocation rate below
   which the efficiency cores keep up, and what that saves.
3. **Does an idle VM stay idle?** With the VM up and no Smalltalk work, and
   with a 120 Hz UI tick doing no Smalltalk work, count wakeups, CPU time
   and energy over a minute. The answer must be essentially zero; anything
   periodic in the collector, the scheduler or the hazard/epoch machinery
   shows up here.

## Where this feeds

- ADR 0003, condition 2 (the slow regime): close or reword it.
- ADR 0006 and 0008: an amendment on QoS placement on device, which may be
  "utility unless headroom shrinks" rather than "user-initiated".
- ADR 0004 if the UI tick itself costs anything.
- AGENTS.md lessons on measuring energy on device.

## Setup

- Device only. **The Mac is in interactive use throughout** and must not run
  benchmark matrices; use it to build, sign and drive the phone over
  `devicectl`. Keep builds incremental. Mac-side numbers are not wanted.
- Base: `experiments/device-measurement/app/` (xcodegen project, team
  `BDN6M642M2`, one configuration per launch, `bench-device.sh`,
  `report.py`), and the `VMR` object memory from `experiments/concurrent-young`
  through the symlink package in `experiments/device-measurement/swift/`,
  which already carries the `vm_map` change. Add scenarios; do not modify the
  other experiments. Where a shared file must change, make a recorded copy
  in this experiment and say so in RESULTS.md, as entry-locality did.
- Energy: `proc_pid_rusage` with `RUSAGE_INFO_V4` or later gives
  `ri_billed_energy` (and `ri_pkg_idle_wkups`, `ri_interrupt_wkups`,
  `ri_cycles`, `ri_instructions`, per-process). First verify it is populated
  on iOS 27 for the app's own pid and that it grows with work. If it is zero
  or does not move, fall back to cycles and CPU time split by core type
  (`ri_user_time` and the P-core share you already log) and say that energy
  was not measured. Battery percentage is too coarse (5 percent steps) for
  anything but a sanity check over a long run; log it anyway. Log thermal
  state at start and end of every line; do not run while `serious`. Low Power
  Mode off, on the cable, screen on. Note that charging on the cable may
  change the power manager's behaviour: run one cross-check of Part 1
  unplugged (launch over the cable, unplug, run, copy results on reconnect)
  and report whether the regime and energy numbers moved.
- Per-thread CPU time: `thread_info` with `THREAD_BASIC_INFO` for every VM
  thread, or `pthread_getugid`-free bookkeeping of the collector threads'
  own `clock_gettime(CLOCK_THREAD_CPUTIME_ID)`. Report collector CPU seconds
  and mutator CPU seconds separately for every run.
- Medians of 3 launches per configuration, interleaved, and repeat the first
  configuration at the end of each matrix (thermal check). Report the
  per-launch spread wherever Part 1 of entry-locality showed bimodality.

## Part 1: the slow regime and the price of waking the cluster

Kernel: entry-locality's `walk22` on the object table (B / VMR's layout),
1 worker. Configurations:

- alone (idle cluster)
- companion spinning (the entry-locality fast regime)
- companion waking on a timer at 10 kHz, 1 kHz, 100 Hz, doing nothing
  (`dispatch_source` timer or a `usleep` loop; log its own CPU time)
- companion at utility QoS spinning (does an E-core spin wake the P cluster?)
- a second worker doing the same walk on its own graph (the realistic
  "two threads busy" case)

For each: ns per hop, `ri_billed_energy` delta per hop (nJ per hop), total
energy for the run, CPU time of the worker and of the companion, P-core
share, IPC. The number that decides: **energy per hop, slow regime against
fast**. If the fast regime does more work per joule as well as per second,
the slow regime is a loss and something must wake the cluster; if it does
less work per joule, the slow regime is the phone being efficient and
should be accepted. Also run the chase microbenchmark (`chase-bench`,
256 MB, 1 thread) alone and with the spinning companion, so the result does
not depend on the VM.

Also: Instruments is on the Mac and the user is using the Mac. Do not open
Instruments. If a performance counter can be read from inside the process
on iOS (`kpc` is private; assume not), do not try.

## Part 2: collector energy at realistic allocation rates

Build a rate-limited allocation scenario on VMR: one "main" worker
allocates at a fixed rate with the storm kernel's survival shape (use
`share.kasm` or device-measurement's storm, whichever has a survival rate
in the 5 to 20 percent range that promotes into old space), paced by a
120 Hz tick, so bytes per frame = rate / 120. Rates: 2, 10, 50, 200 MB/s
(2 MB/s is a quiet UI, 200 is near the storm). A slowly mutating old heap
of 200 MB behind it, as in concurrent-marking's realistic scenario, so the
marker has something to do. Run 30 s per configuration. Collector
configurations:

- `stw`: the stop-the-world oracle (`KAJO_YOUNG=stw`, marker off or STW
  full collections)
- `conc-high`: offloaded young collection and concurrent marking, collector
  and marker at user-initiated (`KAJO_YC_QOS`, `KAJO_CM_QOS=high`)
- `conc-utility`: both at utility
- `conc-mixed`: young collector user-initiated, marker utility (the
  cheap-if-it-keeps-up split)

Report per configuration and rate: total energy (J), energy per MB
allocated (mJ/MB), collector CPU seconds and mutator CPU seconds, P-core
share of collector time, cycles started and completed, fallbacks to
stop-the-world (ADR 0006: never hide), scavenges and their pause p50/p99/max
on the main worker, frames missed of the 120 Hz tick, old-space high-water
mark. The decision table is **energy per MB allocated against rate, for
the four configurations**, plus the rate at which `conc-utility` first falls
back or misses frames.

One cross-check: the same matrix at 1 MB/s for 60 s for `stw` and
`conc-utility`, to see the quiet-app cost.

## Part 3: idle

- VM up, all workers parked on their condition variables, no UI, 60 s:
  `ri_pkg_idle_wkups`, `ri_interrupt_wkups`, CPU time, energy. Expect
  zero wakeups from the VM. Anything else: name the thread.
- The same with the 120 Hz display-link tick running an empty Smalltalk
  frame (enter the VM, run nothing, return), 60 s. Expect 120 wakeups per
  second and nothing else.
- The same with the UI tick and 2 MB/s allocation: how many wakeups per
  second does the concurrent collector add at utility and at user-initiated?

## Deliverables

- `experiments/power/`: this brief, `SPEC.md` for whatever you add,
  `app/` (xcodegen project like device-measurement's; or extend a copy of
  it), `bench-device.sh` (coreutils `timeout` is `gtimeout`), `report.py`,
  `results/` with every raw line, `RESULTS.md` with the tables above, each
  with the thermal check, the per-launch spread where it matters, and a
  recommendation for each of the three questions.
- Fill the `power/` row in `experiments/README.md` with "See
  `power/RESULTS.md`" (the final outcome text is written afterwards).
- Tests: whatever you add to the VM (rate-limited allocator, thread CPU-time
  bookkeeping, energy readout) gets a test; the existing VMR suite must still
  pass. No ThreadSanitizer run is needed on the Mac for this one beyond the
  default `swift test`; say which you ran.
- Commit as you go, small commits, only inside `experiments/power/` and the
  README row. Never commit profiles, certificates, DerivedData or anything
  under `references/`.
- If signing or device trust fails, stop and report; the team is
  `BDN6M642M2` and the device is `00008150-001271502182401C`.
- RESULTS.md ends with "Deviations and honest notes": what was not done,
  what was added beyond the brief, and anything that would make a reader
  distrust a number.
