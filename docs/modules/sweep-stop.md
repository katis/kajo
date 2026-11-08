# The sweep finished in a stop

A collector follow-up to modules 5 and 7 and the large-bytes follow-up.
Briefed 2026-11-08 from the row of the same name in `docs/PLAN.md`.

## What is wrong

The large-bytes follow-up made an allocation that finds the entry table
empty, or an old allocation that finds no room, finish the lazy sweep in its
own stop and apply it (`finishSweepInStop`, `Sources/KajoVM/Marking/Sweep.swift`;
`sweepsForEntries`, `sweepsForOld`, `sweepsFinishedInPause`), so that the
entries the sweep had already freed but still held pending reach the
allocators without module 1's full collection (41 to 84 ms on the devices).
That removed every fallback on the devices. The runtime comparison then
found what it costs on the Mac: on binarytrees at 8 workers the sweep is
finished in a stop seven times a 1.8 s run, each stop 19 to 30 ms, 42 ms of
sweeping inside stops per run, where every other stop kind is under 0.4 ms
(`docs/performance/README.md`, the 8-worker rows). The stop has no kind of
its own: `finishSweepInStop` does not call `markStop`, so it is counted as
`other` in `stopsByKind` and nothing in a report names it.

The sweep runs chunked with the world running (`sweepCycle`, polling every
4096 entries) and is applied at the next pause; the stop exists because the
mutators emptied the table faster than the utility-QoS marker swept it. The
work itself is not the problem; where it runs is.

Beside it, since the interpreter-speed module: the ring under the
stop-the-world young mode on the Mac at 7 workers crosses the soft limit
with no cycle running 26 to 32 times a run (20 to 28 before the faster
mutators), every one a 185 to 200 ms compacting full collection
(`fallbacksSoftLimit`; the weekly run's Mac matrix shows the same, 30 in
the 2026-11-07 quick run). The trigger's headroom (`InitialMark.swift`,
`cycleDue`: a cycle starts when the old-space or entry-table headroom is
under a threshold, decided at young collections) was tuned on the slower
interpreter.

## Parts

1. **Instrument first.** Give the stop its own `StopKind` (`sweep`), so it
   is a row of `stopsByKind` on every run line and in the shells' reports,
   and give it a record: the cause (entries or old space), the phase the
   cycle was in, how far the sweep had got (entries and blocks swept and
   freed so far, pending runs held, entries and blocks still to sweep), how
   long the sweep had been running and at what QoS, and how long the stop's
   sweeping and apply each took. Reproduce the comparison's row (`just perf`
   is too wide; `kajo run` on the binarytrees program at 8 workers, the
   comparison's kernels are under `experiments/runtime-comparison/`) and
   read the records: how far through was the sweep when the table emptied,
   and how much of the stop was sweeping against applying.

2. **Bound the stop.** The final mark's rule (`docs/modules/final-mark.md`)
   applies: a pass that runs inside a stop is bounded in work or moved out
   of it. The shape the PLAN row proposes: apply what is already swept and
   let the rest be swept with the world running. Before building it, list
   every reader of an entry's state between "swept, pending" and "applied"
   (the allocators, both sweeps, the young collector's deferred frees, the
   relocator's epoch freeing, the verifiers' skip rules, the snapshot
   writer and loader) and make the one-owner rule hold for a partial apply
   in the same commit (`AGENTS.md`: every entry state between generations
   needs exactly one owner; a lazy sweep is not cheap to abandon). If the
   young-collection model (`docs/models/young-collection.md`) covers the
   deferred frees the change touches, update the model in the same commit
   and run `just model-check`. A test switch keeps the old behaviour
   (`sweepStopUnbounded`) and a test shows the bounded stop with the
   verifiers on; a broken variant (applying an entry the sweep has not
   reached) must fail a verifier, and that is a test too. If a partial
   apply cannot be made sound, say so with the reader that breaks it and
   bound the stop the other way: sweep inside the stop only up to a work
   bound, apply, and let the allocation wait outside the stop as
   `waitForMarkingCycle` does (background workers only; the main worker
   never waits past a frame).

