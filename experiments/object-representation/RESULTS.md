# Results: object representation, direct pointers vs object table

Three object memories under one interpreter source (`swift/shared/`,
symlinked into each module), built against `SPEC.md`:

- **A**: oop = address of the header; `become:` via Spur-style forwarders.
- **B**: oop = offset of a 16-byte table entry (header + body offset); body
  starts with a back reference.
- **C**: A compiled with `OOP_OFFSET`; oop = heap offset.

Every number comes from `./bench.sh` (output verbatim in `bench-output.txt`,
raw per-run lines in `bench-raw.txt`). Apple M2 Max, 8 P + 4 E cores, macOS
27, Swift 6.4, no thread pinning. Medians of 5 interleaved runs, kernel wall
time only (thread spawn to join). Two builds: `O` (`-c release`) and
`align32` (the same plus LLVM `-align-all-nofallthru-blocks=5`). They agree
to within a few percent everywhere below, so no conclusion rests on code
placement. All unit tests (14 for A, 12 for B, 14 for C) pass, also under
ThreadSanitizer (`swift test --sanitize=thread`, including a 4-worker test
that runs become, reshape, GC and compaction while other workers execute).

## Fairness fixes made before the final run

Three things would have been misread as representation effects. Each was
found by looking at the output, then fixed in the shared code for every
variant:

1. **A spilled all interpreter registers on every send.** The poll slow path
   took and returned the `Regs` struct by memory, so LLVM stored five
   registers to the stack before the `gcRequested` test on every send. Fix:
   the slow paths take and return scalars.
2. **B's `send` was a call, not inlined**, despite `@inline(__always)`. Fix:
   `@_transparent`. Both are checked in the assembly below.
3. **False sharing between `Worker` structs.** The first full run had B 23
   to 28 percent *faster* than A on `sends` and `alloc` at 8 workers, with A
   scaling 5.4x on `sends`. Adjacent `malloc`s put workers on shared cache
   lines, and workers write their struct on every primitive call and TLAB
   bump; B's larger struct happened to fall differently. Workers are now
   128-byte aligned and padded, and all three scale alike (7.5x on sends,
   5.3x on alloc). The earlier output is not kept in the tree. This bug
   exists in the `vm-language-bench` slice too, so its "allocation scaled
   4.3x because marking is single threaded" was probably partly false
   sharing.

## 1. Results tables

### Kernels (median ms; B/A and C/A ratios; checksums equal across all variants and both builds)

