# Gate speed's follow-ups

Gate speed's follow-ups, built 2026-11-15 (`docs/modules/gate-speed.md` "The
agreed follow-ups", `docs/modules/allocation-stalls.md` "Gate speed's
follow-up: three stall tests"; `tools/`, `kernel/Compiler/` and one test
file, nothing under `Sources/`): `DevClient` re-arms a request's 30 s
timeout when it sends the request again on a new session (06e0d08; the
previous send's timer keeps running through the outage; the timers go
through `requestTimerAfter:do:` and `cancelRequestTimer:`, which
`FakeDevClient` records and the tests fire, so no test waits on a clock)
and, a deviation, sends a request at most `DevClient class>>sendLimit` times
(4, the first included), after which the next new session fails it, so a
request never answered ends within about two minutes however often the link
drops; three new tests fail on 7ec1bca, one of them because the old client
armed its timeouts on `UIEventLoop` directly, which headless answers nil: no
tools test had ever had a timeout; 16 of 16 after; the kernel compiler's
`literalIndex:` searches a frame of up to 32 literals whole as before and
past that through buckets keyed by `BytecodeGenerator class>>literalKey:`
with `literal:sameAs:` still deciding within a bucket, so no method's bytes
change (5bfbb7b; the two selector limit cases 137.4 and 138.2 s to 5.0 and
4.8, the limit test 285.6 to 20.0 s, buckets for every frame having cost the
long chain test 17 percent; `CompilerTest` 9 of 9, the corpus and the
byte-identical round trip unchanged; the Smalltalk tier's `compiler-tests`
71 s against 154 and the compiler bundle in plain `swift-test` 68 against
159); the three stall tests (723b3fe):
`aRingLikeLoadStallsInsteadOfFallingBack` was owed no stall in the run that
failed (in `local` and `offload` a worker stalls when blocks in use,
promised and one young generation pass the soft limit's 512 blocks, and a
run of fixed length peaked at 488 to 494, on one side of the edge or the
other by how the cores were shared; repeating the round did not reach it),
so the test slows the marker 64 times (16 under `stw`) until a background
worker has stalled and then lets it run, both waits on the collector's
progress, the assertions unchanged, 10 of 10 filtered runs under the
sanitizer and twelve loops with all 30 cases stalling;
`aFullHeapFallsBackJustifiedThenRunsOutOfMemory` runs a 3 MiB heap under the
sanitizer (12 otherwise; 82 to 93 percent of its time was the full
collections after the justified stalls, whose number does not shrink with
the heap and whose length does: 588 s at 12 MiB, 393 at 6, 239 at 3), claim
and assertions unchanged; `StallDiag`'s progress counts local and offloaded
young collections, read without a stop and with no core change; one measured
run of three kernel-test parts under the sanitizer and the loops passed 162
of 162 with the reconnect test in 105.7 s (one run, not a rate; the parts
stay two); the gates on 723b3fe: `just check 7ec1bca`, the Swift tier, every
gate in 3959 s (456 + 162 tests, `swift-test` 731 s against 839, `tsan` 2725
against 2969 with 0 reports, 249 kernel tests, apps, new-check), the
Smalltalk tier forced in 405 s (249 kernel and 295 tools-image tests,
golden, the Mac shell's 249 of 249) and `tsan-load` alone through
`gates-lib.sh`'s definition in 3777 s against 3934 with 0 reports; found and
not explained: the full-heap test's body at its unchanged 12 MiB read 348.5
s in the plain `swift-test` gate against 69 s filtered (its full collections
up to 5.9 to 6.4 s each beside the rest of the suite); not done: the limit
test's large cases under the sanitizer, `aSlowedMarkerPacesTheMutator` and
`fragmentationIsToldFromAFullHeap` still slowed for their whole run; its
four open questions answered by the owner on 2026-11-15 as recommended and
as built (the send limit of 4, the kernel-test parts two until five parts
are measured over several loaded sanitizer runs, the ring's slowdowns of 64
and 16, the 3 MiB heap under the sanitizer only).
