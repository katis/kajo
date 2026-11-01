# Spec: concurrent marking and lazy sweeping of old space

Written before the collector code. Everything not stated here is as in
`../generational-gc/SPEC.md` (nursery, parallel scavenge, remembered set,
entry chunks and bitmaps, stop protocol, pause accounting) and below that
`../ui-thread-scheduling/SPEC.md` and `../object-representation/SPEC.md`
variant B. Where DESIGN.md left a choice the simpler option is taken and
listed under "Choices"; where DESIGN.md's protocol is changed the change is
listed under "Changes to DESIGN.md's protocol" with the reason.

## Package shape

`swift/` is a copy of `../generational-gc/swift/`, renamed:

- `Kasm`: unchanged assembler; kernel lookup adds `oldheapN` (below).
- `VMC`: the VM (was `VMG`). New compile flag `NO_MARK_BARRIER` removes the
  SATB barrier from every site (the generational barrier stays). Such a
  build can only run the stop-the-world collector; asking it for
  concurrent marking is a fatal error. `NO_BARRIER` and `NO_BUDGET` are
  kept.
- `cm-bench`: `cm-bench kernel <name> <workers>` prints one `key=value`
  line.
- `kajo-ui`: the AppKit app, scenarios `C0`..`C6`.
- `VMCTests`: Swift Testing, headless, also under ThreadSanitizer.

Runtime switches (environment, read once at `Runtime` creation):

| variable | values | default |
|---|---|---|
| `KAJO_GC` | `stw` (full collections as in ADR 0005), `cm` (concurrent marking) | `cm` |
| `KAJO_CM_THRESHOLD` | old-space occupancy that starts a cycle, percent of the soft limit | 60 |
| `KAJO_CM_MARKERS` | marker threads, 1 or 2 | 1 |
| `KAJO_CM_FORCE` | 1: the barrier's marking flag is never cleared and a cycle starts at every scavenge while none is running (threshold 0) | 0 |
| `KAJO_VERIFY` | `cm`: compare mark sets at every final mark; `all`: also the inherited scavenge verifier | off |
| `KAJO_NURSERY_KB` | per-worker nursery | 4096 |
| `KAJO_HEAP_MB` | old-space soft limit | 64, or `2 * N + 64` for `oldheapN` |

## Side tables

All indexed by entry index (oop >> 4), beside the entry table, never in
the header word:

- **Mark map**: one byte per entry (16 MiB, `mmap`, lazily committed),
  accessed only as `Atomic<UInt8>`. 1 = marked in the current cycle.
  Invariant: outside a cycle every byte is 0. Set by markers and by the
  final-mark drain (exchange), read by the barrier and markers (relaxed
  load), cleared by the sweeper for live entries as it sweeps them (dead
  entries were never set). A fallback clears the map up to the table's
  high-water mark.
- **Snapshot bitmap**: one bit per entry (2 MiB). At the initial mark it
  becomes a copy of the `used` bitmap up to the high-water mark. A set bit
  means "this entry was an old object when marking started". Read-only
  until the next initial mark. Words above the high-water mark are never
  written and stay 0 (the mark is monotonic).
- **Snapshot block map**: one byte per old block, a copy of `inUse` at the
  initial mark. **Sweep-live block map**: one byte per block, written by
  the sweeper only.

The snapshot bitmap does three jobs, which is why it exists:

1. **Candidate filter.** The marker and the barrier consider an oop only if
   its snapshot bit is set. Anything else was allocated after the snapshot
   (young, or promoted during marking) and is black by construction. So
   neither the marker nor the barrier ever reads the header of a young
   object, whose header a mutator may be writing concurrently.
2. **Sweep set.** The sweeper frees exactly the snapshot entries that are
   unmarked at the final mark. Entries allocated after the snapshot are
   never swept by this cycle; that is "allocated black" without a store.
3. **Stability.** No snapshot entry is freed or reused before the sweep, so
   markers may read snapshot objects' headers and entries without racing.

## SATB barrier

Snapshot at the beginning (Yuasa deletion barrier). Incremental update was
not chosen because it records the *new* value stored into a black object,
so the final pause must rescan every root that may have been written since
marking began, which here means every Process stack (stacks are not
barriered) and grows with the number and depth of Processes. SATB scans the
stacks once, in the initial pause, and never again.

