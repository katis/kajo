# Gate reliability: the close's wait, the gate's kill, the random programs' tally

Built 2026-11-27 from 71f2706, on the owner's "Fix both first" of the same
day (the question: fix the two gate-reliability faults first, or go to
user-visible work). Brief and "As built": `docs/modules/gate-reliability.md`.
Commits 22fb102 (part 1), 100add6 (A), d4126d4 (B), 9dd2536 (C, the final
code commit), b8d3a04 (the doc). Work files: `~/kajo-scratch/gate-reliability/`.

## Not met, said first

- The bar's item 2, partly. The mechanism of a close that waits for ever is
  named and forced. Which Process the hung tools test on 8efdf05 waited
  for is not known; that run was never reproduced. The next close that
  gives up prints every live Process with its state and frames.
- The bar's item 4, partly. The thin test was not forced at the rate the
  agent's own rule asked (4 of 5). Under its third condition it failed 3
  of 5 on the starting commit and 0 of 5 after; the prints of two runs
  show the race itself (`part1/C/head/run-5.txt`, `f2-head/run-1.txt`).

## A, the close

`VM.terminateAll` takes one snapshot of the live Processes. A Process
forked after the snapshot by a Process still running was terminated by
nobody, and `ShellVM.closeOnce` then waited untimed for it. The forcing
test (`CloseWaitTests.aCloseWithAProcessForkingWaitersReturns`) did not
return in 120 s in 5 of 5 runs on 71f2706 and passes after, under the
loaded sanitizer too. Other shapes on 71f2706 (`part1/A/start.out`): a
Mutex left held with waiters forked late 3 of 5, a Process forking
main-affine Processes 1 of 5, Processes waiting for ever 0 of 5,
main-affine Processes 0 of 5.

Built: `VM.terminateAllAndWait(quietNs:)` in `Sources/KajoVM/Shell/CloseWait.swift`
terminates in rounds (each round every live Process, those made since the
last round too) and waits on the scheduler's done condition 20 ms at a
time, on the closing thread only. It ends when none is alive, or after
5 s in which no Process ended and the live count did not change; then the
close prints each live Process (id, state, priority, affinity, worker,
what it waits on, eight frames), shuts down, destroys anyway, and
`ShellCloseReport` carries `liveProcesses` and `lateProcesses`. A test
that closes fails on a live Process (`ShellVM.liveAtCloseHook`). `kajo
test`'s end and a resumed run's end do the same (`VM.endAllProcesses`).
The longest close under the loaded sanitizer waited 253 ms, so the bound
has no sanitizer value. No VM thread gained a timed wait. The broken
variant (`KAJO_BROKEN_CLOSE_WAIT=1`, by hand): "close did not return in
120 s; 32 live" (`broken/A-untimed-wait.txt`).

## B, the kill

Reproduced: `swiftpm-testing-helper` runs in a process group of its own,
so `gtimeout`'s kill of its group misses it and it is left with parent 1
(`part1/B/start.out`). Built in `scripts/gates-lib.sh`: every process of
a gate carries `KAJO_GATE_TAG` in its environment; after the gate
`gl_leftovers` finds the tagged processes by pid (seen twice, 2 s apart),
logs each with parent, group and command, samples it into
`leftover-<gate>-<pid>.txt`, kills it by pid, and the gate's end line
ends `leftover=<n>`. A leftover fails a gate that passed.
`check-tier-test.sh` has a stand-in gate (136 checks; its three new ones
fail against the starting `gates-lib.sh`).

## C, the thin test

The cause was the test's, not the collector's: the interpreted and the
native random programs run side by side and shared one tally keyed by the
configuration, so the first to end emptied the other's sum. The native
programs have a tally of their own (`randomScavengesNative`). Counts
before and after, each rule written before its runs: condition F 2 of 5
then 0 of 5, F2 0 of 5 and 0 of 5, F3 3 of 5 then 0 of 5; the native test
alone 3 of 3 passed under each. The assertion is unchanged. A failure of
the interpreted `exhaustedReserveOffload` in part 1's loaded run has the
same shape; that it had this cause is a reading.

## Gates

`~/kajo-scratch/gate-reliability/check/gates.log`: "2026-11-27 20:15:52
9dd2536 check-tier done swift failed=0 3494s", every gate rc=0 and
leftover=0 (3656 s on 1a68580). Then `tsan-load` three times on 9dd2536
(`check-load-1..3/`): rc 0, 0, 0 in 2580, 2669 and 2659 s. With the
tier's own, four loaded sanitizer runs of four passed, 0 sanitizer
reports. Tests per shard 486, 3, 2, 168 (162 before: the close tests), 39;
kernel tests 271.

## Verified by the main session

From the files: the commits and a clean tree; every `gates.log` line on
9dd2536 with rc=0; 0 sanitizer reports and the test counts in the four
`tsan-load.txt`; the diff of `Shell.swift`, `CloseWait.swift`,
`gates-lib.sh` and `RandomPrograms.swift` read whole; `part1/A/start.out`,
C's rules and before and after counts, B's `gates.log`; no process of
Kajo alive. Not run again by the main session: any test.

## Decided (the brief's open questions, as recommended)

1. When the bound runs out the close destroys anyway and reports.
2. The bound is 5 s of quiet with no Process ending.
3. The change stayed in `Shell/` and `Headless.swift`: the Swift tier.
4. A leftover fails the gate.
5. The block-buffered output is left; the sample is the evidence.

## Deviations

- Rounds of termination are not a retry of a wait: each round terminates
  only what an earlier one could not have seen. Accepted.
- `kajo test`'s end and a resumed run's end got the same rounds and bound,
  which the brief did not ask for. Accepted: the same untimed wait.
- `ShellVM.liveAtCloseHook` is a static test hook, global mutable state in
  the VM's module; no test fired it.

## Not done, and found

- `VM.shutdown`'s join of a worker held in a host callback has no bound.
- `VM.endAllProcesses`'s give-up line has never run.
- `VM.terminateAll` keeps its one snapshot for its other callers (the
  random programs' cleanup after a failure).
- The iOS shell and the devices were not run (Swift tier).
- The first weekly run with the leftover check is 2026-11-30.
