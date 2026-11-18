# Types 2: the checker in the development image

Briefed by the main session on 2026-11-17 (`docs/modules/types-2.md`, the
owner: "Start") and built overnight by one build agent from 1e8f324: eight
commits, fa8561f to 0455923, 70 files. The last code commit is 7ac2711. The
doc's "Part 1" and "As built" sections hold every number; the raw files are
in `~/kajo-scratch/types-2/`.

## What was built

- The signature without a method, as the owner approved it: a Tonel method
  entry with no body, in both readers, the writer, `ClassTypes`, the image
  build and the live API (`Behavior>>signature:classified:`). After the
  pattern a `[` starts a body; a `{` or the end of the file ends a
  signature; anything else is refused ("expected [ after the method's
  pattern"). A comment does not end a signature: by the brief's literal
  rule 762 forgotten brackets in the kernel would have been read as
  signatures. Also refused, alike in both readers: a signature with no
  type, a signature twice, a selector that is both a method and a
  signature, a method of one class in another's file. In the image a
  method compiled where a signature stands replaces it.
- The 45 placed by `experiments/optional-types/scripts/place45.py`: 16 by
  `Self`, 15 on Behavior's own methods, 1 dropped (`Integer>>//`), 13
  signatures without a method.
- The checker as the package `types/` (27 class files and a `DevSession`
  extension): it checks the image it runs in, reads types from method
  patterns and `ClassTypes`, and reads no side file.
- A live service (`TypeService`): a background Process that rechecks what a
  change touches, through one plain Smalltalk hook in the kernel
  (`Smalltalk changeListener:`, `noteChange:of:in:`, `changesDuring:`). It
  waits untimed when idle.
- The request `diagnostics` (`className`, `selector`, `side`) and the event
  `diagnostics.changed`, on the development protocol and through MCP. The
  request is the package's, so a target without it answers "unknown request
  diagnostics".
- Built into development images only (`kajo build-image --with types`,
  `just dev-image`, a generated app's Debug image). `new-check` asserts
  that a Release image holds no checker class and no signature text.

No file under the core directories changed and there is no new primitive.

## The brief's starting positions

1. Wrong. With the experiment's checker the placing gives the slice's 27
   classes 30 diagnostics against the side files' 20 (not 21 on this
   commit). Seven of the ten come from Behavior's 15 signatures applying at
   all (the experiment never applied Object's class side): `self species
   new:` is Instance, not Self. Three are `negated ^<Self>`. The checker as
   built gives 24, with two rules the brief did not name: `self class new`
   is Self, and a value typed only as some Behavior makes Dynamic instances.
2. Right, with the rule corrected as above: all 2754 methods have `[` right
   after the pattern.
3. Right: no primitive, no core change, one kernel hook.
4. Wrong for the whole image: 1703 to 1726 ms for 3180 methods against the
   experiment's 1463 to 1479 ms for 3111, 14 to 17 percent slower. Right
   for one method: a changed body rechecks in 0.15 to 1.0 ms with the
   invalidation.
5. Right: 2.95 MB held after a whole check of the development image
   (the experiment 4.79 MB), 2.44 MB in an image shaped like a Debug app's.

The whole development image has 81 diagnostics: the slice's 24, 22 written
on purpose in the checker's samples, 30 in kernel and tools tests, 5
elsewhere.

Sizes: the release kernel image grew 69 728 bytes, of which 68 264 are part
2's kernel code and 1 440 the type text of the 45. So the bar's "the same
size up to the signatures' text" is not met; the growth is kernel code that
reads and writes signatures, which every image has. The development image
grew from 8 440 736 to 9 701 944 bytes with the package. A generated Mac
app's Release binary went from 5 220 736 to 5 241 312 bytes.

## Verified by the main session from the files

- `git log 1e8f324..HEAD` is the eight commits, the tree is clean, and the
  one commit after 7ac2711 touches only the doc. No file under the core
  directories, `AGENTS.md` or `docs/PLAN.md` changed.
- `~/kajo-scratch/types-2/check/gates.log`: `just check 1e8f324` on 7ac2711
  chose the Swift tier, swift.org 6.4.2, eight gates, every one `rc=0`,
  4 384 s (Types 1: 4 333 s); the fuzz lines read `runs=95076 build=ok` and
  `runs=365638 build=ok`; the sanitizer's output has 0 reports.
- `check/new-check.txt`: `checker_classes=0 signature_text=0` on all four
  Release rows, `checker_classes=437 signature_text=2` on the Debug row.
- `measure/new-image-1/image.txt`: `slice27 ... diagnostics=24`, `image ...
  diagnostics=81`.
- `scripts/canonical-tonel.sh --check` run again: lists nothing, rc=0.
- `swift test --filter SignatureTests` run again on 0455923: 4 tests pass
  (`verify/signature-tests.txt`).
- `check/golden-final.txt` rc=0 and `check/mac-tests-final.txt` 255 of 255:
  the two Smalltalk-tier gates the Swift tier does not run, on 7ac2711.
- `work/fuzz-syntax-kernel.txt`: "libFuzzer build: ok", 3 426 runs.
- `work/exchange.txt`: one real request, reply and event.
- `Sources/KajoVM/Processes/External.swift`: `startDelay` does hand a
  `VMRef` to `asyncAfter` with nothing that cancels it (found, below).
- No Kajo process alive after the hand-back.

Not verified by the main session: the timing and footprint tables were read
in the raw files, not rerun; the five broken variants' outputs were listed,
not read line by line; the development image's 333 tests and the sanitizer
run of the new suites under load were not run again.

## Deviations

- The request lives in the package, not in the kernel.
- The checker starts at the first `diagnostics` request, not at image start.
- The shells' scenario images do not hold the package, so the matrices
  measure what they measured.
- The request's wait for the checker is untimed. A Delay-bounded wait
  crashed the first gate run (below).
- The live tests start the service without the whole-image check; the
  protocol test checks the whole image.
- `Behavior>>signature:classified:` refuses with an Error, not the
  ClassDefinitionError part 1 named.

## Not done

- The narrowing check covers a signature without a method, not a typed
  method over a typed method.
- Nothing in the tools' windows shows a diagnostic (out by the brief).
- `BlockClosure>>ifError:`'s block type is wrong and not corrected; five
  `arity` diagnostics in BlockClosureTest name it.
- No device run (none asked).

## Found, not this module's

- A Delay outlives its VM. `startDelay` arms a GCD timer that holds a
  `VMRef` and nothing cancels it, so a VM that ends first is signalled
  after its end. The first gate run (44d4738, `check-1-aborted/`) died
  there under the sanitizer: SEGV in `VMRef.signalFromOutside`. A core bug
  as old as module 3's external signals; any short-lived VM with a pending
  Delay can hit it.
- A started `TypeService` keeps `kajo run` from ending.
- Three unguarded `lookupSelector:` results (`DevProtocol class>>describe`,
  `run:in:with:replyTo:`, `TestCase>>tags`), which the checker reports.

## Open questions

1. When the checker starts. Built and recommended: at the first request;
   starting at a session's open would put a 1.7 s check (more on a phone)
   behind every connection.
2. The Delay that outlives its VM. Recommended: a core follow-up that
   cancels a VM's pending timers when it ends, with a test that ends a VM
   with a long Delay pending.
3. `species ^<Behavior>`. Recommended: `^<Self class>` where it is true
   (not Interval), in the next annotation pass, measured first.
4. The narrowing check for a typed method over a typed one. Recommended:
   later, after its count on the image is measured.
5. `BlockClosure>>ifError:`'s type. Recommended: corrected in the next
   annotation pass.