**Fast path**, before every store of a value into a pointer slot of a heap
object (the same sites as the generational barrier plus the VM-internal
stores of `nil` over a pointer, listed in RESULTS.md):

```
if w.marking != 0 { satbSlow(o, i) }   // one ldrb + cbnz; then the store,
store slot                              // then the generational barrier as before
```

`w.marking` is a byte in the worker's own `Worker` struct, written only by
a stopper with the world stopped.

**Slow path** (out of line, scalars passed):

```
if header(o) is young: return                // a holder created after the snapshot
old = slot(o, i)
if old is a SmallInteger or 0: return
if snapshot bit of old is 0: return          // allocated after the snapshot
if mark[old] != 0: return                    // already marked
push old onto w.satb                         // 512 oops; hand over when full
```

The holder test is in the slow path, not the fast path: with nothing young
at the snapshot, a young holder was created after it, and overwriting its
slots deletes no snapshot edge. (The first build had no holder test; the
slow path then ran for every store into a fresh object while marking, 15
million times in one `alloc` run.) In the literal-protocol test mode below
young holders exist at the snapshot, so the test is skipped there.

**Slot stores are atomic.** The marker reads slots of snapshot objects
while mutators write them. Every slot store (`OM.setSlot`) is a relaxed
atomic store and every marker slot read a relaxed atomic load; on arm64
both are plain `str`/`ldr`. Initialising stores into a fresh young object
stay plain (no marker can see a young object).

## SATB buffer protocol

- Each worker owns one buffer of 512 oops (`satbBuf`, `satbCount`).
- **Handover**: when a push finds the buffer full, the worker takes
  `cm.lock`, appends `(buffer, 512)` to the shared queue as an SATB item,
  takes a buffer from the free list (or `malloc`s one), signals the marker
  if one is waiting, and releases the lock. `cm.lock` is a leaf lock; it may
  be taken while holding `schedLock`.
- The marker takes items from the queue under `cm.lock`, processes each
  entry (snapshot bit set and `exchange(mark, 1) == 0` makes it grey), and
  returns the buffer to the free list.
- **Final mark** drains every worker's partial buffer and every queued
  item with the world stopped.
- At the **initial mark** every worker's buffer count is reset to 0 and the
  queue is emptied (in force mode the barrier runs between cycles and fills
  buffers with entries that mean nothing; the marker discards items that
  arrive while no cycle is marking).
- Volume is counted per worker: entries pushed, buffers handed over.

## Grey set and markers

- Each marker has a local stack (raw memory, growable). Grey = marked and on
  some stack or in some queued packet.
- The shared queue (under `cm.lock`) holds two kinds of items: SATB buffers
  (entries are candidates, not yet marked) and grey packets of up to 256
  oops (already marked, to be scanned).
- **Tracing** an object: relaxed-load its header (stable: a snapshot
  object), then for each slot (relaxed atomic load) a value `v` that is a
  pointer with its snapshot bit set and `exchange(mark[v], 1) == 0` is
  pushed. Byte objects are marked, not scanned. Marked bytes and objects are
  counted.
- **Two markers** (option): a marker whose stack holds at least 64 oops
  exports the bottom half (up to 256) as a grey packet when the other
  marker is idle and no packet is queued.
- **Markers are VM participants.** A marker counts as active in the stop
  protocol while it works (`enterVM`), polls `gcRequested` every 128 traced
  objects and between queue items, and parks without joining the scavenge
  (markers have no nursery and take no copy tasks). So no marker runs during
  any pause, and nothing the scavenge moves is ever read by a marker. While
  it has nothing to do a marker leaves the VM and waits on `cm.cond` (1 ms
  timeout).
- **Termination.** A marker that finds its stack and the queue empty
  becomes idle; when every marker is idle it requests the final mark as its
  own stop (the marker is the stopper). Partial SATB buffers still held by
  mutators are drained in that pause.
- Marker threads are pthreads with QoS `utility` (workers inherit the
  default). Per-thread CPU time (`CLOCK_THREAD_CPUTIME_ID`) is measured
  around every work period; core placement is not observable from user
  space on macOS, so CPU time and wall time are reported instead.

