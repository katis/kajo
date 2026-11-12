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
