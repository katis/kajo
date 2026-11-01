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
 - 1 to 8 worker scaling was 7.5x on compute kernels. Allocation scaled 4.3x
   because marking is single threaded; parallel marking is future work.
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
   `nonisolated(unsafe)`.
 - `Atomic` is non-copyable, so a struct holding one inline becomes
   `~Copyable`. There is no clean way to treat a raw object header word as an
   atomic; parallel marking will need its own design.

## Project structure

 * `Package.swift` is the root SwiftPM package: `KajoVM` library, `kajo`
   headless CLI, `KajoVMTests` (Swift Testing).
 * `Sources/KajoVM/` the VM core. `Sources/kajo/` the CLI.
 * `kernel/` Smalltalk sources the image is built from. The image is never
   committed.
 * `apps/` Xcode projects for the macOS and iOS shells, depending on the root
   package. Not created yet.
 * `experiments/` throwaway spikes with a design brief and results each.
 * `docs/CONTEXT.md` domain vocabulary. `docs/adr/` one decision per file.
 * `references/` contains prior art and other references we might benefit from
   in the design. Gitignored; see `references/MANIFEST.md`.
 * `justfile` has the common commands: `just build`, `just test`, `just run`,
   `just bench`, `just ios-check`.
