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
   token never enters the image, the image sees five transport operations
   (targets, connect, send, close, timer), every received line is checked
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

## Verification

Since 2026-11-07 (the owner's decision when the VM core was declared done;
the interpreter-speed module, its last, landed the same evening) the gates
are tiered by what a diff touches: Smalltalk only (`kernel/`, `tools/`, `apps/Shared/smalltalk`)
runs the image build, the kernel tests, the compiler tests, `just golden`
and the Mac shell's tests mode; Swift outside the core runs a clean build,
`swift test`, ThreadSanitizer once alone, the kernel tests, `just apps`,
`just new-check` and the one relevant fuzzer for 120 s; a change under the
core directories (`Sources/KajoVM/{ObjectMemory,Interpreter,Loader,Workers,
Processes,Nursery,Marking,Relocation,YoungCollection,ObjectModel}`) runs
all 18 gates, the aligned A/B, `just arc-check` and the device rows.
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
full set with the device matrix runs weekly on the mini (Sunday 02:00,
the LaunchAgent `dev.katajamaki.kajo.weekly` running `scripts/weekly.sh`,
loaded by the main session on 2026-11-08, writing `~/kajo-weekly/<date>/`
with a `summary.md` that tabulates every matrix's raw rows, `just
weekly-status`; it refuses, exit 0 and one line in
`~/kajo-weekly/weekly.log`, when a `kajo`, `swift-build`, `swift-test`,
`xcodebuild`, `KajoShell`, `Sample` or `yes` process of the user runs
outside its own process group, so no agent starts a gate or a device run
on a Sunday morning without reading that log first, and nothing of Kajo
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
is 1.07 to 1.10 from the read-only check; the owner's answers to 8a's
questions are in the Built note: inline `class`/`isNil`/`notNil` stay,
the read-only failure is `modificationForbiddenAt:value:`, the symbol
table is weak (8b), and images hold Processes (module 8c); the Smalltalk
side built in module 8b: a kernel of 123 classes and 1368 methods written
from scratch in Tonel, a bootstrap compiler in Swift sharing kasm's
encoder and verifier, a compiler in Smalltalk that agrees with the
bootstrap on every method of the image, the weak symbol table, the image
build at 2.5 MB, SUnit with the v1 NDJSON event stream and JUnit XML, and
the Smalltalk kernels at 0.88 to 1.03 of their kasm twins; 8b left class
variables, a method-install primitive, saved Processes (8c), Unicode
tables and the main-thread check undone, and its five open questions in
`docs/modules/kernel-image.md` await the owner; Processes saved in the
image built in module 8c: the stack words copied verbatim into Array
chunks under special object 8 with the ready queues, the finalization
Semaphore and the saver, image format version 2 (3 since 8d, 4 since 9b for class-table holes, 5 since module 10 for runs of blocks; 1 to 4 are
refused naming module 10, images are rebuilt from sources), `Smalltalk snapshot:`
answering false in the saver and true on resume, a hold on the scheduler
before the stop with its own model, a loader that checks every saved frame
against its method and the bytecode verifier's depth at its pc, `kajo run`
resuming such an image until it is quiescent, the random programs saved
mid-run agreeing with their model, the kernels within noise, a save's stop
at 0.45 to 0.56 ms; 8c's six open questions in
`docs/modules/image-processes.md`; the owner answered 8b's and 8c's
questions on 2026-11-04: per-iteration temp vectors as Pharo, class
variables, installing from Smalltalk behind a release flag, the rest as
built; built in module 8d, `docs/modules/kernel-live.md`: an inlined loop
body owns the temp vector of its captured and assigned temps and makes a
new one per pass, in both compilers, 10.8 ns per such iteration; class
variables as Binding objects in a read-only pool the metaclass holds, no
new bytecode; the make primitive 143 over the image build's own
`MethodBuilding`, primitive 85 running a made method once, 97 and 98
refusing sealed classes and release images, the release flag in the image
header set by `kajo build-image --release` or `kajo seal` and never
cleared, `Behavior>>compile:` keeping sources and the pragma index,
`Compiler evaluate:`; 1500 seeded mutations through the make primitive and
a make-and-run fuzz mode; two 8b bugs fixed: the sources table could not
pass one block and a build step dying in an unhandled error went on, and
a message chain of thousands overflowed the parser's stack; its four open
questions answered by the owner on 2026-11-04); the native shells
built in module 9a (`docs/modules/shells.md`: the public host surface
`Sources/KajoVM/Shell/` over which no oop crosses, the event queue on
module 3's external-signal queue, the first view wrappers behind one hop
primitive as ADR 0010 (proposed), the AppKit and UIKit shells under
`apps/` over the shared `KajoShellCore`, the scenario matrix on the Mac
mini's 120 Hz display: 0 of 1200 frames missed in every scenario but the
ring under the stop-the-world oracle, event latency p99 2 to 3 ms, a hog
on main preempted 2414 times per 10 s with 0 frames missed; the iPhone 13
Pro ran the same matrix on 2026-11-04 once Xcode was signed in: 179 kernel
tests pass on the phone, 0 of 1200 frames missed in every scenario but the
ring under the oracle (2), young collection stops the main thread 2 to 16
times less than stop-the-world in every scenario including share, the
marker kept up on efficiency cores, event latency p99 3 ms, the hog
preempted 2411 times with 0 frames missed, most rows at thermal serious;
on that evidence the owner accepted ADRs 0004 to 0008 and 0010; the
development protocol, the debugger and the agent interface built in module
9b, `docs/modules/development-protocol.md`, from the owner's answers of
2026-11-04 (Swift for the compiler and the bindings, every developer tool
in Smalltalk; stepping and define-and-proceed in the first version):
JSON-lines requests as `<devProtocol>` methods of `DevSession`, 28 of
them, listed by `protocol.describe`, served by one protocol Process that
runs each request in a Process of its own, over a Unix socket with a
pairing token (`kajo run --protocol`, the Mac shell's `protocol=`), never
in a release image (ADR 0011, proposed); an unhandled error stops its
Process while the protocol serves, with no timeout, and the stopped
Process runs the debugger's commands itself: frames with named variables
and source ranges from a pc-to-source map both compilers record as the
last literal (image +1.8%), evaluate in a frame, proceed, restart, retry a
send, terminate, suspend, and stepping into, over and out decided in
`pollSlow` for the stepped Process only, so `interpret` is unchanged
instruction for instruction (ADR 0012, proposed; a step to its stop 1.6
ms, compile 0.85 ms, evaluate 0.21 ms at p50); methods carry a package,
extension files are `<Class>.extension.st`, the author is Tonel metadata,
the client writes accepted changes to `--project` and the files rebuild
the edited image; `kajo mcp` builds its tools from `protocol.describe`,
the CLI gains `eval`, `compile`, `browse`, `debug`, `test --target` and
`request`; `terminate` runs ensure blocks within about 1 s; removed
classes are freed into class-table holes by `Smalltalk garbageCollect`
(image version 4); the Mac shell kept 1200 of 1200 frames while its event
loop's Process sat stopped for 10 s; a libFuzzer target for requests;
its five open questions answered by the owner on 2026-11-06 (a
development image stops an unhandled error's Process with or without a
client, the author mark becomes a pragma, both to be built in a
follow-up; sealed extensions that only send stay; terminate's bound stays
with a cut-off never silent; an agent has the developer's rights for
now); the developer UI built in
module 9c, `docs/modules/developer-ui.md`, as a Smalltalk package `tools/`
(27 classes: `DevClient`, a model and a window each for the browser,
workspace, inspector, debugger, test runner, transcript and target picker,
tested against a fake client) compiled into a development image by `kajo
build-image --with tools` (`just dev-image`, `just tools`; ADR 0013,
proposed), speaking the protocol even to its own image through primitive
164 and `KajoDev.ClientHost` (the host owns the sockets and the token,
replies and the connection's end arrive as events on 9a's queue, timeouts
as timer events); while the protocol serves, an error in a tool hands the
event loop to a new Process and the stopped one opens a debugger
(define-and-proceed tested end to end); the second round of wrappers
(text view with selection, styles, bound keys and change events; outline,
table, split, scroll, toolbar, menus, window frame) on AppKit, the text
view's new features only on iOS; the tools push items to the views, the
on-demand form is built and measured (ADR 0010's Built (9c) note); a view
call past the turn's deadline makes the next poll check the budget
(longest turn 40 to 13 ms); no object passed one heap block then, so
`LargeArray`, a merge sort and pieced JSON lines went into the kernel and
an oversize request was refused with a reply (module 10 removed
`LargeArray` and lifted the request limit to 16 MiB; the merge sort and
the pieces stay); on the Mac mini's display at
120 Hz a scripted session over 2009 classes and 22 284 methods ran in 3.7
to 3.9 s missing 26 to 32 frames of about 450, mostly AppKit opening the
first windows, typing under load p50 2.3 ms and p99 2.9 ms, idle p50 5.5
ms with unexplained frame misses, `class.hierarchy` 0.33 s and
`package.selectors` 0.7 s round trips, bench A/B within noise and
`interpret` unchanged; the kernel has 200 SUnit tests and `tools/` 25;
its five open questions answered by the owner on 2026-11-05 (a
large-object space in the VM as a module of its own, push by default and
on demand for long lists, a tool's error stops for the debugger, apps
against a second target image, no token in the image); the phone
transport built in module 9d, `docs/modules/phone-transport.md`:
`ProtocolServer` listens on TCP beside the Unix socket with one accept
loop and the same reader and token rule, `TCP_NODELAY` and keepalive,
three wrong tokens close a connection and ten failures in a minute pause
the listener, a Bonjour advertisement `_kajo-dev._tcp` through dns_sd
whose TXT record names the image and the versions and never the token,
the iOS shell's `protocol=tcp` with a pairing screen (token per install
in Application Support at 0600, a New token button that ends every
session), `TargetAddress` reading `/path`, `tcp://host:port` and
`bonjour:<name>` for `ClientHost`, the Swift client, the CLI, MCP and the
targets file, phones found by `NWBrowser` listed by `targets` with a
`targets.changed` event, `DevClient` reconnecting with 1, 2, 4 s backoff
up to a minute and sending again every request but `evaluate`,
`process.evaluate`, `process.step` and `test.run`, debuggers refreshing
from `process.list`, 9c's scripted session against another target
(`mode=devsession target=`, `mode=serve`, `scripts/remote-session.sh`)
with define-and-retry and a dropped link as steps; measured Mac to Mac
because the iPhone build waited on a keychain prompt the agent could not
answer: TCP adds about 0.07 ms a request over the Unix socket, round
trips through the tools match the local ones, the first Bonjour connect
costs 0.3 to 0.4 s of resolution, define-and-retry across the link 0.2
s, a dropped link is whole again in 1.05 to 1.09 s of which 1.006 s is
the backoff, the serving shell missed 0 of 2400 frames idle and ring with
and without a client, bench within noise and `interpret` identical; 9b's
client closed a descriptor twice from `deinit` (fixed); the phone's rows
ran in part on 2026-11-06 (signing cleared by the owner): the iPhone signs, serves over TCP and missed 0 of 2400 frames serving idle and ring with no client (ring stopped for others 48 ms per 10 s, 4.1 W, thermal nominal), but no client row ran on either device because the Mac session's processes get "No route to host" to every LAN host but the router (macOS Local Network privacy for the terminal's process tree, the owner's to allow; the Mac-to-Mac run never left the Mac's own address so never met it) and the phone's `_kajo-dev._tcp` never appeared in `dns-sd -B` (iOS's local-network permission for the shell, the owner's to grant); the iPad (device family 1,2 since c2de63f) did not build because Xcode has no account for team BDN6M642M2 and the team profile does not include it; two script bugs fixed on the way (`device.sh token` copied onto a directory, so the token never arrived; `remote-session.sh` took the phone's first address, the USB link's 169.254 one, instead of its address on the Mac's network); the kernel tests on the iPhone and the Mac shell's tests mode failed 4 and 3 of 202 in `ViewWrapperTest`, which assumed the headless host (fixed in 815b512 the same night: `View class>>supports:`, 202 of 202 on all three hosts); the rest ran on 2026-11-06 once the owner allowed Local Network on the mini and signed the mini's Xcode in (5a180c2, `docs/modules/phone-transport.md` "On the devices" and `docs/modules/shells.md`): the iPad Pro 12.9-inch 3rd generation (A12X, iPadOS 26.7.2) passes 202 of 202 kernel tests in 7.1 s and misses 0 of 1200 frames in every scenario at 5 workers, the main thread stopped for others 475 / 54 / 53 ms per 10 s under the storm and 1244 / 101 / 93 under the ring (stop-the-world / local / offload; the iPhone 464 / 43 / 48 and 1252 / 76 / 81), share even at 71 / 70 / 64 where the iPhone's halves, at 7 workers the ring under the oracle misses 7 to 30 frames from oversubscribing its 8 cores, one worker 1.24 to 1.62 times the A15's time and six within 2 to 12 percent; module 10's large churn misses no frame on either device (main stopped 117 ms per 10 s on the iPhone, 160 on the iPad, against the Mac's 59 to 67) but counts module 5 fallbacks in 3 of 6 runs where the Mac counts none; module 9d's client rows over Wi-Fi: 51 sessions against the iPhone (by address and by Bonjour name) and 23 against the iPad (by address), none failed, 0 frames missed in all 30 serving launches with or without a client, `class.definition` 3.9 to 9.9 ms against 0.8 Mac to Mac, `class.hierarchy` 40 to 65 ms against 29, `package.selectors` 77 to 103 against 78, define-and-retry 235 to 315 ms against 211, a dropped link whole again in 1.18 to 1.21 s, so the class tree keeps the push form (the 2000-class image was not served from a device; that is an extrapolation); the iPad's `_kajo-dev._tcp` was not seen from the Mac until the owner granted its local-network permission later that day, after which its rows by name ran beside rows by address (45 sessions, 22 by name, none failed, 0 frames missed in 12 serving launches, name and address within each other's ranges), and `remote-session.sh`'s lan form no longer waits for a Bonjour name (7bdb024); unexplained on the iPad: event latency p50 2.2 ms under the storm (22 times the iPhone's), request maxima of 0.2 to 0.7 s over Wi-Fi, and energy readings too low to compare with the iPhone's; the devices investigation of the same evening (`docs/modules/shells.md` "Where the 2.2 ms went" and "The iPad's energy reading checked", `docs/modules/phone-transport.md` "The devices investigation") explained or bounded all three: the latency is the main thread's busy fraction (an event due inside a turn waits about half of it; cooled, the iPad's p50 is 0.118 ms against the iPhone's 0.097, and after sustained load its performance cluster runs at 1.3 to 1.7 GHz instead of 2.3 while the state reads only fair, the frame work no longer fits its turn, the main thread is busy more than half the time and the median event is one that waited), the request maxima are the link (every request served inside the device in at most 7.4 ms while the client saw up to 245; both devices doze between bursts and the first request after a gap costs about one beacon interval, 95 to 115 ms), and the A12X's energy counters are not usable for performance cores (17 pJ per cycle against 40 on its own efficiency cores and 323 on the A15), with no sign of a capped clock (one thread at the rated 2.47 GHz in every launch, the slower kernels being clock times IPC; not run on battery); the 2000-class image served from both devices (36.9 MB, 24 sessions each, none failed, 0 frames missed) puts `class.hierarchy` at 360 to 404 ms and `package.selectors` at 513 to 551 against the Mac's 335 and 457 with the tree step the same pushed or on demand, so push holds on evidence; the same raw rows show the storm missing frames on the devices in 14 of 49 launches, every one a module 5 fallback while sweeping with a stop-the-world full collection of 41 to 84 ms (3 of 16 at 5 workers cooled, 11 of 21 at 7 workers), to be removed in the large-bytes follow-up; its six open questions answered by the owner on 2026-11-05 (plain TCP now and PSK-TLS as a later module, no token expiry, any number of sessions on the phone, serving only by launch argument, signing is the owner's, doits fail at a dropped link rather than being resent); the owner's distribution shape (2026-11-05): Kajo ships as one Mac app (`Kajo.dmg`, outside the App Store) carrying the development image, in which the developer customizes the tools and creates new apps; a new app is a generated project (an xcodegen spec with a Mac and an iOS target sharing one Tonel directory, a pinned dependency on the Kajo package, the Debug configuration bundling the development image with the protocol compiled in, the Release configuration the release image without it), so the phone runs the developer's own development build installed with Xcode and no Kajo app is ever reviewed under guideline 2.5.2; serving on the phone therefore becomes a property of the development build, not a launch argument, with the pairing screen reached from the running app; a separate iOS/iPadOS Kajo app, a teaching tool and playground with the tools on the device, is a later idea, not planned; module 10 (large objects, built 2026-11-06, `docs/modules/large-objects.md`, ADR 0003's and 0007's Built (10) notes): an object past one 32 KiB block (4095 slots) is a run of contiguous blocks, one head and continuations in a one-byte-per-block kind table, allocated old, never young, never relocated or compacted, its largeness read from the header's count (no header bit), the limit the 24-bit count field (16 777 215 slots, 128 MiB, or 16 MiB - 1 bytes); every reader of a body walks runs (verifiers, both sweeps, the block pool, compaction, the relocator and its verifier, snapshot writer and loader, reshape, become); the marker scans a large object 4096 slots at a time and polls by work done; a large allocation decides module 5's trigger and starts the cycle from the allocating worker's young collection with the object a pending root (the first version rooted it only in its own stop and the random programs crashed); a full collection forced by an old allocation counts as module 5's fallback; image version 5 (snapshot 4), versions 1 to 4 refused naming module 10, fuzz seeds upgraded plus `large-objects.img`; the kernel back to plain Arrays (`LargeArray` and `Array class>>large:` gone, `basicNew:` names the limit), the transport's request limit 16 MiB - 1 with replies still in pieces; vm-teardown's two items built (old space grows for the VM's final collection out of address space reserved with the heap, `Image.saveImage` throws `processesHaveFrames` naming `Smalltalk snapshot:`); the random programs gained a large-object step and the shells `scenario=large`; measured on the mini: 1 MiB allocate p50 0.044 ms and 16 MiB 0.62 ms, freeing them 0.020 ms, `at:`/`at:put:` on a million elements 1016 ms against `LargeArray`'s 4567, marking a 1M-slot Array 0.8 ms in 244 chunks with 0.013 ms between polls, the large churn scenario 0 of 1200 frames missed with 811 to 819 cycles per 10 s all started by large allocations, the 2000-class image 481 ms against 518, `package.selectors` 443 ms against 657 and 19 866 rows pushed in 36 ms against 108, bench within noise and `interpret` identical, worst-case fragmentation 1.64 times live data (683 free blocks with no three adjacent), 46 new `unsafe` sites in the object memory and marker; four test bounds of earlier modules widened under the sanitizer only or repeated a round (9d's listener pause and 9b's evaluate under ThreadSanitizer with load, the relocation fragment kernel's two selecting cycles, the exhausted-reserve heaps two blocks larger); not done: no card table for large objects (a remembered one is scanned whole by a scavenge), filling a large object does not poll (about 5 ms at 128 MiB), runs never move so fragmentation between them persists, LargeIntegers stay one block, nothing ran on the iPhone; the owner answered its four questions on 2026-11-06: 16 MiB is too little for bytes if images or photos sit in a ByteArray (the limit is to be lifted in a follow-up), runs are never relocated, no card marking yet, and the pieces stay until the follow-up has measured them against one String; after the device run the owner also asked for the large-churn fallbacks to be tuned away on devices (such churn is plausible in a photo or video app), for an investigation of the iPad's three unexplained readings, and for the 2000-class image to be served from a device; the large-bytes follow-up built the three on 2026-11-06 (`docs/modules/large-bytes.md`, ADR 0003's and 0006's Built (large bytes) notes, `experiments/large-bytes/`): a byte object may be 2 GiB - 1 bytes long (`Header.maxByteLength`); from 2^24 - 8 bytes the header's count field is a sentinel holding the length's low three bits and the length is the back reference's words, so the bounds check `i < count` stays the fast path and only its failure and `size` read the true length, no header bit spent, pointer objects keep 16 777 215 slots (the experiment: a count in words would have added three instructions to every byte bounds check), every reader of a byte count in one table, every byte primitive over a long object polling between 256 KiB chunks (a 1 GiB copy in 58 ms kept stops waiting at most 0.093 ms; without polls a 256 MiB copy kept one waiting 10.1 ms), primitive 38 copying bytes, image version 6 (snapshot 5) with the loader refusing a length that does not fit its run and a sentinel on a short body, the fuzz seeds upgraded plus `long-bytes.img`, broken variants as test switches (`trustCountField`, `trustLongLength`, `noBytePolls`), `scenario=photo`; the devices' fallbacks traced with a fallback record (cause, phase, sweep progress, entries and blocks used, the marker's QoS) and removed at their causes: the storm ran out of entries, not old space, while the utility-QoS marker on efficiency cores still held the swept entries pending their apply, so the QoS policy now watches the entry table and is re-decided at every young collection while a cycle runs, an empty table or an old allocation without room finishes a pending sweep in its own stop instead of a full collection (`sweepsForEntries`, `sweepsForOld`), and an allocation that finds a cycle still marking raises the marker and waits for the final mark up to 100 ms, background workers only (`allocWaits`); a first version deciding the policy at every large allocation raised the marker for every cycle on the iPad and stopped the main thread 60 percent longer, replaced; before: 8 to 10 of 10 storm launches at 7 workers and 8 to 9 of 10 large-churn launches fell back per device; after (c196de8, 10 launches per row per device, `dev/final2`): 0 fallbacks in 80 launches, the iPad missing no frame, the iPhone missing 1 and 2 frames in two storm launches at thermal serious behind final marks of 8 and 20 ms (not fallbacks; 9a's unexamined final-mark maxima), the iPhone's large churn stopped 71 ms per 10 s against 117, the iPad's 166 against 160 (the finished sweeps' stops), the Mac's rows unchanged, the iPhone's CPU energy 4 to 14 percent lower with the marker's own 7 percent to 3.5 times higher; the transport's long lines decided per direction by measurement: a reply the image writes stays in pieces (100 `package.selectors` replies 1.19 s against 1.59 as one String, half the old-space bytes) and a line the image's client receives is one String up to 16 MiB - 1 (`class.hierarchy` 253 to 267 ms against 308 to 336 in the 2000-class session), the switch deleted; the `relocateEveryLiveBlock` random programs let every started cycle finish before the runtime stops (060116e, the investigation's one sanitizer failure; 20 of 20 alone under the sanitizer with 12 busy loops); bench 0.966 to 1.056 with overlapping ranges and `interpret` identical but for four page offsets, 120 new `unsafe` lines; not done: pointer objects past the field, `ByteArray>>=` and `hash` as Smalltalk loops, host conversions refusing a long String, the allocation measurements and part 3 on the devices, the snapshot fuzzer running the 16.8 MB seed truncated to its 1 MiB `max_len`, one iPad large-churn launch of an earlier block missing 2 frames behind a 19.5 ms main turn; its five open questions await the owner; the development answers built on 2026-11-07 (`docs/modules/development-answers.md`, ADR 0011's and 0012's Built (development answers) notes): a development image stops an unhandled error's Process wherever its host says a debugger can come: one host setting (`Headless.Options.stopsForDebugger`, false by default, an atomic in `ShellBridge`, read by the kernel through primitive 165 and always false in a release image), turned on by the development app before the image resumes and by `ShellVM.openProtocol()` so every serving host stops; batch hosts (`kajo run`, `kajo test`, the image build, the fuzz targets) have no bridge and report and end, each with a test that a forked Process's error ends the host within a bound; `UnhandledError>>defaultAction` reads only `Debugger stopsErrors`; standing stops are capped at 32 (`Debugger stopCap`; past it the error is reported, the Process ended, `refusedStops` counted and a Transcript line written), listed to a later client in `session.open`'s answer from the summary the Process made when it parked (the tools open a debugger for each on connect; an error with no client, a client connecting later, defining the method and retrying to 42 is tested end to end), survive a snapshot and are listed by the resumed image, and an error in the app's start-up stops while serving still starts; the event loop hands over whenever `Debugger canStop`; `Transcript showLine:` because concurrent `show:` then `cr` merged lines; the author mark is the pragma `<author: #'agent:<name>'>` on its own line after the pattern, comment and leading pragmas (an agent's compile leaves exactly its own author pragma, a developer's compile is the source as written; `Smalltalk authorOfSelector:in:` reads it, the authors table is gone, `Pragma allNamed: #author:` answers the agent's methods, the writer writes only the category and both readers ignore unknown keys as Pharo's Tonel does, the one fixture that carried the key rewritten in its own commit f7a760c); `Process>>terminate` answers whether the unwinding ran to its end, a new kernel class `Unwinding` notes each unwind block and counts cut-offs, each cut-off writes a Transcript line naming the Process and the block, `process.terminate` answers `{process, unwound, cutOff}`, the debugger's terminate uses the same bound and restart and retry answer after their unwinding and say where it stands past 1 s; measured 2026-11-07 at thermal nominal: a standing stop holds 16 to 18 KB once warm and a full cap 528 to 576 KB, the Mac mini and the iPhone 13 Pro missed 0 of 1266 frames in the 10 s window with the event loop stopped and no client (1 stop and a full cap of 32) and 0 after a client connected and proceeded, the one frame some runs missed falling where serving starts, `session.open` with the stops 10 to 17 ms on the Mac and 23 to 30 on the phone; the VM change is the setting alone (5 files, 56 lines, no `unsafe`), `interpret` identical but for four page offsets, the A/B 0.991 to 1.014 at 1 worker and 0.940 to 1.080 at 8 with `sends` on 8 at parity when re-run 10 times; 9d's listener-pause test waits 120 s for its report everywhere (its 10 s ran out behind twelve busy loops without the sanitizer); the gates on f6024a3 read 369 + 112 Swift tests and 205 kernel tests, the four fuzz targets run at the same time for 601 s each with "libFuzzer build: ok" and 0.92 to 2.99 million runs; not done: the iPad rows, UI for a standing stop with no client, aging out stopped Processes; its five open questions answered by the owner on 2026-11-07, all as recommended (the 2 GiB - 1 limit, the per-direction transport, the devices' extra stops accepted); the final mark on the devices, built 2026-11-07 (`docs/modules/final-mark.md`, ADR 0006's and 0008's Built (final mark) notes): the brief's premise was wrong, the final mark's stop was 0.16 to 0.54 ms on both devices in every mode all along and the 7 to 20 ms were the stopper's wait for open young collections before its request, with the world running, which module 3's StopRecord counted as time to safepoint; the frames the devices missed in 7 of 162 young-mode launches before the change were the initial mark's young-root scan inside its stop (3.4 to 8.4 ms, every nursery walked), a main-thread flip that waited 14 ms while a stop was wanted, and local mode's own collections; so stops are timed from their request with the wait before it a field of its own and every final mark a record (phases, last parker and how it came, the stopper's QoS, core and clock, thermal state; `finalLog`, `stopsByKind` on the run line), the main worker may open one collection while a stop is wanted (the young-collection model updated in the same commit, `mainOpensWhileWanted`), the young-root scan left the initial mark's stop (the stop records each nursery's ranges and marks the scan owed; the marker, the nursery's collector before anything of it moves, or module 4's scavenge claims and walks it; until a nursery is scanned the SATB barrier records stores into its young holders, in `satbRecord` and `copySlots`; no model covers it, the doc has the argument and the tests break each rule), the final mark's tracing is bounded in work (16 384 units; past the bound or with a scan owed it gives up before anything is decided and the marker drains concurrently and asks again; after 8 give-ups it finishes past the bound, counted), and a real bug found on the way: the remembered filter ran before the ephemerons, so a holder marked only by a fired ephemeron's value was dropped from the remembered set and its young referent lost (a test fails on 4a94f07 with verifier failures; the filter runs after the ephemerons); measured on both devices interleaved, 162 launches before, 222 after and 110 on the final code: the final mark at most 0.54 ms with no give-up in 332 launches, the initial mark at most 1.05 ms (from 3.4 to 8.4), every stop kind under 1.1 ms in every launch, 0 frames missed in 120 storm launches under young offload but two single frames on the iPhone at 7 workers that were no stop (a 6.4 ms wait for the safepoint mutex, a 6.9 ms CPU turn; the default stays 5 workers, where 0 of 30 launches per device missed), the iPad missing none, young local still missing frames on the iPhone at 7 workers behind the main worker's own collections (6 to 21 ms), the main thread's stopped time no worse (offload p50 iPhone 40.0 and 37.0 ms per 10 s against 38.4 and 47.5, iPad 49.1 and 64.8 against 53.6 and 70.7), 0 fallbacks, the Mac 0 frames missed with young collection on and its final mark p50 0.15 to 0.17 ms, no QoS changed (the marker does 11 percent less to 30 percent more CPU with the root scans moved onto it), the aligned A/B against 4a94f07 0.988 to 1.005 at 1 worker and 0.960 to 1.047 at 8 with overlapping ranges, `interpret` identical but for four page numbers and `storeWithBarriers` and `copySlots` gaining the owed-scan check on the young-holder SATB branch only; the gates on bcee36d read 381 + 112 Swift tests, 205 kernel tests and the four fuzz targets one after another at 0.94 to 3.21 million runs; not done: local mode's main-worker collections, main-thread parks of 8.3 to 10.5 ms with every stop under 0.7 ms on the iPhone at serious (no frame cost, not explained), the ephemerons' firing unbounded past the commit point, the wait before a request for background workers, parallel root scans; its four open questions await the owner (the bound's value, eight give-ups then an overrun, whether `young=local` should still offload the main worker, one collection per wanted stop); with it the owner declared the VM core done on 2026-11-07 but for the interpreter-speed module (the send path, superinstructions, the special sends), after which gates are tiered by what a diff touches and the full set with the device matrix runs weekly on the mini (see Verification); the stop-the-world scavenge trapped when its promotion
reserve ran out, the ring at 600 MiB, fixed in the reserve-and-depth
follow-up, `docs/modules/reserve-and-depth.md`: the cause was the fallback,
not the reserve's size, a mark-sweep that could not bring old space under
its soft limit, so a full collection now compacts when the sweep leaves
old space past the limit, a stop-the-world scavenge keeps in place what
finds no block and requests the full collection, a module 7 young
collection opens only with its promotion room promised under the pools
lock and otherwise stops the world for module 4's scavenge, become,
reshape and the save refuse with a heap full of live data, two
random-program configurations run with no reserve; the ring at 600 MiB
under the oracle now finishes every run, missing 143 of 1200 frames to
compacting full collections of 250 ms where the concurrent modes miss
none; the same follow-up walks message chains by loops in the bootstrap
compiler, lowers the nesting limit to 32 in both compilers after
measuring 4 to 9.5 KB of debug stack per level, and runs the syntax
fuzzer on a 512 KB thread; its two open questions answered by the owner
on 2026-11-04 (the oracle's misses are acceptable, the limit stays 32); live
classes built in module 8e, `docs/modules/live-classes.md`: primitives 145
to 147 define, redefine and remove a class in the install stop, re-checking
the build's rules through the shared `ClassRules`, a redefinition making
every method again against the new shape and reshaping every instance of
the class and its subclasses by name before anything changes (10 000
instances and 50 methods in 10.8 ms, the longest install stop 1.04 ms),
old methods forwarded to the recompiled ones or to an error stub, a
removed class kept as `AnObsoleteFoo`, the running-frame rule refusing a
change while any Process runs a method of the class, removed class
variables left as undeclared Bindings; categories, comments and class
definitions kept in the image; the Tonel writer and reader in Smalltalk
over file primitives 148 and 149 bounded to the directory `--sources`
opens, `kernel/` rewritten in the canonical form the image writes and a
byte-identical round-trip test; 1500 class-spec and 500 reshape-spec
mutations; its five open questions answered by the owner on 2026-11-04 or
closed by later modules; the vm-teardown
follow-up, `docs/modules/vm-teardown.md`: `VM.destroy` runs one final
promote-all stop and hands every stash's entries back, so the image the
host holds afterwards is whole, `Image.saveImage` works and another VM can
run over the same image (5 to 15 µs for an empty nursery, 1.0 to 1.2 ms for
a full one, in release); the file primitives resolve the last path
component too, read with `O_NOFOLLOW` and create the write's temporary
file exclusively; its two open questions answered by the owner on
2026-11-04 and built in module 10; the
collectors review, `docs/modules/collectors-review.md` (2026-11-06): the
first external review of modules 1 and 4 to 7 (pull request 1, 54 files)
found nine things and all nine are fixed, each with a test that fails on
the starting commit: every primitive that reads a slot a program could
make weak keeps its referent alive while a cycle marks (the array copy,
`instVarAt:`, `slotAt:`, `shallowCopy` and, found beside them, the symbol
table's bucket growth had no keep-alive barrier; the array copy records a
weak source's referents in a pass before the copy, so every other copy
runs the old loop: 1.011 with a cycle marking, where a check per slot cost
1.068); no primitive traps on an extreme SmallInteger (the array copy and
`basicNew:` did arithmetic before their bounds checks, two Mac shell view
wrappers took any count), with a seeded test of 840 calls and an extreme
argument in the make-and-run fuzz mode; the collectors' logs are rings of
`VMConfig.logCapacity` records (65 536, 4096 in the shells' demo and
developer modes) with running totals and a dropped count; marking sets and
clears only bit 0 of the shared barrier word (it stored the whole word and
erased module 7's count, so the young stress flag stopped stressing after
the first cycle; no deletion record was ever lost, because stops wait for
open young collections), with a stop verifier on the word and a
`youngBarrierAlwaysOn` random-program configuration; a reshape runs
module 4's hook before it lists instances; the object memory releases
every reservation when a later one fails and an Image whose boot fails
destroys its memory; one `bodyBytes`, one pair of cache-line helpers, one
`copyBody`; bench within noise and `interpret` identical; the owner kept
the stop-verifier assertion in every random-program configuration and the
fuzzer's second run (2026-11-06), and the apps keep 4096 records per log
until a tool reads them); module 11a (the app project, built 2026-11-06,
`docs/modules/app-project.md`, ADR 0014 proposed): the AppKit and UIKit
hosts and the runtime are the `KajoApp` library and serving, the token
store and the pairing screens the `KajoAppDevelopment` library, the
shells in `apps/` rebuilt on them (54 and 64 lines of Swift of their
own); `kajo new` (the `KajoGenerator` library, deterministic, every
refusal a value, its output a byte-for-byte fixture) writes an xcodegen
project with a Mac and an iOS target over one `src/` of Tonel, one
17-line `App.swift`, a build phase making a development image in Debug
and a sealed one in Release, and a local `KajoPin` package that pins Kajo
and enables the `KajoAppBuild` trait; a Debug build serves over TCP and
Bonjour from launch as "<app> on <device>" with 9d's per-install token,
the pairing screen a shake on iOS and the app menu's Pairing… on the Mac;
a Release binary has 0 symbols of KajoDev, KajoAppDevelopment,
KajoCompiler and KajoShellCore, no Bonjour import and no local-network
key (2.1 MB on the Mac, 2.0 on iOS), checked by `just new-check` on every
run; because Xcode links a package product in every configuration the
development half is a dependency with `link: false` and Debug's linker
flags name its three prelinked objects; on the Mac the round trip ran
whole (generate, build, connect by Bonjour name, change a method live in
68 to 70 ms from the CLI and 5 to 8 ms from the tools, the change in
`src/`, rebuilt and there at launch, the Release app not serving), 0 of
3780 frames missed across 8 sessions and 2 changes, cold launch 213 to
255 ms Debug and 190 to 235 Release, the Debug VM 2.6 to 4.0 times slower
than Release, bench within noise and `interpret` identical; a latent 9a
trap fixed (a follow-up turn outliving its host); the refactored shells
pass 202 of 202 and miss 0 of 1200 frames in every scenario on both
devices; the sample app's device rows did not run: `xcodebuild` answers
"No Accounts" for the new bundle identifier `dev.katajamaki.kajo.sample`
(the account the owner signed in that morning is no longer seen; the main
session's own attempt got the same answer; the owner signed Xcode in again and built the sample from Xcode's window on 2026-11-07, after which its profile exists), and its six open questions answered by the owner on 2026-11-07: the Release VM ships as a prebuilt xcframework in the dmg so development builds run it, generated projects pin a checkout the dmg carries (copied to `~/Library/Application Support/Kajo/<version>/`; the public repository with tags later), the paid Developer Program is renewed so Developer ID signing and notarization are available, pairing via shake and ⇧⌘P, object-name linking and the Mac sandbox off stay as built; the sample's device rows ran on 2026-11-07, `docs/modules/app-project.md`: the CLI changes a method live on the phone in 140 ms and on the iPad in 174 ms, the Release app does not serve, and three things were found for a follow-up: the generated iOS plist lacks `CADisableMinimumFrameDurationOnPhone` so the sample runs at 60 Hz on the iPhone, the Debug build takes 35 s to its first frame on both devices where Release takes 0.1 to 0.2 s, and `app-roundtrip.sh`'s by-address fallback keeps the first launch's port; all three fixed the same day, `docs/modules/app-project.md` "The sample on the devices": the key is in both generated iOS plists and the fixture, the 35 s was `ProcessInfo.hostName` on the main thread answering "localhost" after 35.0 s in every traced launch, found by a launch trace (`kajo-launch-report` prints `launch step=<name> ms=` per step) and not by the suspects the brief named, so the device's part of the service name is the model's on iOS and the development half starts at the app's second frame or after 1 s without frames (`AfterFrames`, `KajoAppRunner.startDevelopment`, told once), the script re-reads the address and port from the console of the launch it talks to and a rebuilt app that does not answer is a `FAILED` line; after: the iPhone's Debug first frame 103 to 157 ms and the iPad's 230 to 254 against 35.2 to 35.6 s, 120 Hz on the iPhone with 0 of 1264, 3647 and 1012 frames missed, `starts_with_change=1` on both devices by address, the Mac unchanged; the owner allowed Local Network for the sample on both devices the same evening and the round trip then ran by name on each (`Sample on iPhone`, `Sample on iPad`, `starts_with_change=1`, 0 frames missed, the first request paying the name's resolution: 143 ms on the iPhone and 899 on the iPad); gates of the Swift-outside-core tier on 6ffdb6d, 381 + 115 tests, ThreadSanitizer 0 reports, 205 kernel tests, the protocol fuzzer 366 718 runs); the runtime comparison and the performance report (2026-11-07, `experiments/runtime-comparison/`, `docs/performance/README.md`, `just perf` and `just perf-report`, `scripts/perf-report.py` with a fixture test): the same five programs (fib, dispatch, binarytrees, collections, arith) with one checksum each in Kajo (kasm and Smalltalk, 1 and 8 workers), Pharo 12's Cog, C, LuaJIT with and without its JIT, Lua 5.4, Node with and without, Java G1, `-Xint` and ZGC, Ruby with and without YJIT and CPython, five interleaved rounds on the mini, 341 runs none refused at thermal nominal; on one thread Kajo is level with Java `-Xint` on fib (47 M calls/s), ahead of Node `--jitless`, Ruby, Lua and CPython on binarytrees (14 M objects/s), behind every interpreter but CPython on dispatch (15 M sends/s) and arith (675 M bytecodes/s), and LuaJIT's interpreter is 2.3 to 2.6 times faster on all but binarytrees; 8 workers scale 6.1 to 7.4 times; the kernel's collections take 4.3 times Pharo's; the report's part 0 says what kind of VM and collector this is and what each choice costs; found on the way: the 8-worker rows' 19 to 30 ms stops are the finished sweeps for an empty entry table (`sweepsForEntries`), a collector follow-up in `docs/PLAN.md`); the interpreter-speed module, the last of the VM core, built 2026-11-07 (`docs/modules/interpreter-speed.md`, ADR 0009's Built (interpreter speed) note): measured first (`kajo run` reports the workers' own cycles and instructions from the per-thread counters; a counting build, `-DKAJO_COUNT_OPCODES`, writes dynamic and static opcode singles, pairs and triples, none of it in the product build): fib cost 71.3 cycles per send and 7.13 per bytecode on the global method cache, `sends` 109.6 and `st-sends` 193.7 per send, `arith` 106.8 per iteration; part 1 (the send path) was measured and discarded step by step: a build that trusts the cache line without comparing put a per-site inline cache's ceiling at 2 percent, removing the poll countdown entirely at 1.1, and a leaner activation (built two ways in four register layouts) won 8 percent on fib alone but spilled `true` and `false` and lost 6 to 8 on `arith` and `ivars`, adding nothing over fusion; part 2 kept: 17 fused instructions (opcodes 50 to 66) chosen from the counts (`push_temp`/`push_self` with `push_temp`/`push_int`, `push_int` with `add`/`sub`, `add`/`sub` with `store_temp`, `store_temp jump`, `dup store_temp`, `pop push_temp`, and `lt`/`gt`/`le`/`ge`/`eq`/`identical` with `jump_if_false`), where a fused opcode replaces only the first instruction's opcode byte so offsets, operands, jump targets, the source map, saved pcs and stepping are those of the plain code and a fast path that does not apply runs the first part alone and dispatches the intact second; the peephole `fuseBytecodes` in `MethodBuilding` fuses every made method (idempotent, never an extended instruction; `noFusion` test switch), the verifier's one new rule is that the second part follows plain and unextended, kasm reads the mnemonics, primitive 166 `plainBytecodes` lets the compiler tests and `CompiledCode>>matches:` compare plain code, the random programs gained a `plainBytecodes` configuration and the kasm fuzzer a seed of every mnemonic; part 3 kept: `at:` on an Array with an in-bounds SmallInteger index, `isNil` and `notNil` inline in the loop (`st-sends` 0.888 against part 2); the aligned A/B against b04acba (5 interleaved runs, 1 and 8 workers, checksums equal): cycles per send fib 0.815 (58.1 per send), `sends` 0.638, `st-sends` 0.605, `arith` 0.717 per iteration, `st-closures` 0.845, `storeheavy` 0.878, `ivars` 0.924, `alloc` 0.983, nothing slower than 1.008 in wall time, dispatches 0.62 to 0.84 of the plain count; `interpret` 1320 to 1816 instructions, still one jump table and one indirect branch, the register map and the seven-instruction dispatch identical; the iPhone 13 Pro at 1 worker fib 0.811, `sends` 0.832, `arith` 0.720, `st-sends` 0.605; the shells' matrices on the iPhone (5 workers) and the Mac (7): 0 fallbacks and 0 frames missed in every row but the ring under the stop-the-world young mode (iPhone 0, 1, 5 at thermal serious behind 13.6 and 17.3 ms scavenges, 9a's 1 to 4; Mac 289 to 316 against the starting commit's 193 to 282 in seven interleaved launches each, every miss a counted soft-limit fallback's compacting full collection of 185 to 200 ms, 26 to 32 of them against 20 to 28, because the faster mutators cross the soft limit with no cycle running more often, an open question) and one Mac idle launch, the matrix's first, missing 595 frames behind a 4.97 s gap with no stop in it that six more launches did not repeat (unexplained); the gates on ae1b0d6 read 385 + 115 Swift tests, 205 kernel tests and the four fuzz targets one after another at 0.90 to 3.33 million runs; 120 new `unsafe` lines; not done: fused sends and triples, inline `size` and `class`, the iPad rows, misprediction counters (root); its three open questions await the owner (image version 6 kept, the oracle ring row, fused sends as a follow-up); with it the VM core is done and the gate tiers of Verification apply; the comparison re-run the same evening (`docs/performance/README.md` section 1a, baseline kept as `experiments/runtime-comparison/bench-raw-before-interpreter.txt`): every other runtime within 1 percent of its baseline, Kajo fib 0.82, dispatch 0.64 and 0.61, arith 0.74 and 0.76, binarytrees 0.97 and collections 0.88 of before, now ahead of Java `-Xint` on fib, level with Lua 5.4 on dispatch and within 3 percent of Ruby on arith, LuaJIT's interpreter 1.5 to 2.1 times faster where it was 2.3 to 2.6); the gate tiers and the weekly run, built 2026-11-07 (`docs/modules/gate-tiers.md`; scripts only, nothing under `Sources/`, `kernel/` or `tools/`): `just check` over `scripts/gates-lib.sh` (one gate as a name, a command, a bound and a check of its output; a fuzz gate fails without the "libFuzzer build: ok" line, a clean build with a warning, the Mac shell's tests mode with a failed row), `scripts/check-tier-test.sh` (36 checks of the decision), `scripts/weekly.sh` with its LaunchAgent plist, `scripts/device-rows.sh` (the device build with a codesign watchdog: 60 s at 0 percent CPU kills it, writes the fact and skips the rows with rc 3), the aligned A/B as `scripts/ab.sh` and `ab-table.py`, `scripts/shell-report.py --bar` (launches failed, checksums, frames missed, fallbacks and the longest stop over every raw row) and `scripts/release.sh <tag>` (the Release CLI and the development image as a tarball with its SHA-256 and the `gh release create` line, not run yet); sample diffs by `--dry-run`: 8c3e80f docs none, ae1b0d6 `kernel/` smalltalk 7 gates, ad0b433 KajoDev swift with the protocol fuzzer, c657344 KajoCompiler swift with the syntax fuzzer, e417519 `Dispatch.swift` core 21 gates, the module's own diff swift with no fuzzer; tier 1 forced on dc80549 passed in 355 s (205 kernel, 235 tools-image and 115 compiler tests, golden, the Mac shell's 205 of 205), tier 2 on 3f2acdd passed in 3641 s (385 + 115 tests, ThreadSanitizer 2820 s with 0 reports, 205 kernel tests, apps, new-check); the quick weekly run on dc80549 under `env -i` with exactly the plist's environment ran all 18 gates in 144 min (ThreadSanitizer alone and under load 0 reports, the four fuzzers with "libFuzzer build: ok" at 0.05 to 0.33 million runs in 60 s) and its Mac matrix, whose `--bar` first read 24 golden rows with `ok=-1` (no published checksum at that worker count) as failures, fixed in 3f2acdd, after which the Mac and iPhone matrices on 3f2acdd pass with the summary agreeing with the raw rows (Mac: the ring under the stop-the-world young mode 332 frames and 30 soft-limit fallbacks with a 187 ms compacting full collection, the hog with the budget off 1192 by design; iPhone at 5 workers: 0 frames missed and 0 fallbacks in every row but the hog, longest stop a 13.44 ms scavenge, built and signed with no prompt in 49 s); the first idle launch of the quick run's Mac matrix missed 428 frames behind a 3.6 s gap with no stop, the second time a matrix's first launch of a freshly built shell has done so (595 in the interpreter module), the same binary's later launches missing none, unexplained; the refusal was tested with a `yes` in another session (refused) and in its own process group (not refused); `weekly.sh` does not wake a sleeping display, the display sleeps after 10 min on the mini, and nothing else of its four open questions is built; the first weekly run, 2026-11-08 02:00 to 05:33 on a024a90: 17 of 18 gates, `tsan-load` failing on the relocation kernel round that completed one selecting cycle in each of three runs, the Mac's rows all with frames, 0 fallbacks on the devices; the failing round fixed the same morning in the tests alone, 9c1dc2a, `docs/modules/relocation.md` "The round under load": the marker was starved, not the kernel short, the third run's second cycle planned at its initial mark but not at its final mark when the Processes ended and the counters were read, its one pass at 0.14 s of CPU in 4.19 s of wall; `underRelocation` now waits for the marking phase to be idle after the Processes terminate, 600 s under the sanitizer and 120 s otherwise with not reaching idle a failure, the assertion, the three runs and the iteration counts unchanged, each round printing where it stood at its kernel's end; the wait took under 1 ms in every loaded sanitizer run and 0.31 and 2.07 s in `just check`'s plain `swift test`, where it turned 3 of 4 and 2 of 3 selected cycles into every one; 10 of 10 filtered loaded sanitizer runs, 3 of 3 plain, `tsan-load` once at 385 + 121 tests and 0 reports, `just check` on 9c1dc2a in 3621 s); the sweep stop, built 2026-11-08 (`docs/modules/sweep-stop.md`, found by the comparison's 8-worker binarytrees: an allocation that found the entry table empty finished the whole lazy sweep in its own stop, 5 to 7 stops of 20 to 27 ms a run counted as `other`): the stop is its own kind `sweep` with a record (cause, phase, outcome, how far the sweep had got, runs pending, time since the sweep could start, the marker's QoS, table and old space, sweeping and apply time, whether it cut a relocation pass off; `sweepStopLog`, `sweepStops*` and `sweepWaits*` on the run line, a sweep-stops column in `shell-report.py` and `--bar`); the records showed the stop's time was sweeping (0.46 to 26.5 ms at about 143 ns a word, the apply 0.11 to 0.13 ms) with 3.2 to 12 million entries already swept and pending in 793 to 3003 runs, so a bounded stop hands every pending run to the allocators (`publishSwept`) and sweeps inside the stop only while fewer than 65 536 swept entries are pending and then at most `sweepStopWords` 4096 words, cutting an unfinished relocation pass off first (`relocationCutOffForSweep`: the relocator moves only snapshot entries, a sweep ahead of it could evacuate a block with a live body); an old allocation the hand-over cannot serve waits outside the stop on a background worker (`waitForSweep`, 100 ms) while the main worker keeps the unbounded stop; every reader of a swept-but-pending entry is listed in the doc with the one-owner argument, the verifier checks that a free entry still in the pending sweep's snapshot has two owners, `sweepStopUnbounded` brings the old stop back and the broken variant `applyAheadOfSweep` fails that check as a test; the young-collection model is unchanged (its sweep frees entries one per step with the world running, more than a partial apply allows); the brief's premise did not hold on the Mac: the sweep visits 250 to 370 million entries a second against 88 to 112 million consumed, the table emptied because the cycle started too late (old entries at 0.81 of the table at the trigger), so the trigger `entryRate` starts a cycle when the free entries would last less than `safetyFactor` (2) times the last cycle's duration at the observed promotion rate and the QoS policy raises the marker when the table would empty before the running cycle's predicted end (binarytrees 13 to 15 cycles a run against 10, triggered at 0.53 to 0.61 of the table, the marker raised in 2 to 5 cycles against 8 to 9); the ring's soft-limit cascade at 7 workers under `young=stw` was not a trigger problem (the collector already ran back to back at 860 to 925 MB/s of promotion, each episode one cycle started and not finished then 2 to 3 fallbacks with no cycle between because the mark-sweep left old space at 97.5 to 101 percent of the limit and a requested full collection suppresses the trigger, plus one spurious request from the compacting collection's own promote-all 300 to 400 ms later at 15 percent): a fallback's full collection compacts when its mark-sweep leaves old space at or above the trigger's floor and withdraws the request its promote-all made, 31 to 33 fallbacks a launch to 8 in every launch of two matrices, 308 to 320 frames to 162 to 190, every remaining fallback a cycle started and not finished; measured interleaved: binarytrees 8 workers longest stop 0.38 to 0.55 ms against 23.1 to 27.2, sweep stops 0 to 1 a run at 0.10 to 0.17 ms, the run 2196 against 2218 ms, the comparison's row 1.82 s kasm and 1.87 Smalltalk against section 1a's 1.88; the devices at 5 workers, 10 launches a row a side, 0 fallbacks and 0 frames missed in all 80 launches with the main thread stopped no worse (iPhone storm 31.7 to 30.0 ms per 10 s, large churn 67.7 to 75.5 with overlapping ranges; iPad 46.8 to 48.8 and 154.3 to 154.7), the devices' sweep stops being the large churn's old allocations as before (1 to 14 a launch on the iPhone, 146 to 284 on the iPad, 0.06 to 0.12 ms of work with up to 10.7 ms of time to safepoint from a large fill that does not poll), the Mac's other rows unchanged; unexplained: one iPad large-churn launch's initial mark with 570 ms of time to safepoint (every other under 5 ms in 40 launches, the main thread's longest park 1.3 ms, no frame missed; likely the utility marker on the efficiency cores not reaching a poll); the aligned A/B against 97465fc 0.995 to 1.004 at 1 worker and 0.944 to 1.059 at 8 with overlapping ranges and cycle ratios 0.993 to 1.009 (as earlier modules' 8-worker spread), `interpret` identical, `just arc-check` passes; `just check` on 767fd7f, the core tier, every gate in 12 375 s (393 + 121 tests in every test gate, ThreadSanitizer 0 reports alone and under load, 205 kernel tests, the four fuzzers with "libFuzzer build: ok" at 0.83 to 3.34 million runs, the Mac matrix 8 fallbacks in each ring `young=stw` launch and a first idle launch missing 344 frames behind no stop, the third such, the iPhone 0 fallbacks and 4 and 6 frames in the ring `young=stw` behind 15.6 ms scavenges as before); two earlier gate runs failed, `ios-check` on an unneeded `unsafe` the macOS build did not flag (46f8454) and `tsan-load` on a module 7 test's 10 s wait for the young collector's verifier stop, now 120 s with the assertion unchanged (767fd7f); not done: no row exercised `waitForSweep` or the main worker's unbounded old-space stop, the rate rule watches promotion only, the large fill's time to safepoint; its three open questions answered by the owner on 2026-11-09 as recommended (the main worker never waits outside a stop, the extra marking accepted with the devices' energy measured at the next energy pass, 8 to 10 ring fallbacks a launch under `young=stw` the oracle row's known cost)); collections speed, built 2026-11-08 to 09 (`docs/modules/collections-speed.md`, the owner's choice of 2026-11-08: the library, measured first, no dictionary-probe primitive): the comparison's `collections` program split into four kernels of its own plus an empty program for the start-up (`experiments/runtime-comparison/programs/collections-{oc,dict,stream,sort,empty}`, `bench.sh`'s `$PARTS`, the checksums adding up to the whole's), five interleaved rounds against Pharo 12 at thermal nominal with the sends from `kajo run` and the counting build: before, net of start-up, OrderedCollection 1.89 times Pharo (2.0 sends per element), Dictionary 2.85 (152.6 sends per element, 57 percent of it `printString`), the stream 15.5 (8.0 sends per character) and the sort 4.63 (3.0), so the stream was the library's and the rest were under the interpreter's 5.5 to 6; the one VM change: primitives 121 and 122 take any byte object (`Machine.isByteObject`; the long paths poll as a long String's), `ByteArray>>=` keeps the class check and compares with 121, `ByteArray>>hash` is 122's FNV-1a with the same function in Smalltalk (`hashOfBytes`) as the fallback, so a ByteArray and a String of the same bytes hash alike and are never equal; `WriteStream>>nextPut:` on a String stream is one send, the encoding primitive 128, with `nextPutGrowing:` on failure, `readLimit` brought up to date where it is read rather than `max:` on every put, `grow`, `contents` and `nextPutAll:` of a String, Array or ByteArray copying in one step with primitive 38 (4 to 2 sends per Character, 9 to 4 per `nextPutAll: 'hello'`, a million puts 124 to 58 ms, `contents` of 1 MB 30 to under 1 ms), `PositionableStream>>skip:` on a non-text stream no longer sends an undefined `max:min:`; `Integer>>printString:` counts the digits and writes them into a ByteArray from the right with no stream (105 to 9 sends per number, 1786 to 356 ms for 600 000; a part under the ratio, flagged as a deviation, kept because printing an Integer is every app's path), `String>>do:` skips `scalarSizeAt:` when every byte is a scalar; after: Dictionary 1.49 (56.8 sends per element), the stream 9.23 (5.0 per character, none removable in the kernel), OrderedCollection and the sort unchanged within their ranges, the whole program 4.45 s against 6.26 (2.77 times Pharo's 1.61, from 3.88), the per-part table beside the whole-program row as a hand-written block in `docs/performance/README.md` section 5; the 2000-class scripted session Mac to Mac, five a side interleaved, `class.hierarchy` p50 258.9 to 233.9 ms and `package.selectors` 307.6 to 290.0 with frames missed overlapping (39 against 44); the round trip byte-identical on every kernel commit (`canonical-tonel.sh --check`, 172 kernel and 28 tools files); the aligned A/B against 1a6a1b8 0.995 to 1.009 at 1 worker with instruction ratios 1.000 (`st-sends` 1.009 is a Smalltalk kernel built with the changed classes) and 0.960 to 1.086 at 8 with overlapping ranges, `Dispatch.o` identical, `just arc-check` passing; `just check 1a6a1b8` on 0c8e48a, the core tier, every gate in 12 197 s (394 + 121 tests, ThreadSanitizer 0 reports alone and under load, 211 kernel tests, 241 tools tests, the four fuzzers with "libFuzzer build: ok" at 0.80 to 3.19 million runs, the Mac matrix's ring under `young=stw` 8, 8 and 10 fallbacks and its first idle launch missing 272 frames behind no stop, the fourth such, the iPhone 0 fallbacks and 2 to 5 frames in the same ring row); not done: the stream's remaining five sends per character, `String>>reverseDo:`, `keysAndValuesDo:` and `reversed` still stepping one scalar at a time, the probe's hooks unchanged, a LargeInteger's `printString` dividing twice as often; its three open questions built as recommended (`Symbol asString` left, no part sends it; no sort primitive, the sort is under the ratio and would remove about 789 bytecodes and 18.3 block activations per element while apps sort with a block; no probe primitive, a Symbol lookup 12.1 sends and 339 ns, a String lookup 19.8 sends and 464 ns)); the first launch's gap, built 2026-11-09 (`docs/modules/first-launch.md`, a bug follow-up; nothing under `Sources/KajoVM`, `kernel/` or `tools/`): the brief's premise did not hold, the gapped row was not the new binary's first launch but the matrix's first scenario launch after its 3 drift and 108 golden launches, and the cause was the Mac mini's display turned off by powerd inside the window (the brief's case three, a gap in the display link itself): a golden launch declares user activity, which wakes the display, but holds no display assertion, so with the user idle past the display-sleep time powerd asked for the display off at every golden exit and the display cycled off and on through the golden phase (every 12 to 15 s in the weekly and gate runs); the off asked for as the last golden launch exited landed in the first scenario window (b2: "Time to turn off display" at 03:37:44.540, WindowServer's `Display 2 setEnabled:0` at 03:37:52.27 while the scenario's own `PreventUserIdleDisplaySleep` assertion, taken when its link started, was 7 s old; the gap opened at 6496.4 ms of the window and ran 3503.6 ms to its end, 419 frames, the `screens-sleep` notification on the main queue at 6500.3 ms, callback lateness at most 1.75 ms, longest turn 3.19 ms, 0 stops), and every later launch missed none because a scenario launch releases a display assertion at exit, which turns on powerd's `delayDisplayOff`; the three historic gapped rows each have "Display is turned off" inside their launch in `pmset -g log`; the system's first-launch work on a new binary is real but separate, 392 ms before `main` (amfid, XprotectService, syspolicyd) against 5 ms on later launches, all before the window; built: the scenario mode's launch trace (`kajo-launch-report` prints `launch step=` from `main` to `window-end`; every display-link gap over 100 ms recorded with its place in the window, the callback's lateness, the last turn and view call before it; a 10 ms main-queue heartbeat and the system's notifications when tracing; `gaps100` and `gap_max_at_ms` on the result line; `Sources/KajoShellCore/FrameGaps.swift`), every `mode=` launch of the Mac shell holds `PreventUserIdleDisplaySleep` from `main` until exit (the product mode holds none; no setting changed), `shell-matrix.sh` runs one idle warm-up launch into `warmup.txt` before its first row (`WARMUP=0` leaves it out) and `shell-report.py` prints its numbers on a line of their own before the tables and `--bar`, never as a row (the weekly summary inherits it; both readers' output on the 2026-11-08 matrices byte for byte unchanged); measured: part 1 over five fresh builds with the matrix's own prefix, b2 419 frames missed behind 5 display offs in the prefix and b4 with the fix 0 missed and 0 offs, neither with a warm-up (b3 and b5 without the fix met no off in their first window, the off cycle being 30 s there against 12 to 15; not traced); part 4 five fresh builds of cda1177, every warm-up and every first idle row 0 of 1200 with 0 display offs during any matrix, the only misses the ring under `young=stw` (184 to 220 frames, 8 to 10 counted soft-limit fallbacks); the iPhone matrix at 5 workers with the warm-up (157 launches for 156 rows, the warm-up 0 of 1200 at thermal nominal) 0 fallbacks, the ring under `young=stw` 1, 4 and 5 frames behind 13.7 to 14.6 ms scavenges as before; `just check` on cda1177, the Swift tier, every gate in 3485 s (394 + 121 tests, ThreadSanitizer 0 reports in 2685 s, 211 kernel tests, apps, new-check); not done: no notarized dmg launched (none exists), the 12 to 15 against 30 s off cycle, the iPad; its two open questions built as recommended (the warm-up a line, kept for the binary's own 392 ms; a release smoke test later with the release module)); module 11b, Distribution, built 2026-11-08 (`docs/modules/distribution.md`, ADR 0014 amended; nothing under `Sources/KajoVM`, `kernel/` or `tools/`): the macOS shell is the Kajo app (target, scheme and product `Kajo`, bundle `dev.katajamaki.kajo`, `Sources/KajoShellCore/Product.swift`: with no `mode=` it copies the checkout it carries to `~/Library/Application Support/Kajo/<version>/` once per version, a partial folder renamed with a marker written last and an incomplete one moved aside, opens the tools on the development image with write-back to the copied `tools/`, File > New App… over `KajoGenerator` and a bundled xcodegen, File > Install Command Line Tool… linking `Contents/Helpers/kajo` into `/usr/local/bin` on request and showing the `sudo ln` line when it cannot write there; `KAJO_SUPPORT_DIR` and `KAJO_CLI_LINK_DIR` override both for tests); the checkout's `Prebuilt/` holds four static xcframeworks (KajoVM, KajoApp, KajoAppDevelopment, KajoDev; macOS arm64 and iOS arm64 slices, every compile `-O -whole-module-optimization -strict-memory-safety -enable-library-evolution -swift-version 6`, no `-g`, no `-enable-testing`, built by `xcodebuild build` from `scripts/dist-frameworks.yml`), `bin/kajo` and a `Package.swift` of binary targets that a generated project names as its one local package (SwiftPM refuses an absolute `binaryTarget` path and a `KajoPin` with Swift sources is compiled for x86_64 too in an Any Mac Release build, so `KajoPin`, the `KajoAppBuild` trait and KajoVM's conditional `-O` are gone; both configurations link `KajoApp`, Debug adds the development frameworks by name with `link: false`, the image phase runs the prebuilt `kajo` and compiles nothing: 0.12 s where 11a's took 14); `scripts/dist.sh <version>` (export, CLI, frameworks, app, inside-out signing with the hardened runtime and no entitlements, notarization and stapling only when `KAJO_NOTARY_PROFILE` names a keychain profile, `hdiutil` dmg with SHA-256, `codesign --verify` and `spctl` on the app, the dmg and a quarantined copy; 3 min 7 s) and `scripts/release.sh v0.<n> [--dry-run]` (local tag, dist, notes, the `git push` and `gh release create` lines, uploads nothing); measured from the dmg-made Sample: the Debug app's VM at 1.005 of Release on fib, 0.997 sends, 0.999 alloc (n = 9 each, checksums equal; 11a's 2.6 to 4.0), Debug first frame 188 to 232 ms on the Mac, 99 to 114 on the iPhone, 224 to 241 on the iPad, 0 frames missed in every window but one Mac live window (1 of 3786), builds from clean 5 to 9 s against 30 to 43, the bundled `kajo test` 205 of 205, the round trip by Bonjour name on the Mac twice, the iPad once and the iPhone on the third run (the first two rebuilt steps found the name still resolving to the previous launch's port, `Connection refused`, so `app-roundtrip.sh` falls back to the console's address, 8523a77, a path no device run has exercised yet); sizes: dmg 15.3 MB, the app 45.8 MiB of which the checkout 25.7 MiB (`Prebuilt/` 18.6, KajoVM 10.5), xcodegen 7.3 MiB, `dev.img` 6.1 MB; Gatekeeper not met: the keychain holds only an Apple Development identity and no notary profile, `spctl` rejects the app and the dmg (origin Apple Development), the dmg is named `Kajo-0.1-unsigned-dev.dmg` and the script needs no change once a Developer ID Application certificate and `notarytool store-credentials kajo-notary` exist (the owner's); the offline build met with `-skipPackageUpdates -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -scmProvider system`, empty caches and a log that fetched nothing, the network itself on; `just check` on 1667cb1 (Swift tier, no fuzzer owed): 385 + 121 tests, ThreadSanitizer 0 reports in 3040 s, 205 kernel tests, apps, new-check on the wizard's project, the first run on 8523a77 failing `just apps` because `KajoShellCore` used `Process` on iOS (fixed in 1667cb1); the first real release ran on 2026-11-09 once the owner had created the `Developer ID Application: Joni Katajamaki (BDN6M642M2)` certificate and the `kajo-notary` profile and allowed the keychain prompt (`KAJO_NOTARY_PROFILE=kajo-notary just release v0.1` on 8b11e25: export, CLI, frameworks, app, signing, notarizing the app in 36 s and the dmg in 34 s, stapling, `spctl` accepting the app, the dmg and a quarantined copy as "Notarized Developer ID", the bundled `kajo test` 211 of 211, 4 min 32 s in all; `Kajo-0.1.dmg` 15 431 768 bytes; the tag `v0.1` pushed; two earlier attempts the day before died on the keychain prompt `codesign` waited on, which `dist.sh`'s 120 s bound turned into a `FAILED` line, and one `xcodebuild` SIGKILLed at 0 s with no killer in the log); not done: a build with the network off, `kajo-bench` on the phone, simulator and Intel slices, Sparkle, `Config.swift`'s dead `!KajoAppBuild`; its six open questions answered by the owner on 2026-11-09: simulator slices are to be added to the prebuilt xcframeworks (a follow-up, `docs/modules/simulator-slices.md`), the rest as built (the menu item for the CLI, no updater, the app's image not sealed, xcodegen bundled at 7.3 MB, the absolute pin now and a remote binary package with a later release); the simulator slices, built 2026-11-09 (`docs/modules/simulator-slices.md`, the first answer built; scripts and the generator, nothing under `Sources/KajoVM`, `kernel/` or `tools/`): `dist.sh` builds a third slice of each prebuilt framework for `generic/platform=iOS Simulator` at `ARCHS=arm64` with the same flags (`-target arm64-apple-ios18.0-simulator`), `-create-xcframework` takes the three, each xcframework lists `ios-arm64`, `ios-arm64-simulator` and `macos-arm64`, the manifest and the size listing name the slice; the generated iOS target gains `"ARCHS[sdk=iphonesimulator*]": arm64` because a generic simulator build asks for x86_64 too and failed to resolve `KajoApp` (the device build's settings unchanged, shown by `-showBuildSettings`; fixture and test in the same commit); `new-check.sh` builds the generated iOS target's Debug for the simulator with 0 warnings, the Debug product's checks and `vtool` saying `IOSSIMULATOR`; measured: the frameworks step 69 to 100 s, the dmg 15 448 949 to 17 452 775 bytes (+2.0 MB; the app +7.6 MiB, each slice's interfaces about as large as its binary), the macOS and iOS slices' object code identical but for two path-length immediates; a dmg-made Sample builds for the simulator in Debug (6 s) and Release (5 s) with 0 warnings and no Kajo module compiled, and on a temporary iPhone 17 simulator (iOS 27.2, the runtime installed by the owner during the run) the Debug app reaches its first frame in 419 to 477 ms and serves (a `serving=tcp` line each launch, the name in `dns-sd -B`, one listening socket) while the Release app reaches it in 364 to 398 ms and does not; `just check` on 8f06c70, the Swift tier, every gate in 3522 s (394 + 121 tests, ThreadSanitizer 0 reports, 211 kernel tests, apps, new-check with the simulator row); not done: no x86_64 slice, no `simulator` target in `app-roundtrip.sh`, no request sent to the simulator's server (needs the token); its two questions built as recommended (arm64 only; no round-trip target); the discoverability follow-up, built 2026-11-09 (`docs/modules/discoverability.md`, from the owner's first use of v0.1: the tools' keys were bound but shown nowhere, and Pharo's `allInstances` was wanted): a Smalltalk menu (Do it ⌘D, Print it ⌘P, Inspect it ⌘I, Accept ⌘S, Senders of it ⇧⌘N, Implementors of it ⇧⌘M, Browse it ⇧⌘B, Instances of it ⇧⌘I) whose items act on the focused pane through its own key action (each tool registers its panes with `pane:keys:action:`, the host's `focused` get and `pressKey` call, `KajoTextView` taking a bound key in `performKeyEquivalent:` so it never reaches the menu bar), the same items as each pane's context menu, the Workspace's key hint and the browser's Accept hint in the status line until first used, Help with Keyboard Shortcuts generated from the menus, panes and toolbars (a test asserts every bound key is listed) and Kajo on GitHub through a host `openURL` op (http and https only), all three menus built from item lists in `DevTools`, the release notes' First steps; primitives 167 `allInstancesOf:limit:` and 168 `instanceCountOf:` (`Sources/KajoVM/ObjectModel/InstancePrimitives.swift`, `ObjectMemory/Instances.swift`) run in one stop of their own kind `instances` after the promote-all hook and walk the old map, which then holds exactly the used entries (pending-sweep entries and deferred frees are applied or released by the hook, a large object counts once); 167 counts and fills in the same stop with the Array allocated in old space through the object memory with the stop's roots, as class definitions and reshapes do, and rooted by the answer with no poll between (if the allocation collected, a second Array of exactly what was found); limits 0 to 16 777 215, immediates answer `#()`; the kernel's `Behavior>>allInstances` (limit 100 000), `allInstances:`, `allSubInstances` (one walk over `Smalltalk allBehaviors`, metaclasses included) and `instanceCount`, in `ExtremeIntegerTests`; measured: `Object allInstances: 1` 0.049 ms p50 on the development image and 0.30 on the 2000-class image, `String allInstances: 100000` 0.16 and 0.72, with 1.2 million garbage objects 1.5 to 3.4 ms and the slowest stop 3.8 ms, so no chunking; a Workspace evaluating the walk ten times by its Do it (`mode=devsession session=instances`, frames counted per step) missed 0 frames in 40 evaluations; `interpret` identical, the aligned A/B against 194d8ed 0.997 to 1.010 at 1 worker and 0.964 to 1.022 at 8 with instruction ratios 0.997 to 1.000; `just check 194d8ed` on 32c0a44, the core tier, every gate in 12 480 s (399 + 121 tests, ThreadSanitizer 0 reports alone and under load, 218 kernel tests headless, in the Mac shell and on the iPhone, the four fuzzers with "libFuzzer build: ok" at 0.85 to 3.35 million runs, the Mac matrix's ring under `young=stw` 167 to 191 frames behind 8 to 9 fallbacks and its warm-up and first idle row 0 of 1200, the iPhone 0 fallbacks and 3 to 7 frames in the same row); deviations: one key, one action measured in AppKit's documented order (the window's views, then the menu bar) because macOS refused to activate the scripted shell so its window was never key, `Class allSubInstances` answers every class, the frame measurement evaluates the Array's `size` (printing it re-found the previous runs' printStrings and doubled the work each time, to 15.6 s); not done: the window-server key path, UIKit has no menus, Instances of it on source panes, `DevSession>>describe:` printing a whole collection before cutting it, the iPad; its three questions answered by the owner on 2026-11-09 (`pointersTo:` its own module, no Smalltalk items in the Edit menu, and no default limit for `allInstances`, Pharo's rule, against the recommended 100 000: built in the `pointersTo:` follow-up, whose `pointersTo` has none either). ADRs
0003, 0006 and 0008 carry device measurements from an iPhone 17 Pro
(experiments/device-measurement and entry-locality) and energy measurements
(experiments/power: marker at utility, young collector at user-initiated on
device; the marker's timed wait is the VM's whole idle cost). Read them before touching the areas they
cover.

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
   session=instances` (`docs/modules/discoverability.md`).
 * `tools/` the developer UI (module 9c, `docs/modules/developer-ui.md`,
   ADR 0013): 27 Tonel class files, `DevClient` over primitive 164, the
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
   170 Tonel class files since module 10 (`LargeArray` removed in 10,
   `LargeObjectTest` in place of `LargeArrayTest`; the merge sort since
   9c), in the canonical form the image
   itself writes (`Smalltalk writeTonel:`); `just build-image`, `just
   kernel-test`). The image is never committed.
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
