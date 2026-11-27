# The VM's known faults

Built 2026-11-27 by one build agent from 7ba9643 under the owner's
delegation of 2026-11-25 (the second of its two modules; the first is
`56-check-time.md`). Brief and "As built": `docs/modules/known-faults.md`.
Commits 183b5db (the lateness counter), a8bb1de (part 1), 5063170, bb602c1,
7bc4db9, 8efdf05, 46f7510 (the final code commit), 8b53add (doc). Work
files and every raw output: `~/kajo-scratch/known-faults/`. Toolchain
swift.org 6.4.2 through swiftly.

## Not met, said first

The bar asked for three loaded sanitizer runs passing on the final commit.
On 46f7510 the tier's own `tsan-load` and two of the three passed;
`check-load-1` failed one assertion of a test recorded as thin since the
third review's small fixes, part 2
(`randomProgramsAgreeWithTheirModelNatively`, `slowedMarker`,
"randomScavenges.take(config) > 0"). Alone under the sanitizer and twelve
loops it failed 0 of 5 on the head and 0 of 5 on 7ba9643 (`thin/`), a
condition that is not the gate's; one failure in four loaded runs is what
is known. On the commit before (8efdf05) one loaded run of five hung for
its whole 10800 s (below).

## What was built, item by item

1. **The Delay timers: the counter, no queue.** Each Delay notes fired
   minus due (`DelayLateness` in `VMLife`, under the lock the timer takes;
   the run line's `delaysFired`, `delayLateMeanMs`, `delayLateMaxMs`,
   `delaysLate10ms`, `delaysLate100ms`; `kajo test` and each kernel part
   print them). Alone the maximum is 10.1 ms (GCD's leeway), under twelve
   loops 18.3 ms, in the kernel parts 5 ms. Under the loaded sanitizer
   suite a Delay was 100 ms or more late in 5 of 7 runs (maximum 259 ms).
   The queue (a serial queue per VM at user-initiated) was built and
   measured: nothing changed alone or loaded, and the one sanitizer run
   with it still had 2 Delays past 100 ms (116.6). A guard test shows a
   Delay fires 1 to 6 ms late while the global queue is held full, on the
   starting code too. The queue is not committed
   (`work/queue-not-built.patch`). The brief's starting position was
   wrong: the global queue is not why Delays run late there; the suite's
   CPU is.
2. **Eight workers and a million Symbols each: fixed.** Reproduced:
   4 012 052 interned, then every `asSymbol` fails with `cycles=0`: a
   Symbol is old at birth, a dead one's weak slot is a hole only after a
   collection, and nothing started one. At a bucket at its largest a
   background worker stalls for the collector (resource `symbols`, the
   allocation stalls' rule); the main and host workers, a justified stall
   and a VM with no marker take one full collection (cause `symbols`,
   counted); the insert fails only when a collection left the bucket full.
   After: 8 000 000 interned, 0 failures, 1 cycle, 1 stall of 14.3 ms.
   Nothing changed under the intern lock; the model is unchanged. Short
   reproduction (buckets of 4): 12 044 of 16 000 fail before, 0 after;
   the broken variant `symbolFullFailsAtOnce` is a suite test.
3. **A held method's source and the pragma index: fixed.** A replaced or
   removed method's source is kept weakly (`Smalltalk retireSourceOf:`,
   the new `WeakIdentityTable`) while something holds the method; install
   and removal run the primitive and the pragma index's note in one
   `Smalltalk registry:` block, a refusal signalled after it.
4. **The type service: fixed.** An error in a recheck is counted
   (`errors`, `lastError`) and the Process goes on.
5. **A refused class removal names the Process and the frame's method.**
6. **The frames reply: fixed.** Frame variables are kept per method across
   stops (a `WeakIdentityTable` of at most 1024 methods): a new stop's
   first reply 38.6 ms to 1.8 ms in release; before, compiling was 94 to
   98 percent of it (26.7 s under the sanitizer).
7. **The turn overrun: measured only.** 100 runs alone (largest 0.081 ms)
   and 100 loaded (0.169 ms), none past 0.2 ms. Turns that acknowledged a
   young round passed 0.1 ms 1.7 times as often as the others, under the
   rule's 3 times: the acknowledgement is not the cause.

The six new kernel and type tests fail or error on the starting kernel in
5 of 5 runs; 271 of 271 kernel tests pass after.

## A fault the module made and fixed

8efdf05 ran primitives 97 and 98 inside `Smalltalk registry:`; a
primitive's refusal signals from the fallback code, so a handler or a
debugger stop held the registry and every reader of a source waited.
46f7510 catches the refusal in the block and signals after it
(`KnownFaultsTest>>testARefusedInstallSignalsOutsideTheRegistry`: fails 3
of 3 on 8efdf05's kernel). Found by reading for the hang, not by a gate:
the first tier run on 8efdf05 was `failed=0`.

## The hang on 8efdf05

`check-load-3` on 8efdf05 timed out at 10800 s. The tools shard alone
under load: 8 of 8 passed (4 on the head, 4 on the start), not reproduced.
The hung test process had outlived the gate's kill, orphaned to launchd,
and was found nine hours later; its sample
(`hang/orphan/sample-70841.txt`) has the test thread in
`ProjectDirectoryToolsTests.theToolsChooseThroughTheHostAndTheirChangesLandThere`,
in `LocalTools.close()`, `ShellVM.closeOnce` (`Shell.swift:464`),
`VM.waitUntilAllTerminated()`, an untimed wait, with every VM thread idle:
a Process never terminated. Which Process and why is not known, nor
whether 8efdf05's registry fault took part.

## Gates

`check/gates.log`, last line "2026-11-27 14:04 46f7510 check-tier done
core failed=0 6628s", every gate rc=0: clean-build 20, swift-test-load
361, tsan-load 2462, ios-check 17, arc-check 45, golden 73, native-golden
163, native-kernel-test 91, native-cc 40, test-release 142, model-check
35, soak 62, fuzz 645 (each of four "build=ok"), apps 130, kernel-test 129
(271 tests), new-check 271, ab 331, matrix-mac 771, matrix-iphone 840.
This is the first real core-tier run of check time's layout: 110 minutes
with the two matrices, 84 without, against check time's estimate of about
97 for the Mac gates. 0 sanitizer reports in the tier and in
`check-load-1..3` (rc 1, 0, 0; 2569, 2635, 2652 s); 486 + 162 + 2 + 3 + 39
tests in each test gate; no THIN or PAST margin.

Aligned A/B against 7ba9643 (`check/ab/table.md`), checksums the same,
instructions 0.997 to 1.002: 1 worker 0.995 to 1.009 (the hand-back said
1.004; `st-sends` reads 1.009 with cycles 1.002), 8 workers 0.954 to 1.055
(fib and sends 1.055, cycles 1.014 and 1.020). No file on the
interpreter's path changed.

The matrices' bar columns, 153 rows each: 0 failed, 0 fallbacks, 0
unjustified on both. Mac: 3594 frames missed (3579 in the three hog rows,
15 in two ring `stw` rows), stalls 696 (longest 19.68 ms), longest stop
12.66 ms, longest wait for a safepoint 0.46 ms. iPhone 13 Pro: 3586
missed (3577 in the hog rows), 0 stalls, longest stop 19.39 ms, longest
wait 9.52 ms (the marker at a poll).

## Verified by the main session

The log and tree (eight commits, clean, nothing of Kajo alive); every
`gates.log` line's commit and rc; 0 sanitizer reports by grep over the
four directories; the failing line of `check-load-1`; the A/B table and
the Mac bar (run again from the rows); the Symbols numbers before and
after from their files; the thin and hang counts; the sample's frames; the
core diff of the Symbols fix read whole; `swift test --filter
'SymbolTableFullTests|DelayQueueTests|SwitchTableTests'` run once (8 of 8,
`verify/swift-test.txt`: "broken variant: failed=12044", "stalled:
failed=0 stallsSymbols=46", "no marker: failed=0 fallbacksSymbols=12",
`delay.globalQueueFull` 8.5 of 1000 ms); `canonical-tonel.sh --check` on
`kernel`, `tools`, `types` rc=0.

Not verified by anyone: what hung; the thin test's rate under the gate's
conditions; the queue's effect beyond one sanitizer run; item 7 at the
gate's conditions; the iPad.

## Decided under the owner's delegation (reversible)

1. The Delay queue is not built, against the owner's approval of
   2026-11-23, which was given before the counter existed: built and
   measured, it changed nothing. The counter and the guard test stay;
   reopen if a Delay is seen 1 s late.
2. The Symbols fix as built (stall, then a counted fallback); no cycle
   trigger before a bucket fills.
3. A failed recheck's changes are not checked again until they change.
4. The module is recorded with its bar's item 4 not met: the failing test
   is not the module's and was thin before it.

## Open, for the owner

1. `ShellVM.closeOnce` waits with no bound and a gate's kill left its
   test process alive. Recommended: a small follow-up that prints the
   live Processes and their frames when the wait has been quiet for a
   long stretch, and makes the gate's kill reach the test process, before
   any bound is set.
2. `randomProgramsAgreeWithTheirModelNatively` (`slowedMarker`) fails
   about one loaded sanitizer run in four. Recommended: a small test
   follow-up that drives the scavenge it asserts (slow the producer until
   the counter says so).
3. A turn profile by phase for the overrun: when the owner wants it.

## Not done

No Delay queue, QoS comparison or idle-wakeup measurement; the bucket
scan at four million Symbols (the fixed program takes 236 s); no iPad
rows.
