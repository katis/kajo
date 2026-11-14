# Symbol interning without a stop

Status: briefed 2026-11-13 (the owner, the same day: "do it after
gate-speed"). Not built.

## What it is

A new Symbol is made and put into the symbol table with the world stopped
(`Machine.internSlow` in `Sources/KajoVM/ObjectModel/Strings.swift`, 8b's
rule that two workers never intern the same bytes twice). Looking up a
Symbol that exists does not stop. The stop was free on one worker and is
three quarters of a run on eight: AOT 1 ran the comparison's `collections`
program at 8 workers for the first time and it took 31.6 s interpreted and
30.5 s native against 4.36 and 2.37 at 1 worker.

AGENTS.md has the lesson already: a stop per operation is a per-operation
cost that grows with the workers, and anything a program can do in a loop
is measured at 8 workers before a stop is accepted as its mechanism.
`asSymbol` on a new String is such an operation; installing a method and
defining a class are not, and they keep their stops.

## What is known (measured 2026-11-12, the interpreter, dcb6075)

The dictionary part's keys are `('k', i printString) asSymbol` for 200 000
`i` (`experiments/runtime-comparison/programs/collections-dict`). Every
worker runs the whole program.

| workers | run s | intern stops | time to safepoint per stop |
|---|---|---|---|
| 1 | 4.4 | about 200 000 | 0.7 µs |
| 2 | 5.9 | about 200 000 | 3.9 µs |
| 4 | 8.6 | about 200 000 | 14 µs |
| 8 | 32.7 | 268 984 | 86 µs |

At 8 workers 24.5 s of the 32.7 are stopped and 167 of 262 worker-seconds
are parked. Each stop also bumps the safepoint epoch, so every worker
flushes its method cache when it next looks (`noteEpoch` in
`Workers/Safepoint.swift`). The 8-worker run interns more than 200 000
because the marker's cycles free Symbols between passes and they are
interned again: the table is weak.

## The code as it stands

- `Machine.intern` (`Strings.swift`): hash, `symbolLookupSlot` over the
  bucket, the weak read barrier on a hit, else `internSlow`.
- `internSlow`: `stopWorld(retry: true, keeping: [o])`, and inside it
  `insertSymbol`: look up again; allocate the Symbol through the object
  memory with the stop's roots; copy the bytes; pin it for good; make it
  read-only; store it into a nil slot of its bucket, or replace a full
  bucket by one twice its size (the old one's Symbols copied through
  `keepAliveRead`), and store the new bucket into the table.
- The table (`ObjectModel/Symbols.swift`): an Array of 1024 buckets, each
  nil or a WeakArray; a lookup scans its whole bucket (a hole is no end)
  and compares count and bytes of every Symbol in it; a bucket grows 4, 8,
  … 4095.
- Primitive 129 interns, primitive 135 looks up without interning.
  `Image.intern` (`Loader/Image.swift`) is the host's and the loader's
  insert, with no VM running or in a stop; `Interpreter.swift:78` uses it.
- `StoreKind.symbolTable` names the four stores ("in a stop").
- `Machine.allocateOld` already allocates an old object outside a stop,
  with the allocation stalls and a held object.

## A suspected hole, to be settled first

`insertSymbol`'s second lookup answers the Symbol it finds with no
keep-alive barrier (`if again != .none { return again }`). The Symbol it
finds was interned by another worker after this worker's miss. If that
worker dropped it, and a scavenge with an initial mark came before this
worker's own stop (it parks for both inside `stopWorld`'s retry loop), the
Symbol is a snapshot entry held only weakly, and this worker receives it
through a weak read with no barrier: stored into an already scanned
object, it would be swept under a live reference. This is a reading, not a
finding. Part 1 writes the test (the schedule forced with test switches or
the stress modes, the mark verifier as the judge) and says whether it
fails on the starting commit. If it does, it is fixed in its own commit
before anything else, whatever the protocol becomes; if it cannot happen,
the doc says why.

## Part 1: measure, nothing built

1. Give the intern stop its own stop kind (`intern`), so the rows say
   what they count; today it is in `other`. Instrumentation, kept.
2. `collections` and `collections-dict` at 1, 2, 4 and 8 workers, both
   engines, five interleaved runs: wall, intern stops, their time to
   safepoint and pause (p50, p99, max, the last parker and how it parked,
   from `stopsByKind`), worker-seconds parked, sends, and the method
   cache's misses, so the flush's share is a number.
