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

## As built

Built by the build agent on 2026-11-20 on master from 0b33ed3, toolchain
swift.org 6.4.2 first on PATH (swiftly); Xcode's for the shells' builds.
Raw files are in `~/kajo-scratch/review-3-small-fixes/` (`part1/`,
`work/`, `broken/`, `check/`).

Commits: cc00a80 (part 1), b8e8617 (item 1), da1e867 (items 2, 3, 4 and
the stream), 8f89c19 (items 5, 6, 7), f1bc64f (the rest of item 8),
577ccd2 (the stall tests' runs unverified, Found 2), 18ad7a9 (a shell
verifies only when asked, Found 3), and the commit of this section.

### Item 1: the verifier level

`Headless.Options.verify` is `Bool?`: nil is the build's level
(`checkedBuild`, on in a debug build, off in a release build) and
`Options.verifies` says which; `configs` sets the object memory's and the
young collector's verifiers from it and no longer writes false over the
checked default. `kajo run` and `kajo test` take `--verify` and
`--no-verify`. The run line carries `verify=on|off` and the counter
`verifies` (the object memory's verifier runs), the resume line both,
`kajo test`'s `gc` summary event `"verify"` and `"verifies"`, and `kajo
test` prints `kajo test: verify=on|off verifies=N` after its summary.

Where it is off, and why: **`ShellVM`** (so every shell, `DevTarget`
and the tool tests over them) verifies only when its host sets
`options.verify`, because with the checked level on there the sanitizer
gate failed twice in a row on tool tests over a shell (Found 3); the
stall tests' `headless` helper
(`Tests/KajoVMTests/Marking/AllocationStallTests.swift`: Found 2); and
**`kajo test`** (so the `kernel-test` and
`tools-test` gates) **and `KernelTestParts`** (`runKernelTests` in
`Tests/KajoCompilerTests/KernelImageTests.swift`, the kernel's tests in
`swift test` and under the sanitizer) set it off by default, each with the
reason beside it: the kernel's tests trap with the verifiers on (Found).
Everything else that goes through `Headless` (`kajo run` without
`--protocol`, which serves through a shell, and the Swift tests that run
`Headless.run` or `Headless.test` with the default options:
`HeadlessTests`, `MainOffloadTests`, the verifier-level test) now
verifies in a debug build.
`--verify` turns `kajo test` on for anyone who wants it; the tools' 61
tests pass with it, and so does every kernel test but the seeded MakeFuzz
test.

Test: `aHeadlessRunReportsItsVerifierLevel` (the default, off and on, the
counter above zero when on). Broken variant, the overwrite put back
(`config.verify = options.verify ?? false`): the default run reports
`verifies` 0 and the test fails (`broken/verify-overwrite-and-late-reply.txt`).

The cost, over the 260 kernel tests that can run verified (every one but
`MakeFuzzTest>>testSeededMutationsAreRefusedOrRun`), five interleaved runs
a side, wall seconds of `kajo test`:

| build | tests | runs a side | off, s (median, range) | on, s (median, range) | added | verifier runs |
|---|--:|--:|--:|--:|--:|--:|
| debug | 260 | 3 | 117.9 (117.8-118.1) | 351.9 (351.7-352.1) | 2.98x | 2121 |
| release | 260 | 5 | 7.2 (7.1-7.4) | 12.3 (12.3-12.4) | 1.71x | 2121 |
| debug, ThreadSanitizer | 65 (every fourth) | 2 | 59.1 (58.0-60.3) | 128.4 (126.3-130.5) | 2.17x | 113 |

(`part1/cost-debug.txt`, `cost-release.txt`, `cost-tsan.txt`; the
binaries are the head's, `--no-verify` being the starting commit's
behaviour.) The debug runs were stopped after three rounds of five: each
round took eight minutes and the three agreed within 0.3 s a side. The
sanitizer part is every fourth test of the list, two rounds, built with
`swift build --sanitize=thread`; no sanitizer report in any run. The
verifiers do far more than the brief's "little": 3.0 times the debug run,
1.7 times the release run and 2.2 times the sanitized part. The counter
reads 2121 verifier runs over the 260 tests where the review expected
about 47 pauses from the unfiltered run's summary; which pauses make up
the difference was not read.

### Item 2: Monitor

`critical:` waits inside its `ensure:`'s protected block and sets `owner`
right after the wait (no send between, as `Mutex` since item 14); its
ensure block gives the mutex back only when this Process is the owner.
`wait` gives up the ownership with the mutex, and its wait (on the
condition and then on the mutex) is in an `ifCurtailed:`: a Process
terminated there that does not own the monitor runs `abandon:`, which
takes the monitor back (so `critical:` gives it back once), removes its
condition Semaphore from the waiters, or, when a signal already took it
out, passes that wakeup on to the next waiter. The four tests pass; the
broken variants, run by hand: the old `critical:` shape fails the
released-then-terminated test (excess 0, `broken/monitor-old-critical.txt`);
the `wait` without `ifCurtailed:` fails the condition test (a dead waiter)
and the SharedQueue test (the live consumer never woken),
`broken/monitor-no-abandon.txt`.

### Item 3: OrderedCollection

`grow` moves the elements to the middle of the same array when they fill
less than half of it, and doubles otherwise. The move is primitive 38
(which copies forwards): towards the front always, towards the end when
the ranges do not overlap, else a loop backwards; the slots left behind
are cleared by copying nils from the other side of the elements, the
start rounded so that side holds enough. Nothing in `removeFirst` or
`removeLast` changed. A queue of ten after a million `addLast:` and
`removeFirst` keeps a 32-slot array and allocates nothing (1 048 576
slots and 16.8 MB on the starting commit); `addFirst:` with `removeLast`
the same; appends only are unchanged (`part1/oc-sends-base.txt`,
`oc-sends-new2.txt`).

The bar's "sends per operation not above the base's" does **not** hold
over a run: the common path is the same 4 sends a pair, but each move is
4 sends of its own (`grow`, two `replaceFrom:`, `size`), once per 11
pairs for a queue of ten: 4.36 sends a pair against 4.00. Time, five
interleaved runs on one release kajo, with the variant that moves only
below a quarter (`work/kernel-quarter`) beside it:

| program (a million pairs) | variant | ms (median, range) | cycles (median) | sends | array | allocated |
|---|---|--:|--:|--:|--:|--:|
| queue | 0b33ed3 | 134.4 (129.9-136.7) | 423 M | 4 000 142 | 1048576 | 16 769 112 |
| queue | built (below half) | 157.5 (153.0-163.3) | 495 M | 4 363 667 | 32 | 0 |
| queue | below a quarter | 143.8 (137.1-145.4) | 452 M | 4 148 185 | 64 | 0 |
| front | 0b33ed3 | 125.1 (123.9-129.3) | 395 M | 4 000 142 | 1048576 | 16 769 112 |
| front | built (below half) | 152.0 (146.6-152.8) | 477 M | 4 363 667 | 32 | 0 |
| front | below a quarter | 136.3 (131.0-140.7) | 430 M | 4 148 185 | 64 | 0 |
| append | 0b33ed3 | 53.9 (52.7-55.5) | 172 M | 1 000 149 | 2097152 | 33 546 336 |
| append | built (below half) | 54.9 (52.7-56.6) | 172 M | 1 000 131 | 2097152 | 33 546 336 |
| append | below a quarter | 54.6 (52.0-55.9) | 171 M | 1 000 131 | 2097152 | 33 546 336 |

(`part1/oc-timing-final.txt`, five interleaved rounds, one release kajo,
`--workers 1 --slice-ms 0`; `queue` is `addLast:` with `removeFirst`,
`front` `addFirst:` with `removeLast`, both over ten held, `append` a
million `addLast:`; the array is what the program answers. No separate
base-against-base run: the ranges show the spread, under 5 percent.) The
built variant costs 17 to 22 percent more time on a queue of ten than the
leaking one; moving only below a quarter costs 7 to 9 percent with a
64-slot array, and would need the mix test's bound raised from four to
eight times the most held (open question 4). Appends are unchanged.

Tests: the three `OrderedCollectionTest` tests (a queue, a deque at the
front, a seeded mix of the four operations against an Array, checked after
every operation, the array bounded by four times the most held). Broken
variant, the old `grow`: all three fail (`broken/oc-old-grow.err`: 32 768,
32 768, and 2048 slots for at most 40).

### Item 4: DevSession

`classSelectors:side:` builds the organization once; `selectorsInCategory:`
selects one category's selectors instead of building the organization;
`handleOf:` finds a handle in `objectHandles`, an IdentityDictionary kept
with `handles` under the same lock and emptied with it at `inspect.release`
(and dropped with the session); `classHierarchy` sorts the classes by name
before it builds their objects; `classList:tag:` asks `tagOf:` once. Sends
(`part1/devsession-sends.txt`, release, one run each, sends are exact):
`classSelectors: 'Object'` 100 times 6 977 725 before, 653 632 after;
2000 handles made and each looked up ten times 84 235 385 before, 394 732
after. No new test: `DevelopmentTest` and `RegistryTest` cover handles and
pass.

### Item 5: one transcript sink

`transcriptText(ofLine:)` in `Sources/KajoVM/Shell/TranscriptLine.swift`
(a Release app needs it, and every caller already imports `KajoVM`)
compares the line's start with `{"v":1,"kind":"transcript",` and parses
only a line that matches; the seven sinks (`Application.swift`,
`App.swift`, `Scenario.swift`, two in `DevModes.swift`, two in
`main.swift`) call it. Test: `theTranscriptSinkReadsOnlyTranscriptLines`.
Not measured: the review's per-line cost on `mode=devsession classes=2000`
(no counter was added; the brief did not ask for one).

### Item 6: UIKit's appendLine

Appends `"\n" + line` to `textStorage` with the view's `font` and
`textColor` (what setting the whole text applied), sets the text for the
first line, and scrolls to the storage's length. A first version read the
last character's attributes, an API Xcode's toolchain calls unsafe; the
iOS shell's build warned and it was replaced before any commit. Checked by
building both shells (0 errors, 0 warnings, `work/apps-dd-ios2.log`) and
by reading. Not run on a device or a simulator: the main session's tests
mode run on the iPhone is the check.

### Item 7: late replies and DevClient's logs

`ProtocolClient` keeps the ids `send` waits for; a reply for any other id
is dropped and counted (`lateReplies`), and a send that ends for any
reason removes its id and anything stored under it. Test:
`aReplyAfterItsRequestTimedOutIsDropped`; broken variant (every reply
kept): `pendingReplyCount` 1 and `lateReplies` 0
(`broken/verify-overwrite-and-late-reply.txt`).

`DevClient` keeps the last `DevClient class>>logBound` (1024) records of
`latencies` and of `outages`, with `replyCount`, `repliesOf:` (per label,
the retried ones under `kind (retried)` as `latencies` names them),
`latenciesDropped`, `outageCount` and `outagesDropped`. Three readers used
`latencies size` as a count of replies and would have stopped counting at
the bound: `DevSessionBench` (populate, the step, the reconnect's frames)
and `ToolsProbe` read the counts now, and the bench's done line adds
`latenciesDropped` and `outagesDropped`. Test:
`DevClientTest>>testTheLogsAreBoundedAndTheirTotalsKept`.

### Item 8: the rest

`processTask()` multiplies by the Mach timebase (part 1, position 10).
`PositionableStream>>contents` has one branch. The comment of
`scripts/shell-matrix.sh` names `drift` first, as line 36 does.

### Gates

`just check 0b33ed3` on 18ad7a9, the final code commit, into
`~/kajo-scratch/review-3-small-fixes/check/` (tier swift, 8 gates; toolchain
swift.org 6.4.2 on every line). Last line: `2026-11-20 17:27:17 18ad7a9
check-tier done swift failed=1 4874s`.

| gate | 18ad7a9 | ec0a6ef |
|---|--:|--:|
| check-tier-test | rc=0, 6 s (107 checks) | not run |
| clean-build | rc=0, 20 s | 20 s |
| swift-test | rc=0, 703 s (471 and 192 tests) | 714 s |
| tsan | **rc=1**, 3416 s | 3490 s |
| kernel-test | rc=0, 130 s (261 tests, `verify=off`) | 120 s |
| apps | rc=0, 143 s (0 errors, 0 warnings both) | 129 s |
| new-check | rc=0, 287 s | 267 s |
| fuzz (protocol, 120 s) | rc=0, 169 s (build=ok, 347 726 runs) | |

The `tsan` gate failed on one test that is not this module's,
`theToolsReconnectAfterADroppedLink` (`PhoneTransportTests.swift:296`,
`reconnected never held`; the remote client open again, nothing pending,
both requests retried and answered, `listed true hierarchy true`, so the
probe's last clause, the debugger's frames fetched again, did not hold in
60 s). Its history in this module: it failed the same way in the first
complete tier run (577ccd2, `check-second-run/tsan.txt`, then with two
requests pending and none retried), passed the gate run once more
(`check-second-run/tsan-rerun/`, which failed
`theToolsDevelopTheImageTheyRunIn` instead), and fails again here, with
the shells' verifiers off. Alone under the sanitizer it passes 5 of 5 on
the head (109 to 111 s, `check-second-run/reconnect-alone.txt`) and 3 of
3 on the starting commit in the same 111 s (`work/reconnect-base.txt`),
so the module did not make it slower alone; in the suite it took 85 to 94
s on ec0a6ef and in the 2026-11-16 weekly, and never failed there. The
condition that makes it fail in the suite was not found, and no wait was
lengthened. Every other gate passed; ThreadSanitizer reported nothing.

### Deviations

- The bar's item 6 is not met: the `tsan` gate failed on
  `theToolsReconnectAfterADroppedLink` (Gates, above; Found 4).
- The bar's item 2 is met by its second half: `kajo test` in a debug
  build says `verify=off`, not `on`, because with the verifiers on the
  kernel's tests trap (Found). The level itself is on by default in a
  checked build everywhere else that goes through `Headless`.
- The bar's item 4 holds for the array, not for the sends: 4.36 sends a
  pair against 4.00 and 17 to 22 percent more time on a queue of ten
  (item 3's table). The common path is unchanged; the moves cost.
- The debug cost runs are three rounds a side, not five, and the
  sanitizer part two (the spread was 0.3 s and 4 s).
- Part 1's position 2 was measured after part 2 existed, with its flags;
  `--no-verify` is the starting commit's behaviour.
- The third Monitor fault (a terminated waiter keeps its condition
  Semaphore queued and eats the next signal) was not in the brief; it is
  fixed with the other two, since `SharedQueue` under termination does
  not work without it.
- Item 4 also changed `Behavior>>selectorsInCategory:` (the finding's
  proposal) and `classList:tag:` (asks `tagOf:` once).

### Not done

- Item 6 was not run on a device or a simulator.
- The Swift tier's gates did not all pass (Found 4).
- Item 5's per-line cost (the review's counters around the hook) was not
  instrumented or measured.
- The verifiers stay off in `kajo test`, `KernelTestParts`, `ShellVM`
  and the stall tests' runs until the found faults are fixed or
  understood (a core change, part 2 or its own follow-up).

### Found, not this module's

1. **The make primitive's methods name young objects unremembered.**
   With the heap verifiers on, `MakeFuzzTest>>testSeededMutationsAreRefusedOrRun`
   followed by any scavenge traps the object memory's verifier: `nursery
   verifier, before scavenge N: entry E (old) names young @Y (nursery 1)
   in slot S, and is not remembered for it` (10 entries listed), 5 runs
   of 5 in the unfiltered debug run at scavenge 720, and also under
   `--young stw` (scavenge 905, inside the MakeFuzz test). Started from
   test 130 of the run's order, the same pair gives `after scavenge 1:
   entry 28490 slot 1 names @88622, a freed entry`: young objects were
   freed while old objects still named them. The suspect, read but not
   checked line by line: primitive 143 makes its methods in old space
   (`LiveMethodHeap`), and a literal that is "any other object"
   (`CodeReader.literal`'s `.object(v)`) is stored as it is, so a young
   object in a mutated literal frame is never remembered
   (`Sources/KajoVM/ObjectModel/LiveMethods.swift`). The fuzz test makes
   such literals on purpose; whether the compiler can (a young Binding
   of a class variable just added, say) was not read. Raw:
   `part1/verify-debug-*.err`, `found-*.err`, `found-summary.txt`,
   `found-bisect.txt`. A core change; the verifiers in `kajo test` and
   `KernelTestParts` go on again with its fix.
2. **A cross-nursery young reference unremembered under the offloaded
   collector.** The first gate run (f1bc64f, `check-first-run/`), with
   the checked level on in every `Headless` run, died in `swift-test` in
   `aFullHeapFallsBackJustifiedThenRunsOutOfMemory` (its `young=offload`
   half, through the stall tests' `headless` helper): `nursery verifier,
   after scavenge 17: entry 148628 (young in 1) names young @148629
   (nursery 0) in slot 0, and is not remembered for it; entry 149172
   (young in 0) names young @149173 (nursery 1) ...`. The trap ended the
   whole VM test bundle. Run alone it passed with the verifiers on
   (`part1/found2-fullheap-alone.txt`, 738 s): 1 of 2, under the suite's
   load only; not repeated further (each run is twelve minutes). Not
   diagnosed; a core question. The helper verifies nothing now, as before
   this module.
3. **Tool tests over a shell failed the sanitizer gate with the
   verifiers on in every debug `ShellVM`.** First gate run on 577ccd2
   (`check-second-run/tsan.txt`): `theToolsReconnectAfterADroppedLink`
   (`reconnected never held ... pending 2 reconnects 1 retried 0
   outages #(#(48298884 0))`: a 48 s outage against the requests' 30 s
   timeout); alone under the sanitizer it passed 5 of 5 in 109 to 111 s
   (`check-second-run/reconnect-alone.txt`; it took 85 to 94 s in the
   suite on ec0a6ef and the weekly). The tsan gate run once more
   (`check-second-run/tsan-rerun/`) passed that test (115 s) and failed
   `theToolsDevelopTheImageTheyRunIn` instead (`compiledTypedThroughTheBrowser
   never held`, the probe's `Smalltalk sourceOf:` answering nil while the
   browser said compiled). Neither failed on ec0a6ef or in the 2026-11-16
   weekly. The cause was not found; the shells' level went back to off
   (18ad7a9) and the tier ran again. Whether the
   verifiers' time alone makes these tests' timing thin, or a fault shows,
   is open.
4. **`theToolsReconnectAfterADroppedLink` fails in the sanitizer suite.**
   Two of the three sanitizer gate runs of this module failed it (the
   third failed another tool test, Found 3); alone it passes on the head
   and on the starting commit alike, in 111 s. Not seen before this
   module. Whether a change of this module makes it fail in the suite
   (the kernel's `Monitor` and `OrderedCollection` run in the tools' event
   loop; `DevClient` counts replies now) or the suite's load alone does is
   open.
5. The verifiers cost 1.7 to 3 times the kernel tests' run (item 1's
   table), not "little": turning them on in the gates is a gate-time
   decision of its own.

