# The main worker always offloads its young collections (a follow-up of module 7 and the final mark)

## Status

Built 2026-11-16 (see As built); the owner answered the three open
questions the same evening while the module ran (question 1 further than
recommended). Briefed 2026-11-16. The final mark's third open question asked
whether `young=local` should still let the main worker collect its own
nursery. The owner, 2026-11-15: "Always offload." Recorded in
`docs/decisions/13-final-mark.md`: local collection is for background
workers only and no mode lets the main thread collect. Chosen as the next
module by the owner on 2026-11-16.

## What it is

Today a young mode decides who collects the main worker's nursery: under
`offload` the young collector thread does, under `local` the main worker
itself does, on the main thread, between two frames. After this module no
mode reachable from the command line, a shell or an app has the main thread
run a young collection of a nursery. The main worker's nursery is always the
two-half nursery the collector thread collects. This is a change to module
7's protocol as configured, so the young-collection model changes in the
same commit.

## What is known (check these before building on them)

- `YoungMode` has three cases (`Sources/KajoVM/YoungCollection/
  YoungConfig.swift`): `stw` (module 4's parallel scavenge, the oracle),
  `local` (every nursery collected by its owner) and `offload` (the default:
  worker 0's nursery collected by the young collector thread, "background
  workers (and the host) collect locally"). `isOffloaded(k)` is `mode ==
  .offload && k == 0` (`YoungState.swift`), and the nursery is made with
  two eden halves only when `young.mode == .offload`
  (`Nursery/YoungAllocation.swift`).
- So after the change `local` and `offload` differ in nothing. What is left
  of `local` is a name.
- `YoungConfig.collectorThread = false` (and a VM before `VM.start`) makes
  an offloaded nursery "collected by its owner right after its flip": tests
  that drive workers from one thread use it. That is the main worker
  collecting, in a test configuration.
- The host is a participant with a nursery of its own that it collects
  locally (`YoungHost.swift`). In the shells and in a generated app the
  host's calls come from the main thread. Whether that puts young
  collections on the main thread in any scenario has not been measured.
- Under `stw` the main worker is stopped and copies in the parallel
  scavenge (`collectorNs` on the turn's record). That is the oracle and is
  not this module's (open question 3).
- The evidence the answer rests on (`docs/decisions/13-final-mark.md`,
  `docs/modules/final-mark.md`): with every stop under 1.1 ms, `young=local`
  still missed frames on the iPhone at 7 workers behind the main worker's
  own collections of 6 to 21 ms; `offload` missed none in 120 storm
  launches but two single frames at 7 workers that were no stop.
- The weekly run of 2026-11-16 (30e14bd, `~/kajo-weekly/2026-11-16/`): 156
  rows a matrix on the Mac, the iPad and the iPhone, 0 failed launches, 0
  fallbacks; frames missed outside the hog rows: Mac 0, iPad 2, iPhone 10
  (the ring under `young=stw`). Native by default's matrices
  (`~/kajo-scratch/native-by-default/`): every `local` and `offload` row 0
  in both engines.
- `scripts/shell-matrix.sh` runs each scenario under `stw local offload`;
  the weekly's summary and `shell-report.py --bar` read those rows.
- The main worker may open one collection while a stop is wanted
  (`mainMayPass`, `Collect.swift`; the final mark's fourth answer: kept).
- When the main worker fills its second half while the collector still
  works on the first, the main worker waits. That wait is the price of
  never collecting on the main thread; where it is counted, and how long it
  was in the matrices, is to be found before anything is built.

## Starting positions (measure, then decide; say where one was wrong)

1. The mode `local` goes: `--young local` and the shells' `young=local` are
   refused with one line that names `offload`, the enum has two cases, the
   matrices have two young modes and a third fewer scenario rows. Nothing
   aliases the old name to the new behaviour (open question 1).
2. Nothing in the protocol itself is new: an owner collecting its own
   nursery stays (background workers), an offloaded nursery stays (worker
   0). What changes is which configurations exist, so the model loses
   configurations and gains none. Check this against the model before
   believing it: every place the model or a verifier asks "is this the
   main worker" or "is this mode local" is listed in the doc.
3. The tests that ran under `local` to exercise an owner's collection keep
   their coverage through background workers; the tests that named worker 0
   under `local` are the ones to rewrite, and each is named in the doc with
   what covers its claim now.
4. The host's nursery is not collected on the main thread often or long
   enough to cost a frame. If part 1 says otherwise, say so and stop for
   the bar's first item: it is then not met by removing a mode, and what to
   do about the host is an open question with the numbers, not a second
   module built on the side.
5. The single-thread test configuration (`collectorThread = false`) stays
   as it is, reachable from tests only (open question 2).
6. The wait of the main worker for its collector is counted already; if it
   is not, part 1 adds the count and the longest wait to the run line and
   to the shells' rows.

## Parts

1. **Measure and instrument, build nothing else.** On the starting commit:
   a counter of young collections of a nursery that ran on the main thread
   and their longest time, by whose nursery (worker 0's, the host's) and by
   mode, on the run line and in the shells' rows; the main worker's waits
   for its collector (count, longest). Then the Mac matrix, and the two
   devices' matrices, as the before. Read from them: where the main thread
   collects today under `offload` (it should be nowhere), what `local` costs
   beside `offload`, and what the host's nursery does.
2. **The model.** `models/Sources/YoungCollectionModel/` and
   `docs/models/young-collection.md`: the configurations that remain; each
   switch off still finds its violation. Same commit as part 3.
3. **The change.** The mode's removal in `YoungConfig`, the nursery's
   making, `Headless`, the CLI's usage line, the shells' argument, a
   generated app (if it can name a mode at all, say which), and the tests.
   A verifier or a checked-build assertion: a young collection of a nursery
   on the main thread outside the single-thread test configuration is a
   counted failure, never a silent path.
4. **The scripts.** `shell-matrix.sh`, `shell-report.py` (`--bar` and the
   tables), `device-rows.sh`, `weekly.sh`'s summary: two young modes. Each
   changed script is run once alone, and `check-tier-test.sh` passes.
5. **Measure again:** the same three matrices, the aligned A/B against the
   starting commit, the new counter in every row.
6. **The docs:** this file's "As built"; a dated section in
   `docs/modules/young-collection.md`; a "Built" note in ADR 0008;
   `docs/models/young-collection.md`.

## Tests

- Written first, failing on the starting commit: a VM started as `kajo run
  --young local` does, with a load that fills worker 0's nursery, shows a
  young collection on the main worker; after the module the same request is
  refused, and under `offload` the counter reads 0 with the same load.
- The broken variant: a test switch that lets worker 0 collect its own
  nursery with the collector thread running makes the new verifier fail
  (a named check, not a trap).
- The young verifier, the random programs' young configurations and the
  shared-objects test run in the modes that remain; say which
  configurations of the random programs changed.
- The model: each switch off finds its violation, as before.
- Every option that takes a mode name is called once with `local` and its
  refusal quoted.

## The bar

- The new counter reads 0 in every row of the three after matrices but the
  `stw` rows, and the host's share is stated with its numbers.
- `offload` rows: frames missed, fallbacks and failed launches no worse
  than the before matrices of part 1 and the weekly's of 2026-11-16; every
  column of `shell-report.py --bar` tabulated. Device blocks are read with
  their thermal state: wait for nominal between blocks or interleave.
- The aligned A/B (`scripts/ab.sh`) against the starting commit within the
  runs' own spread at 1 and 8 workers; `interpret` identical in the
  disassembly diff, or each difference explained.
- `just arc-check` passes.
- `cd models && swift test` passes; the doc lists the model's
  configurations before and after.
- `just check <the brief's commit>` on the final code commit: the core
  tier, every gate `rc=0`, `gates.log` quoted, gate times against
  `~/kajo-scratch/aot-product/check/gates.log` (the last core-tier run,
  1f7828f, 11 307 s) with the matrices' new length said.
- The matrices' row counts before and after, and the weekly's summary made
  once from the after rows.

## Rules of the house that bind here

- `docs/PROCESS.md`, "Constraints on every agent", in full.
- A model is updated in the same commit as any change to its protocol, and
  a model with switches is believed only when each switch off finds its
  violation.
- Every entry state needs exactly one owner; when a configuration goes,
  list every reader of what it configured (the nursery's shape, the
  remembered sets, the verifiers' skip rules) and make them agree in the
  same commit.
- A summary that classifies a field lists the field's every value first: the
  reports must not count a missing `local` row as a failed one, and old raw
  files with `local` rows must still be readable or be refused by name.
- A changed gate script is run once on its own before the gate run.
- A before and after on a device is read with each block's thermal state.
- A hand-back quotes one run of every switch and mode the module adds or
  removes.
- A brief's premise is measured before it is built: part 1 first.

## Not in this module

- The stop-the-world oracle's scavenge and who copies in it.
- The collector thread's QoS, the nursery's size, a second collector
  thread.
- The host's nursery, beyond measuring it (starting position 4).
- The two `young=stw` row kinds that missed more frames with native code
  on; fused sends; AOT 3.

## Deliverables

- The commits; the before and after matrices and tables with their raw
  files under `~/kajo-scratch/main-offload/`.
- `check/gates.log` on the final code commit.
- The hand-back map of `docs/PROCESS.md` step 5.

## Open questions (build the recommended option; decisions only)

1. The name `local`: refused with a line that names `offload`
   (recommended; a name that silently means another mode makes old rows and
   old commands read wrong), or kept as an alias of `offload`.
2. The single-thread test configuration, in which worker 0 collects its own
   offloaded nursery because no collector thread runs: kept, tests only
   (recommended; about a hundred tests drive a VM from one thread), or
   those tests get a collector thread.
3. "No mode lets the main thread collect" and the oracle: `stw` stays as it
   is, the main worker stopped and copying with the others (recommended; it
   is the oracle the other modes are compared with, and a stopped main
   thread that does not copy only makes the stop longer), or the main
   worker waits out the scavenge without copying.

## As built

Toolchain: swift.org 6.4.2 (swiftly, first on PATH), Apple Swift version
6.4.2 (swift-6.4.2-RELEASE). Work files under
`~/kajo-scratch/main-offload/`.

### The owner's answers (2026-11-16, given while the module ran)

"no alias, no need to keep any references to a non existent modes, we
don't have any users yet. agreed on others"
(`~/kajo-scratch/main-offload/owner-answers-2026-11-16.md`).

1. Further than the recommendation: `local` is simply a name that is no
   mode. It gets the generic refusal that lists the modes that exist
   (`--young: stw or offload, not local`); no special case and no
   reference to the removed mode in code, comments, usage lines, tests,
   scripts or reports. The reports need not read old raw files with
   `local` rows (the brief's rule item on that is dropped); a value a
   reader does not know is still counted as unknown, never as a pass or a
   failure. This section and the dated sections name `local` only to say
   what was removed.
2. The single-thread test configuration is kept, tests only.
3. The oracle `stw` is unchanged.

### Part 1: the counter and the before matrices (576eff0)

The run line (and the shells' rows, as `gc_` keys) gained:

| key | what |
|---|---|
| `ycOnMain`, `ycOnMainMaxMs` | young collections of a nursery that ran on the main thread: collected by the main worker (worker 0: the shells' main thread, `kajo run --main-ms`'s calling thread) or on the process's main thread (`pthread_main_np`, where the shells' host calls run); the longest `totalNs` |
| `ycOnMainW0`, `ycOnMainHost`, `ycOnMainOther` (with `MaxMs`) | the same by whose nursery: worker 0's, the host's, any other |
| `ycHost`, `ycHostMs`, `ycHostMaxMs` | every collection of the host's nursery, on any thread |
| `ycMainCollectorWaits`, `ycMainCollectorWaitMs`, `ycMainCollectorWaitMaxMs` | the main worker's waits for its collector before a flip (counted since module 7 as `collectorWaits`; the run line had them only with `--main-ms`, the shells' rows without the longest: the shells now print `main_collector_wait_max_ms`, `--main-ms` `mainCollectorWaitMaxMs`) |

Under `young=stw` (no module 7) every one reads "-": the main worker copies
in the stop-the-world scavenge, which `collectorNs` counts. The test
`theMainThreadCounterSeesTheMainWorkersCollectionsUnderLocal` (part 1's
commit, replaced in part 3) showed it counting worker 0's collections in the
removed mode, and 0 under `offload`.

Before matrices, `RUNS=3`, Mac (7 workers), iPad and iPhone (5 workers),
156 rows each, raw rows in `part1/matrix-{mac,ipad,iphone}/`, bars in
`part1/matrix-*/bar.md` (re-read with part 4's `shell-report.py --bar`):

| matrix | rows | failed | frames missed outside hog (rows) | fallbacks | young on the main thread | host's nursery | main worker's collector waits | main flips |
|---|--:|--:|---|--:|--:|--:|--:|--:|
| Mac | 156 | 0 | 0 | 0 | 0 | 0 | 0 | 9 |
| iPad | 156 | 0 | 1 (ring, `stw`) | 0 | 0 | 0 | 0 | 18 |
| iPhone | 156 | 0 | 11 in 4 rows (storm 1 and ring 3, all `stw`) | 0 | 0 | 0 | 0 | 18 |

The weekly of 2026-11-16 (30e14bd) had Mac 0, iPad 2, iPhone 10 outside the
hog rows, all `stw`. The hog rows miss frames by design (1786, 3576,
3576 here).

What the before matrices say:
- **Under `offload` the main thread collects nowhere**: 0 in every row of
  all three.
- **What the removed mode cost beside `offload` is not visible in the
  matrix**: its rows never fill the main worker's 4 MiB nursery (the main
  worker flipped 9 times on the Mac and 18 on each device, all in the
  `events` rows, which run `offload` only; `main_own_collections` 0 in
  every row). So part 1 added one interleaved block, storm with
  `events=1000`, both modes in both orders, 3 runs a mode
  (`part1/events-block/`): the Mac never filled the nursery in 10 s under
  the removed mode and flipped once under `offload`; on both devices the
  removed mode made one main-thread collection a launch, 0.64 to 0.69 ms
  (iPad, nominal) and 0.72 to 0.95 ms (iPhone, fair to serious), and
  `offload` 0 with two flips; no frame missed in either mode. At 5 workers
  and this load the cost is under a millisecond a launch; the final
  mark's 6 to 21 ms were at 7 workers on the iPhone behind background
  acknowledgements.
- **Starting position 4 holds**: the host's nursery was collected 0 times
  in every row of the three matrices and the block, on any thread.
- **The main worker's wait for its collector** was 0 in every row
  (starting position 6: it was counted already; only its longest was
  missing from the rows).


### Part 2: the model (fad4e37, the same commit as part 3)

`models/Sources/YoungCollectionModel/` and `docs/models/young-collection.md`
(dated section "2026-11-16: the main worker always offloads"). Every place
the model asked "is this the main worker" or "is this mode offload":
`mainPasses` (`w == 0` in either mode, now `w == 0 && offloaded(0)`), the
allocation's nursery, H1's new-half record, the snoop and T1's new-half
scan (`config.mode == .offload`, now `offloaded(k)`, the VM's
`isOffloaded`), and a new precondition in `Configuration.init` (only worker
0 flips, only in `offload`, and there it never collects).

Starting position 2 was wrong in one place. The model did not only lose a
configuration: `mainOpensWhileWanted` had been checked only on the local
ownership pair, whose worker 0 was the main worker collecting its own
nursery. With that gone the switch changed nothing (the test now asserts
equal state counts there: 171,691 and 128,527), so the pair was added in
its offloaded form (W0 flips and C collects nursery 0, W1 collects nursery
1, O snapshot and sweep or a full collection). Configurations before: nine,
the ownership pair with a main worker that collects (213,969 and 170,836
states). After: the same nine with no main worker in `local` (the pair at
171,691 and 128,527) and the two offloaded ones (854,700 and 679,696). With
`mainOpensWhileWanted` off the offloaded pair has 686,035 and 511,118
states and holds. `deferredEntriesBelongToTheirNursery` off finds claim 5
in the offloaded pair too ("C frees deferred entry H, but the old-space
collector already freed it", 142 and 141 steps). Every other switch finds
its violation as before, at the same state counts. `cd models && swift
test -c release --filter YoungCollection`: 31 tests pass, 17.8 s
(`~/kajo-scratch/main-offload/part2-model.txt`).

### Part 3: the change (fad4e37)

- `YoungMode` has `stw` and `offload`. `kajo run --young`, `kajo test
  --young` and the shells' `young=` go through `Headless.configs`, which
  answers any other name with `YoungMode.refusal`'s one line. A generated
  app names no mode (it takes `Headless.Options`'s default, `offload`).
- `isOffloaded(k)` is `k == 0` under `offload` (a young state exists only
  under `offload`); `startYoungCollector`, the nursery's two halves and
  `install` are unchanged in effect. Readers of what the mode configured
  (the nursery's shape, the remembered sets, the verifiers' skip rules)
  read the same values they read under `offload` before; none named the
  mode but these.
- The main-thread verifier, at the end of every young collection under the
  safepoint mutex: a collection whose collector is worker 0 while the
  collector thread runs counts `youngOnMainFailures` (on the run line's
  counters) and traps in a build that traps. The single-thread test
  configuration (no collector thread started) is its one exception. Broken
  variant, the test switch `mainCollectsItsOwnNursery` (worker 0 takes the
  owner's local path with the collector thread running):
  `withTheMainWorkerCollectingItsOwnNurseryTheMainThreadVerifierFails`
  prints `youngOnMainFailures=14 onMain=14 flips=0 own=14`; without the
  switch the same run prints `youngOnMainFailures=0 onMain=0 flips=14
  own=0`.
- The refusal, quoted from `aNameThatIsNoModeIsRefusedWithTheModesThatExist`:
  `--young: stw or offload, not local`. Written before the change; on
  576eff0 it does not compile (`YoungMode.refusal` and the switch are new)
  and its behaviour was the opposite: part 1's test ran the same load under
  that name and counted worker 0's collections on the main thread.
- Found and fixed on the way (`Headless.swift`, `mainLoad`): `kajo run
  --main-ms` released a tick that had not finished in four frames, and
  `waitUntilAllTerminated` then waited for that main-affine Process
  forever, since only the main turns run it. The first full `swift test`
  hung there on the new `mainLoadRun` tests (0 percent CPU,
  `VM.waitUntilAllTerminated`, sampled); the turns now finish every such
  tick before the run ends.

Tests that ran under the removed mode:

| test | what it named | what covers its claim now |
|---|---|---|
| `theMainWorkerOpensOneCollectionWhileAStopIsWanted` (FinalMarkTests) | worker 0 opening and collecting its own nursery while a stop is wanted | the same test under `offload` with the collector thread started: worker 0 flips while the stop is wanted (`opensWhileWanted == 1`, `flips == 1`, `ownCollections == 0`, nothing on the main worker) |
| the ten `youngRuntime` tests of YoungCollectionTests, the five of FinalMarkTests | workers 1 and 2 collecting their own nurseries | unchanged under `offload`: background workers still collect locally |
| `theYoungCollectionAndRoundLogsKeepTheirCapacityAndTotalEveryRecord` | the logs under local collections | under `offload` (background workers' collections) |
| `aRingLikeLoadStallsInsteadOfFallingBack`, `immediatesAreNotReferencesInAnyCollector`, `readOnlyFlipsRaceNoYoungCollection`, `theImageIsWholeAfterTheVMEnds`, `sharedYoungObjectsAreClaimedOnceByParallelScavengers` | one argument each for the removed mode | their `stw` and `offload` arguments |
| random programs `localCollection`, `exhaustedReserveLocal`, `youngBarrierAlwaysOn` | every nursery collected by its owner | `backgroundCollection` and `exhaustedReserveOffload` (offload, no main task: the background workers collect locally), `youngBarrierAlwaysOn` under offload; 100 seeds each, none failing |

`swift test` on the part-3 tree: 466 and 164 tests pass
(`~/kajo-scratch/main-offload/part3-swift-test2.txt`). The new and changed
tests once under ThreadSanitizer with twelve busy loops: 6 pass, 0 reports
(`part3-tsan-load.txt`). `just ios-check` 0 warnings, `just arc-check` OK.

### Part 4: the scripts (5b72399)

`shell-matrix.sh` runs `stw offload`: the matrix has 21 scenario rows a
run of three instead of 30 (147 rows a matrix instead of 156).
`shell-report.py --bar` prints a line naming the young modes the rows
carry (an unknown value as unknown) and two columns: young collections on
the main thread and the host's nursery's, each with the longest; rows
without the counter read "?". `device-rows.sh` and `weekly.sh` needed no
change (they call the two scripts). Each was run alone on the part-1 raw
rows and on a file with an unknown mode
(`~/kajo-scratch/main-offload/part4/unknown/`); `check-tier-test.sh`: 96
checks, ok.

### Part 5: measured again (5b72399)

After matrices, `RUNS=3`, the same three devices and worker counts, raw
rows in `~/kajo-scratch/main-offload/part5/matrix-{mac,ipad,iphone}/`,
`shell-report.py --bar` in each `bar.md`. 147 rows each (156 before: the
nine scenario rows of the removed mode are gone).

| matrix | rows | failed | checksums not ok | frames missed outside hog (rows) | fallbacks | unjustified | young on the main thread | host's nursery | longest stop |
|---|--:|--:|--:|---|--:|--:|--:|--:|---|
| Mac before | 156 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 13.74 ms (`stw` scavenge) |
| Mac after | 147 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 17.96 ms (`stw` scavenge) |
| iPad before | 156 | 0 | 0 | 1 (1 row, `stw` ring) | 0 | 0 | 0 | 0 | 13.70 ms (`stw` scavenge) |
| iPad after | 147 | 0 | 0 | 5 (2 rows, `stw` ring) | 0 | 0 | 0 | 0 | 14.87 ms (`stw` scavenge) |
| iPhone before | 156 | 0 | 0 | 11 (4 rows, `stw`) | 0 | 0 | 0 | 0 | 16.56 ms (`stw` scavenge) |
| iPhone after | 147 | 0 | 0 | 12 (4 rows, `stw`) | 0 | 0 | 0 | 0 | 15.78 ms (`stw` scavenge) |

- **The new counter reads 0 in every row but the `stw` rows** (which read
  "-") in all six matrices; the host's nursery was collected 0 times in
  every row; the main worker waited for its collector 0 times.
- **`offload` rows: 0 frames missed** in the 12 scenario rows (and the
  events rows) of every matrix before and after, 0 fallbacks, 0 failed
  launches; the weekly of 2026-11-16 had 0 as well. Every missed frame
  outside the hog rows is a `stw` row behind its scavenge (the oracle, not
  this module's, open question 3). Thermal state at the scenario rows'
  starts: before, iPad nominal to serious and iPhone fair to serious;
  after, iPad fair to serious and iPhone serious throughout. The blocks
  ran one after the other on each device, before at 19:54 to 20:26 and
  after at 21:35 to 22:03, not interleaved; the `offload` rows read 0
  at every state, so the order does not decide the reading.
- The hog rows miss frames by design (1785, 3576, 3576 after).

The aligned A/B against 3c4ef9f (`scripts/ab.sh`, five interleaved runs,
`part5/ab.txt`, raw lines in `part5/ab/bench.txt`), checksums the same in
every row: at 1 worker every kernel within 0.993 to 1.011 of the base;
at 8 workers 0.907 to 1.090, every head range overlapping the base's
(st-closures 8: 451 to 568 against 487 to 582 ms). Instructions per run
within 0.998 to 1.002. `interpret` disassembled from both builds
(`part5/interpret-{base,head}.s`, 1816 lines each) differs only in four
`adrp` page offsets (`part5/interpret.diff`): data moved, code identical.
`just arc-check`: OK.

The refusal of each option that takes a mode name
(`part5/refusal/refusals.txt`):

    $ kajo run fib.kasm --young local
    kajo: --young: stw or offload, not local          (exit 1)
    $ kajo test --young local
    kajo test: --young: stw or offload, not local     (exit 2)
    $ scripts/mac-shell.sh run ... mode=scenario young=local
    ... scenario=storm FAILED=1 error=options:_--young:_stw_or_offload,_not_local

A generated app names no mode.