3. **Headroom, so the stop does not come.** The trigger and the QoS policy
   watch the entry table's headroom but not its rate: binarytrees at 8
   workers consumes entries faster than a utility-QoS sweep frees them.
   Measure the consumption rate against the sweep rate on that program
   (entries per second each) and give the trigger a rule that starts the
   cycle early enough for the sweep to finish before the table empties at
   the observed rate, or raises the marker for the sweep when the table
   will empty before it is done (the policy is re-decided at every young
   collection already). Decide from the measurement, not from a constant;
   whatever constant remains is named in `MarkingConfig` with the
   measurement beside it. The bar is that the sweep stop becomes rare on
   the Mac's binarytrees, not that it is hidden: the counter stays.

4. **The ring's soft-limit trigger re-measured.** On the Mac at 7 workers
   under `young=stw`, the ring crosses the soft limit with no cycle running
   26 to 32 times a run. Read the fallback records (the large-bytes
   follow-up gave every fallback one): is the cycle not started because
   the headroom threshold is crossed between two young collections, or
   started and not finished. Then re-tune the headroom against the faster
   mutators, in the mode that falls back first, from the measurement, and
   report the count before and after with the rows for the other young
   modes unchanged. A fallback is counted and reported; this part changes
   when a cycle starts, never whether a fallback is counted. The owner
   accepted the oracle ring's misses in reserve-and-depth; the bar here is
   fewer soft-limit fallbacks at 7 workers, with the number stated, not
   zero.

5. **Measure.** `kajo run` on binarytrees at 8 workers before and after
   (`stopsByKind`, the sweep kind's count, max and p50, the run time); the
   Mac matrix at 7 workers before and after (`scripts/shell-matrix.sh`;
   the storm, large churn, ring in all three young modes, photo); the
   iPhone and the iPad at 5 workers, storm and large churn, 10 launches
   per row per device through `scripts/device-rows.sh` or
   `scripts/shell-matrix.sh device`, interleaved before and after so
   thermal states compare; the aligned A/B (`scripts/ab.sh`) against the
   starting commit and `just arc-check`; the comparison's binarytrees row
   is re-run alone (not the whole `just perf`) and the 8-worker number put
   beside section 1a's.

## Bar

- The sweep stop is a kind of its own with a record, in `stopsByKind` on
  every run line and in `shell-report.py`'s tables.
- On the Mac's binarytrees at 8 workers no stop of any kind is longer than
  2 ms, and the sweep kind's stops are at most a few per run with their
  count stated (before: seven of 19 to 30 ms).
- The devices' storm and large churn keep 0 fallbacks and 0 frames missed
  at 5 workers in 10 launches per row per device, and the main thread's
  stopped time per 10 s is no worse than the final-mark module's rows.
- The Mac's ring at 7 workers under `young=stw` falls back fewer times than
  26 to 32, with the count stated; the other young modes' ring rows miss no
  frame as now.
- The aligned A/B within noise on every kernel (0.98 to 1.02 with
  overlapping ranges), `interpret` identical by disassembly diff (page
  offsets aside), `just arc-check` passes.
- The core tier passes on the final code commit: `just check` (the diff is
  under `Marking/` and `Nursery/`, so it picks the core tier itself: all 18
  gates, the A/B, the Mac and iPhone matrices), with its `gates.log`
  quoted, plus the iPad rows.
- The verifiers run in at least one scenario with the bounded stop and the
  broken variant fails one.

## Open questions for the owner (build the recommended option, list the question)

1. Should the main worker ever wait for a sweep outside a stop? Recommended:
   no; the main worker keeps the stop, bounded, and the headroom rule is
   what protects a frame.
2. If part 3's rule raises the marker's QoS more often on the devices, is
   the energy cost (the marker at user-initiated costs up to 3.5 times its
   own energy, the large-bytes follow-up) acceptable for fewer stops?
   Recommended: raise only when the table will empty before the sweep is
   done at the observed rate, which the devices' storm did not need.
3. The ring's soft-limit fallbacks at 7 workers: a number the owner accepts,
   or a target. Recommended: report the number after re-tuning and leave
   the target open.

## As built (2026-11-08)

Commits 3734f03 (parts 1 to 3) and d194336 (part 4) on top of the brief
97465fc. Everything is under `Sources/KajoVM/Marking/`, `Nursery/`,
`Relocation/Relocator.swift` (the cut-off), `ObjectMemory/Verifier.swift`
(one check), `Workers/VMState.swift` (the kind and a counter),
`YoungCollection/` (the samplers) and `Headless.swift` (the run line);
nothing in `kernel/` or `tools/`. 40 new or changed `unsafe` lines.

### Part 1: the kind, the record, and what they said

`StopKind.sweep` is set by `finishSweepInStop` (`markStop`), so the stop is
`sweep:n/max/ttsp` in `stopsByKind` on every run line and in the shells'
`gc_stopsByKind`; `shell-report.py` has a sweep-stops column in its
scenario table and in `--bar`. Every sweep stop appends a
`SweepStopRecord` (a ring of 64 in the marking log): the cause, the phase,
the outcome (whole, partial, unbounded), the requester, how far the sweep
had got (snapshot words swept of all, entries visited, entries freed and
already handed over, runs pending), the time since the sweep could start
(the final mark's end), the marker's QoS and the policy's wish, the table
and old space, and the stop's own work (words swept and entries freed in
it, its sweeping and its apply or hand-over, entries handed over, whether
it cut a relocation pass off). The run line prints them as `sweepStopLog`
with the counters `sweepStops`, `sweepStopsWhole`, `sweepStopsPartial`,
`sweepStopsUnbounded`, `sweepStopP50ms`, `sweepStopMaxMs`,
`sweepStopRelocCutOffs`, `sweepWaits`, `sweepWaitMs`, `sweepWaitTimeouts`.
`kajo run --sweep-stop-words -1` brings the old stop back for comparison.

The comparison's row reproduced with the old stop (three runs of
binarytrees at 8 workers, `records/part1-unbounded.txt`): 5 to 7 sweep
stops a run, the longest 20.3 to 26.7 ms. Read from the records:

