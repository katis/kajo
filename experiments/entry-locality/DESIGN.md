# Experiment: entry locality, and what the table costs the marker

## Question

`experiments/device-measurement/` found the object table's one bad regime
on the iPhone 17 Pro: a single thread chasing pointers through a structure
of about 100 MB or more pays 4.4x for the `walk` kernel and 7.4x per hop
(522 ns against 70 ns for direct pointers). Below about 50 MB per thread
it pays 1.1 to 1.3x. On the Mac the per-hop cost is 2.0x at every size.
ADR 0003 stays proposed until this is understood and either fixed or
accepted. This experiment asks:

1. **What is the phone's memory hierarchy doing?** A hop through the table
   is two dependent misses (entry, then body) where direct pointers take
   one. Two misses explain 2x, not 7x. Characterise the device with a
   synthetic dependent-load chase so that the 7x has an explanation in
   terms of cache and translation reach, and so that any layout's best case
   can be predicted before it is built.
2. **Does entry locality close the gap?** If the entry and the body share a
   page, a hop costs one translation and two cache lines instead of two
   translations. Build a table layout where entries live in the same block
   as the bodies they point to, and measure it against today's table and
   against direct pointers, on the Mac and on the phone.
3. **What does the table cost the marker?** The marker is the program that
   does this traversal on every cycle. Measure a stop-the-world mark of a
   200 MB graph with direct pointers, with today's table, and with the local
   layout, on the phone at user-initiated QoS, one thread. This separates
   the table's cost from the QoS effect that the device run could not.
4. **Recommendation for ADR 0003.** Accept the table as is, accept it with
   the local layout, or revise toward heap offsets (C).

## Starting point

Do not modify earlier experiments. `experiments/object-representation/`
has the three object memories A (direct pointers), B (table) and C (heap
offsets) under one interpreter, with the `walk` and `walkbuild` kernels and
a stop-the-world mark-sweep each. `experiments/device-measurement/` has the
iOS app pattern: xcodegen `project.yml`, team `BDN6M642M2`, one kernel per
launch over `devicectl` with stdout streamed and a results file in
Documents, thermal state and footprint on every line, cool-downs, a
repeated kernel at the end for drift. Copy what you need from both into
this experiment; symlinks per file as device-measurement did are fine.
Follow the Swift notes in `AGENTS.md`, in particular the device bullets:
thermal state on every line, compare only configurations run back to back,
QoS set deliberately, one launch per kernel.

Device: iPhone 17 Pro, UDID `00008150-001271502182401C`, iOS 27.0.1,
connected by cable, paired, trusted. Mac: M2 Max.

## Part 1: memory hierarchy characterisation

A Swift microbenchmark, no VM, run on both machines:

- **Chase.** A random cyclic permutation over N 64-byte nodes; follow it
  for M hops; report ns per hop. N from 1 MB to 1 GB of working set in
  powers of two. This is the direct-pointer hop.
- **Double chase.** Two arrays: an index array (16-byte entries, like the
  table) and a node array. Each hop reads the entry, then the node it names.
  Three placements: entries in a separate region (today's table); entries in
  the same 16 KiB page as their nodes (the local layout); entries in a
  separate region but with the node array half the size (to separate "two
  misses" from "more memory touched").
- Vary the page footprint independently of the byte footprint: nodes
  spread one per page against packed, to tell translation reach from cache
  reach.
- 1 thread, then 2 and 6 on the phone (8 on the Mac), each thread its own
  arrays, to reproduce the per-thread size effect the device run saw.
- Report ns per hop against working set as tables, and name the knees: the
  working set where single-chase cost steps up (L2, system cache, TLB
  reach) on each machine, and where double chase departs from 2x single.
  If the phone has a knee between 50 and 100 MB that explains 7x, say so
  with the numbers. Performance counters are not available on the device;
  Instruments' CPU Counters template is, if you can drive it unattended,
  but do not spend long on it.

## Part 2: a local table layout (variant L)

Build **L** as a fourth object memory beside A, B and C, derived from B:

- Entries live inside the block of their body at allocation time. A block
  (use 16 KiB, the iOS page size, or justify another size) holds an entry
  area growing down from the top and a body area growing up from the
  bottom; allocation of an object takes one entry and one body from the
  same block, and the block is full when they meet. Oop = entry address
  offset, exactly as in B; the oop stays stable for life. After compaction
  moves a body to another block, its entry stays where it was, so locality
  degrades for moved objects. Measure how much, by running `walk` after a
  compaction that moves everything.
- Entry index space is sparse (block index times maximum entries per
  block plus slot). Side tables indexed by entry index are sized for the
  maximum; state the memory cost.
- Everything else as B: free entry runs per worker (now per block), mark
  bits in the entry header, the backref, become, compaction, snapshot.
- Report L's footprint against B's and A's on `walk`.
- Tests: all of B's tests pass on L, plus a test that an entry and its body
  share a page at allocation, plus the ThreadSanitizer run.

## Part 3: measurements

On both machines, 5 interleaved runs, medians, thermal state logged on the
phone with cool-downs between kernels:

- **walk and walkbuild** on A, B, C, L at 1 worker, with the per-thread
  graph size swept: 25, 50, 100, 200 MB of A-bytes. Report per-hop cost
  (walk minus walkbuild, divided by hops) for each variant and size, and
  B/A, L/A, C/A. This is the table that decides.
- **walk after compaction** on L and B at 100 and 200 MB: build, compact
  everything, traverse. L/B tells what the degraded layout costs.
- **sends and ivars** on A, B, L at 1 and 6 workers, to check L costs
  nothing on ordinary code.
- **Mark rate.** A stop-the-world mark of the `walk` graph at 100 and 200
  MB on A, B, L: milliseconds and MB of live data per second, one marker
  thread at user-initiated QoS, phone and Mac. If the harness allows, also
  the time of the compaction pass.
- Phone against Mac for every row, as device-measurement did.

## RESULTS.md must contain

- Answers to the four questions with numbers.
- Part 1's knee table for both machines and the explanation of the 7x, or
  an explicit statement that the data do not explain it.
- The per-hop table against size for A, B, C, L on both machines.
- L's footprint and the cost of degraded locality after compaction.
- The mark-rate table.
- What L's layout costs in complexity: block sizing, sparse index space,
  entry runs per block, anything that got harder in compaction or snapshot.
- Thermal drift of the phone runs.
- A recommendation paragraph for ADR 0003 with one of: accept B, accept
  with L, revise to C; and the conditions.
- Honest notes and deviations.

## Layout

```
experiments/entry-locality/
  DESIGN.md
  SPEC.md           L's layout and the microbenchmark definitions
  swift/            package: Kasm, VMA, VMB, VMC (symlinked), VML, memchase,
                    el-bench
  app/              iOS app, from device-measurement's pattern
  kernels/          walk variants with sizes; others symlinked
  bench.sh          Mac matrix
  bench-device.sh   phone matrix
  report.py
  results/
  RESULTS.md
```

## Non-goals

- Changing the concurrent collector VM (`concurrent-young`). If L wins,
  porting the layout there is the next experiment, not this one.
- Prefetching schemes or header caching beyond what B already does.
- Hardware counters beyond what can be had cheaply.