## Phases

The cycle state (`cm.phase`: idle, marking, sweeping, swept; `cm.cycle`,
incremented at every initial mark and abort) changes only with the world
stopped, except sweeping -> swept, which the sweeper stores when done.

### 1. Initial mark (piggybacked on a scavenge)

At the end of a scavenge pause (so nothing is young), when the phase is
idle and old space holds at least `threshold` of its soft limit (or in
force mode, always):

1. retire every promotion TLAB (no object is ever appended to a snapshot
   block again);
2. copy the `used` bitmap into the snapshot bitmap (words below the
   high-water mark) and `inUse` into the snapshot block map;
3. `phase = marking`, `cycle += 1`, every worker's `marking = 1`, SATB
   buffers and the queue reset;
4. scan the roots, exactly the full collector's root set: symbol and host
   roots, globals, special selectors, class table, ready-queue heads and
   tails, the pending-root table (every Semaphore with an outstanding
   external signal; native events hold no oops), every live Process
   record's process oop and its stack from the base to the saved or
   flushed `sp`. The remembered set is not a root. Every root word naming
   a snapshot entry is marked and appended to a grey packet;
5. queue the packets, wake the markers.

Recorded: the whole pause, its scavenge part (as in ADR 0005) and the
initial-mark part split into snapshot copy and root scan, plus ttsp
(stopping) separately from work.

### 2. Concurrent mark

Markers drain the queue as above. Only snapshot objects are traced; young
objects and objects promoted during marking are ignored.

### 3. Scavenges during marking

Unchanged scavenges. Promoted objects are not in the snapshot, so they are
black without any store, and their slots are never traced. This is sound
because the snapshot was taken with nothing young (step 1 above): every
object reachable when marking started is a snapshot object, and every
object created since can only hold references to snapshot objects (which
SATB keeps) or to other new objects. See "Changes to DESIGN.md's protocol".

### 4. Final mark (its own pause)

Requested by the marker that found no work left. With the world stopped:

1. every worker's `marking = 0` (force mode: stays 1);
2. drain to completion, single-threaded by the stopper: every worker's
   partial SATB buffer, every queued item, every marker's local stack;
3. filter the remembered buffers: a remembered holder that is a snapshot
   entry and unmarked is dead and about to be freed; it is removed and its
   remembered byte cleared (otherwise the next scavenge would scan a freed
   entry);
4. verifier (if on, see below; its time is reported separately);
5. `phase = sweeping`, wake marker 0.

Recorded: the whole pause, ttsp, drain time, entries and objects drained,
filter time, verifier time.

### 5. Lazy sweep (background, marker 0)

With the phase sweeping, marker 0 walks the snapshot bitmap chunk by chunk
inside the VM (polling between chunks):

```
for each word with snapshot bits s:
   for each bit: if mark[e] != 0 { mark[e] = 0; live += size; sweepLive[block of body] = 1 }
                 else dead |= bit
   if dead != 0 { used[word].fetch_and(~dead); freed += popcount(dead); chunk had frees }
```

Then `phase = swept`. Nothing is published to allocators yet: the next
stop of any kind (scavenge, final mark, full) **applies** the result before
its own work, with the world already stopped: every snapshot block without
a live object is freed (`inUse = 0`), the free-block list is rebuilt, the
chunks that gained free entries are added to the chunk pool (deduplicated),
and the phase becomes idle. The apply time is recorded in that pause.

Allocation never waits for a block to be swept: mutators allocate young,
promotion uses the promotion reserve, and a block becomes allocatable only
when the apply publishes it. Whether that is late enough to hurt shows up
as fallbacks, which are counted.

`used` words are accessed atomically outside pauses: workers take a word
with `exchange(~0)` (was a load and a store), the sweeper clears bits with
`fetch_and`. A bit the sweeper clears in a word a worker holds is simply
free again; the worker never owned it.

## Triggers and fallback

- After every scavenge in `cm` mode: if the phase is swept, apply first
  (above). Then, if the phase is idle and blocks in use >= threshold x soft
  limit, run the initial mark in the same pause.
