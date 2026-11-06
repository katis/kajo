# ADR 0003: Object representation

Date: 2026-11-01
Status: accepted (2026-11-02, after experiments/entry-locality)

## Context

An oop must refer to its object somehow, and the choice shapes the garbage
collector, the image format, live development (`become:`, reshaping classes
with live instances, instance enumeration), and how shells and development
tools hold references to VM objects. Three candidates were built from the
Swift VM slice and measured; see `experiments/object-representation/RESULTS.md`.

- **A. Direct pointers with forwarders.** Spur's approach. `become:` leaves a
  forwarder that is followed lazily and cleaned up by the GC.
- **B. Object table.** oop is an offset into a table; the entry holds the body
  offset and the header word, so a send still fetches the class in one load.
  Per-worker entry chunks avoid the global allocation lock Smalltalk-2026 hit.
- **C. Direct heap offsets.** A on top of a base register. Zero relocation at
  image load, otherwise identical to A.

## What was measured

| | A direct | B table | C offsets |
|---|---|---|---|
| arith, ivars, alloc, fib (vs A) | 1.00 | 1.00 to 1.02 | 1.00 |
| sends (vs A) | 1.00 | 1.05 | 1.00 |
| walk, cache-defeating pointer chase (vs A) | 1.00 | 1.45 (traversal alone 2.0) | 1.00 |
| scaling 1 to 8 workers | same | same | same |
| overhead per object | 8 B | 24 B | 8 B |
| peak RSS on walk | 167 MB | 231 MB | 167 MB |
| reshape pause, 1M instances | 13.4 ms + 8.7 ms GC cleanup | 8.9 ms | as A |
| compaction pause, 32 MB live | 26 ms, 2.1M slots rewritten | 15.6 ms, 0 slots | as A |
| two-way become inside pause | 3.3 us | 0.2 us | as A |
| bulk one-way become, 100k objects | 2.0 ms + 1.7 ms GC | 6.4 ms (full scan) | as A |
| snapshot load relocation | 8.4M words | 0 | 0 |
| sites outside the object memory that know the mechanism | 4, plus a "never forward these" rule | 0 | as A |

Stopping the world dominated every two-way become in all variants, about
35 us with seven busy workers.

## Decision

Use an **object table** (variant B): oops are table offsets, entries hold the
body offset and the header word, entries are allocated from per-worker chunks.

## Reasons

- **Oops never change.** Nothing outside the object memory ever learns that
  an object moved: no lookup cache, dictionary, host-side reference or
  development-protocol identifier has to be fixed. Variant A leaked this
  concern into four places, and the experiment found two of them only
  through a test that the benchmark kernel passed with both broken. Live,
  image-based development is Kajo's first principle, and it needs exactly
  the operations that stable identity makes trivial.
- **Shells and tools need handles anyway.** A SwiftUI shell or a remote
  development tool holding a reference to a VM object needs a stable
  identifier under any moving collector. With direct pointers that means
  building a handle table beside the heap. The object table is that table.
- **Shorter pauses now, concurrent compaction later.** Compaction and
  reshape pauses were 40 and 34 percent shorter, with no slot rewriting. More
  importantly, the table gives each object one word in which a move can be
  published atomically, which makes concurrent compaction tractable. With
  direct pointers it needs a read barrier or forwarder check on every access,
  which is the hot-path cost this design kept off the hot path. Smooth
  scrolling on iOS will eventually require a collector whose pauses fit in a
  frame, and the table is the easier road there.
- **Measured cost is bounded.** Zero when entries are cached, 2 to 6 percent
  on send-heavy code, and 16 bytes per object. The one bad case is a
  cache-defeating pointer chase at 1.45 to 2x.

## Costs accepted

- 16 extra bytes per object and about 38 percent more RSS on object-heavy
  heaps. On a phone this is the cost that matters most.
- Cache-missing traversals of large linked structures run up to 2x slower.
  iOS devices have smaller caches than the M2 Max this was measured on, so
  the gap there is likely wider, not narrower. This must be measured on a
  device before this ADR moves to accepted.