```
| kernel | workers | build | A ms | B ms | C ms | B/A | C/A | checksum | equal |
|---|--:|---|--:|--:|--:|--:|--:|---|:-:|
| arith | 1 | align32 | 3028.6 | 3014.4 | 3019.0 | 1.00 | 1.00 | 372800000 | yes |
| arith | 1 | O | 3023.0 | 3013.8 | 3016.3 | 1.00 | 1.00 | 372800000 | yes |
| arith | 8 | align32 | 405.4 | 407.7 | 405.8 | 1.01 | 1.00 | 372800000 | yes |
| arith | 8 | O | 406.0 | 406.0 | 409.8 | 1.00 | 1.01 | 372800000 | yes |
| fib | 1 | align32 | 1523.3 | 1550.1 | 1550.0 | 1.02 | 1.02 | 24682992 | yes |
| fib | 1 | O | 1506.9 | 1550.4 | 1527.3 | 1.03 | 1.01 | 24682992 | yes |
| fib | 8 | align32 | 203.2 | 205.8 | 200.6 | 1.01 | 0.99 | 24682992 | yes |
| fib | 8 | O | 202.0 | 202.5 | 198.3 | 1.00 | 0.98 | 24682992 | yes |
| sends | 1 | align32 | 2510.8 | 2647.1 | 2525.3 | 1.05 | 1.01 | 1066666666666668 | yes |
| sends | 1 | O | 2380.9 | 2464.6 | 2392.6 | 1.04 | 1.00 | 1066666666666668 | yes |
| sends | 8 | align32 | 335.4 | 351.2 | 337.5 | 1.05 | 1.01 | 133333335000001 | yes |
| sends | 8 | O | 313.2 | 331.0 | 312.9 | 1.06 | 1.00 | 133333335000001 | yes |
| alloc | 1 | align32 | 2132.4 | 2170.5 | 2137.2 | 1.02 | 1.00 | 41950911 | yes |
| alloc | 1 | O | 2111.6 | 2155.1 | 2113.2 | 1.02 | 1.00 | 41950911 | yes |
| alloc | 8 | align32 | 405.2 | 408.8 | 405.1 | 1.01 | 1.00 | 42008248 | yes |
| alloc | 8 | O | 412.1 | 400.7 | 415.0 | 0.97 | 1.01 | 42008248 | yes |
| ivars | 1 | align32 | 2187.5 | 2192.8 | 2181.5 | 1.00 | 1.00 | 36383626 | yes |
| ivars | 1 | O | 2184.3 | 2189.0 | 2180.4 | 1.00 | 1.00 | 36383626 | yes |
| ivars | 8 | align32 | 289.9 | 290.8 | 282.9 | 1.00 | 0.98 | 71714128 | yes |
| ivars | 8 | O | 287.1 | 294.9 | 287.5 | 1.03 | 1.00 | 71714128 | yes |
| walk | 1 | align32 | 1974.8 | 2867.0 | 1959.5 | 1.45 | 0.99 | 9016009025388544 | yes |
| walk | 1 | O | 1978.1 | 2878.4 | 1946.9 | 1.46 | 0.98 | 9016009025388544 | yes |
| walk | 8 | align32 | 235.1 | 331.4 | 236.2 | 1.41 | 1.00 | 1127013096095744 | yes |
| walk | 8 | O | 235.7 | 337.5 | 236.0 | 1.43 | 1.00 | 1127013096095744 | yes |
| walkbuild | 1 | align32 | 1068.5 | 1047.9 | 1073.6 | 0.98 | 1.00 | 0 | yes |
| walkbuild | 1 | O | 1068.4 | 1043.8 | 1068.5 | 0.98 | 1.00 | 0 | yes |
| walkbuild | 8 | align32 | 137.9 | 139.3 | 142.2 | 1.01 | 1.03 | 0 | yes |
| walkbuild | 8 | O | 143.9 | 148.7 | 140.0 | 1.03 | 0.97 | 0 | yes |
```

`walkbuild` is not in DESIGN.md: it is `walk` with zero traversals, so
`walk - walkbuild` isolates the traversals. **Traversal only (align32):
A 906 ms, B 1819 ms, C 886 ms at 1 worker; A 97, B 192, C 94 ms at 8
workers. The table doubles the cost of a pointer chase that misses the
cache.** Building the graph (allocation, `Big` stores) costs the same in all
three.

### Scaling 1 -> 8 workers, refills, GCs

```
| kernel | build | A | B | C | tlab refills | B entry refills | GCs |
|---|---|--:|--:|--:|--:|--:|--:|
| arith | align32 | 7.47x | 7.39x | 7.44x | 0 | 0 | 0 |
| fib | align32 | 7.50x | 7.53x | 7.73x | 0 | 0 | 0 |
| sends | align32 | 7.49x | 7.54x | 7.48x | 8 | 8 | 0 |
| alloc | align32 | 5.26x | 5.31x | 5.28x | 30855 | 10325 | 20 |
| ivars | align32 | 7.55x | 7.54x | 7.71x | 8 | 8 | 0 |
| walk | align32 | 8.40x | 8.65x | 8.30x | 5120 | 1032 | 0 |
| walkbuild | align32 | 7.75x | 7.52x | 7.55x | 5120 | 1032 | 0 |
```
(`O` rows in `bench-output.txt`, same picture.)

**Entry allocation in B introduces no contention.** Per-worker runs of 4096
entries (lock-free pool or high-water `fetch_add`) refill about once per three
TLAB refills on `alloc` (10 325 entry refills vs 30 855 block refills over 20
GCs, 8 workers), and B scales like A on every allocation kernel. This is the
design that avoids Smalltalk-2026's lock-per-allocation; the scaling confirms
it. (Walk scaling above 8x comes from 8 workers each walking 1/8 of the
graph, which fits caches better.)

### become (8 workers: 1 operating, 7 running fib until stopped)

2^20 live objects; 10 000 two-way becomes between a random 2-slot P and a
random 3-slot Q (different sizes, so A takes the forwarder path); then one
bulk `becomeForward` of 100 000 objects.

