# Model check: Symbol interning without a stop

Status: built (2026-11-15) before the protocol's code, with the module
"Symbol interning without a stop" (docs/modules/symbol-interning.md,
part 2). `models/Sources/SymbolInterningModel/`, tests in
`models/Tests/SymbolInterningModelTests/`, on the shared explorer and
memory model (`ModelKit`). Any change to how a Symbol enters the table
updates the model in the same commit.

```
cd models && swift test --filter SymbolInterning
```

## What it models

One bucket of the symbol table (a weak array) behind one strong table
slot, the intern lock beside the table, interners, one lock-free reader
and one cycle of the concurrent old-space collector.

| step | production (`Sources/KajoVM/ObjectModel/Strings.swift`) |
|---|---|
| T lock-free lookup of x (finds / misses) | `Machine.intern`: `symbolLookupSlot` over the bucket, `weakReadBarrier` on a hit |
| T allocates S under the lock (fast path) / the fast allocation fails | `internSlow`: `tryAllocateAny` in the worker's old context under the lock (no poll), `makeWhole` |
| T allocates S (old, pinned, read-only) | the slow path outside the lock: `allocateOld` (a poll: stops, stalls), `makeWhole` |
| T fills S's bytes (under the lock) | `copyBytes` in `makeWhole` |
| T takes the lock / lets it go | `internLock` / `internUnlock` (`VMState.internLock`, a full fence in the model) |
| T second lookup (finds: S becomes a String / hole / full) | the lookup under the lock, `keepAliveRead` on a hit, `discardSymbol` |
| T stores S into B[i] (release) | `atomicMemoryFence(.releasing)` then `store(b, i, sym, .symbolTable)` (the post-store check's seq_cst store) |
| T allocates B' of twice the size (old, nil) | `growBucket`: `allocateOld` of a WeakArray before the lock |
| T finds the table still naming B / changed | the check under the lock (`growthRetries`) |
| T copies B into B' and stores B' into the table | the copy with `keepAliveRead` per slot, the release fence, the table store |
| T stores S into an already scanned holder and drops it / drops S | what a program does with the answer |
| R reads the table, a slot, a Symbol's bytes | a lock-free lookup a load at a time (any worker's `intern`, primitive 135) |
| initial mark (stop) | module 5's initial mark at the end of a scavenge: the snapshot, the holders traced |
| final mark (stop): weak pass, sweep | module 5's final mark: registers rescanned, every snapshot bucket's slot to an unmarked snapshot Symbol nil'ed, those Symbols freed |

