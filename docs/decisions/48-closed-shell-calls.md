# A closed shell refuses its host's calls

Briefed by the main session on 2026-11-18
(`docs/modules/closed-shell-calls.md`, the owner: "brief it", then "and
start") and built the same day by one build agent from 0e30cff: four
commits, 7f34d15 (part 1), e1506f1 (the check), 5ce3d0e (the tests, the
last code commit) and ac4ace2 (the doc), 3 files. The doc's "Part 1" and
"As built" sections hold every number; the raw files are in
`~/kajo-scratch/closed-shell-calls/`.

## What was built

- `ShellVM` (`Sources/KajoVM/Shell/Shell.swift`) holds its closed flag as
  an `Atomic<Bool>`. `close` sets it under `closeLock`.
- 24 members check it with one relaxed load and stop the process with
  "ShellVM.<call> after close" at the member's own line: `start`,
  `openProtocol`, `stopsForDebugger`, `runTurn`, `checkStuck`, `spawn`,
  `state`, `result`, `failure`, `waitUntilTerminated`, `terminate`,
  `release`, `liveProcessCount`, `resumedProcessCount`, `isReleaseImage`,
  `nativeBindReport`, `nativeGenerated`, `snapshot`, `counters`,
  `collectorReport`, `mainThreadCounters`, `pauses`, `threads` and
  `hopLatencies`.
- 7 are exempt, each with its reason in the test: the initializers,
  `close`, the static `now`, `post`, `postRequest`, `queuedEvents` and
  `queuedRequests`.
- `refusal(_:)` (internal) answers the message or nil; it is the one
  place the rule lives. `checkOpen` is inlined, the trap is out of line.
- The class comment and `close`'s comment state the thread rule: a host
  closes from the thread that drives the VM, and the check does not make
  a call safe to race with `close`.
- `Tests/KajoCompilerTests/ClosedShellCallsTests.swift`: the guard test,
  the table test over the source (32 public members, 24 checked, 7
  exempt, one extension member that delegates), and the hand-run test
  `aCallAfterCloseByHand` (`KAJO_CLOSED_SHELL_CALL=runTurn|spawn|
  liveProcessCount`, off by default).

No file under the core directories changed; `check-tier.sh --dry-run
0e30cff` says "tier: swift", fuzzers none.

## The brief's starting positions

1. Right. On 0e30cff a call after `close` ends with signal 11 in 9 of 9
   debug runs (three calls, three runs each). Under ThreadSanitizer
   `liveProcessCount` reports a SEGV in `VM.schedRead` 3 of 3, `runTurn` a
   SEGV in `worker(_:)` (one run) and `spawn` a failed precondition in
   `RawArray` (one run).
2. Right, with one change: `fatalError`, not `preconditionFailure`, so the
   message prints in a release build too.
3. Right. No lock is held across a call.
4. Right for the four exempt calls. Wrong for four others: the brief had
   `openProtocol`, `stopsForDebugger`, `resumedProcessCount` and
   `nativeBindReport` entering the VM; they touch the bridge or Swift
   properties of the `VM` object and no freed memory. The agent checks
   them anyway (each is a host bug after a close, none is called from
   another thread by design).
5. Built as written; the table test also scans `extension ShellVM` blocks
   under `Sources/`.
6. Right: `ShellRuntime` needed no check (its later turns hold it weakly,
   the apps never close).
7. Right. An empty `runTurn`, aligned `-enable-testing` release builds of
   0e30cff and e1506f1, 1 000 000 turns five times a launch, five rounds
   alternating the order, two blocks, thermal state nominal on every line:

   | Block | Base median (range) | Fix median (range) | Fix / base |
   | --- | --- | --- | --- |
   | 1 | 302.70 ns (300.80 to 305.06) | 304.51 ns (304.04 to 305.75) | 1.006 |
   | 2 | 305.80 ns (299.54 to 306.91) | 303.68 ns (301.26 to 305.73) | 0.993 |

   The sign changes between blocks and both ratios are inside the base's
   own spread (1.4 and 2.4 percent). In the disassembly `runTurn` gained
   `ldrb` and `tbnz`, the trap block after the return, no retain or
   release.
8. Right.

## Messages on the fix

- `KajoVM/Shell.swift:530: Fatal error: ShellVM.runTurn after close`
- `KajoVM/Shell.swift:563: Fatal error: ShellVM.spawn after close`

## Broken variants (by hand)

- The check removed from `liveProcessCount`: the table test fails with
  "ShellVM.liveProcessCount is listed as checked but calls
  checkOpen("liveProcessCount") 0 times for 1 accessors".
- A new public member `workerCount`: "ShellVM.workerCount is neither
  checked nor exempt".
- Not run: the third case the test covers, an extension member not on the
  delegating list.

## Gates

`~/kajo-scratch/closed-shell-calls/check/gates.log`, on 5ce3d0e, the Swift
tier, swift.org 6.4.2: "check-tier done swift failed=0 4287s", every gate
`rc=0`.

| Gate | 5240ac7 (shell-close) | 5ce3d0e |
| --- | --- | --- |
| clean-build | 20 s | 21 s |
| swift-test | 728 s | 716 s |
| tsan | 3156 s | 3030 s |
| kernel-test | 121 s | 120 s |
| apps | 137 s | 131 s |
| new-check | 268 s | 269 s |

`tsan.txt` holds 0 "WARNING: ThreadSanitizer" lines. No fuzzer is in the
tier for this diff (shell-close's tier had the protocol fuzzer because it
touched `Sources/KajoDev`).

## Verified by the main session

- `git log 0e30cff..HEAD` (four commits), `git status --short` clean, the
  source diff read whole, `gates.log`, the dry run, the hand-run files,
  the bench table and the broken variants' files.
- `swift test --filter 'ClosedShellCallsTests|ShellCloseTests'` rerun on
  ac4ace2: 8 tests pass
  (`~/kajo-scratch/closed-shell-calls/verify/rerun.txt`).
- Not verified: the disassembly claim (read from the hand-back only), and
  the `unsafe` count (5928 here and in the Delay fix, 5929 in
  shell-close's doc; the counts were made with different commands).

## Deviations

- `fatalError` in place of `preconditionFailure`.
- Four members that touch no freed memory are checked.
- The sanitizer hand-run needs `TSAN_OPTIONS=abort_on_error=0`: without
  it the first run sat in `abort` at 100 percent CPU for 15 minutes and
  lost its output. Only `liveProcessCount` got three sanitizer runs.

## Not done

- Nothing makes a call safe against a `close` racing on another thread.

## Found, not this module's

- `RunningTarget.close()` (`Tests/KajoCompilerTests/DevProtocolTests.swift`)
  waits at most 30 s for its run thread, ignores the wait's answer and
  closes. If the wait ran out, `close` would race a `runTurn` on that
  thread, which no check can catch. It has not been seen to run out.
  Recommended: record an issue when the wait runs out and leak the target.

## Open questions

1. Should the rule "a host closes from the thread that drives the VM" be
   enforced, not only written? Recommended: no. Enforcing it puts a lock
   or a thread check in every frame, and the check already catches every
   call made after `close` returned.
2. Should `RunningTarget.close()` be fixed as recommended above (a test
   helper, Swift tier)? Recommended: yes, with the next change that
   touches the development protocol's tests; it is not worth a gate run
   of its own.

## The owner's answers (2026-11-19)

"Yes, as recommended", to both questions.

1. The rule that a host closes from the thread that drives the VM stays
   written and is not enforced.
2. `RunningTarget.close()` is fixed with the next change that touches the
   development protocol's tests (record an issue when the 30 s wait runs
   out and leak the target). It gets no module and no gate run of its own.
