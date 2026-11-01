# Spec: object representation variants A, B, C

Written before the code. Everything not stated here is as in
`../vm-language-bench/SPEC-SHARED.md` (tagging, header bits, class indices,
bytecodes, frames, lookup cache, TLAB/block heap, kasm format). Where
DESIGN.md offered a choice, the simpler option is taken, used identically in
every variant, and listed under "Choices".

## Package shape

One SwiftPM package in `swift/`:

- `Kasm` target: the `.kasm` parser/assembler (copied from the slice) and
  kernel file loading. Host-side only.
- `swift/shared/*.swift`: interpreter, primitives, boot/loader, lookup,
  workers, safepoint protocol, frame fixups, kernel runner. **Symlinked into
  every VM module**, so all variants run the same interpreter source. Lines
  that only exist for one variant are under `#if FORWARDERS` (A and C).
- `VMA`: shared sources + `VMA/Memory.swift` (oop encoding, allocation, mark,
  sweep, compaction, become, reshape, snapshot). Defines `FORWARDERS`.
- `VMC`: symlinks to VMA's files, plus `OOP_OFFSET`. Not a third
  implementation.
- `VMB`: shared sources + `VMB/Memory.swift`.
- `orep-bench <A|B|C> <kernel> <workers>`: one executable linking all three.
- Test targets `VMATests`, `VMBTests`, `VMCTests`; one symlinked test file
  with variant-specific tests under `#if`.

The object memory API the shared code sees (per variant, `@inline(__always)`):
`om.header(o)`, `om.setHeader`, `om.slot(o,i)`, `om.setSlot`, `om.slotsPtr(o)`,
`om.bytesPtr(o)`, `om.classIndexOf(v)`, `alloc(vm,w,cls,n,bytes)`. `om` is a
trivially copyable struct loaded once per `run` (A: no fields; C: one base;
B: table base and heap base) so the bases live in registers.

## Oop encodings

All three keep SmallInteger tagging: low bit 1 = SmallInteger. `0` is never a
valid object.

**A, direct pointer.** `oop = address of the object's header word`. Body =
header word then slots, exactly the slice's layout. Slot `i` is at
`oop + 8 + 8i`.

**C, heap offset (A with `OOP_OFFSET`).** `oop = (address of header) - heapBase + 8`.
The `+8` bias keeps offset 0 (the first object, `nil`) from encoding as 0.
Dereference: `(heapBase - 8) + oop`; `om` holds `heapBase - 8`. All of A's
code is otherwise unchanged.

**B, object table.** `oop = byte offset of the entry in the table` = entry
index × 16 (low four bits zero, so the tag bit is free). Entry 0 is reserved.
Table: one `mmap` reservation of 16 Mi entries × 16 B = 256 MiB, pages arrive
on first touch; no growth (growth would be a safepoint operation that
`mremap`s or copies the table and rebases `om`; with oops as offsets nothing
else changes).

```
entry (16 B, at tableBase + oop):
  word 0  header   same bit layout as SPEC-SHARED (class 22, slots 32, mark, bytes)
  word 1  body     byte offset of the body from heapBase      (in use)
                   next free entry oop, 0 = end                  (free: header == 0)
body (in the block heap, at heapBase + bodyOffset):
  word 0  backref  bits 0..31  entry index (oop >> 4)
                   bits 32..63 body size in words, word 0 included
  word 1.. slots / bytes
```

Body size in bytes is the same as A's object size (`8 + slots`): the backref
word replaces A's header word. Packing the body size into the backref word
keeps the heap linearly walkable after an entry has been freed or repointed,
so compaction and the heap walk do not need the table to find dead bodies'
sizes. A body is live iff `entry(backref).header` is marked (during GC) and
`entry(backref).body == this body's offset`.

Per-object overhead: A and C 8 B (header). B 8 B (backref) + 16 B (entry) = 24 B.

## Forwarders (A, C)

