# Results: VM core language, Rust vs Swift

Two equivalent VM slices (`rust/`, `swift/`) built against `SPEC-SHARED.md`,
running the same `.kasm` kernels from `kernels/`. Every number below comes from
`./bench.sh` (output saved verbatim in `bench-output.txt`, raw per-run lines in
`bench-raw.txt`). Machine: Apple M2 Max, 8 P-cores + 4 E-cores, macOS 27,
rustc 1.86.0, Swift 6.4 (Xcode 27.1). No thread pinning.

## 1. Results table

Median of 5 interleaved runs, wall time of the kernel only (thread spawn to
join; boot and .kasm loading excluded). "equal" = every variant of both
languages produced the same checksum for that kernel and worker count.

Variants:

- `rust`: `--release`, `opt-level=3`, `lto="fat"`, `codegen-units=1`, `panic="abort"`
- `rust-native`: the same plus `-C target-cpu=native`
- `swift-O`: `swift build -c release` (`-O`, whole-module optimization)
- `swift-Ounchecked`: the same plus `-Ounchecked -enforce-exclusivity=unchecked`
- `rust-align32`, `swift-O-align32`: the default flags plus LLVM
  `-align-all-nofallthru-blocks=5`. These are **not** in DESIGN.md. I added
  them after finding that `swift-O` and `swift-Ounchecked` emit identical
  interpreter loops yet differ by about 20% (see below). They control for
  code placement.

