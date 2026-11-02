# Spec: young collection without stopping the world

Written before the collector code. Everything not stated here is as in
`../concurrent-relocation/SPEC.md` (age field, survivor spaces, relocation,
post-store check, hazard slots, epochs) and the specs below it. Where
DESIGN.md left a choice it is listed under "Choices"; where DESIGN.md's
protocol is changed the change is under "Changes to DESIGN.md's protocol",
with the reason. Instruction counts marked "(est.)" are replaced by the
disassembly in RESULTS.md.

## Package shape

`swift/` is a copy of `../concurrent-relocation/swift/`. Targets keep their
names (`Kasm`, `VMR`, `kajo-ui`, `VMRTests`) except the bench executable,
`cy-bench` (`cy-bench kernel <name> <workers>`, one key=value line).

New build flag `NO_YOUNG_BARRIER`: the cross-nursery barrier reverts to the
inherited "old holder, young value" test and the young deletion barrier is
removed. Such a build is the `adr7` reference, and with `KAJO_YOUNG=local` the
`nobarrier` cost configuration (unsound by construction; checksums are
reported, not gated). `NO_POST_STORE`, `NO_MARK_BARRIER`, `NO_BARRIER`,
`NO_BUDGET` are kept.

Runtime switches (environment, read at `Runtime` creation; all earlier ones
stay):

| variable | values | default |
|---|---|---|
| `KAJO_YOUNG` | `stw` (ADR 0007 stop-the-world scavenge), `local` (Part 1), `offload` (Part 2) | `stw` |
| `KAJO_IM` | initial mark in `local`/`offload`: `young` (Part 3 (a), young-root scan) or `scavenge` ((b), forced global scavenge) | `young` |
| `KAJO_YC_QOS` | collector thread QoS: `interactive`, `initiated`, `utility` | `initiated` |
| `KAJO_VERIFY` | adds `young`: the young verifier at a forced pause after every local collection | off |

`local` and `offload` need `KAJO_GC=cm` and N >= 1; all the matrix runs use
N = 2.

## Header word

The slot count shrinks from 32 to 24 bits (objects are at most a block, 4095
slots) to make room for a nursery index next to the young bit:

```
bits  0..21  class index
bits 22..45  slot count
bit  46      mark (full collection only)
bit  47      bytes object
bits 48..51  unused
bits 52..55  nursery index, young objects only (= worker id of the nursery)
bit  56      young
bits 57..59  age
bit  60      pinned for good
bit  61      frame pin
bits 62..63  scavenge claim tag (stop-the-world scavenge only)
```

**Nursery index: header bits, set at allocation**, not derived from the body
offset. The allocating worker's `youngMark` is `youngBit | id << 52`, so
setting it costs nothing. A young object never changes nursery in `local` and
`offload` (a local collection copies survivors into the same nursery's
survivor-to); the stop-the-world scavenge, which copies survivors into the
copying participant's survivor-to as before, writes the participant's index
with the claim CAS. Bits 52..56 are contiguous, so "young in the same nursery
as" is one `eor` and one `tst` with a logical immediate.

Mutators never write headers. A local collection writes young headers (age,
promotion) while mutators read them, so every header load is now a relaxed
atomic load (a plain `ldr`, as before); only tags and age change, never the
class or size a mutator reads.

## Spaces per worker

As ADR 0007: nursery = eden + S0 + S1 (S = nursery / 8). `local`: one eden.
`offload`: the eden is split into two halves E0 and E1 of equal size; the
worker allocates in one while the collector empties the other. **No extra
nursery bytes; the cost is half-size edens, so twice as many collections**
(see Choices).

Survivor state (S0/S1 roles, survivor-to bump, survivor-from top), the
nursery's carried remembered list and its deferred entry frees live in a
per-nursery record `Nur`, separately allocated, written only by whoever is
collecting that nursery (one at a time) or with the world stopped. The
worker's own record keeps only what the worker writes (eden bump, logs,
buffers): writing different fields of one struct from two threads is a
Swift exclusivity race (AGENTS.md).

## Remembered sets: per nursery

`rem` becomes 16 bits per table entry (bit n: the holder is in nursery n's
remembered set) and each worker has 16 remembered buffers `rem[n]`. Each
nursery record has a `carried` list (holders kept from its previous
collection). Nursery n's remembered set is the union of every worker's
`rem[n]` and `carried[n]`. Per-nursery sets let collections of different
nurseries overlap without taking holders from each other and let a local
collection scan only its own holders. The stop-the-world scavenge scans all of
them (as it scanned the single set before).

