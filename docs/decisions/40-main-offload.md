# The main worker always offloads its young collections

A follow-up of module 7 and the final mark, built 2026-11-16 and 17
(`docs/modules/main-offload.md`; one sitting, final code commit 5b72399, the
gates on a89dd0e, which adds only the doc; a test fix by the main session,
e9b1b3b). The owner's answer of 2026-11-15 to the final mark's third question
was "Always offload."

## What was built

The young mode `local`, in which every nursery was collected by its owner and
so the main worker collected its own on the main thread, is gone. Two modes
remain: `offload` (the policy: worker 0's nursery has two eden halves and the
young collector thread collects it; background workers and the host collect
their own) and `stw` (the oracle). Any other name is refused by one generic
line ("--young: stw or offload, not <the name>") in `kajo run`, `kajo test`
and the shells; a generated app names no mode. A new check counts a young
collection by worker 0 while the collector thread runs as a failure
(`youngOnMainFailures`). The scenario matrix runs two young modes and has 147
rows where it had 156.

## Part 1, measured before anything changed

New on the run line and in the shells' rows: young collections that ran on
the main thread by whose nursery with the longest (`ycOnMain*`), every
collection of the host's nursery (`ycHost*`), and the main worker's waits for
its collector with the longest (`ycMainCollectorWait*`).

- Under `offload` the main thread collected nothing in any row of the three
  before matrices, the host's nursery was collected 0 times on any thread,
  and the main worker never waited for its collector.
- The matrix never filled the main worker's nursery under `local` (its
  events and hog rows, which do fill it, ran `offload` only): the brief
  expected the `local` rows to show the cost, and they showed none. The agent
  added a block (the storm with 1000 events, both modes, both orders, three
  runs each, `~/kajo-scratch/main-offload/part1/events-block/`): `local` made
  one main-thread collection a launch, 0.64 to 0.69 ms on the iPad and 0.72
  to 0.95 ms on the iPhone, `offload` none; no frame was missed in either
  mode; on the Mac the nursery never filled under `local`.

So at 5 workers the removed mode cost under a millisecond a launch. The 6 to
21 ms the answer rested on were measured at 7 workers on the iPhone
(`13-final-mark.md`) and were not measured again here.

## The matrices

Before on 576eff0 (`part1/matrix-*`), after on 5b72399 (`part5/matrix-*`),
and the gate's own on a89dd0e (`check/matrix-*`); `shell-report.py --bar`
over every row. In all of them: 0 failed launches, 0 wrong checksums, 0
fallbacks, 0 unjustified fallbacks, 0 young collections on the main thread
and 0 of the host's nursery in every `offload` scenario row (the golden and
drift rows carry no such field and read "?"; the `stw` rows read "-").

Frames missed outside the hog rows, before and after: Mac 0 and 0; iPad 1 and
5; iPhone 11 and 12; the gate's iPhone matrix 12. Every one is a `young=stw`
row with a scavenge stop of 14 to 17 ms (the ring, and one storm row on the
iPhone); every `offload` row missed 0. The weekly run of 2026-11-16 read Mac
0, iPad 2, iPhone 10, the same rows. The device blocks ran one after another,
not interleaved (iPad nominal to serious before and fair to serious after,
iPhone fair to serious and serious throughout), so the iPad's 1 against 5 is
not a measurement of the module, which does not change `stw`.

## The model

`models/Sources/YoungCollectionModel/`, changed in the code's commit
(fad4e37): every mode test asks `offloaded(k)`, as the VM's `isOffloaded`
does. The brief's second starting position was wrong in one place: the switch
`mainOpensWhileWanted` had been checked only on the local ownership pair,
whose worker 0 was a main worker collecting its own nursery; with that
configuration gone the switch changed nothing. Two configurations were added
(the ownership pair with nursery 0 offloaded, 854 700 and 679 696 states),
the switch off holds there, and `deferredEntriesBelongToTheirNursery` off
finds its violation there too. 31 model tests pass
(`~/kajo-scratch/main-offload/part2-model.txt`).

## Speed

The aligned A/B against 3c4ef9f (`check/ab.txt`): 0.995 to 1.014 at 1 worker,
0.936 to 1.064 at 8 with overlapping ranges, instructions 0.998 to 1.002,
checksums equal. `interpret` differs in four `adrp` page numbers only
(`part5/interpret.diff`).

## Gates

`just check 3c4ef9f` on a89dd0e, the core tier, swift.org 6.4.2 first on
PATH, 10 884 s against 11 307 s on 1f7828f
(`~/kajo-scratch/main-offload/check/gates.log`). Every gate `rc=0` but
`tsan-load`: 466 and 164 tests, 0 ThreadSanitizer reports, and one failed
check in `PhoneTransportTests.bonjourFindsAListenerTheTestStarts`, which read
the `targets` event the instant the list showed the name; the browser updates
its list before its callback posts the event. Not the module's. The main
session made the test wait for the event (e9b1b3b, a test file only) and ran
`tsan-load` again alone through `gates-lib.sh`'s own definition:
`rc=0` in 3733 s on e9b1b3b, 466 and 164 tests, 0 ThreadSanitizer reports, the Bonjour test passed (`~/kajo-scratch/main-offload/check-rerun/`). `matrix-mac` 670 s
(826) and `matrix-iphone` 738 s (900) are shorter by the nine rows; the four
fuzz targets built with libFuzzer and ran 0.78 to 3.16 million inputs.

## Deviations and not done

- The events block and the model's two configurations, above.
- `kajo run --main-ms` released a tick still running after its four frames
  and then waited for it forever; the agent's first full `swift test` hung
  there. The main turns now finish such a tick (`Headless.swift`).
- The before and after device blocks were not interleaved.
- The weekly's summary was not made from the after rows; `--bar` was.
- No full tier run has every gate at `rc=0` in one log.

## Found, not the module's

- The Bonjour test's race (fixed, above).
- A test-only race in `collectOwnNursery`: a collector thread started between
  a flip and the "started" check leaves the opened collection never run. Not
  fixed.

## Open questions

The brief's three were answered by the owner on 2026-11-16, while the agent
worked: "no alias, no need to keep any references to a non existent modes,
we don't have any users yet. agreed on others".

1. The name `local`: no alias and no reference to the removed mode. This
   went further than the recommendation (a refusal line naming `offload`)
   and is what was built.
2. The single-thread test configuration, in which worker 0 collects its own
   nursery because no collector thread runs: kept, tests only, as
   recommended.
3. The stop-the-world oracle: unchanged, as recommended.

4. Asked by the main session on 2026-11-17 on a wrong premise: "the regular
   matrix never fills the main worker's nursery; add a scenario that does,
   for example the storm with 1000 events". The owner answered "sure".
   The premise was wrong and the example is a row the matrix has: the
   events and hog rows with `events=1000` flip the main worker's nursery
   once a launch on the Mac and twice on each device under `offload`
   (`part5/matrix-*/events.txt`: `main_flips` 1 and 2, the flip at most
   0.007 ms, the offloaded collection 0.2 to 1.1 ms, 0 waits for the
   collector, 0 frames missed). Nothing was built from the answer.

One question awaits the owner in its place:

5. One or two flips a launch show the policy's price at a light load and
   give its percentiles one or two samples. No row makes the main worker
   fill a half before the collector has finished the other, so the wait
   for the collector, the one way the policy can hold the main thread, has
   read 0 in every row ever run. Add a scenario in which the main worker
   allocates enough to flip a hundred times or more a launch
   (recommended; a small module in the Swift tier, three more rows a
   matrix), or leave the matrix as it is.
