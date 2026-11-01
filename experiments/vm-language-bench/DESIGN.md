# Experiment: VM core language, Rust vs Swift

## Question

Kajo needs a Smalltalk VM that runs on iOS (no JIT) and macOS, executes
Smalltalk processes in parallel on a shared heap, and never makes the UI
thread wait. Candidate implementation languages for the VM core are Rust and
Swift. This experiment answers two things:

1. **Performance.** With the same design and the same bytecode programs, how
   close are Rust and Swift on an interpreter hot loop, on send-heavy code,
   and on allocation-heavy code with a real collector? Both at 1 worker and
   at 8 workers (the M2 Max has 8 performance cores and 4 efficiency cores).
2. **Ergonomics.** How does the unsafe object-memory and GC code read and
   feel in each language? Where did the compiler help, where did it fight?

The result is not a product. It is two throwaway implementations and a
`RESULTS.md`. Nothing here needs to be beautiful; it needs to be *equal*
between the two languages so the comparison is fair.

## Fairness rules

- Same object layout, same bytecode set, same algorithms, same data
  structures, same caching strategy, same optimizations. If one side gets a
  trick, the other gets it too. If a trick is impossible in one language,
  note it in RESULTS.md rather than compensating silently.
- Hot paths use unchecked access in both: `get_unchecked` / raw pointers in
  Rust, `Unsafe*Pointer` in Swift. Neither side pays bounds checks the other
  does not.
- Every kernel produces a checksum. Rust and Swift must produce identical
  checksums for identical inputs; a mismatch is a bug, not a result.
- Release builds only:
  - Rust: `--release`, `lto = "fat"`, `codegen-units = 1`, `panic = "abort"`,
    `opt-level = 3`. Report with and without `-C target-cpu=native`.
  - Swift: `-O` with whole-module optimization. Also report `-Ounchecked`
    and `-enforce-exclusivity=unchecked` as a separate column, clearly
    labelled.
- Inspect the generated arm64 assembly of the dispatch loop in both (`otool
  -tV`, `cargo asm`, or `swiftc -S`). Confirm whether the `match`/`switch`
  became a jump table (`br` through a table) or a compare chain. Record this.

## The VM slice to build

Keep it to roughly one to two thousand lines per language. This is the
minimum that exercises the real costs.

### Object memory

- 64-bit words. Tagged values: low bit 1 = SmallInteger (63-bit, arithmetic
  shift), low bit 0 = object pointer (direct pointer, 8-byte aligned). No
  object table. `nil`, `true`, `false` are ordinary preallocated objects.
- Object header: one 64-bit word. Pack: class index (bits 0..21), slot count
  (22..53), mark bit, "has pointers" format bit, and a few spare bits. Define
  the exact packing once and copy it to both implementations. Followed by
  `slot count` 64-bit slots. For byte objects (used for method bytecodes and
  literal arrays can stay pointer objects) the slot count is in bytes and
  format bit says "bytes".
- Classes are heap objects too, with slots: superclass, method dictionary,
  name (ignore), instance slot count. Class index maps through a global class
  table (plain array of pointers) to the class object.
- **Allocation:** per-worker thread-local allocation buffer (TLAB) bump
  allocation. TLABs are carved from a shared heap of fixed-size blocks (say
  32 KiB blocks from one big `mmap`/`Vec`/`UnsafeMutableRawPointer` arena of
  some hundred MiB). A worker that exhausts its TLAB takes the next free
  block under a lock or atomic cursor. When no block is free, request a GC.
- **GC:** stop-the-world, non-moving mark-sweep.
  - Roots: each worker's frame stack, the class table, globals.
  - Mark: iterative with an explicit mark stack, setting the header mark
    bit. Single-threaded marking is acceptable; note whether parallel
    marking would be easy in each language.
  - Sweep: walk each block linearly (objects are contiguous within a block,
    header gives size), build a per-block free list of dead ranges, and
    return fully empty blocks to the global pool. Allocation from a
    partially free block can use a simple first-fit on that block's free
    list, or simpler: TLAB allocation only from fully empty blocks, and
    partially full blocks are left alone until they empty. Pick the simpler
    one and do it the same way in both languages.
  - **Safepoints:** a global atomic "GC requested" flag polled at every send
    and backward jump. A worker reaching a safepoint parks until GC
    completes. The requesting worker waits for all others to park, runs the
    GC, then releases everyone. Use proper acquire/release orderings. Count
    GC cycles and report them per kernel.

### Execution model

- A per-worker **frame stack**: one contiguous array of 64-bit words per
  worker (not heap-allocated contexts). A frame holds: return pc, caller
  frame pointer, method pointer, receiver, arguments, temporaries, then the
  operand stack. Frames are never materialized as objects in this
  experiment. Depth limit of a few thousand frames is fine.
