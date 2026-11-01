# Spec: age field, survivor spaces and concurrent relocation of old space

Written before the collector code. Everything not stated here is as in
`../concurrent-marking/SPEC.md` (SATB marking, lazy sweep, triggers and
fallback, side tables) and below that `../generational-gc/SPEC.md` (nursery,
parallel scavenge, remembered set, entry chunks and bitmaps, stop protocol,
pause accounting). Where DESIGN.md left a choice the simpler option is taken
and listed under "Choices"; where DESIGN.md's protocol is changed the change
is listed under "Changes to DESIGN.md's protocol" with the reason.

## Package shape

`swift/` is a copy of `../concurrent-marking/swift/`, renamed:

- `Kasm`: unchanged assembler. Kernel lookup adds `fragment` and
  `storeheavy` (this experiment's `kernels/`), and reads every earlier
  kernel in place, `oldheap.kasm` from `../concurrent-marking/kernels/`.
- `VMR`: the VM (was `VMC`). New compile flag `NO_POST_STORE` removes the
  post-store check from every store site (stores are then exactly the
  previous experiment's relaxed stores). Such a build cannot relocate;
  asking it to is a fatal error. `NO_MARK_BARRIER`, `NO_BARRIER` and
  `NO_BUDGET` are kept.
- `cr-bench`: `cr-bench kernel <name> <workers>` prints one `key=value`
  line.
- `kajo-ui`: the AppKit app, scenarios `R0`..`R6` (and `R5n`).
- `VMRTests`: Swift Testing, headless, also under ThreadSanitizer.

Runtime switches (environment, read once at `Runtime` creation; the
previous experiment's `KAJO_GC`, `KAJO_CM_*`, `KAJO_NURSERY_KB`,
`KAJO_HEAP_MB`, `KAJO_VERIFY` stay):

| variable | values | default |
|---|---|---|
| `KAJO_AGE` | N, the number of scavenges an object survives before promotion, 1 to 7 | 1 (ADR 0005/0006 behaviour) |
| `KAJO_SURVIVOR_KB` | size of one survivor half per worker when N > 1 | nursery / 8 |
| `KAJO_RELOC` | `off`, or the relocation threshold in percent of a block (`25`, `50`, `75`, `100`), or `all` (every snapshot block with a live object, full ones included) | `off` |
| `KAJO_RELOC_CAP` | at most this fraction of the free blocks is used as to-space in one cycle | 0.5 |
| `KAJO_VERIFY` | `cm`: mark-set verifier at every final mark and the relocation verifier at every pause; `all`: also the inherited scavenge verifier | off |
| `KAJO_SAMPLE_MS` | footprint sampling interval of `cr-bench` (old space in use and live bytes) | 100 for `fragment`, else off |

The **ADR 0006 configuration** is `KAJO_GC=cm KAJO_AGE=1 KAJO_RELOC=off`
with the post-store check compiled in: everything the previous experiment
measured as `cm`, plus a post-store check that never finds a conflict.

## Header word

```
bits  0..21  class index
bits 22..53  slot count
bit  54      mark (full collection only)
bit  55      bytes object
bit  56      young
bits 57..59  age: scavenges survived, young objects only (0..7)
bit  60      pinned for good: never relocated
bit  61      frame pin: not relocated in the current cycle
bits 62..63  scavenge claim tag, young objects only
```

**Age encoding: header bits, not a byte map.** The age is read and written
only by scavenges, with the world stopped, and only for young objects, whose
header no other thread reads concurrently with a scavenge. It has to be read
in the same atomic load that decides whether the object is young and whether
it has already been claimed, so it belongs in the same word. Promotion
clears the age, the claim tag and the young bit in one CAS.

**Claim tag.** The previous scavenge claimed an object by clearing its young
bit with a CAS; another participant seeing the bit clear knew it was taken.
A survivor stays young, so the young bit no longer says "claimed". Scavenge
number s (counted per VM) uses tag bit `62 + (s & 1)`. An object is claimed
in this scavenge if its current tag bit is set; the winning CAS sets the
current tag and clears the other one, writing the decision (survive with age
a + 1, or promote) into the same word. A participant that loses the CAS or
finds the tag set reads the decision from the header: young means it stayed
young. Objects allocated in eden have no tag. No pass is needed to clear
tags: the next scavenge uses the other bit.

**Pin bits** are set only with the world stopped (permanent pins at image
build, before any thread starts; frame pins at the final mark) and cleared
only with the world stopped (frame pins at the apply or abort of the cycle).
The relocator reads them with a relaxed atomic load outside pauses. No
mutator ever writes the header of an old object (AGENTS.md).

## Part 1: eden, survivor spaces and the age field

### Layout per worker

Each worker's nursery (4 MiB) is split, when N > 1:

```
nurseryStart                                         nurseryStart + nursery
|<---------------- eden ------------------>|<- S0 ->|<- S1 ->|
```

S = `KAJO_SURVIVOR_KB` (default nursery / 8 = 512 KiB), eden = nursery - 2 S
(3 MiB by default). With N = 1 there are no survivor halves and eden is the
whole nursery, exactly as before. The worker's TLAB is its eden
(`nurseryTop` .. `edenEnd`). One of S0 and S1 is survivor-from (holds the
survivors of the previous scavenge, `survFromTop` bytes), the other
survivor-to (empty). `inNurseries` still covers the whole region, so every
young body is in a nursery.

### Scavenge

As before: roots, remembered holders, parallel copy with work sharing, then
the young-log entry sweep. Changed:

- **Decision.** The winner of a young object with age a computes a + 1. If
  the scavenge is not a full one, a + 1 < N, and the winner's own
  survivor-to has room, the object is copied into the winner's survivor-to
  with age a + 1 ("survived"); otherwise it is copied into the winner's
  promotion buffer with the young bit, age and tag cleared ("promoted").
  A promotion because survivor-to had no room is an **overflow promotion**,
  counted separately (objects and bytes).
- **Full collections promote everything** (`promoteAll`): the scavenge in
  front of a stop-the-world mark-sweep (`stw` mode, fallbacks) ignores the
  age, so the mark-sweep still runs with nothing young.
- **Survivors go into the winning participant's survivor-to**, whichever
  nursery they came from. A participant's survivor-to is only bumped by
  that participant. Survivor-to of every worker is empty at the start (it
  was evacuated as survivor-from in the previous scavenge).
- **Remembered set across scavenges.** An old object that holds a young
  object after the scavenge must stay remembered. Holders are scanned in two
  places: remembered holders (old) and promoted objects (newly old). After
  scanning a holder, if any of its slots names an object that is young after
  this scavenge (the claim decision says so), the holder is put in the
  scanning participant's next remembered buffer and its remembered byte is
  set (or kept); otherwise the byte is cleared. At the end each worker's
  remembered buffer becomes its next buffer. Young holders (survivors) are
  never remembered.
- **Young log across scavenges.** The entry sweep frees young entries that
  did not survive, from the logs of entry words taken since the last
  scavenge. Survivors' entries must be in the next scavenge's log: the
  winner appends (word, bit) for each survivor to its survivor log, which
  becomes its young log at the end.
- **Entry sweep is per bit.** A word can now be in two log records (a
  survivor's single bit and a later take of the same word's free bits), so
  the sweep clears only its record's bits: `alive = surv[w] & bits` read,
  `surv[w] &= ~bits`, `used[w] &= ~(bits & ~alive)`, all atomic. (The
  previous sweep exchanged the whole `surv` word with 0, which loses a
  survivor if the word has two records in one cycle; with the lazy sweeper
  freeing old entries concurrently that could already happen, rarely.)
- **Flip.** At the end every worker's survivor halves swap roles; the new
  survivor-from holds what was copied into survivor-to.

Reported per scavenge: young bytes (eden used plus survivor-from used),
survived bytes and objects, promoted bytes and objects, overflow bytes and
objects, bytes copied (survived plus promoted).

### Snapshot soundness with survivors

ADR 0006's rule: take the snapshot at the end of a scavenge, when nothing is
young. With survivors, young objects exist at the end of every scavenge,
including the one that carries the initial mark. The loss the previous
experiment showed needs a young object Y alive at the snapshot that holds
the only reference to an old object O; the program copies O into an
already-scanned old object over nil (no SATB record) and drops Y.

**Adjustment: survivors are scanned as roots at the initial mark.** After
the scavenge part of the initial-mark pause, the stopper:

1. builds the snapshot bitmap from `used` minus every bit in every worker's
   young log (which now holds exactly the survivors), so no survivor is a
   snapshot entry;
2. scans every survivor's slots and greys every snapshot entry they name,
   along with the ordinary roots.

Why this is sound: every old object that a young object references at the
snapshot is marked at the snapshot, so the only paths from roots to snapshot
objects that the marker does not trace are paths through young objects, and
those are cut at the first old object, which is marked. Young objects are
not snapshot entries, so their later slot changes delete no traced edge and
the barrier keeps skipping young holders. Survivors promoted during marking
are not snapshot entries either: black, as before. The cost is a scan of
the survivor spaces in the initial-mark pause, reported as its own part.

The alternative, promoting every survivor at the initial-mark scavenge,
keeps the rule literally but promotes the survivor spaces once per cycle,
which is the traffic the age field is meant to remove.
`survivorRoots = false` (test switch) disables step 2; a test shows that
the verifier then reports the lost object.

## Part 2: concurrent relocation

### Selecting the relocation set

- **Live bytes per block.** A byte counter per old block (`blockLive`,
  atomic 32-bit), zeroed at the initial mark. Whenever a marker or the
  final-mark drain traces a marked object (every marked object is traced
  exactly once, byte objects included), it adds the object's size to the
  counter of the block that holds its body.
- **At the final mark**, after the drain and the verifier: every snapshot
  block in use with `0 < blockLive < threshold x blockSize` (`all`: every
  snapshot block with live bytes) is a candidate, in block order. Candidates
  are taken until the bytes to move would exceed `KAJO_RELOC_CAP` times the
  free blocks under the soft limit (the to-space must come from somewhere;
  this keeps relocation from causing a fallback). Recorded: candidates,
  blocks selected, bytes to move, expected reclaim (selected blocks times
  the block size minus bytes to move), time.
- Blocks with no live object are not selected: the sweep frees them anyway.

### Pins and hazards

**Inventory of raw body pointers** (DESIGN.md asks for it; it decides what
needs a pin). In this VM the interpreter re-derives a body address from the
entry at every access except for these:

| holder | points into | lifetime | handling |
|---|---|---|---|
| `Regs.pc`, `Worker.pc`, saved `pc` in each frame (`hdr[1]`), Process `pPc` | a method's bytecodes (ByteArray) | across instructions, sends, parks and slices | bytecode objects are pinned for good |
| `Regs.lits` | a method's literal Array | across instructions; re-derived from the method at every return and resume | literal Arrays are pinned for good |
| receiver in `push_ivar`/`store_ivar` | receiver body | within one instruction (entry load, then slot access) | none needed: no safepoint inside an instruction; the store has the post-store check |
| `at:` / `at:put:` / bytes `at:` | receiver body | one primitive call, one access | as above |
| `arrayCopy` primitive (new, `replaceFrom:to:with:startingAt:`) | source and destination bodies | a loop of stores | hazard slots 0 and 1 |
| `ioResult:` | a fresh ByteArray | one primitive, no safepoint | young, never relocated |
| image loader (`bytesPtr`) | fresh bytecode objects | boot, single thread | before any relocation |
| scavenge, marker, sweeper, verifier | any body | inside a pause, or while no relocation runs (marking and relocation are different phases of the same thread) | none |

**Re-derivation at resume** (read from `resumeCurrent` and `doReturn`):
a parked Process keeps only `pSp`, `pFp`, `pHdr` (its own native stack, not
the heap) and `pPc` (a bytecode object, pinned). On resume `lits` is
re-derived from `hdr[0]`, the method oop, through its entry. On every
return `lits` is re-derived from the caller's method. Frame slots (receiver,
arguments, temporaries, stack) hold oops only. So parked Processes need no
pins, and neither does the running frame in this interpreter: the receiver
body is never cached. The frame pin below is implemented because DESIGN.md
requires it, and counted, but no load-bearing pointer depends on it here.

**Pin rule.**
- *Pinned for good* (bit 60), set when the image is built: every method,
  its bytecode object and literal Array, every class, every symbol, nil,
  true and false. (The class table, globals and special-selector table are
  native arrays, not heap objects.) Method dictionaries are not pinned:
  lookups read them one slot at a time.
- *Frame pins* (bit 61), at the final-mark pause: for each worker with a
  current Process, every old object named by a word of its current frame,
  from `fp` (receiver) to the flushed `sp`, plus the method. The pinned oops
  go into a list; the next pause that applies or aborts the cycle clears
  them. Counted per cycle.
- The relocator skips an object with either bit set, and the block it is in
  is then not freed this cycle.

**Hazard slots.** Each worker has two hazard words (`hz0`, `hz1`) in its own
cache line, beside its epoch word. A primitive that keeps a body pointer
across more than one access:

```
hz[k].store(o, seq_cst)
loop { e = entry(o).offset.load(seq_cst); if e has RELOCATING: spin; else break }
p = heap + e                      // valid until hz[k] is cleared
... loop of accesses through p (stores do the barriers, no post-store check)
hz[k].store(0, release)
```

The relocator, after its CAS to RELOCATING and a seq_cst fence, loads every
worker's two hazard words (seq_cst); if one names the object it stores the
old offset back (revert, release) and skips the object until the next cycle
(counted). Dekker argument as for the post-store check below: either the
relocator sees the hazard, or the primitive sees RELOCATING and waits for
the revert or the switch, then uses the current body. `arrayCopy`
(primitive 38, new) is the only primitive that needs this; none of the 28
existing primitive numbers does. `fragment` calls it every 64th iteration.

### Entry state encoding

An entry is 16 bytes: header word, then the offset word (byte offset of the
body from the heap base, a multiple of 8). States of the offset word:

| state | offset word |
|---|---|
| NORMAL | `off` (bit 32 clear) |
| RELOCATING | `off + R`, with R = 2^32 |
| switched | `new` (bit 32 clear) |

**The heap is mapped twice**: the same memory object at `base` and at
`base + R` (`mach_make_memory_entry_64` plus two `mach_vm_map`s into one
reserved range; heaps are smaller than 4 GiB). So `heap + (off + R)`
addresses the old body through the alias, and every mutator read and store
during RELOCATING goes to the old body with no masking and no branch.
Mutator reads need no barrier at all: before and during the copy the entry
leads to the intact old body, after the switch to the new one. One relaxed
atomic load of the offset word (a plain `ldr`) per access, as before.

The switch is one 64-bit store (release) of `new` by the relocator, the
only writer of an old entry's offset word outside pauses. RELOCATING is
entered with a CAS from `off` (seq_cst) and left by the switch or by a
revert to `off`. No entry is RELOCATING at any pause (the relocator polls
only between objects), and the verifier checks it.

### Copy protocol

For each object in the set (marker 0, inside the VM, between the final
mark and the sweep):

1. walk the block's bodies by their back references; skip a body whose entry
   is not a marked snapshot entry or whose entry's offset is not this body
   (dead, or a stale copy);
2. skip if pinned (header bits 60, 61);
3. allocate the to-space copy from the relocator's own TLAB (fresh blocks,
   under the soft limit; none left: stop relocating, counted);
