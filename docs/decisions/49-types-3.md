# Types 3: diagnostics in the tools

Briefed by the main session on 2026-11-19 (`docs/modules/types-3.md`, the
owner: "Start the next types module") and built the same day by one build
agent from ef2f0f2: five commits, 7c84479 (part 1, the doc only), 0e08b2e
(the client), 47d3f07 (the browser, the list, the live updates), cf36665
(the annotation pass, the last code commit) and bba836d (the doc), 24
files. The doc's "Part 1" and "As built" sections hold every number; the
raw files are in `~/kajo-scratch/types-3/`.

## What was built

- **The browser** (`tools/Models/BrowserModel.class.st`,
  `tools/Windows/BrowserWindow.class.st`) marks each diagnostic of the
  shown method with `background:orange` over its byte range, or over the
  first line when it has no range. The compile error's red is drawn after
  it. A selector with a diagnostic carries "  ⚠" in the selectors table.
  The status line says "N type diagnostic(s): <the first one's text>"; a
  compile error keeps the line.
- **The marks' three states:** `#shown`, `#dropped` at the first edit, and
  `#awaiting` from an accept until the diagnostics reply that follows it.
- **One request per class, not per method.** The browser makes one
  class-scope `diagnostics` request when a class is selected, after an
  accept and after a `diagnostics.changed` event that names a method of
  the shown class. At most one is outstanding; one wanted meanwhile is
  asked when the reply comes. Showing a method asks nothing.
- **The list:** the Smalltalk menu's "Type diagnostics of the class"
  (⇧⌘E) and "of the image" (⇧⌘D) fill the messages window with the
  columns Class, Side, Selector and Diagnostic. A row goes to its method.
  The list asks again on an event (any event for the image's list, one
  that names its class otherwise). A closed window stops listening.
- **A target without the checker:** `DevClient` remembers a kind the
  target answered as "unknown request <kind>:" (`refuses:`,
  `noteRefusal:of:`) until the next session opens. The browser asks once
  and says nothing; the list, which the developer asked for, says so on
  the status line.
- **The target's side:** `method.source` answers a signature without a
  method (its text, `signature` true; the browser shows it and does not
  change it). `TypeService class>>keysOfClass:` reads the class's own
  keys for the class scope. `DevProtocol class>>describe` is made from
  the request methods themselves, and `run:in:with:replyTo:` answers an
  error reply when the request's method is gone.
