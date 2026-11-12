# Allocation stalls: old space paced by the collector's progress

A collector follow-up to modules 4, 5 and 7, the large-bytes and sweep-stop
follow-ups and AOT 1. Briefed 2026-11-12 from the owner's decision of the
same day: after AOT 1's report that the oracle ring row falls back twice as
often under the native engine, and an explanation of why, the owner asked
for it to be fixed properly, with the method chosen so that it needs doing
once. The method is the main session's choice and is argued here.

## What is wrong

A fallback is a stop-the-world full collection (module 1's mark and sweep,
compacting since the reserve-and-depth follow-up) taken because old space
or the entry table ran out before the concurrent cycle that would have
freed them had finished. It stops every worker and the main thread for 185
to 325 ms. Three modules in a row have each removed the fallbacks one
measurement showed, and each faster mutator has brought them back:

| ring, 10 s | frames missed | fallbacks | cycles started / done | old peak |
|---|---|---|---|---|
| Mac, 7 workers, `young=stw`, interpreted | 189, 187, 189 | 9, 8, 9 | 43 / 34 | 641 MB |
| Mac, 7 workers, `young=stw`, native | 350, 346, 335 | 17, 17, 16 | 37 / 21 | 644 MB |
| Mac, 7 workers, `young=local`, native | 0 | 0 | 91 / 90 | 514 MB |
| Mac, 7 workers, `young=offload`, native | 0 | 0 | 92 / 91 | 489 MB |
| Mac, 7 workers, `young=offload`, interpreted | 0 | 0 | 89 / 88 | 474 MB |
| iPhone, 5 workers, `young=stw`, interpreted | 3, 1, 2 | 0 | | |
| iPhone, 5 workers, `young=stw`, native | 43, 47, 19 | 1, 1, 0 | | |

(AOT 1's matrices; the heap is 600 MiB. The interpreter-speed module took
the same row from 20 to 28 fallbacks to 26 to 32, the sweep-stop follow-up
to 8 to 10, the native engine to 16 to 17.)

The ring load (`ShellBench class >> ring:`) promotes about 0.7 of what it
allocates (the nodes survive every scavenge and die in old space 32 768
iterations later): 1.2 to 1.9 GB/s of promotion over about 85 MB of live
old data. Marking is snapshot-at-the-beginning, so everything promoted
while a cycle runs floats until the next cycle. A steady state therefore
needs

    live + 2 x (promotion rate x cycle time) <= the soft limit

and nothing in the VM makes that hold. Under `young=stw` the marker is
parked in about 850 scavenge stops a run (its wall time per cycle is 2.4
times its CPU time: 152 against 64 ms), the cycle takes 200 ms, and 85 MB +
2 x 240 to 300 MB is over 600 MiB: 16 of the native row's 17 fallbacks
found a cycle still marking. The shipping modes hold only because their
cycle is 115 to 120 ms: they sit at 77 to 86 percent of the limit with the
marker at 88 to 93 percent of a core running cycles back to back (marker
CPU 8.8 to 9.3 s of 10). The next faster mutator (inline allocation, AOT 3)
tips them over as the native engine tipped the oracle. The lesson is in
`AGENTS.md` twice already: a faster mutator is a heavier load on every
provisioning rule.

Every earlier fix made the collector start sooner or run at a higher QoS.
Those are capacity levers: they move the speed at which the inequality
breaks. Parallel marking and mark assists are capacity levers too. The only
thing that makes the inequality hold at every mutator speed is to bound the
promotion rate by the collector's progress: a worker that would take old
space past its limit waits for the collector instead of stopping the world.
This is what concurrent collectors that give the guarantee do (ZGC's
allocation stalls, Shenandoah's pacing). The VM already has two such waits
for two of the resources, each with a 100 ms bound after which it falls
back anyway (`waitForMarkingCycle` for an empty entry table while a cycle
marks, `waitForSweep` for an old allocation the sweep's hand-over cannot
serve; `Marking/Sweep.swift`, `MarkingConfig.allocationWaitMs` and
`sweepWaitMs`), both polling with `usleep(100)`. It has none for the
resource the ring exhausts, blocks for promotion: `afterYoungCollection`
(module 7) and module 4's scavenge set `fullRequested` when a collection
leaves old space over the soft limit, and a requested full collection also
suppresses the cycle trigger.

## The rule this module builds

**The collector's turn.** A background worker (any worker but the main
one) whose mutator code needs a resource of old space that it cannot have
without crossing a limit raises the marker, makes sure a cycle is running,
and waits, outside every stop, until the collector's progress has made the
resource available. The resources are: blocks for a young collection's
promotion (module 7's promise in `openYoungCollection`, module 4's scavenge
in `young=stw`), entries (an empty stash and table), and room or a run of
blocks for an old or large allocation. The wait is one mechanism for all
three. It is ended by the collector's progress and by nothing else: not by
a clock.

