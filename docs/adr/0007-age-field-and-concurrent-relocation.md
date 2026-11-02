# ADR 0007: Age field with survivor spaces, and concurrent relocation of old space

Date: 2026-11-01
Status: proposed

## Context

ADR 0006 left two problems. Promotion on first survival made the allocation
storm promote 1.5 GB/s into old space, which no marker keeps up with without
large headroom. And old space was never compacted, so scattered long-lived
objects could pin blocks and make footprint grow without bound. The object
table (ADR 0003) makes relocation unusually cheap in principle: every
reference goes through an entry, so moving a body changes one word and no
pointer in the heap. `experiments/concurrent-relocation/` tested both on the
concurrent-marking VM. See its RESULTS.md.

## What was measured

Allocation storm, 8 workers, promotion into old space, fallbacks summed over
5 headless runs:

| nursery | N | promoted MB/s | fallbacks |
|---|--:|--:|--:|
| 4 MiB | 1 | 1490 | 64 |
| 4 MiB | 2 | 1206 | 42 |
| 4 MiB | 4 | 1202 | 48 |
| 16 MiB | 1 | 554 | 0 |
| 16 MiB | 2 | 78 | 0 |

At 4 MiB nearly all of what still promotes is survivor overflow: the live
set per worker at a scavenge is about 3 MB against a 512 KiB survivor half.
Growing the halves inside the same 4 MiB makes it worse because eden
shrinks. The 16 MiB nursery pays with a scavenge p50 of 4.7 ms against 3.2.
Copying survivors twice lengthens scavenge tails, not medians: p99 2.3 to
4.9 ms on the survivor kernel. Scanning survivor spaces as roots adds up to
1.3 ms to the initial mark with 8 workers.

Concurrent relocation: 45 runs per kernel and worker count across 9
configurations, every checksum equal to stop-the-world, including a
configuration that copies every live block in every cycle while mutators
rewire the heap. Conflicts were rare: at most 53 redone stores and 107
hazard skips per 5 runs that moved 40 million objects, mutator spins while
an object was mid-copy under 0.01 ms, none on the main thread.

Post-store check cost, with the check against a build that compiles it out:

| kernel | 1 worker | 8 workers |
|---|---|---|
| SmallInteger stores, L1-hot | 1.00 to 1.01 | 1.02 |
| ivars, sends, fib, arith | 0.98 to 1.03 | 0.98 to 1.01 |
| random pointer stores into a large heap | 1.10 to 1.13 | 1.05 to 1.07 |

Footprint on the fragmentation kernel, 5 percent of objects kept at
scattered addresses: old space ends at 230 MB without relocation, 87 MB with
one relocating cycle, 17 MB with relocation every cycle, for 12 to 16 MB of
live data. In the app, 392 MB against 92 MB after 10 s.

Frames missed of 1200 at 120 Hz, median of three runs:

| scenario | missed | fallbacks |
|---|--:|--:|
| storm, ADR 0006 configuration | 15 | 100 |
| storm, N = 2 | 0 | 44 |
| storm, N = 2 plus relocation at 50 percent | 1 | 58 |
| storm, N = 2, relocation, main-thread allocation | 4 | 42 |
| 256 MiB mutating heap, every live block relocated every cycle | 0 | 0 |
| fragmentation, with / without relocation | 16 / 10 | 0 |

The 256 MiB scenario moved 10 GB in 10 s with a final mark of 0.13 ms p50.
The fragmentation misses are 6 to 22 ms scavenges of a ring of kept objects,
the same with or without relocation.

## Decision

- **An age field in the entry header and two survivor halves per worker
  nursery.** Objects promote after N survivals or on survivor overflow. N is
  2; the lever that matters is nursery size, which must be sized to the
  live set per worker at a scavenge, not to the promotion count.
- **Old space is relocated concurrently by the marker thread** after
  marking, before the sweep. The relocation set is chosen by live bytes per
  block. The entry's offset word is the single switch point, with a
  RELOCATING state that still leads to the intact old body.
- **Three rules make it sound, each with a test that fails without it:**
  a post-store check on every heap store that redoes the store if the
  target moved under it; permanent pins for objects the interpreter holds
  raw pointers into (bytecodes and literal frames, and the never-relocate
  classes) plus pins for running frames; and per-worker hazard slots for
  primitives that hold a body pointer across a loop. Evacuated blocks are
  freed by epoch, after every worker has passed a safepoint.
- **Survivor spaces are scanned as roots at the initial mark.** ADR 0006's
  "nothing is young at the snapshot" no longer holds once survivors exist;
  the verifier shows the old object reachable only through a dead survivor
  being missed without this scan.
- **Policy is decided on footprint alone.** The mechanism can move a whole
  256 MiB heap every cycle without dropping a frame at a 5 to 14 percent
  mutator cost, so how much to relocate is a tuning question, not a
  correctness one. Relocating sparse blocks is enough to stop scattered
  garbage from pinning memory.

## Costs and conditions