```
| kernel | variant          | workers | median ms | min ms | speedup 1->8 | GC cycles | checksum | equal |
|--------|------------------|--------:|----------:|-------:|-------------:|----------:|----------|:-----:|
| arith  | rust             |       1 |    3004.1 | 2984.0 |              |         0 | 372800000 |  yes  |
| arith  | rust             |       8 |     397.9 |  397.6 |        7.55x |         0 | 372800000 |  yes  |
| arith  | rust-native      |       1 |    3005.1 | 2981.3 |              |         0 | 372800000 |  yes  |
| arith  | rust-native      |       8 |     404.4 |  402.1 |        7.43x |         0 | 372800000 |  yes  |
| arith  | swift-O          |       1 |    3629.6 | 3627.6 |              |         0 | 372800000 |  yes  |
| arith  | swift-O          |       8 |     483.1 |  478.5 |        7.51x |         0 | 372800000 |  yes  |
| arith  | swift-Ounchecked |       1 |    3049.2 | 3045.0 |              |         0 | 372800000 |  yes  |
| arith  | swift-Ounchecked |       8 |     413.7 |  404.8 |        7.37x |         0 | 372800000 |  yes  |
| arith  | rust-align32     |       1 |    2999.2 | 2979.2 |              |         0 | 372800000 |  yes  |
| arith  | rust-align32     |       8 |     406.9 |  402.6 |        7.37x |         0 | 372800000 |  yes  |
| arith  | swift-O-align32  |       1 |    3029.5 | 3017.3 |              |         0 | 372800000 |  yes  |
| arith  | swift-O-align32  |       8 |     410.1 |  402.9 |        7.39x |         0 | 372800000 |  yes  |
| fib    | rust             |       1 |    1465.6 | 1456.6 |              |         0 | 24682992 |  yes  |
| fib    | rust             |       8 |     189.7 |  188.5 |        7.73x |         0 | 24682992 |  yes  |
| fib    | rust-native      |       1 |    1468.6 | 1451.5 |              |         0 | 24682992 |  yes  |
| fib    | rust-native      |       8 |     189.5 |  188.3 |        7.75x |         0 | 24682992 |  yes  |
| fib    | swift-O          |       1 |    1924.3 | 1905.7 |              |         0 | 24682992 |  yes  |
| fib    | swift-O          |       8 |     252.1 |  248.5 |        7.63x |         0 | 24682992 |  yes  |
| fib    | swift-Ounchecked |       1 |    1543.9 | 1525.4 |              |         0 | 24682992 |  yes  |
| fib    | swift-Ounchecked |       8 |     201.2 |  198.1 |        7.67x |         0 | 24682992 |  yes  |
| fib    | rust-align32     |       1 |    1464.2 | 1453.3 |              |         0 | 24682992 |  yes  |
| fib    | rust-align32     |       8 |     188.4 |  188.0 |        7.77x |         0 | 24682992 |  yes  |
| fib    | swift-O-align32  |       1 |    1552.7 | 1536.9 |              |         0 | 24682992 |  yes  |
| fib    | swift-O-align32  |       8 |     203.4 |  201.3 |        7.63x |         0 | 24682992 |  yes  |
| sends  | rust             |       1 |    2383.7 | 2352.2 |              |         0 | 1066666666666668 |  yes  |
| sends  | rust             |       8 |     440.4 |  401.6 |        5.41x |         0 | 133333335000001 |  yes  |
| sends  | rust-native      |       1 |    2365.0 | 2356.9 |              |         0 | 1066666666666668 |  yes  |
| sends  | rust-native      |       8 |     414.5 |  328.2 |        5.71x |         0 | 133333335000001 |  yes  |
| sends  | swift-O          |       1 |    2943.6 | 2930.9 |              |         0 | 1066666666666668 |  yes  |
| sends  | swift-O          |       8 |     521.0 |  494.7 |        5.65x |         0 | 133333335000001 |  yes  |
| sends  | swift-Ounchecked |       1 |    2554.4 | 2542.0 |              |         0 | 1066666666666668 |  yes  |
| sends  | swift-Ounchecked |       8 |     446.0 |  407.2 |        5.73x |         0 | 133333335000001 |  yes  |
| sends  | rust-align32     |       1 |    2381.9 | 2374.9 |              |         0 | 1066666666666668 |  yes  |
| sends  | rust-align32     |       8 |     397.8 |  381.5 |        5.99x |         0 | 133333335000001 |  yes  |
| sends  | swift-O-align32  |       1 |    2561.0 | 2548.4 |              |         0 | 1066666666666668 |  yes  |
| sends  | swift-O-align32  |       8 |     448.2 |  434.2 |        5.71x |         0 | 133333335000001 |  yes  |
| alloc  | rust             |       1 |    2023.6 | 2014.9 |              |        15 | 41950911 |  yes  |
| alloc  | rust             |       8 |     468.3 |  463.6 |        4.32x |     20-21 | 42008248 |  yes  |
| alloc  | rust-native      |       1 |    2019.5 | 2015.6 |              |        15 | 41950911 |  yes  |
| alloc  | rust-native      |       8 |     479.8 |  463.0 |        4.21x |        20 | 42008248 |  yes  |
| alloc  | swift-O          |       1 |    2375.5 | 2363.7 |              |        15 | 41950911 |  yes  |
| alloc  | swift-O          |       8 |     516.1 |  499.0 |        4.60x |     19-20 | 42008248 |  yes  |
| alloc  | swift-Ounchecked |       1 |    2069.7 | 2064.8 |              |        15 | 41950911 |  yes  |
| alloc  | swift-Ounchecked |       8 |     492.6 |  486.7 |        4.20x |        20 | 42008248 |  yes  |
| alloc  | rust-align32     |       1 |    2012.4 | 2000.9 |              |        15 | 41950911 |  yes  |
| alloc  | rust-align32     |       8 |     477.8 |  464.5 |        4.21x |        20 | 42008248 |  yes  |
| alloc  | swift-O-align32  |       1 |    2111.4 | 2078.5 |              |        15 | 41950911 |  yes  |
| alloc  | swift-O-align32  |       8 |     495.0 |  485.2 |        4.27x |        20 | 42008248 |  yes  |

Swift / Rust median ratio (same workers; >1 means Swift slower):
  arith  w=1: swift-O 1.21, swift-Ounchecked 1.02, swift-O-align32 1.01, rust-native 1.00, swift-O-align32/rust-align32 1.01
  arith  w=8: swift-O 1.21, swift-Ounchecked 1.04, swift-O-align32 1.03, rust-native 1.02, swift-O-align32/rust-align32 1.01
  fib    w=1: swift-O 1.31, swift-Ounchecked 1.05, swift-O-align32 1.06, rust-native 1.00, swift-O-align32/rust-align32 1.06
  fib    w=8: swift-O 1.33, swift-Ounchecked 1.06, swift-O-align32 1.07, rust-native 1.00, swift-O-align32/rust-align32 1.08
  sends  w=1: swift-O 1.23, swift-Ounchecked 1.07, swift-O-align32 1.07, rust-native 0.99, swift-O-align32/rust-align32 1.08
  sends  w=8: swift-O 1.18, swift-Ounchecked 1.01, swift-O-align32 1.02, rust-native 0.94, swift-O-align32/rust-align32 1.13
  alloc  w=1: swift-O 1.17, swift-Ounchecked 1.02, swift-O-align32 1.04, rust-native 1.00, swift-O-align32/rust-align32 1.05
  alloc  w=8: swift-O 1.10, swift-Ounchecked 1.05, swift-O-align32 1.06, rust-native 1.02, swift-O-align32/rust-align32 1.04
```

