# Module 9a: the shells on device

Status: brief, 2026-11-04. Module 9 of `docs/PLAN.md` is split: 9a (this
brief) is the native shells that run the kernel image on macOS and on the
iPhone, the host surface they need, the first native view wrappers, and
the device measurements ADRs 0003 to 0008 have waited for. 9b, the
development protocol and the developer UI, waits for the owner's answers
(the install primitive, warnings as events, the protocol's design) and is
not in this brief.

## What it hides

A Kajo image runs inside a native application on a Mac and on an iPhone,
with the main thread given to the VM in turns as ADR 0004 decided, a
Smalltalk Process handling UI events synchronously in the run-loop turn
that delivered them, and the display holding its frame rate while the VM is
abused. The shell owns the run loop, the display link and the views; the VM
owns every Process; the kernel owns the event loop and the wrappers. What a
view is behind a wrapper (AppKit or UIKit, a handle table, how a dead
wrapper releases its view) is this module's to hide behind one Smalltalk
protocol that is the same on both platforms.

## Starting point (read these as built)

- AGENTS.md's use cases and ADR 0004 (the main thread is a VM worker owned
  by the shell, budgeted preemption, hop to main, primitives never block,
  the stuck report, UIKit and AppKit as targets, no SwiftUI). Its "Built
  (module 3)" note: `VM.runMain(budgetNs:minPriority:)`, the main worker is
  worker 0, `wakeMain`, external signals, the event queue is not built.