4. CAS the offset word `off -> off + R` (seq_cst); then a seq_cst fence;
5. check every worker's hazard words; if hazarded, store `off` back, undo
   the TLAB bump, skip;
6. copy the body word by word (relaxed atomic loads from the old body,
   relaxed atomic stores into the new one);
7. switch: store `new` (release);
8. after the last object of a block: if nothing in it was skipped, the
   block goes on the pending-free list with the current epoch (below).

**Post-store check (mutators).** Every store into a slot of a heap object,
SmallIntegers included, outside fresh-object initialisation:

```
e1 = offset(o).load(relaxed)
slot(heap + e1, i).store(v, seq_cst)            // stlr
e2 = offset(o).load(seq_cst)                    // ldar
if e2 != e1 || e1 & R != 0 { postStoreSlow(w, o, i, v) }   // one out-of-line call
```

Slow path: loop { wait while the offset word has R (spin, `sched_yield`
every 64 spins); store `v` into the current body (seq_cst); reload the
offset (seq_cst); done if unchanged }. Counted per worker: stores redone,
spin episodes, spin time (max and total). In `store_ivar` and `at:put:` the
check and the generational barrier form one shape: if the check fails, one
out-of-line call (`storeConflict`) redoes the store and runs the barrier;
otherwise the inline barrier follows, so nothing of the instruction is live
after a call (AGENTS.md). The generational and SATB barrier
work stays as it is and runs only for pointer stores.

