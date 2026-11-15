# Gate speed and the stall tests' follow-up

Gate speed, built 2026-11-13 (`docs/modules/gate-speed.md`, the owner's
request of the same day, "figure out if we can optimize all these tests and
checks, they're getting really long"; only `Sources/kajo/Test.swift` and
`main.swift` under `Sources/`): the core tier ran in 11 758 s against the
allocation stalls' 19 659 with the same tests in every test gate (449 + 162
against 445 + 161, the same 249 kernel test ids each exactly once in the
plain, loaded and sanitized gates, re-derived by the main session with the
module's `compare-ids.py`); the kernel's SUnit tests run as two VMs side by
side inside the suite (`kajo test --test <Class>>selector>` and `--list`,
`Smalltalk class>>test:`, `KernelTestParts` weighted by measured sanitizer
seconds, `KAJO_KERNEL_TEST_PARTS`; five parts failed the phone transport's
reconnect test 6 times in 8 and three 1 in 2 because the extra VMs starved
`ClientHost`'s global-queue timers, two failed 0 of 1 and the gates since),
the duplicate development-image run in `LiveInstallTests` is gone, the four
fuzzers run side by side for their full time each as one gate
(`scripts/fuzz-gate.sh`, a `gates.log` line per target with its runs and
"libFuzzer build: ok"), compiled native test modules are cached on disk by
source, compiler and flags (`.build/native-test-cache`, 2 GiB,
`KAJO_NATIVE_CACHE=off|<dir>`), `test-release` leaves the random programs to
`soak`, the compilers' limit cases run in parallel, `check-tier-test.sh` (96
checks) is a gate whenever a gate script changes, plain `swift-test` left
the core tier by the owner's decision (the Swift tier and the weekly keep
it) and the weekly is the full set again with the native gates and an
aligned A/B against the last finished weekly's commit; its gate times:
`tsan` 3063 s against 4677 and `tsan-load` 4258 against 5889, the four
fuzzers 608 s together; three final runs failed before the fourth
(Homebrew's LLVM first on PATH broke the native gates' link; the reconnect
test under five and three parts; the allocation-stall tests under the denser
suite), and the fourth passed every gate but `swift-test-load`, on
`aStalledProcessTakesAnInterrupt`; the owner's "fix the stall first" of
2026-11-14 held the module unpushed until the stall tests' follow-up, built
2026-11-14 (`docs/modules/allocation-stalls.md` "The stall tests in a dense
suite" and "The fifth test"; the tests and one test hook, no behaviour of
the VM changed): instrumented first, the failure was neither a lost wakeup
nor a marker starved to nothing: a command-line process on the mini caps
user-initiated and user-interactive at priority 31, the priority of the
twelve default-QoS loops and of every other test's workers (an app's
user-initiated is 37, which is why the stall's QoS override helps in the
shells and cannot help in the test process), the marker got 0.39 to 0.48 of
a core, and the tests' slowdown multiplies the marker's CPU, so a slowed
cycle of 3.2 s alone took 43.5 to 45.8 s in the loaded suite and a stall
that waits for up to two cycles and a fallback needed 90 to 150 s against
the 120 s bound; the times of 460 to 1290 s the suite printed for these
tests were Swift Testing counting the wait for a cooperative-pool thread (a
0.1 s body read 408.8 s), so every test in the file now prints its body's
own time; the fix: the slowdown is an atomic a test can change
(`MarkingShared.slowdown`, `VM.setMarkerSlowdown`, read at the marker's
polls; diagnostic readers `markerThreadSample`, `stallsNow`,
`markingCycleNow` that take no stop), each stalled-Process test slows the
marker until its workers have stalled and its request is made and then lets
the cycle run at full speed, and the waits after the request, the idle
test's rings and the full-heap test end on the collector's own progress
(`StallDiag.waitProgress`: fail only when no stop, cycle or stall has been
counted for 120 s, 600 under the sanitizer, printing where it stood) instead
of racing 120 to 900 s clocks, no bound widened and no assertion dropped;
`theRunningCycleDoesNotJustifyAFallback`, which failed the first tier run's
`tsan-load` at its 900 s bound, ran each heap to out of memory through 41 to
58 full collections where its claim needs a few justified stalls (another
test checks the out-of-memory answer): it waits for four justified stalls,
asserts at least one justified stall's fallback beside 0 unjustified, its
broken variant still fails 4 of 4, and its body went from 1043 to 1352 s in
the loaded sanitized suite to 27 to 42; a slowed cycle ending a stall stays
covered by the ring, slowed-marker and random-program tests; 12 of 12 loaded
suite runs and 3 of 3 loaded sanitized runs on the final code with no
stall-test failure (bodies 4 to 40 s loaded, 122 to 449 s loaded and
sanitized, the longest quiet stretch 89.6 s of 600); `interpret` identical
(1816 lines each), the aligned A/B against 3cf22fe 0.991 to 1.011 at 1
worker and 0.956 to 1.032 at 8, 13 new `unsafe` lines; `just check 3cf22fe`
on e8f9585 (code f2e8aec), the core tier's 21 gates in 11 802 s, passed 20
(the fuzzers at 0.77 to 3.18 million runs each with "libFuzzer build: ok",
the Mac matrix 0 fallbacks, the iPhone 0 fallbacks and 3 to 5 frames in the
oracle row) and failed `tsan-load` on the fifth test; only test files
changed after that, so the three test gates were run again on 2dc41e6
through `gates-lib.sh`'s own definitions and passed in 7980 s
(`swift-test-load` 917, `tsan` 3010, `tsan-load` 4053, 449 + 162 tests and 0
sanitizer reports in each), which is also gate speed's passing run; not
done: `aFullHeapFallsBackJustifiedThenRunsOutOfMemory` has no bound and
takes 903 to 1554 s under the sanitizer, now the sanitized suite's length;
the progress wait does not count young collections that are not stops;
3cf22fe was not rebuilt; DevClient's request timeout still counts from the
first send across a reconnect, which is why the kernel's tests stay at two
parts; the kernel compiler's quadratic `literalIndex:` (two selector limit
cases of about 138 s each); `native-check.sh` and `NativeTest.clang` take
the first clang on PATH; the owner's decisions on the way: Symbol interning
without a stop is the next module, before AOT 2 (2026-11-13), and the weekly
run is on Mondays at 02:00 for good (2026-11-14, the installed LaunchAgent
reloaded by the main session; the first Monday run is 2026-11-16); gate
speed's six open questions answered by the owner on 2026-11-15 as
recommended (DevClient's request timeout is to be re-armed when a request is
sent again after a reconnect and the kernel compiler's quadratic
`literalIndex:` fixed, both as a small follow-up; two kernel-test parts
until then; the cache's 2 GiB bound, the weekly's A/B base and the unsliced
every-method tests as built).