- **Fallback**: if a scavenge leaves more than the soft limit in use while
  a cycle is running (marking, sweeping or swept but not applied), or while
  idle (a single scavenge jumped past the threshold and the limit), a
  stop-the-world full collection is due: in its own pause 1 ms later
  (`KAJO_FULL_DELAY_US`), as ADR 0005 does, or in the same pause if old
  space is more than a quarter of the promotion reserve above the limit.
  The full collection aborts the cycle (`phase = idle`, `cycle += 1`,
  marking flags off, buffers and queue discarded, mark map cleared, markers
  drop their stacks when they wake), then runs the inherited scavenge plus
  mark-sweep. Every fallback is counted, logged with its pause, and
  printed to stderr.
- `stw` mode is exactly ADR 0005: full collection requested one scavenge
  early when the next would cross the soft limit, own pause 1 ms later.

## Verifier

`KAJO_VERIFY=cm` (tests: always): at every final mark, after the drain, a
from-scratch stop-the-world traversal from the roots through every object
(young and old) records the reachable set in a side bitmap. Then for every
snapshot entry:

- reachable and unmarked: **missed** (a collector bug), counted in
  `verifyFailures` and printed;
- marked and unreachable: floating garbage, counted and summed in bytes.

The inherited scavenge verifier (`KAJO_VERIFY=all`, tests: always) keeps
checking after every scavenge that no used entry names a free one and that
the remembered-set invariant holds; it skips entries that are pending-dead
(snapshot bit set, unmarked, sweep not yet applied), which may name
entries the sweeper already freed.

## Test-only protocol switches

So that the tests can show what each rule buys, `CMConfig` has switches
that are never used outside tests:

- `satb = false`: the slow path returns immediately.
- `literal = true`: DESIGN.md's protocol as written: the initial mark does
  not scavenge first (the snapshot is `used` minus the young-log bits, so
  young objects exist at the snapshot), and every object promoted while
  marking is pushed grey (tagged, so a marker scans it even though it is
  not a snapshot entry). `literalGrey = false` drops that push.
- `manual = true`: no marker threads; the test drives marking (`cmStart`,
  `cmMark(n)`, `cmFinal`, `cmSweep`) from its own thread, interleaved with
  Smalltalk run on chosen workers.

## Changes to DESIGN.md's protocol

- **The initial mark is taken at the end of a scavenge**, not in a pause of
  its own. DESIGN.md's initial mark leaves young objects alive at the
  snapshot and greys promoted objects later. That loses objects: a young
  object `Y` alive at the snapshot holds the only reference to an old `O`;
  the mutator copies `O` into an already scanned (black) old object over a
  `nil` (no SATB record) and then drops `Y`; `Y` dies in the next
  scavenge, is never promoted, so never greyed, and `O` is swept while
  reachable. Young objects at the snapshot are part of the snapshot graph,
  and their death deletes edges without any barrier. Taking the snapshot
  when nothing is young removes the case, and it costs nothing extra when
  the initial mark rides on a scavenge that was happening anyway. A test
  reproduces the loss in the literal mode.
- **Promoted objects are black, not grey.** With nothing young at the
  snapshot, an object promoted during marking was created after the
  snapshot and can only reference snapshot objects (kept by SATB) or newer
  ones. They need no scan; the snapshot bitmap makes them black for free.
  The literal mode keeps the grey rule for the tests.

## Kernels

From earlier experiments, read in place: `arith`, `fib`, `sends`, `alloc`
(`../vm-language-bench/kernels/`), `ivars`
(`../object-representation/kernels/`), `churn`, `survivors.kasm`,
`gclib.kasm`, `gcui.kasm` (`../generational-gc/kernels/`), `lib.kasm`,
`ui.kasm` (`../ui-thread-scheduling/kernels/`). New in `kernels/`:

**`oldheapN`** (`oldheap.kasm` plus generated methods answering N, the
iteration count and the replacement interval):

