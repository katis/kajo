# Symbol interning without a stop

Symbol interning without a stop, built 2026-11-15
(`docs/modules/symbol-interning.md`, `docs/models/symbol-interning.md`; the
owner's choice of 2026-11-13): interning a new Symbol no longer stops the
world; part 1 gave the stop a kind of its own (`intern`) and measured
`collections` at 1, 2, 4 and 8 workers at thermal nominal: 4352, 5842, 8437
and 32 484 ms interpreted and 2329, 3817, 8131 and 31 520 natively, 268 903
intern stops at 8 workers with 85.0 µs to reach a safepoint and 90.7 µs of
pause each, 166 worker-seconds parked, the last parker a background worker
at a poll; a cheating build with one global mutex (never committed) put the
ceiling at 1.16 times the 1-worker time interpreted and 1.31 natively, which
decided one lock and not one per bucket; no other operation a program can
loop on (a `perform:` with a String, `Symbol new`) stops; the suspected hole
was real and fixed first (ce2b1d6): the slow path's second lookup answered a
Symbol found in the weak table with no keep-alive barrier, so a cycle
marking at that moment could sweep it under the reference (the test failed
on the starting code with "missed 1"; switch `internNoKeepAlive`); the model
came before the protocol (`models/Sources/SymbolInterningModel`, three
configurations each under the store-buffer model, under sequential
consistency and in both insert orders; claims: one Symbol per byte sequence,
whole reads, no Symbol held is swept, everyone finishes; each switch off
finds its violation: no second lookup, publish before fill, a relaxed
publishing store, which finds nothing under sequential consistency, and no
keep-alive on either lookup or on the growth copy); the protocol
(`Machine.internSlow` in `ObjectModel/Strings.swift`): lookups stay
lock-free, a miss takes one lock that lives beside `InternState`
(`internLock`), looks again, grows the bucket before any Symbol exists so no
unpublished Symbol is held across a poll, makes the Symbol whole under the
lock with the allocation fast path (falling back to `allocateOld` outside
the lock and looking again) and publishes it with a seq_cst store; no stop
finds the lock held (a verifier at every stop), a Symbol made for nothing
becomes a String before any poll, the method cache is not flushed (argued in
the doc's rule 8 and tested by a selector collected and interned again); the
readers' table and the collectors' arguments are in the doc; the brief's
order (make the Symbol, then lock) was built first and measured: eight
workers interning the same bytes in step made 137 000 Symbols a run for
nothing and the native run took 3538 ms at 8 workers against 2176 at 1
(1.63), so the lock comes first (f117715); the broken variants as test
switches: `internNoKeepAlive` (the final mark missed 1),
`internNoSecondLookup` (two Symbols with the same bytes, a verifier
failure), `internPublishBeforeFill` (4512 lookups answered a Symbol of NUL
bytes; skipped under the sanitizer only, a data race by construction); the
random programs gained an intern step (23 of 23 configurations at 20 seeds);
after, at thermal fair, checksums as before: `collections` 4176 ms at 1
worker and 4909 at 8 interpreted (1.18) and 2188 and 2964 natively (1.35),
against 7.5 and 13.5 times before, the dictionary part alone 1.45 and 1.72,
0 intern stops, 3 to 12 stops of any kind a run; the bar is met (at most 1.5
in both engines, no intern stop, `interpret` identical at 1817 lines each,
the aligned A/B against 9c5e984 0.995 to 1.000 at 1 worker and 0.975 to
1.013 at 8 with instruction ratios 0.998 to 1.000); 62 new `unsafe` lines
and 6 removed; `just check 9c5e984` on b478aaf (docs above the last change
under `Sources/`, f117715), the core tier in 11 368 s, passed 18 gates (the
four fuzzers with "libFuzzer build: ok" at 0.78 to 3.09 million runs, 249
kernel tests, native-kernel-test 4057 of 4057 bound, the model check with
the new model, the Mac matrix 0 fallbacks with frames missed only in the hog
rows with the budget off, the iPhone 0 fallbacks and 1 to 6 frames in four
`young=stw` rows behind 13.8 to 16.2 ms scavenges) and failed two:
`tsan-load` on the module's own growth test (its Process did not finish in
600 s and the helper then read a nil result and trapped the test process;
fixed in the test, c98d981) and `tsan` on an allocation-stall test that is
not the module's (`aRingLikeLoadStallsInsteadOfFallingBack` under `offload`:
the right checksum, 0 fallbacks, 2 cycles and 0 stalls; it asserts that a
stall happened in a run of fixed length); only test files changed after, so
the three test gates were run again on c98d981 through `gates-lib.sh`'s own
definitions and passed in 7961 s (`swift-test-load` 1058, `tsan` 2969,
`tsan-load` 3934, 456 + 162 tests and 0 sanitizer reports in each; the new
tests cost about 140 s in the plain loaded gate against 2dc41e6's 917); not
done: a lock per bucket, the bucket scan at a million Symbols (a hit 4.4 µs
there, 0.25 at 100 000, 0.08 at 3000), the verifier's own cost under load, a
broken variant for the lock-free-at-a-stop rule, the new unit tests under
the native harness, device rows that intern in a loop; found and left:
`Image.insertSymbol`'s growth copy has no keep-alive barrier (it runs only
with no VM or no marking), the lock-free hit calls `weakReadBarrier` out of
line, and the ring stall test above; Symbol interning's three open questions
and the stall follow-up's four answered by the owner on 2026-11-15 as
recommended (one lock, the bucket scan left alone until an image holds more
than about 100 000 Symbols, the `intern` stop kind kept for a release; the
command-line priority limit accepted and documented, since a shipped app's
user-initiated is 37 and a stall has no time bound, the `stall-diag` lines
kept, a smaller heap under the sanitizer for the full-heap test, young
collections counted in the progress wait), with AOT 2 the next module
("let's do AOT 2 after interning"; `docs/modules/aot-product.md`, briefed
the same day: size first, Release builds only, opt-in until the owner has
read the sizes) and parallel marking with help from stalled workers kept as
an idea in `docs/PLAN.md`.