**The fallback stays, counted, and must be justified.** A full collection
on behalf of a background worker's mutator code is taken only when a
marking cycle whose snapshot was taken after that worker began to wait has
completed and been applied and the resource is still not available: the
heap is full of live data (or fragmented past what the cycle's relocation
could repair; the record tells the two apart), and after the full
collection the existing out-of-memory rules apply. A stall is therefore
bounded by two cycles. Every fallback's record says who asked (a background
worker's justified wait, the main worker, an allocation made inside a
stop), what ran out and which cycle justified it. A fallback that is none
of these is `unjustifiedFallbacks`, a counter that is 0 in every test and
every row and a verifier failure in checked builds.

**The main worker never waits outside a stop** (the owner, 2026-11-09). It
is exempt from the stall. Starting position: background promotion is
promised below the soft limit (`blocksInUse + promotionReserved + needed <=
softLimitBlocks`, else the worker stalls), and the reserve above the soft
limit is the main worker's and the collector's own, as `reservePromotion`
already takes promises from it; the main worker's existing path when even
the reserve refuses (a stop-the-world scavenge keeping in place what finds
no block, then a full collection) stays, counted with a record naming main.
Crossing the soft limit is then no longer a reason for a full collection by
itself: `fullRequested` after an over-limit collection goes, and pressure
never suppresses the trigger.

Binding rules, each from a lesson in `AGENTS.md`:

1. A stall happens outside every stop, with no lock held, no young
   collection open, no pin or hazard slot taken, nothing of the current
   instruction live but what is flushed, and the object being allocated (if
   any) a pending root. An allocation made inside a stop never stalls; it
   keeps the in-stop paths (the bounded sweep stop's hand-over, then a full
   collection whose record names the operation).
2. Every wait inside the VM is a place a stop must reach. A stalled worker
   parks for stops, services handshake rounds, is quiescent for epochs with
   the wake's zero, and holds nothing the marker, the relocator, the young
   collector, a stopper or the saver waits for. `waitServicing`
   (`YoungCollection/Rounds.swift`) is the existing wait that does all of
   this under the safepoint lock; reuse it or say why not.
3. The wait is untimed (a timed wait in an idle thread is the VM's whole
   idle cost; the two existing waits poll every 100 microseconds). Before
   the bounds go, list every transition the wait depends on and show each
   signals under the lock: a sweep's apply (whole or partial), blocks freed
   by an epoch, a cycle's end and its abandonment, a full collection by
   anyone, a scavenge by anyone (in `young=stw` another worker's scavenge
   empties the waiter's eden, so its need is gone), an operation of module
   1 that abandons marking, shutdown. A test shows that work after a stall
   completes within a CPU bound.
4. A starved thread cannot raise itself: the stalling worker raises the
   marker (`wantUserInitiated`) from its own thread, and makes sure a cycle
   is running by the mode's own way (with module 7 it may request the
   initial mark; in `young=stw` the initial mark rides a scavenge and
   nothing may be young, so say how a cycle starts when every worker is
   stalled and none is running). The marker's QoS policy covers every role
   it plays while workers wait on it.
5. Stall time is not VM work and not a stop. It is counted apart: stalls,
   their total, p50, p99 and maximum, by resource and by outcome (resource
   came, justified fallback), per worker; on the run line, in the shells'
   result rows, as a column of `scripts/shell-report.py` and `--bar`. A
   slice's budget and the turn-overrun bound do not count it as CPU.
6. Any change to a protocol that has a model (`models/`,
   `docs/models/young-collection.md`, `save-hold.md`, `relocation.md`)
   updates the model in the same commit. If the stall adds no state the
   models have (a stalled worker is one in `waitServicing`), say so with
   the argument. The save's hold needs its own paragraph: a stalled worker
   is in a slow path, not at a resume point, so the hold waits for the
   stall, and the collector must never wait for the saver.
7. Every reader agrees in the same commit: every site that sets or reads
   `fullRequested`, `fullCollectionDue`, the soft limit, `promotionReserved`
   and the three old waits is listed in the doc with what it does after.
   Every consumer of old-space blocks is listed with whether it stalls,
   uses the reserve or runs in a stop (promotion in each young mode, old
   and large allocation, relocation's to-space, compaction, class
   definition and reshape, become, the answers of primitives 167 and 169,
   symbols, the image build).
