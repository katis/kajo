# The third review's small fixes, part 1

Briefed by the main session on 2026-11-20 (`docs/modules/review-3-small-fixes.md`,
the owner: "Small safe fixes", after the third review,
`docs/reviews/2026-11-20/`) and built by two build agents from 0b33ed3. The
first built the eight items in eight commits (cc00a80 part 1, b8e8617,
da1e867, 8f89c19, f1bc64f, 577ccd2, 18ad7a9, 0b53285 the doc) and handed
back with the sanitizer gate failing on a test it had not written. The
second found that failure's conditions and fixed them in three commits
(a324f92 instrumentation, aca38de the fixes and the last code commit,
a73a6f1 the doc). No file under the core directories changed. The doc's
"Part 1", "As built" and "The failed sanitizer gate" sections hold every
number; the raw files are in `~/kajo-scratch/review-3-small-fixes/`.

## What was built

1. **The verifier level** (`verification.A1`). `Headless.Options.verify` is
   `Bool?`; nil is the build's level (on in a checked build), and `configs`
   no longer writes false over it. `--verify` and `--no-verify` on `kajo
   run` and `kajo test`; `verify=on|off` and `verifies=N` on the run line,
   the gc summary event and `kajo test`'s line. **Off** in `kajo test`,
   `KernelTestParts`, `ShellVM` and the stall tests' helper, because of the
   fault below; on in the other checked Headless runs.
2. **`Monitor`** fixed as `Mutex` was: an owner, the wait inside the
   `ensure:`, `abandon:` for a wait cut short, and (second agent) the whole
   of `wait` inside its `ifCurtailed:` with a `released` flag. A third
   fault the brief did not name: a terminated waiter took the next signal,
   so a live `SharedQueue` consumer was never woken.
3. **`OrderedCollection>>grow`** moves the elements to the middle of the
   same array when they fill less than half of it.
4. **`DevSession`**: the organization built once per `classSelectors:side:`,
   handles found through `objectHandles`, the hierarchy sorted before the
   collect, `Behavior>>selectorsInCategory:` reads one category.
5. **One transcript sink**: `transcriptText(ofLine:)` decides by a prefix
   compare and parses only a Transcript line; seven sinks call it.
6. **UIKit's `appendLine`** appends to the text storage.
7. **`ProtocolClient`** drops and counts a reply nobody waits for;
   `DevClient` keeps the last 1024 latencies and outages with running
   counts.
8. `processTask()` converts through the Mach timebase (1.001 s of CPU read
   24 025 687 before); `PositionableStream>>contents` has one branch; the
   matrix script's comment.

