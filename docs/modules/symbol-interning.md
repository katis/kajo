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
2. The Symbol is made whole with no lock held: `allocateOld` of a byte
   object of class Symbol (old at birth, `softFailure`, the String
   held), its bytes copied, `pinForGood`, `setReadOnly`, all by the
   allocating worker before the oop escapes.
3. Under `VMState.internLock` (a mutex beside `VMState.intern`, the
   counters it guards, never inside them): the bytes are looked up
   again; a hit goes through `keepAliveRead` (the hole's fix, kept) and
   the Symbol made is turned into a String (`discardSymbol`: its class
   index swapped with one relaxed atomic store; nobody saw it and no
   poll passed since it was made, so no walk can answer two Symbols of
   the same bytes) and counted `internMadeForNothing`. Else a hole of the
   bucket (`symbolSlot`) gets the Symbol: a release fence, then the
   ordinary barriered store (SATB, the post-store check's seq_cst store
   and reload, the insertion barrier). A bucket filled between the hint
   and the lock: let go, discard, again (`internBucketFilled`).
4. The critical section holds no allocation, no poll, no stall and no
   park: two lookups over at most 4095 slots, at most 4095 copied slots
   and three stores. Its length is measured (`internHoldMeanUs`,
   `internHoldMaxUs`), its contended acquisitions and their wait counted
   (`internContended`, `internWaitNs`).

Failure is a value as before: no room or a bucket at 4095 answers
`.none`, primitive 129 fails and the kernel's `asSymbol` reports
`primitiveFailed`. Without a VM (the module 2 interpreter, one thread)
the same code runs with no lock.

**What the protocol keeps** (the brief's nine rules):

1. One Symbol per byte sequence: every insert looks again under the one
   lock that every insert holds; a Symbol made for nothing becomes a
   String before anything can see it. Model claim 1; tests
   `workersInterningTheSameBytesAtOnceGetOneSymbol` (until a race was
   seen, `madeForNothing > 0`), `withoutTheSecondLookupTwoSymbolsOfTheSameBytesAppear`
   (switch `internNoSecondLookup`), the verifier.
2. Whole reads: the fill, the pin and the read-only bit come before the
   release fence and the publishing store, and a new bucket's nils and
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
4. Nothing is decided across a poll: the lock is taken after the last
   allocation of an attempt and let go before the next. So a stop never
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
`~/kajo-scratch/symbol-interning/tests/variants.txt`; every test passes
because each asserts its variant's failure):

| switch | where the failure is | quoted |
|---|---|---|
| `internNoKeepAlive` | the final mark's verifier | "broken variant internNoKeepAlive: the final mark missed 1, the Symbol alive false" |
| `internNoSecondLookup` | the answers and the symbol-table verifier | "6 byte sequences answered by two Symbols in 8 rounds; 6 verifier failures, first: object memory verifier, symbol table at a stop: two Symbols in the table with the bytes of d7_94; ..." |
| `internPublishBeforeFill` with `internPauseUs` 20 000 | lock-free lookups of six NUL bytes | "2941 lookups of six NUL bytes answered a Symbol" (skipped under ThreadSanitizer only: bytes written while readers compare them is a data race by construction) |

The correct runs beside them: "same bytes at once: 4 rounds, 1600
inserted, 17 made for nothing, 10 contended, longest hold 615292 ns" (a
debug build with every verifier on); the re-interning test, the growth
test (every size to 4095, the 4096th answered nil by the primitive's
fallback) and the method-cache test pass. The random programs with the
intern step: 20 seeds in each of the 23 configurations, none failing
(`tests/random20.txt`). The rule "a stop never finds the lock held" has
no switch: its broken variant (a poll inside the critical section) would
deadlock the stop against the waiter, not fail a check; the verifier is
its check in every run instead.

Counters on the run line: `internInserted`, `internMadeForNothing`,
`internBucketFilled`, `internGrowths`, `internGrowthRetries`,
`internHolds`, `internHoldMeanUs`, `internHoldMaxUs`, `internContended`,
`internWaitNs`, `symbolVerifies`, `symbolVerifyMs`,
`symbolVerifierFailures`, and part 1's `internStops` (0 since).
