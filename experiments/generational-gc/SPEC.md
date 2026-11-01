# Spec: a generational nursery on the object table VM

Written before the code. Everything not stated here is as in
`../ui-thread-scheduling/SPEC.md` (Processes, scheduler, budget, hop to
main, external signals, the AppKit app) and, below that,
`../object-representation/SPEC.md` variant B (object table, block heap,
TLABs, safepoints, bytecodes). Where DESIGN.md left a choice the simpler
option is taken and listed under "Choices".

## Package shape

`swift/` is a copy of `../ui-thread-scheduling/swift/`, renamed:

- `Kasm`: unchanged assembler; kernel lookup extended (below).
- `VMG`: the VM (was `VMP`). Compile flag `NO_BARRIER` removes the write
  barrier from every site and forces the nursery size to 0, so the
  collector runs non-generationally. `NO_BUDGET` is kept.
- `ggc-bench`: `ggc-bench kernel <name> <workers>` prints one `key=value`
  line. The nursery size comes from `KAJO_NURSERY_KB` (0 =
  non-generational; default 4096).
- `kajo-ui`: the AppKit app, scenarios `G0`..`G5` (below). The old S
  scenarios are removed.
- `VMGTests`: Swift Testing, headless, run also under ThreadSanitizer.

## Spaces

One `mmap` reservation, three regions, all addressed by byte offset from
the same base (so an entry's body offset works for every region):

```
| old blocks: soft limit S          | promotion reserve R | nurseries: 16 x N |
  0 .............................. S/32K ........ (S+R)/32K       (not blocks)
```

- **Old space**: the existing 32 KiB block heap and free-block pool. Its
  *soft* size `S` is the heap size parameter (64 MiB everywhere, as in the
  earlier experiments). Mutator allocation of old objects (non-generational
  mode only) refuses a block once `S` worth of blocks is in use and asks for
  a full collection, exactly as before. Promotion ignores the soft limit
  and may use the reserve `R = 16 x N`, which bounds the worst case (every
  young byte of every nursery survives), so a scavenge can never fail for
  lack of space. A scavenge that leaves more than `S` in use is followed in
  the same pause by a full collection. Old space never moves.
- **Nurseries**: worker `id` (0 main, 1..n background, n+1 host) owns
  nursery slot `id`, `N` bytes, contiguous, beyond the block range (so a
  nursery is not made of pool blocks; it is never handed out or swept).
  Maximum 16 workers. `N` = `KAJO_NURSERY_KB` (1, 4 or 16 MiB in the
  bench). The worker's TLAB is its whole nursery: `cur..end` bump, no block
  boundaries inside a nursery (objects are still at most one block).
  `nurseryTop` keeps the bump position when the TLAB is retired at a park.
- **The boot worker** (image building) has no nursery: the image is
  allocated old.
- Every other allocation in generational mode is young, up to the 32 KiB
  object limit. There is no large-object space.

## Young/old encoding

Header bit 56 = **young** (`youngBit`). Set at allocation in a nursery,
cleared by the scavenge when the object is promoted. Chosen over a
body-offset range check because the barrier already loads the holder's
header (one cache line with the body offset it just used) and a bit test
needs no per-worker range bounds.

The header is written only (a) by its allocating worker before the oop
escapes, (b) by the scavenge (young bit, atomically, see claiming) and
(c) by the full collector's mark bit, the last two with the world stopped.
Mutators never write a published header.

## Remembered set

- **Remembered byte map**: one byte per entry (16 MiB, lazily committed),
  accessed only through atomics. DESIGN.md proposed a header bit. It cannot
  be one here: a mutator setting a bit in a published header word races
  with every other worker's plain header loads (every send reads the class
  from it), which ThreadSanitizer reports and which is a real data race in
  the Swift memory model. The byte map keeps headers immutable while the
  world runs.
- **Remembered buffer**: per worker, a growable raw array of holder oops,
  written only by its owner.
- An entry's byte is 1 exactly while its oop sits in some worker's buffer.
  A scavenge empties every buffer and clears every byte (promotion is on
  first survival, so after a scavenge nothing is young and no holder needs
  to stay remembered).

## Write barrier

After every store of a value `v` into slot of heap object `o`:

```
if v & 1 == 0                       // pointer, not SmallInteger
   && header(o) & young == 0        // holder old
   && header(v) & young != 0        // value young
   { remember(o) }                  // out of line
remember(o): if rem[o].load == 0 && rem[o].exchange(1) == 0 { w.remBuf.push(o) }
```

The holder test comes first because the holder's entry was just loaded to
reach its body; in allocation-heavy code holders are mostly young and the
value's entry is never touched.