- Methods are heap objects: a bytecode byte-object, a literal array (pointer
  object), argument count, temporary count, max stack.
- Method dictionaries: an open-addressing hash table keyed by selector
  (selectors are preallocated Symbol objects; hash by identity, i.e.
  pointer bits). Lookup walks the superclass chain.
- **Inline cache:** a per-worker global lookup cache (say 1024 entries)
  keyed on (receiver class index, selector) → method. No per-call-site
  inline caches. Both sides do exactly this.
- **Primitives:** SmallInteger `+ - * < > <= >= =` and `==` are special
  bytecodes with a fast path when both operands are SmallIntegers, falling
  back to a normal send otherwise. Add a handful of primitives reachable by
  send: `Object>>at:`, `at:put:`, `basicNew:`, `Object>>class`, and
  `Array new:`. That is all.

### Bytecode set

A small, fixed set shared byte-for-byte between the two implementations.
Suggested encoding (one byte opcode, optional one-byte operand):

```
push_temp n        push_literal n      push_self        push_ivar n
store_temp n       store_ivar n        pop              dup
push_nil           push_true           push_false       push_smallint n (signed byte)
send sel_idx argc  (two operands)      return_top       return_self
jump off           jump_if_true off    jump_if_false off (signed 16-bit offset)
add sub mul lt gt le ge eq  (special sends, fast path)
identical          (==)
```

Write a tiny assembler in each language (or one shared text format both
parse) so the kernels are defined once and identically. A shared text file
like `kernels/*.kasm` that both implementations load is preferred, because
then kernel equality is by construction.

### Kernels

Mirror the shape of Smalltalk-2026's `make bench`: total work fixed, divided
evenly between workers, each worker running the same method with different
inputs, results combined into a checksum.

1. **arith**: a loop summing `i * 3 + 7` modulo something over tens of
   millions of iterations, all SmallIntegers, no sends except the special
   arithmetic bytecodes, no allocation. Measures raw dispatch.
2. **fib**: recursive `fib: n` for n around 30 to 32, repeated. Measures
   send, lookup cache, frame push and pop, return.
3. **sends**: a polymorphic loop calling a 1-argument method on receivers
   of three different classes with the same selector, so the lookup cache
   is exercised with real misses and hits. Measures method lookup.
4. **alloc**: a binary-trees style kernel (allocate a tree of depth ~16,
   walk it computing a checksum, drop it, repeat) that forces many GC
   cycles per worker. Measures allocation, marking, sweeping, safepoint
   coordination.

Each kernel runs with 1 worker and with 8 workers. Report wall time for
each, the speedup, GC cycle count, and the checksum. Run each configuration
at least five times and report the median. Pin nothing; just note that the
machine has 8 P-cores and 4 E-cores.

### Threads

Workers are OS threads (`std::thread` / `Thread` or `pthread`). No async,
no actors, no Dispatch queues for the workers themselves; the point is to
model what a real VM would do. Swift 6 strict concurrency checking may need
`nonisolated(unsafe)` or `@unchecked Sendable` in places; count how many
and where, that is an ergonomics data point.

## Layout

```
experiments/vm-language-bench/
  DESIGN.md           this file
  RESULTS.md          written at the end
  kernels/            shared .kasm kernel sources, if the shared format is used
  rust/               Cargo project, `cargo run --release -- <kernel> <workers>`
  swift/              SwiftPM package, `swift run -c release kajo-bench <kernel> <workers>`
  bench.sh            runs the whole matrix for both and prints a table
```

## RESULTS.md must contain

1. The results table: kernel × language × workers × build flags → median ms,
   speedup 1→8, GC cycles, checksum equal yes/no.
2. The dispatch loop assembly verdict for each language (jump table or not),
   with a short excerpt.
3. Ergonomics notes, written honestly from the experience of writing it:
   - Lines of code per component (object memory, GC, interpreter, threading).
   - Where `unsafe` lives in Rust and how much; where `Unsafe*Pointer`,
     `nonisolated(unsafe)`, `@unchecked Sendable`, `withExtendedLifetime`
     etc. live in Swift and how much.
   - Anything that was clearly nicer or clearly worse in one language.
   - Any ARC traffic found in the Swift hot path (check with Instruments or
     by reading assembly for `swift_retain`/`swift_release` calls inside the
     interpreter loop) and what it took to remove it.
   - Build times for a clean release build of each.
4. A one-paragraph recommendation with the caveats that matter.

## Non-goals

No image format, no Smalltalk parser, no blocks or non-local return, no
process scheduler beyond "one Smalltalk process per worker", no UI, no iOS
build (a `cargo build --target aarch64-apple-ios` and an `xcodebuild` for
iOS are nice to try at the very end if cheap, but not required).
