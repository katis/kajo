# Follow-up: the image after the VM ends, and the file primitives' last link

Status: built, 2026-11-04, from module 8e's open question 5 and its Not
done note on links (`docs/modules/live-classes.md`). A small follow-up,
not a module of `docs/PLAN.md`; built by the same rules. Code in
`Workers/VM.swift` (`destroy`), `Nursery/YoungAllocation.swift`
(`endYoungGeneration`, `VMEndReport`), `Nursery/NurseryState.swift`
(`NurseryShared.destroy`), `ObjectMemory/Generations.swift`
(`releaseNurseryRegion`) and `ObjectModel/LiveClasses.swift`
(`sourcesPath`, the file reads and writes). Tests in
`Tests/KajoCompilerTests/VMEndTests.swift` and `LiveClassTests.swift`.

## What was wrong

**The image was not whole after a VM ran with nurseries.** `VM.destroy`
uninstalled the nurseries and destroyed the workers. Whatever lived in the
nurseries was lost with their pages (`madvise(MADV_FREE)`), and the free
entries in each nursery's entry stashes were left free in the table but in
no list. Module 1's verifier at the host's next collection trapped.
Reproduced on the starting commit d8d6797 with 8e's
`aClassWrittenOutOfOneImageReadsBackIntoAnother` and `runSmalltalk`
without its nursery-free lines:

    KajoVM/Verifier.swift:38: Fatal error: object memory verifier, before collection:
    free entry 59630 is in no free list; free entry 59631 is in no free list; ...

A second VM over the same image trapped earlier than that, at its start:
`Generations.swift:343: Precondition failed: the nursery region is reserved
once` (8e's `answerOf`, which runs three VMs over one image, without its
nursery-free lines).

**The read primitive followed a symbolic link in the last path
component.** `sourcesPath` resolved the parent directory and checked it,
but `open` in the read primitive (149) followed a link named by the last
component, so a link planted in the directory could read a file outside
it. While fixing it a second way out showed: the write primitive (148)
wrote the new contents to `<path>.kajo-tmp` with `open(O_CREAT |
O_TRUNC)`, which follows a link planted under that name, so a write could
truncate and fill a file outside the directory before its rename.

## The rules this follow-up sets

- **After `shutdown` and `destroy`, the image the host holds is whole.**
  Every object reachable from the image's roots is in old space; every
  entry the VM took and did not use is back in a free list; module 1's
  verifiers pass; `Image.saveImage` yields an image that loads, verifies
  and runs; and another VM can run over the same image.
- **No path of the file primitives reaches a file outside the sources
  directory, through any component.**

## The mechanism: a final collection in `destroy`

`VM.destroy` first runs `endYoungGeneration` on the host worker, before
anything is freed:

1. One stop (`stopWorld`, the host worker the stopper) runs module 1's
   promote-all hook (`prepareOldSpaceOperation(nil)`, module 4's
   `promoteAllForOldSpace`) with the stop's roots: Process stacks and
   records, ready queues, pending roots, registers, the root registry and
   class table. The hook already does everything an old-space operation
   needs: module 5's marking cycle is abandoned or its lazy sweep finished
   and applied in the pause (no entry is left in a pending run), module
   6's pending blocks are freed at the pause, module 7's deferred entry
   frees are released, and a promote-all scavenge promotes every live young
   object and empties every eden and survivor space. If the reserve's
   fallback kept objects young, the hook collects and compacts old space
   around them and promotes again.
2. If anything is still young after that (old space cannot take the live
   young objects even after collection and compaction), `destroy` traps
   (`kajo: N young objects found no room in old space at the VM's end; the
   image is not whole`). The image would be corrupt; the trap is the
   honest end (Not done, open question 1).
