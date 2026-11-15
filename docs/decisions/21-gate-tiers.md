# The gate tiers and the weekly run

The gate tiers and the weekly run, built 2026-11-07
(`docs/modules/gate-tiers.md`; scripts only, nothing under `Sources/`,
`kernel/` or `tools/`): `just check` over `scripts/gates-lib.sh` (one gate
as a name, a command, a bound and a check of its output; a fuzz gate fails
without the "libFuzzer build: ok" line, a clean build with a warning, the
Mac shell's tests mode with a failed row), `scripts/check-tier-test.sh` (36
checks of the decision), `scripts/weekly.sh` with its LaunchAgent plist,
`scripts/device-rows.sh` (the device build with a codesign watchdog: 60 s at
0 percent CPU kills it, writes the fact and skips the rows with rc 3), the
aligned A/B as `scripts/ab.sh` and `ab-table.py`, `scripts/shell-report.py
--bar` (launches failed, checksums, frames missed, fallbacks and the longest
stop over every raw row) and `scripts/release.sh <tag>` (the Release CLI and
the development image as a tarball with its SHA-256 and the `gh release
create` line, not run yet); sample diffs by `--dry-run`: 8c3e80f docs none,
ae1b0d6 `kernel/` smalltalk 7 gates, ad0b433 KajoDev swift with the protocol
fuzzer, c657344 KajoCompiler swift with the syntax fuzzer, e417519
`Dispatch.swift` core 21 gates, the module's own diff swift with no fuzzer;
tier 1 forced on dc80549 passed in 355 s (205 kernel, 235 tools-image and
115 compiler tests, golden, the Mac shell's 205 of 205), tier 2 on 3f2acdd
passed in 3641 s (385 + 115 tests, ThreadSanitizer 2820 s with 0 reports,
205 kernel tests, apps, new-check); the quick weekly run on dc80549 under
`env -i` with exactly the plist's environment ran all 18 gates in 144 min
(ThreadSanitizer alone and under load 0 reports, the four fuzzers with
"libFuzzer build: ok" at 0.05 to 0.33 million runs in 60 s) and its Mac
matrix, whose `--bar` first read 24 golden rows with `ok=-1` (no published
checksum at that worker count) as failures, fixed in 3f2acdd, after which
the Mac and iPhone matrices on 3f2acdd pass with the summary agreeing with
the raw rows (Mac: the ring under the stop-the-world young mode 332 frames
and 30 soft-limit fallbacks with a 187 ms compacting full collection, the
hog with the budget off 1192 by design; iPhone at 5 workers: 0 frames missed
and 0 fallbacks in every row but the hog, longest stop a 13.44 ms scavenge,
built and signed with no prompt in 49 s); the first idle launch of the quick
run's Mac matrix missed 428 frames behind a 3.6 s gap with no stop, the
second time a matrix's first launch of a freshly built shell has done so
(595 in the interpreter module), the same binary's later launches missing
none, unexplained; the refusal was tested with a `yes` in another session
(refused) and in its own process group (not refused); `weekly.sh` does not
wake a sleeping display, the display sleeps after 10 min on the mini, and
nothing else of its four open questions is built; the first weekly run,
2026-11-08 02:00 to 05:33 on a024a90: 17 of 18 gates, `tsan-load` failing on
the relocation kernel round that completed one selecting cycle in each of
three runs, the Mac's rows all with frames, 0 fallbacks on the devices; the
failing round fixed the same morning in the tests alone, 9c1dc2a,
`docs/modules/relocation.md` "The round under load": the marker was starved,
not the kernel short, the third run's second cycle planned at its initial
mark but not at its final mark when the Processes ended and the counters
were read, its one pass at 0.14 s of CPU in 4.19 s of wall;
`underRelocation` now waits for the marking phase to be idle after the
Processes terminate, 600 s under the sanitizer and 120 s otherwise with not
reaching idle a failure, the assertion, the three runs and the iteration
counts unchanged, each round printing where it stood at its kernel's end;
the wait took under 1 ms in every loaded sanitizer run and 0.31 and 2.07 s
in `just check`'s plain `swift test`, where it turned 3 of 4 and 2 of 3
selected cycles into every one; 10 of 10 filtered loaded sanitizer runs, 3
of 3 plain, `tsan-load` once at 385 + 121 tests and 0 reports, `just check`
on 9c1dc2a in 3621 s.