Clean release build times, from the same `bench.sh` run (`rm -rf target .build`
first, wall clock):

| build | time |
|---|---|
| rust (release, fat LTO) | 3.3 s |
| rust (target-cpu=native) | 3.3 s |
| rust (align32) | 3.3 s |
| swift -O WMO | 6.1 s |
| swift -Ounchecked | 5.8 s |
| swift -O align32 | 6.0 s |

Both projects have no dependencies. The Swift time includes SwiftPM manifest
compilation and the test-free product only.

### What the numbers say

- **With layout controlled, Swift is 1-8% slower than Rust.** On 1 worker
  `swift-O-align32` vs `rust-align32` is 1.01 (arith), 1.06 (fib),
  1.08 (sends) and 1.05 (alloc). `swift-Ounchecked` vs `rust` is in the same
  range (1.02 to 1.07).
- **The plain `swift-O` column (17-31% slower) is mostly a code-placement
  artifact, not safety checks.** I diffed the disassembly of the interpreter
  function `run()` for `-O` and `-Ounchecked`. The instructions are the same
  in both builds, apart from `adrp` page offsets. The `-O` binary is slower on
  `arith`, whose hot loop never leaves `run()`, so the difference can only come
  from where the loop lands in memory. Forcing 32-byte alignment of branch
  targets in the `-O` build recovers almost all of it: arith goes from 3630 to
  3030 ms. The same flag does nothing for Rust, which happened to land well.
  The lesson for Kajo is that a switch interpreter on M2 swings about 20% with
  code layout, so any language A/B under 10% is within layout noise unless
  layout is pinned.
- `target-cpu=native` makes no measurable difference for Rust.
- **Scaling 1 to 8 workers** is about the same in both languages: arith/fib
  7.4-7.8x, sends 5.4-6.0x, alloc 4.2-4.6x. The 8 P-cores are shared with
  whatever else macOS runs, and nothing is pinned. Sends has noisy 8-worker
  runs; compare its min column to its median. Alloc scales worst because GC is
  single-threaded and stop-the-world. At 8 workers, about 150 ms of the about
  470 ms wall time is inside `collect()` (median `gc_ms` in `bench-raw.txt`,
  similar in both languages), about 7.5 ms per pause with about 16 MB live.
  Time-to-safepoint is not included in that figure.
- **GC cycles are identical across languages**: 15 at 1 worker, 19-21 at 8
  workers. At 8 workers the count varies by one between runs because block
  races between workers change fragmentation.
- **Checksums**: identical between Rust and Swift, and across all variants, for
  every kernel and worker count. fib's checksum is also the same for 1 and 8
  workers. arith's checksum matching across worker counts is arithmetic
  coincidence (each partial sum is reduced mod p separately). sends and alloc
  differ by design: sends' inputs depend on the worker, and alloc keeps one
  long-lived tree per worker.

