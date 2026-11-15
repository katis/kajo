# Allocation stalls and the stop rows' last parker

Allocation stalls, built 2026-11-12 to 13
(`docs/modules/allocation-stalls.md`, ADR 0005's, 0006's and 0008's Built
(allocation stalls) notes; the owner's "fix it properly, choose the best
method so this needs to be done once" of 2026-11-12 about the oracle ring
row): old space is paced by the collector's progress instead of tuned to the
mutator's speed; part 1's records on the Mac's ring at 7 workers confirmed
the brief's inequality (under `young=stw` the marker is parked in scavenges
for more than half its marking wall time, 72 to 74 ms of CPU in 158 to 193
of wall, a cycle takes 200 to 250 ms, 256 to 291 MB are promoted while it
runs against 84 to 87 MB marked, so live + 2 x promotion is 599 to 667 MB
against the 629 MB soft limit, where the shipping modes sit at 417 to 533;
the main worker's promotion 0.1 to 0.3 MB a cycle) and found what it did not
have: relocation, not the sweep, frees the ring's blocks (3509 to 9834
against 142 to 431 a cycle); a cheating build (100 µs sleeps while a cycle
runs, not committed) took the oracle row to 0 fallbacks in six launches
before anything was built; the rule (`Sources/KajoVM/Marking/Pacing.swift`,
`stallForCollector`): a background worker (never the main worker, and never
the host worker, the last, which the shells' main thread enters) whose
promotion, entry or old allocation would cross a limit waits outside every
stop with its object a pending root, raises the marker (the policy's flag
and a QoS override of the marker thread for the wait, `markerOverrides`),
starts a cycle when none runs (trigger `stall`), takes the bounded sweep
stop once per cycle for entries and old space, and otherwise waits untimed
in `waitServicing` for `SafepointState.progress` (bumped under the safepoint
mutex at every stop's release and when blocks are freed outside a stop) or
for the phase to become idle; module 7 promises a background worker
promotion room only below the soft limit and a background worker's scavenge
under `young=stw` is gated on the blocks committed plus one young
generation, so crossing the soft limit no longer requests a full collection
where stalls are on (it still does with no marker thread, under `--gc stw`
and the switch `noStalls`, cause `softLimit`); a stall is justified when a
cycle numbered above the one current at its start has been applied, or a
full collection ran meanwhile (`full`), or under `young=stw` no cycle can
start (`nostart`, `start`), and only then leads to one full collection of
its own, unless the resource is there (`fallbacksAvoided`); every fallback's
record begins cause, requester, worker, justification, stalled ms and live
percent, and a fallback by a background worker with no justification counts
`unjustifiedFallbacks`, a verifier failure in a checked build;
`waitForMarkingCycle`, `waitForSweep` and their 100 ms bounds are gone (one
wait); a waited-on cycle may take relocation's to-space from the reserve up
to the hard limit (part 4, measured: at a marker 4 times slower 3.5 to 4.2
times the background allocations, while skipping relocation brought 5 to 7
justified fallbacks a launch back; `--stall-reloc plain|reserve|skip`);
`VM.start` starts the marker before the workers and a VM never started does
not stall; `fullCollection` always withdraws the request its own promote-all
made (a full heap ran full collections at every poll forever on efc546d, 120
s timeouts in both young modes); no model changed (a stalled worker is the
young-collection model's opener waiting for a wanted stop; the save's hold
with a stall is tested, not model checked); the broken variants: the test
switches `stallJustifiedByRunningCycle` and `stallIgnoresEntries` fail the
unjustified count, and by hand no park in the stall hangs a stopper, no
progress bump alone does not hang (the phase going idle and the epoch frees
still wake) and both removed hang in 40 s; measured on the Mac, the starting
commit's shell against the module's back to back, five launches a row a
side, 7 workers, both engines, 240 rows none failed: the ring under
`young=stw` from 148 to 208 frames missed behind 6 to 9 fallbacks
interpreted and 326 to 346 behind 16 to 17 natively to 1 to 6 and 1 to 5
frames with 0 fallbacks of any kind, 228 to 261 stalls a launch (longest 20
to 25 ms interpreted, 43 to 46 natively), the frames left behind
stop-the-world scavenges of 10.5 to 12.5 ms (the oracle's own cost), the
main thread stopped 990 to 1041 ms per 10 s against 1221 to 1572 (natively
454 to 607 against 1173 to 1550) and throughput up (316 to 318 million
background young allocations against 308 to 313, natively 327 to 330); every
other row 0 frames and 0 fallbacks as before, the native storm under `local`
and `offload` stalling 6 to 137 times a launch for entries (longest 4.5 to
6.9 ms) with the main thread's stopped time within 52 to 64 ms against 50 to
58; the claim as a test, the marker slowed (`--marker-slowdown`, the shells'
`markerslow=`): the ring under `young=offload` at 4 times slower 0 frames
and 0 fallbacks in ten launches with 736 to 3317 stalls a launch (longest
366 to 424 ms) and 248 to 260 million allocations against 469 to 549
unslowed, at 16 times 0 and 0 with 1710 to 1828 stalls (longest 1.65 to 1.72
s) and 52 million: the mutator is paced; the comparison at 8 workers within
its ranges (binarytrees 1748 against 1765 ms kasm and 1780 against 1802
Smalltalk, `collections` 32.2 against 32.1 s, the Symbol-interning stops
unchanged); the devices at 5 workers, 260 launches none failed: 0 fallbacks
and 0 unjustified before and after in every row and no stall in any ring row
(neither device's ring outruns its collector there), the iPad's large churn
234 to 648 stalls for old space a launch (longest 1.7 to 7.6 ms) with the
main thread stopped no longer; the first pair of blocks ran the module's
shell second and hotter and missed more frames (the iPhone's oracle row up
to 17 behind 17.7 ms scavenges at serious), a second pair in the other order
missed no more than the starting commit's (iPhone 0 to 6 and 0 to 2 against
0 to 9 and 0 to 4, iPad 0 against 0 to 2); one iPad launch of the oracle
ring row, after, whose scavenge stop waited 141.3 ms for the safepoint and
missed 17 frames at thermal nominal with no stall in the launch: its last
parker was the marker at utility QoS on the efficiency cores
(`gc_scavSlowest=7` at 5 workers), which is the last parker of the longest
scavenge stop in 36 of the 80 ring `young=stw` device rows (20 of 40 before,
16 of 40 after) with waits of 0.3 to 9.6 ms in every other row but one, so
an outlier of a shape older than the module, not repeated in 20 more
launches and not excluded as made likelier by it (the hand-back put it down
to the large fill that does not poll, which the ring does not have; the main
session's correction then misread `gc_scavSlowest` as the scavenger that
copied longest and called the wait unexplained in 8b4bd73, corrected on
2026-11-13); `interpret` identical (1819 lines each), `just arc-check`
passing, nothing added to the allocation fast path, the store path or the
dispatch loop and no struct the generated C reads changed; 284 new `unsafe`
lines, all in the core; `just check efc546d` on a18696a (docs above the
final code commit 26e3a50), the core tier's 24 gates in 19 660 s, every gate
passing (444 + 161 tests in every test gate, ThreadSanitizer 0 reports alone
and under load, 249 kernel tests, native-kernel-test 3276 of 3276 bound, the
four fuzzers with "libFuzzer build: ok" at 0.86 to 3.39 million runs, the
aligned A/B against efc546d 0.977 to 1.008 at 1 worker with instruction
ratios 1.000 and 0.941 to 1.058 at 8, the gate's Mac matrix 0 fallbacks in
156 rows with frames missed only in the hog rows with the budget off and 714
stalls, the iPhone 0 fallbacks, 0 stalls and 2 to 4 frames in the oracle row
behind 13.6 to 16.2 ms scavenges), a first run having failed `tsan-load` on
a new test whose rings ran past 900 s (it now waits for what must happen,
26e3a50) and `ios-check` and `apps` on an `unsafe` only Xcode's toolchain
and the iOS SDK ask for (a1061d2); the module's tests made the test gates
longer (`swift-test` 1329 s against AOT 1's 1017, `tsan` 4677 against 4110,
`tsan-load` 5889 against 5144; the 401, 3034 and 3492 first recorded here
were review-fixes part 1's, three modules back);
`scripts/check-tier-test.sh` had failed since AOT 1 added its three gates
and no gate runs it (fixed in 53860b7); not done: the main and the host
worker never stall, so one worker running everything on main still falls
back when it outruns the collector, under `young=stw` the main worker's
scavenges promote every nursery into the reserve (a fallback named `main`,
seen in no row), an allocation inside a stop never stalls, the large fill's
times to safepoint on the iPad (initial marks that waited 452 ms before and
41.5 after), no device energy measurement of the QoS override; its five open
questions answered by the owner on 2026-11-13 as recommended and as built
(the main and host workers exempt everywhere, headless hosts included; no
time bound on a stall; a stalled Mutex holder the main thread waits on
accepted; a waited-on cycle may take the reserve for relocation; a full
collection during a stall justifies it with no cycle named); the stop rows'
last parker, built 2026-11-13 at the owner's request (40ce930,
`docs/modules/allocation-stalls.md` "The last parker in the rows";
`Headless.swift`, `scripts/shell-report.py` and one test, no record
changed): `stopsByKind` on the run line and `gc_stopsByKind` in the shells'
rows are `kind:count/longest pause ms/longest wait for the safepoint ms/last
parker/how it parked` per kind, the last two of the stop with that wait, the
parker by name (`participantName`: `main`, `w<i>`, `host`, `marker`,
`young`) and the way a `ParkVia` (`poll`, `wait`, `stopper`);
`shell-report.py --bar` gained a last column, the longest wait for a
safepoint with its kind and parker, per file and over all with its row, a
row from before the fields reading `?`; `just check` on 40ce930, the Swift
tier, passed every gate in 6147 s (445 + 161 tests, ThreadSanitizer 0
reports in 4526 s, 249 kernel tests, apps, new-check); not done: no device
row has the new fields before the weekly run of 2026-11-15.