| parameter | value |
|---|---|
| node | Array of 14 slots: slot 1 links to a node of the same group, slot 2 a SmallInteger, 120-byte body |
| group | Array of 256 nodes, linked in a ring at first; 32 776 bytes of bodies |
| live size | N x 32 groups in total (N MiB of bodies plus spines), split between workers |
| spine | per worker, Arrays of 256 groups under one Array |
| iterations | N x 250 000 in total, split between workers (every run replaces about twice the live data) |
| churn | one 2-slot `OHPoint` per iteration, read back and dropped |
| rewire | every 8th iteration: `(g at: a) at: 1 put: (g at: b)`, pseudo-random g, a, b (LCG) |
| replace | every 4096th iteration (headless; 32 768th in the app, "slowly mutating"): the oldest group (FIFO per worker) is replaced by a freshly built one |
| old space | soft limit `2 N + 64` MiB, so live data is 33 to 47 percent of it |
| checksum | churn sum plus, over every node, its link target's payload |

Groups are replaced oldest first so that garbage dies in roughly the order
it was promoted and whole blocks empty out; old space here reclaims only
whole blocks (no compaction, a non-goal). Rates (rewires and replaced bytes
per second) are measured and reported with each run.

## Headless matrix

Every kernel (`arith fib sends ivars alloc churn survivors5 survivors30
oldheap64 oldheap256 oldheap512`) x 1 and 8 workers x configurations, 5
interleaved runs, medians, 4 MiB nurseries:

| config | build | mode |
|---|---|---|
| `nomark` | `-DNO_MARK_BARRIER` | `stw` |
| `stw` | barrier | `stw` (the SATB fast path runs and never fires) |
| `cm` | barrier | `cm`, 1 marker |
| `cm2` | barrier | `cm`, 2 markers (oldheap kernels and alloc only) |
| `force` | barrier | `cm`, `KAJO_CM_FORCE=1` (marking on continuously) |

Old space 64 MiB except `oldheapN`. Alignment: compute kernels and `churn`
also run in an `align32` build (`-align-all-nofallthru-blocks=5`) of
`nomark` and `stw`, as the earlier experiments did.

Reported: wall time, cycles, fallbacks, initial-mark and final-mark pause
p50/p99/max (pooled over runs) with breakdowns, scavenge pauses, marking
duration, marker CPU time, sweep CPU time and duration, SATB entries and
buffers, promoted bytes during marking (headroom), floating garbage (only
with the verifier), old space in use at cycle start and after the apply,
peak RSS, mutation rates for oldheap.

## Scenarios

The AppKit app and its frame measurement as in ADR 0005's experiment; 7
background workers, UI Process handling 1000 events/s, 1 s warm-up (after
the old heap is built, for C3, C4, C6), 10 s measured, 3 runs, median run
by missed frames then max gap.

| id | load | GC |
|---|---|---|
| C0 | none | `cm` |
| C1 | `alloc` on 7 workers (G2 of ADR 0005) | `stw`, 64 MiB, 4 MiB nurseries |
| C2 | C1 | `cm` |
| C3 | `oldheap` 256 MiB live on 7 workers, mutating forever | `stw`, 576 MiB soft limit |
| C4 | C3 | `cm` |
| C5 | C2 + ~100 us of Point churn on the main thread after each event (G4) | `cm` |
| C6 | C4 | `cm`, 2 markers |

Reported per scenario: frames, missed, drops, max gap, worst run-loop
iteration with VM work, GC park and GC enter wait inside it (enter wait now
includes blocking on the safepoint mutex, which ADR 0005's runs counted as
VM time), every pause kind's distribution, cycles, fallbacks, marking
duration. One extra run of C4 and of C2 with `KAJO_VERIFY=cm`, reported
separately.

## Choices (where DESIGN.md left one open)

- Mark map: a byte map (one byte per entry), not a bitmap: a byte can be
  set with a plain atomic exchange and read with a plain `ldrb`.
- The sweeper is marker 0 in the background, not allocating workers.
- Sweep results are published at the next stop, not by lock-free pushes to
  the pools.
- Threshold 60 percent of the soft limit.
- One marker by default; two as an option.
- Final mark requested by the marker, as its own pause.
- The final mark does not scavenge.
- SATB buffers of 512 oops; grey packets of 256.
- `oldheap` replaces whole groups FIFO so garbage is block-coherent.
