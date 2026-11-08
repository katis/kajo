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