- **The annotation pass:** `Collection>>species` and
  `OrderedCollection>>species` answer `^<Self class>` (not Interval's),
  `BlockClosure>>ifError:` takes a block of none, one or two arguments,
  and `TestCase>>tags` answers `#()` for a test whose selector names no
  method.

No file under `Sources/` changed. The tier is the Swift tier, not the
brief's Smalltalk tier, because the real-target test is in `Tests/`
(`ToolsTests.swift`, its probe and `TypeCheckerTests.swift`).

## The brief's starting positions

1. Right for the product: no primitive, no new request, no Swift under
   `Sources/`. Both hosts draw a named background at 0.3 alpha already.
   Wrong for the tier (above).
2. Right. `describe` listed `diagnostics` since Types 2.
3. Right. The first request takes 1.7 s headless and 1.9 to 2.0 s in the
   Mac shell against the client's 30 s. Not measured on a device.
4. Built.
5. Right. Offsets are bytes from 0, the end exclusive. A method of 58
   bytes and 53 characters gave start 49, end 58, exactly the send
   (`part1/offsets/offsets.txt`).
6. Built, with the third state `#awaiting`.
7. Built with the class as the unit: five events while a request is
   outstanding make one more request, after the reply.
8. Right (the typing rows below).
9. Wrong for `species`, which removed no diagnostic (known receivers
   15879 to 15890, known results 10668 to 10684). Right for `ifError:`,
   which removed five.

## Numbers

First request and round trips. Headless: three interleaved launches a
side (`measure/rt/`). Mac shell: `measure/shell-diag.txt`.

| | Headless, ef2f0f2 | Headless, cf36665 | Mac shell, ef2f0f2 | Mac shell, cf36665 |
| --- | --- | --- | --- | --- |
| First request | 1680 to 1691 ms | 1739 to 1746 ms | 1904 to 1936 ms | 1969 to 2032 ms |
| One method | 0.25 to 0.27 ms | 0.24 to 0.28 ms | 0.34 to 0.42 ms | 0.36 to 0.46 ms |
| One class | 2.91 to 2.99 ms | 1.03 to 1.09 ms | p50 9.4 ms | p50 2.5 ms |
| The image | 6.6 to 6.9 ms | 6.2 to 6.4 ms | 17.6 to 26.7 ms | 16.9 to 26.2 ms |

(The headless columns are as the main session read them from the six
files; the doc's ranges are a little wider. The shell columns are the
doc's.) `keysOfClass:` agrees with the old scan for all 239 classes: 3.7
ms for all of them against 467 ms (`measure/classkeys/classkeys.txt`).

Typing, five interleaved launches a side, thermal state nominal on every
line (`measure/typing-table.txt`; the base against itself is
`part1/typing-base-base-table.txt`):

| | Key to redraw p50 | Colour p50 | Frames missed (five launches) |
| --- | --- | --- | --- |
| Idle, cf36665 | 5.0 ms | 2.8 ms | 1, 26, 88, 55, 15 |
| Idle, ef2f0f2 | 5.7 ms | 3.0 ms | 3, 77, 39, 195, 33 |
| Idle, the base twice | 5.4 and 8.1 ms | 2.4 and 2.9 ms | up to 191 |
| Storm, cf36665 | 3.3 ms | 1.02 ms | 1, 1, 186, 0, 1 |
| Storm, ef2f0f2 | 3.3 ms | 1.03 ms | 1, 1, 1, 1, 1 |
| Storm, the base twice | 8.2 and 3.3 ms | 0.89 and 0.89 ms | 0, 1, 197, 1, 1 in one block |

The storm's one launch of 186 missed frames on the head has its like in
the base against itself (197). The longest turn is 14.0 to 15.8 ms on
both sides.

Diagnostics in the development image, 81 to 73 (`measure/ann-*/image.txt`,
`measure/final-image/image.txt`):

| Step | Diagnostics |
| --- | --- |
| ef2f0f2, and with the tools code of parts 2 to 5 | 81 |
| `Collection>>species ^<Self class>` | 81 |
| `OrderedCollection>>species` too | 81 |
| `ifError:` as a union of three block types | 76 |
| The lookups guarded | 73 |

By class: BlockClosureTest 7 to 2, DevProtocol 2 to 0, TestCase 1 to 0.
The slice's 24 are unchanged. Of the other 49, 22 are written on purpose
in the checker's samples, 25 are in kernel and tools tests and 2 in
ByteArray.

Typed methods over typed methods (Types 2's question 4, counted only):
617 typed methods, 152 override a typed method and 3 a signature
(`part1/overrides/overrides.txt`).

`new-check`: `checker_classes=0 signature_text=0` on the four Release
rows, `checker_classes=441 signature_text=2` on macos-debug.

## Broken variants (by hand, `scripts/broken.sh`, outputs in `broken/`)

| Variant | Failing check |
| --- | --- |
| The marks kept after an edit | `BrowserModelTest>>testAnAcceptAsksAgainAndTheFirstEditDropsTheMarks`, `ToolWindowTest>>testTheSourceMarksEachDiagnosticAtItsBytes` |
| A request per event | `testABurstOfEventsMakesOneRequest`: "Expected 2 but was 6" |
| The refusal not remembered | `testATargetWithoutTheCheckerIsAskedOnceAndSaysNothing`, `DevClientTest>>testAnUnknownRequestIsRememberedAndAskedOncePerSession` |
| Offsets taken as characters | `testTheSourceMarksEachDiagnosticAtItsBytes` |
| No guard in `run:in:with:replyTo:` | "nil does not understand #hasPragma:" |
| No guard in `tags` | "nil does not understand #pragmas" |

## Gates

`~/kajo-scratch/types-3/check/gates.log`, on cf36665, the Swift tier,
swift.org 6.4.2: "check-tier done swift failed=0 4329s", every gate
`rc=0`.

| Gate | 5ce3d0e (closed-shell-calls) | cf36665 |
| --- | --- | --- |
| clean-build | 21 s | 20 s |
| swift-test | 716 s | 714 s (471 and 185 tests) |
| tsan | 3030 s | 3074 s (0 reports) |
| kernel-test | 120 s | 121 s (258 tests) |
| apps | 131 s | 130 s (0 warnings) |
| new-check | 269 s | 270 s |

The Smalltalk tier was also run by hand on cf36665
(`check/smalltalk/gates.log`): build-image, dev-image, kernel-test,
tools-test (351 of 351, 159 s against the starting commit's 158),
golden and the Mac shell's tests mode (258 of 258) `rc=0`;
compiler-tests `rc=1` on `ShellCloseTests.
aShellClosedWithADelayPendingFreesItsVM` (below, not this module's),
185 of 185 when run again. ToolsTests and TypeCheckerTests under
ThreadSanitizer with twelve busy loops: 13 of 13, 0 reports, 1700 s.

## Verified by the main session

- `git log ef2f0f2..HEAD` (five commits), `git status --short` clean, no
  process of Kajo alive, both `gates.log` files, the test gates' own
  counts, 0 "WARNING: ThreadSanitizer" lines in `tsan.txt`, the
  `new-check` rows, the dry run ("tier: swift").
- The numbers above from their raw files: the six round-trip files, both
  typing tables, the six image counts, the offsets, the class keys, the
  overrides, the six broken variants' outputs.
- The source diff of the kernel, the client, the checker's service, the
  browser's model and window, read.
- Rerun on bba836d: BrowserModelTest 16 of 16, DevClientTest 18 of 18,
  ToolWindowTest 5 of 5, TypeServiceTest 2 of 2, and
  `theBrowserMarksADiagnosticAndFollowsTheFix` with ShellCloseTests, 6
  of 6 (`~/kajo-scratch/types-3/verify/`).
- Not verified: the Mac shell's round-trip columns and the shown
  diagnostic in the shell's own views beyond the files' first lines; the
  by-class split of the 49 other diagnostics.

## Deviations

- The Swift tier (the test lives in `Tests/`).
- One class-scope request per class selection in place of one request
  per method shown.
- `method.source` answers signatures; `keysOfClass:` is new in `types/`.
- `describe` rebuilt, not guarded.
- The fourth broken variant takes offsets as characters; bytes are the
  right unit.
- The real-target test starts the checker without its whole-image check.
  The other ToolsTests now start a whole check in their VM's background.
- The bar asked for the shown diagnostic in the Mac shell's tests mode.
  That mode runs the kernel image only, so it was shown through the
  session bench with a patch kept in the scratch directory.

## Not done

- The first request on a phone or in a Debug app.
- An underline in place of a background (a Swift change in both hosts).
- Changing a signature in the browser.
- The narrowing rule for typed overrides (counted only).

## Found, not this module's

- `ShellCloseTests.aShellClosedWithADelayPendingFreesItsVM`
  (`ShellCloseTests.swift:74`) waits until the Delay's timer is armed and
  then reads the Process's state once; the timer is armed before the
  Process is waiting. It failed 1 of the 5 full runs of this module's
  gates and 0 of 8 alone. The fix is a bounded wait on the state. It is
  shell-close's test (the main session's module), and rides with the
  next Swift-tier change, as `RunningTarget.close()` does.
- The Mac shell's round trips have a second mode near 9 ms (the base's
  class scope in 14 of 15 rounds, the head's in 4 of 15). Headless runs
  do not show it. Not explained.
- The ToolsTests view host answers 0 for `get: 'styles'`.

## Open questions

1. The mark's look. Built: a pale orange background. Recommended: keep
   it; an underline is a Swift change in both hosts and can wait until
   someone wants it.
2. The "  ⚠" on a selector with a diagnostic. Built. Recommended: keep it
   (the class scope is 2.5 ms p50 in the Mac shell).
3. When the checker starts. Built: at a session's first class selection,
   about 2 s on the mini, on a background Process. Recommended: keep it.
4. The first request's timeout on a slow target. Recommended: measure the
   first request on the iPhone in the next device run before this
   request gets a timeout of its own.
5. Typed overrides (155 of 617). Recommended: before the narrowing rule
   is built, count how many contradictions it would report.
