# Experiment: object representation, direct pointers vs object table

## Question

How should a Kajo oop refer to its object? This decision shapes the GC, the
image format, and everything live development needs: `become:`, class
reshaping while instances exist, instance enumeration, pinning for FFI. It
also costs or saves a memory load on every field access and every send, and
Kajo runs interpreted on iOS where there is no JIT to hide that.

Smalltalk-2026 kept an object table and argues the trade inverts under
threads (`references/Smalltalk-2026/doc/MultiThreading.md`, section "Why
there is still an object table"), but also hit a global lock on every
allocation through it (`doc/SCALING.md`, "What perf said"). Spur, Pharo's
memory manager, dropped the table for direct pointers and handles `become:`
with forwarding objects that are followed lazily and cleaned up by the GC.
Both are prior art, not designs to copy.

We want numbers for Kajo's own interpreter design, in Swift, on this machine.

## Variants

Build from the Swift slice in `experiments/vm-language-bench/swift/`. Copy it;
do not modify the original. Follow the Swift notes in `AGENTS.md` (one opcode
per switch case, no ARC in hot paths, explicit trap opt-outs, be aware of
code alignment when comparing numbers).

### A. Direct pointers with forwarders

- oop = pointer to the body. Header word in the body, as in the slice.
- `become:` and one-way `becomeForward:` turn the old body into a
  **forwarder**: a distinguished format/class index whose first slot is the
  target oop. Forwarders are followed lazily. At minimum they must be caught:
  when fetching the receiver class for a send (follow, patch the stack slot,
  retry), in primitives that touch arguments' fields (`at:`, `at:put:`,
  `==` must compare followed oops), and by the GC, which during marking
  rewrites every slot that points to a forwarder to point at the target, and
  frees the forwarders. Frame stacks are scanned and fixed when the become
  happens. Count every site where a forwarder check had to be added; that
  count is a result.
- Class reshape (add an instance variable to a class with N instances):
  enumerate instances by heap walk, allocate new bodies, copy, one-way forward
  old to new.
- GC: the slice's non-moving mark-sweep, plus a **mark-compact** mode
  (sliding, Lisp-2 style: compute forwarding addresses, update every slot in
  every live object and every root, move bodies) so compaction cost can be
  compared. Kajo will eventually want a moving collector, so this is not
  optional.

### B. Object table

- oop = byte offset into the table, 8-byte aligned so the tag bit stays free.
  Entry = 16 bytes: body offset into the heap, and the header word (class
  index, size, format, mark). Putting the header in the entry means a send
  fetches the receiver class with one load, not two. Body = a one-word back
  reference to its entry, then the slots.
- Table is a fixed-size reservation (say 16M entries) for this experiment;
  note what growth at a safepoint would involve.
- Entry allocation: per-worker chunks of free entries, carved from a global
  free list under a lock or atomic, refilled rarely. The slice's TLAB logic,
  applied to entries. Smalltalk-2026's global lock on every allocation is the
  anti-pattern to avoid; measure scaling to confirm.
- `become:` = swap the two entries' contents. `becomeForward:` = copy one
  entry over the other and free the first. Both at a safepoint.
- Class reshape: enumerate instances by scanning the table (no heap walk),
  allocate new bodies, copy, repoint entries.
- GC: mark via entries, sweep bodies, and a **compaction** mode that slides
  bodies and updates each body's entry through the back reference. Free
  table entries are threaded back onto the free list.

### C. Direct pointers as heap offsets (compile-time flag on A)

Same as A but oop = byte offset from the heap base, so the body address is
`base + oop`. One add per dereference, zero relocation at image load. This
is a flag on A, not a third implementation. It must build and run every
kernel; its only distinct measurements are the kernels and snapshot load.

If time runs out, C is the variant to drop. Say so in RESULTS.md.

## Kernels

