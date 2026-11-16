# Symbol interning without a stop

Status: briefed 2026-11-13 (the owner, the same day: "do it after
gate-speed"). Built 2026-11-15 ("As built" below).

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

## As built

Built 2026-11-15 on master from 9c5e984, the toolchain first on PATH
swift.org's 6.4.2 through swiftly (`~/.swiftly/bin`, as
`~/kajo-scratch/stall-tests/check/env.txt`). Raw files are under
`~/kajo-scratch/symbol-interning/` (`p1/` part 1, `hole/`, `model/`,
`p4/` part 4, `check/` the gates); every number below names its file.

### Part 1: what was measured

**The `intern` stop kind** (6361677): a new Symbol's stop is its own
kind in the stop records and in `stopsByKind`, and the run line carries
`internStops`, `internStopNs` and `internTtspNs` as totals (the stop log
is a ring of 65 536 records and a run makes up to 285 000 intern stops)
and `symbolsInterned`. Kept as instrumentation (after part 2 the kind
never occurs; the counters read 0 in every row).

**The matrix** (`p1/matrix-raw.txt`, summary `p1/matrix-summary.md`,
script `p1/matrix.sh`): `collections` and `collections-dict` at 1, 2, 4
and 8 workers, interpreted and native (each image's own module, `kajo
aot` and `clang -O2`), five interleaved rounds on the mini, every run at
thermal nominal, checksums equal, the aligned release build of 6361677.
Medians (range):

| program | engine | workers | wall ms | intern stops | pause mean µs | ttsp mean µs | parked worker-s | cache misses M | cache flushes M |
|---|---|--:|--:|--:|--:|--:|--:|--:|--:|
| collections | interp | 1 | 4352 (4333-4379) | 200 000 | 0.7 | 0.0 | 0.0 | 2.8 | 0.2 |
| collections | interp | 2 | 5842 (5815-5868) | 200 000 | 5.2 | 3.7 | 1.5 | 4.1 | 0.4 |
| collections | interp | 4 | 8437 (8381-8723) | 200 010 | 15.6 | 13.4 | 10.4 | 7.7 | 0.8 |
| collections | interp | 8 | 32 484 (32 292-32 758) | 268 903 | 90.7 | 85.0 | 165.8 | 14.5 | 2.2 |
| collections | native | 1 | 2329 (2305-2360) | 200 000 | 0.7 | 0.0 | 0.0 | 2.8 | 0.2 |
| collections | native | 2 | 3817 (3808-3841) | 200 000 | 5.5 | 3.9 | 1.5 | 4.2 | 0.4 |
| collections | native | 4 | 8131 (6365-8308) | 285 795 | 15.8 | 13.6 | 15.1 | 8.6 | 1.1 |
| collections | native | 8 | 31 520 (31 176-31 736) | 280 296 | 91.1 | 85.2 | 174.1 | 14.3 | 2.2 |
| collections-dict | interp | 1 | 1601 (1589-1624) | 200 000 | 0.7 | 0.0 | 0.0 | 2.8 | 0.2 |
| collections-dict | interp | 8 | 30 059 (29 776-30 351) | 272 657 | 91.0 | 85.2 | 169.2 | 14.6 | 2.2 |
| collections-dict | native | 1 | 1139 (1136-1157) | 200 000 | 0.7 | 0.0 | 0.0 | 2.8 | 0.2 |
| collections-dict | native | 8 | 30 584 (30 413-30 736) | 283 833 | 91.1 | 85.3 | 176.6 | 14.3 | 2.3 |

(2 and 4 workers of `collections-dict` are in the summary file.) The
pause percentiles over the ring (all stop kinds, the intern stops nearly
all of them) are p50 0.001 / p99 0.001 ms at 1 worker and 0.091 / 0.138
ms at 8; the ring's longest intern stop 0.22 to 0.35 ms, its last parker
a background worker parked at a poll (`w4/poll`, `w7/poll`; once
`w8/stopper`, a worker that was itself asking for an intern stop). Every
worker runs the whole program, so 8 workers do 8 times the work: the
sends are 57.1 M at 1 worker and 456.8 M at 8. `symbolsInterned` is
200 000 in every row: of 268 903 stops at 8 workers 68 903 found the
Symbol already inserted inside the stop (another worker's stop came
first). At 8 workers 24.4 s of the 32.5 are intern stops (268 903 x
90.7 µs), and 166 of 260 worker-seconds are parked: the brief's numbers
reproduce.

**The flush's share** (`p1/cheat-raw.txt`, the same runs under the
cheating build, which bumps no epoch): the method cache misses
are 2.80 M against 1.20 M at 1 worker and 14.5 M against 9.6 M at 8, so
the stop's flush costs about 1.6 M extra misses per 200 000 interns
(eight per intern); at 1 worker the stop and its flush together are
4350 against 4165 ms (4 percent), at 8 workers the flush is noise
beside the stop.

**The lookup alone by table size** (`p1/lookup/UndefinedObject.extension.st`,
run at 1 worker, `p1/lookup-raw.txt` holds the Transcript lines and the
run line): 200 000 hits (`asSymbol` on a String copy, primitive 129's
fast path) and 200 000 misses (`Symbol lookup:` of bytes never
interned, primitive 135) at each table size, the loop's own cost
(`yourself`) beside them:

| Symbols in the table | loop ns | hit ns | miss ns | Symbols per bucket (mean) |
|--:|--:|--:|--:|--:|
| 3 140 | 34 | 80 | 75 | 3 |
| 12 140 | 32 | 109 | 86 | 12 |
| 102 140 | 32 | 245 | 195 | 100 |
| 1 002 140 | 32 | 4443 | 2521 | 979 |

A hit compares the count of every Symbol before it in the bucket and a
miss of every Symbol in it; each comparison is a slot load, an entry
(state word) load and a header load, so a bucket of 979 is about 2900
dependent loads, most of them misses at a million Symbols. At the 200 000
Symbols of `collections` a bucket holds about 195 and a hit costs about
0.3 µs; the program's 600 000 `asSymbol` per worker cost about 0.15 s of
its 1.6 s (dict) at 1 worker. The scan is not the cost that matters
here (the stop is, by two orders of magnitude at 8 workers), but at a
million Symbols it is 4.4 µs a hit: an open question below, not a
change made here (rule 9).

**The cheating build** (never committed; `p1/cheat.py` applied to a
`git archive` of 6361677 in `cheat-src/`, built into `build-cheat/`,
removed before the hand-back): the intern stop replaced by one global
mutex around the same insert. What was switched off to make that safe
enough to time: the insert's allocation can fall back to a full
collection with no stop, so both builds ran with `--heap 3072` (8192
is past the 4 GiB address limit, `p1/cheat-raw.txt`'s first attempt),
and every cheating line reads `fullCollections=0`, `collections=0`;
nothing flushes the method caches (no stop, no epoch); the second
lookup has no keep-alive barrier (the hole below; the runs' marking
cycles found nothing missed, which proves nothing). Three interleaved
rounds against the starting build with the same heap
(`p1/cheat-raw.txt`, summary `p1/cheat-summary.md`):

| program | engine | 1 worker ms | 8 workers ms | 8 / 1 | starting build 8 / 1 |
|---|---|--:|--:|--:|--:|
| collections | interp | 4165 | 4847 | 1.16 | 7.54 (32 820 / 4350) |
| collections | native | 2163 | 2844 | 1.31 | 13.5 (31 774 / 2346) |
| collections-dict | interp | 1422 | 2002 | 1.41 | 18.8 |
| collections-dict | native | 989 | 1642 | 1.66 | 26.6 |

So one global lock with no stop already brings `collections` under the
bar's 1.5 in both engines: the ceiling is near the 1-worker time and the
module does not need a lock per bucket; part 2 builds the one lock. The
dictionary part alone, natively, is 1.66: its 8 workers intern the same
200 000 Symbols in step, and the extra half second is the serialised
inserts and allocation of eight times the Strings; it is not the bar's
row.

**Other operations of the same shape** (`p1/others-*/`,
`p1/others-raw.txt`, 1 and 8 workers, the starting build): `asSymbol`
on the bytes of an existing Symbol, 1 000 000 times: 58.8 and 60.2 ms,
0 stops (a hit never stops); `Symbol lookup:` of bytes never interned,
1 000 000 times: 46.6 and 51.6 ms, 0 stops (primitive 135 never
inserts); `perform:` with a selector made by `asSymbol` from a String,
1 000 000 times: 82.9 and 81.8 ms, 0 stops, and `perform:` with a String
is an Error (primitive 89 fails, `perform: needs a Symbol`), no intern;
`Symbol new` and `Symbol basicNew: 3`, 100 000 times each: every one an
Error (`shouldNotImplement`, and the instantiation primitive refuses
Symbol), 0 stops, so no program makes a Symbol outside the table. The
operations a program can loop on that still stop are the ones the brief
keeps (installing a method, defining a class) and the walks of
primitives 167 to 170 (one stop each by design); none is in a
benchmark's loop.

**What part 1 decided.** The brief held: the stop is the cost, a single
lock is enough (the cheating build's ceiling, 1.16 and 1.31), the scan
is the next cost only at a million Symbols. One deviation from the
candidate: a bucket with no hole is grown before the Symbol is made
(the candidate made the Symbol and then grew), so no Symbol is held
across the bucket's allocation, a poll at which an instance walk could
have answered a Symbol not yet in the table.

### The suspected hole: real, fixed first

`Tests/KajoVMTests/ObjectModel/SymbolInterningTests.swift`,
`aSymbolTheSecondLookupFindsDuringMarkingIsKeptAlive`: a Process
interns `zzHole` and drops it; a scavenge, `startCycle` and a mark step
scan the holder H, the table and the bucket but not the Symbol (held
only weakly); the host worker then runs `Machine.internSlow` alone (the
schedule in which its lock-free lookup missed just before another
worker's insert, no switch in the fast path) and stores the answer into
H; the final mark follows. On the code of 6361677 (the intern stop) it
fails: `missed 1` (`hole/before-fix.txt`: "Expectation failed: missed
== 0 && alive ... missed 1"). The fix is the keep-alive barrier on the
second lookup (`keepAliveRead` on the slot it read), with the test
switch `internNoKeepAlive` as the broken variant the test also runs;
after it the test passes, with the bucket-growth and weak-symbol tests
beside it (`hole/after-fix.txt`). The fix came in its own commit before
the protocol, on the stop-based insert, and the protocol keeps it.

### The model

`docs/models/symbol-interning.md` (aba0ad4), built before the protocol's
code. Claims: one Symbol per byte sequence among what threads hold and
the table names; lookups read only whole buckets and Symbols; no Symbol
held is swept; every thread finishes. Three configurations (`sameBytes`,
`bucketMates`, `growth`), each under the store-buffer model and under
sequential consistency, hold every claim (8 779 to 43 999 states,
`~/kajo-scratch/symbol-interning/model/run2.txt`). Each switch off finds
its violation: no second lookup, claim 1 ("bytes 1 have Symbols [1, 4]");
publish before fill and relaxed publishing stores, claim 2 ("Symbol 1
read before its bytes were filled", also through a growth; nothing under
sequential consistency, so the violation is the store order); no
keep-alive on the second lookup, on the lock-free hit or on the growth
copy, claim 3 (the hole's 24-step trace; "the table's bucket names S0,
which the sweep freed"). Two of the first run's "passes" were modelling
bugs, written down in the model's doc (`model/run1.txt`): the lock had
been a full fence, which hid the relaxed store's reordering, and the
model's lookup stopped at its match and never saw the hole behind it.

### The protocol (part 2)

`Sources/KajoVM/ObjectModel/Strings.swift`: `Machine.intern` is
unchanged (the lock-free lookup, the weak read barrier on a hit, then
`internSlow`). `internSlow` no longer stops the world:

1. If the bucket of the hash has no hole (a hint read without the lock),
   `growBucket` first: the larger WeakArray is allocated old
   (`allocateOld`, a poll, with the allocation stalls; the String held),
   then under the lock the table must still name the bucket measured
   (else the new one is garbage, `internGrowthRetries`), the old slots
   are copied each through `keepAliveRead`, a release fence, and the
   new bucket is stored into the table. Then again from the top. The
   brief's candidate made the Symbol first; growing first means no
   Symbol is ever held across an allocation (an instance walk in a stop
   at that poll could have answered a Symbol not in the table).
2. Under `VMState.internLock` (a mutex beside `VMState.intern`, the
   counters it guards, never inside them): the bytes are looked up
   again; a hit goes through `keepAliveRead` (the hole's fix, kept) and
   is answered (`internFoundUnderLock`). Else, with a hole in the bucket
   (`symbolSlot`), the Symbol is made by the allocation fast path,
   `tryAllocateAny` in the worker's own old context (a bump; it may
   take a block from the pool, never polls, stalls or parks), and made
   whole there (`makeWhole`: bytes, `pinForGood`, `setReadOnly`, all by
   the allocating worker before the oop escapes); a release fence; the
   ordinary barriered store into the hole (SATB, the post-store check's
   seq_cst store and reload, the insertion barrier). A bucket filled
   between the hint and the lock: let go, grow, again
   (`internBucketFilled`).
3. When the fast path has no room (its context's block and pool are
   out, or the name is larger than one block), the lock is let go and
   the Symbol is made whole outside it by `allocateOld` (a poll, with
   the allocation stalls; the String held; `internSlowAllocations`),
   then the lock is taken again and step 2 repeats with that Symbol. If
   the second lookup then finds the bytes, or the bucket must grow, the
   Symbol made is turned into a String (`discardSymbol`: its class index
   swapped with one relaxed atomic store; nobody saw it and no poll
   passed since it was made, so no instance walk can answer two Symbols
   of the same bytes) and counted `internMadeForNothing`.
4. The critical section holds no poll, stall or park and no allocation
   that can do one: two lookups over at most 4095 slots, at most one
   fast-path allocation and a copy of the name's bytes, or at most 4095
   copied slots, and three stores. Its length is measured
   (`internHoldMeanUs`, `internHoldMaxUs`), its contended acquisitions
   and their wait counted (`internContended`, `internWaitNs`).

**The order is part 4's, not the brief's.** The brief's candidate made
the Symbol before taking the lock (built so first, 3eea94b). Part 4's
first matrix (`p4/matrix-raw-made-before-lock.txt`, summary
`p4/matrix-summary-made-before-lock.md`) showed what it costs when
eight workers intern the same bytes in step, as `collections` does: 137
000 Symbols a run made for nothing (each an old allocation, pinned, then
garbage), `collections` at 8 workers 5786 ms (4882-6395) interpreted
against 4226 at 1 (1.37) and natively 3538 (3050-3873) against 2176
(1.63, past the bar). With the lock first and the fast path under it
(f117715) no Symbol is made for nothing in those runs
(`internMadeForNothing` 0 in every 8-worker row) and the rows below
follow. The model has both orders (`allocateUnderLock`).

Failure is a value as before: no room or a bucket at 4095 answers
`.none`, primitive 129 fails and the kernel's `asSymbol` reports
`primitiveFailed`. Without a VM (the module 2 interpreter, one thread)
the same code runs with no lock.

**What the protocol keeps** (the brief's nine rules):

1. One Symbol per byte sequence: every insert looks again under the one
   lock that every insert holds; a Symbol made outside the lock for
   nothing becomes a String before anything can see it. Model claim 1;
   tests `workersInterningTheSameBytesAtOnceGetOneSymbol`, both paths
   (`internSlowAllocation` forces the outside one), until a race was
   seen (`internFoundUnderLock > 0`), `withoutTheSecondLookupTwoSymbolsOfTheSameBytesAppear`
   (switch `internNoSecondLookup`), the verifier.
2. Whole reads: the fill, the pin and the read-only bit come before the
   release fence and the publishing store (under the lock or before it), and a new bucket's nils and
   copies before its table store. Readers' loads are relaxed atomic
   loads (`ObjectMemory.load`), and every body address is computed from
   the state word just loaded (the address dependency module 6
   relies on). The publishing store is the post-store check's seq_cst
   store followed by its seq_cst reload, so a barrier's load after it
   never overtakes it (the young-collection model's finding). Model
   claim 2; test `aLookupNeverReadsASymbolBeforeItIsWhole` (switches
   `internPublishBeforeFill`, `internPauseUs`).
3. No Symbol a worker received is swept: both lookups and the growth
   copy read weak slots through the keep-alive barrier. Model claim 3;
   tests `aSymbolTheSecondLookupFindsDuringMarkingIsKeptAlive` (switch
   `internNoKeepAlive`), `aSymbolCopiedIntoAGrownBucketDuringMarkingIsKeptAlive`
   (marking's `noWeakKeepAlive`), `symbolsDroppedCollectedAndInternedAgainStayUnique`.
4. Nothing is decided across a poll: the lock is let go before every
   allocation that can poll (the slow path, a bucket's growth) and taken
   again after it, and everything is looked up again under it. So a stop never
   begins while it is held (a holder runs no poll; a waiter is not
   parked), a stop whose own work interns finds it free, and a save's
   hold never meets a half-done insert. Checked at every stop:
   `verifyInternLockFreeAtStop` (one trylock under `verifyStops`, every
   test runtime and checked build).
5. A worker waiting for the lock waits inside the VM, so a stop waits
   for it; by rule 4 that wait is bounded by the critical sections ahead
   of it, at most one per other worker. Measured below (part 4:
   `internHoldMaxUs`).
6. The collectors, each with what it reads:
   - *The scavenge and module 7's young collections.* Symbols and
     buckets are old at birth (`allocateOld`), and the table holds only
     them, so no store of the insert makes a remembered holder (the
     insertion barrier runs and finds an old value). The String `o` may
     be young and moves; it is held through `allocateOld`'s `keeping`
     and read by entry, never by a raw pointer.
   - *The marker and the final mark's weak pass.* A Symbol or bucket
     made while a cycle runs is not a snapshot entry: never swept by that
     cycle, and the final mark never nils a new bucket's slots, which is
     why every Symbol the growth copies is kept alive. The weak pass runs
     in a stop, so it never runs during a copy (rule 4): the marker
     running concurrently with a copy only traces strong slots and never
     reads a bucket's weak ones.
   - *The lazy sweep and the bounded sweep stop.* An entry the sweep
     frees reaches an allocator only through a stop's apply or
     `publishSwept`, so the Symbol an allocation answers was free at a
     pause every worker noted; nothing of the table is swept while the
     insert holds it (the table is a root, the buckets strongly held by
     it, a replaced bucket recorded by the SATB barrier).
   - *The relocator.* Buckets and the table move; every store of the
     insert is the barriered store with the post-store check, which
     redoes it after a concurrent move, as every heap store does.
     Symbols are pinned for good before they are published and never
     move (the interpreter keeps raw pointers into nothing of a Symbol
     anyway; its bytes are read by entry).
   - *The full collection and compaction* run in stops: never during a
     critical section.
7. The readers, in one table:

| reader | when | lock | what it reads | how it stays safe |
|---|---|---|---|---|
| `Machine.intern` (primitive 129's fast path, `perform:`'s callers, the compiler through 129) | any time | none | table slot, bucket slots, Symbols' counts and bytes | relaxed loads by entry; rule 2's ordering; `weakReadBarrier` on a hit |
| primitive 135 (`Symbol lookup:`) | any time | none | the same | the same; it inserts nothing |
| the second lookup and `symbolSlot` in `internSlow` | under the lock | intern | the same | sees every insert (each was made under the lock); `keepAliveRead` on a hit |
| `growBucket`'s copy | under the lock | intern | the old bucket's slots | `keepAliveRead` per slot; the weak pass cannot run (a stop) |
| `Image.intern` and `Image.insertSymbol` (loader, image build, module 2's `runToReturn`) | no VM running, or a stop | none | all | no insert runs concurrently: rule 4 |
| `Image.symbol` (`VM.spawn`'s selector, through `host`) | inside the VM as the host worker | none | the same as a lookup | a lock-free reader; the Symbol is only compared, never stored, so it needs no keep-alive |
| `ObjectMemory.symbolCount` | tests, the host | none | every bucket | stops or no VM |
| the snapshot writer and the save (8c) | in the save's stop, behind the scheduler hold | none | the table as an object graph | rule 4: no half-done insert at a stop; discarded Symbols are Strings |
| the loader (`ImageFile`) | no VM | none | every bucket: Arrays, Symbols, uniqueness | unchanged (rule 9): the table's shape and the image format are the same |
| the heap verifiers and `verifySymbolTable` | stops | none (trylock for the check) | everything | stops |
| primitives 167 to 170 (`allInstances`, `pointersTo`) | their own stop | none | every old object | only published Symbols are Symbols: a Symbol made for nothing is a String before any poll, and no Symbol is held across a poll unpublished |
| `Image.saveImage` after `VM.destroy` | no VM | none | all | no insert |

8. The method cache: a line is (class index, selector entry, method),
   and a line naming a Symbol exists only while a method dictionary
   holds that Symbol (only found methods are cached). A Symbol's entry
   is freed only by the old-space sweep's apply or a full collection,
   both at a pause; every worker flushes its cache when it notes the
   pause (`noteEpoch` at a park and at `enterVM`). So no line can name an
   entry freed and reused: the stop's flush at every intern was never
   what kept this. Test `aSelectorCollectedAndInternedAgainFindsNoStaleLine`
   plants a line on worker 1 for a Symbol nothing holds, runs the cycle
   that frees it, and checks that worker 1's next slice flushed the line
   and that `perform:` of the bytes interned again does not find the
   planted method. The young collections that free entries without a
   pause free only young entries, and no Symbol is young (`Symbol new`
   and `basicNew:` are errors, part 1).
9. The table's shape and the image format do not change: the loader's
   rules are untouched and the image version stays 6.

### Tests, the verifier, the broken variants, the counters (part 3)

`Tests/KajoVMTests/ObjectModel/SymbolInterningTests.swift`; the random
programs gained an intern step (`Tests/KajoVMTests/Workers/RandomPrograms.swift`,
case 14: a name of a pool of six every task shares, interned twice from
two Strings and compared by identity, or a name a Symbol literal holds,
compared with the literal; the model counts one per step) and run with
the symbol-table verifier on (`VMConfig.verifySymbols`) in every
configuration. The verifier (`ObjectMemory.verifySymbolTable`, run by
`verifySymbolTableAfterInserts` at the first stop after inserts, when
`verifySymbols` is on): every bucket nil or a WeakArray, every Symbol in
its hash's bucket, read-only and pinned for good, no two with the same
bytes; failures go to the object memory's reports and
`symbolVerifierFailures`. The tests were written with the protocol, not
before it (a deviation); their evidence is the broken variants below and
the hole's test, which failed on the code it was written against.

The broken variants, one quoted run each (debug build,
`~/kajo-scratch/symbol-interning/tests/variants3.txt`, on f117715; every test passes
because each asserts its variant's failure):

| switch | where the failure is | quoted |
|---|---|---|
| `internNoKeepAlive` | the final mark's verifier | "broken variant internNoKeepAlive: the final mark missed 1, the Symbol alive false" |
| `internNoSecondLookup` | the answers and the symbol-table verifier | "1 byte sequences answered by two Symbols in 11 rounds; 1 verifier failures, first: object memory verifier, symbol table at a stop: two Symbols in the table with the bytes of d10_88" (on 3eea94b, the first order: "6 byte sequences ... in 8 rounds", `tests/variants.txt`) |
| `internPublishBeforeFill` with `internPauseUs` 20 000 | lock-free lookups of six NUL bytes | "4512 lookups of six NUL bytes answered a Symbol" (skipped under ThreadSanitizer only: bytes written while readers compare them is a data race by construction) |

The correct runs beside them: "same bytes at once (slow allocation
false): 1 rounds, 400 inserted, 3 found under the lock, 0 made for
nothing, 0 made outside the lock, 3 contended, longest hold 2108542 ns"
and "(slow allocation true): 1 rounds, 400 inserted, 12 found under the
lock, 7 made for nothing, 407 made outside the lock, 8 contended,
longest hold 1087833 ns" (a debug build with every verifier on, eight
workers on the mini's ten cores: the holds of 1 to 2 ms there are a
debug build's growth copies and the OS descheduling a holder; release
numbers are in part 4); the re-interning test (both paths), the growth
test (every size to 4095, the 4096th answered nil by the primitive's
fallback) and the method-cache test pass. The random programs with the
intern step: 20 seeds in each of the 23 configurations, none failing
(`tests/random20.txt` on 3eea94b, `tests/random20b.txt` on the final
order). The new suite once under ThreadSanitizer with twelve busy loops
(on 4b217ac, the first order; `tests/tsan-new.txt`): 11 tests, 0
reports, 381 s, 369 of them the growth test, which 577ce9c cut (its
candidates hashed from a byte buffer, the verifier once at the end). The rule "a stop never finds the lock held" has
no switch: its broken variant (a poll inside the critical section) would
deadlock the stop against the waiter, not fail a check; the verifier is
its check in every run instead.

Counters on the run line: `internInserted`, `internMadeForNothing`,
`internBucketFilled`, `internGrowths`, `internGrowthRetries`,
`internHolds`, `internHoldMeanUs`, `internHoldMaxUs`, `internContended`,
`internWaitNs`, `symbolVerifies`, `symbolVerifyMs`,
`symbolVerifierFailures`, and part 1's `internStops` (0 since).

### Part 4: after

**Part 1's table again** (`p4/matrix-raw.txt`, summary
`p4/matrix-summary.md`, the same script, images and native modules, the
aligned release build of f117715 in `build-p4/`, five interleaved
rounds, every run at thermal "fair" where part 1's were at nominal (the after
rows are the slower-clocked ones if anything), checksums equal to part 1's,
every native run binding all 3283 or 3289 methods):

| program | engine | workers | wall ms before | wall ms after | 8 / 1 after | intern stops after |
|---|---|--:|--:|--:|--:|--:|
| collections | interp | 1 | 4352 | 4176 (4153-4203) | | 0 |
| collections | interp | 2 | 5842 | 4417 (4395-4428) | | 0 |
| collections | interp | 4 | 8437 | 4636 (4611-4662) | | 0 |
| collections | interp | 8 | 32 484 | 4909 (4892-4930) | **1.18** | 0 |
| collections | native | 1 | 2329 | 2188 (2168-2188) | | 0 |
| collections | native | 2 | 3817 | 2369 (2363-2381) | | 0 |
| collections | native | 4 | 8131 | 2901 (2594-3045) | | 0 |
| collections | native | 8 | 31 520 | 2964 (2930-3043) | **1.35** | 0 |
| collections-dict | interp | 1 | 1601 | 1426 (1419-1446) | | 0 |
| collections-dict | interp | 8 | 30 059 | 2070 (2063-2100) | 1.45 | 0 |
| collections-dict | native | 1 | 1139 | 980 (976-989) | | 0 |
| collections-dict | native | 8 | 30 584 | 1682 (1673-1701) | 1.72 | 0 |

At 8 workers, medians over the five runs of each `collections` row:
`internInserted` 200 000, `internFoundUnderLock` 127 928 interpreted and
124 558 natively (the other workers' interns of the same bytes, now
answered under the lock with nothing made), `internMadeForNothing` 0,
`internSlowAllocations` 0, `internGrowths` about 6240 with 1500 to 3000
growth retries, `internContended` 133 358 and 130 823 with 2.2 and 2.4 s
of waiting summed over the eight workers (about 6 percent of their 39 and
24 worker-seconds), the critical section 0.50 µs on average and at most
99.5 and 113.0 µs (the dictionary part 113.6 and 167.5); the stops are
9 to 12 a run, all the collector's (scavenges, initial and final marks,
applies), the longest time to a safepoint of any stop at 8 workers 0.42
ms (0.72 before), parked worker-seconds 0.0 (166 before); the method
cache's misses 9.6 M against 14.5 M before, 1.2 M at 1 worker against 2.8
M (the stop's flush gone) and the 1-worker runs 4 and 6 percent faster
(4176 against 4352 ms, 2188 against 2329). The cheating build's ceiling
was 1.16 and 1.31; the protocol lands at 1.18 and 1.35.

What is left at 8 workers is contention on the one lock, not the insert
being slow: eight workers that intern the same 200 000 Strings in step
queue on it (130 000 contended acquisitions a run), and natively the
mutator is twice as fast, so the queue is a larger share. The dictionary
part alone does nothing but that, and natively it is 1.72; it is not
the bar's row. A lock per bucket would let the eight workers' different
bytes proceed at once; it is an open question below, with these numbers.

**The bar, item by item:**

1. `collections` at 8 workers at most 1.5 times its 1-worker time in
   both engines: **met**, 1.18 interpreted and 1.35 native (7.46 and
   13.5 before).
2. No intern stop exists: **met**. `markStop(.intern)` is gone,
   `internStops` reads 0 in every row of `p4/matrix-raw.txt` and in
   every test runtime (`workersInterningTheSameBytesAtOnceGetOneSymbol`
   asserts it); the stop kind stays as instrumentation. The uniqueness
   tests and the model's claims hold, and each broken variant fails
   where it should (tables above).
3. Kernels within noise, `interpret` identical: see the gates below (the
   aligned A/B against 9c5e984 and the disassembly diff of the A/B's own
   objects).
4. The core tier through `just check 9c5e984` on the final code commit:
   see the gates below.

**The method cache** after the protocol: `cacheFlushes` 0 in every row
(each intern stop flushed every worker's cache before); the stale-line
test passes, on the argument of rule 8.

### Deviations

- **The order of the insert** (part 4): the Symbol is made under the
  lock by the allocation fast path and only made outside it when that
  has no room, where the brief's candidate always made it first; the
  numbers that decided it are above, and the model has both orders.
- **A full bucket is grown before the Symbol is made**, not after (part
  1's paragraph), so no unpublished Symbol is ever held across a poll.
- **The tests were written with the protocol**, not before it. The
  hole's test was written first and failed on the code it was written
  for (`hole/before-fix.txt`); every other rule's test shows its value
  through its broken variant, run in the same test.
- **The forced schedule for the hole** is the host worker calling
  `internSlow` directly (the slow path with the lock-free lookup
  skipped), not a test switch in the lookup's fast path, which would
  have cost every hit a load.
- **Part 4's matrix ran at thermal "fair"**, part 1's at nominal; the
  after rows are the ones that could only have been slowed.
- **Stress coverage of the new paths is the random programs'**: their
  intern step runs in all 23 configurations (a stop and a preemption at
  every poll, a collection at every allocation, marking always on,
  relocation of every live block, the young barrier always on, the
  slowed marker, the three young modes and the oracle, the exhausted
  reserve), interpreted and, in the gate's `swift test`, natively; the
  new unit tests run in the default configuration.

### Not done

- A lock per bucket (an open question below, with part 4's contention
  numbers).
- The bucket scan's cost at a million Symbols (4.4 µs a hit): the
  table's shape is unchanged by rule 9; an open question.
- The symbol-table verifier's own cost under load was not measured; it
  is off in every product build and in `kajo run`, on in the tests and
  the random programs.
- The rule "no stop finds the lock held" has a verifier at every stop
  but no broken variant: a poll inside the critical section would
  deadlock the stop against the waiters, not fail a check.
- The new unit tests under the native harness (`KAJO_NATIVE_HARNESS=1`);
  the native random programs run the intern step.
- No device row interns in a loop; the gate's iPhone matrix ran as
  always.

### Found, not this module's

- `Image.insertSymbol`'s bucket growth copies a weak bucket with no
  keep-alive barrier. It runs only with no VM (the loader, the image
  build) or in module 2's standalone interpreter, where no cycle marks,
  so it is not a hole today; a host insert into a running VM would need
  `internSlow`.
- The lock-free hit in `Machine.intern` calls `weakReadBarrier` out of
  line on every hit (not `keepAliveRead`, which reads the flag word
  first): a call per `asSymbol` hit with marking off. Not changed: the
  fast path was to gain nothing.

### Open questions

1. **One lock or one per bucket?** At 8 workers the one lock is
   contended 130 000 times a run of `collections` with 2.2 to 2.4 s of
   waiting summed over eight workers (6 percent), the bar met at 1.18
   and 1.35, the dictionary part alone at 1.45 and 1.72. Recommendation:
   keep the one lock; a striped lock (the bucket index modulo a small
   power of two) is a small change if a real program interns in
   parallel at this rate, and part 4's rows are its baseline.
2. **The bucket scan.** A hit at a million Symbols costs 4.4 µs (979
   per bucket, three dependent loads each). Recommendation: no change
   until an app holds more than about 100 000 Symbols (0.25 µs a hit
   there); then a table that grows its bucket count, which changes the
   image format and is a module of its own.
3. **The `intern` stop kind.** It cannot occur any more.
   Recommendation: keep it and its counters (they read 0) for a release
   so the rows' readers see the zero, then remove them.

### The gates

`just check 9c5e984` ran once, on b478aaf (docs above the code commit
f117715), the core tier's 20 gates with swift.org 6.4.2 first on PATH,
into `~/kajo-scratch/symbol-interning/check/` (`gates.log`), 11 368 s.
Against the previous module's tier on e8f9585
(`~/kajo-scratch/stall-tests/check/gates.log`):

| gate | result | s | baseline s |
|---|---|--:|--:|
| clean-build | pass | 19 | 20 |
| swift-test-load | pass (456 + 162 tests) | 1169 | 965 |
| tsan | **fail**, 0 reports | 3161 | 2997 |
| tsan-load | **fail**, 0 reports | 3295 | 4103 (failed then too) |
| ios-check | pass | 16 | 16 |
| arc-check | pass | 58 | 58 |
| golden | pass | 75 | 75 |
| native-golden | pass | 97 | 96 |
| native-kernel-test | pass (3280 of 3280 and 4057 of 4057 bound, 0 declined) | 46 | 46 |
| native-cc | pass | 29 | 29 |
| test-release | pass (451 + 162) | 119 | 117 |
| model-check | pass | 21 | 20 |
| soak | pass | 62 | 64 |
| fuzz | pass, "libFuzzer build: ok" for each: kasm 2 076 676, snapshot 3 085 135, syntax 781 803, protocol 1 730 748 runs in 601 s | 664 | 662 |
| apps | pass | 129 | 125 |
| kernel-test | pass (249 of 249) | 107 | 107 |
| new-check | pass | 253 | 251 |
| ab | pass | 324 | 323 |
| matrix-mac | pass | 823 | 822 |
| matrix-iphone | pass | 901 | 900 |

The two failures. `tsan-load` was this module's: the growth test's one
Process filling a bucket to 4095 (quadratic: every insert scans the
bucket) did not finish within 600 s in a debug build under the
sanitizer and twelve loops, and the test's helper then read the
unfinished Process's nil result as an Array and trapped the test
process ("1 Processes still live", then "ObjectMemory.swift:208:
Assertion failed"), so the rest of the VM suite did not run. Fixed in
the test (c98d981): results are read only from Processes that answered,
and under the sanitizer the bucket grows to 64 with the full fill and
the refusal left to every other build. `tsan` failed in a test that is
not this module's: `aRingLikeLoadStallsInsteadOfFallingBack(offload)`
asserts that a stall happened and saw none ("stalls=0 ... cycles=2
markerSlowSpins=2250"; its body took 236 s against 115 in the stall
tests' own run). Its sanitizer runs have always been at the edge (2 to
3 stalls in the x16 offload rows of `stall-tests/check2/tsan.txt` and
`tsan-load.txt`), and this module's tests running beside it in the
parallel suite (eight-worker interning, the growth test) slow the
mutator that has to outrun the slowed marker. It is a test that
asserts parallelism without running until it sees it (AGENTS.md); not
changed here, handed back.

Only test files changed after that run, and every other gate had
passed, so the three test gates ran again alone on c98d981 through
`scripts/gates-lib.sh`'s own definitions and `gl_gate`
(`~/kajo-scratch/symbol-interning/tools/three-gates.sh`, the stall
follow-up's driver with this PATH), into
`~/kajo-scratch/symbol-interning/check2/gates.log`, 7961 s:
swift-test-load pass in 1058 s (456 + 162 tests), tsan pass in 2969 s
(0 reports; the ring test passed), tsan-load pass in 3934 s (0 reports).
Against the stall follow-up's three gates on 2dc41e6 (917, 3010 and
4053 s) the new tests cost about 140 s in `swift-test-load` and nothing
measurable in the sanitizer gates (their own variation is larger); the
VM suite's random programs, which now verify the symbol table at every
stop after inserts, account for most of the plain gate's difference
(the interpreted random programs ended at 762 s of the suite against
593 in the tier's run).

**The A/B** (the gate's, `check/ab.txt`, aligned `-enable-testing`
builds of 9c5e984 and b478aaf, five interleaved runs): 0.995 to 1.000 at
1 worker and 0.975 to 1.013 at 8 workers with overlapping ranges,
instruction ratios 0.998 to 1.000, checksums the same in every row.
**`interpret`** in the A/B's own objects (`check/ab/{base,head}-build/.../Dispatch.o`,
`otool -tV` with the addresses stripped, `p4/interpret-{base,head}.txt`):
1817 lines each, identical instruction for instruction. **`just
arc-check`** passes (no retain or release on the checked paths;
`stringPrimitive`, `Machine.intern` ARC 0; the loop one jump table).
**New `unsafe` lines**: 62 added and 6 removed in `Sources/KajoVM`
(`git diff 9c5e984 c98d981`), all in the core (`Strings.swift`,
`Symbols.swift`, `Safepoint.swift`, `VM.swift`, `VMState.swift`,
`Headless.swift`); the clean build and `just ios-check` with 0 warnings.

**The matrices** (`check/matrix-mac.txt`, `check/matrix-iphone.txt`,
`--bar` over every row): the Mac 156 rows, 0 launches failed, 0
fallbacks, frames missed only in the hog rows with the budget off (1787,
by design), 680 stalls (longest 24.55 ms) against the baseline's 668,
the longest stop an 11.02 ms scavenge under `young=stw`; the iPhone at
5 workers 156 rows, 0 fallbacks, 0 stalls, the hog rows by design, and
the oracle's rows: the ring under `young=stw` 2, 6 and 1 frames (the
baseline 5, 3 and 5) and one storm launch under `young=stw` 1 frame,
each behind a stop-the-world scavenge of 13.8 to 16.2 ms (the oracle's
own cost, as in every earlier matrix). No row interns in a loop; none
moved for this module.

## 2026-11-16: the race tests drive their race

The weekly run of 2026-11-16 on 30e14bd failed `swift-test`,
`swift-test-load` and `tsan` on two tests of this module:
`workersInterningTheSameBytesAtOnceGetOneSymbol(slowAllocation: false)`
saw no race in 40 rounds ("0 found under the lock, 0 contended") and
`withoutTheSecondLookupTwoSymbolsOfTheSameBytesAppear` no duplicate in
40. No answer was wrong and the VM was not the suspect: the eight
Processes of a round were spawned one after another and raced only when
a lagging one caught up with the leader, which beside the rest of the
suite did not happen. Since 01d4580 every round starts at a gate (each
Process marks its slot of an arrivals Array and spins until all have
arrived, `internAll:arrivals:index:`), the assertions and the bound of
40 rounds unchanged, and each test prints its body's own time. Before,
beside the VM suite's random programs, the correct variant needed up to
34 rounds and the broken variant failed once in 30; after, in 150 runs
per test across five conditions (plain, twelve busy loops, the
sanitizer, both, and beside the random programs), every run raced within
3 rounds. The measurement and the tables are in
`docs/modules/interning-tests.md`. The protocol, the model and the
verifiers did not change.