From the failed gate: `ClientHost`'s timers on a serial queue of their own,
`DebugStop>>variablesOf:` (a stop's frame variables found once per method),
and the reconnect test's diagnostics (`remoteDebuggerState`, `HostLog`).

## Numbers

| What | Before | After |
|---|---|---|
| Queue of 10, a million pairs: array | 1 048 576 slots, 16.8 MB allocated | 32 slots, 0 |
| The same: time (median), sends per pair | 134 ms, 4.00 | 158 ms, 4.36 |
| `classSelectors: 'Object'` 100 times: sends | 6 977 725 | 653 632 |
| 2000 handles looked up 10 times: sends | 84 235 385 | 394 732 |
| Verifiers on, 260 kernel tests, release | 7.2 s | 12.3 s (1.71x) |
| The same, debug | 117.9 s | 351.9 s (2.98x) |
| The same, sanitizer, 65 tests | 59.1 s | 128.4 s (2.17x) |
| A host timer with the global queue full | never in 20 s | 57 ms |
| Frames after a reopen, sanitizer suite | 18.3 to 29.6 s | 6.0 to 11.9 s |

## The failed sanitizer gate

`theToolsReconnectAfterADroppedLink` failed 3 of the first agent's 4 gate
runs and passes alone. Two shapes, both CPU-proportional work under a 30 s
wall-clock timeout: the image's 1 s reconnect timer, armed on
`DispatchQueue.global()`, fired 4.7 to 26.8 s late while the suite held
that queue's threads; and a frames reply compiled every frame's method
again (9 s alone under the sanitizer, 18 to 30 s in the suite), asked twice
after a reopen. Counted under a rule written first, the compiler bundle up
to the test, interleaved: head 0 failures of 12, starting commit 1 of 12.
The module did not cause it. After the fixes 0 of 12, outages 2.5 to 3.7 s.
Not established: why it failed in the module's gate runs and in none of the
18 before. Still near 30 s under the sanitizer suite, on the starting
commit too: the class hierarchy (15.3 to 26.8 s) and the first frames reply
(15.2 to 21.2 s).

## Gates

The Swift tier on aca38de, `~/kajo-scratch/review-3-small-fixes/check-final/gates.log`:
`check-tier done swift failed=0 4619s`; `tsan` 3230 s with 0 reports,
`swift-test` 711 s, `kernel-test` 122 s (262 tests), `apps` 0 warnings,
`new-check`, the protocol fuzzer 120 s (`build=ok`, 379 371 runs). A second
`tsan` run alone: `rc=0 3125s`. Two runs do not prove a rate. The first
agent's run on 18ad7a9 (`check/gates.log`) ended `failed=1` (tsan).

The main session read the product diff of both hand-backs, checked the
dry run ("tier: swift"), the canonical Tonel form, and reproduced the
verifier fault 2 of 2. It did not rerun the new tests on the starting
commit or the broken variants; their output files are in `part1/`,
`broken/` and `part-reconnect/before/`.

The device: the main session built the iOS shell from a73a6f1 (Release, 69 s) and ran the kernel tests on the iPhone 13 Pro (`scripts/device.sh tests`, `~/kajo-scratch/review-3-small-fixes/device/`): 262 of 262 passed in 7.5 s, thermal nominal, `ViewTest>>testTextViewAppendsLines` among them (a first line, then a second through the text storage, read back). That is the only run of the UIKit `appendLine` change; a long Transcript's cost on the device was not measured.

## Found, not this module's

1. **The make primitive's methods name young objects unremembered.** `kajo
   test <image> --verify --test 'MakeFuzzTest>>testSeededMutationsAreRefusedOrRun'`
   traps in a debug build: `object memory verifier, nursery verifier,
   before scavenge 1: entry 33398 (old) names young @102257 (nursery 1) in
   slot 1, and is not remembered for it` (the main session, 2 of 2; the
   agent, 5 of 5 in the whole run, under `--young stw` too, and once as
   "names a freed entry"). Suspect, not confirmed: primitive 143 makes its
   methods old (`LiveMethodHeap`) and stores a literal that is "any other
   object" as it is (`ObjectModel/LiveMethods.swift`). The other 260 kernel
   tests and the 61 tools tests pass with the verifiers on.
2. **A cross-nursery young reference unremembered**, once:
   `aFullHeapFallsBackJustifiedThenRunsOutOfMemory` under `offload`
   trapped in the suite ("entry 148628 (young in 1) names young @148629
   (nursery 0) ... not remembered"); it passed alone.
3. With the verifiers on in every debug `ShellVM` two tools tests failed
   under the sanitizer, cause not found (cost or fault); `ShellVM` verifies
   only when its host asks.
4. The VM's Delay timers (`Processes/External.swift`) use
   `DispatchQueue.global().asyncAfter`, the shape the host's timers had.
5. `swift test` writes to a file in blocks, up to 35 minutes late.

## Deviations and not done

- `kajo test` says `verify=off` (the bar asked for on): Found 1.
- The queue costs 4.36 sends per pair against 4.00, 18 percent in time.
- The verifier cost: 3 debug rounds and 2 sanitizer rounds, not 5; no
  base-against-base run.
- The counted reconnect runs are the bundle up to the test, not the whole
  gate; the first hand-back's 18ad7a9 failure shape (frames) is inferred
  from its line, that run having no instrumentation.
- No per-line cost counter for the transcript sink.
- `theToolsDevelopTheImageTheyRunIn` (Found 3) was not looked at.

## The owner's answers (2026-11-20, "agreed on questions")

1. `OrderedCollection>>grow` moves under half full, as built (a quarter
   measured 144 ms and 64 slots).
2. After Found 1 is fixed the verifiers run in the release-build kernel
   gate only (the debug cost is 3 times).
3. The core brief for Found 1 and Found 2 comes before part 2 of the small
   fixes.

## Open

1. The VM's Delay timers on a queue of their own: a core change.
   Recommended: yes, after a counter of how late a Delay fires.
2. The reconnect test's remaining margins (hierarchy, the first frames
   reply). Recommended: leave them and watch the test's printed line in
   the weekly run; a longer timeout only moves the bound.
3. `DevClient`'s log bound: 1024 as built.

## The owner's answers (2026-11-23, "Yes, as recommended")

1. The VM's Delay timers go on a queue of their own, after a counter of
   how late a Delay fires. Approved, not built: a core change, a row of
   `docs/PLAN.md`.
2. The reconnect test's two margins are left; its printed line is watched
   in the weekly run.
3. `DevClient`'s log bound stays 1024.