## Barriers

All on `store_ivar`, `at:put:`, `arrayCopy` and the VM-internal `store`.

**Flag word.** One global atomic word `barrierWord`: bit 0 = old-space marking
(the SATB barrier of ADR 0006, formerly the per-worker `marking` byte, set and
cleared with the world stopped), bits 1.. = 2 x the number of nurseries being
collected. The interpreter's store does one relaxed load of it; nonzero sends
the store to the one out-of-line `storeWithBarriers(w, o, i, v)`, which does
the SATB record if bit 0, the young deletion record if bits 1.., the store
with the post-store check and the insertion barrier. Same shape and count as
the inherited `marking` test (one load, one branch), now from the VM struct
instead of the worker.

**Young deletion barrier** (slow path only):
```
old = slot(o, i)                         // relaxed
if old is a pointer, header(old) young:  // one table load
   n = nursery(header(old))
   if collecting[n] (acquire): w.del[n].push(old)
```
Per-worker per-nursery deletion buffers `del[n]`. The holder may be anything,
young holders included (unlike SATB, which skips young holders).

**Cross-nursery (insertion) barrier**, after the store:
```
if v & 1 == 0:                            // tbnz
  hv = header(v)                          // ldr
  if hv & young:                          // tbz
     ho = header(o)                       // ldr
     if (ho ^ hv) & (young|nursery) != 0: // eor, tst #0x1f<<52, b.ne
        remember(w, o, nursery(hv))       // out of line
```
7 instructions to the decision when the value is young (est.), 3 when it is
not (the common case loads only the value's header; the inherited barrier
loaded the holder's header first, 5 instructions). `remember`: `bit = 1 << n`;
seq_cst load of `rem[o]`; if the bit is clear, `fetch_or`; if this call set it,
push `o` on `w.rem[n]`.

`NO_YOUNG_BARRIER`: `v & 1 == 0 && header(o) & young == 0 && header(v) &
young != 0` then `remember(w, o, nursery(hv))`, no deletion record.

## Handshakes

An **attention word** replaces `gcRequested`: bit 0 = a stop-the-world stop is
requested (the old flag), bits 1.. = 2 x the number of open handshake rounds.
The poll is unchanged: `countdown == 0 || attention != 0`, one load. The poll
slow path parks for a stop (bit 0) and services handshakes (bits 1..).

A **round** of collection k is opened by its collector C under the safepoint
mutex: `round += 1`; every worker in `vm.workers` that is outside the VM is
acknowledged by proxy (it holds no reference); every worker inside a
**blocking region** (below) is acknowledged by proxy and C performs its round
work on its flushed state under the mutex; the rest are counted in `need`.
`attention += 2` while `need > 0`. A worker services rounds at a safepoint:
under the mutex it collects the rounds it has not acknowledged, releases the
mutex, does the work, takes the mutex, publishes, decrements `need` (the last
one does `attention -= 2` and signals), and advances its epoch word.

Safepoints that service rounds: the interpreter poll, the top of
`backgroundLoop`/`runMain`, `enterVM`/`leaveVM` (proxy), and **every wait
loop of a worker inside the VM**: a collector waiting for its own round, a
worker waiting for the collector (Part 2), the eden-reuse wait, a stop
waiting for collections to drain. Marker threads and the collector thread are
not participants: they never hold a young reference.

Round kinds:

- **H0 (barrier on).** Work: clear the worker's own `del[k]` (records left
  from an earlier collection of k are stale: their entries may be free).
  Nothing else. When H0 completes, every participant has observed
  `collecting[k]` and the flag word (both stored before the round was
  opened; the acknowledgement acquires the mutex).
- **H1 (roots).** Work: scan the worker's stack (current Process from its
  base to the flushed `sp`, the `current` register (not `result`: it is
  consumed before any safepoint, and a stale one keeps a dead object), the host
  worker's host roots) for references into Y_k, mark the current Process
  scanned for k (below), publish `rem[k]` and `del[k]` (hand the buffers over,
  take empty ones).
- **H2.. (drain).** Work: publish `rem[k]` and `del[k]`.

**Blocking regions.** A primitive that may block for long without touching
the heap brackets itself with `blockingBegin`/`blockingEnd` (under the
mutex). Inside, the worker is acknowledged by proxy and C scans its flushed
stack; its epoch word is *not* advanced (it may hold a body pointer). Users:
the main worker's UI primitives (the shell hook), and the test primitive
`slowPeek` (39). `blockingEnd` services any round opened meanwhile.

