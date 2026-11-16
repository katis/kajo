# The main worker always offloads its young collections (a follow-up of module 7 and the final mark)

## Status

Briefed 2026-11-16, not built. The final mark's third open question asked
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