## 2. Dispatch loop: jump table or not

**Rust: jump table.** One central `br` through a table of 32-bit relative
offsets, with a single range check (the `_ => fatal` arm). The registers
(`pc`=x9, `sp`=x25) stay in registers across the loop:

```
ldrb   w8, [x9], #0x1          ; op = *pc++
cmp    w8, #0x1a
b.hi   <bad opcode>
adr    x10, #0
ldrsw  x11, [x27, x8, lsl #2]
add    x10, x10, x11
br     x10
```

**Swift (final): jump table**, the same shape with 16-bit table entries:

```
ldrb   w8, [x9], #0x1
cmp    w8, #0x1a
b.hi   <bad opcode>
adr    x10, #-32
ldrh   w11, [x25, x8, lsl #1]
add    x10, x10, x11, lsl #2
br     x10
```

**Swift (first version): two jump tables plus a compare chain.** The first
Swift loop had `case 0x10, 0x11:` (jump_if_true and jump_if_false sharing one
body, which tested `op == 0x10` inside). LLVM split the switch into three
parts: a table for 0x00-0x0F, a compare for 0x10, and a second table for
0x11-0x1A. Every arithmetic or compare bytecode paid two extra branches:

```
ldrb   w9, [x8], #0x1
cmp    w9, #0xf
b.hi   L_upper              ; ops >= 0x10 leave the first table
...table 1...
L_upper: cmp w9, #0x10 ; b.ne L_t2
L_t2:    sub w10, w9, #0x11 ; cmp w10, #0x9 ; b.hi ... ; ldrb ... ; br x12
```

Rust had the same merged arm (`OP_JUMP_IF_TRUE | OP_JUMP_IF_FALSE`) and still
got a single table. Splitting the case into two took arith on Swift from 3430
to 3000 ms. I made the same split in Rust, which changed nothing measurable
there, so the sources stay structurally identical. This shows how fragile
switch lowering is, and it is a reason to check the assembly in CI for the real
VM.

## 3. Ergonomics

### Lines of code (non-blank, non-comment; tests excluded unless noted)

| component | Rust | Swift |
|---|---|---|
| object model and tagging (`object.rs` / `Object.swift`) | 118 | 77 |
| heap, blocks, TLAB, sweep (`heap.rs` / `Heap.swift`) | 139 | 110 |
| boot and loader, method dicts, lookup (`image.rs` / `Image.swift`) | 166 | 148 |
| GC mark + safepoints + VM state + alloc slow path (`gc.rs`+`vm.rs` / `VM.swift`) | 28 + 196 | 205 |
| interpreter + primitives (`interp.rs` / `Interp.swift`) | 326 | 290 |
| threading / runner (`runner.rs` / `Runner.swift`) | 62 | 69 |
| assembler (`kasm.rs` / `Kasm.swift`) | 264 | 237 |
| CLI + module list (`main.rs`+`lib.rs` / `main.swift`) | 35 | 27 |
| **total (no tests)** | **1334** | **1163** |
| unit tests | 13 tests, 182 lines inline | 13 tests, 129 lines |

The two are roughly the same size. Swift is about 12% shorter, mostly because
of less `unsafe { }` and `*p.add(i)` noise, and because pointer subscripts
read naturally (`r.fp[1 &+ n]` vs `*r.fp.add(1 + n)`). Rust's interpreter is
compacted by `macro_rules!`. Swift has no equivalent and uses `@inline(__always)`
helpers that take closures (`compare(vm, w, &r, 3, <)`). Those inline cleanly,
with no closure context or ARC in the output.

### Where the unsafety lives

**Rust**: 27 `unsafe fn` and 17 `unsafe { }` blocks (8 of the fns are in
`interp.rs`, 7 are the raw accessors in `object.rs`). There are 3
`unsafe impl`: `Sync` and `Send` for `Vm`, and `Send` for a `SendPtr(*mut Worker)`
wrapper used to move a worker pointer into `std::thread::scope`. Shared mutable
state that only changes while the world is stopped uses `UnsafeCell` (worker
registry, mark stack). Safepoint state is a real `Mutex<SafepointState>` +
`Condvar`, which is the one place the borrow checker actively helped: the guard
holds the lock and `wait` consumes and returns it, so mistakes there do not
compile. Everything else is raw pointers and the compiler checks nothing,
same as Swift.