3. `NurseryShared.destroy` checks that every nursery is empty (each
   stash's handed-out prefix empty, no survivor, no deferred free, every
   eden at its start; a precondition) and hands every entry of both
   stashes of each nursery (the allocating one and module 7's second one)
   back to module 1's pool as runs (`trimStash(keep: 0)`) before
   unregistering them.
4. `releaseNurseryRegion` gives the region's pages back and clears the
   object memory's record of it, so a later VM reserves a region again.
   The object memory's soft limit, which the VM lowered below its
   promotion reserve, is given back (`NurseryShared.softLimitBefore`).

Allocation contexts already gave their private free lists back when a
worker was destroyed (module 8's `destroyContext`); nothing changes there.
Without a nursery `endYoungGeneration` does nothing: marking and
relocation are only installed with one, so no in-between state exists.

`destroy` answers a `VMEndReport` (`@discardableResult`): whether the
final collection ran, the young objects and bytes it promoted, the stop's
time from request to release and the hook's work time.

**Why `destroy` and not `shutdown`.** The brief proposed `shutdown`, after
the workers join and before the collectors stop. In `destroy` every VM
thread has joined (workers, the young collector thread after draining its
queue, the marker), so nothing can make an object young or start a cycle
after the final collection; host calls between `shutdown` and `destroy`
that allocate (`newArray`, `spawn`) are covered too; a VM the host drove
without `start` (tests) is covered; and what the host reads between the
two (`kajo run`'s scavenge and marking reports, counters in tests) is
unchanged, since the final stop comes after it. A stop works after
`shutdown`, as every host inspection after it already relied on.

**No new cross-thread protocol.** The final collection is an ordinary stop
whose work is module 4's existing promote-all hook, with no other VM
thread left; the models under `models/` are unchanged. Zero behaviour
change for a VM that saves through its own save primitive: the save, its
hold (`docs/models/save-hold.md`) and the saved-process rules happen while
the VM runs and are untouched.

## The last link

`sourcesPath` answers the path to write (the resolved parent and the last
component as named) and, when the last component exists (`lstat`: a file
or a link), the whole path resolved by `realpath`, which must lie under
the directory and not be the directory itself; a dangling link does not
resolve and is refused.

- **Read (149)** opens the resolved path with `O_RDONLY | O_NOFOLLOW`: a
  link inside the directory to a file inside it is read through; a link
  leading outside, a dangling link and a missing file are refused.
- **Write (148)** is refused for an existing last component that resolves
  outside (or dangles); otherwise it renames over the named path as
  before, so a link inside the directory is replaced by the file, never
  followed. The temporary file is unlinked first (a link there is removed
  itself) and created with `O_CREAT | O_EXCL | O_NOFOLLOW`, so a link
  planted between the two refuses the write instead of leading out.

## Measurements

The final collection at the VM's end
(`VMEndTests>>theFinalCollectionsCostIsReported`, one background worker,
`stw` mode, Mac mini M2 Pro, swift.org 6.4.2). "Empty": a VM that ran one
Process and nothing else (it promotes one young object). "Full": twelve
Processes left 96 000 live young objects of 2.30 MB in one nursery (eden
3 MiB).

| build | nursery | promoted | stop (request to release) | hook's work |
|---|---|--:|--:|--:|
| release, `-enable-testing`, verifiers off (5 runs) | empty | 1 object, 16 B | 5 to 15 µs | 5 to 10 µs |
| release, `-enable-testing`, verifiers off (5 runs) | full | 96 000 objects, 2.30 MB | 1.04 to 1.18 ms | 1.04 to 1.18 ms |
| debug, verifiers on (2 runs) | empty | 1 object, 16 B | 6.4 to 6.7 ms | 6.4 to 6.7 ms |
| debug, verifiers on (2 runs) | full | 96 000 objects, 2.30 MB | 127 to 161 ms | 127 to 161 ms |

A full nursery costs what one promote-all scavenge of it costs (about
2 GB/s on one participant); the debug numbers are mostly the verifiers at
the stop. The cost is paid once, when the host ends the VM.

### The kernels against the starting commit

The final collection is not on any hot path: `destroy` is called once,
and nothing in `interpret`, the send, allocation, barrier or young
collection paths changed. d8d6797's `kajo` (from a worktree) against this
follow-up's, both built `-c release -Xswiftc -enable-testing` with
`-align-all-nofallthru-blocks=5 -align-loops=32`; five runs interleaved,
`--slice-ms 0`; median (min to max) ms of round 1; two rounds back to
back, 2026-11-04 15:20 to 15:25 (load average 1.9 to 5.8, the agent
session the busiest other process). Checksums equal on both sides and the
published ones. "Process wall" is the whole `kajo run`, `destroy`
included (median ms, round 2).

| kernel | workers | start ms | this ms | this / start, round 1 | round 2 | process wall start / this |
|---|--:|--:|--:|--:|--:|--:|
| fib | 1 | 1707.3 (1700 to 1725) | 1701.0 (1696 to 1720) | **0.996** | **0.994** | 1711 / 1700 |
| fib | 8 | 219.4 (218 to 223) | 222.5 (217 to 239) | **1.014** | **0.953** | 243 / 232 |
| arith | 1 | 2548.2 (2538 to 2552) | 2549.0 (2547 to 2555) | **1.000** | **0.996** | 2556 / 2545 |
| arith | 8 | 336.6 (336 to 339) | 348.0 (337 to 355) | **1.034** | **0.956** | 364 / 348 |
| sends | 1 | 2575.9 (2574 to 2586) | 2588.0 (2587 to 2592) | **1.005** | **0.998** | 2594 / 2588 |
| sends | 8 | 331.8 (331 to 343) | 351.0 (350 to 357) | **1.058** | **0.952** | 360 / 342 |
| ivars | 1 | 1971.1 (1959 to 1973) | 1965.6 (1960 to 1971) | **0.997** | **1.000** | 1981 / 1982 |
| ivars | 8 | 256.0 (253 to 271) | 254.2 (252 to 272) | **0.993** | **0.948** | 285 / 271 |
| storeheavy | 1 | 2413.4 (2403 to 2418) | 2397.6 (2392 to 2404) | **0.993** | **1.004** | 2411 / 2421 |
| storeheavy | 8 | 329.8 (320 to 336) | 316.2 (312 to 318) | **0.959** | **1.091** | 319 / 348 |
| alloc | 1 | 2932.7 (2927 to 2933) | 2940.1 (2933 to 2941) | **1.003** | **0.999** | 2960 / 2956 |
| alloc | 8 | 489.9 (461 to 508) | 441.7 (440 to 483) | **0.902** | **1.051** | 460 / 505 |

One worker: 0.993 to 1.005 in both rounds. Eight workers: 0.90 to 1.09,
and every eight-worker ratio but fib's changes side between the rounds
(sends 1.058 then 0.952, storeheavy 0.959 then 1.091): noise of the shared
machine. `interpret` is the same code in both aligned builds, instruction
for instruction (1326 lines of disassembly; only its address differs, by
32 bytes).

## Deviations from the brief

- **The final collection runs in `destroy`, not in `shutdown`** (reasons
  above). The image is whole after `shutdown` and `destroy`, as the rule
  says; between the two the VM is as it was.
- **A second VM over the same image** needed the nursery region released
  (`releaseNurseryRegion`): the brief named the save only, but 8e's
  `answerOf` runs three VMs over one image and could not lose its
  nursery-free lines otherwise.
- **The write's temporary file** is created exclusively without following
  a link: a way out the brief did not name, found while fixing the read.
- **A dangling link as the last component is refused** for read and write
  (it cannot be shown to stay inside), though a write would only replace
  the link.
- **`VMEndReport`**: `destroy` answers what the final collection did, for
  the measurement and the tests; existing callers ignore it.

## Tests

Swift: 312 `KajoVMTests` (as at the start) and 56 `KajoCompilerTests`
(Swift Testing's count, parameterized tests once; 54 at the start): new
`VMEndTests` (2).

- `theImageIsWholeAfterTheVMEnds(mode, workers)`, for `stw`, `local` and
  `offload` with 1 and 8 background workers, the object memory provisioned
  as `kajo run` does it (promotion reserve, doubly mapped nursery region,
  so the young modes are in effect; asserted): a VM of the default
  configuration makes `Keep`'s class-side `objs`; a second VM runs eight
  Processes that each hang 300 small Arrays (each holding its index and a
  one-slot Array) under it and end; the VM ends. Asserted: the final
  collection ran and promoted at least those 4800 young Arrays; module 1's
  heap and free-list verifiers report nothing; a third VM over the same
  image sums every value (`Keep total`); the host saves with
  `Image.saveImage`, the saved image loads with every loader rule, the
  class still holds every Array with its contents, and a VM over it sums
  the same total.
- `theFinalCollectionsCostIsReported`: the measurement above; asserts the
  promoted count and the verifiers.
- `LiveClassTests>>theFilePrimitivesStayInTheirDirectory` gained a link as
  the last component: to a file outside (read and write refused, the file
  and the link unchanged), to a file inside (read through, the write
  replaces the link with a file, the target unchanged), dangling
  (refused), and a link in place of the write's temporary file leading
  outside (the write succeeds, the file outside is unchanged).
- The nursery-free workaround is gone from 8e's helpers: `answerOf`
  (`LiveClassTests.swift`) and `runSmalltalk` (`TonelRoundTripTests.swift`)
  run the default VM configuration, so 8e's save-and-load tests now save
  an image nursery VMs ran on (three in turn, for `answerOf`).
  `runClassSide` (`Support.swift`, module 8b's) keeps its configuration:
  it builds a fresh image per call, runs one VM and never saves, so it was
  not there for this bug.

## Broken variants run by hand

| rule | broken variant | test | result |
|---|---|---|---|
| a final collection at the VM's end | `destroy` skips `endYoungGeneration` | `VMEndTests` | traps: `NurseryState.swift:468: Precondition failed: nursery 1 is not empty at the VM's end` |
| the same, without the emptiness check | as above, and `NurseryShared.destroy`'s precondition removed | `VMEndTests` | fails: nothing ran or was promoted, `verifyHeap` reports issues (the young objects were lost with their pages), and the next VM's `Keep total` ends in `doesNotUnderstand #+ (receiver UndefinedObject)` |
| the stashes' entries go back | `NurseryShared.destroy` skips `trimStash(keep: 0)` | `VMEndTests` | traps in the next VM over the image: `object memory verifier, nursery verifier, after scavenge 1: free entry 286 is in no free list; ...`, the starting point's failure |
| no link in the last component leads out | d8d6797's `LiveClasses.swift` (parent resolved only, `open` follows, the temporary file opened with `O_TRUNC`) | `LiveClassTests>>theFilePrimitivesStayInTheirDirectory` | fails: `run` does not answer 1 (the read through `outfile` reaches the file outside), the link inside is followed rather than replaced, `sub/c.txt` is never written |

They trap or need the code changed, so they are run by hand, as AGENTS.md
says of trapping variants.

## Unsafe surface

`Sources/KajoVM` lines with `unsafe` (comments excluded, counted the same
way on both commits): 4608, against 4590 at d8d6797. `YoungAllocation.swift`
+7 (the final collection's stop and its reads of the nursery's counters,
the soft limit kept), `Generations.swift` +5 (`releaseNurseryRegion`'s
`madvise` and the region's three words), `NurseryState.swift` +3 (the
emptiness check and the two stash hand-backs), `LiveClasses.swift` +2
(`lstat`, the `unlink` of the temporary file), `VM.swift` +1 (`destroy`'s
host call). Counted on the final commit, whose clean build has 0 warnings.

## Hot-path check

Nothing of this follow-up is on a checked path: `destroy` runs once per
VM, and `endYoungGeneration` reaches the scavenge through the existing
out-of-line promote-all hook. `just arc-check` on the final code: 135
functions, zero `swift_retain`/`swift_release`; `interpret` 1056
instructions (as at the start), one jump table. `interpret` is identical instruction for instruction to the
starting commit's in the aligned bench builds.

## Not done

- **A heap whose old space cannot take the live young objects at the
  VM's end** traps in `destroy` rather than leaving a corrupt image. It
  needs old space past its soft limit and the promotion reserve both used
  up, which the reserve's sizing makes unlikely; nothing tests it.
- **Process stacks** are still freed by `destroy`, as before: a live
  Process's stack lives outside the heap, so an image saved on the host
  after a VM ended with live Processes holds Process objects whose frames
  are gone. Saving running Processes is the VM's own save (8c); `kajo run`
  and the shells terminate every Process before ending the VM.
- Races with another process changing the sources directory between the
  check and the open are narrowed (`O_NOFOLLOW` on the last component,
  exclusive creation of the temporary file) but not closed for the parent
  directories: a directory swapped for a link between `realpath` and
  `open` is not caught (`openat` on a held directory descriptor would).

## Open questions for the owner

1. **Young objects that do not fit old space at the VM's end**: trap (as
   built), grow old space for the final collection, or answer the failure
   to the host (`destroy` refusing, the VM kept)?
2. **The host's save after a VM with live Processes**: should `destroy`
   refuse while Processes are alive, or should the host's save take
   Processes as the VM's own save does (8c), now that the image is whole
   at the end?

## Gates

The code and this doc but for this table and the hot-path paragraph are
1793ea2's; every gate ran on 1793ea2, Mac mini (M2 Pro), swift.org 6.4.2
(the toolchain first on PATH), 2026-11-04 15:28 to 17:28, every output in
a file, each step logged with the commit it ran on:

| gate | result |
|---|---|
| `swift test` | 312 + 56 passed, 229 + 56 s |
| under load (12 busy loops) | 312 + 56 passed, 278 + 68 s |
| ThreadSanitizer | 312 + 56 passed, 0 reports, 651 + 1463 s |
| ThreadSanitizer under load | 312 + 56 passed, 0 reports, 610 + 1627 s |
| `just ios-check` | exit 0, 0 errors, 0 warnings |
| `just arc-check` | OK: no retain or release in 135 functions, `interpret` 1056 instructions, one indirect branch and one jump table |
| `just golden` | 12 of 12 checksums |
| `just test-release` | 312 + 56 passed |
| `just model-check` | 28 + 5 + 15 passed |
| `just soak` | passed: 1000 seeds under every configuration, no failing seed; the resumed modes saving 930 and 973 of 1000 |
| `just fuzz kasm 600` | libFuzzer build ok, 2.40 million runs, no crash |
| `just fuzz snapshot 600` | libFuzzer build ok, 3.35 million runs, no crash |
| `just fuzz syntax 600` | libFuzzer build ok, 1.14 million runs, no crash |
| `just apps` | macOS and iOS: exit 0, 0 errors, 0 warnings |
| clean build | exit 0, 0 errors, 0 warnings |

(312 is `KajoVMTests`, 56 `KajoCompilerTests`.) The clean build took 10 s
from an empty scratch path (the toolchain's compilation cache, as in 8e);
`just ios-check` typechecks every KajoVM file with strict memory safety
from nothing and reports no warning either. `just test-release` took 14 s:
its release build was already up to date from the measurements.

## Commands

```zsh
swift test --filter VMEndTests                     # the six configurations and the cost report
swift test -c release -Xswiftc -enable-testing --scratch-path .build/release-tests --filter theFinalCollectionsCostIsReported
swift test --filter theFilePrimitivesStayInTheirDirectory
S=<scratch>; git worktree add $S/start d8d6797
A2=(-Xswiftc -enable-testing -Xswiftc -Xllvm -Xswiftc -align-all-nofallthru-blocks=5 -Xswiftc -Xllvm -Xswiftc -align-loops=32)
(cd $S/start && swift build -c release --product kajo --scratch-path .build/bench-a2 $A2)
swift build -c release --product kajo --scratch-path .build/bench-a2 $A2
zsh bench.sh $S/start/.build/bench-a2/release/kajo .build/bench-a2/release/kajo bench.txt 5; python3 agg.py bench.txt
```