**Ordering argument.** Take the single total order S of seq_cst operations.
The mutator's store X precedes its load L of the offset word in S (program
order); the relocator's CAS C precedes its fence F, which precedes its copy
loads. (a) If L reads a value written before C (it sees `e1` without R and
equal to it), then L precedes C in S, so X precedes F in S, and by the fence
rule every copy load after F sees X or a later store: the copy carries X.
(b) Otherwise L sees RELOCATING or a switched offset (or e1 itself had R),
so the mutator takes the slow path, waits until the switch (or revert) is
visible with acquire, which happens after the copy finished, and stores
again into the current body, after the copy's write of that slot: the
store lands in the new body. X itself may also have been copied (it went
into the old body through the alias); the redo writes the same value. A
store whose operation overlaps another thread's store to the same slot can
be ordered either way, which is linearizable. On arm64 this is `stlr` then
`ldar`, which the architecture does not reorder (RCsc); the cost is that
the `ldar` waits for the `stlr` to drain. That is the cost DESIGN.md asks
for, measured with `NO_POST_STORE`.

New bodies are read by mutators after a relaxed load of the switched offset
word; the address depends on that load, which orders the reads after it on
every arm64 and x86 CPU (the RCU / `consume` argument). Body words written
by the relocator are relaxed atomic stores and every mutator slot load is a
relaxed atomic load (both plain on arm64), so ThreadSanitizer sees no
plain/atomic race. Mutator stores into the old body through the alias are
not seen by ThreadSanitizer as the same address as the relocator's loads
(a limit of the tool, noted in RESULTS.md).

