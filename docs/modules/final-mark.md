# The final mark on the devices (a follow-up to modules 5 and 7)

Status: built, 2026-11-07, from the brief of the same day (the open item of
module 9a's device rows, `docs/modules/shells.md`, and the large-bytes
follow-up's last device block, `docs/modules/large-bytes.md`, "After").
Code in `Sources/KajoVM/Workers/Safepoint.swift` and `VMState.swift` (the
stop's record), the new `Sources/KajoVM/Marking/FinalMarkRecord.swift`
and `RootScans.swift`, `Marking/FinalMark.swift`, `Marker.swift`,
`InitialMark.swift`, `SATB.swift`, `MarkingState.swift`,
`MarkingConfig.swift`, `MarkingHost.swift`, `Sweep.swift`,
`Relocation/Hazard.swift` (the array copy's SATB record),
`Nursery/Scavenge.swift`, `YoungCollection/Collect.swift`,
`Rounds.swift`, `YoungState.swift`, `YoungConfig.swift`, `YoungHost.swift`,
`Headless.swift` (the report) and `Shell/Shell.swift`; the shells' run
line in `Sources/KajoShellCore/Scenario.swift`; the young-collection model
in `models/Sources/YoungCollectionModel/` and
`docs/models/young-collection.md`. Tests in
`Tests/KajoVMTests/Marking/FinalMarkTests.swift`. `scripts/check-hot-path-arc.sh`
covers the new scans.

The brief asked why the final mark's stop is 7 to 20 ms on the devices
with young collection on and to bound it. The record it asked for said
first that the stop was never that long: **the final mark's stop, from its
request to its release, is 0.16 to 0.54 ms on both devices** in every
mode; the 7 to 20 ms were the stopper's wait for open young collections
*before* its request, with the world running, which module 3's stop
record counted as time to safepoint. That wait cost a frame once, through
the main worker, which may not open a collection while a stop is wanted.
The stops that did cost frames in the young modes were the **initial
mark's**, whose young-root scan walked every nursery inside the stop (3.4
to 8.4 ms at most per row), and in local mode the main worker's own collections. What
changed:

1. **Stops are timed from their request** (`StopRecord.pauseNs`,
   `timeToSafepointNs`); the wait before the request is a field of its
   own (`beforeRequestNs`), and every final mark has a record of its
   phases, its stopper's core and clock, and the thermal state.
2. **The main worker may open one collection while a stop is wanted**
   (`openYoungCollection`; the young-collection model updated).
3. **The young-root scan left the initial mark's stop**: the stop records
   each nursery's ranges and marks its scan owed; the marker, the
   nursery's collector, or a stop that moves young objects does it
   outside; meanwhile the SATB barrier records stores into young holders
   of an owed nursery.
4. **The final mark's tracing is bounded in work**: past
   `MarkingConfig.finalMarkWork` units, or with a scan still owed, the
   stop gives up, the world runs with marking still on, and the marker
   asks again.
5. Found on the way: **the remembered filter ran before the ephemerons**,
   so a holder marked only by a fired ephemeron was dropped from the
   remembered set and its young referents went unscanned (a test that
   fails on the starting commit); it runs after them now.

After, with young offload (the shells' default): 0 frames missed in 120
storm launches at 5 and 7 workers on the iPhone 13 Pro and the iPad Pro
but two single frames on the iPhone at 7 workers, neither behind a
stop; every stop of the cycle under 1.1 ms in every launch of the final
code; the main
thread's stopped time no worse than the large-bytes follow-up's final
block; the stop-the-world control and the Mac as they were. Young local
still misses frames on the iPhone at 7 workers behind the main worker's
own collections.

## What it hides

How long the world stands still at the start and at the end of a marking
cycle, and what each pause waits for. Smalltalk code and the shells see a
frame budget that holds; nothing above the collector learns what the
initial mark records, what the final mark drains, in what order, which
thread scans a nursery's young roots, or when a final mark gives up and
asks again.

## Found first: the record

### The record (0cb7190, 30542ca)

Every stop's record (`StopRecord`) now splits what module 3 called its
time to safepoint: `beforeRequestNs`, the stopper's wait before it sets
the flag (parked for another stop, and module 7's
`waitForCollectionsLocked`: every open young collection must end, and no
collection opens meanwhile, while the world runs), with the collections
open when the wait began; then the request to the last park, the last
parker and how it came (`ParkVia`: a poll, a wait inside the VM it had to
be woken from, another stopper) and how many came from a wait. Every
final mark's `CycleRecord` adds its work to the phase change
(`finalWorkNs`), the parts after the verifier that module 5 did not time
(module 6's selection and pins, `relocationAtFinalNs`; the sweep's setup,
`sweepSetupNs`), the stopper's QoS before the stop raised it, its CPU by
core type and its clock from just before the request to the end of the
work (`CoreTime`, the private `proc_pidinfo` flavor 34 that
experiments/power read on iOS, declared by `@_silgen_name` as the shells'
telemetry does: the iOS SDK has no libproc header), and
`ProcessInfo.thermalState` (`FinalMarkContext`, read by the marker
outside the stop; Foundation and the syscall stay out of every path `just
arc-check` covers). The run line carries one entry per final mark the log
kept (`gc_finalLog`: wait before the request / time to safepoint / work /
relocation selection / sweep setup in ms, collections open, last parker
and how, parkers from waits, stopper QoS, P share, GHz, thermal), and the
shells' line the main thread's longest turn split into its park, its
enter and leave waits and its young-collection time, its longest park
and wait in any turn, and its longest wait to open a collection
(`main_stop_wait_max_ms`).

### The devices, before (30542ca, 2026-11-07 06:13 to 06:42)

The instrumented build without any change of behaviour, both devices
interleaved, ten rounds of storm at 5 and at 7 workers under young
offload, young local and the stop-the-world scavenge (the control), idle
between, 1000 events per second in odd rounds, the first row again at
the end (`dev/before/`, `dev/block.sh`). Both devices started cooled
(nominal; the iPad nominal to fair, the iPhone reached serious from the
sixth round). Every launch's QoS lines: workers user-initiated, main
user-interactive, marker utility, young collector user-initiated, as
before. The final mark's stop here is the request to the release (time to
safepoint and work, from the per-final-mark entries):

| device, row | launches | thermal | frames missed (launches) | final mark stop p50 / p99 / max ms | wait before its request p50 / max ms | initial mark stop max ms | main stopped by others ms/10 s p50 [range] | cycles | stopper P share, GHz |
|---|--:|---|--:|--:|--:|--:|--:|--:|--:|
| iPad storm5-offload | 10 | nominal,fair | 1 (1) | 0.18 / 0.25 / 0.35 | 2.64 / 10.66 | 3.41 | 54.8 [39.1–57.1] | 126 | 0.76, 2.35 |
| iPad storm5-local | 10 | nominal,fair | 0 (0) | 0.19 / 0.25 / 0.26 | 2.39 / 13.18 | 4.40 | 57.7 [37.4–71.1] | 114 | 0.75, 2.31 |
| iPad storm5-stw | 10 | nominal,fair | 132 (1) | 0.21 / 0.26 / 0.30 | 0.01 / 0.02 | - | 513.9 [450.8–632.8] | 133 | 0.80, 2.14 |
| iPad storm7-offload | 10 | nominal,fair | 0 (0) | 0.23 / 0.33 / 0.34 | 5.16 / 23.17 | 7.53 | 71.2 [48.8–97.3] | 105 | 0.74, 2.14 |
| iPad storm7-local | 10 | nominal,fair | 4 (1) | 0.25 / 0.35 / 0.36 | 4.61 / 19.78 | 7.24 | 69.0 [48.2–95.5] | 98 | 0.76, 1.97 |
| iPad storm7-stw | 10 | nominal,fair | 50 (3) | 0.28 / 0.40 / 0.41 | 0.01 / 0.95 | - | 629.2 [492.8–779.2] | 143 | 0.79, 1.70 |
| iPad idle5 | 10 | nominal,fair | 0 (0) | - | - | - | 0.0 [0.0–0.0] | 0 | - |
| iPad last | 1 | fair | 0 (0) | 0.17 / 0.20 / 0.20 | 2.37 / 5.59 | 3.37 | 47.5 [47.5–47.5] | 12 | 0.69, 2.30 |
| iPhone storm5-offload | 10 | nominal,serious | 0 (0) | 0.17 / 0.24 / 0.25 | 1.92 / 9.64 | 3.71 | 35.7 [30.3–41.8] | 160 | 0.70, 2.40 |
| iPhone storm5-local | 10 | nominal,fair,serious | 0 (0) | 0.18 / 0.27 / 0.27 | 1.86 / 8.52 | 3.68 | 41.4 [30.9–51.8] | 137 | 0.70, 2.21 |
| iPhone storm5-stw | 10 | nominal,fair,serious | 5 (3) | 0.17 / 0.23 / 0.23 | 0.00 / 0.02 | - | 433.7 [344.4–490.5] | 132 | 0.74, 2.02 |
| iPhone storm7-offload | 10 | nominal,fair,serious | 4 (3) | 0.24 / 0.44 / 0.47 | 7.27 / 20.31 | 7.69 | 45.8 [35.9–78.0] | 113 | 0.63, 2.02 |
| iPhone storm7-local | 10 | nominal,fair,serious | 4 (2) | 0.26 / 0.44 / 0.45 | 8.36 / 21.83 | 8.37 | 51.4 [39.5–86.1] | 108 | 0.62, 1.81 |
| iPhone storm7-stw | 10 | nominal,fair,serious | 561 (10) | 0.26 / 0.50 / 0.51 | 0.00 / 6.74 | - | 718.7 [514.6–1057.1] | 133 | 0.71, 1.59 |
| iPhone idle5 | 10 | nominal,fair,serious | 0 (0) | - | - | - | 0.0 [0.0–0.0] | 0 | - |
| iPhone last | 1 | serious | 0 (0) | 0.19 / 0.21 / 0.21 | 3.79 / 6.70 | 3.37 | 44.6 [44.6–44.6] | 14 | 0.66, 2.02 |

- **The final mark's stop is 0.16 to 0.51 ms in every row**, the same
  under the stop-the-world scavenge as with young collection on, with a
  time to safepoint of at most 0.32 ms and work of 0.08 to 0.40 ms (module
  6's selection the largest part, up to 0.34 ms). The stopper was raised
  for its stop (marker QoS 17 or 25 before, `stopperQoSRaises`) and ran 62
  to 80 percent of its CPU on performance cores at 1.6 to 2.4 GHz.
- **The 7 to 20 ms were the wait before the request**: 1.9 to 8.4 ms p50
  and up to 23 ms with young collection on, 0.00 to 0.01 ms p50 under the
  oracle, growing with workers (5 against 7) and with the collections open
  when it began (up to 5). Nothing stops during it, and module 9a's and
  the large-bytes rows read it as the final mark because module 3's stop
  record counted from the start of that wait.
- **What cost frames with young collection on** (the 7 launches of 80
  that missed, every one read from its row's columns, none a fallback):
  - **The initial mark's stop** (module 7's initial-mark pause, its
    young-root scan walking every nursery in the stop): 3.4 to 8.4 ms at
    most per row, 7.2 to 8.4 at 7 workers. Two iPhone launches at 7
    workers and serious missed 1 and 2 frames with the main thread parked
    5.5 ms in a tick turn and waiting 7.1 ms to enter the VM.
  - **The wait before a request, through the main worker**: an iPad
    launch at 5 workers (offload) missed a frame behind a 14.0 ms flip,
    the main worker's opener waiting while a stop was wanted
    (`main_stop_wait_max_ms`), the stopper itself waiting for the
    background workers' collections.
  - **The main worker's own collections in local mode**: three launches
    at 7 workers (one iPad, two iPhone at serious) missed 2 to 4 frames
    behind main-thread collections of 15.7 to 18.3 ms (`main_own_max_ms`),
    whose rounds waited for the background workers' acknowledgements (the
    longest acknowledgement of any participant up to 32 ms in these rows). This is module 7's local mode for the main
    worker, which the shells do not use by default (offload hands the main
    worker's collections to the collector thread for this reason); not
    the final mark's.
  - One iPhone launch at 7 workers (offload, serious) missed a frame
    behind an 8.1 ms acknowledgement on the main thread; not explained.
- **The young-root scan is the brief's candidate in the wrong pause**:
  module 7 moved it from module 5's survivor scan at the initial mark,
  not to the final mark. The final mark drains next to nothing under the
  storm (the drain p50 0.001 to 0.003 ms; the storm's stores record no
  SATB entry, `gc_satbPushed` 0), its time to safepoint is small, and the marker's raise for the stop takes effect.
  The thermal state changed the wait before the request and the initial
  mark (both longer at serious), not the final mark's stop.
- The stop-the-world control missed frames as module 9a's did (its
  scavenges are stops of 5 to 39 ms at most per row on the iPhone).

## What changed

### 1. Stops timed from their request

`stopWorld` takes the time when it sets the flag (`tr`): the record's
`timeToSafepointNs` is the request to the last park, `pauseNs` the request
to the release, `atNs` the request, `beforeRequestNs` the wait before it
(counted VM-wide as `stopRequestWaitNs`; the `stopNs` and
`timeToSafepointNs` counters count from the request too). The stopper's
own `stopNs` still includes its wait (it is that thread's time). Every
reader of a stop's pause (module 4's and 5's reports, the `gc` events,
the shells' pause list, the tests that bound a stop) now reads what the
world stood still for. Module 5's `final` keys (`finalP50ms`,
`finalMaxMs`, `finalTtspP50ms`) mean the stop since this follow-up; the
wait is `finalBeforeRequestP50ms` and `finalBeforeRequestMaxMs`.

### 2. The main worker and a wanted stop

`openYoungCollection` makes every opener wait while a stop is wanted
(`stwWanted`: a stopper waiting for the open collections) or requested,
so that no stop starves. The main worker now waits only for a requested
stop, and opens at most one collection while one is wanted
(`SafepointState.mainOpenedWhileWanted`, cleared when the stop is
requested; counted per worker, `opensWhileWanted`, on the shells' line as
`main_opens_while_wanted`). The stopper waits for that collection too: in
offload the collector thread runs it (1.6 to 8 ms p50 on the devices,
with the world running), in local the main worker. A stop is delayed by
one collection at most per request, never interleaved with one.

This is a change to module 7's protocol, and the young-collection model
changed with it (`mainOpensWhileWanted`, worker 0 as the main worker, on
by default; `docs/models/young-collection.md`, Results): the ownership
configurations, the ones with an old-space collector, hold with it and
without it, in 214 and 171 thousand states against 172 and 129. The
model's O stops only when `ycActive` is 0, so the change is one of
liveness: a collection the main worker opens is one more O waits for.

### 3. The young-root scan out of the initial mark's stop

Module 7's initial-mark pause greyed every slot of every young body in
every nursery (`youngRootScan`), because a young object alive at the
snapshot is a root of it and the SATB barrier skips young holders. Now
(`RootScans.swift`):

- **The stop records** each nursery's eden (or current half) from its
  start to its top and its survivor-from (`rootScanRanges`, four words a
  nursery) and marks the scan **owed** where either is not empty
  (`rootScans`, one atomic byte a nursery: none, owed, claimed). Its cost
  is O(nurseries).
- **Whoever comes first claims and walks it** (owed to claimed by
  compare-and-swap; claimed to none, released, at the end; the walk is
  module 7's, by back references, every slot of a body whose entry leads
  to it, bytes and deferred frees skipped, ranges below the recorded
  tops only):
  - **the marker**, at the start of its cycle, nursery 0 (the main
    worker's) first, greying onto its own stack and polling every 256
    bodies (`markerScansYoungRoots`). A stop that finishes its claim under
    it, or ends the cycle, makes it drop the walk at its next poll.
  - **the nursery's collector**, at the start of a collection and before
    anything of the nursery moves (`collectorFinishesRootScan`, called
    first thing in `collectYoung`). It is not the marker participant and
    never sets a mark: its candidates (unmarked snapshot entries) go to
    the marker's queue in 512-word SATB items, as a worker's barrier
    records do, and it services other collections' rounds every 256
    bodies (no stop can be requested while a collection is open, so the
    walk never parks). If the marker holds the claim, the collection
    waits for it in `waitServicing` (the marker broadcasts under the
    safepoint mutex; counted, `rootScanWaits`).
  - **a stop that moves young objects**: module 4's scavenge
    (`finishRootScansInStop` first thing in `scavenge`), which also serves
    module 1's promote-all and module 7's reserve fallback; and a final
    mark that may not give up any more (below). Counted
    (`rootScansInStop`).
- **Until a nursery's scan is done, the SATB barrier records stores into
  its young holders** (`satbRecord` and the array copy's per-slot record
  in `copySlots`: a young holder is skipped only when
  `youngHolderScanOwed` says its nursery's scan is none). The load of the
  state is an acquire: reading none orders the store after the walk's
  read of the slot (the walk's end is a release store), so a slot the
  walk has not read, or reads after the store, loses no snapshot edge.
  These are the two paths that skip young holders; every other store
  into a slot goes through `storeWithBarriers`.
- **Nothing of an owed nursery moves**: only its own collection and
  module 4's scavenge move young objects, and both finish the scan
  first. Its eden is reused only by its own collection (after its epoch
  wait), so the walk never reads reused memory. Entries the walk reads
  (`stateWord(o) == a`) are freed only by that collection too.
- **The marker asks for the final mark only with every scan done**: it
  scans what is owed, notes whether any scan is pending, marks, and if a
  collector held one it waits for the release (`markerWaitsForRootScans`,
  inside the VM in `waitServicing`, parking for stops) and marks again
  (the collector queues its candidates before it releases the claim, so
  a queue read after the release sees them).
- `vm.markStep` and `markStepDone`, the manual marker of the tests, scan
  first as the marker thread does. An abort clears every scan.

No model covers the scans: the young-collection model takes module 5's
marking as its result ("the snapshot entries reachable at the pause are
marked", `docs/models/young-collection.md`), not its work, and the
relocation and save-hold models have no young objects. The argument
above is the soundness case; the tests below each break one rule and
find the loss with module 5's verifier.

### 4. The final mark's tracing bounded in work

`runFinalMark` counts units of tracing (`MarkingConfig.finalMarkWork`,
16 384 by default: an SATB entry taken, an object traced, a large
object's chunk as `MarkChunk.weight`) and **gives up** when the drain,
or the ephemerons' traced-key loop, reaches the bound with work left, or
when a young-root scan is still owed: nothing has been decided then (no
ephemeron fired, no weak slot nil'ed, no remembered holder filtered), the
marking bit is still on (it is cleared only past the commit point now),
what the stop took stays on the marker's stack, and the world is
released with the cycle marking. The marker drains concurrently and asks
again (its loop comes back to `markCycle`). The bound is a property of
the stop: one attempt traces at most the bound plus one step's overshoot
(every worker's partial SATB buffer is taken whole, then at most one
queue item of 512 entries or one traced object). After
`finalMarkGiveUps` (8) give-ups in one cycle the final mark finishes past
the bound, counted (`finalOverruns`), so that marking ends whatever the
mutators do. Firing the remaining ephemerons is past the commit point
and not bounded; its tracing is counted in the units. Counted: give-ups
per cycle and over the run (`finalGiveUps`), the largest attempt
(`finalUnitsMax`).

The bound guards the stop; under the storm on the devices the final mark
never reached it (below). The work past it is done before the stop, as
the brief proposed, by the marker's concurrent drain; nothing is done
after it that the lazy sweep did not already do.

### 5. The remembered filter after the ephemerons

Module 5's final mark filtered dead holders out of the remembered sets
(an unmarked snapshot entry is about to be freed) and then resolved the
ephemerons, whose tracing marks objects: a holder reachable only through
a fired ephemeron's value was dropped from its remembered set, survived
the sweep, and the next scavenge did not scan it, so its young referent
was not found (the scavenge verifier's failure;
`aHolderMarkedByAFiredEphemeronStaysRemembered` fails so on the starting
commit, 4a94f07: the session's `finalmark/filter-order-on-start.txt`). The filter runs
after the ephemerons now, with the marks final. Found by reading the
final mark's order while bounding it; no device or random program had
shown it.

## After

### The devices (ce64e6d, 2026-11-07 06:51 to 07:36)

The final code, both devices interleaved, twenty rounds of storm at 5 and
at 7 workers under young offload and young local, the stop-the-world
control in every fourth round, idle between, 1000 events per second in
odd rounds, the first row again at the end (`dev/after/`, `dev/after.sh`),
started nine minutes after the first block (the devices idle meanwhile).
The iPad at nominal and fair throughout, the iPhone from nominal to
serious from the eighth round on; the A/B ran on the Mac for four
minutes of it. Every launch's QoS as before. 0 failed launches, 0
fallbacks in 222.

| device, row | launches | thermal | frames missed (launches) | final mark stop p50 / p99 / max ms | wait before its request p50 / max ms | initial mark stop max ms | main stopped by others ms/10 s p50 [range] | cycles | stopper P share, GHz |
|---|--:|---|--:|--:|--:|--:|--:|--:|--:|
| iPad storm5-offload | 20 | nominal,fair | 0 (0) | 0.18 / 0.25 / 0.27 | 2.24 / 12.88 | 0.75 | 49.1 [44.2–54.4] | 242 | 0.71, 2.14 |
| iPad storm5-local | 20 | nominal,fair | 0 (0) | 0.19 / 0.26 / 0.28 | 2.85 / 13.03 | 0.79 | 50.0 [46.5–55.3] | 234 | 0.71, 2.14 |
| iPad storm5-stw | 5 | fair | 0 (0) | 0.23 / 0.31 / 0.31 | 0.01 / 0.12 | - | 525.0 [476.5–635.5] | 65 | 0.80, 2.14 |
| iPad storm7-offload | 20 | nominal,fair | 0 (0) | 0.24 / 0.34 / 0.34 | 5.50 / 23.60 | 0.95 | 64.8 [45.2–79.0] | 222 | 0.73, 2.07 |
| iPad storm7-local | 20 | nominal,fair | 0 (0) | 0.25 / 0.38 / 0.40 | 4.47 / 25.84 | 0.75 | 66.8 [55.5–79.2] | 209 | 0.72, 1.70 |
| iPad storm7-stw | 5 | fair | 0 (0) | 0.32 / 0.46 / 0.46 | 0.01 / 0.13 | - | 562.7 [491.8–619.5] | 65 | 0.79, 1.18 |
| iPad idle5 | 20 | nominal,fair | 0 (0) | - | - | - | 0.0 [0.0–0.0] | 0 | - |
| iPad last | 1 | fair | 0 (0) | 0.18 / 0.21 / 0.21 | 2.89 / 4.28 | 0.45 | 51.5 [51.5–51.5] | 11 | 0.73, 2.14 |
| iPhone storm5-offload | 20 | nominal,fair,serious | 0 (0) | 0.19 / 0.35 / 0.37 | 2.50 / 16.32 | 0.65 | 40.0 [27.9–55.2] | 280 | 0.68, 2.02 |
| iPhone storm5-local | 20 | nominal,fair,serious | 0 (0) | 0.20 / 0.37 / 0.40 | 2.28 / 11.06 | 0.75 | 42.2 [28.6–62.9] | 250 | 0.70, 1.81 |
| iPhone storm5-stw | 5 | fair,serious | 0 (0) | 0.18 / 0.26 / 0.26 | 0.00 / 0.01 | - | 469.2 [447.3–512.0] | 63 | 0.77, 1.81 |
| iPhone storm7-offload | 20 | nominal,fair,serious | 0 (0) | 0.23 / 0.31 / 0.37 | 7.25 / 23.36 | 0.72 | 37.0 [33.1–46.0] | 270 | 0.61, 2.20 |
| iPhone storm7-local | 20 | fair,serious | 8 (5) | 0.27 / 0.44 / 0.49 | 8.45 / 26.44 | 0.77 | 45.9 [38.0–73.6] | 221 | 0.63, 1.60 |
| iPhone storm7-stw | 5 | serious | 209 (5) | 0.32 / 0.54 / 0.54 | 0.00 / 0.01 | - | 683.6 [644.7–860.0] | 64 | 0.72, 1.15 |
| iPhone idle5 | 20 | nominal,fair,serious | 0 (0) | - | - | - | 0.0 [0.0–0.0] | 0 | - |
| iPhone last | 1 | serious | 0 (0) | 0.18 / 0.24 / 0.24 | 2.78 / 8.11 | 0.53 | 33.9 [33.9–33.9] | 16 | 0.69, 2.02 |

- **With young offload, the shells' default: 0 frames missed in all 80
  storm launches** (20 at 5 and 20 at 7 workers on each device, cooled
  and heated). Young local: 0 on the iPad; on the iPhone at 7 workers, at
  fair and serious, 8 frames in 5 of 20 launches, every one behind the
  main worker's own local collection (`main_own_max_ms` 6.0 to 20.8 ms,
  the turn's young-collection time) but one, a 10.2 ms event turn with an
  8.0 ms enter-or-leave wait (its own collection reached 6.3 ms in that
  launch). None was a stop of the cycle: in those launches the final
  mark's stop was at most 0.48 ms and the initial mark's 0.76 ms.
- **The final mark's stop is at most 0.54 ms in every launch** (the iPhone
  under the oracle at serious), 0.49 with young collection on; p50 0.18
  to 0.27 ms. No final mark gave up (`finalGiveUps` 0 in 222 launches;
  the largest attempt 10 units of a 16 384 bound), and no young-root scan
  ran in a stop (`rootScansInStop` 0).
- **The initial mark's stop is at most 0.95 ms** (it was 3.4 to 8.4 ms at
  most per row): the snapshot copy, the roots and the ranges. The longest
  park of the main thread in any turn fell from 2.5 to 9.7 ms per row to
  0.6 to 1.0 ms on the iPad and 0.6 to 0.7 ms at 5 workers on the iPhone; at 7
  workers on the iPhone three launches parked 4.1 to 10.4 ms in one tick
  turn with neither mark's stop over 0.7 ms in them (no frame missed).
  This block's line named no other stop kind; the next block's does
  (below).
- **The young-root scans**: 13 415 by the marker and 2 254 by a
  collector in all, a nursery's scan 0.8 to 1.0 ms mean per launch (p50
  over launches) and up to 78 ms at most (the marker at utility on the
  iPhone's efficiency cores at serious, outside every stop); 623
  collections waited for the marker's scan of their nursery, up to 41 ms
  in all in one launch, background workers' eden time. The main worker
  opened a collection while a stop was wanted in 4 launches (it waited
  for none).
- **The wait before a request** is unchanged in kind: 2.2 to 8.5 ms p50,
  up to 26 ms, the world running; under the oracle 0.00 to 0.01 ms.
- **The main thread's stopped time is no worse than the large-bytes
  follow-up's final block** (offload, ms per 10 s, p50): iPhone storm 5
  40.0 [27.9–55.2] against 38.4 [30.4–50.3], storm 7 37.0 [33.1–46.0]
  against 47.5 [31.6–67.7]; iPad storm 5 49.1 [44.2–54.4] against 53.6
  [47.7–57.9], storm 7 64.8 [45.2–79.0] against 70.7 [62.4–75.1]. Against
  this follow-up's first block: iPhone 35.7 and 45.8, iPad 54.8 and 71.2.
- **The stop-the-world control is unchanged**: its scavenges are the
  stops that cost it frames, as before (the iPhone at 7 workers and
  serious 209 frames in 5 of 5 launches, the first block 561 in 10 of 10;
  its final mark the same 0.2 to 0.5 ms).
- **Cycles**: 209 to 280 per twenty launches with young collection on,
  10.5 to 14 per 10 s as in the first block (98 to 160 per ten).

### The devices on the final code (bcee36d, 2026-11-07 07:42 to 08:04)

bcee36d adds one key to the run line (`stopsByKind`: every stop kind's
count, longest stop and longest time to safepoint), to name the stop
behind the main-thread parks above; nothing else changed. Ten more
rounds of the same block (`dev/final/`), six minutes after the last, the
iPad at nominal and fair, the iPhone from fair to serious; 0 failed
launches, 0 fallbacks in 110:

| device, row | launches | thermal | frames missed (launches) | final mark stop p50 / p99 / max ms | wait before its request p50 / max ms | initial mark stop max ms | main stopped by others ms/10 s p50 [range] | cycles | stopper P share, GHz |
|---|--:|---|--:|--:|--:|--:|--:|--:|--:|
| iPad storm5-offload | 10 | nominal,fair | 0 (0) | 0.19 / 0.25 / 0.28 | 2.67 / 12.40 | 0.56 | 49.1 [40.6–51.6] | 116 | 0.70, 2.28 |
| iPad storm5-local | 10 | nominal,fair | 0 (0) | 0.19 / 0.24 / 0.32 | 2.81 / 8.80 | 0.60 | 50.0 [46.0–52.8] | 127 | 0.72, 2.14 |
| iPad storm5-stw | 2 | fair | 0 (0) | 0.23 / 0.28 / 0.28 | 0.01 / 0.01 | - | 569.4 [519.3–619.6] | 26 | 0.79, 2.14 |
| iPad storm7-offload | 10 | nominal,fair | 0 (0) | 0.23 / 0.35 / 0.35 | 4.71 / 16.44 | 0.94 | 63.8 [58.5–71.6] | 115 | 0.74, 2.14 |
| iPad storm7-local | 10 | nominal,fair | 0 (0) | 0.24 / 0.34 / 0.36 | 5.77 / 17.15 | 0.89 | 67.4 [60.7–74.0] | 111 | 0.72, 1.90 |
| iPad storm7-stw | 2 | fair | 0 (0) | 0.33 / 0.42 / 0.42 | 0.01 / 0.07 | - | 572.9 [527.2–618.6] | 27 | 0.79, 1.70 |
| iPad idle5 | 10 | nominal,fair | 0 (0) | - | - | - | 0.0 [0.0–0.0] | 0 | - |
| iPad last | 1 | fair | 0 (0) | 0.19 / 0.22 / 0.22 | 3.14 / 7.81 | 0.50 | 48.8 [48.8–48.8] | 12 | 0.75, 2.13 |
| iPhone storm5-offload | 10 | nominal,serious | 0 (0) | 0.19 / 0.34 / 0.35 | 3.07 / 11.06 | 0.58 | 36.9 [28.8–56.2] | 146 | 0.68, 2.21 |
| iPhone storm5-local | 10 | nominal,serious | 0 (0) | 0.20 / 0.36 / 0.36 | 3.20 / 11.71 | 0.70 | 39.9 [34.0–65.0] | 125 | 0.73, 2.02 |
| iPhone storm5-stw | 2 | serious | 0 (0) | 0.18 / 0.23 / 0.23 | 0.00 / 0.01 | - | 497.1 [485.1–509.1] | 25 | 0.75, 1.81 |
| iPhone storm7-offload | 10 | fair,serious | 2 (2) | 0.23 / 0.31 / 0.34 | 6.93 / 17.40 | 0.66 | 39.7 [35.0–48.2] | 129 | 0.61, 2.20 |
| iPhone storm7-local | 10 | fair,serious | 1 (1) | 0.28 / 0.45 / 0.46 | 7.74 / 22.03 | 1.05 | 48.1 [36.2–73.3] | 109 | 0.63, 1.38 |
| iPhone storm7-stw | 2 | serious | 91 (2) | 0.37 / 0.44 / 0.44 | 0.00 / 0.00 | - | 726.0 [681.0–771.0] | 26 | 0.73, 1.15 |
| iPhone idle5 | 10 | nominal,fair,serious | 0 (0) | - | - | - | 0.0 [0.0–0.0] | 0 | - |
| iPhone last | 1 | serious | 0 (0) | 0.20 / 0.26 / 0.26 | 4.79 / 11.03 | 0.37 | 38.9 [38.9–38.9] | 16 | 0.69, 2.03 |

- **Every stop of every kind is under 1.1 ms in every launch with young
  collection on** (`stopsByKind`): the final mark at most 0.50 ms, the
  initial mark 1.05, the apply 0.58, their times to safepoint at most
  0.36 ms. No final mark gave up, no scan ran in a stop.
- **Frames**: 0 missed at 5 workers on either device, 0 at 7 on the
  iPad; on the iPhone at 7 workers 1 frame in each of two offload
  launches (fair, serious) and one local launch. None of the three was a
  stop: one behind a 6.4 ms wait to enter or leave the VM inside an
  8.9 ms tick turn (every stop of that launch under 0.5 ms, so the wait
  was for the safepoint mutex, not for a stop), one with a 6.9 ms event
  turn in which the main thread neither parked nor waited, and the local
  one behind the main worker's own 6.7 ms collection.
- **Main-thread parks of 8.3 to 10.5 ms** in single tick turns, in five
  iPhone launches at 7 workers and serious, with every stop of those
  launches under 0.7 ms: not explained. The park is timed from the
  parker's count to its wake with the mutex held again, so a slow wake or
  the mutex's reacquisition among ten waking threads on six cores would
  show so, as would several stops in one turn; they cost no frame (the
  turns ended at 8.5 to 12.8 ms within the display's deadline). The first
  after-block's 5.8 and 10.4 ms parks were the same.
- Over both after-blocks, **young offload, the shells' default: 0 frames
  missed in 120 storm launches but 2 single frames on the iPhone at 7
  workers**, neither a collector stop; at 5 workers, the shells' default,
  0 in 30 on each device. The iPhone at 7 workers runs more busy threads
  than its two performance cores, as the large-bytes follow-up found;
  the default stays 5.

### Energy

No QoS changed. The young-root scans moved from the initial mark's stop
(on whichever worker stopped, at user-initiated) onto the marker (at
utility) and the collectors. The process's CPU power and the marker's
energy per launch, p50, first block against this one (`ri_energy_nj` and
`proc_pidinfo` flavor 34; neither counts DRAM, the display or the render
server; the thermal mix differs between the blocks, the iPhone's second
running longer at serious):

| device, row | power W before / after | marker mJ per 10 s | marker CPU ms | marker P share |
|---|--:|--:|--:|--:|
| iPhone storm5-offload | 4.13 / 2.42 | 306 / 235 | 853 / 758 | 0.04 / 0.04 |
| iPhone storm5-local | 3.48 / 2.51 | 230 / 206 | 721 / 682 | 0.02 / 0.01 |
| iPhone storm7-offload | 3.39 / 3.63 | 213 / 364 | 606 / 787 | 0.13 / 0.17 |
| iPhone storm7-local | 2.55 / 2.25 | 255 / 232 | 615 / 691 | 0.16 / 0.14 |
| iPad storm5-offload | 1.36 / 1.35 | 270 / 255 | 1080 / 1111 | 0.11 / 0.11 |
| iPad storm5-local | 1.32 / 1.31 | 222 / 259 | 1021 / 1097 | 0.09 / 0.10 |
| iPad storm7-offload | 1.38 / 1.64 | 258 / 286 | 895 / 1025 | 0.19 / 0.16 |
| iPad storm7-local | 1.34 / 1.55 | 232 / 268 | 923 / 1028 | 0.15 / 0.15 |

The marker does 11 percent less to 30 percent more CPU per 10 s (the
scans, against fewer launches at full clock), at a
fraction of a joule; the process's power moves with the thermal state
more than with the change (the iPhone's storm 5 rows 4.1 against 2.4 W
with more launches at serious in the second block, where the clock is
lower).

### The Mac

The final code's macOS shell on the Mac mini's display (M2 Pro, 120 Hz),
storm at 7 workers under each mode, three launches each interleaved,
2026-11-07 08:05 to 08:07 (`finalmark/mac/mac.txt`):

| device, row | launches | thermal | frames missed (launches) | final mark stop p50 / p99 / max ms | wait before its request p50 / max ms | initial mark stop max ms | main stopped by others ms/10 s p50 [range] | cycles | stopper P share, GHz |
|---|--:|---|--:|--:|--:|--:|--:|--:|--:|
| Mac storm7-offload | 3 | nominal | 0 (0) | 0.15 / 0.20 / 0.20 | 0.23 / 2.06 | 0.30 | 76.8 [75.7–79.0] | 121 | 1.00, 3.08 |
| Mac storm7-local | 3 | nominal | 0 (0) | 0.15 / 0.22 / 0.23 | 0.37 / 2.14 | 0.33 | 75.0 [73.4–76.3] | 141 | 1.00, 3.07 |
| Mac storm7-stw | 3 | nominal | 0 (0) | 0.17 / 0.23 / 0.23 | 0.00 / 0.02 | - | 356.4 [323.3–387.9] | 105 | 1.00, 3.11 |
| Mac idle7 | 1 | nominal | 0 (0) | - | - | - | 0.0 [0.0–0.0] | 0 | - |

0 frames missed in every launch; the main thread stopped by others 75 to
79 ms per 10 s with young collection on (the large-bytes follow-up's Mac
rows 83 to 101, module 9a's 89 to 99) and 323 to 388 under the oracle
(9a: 293 to 338); the final mark's stop p50 0.15 to 0.17 ms (module 5's
0.11 to 0.14 at 8 workers on the M2 Max, headless), every stop of the
cycle under 0.34 ms. The wait before the request is 0.2 to 0.4 ms p50 on
the Mac. A first set on ce64e6d (`mac-ce64e6d.txt`) missed 9 frames in
one oracle launch behind a 24.8 ms scavenge while a Swift build ran on
the Mac; it was run again on the final code without the build.

### The kernels against the starting commit

The starting commit's `kajo` (4a94f07, from a worktree) against this
follow-up's (ce64e6d, the last commit that changes the VM's code), both
`-c release -Xswiftc -enable-testing` with `-align-all-nofallthru-blocks=5
-align-loops=32`; five runs interleaved, `--slice-ms 0`, 2026-11-07 06:53
to 06:57 (load average 3.5 to 8.0, the devices' after-block running);
median (min to max) ms, every checksum equal on both sides and the
published one (`finalmark/ab/bench-ab.txt`).

| kernel | workers | start ms | final mark ms | ratio | checksum |
|---|--:|--:|--:|--:|---|
| alloc | 1 | 2958.8 (2948 to 2965) | 2958.3 (2942 to 2966) | **1.000** | 41950911 |
| alloc | 8 | 477.6 (465 to 492) | 498.1 (463 to 499) | **1.043** | 42008248 |
| arith | 1 | 2551.7 (2546 to 2561) | 2543.3 (2538 to 2548) | **0.997** | 372800000 |
| arith | 8 | 346.7 (338 to 353) | 338.3 (337 to 356) | **0.976** | 372800000 |
| fib | 1 | 1692.2 (1689 to 1700) | 1701.2 (1690 to 1705) | **1.005** | 24682992 |
| fib | 8 | 224.8 (217 to 239) | 233.8 (219 to 241) | **1.040** | 24682992 |
| ivars | 1 | 1969.4 (1968 to 1977) | 1974.5 (1967 to 1976) | **1.003** | 36383626 |
| ivars | 8 | 265.5 (252 to 274) | 254.8 (252 to 276) | **0.960** | 71714128 |
| sends | 1 | 2613.7 (2606 to 2621) | 2611.6 (2607 to 2622) | **0.999** | 1066666666666668 |
| sends | 8 | 351.8 (336 to 368) | 350.1 (342 to 363) | **0.995** | 133333335000001 |
| storeheavy | 1 | 2405.1 (2402 to 2410) | 2408.3 (2406 to 2417) | **1.001** | 512000 |
| storeheavy | 8 | 314.3 (307 to 326) | 329.1 (309 to 332) | **1.047** | 512000 |
| Smalltalk closures | 1 | 3828.2 (3813 to 3848) | 3804.7 (3799 to 3817) | **0.994** | 210210000 |
| Smalltalk closures | 8 | 497.2 (486 to 516) | 511.6 (489 to 535) | **1.029** | 209214000 |
| Smalltalk ivars | 1 | 1970.0 (1968 to 1978) | 1969.1 (1966 to 1972) | **1.000** | 36383626 |
| Smalltalk ivars | 8 | 257.3 (252 to 280) | 262.2 (252 to 272) | **1.019** | 71714128 |
| Smalltalk sends | 1 | 2346.7 (2336 to 2354) | 2318.2 (2311 to 2335) | **0.988** | 1066666666666668 |
| Smalltalk sends | 8 | 309.6 (295 to 320) | 301.8 (297 to 323) | **0.975** | 133333335000001 |

Within noise: 0.988 to 1.005 on one worker; 0.960 to 1.047 on eight, every
range overlapping its pair's (alloc 465 to 492 against 463 to 499,
storeheavy 307 to 326 against 309 to 332). The kernels run no marking
cycle, and nothing this follow-up changed is on their paths but the
stop's record (two more clock reads per stop) and `park`'s argument.

## Changes to earlier modules

- **Module 3**: `StopRecord` and `StopContext` count from the request and
  carry the wait before it, the collections open, the last parker's
  `ParkVia` and the parkers from waits; `parkLocked(_:_:via:)`;
  `Counter.stopRequestWaitNs`.
- **Module 4**: `scavenge` finishes any owed young-root scan first.
- **Module 5**: `runFinalMark` bounded (`finalMarkWork`,
  `finalMarkGiveUps`, `finalGiveUps`, `finalOverruns`), the marking bit
  cleared after the bounded part, the remembered filter after the
  ephemerons; `markCycle` scans the young roots, waits for collectors'
  scans and marks again; `drainStack(_:_:_:units:bound:)` and
  `queueHasItems`; the SATB record of a young holder whose nursery's
  scan is owed; `CycleRecord`'s final-mark fields, `FinalMarkContext`,
  `CoreTime`; `MarkingShared.rootScans`, `rootScanRanges`,
  `rootScanStats`; the test switches `unboundedFinalMark`,
  `youngRootsInStop`, `noOwedScanBarrier`, `collectBeforeRootScan`,
  `markerSkipsRootScans`; the report's `finalBeforeRequest*`, `finalTtspMaxMs`,
  `finalWork*`, `finalReloc*`, `finalSweepSetupMaxMs`,
  `finalCollectionsOpenMax`, `initial*`, `finalLog`, `finalGiveUps`,
  `finalOverruns`, `finalUnitsMax` and `rootScan*` keys.
- **Module 6**: the array copy's SATB record of a young holder whose
  nursery's scan is owed (`copySlots`).
- **Module 7**: `initialMark`'s young branch records instead of scanning
  (`youngRootScan` stays for `youngRootsInStop`); `collectYoung` finishes
  its nursery's owed scan first; `openYoungCollection` lets the main
  worker open one collection while a stop is wanted
  (`mainOpenedWhileWanted`, `opensWhileWanted`, the test switch
  `mainWaitsForWantedStops`); `waitServicing` parks `via: .wait`;
  `stopWaitMaxNs`, `drainWaitMaxNs`; `VM.collectionsOpen` for tests.
- **Module 9a's shells**: the run line's `max_turn_park_ms`,
  `max_turn_wait_ms`, `max_turn_young_ms`, `max_park_ms`,
  `max_enter_leave_wait_ms`, `main_stop_wait_ms_per10s`,
  `main_stop_wait_max_ms`, `main_drain_wait_ms_per10s`,
  `main_opens_while_wanted`; `MainThreadCounters.stopWaitMaxNs`,
  `opensWhileWanted`.
- **The young-collection model**: `mainOpensWhileWanted`.
- **`just arc-check`**: `drainStack`'s new signature and the three scans.

## Deviations from the brief

- **The phase that grew is not in the final mark's stop.** The brief's
  7 to 20 ms were the stopper's wait for open young collections before
  its request; the stop is 0.16 to 0.54 ms. The record says so, the stops
  are timed from the request since, and module 5's `final` keys changed
  meaning with them (older rows' figures include the wait).
- **The young-root scan was in the initial mark, not the final mark**,
  and it was the stop that cost frames (3.4 to 8.4 ms at most per row); it moved out of
  that stop. The brief's "pre-scan of young roots with the barrier
  catching the rest" is what was built, after the snapshot rather than
  before it.
- **The bound is a give-up, not a stop that always finishes**: work past
  the bound is done concurrently before the next request, and after eight
  give-ups in a cycle the final mark finishes regardless (counted), so
  that marking ends. Firing ephemerons is not bounded.
- **The brief's 20 launches per row ran on ce64e6d**; the final code
  (bcee36d, one more run-line key) ran 10 per row after it. Over both,
  with young offload, 0 frames missed at 5 workers on either device and
  at 7 on the iPad; on the iPhone at 7 workers two single frames in 30
  launches, neither behind a stop of any kind (above). What bounds the
  iPhone at 7 workers there is the CPU (seven busy workers, the main
  thread and the collector threads on two performance and four
  efficiency cores), not the final mark; the shells' default stays 5.
- **Local mode's main-worker collections are not addressed**: they are
  module 7's design for that mode (the shells use offload), and their
  length is the background workers' acknowledgements, not marking.
- **No QoS changed**, so no energy comparison was required; the marker's
  energy is reported anyway, since the young-root scans moved onto it.
- **The filter's order** was not in the brief; it was found while
  bounding the final mark and is fixed with a test that fails on the
  starting commit.

## Tests

Swift: `KajoVMTests` and `KajoCompilerTests` (counts in Gates). New in
`Tests/KajoVMTests/Marking/FinalMarkTests.swift`:

- `theFinalMarksRecordSplitsItsTimeToSafepoint`: a final mark requested
  while a collection is open waits for it before the request; the record
  names the collection, the wait, the stop from the request and the
  work's parts.
- `theFinalMarksStopIsBoundedInWork` and
  `withoutTheBoundTheFinalMarkTracesEverythingInItsStop`
  (`unboundedFinalMark`): ten 2000-Pair lists and a cycle with nothing
  marked concurrently; with a bound of 256 the first final mark gives up,
  the concurrent step marks, the second finishes, no attempt does more
  than the bound and one step's overshoot, and the verifier finds
  nothing missed; without the bound one stop traces over 20 000 units.
- `theInitialMarkLeavesTheYoungRootsOwed`: the pause scans nothing, the
  marker's step does the scan, the cycle completes clean.
- `aStoreIntoAYoungHolderWhoseScanIsOwedIsRecorded` and
  `withoutTheOwedScanBarrierTheValueIsLost` (`noOwedScanBarrier`): O moves
  from a young Y into an already traced H before Y's nursery is scanned;
  without the barrier the verifier reports O.
- `aCollectionScansItsOwedNurseryBeforeItMovesIt` and
  `withoutTheScanBeforeTheCollectionTheValueIsLost`
  (`collectBeforeRootScan`): Y dies and its nursery collects before the
  scan; without the rule O is lost.
- `theMarkerScansTheOwedNurseriesBeforeItAsks` and
  `withoutTheScansBeforeTheStopTheFinalMarkGivesUpThenOverruns`
  (`markerSkipsRootScans`): without the work before the stop every final
  mark gives up (8) and the ninth does the scans in its stop, an overrun.
- `theMainWorkerOpensOneCollectionWhileAStopIsWanted`: during worker 1's
  collection a stop is wanted and the main worker opens its own.
- `aHolderMarkedByAFiredEphemeronStaysRemembered`: fails on 4a94f07.

The random programs (21 configurations, the young modes and
`markingAlwaysOn` among them) run the deferred scans, the give-ups and
the main worker's opens under the threaded marker with every verifier on.

## Broken variants run by hand

- `mainWaitsForWantedStops` in `theMainWorkerOpensOneCollectionWhileAStopIsWanted`
  (the wait shortened to 3 s for the run): the second collection never
  opened inside the hook, `opensWhileWanted` 0
  (`finalmark/broken-mainwaits.txt`). Not in the suite: its failure is a
  timeout, a wall-clock assertion.
- Every other rule's broken variant is a test switch in the suite (above).
- `aHolderMarkedByAFiredEphemeronStaysRemembered` on the starting commit:
  the holder is not remembered after the final mark and the scavenge
  verifier fails (`finalmark/filter-order-on-start.txt`).

## Unsafe surface

157 new lines with `unsafe` (186 added, 29 removed, comments excluded),
all in `Sources/KajoVM`: `Marking/RootScans.swift` 86 (the scan states'
atomics, the ranges, the walk over bodies through offsets, the candidate
buffer under the marking lock), `Marking/FinalMark.swift` 11 net,
`Marking/MarkingHost.swift` 14 (the new sub-states' allocation and the
accessors), `Workers/Safepoint.swift` 9, `Marking/Marker.swift` 8,
`YoungCollection/Collect.swift` 7, `Headless.swift` 6,
`Marking/FinalMarkRecord.swift` 4 (`proc_pidinfo` into a local tuple),
`InitialMark.swift` 3, `Rounds.swift` 3, `YoungHost.swift` 3, `SATB.swift`,
`Sweep.swift` and `Scavenge.swift` 1 each. Nothing in `KajoDev` or the
shells. The clean build of the gates reports no strict memory-safety
warning.

## Hot-path check

The disassembly of the A/B's two aligned builds, normalized for
addresses (`finalmark/ab/disasm/`):

| function | start | final mark | difference |
|---|--:|--:|---|
| `interpret` | 1320 instructions | 1320 | four `adrp` page numbers (the code after it grew), nothing else |
| `v1Instruction` | 319 | 319 | one `adrp` page number |
| `specialSend` | 764 | 764 | none |
| `pollSlow` | 430 | 430 | one `adrp` page number |
| `park` | 67 | 67 | `parkLocked`'s new argument (`mov w2`), one alignment `nop` fewer |
| `storeWithBarriers` | 192 | 216 | on the SATB record's young-holder branch only: the test switch's byte, the holder's nursery from its header, a bounds compare, the `ldaprb` of the scan state and a branch (and alignment) |
| `copySlots` | 300 | 316 | the same check in the per-slot SATB record (taken only while marking, for a young holder), the holder's nursery index computed once before the loop and kept in a stack slot, registers renamed around it |

The store fast path in `interpret` is untouched; the new instructions
are on the slow path a store takes only while a cycle marks, and on its
young-holder branch only.

## Not done

- **Local mode's main-worker collections** (7 to 18 ms on the devices
  under the storm at 7 workers, behind the background workers'
  acknowledgements): module 7's design for that mode, the shells' default
  is offload. Not changed.
- **The 8.1 ms acknowledgement on the iPhone's main thread** (one launch
  at serious before the change), **the 6.4 ms wait to enter or leave the
  VM and the 6.9 ms event turn** behind the final block's two missed
  frames, and **the main-thread parks of 8.3 to 10.5 ms with every stop
  under 0.7 ms** (iPhone, 7 workers, serious): not explained. The parks
  cost no frame. A wake-to-mutex timing in `parkLocked` would separate
  the stop from the wake.
- **The ephemerons' firing is not bounded** (past the commit point); its
  tracing is counted in the units. The remembered filter, the weak slots,
  module 6's selection and the sweep's setup are in the stop and
  proportional to the remembered lists, the weak holders the marker met
  and the heap's blocks (up to 0.34 ms together on the devices); measured,
  not bounded.
- **The wait before a request** is unchanged apart from the main worker:
  a stopper still waits for every open collection, background workers'
  openers wait with it, and the wait is 2 to 23 ms on the devices. It
  costs the background workers time (their eden waits), not the main
  thread frames.
- **The young-root scans run on the marker at utility**, mostly on
  efficiency cores (one nursery's walk up to the figures in Measurements);
  a collector that finds the marker holding its nursery's scan waits for
  it. Parallel scans (one per nursery on its owner) were not built.
- **No model covers the deferred young-root scans or the bounded final
  mark** (module 5's marking is a result in every model); the tests above
  and the random programs are the evidence.

## Open questions for the owner

1. **The bound's value**: 16 384 units, about a millisecond on the
   iPhone's efficiency cores, never reached under the storm. Keep it, or
   tie it to a time budget measured at the stop?
2. **Eight give-ups, then an overrun**: the right escape, or should the
   ninth attempt raise the marker to user-initiated and keep giving up?
3. **Local mode for the main worker**: its own collections cost frames at
   7 workers on both devices. Should `young=local` make the main worker
   offload anyway (local for background workers only, as ADR 0008's
   decision reads), so that no mode lets the main thread collect?
4. **One collection for the main worker per wanted stop**: enough, or
   should the main worker never wait for a wanted stop (it may then delay
   a stop by more than one collection)?

## Gates

Every gate ran on bcee36d (the last commit that changes code; the commit
after it is this doc and the other docs' corrections), Mac mini (M2 Pro),
swift.org 6.4.2 (the toolchain first on PATH), 2026-11-07 08:07 to 11:18,
no device run meanwhile, every output in a file under the session's
`finalmark/gates/`, each step logged with its commit in
`finalmark/gates.log`. ce64e6d, the commit before bcee36d, differs from it
only in the run line's `stopsByKind`; the bench A/B and the disassembly
are of ce64e6d's aligned build.

| gate | result |
|---|---|
| clean build (`--scratch-path .build/clean-check`) | exit 0, 0 errors, 0 warnings, 19 s (the toolchain's compilation cache, so the full strict-memory-safety typecheck is `just ios-check`'s) |
| `swift test` | 381 + 112 passed, 314 + 98 s |
| under load (12 busy loops) | 381 + 112 passed, 473 + 177 s |
| ThreadSanitizer | 381 + 112 passed, 0 reports, 686 + 2596 s |
| ThreadSanitizer under load | 381 + 112 passed, 0 reports, 765 + 3054 s |
| `just ios-check` | exit 0, 0 errors, 0 warnings |
| `just arc-check` | OK: no retain or release on the checked paths (139 function lines, the three young-root scans among them), `interpret` 1056 instructions, one indirect branch and one jump table |
| `just golden` | 12 of 12 checksums |
| `just test-release` | 381 + 112 passed |
| `just model-check` | 29 + 5 + 15 passed (the young-collection model's new test among the 29) |
| `just soak` | passed: 1000 seeds under every configuration (27 lines, no failing seed); the resumed modes saving 908 to 995 of 1000 |
| `just fuzz kasm 600` | libFuzzer build ok, 2.21 million runs, no crash |
| `just fuzz snapshot 600` | libFuzzer build ok, 3.21 million runs, no crash |
| `just fuzz syntax 600` | libFuzzer build ok, 0.94 million runs, no crash |
| `just fuzz protocol 600` | libFuzzer build ok, 1.72 million runs, no crash |
| `just apps` | macOS and iOS: exit 0, 0 errors, 0 warnings |
| `just kernel-test` | 205 tests, 205 passed |
| `just new-check` | ok: both targets in both configurations, 0 errors, 0 warnings; the Release products without the protocol |

(381 is `KajoVMTests`, 12 of them new; 112 `KajoCompilerTests`, as at the
start.)

## Commands

```zsh
swift test --filter 'FinalMarkTests'                                       # the record, the bound, the scans, the main worker, the filter
cd models && swift test --filter withTheMainWorkersOpenWhileAStopIsWanted  # the model with and without the main worker's open
DEVICE=<udid> scripts/device.sh run out.txt mode=scenario scenario=storm workers=7 young=offload seconds=10 events=1000
scripts/mac-shell.sh run out.txt mode=scenario scenario=storm workers=7 young=offload seconds=10
# the device blocks: finalmark/dev/block.sh (before) and after.sh (after); tables: table.py, summary.py, missed.py, energy.py
```