8. The native engine calls the VM's own slow paths, so the generator should
   not change. If a struct the generated C reads changes layout, the layout
   hash must cover it; say which. `interpret` stays identical instruction
   for instruction and `just arc-check` passes.
9. `--gc stw` has no concurrent collector to wait for and is unchanged: its
   full collections are its collector, not fallbacks.

## Parts

1. **Instrument, and bound the idea with a cheating build.** Before any
   design is fixed (a module's part 1 is always the instrumentation, and a
   brief's premise is measured before it is built):
   - a per-cycle record: old space and entries at the snapshot and at the
     end, bytes promoted while the cycle ran, live bytes marked, blocks
     freed by the sweep and by relocation, the marker's CPU, wall and
     parked time per phase, and whether anything waited on it;
   - promotion per young collection and per worker, the main worker's
     apart;
   - on the Mac's ring row at 7 workers, each young mode, both engines:
     check the inequality above against the records, and say what the
     analysis in "What is wrong" got right and wrong;
   - a cheating build: background workers that would cross the soft limit
     sleep in a park-aware loop while a cycle is in progress, nothing else
     changed. Run the same rows. If fallbacks do not go to 0 or near it,
     find out why before building anything (fragmentation that relocation
     does not repair, the main worker's own promotion, a cycle that cannot
     start); this checkpoint is real, and a hand-back at it with the
     records is a good result.
   Record what the cheating build costs in throughput (ring iterations
   done) against the fallbacks it removes.

2. **The stall for promotion**, in all three young modes, with the rule's
   invariant, its record and the unjustified counter, the main worker's
   exemption and the removal of `fullRequested` as a consequence of
   crossing the soft limit. The models, if touched.

3. **One wait.** `waitForMarkingCycle` and `waitForSweep` become the same
   stall for entries and for old and large allocations; the 100 ms bounds
   and the `usleep` polls go unless a measurement shows a bound protects
   something (say what). The bounded sweep stop that hands already swept
   entries to the allocators stays: it is not a fallback. `allocWaits` and
   `sweepWaits` on the run line become the stall counters by resource, and
   every reader of the old names (reports, `--bar`, tests, docs) follows.

4. **What the records ask for.** Decided from part 1 and from the stalls
   part 2 and 3 count, each change measured on its own and kept or
   discarded: whether a cycle something waits on skips, shortens or uncaps
   its relocation pass (the pass is about a sixth of the marker's time on
   the ring, and it is also what repairs fragmentation, so decide by which
   the records show); whether the trigger should start cycles earlier when
   stalls occur (stalls are the signal the predictor lacked); whether the
   marker's raise for a waited-on cycle needs anything beyond what exists.
   No tuning constant is added without the row that needed it.

5. **A slowed marker.** A test switch that makes the marker N times slower
   (it stands for a mutator N times faster): at 4 and 16 the ring-like
   kernels and the random programs finish with the oracle's checksums, 0
   unjustified fallbacks and 0 justified ones where the live data fits,
   with the stalls counted. This is the module's claim (speed independence)
   as a test. A counter shows the switch's slow path is taken.

6. **Before and after**, both engines: the Mac's matrix, the iPhone's and
   the iPad's rows (see the bar).

## Tests

Each new test is run on the starting commit; the ones that pass there are
said to pass there.

- A headless ring-like kernel (`fragment.kasm`, `oldheap.kasm` and
  `allocstorm.kasm` are the nearest fixtures; the shells' `ring:` is the
  load to imitate) on a small heap at several workers that counts soft-limit
  fallbacks on the starting commit and after has 0 fallbacks, stalls above
  0 and the same checksum, in every young mode and both engines.
- The slowed marker at 4 and 16, as part 5.
- A genuinely full heap: live data that does not fit. The fallback is
  justified (its record names the completed cycle), then out of memory as
  now. The test finishes within a CPU budget; no wall-clock assertion.
- Fragmentation: a load that keeps one object in twenty per block with
  relocation on and with `--reloc off`; the records tell fragmentation
  from a full heap.
- Main-only growth: the main worker alone exhausts its reserve; the record
  names main and no background worker's stall is charged.
- Entries and old allocations: a storm that empties the entry table and a
  large-allocation churn (the photo scenario's shape) stall and finish
  with 0 fallbacks.
- A stalled Process is terminated, stepped and saved (`Smalltalk
  snapshot:` from another Process, and a host save): each completes, the
  stall's end is what they wait for, and an image saved meanwhile loads.
- Idle after a stall: a VM whose workers stalled and finished wakes no
  thread while idle, and work after idling completes within a CPU bound.
- Broken variants. As test switches where the variant fails a check: the
  gate ignores the entry table; the cycle already running when the wait
  began counts as the justifying one (must count an unjustified fallback
  or fail the verifier). By hand, with the trap or hang message recorded,
  where it hangs or traps: no park in the stall (a stop waits forever);
  no wake at the apply.
- The random programs gain a configuration with a small heap and a slowed
  marker whose stall counter must be above 0 over the run (assert on what
  must have started, not on what completed), in both engines (the native
  one at 100 seeds).
- Each new Swift suite once under ThreadSanitizer with twelve busy loops
  before the gates.

## Bar

- The ring row under `young=stw` on the Mac at 7 workers and on the iPhone
  at 5, both engines, five launches each: 0 unjustified fallbacks and 0
  soft-limit fallbacks; any fallback left is named by its record and
  explained. Every frame still missed in that row is attributed (a
  scavenge stop over a frame is the oracle's known cost; say what is left
  and why). Ring iterations done before and after.
- The shipping modes' rows (`young=offload`, `young=local`; storm, ring,
  share, large, photo, idle) on the Mac in both engines: 0 frames missed
  and 0 fallbacks as before, the main thread's stopped time and the
  throughput no worse in interleaved launches, stalls reported per row
  (0 is expected; a row that stalls is discussed).
- The devices, in blocks run back to back with the thermal state on every
  line, five launches a row a side: the iPhone and the iPad, both engines,
  ring in the default mode and under `young=stw`, storm, large and photo.
  0 fallbacks, frames and the main thread's stopped time no worse; the
  iPad's large churn (146 to 284 sweep stops a launch before) is the row
  the unified wait touches most.
- The slowed-marker rows: the Mac's ring row in the default mode with the
  marker at 4 and 16 times slower misses no frame on the main thread and
  counts no fallback; stalls and throughput reported.
- `collections` and binarytrees at 8 workers (the comparison's programs):
  no slower, their stop tables beside the old ones.
- The aligned A/B of the interpreter against the starting commit within
  noise at 1 and 8 workers with `interpret` identical; `just arc-check`.
- The core tier's `just check <starting commit>` on the final code commit,
  every gate.

## Not in this module

- Parallel marking and mark assists: the capacity lever, with its own
  design (the header word cannot be an atomic; see `AGENTS.md`). With the
  stall in place they become a throughput question, not a correctness one.
- Growing the heap past its configured size.
- The oracle's scavenge stops themselves (13 to 17 ms on the iPhone).
- Symbol interning without a stop.

## Open questions for the owner (build the recommended option, list the question)

1. The main worker stays exempt in every host, headless ones included, so
   one worker running everything on main still falls back when it outruns
   the collector (recommended: yes, one rule everywhere; a host setting
   that lets a headless host stall worker 0 is a small later step).
2. A stall has no time bound; it ends with the collector's progress, at
   most two cycles (recommended). The alternative is a bound after which a
   background worker stops the world anyway, which is the behaviour this
   module removes.
3. A background Process that stalls while holding a Mutex the main thread
   waits on makes the main thread wait for the stall. Recommended: accept
   and document; it replaces a stop of the same length for everyone.

## As built (2026-11-12)

Starting commit efc546d. Commits, in order: 41dc7a0 (part 1, the
instrumentation), 7b5f181 (part 2, the stall for promotion), 0f95e2c
(part 3, one wait), c56b255 (part 5's switch), 7de6598 (part 4's kept
candidate; it builds only with the next commit, which carries
`cycleWaitedOn` and the options), 1d42a59 (the host worker exempt, a full
collection ends a stall, the justification records, the full-heap
livelock), b74ea73 (the tests), 53860b7 (`shell-report.py`,
`check-tier-test.sh`), 5115a82 (a stall needs a running marker), and the
docs. Raw rows, records and runs are in the hand-back's output directory
(`baseline/`, `cheat/`, `steps/`, `slowed/`, `mac-matrix/`, `device/`,
`comparison/`, `ab/`, `check/`).

### Part 1: what the records showed

Each cycle's record (`CycleRecord`, `Marking/Pacing.swift`'s
`cycleRecordAtStart` and `cycleRecordAtEnd`; `cycleRecs` on the run line,
`gc_cycleRecs` in the shells' rows) now carries old space in blocks at the
snapshot and at the end, the bytes promoted while the cycle ran (every
nursery and the main worker's alone: `promotedMainBytes` in module 4's
participant stats by the claimed header's nursery, and in module 7's log
under the safepoint mutex), the blocks the sweep and the relocation freed,
the marker's CPU, wall and parked time by phase (marking, relocation,
sweeping; `markerPoll` times each park), the relocation pass's wall and
CPU time, and the stalls and fallbacks during it. The run line gains
`youngAllocMain` and `promotedMainMB`.

The Mac's ring at 7 workers on the instrumented starting code (41dc7a0),
three launches per young mode and engine, interleaved (`baseline/`):

| ring, 10 s | fallbacks | cycles done / abandoned | cycle ms | promoted while it ran MB | marked MB | marked + 2 x promoted MB | cycles over the soft limit (629 MB) | marking CPU / wall / parked ms |
|---|---|---|---|---|---|---|---|---|
| `young=stw` interpreted | 9, 9, 11 | 34/7, 36/7, 20/11 | 218 to 247 | 256 to 260 | 84 to 87 | 599 to 606 | 14 of 34, 19 of 36, 7 of 20 | 72-74 / 158-193 / 84-113 |
| `young=stw` native | 17, 16, 17 | 22/16, 28/13, 20/16 | 200 to 211 | 283 to 291 | 85 to 86 | 652 to 667 | 20 of 22, 25 of 28, 18 of 20 | 65-68 / 153-166 / 89-96 |
| `young=local`, `offload` interpreted | 0 | 86 to 87 / 0 | 116 to 120 | 168 to 174 | 82 to 83 | 417 to 431 | 0 | 78-80 / 82-84 / 0 |
| `young=local`, `offload` native | 0 | 76 to 91 / 0 | 120 to 144 | 199 to 226 | 82 to 84 | 481 to 533 | 0, 1 or 3 | 80-91 / 83-106 / 0 |

The inequality held as the brief wrote it: under the oracle the marker is
parked in the scavenges for more than half its marking wall time, the
cycle takes 200 to 250 ms, the promotion while it runs is 256 to 291 MB,
and live + 2 x promotion passes the soft limit in most cycles (in all but
2 to 3 per launch natively). The shipping modes sat at 417 to 533 MB of
629. Right too: the main worker's promotion is negligible (0.1 to 0.3 MB a
cycle; `main MB/cycle` in `notes.md`).