### Freeing old blocks: epochs

- A global epoch counter E (atomic). Each worker has an epoch word in its
  hazard cache line: at every budget poll (every `pollEvery` = 1024 polls,
  the poll slow path) and at every safepoint park it stores the current E
  (acquire load, release store); `leaveVM` stores "quiescent" (max); 
  `enterVM` stores the current E.
- When the relocator finishes a block whose objects were all moved, it
  records `(block, s = E, time)` on the pending-free list and increments E.
  A pending block is freed when every worker's epoch word is greater than s
  (quiescent counts): every worker has, since the switch, passed a point
  where it holds no body pointer. The relocator checks after every block,
  at the end of the pass and every 1 ms while it waits for work (inside the
  VM).
- **Every pause frees all pending blocks first**: with the world stopped
  every active worker is parked at a safepoint, which is what the epoch
  stands for.
- Freeing: `used[b] = 0`, `inUse[b] = false`, the snapshot block map entry
  cleared (so the cycle's apply does not consider it), `taken` decremented,
  and the block appended to the free list (`freeList[count] = b`, count
  stored with release). `takeBlock` becomes a CAS loop on the take index
  bounded by an acquire load of the count, so a block appended outside a
  pause can be taken. The list has room for 2 x the block count; when full,
  the block waits for the next pause.
- Reported: delay from switch to free (max and mean per cycle), blocks freed
  by epoch and at pauses. In the generational VM only promotion (in pauses)
  and the relocator take blocks, so a block freed by epoch becomes useful at
  the next pause in practice.

### Phases

The marker 0 thread relocates in the sweeping phase, before sweeping:
final mark (selection, frame pins) -> sweeping: relocate, then sweep ->
swept -> apply at the next pause (also clears frame pins). Relocating
before sweeping keeps every entry the relocator touches stable: snapshot
entries are freed only by the sweep. The sweep then flags blocks by the
entries' new offsets, so fully evacuated blocks show no live object; they
belong to the relocator (pending list) and their snapshot-map entry was
cleared when freed. Apply clears the sweep-live map of every block (not
only snapshot blocks), since a freed block can be reused as to-space within
the cycle. A fallback aborts relocation: the relocator, back from the park,
sees the cycle changed and stops; the full collection frees evacuated
blocks by its own block sweep.

### Verifier

`KAJO_VERIFY=cm` or `all`, and in every test: at every pause, after pending
blocks are freed and after the pause's work:

- no entry is RELOCATING;
- every used entry's body is in a nursery or in an in-use old block, inside
  `used[b]` bytes of it, and the body's back reference names the entry;
- no in-use block is in the unconsumed part of the free list, no free-list
  block is in use, no block is twice in the free list;
- no block on the pending-free list is in the free list.

Failures are counted in `verifyFailures` and the first ten printed. The
mark-set verifier (final mark) and the scavenge verifier (survivors allowed
in survivor-to, remembered-set invariant, reachable young objects copied
exactly once) stay.

## Test-only switches

`CMConfig`: `survivorRoots` (default true), `pinRule`, `hazardRule`,
`epochRule` (default true each), `manualReloc` (no relocation by the marker
thread; the test calls `relocPass`). A test-only unchecked store
(`setSlotRaw`) stands for "no post-store check". Step functions
`relocBegin`, `relocCopy`, `relocSwitch` for one object let a test hold an
object in RELOCATING.

## Kernels

From earlier experiments, read in place: `arith`, `fib`, `sends`, `alloc`,
`prelude`, `ivars`, `churn`, `survivors`, `gclib`, `gcui`, `lib`, `ui`,
`oldheap`. New in `kernels/`:

**`storeheavy`**: class `Hot` with 8 instance variables; `spin: n` stores
the loop counter into all 8 (SmallIntegers, `store_ivar`), n times; 4 hot
objects per worker, 64 000 calls of `spin: 1000` in total split between
workers (64 million iterations, 512 million stores). No allocation in the
loop, no pointer store. Checksum: the sum of every object's ivars at the end
of each call.

**`fragment`**: per iteration a 14-slot Array node (120-byte body, slot 2 a
SmallInteger payload) and 4 two-slot `FPoint`s of young garbage (96 bytes).

| parameter | value |
|---|---|
| iterations | 2 000 000 in total, split between workers |
| ring (medium-lived) | per worker an Array of 32 768 nodes; iteration i stores its node at slot i \\ 32768 + 1, so a node lives 32 768 iterations (about 7 MB of allocation, 2 to 3 eden fills: promoted at N = 2, mostly dead young at N = 4) |
| keep (long-lived) | every 20th node (5 percent) also goes into the worker's keep store (a spine of Arrays of 1024) and stays for the whole run, scattered among the promoted ring nodes |
| keeper writes | every 4th iteration, `(keep at: r) at: 2 put: i` for a pseudo-random kept node r (a SmallInteger store into an old object that relocation moves) |
| old space | 256 MiB soft limit (the 230 MB promoted with N = 1 or 2 fits without relocation, and cycles start at 60 percent, 154 MB) |
| checksum | churn sum + sum of every kept node's payload + sum of the ring's payloads at the end |
| footprint | `cr-bench` samples old space in use (blocks x 32 KiB) and live bytes (from the latest sweep) every `KAJO_SAMPLE_MS` (100 ms for this kernel: a run takes 0.1 to 1 s; the app scenario R5 gives the per-second curve) |

In the app (R5) the same loop runs forever, paced to 500 iterations per
10 ms per worker (a `delay:` between batches), with keep stores of 256 x
1024 slots that wrap around; 512 MiB soft limit and cycles from 30 percent
of it, so that cycles start within the 11 s window (about 40 MB/s is
promoted). `nil fragmentIters` is defined by the loader (2 000 000, or N
for a kernel named `fragmentN`, used by the tests). Every 64th iteration
the worker copies its newest keep chunk into a mirror Array with
`replaceFrom:to:with:startingAt:` (`arrayCopy`, hazard slots).

**`oldheap`** as before (`oldheapN`). Under `KAJO_RELOC=all` with cycles
forced back to back it is the lost-store test: the checksum reads every
node's link and payload at the end.

## Headless matrix

Kernels `arith fib sends ivars storeheavy alloc churn survivors5
survivors30 oldheap64 oldheap256 oldheap512 fragment` x 1 and 8 workers x
configurations, 5 interleaved runs, medians, 4 MiB nurseries:

| config | build | GC |
|---|---|---|
| `stw` | post-store check | `KAJO_GC=stw`, N = 1 (checksum reference) |
| `adr6` | post-store check | `cm`, N = 1, no relocation (ADR 0006) |
| `n2` | post-store check | `cm`, N = 2 |
| `n4` | post-store check | `cm`, N = 4 |
| `r25`, `r50`, `r75` | post-store check | `cm`, N = 2, relocation at 25, 50, 75 percent |
| `ragg` | post-store check | `cm`, N = 2, `KAJO_RELOC=all`, `KAJO_CM_FORCE=1` (cycles back to back, relocation of every live block: maximum conflicts) |
| `nops` | `-DNO_POST_STORE` | `cm`, N = 1, no relocation |

Old space 64 MiB, `oldheapN` 2 N + 64 MiB, `fragment` 256 MiB. Alignment
control: `arith fib sends ivars storeheavy` also run `adr6` and `nops` in
`align32` builds (`-align-all-nofallthru-blocks=5`), as the earlier
experiments did.

Reported: wall time, checksum (must equal `stw`'s for every config), promotion
MB/s, survived and overflow bytes, fallbacks, scavenge pause p50/p99/max,
bytes copied per scavenge, cycles, final-mark pause with its selection and
pin parts, relocation: blocks selected, bytes planned and moved, objects
moved, objects skipped (pinned, hazarded, no space), stores redone, spin
episodes and time, blocks freed (by epoch, at a pause), switch-to-free
delay, relocator CPU and wall time, peak RSS, and for `fragment` the
footprint series.

## Scenarios

The AppKit app and frame measurement of the previous experiment; 7
background workers, UI Process handling 1000 events/s, 1 s warm-up (after
the old heap is built for R4), 10 s measured, 3 runs, median run by missed
frames then max gap. 4 MiB nurseries.

| id | load | GC |
|---|---|---|
| R0 | none | `cm`, N = 2, relocation 50 |
| R1 | `alloc` on 7 workers (C2) | ADR 0006: `cm`, N = 1, no relocation, 64 MiB |
| R2 | R1 | N = 2 |
| R3 | R1 | N = 2, relocation 50 |
| R4 | `oldheap` 256 MiB live on 7 workers, mutating forever | N = 2, relocation `all`, cycles back to back (`force`), 576 MiB |
| R5 | `fragment` on 7 workers (paced) | N = 2, relocation 50, 512 MiB, cycles from 30 percent |
| R5n | R5 | N = 2, no relocation |
| R6 | R3 + ~100 us of Point churn on the main thread after each event (C5) | N = 2, relocation 50 |

Reported per scenario: frames, missed, drops, max gap, worst run-loop
iteration with VM work, GC park and GC enter wait inside it, every pause
kind's distribution, cycles, fallbacks, relocation activity (bytes moved,
conflicts, pins, hazards, frees), the main worker's post-store spins (count
and max), and for R5/R5n the footprint once per second. One run each of R4
and R3 with `--verify` (the mark-set verifier at every final mark and the
relocation verifier at every pause; the scavenge verifier, which builds a
Swift Set of every young object, is left to the tests), reported
separately.

## Choices (where DESIGN.md left one open)

- Age in header bits 57 to 59 (above); survivors in each worker's nursery,
  eden 3 MiB and two 512 KiB halves; survivors go to the copying
  participant's survivor-to.
- Survivors scanned as roots at the initial mark, rather than promoted.
- RELOCATING encoded as the old offset plus 2^32, readable through a second
  mapping of the heap (no read barrier, no mask), rather than a low tag bit
  (which every read would have to mask).
- Relocation runs on marker 0 before the sweep, in block order, capped by
  half the free blocks.
- Permanent pins as a header bit set at image build, frame pins as a second
  bit; both cleared only in pauses.
- The epoch advances at the poll slow path (every 1024 polls) and at parks;
  every pause frees all pending blocks.
- One new primitive, `arrayCopy`, so that the hazard protocol has a real
  user; no existing primitive needed it.
- R5 is run twice (R5 with relocation, R5n without) to give "with and
  without relocation".