3. The lookup alone, by table size: a hit and a miss at 1000, 10 000,
   100 000 and 1 000 000 Symbols (ns each, and the dependent misses: a
   bucket of 200 Symbols is 200 entries and 200 headers read). With
   200 000 Symbols a bucket holds about 195. If the scan is the next
   cost once the stop is gone, the module must know before it sets its
   bar.
4. A cheating build, not committed: the insert under one global lock
   with no stop, run where that is safe enough to time (say what was
   switched off to make it so). It bounds what the module can win at 8
   workers before the protocol is designed. If the ceiling is far from
   the 1-worker time, find out what else there is (the scan, old
   allocation, `printString`) before building.
5. Whether any other operation a program can loop on shares the shape
   (`Symbol` lookups by `perform:` with a String, `asSymbol` on an
   existing Symbol's bytes, `Symbol new`); a list with a measurement
   each, not a fix.

Parts 2 to 4 are decided from what part 1 printed. Where it contradicts
this brief, the doc says so and the module builds what the measurement
asks for.

## Part 2: the protocol

The candidate, to be confirmed or replaced by part 1:

- A miss allocates the Symbol before it takes anything: old at birth
  (`allocateOld`, with its stalls and the String held), bytes copied,
  pinned for good, read-only, complete before any other thread can see
  it.
- Then one lock beside the table (not in a struct it guards; one
  sub-state per lock), held for a critical section with no allocation,
  no poll, no stall and no park in it: look the bytes up again (with the
  keep-alive barrier on a hit; the Symbol just made is then garbage,
  counted), else store the Symbol into a hole of its bucket.
- A full bucket: read its size under the lock, let go, allocate the
  larger bucket (old), take the lock again and check that the bucket is
  still the one measured (else again), copy with `keepAliveRead`, add
  the Symbol, publish the bucket into the table.
- Lookups stay lock-free. A lookup that misses a Symbol being inserted
  takes the slow path and finds it under the lock.

One lock for the table or one per bucket is part 1's contention number
to decide, not a preference.

What the protocol must keep, each with its argument in the doc and a
test or a model claim:

1. One Symbol per byte sequence among the Symbols any worker can hold.
2. A lookup never reads a Symbol or a bucket that is not whole: the
   publishing store is ordered after the fill, and every store a
   barrier's load follows is seq_cst or fenced (the young-collection
   model's finding). Lock-free readers' loads of a slot a writer may
   store are relaxed atomics, for ThreadSanitizer and for C++.
3. No Symbol a worker received is swept under it: every read of a weak
   slot that hands its value on goes through the keep-alive barrier, the
   second lookup included.
4. Nothing is decided across a poll. The lock is never held where the
   holder can park, stall or allocate; so a stop whose own work interns
   (method installation, class definition, the host between slices)
   finds the lock free, and a save's hold never meets a half-done
   insert.
5. A worker waiting for the lock is waiting inside the VM: either the
   wait is so short by rule 4 that no stop can be kept waiting more
   than the critical section (say the bound and measure it), or it is a
   wait a stop request wakes.
6. The collectors, each named with what it reads of the table and why
   the insert is safe beside it running: the scavenge and module 7's
   young collections (Symbols and buckets are old; is the table ever a
   remembered holder?), the marker and its final mark's weak pass (a
   bucket born after the snapshot is not a snapshot entry: the existing
   comment's argument, now with the marker running during the copy), the
   lazy sweep and the bounded sweep stop, the relocator (buckets move;
   Symbols are pinned; the post-store check on every store), the full
   collection and compaction.
7. Every other reader of the table, listed in one table in the doc as
   AGENTS.md asks whenever a protocol changes who writes when: primitive
   135, `Image.intern` and the image's lookups, `symbolCount`, the
   snapshot writer and the loader, the verifiers, the walks of
   primitives 167 to 170 (a Symbol being built is complete before its
   maker's next poll, or it carries the building mark), the save.
8. The method cache. The stop's epoch bump flushed every cache; without
   the stop a new Symbol flushes nothing. Say why no cache line can name
   a new Symbol's entry from an earlier life (when is an old entry freed
   and reused, and is every such free behind a pause all workers noted),
   and test it: a selector collected and interned again must not find
   the old line.
9. The table's shape and the image format do not change; an image saved
   by the new code loads in the old loader's rules and the other way
   round. If part 1 shows the bucket scan is the larger cost, that is an
   open question with its numbers and a recommendation, not a change
   made here.

The model comes before the protocol's code: a new model in `models/`
(`docs/models/symbol-interning.md`) with two interners of the same bytes,
one of other bytes into the same bucket, a lock-free reader, a bucket
growth and a marking cycle with its final mark, claiming rules 1 to 3;
each switch off must find its violation (no second lookup: two Symbols;
publish before fill: a half-built read; no keep-alive on the second
lookup or the growth copy: a lost Symbol; a relaxed publishing store
where the barrier's load follows). A "violation" that is the model's own
bug is written down as such, as the relocation model's was.

## Part 3: tests and broken variants

- Written before the protocol and failing without the rule: N workers
  intern the same and different bytes and every pair of answers for the
  same bytes is identical; Symbols dropped, collected and interned again
  across marking cycles; a bucket grown through every size to 4095 and
  the refusal past it (`grownBucketSize` answers nil: what does the
  program see, and is it a value, not a trap).
- Under the stress modes that reach the paths: a stop at every poll,
  `collectAtEveryAllocation`, `markingAlwaysOn`,
  `relocateEveryLiveBlock`, `youngBarrierAlwaysOn`, the slowed marker,
  both young modes and the oracle; under ThreadSanitizer alone and with
  the twelve loops; natively as well as interpreted.
- The random programs gain an intern step if they have none (new bytes,
  bytes interned before, bytes of a Symbol dropped earlier), and the
  model they agree with knows a Symbol by its bytes.
- A verifier: no two Symbols in the table with the same bytes, every
  Symbol in its hash's bucket, pinned for good and read-only. It is
  O(symbols): run it at the pauses that follow inserts, not at every
  stop, and measure its own cost under load (the relocation verifier's
  lesson).
- Broken variants as test switches where the failure is a check (no
  second lookup, publish before fill, no keep-alive), by hand with the
  message recorded where it is a trap, skipped under the sanitizer only
  where the variant is a data race by construction.
- Counters on the run line: Symbols interned, second lookups that found
  one (the Symbol made for nothing), bucket growths and their retries,
  the lock's contended acquisitions and the longest hold.

## Part 4: after

- Part 1's table again, both engines, with the comparison's rows
  (`docs/performance/README.md`, the collections rows at 8 workers that
  section 10 flagged).
- 0 intern stops in every row.
- The aligned A/B on every kernel against the starting commit,
  `interpret` identical instruction for instruction, `just arc-check`
  (the lookup's fast path gains nothing; the slow path is one
  out-of-line call).
- The Mac's and the iPhone's matrices by the tier's gates; no row is
  expected to move, and one that does is explained from its records.

## The bar

- `collections` at 8 workers takes at most 1.5 times its 1-worker time
  in both engines (7.4 and 12.9 times today), or the doc shows from part
  1's numbers what the remaining factor is and that it is not the
  insert.
- No intern stop exists. The uniqueness tests and the model's claims
  hold, and each broken variant fails where it should.
- Kernels within noise, `interpret` identical.
- The core tier through `just check <starting commit>` on the final
  code commit, every gate passing, its `gates.log` quoted.

## Rules of the house that bind here

AGENTS.md's list is binding; the ones this module lives on: the roots
are the problem, never the copying; write the lost-object test before
the protocol; a model with switches is believed only when each switch
off finds its violation; a barrier belongs to the slot; every entry
state needs exactly one owner; a lock lives beside the struct it guards;
every wait inside the VM is a place a stop must reach; a loop that polls
re-reads what it holds of the heap after the poll; a test that asserts
parallelism runs long enough to see it; a new suite runs once under the
sanitizer with a dozen loops before the long gate run; a first
measurement at a new worker count measures everything.

## Deliverables

1. Part 1's numbers and what they decided, with the cheating build's
   ceiling.
2. The suspected hole: a failing test and a fix, or the reason it
   cannot happen.
3. The model, its claims and its switches.
4. The protocol, with the readers' table and the collectors' arguments.
5. The tests, the verifier, the broken variants, the counters.
6. Part 4's tables and the comparison's rows.
7. The gates.

## Open questions

None at the brief. The table's shape, if part 1 finds the scan is the
larger cost, comes back as one.
