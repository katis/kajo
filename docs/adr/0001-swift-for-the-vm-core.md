# ADR 0001: Swift for the VM core

Date: 2026-11-01
Status: accepted

## Context

Kajo needs a Smalltalk VM that runs on iOS without a JIT, executes Smalltalk
processes in parallel on a shared heap, and talks to native SwiftUI/UIKit/AppKit
shells without ever blocking the UI thread. The candidate implementation
languages were Rust and Swift. C and Zig were considered and set aside: C gives
up compile-time help the other two offer, Zig is pre-1.0.

We built the same VM slice in both languages and benchmarked it. See
`experiments/vm-language-bench/RESULTS.md`. The slice has tagged 64-bit words,
per-worker TLAB allocation from a shared block arena, stop-the-world mark-sweep
with safepoint polling, per-worker frame stacks, a method lookup cache and a
small bytecode set, run on four kernels at 1 and 8 workers.

## Decision

The VM core is written in Swift, as a SwiftPM library target `KajoVM` with
strict memory safety enabled. Native shells are Swift. Everything above the
primitives is Smalltalk.

## Reasons

- Performance is equal within noise once code alignment is controlled: Swift
  was 1 to 8 percent behind Rust across the four kernels, and both dispatch
  loops compile to a single jump table. Scaling to 8 workers was the same.
- One language end to end. The VM, the VM-to-UI bridge, and the shells share
  one package, one debugger and Instruments. There is no C ABI to maintain.
- The VM to UI boundary is where Swift 6 strict concurrency earns its keep:
  `@MainActor` isolation turns "VM thread touched a view" into a compile error.
- The Swift VM module cross-compiled for iOS on the first try.
- Escape hatch: SwiftPM supports C targets natively. If a hot loop ever
  disappoints, it can become a small C target in the same package.

## Costs accepted

- The unsafe core (object memory, GC) is C-like raw pointer code in either
  language. Swift gives no Miri equivalent, so correctness there rests on
  design, tests, and ThreadSanitizer as a gate.
- Atomics are clumsier than in Rust: `Atomic` is non-copyable, and there is no
  clean way to treat a raw object header word as an atomic. Parallel marking
  will need care.
- The hot path must opt out of overflow and bounds traps explicitly with
  wrapping operators and unchecked access.
- Swift clean release builds were about twice as slow as Rust's (6 s vs 3 s on
  the slice).

## Consequences

- `KajoVM` has `.strictMemorySafety()` on, so every unsafe construct is
  labelled with `unsafe` and the trusted surface is greppable.
- VM worker threads are OS threads, never Swift `Task`s. Swift concurrency is
  used at the boundary, not inside the VM.
- The VM test suite will run under ThreadSanitizer as a gate, not a report.
