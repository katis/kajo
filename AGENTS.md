# Kajo

Kajo is my dream programming language project.

I want a Smalltalk that renders native UI (for now, macOS and iOS) and makes live development possible.

Performance must be considered carefully and research of multithreaded and state-of-the art VM designs is needed.
iOS doesn't allow JIT, so a snappy VM and GC is needed. We don't want to make scrolling and animations choppy.

We must find a way to make development smooth (no VM to UI thread delay), while making it hard to lock up the UI thread by accident.

## Use cases
 - Develop iOS app remotely and live from Macbook, with a Smalltalk developer UI in the Macbook with AI agent integration
 - Debug, with all the Smalltalk magic
 - Build and release an iOS or Macbook app

## Design principles:
 - Live, image based development is the key
 - Research state-of-the art
 - But also experiment and invent, be creative
 - Do not lock in a tight roadmap, a step or two at a time, rest are ideas
 - References are for inspiration and research, not for copy-paste. This is a greenfield project, no legacy cruft.

## Development principles:
 - Experiment technical details carefully before locking in designs.
 - "Modules hide decisions, not just data"
 - Use TDD wherever possible

## Implementation language

Swift, for the VM core and the native shells alike (ADR 0001). Smalltalk for
everything above the primitives. The choice was made by building the same VM
slice in Rust and Swift and benchmarking it; see
`experiments/vm-language-bench/RESULTS.md`.

### What the experiment taught us about Swift

Performance:
 - Swift `-O` matched Rust within 1 to 8 percent on dispatch, sends and
   allocation kernels once code alignment was controlled. A raw `-O` build
   looked 17 to 31 percent slower, and almost all of that was where the loop
   landed in memory, not safety checks. Benchmark with alignment in mind, and
   do not read a single run as a language verdict.
 - `-Ounchecked` bought nothing the alignment did not. Keep `-O`.
 - A `switch` over bytecodes compiles to one jump table, but a `case a, b:`
   sharing a body split it into two tables plus a compare and cost 12 percent.
   One opcode per case in the dispatch loop. Check the arm64 assembly when
   touching it (`swiftc -S` or `otool -tV`).
 - Zero ARC traffic in the hot path is achievable but only by design: VM and
   worker state are structs in raw memory, state is passed by value or
   pointer, no classes or existentials inside the interpreter, GC, allocation
   or send paths. Grep disassembly for `swift_retain` and `swift_release`
   after changes there.
 - The hot path must opt out of traps explicitly: `&+ &- &* &>>`,
   `truncatingIfNeeded:`, `unsafelyUnwrapped`. Everywhere else keep the
   default trapping arithmetic and bounds checks; they are a safety net.
 - Runtime exclusivity enforcement cost nothing measurable. Leave it on.
 - Pad every per-worker state struct to its own 128-byte cache lines. The
   first experiment's "allocation scales only 4.3x" was partly false sharing
   between adjacent worker structs; padded, compute kernels scale 7.4 to
   7.7x and allocation 5.3x, the rest being single threaded marking.
 - Pass interpreter registers as scalars into slow paths. Passing the
   register struct by memory spilled all of them on every send.
 - `@inline(__always)` did not inline the send path; `@_transparent` did.
 - Clean release builds take about twice as long as the Rust equivalent.
 - The VM module cross compiled for iOS without changes. `just ios-check`.