- Two allocators with separate exhaustion paths, and the table itself must
  be swept and eventually grown at a safepoint.
- One-way bulk `becomeForward:` still needs a full scan to preserve identity,
  so it is slower than with forwarders. It is rare.
- The interpreter needs two live base registers, which showed up as stack
  reloads in the send path on arm64.

## Alternatives rejected

- **A, direct pointers with forwarders.** Fastest on pointer chasing and
  smallest, but address-valued oops leak into caches, dictionaries and host
  tables once objects move, and concurrent moving needs a hot-path barrier.
- **C, heap offsets.** Removes snapshot relocation for free and otherwise
  behaves exactly like A, with all of A's leaks. If the table's memory cost
  proves unacceptable on devices, C is the fallback, not A.

## Consequences

- The object memory module owns the table, entry allocation, and body
  allocation, and exposes oops that are opaque offsets. No other module may
  compute a body address.
- A generational collector will want a separate entry region for the nursery
  that can be reset in bulk, or entry allocation becomes the bottleneck the
  per-worker chunks avoided.
- The first thing to build after the object memory is a device benchmark of
  the walk and sends kernels on an iPhone, to confirm or revise this ADR.

## Device measurement (2026-11-02)

`experiments/device-measurement/` ran the three object memories on an
iPhone 17 Pro (iOS 27.0.1, 2 performance and 4 efficiency cores). See its
RESULTS.md.

| kernel | workers | table / direct, phone | table / direct, Mac |
|---|--:|--:|--:|
| walk | 1 | 4.42 | 1.46 |
| walk, traversal only | 1 | 7.65 | 2.02 |
| walk | 6 (Mac 8) | 1.12 | 1.43 |
| sends | 1 | 1.11 | 1.04 |
| ivars | 1 | 1.01 | 1.00 |
| footprint on walk | 1 | 1.38 | 1.38 |

The prediction "wider, not narrower" held, in one regime only. A single
thread chasing pointers through a structure of about 100 MB or more pays
4.4x for the kernel and 7.4x per hop (522 ns against 70 ns). Below about
50 MB per thread the table pays 1.1 to 1.3x, narrower than the Mac. The
cost follows the per-thread structure size, which points at the reach of
one core's address translation or cache with two pages touched per hop;
no performance counters were read, so that is a hypothesis. Ordinary code
and footprint match the Mac. Compaction and become pauses still favour the
table by a third, and ADRs 0006 to 0008 have since built the concurrent
collector on the entry switch.

Status stays proposed. The table is kept. Before acceptance, in order: the
concurrent marker's rate through the table against a direct-pointer marker
on a 200 MB old heap on device, since the marker is the program that does
this traversal every cycle and its QoS and the table are not yet separated;
entry locality (entries allocated in body order or per block) to see
whether the per-hop cost falls to the Mac's 2x; and a development-sized
image under a realistic single-threaded traversal. If locality closes the
gap, accept. If it does not and the marker pays the same 4x, revise toward
heap offsets (C): the table's memory cost was the expected risk on a phone,
its cache-reach cost is the one found.

## Entry locality and the marker (2026-11-02)

`experiments/entry-locality/` answered the three questions above on the same
iPhone and the Mac. See its RESULTS.md; every table is regenerated from the
raw lines in `results/`.

**The 7x is not cache or translation reach.** A chase microbenchmark without
the VM found the same translation reach on both machines (L1 TLB 2 to 4 MB
on the phone, 4 to 8 on the Mac; L2 TLB 48 MB on both; a page walk costs
12 to 14 ns past it on both) and no knee between 50 and 100 MB. A double
dependent miss costs 1.9 to 2.2 times a single one on both machines once
every core is busy. What the phone does have is two per-launch regimes for
a single latency-bound thread on an otherwise idle performance cluster: in
the slow one every dependent miss costs 2.5 to 4 times more. Table walks
fall into it far more often than direct-pointer walks (B in 4 of 8
launches, L in 8 of 8, A in 0 of 8 at 48 MB), and direct pointers are not
immune (A after a compaction ran 2.3 to 2.6 times its fresh cost). The P
cores were at 3.5 to 4.15 GHz with over 92 percent of CPU time on them in
every run; worker QoS and visiting order changed nothing. A companion thread
on the other P core that only spins removes the regime. The mechanism
inside the chip was not identified; no performance counters were read.

