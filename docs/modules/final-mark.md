# The final mark on the devices (a follow-up to modules 5 and 7)

Status: brief, 2026-11-07. From the open item of module 9a's device rows
(`docs/modules/shells.md`, "What is still unknown": the final mark is 7 to
17 ms at most on the phone with young collection on, against under 0.6 ms
with the stop-the-world scavenge; the iPad 4.8 to 8.6 ms at 5 workers and
8.4 to 16.5 at 7) and from the large-bytes follow-up's last device block
(`docs/modules/large-bytes.md`, "After"): with every fallback gone, the
iPhone 13 Pro still missed 1 and 2 frames in two of twenty storm launches
at thermal serious, behind final marks of 8.3 and 20 ms. The module that
builds this rewrites the file as the as-built description.

One thing: the final mark's stop under the storm on a device is bounded so
that it costs no frame, and the bound is understood, not tuned into.

Not in this follow-up: the remaining 9a unknowns (the Mac shell's typing
misses idle, the control shell's 87 to 101 missed frames in three
link-probe launches, the iPad's one 19.5 ms main turn in a large-churn
launch), the pointer-object sentinel, card marking.

## What it hides

How long the world stands still at the end of a marking cycle. Smalltalk
code and the shells see a frame budget that holds; nothing above the
collector learns what the final mark drains, in what order, or on which
core.

## Find out first

The final mark is one stop-the-world phase (`Marking/FinalMark.swift`,
`MarkingHost.finalMark`): time to safepoint, the SATB buffers drained, the
young roots scanned (module 7's young-root scan, `youngRootScans`), the
remembered filter, pending roots and the finalization queue, weak slots
and ephemerons, then the verifier where it is on. Module 5 measured 0.11
to 0.14 ms p50 at 8 workers on the Mac; with young collection on, on the
devices, the maximum is a hundred times that. The brief does not know
which part grows. Before any change, instrument the phases of every final
mark with the time each took (a per-cycle record beside module 5's cycle
log, with the thread's QoS and whether it ran on a performance or an
efficiency core, as the large-bytes fallback record did) and run the
storm at 5 and at 7 workers on the iPhone and the iPad, cooled and
heated, 10 launches each, with young collection `offload` and `local` and
with the stop-the-world scavenge as the control. Tabulate, over every
row, the final mark's p50, p99 and max beside frames missed, and say
which phase the maxima are in. Candidates the earlier modules suggest,
to be confirmed or ruled out by the record and not by argument:

- **Time to safepoint**: seven busy workers on six cores, one of them
  descheduled, and the stop waits for it (`finalTtspP50ms` exists; the
  max does not).
- **The SATB drain**: the storm's allocation rate fills the buffers
  faster than a utility-QoS marker on efficiency cores drains them
  concurrently, so the final mark drains the backlog in the stop.
- **The young-root scan**: with young collection on nothing is promoted
  at the final mark, so every nursery's live young objects are roots and
  are scanned in the stop, and seven nurseries at 4 MiB are more than the
  oracle's empty ones.
- **The marker's QoS for the stop itself**: module 7 raises a stopper
  outside the worker table to user-initiated for its stop
  (`stopperQoSRaises`); check that the final mark's thread is raised
  before it waits and that the raise takes effect on a saturated phone.
- **Thermal**: the maxima came at serious on the iPhone; the record must
  carry the thermal state and the thread's clock as the investigation
  logged them.

## Then bound it

Fix the cause found, not the symptom. Whatever it is, the bound is a
property the design states and a test checks (as module 10's chunked
scan polls by work done): the work the final mark may do inside its stop
is bounded in work, and work past the bound is done concurrently before
the stop (another drain round, a pre-scan of young roots with the
barrier catching the rest) or after it (as the lazy sweep is). The
earlier modules' rules bind: every slot a mutator may store into while
marking goes through the SATB barrier; nothing young is promoted by the
final mark under young collection; the verifier's skip rules and every
reader of the entry table agree in the same commit; the models in
`docs/models/` are updated in the same commit as any change to the
protocols they cover, and a change that no model covers says so and why.
Any QoS change is measured for energy on the iPhone as experiments/power
did.

The Mac's rows stay as they are (0 frames missed, the final mark's p50
within its module 5 numbers). The hot path is untouched: `interpret`
diffed instruction for instruction, `just arc-check`, the aligned A/B
against the starting commit.

Done when 20 storm launches at 5 and 20 at 7 workers on each device,
cooled and heated, interleaved with idle, miss no frame with young
collection on, the final mark's max is under half a frame (4 ms at 120
Hz) in every one, the main thread's stopped time is no worse than the
large-bytes follow-up's final block, and the stop-the-world control and
the Mac are unchanged. If a device at 7 workers cannot meet it, say what
bounds it and what the default worker count should be there.

## Verification

Every gate on the final code commit, outputs to files, `gates.log` with
the commit of each (the eighteen of `docs/modules/large-bytes.md`'s
Verification; the four fuzz runs one after another). The aligned A/B and
the `interpret` diff. Broken variants: the bound removed (the test that
counts the final mark's work fails), the pre-stop work skipped (the
verifier finds a lost object or the bound test fails).

## Decision record

ADR 0006 gets a "Built (final mark)" note with the phase that grew and
the bound; ADR 0008 one if the young-root scan is what changed.
