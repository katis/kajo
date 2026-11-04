# Follow-up: the promotion reserve's fallback and the parser's depth

Status: built, 2026-11-04, from the brief written the same day from two
findings (module 9a's open question 3, answered by the owner: fix it;
module 8d's open question 4). Two parts, each with its tests. Code in
`Sources/KajoVM/Nursery/` (`Scavenge.swift`'s kept objects and
`placeKept`, `YoungAllocation.swift`'s full collection and promote-all
hook), `Sources/KajoVM/ObjectMemory/` (collect and compact around young
objects, `reservePromotion`), `Sources/KajoVM/YoungCollection/`
(`openYoungCollection`'s promise, `collectOwnNursery`'s stop),
`Sources/KajoCompiler/` (`Compiler.chain`, `SendNode`'s teardown, the
limit) and `Sources/fuzz-syntax/main.swift`. Tests in
`Tests/KajoVMTests/Nursery/ReserveTests.swift`, two random-program
configurations, `Tests/KajoCompilerTests/StackDepthTests.swift` and a
changed `CompilerTests` case.

## What it hides

- What happens when promotion finds no block: in a stop-the-world
  scavenge, in a young collection beside the mutators, in a promote-all
  before an old-space operation, and what a full collection does about an
  old space that a mark-sweep cannot bring under its soft limit.
- How far the bootstrap compiler recurses, on what input, and what stack
  that takes; how a message chain of any length is compiled without it.

## 1. The promotion reserve

### Why the oracle ran out on the ring

The ring (`apps/Shared/smalltalk/ShellBench.class.st`, module 7's
`fragment` bounded) promotes almost everything it allocates that lives:
each node lives 32 768 iterations, longer than a nursery holds it, and
dies in old space; one evicted node in twenty is kept in a keep ring of
65 536, so every old block keeps about a dozen live nodes among some 270
dead ones. At 600 MiB with seven workers the stop-the-world mode promotes
about 1 GB/s (11.8 GB in a run, 11.6 of it survivor overflow). Concurrent
marking and relocation keep up in the local and offloaded modes (80
cycles a run, 816 MB moved); in the stop-the-world mode the marker falls
behind (42 cycles, 536 MB) and old space crosses its soft limit 12 times a
run, 8 times with marking idle and 4 with a cycle unfinished (module 5's
fallbacks). Each time module 4 requests a full collection, and that was a
mark-sweep, which frees a block only when nothing in it lives: on the
ring it freed almost nothing, old space stayed past the soft limit, every
scavenge after it requested another full collection, and while one is due
no marking cycle starts, so nothing relocated either. Every scavenge then
promoted up to the nurseries' contents into the reserve, which holds about
twice that, and the third or so found no block.

**The sizing rule was not wrong, the full collection was, and the trap
was the wrong fallback.** Twice the nurseries (plus a third for block
tails and two blocks per participant) covers a scavenge past the soft
limit and the promote-all of the full collection it requests, as module 4
argued, on the condition that the full collection brings old space back
under the limit. A mark-sweep does not on a fragmented old space; module
1's compaction does. The headless reproduction is `fragment` with eight
workers at `--heap 240 --young stw`, which trapped in every collector
mode at the starting commit (16 full collections, then 10 687 of 10 687
blocks in use against a soft limit of 7 680) and runs to its checksum now
in all three with 4 to 11 compactions.

### What was built

Three rules, each in the module that owns the resource:

1. **A full collection compacts when its mark-sweep leaves old space past
   the soft limit** (`fullCollection`, module 4's; counted in
   `fullCompactions`). The soft limit's accounting is module 4's as
   before: a scavenge that leaves old space past it sets `fullRequested`,
   the next poll (or the next scavenge request, upgraded) runs the full
   collection in a stop of its own.
2. **A stop-the-world scavenge whose promotion finds no block keeps the
   object young in place** (`Scavenger.evacuate`, `keep`, `placeKept`).
   The winner takes the promotion body *before* its claim is published:
   when the bump answers nil it claims with a kept header instead (young,
   its own nursery, its age, this scavenge's tag), so every other
   participant, the entry sweep and the weak pass read it as a survivor,
   and none ever reads "old" for an object that stays young (a loser that
   bumped gives the body back, `unbumpPromotion`). From the first failure
   the participant keeps without asking the pool again. After the join the
   stopper places the kept bodies, which lie in space that is free now: a
   nursery's kept bodies in the eden half being allocated in slide down to
   its start in address order (each destination at or below its source,
   as module 1's compaction); the rest follow in that eden, then in the
   free tail of the nursery's new survivor-from. Both are what every
   collector reads as young (module 7's Y is the eden part and
   survivor-from), and the kept entries join the nursery's survivor log,
   the next entry sweep's input. A body that fits nowhere in its nursery
   goes to another's eden or tail with that nursery's index, and every
   holder remembered for the first nursery is remembered for the second
   too (a superset is sound). The kept bodies sum to no more than the
   young bytes that neither survived nor were promoted, so the nurseries
   hold them; a body that still fits nowhere is a broken invariant (a
   precondition, not a provisioning failure). The scavenge requests the
   full collection and counts `exhaustedScavenges`, `keptObjects`,
   `keptBytes`, `keptAcross`; module 1's `reserveExhaustions` counts the
   refills that found no block. The verifier after the scavenge knows the
   kept entries: young in eden or survivor-from, tagged, logged, any age,
   and the eden from its start holds only kept bodies.
3. **A young collection beside the mutators opens only with its promotion
   room promised** (`openYoungCollection`, `ObjectMemory.reservePromotion`):
   everything in Y may be promoted, into blocks that each lose less than
   a large object to their tail, so it asks for `ceil(Y / (block - large
   limit)) + 1` blocks out of those no mutator may take (past the larger
   of the soft limit and the blocks in use) that no collection in flight
   was promised, under the pools lock, and gives them back when it ends.
   Promised blocks stay counted once taken (conservative, never short).
   Refused, it opens nothing and the owner stops the world for module 4's
   scavenge instead (`scavengeForReserve`, counted as the young fallback
   `reserve`), which keeps what finds no block. A young collection cannot
   keep objects in place (mutators read them meanwhile and its eden is
   reused after its epoch), so the promise is its rule, and its own
   promotion that finds no block is now a broken invariant.

Around them:

- **Old-space operations with kept objects.** The promote-all hook
  (`promoteAllForOldSpace`) answers the young objects it could not
  promote. When there are some it collects old space around them (they
  are roots; module 1's sweep leaves young entries to their nursery and
  sweeps the rest), compacts when that leaves old space past its soft
  limit, and promotes again (`reclaimsAroundYoung`). `collect` and
  `compact` take what is still young as roots; `become` (both), `reshape`
  and `snapshot` refuse (`BecomeError.heapFull`, `ReshapeError.heapFull`,
  the save primitive fails, the host's `snapshot()` traps with "old space
  cannot take every young object": a heap full of live data). After every
  sweep of old space the carried lists drop holders the sweep freed and
  their remembered words are cleared (`dropFreedHolders`), before their
  entries can be reused: only kept objects leave holders listed across a
  full collection.
- **Out of memory is the program's failure, not a loop.** An eden whose
  top is still the kept objects' end after a collection and too full for
  the allocation holds nothing else; the second such collection was the
  full collection the first requested, and the allocation fails with
  `outOfMemory` (`allocateYoungSlow`, `NurseryAlloc.keptEnd`).
- **Reported**: `kajo run` and the shells' telemetry (`gc_` keys) print
  `fullCompactions`, `reserveExhaustions`, `exhaustedScavenges`,
  `keptObjects`, `keptMB`, `keptAcross`, `reclaimsAroundYoung` and
  `fallbackReserve`.

No new cross-thread protocol: the kept header is the claim compare-and-swap
module 4 already has, written with a different value before the same
publication; placement, the reclaim and the holder cleanup run with the
world stopped; the promise is a counter under the pools lock, read and
written by openers and finishers, with no ordering beyond that lock's (as
module 9a's registration). The young-collection model is unchanged.

### Measurements

The ring at 600 MiB in the macOS shell, three runs of each mode
interleaved (`scripts/mac-shell.sh run`, seven background workers, 10 s
after 1 s, the display awake by the shell's assertion, thermal nominal;
the table in `docs/modules/shells.md` with its footnote):

| young | missed of 1200 | max gap ms | stopped for others ms/10 s | full collections (compacting) | full max ms | exhaustions | load failures |
|---|--:|--:|--:|--:|--:|--:|--:|
| stw | 143 [139–146] | 251.1 [246.2–256.0] | 1381.1 [1266.2–1826.6] | 12 (3) each run | 243.8, 244.5, 254.0 | 0, 0, 0 | 0 |
| local | 0 | 8.4 | 148.4 [126.9–152.9] | 0 | - | 0 | 0 |
| offload | 0 | 8.4 | 152.8 [151.9–172.1] | 0 | - | 0 | 0 |

The oracle runs to its end in every run; the frames it misses are the
compacting full collections' pauses on the main thread, not a trap, and
no scavenge ran out of blocks (the compaction keeps old space under its
soft limit, so the reserve is never reached). The starting commit traps in
every run at 600 MiB; at 1024 MiB it missed 6 frames.

`fragment` with eight workers at 240 MiB (`kajo run prelude lib fragment
fragmentIters8 --workers 8 --heap 240 --slice-ms 0`): the checksum
17698143198236 in every mode with 4 (stw), 11 (stw with `--gc stw`), 5
(local) and 4 (offload) compactions; the starting commit traps in all.

The A/B against the starting commit is below (Hot path).

### Tests

- `promotionPastTheReserveKeepsObjectsYoungAndTheProgramFinishes` (every
  young mode, a reserve of 0 and of 4 blocks): four workers each keep a
  ring of 1024 Pairs that live about three edens and die in old space,
  24 KiB nurseries, a heap of the image plus 24 blocks, concurrent marking
  off (its lazy sweep keeps this load under the soft limit); the answers
  are the rings' sums. With no reserve every scavenge that crosses the
  heap's end keeps objects: 7 or 8 exhausted scavenges, 2 000 to 6 600
  kept objects, 3 or 4 reclaims around young objects per run, every young
  collection refused and stopped for (about 170); with 4 blocks about 530
  young collections run beside the mutators and about 65 are refused, and
  nothing is exhausted. Every verifier runs (the young verifier every
  fourth collection), and the run report carries the counters.
- `aFullCollectionCompactsAFragmentedOldSpace`: forty holders of 1000
  Pairs, every 64th kept in a chain and the holders dropped, so the
  survivors are scattered over every block; a full collection under the
  soft limit only sweeps, one with the soft limit lowered below the
  blocks in use compacts and ends below half of them.
- The random programs: `exhaustedReserve` (stop-the-world young) and
  `exhaustedReserveLocal` (local young collection) run every seed on a
  heap of three blocks (the image takes one) with no promotion reserve,
  no concurrent marking, 24 KiB nurseries that promote everything, four
  workers, every verifier; the configuration must see exhausted scavenges,
  and every answer is the model's (100 seeds in `swift test`, 1000 in
  `just soak`). **The soak did not reach exhaustion before**: no earlier
  configuration's heap fills (the trap would have fired), so the two
  configurations are added to its matrix.

### Broken variants run by hand

Each on the code of 7c9cc94, by hand (a trap cannot live in the suite):

| variant | run | result |
|---|---|---|
| the kept object's claim publishes the promote header (old) | `promotionPastTheReserve...` | trap: `KajoVM/RawArray.swift:48: Precondition failed` (a participant reads "old" for a body that never moved) |
| a young collection opens with nothing promised | `promotionPastTheReserve...` | trap: `Collect.swift:355: Fatal error: kajo: a young collection found no promotion block although its room was promised` |
| a full collection never compacts | `fragment` at 240 MiB, eight workers, each mode | the checksum in every mode, 52 to 59 full collections, 3 to 6 exhaustions keeping 283 000 to 413 000 objects, 2 or 3 reclaims around them (which compact): the fallback alone carries the ring's case, at the cost of the kept objects' scavenges |
| freed holders stay in the carried lists (`dropFreedHolders` off) | `promotionPastTheReserve...` and both exhausted random configurations, 100 seeds | no failure: a holder whose entry is freed and reused is still scanned by its index at the next scavenge. Kept for module 4's strict remembered-set check, which names a freed entry in a list; no test reaches a dead holder of a kept object |

## 2. The parser's depth

### Measured

The stack the bootstrap compiler uses (parse, analysis, code generation,
assembly, teardown), measured by painting an 8 MB thread's stack below
the caller and finding the deepest byte written
(`stackPerLevelOfNesting`, `KAJO_STACK_PROBE=1`), bytes per level of
nesting between 16 and 256 levels at the starting commit and between 16
and 32 now:

| construct | debug, start | release, start | debug, now | release, now |
|---|--:|--:|--:|--:|
| parentheses `((1))` | 4 015 | 848 | 4 048 | 848 |
| blocks `[[1]]` | 9 347 | 1 608 | 9 488 | 1 632 |
| cascades `((1 foo; bar) foo; bar)` | 6 912 | 799 | 7 056 | 848 |
| keyword arguments `1 k: (1 k: (1))` | 7 184 | 1 328 | 7 200 | 1 328 |
| assignments `a := a := 1` | 6 928 | 373 | 7 056 | 413 |
| literal arrays `#(())` | 3 674 | 767 | 3 680 | 816 |
| brace arrays `{{}}` | 6 929 | 844 | 7 056 | 848 |
| parenthesized keyword chain `((x k: 1) k: 1)` | 6 928 | 848 | 4 048 | 848 |
| binary chain `x + 1 + 1` | 6 928 | 374 | 0 (to 10 000) | 0 (to 10 000) |
| unary chain `x yourself yourself` | 6 913 | 348 | 0 (to 10 000) | 0 (to 10 000) |

The debug build's frames are four to eighteen times the release build's
(the parser alone takes 8.7 KB per block level in debug: `parsePrimary`,
`parseBlock`, `parseStatements`, `parseExpression`, `parseCascade`,
`parseMessages` each keep every local of every case). A chain cost 6.9 KB
a link in debug, so a 512 KB thread overflowed at about 70 links, as 8d
found; at 256 nested blocks a debug build needs 2.4 MB and a release
build 428 KB.

### What was built

- **Chains are loops.** The parser already built a chain in a loop; the
  analysis and code generation now walk it in one too (`Compiler.chain`:
  the sends of the chain innermost first and the node they start from,
  stopping at a super send or an inlined one), in the order the recursion
  had (receiver, then each send's arguments), and `SendNode` releases a
  chain one link at a time (`deinit`), since a long chain's nested
  deinits overflow too. The parser no longer limits chains (8d's
  `chainLength` is gone): a chain is bounded only by the method's 32 760
  bytes of bytecode, as in the compiler in Smalltalk, which never limited
  them. The emitted code is unchanged (`CompilerTest`'s comparison of
  every kernel method holds).
- **The nesting limit is 32 in both compilers** (`Parser.maxDepth`,
  `kernel/Parser.class.st`; ADR 0009's Built (8d) note): brackets, blocks,
  brace and literal arrays and assignments, where recursion is the
  natural shape. At 32 the deepest input takes 327 KB in a debug build
  (blocks; a margin of 1.6 on 512 KB) and 62 KB in release (a margin of
  8). The kernel nests 8 deep at most (770 methods at 0, 433 at 1, one at
  8), and the make primitive already refused blocks nested past 64.
- **The syntax fuzzer runs every input on a 512 KB thread**
  (`Sources/fuzz-syntax/main.swift`): one thread of that size for the
  whole run, handed one input at a time (a thread per input ran a third
  as many inputs); `KAJO_FUZZ_STACK_KB` sets another size, 0 the calling
  thread. The libFuzzer build is release with AddressSanitizer.

### Tests

- `theDeepestInputCompilesOnA512KBThread` (ten constructs): on a `Thread`
  with `stackSize` 512 KB, the deepest input each construct allows
  compiles (32 levels; chains of 10 000) and one level more is refused;
  in debug (`swift test`) and release (`just test-release`).
- `stackPerLevelOfNesting` (ten constructs): the measurement above, and
  the deepest input fits 512 KB with a margin of four in an optimized
  build and of 1.25 in a debug one.
- `aMessageChainOfAnyLengthCompiles` (8d's
  `aMessageChainPastTheNestingLimitIsRefused` turned round): a binary
  chain of 5000 compiles to 5000 `add`s in order, a unary chain of 300,
  a mixed chain binds unary first, and the fuzzer's
  `crash-long-binary-chain.st` compiles and runs.

## Changes to earlier modules

- Module 1: `prepareOldSpaceOperation` answers the young objects left;
  `collectOldSpace` and `compactOldSpace` (the operations without the
  hook); the sweep leaves young entries alone; compaction's pin scan skips
  young bodies; the after-sweep hook; `become`, `reshape` and `snapshot`
  refuse with young objects left (`trySnapshot` for the save primitive);
  `unbumpPromotion`, `reservePromotion`, `releasePromotion`.
- Module 4: the kept claim, `placeKept`, the full collection's compaction,
  the promote-all hook's reclaim, `dropFreedHolders`, the out-of-memory
  rule, the counters and the verifier's kept entries; the test switch
  `promotionReserveBlocks` (a reserve of that many blocks, the soft limit
  the rest of the heap).
- Module 7: the promise at the opening and its refusal, the young
  fallback `reserve`; a young collection's promotion that finds no block
  is a broken invariant.
- Module 8b/8d: the chain walk, the limit, the fuzz driver.
- Module 9a: `scripts/shell-matrix.sh` runs the ring at 600 MiB in every
  mode; `docs/modules/shells.md`'s ring rows and footnote.

## Deviations from the brief

- **The recovery is all three of the brief's options, each where it
  applies**, not one: the full collection compacts (it, not the reserve,
  was what failed), the stop-the-world scavenge keeps objects in place,
  and the concurrent young collection is promised its room or stops the
  world. Keeping in place is the only one a scavenge can do in its own
  stop without old space, and a young collection beside mutators cannot
  keep in place at all.
- **The nesting limit went down as well as chains becoming loops**, to 32,
  not kept at 256: brackets and blocks cost 4 to 9.5 KB a level in a
  debug build, so 256 needs 1 to 2.4 MB; the brief expected the limit to
  hold once chains were loops. A margin of four in debug would need a
  limit of about 11; 32 keeps four in release and 1.6 in debug.
- **The ring's missed frames are not 0**: 143 of 1200 at 600 MiB, behind
  three compacting full collections of about 250 ms per run. None is a
  trap; the oracle's full collections are the cost.
- **`ReserveTests` turns concurrent marking off**: with it the lazy sweep
  keeps that load under its soft limit and the reserve is never reached.
  The ring in the shell is the case with marking on.
- **The A/B ran the kasm kernels only** (and `survivors`, the promotion
  path): the Smalltalk kernels' bytecodes are unchanged and part 2 does
  not touch the VM.

## Unsafe surface

`unsafe` in `Sources/KajoVM`: 4687 at the start, 4788 now (+112 added,
-11 removed: the kept claim and its placement, the reserve's promise, the
reclaim and holder cleanup, counters through pointers);
`Sources/fuzz-syntax`: 1 to 9 (the 512 KB thread: `pthread_attr`,
`pthread_create` with an `Unmanaged` argument, `getenv`). None in
`KajoCompiler`. Counted with `git grep -o '\bunsafe\b'` over the sources
(comments included); the clean build has 0 warnings (Gates).

## Hot path

- **The promotion path**: the winner bumps before its claim instead of
  after (`Scavenger.evacuate` grew from 266 to 312 instructions in the
  aligned `-enable-testing` build), a lost claim gives the body back with
  one store, and the fallback is one out-of-line call (`keep`, 92
  instructions, no retain or release); `placeKept` runs only after a
  scavenge that kept something. `drain` reads the survivor's nursery from
  its header (the same 252 instructions). `just arc-check` passes (Gates).
- **`interpret`** is the same code in both aligned binaries: 1320
  instructions, 4 lines differing only in addresses.
- **The A/B** against the starting commit (`kajo` from a worktree at
  d5a644a and from 7c9cc94, both `-c release -Xswiftc -enable-testing`
  with `-align-all-nofallthru-blocks=5 -align-loops=32`, five runs
  interleaved with the order alternating, `--slice-ms 0`; median (min to
  max) ms; every checksum the same on both sides):

| kernel | workers | d5a644a ms | now ms | now / start | checksum |
|---|--:|--:|--:|--:|---|
| fib | 1 | 1691.5 (1687 to 1697) | 1698.1 (1687 to 1709) | **1.004** | 24682992 |
| fib | 8 | 224.7 (217 to 232) | 231.5 (217 to 244) | **1.030** | 24682992 |
| arith | 1 | 2535.7 (2527 to 2538) | 2551.9 (2518 to 2561) | **1.006** | 372800000 |
| arith | 8 | 341.7 (337 to 352) | 349.7 (338 to 357) | **1.023** | 372800000 |
| sends | 1 | 2574.8 (2558 to 2583) | 2568.1 (2556 to 2587) | **0.997** | 1066666666666668 |
| sends | 8 | 339.9 (331 to 355) | 351.1 (335 to 356) | **1.033** | 133333335000001 |
| ivars | 1 | 1964.3 (1960 to 1976) | 1964.7 (1960 to 1975) | **1.000** | 36383626 |
| ivars | 8 | 264.7 (253 to 272) | 271.8 (253 to 282) | **1.027** | 71714128 |
| storeheavy | 1 | 2397.6 (2396 to 2413) | 2406.6 (2385 to 2413) | **1.004** | 512000 |
| storeheavy | 8 | 320.8 (309 to 341) | 319.0 (310 to 322) | **0.994** | 512000 |
| alloc | 1 | 2938.4 (2928 to 2946) | 2929.4 (2916 to 2940) | **0.997** | 41950911 |
| alloc | 8 | 485.0 (463 to 497) | 459.0 (434 to 480) | **0.946** | 42008248 |
| survivors (30 percent) | 1 | 1950.6 (1944 to 1956) | 1968.6 (1946 to 2010) | **1.009** | 38399861600000 |
| survivors (30 percent) | 8 | 308.5 (289 to 320) | 308.2 (294 to 342) | **0.999** | 4799861600000 |

  One worker 0.997 to 1.009, eight workers 0.946 to 1.033 both ways,
  every pair of ranges overlapping: within noise. The kernels that
  promote (`alloc`, `survivors`) are not slower.

## Not done

- The debug build's parser frames (8.7 KB per block level) are not made
  smaller; a limit of 32 is what they leave room for.
- No device run of the ring (the iPhone is not signed in, module 9a).
- `ReserveTests` and the exhausted random configurations run with
  concurrent marking off; exhaustion with marking on is reached only by a
  heap the marker cannot keep under its soft limit, which no test builds.
- The refusals of `become`, `reshape` and the save primitive with young
  objects left (a heap full of live data) have no test, nor has a kept
  object placed in another nursery (`keptAcross` was 0 in every run).

## Open questions for the owner

1. The oracle's ring at 600 MiB misses 143 frames to compacting full
   collections of about 250 ms. Acceptable for the oracle, or should
   module 5's trigger start marking earlier in the stop-the-world mode
   (it falls behind: 42 cycles against 80)? **Owner (2026-11-04):
   acceptable.**
2. The nesting limit is 32 (debug margin 1.6, release 8). Keep it, lower
   it to about 11 for a margin of four in debug, or spend the work to make
   the parser's debug frames smaller and raise it again? **Owner
   (2026-11-04): keep 32.**

## Gates

Run by one script on bdf161b (the commit before this table), Mac mini M2
Pro, swift.org Swift 6.4.2 first on PATH, Xcode 27.2 for the apps,
2026-11-04 10:06 to 11:43; full output in files, the commit each gate ran
on logged. "Load" is twelve `gtimeout 1500 yes` busy loops (the
ThreadSanitizer run under load took 1672 s, so its last three minutes ran
without them).

| gate | result |
|---|---|
| clean build (`swift build --scratch-path .build/clean-check`) | pass: 0 warnings |
| `swift test` | pass: 312 tests (KajoVMTests) and 48 in 6 suites (KajoCompilerTests) |
| `swift test` under load | pass: 312 and 48 |
| `swift test --sanitize=thread` | pass: 312 and 48, 0 ThreadSanitizer reports |
| the same under load | pass: 312 and 48, 0 ThreadSanitizer reports |
| `just ios-check` | pass |
| `just arc-check` | pass: no retain or release on the checked paths, one jump table |
| `just golden` | pass: 9 kasm and 3 Smalltalk kernels, every checksum |
| `just test-release` | pass: 312 and 48 |
| `just model-check` | pass: 15 tests in 4 suites |
| `just soak` | pass: 1000 seeds under every configuration (the two exhausted ones included), every resumed mode, failing none |
| `just fuzz kasm 600` | pass: libFuzzer build ok, 2 539 265 runs, no crash |
| `just fuzz snapshot 600` | pass: libFuzzer build ok, 3 634 450 runs, no crash |
| `just fuzz syntax 600` | pass: libFuzzer build ok, every input on a 512 KB thread, 1 319 335 runs, no crash |
| `just apps` | pass: macOS and iOS, 0 errors, 0 warnings |

A first run on 3322e50 stopped at `swift test`: `oneReadyProcessRoundTrips`
(module 8c) found the counter missing from the saved image. The test took
164 s in the full suite (109 s in a passing run before this work, 0.05 s
alone): on a busy machine the saver's thread was descheduled while the
counter yielded to its end, so the save caught the saver alone. The test
now repeats its round, at most five times, until the save catches the
counter still ready (bdf161b), and every gate ran again from the start.

## Commands

```zsh
# the ring at 600 MiB, three runs of each mode interleaved
just mac-shell build
for run in 1 2 3; do for y in stw local offload; do
  scripts/mac-shell.sh run $OUT/scenarios.txt mode=scenario scenario=ring young=$y workers=7 seconds=10 run=$run
done; done
python3 scripts/shell-report.py $OUT
# fragment at 240 MiB, every mode
for y in stw local offload; do .build/release/kajo run prelude.kasm lib.kasm fragment.kasm fragmentIters8.kasm \
  --workers 8 --heap 240 --young $y --slice-ms 0; done   # in Tests/KajoVMTests/Fixtures/kernels
# stack per level of nesting
KAJO_STACK_PROBE=1 swift test --filter stackPerLevelOfNesting
KAJO_STACK_PROBE=1 swift test -c release -Xswiftc -enable-testing --scratch-path .build/release-tests --filter stackPerLevelOfNesting
# the reserve's tests and the exhausted random programs
KAJO_RESERVE_DEBUG=1 swift test --filter promotionPastTheReserve
KAJO_SEEDS=100 swift test --filter randomProgramsAgreeWithTheirModel
```