**Entry locality does not close the gap.** Variant L allocated 99.95
percent of entries in the 16 KiB page of their body and cost the same per
hop as the table as built: L/B 0.91 to 1.11 on both machines, before and
after a compaction that moved every live body away from its entry. It saved
11 percent of marking on the phone and nothing elsewhere, and it cost a
second non-moving arena for bodies over 4 KiB, a sparse entry index space
(side tables at 6.25 percent of the heap), and a compaction that cannot
free a block while any entry in it is live.

**The marker pays 1.8 to 2.0x, not 4x.** One thread at user-initiated QoS
marking a random graph: phone 271 / 141 MB/s (direct / table) at 128 MB
live and 211 / 120 at 256 MB; Mac 244 / 122 and 235 / 117.

| 1 worker, ns per cache-missing hop | phone, idle cluster | phone, other P core busy | Mac |
|---|--:|--:|--:|
| table / direct | 3.7 to 6.9 | 2.0 to 2.3 | 1.4 to 2.1 |
| table with local entries / table | 0.96 to 1.09 | 0.91 | 0.92 to 1.11 |
| marker, table / direct (time) | 1.76 to 1.91 | not measured | 2.00 |
| footprint, table / direct | 1.33 to 1.39 | | 1.39 |

**Decision: accepted, variant B as built, without L.** The ADR's own rule
was to accept if locality closed the gap and to revise toward heap offsets
(C) if it did not and the marker paid 4x. Neither branch applied: locality
buys nothing, and the marker pays the Mac's 2x. With the cluster awake the
table's per-hop cost on the phone is the Mac's. The costs accepted above
are revised to:

- 2x per cache-missing hop and 1.8 to 2.0x marking time against direct
  pointers. ADR 0006's old-space headroom must be sized for a marker at 120
  to 140 MB/s on one performance core over a random 200 MB graph.
- A single latency-bound thread on an idle P cluster can run 2.5 to 4 times
  slower per miss on the phone under any representation, and reaches that
  state more often through the table. `experiments/power` measured the
  regime's energy: it is **not** a power-saving state. In it the core runs
  at a higher clock (4.08 against 3.78 GHz) with half the IPC and spends
  1.4 to 1.5 times the CPU energy per hop as well as 2.7 times the time
  (309 against 205 nJ per hop, CPU energy only, DRAM not counted). A
  companion thread on the other P core in a `wfe` loop prevented it in 13 of
  13 launches for 0.3 W, at the same process energy per hop as the slow
  regime and 3.7 times the speed; a spinning companion costs 2.9 W, timers
  at 100 Hz to 10 kHz and a utility-QoS spin do not prevent it. The main
  thread running Smalltalk while every worker idles is the shape that hits
  it. Before the UI path relies on large traversals, measure a
  development-sized image traversed on the main thread on device, and decide
  whether the shell runs a `wfe` companion during such traversals or accepts
  the regime; measure DRAM energy first if it can be read, since it could
  change the sign.
- Revisit C only if that measurement shows table walks in the slow regime
  dominating real UI work, or if footprint (1.33 to 1.39x) becomes the limit
  on device.

## Device (9a) (2026-11-04)