## Part 1: local collection

Y_k = the young objects of nursery k: body in the eden being collected or in
survivor-from of nursery k. Test "v in Y_k": header young, nursery bits k,
body offset in [eden start, eden top) or [survivor-from start, top) (two
range compares on the offset word; `local` has one eden, `offload` the one
being collected).

Worker W (= nursery k) finds its eden full in `allocSlow`:

1. Under the mutex: wait while a stop is pending (servicing rounds, parking
   when it comes); then `collecting[k] = true` (release), `barrierWord += 2`,
   `ycActive += 1`, collection sequence `seq[k] += 1`. W retires its TLAB,
   releases its entry reservation (atomic `fetch_and` on `used`: the lazy
   sweeper and other workers touch the same bitmap), and takes its young log
   and chunk list into the collection.
2. **H0**, then **H1**. W scans its own stack directly (it is at a safepoint).
   C sets `afterH1Start[k]` before opening H1 (resumers use it, below).
3. **T1: process roots.** Under `schedLock`: set `afterT1[k]`, claim every
   live Process record that is not running and not yet scanned for k (CAS
   on its scan word, below), collect the Process oops of every live record.
   Then scan the claimed stacks, the global roots (globals, special objects,
   class table, `roots`, ready queues under `schedLock`, pending under
   `pendingLock`), the published stack roots, `carried[k]` and every published
   `rem[k]` and `del[k]` buffer.
   - A root or record v in Y_k not yet copied is **evacuated**: claim with a
     header CAS that writes the decision (survive with age + 1 into nursery
     k's survivor-to, or promote: young bit, nursery, age cleared), *then*
     the relocation copy protocol on the offset word: CAS `off -> off + R`
     (seq_cst), seq_cst fence, hazard check (hazarded: revert, wait until
     the hazard slot no longer names v, retry), word copy with relaxed
     atomics, switch (release store of the new offset). The header is
     written before the offset CAS so that a mutator whose post-store check
     fails reads the decided header in its slow path (below).
   - A copied object is pushed and its **new body** scanned for Y_k.
   - A holder H from `carried[k]` or a published `rem[k]`: `old =
     rem[H].fetch_and(~bit k)` (seq_cst); if bit k was clear, skip (a
     duplicate, or freed meanwhile); else scan H's slots (relaxed loads after
     the seq_cst RMW). If after the scan H names an object that is young in
     nursery k (a survivor), set bit k again and put H on the next
     `carried[k]`.
   - A promoted object whose new body names a survivor of k is put on the
     next `carried[k]` with bit k (as before). A promoted or surviving object
     naming a young object of another nursery j is remembered for j (into
     C's own `rem[j]`): the barrier's rule applied to the copy.
4. **H2, H3, ...**: when C's stack is empty, open a drain round; process
   what it published (and any stack roots resumers appended). **Stop after
   the first round that copied nothing.** Iterations are counted.
5. **Finish.** `collecting[k] = false`, `barrierWord -= 2`, `ycActive -= 1`
   (mutex). Entry sweep over the collection's young log (per bit, as ADR
   0007; a dead entry with a nonzero `rem` word has the word cleared and its
   free deferred to step 6). Survivor halves flip. Chunks of the log with a
   free bit go on W's private recycle list (W's entry refill takes from it
   before the global pool). The global epoch is bumped (`s`).
6. **Eden reuse (epoch rule).** Before W allocates into the old eden (and
   before deferred entries are freed), every participant's epoch word must
   exceed `s`. Workers advance it at round acknowledgements, polls (every
   1024), parks; outside the VM it is quiescent. Blocking regions keep it.
   The wait is measured (`eden_wait`).
7. **Triggers.** Old space above the soft limit: request a stop-the-world
   fallback (as before). Phase idle and above the cycle threshold: request
   the initial-mark pause. Phase `swept`: the marker requests an `apply`
   pause (below).

**Overlap.** Collections of different nurseries overlap: every structure is
per nursery (rounds, `collecting`, remembered and deletion buffers, Process
scan words, carried lists). Nothing serialises them; a collector services
other collections' rounds in its own waits and every 256 copied objects.

**Stops and collections are not interleaved.** A stop-the-world requester
first sets `stwWanted` (no collection starts while it is set), waits until
`ycActive == 0` (servicing rounds), then stops the world as before. A worker
whose eden fills while `stwWanted` is set waits for the stop and parks in it.
So no pause ever sees a collection in progress: no object is RELOCATING by a
young collector and every nursery is in a quiescent state.

