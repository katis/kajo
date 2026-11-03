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
   second while every other VM thread woke zero times; untimed, 0.08.
   Idle threads wait untimed, and before removing a timeout audit every
   transition the wait depends on for a signal under the lock and add a
   test that work after idling completes within a bound.
 - A wall-clock assertion in a test (a 300 ms spinner accrued 200 to 400 ms,
   N wakeups in a window) fails under load. Assert agreement between two
   readings of the same quantity, or run until a CPU budget is spent. The
   idle test's CPU probe was the latest instance: a 50 ms window gave the
   spinner 23 ms under ThreadSanitizer and twelve busy loops; it now spins
   until the probe has seen 30 ms. A CPU bound is not safe either when the
   sanitizer inflates the work it bounds: the main-thread hog's turn, bounded
   at 20 ms of CPU for a 1 ms budget, cost 24 and 28 ms in the full suite
   under ThreadSanitizer (alone it passes every run on two commits); such a
   bound gets a sanitizer value of its own through `underThreadSanitizer`.
 - "Wait until the Process is running" is not "wait until its frame holds
   the object": the state is set before the frame is installed. Tests that
   need a value on a stack wait on a flag the program sets after the store.
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
 - A generated `Opcode(rawValue:)` was an out-of-line call per bytecode and
   cost a third of fib. The dispatch loop decodes with one compare
   (`Opcode.decode`), and `just arc-check` asserts the loop is exactly one
   indirect branch and one jump table so the regression cannot return
   silently.
 - Frame links (caller pc, fp, hdr) are SmallInteger offsets and indices,
   never addresses. Methods move under compaction and stacks will move with
   Processes; with offsets nothing inside a stack needs fixing after either.
 - A loader's stack-depth check must trace every path through the method; a
   linear scan is unsound for untrusted input, and a unary
   `doesNotUnderstand:` at the deepest operand slot pushes one word past the
   computed maximum. Frames reserve that word and a guard past the stack end
   catches the next such case.
 - Class, Method and MethodDict are sealed from Smalltalk (no primitive
   reads, writes, creation or become; no ivar access in their methods) or a
   verified method's bytecodes could be rewritten at run time.
 - A stress mode that preempts at every poll livelocks: a Process preempted
   at a send is resumed at that send and preempted again. Every slice must
   execute at least one instruction; the stress flag lets the first poll of
   a slice through, and that configuration is its regression test.
 - A lock-free push is not a lock-free wakeup. Waking an idle worker that
   waits untimed needs the scheduler lock, or the signal can land between
   its check and its wait and be lost. The push stays lock-free; the wake
   takes the lock.
 - Incremental builds hid 82 unmarked unsafe constructs; the strict memory
   safety warnings appear only on a clean build. Clean-build before
   counting or claiming the unsafe surface.
 - A rule whose broken variant traps (register flush before a stop) cannot
   live in the suite; run it by hand and record the trap message in the
   module doc. Rules whose broken variants fail a verifier go in the suite
   as test switches (parked count, publish order, result register).
 - Verifiers at every stop (no parker returns while the stop works; workers
   and Process records name each other) cost nothing measurable and are
   what turns a broken-protocol test switch into a failing test.
 - Put the interpreter state at offset 0 of the worker, so the interpreter's
   state pointer is the worker pointer and the hot path pays no second load.
 - The relocation model (docs/models/relocation.md) found four things the
   SPEC left to the code: `enterVM` must store epoch 0 before the current
   epoch or a block is freed under an entering worker's pointer; the
   relocator's scan of epoch words wants seq_cst, not acquire, for the
   argument to hold under C++ rules; "the relocator polls only between
   objects" is a liveness rule (a park between the CAS and the switch
   deadlocks every spinner in the post-store and hazard slow paths, so
   to-space allocation stays before the CAS); and reads of a new body rest
   on an address dependency the compiler does not promise, so the body
   address is always computed from the offset just loaded. Both halves of
   the post-store check must be seq_cst, each on its own.
 - A model with switches is believed only when each switch off finds its
   violation. The first run's "violation" of a claim was a modelling bug (a
   buffered revert at a pause) that also exposed an unstated fence in the
   SPEC; write both kinds of finding down.
 - The young-collection model (docs/models/young-collection.md) found that
   a relaxed store followed by the barrier's seq_cst load of the remembered
   word can be overtaken by that load (C++ and ARMv8 both allow `str` then
   `ldar` to reorder), so a concurrent collector's clear-then-scan misses
   the store and nobody re-arms the holder. Every store that a barrier's
   load follows is seq_cst or has a seq_cst fence before the load; the
   experiment's array-copy primitive got this wrong. The same model showed
   the owner's new-half scan alone covers amendment 7 and the snoop is
   belt and braces, that the wake from a quiescent wait must store epoch 0
   like `enterVM`, and reproduced both the single-round loss under
   sequential consistency and the deferred-entry double free.
 - In a shared working tree never `git mv`: it stages the rename for every
   agent, and another agent's commit by name can carry it. Move with plain
   `mv` and add the new path when committing.
 - Sweeping young entries from a per-nursery stash costs about 0.07 ms per
   4 MiB nursery, nearly all of a churn scavenge (p99 0.53 ms at 8 workers
   against the experiment's 0.32 with chunk bitmaps). The choice is behind
   the module boundary; the cost is a known item, not a surprise.
 - A slice's first budget check never preempts. The stress-mode livelock
   had a second form: a stop longer than the slice preempts the resumed
   Process at the send it was rewound to, forever (187k stops in 600 s
   under ThreadSanitizer). Any rule of the form "preempt when the deadline
   passed" needs "but not before this slice ran one instruction".
 - Parked workers join the parallel scavenge, so the main thread copies in
   every scavenge it is parked in. Report that time (`collectorNs`) apart
   from the turn's own CPU, and keep it out of the turn-overrun bound.
 - Every module 1 operation that assumes nothing young (collect, compact,
   become, forward, reshape, snapshot) runs a promote-all first through one
   hook, rather than each caller remembering to.
 - Timers in tests (pending-root delays) at 80 ms fired early under load
   relative to the test's own clock; 1.5 s is the floor for a timer a test
   waits on.
 - Device iteration is fast: about one second per launch over `devicectl`,
   with stdout streamed. Design device benchmarks as one kernel per launch
   so a crash costs one run and thermal state is logged per launch.
 - A snapshot-at-the-beginning barrier records stores, not loads. A
   referent held only weakly at the snapshot, read through its weak slot
   and stored into an already scanned object, was swept under a live
   reference. Weak reads during marking need a keep-alive barrier; the test
   that fails without it is in the marking suite.
 - The marking snapshot set is an old map, one bit per entry set exactly
   while the entry holds an old object, maintained by old allocation, the
   entry sweep and the lazy sweep. Copying it is 0.02 to 0.05 ms for
   millions of entries; a used bitmap would have cost an atomic per eden
   allocation and still needed the survivors subtracted.
 - A test variant whose broken protocol is a data race by construction
   (a released worker running inside the next stop) is a ThreadSanitizer
   report, not a failing check. Skip only that variant under the sanitizer
   and keep it in every other build, as trapping variants are run by hand.
 - A trigger must watch every resource a fallback can exhaust. `alloc`
   filled a 16.7 million-entry table before its blocks reached the
   occupancy floor and fell back with no cycle ever started; the entry
   table got a floor of its own.
 - A marking cycle is cheap to abandon; a lazy sweep is not. Once entries
   sit in pending runs, abandoning the sweep would leave them owned twice,
   so a module 1 operation finishes and applies the sweep in its pause and
   abandons only marking.
 - "If no pause comes" cannot be decided without a timer. The sweeper
   requests its own short apply stop when it finishes, unless a scavenge
   applied first; a module with no timed wait has no other way.
 - A terminated Process's result slot is a root. Tests that expect
   objects to be reclaimed must release the Processes that answered them,
   or the "dead" objects stay reachable through the host's Process roots.
 - Every mutator load of a state word or a slot that a relocator may write
   concurrently is a relaxed atomic load, for ThreadSanitizer and for C++;
   on arm64 it is the same `ldr`. The compiler does not merge atomic
   loads, so a send and a return that read the method's state word five
   times cost 4 to 6 percent until they read it once.
 - A verifier at every pause can starve the program it verifies. An
   O(entries) relocation verifier at every host inspection stop kept the
   world stopped most of the time and the utility-QoS marker missed its
   bounds under load. Run a verifier at the pauses that follow the work it
   checks, and measure the verifier's own cost under load.
 - ThreadSanitizer does not intercept `vm_allocate` and `vm_deallocate`,
   so its shadow survives address reuse and two tests whose side tables
   happened to share an address were reported as a race. Reserve with
   `mmap` and `munmap`, which it intercepts.
 - Pins for good are not a test switch. Turning them off moved a running
   method's bytecodes; the block was freed by epoch and reused as to-space
   under the worker's pc. Only frame pins can be switched off in a test.
 - Block stamps alone do not keep an allocator out of a block being
   evacuated: a selected block with a tail is still in the pool. Selected
   blocks leave the pool at selection.
 - A concurrent pass that polls at every object makes one object of
   progress per stop under a stop storm (a host polling counters every
   0.5 ms under ThreadSanitizer left a cycle unfinished in 30 s). Poll
   every N objects or bytes, still only between objects.
 - The marker is a stopper too, and at utility QoS twelve default-QoS busy
   loops starved one final mark to 20 s. A QoS policy for a thread has to
   cover every role it plays, the stopper role included. Module 7 settled
   it: a stopper outside the worker table is raised to user-initiated for
   its stop and restored afterwards, counted as `stopperQoSRaises`.
 - For an A/B of two binaries, build both with
   `-align-all-nofallthru-blocks=5 -align-loops=32`: `storeheavy` was 6
   percent slower in plain builds and 0.3 percent in aligned ones, and a
   build with the check removed was within 0.5 percent of a build with it.
 - A stop request must wake every participant waiting inside the VM, on
   whatever condition it waits: an opener waiting for a wanted stop slept
   through the request and the stop waited for it forever (the suite hung
   once, the marker's final mark against two openers). Every wait inside
   the VM is a place a stop must reach; the stop request broadcasts, and
   a requester leaving `stwWanted` wakes the openers.
 - Any thread that reads entries between polls is an epoch participant,
   not only the mutators: the young collector reads other nurseries'
   holders, so collections and the relocator wait for its epoch word too.
 - A handshake protocol charges every participant a fee per round, so it
   wins where stops were long and loses where they were already short:
   under the storm the main thread stops 5 times less than stop-the-world,
   under `share` it stops more (195 against 139 ms per 10 s), because many
   cheap collections cost one 28 to 44 µs acknowledgement each. The
   acknowledgement on the main thread is the number to watch on device.
 - Tests that count work under ThreadSanitizer and load assert on what
   must have started, not on what completed: ten small random programs
   completed no marking cycle in a loaded sanitizer run and the tally
   failed; counting cycles started is the honest assertion.
 - An agent's background `until` loop waiting for a line in an output file
   outlives the agent when the line never comes, and the session counts
   the agent as still waiting. Waits in agent sessions are bounded or
   rely on the harness's own completion notice.
 - A bigger dispatch loop costs register allocation before it costs
   instructions: with the 50-case v1 switch, inline fast paths spilled the
   heap and table bases and the loop loaded `fp` and `hdr` as one vector
   pair and unpacked them at every dispatch (5 to 23 percent on every v0
   kernel). The remedy was the disassembly, not the instruction count:
   fast paths that need extra live values run out of line as one call from
   their own case, hot pointers are not neighbours in the register struct,
   and an empty frame's context word is an immediate so the return compares
   against a constant. The loop keeps one jump table.
 - A header-bit test in the store path costs about two cycles per store and
   shows only on a kernel that does nothing but store (`storeheavy` 1.07 on
   one worker, 1.10 on eight, parity with the bit out of the mask); the
   kernels that load as well do not see it. The read-only bit is that cost;
   ADR 0009's Built note raises it for the owner.
 - `just arc-check` depends on the toolchain: swift.org 6.4.2 hoists the
   jump table's address into a register (named by a section label) and
   inlined a Swift array append into `runRound`, so module 7's own commit
   failed the check on the toolchain the mini uses while passing Xcode's.
   The script reads both forms now and the append is out of line. Run the
   gates on the toolchain first on PATH and say which one in the doc.
 - Once immediates beyond SmallInteger exist, every "is this a reference"
   test is the full low-nibble pattern. Six insertion-barrier sites tested
   `raw & 1`; with one put back the VM dies with signal 11 under the random
   programs. Test the SmallInteger bit first (one `tbnz`), then the rest, so
   the common case stays one instruction.
 - A collector's compare-and-swap on a live header must expect a concurrent
   atomic bit flip from a mutator (the read-only primitive's `or`): keep the
   foreign bit, retry, and count any other change as the bug it is. The
   "mutators never set bits in a live header" rule is about non-atomic
   writes.
 - An image loader guards every slot read by the holder's size and kind
   before trusting it: the snapshot fuzzer flipped one bit, a well-known
   class's name became a Character, and the loader dereferenced it (signal
   11 in release). The runtime verifier is not the loader's trust boundary:
   it skips a deferred free's body on purpose (the body may be reused), so
   a snapshot with a deferred-free entry whose offset lay outside the heap
   passed it and the marker read the offset; the loader now refuses what a
   promote-all makes impossible (young and deferred-free entries). And a
   fuzz run can silently be the fallback driver: the libFuzzer build failed
   because swiftly refuses `TOOLCHAINS`, so 600 s of "fuzzing" was replay
   and mutation without coverage, and the first coverage-guided run found
   the second crash in 3.8 million inputs. Read the "libFuzzer build: ok"
   line before counting a fuzz gate.

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
budgeted preemption (proposed, built headlessly in module 3; pending a
pause-bounded collector and the shell's 120 Hz measurement), 0005
generational collection with per-worker nurseries (proposed, built in module 4), 0006
concurrent marking and lazy sweeping of old space (proposed, built in module
5: the final mark is 0.11 to 0.14 ms p50 at 8 workers from 64 to 512 MiB of
live old data, the barrier costs 1.4 percent on `ivars` with marking off), 0007 age field with survivor
spaces and concurrent relocation of old space through the entry table
(proposed; old-space work is off the frame budget, scavenges remain; the age
half is built in module 4, the relocation half is model checked in
`docs/models/relocation.md` and built in module 6: the post-store check is
within noise on the hot kernels in aligned builds and 5 to 10 percent on
cache-missing stores, `fragment` ends at 18 MB against 240 with relocation
off, zero stores redone on the hot kernels), 0008
young collection without stopping the world, offloaded for the main thread
and local for background workers (proposed; no collector pause on the main
thread exceeds a frame, acknowledgements and the initial mark remain; model
checked in `docs/models/young-collection.md`, which found the array-copy
store ordering hole; built in module 7: the main thread's stopped time
under the allocation storm is 5 times lower than stop-the-world and comes
in acknowledgements of 28 to 44 µs, the share scenario is the one case
that is worse, and ADR 0008 raises the acceptance question for 0004 to
0008 for the owner), 0009 object
model and bytecode set (proposed, accepted in principle: weak slots and
ephemerons, immediate SmallFloat and Character, native frames materialized
into Contexts on demand, compiled closures with temp vectors, frame-walk
unwinding, classic metaclasses, UTF-8 strings, read-only bit, bytecode set
v1, unsynchronized kernel collections; its first three sections precede
module 5 and module 3 reserves the frame's Context slot; sections 2 to 11
built in module 8a: SmallFloat round-trips bit for bit against `Double`,
the dispatch loop keeps module 7's register budget with the v1 fast paths
out of line, the hot kernels are within noise of module 7 and `storeheavy`
is 1.07 to 1.10 from the read-only check, and the Built note holds the
open questions for the owner: inline `class`/`isNil`/`notNil`, the
`attemptToModify:at:value:` spelling, the strong symbol table, Processes
in images). ADRs
0003, 0006 and 0008 carry device measurements from an iPhone 17 Pro
(experiments/device-measurement and entry-locality) and energy measurements
(experiments/power: marker at utility, young collector at user-initiated on
device; the marker's timed wait is the VM's whole idle cost). Read them before touching the areas they
cover.

## Project structure

 * `Package.swift` is the root SwiftPM package: `KajoVM` library, `kajo`
   headless CLI, `KajoVMTests` (Swift Testing).
 * `Sources/KajoVM/` the VM core, one directory per module:
   `ObjectMemory/` (module 1, built; `docs/modules/object-memory.md`),
   `Interpreter/` and `Loader/` (module 2, built; `docs/modules/interpreter.md`),
   `Workers/` and `Processes/` (module 3, built; `docs/modules/workers.md`:
   workers, safepoints, Process-owned stacks, scheduler, budgeted
   preemption, external signals, the seeded random-program generator and
   `just soak`), `Nursery/` with `ObjectMemory/Generations.swift` (module 4,
   built; `docs/modules/nursery.md`: per-worker eden and survivors, age and
   claim tags, barrier and remembered set, parallel stop-the-world scavenge,
   entry stashes, weak slots, ephemerons in the oracle, the finalization
   queue, snapshot v2), `Marking/` with `ObjectMemory/OldMap.swift` (module
   5, built; `docs/modules/concurrent-marking.md`: old map and snapshot map,
   SATB barrier behind the flag word, the marker thread as a VM participant,
   initial mark at the end of a scavenge, final mark with the remembered
   filter, ephemerons and weak slots, lazy sweep into pending runs applied
   at the next pause, triggers and counted fallbacks, the QoS policy, the
   final-mark verifier; `kajo run --gc cm|stw`), `Relocation/` (module 6,
   built; `docs/modules/relocation.md`: the post-store check in every heap
   store, pins for good and frame pins, hazard slots and the array-copy
   primitive, epoch words and pending blocks, selection by live bytes,
   the relocation pass on the marker thread between final mark and sweep,
   the relocation verifier, the model-step table; `kajo run --reloc
   on|off`), `YoungCollection/` (module 7, built;
   `docs/modules/young-collection.md`: rounds on the attention word,
   proxies and blocking regions, local and offloaded collections through
   module 6's copy protocol, per-nursery remembered sets with carried
   lists, deferred entry frees owned by their nursery, the epoch rule with
   the quiescent wake's zero, the young collector thread, the initial
   mark's young-root scan, the young verifier, the model-step table;
   `kajo run --young stw|local|offload --main-ms`), `ObjectModel/` with
   the v1 parts of `Interpreter/` and `Loader/` (module 8a, built;
   `docs/modules/object-model.md`: SmallFloat and Character immediates,
   the class format word and classic metaclasses, bytecode set v1 with
   the `ext` prefix and one bytecode verifier, closures, temp vectors,
   Contexts materialized on demand and detached on return, non-local
   return and the unwind and handler walks, super and the `perform:`
   family, method installation in a stop, LargeIntegers and boxed Float,
   the UTF-8 String and interned Symbol primitives, read-only bit 50 in
   every store path, stack growth by copying, pragma literals, the image
   format and its loader; 8b, the Smalltalk side, is next), `Headless.swift` the public entry `kajo run` uses. `Sources/kajo/` the
   CLI; `Sources/fuzz-kasm/` and `Sources/fuzz-snapshot/` the libFuzzer
   targets (`just fuzz kasm|snapshot <seconds>`, needs a swift.org
   toolchain; Xcode's ships no libFuzzer runtime). `scripts/`:
   `check-hot-path-arc.sh` (`just arc-check`) greps the release disassembly
   of the dispatch loop, send, primitive and allocation paths for retain and
   release and asserts the loop is one jump table; `golden.sh` (`just
   golden`) runs the fixture kernels through `kajo run` against their
   published checksums; `just test-release` runs the suite in a release
   build with the full-size kernels.
 * `kernel/` Smalltalk sources the image is built from. The image is never
   committed.
 * `apps/` Xcode projects for the macOS and iOS shells, depending on the root
   package. Not created yet.
 * `experiments/` throwaway spikes with a design brief and results each.
 * `docs/PLAN.md` the module order for building the production core from
   the experiments; `docs/modules/` one brief, later description, per module.
 * `models/` a separate SwiftPM package holding the exhaustive interleaving
   models of the concurrent protocols (`cd models && swift test`;
   `docs/models/` one brief, later description, per model). The relocation
   model precedes module 6 and is updated in the same commit as any change
   to the protocol.
 * `docs/CONTEXT.md` domain vocabulary. `docs/adr/` one decision per file.
   `docs/VERIFICATION.md` how the experiments become the production core
   and what verification that core needs beyond tests and ThreadSanitizer.
 * `references/` contains prior art and other references we might benefit from
   in the design. Gitignored; see `references/MANIFEST.md`.
 * `justfile` has the common commands: `just build`, `just test`, `just run`,
   `just bench`, `just ios-check`.