**Sites.** Interpreter: `store_ivar`. Primitives: `at:put:`. VM-internal
stores of an oop that may be a young heap object into a heap object
(the count is a result; RESULTS.md lists them): ready/Semaphore list links,
Semaphore head/tail, a Process's `waitingOn`, `exitSem`, `result`. Not
barriered, with the reason:

- stores of SmallIntegers or of `nil`/`true`/`false` (always old);
- initialising stores into an object allocated in the same primitive with
  no safepoint in between (the holder is young);
- native root arrays scanned at every scavenge: globals, class table,
  ready-queue heads and tails, pending-root table, host roots, symbol
  roots, Process records, Process stacks;
- image building (boot allocations are old and nothing young exists yet).

`NO_BARRIER` compiles every site out.

## Entry allocation: chunks and bitmaps

Entries keep variant B's layout (16 bytes: header, body offset; oop = byte
offset of the entry). The free-entry linked lists and runs are replaced:

- The table is split into **chunks** of 4096 consecutive entries (64 KiB of
  entries). Each chunk has a **used bitmap** of 64 words; bit = entry in use
  or reserved. Entry 0 is permanently used (oop 0 means "none").
- A **global chunk pool**: an array of chunk indices consumed lock-free with
  `fetch_add`, rebuilt only with the world stopped. When it is empty a
  fresh chunk is taken at the table's high-water mark (`fetch_add`).
- A worker owns one **current chunk** and a cursor over its 64 bitmap words.
  To refill it takes the next word with a zero bit *whole*: it ORs all the
  word's free bits into the bitmap (they are now reserved) and keeps them in
  `entFree`. The allocation fast path is `ctz(entFree)`, clear the lowest
  bit, `oop = entBase + bit * 16`. No load from the table.
- In generational mode every word taken is appended to the worker's **young
  log** as `(word index, bits taken)`; every chunk taken is appended to the
  worker's chunk list.
- **Survivor bitmap**: one bit per entry, set atomically by the scavenger
  that promotes the object.
- **Release at a stop**: each worker's unused reserved bits go back
  (`used &= ~entFree`, and are removed from the last log record); the
  current chunk is released.
- **Entry sweep after a scavenge**: for each young-log record:
  `dead = bits & ~survivors(word)`; `used(word) &= ~dead`; the survivor
  word is cleared. This touches only the bitmap words that held young
  entries since the last scavenge, never the entries themselves (a freed
  entry keeps stale contents until it is reused, and the allocator
  overwrites both words). This refines DESIGN.md's "bitmap sweep of the
  chunks that held young entries": it sweeps the *words* that did.
- **Pool rebuild after a scavenge**: the pool's unconsumed chunks plus every
  chunk any worker took this cycle that now has a free bit. Fully free and
  partially free chunks both go to the global pool (a worker reuses a
  partially free chunk only if it takes it from the pool again).
- **Full collection sweep**: every chunk below the high-water mark: for
  each used bit, the entry's mark bit is cleared if set, else the bit is
  cleared; the pool is rebuilt from every chunk with a free bit.

## Scavenge

A scavenge is a stop-the-world operation (`SafeOp.scavenge`) through the
existing safepoint protocol.

**Trigger**: a worker's nursery cannot fit the next object (`allocSlow`).
Also the test primitive `nil scavenge` and the host. Old-space exhaustion
(non-generational mode, or the table running out of chunks) triggers a
full collection as before.

**Participants**: the stopping worker plus every worker parked at a
safepoint when the stop completes. Workers outside the VM (idle, the main
thread between turns, the host) do not participate; their nurseries,
stacks, buffers and logs are still processed, by whoever takes the task.

**Phases** (stopper unless noted):

1. *Stop*: as before (time to safepoint, `ttsp`).
2. *Prep*: retire every TLAB (nursery top recorded), release entry
   reservations, compute the root ranges (the Process `sp` slots are read
   here, before anything moves), build the task list, reset counters.
   Verify mode runs its pre-checks here.
3. *Copy phase* (all participants in parallel): the stopper opens the
   phase under the safepoint mutex and broadcasts; each parked worker
   wakes, joins (taking a participant slot), and leaves the mutex. Each
   participant increments `inCopy`, then takes copy tasks with
   `fetch_add` on a shared index until none are left, then drains its own
   work stack, then decrements `inCopy`. Tasks are root ranges (split at
   4096 words) and remembered-buffer slices of 256 holders.
4. *Copy barrier*: a participant that found no task left waits (spin with
   `sched_yield`) until `inCopy == 0`. Because every participant
   increments `inCopy` before taking its first task, `inCopy == 0` after
   the task list is exhausted means every copy has finished.
5. *Entry sweep* (all participants in parallel): sweep tasks are slices of
   1024 young-log records; each participant takes them with `fetch_add`.
6. *Join*: the stopper closes the phase (no late joiners) and waits under
   the mutex until every joined participant reported done.