## Processes

A Process's stack must be scanned once per collection of k, at a moment after
H0 has completed, while the stack is not changing. Per live Process record
and nursery there is an atomic scan word holding `seq[k]` when scanned and
`seq[k] | 2^63` while being scanned.

- The worker running it at its H1 acknowledgement scans it (CAS).
- A worker **resuming** a Process (`runSlice`, before running it) while
  collection k is past `afterH1Start` and the word is not `seq[k]`: wins the
  CAS and scans it (it is parked, so stable), or waits while C holds it.
- C at T1 claims every **parked** unscanned record under `schedLock` (a
  parked Process cannot be resumed while C holds its word: the resumer
  waits), then scans them.
- A Process **created** while k is active: scanned if `afterT1[k]` (read
  under `schedLock`, where creation happens), else not scanned.

Why this covers every Process: a Process running at T1 was either running at
its runner's H1 acknowledgement (scanned there) or resumed after H1 started
(scanned at resume); one parked at T1 is claimed by C; one created after T1
starts from values its creator held after the creator's own H1 scan, which
the argument below covers. DESIGN.md's "covered by the deletion barrier plus
the picking worker's scan" is not enough: a Process parked at H1, resumed by
a worker that acknowledged H1 earlier, before C's parked scan, would have its
stack scanned by nobody.

## Ordering and soundness

**Marking, not copying, is what must be sound.** References are oops; a copy
never changes one. A local collection is a concurrent mark of Y_k whose
action on a marked object is the copy. It frees an entry iff it did not
mark it, so soundness is: every Y_k object any mutator can reach after the
collection was marked.

