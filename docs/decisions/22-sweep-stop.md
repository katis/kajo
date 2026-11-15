# The sweep stop

The sweep stop, built 2026-11-08 (`docs/modules/sweep-stop.md`, found by the
comparison's 8-worker binarytrees: an allocation that found the entry table
empty finished the whole lazy sweep in its own stop, 5 to 7 stops of 20 to
27 ms a run counted as `other`): the stop is its own kind `sweep` with a
record (cause, phase, outcome, how far the sweep had got, runs pending, time
since the sweep could start, the marker's QoS, table and old space, sweeping
and apply time, whether it cut a relocation pass off; `sweepStopLog`,
`sweepStops*` and `sweepWaits*` on the run line, a sweep-stops column in
`shell-report.py` and `--bar`); the records showed the stop's time was
sweeping (0.46 to 26.5 ms at about 143 ns a word, the apply 0.11 to 0.13 ms)
with 3.2 to 12 million entries already swept and pending in 793 to 3003
runs, so a bounded stop hands every pending run to the allocators
(`publishSwept`) and sweeps inside the stop only while fewer than 65 536
swept entries are pending and then at most `sweepStopWords` 4096 words,
cutting an unfinished relocation pass off first (`relocationCutOffForSweep`:
the relocator moves only snapshot entries, a sweep ahead of it could
evacuate a block with a live body); an old allocation the hand-over cannot
serve waits outside the stop on a background worker (`waitForSweep`, 100 ms)
while the main worker keeps the unbounded stop; every reader of a
swept-but-pending entry is listed in the doc with the one-owner argument,
the verifier checks that a free entry still in the pending sweep's snapshot
has two owners, `sweepStopUnbounded` brings the old stop back and the broken
variant `applyAheadOfSweep` fails that check as a test; the young-collection
model is unchanged (its sweep frees entries one per step with the world
running, more than a partial apply allows); the brief's premise did not hold
on the Mac: the sweep visits 250 to 370 million entries a second against 88
to 112 million consumed, the table emptied because the cycle started too
late (old entries at 0.81 of the table at the trigger), so the trigger
`entryRate` starts a cycle when the free entries would last less than
`safetyFactor` (2) times the last cycle's duration at the observed promotion
rate and the QoS policy raises the marker when the table would empty before
the running cycle's predicted end (binarytrees 13 to 15 cycles a run against
10, triggered at 0.53 to 0.61 of the table, the marker raised in 2 to 5
cycles against 8 to 9); the ring's soft-limit cascade at 7 workers under
`young=stw` was not a trigger problem (the collector already ran back to
back at 860 to 925 MB/s of promotion, each episode one cycle started and not
finished then 2 to 3 fallbacks with no cycle between because the mark-sweep
left old space at 97.5 to 101 percent of the limit and a requested full
collection suppresses the trigger, plus one spurious request from the
compacting collection's own promote-all 300 to 400 ms later at 15 percent):
a fallback's full collection compacts when its mark-sweep leaves old space
at or above the trigger's floor and withdraws the request its promote-all
made, 31 to 33 fallbacks a launch to 8 in every launch of two matrices, 308
to 320 frames to 162 to 190, every remaining fallback a cycle started and
not finished; measured interleaved: binarytrees 8 workers longest stop 0.38
to 0.55 ms against 23.1 to 27.2, sweep stops 0 to 1 a run at 0.10 to 0.17
ms, the run 2196 against 2218 ms, the comparison's row 1.82 s kasm and 1.87
Smalltalk against section 1a's 1.88; the devices at 5 workers, 10 launches a
row a side, 0 fallbacks and 0 frames missed in all 80 launches with the main
thread stopped no worse (iPhone storm 31.7 to 30.0 ms per 10 s, large churn
67.7 to 75.5 with overlapping ranges; iPad 46.8 to 48.8 and 154.3 to 154.7),
the devices' sweep stops being the large churn's old allocations as before
(1 to 14 a launch on the iPhone, 146 to 284 on the iPad, 0.06 to 0.12 ms of
work with up to 10.7 ms of time to safepoint from a large fill that does not
poll), the Mac's other rows unchanged; unexplained: one iPad large-churn
launch's initial mark with 570 ms of time to safepoint (every other under 5
ms in 40 launches, the main thread's longest park 1.3 ms, no frame missed;
likely the utility marker on the efficiency cores not reaching a poll); the
aligned A/B against 97465fc 0.995 to 1.004 at 1 worker and 0.944 to 1.059 at
8 with overlapping ranges and cycle ratios 0.993 to 1.009 (as earlier
modules' 8-worker spread), `interpret` identical, `just arc-check` passes;
`just check` on 767fd7f, the core tier, every gate in 12 375 s (393 + 121
tests in every test gate, ThreadSanitizer 0 reports alone and under load,
205 kernel tests, the four fuzzers with "libFuzzer build: ok" at 0.83 to
3.34 million runs, the Mac matrix 8 fallbacks in each ring `young=stw`
launch and a first idle launch missing 344 frames behind no stop, the third
such, the iPhone 0 fallbacks and 4 and 6 frames in the ring `young=stw`
behind 15.6 ms scavenges as before); two earlier gate runs failed,
`ios-check` on an unneeded `unsafe` the macOS build did not flag (46f8454)
and `tsan-load` on a module 7 test's 10 s wait for the young collector's
verifier stop, now 120 s with the assertion unchanged (767fd7f); not done:
no row exercised `waitForSweep` or the main worker's unbounded old-space
stop, the rate rule watches promotion only, the large fill's time to
safepoint; its three open questions answered by the owner on 2026-11-09 as
recommended (the main worker never waits outside a stop, the extra marking
accepted with the devices' energy measured at the next energy pass, 8 to 10
ring fallbacks a launch under `young=stw` the oracle row's known cost).