```
| build | variant | 2-way becomes | fwd path | op us/become | pause us/become | wall us/become | bulk fwd pairs | bulk op ms | bulk pause ms | GC before ms | GC after ms | cleanup extra ms | ttsp us/stop | parked ms (7 workers) |
|---|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| align32 | A | 10000 | 9797 | 3.291 | 35.0 | 42.9 | 100000 | 1.957 | 2.032 | 8.880 | 10.6 | 1.715 | 31.8 | 2603.8 |
| align32 | B | 10000 | 0 | 0.204 | 40.4 | 48.8 | 100000 | 6.382 | 6.483 | 6.260 | 6.170 | -0.090 | 40.2 | 2800.5 |
| align32 | C | 10000 | 9797 | 3.382 | 35.9 | 44.5 | 100000 | 2.379 | 2.465 | 9.050 | 10.3 | 1.259 | 32.6 | 2688.4 |
```

- Per two-way become, the work inside the safepoint is **3.3 us in A**
  (follow, clone two objects, scan 8 stacks and the roots) vs **0.2 us in
  B** (swap two entries and two back references). Both are dwarfed by
  stopping the world: 31 to 40 us time-to-safepoint per stop with 7 busy
  workers, so the pause per become is 35 to 40 us and the wall time 43 to
  49 us in every variant. (203 of A's becomes took the in-place swap: a
  forwarded P resolves to a Q-sized clone.)
- Bulk forward of 100 000: **A 2.0 ms** (write forwarders, one root scan) +
  **1.7 ms extra in the next GC** to rewrite references and drop forwarders.
  **B 6.4 ms**, because a correct one-way become in B has to scan every live
  object's slots (2.8 M slots) and every root; see the deviation note. B's
  next GC costs nothing extra.
- The 7 fib workers spent 2.6 to 2.8 s parked in total over 10 003 stops.

### reshape (add an ivar to a class with 2^20 instances)

```
| build | variant | instances | op ms | pause ms | GC before ms | GC after ms | pause + GC after ms | parked ms |
|---|---|--:|--:|--:|--:|--:|--:|--:|
| align32 | A | 1048576 | 13.4 | 13.4 | 6.042 | 8.709 | 22.1 | 198.9 |
| align32 | B | 1048576 | 8.889 | 8.889 | 5.600 | 5.750 | 14.6 | 142.8 |
| align32 | C | 1048576 | 12.4 | 12.4 | 5.675 | 8.953 | 21.3 | 188.6 |
```

Stop-the-world pause: **A 13.4 ms, B 8.9 ms**. A is forwarder-free after the
next GC (8.7 ms, 2.7 ms more than a normal one): 22.1 ms of pauses in total.
B is quiescent when the op ends; its next GC is a normal one. Between the two,
A's kernel touched every instance through forwarders (each send to a
forwarded receiver misses the cache and follows), which is not timed
separately.

### compact (2^21 allocated, every other one dead, 32 MB live)

```
| build | variant | GC mark ms | GC sweep ms | cmp mark ms | plan ms | update ms | move ms | entry sweep ms | compaction pause ms | update/(update+move) | MB moved | MB live | slots updated | parked ms |
|---|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| align32 | A | 6.372 | 3.029 | 4.732 | 8.437 | 4.829 | 7.911 | 0.000 | 26.1 | 0.379 | 32.0 | 32.0 | 2098275 | 249.3 |
| align32 | B | 6.831 | 1.793 | 6.084 | 0.000 | 0.000 | 8.109 | 1.635 | 15.6 | 0.000 | 32.0 | 32.0 | 0 | 170.8 |
| align32 | C | 7.083 | 2.690 | 5.087 | 8.389 | 4.706 | 7.892 | 0.000 | 26.0 | 0.374 | 32.0 | 32.0 | 2098275 | 251.4 |
```

- Non-moving collection first (`gc: 3`): mark 6.4 / 6.8 ms, sweep A 3.0 ms
  (heap walk), B 1.8 ms (table scan). It frees no block: every block is half
  live.
- Compaction pause: **A 26 ms, B 15.6 ms**. A = mark 4.7 + plan 8.4 + update
  4.8 + move 7.9. Of A's post-plan work, **slot updating is 38 percent and
  moving 62 percent**; counting the plan pass (which exists only to compute
  forwarding addresses and displace headers), 63 percent of A's
  non-marking compaction time is pointer bookkeeping. B = mark 6.1 + one
  sliding pass 8.1 (moves the same 32 MB and stores one entry per object) +
  entry sweep 1.6, and rewrites 0 slots.