- **How far the sweep had got.** 21 to 99 percent of the snapshot's words
  (median about 80), 3.2 to 12.0 million entries freed and none handed
  over, held in 793 to 3003 pending runs, 12 to 38 ms after the sweep
  could start. The table did not empty because the sweep was slow: every
  stop found millions of dead entries already swept and waiting for the
  apply.
- **The marker was already raised.** QoS 25 (user-initiated) with the
  raise wanted in every record: the large-bytes policy had done its part.
- **Sweeping against applying.** The stop's sweeping took 0.46 to 26.5 ms
  (3 072 to 194 177 words, 140 to 145 ns a word, about 2.3 ns an entry);
  the apply 0.11 to 0.13 ms. The stop was the rest of the sweep, nothing
  else.

### Part 2: the partial apply

`finishSweepInStop(vm, for:, bounded:)` (world stopped, kind `sweep`):

- phase swept: the whole apply, as before (0.11 to 0.13 ms);
- phase sweeping, bounded: first the relocation pass of this cycle is cut
  off if it has not finished (below), then the stop sweeps at most
  `MarkingConfig.sweepStopWords` (4096, about 0.6 ms on the Mac at part
  1's rate) but only when fewer than `sweepStopEnoughEntries` (65 536)
  swept entries are pending; if that reaches the end the cycle is applied
  whole, otherwise `publishSwept` hands every pending run to the
  allocators, takes those entries off the old-entry estimate
  (`entriesPublished`, so the whole apply subtracts only the rest) and
  leaves the cursor, the snapshot, the pending-dead set, the marking flag,
  the blocks and the relocation state as they are: the marker resumes
  from the cursor at its poll and the whole apply comes as before;
- unbounded (`sweepStopUnbounded`, the main worker's old allocation, a
  background worker whose wait ran out): the sweep is finished in the
  stop and applied, as the large-bytes follow-up built it.

Blocks are freed only by the whole apply (`freeDeadBlocks` needs every
block's live bit), so a partial apply cannot serve an old allocation that
lacks blocks. Such an allocation on a background worker releases the stop
and waits for the sweep outside it (`waitForSweep`: at most
`sweepWaitMs`, 100 ms, the marker raised, parking for stops and servicing
rounds as `waitForMarkingCycle` does, its object a pending root), then
tries again and its next stop applies the swept cycle; past the wait it
finishes the sweep in the stop. The main worker keeps the bounded stop
for entries and the unbounded one for old space (open question 1). Under
the verifier option every sweep stop retires the contexts and runs the
heap and free-list verifiers.

**The readers of an entry between "swept, pending" and "applied", and
why a partial apply keeps one owner per entry.** A swept dead entry is,
from the moment its chunk is swept: state word free and linked into a
run, header 0, mark byte 0, old-map bit cleared, snapshot bit cleared
(the sweep clears the word), and owned by the pending list. A partial
apply moves its run from the pending list to the pool and changes nothing
else. Each reader:

1. *The allocators* (`refillStash`, the old allocation's contexts) take
   entries from the pool only. After the hand-over the entry is
   indistinguishable from one never used: free, header 0, mark 0, in no
   map. Owner: the pool, then the allocating stash.
2. *The lazy sweep* walks snapshot words from its cursor up and frees
   only entries whose snapshot bit is set. Every handed-over entry lies in
   a word below the cursor whose snapshot bits are zero, so the sweep
   never meets it again. This is the rule the broken variant breaks.
3. *The whole apply* publishes the runs still pending (only those freed
   after the last hand-over), frees blocks by the sweep's live bits and
   the stamps (a block an allocator took after the snapshot carries the
   cycle's stamp whichever entry its new bodies use), and subtracts only
   the entries not yet handed over from the old-entry estimate.
4. *Module 1's operations* (`markingBeforeOldSpaceOperation`: collect,
   compact, become, reshape, the save's promote-all, the VM's end) finish
   the sweep from the cursor and apply; the handed-over entries are not in
   the rest of the sweep, so nothing is freed twice.
5. *Module 7's deferred entry frees* are young entries, owned by their
   nursery and never in the snapshot (amendment 17); a partial apply
   touches no young entry. Module 7's holder lists (remembered buffers,
   carried lists) and the weak slots were cleared of every dead snapshot
   entry at the final mark (the remembered filter, the weak pass), so no
   list names a handed-over entry when it is reused. The young-collection
   model frees sweep entries one per step with the world running, which
   is more than a partial apply allows, so the model is unchanged and
   `just model-check` was not owed.
6. *The relocator* moves only snapshot entries (`snap.contains(e) &&
   mark`). A bounded sweep that ran ahead of its pass would clear the
   snapshot bit of live entries it had not moved yet; the pass would take
   them for dead and could evacuate (and later free) a block with a live
   body in it. So a bounded stop that sweeps cuts the pass off first
   (`relocationCutOffForSweep`: `relocatedCycle := cycle`, read by the
   relocator after its next poll), exactly as an apply ends it: evacuated
   blocks stay pending and are freed by epoch, the rest return to the
   pool at the apply's rebuild. A stop that only hands over runs the
   marker swept needs no cut-off: the sweep starts after the pass.
7. *Relocation's epoch freeing* frees blocks, never entries.
8. *The verifiers.* `isPendingDead` (snapshot bit and mark 0) is false for
   every handed-over entry, so the heap verifier checks it as an ordinary
   free entry; the free-list verifier counts pool and pending runs as
   lists of their own (one list each); the mark check (`mark set outside a
   collection`) still sees marking active. New: while a sweep is pending,
   a free entry whose snapshot bit is set fails the heap verifier ("the
   sweep has not reached it"): it would have two owners.
9. *The snapshot writer and loader*: a save promotes everything first,
   which finishes and applies the sweep; the image never holds a pending
   run.
10. *The SATB barrier* is off during the sweep (under `markingAlwaysOn`
    it records stores, but `greyIfCandidate` ignores entries without a
    snapshot bit and the next initial mark discards the buffers).

Tests (`Tests/KajoVMTests/Marking/SweepStopTests.swift`, every runtime
with every verifier on): two bounded stops hand over 16 words each and
leave the sweep running; a stop finds the marker's swept entries and hands
them over without sweeping; the switch `sweepStopUnbounded` sweeps the
whole snapshot in the stop; the young allocation's own path is served by
bounded stops with no full collection and no verifier failure; the broken
variant `applyAheadOfSweep` (the dead entries of the first snapshot word
past the cursor freed and handed over) fails the verifier at that stop
with "the sweep has not reached it"; a bounded stop cuts off a pending
relocation pass and the cycle, the relocation verifier and a later churn
are clean. The large-bytes follow-up's tests pass unchanged (their stops
now end whole: the small snapshots fit the bound).

### Part 3: the rates and the rule

Measured on binarytrees at 8 workers (`records/part3-rates.txt`, three
runs with the rule off and three on; the run line's `entryRateP50Ms`,
`sweepRateP50Ms`, `sweepRateMinMs`, `oldEntriesAtTriggerP50`, from the
cycle records' new `entryRate` and `oldEntriesAtStart`):

| | rule off | rule on |
|---|--:|--:|
| entries consumed (promoted), M/s, p50 at the triggers | 88 to 97 | 102 to 112 |
| a completed sweep, snapshot entries visited per s of its wall time, M/s, p50 (min) | 352 to 369 (185 to 195) | 251 to 310 (156 to 197) |
| marker QoS per cycle (17 utility, 25 user-initiated) | 17x1-2, 25x8-9 | 17x9-12, 25x2-5 |
| cycles a run | 10 | 14 to 15 |
| old entries at the trigger, share of the table, p50 | 0.81 | 0.53 to 0.61 |
| cycle, mean ms | 51 to 53 | 54 to 57 |
| sweep stops a run | 8 to 10 (partial, 0.13 to 0.15 ms) | 0 to 1 |
| run ms | 1744 to 1785 | 1732 to 1760 |

So the brief's premise does not hold on the Mac: the sweep frees entries
three to four times faster than binarytrees consumes them, even at
utility. The table emptied because the cycle started too late for its
whole duration: started by the entries floor (0.6 of the table, which
the estimate passed at 0.81 by the time a young collection decided),
a 52 ms cycle at about 100 M entries a second needs 5 M entries (31
percent of the 16.7 M table) before anything it frees reaches the
allocators.

The rule (`entryRateFillsTable`, `CycleTrigger.entryRate`,
`byEntryRate`): at the end of every young collection or scavenge, while
no cycle runs, a cycle starts when the table's free entries (capacity less
the old-entry estimate) last less than `safetyFactor` (2) times the last
cycle's duration at the observed consumption rate (objects promoted per
second over the samplers' last 8 collections, the young collector's
sampler or module 5's). It is module 5's predictor for old space applied
to the table, so no new constant: `safetyFactor` and the window are the
predictor's, and before the first cycle it waits (no duration). While a
cycle runs the QoS policy also asks for the marker when at that rate the
table empties before the cycle's predicted end (marking: its start plus
the last cycle's duration; sweeping: the sweep's start plus the last
sweep's), counted as the VM counter `entryRateRaises` (1 to 3 a run).
The marker ran raised in fewer cycles with the rule (2 to 5 of 14 to 15)
than without it (8 to 9 of 10): an earlier start leaves the headroom
policy's 25 percent alone. `kajo run --entry-rate off` turns it off.

### Part 4: the ring's soft-limit fallbacks read

The records (`records/ring-stw-before.txt`, eight lone launches, and the
matrix rows below) answer the brief's question with "both, and neither
is the trigger":

- **Started and not finished.** Each episode begins with a fallback while
  marking (or, once in a few, sweeping) in a cycle started by the floor
  that began 10 to 200 ms earlier, with old space at 100 to 102 percent of
  the soft limit and the marker at user-initiated. Its start was 8 to 14
  ms after the previous cycle's apply (the record's ms since the cycle
  started against ms since the last apply): the collector already ran
  back to back (39 to 43 cycles of 240 to 280 ms in 10 s at 860 to 925 MB/s
  of promotion), so no headroom threshold could start it earlier. That
  is a marking rate against a promotion rate, not a trigger.
- **Then a cascade with no cycle at all.** The fallback's full collection
  is a mark-sweep that frees only empty blocks; it left old space at 97.5
  to 101 percent of the limit, the next scavenge 80 to 180 ms later
  crossed the limit again, and a requested full collection suppresses
  the trigger, so two or three more full collections followed (the
  records' `cyclesStarted` does not move) until one compacted. And the
  compacting one's own promote-all scavenge re-requested a full
  collection that ran 300 to 400 ms later with old space at 14.9 percent
  of the limit: a fallback for nothing.

So the change is not in when a cycle starts (part 4's brief) but in the
fallback's own collection, and it counts every fallback as before:
`fullCollection` also compacts when its mark-sweep leaves old space at or
above the trigger's floor (with concurrent marking only; the oracle's
rule is unchanged), and withdraws a full-collection request its own
promote-all made when it ends under the limit. Test:
`aFullCollectionThatLeavesOldSpaceAboveTheFloorCompacts` (floor 0: one
compaction; floor 2: none). Before, at 7 workers under `young=stw`: 31 to
33 fallbacks a launch in the matrix (3 launches; 0 to 15 in eight lone
launches, 35 in all), 308 to 320 frames missed; after: 8 to 9 in the
matrix (0 to 3 in eight lone launches, 9 in all), 162 to 190 frames
missed, every remaining fallback a cycle started and not finished
(the full collection of 196 to 201 ms is a compaction now each time).
The other young modes' ring rows miss no frame and fall back 0 times,
before and after.

