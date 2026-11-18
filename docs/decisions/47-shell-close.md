# A closed shell frees its VM

Briefed by the main session on 2026-11-18 (`docs/modules/shell-close.md`,
the owner: "Yes, brief it", then "Start") and built the same day by one
build agent from 5778e78: three commits, 35e0aab (part 1), 5240ac7 (the
fix, the last code commit) and dcae2be (the doc), 6 files. The doc's "Part
1" and "As built" sections hold every number; the raw files are in
`~/kajo-scratch/shell-close/`.

## What was built

- `ShellVM.close()` (`Sources/KajoVM/Shell/Shell.swift`) destroys the VM
  and its image at once after `shutdown` and the bridge's unregistering.
  The 3 s wait and the `timeoutSeconds` parameter are gone.
- It answers a `ShellCloseReport`: `destroyed`, `pendingRoots` (what the
  old wait waited for), `timersPending` and `undeliveredSignals`. A second
  close and `deinit` answer `destroyed` false.
- `DevTarget.close()` answers the report. `kajo run --protocol` prints
  "kajo: closed with N signals undelivered" on stderr only when N is above
  zero.
- Three internal test seams on `ShellVM`: `closeObserver`,
  `afterShutdownForTests` and `brokenOldWaitSeconds` (the broken variant,
  set only under `KAJO_BROKEN_SHELL_CLOSE=1`, by hand).
- `Tests/KajoCompilerTests/ShellCloseTests.swift`: the reproducing test, a
  close with an event not taken, a close with a request queued, close twice
  then deinit, and a close racing four posters that start at a gate.

No file under the core directories changed; `check-tier.sh --dry-run
5778e78` says "tier: swift".

## The brief's starting positions

1. Right. The test reads the VM's life cell (`VMLife.ended`, set only by
   `VM.destroy`; the cell outlives the VM), so it needs no clock and reads
   no freed memory.
2. Right. A Delay's timer and every post that read its Semaphore before
   the unregistering go through `VMLife`'s lock; a post after it touches
   only the bridge's queue. Not covered: `ShellVM`'s other host calls
   after `close` (question 1).
3. Built, with `pendingRoots` added.
4. Right: no caller passed `timeoutSeconds`.
5. Right: only `Shell/`, `KajoDev/Target.swift` and `kajo` changed.
6. Wrong about the size. Not "several" tests: 33 of the suite's 61 closes
   waited 3 s and leaked, 27 of them a `DevTarget`'s. Every affected test
   still passes.

## Numbers

- On 5778e78 the reproducing test fails 3 of 3: "Expectation failed:
  life.snapshot.ended ... close left the VM undestroyed".
- One full `swift test` on 5778e78: 61 closes, 33 VMs and their images
  leaked (and the new test's), 102.1 s of waiting in all. On 5240ac7: 74
  first closes, 74 destroyed, 0 leaked.
- The race test (posts, undelivered, refused at the end): 1 028 726,
  86 541, 0 in `swift-test`; 110 875, 2103, 1 in `tsan`.
- The broken variant fails the same named check with "State(ended: false,
  timersPending: 1, lateSignals: 0)".

## Gates

`~/kajo-scratch/shell-close/check/gates.log`: the Swift tier on 5240ac7,
swift.org 6.4.2, every gate `rc=0`, "check-tier done swift failed=0
4598s", the protocol fuzzer 121 s with "build=ok". `swift-test` 728 s
against 7ac2711's 696, `tsan` 3156 against 3017; the growth is in the
KajoVMTests run, which this module does not touch (the Delay fix's four
tests are in it), and the bundle that holds every close moved 81.9 to
83.7 s with five tests more. The new tests' bodies take 1.9 to 3.2 s.

## Verified by the main session

- `git log 5778e78..HEAD` (three commits), `git status --short` clean, the
  6 files; `AGENTS.md` and `docs/PLAN.md` untouched; the tier's dry run.
- The source diff read whole.
- `gates.log` line by line; 0 "WARNING: ThreadSanitizer" in `tsan.txt`;
  the "shell-close" lines of both test gates.
- `part1/repro-run{1,2,3}.txt` and `broken/broken-run1.txt`: the failing
  check as quoted.
- `part1/close-log-before.txt` (34 lines that leak) and
  `work/close-log-after.txt` (74 "destroyed=true").
- `swift test --filter ShellCloseTests` on dcae2be: 5 passed
  (`verify/shell-close-tests.txt`).

Not verified by the main session: the leak logs were read, not made again
(their log line was never committed); the `unsafe` line counts (5929 here
against the Delay fix's 5928, not reconciled); the sanitizer run under
load of the new suite.

## Deviations

- Parts 2 to 4 are one commit.
- The race test asserts "destroyed" and "undelivered at most posts"; an
  exact account of every post would need counters in the bridge.
- The broken variant is a property set under an environment variable, run
  by hand: it leaks a VM by construction.

## Not done

- Host calls do not check `closed` (question 1).

## Found, not this module's

- Most of the leaks came from DevProtocol's reaper: its 100 ms Delay
  (`reapEndedRequests`) was pending in 23 `DevTarget` closes, fired during
  the 3 s wait and queued a signal no worker would drain. The root of that
  signal, not a request's, kept almost every development target from
  being freed.

## Open questions

1. Should `ShellVM`'s host calls refuse after `close`? Recommended: yes, a
   precondition with a message in every call that enters the VM; `post`
   and `postRequest` stay as they are (after a close they touch only the
   bridge, and the suite does this 58 times).
2. Should a development target log undelivered signals at its close?
   Built as recommended: `kajo` prints a line only when the count is above
   zero.

## The owner's answer (2026-11-18)

Question 1: "brief it", after asking what the question is and whether the
check would cost performance (the main session's answer: one atomic flag
read per host call, `runTurn` once a frame the only frequent one, `post`
and `postRequest` unchecked; the brief has the measurement as a position).
Briefed the same day as `docs/modules/closed-shell-calls.md` (a row of
`docs/PLAN.md`). Question 2 stands as built.
