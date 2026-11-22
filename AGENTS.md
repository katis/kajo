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

## Process

How a module goes from a brief to a pushed, recorded commit (the roles of
the owner, the main session and a build agent, the brief's shape, the
constraints on every agent, verification from files, how this file and
`docs/PLAN.md` are edited, the weekly run and the scratch directory) is
`docs/PROCESS.md`. Read it before starting or verifying a module.

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
   writes, creation or become; no ivar access in their methods) or a
   verified method's bytecodes could be rewritten at run time. Slot reads
   through `slotAt:` (primitive 117) are allowed since module 8b: the
   kernel's reflection needs them and a read rewrites nothing. Since
   module 8d a method enters a class from Smalltalk only through the make
   primitive (143), which runs the one bytecode verifier on what the
   compiler handed over and makes it read-only and pinned before any other
   Process sees it, and the install primitives (97, 98), which refuse the
   sealed classes and release images. Since module 8e a class is defined,
   reshaped or removed from Smalltalk only through the define, redefine and
   remove primitives (145 to 147), which re-check the image build's class
   rules with the build's own code (`ClassRules`), make and verify every
   recompiled method against the new shape before anything changes, and
   refuse while any frame runs a method of the class. Since module 9b the
   sealed classes take a method from Smalltalk only when the verifier finds
   it can do nothing but send: no instance-variable access, no slot store,
   no primitive, no become (the owner's provisional answer to "what about
   extensions?"). The development protocol (9b, `Sources/KajoDev/`, ADR
   0011) is a trust boundary of the same kind: every request is parsed and
   checked in the target, a malformed request is a reply, a release image
   does not serve, and the pairing token is never written to a file. The
   image's client side (9c, primitive 164, `KajoDev.ClientHost`) is the
   same boundary from the other side: the host owns the sockets and the
   token never enters the image, the image sees the transport's operations
   (targets, connect, send, close, timer, and since 9d and the
   project-directory follow-up pairing, project and chooseProject, the
   last three answered by the host's own table or its own panel: the
   image names no token and no directory), every received line is checked
   and a bad one is a `client.error` event, never a trap. Since 9d the
   same server listens on TCP with a Bonjour advertisement, development
   images only and only when asked, three wrong tokens close a connection
   and ten failures in a minute pause the listener; and no token passes
   through the image at all, typed ones included: the target picker's
   Pair asks the host, which takes the token in a secure field of its own
   (the `pairing` op) and keeps it. The primitive is the trust boundary,
   not the compiler.
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
 - A loader checks every structural invariant the collector relies on, not
   only the ones the snapshot writer could get wrong: the snapshot fuzzer's
   third crash named a nil object no root held, the collection after
   loading swept it while the memory still named it, and the same input
   crashes the commit module 8b started from. The fuzzer finds old bugs
   with new seeds; each is a loader refusal and a regression fixture.
 - A fuzz target is also a leak test. The bootstrap compiler's Scope held
   its Variables and each Variable its Scope, every compilation leaked, and
   the syntax fuzzer ran out of memory after 4.5 minutes. A tree of scopes
   has one owning direction (`unowned` back references) and a test that a
   compilation frees them.
 - A gate that counts warnings hides errors: `just ios-check` lacked
   `-package-name`, every file failed to typecheck, and a check that grepped
   for warnings read it as clean. A gate reads the exit status and the
   error count first.
 - An image's size follows the entry table's high-water mark, not the live
   objects: `Smalltalk at:` rebuilt the list of all classes once per
   recorded source, the garbage left the table's peak near 1.25 million
   entries, and the snapshot wrote them all (16 bytes each, after a
   collection) as a 20 MB image of 2.5 MB of objects. A build step that
   makes much garbage runs with a nursery or collects first; 8c's image
   saving inherits the fact.
 - Placement decides single A/Bs even with the alignment flags: one plain
   aligned link of module 8b was 12 to 36 percent slower on every kernel
   with `interpret` identical instruction for instruction, while
   `-enable-testing` aligned builds of the same commits ran at parity.
   Before attributing a slowdown to code, diff the disassembly of the hot
   functions; if it is identical, the number is the linker's.
 - A stop is not a resume point. Module 8a's install stop parks workers
   wherever they are (inside an allocation's stop, a young collection's
   wait, a primitive's own stop), and no register set of a Process parked
   there can be resumed later. The save first holds the scheduler so every
   running Process leaves its worker at a poll, where module 3's preemption
   already makes its registers exact, and only then stops. A new way of
   quiescing the VM is a new protocol: `docs/models/save-hold.md`.
 - A test that asserts parallelism happened (four scavengers, a stop that
   lands while workers run) fails on a loaded machine unless it runs long
   enough to see it. Make the work longer or repeat the round; never weaken
   the assertion to pass when the parallelism did not occur.
 - An operand that fits one byte is checked where it is encoded: the
   assembler trapped on a keyword send of more than 255 arguments, a bug as
   old as the bootstrap compiler that the syntax fuzzer found only in 8c's
   gate run. Every count a bytecode encodes has a refusal and a test at
   its limit.
 - Inlining moves ARC: when the poll's snapshot trigger was inlined into
   `pollSlow`, the arrays it built were retained on the poll path and `just
   arc-check` caught it. Anything that allocates Swift objects stays out of
   line from the paths the check covers.
 - A check runs in the mode the product builds in. `just ios-check`
   typechecked in Swift 5 mode and never saw that Swift 6 mode flags
   `mach_task_self_` as an unsafe global, which Xcode's iOS build of the
   package did; the recipe now passes the package's language mode. Second
   time this gate hid something (8b: `-package-name`); a gate's command
   line is compared with the real build's before it is trusted.
 - A budget renewed by frames starves when no frames come. The shell's
   frame account renewed on the display link, so with no link running
   (headless modes, an occluded window) normal-priority main Processes
   waited forever; it renews by the clock and a turn that left work
   schedules the next. Any allowance tied to an external tick needs a
   clock fallback.
 - Scripted UI measurements need the display awake and the app's launch
   unprompted: an asleep display delivers no frames, and after a crash
   AppKit's "reopen windows" alert held every scripted launch. The macOS
   shell holds a display-sleep assertion while it measures and sets
   `ApplePersistenceIgnoreState`.
 - A fallback the design promised is checked for every mode that can hit
   it. Module 4's precondition says a provisioning failure is counted and
   reported; the stop-the-world oracle's promotion reserve runs out on the
   ring scenario at 600 MiB and the VM traps instead (open, module 9a).
 - A table that is one object has a hard capacity (one block, 4095 slots,
   until module 10's large-object space). 8b's sources table was one IdentityDictionary whose
   Array could not pass 4095 slots; at 1550 methods it died in an
   unhandled error and the build went on with 14 sources missing, because
   the build read only VM errors. Tables that grow with the kernel are
   split (per class), and a Process that ends without an answer fails the
   step that ran it.
 - Recursion over untrusted input is bounded against the smallest stack it
   runs on. A binary chain of thousands of sends overflowed the Swift
   stack in code generation (ASan, `just fuzz syntax`); the parser holds
   chains to the nesting limit. The limit is still deep enough to
   overflow a 512 KB thread in a debug build at about 100 (open, 8d).
 - A refusal is a value, not a trap, at a boundary that takes Smalltalk's
   input: the make primitive answers the verifier's reason as a String
   the kernel turns into a CompileError. Skipping the verifier there made
   a mutated method run and trap in the object memory; the seeded
   mutation test and the make-and-run fuzz mode exist to catch that.
 - When a reserve runs out, suspect the fallback before the sizing. The
   oracle's promotion reserve was sized right; its full collection was a
   mark-sweep that frees only empty blocks, and a load keeping one object
   in twenty per block left old space past its limit for good. A fallback
   that cannot change the outcome is no fallback; it compacts now.
 - A trap that only the oracle mode reaches is still a trap: the
   concurrent modes avoided the exhaustion by sweeping lazily, so no
   headless matrix saw it until the shells ran the ring under every mode.
   The random programs now have a configuration with no reserve so the
   oracle is exercised where it is weakest.
 - A recursion limit is set from a measurement on the smallest stack the
   code runs on, per construct, in a debug build: blocks cost 9.5 KB per
   level there, so 256 levels needed 2.4 MB and a 512 KB test thread died
   at about 100. Chains became loops; the rest is bounded at 32.
 - An invariant the loader checks on load binds every live change. The
   loader requires every method to fit its class and every class index to
   name a class, so a reshape forwards the old methods to their recompiled
   versions (closures follow) and a removal keeps the class object as
   `AnObsoleteFoo`; an image saved after either still loads. Read the
   loader's rules before designing a change the image must survive.
 - A sentinel in a field is a state every reader must handle. A Process on
   its first slice has a saved pc of -1, and the interrupt delivery that
   stepping relies on refused it; found by 9b's gate run, not by its
   tests, because every test stepped a Process that had already run.
 - A hook that resets everything it finds races with everything built
   before it. The saver's resume hook detached every view wrapper,
   including the ones a 9a test built before the hook ran; the test only
   failed under 9b's heavier gate load. A test that builds after a resume
   waits for the resume to have happened (`Smalltalk resumeCount`).
 - Keep a slow feature off the fast path by deciding it where the slow
   path already is. Stepping is decided in `pollSlow` for the stepped
   Process only, as an interrupt it runs when next resumed; `interpret`
   stayed identical instruction for instruction, which `just arc-check`
   and the disassembly diff showed, not the bench alone (fib moved 1.2%
   from link placement).
 - When a tool writes files a person also edits, the tool's output is the
   canonical form and a test asserts byte identity. 8e's image writes
   `kernel/` out byte for byte as it was read; the rewrite to that form was
   its own commit, checked method for method on both builds, so a round
   trip has no normalizing step that can drift.
 - A gate that finishes ten times faster than it used to has changed; find
   out what it skipped before counting it. 8e's clean build took 10 s from
   an empty scratch path (a toolchain compilation cache), so the full
   strict-memory-safety typecheck of `just ios-check` carried the
   0-warnings check that run.
 - A test that routes around a trap with a configuration switch is hiding
   a bug. 8e's tests turned the nursery off so a host save would pass the
   verifier; the VM's end left young objects nowhere and cached entries in
   no free list. The follow-up made `destroy` leave the image whole and
   the switch went. When a test needs a special configuration, the reason
   is written beside it, and "otherwise it traps" is a bug report.
 - Closing one escape, look beside it for the same shape. The read
   primitive followed a link in the last path component; the write's
   temporary file, opened with `O_TRUNC` next to it, followed one too.
 - A limit no input has reached is a limit no test has reached. No object
   passes one 32 KiB heap block, so the kernel's growable collections
   capped at 2048 elements and a protocol reply over a block could not be
   written; nothing noticed until 9c built an image of 2000 classes.
   `LargeArray` behind the collections, a merge sort in place of the
   insertion sort that cost 5.3 s for 5000 items, and JSON lines carried
   in pieces both ways answered it in the kernel until module 10 built
   the large-object space (runs of blocks, old at birth, never moved,
   image version 5) and the kernel went back to plain Arrays. When a
   module's first big input is its gate, build the big input first.
 - A new object held only by the stop that allocated it is unrooted the
   moment its worker parks for another worker's stop. Module 10's first
   cycle trigger started marking from the allocating worker's own stop
   with the large object as its only root; the random programs crashed in
   release and reported "reachable but not marked" under
   `markingAlwaysOn`. An object that must outlive a collection it starts
   is a pending root on the normal young-collection path, never a local.
 - Every allocation path decides the collector's trigger. Module 5's
   trigger was decided at young collections; a Process allocating only
   large objects never filled a nursery, so no cycle ever started and old
   space fell back to full collections that went uncounted. A fallback
   that is not a counter is a fallback no test sees (module 10 counts
   old-allocation full collections as module 5's fallback).
 - A path never exercised is a path never tested, even when its code
   is tested. 9d's remote session was measured Mac to Mac on the Mac's
   own address, so neither macOS Local Network privacy (every LAN host
   "No route to host" for the session's process tree) nor the two script
   bugs in the phone's path (a token copied onto a directory, the first
   address in the phone's list being the USB link's) showed until the
   first device run. A row that stands in for the device is a row that
   does not test the device's path; say so in the doc and run the real
   one as soon as the owner's part is done.
 - A test that assumes the headless host fails on every real one.
   `ViewWrapperTest` (9c) expects view kinds UIKit does not have and a
   timer refused without a host; the Mac shell's and the iPhone's tests
   mode failed 3 and 4 of 202, and no gate ran those modes after 9a. A test
   of a protocol with several hosts asks the host what it supports: since
   815b512 `View class>>supports:` probes the host by creating and
   releasing one view of the kind, a refused kind must raise a clean
   Error, read-backs the protocol has no get for are asserted only where
   the wrapper keeps its properties, and 202 of 202 pass headless, in the
   Mac shell and on the iPhone.
 - A counter bumped after its lock is let go is read with a bounded wait,
   never once. The Process tests read `terminations` the instant the last
   Process read as terminated; the count landed after, a race as old as
   module 3 that 9c's release gate was the first to lose.
 - A measurement on an idle machine is not the easy case. Typing missed
   up to 170 frames of 1258 idle and 1 to 18 under the storm load, with
   the VM's longest turn 13 to 15 ms either way; the misses are not the
   VM's and are not explained yet. Measure idle and loaded both, and do
   not take the loaded number as the worst.
 - A secret's rule covers the whole path, including the convenient one.
   9c kept tokens in the host and then let the target picker take a typed
   one through a Smalltalk String; the owner closed it in 9d with a
   secure field the host owns, so pairing a phone is reading its screen
   and typing into the host, and no method can ever see a token.
 - A descriptor closed twice closes someone else's. 9b's client could
   close its socket again from `deinit`; by then the number belonged to a
   Bonjour resolver, which lost its socket under 9d's tests. Close once,
   mark it closed, and assert in the tests that a closed thing is closed
   exactly once.
 - A gate that waits on a prompt is a blocked gate, not a slow one.
   `codesign` sat at 0 percent CPU for minutes inside the device build
   three times; the agent reported it and measured Mac to Mac instead of
   answering a keychain prompt it was not allowed to touch. Report what
   blocks and what was done without it.
 - A barrier belongs to the slot, not to the primitive that first needed
   it. `at:` had the weak keep-alive barrier; the array copy, `instVarAt:`,
   `slotAt:`, `shallowCopy` and the symbol table's bucket growth read the
   same slots without it, and only an outside review asked. When a read or
   a store gets a barrier, list every path that reads or stores that kind
   of slot in the same commit (the table is in
   `docs/modules/collectors-review.md`), and a new slot-reading primitive
   goes through `keepAliveRead`.
 - A word two modules share is changed with bit operations, never stored
   whole, and has a verifier that names both owners. Marking stored the
   barrier word and erased module 7's count; nothing failed, the young
   stress flag just stopped stressing after the first cycle. A stress
   mode needs a counter that shows its slow path is being taken, or it
   can be off without anyone knowing.
 - A primitive checks its bounds one by one before any arithmetic on its
   arguments; `stop - start + 1` trapped on minVal and maxVal. Every
   primitive that takes an integer is called with minVal, maxVal, -1, 0
   and count + 1 by one seeded test (`ExtremeIntegerTests`), and a new
   primitive is added to it.
 - A log nothing trims is a leak in an app that runs for days, and an
   append under a mutex is an allocation under it. Logs are `RecordRing`s
   with running totals; reports take sums from the totals, percentiles
   from the records kept, and say how many were dropped.
 - An outside review is a verification layer of its own. The gates, the
   models and the fuzzers had all passed the code in which pull request 1
   found three bugs a program can hit; it read for paths that lacked what
   their neighbours had, which no test of ours was looking for. A pull
   request diffs from the merge base, so a review of existing files needs
   a base branch without them and a head that is the base plus the files.
 - Xcode builds every Swift package in its Debug configuration `-Onone`
   with `DEBUG`, whatever the app's settings say, so a development app got
   a checked, unoptimized VM (fib did not finish in two minutes). Only a
   package trait reaches a dependency's build, and only a package can set
   one: a generated app has a local `KajoPin` package that enables
   `KajoAppBuild`. Xcode's index-while-building refuses whole-module
   flags, so the Debug VM is still 2.6 to 4.0 times slower than Release.
   A product's build mode is decided by whoever builds it; read the
   compile line (`just new-check` does).
 - Xcode links a package product in every configuration, and dead
   stripping does not remove an unreferenced Swift module (1224 `KajoDev`
   symbols stayed in a Release binary). "Not in the release build" is a
   property of the linked binary, checked on it by symbol, string and
   import (`just new-check`), never inferred from the source's `#if`.
 - An `unowned` reference is a lifetime claim every asynchronous path must
   keep. 9a's runtime scheduled its follow-up turn holding itself strongly
   while its platform was `unowned`; the shells' hosts live for the
   process, so the trap waited for 11a's short-lived test hosts under
   ThreadSanitizer. Work scheduled for later holds its owner weakly.
 - A measurement launch of a Mac app behind other windows is napped
   (333 frames missed in one window). Measurement modes hold an activity
   against App Nap as well as the display-sleep assertion.
 - A thermal state is a label, not a clock. The iPad's performance
   cluster fell from 2.3 to 1.3 GHz under sustained load while the state
   read "fair", and its one-thread clock never fell at "serious". Log each
   thread's clock and IPC (cycles and instructions per CPU second from
   the per-thread counters) beside the thermal state.
 - Event latency on the main thread follows its busy fraction: an event
   that falls due inside a turn waits for the rest of it. Past half busy
   the median is a waiting event; report the busy fraction with every
   latency percentile.
 - An energy counter is checked against a known workload on each chip
   before two devices are compared (`mode=spin`: N threads for a fixed
   CPU time). The A12X reports less per cycle on a performance core than
   on its own efficiency core; that is a coefficient, not a measurement.
 - Over Wi-Fi the first request after an idle gap of a quarter second or
   more costs about a beacon interval (100 ms) on both devices: the radio
   dozes. A latency maximum over Wi-Fi is read beside the target's own
   time for the same request id (`requests-<tag>.txt`,
   `scripts/link-probe.sh`), or it says nothing about the target.
 - A hand-back answers the question asked; the rows may hold another
   answer. The investigation's storm rows missed frames in 14 of 49
   launches and its report, about latency, did not say so; reading the
   raw rows for the bar's own columns (frames missed, fallbacks) found
   that every miss was a counted fallback. After any device run, tabulate
   the bar's columns over every row, whatever the run was for.
 - A fallback counter names the symptom; a fallback record names the
   cause. Module 5 counted the devices' fallbacks for two days as "old
   space" ones; the record (what ran out, the cycle's phase, the sweep's
   progress, the marker's QoS) showed the storm ran out of entries the
   lazy sweep had already freed but not yet applied, with the marker
   starved at utility on efficiency cores. Every counted fallback carries
   its record from the start.
 - A QoS policy decided once per cycle cannot answer a resource that
   empties mid-cycle. The marker's raise was decided at the initial mark
   from old space alone; the entry table emptied while it swept. A policy
   is re-decided at every young collection while a cycle runs and watches
   every resource a fallback can exhaust, the same list as the trigger's.
 - A starved thread cannot raise itself. The policy asked the marker to
   rise, but at utility on a saturated phone it never reached the poll
   where it reads the request; the allocation that needs the cycle raises
   the marker from its own thread and waits a bounded time, outside every
   stop, with its object a pending root.
 - Deciding a policy at every allocation of one kind oversteers: deciding
   the marker's QoS at every large allocation raised it for 747 of 749
   cycles on the iPad and stopped the main thread 60 percent longer.
   Decide at the collector's own points (young collections, the initial
   mark) and raise only for a cycle something is waiting on.
 - A sentinel in the count field is free only when the field is never
   more than the truth: an index below the sentinel is in bounds either
   way, so the hot check `i < count` stays and only its failure path asks.
   A count in words would have cost three instructions on every byte
   bounds check, small objects included; measure the candidate on the
   header layout before writing the readers.
 - "Cheaper" is per direction. Pieces won for the replies the image
   writes (half the old-space bytes) and one String for the lines the
   image reads (18 percent faster round trips); a transport measured in
   one direction would have picked wrong for the other.
 - A fuzz seed larger than libFuzzer's default `max_len` (1 MiB) runs
   truncated and is refused at once, so a 16.8 MB seed buys no coverage;
   check each seed's size against the target's `max_len` when adding it.
 - A setting that decides whether an image stops for a debugger lives in
   the host, never in the image: a value held in the image is saved with
   it and read by the next host, so a batch host would inherit a
   development app's choice. The host sets it before the image resumes
   and serving turns it on; the kernel reads it through a primitive that
   a release image answers false.
 - Standing stops reach a new client in the answer to its own open, not
   as replayed events: the answer is the one line that reaches exactly
   that client and cannot race with a stop that happens meanwhile.
 - Two Transcript sends per line (`show:` then `cr`) interleave under
   concurrent Processes; a line is one send (`showLine:`).
 - A wait for a report that runs on a global queue is a wait for the
   queue's thread, not a bound: 9d's 10 s wait for the listener's
   pause-ended report ran out under twelve busy loops without the
   sanitizer (10b's first gate run). A wait for something that must come
   is long everywhere (120 s), with the assertion unchanged.
 - A stop's duration is measured from its request, and whatever a stopper
   waits for before requesting is a field of its own. Module 3's
   StopRecord counted the wait for open young collections, with the world
   running, as time to safepoint; two days of device rows said the final
   mark took 7 to 20 ms when its stop took 0.5, and the brief that
   followed named the wrong phase. Instrument first, then brief.
 - A pass that runs inside a stop is bounded in work or moved out of it,
   and nothing is decided before the bound is known to hold: the final
   mark gives up before any ephemeron fires or weak slot is cleared, so a
   give-up changes nothing and the marker simply asks again. A bounded
   pass with a decision before the bound would need an undo.
 - Reorder two passes only after listing what each one reads of the
   other's result: the remembered filter ran before the ephemerons and
   dropped holders the ephemerons' tracing was about to mark, a bug
   since module 5 that no device, random program or fuzzer found; a
   reading of the stop's order while bounding it did.
 - A constant wait is found by a trace, not by its suspects. The brief
   named the Local Network permission, Bonjour and the token store for
   the Debug sample's 35 s to its first frame; a per-step launch trace
   put all 35.0 s in `ProcessInfo.hostName` on the main thread (a name
   lookup iOS never answers, result "localhost"). Nothing in a launch
   waits on a name or the network before the window, and the
   development half starts after the first frame with a clock bound.
 - A script that talks to a relaunched process re-reads its address
   each time. The round trip's fallback kept the first launch's port,
   the rebuilt app listened on a new one, and `starts_with_change=0`
   was the script connecting to nothing; a step that gets no answer is
   a `FAILED` line, never a measured zero.
 - Bound an optimization with a cheating build before building it. A
   build that trusted the method cache line without comparing class and
   selector put the ceiling of a per-site inline cache at 2 percent, and
   removing the poll countdown put its ceiling at 1.1; neither was built.
   The leaner activation had no such bound, was built two ways in four
   register layouts, and lost on `arith` and `ivars` to spilled `true`
   and `false`. The time was in dispatches, not in the send's lookups:
   fusing pairs cut dispatches to 0.62 to 0.84 and cycles per send to
   0.61 to 0.82.
 - A fused instruction replaces only the first opcode byte. Operands,
   offsets, jump targets, the pc-to-source map, saved pcs and stepping
   stay those of the plain code, a fast path that does not apply runs
   the first part alone and dispatches the intact second, and the
   verifier's one new rule (the second part follows, plain) is what
   keeps a `push_int` operand from being read as a temp index (the
   hand-run broken variant answered 47 for 9). Every tool that compares
   bytecodes compares the plain form (primitive 166).
 - A faster mutator is a heavier load on every provisioning rule. The
   Mac's ring under the stop-the-world young mode fell back 26 to 32
   times a run against 20 to 28 with the interpreter 20 to 40 percent
   faster, every one a soft limit crossed with no cycle running; a
   trigger tuned on one interpreter speed is re-measured after a speed
   change, in the mode that falls back first.
 - A summary that classifies a field lists the field's every value first.
   `ok=-1` on a golden row means no checksum is published at that worker
   count; `--bar` read everything but `ok=1` as a failed checksum and the
   first weekly run's Mac matrix failed on 24 rows that were fine. Each
   value a writer can emit is named by the reader, and the ones it does
   not know are counted as unknown, never folded into pass or fail.
 - A pin is what the build system can resolve, not what the design
   drew. SwiftPM refuses an absolute `binaryTarget` path, and a thin
   package with any Swift source is compiled for every architecture of
   an Any Mac Release build, which arm64-only frameworks cannot serve;
   so a generated project names the checkout's package of binary targets
   directly and no Swift is compiled from any package. Try the pin's
   shape in both configurations before the generator writes it.
 - A Bonjour name can outlive the process it named: two of three phone
   round trips resolved the rebuilt app's name to the previous launch's
   port. A script that talks to a relaunched process has the address
   from the launch's own console as its fallback, and the by-name step
   says which path answered.
 - A frame gap with no stop, no long turn and a free main thread may be
   the display's. The first idle row's 272 to 595 missed frames (five
   matrices, 2026-11-07 to 09) were the Mac mini's display turned off by
   powerd inside the window: the golden launches before it woke the
   display without holding it, so with the user idle powerd asked for an
   off at every exit, and one landed in the first scenario window though
   that launch held a display assertion from its link's start. Every
   measurement launch holds `PreventUserIdleDisplaySleep` from `main`;
   read `pmset -g log` beside any gap no stop explains, and the gap
   records (`gaps100`, `gap_max_at_ms`, `trace gap`) say where it sat.
   The matrix's warm-up launch is not a row.
 - A counter read when the program ends counts the cycles the collector
   finished, not the ones the program caused. The relocation round under
   the sanitizer and twelve loops ended with its second cycle planned at
   its initial mark but not at its final mark, the starved marker's pass
   at 0.14 s of CPU in 4.2 s, and the round read one selecting cycle. A
   test that counts a concurrent collector's work waits for the collector
   to go idle after the program ends (a long bound, not reaching idle a
   failure), and prints where the collector stood at the program's end
   so the next failure says which case it was.
 - A benchmark's gap is split before it is attacked. The collections
   program read as "the library is 3.9 times slower"; its four parts,
   each with sends per element and a ratio net of start-up, showed one
   part at 15 times (the stream, eight sends per character), one whose
   time was mostly Integer printing, and two at the interpreter's own
   ratio with nothing for the kernel to do. The two library fixes took
   the whole from 3.9 to 2.8 times; the guessed cheap wins (String hash
   and equality, `do:` loops, growth by doubling) were already there.
 - A brief's premise is measured before it is built. The sweep-stop brief
   asked for headroom because "the sweep is slower than consumption";
   the records showed the sweep three to four times faster than the
   allocators and the cycle simply started too late, and the ring's
   cascade was not the trigger at all but a fallback whose mark-sweep
   left old space at the limit and suppressed the next cycle. Both fixes
   came from the record, not the brief; a module's part 1 is always the
   instrumentation, and parts 2 to 4 are decided from what it printed.
 - A concurrent pass that runs ahead of another is cut off before a
   stop finishes the second one's work early: the relocator moves only
   snapshot entries, so a sweep applied ahead of an unfinished pass
   could evacuate a block with a live body still in it. When a stop
   publishes a pass's partial result, list every other pass that reads
   the same state and end or exclude each one first.
 - A primitive that clears a protection bit checks every reason the bit
   was set. Primitive 93 refused the sealed classes' instances and so let
   a program make a verified method's bytecodes writable: read-only was
   set by the make primitive, by the loader and by `beReadOnly`, and only
   one of the three was asked. What the VM makes read-only it also pins
   for good, and the clear refuses the pin.
 - A loop that polls re-reads everything it holds of the heap after the
   poll: the object's body, and its length too. `zeroLongBytes` kept a
   length across a park in which a walk primitive handed the half-built
   object to a program that could `become:` it. And an object still being
   built is hidden from every heap walk by one mechanism (the building
   mark on its pending root), not by each walk remembering.
 - A report made under a lock is called by the caller after its unlock,
   never sent to a global queue: under the sanitizer and twelve loops no
   thread of the queue ran the block in 120 s, and the earlier answer
   to the same test, a longer wait, had only moved the bound. When a wait
   for something that must come runs out twice, remove the queue, not
   the bound.
 - A new test's own faults are found by the gates, not by its author's
   run: SIGPIPE from a write to a socket the server closed (raw test
   sockets set `SO_NOSIGPIPE`), autoreleased Foundation reads in a loop
   with no pool (ThreadSanitizer's allocator ran out), twenty connects at
   once against a listen backlog of 16. Run a new suite once under the
   sanitizer with a dozen busy loops before the three-hour run meets it.
 - A reviewer's example is checked against the standard before it becomes
   a test. The report's `outer` example answers 2 under ANSI, not the 20
   it claimed; the test was written from the standard's text and
   separates old from new behaviour by a value neither could produce by
   accident.
 - A whole-tree review by readers with one area each finds what the
   gates cannot: 42 findings in code every gate had passed, the worst a
   primitive that undid the verifier's guarantee. Each reviewer was told
   to read for the invariant its neighbours keep and to name the path;
   the fixes' tests were then run on the starting commit, and the ones
   that passed there were said to pass.
 - A changed gate script is run once on its own before the gate run.
   `device-rows.sh` assigned to `status`, which zsh keeps read-only, and
   died in the fourth hour of a `just check`; the script's own test had
   not run the changed lines. The same for a variable's name in any
   script a gate sources: `status`, `path` and `argv` are zsh's.
 - Two implementations of one rule are compared on inputs written for
   the rule's edges, not only on the inputs that exist. The compilers
   agreed on every method of the image for six modules; a corpus at
   and past each limit and a fuzz mode that runs both found four
   disagreements in a day, one of them the reference's own bug (the
   assembler took 257 temps the heap verifier refuses). When they
   disagree, ask which one the trust boundary agrees with.
 - A signal queued for another thread holds what it will signal. The
   bridge's post read the Semaphore under its lock and signalled after
   it with no root; a re-registration between the two could free the
   Semaphore and the drain signal whatever took its entry, an excess
   signal that on a Mutex's Semaphore breaks mutual exclusion. The
   root is taken where the object is still known to be held and the
   drain releases it.
 - A net is built under every way a request can end, not under each
   cause as it is found: an `ensure:` block for what unwinds and a
   reaper for what does not (a VMError ends a Process without
   unwinding). The reaper exists only while requests pend, so the
   idle image still has no timed wait.
 - A place the host writes is decided by the host, as a secret is kept by
   it. The image passed its client's project directory to `connect`, so
   any method in a development image could have the host write class
   files anywhere the user can; the host now keeps a directory per
   target, set by host code or chosen in the host's own panel, and the
   image may only ask which it is. When an operation of a boundary takes
   a path, a name or an address from the less trusted side, ask whose
   decision it is before validating the value.
 - A hand-back's number with no baseline gets one before it is recorded.
   "58 frames of 273 missed, nothing here touches the frame path" was
   true and proved nothing; five interleaved launches of the starting
   commit's shell missed 43 to 48 and the head's 43 to 57, which is the
   sentence the doc now has.
 - A poll at a send is not a resume point. The native engine's first poll
   handed the interpreter the pc after the send with the send's operands
   still on the stack ("doesNotUnderstand #+ (receiver Adder)", found by
   `--stress stop`). Registers that belong to an instruction in progress
   are continued by the engine that holds them; only a bytecode pc with
   its traced depth is handed to the other engine.
 - A second engine is a faster mutator on every provisioning rule at once.
   Native code at 3 to 10 times the interpreter took the oracle ring row
   from 8 to 9 soft-limit fallbacks a launch to 16 to 17 on the Mac and
   gave the iPhone's row its first. Every matrix runs in both engines, and
   the row that falls back first is read first.
 - Generated code is compiled in pieces and its size is a bar item. One
   47 MB C file took 293 s and 7.9 GB at `-O1`; the same code in files of
   150 groups 14 to 28 s on ten cores at `-O2`. Straight-line code per
   method came to 13 to 27 MB of text per image against a 2 MB app binary;
   measure a generator's output on the largest image, not on the kernels.
 - A wait loop on `pgrep -f <name>` whose own command line holds the name
   waits for itself. Two such loops outlived the AOT agent and the main
   session killed them. Wait on a pid or on a file, bounded.
 - A seed count is part of a gate's time. A thousand seeds per
   configuration, each compiling generated C, did not finish in the soak's
   bound; the native random programs run a hundred and the thousand stay
   the interpreter's. Time a new test at the gate's size before the gate.
 - A broken variant's test reads a value the variant defines. The
   broken-flush test first read a dead stack word and trapped under load;
   garbage is not a failing check. It reads a stale SmallInteger now.
 - Swift's `case a, b, c where cond` applies the condition to `c` only. A
   "without" build inlined two of three cases and the step read as no
   difference. Write the condition on each pattern, and check that an A/B
   switch switches before believing a null result.
 - A switch nobody ran is a switch nobody tested. The hand-back listed the
   generator's fuzz mode (`KAJO_FUZZ_AOT=1`) as built and no file recorded
   a run of it; the main session ran it. A hand-back quotes one run of
   every switch and mode the module adds.
 - Tests of a new engine cannot fail on the starting commit, which has no
   engine. Their evidence is the broken variants (the send count left out,
   no flush at a poll, fp kept across a stack growth run by hand), each
   failing a named check or trapping with a recorded message.
 - A first measurement at a new worker count measures everything, not the
   module that made it: `collections` had never run at 8 workers and takes
   7 times its 1-worker time in both engines. The run line's own counters
   named the cause in one reading (200 000 stops, one per new Symbol,
   each 86 µs to reach a safepoint at 8 workers against 0.7 at 1). Record
   it as found, hand it on, and keep it out of the module's own ratios.
 - A stop per operation is a per-operation cost that grows with the
   workers: interning a Symbol in a stop was free on one worker and three
   quarters of the run on eight. Anything a program can do in a loop
   (intern, install, define) is measured at 8 workers before a stop is
   accepted as its mechanism.
 - A limit tuned to the mutator's speed is re-tuned at every speed change;
   a limit the consumer waits at is not. Three modules started the cycle
   sooner and each faster mutator brought the fallbacks back; a background
   worker that waits for the collector's progress fell back 0 times with
   the marker 4 and 16 times slower. The test of such a rule slows the
   producer (`--marker-slowdown`), and the main thread is never the one
   that waits.
 - A waiter waits for the pass that frees what it needs, and the records
   say which pass that is. The brief had the sweep freeing the ring's
   blocks; relocation frees twenty times more (the ring keeps one node in
   twenty per block), so a waited-on cycle that skipped relocation fell
   back again and one that gave relocation the reserve did not.
 - A wait on a thread needs the thread to exist. The marker started after
   the workers, and a VM driven slice by slice from a test never starts
   one: an extreme `basicNew:` waited there forever. A wait checks that
   what it waits for is running (`stallsEnabled`), and the thread waited
   on starts first.
 - A wait's broken variant removes every wake path. Leaving out the
   progress bump at a stop's release hung nothing, because the phase going
   idle and the epoch frees also wake the waiter; the hang came with both
   removed. List the wake paths (the doc's transition table) and say
   which variant removes which.
 - What a fallback does inside itself must not ask for the fallback again.
   The full collection's own promote-all requested a full collection and
   withdrew it only below the soft limit, so a full heap ran full
   collections at every poll forever, on the starting commit too; it was
   found when a test first filled a heap and waited for the
   out-of-memory answer.
 - A fallback is justified by a number, not by a reading. Each one names
   its cause, its requester and the cycle that began after the wait and
   freed nothing; one with no such cycle is counted
   (`unjustifiedFallbacks`) and fails the verifier, so "the collector
   could not have helped" is a check and not a sentence in a doc.
 - A before and after on a device is run in both orders. The first pair
   ran the module's shell second, hotter, and it missed more frames; the
   second pair, the other way round, did not. The thermal state on each
   line said which block was hot but not what the block would have done
   cool.
 - A hand-back's explanation is checked against the row's scenario. A
   141 ms wait for a safepoint in the ring was put down to the large
   fill that does not poll; the ring makes no large object. And a
   correction is checked as the claim was: the main session then wrote,
   and pushed in three files, that `gc_scavSlowest` is the scavenger
   that copied longest and that the row named no last parker. It is the
   last parker of the longest scavenge stop and the row said 7, the
   marker. Read the line of code that prints a field before saying what
   it measures. What a record holds (`slowest`, `slowestVia`) is printed
   where the rows are read, for every stop kind and by name.
 - A test script no gate runs is wrong by the next module.
   `check-tier-test.sh` had failed since AOT 1 added three gates to the
   list it checks. A script's own test runs in the tier that changes the
   script, or it is not a test.
 - A module's tests are a cost in every later gate run: over three
   modules (review-fixes part 2, AOT 1, the allocation stalls)
   `swift-test` went from 401 to 618, 1017 and 1329 s and the two
   sanitizer gates from 109 to 176 minutes together. Read the gate times
   against the previous module's `gates.log` at the hand-back, not
   against a number in a doc (the stalls hand-back's "against 401" was
   three modules old and was recorded as the module's own cost), and say
   what the new tests cost.
 - The toolchains differ on which Darwin calls are unsafe
   (`pthread_from_mach_thread_np`: Xcode's and the iOS SDK yes, swift.org
   6.4.2's macOS overlay no), the third gate run lost to this. A line
   that adds a Darwin call under strict memory safety is typechecked
   with `just ios-check` and `just apps` before the long run, and is
   written so that the `unsafe` is needed in each (another unsafe
   operand in the same expression).
 - Work files live outside the session's temporary directory. A restart
   of the session emptied its scratchpad under `/private/tmp` mid-module:
   the running agent's measurements and every earlier module's gate
   outputs, the baselines later modules compare against, were gone.
   Prompts, record scripts, gate outputs and baselines go in
   `~/kajo-scratch/<module>/`, and an agent commits its doc as it goes.
 - Tests run side by side share the process's queues. Five kernel-test
   VMs in the suite starved the timers another test's client waits on
   (`DispatchQueue.global().asyncAfter`), and a reconnect test failed 6
   times in 8; the first answer, a longer wait, was reverted. The number
   of parts was set by failures counted at each (five, three, two), and
   what limits it is written down as the next thing to fix.
 - A slowdown proportional to CPU cannot sit under a wall-clock bound. A
   marker made 16 times slower in CPU terms took 3 s alone and 45 s in a
   loaded suite, and the bound was won or lost by where a cycle happened
   to stand. A test slows the collector until the thing it tests has
   happened (the workers stalled, the request made) and then lets it run;
   what remains waits on the collector's own progress and fails only on a
   long quiet stretch, printing where it stood.
 - A QoS override is worth what the process's ceiling lets it be. A
   command-line process on macOS runs user-initiated and user-interactive
   threads at priority 31, the priority of default-QoS busy loops; an
   app's user-initiated is 37. A raise that keeps the marker ahead of
   load in the shells does nothing in a test process or a headless host.
   Probe the priority a thread actually got before reasoning from its QoS.
 - A test's reported duration is not its body's. Swift Testing counts
   the time a synchronous test waits for a thread of the cooperative
   pool: a 0.1 s body read 408.8 s, and "the stall tests take the suite's
   whole length" was the pool. Tests whose time matters print their
   body's own time, and a margin against a bound is read from that.
 - A test checks its claim, not everything that happens after it. The
   justified-fallback test ran each heap to out of memory through 41 to
   58 full collections though four stalls decide its rule and another
   test owns the out-of-memory answer; under the sanitizer and load that
   was 1043 to 1352 s against 27 to 42. When a test nears its bound, ask
   first what its claim needs.
 - The toolchain first on PATH is every compiler the gates call, not only
   `swift`. Homebrew's LLVM ahead of swiftly's made the native gates
   compile with one clang and fail at link; a gate run records its PATH
   (`env.txt`) and a script that calls `clang` says which one it found.
 - What is made before a lock is made by every loser of it. The brief's
   order made the Symbol and then took the table's lock; eight workers
   interning the same bytes in step made 137 000 Symbols a run for
   nothing, each an old allocation, and the native run read 1.63 times
   its 1-worker time against 1.35 with the lock first. Under a lock that
   decides a winner, do the lookup again first and make the object only
   when it will be published.
 - A wait that runs out is a failed check before anything reads the
   result. The growth test's Process did not finish in its 600 s under
   the sanitizer and load, the helper read its nil result and the trap
   took the whole test process, every other test's result with it. A
   helper that waits records the failure and returns; it never unwraps
   what the wait was for.
 - A mechanism that answers nil on the test host has never been tested.
   `DevClient` armed its request timeouts on `UIEventLoop` directly;
   headless that call answers nil, so no tools test had ever had a
   timeout and the rule "a request ends" was unchecked. A timer, like a
   socket, goes through a seam the fake records and the test fires.
 - A test that asserts an edge was crossed drives the system to the
   edge. The ring ran a fixed length and peaked at 488 to 494 blocks of
   the 512 a stall needs, on either side by how the cores were shared;
   repeating the round stayed short of it. Slow the producer until the
   thing has happened (a counter says so), then let it run.
 - An index pays for itself only past a size. Buckets for every literal
   frame made the common small method 17 percent slower to compile; the
   frame is searched whole up to 32 literals and indexed past that.
   Measure the small case of anything built for the large one.
 - A size lever is priced in speed before it is named the answer. The
   machine outliner halved the native module and halved its speed, and
   it hid inside `-Oz`; `-Oz` without it saved 13 percent. Measure a
   flag's parts apart, and state the rule that will choose before the
   numbers are read (`part1/rule.txt` carries its time).
 - A last resort in the brief can be the cheapest lever in the table.
   Compiling only loops and what they send cost the kernels 0.3 percent
   and took 62 percent of the code; sharing tails and folding at link,
   which the brief ranked above it, found nothing. Bound every lever,
   the unloved ones too.
 - A build phase's product is declared as its output and a change in it
   forces the link. The first native library was built and then not
   linked again when it changed; a generated project's shape is tried
   with a second, changed build as well as a clean one.
 - A starting position that says "it may be enough" is opened before
   the measurement is planned around it. The brief had `kajo-frames=` as
   perhaps enough for a Release app to report frames; it lived in the
   Debug-only half, a Release build printed nothing, and part 1 had to add
   code before it could measure. What a brief's part 1 needs from the
   product is checked for existence when the brief is written.
 - A device comparison of two engines is read with each block's thermal
   state before its verdict. Four matrices in a row put every iPhone row
   at "serious", where the interpreted ring missed 137 frames against 10
   on the cool phone the same morning, and the one iPad block still partly
   at "fair" was the one that missed nothing. Both orders do not help when
   the device never cools between blocks: wait for nominal between
   blocks, or interleave the rows.
 - A broken variant tests the checker as well as the product. Run with a
   project that has no module, `new-check` failed as it should and also
   left two stray files in the directory it ran from, a fault the passing
   runs never reach. Look at what a failing run leaves behind.
 - A test known to be thin is named in the next agent's prompt. The weekly
   run failed three gates on two interning tests an hour before a build
   agent started on the same commit; told so, the agent could have read a
   failure of those lines for what it was. They passed, one at round 33 of
   40.
 - A race test starts its racers at a gate. Eight Processes spawned one
   after another and walking the same names raced only when a later one
   caught up with the first before the names ran out, and in a busy suite
   none did in 40 rounds; with each Process marking a slot and spinning
   until all are marked, the race came in round 1 to 3 of 150 runs. Repeat
   rounds are a net under a driven race, never the drive.
 - A failure seen only in the full suite is reproduced with the suite's
   load, not with busy loops. Thirty runs alone, loaded and under the
   sanitizer failed 0 of 120; both tests beside the random programs (23
   VMs at once) failed 1 in 30 with the weekly's own line. Before fixing a
   thin test, find the condition that makes it fail and keep it for the
   after table.
 - A row that is meant to show a cost is checked to reach the cost. The
   brief took the matrix's `local` rows as the price of the main worker's
   own collections; the only rows that fill the main worker's nursery (the
   events and hog rows, one or two flips a launch) ran `offload` only, so
   no row of the removed mode had collected on the main thread since
   module 7. A counter of the thing itself (collections on the main
   thread, flips) in every row is what showed it.
 - When a configuration goes, each switch of the model is checked to still
   change something. `mainOpensWhileWanted` had only ever been exercised by
   the configuration that was removed; on and off gave equal state counts
   and every test passed. A switch whose two settings explore the same
   states is not tested; the model's tests now compare the two counts.
 - A list and its change event are two publications; a test that waited for
   the first reads the second with a wait of its own. The Bonjour browser
   updates its list and then posts the event, and the test's second check
   lost that gap once under the sanitizer and twelve loops.
 - A question to the owner is checked against the rows as a claim is. The
   main session asked for a scenario "that fills the main worker's
   nursery" and named the storm with 1000 events; that row was in the
   matrix already, flipping once or twice a launch, and the module's doc
   said so. The owner answered a question whose example was a no-op.
   Before a question leaves, read the rows for the thing it says is
   missing.
 - A load's default is measured for what it leaves of the turn before a row
   is built on it. The shells' frame load (`mainwork=60000`) was sized on
   the Mac; on the devices it fills the 3 ms turn and up to every frame
   turn is preempted under the storm, which no column of the bar showed.
   Preempted turns over turns is read beside every main-thread number.
 - Before a row is built to reach a cost, bound whether it can. A wait for
   the collector needs a half filled faster than a collection runs; the
   fill takes 86 ms at the most the main turn's bound allows and the
   slowest collection took 29. Two numbers the events rows already had
   would have said the row would read 0; it was still worth building as
   the row that will show the day this stops being true.
 - A file's time is proof of order only until the file is edited. The
   rule's file was corrected after the device rows and its mtime moved
   past them. A rule written before the numbers is committed, or copied
   with its time, before the numbers are run.
 - A rule's clause is no tighter than the measurement's own spread. "No
   kernel slower by more than 1 percent at 1 or 8 workers" could not be met
   at 8 workers by any build: one side's five runs of `floats` spanned
   0.969 to 1.175 in cycles. Measure the base against itself first, and
   write the rule's bounds from that spread.
 - Twenty-four instructions in the dispatch loop are enough to move its
   registers. Fused sends that jumped into the one existing send spilled
   `true` and a base register; a path that is shared is not a path that is
   free. Read the spills in the disassembly for every case added, the
   small ones too.
 - A syntax change is checked against every reader of source, not only
   the compilers. Both Tonel readers end a method's pattern at the first
   `[`; a type such as `Array[E]` in a pattern would have cut every typed
   method there, and the optional-types experiment found it by scanning,
   before any parser was written.
 - What a release image must not hold is decided by where it is stored,
   before the feature is built. Types as pragmas would be literals in every
   method of every image and types as class metadata would ship with the
   class; kept as source text and built into tables only where the checker
   is loaded, a release image holds none.
 - A method no test runs and nothing sends is unverified however long it
   has been there. `BlockClosure>>ifError:` raised a second error inside
   its own handler from the day it was written; a type checker over the
   image was the first thing to read it.
 - A flag is not a strip. `kajo build-image --release` and `kajo seal`
   only set the image header's flag: a release image keeps every class
   comment and every method source, byte for byte the size of the plain
   one. Types 1's brief put class-level types "beside the comment, which a
   release image drops"; what a release image holds is read with `grep` on
   its bytes and its size, never from the flag's name.
 - A count from a script is checked on three rows by hand before a brief
   quotes it. `features.py` cut each line at its first `^`, which can sit
   inside a block type, and the brief's 15 overloaded selectors were 6.
 - A new slow kernel test moves other tests to other parts and so changes
   what runs before them. A test that reads image-wide state (the next
   free class index) failed 2 of 2 after a neighbour that removes classes;
   such a test puts the state where it needs it first (a collection here).
 - A signature needs a method to be written on. 45 of the slice's 622
   restated an inherited method in a subclass and could not move inline;
   when data moves from a side file into source, count first what has no
   place there.
 - A timer handed to a queue holds what it will signal for as long as
   the queue does. `startDelay` gives `asyncAfter` a `VMRef` that nothing
   cancels; a test VM that ended with a 600 s Delay pending was signalled
   after its end (SEGV in the sanitizer gate, Types 2). Since the Delay
   fix (075d2a4) the timer holds the VM's life cell and a late one does
   nothing; a bounded wait in a service is still a reason to ask what
   the bound leaves behind.
 - A test of a use after free makes the freed memory hostile. A VM ended
   with a Delay pending passed under ThreadSanitizer when nothing reused
   its state; the reproducing test overwrites 4096 allocations of the
   state's size with 0xA5, and then fails 3 of 3 with the first crash's
   own frames.
 - Cancelling a timer does not stop a handler that has begun, so a
   lifetime is decided under a lock in a cell that outlives the object
   (`VMLife`), never by cancelling. And why a neighbouring path is safe
   is read in the code: the brief had the bridge's `ref` cleared at
   close; it never is, and the bridge was safe by another line.
 - A wait is checked for who can make its condition true.
   `ShellVM.close` waits for the pending-root count to fall after
   `shutdown`, when no worker drains any more; it has waited its whole
   3 s and leaked the VM at every close with a Delay pending.
 - An operation that can fail quietly answers what it did. `close`
   returned nothing, so 33 of the suite's 61 closes leaked a VM and an
   image for months and every test passed; with a report the leak is one
   `#expect`. And a brief's "several" is counted in part 1: the cause of
   most leaks was a 100 ms reaper Delay nobody had suspected.
 - A rule every member of a type must keep is kept by a test that reads
   the source: `ShellVM`'s table test names a public member that neither
   checks the closed flag nor is exempt with a reason, and a checked one
   whose check was removed. A list in a doc is right on the day it is
   written; the brief's own list had four members wrong.
 - A hand-run that must crash under ThreadSanitizer is run with
   `TSAN_OPTIONS=abort_on_error=0`. Without it the test helper sat in
   `abort` at 100 percent CPU for 15 minutes and its report was lost.
 - A rule that ends a construct at "anything but X" is scanned against
   every file before it is built. The brief ended a signature at a
   comment; 762 method entries would have become signatures the day a
   bracket was forgotten. The token after the pattern decides, comments
   skipped.
 - A count taken with part of the data switched off is not a baseline for
   the data switched on. The side files' 21 diagnostics were counted with
   Object's 15 class-side signatures never applied; placing them on
   Behavior made them apply and gave 30. Before a number becomes a bar,
   ask what the tool that produced it skipped.
 - A feature kept out of a product is kept out by where its entry point
   lives. The `diagnostics` request is an extension in the checker's own
   package, so an image without the package has no name of it and answers
   the protocol's own "unknown request"; a request in the kernel would
   have put a checker's name in every release image.
 - A brief's tier is decided by where its tests live, not only by where
   its product code lives. Types 3's brief said the Smalltalk tier
   because no Swift under `Sources/` would change, and asked in the same
   document for a real-target test, which lives in `Tests/` and owes the
   Swift tier (72 minutes against 9).
 - A request per thing shown is checked against the reply of the next
   scope up. The brief had one `diagnostics` request per method shown;
   the class-scope reply already holds every method's diagnostics, so
   one request per class selection marks the selectors table too and
   showing a method asks nothing.
 - An annotation is kept for what it makes known, and counted by it. The
   brief expected `species ^<Self class>` to remove diagnostics; it
   removed none and made 11 more receivers and 16 more results known.
   Read the known-receiver and known-result counts beside the
   diagnostic count.
 - A check that one line switches off is no check, and nothing said it was
   off. `Headless.configs` wrote false over the checked build's verifier
   default from the day it was written; the first kernel-test run with the
   verifiers on trapped before its first scavenge (the make primitive's old
   methods name young objects unremembered). Every run line and `kajo
   test` print the level they ran at and the count of verifier runs
   (`verify=on|off`, `verifies=N`); a gate that means to verify reads both.
 - A timer on the process's global queue is as late as the queue is full.
   The host's 1 s reconnect timer fired 4.7 to 26.8 s late in the sanitizer
   suite, each time in the same millisecond as every other overdue timer;
   an outage past 30 s then failed the requests it was to send again. A
   host's timers run on a serial queue of its own (57 ms with the global
   queue full, never in 20 s before). The VM's Delay timers have the same
   shape and are not changed yet.
 - A late timeout hides slow replies. With the timers on time, a reply over
   30 s fails where a late timer used to let it through; the class
   hierarchy (15 to 27 s) and the first frames reply (15 to 21 s) under the
   sanitizer suite are margins the fix exposed, on the starting commit too.
 - A reply that recompiles is measured under the slowest build that waits
   for it. A frames reply compiled every frame's method again to find its
   variables: 9 s alone under the sanitizer, 18 to 30 s in the suite,
   against a 30 s timeout; a stop keeps them per method now (6 to 12 s).
 - A gate failure on a test the module did not write is counted on both
   commits under a rule written first, on the smallest set of suites that
   has the suite's load. Head 0 of 12, starting commit 1 of 12: the module
   did not cause it. Why it failed 3 of 4 of the module's gate runs and
   none of 18 before is not established, and the record says so.
 - A failure message prints every clause of the condition it waited for.
   The reconnect test's line printed six fields and the one clause that
   was false (the debugger's state, the frames replies counted) was not
   among them; the first agent could not name the condition and the second
   began by adding the fields and a host log of timers armed and fired.
 - An unwind block covers everything from the first state change, and the
   test terminates at every poll in turn. The first `Monitor>>wait` fix
   left two polls outside its `ifCurtailed:` (the mutex's signal: the
   monitor held for ever; the `ifCurtailed:` send: a dead waiter). Reading
   found one, `preemptEveryPoll` with a termination after each of the 15
   slices found both.
 - Bounding a queue's array costs moves: `OrderedCollection>>grow`
   recentring under half full took a queue of 10 through a million pairs
   from a 1 048 576-slot array to 32 slots and from 134 to 158 ms. The
   memory was the finding; the time is said beside it.
 - `swift test` writes to a file in blocks, up to 35 minutes late. A
   script that waits for one of its lines runs it under a pseudo-terminal
   (`script`), or waits for the process.
 - A verifier's message says what each entry is, not only which. "Entry
   148628 names young @148629 and is not remembered" stood for a day as a
   fault seen once; with the class, the bits, the remembered word and "kept
   and moved from nursery 1 to 0 in scavenge N" in the same line, three
   counted runs of three named the path. Add the description to the
   message before looking for the condition.
 - A set keyed by where an object lies is derived again when the object
   moves. `placeKept` gave a kept body's new nursery to the holders already
   remembered for its old one; the young objects of the old nursery that
   named it (never remembered: same nursery) and the body's own references
   back were in no set, in the offloaded mode only, since module 7. When a
   pass changes an object's owner, list who named it under the rule "same
   owner needs no record" and what it names under the same rule.
 - A rare path gets a switch that forces it before it gets a fix. A
   nursery with no room for its own kept bodies came once in two
   twelve-minute runs under the suite's load; the test switch
   `keptAcrossNurseries` made it 612 verifier failures in 22 s, and the
   fix's broken variant (`keptAcrossWithoutRescan`) is a suite test.
 - A raw store is right only where nothing can be young. The make
   primitive shared `makeMethodObjects` with the image build, whose heap
   has no nursery, and stored a literal taken "as it is" into an old frame
   with `om.store`. Code shared between a build step and a running VM
   takes its stores through the heap it was given (`MethodHeap.storeLiteral`),
   and part 1's table (each store: holder, may the value be young, why) is
   the review of such a path.
 - A verifier's cost is per build, and so is its level. On in a release
   build the kernel tests take 13 s; in a debug build 346 s against 118,
   and the stall tests 4 to 12 times their time. A test that verifies says
   the level it ran at and asserts it (`verify=on`, `verifies` above 0),
   and a gate that does not verify says so on its command line.
 - A brief that restates an owner's answer is read against the answer for
   each build. "The build's own level" and "the release-build kernel gate
   only" disagree for a debug build; the agent saw it, took the owner's
   words and said so first in its hand-back.
 - Before switches become one level, list the combinations in use. Three
   levels in a line (off, stops, all) cannot say "the heap verifiers
   without the stop verifiers", which is what `test-release` ran; the
   brief's bar said no gate's verification would change and one did.
 - A cheating build that loses objects bounds nothing. The barrier's
   early return for an old holder lost objects on 3 of its 4 rows; the
   rule, written first, named a sound fallback (count how many slow-path
   calls leave at the remembered-bit test) and the bound came from that.
   Write the fallback into the rule before the cheat is run.
 - The tier's A/B table is read when every gate passed. The first tier
   run of part 2 was `failed=0` and its table had st-closures 4.4 percent
   slower: the SmallFloat path, inline, grew `specialSend` from 764 to
   1004 instructions and the closure activation in the same function lost
   a register. A change measured on the kernel it is for (`floats`, 0.43)
   is measured on every other kernel before the tier, not by it.
 - A counter decides a module before a brief does. One relaxed counter
   (`weakOnlyCopies`) on four loads said the weak pass of the concurrent
   young collector would save 2 objects in 1.37 million promotions; the
   reviewer's estimate had no number. And a load meant to show the cost is
   checked to reach it: Symbols are old at birth, so interning and
   dropping a million read 0 of 0.
 - A thin test that is not the module's is still counted with the head's
   own rate beside the start's. "Head 3 of 4, start 0 of 2, no mechanism
   in the diff" is what is known; neither "the module caused it" nor "it
   was thin already" is, and the record says the counts.
 - A Process that stops on an error prints its frames in the failure line
   that reports it. Three modules counted "nil does not understand
   #beginsWith:" in the tools test and briefed a suspect (the type
   service's key selects); the stopped Process's two frames named the
   test's own probe reading a new method's source. Print the stack before
   naming a suspect, and a brief's suspect is one candidate.
 - What other workers can find is complete when it becomes findable:
   records first, then the install, or both under the lock its readers
   take. `Behavior>>compile:classified:` installed a method and then
   recorded its source; with two workers no preemption is needed for a
   reader to stand in that gap. Closing it, the same shape was beside it
   twice (a reshape's remade methods, a new class's definition).
 - An inner wait longer than the outer one renames the failure. The
   probe's drive bound under the sanitizer (150 s) outlasted `until`'s
   60 s, so a probe stopped at an error read as "the step never held";
   in a plain build the stop cost 30 s and the test passed. A helper
   that waits says why it gave up, at each level.
 - A natural count after a fix is not the fix's evidence when the count
   before could be 0. The bundle under the sanitizer read 0 of 3 after
   and 0 of 2 before; the forced condition (a wait at the one place: 3 of
   3 before, 0 of 3 after; the kernel tests 20 of 20 and 0 of 20) is the
   evidence, and that a natural failure had this stack is inferred from
   the same error at the same step, not seen.

## Verification

Since 2026-11-07 (the owner's decision when the VM core was declared done;
the interpreter-speed module, its last, landed the same evening) the gates
are tiered by what a diff touches: Smalltalk only (`kernel/`, `tools/`, `apps/Shared/smalltalk`)
runs the image build, the kernel tests, the compiler tests, `just golden`
and the Mac shell's tests mode; Swift outside the core runs a clean build,
`swift test`, ThreadSanitizer once alone, the kernel tests, `just apps`,
`just new-check` and the one relevant fuzzer for 120 s; a change under the
core directories (`Sources/KajoVM/{ObjectMemory,Interpreter,Loader,Workers,
Processes,Nursery,Marking,Relocation,YoungCollection,ObjectModel,Native}`
and, since AOT 1, `Sources/KajoAOT/`) runs all 18 gates, the native
engine's three (`native-golden`, `native-kernel-test`, `native-cc`), the
aligned A/B, `just arc-check` and the device rows (24 lines in `gates.log`). Since gate speed (2026-11-13, `docs/modules/gate-speed.md`) the core tier is 21 gates: `check-tier-test`, the clean build, `swift-test-load`, `tsan`, `tsan-load`, `ios-check`, `arc-check`, `golden`, the native engine's three, `test-release`, `model-check`, `soak`, one `fuzz` gate running the four targets side by side for 600 s each, `apps`, `kernel-test`, `new-check`, the aligned A/B and the Mac and iPhone matrices; plain `swift test` is not in it (the owner's decision; the Swift tier and the weekly run keep it), the Swift tier's fuzzers run through the same `fuzz` gate for 120 s, `check-tier-test` is a gate whenever a gate script changes, and the weekly run is every gate of every tier plus the aligned A/B against the last finished weekly's commit. Since the verifier's two faults (2026-11-21) the heap verifiers run in the release build's kernel tests (`test-release`, which asserts `verify=on` and `verifies` above 0 per part) and the debug kernel gates (`kernel-test`, `tools-test`) say `--no-verify` (the owner's answer of 2026-11-20). Since part 2 of the small fixes (2026-11-22) a level has a name (`verify=off|stops|all`): `test-release` runs at `all`, the stop verifiers with the heap verifiers, and the debug kernel gates' `--no-verify` prints `verify=stops`, which is what they ran before.
`just check [base]` (`scripts/check-tier.sh`, built 2026-11-07 in the
gate-tiers module, `docs/modules/gate-tiers.md`) decides the tier from
`git diff --name-only <base>...HEAD` plus the working tree (`origin/master`
by default), prints the files that chose it and runs the tier's gates one
after another into `.build/check/<date>/` with a `gates.log` naming the
commit and the toolchain per gate (`--dry-run` lists them, `--tier`
overrides, `KAJO_CHECK_OUT` moves the output); a docs-only diff exits 0
in 0.1 s saying so, and two tiers owe the higher. As built the Smalltalk
tier also builds the development image and runs the tools' tests, the
Swift tier runs `just model-check` when `models/` changed and every
fuzzer whose reader the diff touches (`Sources/KajoDev`: protocol;
`Sources/KajoCompiler`: syntax; a fuzz target or its seeds: that one;
the kasm parser and the snapshot loader live in `Loader/`, which is the
core). A module's hand-back runs the tier on its final code commit
through `just check` and quotes that `gates.log`. The
full set with the device matrix runs weekly on the mini (Monday 02:00 since the owner's
decision of 2026-11-14, Sunday before;
the LaunchAgent `dev.katajamaki.kajo.weekly` running `scripts/weekly.sh`,
loaded by the main session on 2026-11-08, writing `~/kajo-weekly/<date>/`
with a `summary.md` that tabulates every matrix's raw rows, `just
weekly-status`; it refuses, exit 0 and one line in
`~/kajo-weekly/weekly.log`, when a `kajo`, `swift-build`, `swift-test`,
`xcodebuild`, `KajoShell`, `Sample` or `yes` process of the user runs
outside its own process group, so no agent starts a gate or a device run
on a Monday morning without reading that log first, and nothing of Kajo
is started while a weekly run is in progress). No paid CI: the repository is public but fuzzing,
ThreadSanitizer and macOS runners do not run on GitHub; releases are
built on the mini and uploaded.

Experiments are evidence, not production code; `docs/VERIFICATION.md` says
how the production core is built from them and lists the verification
layers it needs: a checked build with every verifier on, the stop-the-world
collector kept as an oracle, stress modes, randomized programs, schedule
perturbation, a model of the concurrent protocols, loader fuzzing, counters
as telemetry, and device runs. Read it before starting `Sources/KajoVM`.

## Decisions

Architecture decisions live in `docs/adr/`, one per file (0001 to 0015),
each pointing at the experiment that produced its evidence and carrying
"Built" notes from the modules that built it. ADRs 0003, 0006 and 0008 carry
device measurements from an iPhone 17 Pro (experiments/device-measurement
and entry-locality) and energy measurements (experiments/power: marker at
utility, young collector at user-initiated on device; the marker's timed
wait is the VM's whole idle cost). Read them before touching the areas they
cover.

What each module measured, decided and left undone, with the owner's
answers, is one record per module in `docs/decisions/` (its README has the
rules). Read the record of an area before changing the area. Until
2026-11-15 the records were one paragraph here.

 - `docs/decisions/00-adrs-0001-to-0008.md`: ADRs 0001 to 0008
 - `docs/decisions/01-module-08a-object-model.md`: Module 8a: object model and bytecode set (ADR 0009)
 - `docs/decisions/02-module-08b-kernel-image.md`: Module 8b: the kernel image
 - `docs/decisions/03-module-08c-image-processes.md`: Module 8c: Processes saved in the image
 - `docs/decisions/04-module-08d-kernel-live.md`: Module 8d: live methods, class variables, the release flag
 - `docs/decisions/05-module-09a-shells.md`: Module 9a: the native shells
 - `docs/decisions/06-module-09b-development-protocol.md`: Module 9b: the development protocol and the debugger
 - `docs/decisions/07-module-09c-developer-ui.md`: Module 9c: the developer UI
 - `docs/decisions/08-module-09d-phone-transport.md`: Module 9d: the phone transport, the device rows and the devices investigation
 - `docs/decisions/09-distribution-shape.md`: The owner's distribution shape (2026-11-05)
 - `docs/decisions/10-module-10-large-objects.md`: Module 10: large objects
 - `docs/decisions/11-large-bytes.md`: The large-bytes follow-up
 - `docs/decisions/12-development-answers.md`: The development answers
 - `docs/decisions/13-final-mark.md`: The final mark on the devices; the VM core declared done
 - `docs/decisions/14-reserve-and-depth.md`: The reserve-and-depth follow-up
 - `docs/decisions/15-module-08e-live-classes.md`: Module 8e: live classes
 - `docs/decisions/16-vm-teardown.md`: The vm-teardown follow-up
 - `docs/decisions/17-collectors-review.md`: The collectors review
 - `docs/decisions/18-module-11a-app-project.md`: Module 11a: the app project
 - `docs/decisions/19-runtime-comparison.md`: The runtime comparison and the performance report
 - `docs/decisions/20-interpreter-speed.md`: The interpreter-speed module
 - `docs/decisions/21-gate-tiers.md`: The gate tiers and the weekly run
 - `docs/decisions/22-sweep-stop.md`: The sweep stop
 - `docs/decisions/23-collections-speed.md`: Collections speed
 - `docs/decisions/24-first-launch.md`: The first launch's gap
 - `docs/decisions/25-module-11b-distribution.md`: Module 11b: Distribution and the first release
 - `docs/decisions/26-simulator-slices.md`: The simulator slices
 - `docs/decisions/27-discoverability.md`: The discoverability follow-up
 - `docs/decisions/28-pointers-to.md`: The pointersTo: follow-up
 - `docs/decisions/29-tags-as-subdirectories.md`: Tags as subdirectories
 - `docs/decisions/30-review-fixes.md`: The second review and its fixes, parts 1 and 2
 - `docs/decisions/31-project-directory.md`: The project directory decided by the host
 - `docs/decisions/32-aot-1.md`: AOT 1: the native engine
 - `docs/decisions/33-allocation-stalls.md`: Allocation stalls and the stop rows' last parker
 - `docs/decisions/34-gate-speed.md`: Gate speed and the stall tests' follow-up
 - `docs/decisions/35-symbol-interning.md`: Symbol interning without a stop
 - `docs/decisions/36-gate-speed-follow-ups.md`: Gate speed's follow-ups
 - `docs/decisions/37-aot-2.md`: AOT 2: the product
 - `docs/decisions/38-native-by-default.md`: Native code on by default in a Release build
 - `docs/decisions/39-interning-tests.md`: The interning tests drive their race
 - `docs/decisions/40-main-offload.md`: The main worker always offloads its young collections
 - `docs/decisions/41-main-flips.md`: The main worker's flips under load, a matrix row
 - `docs/decisions/42-fused-sends.md`: Fused sends, measured first (stopped at the bound)
 - `docs/decisions/43-optional-types.md`: Optional types: the direction
 - `docs/decisions/44-types-1.md`: Types 1: the syntax
 - `docs/decisions/45-types-2.md`: Types 2: the checker in the development image
 - `docs/decisions/46-delay-outlives-vm.md`: A Delay does not outlive its VM
 - `docs/decisions/47-shell-close.md`: A closed shell frees its VM
 - `docs/decisions/48-closed-shell-calls.md`: A closed shell refuses its host's calls
 - `docs/decisions/49-types-3.md`: Types 3: diagnostics in the tools
 - `docs/decisions/50-review-3-small-fixes.md`: The third review's small fixes, part 1
 - `docs/decisions/51-verifier-faults.md`: The verifier's two faults
 - `docs/decisions/52-review-3-small-fixes-part-2.md`: The third review's small fixes, part 2
 - `docs/decisions/53-tools-test-fault.md`: The tools test's fault: a method seen before its source

Awaiting the owner: three small questions of the third review's small
fixes, part 1 (`50-review-3-small-fixes.md`, built 2026-11-21): the VM's
Delay timers on a queue of their own (a core change; recommended yes, with
a counter of how late a Delay fires first), the reconnect test's two
remaining margins under the sanitizer (recommended: leave and watch the
printed line), and `DevClient`'s log bound of 1024; and two of the
verifier's two faults (`51-verifier-faults.md`, built 2026-11-21 on the
owner's "Yes, brief it"): the verifier levels as built (on in a release
build's kernel tests and stall tests and in every `kajo test` not told
otherwise, the debug kernel gates saying `--no-verify`; recommended: as
built), and whether fault 1 is said in a release's notes (recommended: no,
only a program that edits a CompiledCode's literals before making it
reached it); and three of part 2 of the small fixes
(`52-review-3-small-fixes-part-2.md`, built 2026-11-22 on the owner's "Yes,
brief it"): `test-release` at the level `all`, which adds the stop
verifiers to that one gate (recommended: keep), no module for the weak pass
of the concurrent young collector (2 weak-only copies in 1.37 million
promotions was the most any load showed; recommended: no module, the
counter stays), and a runner for the by-hand broken variants in the weekly
run (recommended: a later module); and two of the tools test's fault
(`53-tools-test-fault.md`, built 2026-11-22 on the owner's "Yes, brief
it"): the registry's lock held across the reshape primitive, a second
Process's longest `sourceOf:` wait 5.9 ms from 3.5 (recommended: as
built), and nothing in a release's notes (recommended: none). Found and
not briefed: eight workers that each intern a million Symbols fail every
`asSymbol` after 390 s; `removeSelector:` and a replaced method leave a
reader that already holds the old method with a nil source; an error in
the type service's recheck ends its Process in a batch host and later
changes queue with nothing to drain them.
Types 3's five questions were answered as recommended on 2026-11-19
(appended to `49-types-3.md`: the mark stays a pale background; the
selectors table's mark stays; the checker starts at a session's first
class selection; the first request is measured on the iPhone in the next
device run before it gets a timeout of its own; the typed overrides'
contradictions are counted before the narrowing rule is built).
Closed-shell-calls' two questions were
answered as recommended on 2026-11-19 (appended to
`48-closed-shell-calls.md`: the closing thread's rule is not enforced;
`RunningTarget.close()` was fixed on the owner's word the same day,
ec0a6ef, with the shell-close reproduction's wait). Types 2's five questions were answered as recommended on
2026-11-18 (appended to `45-types-2.md`; one changes what is built and is
a row of `docs/PLAN.md`: a VM's pending timers cancelled at its end). Types 1's questions were answered on
2026-11-17 (appended to `44-types-1.md`): for the 45 signatures "`Self`
where possible", then a signature without a method, a method entry with
no body (approved, not built); `kajo seal` stays as it is; types in the
browser's class definition wait for a later module; `:X` and `;` stay. Optional types' five questions were answered
as recommended on 2026-11-17 (appended to `43-optional-types.md`: explicit
`Nil`, overloads, narrowing by class tests, class-level types as Tonel
keys, protocol types made by code only). Fused sends was closed as measured on
2026-11-17 (appended to `42-fused-sends.md`). Main flips' two questions were answered as
recommended on 2026-11-17 (appended to `41-main-flips.md`). Main
offload's question 5 was answered on
2026-11-17 ("Yes, build it", appended to `40-main-offload.md`; built as
`docs/modules/main-flips.md`). Native by default's four questions were
answered as recommended on 2026-11-16 (appended to
`38-native-by-default.md`). The final mark's four, interpreter speed's three and AOT 2's five were
answered on 2026-11-15 (appended to `13-final-mark.md`,
`20-interpreter-speed.md` and `37-aot-2.md`). Three answers change what is
built and are rows of `docs/PLAN.md`: native code on by default in a Release
build (built 2026-11-16), the main worker always offloading its young
collections (built 2026-11-17), and fused sends measured first (measured
2026-11-17: under the rule, not built).

## Project structure

 * `Package.swift` is the root SwiftPM package: `KajoVM` library, `kajo`
   headless CLI, `KajoCompiler` library, `KajoApp`, `KajoAppDevelopment`
   and `KajoGenerator` libraries (module 11a: what a generated app links,
   its Debug-only serving half, and `kajo new`), `KajoShellCore` library
   (the shells' modes, module 9a), `KajoVMTests` and `KajoCompilerTests` (Swift
   Testing; `ShellTests` live in the latter).
 * `Sources/KajoVM/` the VM core, one directory per module:
   `ObjectMemory/` (module 1, built; `docs/modules/object-memory.md`;
   since module 10 large objects as runs of contiguous blocks with a
   one-byte block-kind side table, `docs/modules/large-objects.md`),
   `Interpreter/` and `Loader/` (module 2, built; `docs/modules/interpreter.md`),
   `Workers/` and `Processes/` (module 3, built; `docs/modules/workers.md`:
   workers, safepoints, Process-owned stacks, scheduler, budgeted
   preemption, external signals, the seeded random-program generator and
   `just soak`; since the collectors review `RecordRing.swift`, the ring
   every collector log is, `docs/modules/collectors-review.md`), `Nursery/` with `ObjectMemory/Generations.swift` (module 4,
   built; `docs/modules/nursery.md`: per-worker eden and survivors, age and
   claim tags, barrier and remembered set, parallel stop-the-world scavenge,
   entry stashes, weak slots, ephemerons in the oracle, the finalization
   queue, snapshot v2), `Marking/` with `ObjectMemory/OldMap.swift` (module
   5, built; `docs/modules/concurrent-marking.md`: old map and snapshot map,
   SATB barrier behind the flag word, the marker thread as a VM participant,
   initial mark at the end of a scavenge, final mark with the remembered
   filter, ephemerons and weak slots, lazy sweep into pending runs applied
   at the next pause, triggers and counted fallbacks, the QoS policy, the
   final-mark verifier; since the final-mark follow-up
   `Marking/RootScans.swift`, the deferred young-root scans the initial
   mark leaves owed, the work-bounded final mark and the per-final-mark
   record, `docs/modules/final-mark.md`; `kajo run --gc cm|stw`),
   `Relocation/` (module 6,
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
   `kajo run --young stw|local|offload --main-ms`),
   since the interpreter-speed module `Interpreter/Opcodes.swift` holds
   the 17 fused opcodes (50 to 66) and `Opcode.fused`, `Dispatch.swift`
   their cases, `Loader/MethodBuilding.swift` the `fuseBytecodes` peephole,
   `Interpreter/OpcodeCounts.swift` the counting build (`-DKAJO_COUNT_OPCODES`,
   `KAJO_OPCODE_COUNTS`), primitive 166 `CompiledMethod>>plainBytecodes`,
   and `kajo run` reports `workerCycles` and `workerInstructions`
   (`docs/modules/interpreter-speed.md`), `ObjectModel/` with
   the v1 parts of `Interpreter/` and `Loader/` (module 8a, built;
   `docs/modules/object-model.md`: SmallFloat and Character immediates,
   the class format word and classic metaclasses, bytecode set v1 with
   the `ext` prefix and one bytecode verifier, closures, temp vectors,
   Contexts materialized on demand and detached on return, non-local
   return and the unwind and handler walks, super and the `perform:`
   family, method installation in a stop, LargeIntegers and boxed Float,
   the UTF-8 String and interned Symbol primitives, read-only bit 50 in
   every store path, stack growth by copying, pragma literals, the image
   format and its loader; module 8b added `ObjectModel/Symbols.swift`'s
   weak table and `ObjectModel/KernelPrimitives.swift`),
   `Processes/SavedProcesses.swift` with `Loader/SavedProcessRules.swift`
   (module 8c, built; `docs/modules/image-processes.md`: the saved form,
   the save's hold and stop, the load and resume, the loader's rules for
   saved frames, queues and waiters, `kajo run --snapshot-at`), `Headless.swift`
   the public entry `kajo run` uses. `Sources/KajoCompiler/` the bootstrap
   compiler (module 8b, built; `docs/modules/kernel-image.md`: Smalltalk
   method syntax and Tonel files to the assembler's encoder and the one
   bytecode verifier, the variable-layout and inlining rules at the top of
   `Compiler.swift`, the image build, the test harness and its event
   stream). `Sources/KajoVM/Shell/` the public host surface (module 9a,
   built; `docs/modules/shells.md`: `ShellVM`, `ShellValue`, `ShellEvent`,
   `ShellCallbacks`, primitives 150 to 154: the view hop, `hasShell`,
   release, the event Semaphore, `nextEvent`; no oop crosses it).
   `Sources/KajoApp/` (module 11a, `docs/modules/app-project.md`) the
   runtime (`ShellRuntime` on the main run loop with the frame account),
   `AppKitHost` and `UIKitHost` with the views, `KajoApplication.main`,
   and since the devices' follow-up `AfterFrames` (a step at the N-th
   frame or after a bound), `KajoAppRunner.startDevelopment` and the
   launch trace (`kajo-launch-report`);
   `Sources/KajoAppDevelopment/` serving, the token store, the pairing
   screens and `Development`, linked by Debug apps and the shells only;
   `Sources/KajoGenerator/` the app project generator and its templates
   (fixture under `Tests/KajoCompilerTests/Fixtures/app-project`; since
   11b the project names the checkout's `Prebuilt/` package, `--platforms`).
   Since module 11b (`docs/modules/distribution.md`)
   `Sources/KajoShellCore/Product.swift` is the Kajo app's product mode
   (the checkout copy to Application Support, the tools, New App…,
   Install Command Line Tool…), `scripts/dist.sh <version>` builds the
   dmg (`just dist`; `dist.sh checkout <dir>` the working tree's checkout
   with `Prebuilt/`, used by `new-check.sh` and `app-roundtrip.sh`, which
   take `APP_PROJECT`, `KAJO_CHECKOUT`, `KAJO_NEW` and `KAJO`),
   `scripts/dist-frameworks.yml` is the xcodegen spec the four static
   xcframeworks are built from, `kajo-bench=<kernel.kasm>` is `KajoApp`'s
   launch argument for the Debug-against-Release measurement, and
   `DistributionTests` cover the product mode.
   `Sources/KajoShellCore/` the shells' modes (tests, golden, scenario,
   demo, dev, devsession, serve) and telemetry. `Sources/kajo/` the CLI (`kajo run`, `kajo build-image`,
   `kajo test [image] [--filter] [--tag] [--junit]`); `Sources/fuzz-kasm/`,
   `Sources/fuzz-snapshot/`, `Sources/fuzz-syntax/` and
   `Sources/fuzz-protocol/` the libFuzzer targets (`just fuzz
   kasm|snapshot|syntax|protocol <seconds>`, needs a swift.org toolchain;
   Xcode's ships no libFuzzer runtime). `Sources/KajoDev/` (module 9b,
   `docs/modules/development-protocol.md`) the development protocol's host
   side: bounded JSON, the Unix-socket server and token, the headless
   `DevTarget`, the client, the MCP server and the CLI's development
   commands, and since 9c `ClientHost`, the image's client transport
   (primitive 164: targets, connect, send, close, timer, and since 9d
   pairing; the token stays in the host); since 9d (module 9d,
   `docs/modules/phone-transport.md`) the server and the clients speak TCP
   as well (`TargetAddress`, Bonjour through dns_sd and `NWBrowser`, `kajo
   run --protocol tcp[:port] --name`); `Sources/KajoVM/Processes/Debugging.swift` the stop, step and
   interrupt machinery; primitives 159 to 161 carry requests and replies.
   The kernel's `DevSession` holds the requests as `<devProtocol>` methods. `scripts/`:
   `check-hot-path-arc.sh` (`just arc-check`) greps the release disassembly
   of the dispatch loop, send, primitive and allocation paths for retain and
   release and asserts the loop is one jump table; `golden.sh` (`just
   golden`) runs the fixture kernels through `kajo run` against their
   published checksums; `just test-release` runs the suite in a release
   build with the full-size kernels; `apps-check.sh` (`just apps`) builds
   both shells with xcodebuild from clean, 0 warnings or fail; `device.sh`
   (`just device`) builds, signs, installs and runs the iOS shell on the
   attached iPhone through `devicectl`; `mac-shell.sh`, `shell-matrix.sh`
   and `shell-report.py` run the scenario matrix and make its tables
   (since the first-launch follow-up the matrix's warm-up launch in
   `warmup.txt`, `WARMUP=0`, printed as a line and never a row; the
   scenario mode's launch trace and gap records in
   `Sources/KajoShellCore/FrameGaps.swift`, `gaps100` and
   `gap_max_at_ms` on the result line; `docs/modules/first-launch.md`);
   `canonical-tonel.sh` rewrites a package in the image's canonical form;
   `remote-session.sh` and `remote-report.py` (module 9d) run the scripted
   session against a serving target (the phone through `device.sh serve`
   and `device.sh token`, the Mac shell's `mode=serve`, or `kajo run
   --protocol tcp`) and make its tables; since module 11a `device.sh`
   takes `PROJECT`, `SCHEME`, `CONFIG`, `PRODUCT` and `BUNDLE` (the shell's
   or the sample's identifier only), `new-check.sh` (`just new-check`)
   generates an app, builds its four products from clean and checks the
   Release binaries and the Debug VM's compile line (since the
   simulator-slices follow-up also the iOS Debug build for a generic
   simulator; `dist.sh` builds three slices per framework,
   `ios-arm64-simulator` the third; `docs/modules/simulator-slices.md`), and
   `app-roundtrip.sh mac|device` runs the generated app's live round trip;
   `perf-report.py` (the runtime comparison, 2026-11-07) writes the generated
   blocks and SVGs of `docs/performance/README.md` from
   `experiments/runtime-comparison/bench-raw.txt` and `slices-raw.txt`;
   since the gate-tiers module (2026-11-07, `docs/modules/gate-tiers.md`)
   `check-tier.sh` (`just check [base]`, `--dry-run`, `--tier`, `--paths -`)
   over `gates-lib.sh` (one gate: name, command, bound, output check;
   `gl_gate`, `gl_cleanup` kills the load loops and shells), its
   `check-tier-test.sh`, `weekly.sh` (`just weekly`; `KAJO_WEEKLY_QUICK=1`,
   `KAJO_WEEKLY_ONLY`, `KAJO_WEEKLY_DEVICES`, `KAJO_WEEKLY_ROOT`),
   `launchd/dev.katajamaki.kajo.weekly.plist` (`just weekly-install`
   fills `__HOME__` and `__REPO__`, copies it and prints the `launchctl`
   commands; `just weekly-status`), `device-rows.sh <udid> <out>` (the
   device build with the codesign watchdog, then the matrix), `ab.sh
   <base> <out>` with `ab-table.py` (the aligned `-enable-testing` A/B),
   `release.sh` (since 11b `just release <tag> [--dry-run]`: the local tag,
   `scripts/dist.sh`, the notes and the `gh release create` line), and `shell-report.py
   --bar <dir>` (the bar's columns over every raw row);
   `link-probe.sh` with `link-probe.py` (the devices investigation) times
   one small request against several serving targets in the same window
   beside each target's own serve times; the shells' `mode=spin` runs N
   threads for a fixed CPU time (the energy counters' known workload) and
   `KAJO_SHELL_CLASSES` bundles a generated image of that many classes.
   Since the large-bytes follow-up `Sources/KajoVM/ObjectModel/LongBytes.swift`
   holds the polled byte primitives over long objects, `Marking/Sweep.swift`
   the fallback record and the sweeps finished in a stop (since the
   sweep-stop follow-up the `sweep` stop kind, `SweepStopRecord`, the
   bounded partial apply `publishSwept`, `waitForSweep`, the `entryRate`
   trigger in `InitialMark.swift`, `kajo run --sweep-stop-words n|-1
   --entry-rate on|off`, `Tests/KajoVMTests/Marking/SweepStopTests.swift`;
   `docs/modules/sweep-stop.md`), the shells have
   `scenario=photo` (48 MB ByteArrays filled and dropped on a background
   Process), `experiments/large-bytes/` the sentinel-against-words
   experiment (since the collections-speed follow-up primitives 121 and
   122 take any byte object, `kernel/ByteArrayTest.class.st` exists, and
   `experiments/runtime-comparison/programs/collections-{oc,dict,stream,sort,empty}`
   are the collections program's parts, `bench.sh`'s `$PARTS`;
   `docs/modules/collections-speed.md`), and `KAJO_MEASURE_LONGBYTES=1` the long byte objects'
   measurement.
   Since the development answers primitive 165 (`Debugger class
   primHostStopsErrors`) reads the host's `stopsForDebugger`, the kernel
   has `Unwinding` (cut-off counting) and `Transcript showLine:`, the
   shells `debugstop=noclient` (an error with no client, serve, connect,
   proceed; `KAJO_MEASURE=1` for the memory a standing stop holds), and
   `session.open`'s answer lists standing stops. Since the discoverability
   follow-up primitives 167 and 168 (`ObjectModel/InstancePrimitives.swift`,
   the old-map walk in `ObjectMemory/Instances.swift`, the stop kind
   `instances`) back `Behavior>>allInstances`, `allInstances:`,
   `allSubInstances` and `instanceCount`; the tools' Smalltalk, context and
   Help menus are item lists in `DevTools` and the shells have `mode=devsession
   session=instances` (`docs/modules/discoverability.md`); since the
   `pointersTo:` follow-up primitives 169 and 170 (the slot scan
   `walkPointers` in `ObjectMemory/Instances.swift`) back `Object>>pointersTo`,
   `pointersTo:` and `pointerCount`, the Smalltalk menu's Objects pointing to
   it (⇧⌘O), the Inspector's slots menu and `session=pointers`
   (`docs/modules/pointers-to.md`). Since the third review (2026-11-20, the owner: mechanical sympathy, architecture and code reuse; six read-only reviewers, nothing built or measured) `docs/reviews/2026-11-20/` holds the six reports (memory, collectors, interpreter, hosts, smalltalk, verification; findings are named `<area>.M<n>`, `.A<n>` and `.R<n>`, each with the measurement that bounds it; none is built or decided). Since the second review (2026-11-10) `docs/reviews/2026-11-10/` holds the five reports (collectors, interpreter, kernel, primitives, tools; findings are named `<area>.F<n>`), `docs/modules/review-fixes.md` the fixes' brief and what was built, `Tests/KajoVMTests/ReviewFixes/` and `Tests/KajoCompilerTests/ReviewFixes{Kernel,Transport}Tests.swift` their tests, `kernel/Tests/RegistryTest.class.st` the registries' lock under load, and `VMTestSwitches` gained `slowPeek`, `buildingPauseUs` and `walksSeeBuilding`. Since part 2 (2026-11-11) `ObjectModel/IdentifierRule.swift` holds the one identifier rule and primitive 171, `Loader/KernelCompilerProbe.swift` the compilers' comparison (test and fuzz support only), `scripts/fuzz.sh syntax-kernel` (`KAJO_FUZZ_KERNEL`) the syntax fuzzer's kernel mode, `Tests/KajoCompilerTests/Fixtures/compiler-corpus/corpus.txt` the compilers' corpus, `Tests/KajoCompilerTests/ReviewFixesPart2Tests.swift` part 2's tests, `kernel/Streams/LimitedWriteStream.class.st` the bounded printing stream, and `check-tier.sh` takes `KAJO_CHECK_REPO` for its tests. Since the project-directory follow-up (2026-11-11, `docs/modules/project-directory.md`) `Sources/KajoDev/Project.swift` holds `ProjectRefusal` and `ProjectMemory` beside `ProjectWriter`, `ClientHost` has `setProject(_:for:)`, `setDirectoryPrompt` and `useProjectMemory` and the ops `project` and `chooseProject`, `setHostProjects` in `Sources/KajoShellCore/DevModes.swift` is the one place a host sets a directory, the product mode remembers choices in `<support>/project-directories`, and `Tests/KajoCompilerTests/ProjectDirectoryTests.swift` holds its tests. Since AOT 1 (2026-11-12, `docs/modules/aot.md`, ADR 0015) `Sources/KajoAOT/Generator.swift` is the generator from an image's methods to C (`kajo aot <image>|<file.kasm>... -o <dir>`; linked by `kajo`, the tests and `fuzz-kasm` only, never by an app; `AOTOptions.brokenNoSendCount` and `brokenNoFlushAtPoll` are its broken variants), `Sources/KajoVM/Native/` the runtime half (`NativeState`, `NativeLayout` with the constants the layout hash covers, `NativeBinding` with the content hash and the method-to-native side table, `NativeInterface` with the C-callable slow-path wrappers and the driver `drive`, `NativeInput` what the generator reads of an image), `kajo run --native <dylib>` and `kajo test --native <dylib>` bind a compiled module and the run line carries its counters (`nativeBound`, `nativeDeclined`, `nativeBindMs`, `nativeSends`, `toNativeAtPoll` and the rest), `scripts/native-check.sh golden|kernel-test|cc` are the gates `just native-golden`, `just native-kernel-test` and `just native-cc`, `KAJO_SHELL_AOT=1` makes `apps/Shared/build-images.sh` build each bundled image's module as a signed dylib that the shells' `native=1` binds, `KAJO_NATIVE_HARNESS=1 KAJO_NATIVE_RUNTIME=1` run the VM suite natively, `KAJO_FUZZ_AOT=1` runs the generator over every image a kasm fuzz input loads, and `Tests/KajoVMTests/Native/` holds its tests with the native random programs in `Tests/KajoVMTests/Workers/RandomPrograms.swift`. Since the allocation stalls (2026-11-13, `docs/modules/allocation-stalls.md`) `Sources/KajoVM/Marking/Pacing.swift` holds `stallForCollector`, the stall records, the per-cycle `CycleRecord` (`cycleRecs` on the run line, `gc_cycleRecs` in the shells' rows) and the marker's slowdown; `SafepointState.progress` is the word a stall waits on; `noteFullCollection` in `Marking/Sweep.swift` takes a cause and a requester and counts `unjustifiedFallbacks`; `ObjectMemory.reservePromotion(blocks:belowSoftLimit:)` and `canPromise` are the promise rule; `kajo run --stalls on|off --marker-slowdown n --stall-reloc plain|reserve|skip` and the shells' `stalls=off`, `markerslow=`, `stallreloc=`; the test switches `noStalls`, `stallsWithoutMarker`, `markerSlowdown`, `stallJustifiedByRunningCycle` and `stallIgnoresEntries`; the run line's `stalls*`, `fallbacks*` by cause and requester, `fallbacksAvoided`, `markerOverrides`, `youngAllocMain` and `promotedMainMB` (`allocWaits*` and `sweepWaits*` are gone); `shell-report.py --bar` has the columns unjustified fallbacks and stalls (longest ms); `Tests/KajoVMTests/Marking/AllocationStallTests.swift` holds the tests and the random programs have a `slowedMarker` configuration. Since the stop rows' follow-up (2026-11-13, 40ce930) `stopsByKind(_:workerCount:)` and `participantName(_:workerCount:)` in `Sources/KajoVM/Headless.swift` write each stop kind's last parker and how it parked, `longest_wait` in `scripts/shell-report.py` reads them for `--bar`, and `Tests/KajoVMTests/Workers/StopsByKindTests.swift` holds the test. Since gate speed (2026-11-13, `docs/modules/gate-speed.md`) `kajo test --test <Class>>selector>... --list` selects and lists tests by exact name (`TestRunner casesFilter:tag:tests:`), `KernelTestParts` in `Tests/KajoCompilerTests/KernelImageTests.swift` runs the kernel's tests as weighted parts in parallel VMs (`KAJO_KERNEL_TEST_PARTS`, two by default), `Tests/KajoVMTests/Native/NativeCache.swift` is the disk cache of compiled native test modules (`.build/native-test-cache`, `KAJO_NATIVE_CACHE=off|<dir>`), `scripts/fuzz-gate.sh <seconds> <out> <targets>` is the fuzz gate over `fuzz.sh --build` and `--run`, `gates-lib.sh` has `gl_skip` and `gl_weekly_ab_base`, `weekly.sh --gates` prints the weekly's steps, and `ToolsProbe class>>remoteState` is the reconnect test's diagnostic. Since the stall tests' follow-up (2026-11-14) `MarkingShared.slowdown` and `VM.setMarkerSlowdown(_:)` let a test change the marker's slowdown while it runs, `VM.markerThreadSample`, `stallsNow` and `markingCycleNow` read the collector without a stop, and `StallDiag` in `Tests/KajoVMTests/Marking/AllocationStallTests.swift` (`wait`, `waitProgress`, `unslow`, the `stall-diag` lines and each test's body time) is how a stall test waits and explains itself. Since Symbol interning without a stop (2026-11-15, `docs/modules/symbol-interning.md`) `Machine.internSlow`, `growBucket`, `makeWhole` and `discardSymbol` in `ObjectModel/Strings.swift` are the insert under `internLock` (beside `InternState` in `Workers/VMState.swift`), `verifySymbolTable` and `verifyInternLockFreeAtStop` in `ObjectModel/Symbols.swift` its verifiers, `models/Sources/SymbolInterningModel/` its model (`docs/models/symbol-interning.md`), the stop kind `intern` and the run line's intern counters read 0, the test switches are `internNoKeepAlive`, `internNoSecondLookup` and `internPublishBeforeFill`, `Tests/KajoVMTests/ObjectModel/SymbolInterningTests.swift` holds the tests and the random programs have an intern step. Since gate speed's follow-ups (2026-11-15) `DevClient>>requestTimerAfter:do:`, `cancelRequestTimer:`, `armTimeoutFor:` and `reopened` with `DevClient class>>sendLimit` are the request timeout across a reconnect (`FakeDevClient` records and fires the timers), `BytecodeGenerator>>literalIndex:` keeps `literalBuckets` by `BytecodeGenerator class>>literalKey:` past 32 literals, and in `AllocationStallTests.swift` `ringSlowdown`, `fullHeapMiB` and `StallDiag`'s progress (young collections included) are the stall tests' sizes and waits. Since AOT 2 (2026-11-15, `docs/modules/aot-product.md`) `AOTOptions` in `Sources/KajoAOT/Generator.swift` holds the size levers (`kajo aot --hot`, `--[no-]send-helper`, `--[no-]shared-tails`, `--[no-]cold-minsize`, `--subset`, `--no-subset`, `--full`; the default is the product's configuration and `excluded.txt` names what a subset left to the interpreter), `NativeModule.linkedInMainImage` in `Native/NativeBinding.swift` finds a module linked into the app through the section `__DATA_CONST,__kajo_native`, `ShellVM.nativeBindReport` and `nativeGenerated` feed the launch report's `native=` line (`Sources/KajoApp/Application.swift`), a generated project has `scripts/build-native.sh` and the setting `KAJO_NATIVE` (`kajo new --native`), `scripts/native-check.sh` runs each native gate in the product's configuration and in `--full`, `new-check.sh` has the `-native`, `-native-again`, `-native-truncated` and `-native-stale` rows, `KAJO_AOT_OPTIONS` passes generator options to the native random programs, and `Tests/KajoVMTests/Native/AOTProductTests.swift` holds the levers' tests. Since native by default (2026-11-16, `docs/modules/native-by-default.md`) `AppProjectSpec.native` defaults to `true` and a generated project has `KAJO_NATIVE: YES`, `NewArguments.parse` in `Sources/KajoGenerator/Generator.swift` reads `kajo new`'s arguments (`--no-native`, `--native` still accepted), `Sources/KajoApp/Frames.swift` holds `FrameWindow` and `FrameAccount` so that `kajo-frames=` prints a frames line in a Release app too, a generated `scripts/build-native.sh` names `KAJO_NATIVE=NO` when its step fails and removes the libraries of keys no platform links, and `new-check.sh`'s plain Release rows are the native ones with the `-off` rows (`KAJO_NATIVE=NO`) as their negative control and `macos-release-changed` for the pruning. Since the interning tests' follow-up (2026-11-16, `docs/modules/interning-tests.md`) `internConcurrently(_:_:processes:gate:)` in `Tests/KajoVMTests/ObjectModel/SymbolInterningTests.swift` starts a round's Processes at a gate (the kasm method `internAll:arrivals:index:` in `internAllSrc`), the two race tests pass `gate: true` and print their body's own time. Since the main worker always offloads (2026-11-17, `docs/modules/main-offload.md`) `YoungMode` has the two cases `stw` and `offload` and `YoungMode.refusal(_:)` is the one refusal of any other name (`kajo run --young stw|offload`, the shells' `young=`), `MainThreadCollections` in `YoungCollection/YoungState.swift` and `mainThreadYoungReport` in `Headless.swift` write the run line's `ycOnMain*`, `ycHost*` and `ycMainCollectorWait*` (the shells' `gc_` keys and `main_collector_wait_max_ms`), the counter `youngOnMainFailures` is the check that worker 0 collected nothing while the collector thread ran, the test switch `mainCollectsItsOwnNursery` is its broken variant, the model has the configurations `ownershipOffloaded`, `shell-matrix.sh` runs `stw offload` (147 rows), `shell-report.py --bar` has the columns young on the main thread and the host's nursery and lists an unknown young mode as UNKNOWN, `Tests/KajoVMTests/YoungCollection/MainOffloadTests.swift` holds the tests and the random programs' configurations are `backgroundCollection` and `exhaustedReserveOffload`. Since main flips (2026-11-17, `docs/modules/main-flips.md`) `shell-matrix.sh` has the part `mainload` (the storm with `mainalloc=` and `mainwork=0` under `offload` and `stw`, `MAINALLOC` and `MAINWORK`, 153 rows a matrix), `shell-report.py` has `mainload_tables`, `flips_waits` (the `--bar` columns main flips and main waits for the collector) and `unknown_files` (a row file it does not know is tabulated as UNKNOWN), the scenario's result line carries `mainalloc=` and `mainwork=`, and a change to either script owes `check-tier-test`. Since Types 1 (2026-11-17, `docs/modules/types-1.md`) `Parser.parsePattern`, `TypeNode`, `expectTypeEnd`, `parseClassType` and `parseTypedVariables` in `Sources/KajoCompiler/Syntax.swift` read Strongtalk-style types in a method's pattern and a class definition (the same methods in the kernel's `Parser`, with `kernel/Compiler/TypeNode.class.st`, `MethodNode>>argumentTypes` and `resultType`, `Scanner class>>patternEndIn:` and `Parser class>>patternOf:`), both Tonel readers and `TonelWriter>>headerOf:` take and write `#typeParameters`, `#superclassType` and a type after a name in `#instVars`, `ClassTypes` in `Smalltalk`'s `classTypes` table (`typesOf:`, `noteTypes:of:`, `recordClassTypes:`) holds the class-level types as text in every image but a release build's, code generation reads no type, 27 kernel class files carry the slice's 577 signatures inline (`experiments/optional-types/scripts/inline.py`), `SourceColorer` colours a type, `Tests/KajoCompilerTests/TypesTests.swift` (`KAJO_TYPES_OUT`) and `kernel/Tests/TypeSyntaxTest.class.st` hold the tests, the compilers' corpus has 186 entries and the syntax fuzzer four typed seeds. Since Types 2 (2026-11-18, `docs/modules/types-2.md`) `types/` is the type checker's package (`Checker/`, `Live/`, `Model/`, `Tests/` and `DevSession.extension.st`, the `diagnostics` request and the `diagnostics.changed` event), built into an image by `kajo build-image --with types` (`just dev-image` and a generated app's Debug image; never a release image, which `new-check.sh` asserts with `checker_classes` and `signature_text`); a signature without a method is a Tonel method entry with no body in both readers and `TonelWriter`, kept in `ClassTypes` (`Behavior>>signature:classified:`); `Smalltalk changeListener:`, `noteChange:of:in:` and `changesDuring:` are the kernel's change hook, `TypeService` (`start`, `startCheckingAll:`) the live recheck on a background Process, `experiments/optional-types/scripts/place45.py` placed the 45, and `Tests/KajoCompilerTests/SignatureTests.swift`, `types/Tests/` and `~/kajo-scratch/types-2/scripts/broken.sh` hold the tests and the broken variants. Since the Delay fix (2026-11-18, `docs/modules/delay-outlives-vm.md`) `VMLife` in `Processes/External.swift` is the cell every `VMRef` and Delay timer holds (`whileLive`, `armTimer`, `timerFired`, `end`), `pushExternal` the push a VM thread calls directly, `VMEndReport.timersPending` and `undeliveredSignals`, `VM.lateSignals` and `VM.timersPending` the counters, `VMTestSwitches.lateSignalsIgnoreEnd` the broken variant (`KAJO_BROKEN_DELAY_END=1`, by hand) and `Tests/KajoVMTests/Processes/DelayEndTests.swift` the tests. Since shell-close (2026-11-18, `docs/modules/shell-close.md`) `ShellVM.close()` destroys at once and answers a `ShellCloseReport` (`Sources/KajoVM/Shell/Shell.swift`; `DevTarget.close()` answers it, `kajo run --protocol` prints a line when signals were undelivered), `closeObserver`, `afterShutdownForTests` and `brokenOldWaitSeconds` (`KAJO_BROKEN_SHELL_CLOSE=1`, by hand) are its test seams and `Tests/KajoCompilerTests/ShellCloseTests.swift` its tests. Since closed-shell-calls (2026-11-18, `docs/modules/closed-shell-calls.md`) `ShellVM`'s closed flag is an `Atomic<Bool>`, `checkOpen(_:)` is the check at the top of every member that enters the VM or the image, `refusal(_:)` answers its message ("ShellVM.<call> after close") or nil, `post`, `postRequest`, `queuedEvents` and `queuedRequests` stay unchecked, and `Tests/KajoCompilerTests/ClosedShellCallsTests.swift` holds the guard test, the table test over the source (`shellVMChecked`, `shellVMExempt`, `shellVMDelegating`) and the hand-run `aCallAfterCloseByHand` (`KAJO_CLOSED_SHELL_CALL`). Since Types 3 (2026-11-19, `docs/modules/types-3.md`) `DevClient>>refuses:` and `noteRefusal:of:` remember for a session a kind the target answered as an unknown request, `BrowserModel`'s diagnostics category (`askDiagnostics`, `diagnostics`, `diagnosedSelectors`, `diagnosticsChanged:`, `marks`, `sourceEdited`) and list category (`listDiagnostics:`, `askList`) hold the class-scope request, the marks' states and the diagnostics list, `BrowserWindow>>diagnosticStylesIn:` with `BrowserWindow class>>diagnosticStyle` and `diagnosticMark` draw them, the Smalltalk menu has Type diagnostics of the class (⇧⌘E) and of the image (⇧⌘D), `method.source` answers a signature without a method (`signature` true), `TypeService class>>keysOfClass:` is the class scope's keys, `FakeDevClient` answers and emits the `diagnostics` request and event, and `theBrowserMarksADiagnosticAndFollowsTheFix` in `Tests/KajoCompilerTests/ToolsTests.swift` is the real-target test. Since the third review's small fixes, part 1 (2026-11-21, `docs/modules/review-3-small-fixes.md`) `Headless.Options.verify` is a `Bool?` (nil is the build's level; `verifies`), `kajo run` and `kajo test` take `--verify` and `--no-verify` and print `verify=on|off` and `verifies=N` (`kajo test`, `KernelTestParts`, `ShellVM` and the stall tests' helper stay off until the make primitive's fault is fixed), `transcriptText(ofLine:)` in `Sources/KajoVM/Shell/TranscriptLine.swift` is the one transcript sink's test, `ProtocolClient.lateReplies` counts replies dropped after their request gave up, `ClientHost`'s timers run on the serial queue `kajo-client-timers`, `DevClient` has `replyCount`, `repliesOf:`, `outageCount`, `latenciesDropped`, `outagesDropped` and `DevClient class>>logBound`, `DevSession` keeps `objectHandles` beside `handles`, `DebugStop>>variablesOf:` keeps a stop's frame variables per method, `Monitor` has an owner and `abandon:`, `Tests/KajoCompilerTests/Review3SmallFixesTests.swift` and `Fixtures/monitor/` hold the tests, and `ToolsProbe class>>remoteDebuggerState` with `HostLog` in `ToolsTests.swift` are the reconnect test's diagnostics. Since the verifier's two faults (2026-11-21, `docs/modules/verifier-faults.md`) `MethodHeap.storeLiteral` in `Loader/MethodBuilding.swift` is the store of a literal into a made method's frame (the make primitive's `LiveMethodHeap` through the barrier, `BarrierSite.methodLiteral`; the image build's raw), `placeKept` in `Nursery/Scavenge.swift` scans again the young holders after kept bodies moved across nurseries (the counter `keptAcrossHolders` on the run line), `describeEntry` and `scavengeHistory` in `Nursery/NurseryVerifier.swift` write what each entry of a remembered-set failure is, `ParticipantStats.movedAcross` the moves it names, the test switches are `keptAcrossNurseries` and `keptAcrossWithoutRescan`, `kajo test` verifies at the build's level, `KernelTestParts` and the stall tests' helper verify in a release build and print `kernel part N: verify=on|off verifies=N`, the gates `kernel-test` and `tools-test` say `--no-verify` (`scripts/gates-lib.sh`), `ShellVM` stays off, and `Tests/KajoVMTests/Nursery/VerifierFaultsTests.swift`, `Tests/KajoCompilerTests/VerifierFaultsKernelTests.swift` and `Fixtures/verifier-faults/` hold the tests. Since the third review's small fixes, part 2 (2026-11-22, `docs/modules/review-3-small-fixes-part-2.md`) `VerificationLevel` in `Workers/VMConfig.swift` (`off`, `stops`, `all`; `build`, `withoutHeap`, `apply`) is the one place a verifier switch is set from, `Headless.Options.verify` is a `VerificationLevel?`, `kajo run` and `kajo test` take `--verify-level off|stops|all` and print `verify=off|stops|all`, `barrierWordIndex` in `Marking/MarkingState.swift` is the native layout's `FLAG_BARRIER_WORD`, the generator writes frame indexes from `Frame` and `_Static_assert`s of `KResume`, `KGroup` and `KModule` against `ResumeOffset`, `GroupOffset` and `ModuleOffset` (`Native/NativeBinding.swift`), `smallFloatArith` in `ObjectModel/Numbers.swift` with `smallFloatSpecial` (`Interpreter/Special.swift`) and `floatPrimitiveQuick` (`Interpreter/Send.swift`) answer a SmallFloat operation before any register save, `integerArith` builds no `BigInt` unless an operand is a LargeInteger, the run line has `smallFloatAnswers`, `largeArithCalls`, `specialSendTier` and `floatsBoxed`, the test switch is `noSmallFloatPath`, `weakOnlyCopies` (`YoungCollection/Collect.swift`, `weakFrom` and `classifyWeak`) is on the run line, in the shells' rows, in `kajo test`'s summary and the devsession line beside `ycPromoted`, and `Tests/KajoVMTests/SwitchTableTests.swift` (a test switch with no row fails), `VerificationLevelTests.swift`, `Native/NativeLayoutTests.swift`, `ObjectModel/SmallFloatPathTests.swift` and `YoungCollection/WeakOnlyCopiesTests.swift` hold the tests. Since the tools test's fault (2026-11-22, `docs/modules/tools-test-fault.md`) `Behavior>>compile:classified:` records a method's source and category before it installs the method and takes them back if the install unwinds, `ClassBuilder`'s `primRedefine:` with its records and `primDefineClass:` with `noteDefinition:` each run inside one `Smalltalk registry:` block, `kernel/Tests/SourceRecordTest.class.st` with `SourceRecordSample` holds the forcing tests, `ToolsProbe class>>stops` prints every standing stop with its frames in the tools tests' failure lines (`LocalTools.standingStops`, and `probe` says "did not end"), and `KAJO_TOOLS_HOLD_INSTALL=<ms>` forces the fault in the tools test by hand.
 * `tools/` the developer UI (module 9c, `docs/modules/developer-ui.md`,
   ADR 0013): 30 Tonel class files in the tag subdirectories `Client/`,
   `Models/`, `Tests/` and `Windows/` since tags as subdirectories
   (`docs/modules/tags-as-subdirectories.md`; a class file carries no
   `#category`, its tag is its subdirectory), `DevClient` over primitive 164, the
   models and windows of the browser, workspace, inspector, debugger, test
   runner, transcript and target picker, `FakeDevClient` and the SUnit
   tests; compiled into a development image by `kajo build-image --with
   tools` (`just dev-image`), opened on its own socket by `just tools`
   (the Mac shell's `mode=dev`; `mode=devsession` runs the scripted
   session and the typing measurement). Changes made through the tools are
   written back here.
 * `kernel/` Smalltalk sources the image is built from (module 8b: the
   kernel of `docs/modules/kernel.md` as built in
   `docs/modules/kernel-image.md`, with its SUnit tests beside the classes;
   174 Tonel class files, since tags as subdirectories (2026-11-09,
   `docs/modules/tags-as-subdirectories.md`) each in its tag's
   subdirectory (`Classes/`, `Collections/`, `Compiler/`, `Development/`,
   `Exceptions/`, `Methods/`, `Numbers/`, `Objects/`, `Processes/`,
   `SUnit/`, `Streams/`, `System/`, `Tests/`, `Text/`, `UI/`; nothing at
   the root but the README) with no `#category` key in the file, the tag
   being the subdirectory and the package the directory, in the canonical
   form the image itself writes (`Smalltalk writeTonel:`;
   `scripts/canonical-tonel.sh --check` asserts byte identity); `just
   build-image`, `just kernel-test`). The image is never committed.
   Its compiler in Smalltalk compiles every method and is compared with the
   bootstrap compiler's output by `CompilerTest`, and since module 8d
   (`docs/modules/kernel-live.md`) installs: `Behavior>>compile:`,
   `Compiler evaluate:`, class variables, Pharo's per-iteration temp
   vectors, the release flag. `Sources/KajoVM/ObjectModel/LiveMethods.swift`
   (primitives 143, 85, 144) and `Loader/MethodBuilding.swift` (what the
   image build and the make primitive share) are 8d's. Module 8e
   (`docs/modules/live-classes.md`) added defining, reshaping and removing
   classes, categories and comments in the image, and the Tonel writer and
   reader in Smalltalk: `ObjectModel/LiveClasses.swift` (primitives 145 to
   149) and `Loader/ClassRules.swift` (the class rules the build and the
   primitives share); `kajo run --sources <dir>` and `kajo test --sources
   <dir>` open the file primitives on one directory.
   Module 9a added the view wrappers (View, Window, Label, Button, TextView,
   Slider, UIEvent, UIEventLoop; ADR 0010); module 9c the second round
   (TextView's selection, styles, keys and change events, OutlineView,
   TableView, SplitView, ScrollView, Toolbar, Menu, the window frame).
 * `apps/` the shells (module 9a, built): `KajoShell-macOS` (AppKit) and
   `KajoShell-iOS` (UIKit), Xcode projects generated by xcodegen from their
   committed specs (both committed; `xcodegen` is a Homebrew install), over
   the root package; since module 11a their hosts are `KajoApp`'s and each
   keeps under 70 lines of Swift; `apps/Shared/smalltalk` the scenario
   loads and the demo, bundled as images by a build phase that uses the
   PATH toolchain.
 * `experiments/` throwaway spikes with a design brief and results each.
 * `docs/PROCESS.md` the working process: briefs, build agents, hand-back
   verification, recording, the machine's rules.
 * `docs/PLAN.md` the module order for building the production core from
   the experiments; `docs/modules/` one brief, later description, per module.
 * `models/` a separate SwiftPM package holding the exhaustive interleaving
   models of the concurrent protocols (`cd models && swift test`;
   `docs/models/` one brief, later description, per model). The relocation
   model precedes module 6, the young-collection model module 7 and the
   save-hold model module 8c; each is updated in the same commit as any
   change to its protocol.
 * `docs/CONTEXT.md` domain vocabulary. `docs/adr/` one decision per file.
   `docs/VERIFICATION.md` how the experiments become the production core
   and what verification that core needs beyond tests and ThreadSanitizer.
 * `references/` contains prior art and other references we might benefit from
   in the design. Gitignored; see `references/MANIFEST.md`.
 * `justfile` has the common commands: `just build`, `just test`, `just run`,
   `just bench`, `just perf` (the runtime comparison and the report), `just
   perf-report`, `just ios-check`, `just build-image`, `just kernel-test`,
   `just fuzz <target> <seconds>`, `just apps`, `just new-check`, `just
   mac-shell`, `just device`, `just shell-matrix`, `just check [base]`,
   `just weekly`, `just weekly-install`, `just weekly-status`, `just
   release-build`, `just dist <version>`, `just release <tag>`; `kajo new <Name>
   --bundle-id <id> --kajo <path>`; `kajo run --protocol <socket> --project
   <dir>`, `kajo mcp --target <socket>`, `kajo eval|compile|browse|debug`.