Memory is ModelKit's store-buffer model: every store goes to its thread's
buffer; relaxed stores may drain ahead of older stores to other
addresses; a release store drains only when oldest. The lock is an
acquire read-modify-write performed on memory while the thread's earlier
stores may still be buffered (`pthread_mutex_lock` on arm64 is an
acquiring exclusive pair, and C++ lets earlier stores move into a
critical section), and the unlock a release store (the lock is free when
it drains, after every store of the critical section). A word never written holds `garbage`; reading it, or a
Symbol whose bytes are still the allocation's zero fill, is a read of
something not whole. Object metadata (allocated, snapshot, marked,
freed) is the collector's and changes only in stops, which are enabled
only when every thread is at a poll point (`lookup`, `allocate`,
`allocateBucket`, `stash`, `done`, the reader's first step) with its
buffer drained: the rule that nothing is decided across a poll and no
stop falls inside a critical section.

## Claims

1. **One Symbol per byte sequence** among the Symbols any thread holds
   (registers, the holders it stored into) and the table names; no
   thread holds a Symbol made for nothing.
2. **Whole reads.** A lookup never reads a bucket slot or a Symbol's
   bytes before they were written.
3. **No lost Symbol.** No Symbol a thread holds or the table's bucket
   names is freed by the sweep.
4. **Every thread finishes** (no deadlock, no retry past the model's
   objects).

## Configurations

| name | threads | first bucket | what it exercises |
|---|---|---|---|
| `sameBytes` | T0 and T1 intern A (T1 drops its answer), R looks A up | 2 empty slots | the second lookup, the suspected hole, publication |
| `bucketMates` | T0 interns A, T1 interns B (drops it), R looks A up | 1 empty slot | a growth raced by an insert of other bytes, growth retries |
| `growth` | T0 and T1 intern A (T1 drops) | 1 slot holding C, held only weakly | the growth copy of a weakly held Symbol while a cycle marks |

## Results

Two orders are modelled. Part 4 of the module changed the production
order after the model was first run: the brief's candidate made the
Symbol before taking the lock (`allocateUnderLock = false`, run
`~/kajo-scratch/symbol-interning/model/run2.txt`, every table below
held there too); production now takes the lock first, makes the Symbol
under it by the allocation fast path (no poll), and only when that has
no room lets go, makes it by the slow path (a poll) and takes the lock
again (`allocateUnderLock = true`, the default: the steps "T allocates
S under the lock (fast path)", "T fills S's bytes under the lock" and
the branch "the fast allocation fails"). The run of record for the
production order: `~/kajo-scratch/symbol-interning/model/run3.txt`
(0.32 s for all seven tests).

| configuration | order | states | longest trace | finished | result |
|---|---|--:|--:|--:|---|
| `sameBytes` | lock first | 12 778 | 32 | 22 | every claim holds |
| `sameBytes`, sequentially consistent | lock first | 3 534 | 24 | 22 | every claim holds |
| `sameBytes` | made before the lock | 8 779 | 30 | 22 | every claim holds |
| `bucketMates` | lock first | 44 003 | 58 | 89 | every claim holds |
| `bucketMates`, sequentially consistent | lock first | 12 745 | 40 | 89 | every claim holds |
| `bucketMates` | made before the lock | 29 157 | 50 | 50 | every claim holds |
| `growth` | lock first | 21 381 | 57 | 101 | every claim holds |
| `growth`, sequentially consistent | lock first | 4 329 | 38 | 101 | every claim holds |
| `growth` | made before the lock | 43 999 | 59 | 117 | every claim holds |

Each rule off finds the claim it protects broken, in both orders (the
test prints the shortest trace; the messages below are run3's, run2's
are the same):

| rule off | configuration | claim broken, as the explorer reports it |
|---|---|---|
| the second lookup | `sameBytes`, nobody drops | 1: "bytes 1 have Symbols [1, 4] held or in the table" |
| the fill before the publishing store | `sameBytes` | 2: "Symbol 1 read before its bytes were filled" |
| release publishing stores (relaxed) | `sameBytes` | 2: the slot's store drained before the fill's; T1's lock-free lookup read the Symbol's zero fill |
| release publishing stores (relaxed) | `bucketMates` | 2: the same, through a growth |
| release publishing stores (relaxed), sequentially consistent | `sameBytes` | none: the violation is the store order, nothing else |
| the keep-alive barrier on the second lookup | `sameBytes` | 3: "a thread holds S4, which the sweep freed" (the brief's hole, 24 steps) |
| the keep-alive barrier on the lock-free lookup | `sameBytes` | 3: the same through the hit path |
| the keep-alive barrier on the growth copy | `growth` | 3: "the table's bucket names S0, which the sweep freed" |

The hole's shortest trace in the first order (run2), as printed: T0 and T1 both miss A; T1
allocates S4, fills it, takes the lock, finds a hole, stores S4 into
B0[0], lets go and drops S4; the initial mark takes the snapshot (S4 in
it, held by nothing but the weak slot); T0 allocates S1 (its poll is
where the initial mark could come), fills it, takes the lock, its second
lookup finds S4 and makes S1 a String, lets go, stores S4 into a holder
already scanned and drops it; the final mark nils B0[0] and the sweep
frees S4 under the holder. The production test of the same schedule is
`aSymbolTheSecondLookupFindsDuringMarkingIsKeptAlive`.

**Modelling bugs found on the way** (the first run,
`model/run1.txt`, written down as the relocation model's was): two
switches found nothing at first, and both were the model's fault, not
the protocol's. (1) The lock was a full fence (ModelKit's
`readModifyWrite` needs an empty buffer), so the fill always drained
before the critical section began and a relaxed publishing store could
not overtake it: "relaxed publish ... no violations". The lock became an
acquire RMW and the unlock a release store, which is what the hardware
and C++ give, and the relaxed variant then fails. (2) With the second
lookup off, the model's lookup stopped at the first match, so it never
saw the hole after it and the thread grew the bucket past the model's
objects ("T1 grew past the model's objects", claim 4) instead of
inserting a duplicate. The lookup now scans the whole bucket for a hole
as `symbolSlot` does, and the variant breaks claim 1.

## Limits

Not modelled: the relocator and the post-store check (a bucket or the
table moving while the insert stores into it: the module 6 protocol
every heap store already goes through, model checked in
docs/models/relocation.md), the young collectors (Symbols and buckets
are old at birth and never remembered), the lazy sweep's deferred
apply (a freed Symbol's entry is not reused inside the model), loads
reordered with each other (ModelKit performs loads in program order,
which gives the address dependency from a slot to a Symbol's bytes; the
production readers compute every body address from the state word just
loaded), and more than one cycle. Stops are atomic steps taken where
every thread is at a poll with an empty buffer, which is the rule the
production lock keeps (no poll, park, stall or allocation while it is
held), checked at every stop by `verifyInternLockFreeAtStop` rather than
by the model.
