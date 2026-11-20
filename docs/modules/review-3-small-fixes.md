# The third review's small fixes, part 1 (outside the core)

## Status

Briefed by the main session on 2026-11-20. The owner asked for the third
review on 2026-11-20 ("look for opportunities for mechanical sympathy,
architectural improvements and code reuse") and, given its findings in
four groups, chose "Small safe fixes". The reports are in
`docs/reviews/2026-11-20/`. Starting commit: the commit that adds this
file. Not started.

## What it is

Eight small changes that the review found, each with a mechanism that the
main session checked against the code, and none under a core directory.
Each is a fix of a cost or of a gap, with a test that fails without it.
The four small findings that are under the core directories are part 2,
a later module in the core tier.

## What is known

Each item points at its finding; read the finding whole before the code.
The main session read the lines named here on 821f20f. Check them again.

1. **The heap verifiers are off in everything that goes through
   `Headless`** (`verification.A1`). `Headless.Options.verify` is `false`
   (`Sources/KajoVM/Headless.swift:14`) and `Headless.configs` writes it
   over the checked build's default (`:315`, `:328`). Only `kajo run
   --verify` sets it (`Sources/kajo/main.swift:135`); no gate passes it.
   So `kajo test`, the `kernel-test` and `tools-test` gates and
   `KernelTestParts` run with no heap verifier, in debug and under the
   sanitizer too. `docs/VERIFICATION.md` layer 1 says a checked build
   runs every verifier at every pause.
2. **`Monitor` has the shape the second review fixed in `Mutex`** (the
   Smalltalk report's "Bugs met on the way";
   `kernel/Processes/Monitor.class.st:12-14` and `:35-43`). `critical:`
   is `mutex wait. ^ aBlock ensure: [mutex signal]`: a Process terminated
   between the wait and the `ensure:` keeps the lock. A Process
   terminated while it waits in `Monitor>>wait` unwinds through
   `critical:`'s `ensure:` and signals a mutex it gave back, so two
   Processes can be inside. `SharedQueue` is built on it. The fix of
   `Mutex` is in `docs/modules/review-fixes.md` (finding kernel.F12).
3. **`OrderedCollection>>grow` always doubles** (`smalltalk.M1`;
   `kernel/Collections/OrderedCollection.class.st:40-44`, `:93-102`).
   `addLast:` grows when `lastIndex` reaches the array's end, whatever
   the collection holds, and nothing recentres. A queue that adds at the
   end and removes at the front has an array that grows with what passed
   through it. `addFirst:` has the mirror case.
4. **`DevSession>>classSelectors:side:` rebuilds the organization once
   per category** (`smalltalk.M2`;
   `kernel/Development/DevSession.class.st:187-188`). The same finding
   names `handleOf:` (a scan of every session handle per described slot)
   and `classHierarchy`'s sort.
5. **Every line the image writes is parsed as JSON by a transcript
   sink** (`hosts.M1`; `Sources/KajoApp/Application.swift:202` and six
   more copies the finding lists). The sink runs on the VM thread that
   wrote the line and keeps only the lines of kind `transcript`.
6. **UIKit's `appendLine` reads and sets the whole text per line**
   (`hosts.M6`; `Sources/KajoApp/UIKitHost.swift:249-253`). The AppKit
   host appends to the text storage.
7. **`ProtocolClient` keeps a reply that arrives after its request timed
   out** (the hosts report's bug 1; `Sources/KajoDev/Client.swift:141`,
   `:185`). And `DevClient`'s `latencies` and `outages` are never trimmed
   (the Smalltalk report's bugs; `tools/Client/DevClient.class.st:163`,
   `:264`, `:310`).
8. **Three small things**: the stall tests' `processTask()` reads Mach
   time units as nanoseconds
   (`Tests/KajoVMTests/Marking/AllocationStallTests.swift:371-376`;
   diagnostics only); `PositionableStream>>contents` has two identical
   branches (`kernel/Streams/PositionableStream.class.st:28-31`); the
   comment at `scripts/shell-matrix.sh:9` does not match line 36.

The last Swift-tier run is `~/kajo-scratch/test-waits/check/gates.log`
(ec0a6ef, 4740 s: swift-test 714 s, tsan 3490 s, kernel-test 120 s).

## Starting positions

Each is the main session's belief. Part 1 reads or measures it and
answers right or wrong.

1. With the verifiers on, the kernel's tests and the tools' tests pass.
   If a verifier fails, that is a finding of its own: stop that item,
   record the `verify:` message, the test and the seed, and hand it back
   under "found". Do not fix a collector here (a core change).
2. The verifiers cost the kernel-test gates little: the unfiltered run
   has about 47 pauses. Part 1 measures `kajo test` with and without
   them, in debug and in release, and under the sanitizer for one part
   of the kernel's tests.
3. The verifier item needs no file under a core directory: the level is
   decided in `Headless` (default: on in a checked build, off in a
   release build, `--verify` and a new `--no-verify` say otherwise), and
   `Headless.configs` stops overwriting the checked default. The run line
   and `kajo test`'s summary print `verify=on|off`. If it cannot be done
   without `ObjectMemory/Config.swift` or `Workers/VMConfig.swift`, do
   the `Headless` half and say what is left for part 2.
4. `Monitor` can be fixed as `Mutex` was, in Smalltalk only, and a test
   can show both faults: a Process terminated while it waits to enter,
   and one terminated while it waits on the condition. Each test fails
   on the starting commit by a value (a count of Processes inside, a
   lock that is never free), not by a hang with no bound.
5. `grow` can keep the amortized cost and bound the array: when the
   collection holds less than half the array, move the elements to the
   middle in place and allocate nothing; double only when it is full
   enough. A queue of ten elements with a million passed through keeps
   an array of a few dozen slots. The sends per `addLast:` and
   `removeFirst` on the common path do not rise; count them before and
   after (the collections-speed doc has the method).
6. `classSelectors:side:` needs the organization once. `handleOf:` and
   the hierarchy's sort are fixed only if each is a few lines; if one
   needs a new table, leave it and say so.
7. One prefix test decides a transcript line without a parse. The seven
   sinks become one function. Where it lives is decided by what each
   caller already imports; if two modules cannot share it without a new
   dependency, two copies of a four-line function are better than a
   dependency, and the doc says so.
8. The UIKit `appendLine` can append to `textStorage` as AppKit does and
   keep the same scroll behaviour. No test host runs UIKit; it is
   checked by `just apps` and by reading, and the main session runs the
   device's tests mode after the hand-back.
9. A late reply is dropped when its request is no longer waited for.
   The client knows which ids it waits for; a reply for any other id is
   counted and dropped. `latencies` and `outages` become bounded (keep
   the last N with running totals, as `RecordRing` does in Swift).
10. `processTask()`'s fields are Mach time units. Read the header or
    measure it against `getrusage` before changing the divisor.
11. `scripts/check-tier.sh --dry-run <start>` says "tier: swift" at the
    end. If it says "core", stop and hand back with the file that made
    it so. A changed script under `scripts/` owes `check-tier-test`.

## Parts

1. **Measure and read.** Positions 1, 2, 4, 5, 10 and 11 answered with
   their files. The failing tests of items 2, 3, 7 and the verifier's
   `verify=` line written and shown to fail on the starting commit.
   Nothing fixed. One commit.
2. **The verifiers** (item 1).
3. **The kernel**: `Monitor`, `OrderedCollection`, `DevSession`,
   `PositionableStream` (items 2, 3, 4, 8).
4. **The hosts and the clients**: the transcript sink, UIKit's
   `appendLine`, the late reply, `DevClient`'s logs (items 5, 6, 7).
5. **The rest of item 8** and the doc's "As built".

## Tests

Before the code where possible. Each new test is run on the starting
commit and the doc says "fails there" or "passes there".

- The verifier level: a test that a debug `Headless` run reports
  `verify=on` and that a verifier really ran (a counter of verifier
  runs above zero after a run with at least one pause), and that
  `--no-verify` reports off with the counter at zero. Broken variant:
  the overwrite put back.
- `Monitor`: the two termination tests of position 4, and `SharedQueue`
  under several Processes with one terminated. Broken variant: the old
  `critical:`.
- `OrderedCollection`: the bounded array of position 5 for `addLast:`
  with `removeFirst` and for `addFirst:` with `removeLast`, and the
  contents right across every recentre (a seeded mix of the four
  operations against an Array kept beside it). Broken variant: the old
  `grow`.
- The transcript sink: a transcript line, a reply line, a line that
  holds the prefix inside a string, and an empty line.
- The late reply: a request that times out, its reply sent after, the
  client's table empty and the drop counted.
- `DevClient`: the logs bounded after more replies than the bound, the
  totals still right.

## The bar

1. Every item is fixed or handed back with its reason.
2. `kajo test` in a debug build says `verify=on`, and the kernel's and
   the tools' tests pass with it, or the failure is recorded as found.
3. The verifiers' cost on the kernel-test gates is a table (debug,
   release, one sanitizer part), before and after.
4. A queue of ten elements keeps a bounded array after a million
   operations, and the sends per operation are not above the base's.
5. No file under a core directory changed; the dry run says "tier:
   swift".
6. The Swift tier's `gates.log` on the final code commit, every gate
   `rc=0`, with the times beside ec0a6ef's.
7. The kernel's Tonel files are in the canonical form
   (`scripts/canonical-tonel.sh --check`).

## Rules of the house that bind here

- `docs/PROCESS.md`, "Constraints on every agent", in full.
- A refusal or a failed wait is a value in a test, never a hang: every
  new wait is bounded and prints where it stood.
- A race test starts its racers at a gate.
- A new test's own faults are found by the gates: run the new Swift
  tests once under the sanitizer with the twelve busy loops before the
  tier.
- A count from a script is checked on three rows by hand.
- Read the `verify:` message before naming the suspect.

## Not in this module

- Anything under the core directories. Part 2 (core tier) holds
  `interpreter.A2` (the barrier word's offset outside the layout hash),
  `memory.A1` (weak slots strong in the concurrent young collector: a
  counter first), `memory.M2` (`rememberSlow`'s order), `interpreter.M1`
  (Float arithmetic through the integer path), `verification.R4` (three
  test switches no test names) and the one `VerificationLevel` of
  `verification.A1`.
- The review's larger levers and its gate-time findings.
- A fix of any collector fault the verifiers find.
- The device: no device run by the agent.

## Deliverables

- The commits, part 1 first, each naming its item.
- This doc with "Part 1" (the positions answered) and "As built" (the
  numbers with their files, deviations, not done, found, open
  questions).
- Raw files under `~/kajo-scratch/review-3-small-fixes/`.
- The hand-back map of `docs/PROCESS.md`.

## Open questions

Build the recommended option; bring the decision back.

1. Do the kernel-test gates run with the heap verifiers on in checked
   builds? Recommended: yes, as `docs/VERIFICATION.md` says, unless
   part 1 measures more than a tenth added to the sanitizer gate.
2. Does a release `kajo test` verify? Recommended: no; `--verify` is
   there for the one who wants it.
3. The bound of `DevClient`'s logs. Recommended: the last 1024 of each.

## Part 1: the positions answered

Built and run by the build agent on 2026-11-20 on the starting commit
(0b33ed3) with only the new tests, the fixture and one accessor added
(`ProtocolClient.pendingReplyCount`); for position 1 `kajo test` also took
`--verify` (three lines in `Sources/kajo/Test.swift`, the flag part 2
keeps). Toolchain: swift.org 6.4.2 first on PATH (swiftly). Raw files are
in `~/kajo-scratch/review-3-small-fixes/part1/`.

1. **Wrong.** With the heap verifiers on, the kernel's tests do not pass:
   `kajo test --verify` in a debug build traps at the first scavenge after
   `MakeFuzzTest>>testSeededMutationsAreRefusedOrRun`, every time
   (5 runs of 5 on the unfiltered kernel run, the same scavenge 720 and the same first entry 853907 each time; `found-summary.txt`). The message, from `verify-debug-kernel.err`:
   `object memory verifier, nursery verifier, before scavenge 720: entry
   853907 (old) names young @958173 (nursery 1) in slot 1, and is not
   remembered for it; ...` (nine more of the same shape), in
   `ReflectionTest>>testAClassWithNoInstancesAnswersAnEmptyArray`, whose
   `Smalltalk garbageCollect` makes the scavenge. The development image
   (tools' tests too) and the development image with the type checker
   trap at the same scavenge 720 in the same test (`verify-debug-dev.err`,
   `verify-debug-devtypes.err`). Bisected (`found-bisect.txt`): the
   seeded MakeFuzz test followed by the trapping test is enough
   (`found-pair-makefuzz-seeded.err`: before scavenge 1); the other
   candidates are not; and from test 130 of the order the same pair gives
   the worse form, `after scavenge 1: entry 28490 slot 1 names @88622, a
   freed entry` (`found-bisect-130.err`): the scavenge freed young objects
   that old objects still name. The mutated methods are made by primitive
   143 in old space (`LiveMethodHeap`, `Sources/KajoVM/ObjectModel/
   LiveMethods.swift`), and a literal that is "any other object" is used
   as it is (`CodeReader.literal`, `.object(v)`); a young object stored
   there is not remembered. That is the suspect, not a finding checked
   line by line; it is a core change and is not fixed here (Found, below).
   The stop-the-world young mode (`--young stw`) traps too, at scavenge 905 inside the seeded MakeFuzz test itself (`found-kernel-stw.err`), so the fault is not the offloaded young collector's. Every kernel test but the seeded MakeFuzz test passes with the verifiers on (260 of 260, 2121 verifier runs, `work/verify-kernel-but-seeded.err`), and so do the tools' 61 (`work/verify-tools-only.err`).
3. **Right.** The level is decided in `Headless` alone: `checkedBuild` is
   internal to `KajoVM` and `Headless.configs` reads it; no file under a
   core directory is needed.
4. **Right, with a third fault.** `Monitor` is fixed in Smalltalk only.
   The four tests (`MonitorTerminationTests` in
   `Tests/KajoCompilerTests/Review3SmallFixesTests.swift`, driven slice by
   slice as item 14's were) on the starting commit
   (`monitor-tests-on-base.txt`): terminated while it waits to enter
   passes there (the VM unlinks it; nothing to give back, as item 14
   found for `Semaphore`); released into the Monitor and terminated
   before it runs fails (excess 0: the Monitor is never free again);
   terminated while it waits on the condition fails (excess 2, and its
   Semaphore stays among the waiters); and the third fault, which the
   brief did not name: a `SharedQueue` consumer terminated in `next`
   leaves its condition Semaphore queued, the next `nextPut:` signals it,
   and the live consumer waits for ever (fails: the consumer still
   waiting, excess 2, one dead waiter). Each fails by a value.
5. **Right in the array, wrong in the sends.** On the starting commit a
   queue of ten with a million `addLast:` and `removeFirst` ends with an
   array of 1 048 576 slots and 16.8 MB allocated (`oc-sends-base.txt`;
   `addFirst:` with `removeLast` the same), at 4 sends a pair. The
   common path's sends cannot rise (it is not changed), but every move to
   the middle is sends of its own, so the sends per operation over a run
   do rise; the numbers are in As built.
10. **Right.** `pti_total_user` and `pti_total_system` are Mach time
   units: a spin of 1.001 s of `getrusage` user time read 24 025 687,
   which is 1.001 s through the timebase 125/3 and 0.024 s as nanoseconds
   (`taskinfo-units.txt`, three rounds; the header says only "total
   time").
11. **Right.** `scripts/check-tier.sh --dry-run 0b33ed3` says "tier:
   swift" (with `check-tier-test`, for the comment in
   `scripts/shell-matrix.sh`).

Position 2 (the cost) is measured with part 2's flags, since the
unfiltered kernel run cannot finish with the verifiers on; it is in As
built.

The tests written before the fixes, on the starting commit:

| test | on 0b33ed3 |
|---|---|
| `aHeadlessRunReportsItsVerifierLevel` | fails (no `verify` field) |
| `aProcessTerminatedWhileItWaitsToEnterGivesNothingBack` | passes |
| `aProcessReleasedIntoTheMonitorAndTerminatedGivesItBack` | fails (excess 0) |
| `aProcessTerminatedWhileItWaitsOnTheConditionGivesNothingBack` | fails (excess 2, waiters 1) |
| `aSharedQueueServesItsLiveConsumerAfterOneIsTerminated` | fails (consumer waiting, excess 2, waiters 1) |
| `aReplyAfterItsRequestTimedOutIsDropped` | fails (`pendingReplyCount` 1) |
| `OrderedCollectionTest>>testAQueueKeepsABoundedArray` | fails (32 768 slots) |
| `OrderedCollectionTest>>testADequeAtTheFrontKeepsABoundedArray` | fails (32 768 slots) |
| `OrderedCollectionTest>>testContentsStayRightAcrossEveryRecentre` | fails (2048 slots for at most 40) |
| `DevClientTest>>testTheLogsAreBoundedAndTheirTotalsKept` | fails (1100 records) |

(`new-swift-tests-on-base.txt`, `monitor-tests-on-base.txt`,
`new-st-tests-on-base.err`.)