7. *Finish*: chunk pool rebuild, nursery tops reset, remembered buffers
   emptied, statistics; the world resumes. If another scavenge promoting as
   much as this one would cross old space's soft limit, a full collection is
   marked pending and the stopper requests it as its own pause right after
   resuming (any stop that comes first is upgraded to it). Only if old space
   is already more than a quarter of the promotion reserve above the soft
   limit does the mark-sweep run inside this pause. (Changed after the first
   scenario runs: a scavenge stacked on a mark-sweep made 9 to 14 ms pauses.)

**Scanning a word `v`** (participant):

```
if v is SmallInteger or 0: return
h = atomic load (relaxed) of header(v)
if h & young == 0: return
if !CAS(header(v), expected: h, desired: h & ~young): return   // claimed by another
copy objectBytes(h) bytes of the body into this participant's promotion TLAB
  (a word loop up to 128 bytes, memmove above)
entry(v).bodyOffset = new offset
survivor bit of v: atomic OR
if !bytes(h): push v on the local stack
```

Draining pops `v` and scans each slot of its new body. Every scavenge-time
header access is atomic (an `Atomic<UInt64>` view of the header word);
headers of old objects are never written during a scavenge, so plain loads
of them do not race.

**Claiming protocol**: the CAS is on the entry's **header word** and
clears the young bit; the winner, and only the winner, copies the body,
writes the new body offset, sets the survivor bit and scans the copy. A
loser does nothing: with an object table no reference has to be updated,
because oops do not change when bodies move. Nobody but the winner reads a
young object's body offset or body during the scavenge, so the offset
write needs no atomic.

**Promotion TLAB**: per worker, a block from the old pool (ignoring the
soft limit), kept across scavenges and retired before a full collection.

**Roots** (all read as oop ranges): the symbol and host root stacks,
globals, special selectors, class table, ready-queue heads and tails, the
pending-root table (which holds every Semaphore with an outstanding
external signal; the events themselves are native structs with no oops),
every live Process record's process oop and its stack from the base to the
saved or flushed `sp` (running and parked Processes alike), and every
worker's remembered buffer. The full collector's root set is unchanged.

**Promotion policy**: promote on first survival; there is no age field and
no survivor space. After a scavenge nothing is young, every remembered
buffer is empty and the nursery is reset to its start.

**Load balance**: tasks are shared through the task index. During the
drain, every 1024 objects, a participant whose stack holds at least 8 oops
exports the bottom half (up to 256 oops, the shallowest and usually largest
subtrees) as a packet to a mutex-guarded pool if another participant is
idle and the pool is empty. A participant with no task left takes packets
before declaring itself idle. Termination: packets are pushed only by a
participant counted in `inCopy`; a participant leaves `inCopy` only after
finding the pool empty; an idle participant re-enters `inCopy` (CAS from a
non-zero value, never from 0) before it pops a packet. So `inCopy == 0`
means no packet is left and no copy is in flight, which is the copy
barrier. Per-participant busy time is recorded to show the remaining
imbalance. (Added after the first measurements; see RESULTS.md.)

## Full collection

`SafeOp.full`: in generational mode a scavenge first (so nursery and
remembered set are empty), then the existing non-moving mark-sweep of old
space by the stopper alone, with the bitmap entry sweep above and the
block pool rebuild. Promotion TLABs are retired first. Full-collection
pauses are recorded separately from scavenge pauses. Requested as its own
pause right after the scavenge that found old space nearly full, so its
scavenge part is small.

## Stop protocol fix

The inherited protocol let a parked worker decrement `parked` when it
woke up after the world was released. A stop requested immediately after
another (the pending full collection) could then count released, running
workers as parked. The stopper now zeroes `parked` when it releases the
world and parked workers do not decrement it.

## Pause accounting

Per pause, the stopper records (ns): total (stop request to world
resumed), `ttsp`, prep, copy-phase wall time, sweep-phase wall time, finish,
and for every participant its busy time split into root scanning, remembered
set processing and the drain (copying and scanning promoted objects), plus
its sweep time. Reported breakdown, which sums to the pause:

- **coordination** = ttsp + prep + finish (minus any full mark-sweep) +
  (copy wall − critical participant's copy busy) + (sweep wall − its sweep
  busy): stopping, waking participants, imbalance and the barrier waits;
- **roots**, **remembered set**, **copy**: the critical participant's
  (longest copy busy) split;
- **entry sweep**: the critical sweep participant's sweep time.

Also per pause: participants, young bytes allocated since the last
scavenge, promoted bytes and objects, remembered set size (holders), young
entries allocated, entries freed.

## Verification (tests)

`vm.verify` (tests only) adds, inside the pause:

- *before copying*: walk every used old entry; for each slot holding a young
  oop the holder must be remembered (catches any missing barrier, including
  at sites whose value happens to be rooted elsewhere); count the young
  objects reachable from the roots and remembered holders (single-threaded
  traversal with a side bitmap).
- *after the sweep*: the scavenge promoted exactly that many objects (each
  claimed once); no used entry is young; every pointer slot of every used
  entry and every root names a used entry.

Failures are counted in a metric and printed; tests require zero.

## Kernels

From `../vm-language-bench/kernels/` by path: `arith`, `fib`, `sends`,
`alloc`. From `../object-representation/kernels/`: `ivars`. Prelude from
`../vm-language-bench`, `lib.kasm` from `../ui-thread-scheduling/kernels/`.
New, in `kernels/`:

| kernel | per worker | total work |
|---|---|---|
| `churn` | per iteration a fresh `Point x: i y: i + 1` and a fresh 2-slot Array holding it; reads both back; drops both. Two 24-byte bodies per iteration, nothing survives | 24 000 000 iterations split between workers |
| `survivors5`, `survivors30` | per iteration a fresh Point; with probability p (5 or 30 percent, `i \\ 100 < p`) it is kept in a long-lived structure, else dropped. The structure is an Array of 1024 Arrays of 64 slots, allocated up front, so after the first scavenge it is old; keeper `j` goes to chunk `j \\ 1024 + 1`, slot `j // 1024 + 1`, so every keeper store is an old-to-young store into one of 1024 different holders. When 65 536 keepers are stored the structure is summed and dropped and a new one is built. Checksum includes every structure's sum, which reads every promoted keeper back | 24 000 000 iterations split between workers |

`survivorsP` loads `survivors.kasm` plus a generated one-method source
`UndefinedObject survivalPercent` answering P.

Survival is a property of the kernel *and* the nursery: a keeper survives
its first scavenge only if its structure is not dropped first. The measured
survival (promoted bytes / young bytes) is reported per configuration.

Headless matrix: every kernel (`arith fib sends ivars alloc churn
survivors5 survivors30`) × {`nobar` (`NO_BARRIER` build, non-generational),
`bar0` (barrier compiled in, nursery 0: non-generational, the barrier runs
and never fires), `g1`, `g4`, `g16` (nursery 1, 4, 16 MiB)} × {1, 8
workers} × {`O`, `align32`} builds, 5 interleaved runs, medians. Old space
64 MiB. Pause scaling: `alloc`, `churn`, `survivors30` at 4 MiB with 1, 2,
4 and 8 workers, O build, 5 runs.

## Scenarios (the app)

The app and its frame measurement are unchanged from
`../ui-thread-scheduling` (window, rotating layer, display link at
120 Hz, run-loop observer, frame account, 1 ms event timer stamping events
with their due time, 7 background workers, old space 64 MiB). 1 s warm-up,
10 s measured, 3 runs, median run by missed frames then max gap.

| id | nursery | load |
|---|---|---|
| G0 | 4 MiB | none (control) |
| G1 | 0 | UI Process handles 1000 events/s (~50 µs of Smalltalk and `setLabel:` each) + 7 background Processes running `alloc` forever (`run: 0 of: 8` in a loop). The previous experiment's S4 |
| G2 | 4 MiB | G1 |
| G3 | 4 MiB | G2, but the 7 background Processes run `survivors30` (`run: 0 of: 8` in a loop) |
| G4 | 4 MiB | G2, and after each event the UI Process also allocates ~100 µs worth of Points (calibrated at start-up) on the main thread |
| G5 | 16 MiB | G2 |

G1 is built with the barrier and runs with nursery 0; the barrier never
fires there (see the headless barrier cost).

Reported per scenario: frames, missed, drops, gap p50/p99/max, worst
run-loop iteration with the VM, GC park and GC enter-wait time inside it;
scavenge count and pause p50/p99/max; full collection count and pause max;
ttsp p50/p99/max; main-thread enter waits; event latency.

## Choices (where DESIGN.md left one open)

- Young/old: header bit, not a range check.
- Remembered marker: a byte map beside the table, not a header bit (TSan,
  see "Remembered set").
- Claim: CAS clearing the young bit in the header word.
- Any participant may promote any young object (first to reach it), not
  only its own nursery's; work sharing by exported packets, not stealing
  deques.
- Promotion on first survival; no age field, no survivor space.
- Promotion reserve instead of promotion-failure handling.
- Entry sweep over young-log words, not whole chunks; all chunks with a free
  bit go to the global pool.
- The full collection is a scavenge followed by single-threaded mark-sweep.
- Methods, bytecodes and literal arrays are always old (made at boot), so
  frames may keep raw pcs and literal pointers across a scavenge. A runtime
  compiler would have to allocate methods old.
- `vm.results` (host-visible results of terminated Processes) is not a root;
  the host reads only SmallIntegers from it, as before.