Module 9a built the native shells (docs/modules/shells.md) and was to
re-measure the kernels on an iPhone 13 Pro (A15: 2 performance, 4
efficiency cores) inside the iOS shell, at 1, 2 and 6 workers, three runs.
The phone runs waited for the owner to sign Xcode in to team BDN6M642M2
and ran on 2026-11-04 (18:42 to 18:48, `scripts/shell-matrix.sh device`,
three runs interleaved, thermal nominal in the first and fair in the other
two). The same kernels ran in the macOS shell (Mac mini, M2 Pro, release,
through the app's own `Headless`). Every checksum is the published one at
one worker and identical across runs at two and six, on both machines:

| kernel (ms, median of 3) | Mac 1 worker | 2 | 6 | iPhone 13 Pro 1 worker | 2 | 6 |
|---|--:|--:|--:|--:|--:|--:|
| walk | 3620 | 1766 | 373 | 3710 | 2242 | 892 |
| sends | 2584 | 1312 | 444 | 2903 | 1737 | 902 |
| ivars | 1983 | 1002 | 339 | 2147 | 1368 | 683 |
| alloc | 2956 | 1527 | 550 | 3544 | 2336 | 1588 |
| fib | 1697 | 860 | 292 | 1874 | 1080 | 602 |
| Smalltalk sends | 2307 | 1160 | 388 | 2523 | 1610 | 795 |

Ranges on the phone (shells.md): walk 3542 to 3715 at one worker, 1873 to
2355 at two, 844 to 948 at six; alloc at two 2029 to 2543.

These are the M2 Pro's numbers in an app, within 1.5 percent of `kajo run`
on the same machine (module 8c's table); they say the shell adds nothing
to a kernel, not what the table costs on the A15. On the A15, at one
worker, walk (the cache-missing hop through the table) is 1.02 times the
M2 Pro's time while the compute kernels are 1.06 to 1.12 and alloc 1.20:
the table's hops cost the 13 Pro relatively less than its other work, not
more. walk's three one-worker launches (3542 to 3715 ms) show no second,
slow regime. At six workers walk scales 4.2x from one worker (fib 3.1x,
alloc 2.2x) on two performance and four efficiency cores. These are whole
kernels, not a direct-pointer A/B: the 2x per hop and 1.8 to 2x marking
were not re-measured on the A15. The decision above (accepted, variant B)
stands on the iPhone 17 Pro measurements; nothing on the 13 Pro
contradicts it.

Measured (iPad, 2026-11-06): the iPad Pro 12.9-inch 3rd generation (A12X,
4 performance and 4 efficiency cores), the same scripts and kernels, three
runs, every checksum the published one (docs/modules/shells.md): walk
5452, 2821, 999 ms at 1, 2 and 6 workers; sends 3683, 1941, 952; ivars
2661, 1460, 697; alloc 5731, 3078, 1617; fib 2622, 1384, 670; Smalltalk
sends 3078, 1621, 783. At one worker walk is 1.47 times the A15's time
and the compute kernels 1.24 to 1.40 (alloc 1.62): on the A12X the
table's hop costs relatively more than on the A15, about as much as
closures (1.47); walk scales 5.5x to six workers on four performance
cores. One of walk's three one-worker launches was 15 percent slower
(6248 against 5446 and 5452). Still whole kernels, not a direct-pointer
A/B.

## Built (10): large objects (2026-11-05)

Module 10 (docs/modules/large-objects.md) lifts module 1's "bodies never
span blocks". An object whose body does not fit one 32 KiB block (more
than 4095 slots or 32 760 bytes) gets a **run** of contiguous blocks it
owns alone, up to the header's count field (16 777 215 slots, 128 MiB, or
16 777 215 bytes). The layout is the ordinary one: the entry holds the
state word and the header, the body's first word is the back reference
(entry index, size in words; 32 bits of words hold 128 MiB), slots or
bytes follow. What is new lies beside the table, not in it: a **side
table** of block kinds (ordinary, head, continuation), the head's `used`
being the body's bytes and each continuation's 0, so a reader that walks
a block from its start to its `used` walks a run's one body. No header bit
marks a large object (bit 51 stays reserved): the count says it, and no
hot path asks. Loads, stores, the barriers, become and the class's format
go through the entry as before, so the interpreter and the allocation fast
path are unchanged instruction for instruction (the disassembly diff in
the module doc). The snapshot saves each block's kind in the high byte of
its used word (module 1's snapshot version 4, image format 5); the loader
checks every run before the heap verifier runs. One cost is new: a large
object's slots are one body, so a remembered large object is scanned
whole by a scavenge (no card table), and the stop-the-world collector
marks it whole; the concurrent marker scans it in chunks of 4096 slots.