Reuse `arith`, `fib`, `sends`, `alloc` from `../vm-language-bench/kernels/`
unchanged, so the baseline is comparable to the previous experiment. Add:

1. **ivars**: a tight loop reading and writing instance variables of a
   handful of receivers that stay hot in cache. Best case for the table:
   entries are cached.
2. **walk**: build a graph of roughly four million small objects total,
   divided across workers, linked in a shuffled order so traversal defeats
   the prefetcher, then traverse it several times summing an instance
   variable. Worst case for the table: every hop is two dependent loads.
3. **become**: with about one million live objects in the heap, perform ten
   thousand two-way `become:`s between random pairs, then one
   `becomeForward:` of one hundred thousand objects at once. Report the time
   per two-way become, the total for the bulk forward, and in variant A the
   extra cost of the first GC that cleans up the forwarders.
4. **reshape**: a class with one million live instances gets an instance
   variable added. Report the stop-the-world duration and the total time
   until the heap is forwarder-free (A) or quiescent (B).
5. **compact**: allocate so that every other object dies, collect, then
   compact. Report mark time, sweep time, compaction time, bytes moved, and
   live bytes. For A also report what fraction of the compaction time was
   slot updating versus moving.
6. **snapshot**: save the heap (and table, for B) from the `walk` kernel to a
   file, then load it at a different base address and run one traversal to
   prove it works. Report save time, load time, and the relocation work in
   slots touched. Variant A must relocate every pointer slot. B and C should
   need no slot fixups; confirm that in the measurement, not by assertion.

Every kernel prints a checksum. Variants A, B and C must agree on every
checksum. Run every kernel at 1 and 8 workers except `become`, `reshape`,
`compact` and `snapshot`, which run with 1 worker doing the operation while
7 other workers run `fib` until they are stopped at the safepoint, so that
the measured pause is a real pause. Report the time workers spent parked.

Five runs each, median. Control code alignment as the previous experiment's
`align32` variant did, or report both aligned and unaligned so a placement
effect is not misread as a representation effect.

## Also measure and report

- Bytes of overhead per object in each variant and the peak RSS of `walk`.
- Scaling of allocation-heavy kernels to 8 workers, specifically whether
  entry allocation in B introduces contention. Count how often a worker
  refills its entry chunk.
- The dispatch loop assembly in each variant: does the extra indirection in
  B stay a single dependent load, and did the forwarder checks in A add
  branches to the send path?
- Lines of code per variant, and the number of sites where each variant's
  mechanism had to be known about outside the object memory module:
  forwarder checks in A, `body(oop)` indirections that could not be hidden
  in B. This is the "modules hide decisions" question made concrete.

## RESULTS.md must contain

1. Results tables: kernel × variant × workers → median ms and checksum
   agreement, plus the become, reshape, compact and snapshot tables with the
   fields listed above.
2. Memory overhead and RSS per variant.
3. Assembly verdicts for the send path and the field access path.
4. The leak counts: forwarder-check sites for A, indirection sites for B.
5. Honest notes on what was hard in each variant and what a generational or
   concurrent collector would need from each. Do not implement those; think
   about them in one paragraph each.
6. A recommendation paragraph for Kajo with its caveats. The decision itself
   is made in an ADR afterwards, not here.

## Layout

```
experiments/object-representation/
  DESIGN.md         this file
  SPEC.md           exact oop encodings, entry layout, forwarder format, kernel
                    parameters, safepoint protocol for become; written first
  kernels/          new .kasm kernels; the reused four are referenced, not copied
  swift/            one SwiftPM package: shared Kasm and kernel runner, one VM
                    module per variant (C as a flag on A), tests, bench executable
  bench.sh          builds and runs the matrix, prints the tables
  RESULTS.md
```

## Non-goals

Generational or concurrent GC, image format beyond a raw dump, a Smalltalk
compiler, blocks, process scheduler, UI, iOS device runs. Keep each variant's
object memory under about a thousand lines.