**Swift**: 63 `Unsafe*Pointer` type mentions, 171 `.pointee`, 4
`unsafelyUnwrapped`. Strict-concurrency escape hatches in Swift 6 language
mode: **0** `nonisolated(unsafe)`, **0** `@unchecked Sendable`, **0** `@Sendable`, **0**
`withExtendedLifetime`, **0** `Unmanaged`. That zero is not a sign of safety. The
checker never sees the sharing:
- Workers are `pthread_create`d with a C function pointer and a raw context
  pointer. `Thread`/`Task` would have needed `Sendable` captures, and raw
  pointers are not `Sendable`, so they would have produced the escape hatches.
- All shared state is a `VMCore` struct in raw memory, reached through
  `UnsafeMutablePointer`. Mutation through `.pointee` is invisible to both
  concurrency checking and dynamic exclusivity checking.
- Global constants are `let`s of trivial types, which are `Sendable`.

So the Swift 6 count says "Swift 6 mode cost nothing", but only because the
design opts out of the model entirely, as the Rust one does with its 3
`unsafe impl`.

### Clearly nicer or clearly worse

- **Swift integer semantics fight VM code.** Every `+`, `-`, `<<` and
  `Int(x)` traps on overflow in `-O`, so the hot path is written with
  `&+ &- &>> &<<`, `Int(truncatingIfNeeded:)` and `Int64(bitPattern:)`.
  `UnsafeMutablePointer(bitPattern:)` returns an Optional, so a tagged word
  becomes a pointer through `.unsafelyUnwrapped`. Rust's `as` casts and release
  wrapping are silent, which is terser but hides bugs that Swift would trap
  in `-O`. In this experiment the explicit operators were enough: the checked
  `-O` loop was instruction-identical to `-Ounchecked`.
- **Atomics.** Rust: `AtomicBool` is an ordinary field of `Vm`, and the poll is
  one `ldrb` off the `vm` register. Swift: `Atomic<Bool>` (Synchronization) is
  `~Copyable` and has to live in a `let`. My first version kept it behind its own
  `UnsafeMutablePointer<Atomic<Bool>>`, which costs an extra dependent load at
  every send and back-jump. Making `VMCore` a `~Copyable` struct with
  `let gcRequested: Atomic<Bool>` inline fixed that (one `ldrb`). It works, but
  you need to know about noncopyable types. The heap's block cursor atomics stay
  as pointers. Parallel marking (not implemented) would need atomic `fetch_or` on
  arbitrary object headers. Rust has `AtomicU64::from_ptr` for that. Swift's
  standard library has no blessed way to treat a raw heap word as an atomic.
  It would mean rebinding memory to `Atomic<UInt64>` (murky) or a C shim or the
  swift-atomics package. **Parallel marking is easier in Rust.**
- **Switch lowering.** Rust lowered the merged-arm `match` into one table.
  Swift's front end and LLVM did not (see section 2). Both use LLVM, so this
  comes from the IR each front end hands over, not a fundamental limit, but it
  bit Swift and not Rust.
- **ARC in the hot path: none found, by construction.** I grepped the
  disassembly of `run`, `execute`, `sendSlow`, `primitive`, `lookupMiss`,
  `lookup`, `allocSlow` and `safepoint` for
  `swift_retain/swift_release/swift_bridgeObject*`, and every count was 0. The
  only ARC calls in VM code are 3 `swift_bridgeObjectRelease` in `collect()`'s
  verbose-logging string interpolation. Removing ARC took nothing because I
  designed against it from the start: no classes or existentials reachable from
  the loop (`Image` is a class but only the loader touches it), worker and VM
  state as structs in raw memory passed as `UnsafeMutablePointer`, interpreter
  registers as a trivial struct passed by value, and constants as integer
  literals in `case` labels. So I cannot report what a naive class-based Swift
  VM would have cost. I only know the raw-pointer style avoids ARC without any
  annotations.