- A's Lisp-2 needs an 8-byte side buffer per live object (8 MB here) for the
  displaced headers.

### snapshot (walk graph, 2^22 nodes, saved at a safepoint, loaded at a new base)

```
| build | variant | save ms | MB | load ms | of which reloc ms | slots relocated | root words relocated | heap words changed by load | table entries scanned | reload ok | parked ms |
|---|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| align32 | A | 39.0 | 160.1 | 28.3 | 10.9 | 8391049 | 88 | 8391049 | 0 | 1 | 273.6 |
| align32 | B | 67.8 | 224.2 | 26.6 | 2.572 | 0 | 0 | 0 | 4202496 | 1 | 475.3 |
| align32 | C | 38.3 | 160.1 | 17.5 | 0.000 | 0 | 0 | 0 | 0 | 1 | 268.5 |
```

- **A relocates 8.39 M pointer slots (10.9 ms of a 28.3 ms load)**; the
  independent count of heap words that differ between file and loaded heap is
  the same 8 391 049. **B and C change 0 heap words**, measured the same way.
  B spends 2.6 ms rebuilding its free-entry pool from a 4.2 M entry table scan
  (no slot or live entry touched). C loads in 17.5 ms, the cost of reading
  the file.
- B's snapshot is 40 percent larger (the table) and saves slower. Save times
  are noisy (page cache, disk), loads are stable.
- In every variant the reloaded image's traversal matched the pre-save one.

## 2. Memory overhead and RSS

| | A | B | C |
|---|--:|--:|--:|
| bytes per object beyond its slots | 8 (header) | 24 (8 back reference + 16 entry) | 8 |
| `WNode` (2 slots) | 24 | 40 | 24 |
| peak RSS, walk, 1 worker | 167 MB | 231 MB | 167 MB |
| peak RSS, alloc, 1 worker | 71 MB | 114 MB | 71 MB |

B's table grows with the high-water mark of live+unswept objects and is never
returned (`alloc` touches 43 MB of table for a ~1 MB live set, because a GC
only happens when the 64 MiB block heap fills, by which time ~2.7 M bodies
and entries exist). A minimum body size of 16 bytes is needed for an A
forwarder; 0-slot objects cannot be become'd in A.

## 3. Assembly verdicts

