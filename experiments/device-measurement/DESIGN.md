# Experiment: the VM on an iPhone

## Question

Every number behind ADRs 0003 to 0008 was measured on an Apple M2 Max with
8 performance cores, large caches and no memory limit worth the name. The
target is a phone. ADR 0003 has waited on a device measurement since it was
written, and ADR 0007 and 0008 both say their maxima must be re-measured on
device. This experiment runs the existing benchmarks on an iPhone 17 Pro
and asks:

1. **Object table on device (ADR 0003).** On the phone's cache hierarchy,
   what does the table cost against direct pointers on the cache-defeating
   `walk` kernel, on `sends` and `ivars`, and in memory? ADR 0003 predicted
   "wider, not narrower" than the 1.45x on the Mac. Is it, and is it
   acceptable? If not, C (heap offsets) is the named fallback.
2. **Does the current VM run on iOS at all?** The double mapping of the
   heap (ADR 0007), pthread workers, `mach_absolute_time`, QoS on an
   asymmetric 6-core chip, and memory limits. What breaks, and what had to
   change.
3. **Pauses and throughput on device.** The headless matrix of
   `experiments/concurrent-young` on the phone: stop-the-world scavenge
   against local and offloaded young collection, concurrent marking and
   relocation, at 1, 2 and 6 workers. Owner pauses, handshake latency,
   whether the collector thread keeps up when it lands on an efficiency
   core, promotion rate and fallbacks, footprint.
4. **Frames on device.** The UI scenarios at 120 Hz ProMotion: idle, the
   allocation storm under stop-the-world, local and offloaded collection,
   the fragmentation ring, heavy main-thread allocation. Frames missed, main
   thread pause attribution, as in ADR 0008.
5. **Thermal and power.** Does the phone throttle during a run, and how do
   the numbers drift? Report `ProcessInfo.thermalState` over time and
   repeat the first kernel at the end of each matrix.

## Device

iPhone 17 Pro (iPhone18,1), iOS 27.0.1, 6 cores (2 performance, 4
efficiency), 120 Hz ProMotion display, 12 GB RAM, connected by cable, UDID
`00008150-001271502182401C`. Developer Mode is enabled and the device is
paired. Signing: automatic, team `A7ZJ8ZA2F7` (free Apple Development
identity; the first launch needs the user to trust the developer in Settings,
report when that is needed and continue when it is done). Mac: Xcode 27.1,
iOS 27.1 SDK, `xcrun devicectl` for install, launch with `--console`, and
copying files back.

## Starting point

Do not modify earlier experiments. Build a thin iOS app in
`experiments/device-measurement/app/` that depends on the existing
SwiftPM packages by path:

- `experiments/object-representation/swift` for `VMA`, `VMB`, `VMC` and
  `Kasm` (ADR 0003's three object memories), with its `kernels/`.
- `experiments/concurrent-young/swift` for `VMR` and `Kasm`, with its
  `kernels/` and those it reuses from `concurrent-relocation`.

If a library target does not compile for iOS, fix it in a copy under this
experiment, not in place, and record every change. Kernels are bundled as
resources. An Xcode project is needed for automatic signing: generate it
with `xcodegen` if installed, otherwise write a minimal `project.pbxproj`
by hand; either way `xcodebuild -allowProvisioningUpdates` must build and
sign it unattended. Build Release, `-O`, no `-Ounchecked`, as every
experiment did.

## App shape

- iOS kills an app that blocks the main thread at launch. The headless
  runs execute on a background thread while the main thread draws a status
  view and the current line of output. Every result line also goes to
  stdout (streamed by `devicectl ... --console`) and to a file in the app's
  Documents directory, copied back with `devicectl device copy from`, so a
  killed run still leaves data.
- The run is selected by a launch argument or environment through
  `devicectl device process launch`, one kernel or one scenario per launch,
  so a crash costs one run and thermal state is logged per launch.
- UI scenarios use a UIKit shell with `CADisplayLink`, requesting 120 Hz
  through `preferredFrameRateRange` and the
  `CADisableMinimumFrameDurationOnPhone` Info.plist key. Log the actual
  frame rate the display delivered; ProMotion is variable and an idle view
  may be throttled to 60 Hz or less, so the scenario must draw something
  that changes every frame. Keep the screen awake with
  `isIdleTimerDisabled`.
- Memory: read `os_proc_available_memory()` at start and log footprint
  (`task_vm_info.phys_footprint`) with every result line. Size the large
  heaps so the biggest run stays well inside the limit; `oldheap512` may
  have to become `oldheap256`. Record what the limit was.
- Do not run while the phone is unplugged. Log `UIDevice.batteryState`.

## Matrix

Part A, ADR 0003: `walk`, `walkbuild`, `sends`, `ivars`, `compact`,
`become` on A, B and C, 1 and 6 workers, 5 interleaved runs, medians, and
peak footprint per variant. Report B/A and C/A as the Mac results did, and
the traversal-only cost (`walk` minus `walkbuild`).

Part B, collector: `alloc`, `churn`, `survivors5`, `survivors30`,
`oldheap64`, `oldheap256`, `fragment`, `storeheavy`, `ivars`, `sends`,
`fib`, `arith` under `stw`, `adr7`, `local` and `offload`, at 1, 2 and 6
workers, 4 MiB nurseries, 5 interleaved runs. Report what the concurrent-
young matrix reports: wall, checksum (equal to `stw` is a gate), owner
pause p50/p99/max, handshake latency, collector busy share, waits for the
collector, promotion rate, fallbacks, footprint, initial-mark pause, and
the thermal state at start and end of every run. Where the collector or
marker thread's QoS decides which core it runs on, try user-initiated and
utility and report both.

Part C, scenarios: D0 idle, D1 storm stop-the-world, D2 storm local, D3
storm offload, D4 fragmentation ring (local), D5 heavy main-thread
allocation (offload), each 10 s after 1 s warm-up, 3 runs, with the
delivered frame rate, frames missed, maximum gap, and main-thread pause
attribution with "stopped because another worker allocated" on its own
line. Run them with the phone awake and the app in the foreground; note
anything that got in the way (notifications, thermal state).

## RESULTS.md must contain

- Answers to the five questions with numbers, and for each a one-line
  comparison with the Mac figure from the earlier RESULTS.md.
- What had to change to run on iOS, including whether the double mapping
  worked as is, needed `vm_remap`, or failed.
- The three tables.
- Thermal state over time and how much the repeated kernel drifted.
- The memory limit found and the footprints.
- A recommendation paragraph on ADR 0003 (accept, revise to C, or more
  measurement), and a paragraph on what the device changes about ADRs 0007
  and 0008 (which maxima moved, whether the collector keeps up).
- Honest notes. Device runs are slow to iterate; say what you did not get
  to.
- Exact reproduction: `bench-device.sh` that builds, installs, runs every
  part and pulls the results.

## Layout

```
experiments/device-measurement/
  DESIGN.md
  app/              the iOS app: project, sources, Info.plist
  bench-device.sh   build, sign, install, run the matrix, pull results
  report.py
  results/          pulled raw output
  RESULTS.md
```

## Non-goals

- New VM features or tuning. Measure what exists.
- Simulator runs; they measure the Mac.
- App Store or TestFlight packaging.