- **Tooling.** `cargo test` with tests in each file and `swift test` with Swift
  Testing were both painless, and Swift Testing runs tests in parallel by
  default. Rust clean builds are about 2x faster (3.3 s vs 6 s). Reading
  assembly was the same effort in both (`otool -tV`). LTO inlined the Rust
  interpreter into the thread closure, so finding it took a search for the
  dispatch pattern. Swift kept a named `run` symbol.
- **iOS.** The Swift VM module cross-compiled for `arm64-apple-ios18.0` with
  `swiftc -sdk iphoneos` on the first try. The Rust iOS target is not installed
  on this machine (`rustup target list --installed` shows only darwin and wasm).
  I did not install it.

## Deviations from DESIGN.md (applied identically in both)

- **Extra primitives**: `Class>>basicNew` (fixed-size instances),
  `SmallInteger>>//` and `\\`. Division is used once per worker to split the
  work. arith's "modulo" is a conditional subtract, so no send happens in its
  loop.
- **Symbols** carry a sequential id slot. Method dicts and the lookup cache
  still hash on pointer bits `(sel >> 3)`. Boot order is specified so both heaps
  have identical layouts.
- **No metaclasses**: classes are instances of `Class`, and class-side
  primitives read the receiver's instSize and classIndex slots.
- **Frames** put the 4-word header (method, caller pc, caller fp, caller hdr)
  after the temps rather than before the receiver. That way arguments pushed
  by the caller become the callee's temps without copying. Caller pc/fp are
  stored as tagged SmallIntegers, so GC scans stacks uniformly.
- **`store_temp`/`store_ivar` pop** their value.
- **The sends kernel only produces cold lookup-cache misses** (9 per worker).
  Three receiver classes and one selector never collide in a 1024-entry
  direct-mapped cache. One class (`Leaf`) inherits `step:` so its cold lookup
  walks the superclass chain. The kernel therefore measures cache-hit send cost
  with a polymorphic site plus a primitive send (`at:`), not miss handling.
  Forcing real misses would have meant contriving hash collisions.
- **Sweep**: the simpler option. TLABs come only from fully empty blocks, and
  partially live blocks are left alone.
- **Safepoint poll** is a relaxed load. Acquire/release ordering is carried by
  the release store of the flag and the safepoint mutex. The park path
  re-reads the flag with acquire under the lock.

## 4. Recommendation

On this slice, Swift reached within about 1-8% of Rust once code layout was
controlled, scaled the same across 8 workers, and produced identical results.
Neither language decides the question on performance. The larger risks seen
here apply to both: about 20% swings from code placement, and switch-lowering
fragility that silently turned one jump table into three. Whichever language is
chosen, the VM needs assembly checks and layout-aware benchmarking. Rust's
advantages were concrete but modest: about 2x faster clean builds, a cleaner
atomics story (`AtomicU64::from_ptr` for future parallel marking, plain atomic
fields), terser integer and pointer casts, and macros for opcode families. Swift's
advantages were also concrete: slightly shorter and more readable pointer
code, a first-try iOS cross-compile with the system toolchain, and native
interop with the UIKit/AppKit side Kajo ultimately has to drive. Swift's
safety features (ARC, exclusivity, strict concurrency) did nothing for the VM
core; it is written in a raw-pointer dialect where they are deliberately bypassed,
just as Rust's borrow checker is bypassed with `unsafe`. A reasonable reading is that the core can
be written in either language. The choice should rest on the UI-bridging and
live-development story, which this experiment did not test, not on interpreter
speed. Caveats: one machine, a small switch interpreter (no threaded dispatch,
which neither language expresses natively), single-threaded marking, a sends
kernel without real cache misses, and no iOS on-device numbers.