From `llvm-objdump` of `run` in each module (`O` build, after the fairness
fixes). Each variant's dispatch loop is one jump table, `ldrb; cmp #0x1a;
b.hi; adr; ldrh; add; br`. No `swift_retain`/`swift_release` in `run`,
`lookupMiss`, `primitive`, `allocSlow`, `pollSlow`, `resyncSlow`, mark or
sweep of any variant. The only ARC in VM modules is host-side (loader,
result line) and in the cold safepoint operations (Swift arrays for root
ranges and the compaction plan).

**Field access (`push_ivar`)**

```
A:  ldr  x9, [x23]            ; receiver = fp[0]
    add  x8, x9, x8, lsl #3
    ldr  x8, [x8, #0x8]       ; slot                   2 loads, 1 dependent
C:  ldr  x9, [x23]
    add  x9, x9, x19          ; + heap base (in a register)
    add  x8, x9, x8, lsl #3
    ldr  x8, [x8, #0x8]       ;                        2 loads, +1 add
B:  ldr  x9, [x22]            ; receiver oop
    add  x9, x9, x28          ; + table base
    ldr  x9, [x9, #0x8]       ; entry.body (offset)
    add  x9, x9, x20          ; + heap base
    add  x8, x9, x8, lsl #3
    ldr  x8, [x8, #0x8]       ;                        3 loads, 2 dependent, +2 adds
```

**Verdict: B's indirection stays a single extra dependent load**, plus two
adds (the entry holds a body *offset* as DESIGN specified; an absolute body
address would save one add and lose position independence). In `ivars`,
where receivers stay in L1, it costs nothing measurable (1.00); in `walk`,
where every hop misses, it doubles the traversal.

**Send path, receiver class fetch.** A: `ldr x8,[x20]; tbnz w8,#0; ldr
x8,[x8]; and x2,x8,#0x3fffff` (receiver, header). B: `ldr x8,[x8]; tbnz;
ldr x9,[sp,#0x28]; ldr x8,[x8,x9]` (receiver, entry header; the table base
is reloaded from the stack because B runs out of registers in the send
path). **The header-in-entry design works: the class fetch is one dependent
load in both.** The cost of B is after the cache hit: every read of the
method (`prim`, `nTemps`, `maxStack`), its bytecodes and its literal frame
goes method oop -> entry -> body, and both bases are reloaded from the stack
there (`ldr x28,[sp,#0x28]`, `ldr x20,[sp,#0x8]`). That is the 3 to 5
percent on `fib` and `sends`.

**Did forwarder checks add branches to the send path? No.** The lookup cache
never holds class index 0, so a forwarded receiver misses and is followed in
`lookupMiss`. A's and C's send fast path is instruction-for-instruction the
same shape as B's minus the table hops. The one hot-path cost of forwarders
is `==`: A adds, on the *not identical* path only, `orr; tbnz` (any
SmallInteger?) and two header loads with `tst #0x3fffff` before falling back
to a call; B's `==` is `cmp; csel`.

## 4. Leak counts ("modules hide decisions")

Lines of code (non-blank, non-comment): shared interpreter, loader, VM state,
safepoints, frame fixups, runner, blocks 1124; `VMA/Memory.swift` (A and C)
516; `VMB/Memory.swift` 468. Tests: one 521-line file, 14 tests for A and C,
12 for B.

**A: sites outside the object memory that know about forwarders or about
oops being addresses: 4, plus a refusal rule.**

1. `lookupMiss`: forwarded receiver, follow and patch the stack slot
   (`#if FORWARDERS`).
2. `==` bytecode: follow before comparing (`#if FORWARDERS`).
3. Compaction must flush every worker's lookup cache: its selector keys and
   method values are addresses (found by a test).
4. Method dictionaries could not hash selectors by address: every compaction
   broke every dictionary (found by the compaction test). They now hash by
   the symbol's id. In general A/C need a stored identity hash (header bits)
   for every identity-hashed collection.
5. The refusal rule: Class, Method, MethodDict, Symbol, ByteArray and
   nil/true/false are never forwarded. Without it, lookup, activation, the
   literal frame and boolean tests (about six more sites) would need checks.
   Spur pays for the same thing elsewhere.

Inside A's object memory, every become also scans all stacks and roots.

**B: `body(oop)` indirections that could not be hidden: 0 in the
interpreter and loader.** Every object access goes through `om.*`, and the
interpreter source is identical to A's except the two `#if FORWARDERS`
sites. B's oops never change, so lookup caches, method dictionaries,
host-side oop tables and snapshots need nothing. The only representation
detail outside B's file is `selShift = 4` in the cache index, which A has as
3.

**Shared by every variant (cost of a moving GC, not of a representation): 5
`RAW` sites** where the interpreter caches a raw pointer into a body (`pc`
into the bytecodes, `lits` into the literal frame: activate, return, resync).
Compaction converts every frame's saved pc to an offset before moving and
back afterwards, and workers re-derive `pc`/`lits` after any park point (a
flag checked after polls and after every primitive call; primitive calls
also store `pc` and `hdr` to the worker).

## 5. What was hard, and what generational or concurrent GC would need

**A.** Forwarders themselves were easy (about 60 lines) and the send-path
trick (cache never holds the forwarder class) makes them free on sends. The
hard part was everything an *address* oop drags with it once objects move:
address-hashed dictionaries, lookup caches, host-side oop tables (the
symbol table had to become indices into the root array), the interpreter's
constants held in registers (nil/true/false are asserted never to move).
None of these show up until a test compacts a heap with garbage below the
methods; the benchmark kernel passed with all of them broken. Lisp-2 has
nowhere to put forwarding addresses, so headers are displaced into a side
buffer. Snapshot load must parse the whole heap to relocate it. Become needs
a stack scan per operation, and 0-slot objects cannot be forwarded.

**B.** Two allocators with separate exhaustion paths (entries and bodies),
either of which can trigger a GC; private entry lists must be invalidated by
every sweep (and the boot worker's by hand). Dead bodies must stay walkable
after their entry is freed or repointed, which is why the back reference
carries the body size. One-way become is not cheap with a table (below). The
interpreter needs two more live base registers than A, and on arm64 that
showed up as stack reloads in the send path. On the other hand compaction,
reshape and snapshot load were the simplest code in the experiment.

**Generational, A.** A Spur-style copying nursery fits directly: copy
survivors, leave forwarders (same format), follow during the scavenge. It
needs a write barrier on `store_ivar`/`at:put:` and a remembered set for
old-to-young references; young-object access stays a direct pointer. The
identity-hash header bits become mandatory.

**Generational, B.** Moving a survivor updates one entry, not every
referrer, but a remembered set is still needed to know which young objects
are reachable from old ones, so the write barrier is the same. Every
short-lived object also consumes and frees an entry; a nursery would want its
own entry region that can be reset in bulk, or the table becomes the
allocation bottleneck B avoided here.

**Concurrent, A.** Concurrent marking needs only a write barrier in either
variant. Concurrent *moving* in A needs a read barrier or forwarders checked
on every access (Shenandoah/Brooks style), which puts a forwarder check on
the hot path that this design kept off it.

**Concurrent, B.** The table gives each object one word to publish a move
atomically. That makes concurrent compaction tractable, but not free:
mutators that read or write the old body while it is copied still need a
protocol (per-object lock bit, copy-on-write fixups, or a brief per-object
handshake).

## 6. Recommendation input for the ADR (facts, not a decision)

On this machine, in this interpreter, the object table costs nothing
measurable when the entries are cached (`arith`, `ivars`: 1.00), 2 to 6
percent on send-heavy code (`fib`, `sends`), and **doubles the cost of a
cache-missing pointer chase** (`walk` traversal 2.0x, the whole kernel
1.45x). It uses 24 instead of 8 bytes of overhead per object (+38 percent
RSS on `walk`). It buys stable oops: two-way become is 16x cheaper inside
the pause (but the pause is dominated by stopping the world, ~35 us with 7
busy workers, in all variants), reshape pauses 34 percent less and leaves no
cleanup, compaction pauses 40 percent less and rewrites no slots, snapshot
load needs no fixups, and nothing outside the object memory (caches,
dictionaries, host tables) ever has to know an object moved. One-way bulk
become is *more* expensive in B (6.4 vs 2.0 + 1.7 ms) because it still needs
a full scan. Entry allocation scaled like TLAB allocation. Direct pointers as
heap offsets (C) ran within noise of A on every kernel and loaded snapshots
with zero fixups, so the relocation cost DESIGN.md attributes to direct
pointers is avoidable without a table; C keeps every other cost of A
(forwarders, address-like oops that move, the leak sites above). Caveats:
one machine (M2 Max), interpreted only, synthetic kernels, single-threaded
stop-the-world collector, no generational GC, no identity-hash header field
in A/C yet, and B's entries hold body offsets rather than addresses. iOS
devices have smaller caches than an M2 Max, which would likely widen the
`walk` gap rather than narrow it; that was not measured.

## Deviations from DESIGN.md and SPEC.md

- **B's `becomeForward:`**: DESIGN.md's "copy one entry over the other and
  free the first" splits identity whenever the target is referenced
  elsewhere (`from == to` becomes false). B instead turns each source entry
  into a transient forwarding entry, scans every live object and root once,
  and frees the source entries. Smalltalk-2026 does a full scan for the same
  reason.
- **A's two-way become** uses Spur's in-place swap when sizes match; the
  kernel pairs different sizes so it measures the forwarder path.
- **Not forwardable in any variant**: classes, methods, method dicts,
  symbols, byte arrays, nil/true/false; 0-slot objects in A.
- **Bulk `becomeForward` takes Arrays of Arrays** (no object may exceed a
  32 KiB block, so 100 000 pairs cannot be one Array).
- **Kernels load a shared `lib.kasm`** after the old prelude, including the
  four reused kernels; their checksums are unchanged from vm-language-bench.
- **Method dictionaries hash by symbol id, A/C flush lookup caches after
  compaction, cache index shift is 3 (A/C) or 4 (B)**: see SPEC.md's
  addendum.
- **`walkbuild`** is an added kernel (walk without traversals).
- **Heap size** is 1 GiB (lazy) for the new large kernels and 64 MiB for the
  four old ones and `ivars`.
- **Not done**: AGENTS.md's strict-memory-safety (`unsafe` keyword) mode is
  not enabled in these experiment modules, matching the slice they were
  copied from. Variant C was not dropped.
