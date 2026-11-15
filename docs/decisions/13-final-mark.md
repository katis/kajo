# The final mark on the devices; the VM core declared done

The final mark on the devices, built 2026-11-07
(`docs/modules/final-mark.md`, ADR 0006's and 0008's Built (final mark)
notes): the brief's premise was wrong, the final mark's stop was 0.16 to
0.54 ms on both devices in every mode all along and the 7 to 20 ms were the
stopper's wait for open young collections before its request, with the world
running, which module 3's StopRecord counted as time to safepoint; the
frames the devices missed in 7 of 162 young-mode launches before the change
were the initial mark's young-root scan inside its stop (3.4 to 8.4 ms,
every nursery walked), a main-thread flip that waited 14 ms while a stop was
wanted, and local mode's own collections; so stops are timed from their
request with the wait before it a field of its own and every final mark a
record (phases, last parker and how it came, the stopper's QoS, core and
clock, thermal state; `finalLog`, `stopsByKind` on the run line), the main
worker may open one collection while a stop is wanted (the young-collection
model updated in the same commit, `mainOpensWhileWanted`), the young-root
scan left the initial mark's stop (the stop records each nursery's ranges
and marks the scan owed; the marker, the nursery's collector before anything
of it moves, or module 4's scavenge claims and walks it; until a nursery is
scanned the SATB barrier records stores into its young holders, in
`satbRecord` and `copySlots`; no model covers it, the doc has the argument
and the tests break each rule), the final mark's tracing is bounded in work
(16 384 units; past the bound or with a scan owed it gives up before
anything is decided and the marker drains concurrently and asks again; after
8 give-ups it finishes past the bound, counted), and a real bug found on the
way: the remembered filter ran before the ephemerons, so a holder marked
only by a fired ephemeron's value was dropped from the remembered set and
its young referent lost (a test fails on 4a94f07 with verifier failures; the
filter runs after the ephemerons); measured on both devices interleaved, 162
launches before, 222 after and 110 on the final code: the final mark at most
0.54 ms with no give-up in 332 launches, the initial mark at most 1.05 ms
(from 3.4 to 8.4), every stop kind under 1.1 ms in every launch, 0 frames
missed in 120 storm launches under young offload but two single frames on
the iPhone at 7 workers that were no stop (a 6.4 ms wait for the safepoint
mutex, a 6.9 ms CPU turn; the default stays 5 workers, where 0 of 30
launches per device missed), the iPad missing none, young local still
missing frames on the iPhone at 7 workers behind the main worker's own
collections (6 to 21 ms), the main thread's stopped time no worse (offload
p50 iPhone 40.0 and 37.0 ms per 10 s against 38.4 and 47.5, iPad 49.1 and
64.8 against 53.6 and 70.7), 0 fallbacks, the Mac 0 frames missed with young
collection on and its final mark p50 0.15 to 0.17 ms, no QoS changed (the
marker does 11 percent less to 30 percent more CPU with the root scans moved
onto it), the aligned A/B against 4a94f07 0.988 to 1.005 at 1 worker and
0.960 to 1.047 at 8 with overlapping ranges, `interpret` identical but for
four page numbers and `storeWithBarriers` and `copySlots` gaining the
owed-scan check on the young-holder SATB branch only; the gates on bcee36d
read 381 + 112 Swift tests, 205 kernel tests and the four fuzz targets one
after another at 0.94 to 3.21 million runs; not done: local mode's
main-worker collections, main-thread parks of 8.3 to 10.5 ms with every stop
under 0.7 ms on the iPhone at serious (no frame cost, not explained), the
ephemerons' firing unbounded past the commit point, the wait before a
request for background workers, parallel root scans; its four open questions
await the owner (the bound's value, eight give-ups then an overrun, whether
`young=local` should still offload the main worker, one collection per
wanted stop); with it the owner declared the VM core done on 2026-11-07 but
for the interpreter-speed module (the send path, superinstructions, the
special sends), after which gates are tiered by what a diff touches and the
full set with the device matrix runs weekly on the mini (see Verification).

Answered by the owner on 2026-11-15, asked one by one in the session
(questions 1, 2 and 4 after an explanation, each then answered as the main
session recommended):

1. The bound's value: 16 384 units kept, as built.
2. Eight give-ups, then an overrun: kept, the ninth attempt completes in
   its stop, as built.
3. `young=local` and the main worker: "Always offload." Local collection is
   for background workers only and no mode lets the main thread collect.
   This differs from what was built; it becomes a follow-up
   (`docs/PLAN.md`), a change to module 7's protocol and its model.
4. One collection for the main worker per wanted stop: kept, as built.