What the brief did not have: **relocation, not the sweep, frees the ring's
blocks.** The sweep freed 142 to 431 blocks a cycle and the relocation
3509 to 9834 (`notes.md`, "Blocks freed per completed cycle"): a
mark-sweep frees whole blocks only and the ring keeps one node in twenty
scattered through old space. That decided part 4.

**The cheating build** (`cheat/cheat.patch`, not committed): a background
worker that would cross the soft limit (module 7: the blocks in use, those
promised and its Y; module 4: half the reserve) sleeps 100 µs at a time,
parking for stops and servicing rounds, while a cycle runs. Same rows,
three launches each (`cheat/`): `young=stw` 0 fallbacks in all six
launches (interpreted 4, 6, 3 frames missed; native 3, 5, 3; against 189 to
309 and 328 to 350), the shipping modes unchanged (0 stalls). Its cost:
background young allocations (a proxy of ring iterations, three young
allocations an iteration) 89.1 to 90.5 million against 80.5 to 103.2
interpreted and 83.1 to 84.1 against 98.9 to 105.3 natively. The
checkpoint passed: the rule gives the guarantee on the Mac's oracle row,
and nothing in the records said it could not.

### The rule as built

**The stall** (`Marking/Pacing.swift`, `stallForCollector`). A background
worker (any but the main worker, 0, and the host worker, the last: the
host worker is entered by whatever thread calls into the VM, the shells'
main thread among them) that needs a resource it cannot have without
crossing a limit, outside every stop, its registers flushed, no lock held,
no young collection open, the object it holds (if any) a pending root:

1. raises the marker: the policy's flag (`wantUserInitiated`) and a QoS
   override of the marker thread to user-initiated from the stalling
   thread for as long as it waits (`pthread_override_qos_class_start_np`
   on the thread named by the Mach port the marker stores itself;
   `markerOverrides`, one per stall);
2. loops: asks `available()` (outside the safepoint mutex: it may take
   the pools' lock; for an old allocation and the entries it is the
   allocation or the stash's refill itself); ends `justified` when a
   cycle numbered above the one current when the stall began has been
   applied (`MarkingLog.lastAppliedCycle`, written in the apply's stop),
   or when a full collection ran meanwhile; runs a requested full
   collection as a poll would; for entries and old space, takes the
   bounded sweep stop once per cycle while a sweep is pending (it hands
   swept entries over and is not a fallback); starts a cycle when none
   runs (trigger `stall`); otherwise waits, untimed, in `waitServicing`
   for `SafepointState.progress` to change or the phase to become idle.
   The deadline of the worker's slice moves by the stall's time.

**The promise rule** (the brief's starting position, confirmed by part 2's
rows): module 7's collection of a background worker is promised room only
below the soft limit, the blocks in use and every promise counted
(`ObjectMemory.reservePromotion(blocks:belowSoftLimit:)`, `canPromise`);
the main worker's keeps module 7's rule (the reserve up to the hard
limit). Under `young=stw` a background worker's scavenge is gated: it
stalls while the blocks committed and one young generation of every
nursery (`youngGenerationBlocks`, the reserve's own unit, a half of it)
pass the soft limit; another worker's scavenge that empties its eden
ends the stall too. Crossing the soft limit no longer requests a full
collection where stalls are on; where they are off (no marker thread,
`--gc stw`, the switch `noStalls`) it still does, now recorded as cause
`softLimit`.

**The fallback**: a stall that ends `justified` leads to one full
collection in a stop of its own (`justifiedFullCollection`), unless the
resource is there in that stop (several workers' stalls end at the same
apply and the first one's collection serves the others:
`fallbacksAvoided`); after it the allocation is module 4's out-of-memory
rule as before, and its fallbacks stay justified until the allocation
ends. Under `young=stw` a cycle starts with a scavenge (nothing may be
young at the snapshot but survivors, which are roots), whose promotion
takes the reserve once per cycle started; when the reserve cannot hold one
young generation no cycle can start and the stall is justified at once
(`nostart`).

**Measured** (part 2, `steps/p2`, three launches each): the Mac's ring
under `young=stw` 0 fallbacks in all six launches, 1 to 8 frames missed
(scavenge stops of 11 to 14 ms), 228 to 264 stalls a launch (p50 12.0 to
16.8 ms interpreted, 36.8 to 38.0 natively; longest 23.6 and 50.6 ms), and
104 to 108 million background young allocations against the starting
code's 80.5 to 105.3: no throughput lost against the fallbacks it
replaced, 15 to 25 percent more than the cheating build. The shipping
modes: 0 stalls, unchanged.

### The wait and its transitions

`stallForCollector` waits in `waitServicing` under the safepoint mutex,
with the condition `progress unchanged and the phase not idle`. What it
holds while it waits: the safepoint mutex only inside `pthread_cond_wait`;
one pending-root slot; nothing else (no pool lock, no young collection, no
pin, no hazard slot, no body pointer: its epoch word is quiescent through
`waitServicing`'s `epochQuiesce` and its wake stores 0 first). The
transitions that end the wait, each signalled under the safepoint mutex:

| transition | where it signals |
|---|---|
| a sweep's apply, whole (`applyInStop`) or partial (`publishSwept`) | in a stop; every stop's release bumps `progress` and broadcasts the safepoint condition (`stopWorld`) |
| a cycle's end (apply) and its abandonment (`abortCycle`) | in a stop; both also set the phase idle, the wait's second condition |
| a full collection by anyone, a scavenge by anyone (`young=stw`: it empties the waiter's eden) | in a stop |
| an initial mark, a final mark, a sweep stop, an instances stop, a save's stop | in a stop |
| blocks freed outside a stop (module 6's epoch frees, `tryFreePending` with `atPause` false) | `tryFreePending` bumps `progress` and broadcasts under the mutex |
| a stop request (the waiter must park) | `stopWorld` broadcasts the condition after `requested` is set; `waitServicing` parks |
| module 7's rounds owed | `runRound` broadcasts; `waitServicing` services |
| shutdown | `VM.shutdown` joins the workers before the marker and the young collector, which keep running cycles until then; a stall ends by their progress |

The broken variants run by hand (`broken-variants.txt`): without the park
a stop waits for the stalled workers forever (three workers in the stall's
wait, the stopper in `stopWorld`); without the progress bump at a stop's
release the wait still ends, by the phase becoming idle at the apply (the
second wake path) and by the epoch frees; without both, every background
worker stalls with the marker idle (no cycle to mark, nobody starts one):
a hang in 40 s.

### Liveness

- **Stops**: the stall waits in `waitServicing`, which parks for a
  requested stop (`requested && inside && stopper != me`), and every stop
  request broadcasts the condition. Its own stops (a cycle's start, the
  sweep stop, the justified full collection, a requested full collection)
  are requested from outside every stop with nothing held.
- **The wait for open young collections before a stop request**: a
  stalled worker has no collection open (module 7's stall happens before
  `openYoungCollection` succeeds; the refused open opens nothing).
- **Handshake rounds**: serviced in `waitServicing` (`owedLocked`).
- **Epoch words**: quiescent while it waits, 0 then the global epoch at
  the wake (`waitServicing`).
- **Owed young-root scans**: a stalled worker's nursery is scanned by the
  marker, by a stop or by its own next collection, as for any idle owner;
  the stall opens no collection, so no scan is owed by it.
- **The sweep's apply stop**: the marker requests it; the stalled worker
  parks for it. The sweep stop a stall takes is bounded (`sweepStopWords`).
- **The relocation pass**: polls between objects; a stalled worker never
  holds an object the relocator waits for (no hazard slot, no pin).
- **The save's hold**: a stalled worker is in a slow path, not at a resume
  point, with a Process on it; the saver waits (`otherRunnersInside`) for
  it to leave at a poll, which it reaches when the stall ends. The stall
  ends by the collector's progress, and the collector never waits for the
  saver: the saver holds the scheduler and waits outside any stop, so the
  marker's stops and the young collector run. Tested
  (`aSaveWaitsForAStallAndItsImageLoads`).
- **Interrupts and terminate**: delivered at the Process's first poll
  after the stall (tested: `aStalledProcessIsTerminated`,
  `aStalledProcessTakesAnInterrupt`); a stall is bounded by two cycles.
- **The slice budget**: the stalled worker's deadline moves by the stall's
  time; the main worker and the turn-overrun bound never stall.
- **Shutdown**: above.
- **No collector to wait for**: stalls need the marker thread running
  (its Mach port stored, `stallsEnabled`); a VM driven slice by slice from
  a test thread and never started has none and does not stall (found by
  the full suite: `ExtremeIntegerTests`' extreme `basicNew:` waited there
  forever before 5115a82). An old allocation larger than the soft limit
  itself never stalls.

### How a cycle starts when workers stall

Module 7 (`local`, `offload`): the stalling worker runs the initial-mark
pause itself (`initialMarkPause`, trigger `stall`), no scavenge. Module 4
(`young=stw`): the stalling worker's stop scavenges and starts the cycle
at the scavenge's end (`startCycleInStop`, trigger `stall`); its promotion
takes the reserve (the collector's own), once per cycle started, and
should it find no block the full collection that follows is the stall's,
justified (`start`). When the reserve cannot hold one young generation no
cycle can start and the stall is justified (`nostart`). In the shells'
rows the trigger counts `byStall` 1 to 14 a launch where the stalls
started cycles; the floor and the predictor started the rest.

### Every site, after

| site | before | now |
|---|---|---|
| `Nursery/Scavenge.swift`, end of a scavenge | old space past the soft limit set `fullRequested` | only with stalls off (no marker thread, `noStalls`, `--gc stw`), cause `softLimit` |
| `Nursery/Scavenge.swift`, kept objects | set `fullRequested` | sets it with `fullRequestInfo` (cause `reserve`, requester, worker) first |
| `YoungCollection/Owner.swift`, `afterYoungCollection` | over the soft limit set `fullRequested` | only with stalls off |
| `Marking/FinalMark.swift`, failed verifier | set `fullRequested` (then counted as a soft-limit fallback) | cause `verifier`, requester `inStop` |
| `fullCollection` | withdrew the request only below the soft limit | always withdraws the request its own promote-all made (a full heap's workers otherwise ran full collections at every poll forever; 120 s timeouts on efc546d in both young modes, `failing-before.txt`) |
| `youngPause`, `runDueFullCollection` | noted `.softLimit` | `noteRequestedFullCollection`: the request's cause and requester |
| `fullCollectionDue` readers (`Poll.swift`, `Safepoint.swift`'s flag, `afterScavenge`, `afterYoungCollection`, `initialMarkPause`, `startCycleInStop`) | unchanged | unchanged: a request now means a reserve fallback or a failed verifier only, so pressure no longer suppresses the trigger |
| the soft limit (`isOverSoftLimit`, `softLimitBlocks`) | above, plus `leavesNoHeadroom`, the relocator's cap, `wantsRaise`, `decideTrigger` | unchanged but the relocator's cap in a waited-on cycle (part 4) |
| `promotionReserved` | `reservePromotion`, `releasePromotion` | also `canPromise`, `blocksCommitted` (read under the pools' lock) |
| `waitForMarkingCycle`, `waitForSweep`, `allocationWaitMs`, `sweepWaitMs`, `AllocationWaits` | the large-bytes and sweep-stop waits | removed: the stall for entries and for old space |
| `allocWaits*`, `sweepWaits*` on the run line | counted the two waits | removed; `stalls*` by resource replace them; no script or test read the old names (`FallbackPolicyTests` read `allocationWaits` and were rewritten) |

### Every consumer of old space

| consumer | now |
|---|---|
| promotion, module 7, a background worker | promise below the soft limit, else stalls |
| promotion, module 7, the main worker | the reserve, as before |
| promotion, module 4 scavenge requested by a background worker | gated (blocks committed + a young generation <= soft limit), else stalls |
| promotion, module 4 scavenge by the main worker or the host, and every scavenge's promotion of other nurseries | the reserve, as before (the oracle's nature: a scavenge promotes every nursery) |
| an old or large allocation, background worker | stalls (its retry the allocation), then the stop |
| an old or large allocation, main worker or host | the stop as before (the sweep finished whole, else module 1's collection) |
| entries, background worker | stalls (the sweep stop's hand-over once per cycle), then the stop |
| relocation's to-space | under the soft limit; in a cycle a stall waits on, up to the hard limit (part 4) |
| compaction, class definition and reshape, become, primitives 167 and 169's answers, symbols, the image build | in a stop, as before: an allocation inside a stop never stalls |

### Fallbacks, records, counters

A fallback's record (`FallbackRecord`, `fallbackLog`) now begins
`cause/requester/worker/justification/stalled ms/live percent`: cause
`reserve`, `entries`, `old`, `promotion`, `verifier`, `soft` (stalls off)
or `other` (stress, not counted); requester `main`, `stall`, `inStop`
(an operation in a stop, the host, the marker), `noMarker` (stalls off) or
`background` (none of these); the justification `cycleN`, `full`,
`nostart` or `start`; the justifying cycle's marked bytes over the blocks
in use (a full heap reads 90 percent and more, the fragmented ring 52 to
65). `unjustifiedFallbacks` counts the requester `background`, also when
a stall's justifying cycle is not numbered above the cycle it began in;
in a checked build it is a verifier failure (`VM.counters[.unjustifiedFallbacks]`).
Counters on the run line (and as `gc_*` in the shells' rows): `stalls`,
`stallMs`, `stallP50ms`, `stallP99ms`, `stallMaxMs`, `stallsJustified`,
`stallsPromotion`, `stallPromotionMs`, `stallsEntries`, `stallEntriesMs`,
`stallsOld`, `stallOldMs`, `stallsByWorker` (count/ms for workers 1 to n),
`stallCyclesStarted`, `markerOverrides`, `stallLogDropped`, `byStall`,
`fallbacksReserve`, `fallbacksSoftLimit`, `fallbacksPromotion`,
`fallbacksByMain`, `fallbacksByStall`, `fallbacksInStop`,
`fallbacksNoMarker`, `unjustifiedFallbacks`, `fallbacksAvoided`,
`markerSlowdown`, `markerSlowSpins`, `markerSlowSpinMs`,
`relocReserveCycles`, `relocSkippedForStalls`, `cycleRecs`,
`youngAllocMain`, `promotedMainMB`. `scripts/shell-report.py --bar`
gains the unjustified fallbacks and the stalls with the longest, and a
note naming any row with an unjustified fallback; its scenario tables a
stalls column.

### The models

No model is changed. A stalled worker is a participant waiting in
`waitServicing` with no collection open, its epoch word quiescent and
woken with the zero: the young-collection model's opener waiting for a
wanted stop is that state already (`docs/models/young-collection.md`,
the opener's wait and its wake), and the model has no notion of why it
waits. The relocation model is unchanged by part 4 (which block a
to-space comes from is not in its entry state machine). The save's hold
(`docs/models/save-hold.md`): a stalled worker is a W whose instruction
has not ended; the model's saver waits for `otherRunnersInside`, which
counts it, so the save never runs mid-stall, and the stall's end does not
depend on the saver (the marker's stops proceed during the hold). The
argument is tested, not model checked.