Snapshot: S = (each participant's stack at its H1 scan) + (each Process
stack at its scan) + (the heap at T1, when H1 has completed and the parked
scan is about to start) + (global roots at C's scan, after T1). No Y_k object
is created after the collection starts (W is stopped in Part 1, allocates in
the other eden in Part 2), so nothing unreachable can become reachable.

1. **Every reference a mutator holds after its scan is in S or recorded.** A
   reference a mutator obtains after its H1 scan comes from a load of a heap
   slot or root at some time t > H0 completion. If the slot still holds it at
   T1 (or at C's scan, for global roots), it is a snapshot edge; if it was
   overwritten after t, the overwrite happened after H0 completed, so the
   overwriter's deletion barrier was on and the value was recorded. Global
   root writes (`globalAt:put:`) record the old value like slot stores;
   scheduler roots only name live Processes, which are all roots through the
   Process records.
2. **The heap edges into Y_k at T1 are all scanned.** Edges from Y_k objects
   are traced. Edges from any other object (old, or young of another nursery)
   are in nursery k's remembered set by the insertion barrier, which is
   always on; a holder remembered before its storer's H1 acknowledgement is
   published in H1, after it in a drain round, before termination (the
   storer acknowledges every round). A holder removed by C's `fetch_and`
   before a concurrent store re-arms itself: the storer's `stlr` store, then
   its seq_cst load of `rem` either sees the cleared bit (and pushes the
   holder again) or precedes C's RMW in the total order, in which case C's
   later slot load sees the store.
3. **Termination.** If at the request of drain round r some unmarked Y_k
   object is snapshot-reachable, the classic SATB invariant gives a path to
   it of intact snapshot edges from a grey object or an unprocessed record;
   C's stack is empty, so the head is an unprocessed record (deletion
   record, stack root appended by a resumer, or remembered holder) that
   exists before the request and is therefore published in round r: round r
   copies something. So the first round that copies nothing ends marking.
4. **Why H0 is a round of its own.** Under sequential consistency: worker B
   loads `barrierWord` (0), then C raises it and opens H1, worker A
   acknowledges and scans, A loads X (in Y_k) from an old object G, B
   overwrites the slot of G without a record (its load preceded the raise),
   B drops X and is then scanned. X is held only by A and is never found. One
   round in which every participant observes the flag must complete before
   any stack scan.
5. **Stores into objects being copied** are the post-store check of ADR 0007
   with the same seq_cst argument. The header is decided before the offset
   CAS: a mutator whose check fails reads the header after its redo (acquire
   order) and remembers an old holder of a young value if the holder was
   promoted; a mutator whose check passes stored before the CAS in the total
   order, so the copy carries the store and C's scan of the new body sees it.
6. **Promoted objects and survivors after their scan.** A store of a Y_k value
   into an object C already scanned is a post-snapshot insertion: SATB does
   not need it for this collection, and the insertion barrier (reading the
   decided header, point 5) remembers it for the next.
7. **Memory reuse.** A mutator may hold a body address between the offset load
   and the access of one instruction, or across a blocking region. The old
   eden and survivor-from are reused only after every participant passed a
   safepoint after the last switch (step 6). Remembered holders of other
   nurseries that die are freed only after the same epoch, so a collector
   scanning a stale holder never sees its entry reallocated mid-scan.

## Part 2: offloaded collection

W's eden half fills: W waits if the previous collection of its nursery is
still running (counted, timed) or the epoch of the half it is about to reuse
has not passed; then, under the mutex, it opens collection k as in step 1
(retire TLAB, release reservation, hand the young log and chunk list to the
collection, `collecting[k]`, flag word), records the half being collected,
switches its TLAB to the other half, enqueues k for the collector and
returns. **W's pause is the flip.** W's stack is scanned at its H1
acknowledgement like everyone else's: a stack scan taken at the flip, before
H0 completes, would be unsound by point 4.

One **young collector thread** per VM runs steps 2 to 7 for queued nurseries
in FIFO order. It is a marker-like participant record (parks through stops,
not a round participant). Its QoS is `user-initiated` (set deliberately: at
`utility` it would share efficiency cores with the marker while eight workers
run; see AGENTS.md). Collections are serialised on it.

Main-thread pause report: flip, wait for the collector, eden-reuse wait,
round acknowledgements for its own and for other nurseries' collections,
and stop-the-world events by kind.

## Part 3: initial mark without a global scavenge

In `local`/`offload` the cycle starts with an **initial-mark pause** that does
not scavenge (`KAJO_IM=young`, (a)):

1. snapshot bitmap = `used` minus every bit in every nursery's young log
   (eden objects and survivors), as ADR 0007 did for survivors;
2. roots greyed as before;
3. **young-root scan**: for every nursery, walk the bodies of its active eden
   `[start, top)` and survivor-from `[start, top)` linearly (each body starts
   with its back reference: entry and size); a body whose entry's offset is
   this body (live or dead, not a stale copy) has its slots scanned and every
   unmarked snapshot entry it names greyed.

Soundness: the marking snapshot needs every old object reachable at the
snapshot to be marked. A path from a root to an old object either runs
through old objects only (traced) or its last young object names the first
old one after it; every young object is scanned at the snapshot, so that old
object is grey. Young objects are not snapshot entries; overwrites of their
slots need no SATB record (the barrier keeps skipping young holders), because
everything they named at the snapshot is grey. Objects promoted by local
collections during marking are not snapshot entries (their entries were young
at the snapshot): black. With no collection in progress at a pause (above),
every young body is in an active eden or a survivor-from.

`KAJO_IM=scavenge` ((b)): the initial-mark pause runs the stop-the-world
scavenge of every nursery first, then the ADR 0007 survivor scan. Kept for the
comparison. Test switch `youngRoots = false` drops step 3; the inherited
lost-object test must then fail.

**Apply.** The lazy sweep's results are published at "the next pause". With
no scavenge pauses the marker requests a short `apply` pause when the sweep
finishes.

## Stop-the-world scavenge in this VM

Used by `stw` (the reference), by (b) and by fallbacks. As ADR 0007 except:
remembered tasks come from every worker's 16 buffers and every carried list;
young holders found there are dropped (bits cleared; they are traced if
reachable); after the copy every scanned holder (remembered or copied) is
re-remembered per nursery of each young value it names (`nextRem[n]` of the
participant, swapped in at the end); the claim CAS writes the participant's
nursery index for a survivor; in `offload` the active eden half is collected.

## Young verifier

`KAJO_VERIFY=young` and tests: after every local collection C requests a
`verify` pause. With the world stopped, a from-scratch walk from every root
(the stop's root ranges, which include every Process stack) through every
reachable object checks: its entry is used; a young object's nursery index
equals the nursery its body lies in and the body lies in that nursery's
active eden or survivor-from (not in a reusable eden half, not in
survivor-to); an old object's body is not in a nursery; no entry is
RELOCATING. The relocation verifier (every pause) and mark verifier (final
mark) stay under `KAJO_VERIFY=cm`.

## Test-only switches (`YCConfig`)

`youngDeletion`, `crossNursery`, `stackScan`, `epochRule`, `secondHandshake`
(drain rounds after the first), `youngRoots`, `carryRem`, each default true;
a hook called by the collector after H1 completes and before T1 (tests hold a
collection there). Each rule gets a test that passes with it and fails with
it off.

## Kernels

All earlier kernels read in place. New: `share` (`kernels/share.kasm`):
3 000 000 iterations split between workers; per iteration a 3-slot Box in the
worker's nursery deposited into a shared Array of 256 slots per worker
(global 5, created by the host), an Array of 4 as garbage, and every second
iteration the neighbour's Box at the same position taken, checked, its chain
link followed and checked, and kept in the worker's ring of 512. Checksum
independent of timing (see the file).

## Headless matrix

Kernels `arith fib sends ivars storeheavy alloc churn survivors5 survivors30
oldheap64 fragment share` x 1 and 8 workers x 5 interleaved runs, medians,
4 MiB nurseries, `KAJO_GC=cm`, N = 2; `alloc` and `survivors30` also at 16 MiB.

| config | build | young |
|---|---|---|
| `orig` | `../concurrent-relocation`'s `cr-bench`, unmodified | (ADR 0007) |
| `adr7` | `-DNO_YOUNG_BARRIER` | `stw` (reference; checksum gate) |
| `adr7b` | default | `stw`: barriers compiled in, local collection off |
| `local` | default | `local` |
| `offload` | default | `offload` |
| `nobarrier` | `-DNO_YOUNG_BARRIER` | `local` (cost only) |

Barrier cost = `adr7b` / `adr7`; collection cost (lost parallelism) =
`local` / `adr7b`. Also an `orig`/`adr7` ratio, because the header layout,
per-nursery remembered sets and attention word are in every configuration.

## Scenarios

The AppKit app, 120 Hz, 10 s after 1 s warm-up, 3 runs, median by missed
frames then max gap; 7 background workers (8 for Y6), 4 MiB nurseries, N = 2,
`KAJO_GC=cm`, relocation off.

| id | load | young |
|---|---|---|
| Y0 | none | `offload` |
| Y1 | storm (`alloc` on 7 workers) | `stw` |
| Y2 | storm | `local` |
| Y3 | storm | `offload` |
| Y4l / Y4o | fragmentation ring (R5, relocation 50) | `local` / `offload` |
| Y5l / Y5o | ~100 us of Point churn on the main thread after every event (R6's C5 load), idle workers | `local` / `offload` |
| Y6 | `share` on 8 workers | `offload` |

Main-thread attribution per run: own collection (Part 1) or flip (Part 2),
waiting for the collector, eden-reuse wait, round acknowledgements for its
own nursery and for others (count, total), stop-the-world events by kind
(count, total, with who requested scavenges), and wait time (mutex and stop
waits at enter) apart from work. The headline line: **main-thread time
stopped because another worker allocated** = stop-the-world scavenges
requested by another worker + round acknowledgements for other nurseries +
waits on other workers' collections. Old-space cycle pauses are listed on
their own line.

## Choices (where DESIGN.md left one open)

- Nursery index in header bits 52..55 at allocation, not from the body
  offset (one `eor` + `tst`; no division).
- Per-nursery remembered sets and deletion buffers, so collections overlap
  without a lock.
- Part 2's two edens are the halves of the inherited eden: no extra memory,
  twice the collections. Survivor halves unchanged.
- One collector thread at `user-initiated`.
- Survivors of a local collection stay in their nursery.
- Stops never overlap collections (stops wait for collections).
- The epoch rule reuses ADR 0007's epoch words; acknowledgements advance them.
- Blocking regions for the main thread's UI primitives (they otherwise bound
  handshake latency by AppKit calls).

## Changes to DESIGN.md's protocol

1. **H0 before the root handshake** (soundness point 4): DESIGN.md raised the
   barrier with acquire/release and scanned stacks in the same handshake.
2. **No stack scan at W's flip in Part 2**: W's stack is scanned in H1 (same
   reason). W's pause is the flip.
3. **Process scan words** instead of "the picking worker's scan" (section
   Processes).
4. **Deletion buffers are cleared at H0**: records from an earlier collection
   can name freed entries.
5. **Remembered holders are cleared with a seq_cst `fetch_and` before they
   are scanned**, and re-armed after, instead of after: clearing after the
   scan loses a concurrent insertion.
6. **Dead remembered young entries are freed after the epoch**, not at the
   sweep.