A forwarder is an object whose header class index is **0** (`ciForwarder`;
SPEC-SHARED's "invalid" index) and whose slot count and bytes bit are the
original object's, so the heap stays walkable. Slot 0 holds the target oop.
Chains are allowed and followed until a non-forwarder. An object needs a
body of at least 16 bytes to become a forwarder; smaller ones are refused by
`become:`.

Forwarders are caught:
1. **Send**: the lookup cache never holds class index 0, so a forwarded
   receiver always misses. `lookupMiss` follows, patches the receiver's stack
   slot, and re-probes. The send fast path gets no extra instruction.
2. **`==` (identical bytecode)**: if the words differ and both are
   pointers, load both headers; if either is a forwarder, follow both and
   compare again.
3. **Primitives** that read the fields of their *arguments* follow them
   (become, forward, reshape). `at:`/`at:put:` touch only the receiver, which
   the send already followed; storing a forwarder into a slot is harmless.
4. **At become time** every worker stack and the host roots are scanned and
   forwarder references replaced (so a frame's receiver `fp[0]`, used by
   `push_ivar` without checks, is never a forwarder).
5. **GC mark** rewrites every slot (heap and roots) that refers to a
   forwarder to the final target. Forwarders are never marked, so sweep or
   compaction frees them.

Not forwardable (refused by `become:` in **all** variants, so the semantics
match): SmallIntegers, `nil`/`true`/`false`, and objects of class Class,
Method, MethodDict, Symbol, ByteArray. This keeps forwarders out of lookup,
method activation, literal frames and boolean tests. B could support them;
that difference is reported, not compensated.

## Allocation

Block heap and TLAB as the slice: blocks of 32 KiB, objects never span
blocks, bump allocation. Heap size per kernel: 64 MiB for arith, fib, sends,
alloc, ivars (as the previous experiment); 1 GiB reservation for walk,
become, reshape, compact, snapshot.

B also needs an entry per object. **Entry runs**: per worker, a private
singly-linked list of free entries (`w.entryFree`). Fast path: pop the head
(`w.entryFree = entry.next`). On empty, refill takes a run of up to 4096
entries: first from the global run pool (array of run heads, atomic cursor,
like the block pool, rebuilt only during sweep), else 4096 fresh entries at
the table's high-water mark (atomic `fetch_add`), threaded into a list. No
lock on any allocation path. If neither has entries, the worker requests a
GC like an empty block pool. Refills are counted. Sweep discards all
workers' private lists (their entries are still free in the table) and
rebuilds the pool from the table scan.

## Garbage collection

Single-threaded, stop-the-world, as the slice. Roots: host roots
(nil/true/false, symbols), 16 global slots, special selectors, class table,
every worker's stack `[0, sp]`.

**Mark.** A: mark bit in the header; when a slot or root refers to a
forwarder it is rewritten to the final target before marking. B: mark bit in
the entry header; slots are reached through the entry.

**Sweep (non-moving, the default collector).** The simpler option from the
slice: only completely empty blocks are reused. A walks every in-use block
and clears marks; blocks with no marked object return to the pool. B scans
the table `[1, hwm)`: marked entries are unmarked and flag their body's block
as live; unmarked in-use entries are freed and threaded into runs of 4096 for
the pool. Then blocks without live bodies return to the pool. B's sweep never
walks the heap.

**Compaction (explicit, `compact:`).** Mark, then slide every live object to
the lowest free address in block order (an object that does not fit at the
end of the destination block goes to the start of the next block, so no
object spans blocks). All blocks below the final destination are in use
afterwards, the rest free.

- A (Lisp-2 with displaced headers): (1) *plan*: walk the heap; each live
  object's header goes to a side buffer in walk order and is replaced by
  `newAddress | markBit` (bit 54 cannot be set in an address or a dead
  header). (2) *update*: walk again; for each live object, every pointer slot
  is replaced by the new address read from the target's header word; then all
  roots likewise. (3) *move*: walk again, `memmove` each live object to its
  new address and restore its header (unmarked) from the side buffer.
- B: one pass over the heap; for each live body `memmove` it to the
  destination and store the new offset in its entry. Then a table scan frees
  unmarked entries and unmarks the rest (B's sweep without block handling).
  No slot is ever rewritten.

Both variants must fix **derived pointers** that point into bodies: the
saved return pc in every frame (`hdr[1]`, an address inside the caller's
bytecode ByteArray), each worker's current pc and its cached literal-frame
pointer. Before moving, every saved pc is turned into a SmallInteger offset
from its method's bytecode start; afterwards back into an address using the
moved method. Workers re-derive `pc` and `lits` when they resume (a per-worker
`moved` flag, checked after a safepoint and after every primitive call). This
is shared code: it is the cost of any moving collector in this interpreter,
not of a representation.

## Safepoint operations

The slice's protocol (one atomic `gcRequested`, mutex + condvar, `active`,
`parked`, `epoch`) is generalised to `stopWorld(vm, w, op)`, where `op` is one
of `gc`, `become`, `forward`, `reshape`, `compact`, `snapshot`. The requesting
worker flushes `sp`, `pc`, `hdr`, retires its TLAB, locks; if a stop is
already in progress it parks and retries; else it sets the flag, waits until
`parked == active - 1`, runs the op, clears the flag, bumps `epoch`,
broadcasts. Workers park at sends and backward jumps (polls), or inside an
allocation slow path; at every park point their `sp`, `pc` and `hdr` are
flushed. Allocation inside an op (A's become clones, reshape bodies) uses a
VM-level op TLAB, retired at the end of the op; an op never triggers a GC.

Timed per op: `stw` (flag set to flag cleared, the pause), `ttsp` (flag set to
everyone parked), `op` (the work itself). Each worker records the time it
spends parked.

**become: (two-way).** A: follow both; if the bodies are the same size swap
their contents in place (Spur's shortcut, no forwarder); otherwise clone both
and turn `a` into a forwarder to `clone(b)` and `b` into a forwarder to
`clone(a)`; then scan stacks and roots. B: swap the two entries (header and
body offset) and swap the two bodies' backref indices.

**becomeForward (one-way, bulk).** Pairs `from[i] -> to[i]`. A: make each
`from[i]` a forwarder to `to[i]`, then one stack/root scan. B: see the
deviation below; each `from[i]` entry becomes a transient forwarding entry,
one scan over every live object's slots and all roots rewrites references,
then the `from` entries are freed (their bodies become garbage).

**Reshape (`addInstVar`).** A: heap walk collecting every object of the class
into a list, then for each allocate a body with one more slot, copy, nil the
new slot, forward old to new; stacks/roots scan; bump the class's instSize.
Forwarder-free after the next GC. B: table scan collecting entries of the
class, then for each allocate a new body, copy, repoint the entry and update
its header's slot count; the old body is garbage. Quiescent when the op ends.

**Deviation from DESIGN.md, B's becomeForward.** "Copy one entry over the
other and free the first" breaks identity whenever the target is referenced
from anywhere else (the copied entry and the target's entry are two oops for
one body, so `from == to` is false). Smalltalk-2026 does a full heap scan for
one-way become for the same reason (`om_mt.c`, `forward_one`). B therefore
does one full scan per bulk forward. Reshape in B does not need it because
the new body is not an object yet.

## Snapshot

Raw dump at a safepoint (the kernel's own `snapshot` primitive). File:
a header (magic, variant, saved heap base, block count, `nil/true/false`,
special selectors, class table, globals, roots, B: table high-water mark),
`used` bytes per block, the heap bytes of blocks `[0, lastInUse]`, B: the
table bytes `[0, hwm × 16)`, then the host symbol table (name, oop pairs).
Load maps a fresh arena (and table) while the original VM is still mapped,
so the base address is guaranteed to differ, then:

- A: walk every object in every in-use block and add `newBase - oldBase` to
  every pointer slot; the same for every root word and host symbol oop.
- B: rebuild the entry free runs by a table scan. No slot or entry is touched.
- C: nothing.

Measured: save time, bytes, load time, slots relocated (counted by the code
that writes them), and, outside the timed region, the number of heap words
that differ between the file and the loaded heap (A: every relocated slot; B
and C: 0). The loaded image then runs one traversal; its result must equal
the traversal before the save.

## Kernels and parameters

Load order: `../vm-language-bench/kernels/prelude.kasm`, `kernels/lib.kasm`
(new primitives, `Big` chunked array, walk graph), then the kernel file.
`arith`, `fib`, `sends`, `alloc` are read from `../vm-language-bench/kernels/`
by path.

New primitives: 8 `Object>>become:`, 9 `UndefinedObject>>forward:to:` (two
Arrays of Arrays, pairs in order), 10 `Class>>addInstVar`, 11 `gc:` (tag
selects which metric records it), 12 `compact:`, 13 `snapshot`, 14
`globalAt:`, 15 `globalAt:put:`, 16 `stopRequested`, 17 `stopOthers`.

`Big` is a 0-based array of `n` elements stored as an Array of Arrays of
2048 slots (a 2048-slot Array is 16 KiB; no object may exceed a 32 KiB block).

| kernel | parameters | heap |
|---|---|---|
| arith, fib, sends, alloc | unchanged from vm-language-bench | 64 MiB |
| ivars | 4 `Cell`s (4 ivars) per worker; `spin: 1000` round-robin; 32 000 spins in total split between workers; ~12 ivar reads/writes per iteration | 64 MiB |
| walk | 2^22 `WNode`s (next, val) in total, 2^22/n per worker, node `i` links to node `(1664525 i + 1013904223) mod m` (a full-period LCG, one cycle through all nodes in a scattered order); 2 traversals summing `val * hop` | 1 GiB |
| become | 2^20 objects alternating classes P (2 ivars) and Q (3 ivars); `gc: 1`; 10 000 two-way becomes between a random P and a random Q (always different sizes, so A takes the forwarder path); bulk forward of 100 000 objects (every 10th) to fresh objects; weighted checksum and identity count read through any forwarders; `gc: 2` (A: the cleanup GC); checksum again | 1 GiB |
| reshape | 2^20 instances of R (2 ivars); `gc: 1`; `R addInstVar`; touch every instance (writes and reads the new ivar); `gc: 2` | 1 GiB |
| compact | 2^21 `CNode`s allocated, every other kept (linked to the previous kept one), the rest garbage; `gc: 3` (mark, sweep timed); `compact: 4`; checksum via the chain and via the `Big` | 1 GiB |
| snapshot | one worker builds the walk graph (2^22 nodes) and traverses it once; `snapshot`; host loads it into a new VM at a new base and runs one traversal there | 1 GiB |

`become`, `reshape`, `compact`, `snapshot` run with 8 workers: worker 0 runs
the operation, workers 1..7 run `27 fib` in a loop until worker 0 calls
`stopOthers`; they return 0 so the checksum is worker 0's. The others run at
1 and 8 workers.

## Choices (where DESIGN.md left one open)

- Sweep: only completely empty blocks are reused (the slice's choice).
- Compaction: sliding, block-respecting, Lisp-2 with displaced headers in A,
  one pass in B. No separate forwarding table.
- Table: fixed 16 Mi entries, never grows.
- A's two-way become uses Spur's in-place swap when sizes match; the kernel
  deliberately pairs different sizes so it measures the forwarder path.
- No forwarding of classes, methods, method dicts, symbols, byte arrays or
  the three constants, in all variants.
- Build configurations: `-O` (whole module) and `-O` plus LLVM
  `-align-all-nofallthru-blocks=5` (`align32`), both reported.

## Addendum: changes forced by the tests (written after implementation)

- **Method-dictionary hash = the symbol's id** (its slot 0), not
  `selector >> 3`. With address hashing every compaction in A/C moved
  symbols and broke every method dictionary (`doesNotUnderstand` in the
  compaction test). B's oops are stable, so its address hash would have
  survived; it uses the id hash too so the variants run the same lookup.
- **A/C flush every worker's lookup cache after compaction.** Its keys
  (selectors) and values (methods) are addresses. B's cache survives a
  compaction unchanged.
- **Cache index shift** is 3 in A/C and 4 in B (`selShift`), because B's oops
  are multiples of 16 and a shift of 3 would leave half the cache unused.
- **Primitive calls flush `pc` and `hdr`** to the worker (two stores) and
  check the worker's `moved` flag afterwards (one load), so a worker that
  parks inside an allocation in a primitive can be resynchronised after a
  compaction. Same code in every variant.