Safety:
 - The VM core is raw pointer code in any language; the compiler verifies
   nothing about the shared heap. Correctness comes from the tag scheme, the
   header format, the safepoint protocol, tests, and ThreadSanitizer run as a
   gate (`swift test --sanitize=thread`), not as a report.
 - `KajoVM` builds with strict memory safety on, so every unsafe construct
   must be written with the `unsafe` keyword and the trusted surface is
   greppable. Keep that surface small and inside the object memory, GC and
   interpreter. Nothing outside the core should need `unsafe`.
 - Swift 6 strict concurrency is irrelevant inside the core. Raw pointers are
   `Sendable` and workers are `pthread`s, so the checker sees no sharing. It
   matters at the VM to shell boundary: shells are `@MainActor`, messages
   from VM threads to shells are `Sendable` snapshots, and a VM thread
   touching a view is a compile error. Use it there.
 - VM workers are OS threads, never Swift `Task`s. Do not block the
   cooperative pool.
 - Avoid global mutable state in the VM. Everything hangs off one VM state
   struct reached through a pointer; this also keeps Swift 6 mode free of
   `nonisolated(unsafe)`. But that struct must hold pointers to separately
   allocated sub-states, one per lock. Writing different fields of a single
   struct under different locks is reported by ThreadSanitizer as a Swift
   exclusivity race.
 - A closure written inside a `@MainActor` method is main-actor code, and
   Swift 6 traps at runtime when GCD or a VM thread runs it. Build callbacks
   handed to other threads outside main-actor context.
 - Timestamp events with the time they happened, never the time they were
   enqueued, or a stall between the two is invisible to every measurement.
 - Once objects move, host code may not read heap objects outside the VM.
   Inspection from Swift enters the VM like a primitive does.
 - Mutators must not set bits in a live object header that other workers
   read concurrently. Side tables (a byte map beside the entry table) are
   the pattern for marks set from the hot path.
 - In a stop-the-world protocol, a worker released from one stop must not be
   counted as parked for the next. This bug hid until two pauses came close
   together; the regression test is in experiments/generational-gc.
 - Blocking on a safepoint mutex at VM entry and exit is not VM work. Keep
   wait time and work time separate in every measurement.
 - A slow path called from the interpreter loop must be one out-of-line call
   with nothing of the current instruction live across it. One extra call
   site cost 20 percent through register pressure before it did any work.
 - Collector threads at low QoS land on the efficiency cores when workers
   are busy and run at a third to a half of their speed. Set their QoS
   deliberately; it decides whether the collector keeps up.
 - In a generational heap, take the concurrent-marking snapshot at the end
   of a scavenge, when nothing is young. A snapshot taken while young
   objects exist loses old objects reachable only through them. The failing
   test is in experiments/concurrent-marking.
 - Concurrent collection needs old-space headroom proportional to the
   promotion rate. Fallbacks to stop-the-world are a provisioning failure to
   count and report, never to hide.
 - `Atomic` is non-copyable, so a struct holding one inline becomes
   `~Copyable`. There is no clean way to treat a raw object header word as an
   atomic; parallel marking will need its own design.
 - Survivor-space size, not the promotion age, decides whether an age field
   helps. Size the nursery to the live set per worker at a scavenge; N = 2
   against N = 4 changed nothing, 4 against 16 MiB changed promotion 15x.
 - Every invariant that leans on "nothing is young after a scavenge" breaks
   once survivor spaces exist: the claim bit, the remembered set, and the
   marking snapshot (survivors must be roots). Write the test before adding
   the age.
 - A post-store check needs seq_cst on the store and the following load of
   the state word; release/acquire lets them reorder and loses the store.
   The failed-check path must be one out-of-line call that redoes the store
   and runs the barrier, or register pressure costs more than the check
   (58 percent before, 1 percent after).
 - With the object table, concurrent relocation needs one atomic switch per
   object, a store check, pins for the two raw pointers the interpreter
   caches, and epoch freeing. Keep raw body pointers out of the interpreter
   and primitives; every one you add is a pin or a hazard slot.
 - ThreadSanitizer cannot see that two mappings of the same memory alias.
   Any protocol built on a double mapping is covered by tests and the
   ordering argument only; say so where the mapping is created.
 - In a concurrent collector the roots are the problem, never the copying.
   Any handshake protocol needs a barrier-on round before any stack is
   scanned; a single round is unsound even under sequential consistency.
   Write the lost-object test before the protocol.
 - An owner that keeps allocating during its own collection is a root
   source: its fresh eden must be scanned and stores into it snooped.
 - Lists of heap references kept across a concurrent collection (remembered
   sets, deletion records) can name entries freed and reallocated meanwhile.
   Free such entries only after an epoch.
 - Keep per-object atomics and side-table scans out of copy loops. One CAS,
   one fence and one hazard-slot scan per object halved the copy rate.
 - Interpreter registers are roots. The `result` register kept dead objects
   alive and only a test that must fail without the rule found it.
 - Pause maxima depend on the OS descheduling any VM thread. Report p50 and
   p99 with the max, name the slowest participant, and re-measure on device
   before trusting a maximum.
 - The iPhone runs this interpreter twice as fast as the M2 Max on one
   thread and slower across workers; four of its six cores are efficiency
   cores. Any collector or marker thread at utility QoS runs on them and
   can be 5x slower; on a phone QoS decides whether a cycle completes.
 - Device numbers carry a thermal state. The phone went from nominal to
   serious in 12 minutes of matrix and ran up to 15 percent slower; cooling
   took 7 minutes. Log `ProcessInfo.thermalState` on every result line,
   repeat the first kernel at the end, and compare only configurations run
   back to back.
 - The object table costs 2x per cache-missing hop and 1.8 to 2x marking
   time against direct pointers on both machines; the phone's 4 to 7x was a
   power regime, not cache or translation reach (experiments/entry-locality).
   Entry locality (entries in the body's page) bought nothing: one page walk
   is under 5 percent of a 250 ns hop. Count dependent misses, not bytes.
 - A single latency-bound thread on an idle iPhone P cluster runs in one of
   two regimes from launch to launch, the slow one 2.5 to 4x per miss, for
   every representation. A thread that only spins on the other P core
   removes it. Before reading a single-thread device number, check the
   per-launch spread and whether the rest of the cluster was idle.
 - Default pthread attributes give workers QoS `default` on Darwin, not
   user-initiated. Log the QoS each thread actually got on every result
   line; the first three experiments' workers ran at `default`.
 - The phone core overlaps little independent work with an outstanding miss
   (55 ns of multiply-adds per hop added nearly all of itself; the M2 Max
   hid it). Interpreter work per object is not free under a miss there.
 - Any variant that ties block size to page size makes block size a
   correctness parameter and forces a second arena for large objects. Do
   not pay that for a locality gain you have not measured.
 - Energy on iOS: `ri_energy_nj` from `proc_pid_rusage` is the process's
   CPU energy; `ri_billed_energy` is work others did on its behalf and falls
   when the app gets busy. Per-thread and per-core-type energy comes from
   `proc_pidinfo(PROC_PIDTHREADCOUNTS)`, a private flavor that worked on
   iOS 27. Neither counts DRAM, display or the render server; say so.
 - The phone's single-thread slow regime is not a power-saving state: 1.4
   to 1.5x the CPU energy per hop at a higher clock and half the IPC. A
   `wfe` loop on the other P core prevents it for 0.3 W; a spin costs 2.9 W;
   timers and a utility-QoS spin do not prevent it (experiments/power).
 - Below about 50 MB/s of allocation the whole app, main thread included,
   runs on efficiency cores whatever QoS you ask for, and the collector's
   QoS changes energy by under 10 percent. QoS matters from 100 MB/s up;
   there the marker at utility costs a fifth of the energy per cycle and
   kept up, and the young collector at utility made the main thread wait.
   Mixed is the device policy: collector user-initiated, marker utility.
 - A timed wait in a thread that has nothing to do is the whole idle cost
   of the VM: the marker's 1 ms wait woke the phone 130 to 580 times a
   second while every other VM thread woke zero times. Idle threads wait
   untimed; measure wakeups per second with `ri_pkg_idle_wkups` and ask
   for zero.
 - An empty Smalltalk turn on every 120 Hz frame costs nothing beyond the
   display link itself.
 - A test that fails only under CPU load is a real schedule-dependent bug.
   Run the suite under load on purpose (a dozen busy loops) as part of the
   gate; the lost-object bug in ADR 0008's deferred entry frees was idle-safe
   in 20 runs and failed 1 in 4 under load.
 - Read the `verify:` message before naming the suspect. The test was
   called "parallel scavengers" and the failing check was the concurrent
   mark verifier in a different collector mode; the brief pointed at the
   wrong protocol and the agent had to find that out first.
 - Every entry state between generations needs exactly one owner. An entry
   that is "used but in no young log" is read as old by the snapshot and
   the sweep; deferring a free without hiding the entry from the old-space
   collector let two collectors free it. Whenever a protocol adds an
   in-between state, list every reader of the entry table and every
   verifier's skip rule and make them agree in the same commit.
 - Checksums do not see every lost object; the mark verifier does. Keep
   the verifiers running in at least one scenario per benchmark and treat
   one failure as a bug, never as noise.
 - Strict memory safety cost the object memory 211 `unsafe` sites in 2,200
   lines and forced no design change; the SDK differences (`mach_task_self_`
   needs `unsafe` on macOS and warns on iOS) go behind one accessor.
 - A plain release build strips every internal function nothing public
   calls, so a disassembly check of internal hot paths needs
   `-enable-testing` and a separate scratch path (`just arc-check`).
 - A lock inside the struct it guards is a Swift exclusivity race to
   ThreadSanitizer when one thread reads the lock through the struct while
   another writes a field under it. The lock lives beside the struct, not in
   it; this is the same rule as one sub-state per lock.
 - `mach_vm.h` is unsupported in the iOS SDK; use the `vm_map` family with
   the same arguments. The double heap mapping needs no entitlement.
 - Device iteration is fast: about one second per launch over `devicectl`,
   with stdout streamed. Design device benchmarks as one kernel per launch
   so a crash costs one run and thermal state is logged per launch.

## Verification

Experiments are evidence, not production code; `docs/VERIFICATION.md` says
how the production core is built from them and lists the verification
layers it needs: a checked build with every verifier on, the stop-the-world
collector kept as an oracle, stress modes, randomized programs, schedule
perturbation, a model of the concurrent protocols, loader fuzzing, counters
as telemetry, and device runs. Read it before starting `Sources/KajoVM`.

## Decisions

Decisions live in `docs/adr/`, one per file, each pointing at the experiment
that produced its evidence. Current: 0001 Swift for the VM core, 0002
repository layout, 0003 object table for object representation (accepted;
2x per cache-missing hop and 1.8 to 2x marking against direct pointers,
entry locality rejected), 0004 Smalltalk UI code on the main thread with
budgeted preemption (proposed, pending a pause-bounded collector), 0005
generational collection with per-worker nurseries (proposed), 0006
concurrent marking and lazy sweeping of old space (proposed; pauses no longer
depend on heap size, given old-space headroom), 0007 age field with survivor
spaces and concurrent relocation of old space through the entry table
(proposed; old-space work is off the frame budget, scavenges remain), 0008
young collection without stopping the world, offloaded for the main thread
and local for background workers (proposed; no collector pause on the main
thread exceeds a frame, acknowledgements and the initial mark remain). ADRs
0003, 0006 and 0008 carry device measurements from an iPhone 17 Pro
(experiments/device-measurement and entry-locality) and energy measurements
(experiments/power: marker at utility, young collector at user-initiated on
device; the marker's timed wait is the VM's whole idle cost). Read them before touching the areas they
cover.

## Project structure

 * `Package.swift` is the root SwiftPM package: `KajoVM` library, `kajo`
   headless CLI, `KajoVMTests` (Swift Testing).
 * `Sources/KajoVM/` the VM core, one directory per module:
   `ObjectMemory/` (module 1, built; `docs/modules/object-memory.md`).
   `Sources/kajo/` the CLI. `scripts/check-hot-path-arc.sh` (`just
   arc-check`) greps the release disassembly of the allocation and store
   paths for retain and release.
 * `kernel/` Smalltalk sources the image is built from. The image is never
   committed.
 * `apps/` Xcode projects for the macOS and iOS shells, depending on the root
   package. Not created yet.
 * `experiments/` throwaway spikes with a design brief and results each.
 * `docs/PLAN.md` the module order for building the production core from
   the experiments; `docs/modules/` one brief, later description, per module.
 * `docs/CONTEXT.md` domain vocabulary. `docs/adr/` one decision per file.
   `docs/VERIFICATION.md` how the experiments become the production core
   and what verification that core needs beyond tests and ThreadSanitizer.
 * `references/` contains prior art and other references we might benefit from
   in the design. Gitignored; see `references/MANIFEST.md`.
 * `justfile` has the common commands: `just build`, `just test`, `just run`,
   `just bench`, `just ios-check`.
