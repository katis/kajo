# ADR 0003: Object representation

Date: 2026-11-01
Status: proposed

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