### Open questions

Built as recommended where there was a recommendation; decisions only.

1. Do the kernel-test gates run with the heap verifiers on in checked
   builds? Built: off in `kajo test` and `KernelTestParts`, because they
   trap (Found 1), off in the stall tests' runs (Found 2) and in every
   `ShellVM` unless its host asks (Found 3); on in the rest of a checked
   build's `Headless` runs. Part 1 measured
   2.2 times on the sanitized part, far past the tenth the recommendation
   allowed. Recommendation: after Found 1 is fixed, verify the kernel
   tests in the release-build gate (`test-release`, 1.7 times of seconds)
   and keep the debug and sanitizer kernel runs off.
2. Does a release `kajo test` verify? Built as recommended: no; `--verify`
   turns it on.
3. The bound of `DevClient`'s logs. Built as recommended: the last 1024
   of each.
4. `OrderedCollection`: move below half (built, the brief's shape: a
   queue of ten in 32 slots, 17 to 22 percent slower than the leaking
   base) or below a quarter (64 slots, 7 to 9 percent)? Recommendation:
   keep half; the bound is the point and the cost is a few hundred
   nanoseconds per move.
5. The sanitizer gate's reconnect test (Found 4): record the module with
   the gate failed, or hold it until the test's condition is found?
   Recommendation: hold it; a test that never failed before failed twice
   in this module's runs.
