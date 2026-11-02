# Spec: entry locality (variant L) and the memory-hierarchy microbenchmark

Written before the code. Everything not stated here is as in
`../object-representation/SPEC.md` (variant B) and
`../vm-language-bench/SPEC-SHARED.md`.

## Package shape

`swift/` is one SwiftPM package (macOS 15, iOS 18):

- `Kasm`: `Kasm.swift` symlinked from object-representation; an own
  `KernelFiles.swift` (kernel lookup in `../kernels` first, then
  object-representation's and vm-language-bench's; `experimentsDir` settable
  by the app, as device-measurement's copy).
- `VMA`, `VMB`, `VMC`: per-file symlinks to object-representation's sources.
  Not modified.
- `VML`: object-representation's `shared/` files symlinked (`Frames`,
  `Image`, `Interp`, `Runner`, `Values`, `VM`), plus its own `Blocks.swift`
  (16 KiB blocks with an entry area, a large-object space) and
  `Memory.swift` (derived from B's).
- `MemChase`: the Part 1 microbenchmark as a library; `memchase` its CLI.
- `el-bench <A|B|C|L> <kernel> <workers>`: VM kernels, one per process.
- `VMBTests`: object-representation's `VMTests.swift` symlinked. `VMLTests`:
  a copy of the same file whose only change is the `import` block
  (`@testable import VML`, compiled with `VARIANT_B` so B's expectations
  apply to L), plus `LocalityTests.swift`.
- `app/`: iOS app from device-measurement's pattern, linking all of the
  above; `bench.sh` (Mac) and `bench-device.sh` (phone).

## Variant L layout

### Blocks

The small-object heap is an arena of **16 KiB blocks**, aligned to 16 KiB.
16 KiB is the page size on iOS and on Apple-silicon macOS
(`hw.pagesize` = 16384 on the M2 Max), so a block is exactly one page and
"entry and body in the same block" means "one translation". A larger block
would put the entry area and most bodies in different pages; a smaller one
raises the per-block overheads below without changing translation.

```
block (16 KiB, at heapBase + 16384 * b)
  [0, used)            bodies, growing up      (backref word + slots, as B)
  [used, entryLow)     free gap
  [entryLow, 16384)    entries, growing down    (16 B each, as B: header, body offset)
```

Allocation of a small object takes one entry and one body from the same
block: the TLAB is `cur` (body bump, up) and `end` (entry bump, down). Fast
path, one compare:

```
if end - cur >= size + 16 { end -= 16; entry at end; body at cur; cur += size }
```

The block is full when the two meet. Retiring a TLAB records `used = cur -
start` and `entryLow = end - start` in the block metadata.

**Large objects.** A body bigger than 4 KiB (`size > 4096`) cannot usefully
share a 16 KiB block (the `Big` chunk arrays of the kernels are 16 392 bytes
and would not fit at all). Large bodies go to a **large-object space**: a
second arena of 32 KiB blocks after the small arena in the same reservation
(so body offsets from one base reach both), bump-allocated from a second,
per-worker large TLAB, never moved. Their entry is taken from the worker's
small TLAB as usual, so a large object's entry is *not* local. The 4 KiB
threshold bounds the tail waste of a small block at 25 percent. Every
kernel hop in this experiment goes through 3-word `WNode`s, which are
always small.

### Oops and the sparse index space

Oop = byte offset of the entry from the heap base, exactly as B's oop is
the byte offset of the entry from the table base; in L the table base *is*
the heap base, because the entries live in the heap. `OM` keeps B's two
fields (`table`, `heap`), both set to the heap base, so every accessor
compiles to the same instructions as in B and the comparison is layout,
not codegen. (A single-base L would save a register; not done.)

Entry index = oop >> 4 = block * 1024 + slot: block index times the
maximum entries per block (16384 / 16) plus the slot. Most of that space
can never be an entry (a slot is an entry only above `entryLow`). Offset 0
is a body address, so 0 is never an oop. The body's backref holds the
entry index in 32 bits as in B: up to 64 GiB of small arena.

**Side tables** indexed by entry index must be sized for the maximum:
`smallArenaBytes / 16` entries. B has none (marks are in the entry header,
as here); a future byte-per-entry side table (as AGENTS.md suggests for
marks set from the hot path) would cost 1 byte per 16 bytes of small arena,
6.25 percent, reserved; committed for every touched block regardless of
how many entries it holds (1 KiB of side table per block). In B the same
table costs 1 byte per allocated entry (2.5 percent of B's bytes on `walk`,
40 bytes per node). A bitmap would be 0.78 percent.

### Free entries ("runs per block")

B keeps per-worker lists of free entries refilled in runs of 4096. In L a
worker's run *is* the free gap of its current block: entries come from
bumping `end` down. There is no entry free list, no global run pool and no
high-water mark. Free entries inside a block's entry area (`[entryLow,
16384)` with header 0) are not reused until the whole block is free, just
as dead bodies inside a block are not reused until it is free or
compacted. The block pool (rebuilt at each sweep, lock-free cursor as in
the shared heap) holds every block whose free gap is at least 1 KiB, empty
blocks and partially used ones alike, in block order; a TLAB taken from a
partially used block starts at `cur = start + used`, `end = start +
entryLow`. A, B and C reuse only empty blocks; L needs partial reuse
because its entries pin blocks (below).

### Mark, sweep

Mark exactly as B (mark bit in the entry header). Sweep scans the entry
area `[entryLow, 16384)` of every in-use small block instead of the table:
a marked entry is unmarked and flags *its own block* and its body's block
(small or large) live; an unmarked in-use entry is freed (header 0). Small
blocks with no live entry and no live body return to the pool with `used =
0`, `entryLow = 16384`; large blocks with no live body likewise. A live
entry pins its block even when its body lives elsewhere.

### Compaction

Mark; then one pass over the small blocks computes each block's lowest
live entry (`liveLow`) and frees dead entries; then live small bodies slide
in block order, as B, into the body areas `[start, liveLow(b))` of the
blocks (an object that does not fit goes to the next block). The entry is
repointed; it stays where it is, so **a moved body is no longer in its
entry's page**. A source body never moves to a higher address (every
block's capacity is at least its original content). Large bodies do not
move. Afterwards a block is free only if it has neither a live entry nor a
body; a block whose bodies all moved out but whose entries are live stays
in use with an empty body area, which the pool hands out again as a
partial block. Derived pointers (saved pcs) as in B.

How much locality is lost is measured by `walkcompact` (below): a dead
node is allocated before every live node, so compaction moves every live
body, and roughly the upper half of the blocks keep only entries.

### Become, reshape, forward

As B: two-way become swaps the two entries and the two backrefs (the
bodies change blocks, so both become non-local); bulk forward and reshape
scan the entry areas instead of the table; reshape's new bodies come from
the operation TLAB (non-local). No table, so no table growth.

### Snapshot

The small arena's blocks `[0, lastInUse]` contain entries and bodies, so
the dump is: header, per-block `used` and `entryLow`, small blocks, large
blocks, symbol names. Load maps a fresh reservation and restores block
metadata. Nothing is rewritten and, unlike B, there is no free-entry pool
to rebuild.

## Part 1: memory-hierarchy microbenchmark (`memchase`)

No VM. Per thread, its own arrays, first touched by that thread. A random
cyclic permutation (Sattolo) of N objects; hop count M = max(2^22, 2N)
capped at 2^25, after M/4 warm-up hops; ns per hop = timed / M. Threads at
user-initiated QoS, started together behind a barrier; the reported
figure is the median over threads. Nodes are 64 bytes (one cache line).

- **chase**: N nodes of 64 B in one array; node word 0 = address of the
  next node. One dependent load per hop. Working set W = 64 N.
- **dsep** (double chase, today's table): an entry array of 16-byte
  entries (word 0 a header, word 1 = byte offset of the body from the node
  base) and a node array; entry i names node i (allocation order, as B);
  node word 0 = byte offset of the next *entry* from the entry base. A hop:
  `e = ebase + cur; b = nbase + e[1]; cur = b[0]` (B's hop exactly). Two
  dependent loads. W = 80 N.
- **dlocal** (the L layout): one region of 16 KiB pages, each holding K =
  204 objects: nodes from the bottom, entries from the top, entry j of a
  page naming node j of the same page. Same hop code with one base.
  W = 80 N, pages = N / 204.
- **dhalf**: as dsep with 32-byte nodes (the node array half the size):
  W = 48 N, two misses per hop. Against dsep it says whether bytes touched
  or the number of dependent misses sets the cost.
- **spread**: as chase but one node per 16 KiB page, at a random 64-byte
  offset in its page (to avoid cache-set aliasing). Cache footprint 64 N
  bytes like chase, page footprint 256 times larger. Against chase at the
  same N it separates translation reach from cache reach. Reported by the
  number of pages.

Sizes: the node array (chase's W) from 1 MiB to 1 GiB in powers of two;
the other modes run at the same N, and tables give both N and W. 1 thread
on both machines; 2 and 6 threads on the phone, 8 on the Mac, with the
per-thread size capped so the total stays under 1.5 GB (phone) and 8 GB
(Mac). One size per process launch.

Knees are read from the tables: the working set at which chase's ns/hop
steps (L1/L2 TLB reach, L2, system level cache), and the working set at
which dsep departs from 2x chase.

## Part 3 kernels

Loaded after prelude and lib (both unchanged) and `kernels/el-lib.kasm`,
which adds `Big3` (a 3-level version of `Big`: 2048-slot leaves and
mid-level arrays, so 2^23 elements fit; the original 2-level `Big` needs a
4096-slot top array at 2^23 nodes, which exceeds a 32 KiB block) and the
graph builders below. `walk:hops:` is lib's.

| kernel | what | 
|---|---|
| `walkN` (N = 20..23) | build 2^N / n `WNode`s linked in LCG order (`buildGraph3:`, as `buildGraph:`), traverse twice. 2^20 nodes = 24 MiB of A-bytes, 2^23 = 192 MiB |
| `walkbuildN` | the same, zero traversals |
| `walkcompactN` (N = 22, 23) | build with one dead `WNode` allocated before every live one, `compact: 4`, traverse twice |
| `walkcompactbuildN` | the same, zero traversals |
| `walkmarkN` (N = 22, 23) | build, `gc: 1` (stop-the-world mark and sweep of the graph, mark timed separately), return 0 |

Per-hop cost = (walk - walkbuild) / (2 * 2^N). Heap 1 GiB reserved for all
of these (L: plus 512 MiB of large space). Mark rate = live bytes (the
`liveBytes` metric, object sizes in A's terms for every variant: B and L
count bodies) / mark time. The marking thread is the worker thread; the
harness sets user-initiated QoS on the thread that creates the workers,
and logs the QoS a probe thread created the same way actually gets.

`sends` and `ivars` are the unchanged kernels.