- The post-store check is free on cache-hot stores and costs a memory
  latency on cache-missing ones, 5 to 13 percent on a pointer-rewiring
  kernel. A cheaper protocol (pre-store relaxed check with a relocator
  handshake, or skipping recently written blocks) is the obvious next thing
  to measure.
- The RELOCATING state is implemented by mapping the heap twice and storing
  the state in bit 32 of the offset, so reads need no mask or branch. It
  costs address space and has not been tried on iOS. ThreadSanitizer cannot
  see that an access through the alias and one through the base hit the
  same memory; that part of the protocol is covered by tests and the
  ordering argument only.
- Scavenges are now what drops frames: 3 to 5 ms under the storm, 6 to 22
  ms on the fragmentation ring, 4.7 ms p50 with a 16 MiB nursery. Old-space
  work no longer appears in the frame budget.
- This VM runs the storm a few percent slower than the ADR 0006 VM at N = 1,
  which moves fallback counts noticeably. The cause is unattributed beyond
  the new scavenge and marking bookkeeping.
- Only one of 29 primitives needed a hazard slot. The interpreter caches raw
  body pointers in two places only, both into permanently pinned objects.

## Lessons recorded

- **The object table makes concurrent relocation almost free of machinery.**
  No forwarding pointers, no load barrier, no colored pointers: one atomic
  switch per object and a store check. 83 million objects moved in 10 s
  with no frame drop.
- **Survivor-space size decides whether an age field helps, not N.** Going
  from N = 2 to N = 4 changed nothing; going from 4 to 16 MiB cut promotion
  15x.
- **The age field broke three things that "nothing young after a scavenge"
  had made free:** the claim bit, the remembered set carrying holders across
  scavenges, and the marking snapshot. Every invariant that leaned on that
  phrase needed a test.
- **A failed store check must be one out-of-line call** that redoes the
  store and runs the barrier. The first version cost 58 percent on the
  store-heavy kernel through register pressure, then 1 percent.
- **Release/acquire is not enough for a post-store check.** The store and
  the following load of the state word must be seq_cst, or they can be
  reordered and the moved-under-us store is lost.

## Consequences

- ADR 0004's precondition holds more strongly: old-space collection and
  compaction are both off the frame budget. What remains is the scavenge.
- ADR 0006 is amended: the snapshot is taken at the end of a scavenge and
  survivor spaces are roots.
- Next collector work, in order of value: a cheaper store check or
  relocation policy that avoids hot blocks; concurrent or parallel root and
  survivor scanning through the scheduler; nursery and survivor sizing from
  observed survival; large objects outside the nursery.

## Built: the age field (module 4, 2026-11-02)

The age half is built in `Sources/KajoVM/Nursery/` (docs/modules/
nursery.md): age in header bits 57..59, claim tags in 62..63 alternating
per scavenge, the decision (survive with age + 1 and the winner's nursery
index, or promote with every young bit cleared) written by the claiming
CAS, survivors in the copying participant's survivor-to, overflow
promotion when it is full, remembered holders carried while they name a
survivor, promoted holders of survivors remembered, and promote-all before
every old-space operation. Every rule that "nothing is young after a
scavenge" used to cover has a test that fails with the rule switched off
(carried holders, promoted holders, the alternating tag).

Headless matrix (M2 Max, release, medians of five, 8 workers):

| kernel | nursery | N = 1 promoted MB/s | N = 2 promoted MB/s | N = 2 survived / overflow MB | p99 N = 1 / N = 2 |
|---|---|--:|--:|---|---|
| alloc | 4 MiB | 1320 | 913 | 168 / 477 | 3.90 / 3.99 ms |
| alloc | 16 MiB | 512 | 56 | 159 / 18 | 4.89 / 4.25 ms |
| survivors30 | 4 MiB | 511 | 478 | 72 / 80 | 1.55 / 2.43 ms |
| oldheap64 | 4 MiB | 576 | 552 | 94 / 98 | 2.46 / 2.39 ms |
| fragment | 4 MiB | 603 | 588 | 71 / 164 | 2.01 / 2.45 ms |

As the experiment found: at 4 MiB survivor overflow carries most of what
N = 2 still promotes, a 16 MiB nursery is what cuts promotion (alloc 913
to 56 MB/s), and copying survivors lengthens tails (survivors30 p99 1.55
to 2.43 ms). Full collections on alloc at 4 MiB fell from 32 to 16 per run.
Relocation (Part 2) is module 6.

## Model checked (2026-11-02)

`docs/models/relocation.md`, `cd models && swift test`. The relocation half is model checked before module 6 builds it: five claims
(no lost store, no stale read, no hazarded move, no premature free, nothing
RELOCATING at a pause) hold exhaustively for up to three mutators, and each
rule turned off finds its violation. The model found four things the SPEC
left to the code, which module 6's brief must state: `enterVM` stores epoch
0 before the current epoch; the relocator's scan of epoch words is seq_cst;
the relocator never parks between the CAS and the switch (to-space
allocation stays before the CAS); body addresses are always computed from
the offset just loaded. Both halves of the post-store check must be
seq_cst, each on its own.