- `docs/modules/workers.md` (turns, hops, budget, external signals, the
  host surface, the stuck report), `young-collection.md` (the main-thread
  scenarios storm, ring, share, idle with `kajo run --main-ms`, the mixed
  QoS policy, the acknowledgement costs ADR 0008 asks the shell to
  measure), `concurrent-marking.md` (the marker's QoS), `kernel-image.md`
  (the image, the entry point, the event stream, `kajo test`),
  `image-processes.md` (`Smalltalk snapshot:`, resume).
- `Sources/KajoVM/Headless.swift`: the public surface today is `kajo
  run`'s options and outcome, with an `events` callback for the NDJSON
  stream. Everything else is internal.
- `experiments/ui-thread-scheduling/` (DESIGN.md, RESULTS.md, `kajo-ui`:
  the AppKit measurement shell this module's shells grow from) and
  `experiments/device-measurement/` (DESIGN.md, RESULTS.md "What had to
  change to run on iOS", `app/`: the UIKit port, the Xcode project, the
  launch-argument protocol, Documents output, `bench-device.sh`). Reuse
  their shape; do not modify the experiments.
- AGENTS.md's iOS lessons: `mach_vm.h` is unsupported on iOS, collector
  threads at low QoS land on efficiency cores, energy via `ri_energy_nj`,
  events carry the time they happened.

## The machine and the device

This Mac is a Mac mini (M2 Pro) with Xcode 27.2 and the swift.org 6.4.2
toolchain first on PATH (gates run on it; Xcode builds the apps). `xcodegen`
is not installed: adapt the committed `experiments/device-measurement/app/
KajoDeviceBench.xcodeproj` by hand, or install xcodegen with Homebrew and
commit both the spec and the generated project. The phone is an iPhone 13
Pro (iPhone14,2), iOS 27, 120 Hz ProMotion, A15 (2 performance and 4
efficiency cores), UDID `00008110-001855C63642801E`, connected by cable
(`xcrun devicectl list devices` shows it). Signing: automatic, team
`BDN6M642M2`, `xcodebuild -allowProvisioningUpdates`; the keychain lists one
identity, "Apple Development: Joni Katajamaki (A7ZJ8ZA2F7)". If signing or
the first launch fails for a reason only the owner can fix (a trust prompt
on the phone, Developer Mode, a profile), record exactly what is needed in
the doc and your report, finish everything that does not need the device
(the macOS shell, its measurements, the iOS build), and hand back; do not
alter keychains or accounts. The mini's display is a TV: report its actual
refresh rate and measure against it.

## What 9a builds

### 1. The host surface (`Sources/KajoVM/Shell.swift` or similar, public)

A small public API the two shells share, documented in the doc with every
public symbol:

- open a VM over an image file (the kernel image, with or without saved
  Processes) with the options a shell needs (workers, heap, collector
  modes); close it;
- the main worker as the host's thread: `runTurn(budget)` returning the
  turn's stats, a `wakeMain` callback the shell turns into a scheduled
  turn (`DispatchQueue.main.async` or a run-loop source), and the display
  tick as the shell's call;
- the **event queue**: the shell enqueues events (kind, target wrapper,
  payload, the time it happened) and a Smalltalk Process waits on them
  (`nextEvent` through a Semaphore the queue signals from outside); a
  native callback into Smalltalk only enqueues and returns (ADR 0004);
- the stuck report as a callback with the Process and its current method;
- `spawn` of a main-affine or any-worker Process at a selector;
- the NDJSON event stream callback (8b's) and the counters;
- `snapshot(to:)` for the shell's save command;
- nothing that lets Swift hold an oop across a turn without a root (a
  handle API, or oops valid only inside a callback: decide, document).

### 2. Native view wrappers, the first set (ADR 0010, proposed)

Write ADR 0010 for how Smalltalk objects wrap native views, then build the
smallest set that lets the measurement UI and a demo be written in
Smalltalk: Window, Label, Button, TextView (append a line), Slider, and a
plain View that can be moved every frame (the display-link probe). Rules
to decide and record: the handle table from wrapper to native object and
the reverse map for events; a wrapper's lifetime (an Ephemeron or the
finalization Process releases the view when the wrapper dies, or views
outlive wrappers until closed: decide); every view primitive is a hop
primitive (off the main thread it suspends and retries on main); the
protocol is the same on AppKit and UIKit with the platform behind the
primitives, not in the kernel; a wrapper's properties are set and read
synchronously in the same turn (ADR 0004's "set then get"). The kernel
classes live in `kernel/` with SUnit tests that run headless (the
primitives fail cleanly with no shell, and a test shell in the Swift tests
records the calls).

### 3. The two shells (`apps/`)

`apps/KajoShell-macOS/` (AppKit) and `apps/KajoShell-iOS/` (UIKit), Xcode
projects depending on the root package, bundling the kernel image built by
a build phase (`swift run kajo build-image` with the PATH toolchain; the
image is bytes, the same on both platforms). Launch arguments (the
experiment's `key=value` form) select the mode; both shells share the
Swift that is not platform-specific (a `KajoShellCore` target or a folder
both projects compile):

- `mode=tests`: run the kernel's SUnit tests with the NDJSON stream to
  stdout and to a file (Documents on iOS, copied back with `devicectl`),
  the summary and JUnit as `kajo test` writes them;
- `mode=golden`: the kasm and Smalltalk kernels of `just golden` with
  their checksums and times;
- `mode=scenario scenario=storm|ring|share|idle gc=... young=... workers=N
  seconds=10`: the module 7 scenarios driven by a real display link at
  the display's rate, a view moved every frame so ProMotion does not
  throttle, the frame account (frames observed, missed at 1.5x the
  nominal interval, p50/p99/max gap), main-thread stopped time
  attributed as ADR 0008's table does, event latency when
  `events=1000` synthetic events per second are handled in Smalltalk, the
  stuck report when `hog=1` loops forever on main, thermal state and
  `phys_footprint` per line, energy where available;
- `mode=demo`: a window built in Smalltalk with the wrappers of section 2:
  a label a slider updates, a button appending to a text view, the
  Transcript in the text view, a background Process hopping to main; this
  is what the owner opens.

iOS kills an app that blocks the main thread at launch: load the image
after the first frame, run headless modes on a background thread, draw a
status view. One run per launch, every result line to stdout and to a file,
as the experiment did. A `scripts/device.sh` (or `just device <mode>`)
builds, installs, launches with `--console` and copies results back.

### 4. Measurements

On the iPhone 13 Pro and on the mini's display, three runs each, medians
with ranges, in the doc's tables beside the Mac headless figures of module
7 and the iPhone 17 Pro figures of `experiments/device-measurement`:

- the kernel tests pass on device (the count, the time);
- the kasm and Smalltalk kernels' checksums and times at 1, 2 and 6
  workers on the phone;
- the scenarios: frames missed of the display's count per 10 s, max gap,
  main-thread stopped time, acknowledgements, under stw, local and offload
  young collection, with the marker and the young collector at the module
  7 QoS policy; where the collector thread lands (performance or
  efficiency core; `thread_policy` or the per-thread counters) and whether
  it keeps up; the share case's acknowledgement cost on the real UI thread
  (ADR 0008's open question);
- 1000 events per second handled in Smalltalk: latency p50, p99, max from
  the time the event happened to the primitive that updated the view;
- the infinite loop on main: frames missed, preemptions, the stuck report's
  time; with the budget off as the control;
- thermal state over a full matrix, the first kernel repeated at the end;
  footprint; energy per scenario if `ri_energy_nj` reads on iOS 27.

Write the evidence into a "Device (9a)" note in ADRs 0003, 0004 and 0008
with the numbers the owner needs to decide on accepting 0004 to 0008
(ADR 0008's last section asks the question); do not change their status.

### 5. Verification

Tests: the host surface (open, turns, events, stuck report, snapshot) with
a test shell in Swift; the wrappers' kernel tests headless and against the
test shell; the two shells build with `xcodebuild` with 0 warnings
(`just apps` or two recipes), and `just ios-check` still passes; the
events the shells emit are the v1 protocol in time order. The usual gate
sequence (below). Nothing in this module may touch the dispatch loop; the
hop primitives and the event queue are off the hot paths (`just
arc-check`); the kasm and Smalltalk kernels within noise of the starting
commit (five interleaved aligned `-enable-testing` runs, 1 and 8 workers).

## Rules

AGENTS.md binds (zero ARC on hot paths, strict memory safety with every
unsafe construct marked and counted, tests on CPU or work never wall-clock,
every verifier on in checked builds, no new cross-thread protocol without a
model: the event queue should reuse the external-signal queue's protocol;
if it needs its own, model it). Swift closures for GCD or VM threads are
not built inside `@MainActor` methods (ADR 0004). Events carry the time
they happened. The experiments are not modified.

## Open questions for the owner (build to the provisional answers)

1. Wrapper lifetime: a dead wrapper's view is released by the finalization
   Process (Ephemeron); a window's views live while the window does.
2. The kernel's UI classes are plain wrappers (Label, Button, ...) with
   the native class behind a primitive; no layout system in 9a (frames set
   in points), no SwiftUI ever (ADR 0004).
3. The event queue carries the shell's events only; Smalltalk-to-Smalltalk
   messaging stays Semaphores and SharedQueues.
4. The iOS shell is a single full-screen window; the macOS shell one
   window per Smalltalk Window.
5. 9b (the development protocol, the developer UI with AI agent
   integration, remote compile and install) is briefed after the owner
   answers 8b's question 4 and this module's measurements are in.

## Deliverables

`Sources/KajoVM/Shell.swift` (public surface), `kernel/` wrappers and
their tests, `apps/KajoShell-macOS/`, `apps/KajoShell-iOS/`, shared shell
Swift, `scripts/device.sh`, just recipes, ADR 0010 (proposed), the
"Device (9a)" notes in ADRs 0003, 0004 and 0008, terms in
`docs/CONTEXT.md`, and this file replaced below its title by the as-built
doc in the style of `docs/modules/kernel-image.md` (what it hides, the
host surface with every public symbol, the wrappers, the shells, the
measurements with tables, changes to earlier modules, deviations with
reasons, tests, unsafe surface, hot-path check, not done, gates with the
commit, commands, and what the owner must do by hand if anything needed
the owner). AGENTS.md and PLAN.md are the main session's.
