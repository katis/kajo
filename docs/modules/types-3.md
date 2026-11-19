# Types 3: diagnostics in the tools

## Status

Briefed by the main session on 2026-11-19. The owner: "Start the next types
module". The records are `docs/decisions/43-optional-types.md`,
`44-types-1.md` and `45-types-2.md` (with the owner's "Approve all" for its
five questions); the checker is `docs/modules/types-2.md`. Starting commit:
ef2f0f2. Built by the build agent on 2026-11-19 (the last code commit
cf36665), verified and recorded by the main session the same day
(`docs/decisions/49-types-3.md`).

## What it is

The checker runs in the target and answers one request, and nothing a
person looks at shows what it found. This module puts its diagnostics in
the tools: the browser marks them in the method it shows and says their
text, a list window shows the diagnostics of a class or of the image, and
both follow the checker's event after a change. A small second half is the
annotation pass the owner approved in Types 2's answers: two corrections
and one count.

Diagnostics only. Nothing is refused because of a type: accepting a method
with a diagnostic installs it as before.

## What is known

- The tools run in the Kajo app's image and reach the target over the
  development protocol (`DevClient`, primitive 164). The checker runs in
  the target (`types/`, `TypeService`). So the tools ask; they hold no
  checker of their own for the target's code.
- The request `diagnostics` (`className`, `selector`, `side`; all nil is
  the image) answers `count`, `checked` and `diagnostics`, each with
  `kind`, `class`, `side`, `selector`, `line`, `start`, `end` (nil when
  the diagnostic has no node) and `text`. The first request starts the
  checker, which checks the whole image once (1.7 s headless on the mini)
  and then rechecks after every change. The request waits, untimed in the
  target, until the checker has caught up.
- The event `diagnostics.changed` carries the count now, the methods and
  signatures whose diagnostics changed (at most 200) and their
  diagnostics now (at most 500).
- A target without the package answers the protocol's own "unknown
  request diagnostics". A release image does not serve at all.
- `DevClient` has one method per request (`DevClient class>>requests`,
  which `DevClientTest` checks against `DevProtocol describe`), dispatches
  events to windows by kind (`on:do:`), and fails a request with no reply
  after `timeoutMs` (30 s).
- `BrowserWindow>>colour` builds the source view's styles: the
  `SourceColorer`'s tokens, plus `background:red` on the line of a compile
  error. The hosts know three styles: `color:<name>`,
  `background:<name>` and `bold` (`Sources/KajoApp/TextOffsets.swift`).
- The browser's senders and implementors open a messages window (a list
  whose selection shows a method in the browser).
- The whole development image has 81 diagnostics on 0455923: the slice's
  24, 22 written on purpose in the checker's samples, 30 in kernel and
  tools tests, 5 elsewhere.
- A diff of `kernel/`, `tools/` and `types/` only is the Smalltalk tier:
  seven gates (the two image builds, the kernel tests, the tools' tests,
  the compiler tests, golden, the Mac shell's tests mode).

## Starting positions

Each is the main session's belief. Part 1 says right or wrong with a
number or a line of code.

1. No Swift changes. The three styles the hosts have are enough (a
   background on the diagnostic's range), no new primitive and no new
   protocol request are needed, and the tier stays Smalltalk. If a Swift
   change is needed, part 1 says which and why before it is made, and the
   tier is then the Swift tier.
2. `DevProtocol describe` in an image with the `types` package lists
   `diagnostics`, so `DevClient` gains one method for it and
   `DevClientTest`'s map check holds in the development image. In an image
   without the package the map check must still pass.
3. The first `diagnostics` request of a session can take longer than the
   client's 30 s timeout on a slow target (a Debug app's VM is 2.6 to 4.0
   times slower than Release, and a phone is slower again). Measure the
   first request on the mini headless and in the Mac shell, and say what
   the tools do when it times out. Nothing in the tools waits for it: the
   reply is an event like every other reply.
4. A target without the checker is asked once per session. The refusal is
   remembered, no error goes to a status line, and the browser then works
   exactly as it did before this module.
5. A diagnostic's `start` and `end` are offsets in the installed source of
   the method, in the same units the source view's styles use. Check with
   a method that holds a multi-byte character before the diagnostic.
6. After the first edit of the shown text the ranges are stale. The marks
   are dropped at the first edit and come back with the reply that follows
   an accept.
7. The event names the methods that changed, so the browser re-asks only
   when the event names the method or the class it shows, and a list
   window re-asks its own scope. A burst of events does not queue a burst
   of requests: one request is outstanding per window at most.
8. The typing measurement (`mode=devsession`, the typing rows) does not
   change: `colour` runs on every change of the text and gains only a walk
   of the diagnostics the model already holds.
9. The two approved corrections lower the image's count:
   `species ^<Self class>` where it is true (not Interval) removes the
   `self species new:` diagnostics of the slice, and the corrected
   `BlockClosure>>ifError:` type removes the five `arity` diagnostics in
   `BlockClosureTest`. Measure the count before and after each, on the
   whole development image, before the change is kept.

## Parts

1. **Measure and decide, build nothing else.** The baseline on the
   starting commit: the image's diagnostics by class (81 expected; say the
   number found), the first request's time headless and in the Mac shell,
   a later request's round trip for one method, one class and the image,
   and the typing rows. Positions 1, 2, 3 and 5 answered from the code and
   one run each. The count of typed methods that override a typed method
   (Types 2's question 4: only the count, with three rows checked by
   hand). Commit before part 2.
2. **The client**: `DevClient`'s request method for `diagnostics` and the
   event's kind; `FakeDevClient` answers and emits both. The unknown
   request remembered per session (position 4).
3. **The browser**: the model asks for the shown method's diagnostics when
   a method or a signature without a method is shown and after an accept,
   holds them, and drops them at the first edit. The window marks each
   range with a background (the whole first line when a diagnostic has no
   range) in a colour that is not the compile error's, and the status line
   says the first diagnostic's text and how many there are. A compile
   error still wins the status line. The selectors table marks the
   selectors of the shown class that have a diagnostic, if one class-scope
   request per class selection is cheap (part 1's round trip decides; say
   the number).
4. **The list**: a command in the Smalltalk menu, "Type diagnostics", with
   two scopes, the shown class and the image. It opens the messages window
   the senders use, one row per diagnostic (class, side, selector, text);
   a selection shows the method in the browser with its marks. The list
   follows the event.
5. **Live**: the event handler of position 7 for the browser and the
   list. A window that closes stops listening.
6. **The annotation pass** (Types 2's answers 3 and 5): `species` and
   `BlockClosure>>ifError:`, each measured before it is kept
   (position 9). And the three unguarded `lookupSelector:` results the
   checker reports (`DevProtocol class>>describe`,
   `DevProtocol>>run:in:with:replyTo:`, `TestCase>>tags`): guard each
   with a test that reaches the nil, or say why the nil cannot happen and
   leave the diagnostic.
7. **The numbers again** on the final code commit, beside part 1's.

## Tests

Before the code where possible.

- `DevClientTest`: the request's line, the reply's result, the event
  dispatched by kind, the unknown request remembered and asked once.
- `BrowserModelTest` over `FakeDevClient`: a method with two diagnostics
  holds two; a method with none holds none; an accept re-asks; the first
  edit drops them; an event naming the shown method re-asks and one naming
  another method does not; a burst of five events makes one request; a
  target without the checker makes one request in the whole session and
  no status error; a signature without a method shows its diagnostics.
- `ToolWindowTest`: the styles the window gives its source view hold one
  background per diagnostic at the right offsets (a multi-byte character
  before it), the compile error's line still marked when both exist, the
  status line's text.
- The list: the rows of a class scope and of the image scope, a selection
  shows the method, the list after an event.
- One test against a real target in the development image (no fake): a
  class with a known diagnostic is defined, the browser model shows its
  method and holds the diagnostic, the method is fixed and accepted, and
  the model holds none after the event. It waits on the model's own
  state with a long bound, not on a clock.
- The annotation pass: the checker's tests for `species` on a class where
  `Self class` is true and on Interval, and for `ifError:`'s block.
- Broken variants, each failing a named check, run by hand or as a switch
  of the fake: the model keeps the marks after an edit; the event handler
  re-asks on every event (the burst test counts five); the unknown request
  is asked again at every selection; the offsets are taken as bytes.

## The bar

- A method with a diagnostic shows its mark and text in the browser in
  the Mac shell's tests mode and in the tools' tests; the list shows the
  image's diagnostics and their count equals the request's.
- The image's diagnostic count before and after the annotation pass, by
  class, each remaining one of the slice classified as Types 2 did.
- The typing rows inside the starting commit's own spread (measure the
  base against itself first).
- The first request's time and a later round trip, headless and in the
  Mac shell, beside part 1's.
- A target without the checker: the tools' tests pass in a development
  image built without `--with types` talking to itself, or the doc says
  exactly which tests need the package and why.
- Every method of the image still compiles to the bytecodes it had; both
  compilers agree; `scripts/canonical-tonel.sh --check` lists nothing.
- A Release app's image still holds no checker class and no signature
  text (`new-check`'s rows are not in the Smalltalk tier: run `just
  new-check` once on the final code commit and quote its
  `checker_classes` lines).
- `just check <starting commit>` on the final code commit, every gate
  `rc=0`, the times beside Types 2's Smalltalk-tier gates where they
  exist and beside the starting commit's otherwise.
- One run of every switch and mode the module adds, quoted.

## Rules of the house that bind here

- The development protocol is a trust boundary from both sides: every
  received line is checked, a reply the client does not understand is a
  `client.error` event and never a trap.
- A request ends: the timeout goes through the seam `FakeDevClient`
  records and fires.
- A list and its change event are two publications; a test that waited
  for the first reads the second with a wait of its own.
- A wait for something that must come is long everywhere, on the thing's
  own state, with the assertion unchanged.
- A feature kept out of a product is kept out by where its entry point
  lives: the tools name the request as text, and no class of `types/` is
  named from `tools/` or `kernel/`.
- A count from a script is checked on three rows by hand.
- A new slow kernel or tools test changes the test parts; run the kernel
  tests in parts before the gate run.
- A measurement on an idle machine is not the easy case: the typing rows
  are read idle and under load, as 9c read them.
- Known thin test, not this module's: `ToolsTests.aClassDefinedIntoATag
  FromTheBrowserMovesWithItsTag`. A failure of it is reported as what it
  is.

## Not in this module

- Completion, hover, types shown apart from the text, a "New signature"
  command.
- Diagnostics in the workspace, the debugger or the inspector.
- Annotating more of the kernel than the two corrections.
- The narrowing check for a typed method over a typed one (only its count
  is measured).
- Types on temporaries and block parameters.
- Any device run.

## Deliverables

The code and tests above; this doc with a "Part 1" and an "As built"
section (each starting position's answer, the numbers with their files,
the diagnostics classified, gates, deviations, not done, found); work
files in `~/kajo-scratch/types-3/`.

## Open questions

1. **The mark's look.** The hosts have no underline. Recommended and
   assumed: a pale background that is not the compile error's red, named
   in part 1 from the colours the hosts already know. An underline is a
   Swift change in both hosts and can come later.
2. **Marks in the selectors table.** Recommended: yes if a class-scope
   request per class selection is under 10 ms on the mini; otherwise only
   the shown method is asked.
3. **The checker's start.** Types 2's answer stands (the first request).
   With this module the first request comes when the first method is
   shown, so a session pays the whole-image check once, in the
   background of the target. Recommended: keep it; say the time.

## Part 1: measured and decided (2026-11-19, ef2f0f2)

Measured on the mini with swiftly's swift.org 6.4.2 the first Swift on PATH
(`part1/env.txt`). Raw files are in `~/kajo-scratch/types-3/part1/`, scripts
in `~/kajo-scratch/types-3/scripts/` (`T3Live/T3Measure`, a scratch
measurement package after Types 2's `TypeMeasure`; `t3-run.sh`; `rt.py`, a
protocol client that reads the token from `kajo run`'s stdout in memory and
never writes or prints it; `patch-bench.py`, a scratch-only change to a copy's
`DevSessionBench` whose scripted session times the diagnostics request through
the tools' client; `shell-runs.sh`; `typing-table.py`). The headless numbers
use one aligned release `kajo` built from the starting commit
(`-enable-testing`, `-align-all-nofallthru-blocks=5 -align-loops=32`); the
VM's Swift does not change in this module, so the same binary serves the
images of both sides. The shell numbers use the starting commit's Release
Kajo app built from `git archive ef2f0f2` with the patched bench
(`work/dd-base`). Nothing was built in the repository.

### The baseline

- **The image's diagnostics: 81**, as Types 2 said (`part1/image-1/image.txt`:
  3181 methods and signatures checked in 1747 ms, the slice's 27 classes 24).
  By class (`image-1/image-diagnostics.txt`, column 1): TypeCheckerSample 20,
  OrderedCollection 9, Interval 7, BlockClosureTest 7, DiscoverabilityTest 5,
  LiveCompileTest 4, DevelopmentTest 4, ObjectTest 3, TypeCheckerNarrowSample
  2, String 2, FractionTest 2, Fraction 2, ExceptionTest 2, DevProtocol 2,
  ByteArray 2, and 1 each in WriteStream, TestCase, ReflectionTest,
  OrganizationTest, Number, IntegerTest, Float and Collection.
- **The first request, headless** (`kajo run <development image> --protocol`,
  `rt-headless-1.txt` to `-3.txt`): 1743 ms for the image's, 1725 and 1732 ms
  for one method's. In the target alone (`target/target.txt`,
  `TypeService diagnosticsOf:` with no protocol) 1709 ms: the whole-image
  check is the first request's time, whatever its scope.
- **Later round trips, headless**, five each (`rt-headless-1.txt`): one method
  0.18 to 0.29 ms; one class, TypeCheckerSample (44 checked, 20 diagnostics),
  3.0 to 3.7 ms; String (81 checked) 2.2 to 2.4 ms; the image (3172 checked,
  81 diagnostics) 6.8 to 7.6 ms; `package.list` for reference 0.55 to 0.70
  ms. In the target alone: a method 18 to 26 µs, a class 2.3 to 2.4 ms, the
  image 4.2 to 5.1 ms.
- **In the Mac shell** (the Release app, the tools on the image's own socket,
  three launches, `shell-diag.txt`, the session's `diagnostics` round trips
  in order): the first 1886, 1890 and 1894 ms; a method 0.33 to 0.47 ms; the
  class 7.9 to 11.7 ms (p50 9.4); the image 17.5 to 26.7 ms.
- **The typing rows, the starting commit against itself** (five interleaved
  launches of the same app as A and B, `mode=devsession classes=0
  typing=200`, `typing-base-base-none.txt`, `-storm.txt`, the table in
  `typing-base-base-table.txt`, thermal nominal on every line). Medians
  [range] for A and B:

  | load | key to redraw p50 ms | p99 ms | max ms | colour p50 ms | colour p99 ms | missed (of about 1259) |
  |---|---|---|---|---|---|---|
  | none, A | 5.4 [3.7–9.0] | 8.6 [6.0–10.2] | 16.5 [9.6–22.3] | 2.4 [2.3–3.1] | 7.1 [4.6–8.1] | 25 [2–191] |
  | none, B | 8.1 [4.0–9.4] | 9.4 [6.0–10.3] | 11.1 [10.8–19.5] | 2.9 [2.4–3.0] | 6.1 [4.1–7.9] | 2 [1–62] |
  | storm, A | 8.2 [5.2–8.4] | 8.2 [5.3–8.4] | 8.6 [6.4–12.0] | 0.89 [0.80–0.91] | 4.2 [1.2–4.6] | 0 [0–1] |
  | storm, B | 3.3 [1.4–7.6] | 5.9 [3.3–9.3] | 6.6 [6.5–9.3] | 0.89 [0.81–0.90] | 1.4 [1.1–3.9] | 1 [0–197] |

  The same app's two medians of the key to redraw differ by 2.7 ms idle and
  4.9 ms under the storm; the colouring is the tighter column (2.4 against
  2.9 ms idle, 0.89 against 0.89 under the storm). The bar's "inside the
  starting commit's own spread" is read against these ranges.
- **The gates the tier runs, timed once on the starting commit** (the
  repository's debug `kajo`, after a build, `base-test-times.txt`): the
  kernel's tests 121 s (255), the development image's tests 158 s (333).

### The starting positions

1. **Right for the product code; the tier is the Swift tier because of one
   test.** The hosts already know a background of a named colour
   (`Sources/KajoApp/TextOffsets.swift` reads `background:<name>`;
   `AppKitViews.swift:589` draws any name but `highlight` at 0.3 alpha,
   `UIKitHost.swift:284` every name at 0.3), and `orange` is a name both
   hosts have (`AppKitHost.swift` `color`, `UIKitHost.swift` `color`). So a
   diagnostic is `background:orange`: pale, not the compile error's
   `background:red`, not the debugger's `background:highlight` (open
   question 1). No primitive and no new request: the request and the event
   exist. One answer of an existing request grows: `method.source` of a
   signature without a method answers its text with `signature` true
   (`DevSession>>methodSource:selector:side:`, kernel), because nothing else
   gives the browser a signature's text and the brief asks it to show one.
   The brief's one test against a real target (no fake) needs the tools'
   test shell, which is `Tests/KajoCompilerTests/ToolsTests.swift` with its
   probe `Fixtures/toolsprobe/ToolsProbe.class.st`: a change under `Tests/`
   makes `check-tier.sh` choose the Swift tier. No file under `Sources/`
   changes; the tier is run as the Swift tier, and the Smalltalk tier's
   gates that the Swift tier lacks (the two image builds, the development
   image's tests, golden, the Mac shell's tests mode) are run by hand on the
   same commit.
2. **Right, and already built by Types 2.** `DevClient>>diagnostics:selector:
   side:then:` and its row in `DevClient class>>requests` exist, and
   `DevClientTest>>testEveryRequestHasItsMessage` counts the one request of
   another package only where `TypeService` is. It passes in a development
   image built with and without `--with types` (`base-notypes-devclient.txt`:
   16 of 16 in each).
3. **Right that nothing should wait; the time is far under the timeout on
   the mini.** The first request is 1.7 s headless and 1.9 s in the Mac
   shell against the client's 30 s; a Debug app's 2.6 to 4.0 times gives 5
   to 8 s, which still fits; a phone's Debug app was not measured (no device
   in this module). Decided: the browser's request is a reply like any other
   (nothing waits for it); a timeout fails it quietly (no status line, the
   error kept for the tests as `diagnosticsFailure`), and the marks come with
   the next class selection, accept or event. A diagnostics list, which the
   developer asked for, says its error on the status line.
4. To be built (part 2): the refusal is remembered by the client per session
   (`DevClient>>refuses:`), for any kind the target answers "unknown request
   <kind>:".
5. **Right.** `start` and `end` are byte offsets in the method's installed
   source, from 0, `end` exclusive; the styles are byte offsets from 1, both
   ends in. `offsets/offsets.txt`: a method of 58 bytes and 53 scalars
   (`é`, `ü`, `✓` and `ä` before or in the send) gets a `dnu` at start 49,
   end 58, and bytes 50 to 58 are the send `'ä' zork` exactly; its byte offset
   is 49, its scalar offset 44. So a mark is `{start + 1. end. style}`, and
   the source the browser shows (`method.source`, `Smalltalk sourceOf:`) is
   the source the checker read (`installedEqual=true`).
6. to 8. Built and measured in parts 3 to 5 and 7.
9. Measured in part 6, before each change is kept.

### Types 2's question 4: typed methods over typed methods

`overrides/overrides.txt` (`T3Measure overrides`): of the image's 617 typed
methods (a type in the pattern), 155 override something typed: 152 the first
method of their selector above their class with a type, 3 a signature
without a method (`Interval>>at:`, `OrderedCollection>>at:` and `at:put:`
over SequenceableCollection's); none overrides an untyped method and 462
override nothing. Three rows checked by hand: `Array>>asArray ^<Self>` over
`Collection>>asArray ^<Array[E]>` (ArrayedCollection and
SequenceableCollection define none); `Association>>= anObject <Object>
^<Boolean>` over `Object>>=` (Magnitude defines none);
`ArrayedCollection class>>new ^<Instance>` over `Behavior>>new ^<Instance>`
(through the metaclass chain: no `new` in SequenceableCollection class,
Collection class, Object class, Class or ClassDescription).

### Decided

- **The mark** (open question 1): `background:orange` over the range, the
  whole first line when a diagnostic has none (a signature's, a `checker`
  one), the compile error's red line drawn after it so it wins where they
  meet.
- **Marks in the selectors table** (open question 2): yes, with one change.
  The class-scope request is 2.2 to 3.7 ms headless but 7.9 to 11.7 ms (p50
  9.4) in the Mac shell, at the bar's 10 ms. Its time is
  `TypeService classKeysOf:`, a scan of every checked key of the image for
  the class's prefix (2.3 ms of the 2.4 in the target, where one method is
  20 µs). Part 3 reads the class's own selectors and signatures instead
  (`TypeService keysOfClass:`, the scan kept for a removed class) and is
  measured again. With that, the browser asks **one class-scope request per
  class selection** (and after an accept, and after an event that names the
  class): the selectors' marks and the shown method's come from the same
  reply, so showing a method asks nothing, and a window has at most one
  request outstanding.
- **The checker's start** (open question 3): the first request, which with
  this module is the first class selection of a session's first browser;
  1.7 to 1.9 s on the mini, in the background of the target.
- **The list's keys**: two Smalltalk menu items bound in the browser's source
  pane, Type diagnostics of the class (⇧⌘E) and of the image (⇧⌘D), free in
  every menu (`DevTools` lists them); no option-key combination, whose
  character AppKit turns into a dead key.
- **A signature without a method** is shown read-only (`#signature`): an
  accept of it says the browser does not change signatures yet, rather than
  compiling the bare pattern into a method that answers self.

## As built (2026-11-19)

Built on the mini with swiftly's swift.org 6.4.2 the first Swift on PATH.
Commits on master after ef2f0f2: 7c84479 (part 1), 0e08b2e (part 2),
47d3f07 (parts 3 to 5), cf36665 (part 6), and this doc. Work files in
`~/kajo-scratch/types-3/` (`part1/`, `measure/`, `broken/`, `work/`,
`check/`, `scripts/`). No file under `Sources/` changed; `Tests/` gained one
test and its probe (the tier is the Swift tier, part 1).

### What was built

- **The client** (part 2, `tools/Client/DevClient.class.st`): a kind the
  target answers as "unknown request <kind>:" is remembered for the session
  (`refuses:`, `noteRefusal:of:`): it is not sent again, a request of it
  fails at once with "the target refused it earlier in this session", and a
  new session (the session reply, a reconnect's included) forgets it. The
  request method and its table row were Types 2's. `FakeDevClient` answers
  the request (`diagnostics:`, `diagnostic:class:side:selector:line:start:
  end:text:`, `refuseDiagnostics`) and emits the event
  (`diagnosticsChanged:`), and has `lastId` to answer a held request.
- **The browser** (part 3, `tools/Models/BrowserModel.class.st`,
  `tools/Windows/BrowserWindow.class.st`): one class-scope `diagnostics`
  request when a class is selected, after a method is accepted and after a
  class definition is accepted; at most one outstanding (one wanted
  meanwhile is asked when the reply comes); its reply holds both sides of the
  class (`classDiagnostics`), from which the selectors table's marks
  (`diagnosedSelectors`, a "  ⚠" after the selector) and the shown method's
  diagnostics (`diagnostics`, filtered by side and selector) come, so showing
  a method asks nothing. The window marks each diagnostic with
  `background:orange` over `{start + 1. end}` (the whole first line, its line
  feed included as the compile error's line is, when it has no range), the
  compile error's red line drawn after it; the status line says
  "N type diagnostic(s): <the first one's text>" when a method with
  diagnostics is shown or its diagnostics arrive, unless a compile error is
  named. The marks follow a three-state `marks`: `#shown`; `#dropped` at the
  first edit of the text (`BrowserWindow>>edited` tells the model before it
  colours); `#awaiting` after an accept, until the diagnostics reply that
  follows it. A reply for a class no longer shown is dropped. A target that
  refused the request is not asked again in the session and nothing reaches
  the status line; a failed request (a timeout, a class gone) is kept as
  `diagnosticsFailure` and dropped. A signature without a method is shown as
  `#signature` (`method.source` answers it, below), marked, and accepting it
  says the browser does not change signatures yet.
- **The list** (part 4): the Smalltalk menu's items 20 "Type diagnostics of
  the class" (⇧⌘E) and 21 "Type diagnostics of the image" (⇧⌘D), bound in the
  browser's source pane (`DevTools smalltalkItems`, `paneKeys`,
  `BrowserWindow>>sourceKey:`), so they are in its context menu and in Help >
  Keyboard Shortcuts. `BrowserModel>>listDiagnostics:` fills the messages
  window the senders use with four columns (Class, Side, Selector,
  Diagnostic), one row per diagnostic, the title "type diagnostics of
  <class or the image>: <count>" (the reply's count), and a row goes to its
  method (`selectMessageAt:`; a diagnostic of a class's own types goes to
  the class). Senders or implementors replace it (`showMessages:title:`), and
  its window closing (`listClosed`) ends it. A list asked of a target without
  the checker says so on the status line.
- **Live** (part 5): the browser's listener on `diagnostics.changed`
  (`listen`, from its first request; removed in `closed`) asks again when the
  event names a method of the shown class (`Foo>>…` or `Foo class>>…`) or
  is cut short (`truncated`), and asks the list again when it is the image's
  or the event names its class. A malformed event asks nothing.
- **In the kernel and the checker**: `DevSession>>methodSource:selector:side:`
  answers a signature without a method (its text, category, package and
  `signature` true) where there is no method; `TypeService keysOfClass:`
  makes the class scope read the class's own methods and signatures (the scan
  `classKeysOf:` stays for a removed class); `DevProtocol class>>describe` is
  made from the request methods themselves and `run:in:with:replyTo:` answers
  an error when the request's method is gone (part 6's guards, below).
- **The annotation pass** (part 6): `Collection>>species ^<Self class>`,
  `OrderedCollection>>species ^<Self class>` (it has no subclass; Interval
  keeps `^<Behavior>`), `BlockClosure>>ifError: aBlock <[^Dynamic] |
  [String, ^Dynamic] | [String, Object, ^Dynamic]>`, and `TestCase>>tags`
  answers none for a test whose selector names no method.
- **Tests**: `DevClientTest` 2 (the request's line, result and event; the
  refusal remembered and asked once per session), `BrowserModelTest` 9,
  `ToolWindowTest` 2, `DiscoverabilityTest`'s context menu list, `TypeCheckerTest`
  2 (species, ifError:), `TypeServiceTest` (the class keys against the scan),
  `DevelopmentTest` 2 (the signature's source; a request whose method is
  gone), `SUnitTest` 1 (tags), and `ToolsTests.theBrowserMarksADiagnosticAndFollowsTheFix`
  (Swift, the real target: a class defined and a method with a `returnType`
  compiled through the browser, the browser holds the diagnostic with its
  mark, its row mark and its status line, the fix accepted, the browser
  holds none and the event that named it came; the waits on the browser's
  state with `typesWait`; the checker started without the whole check, the
  reason in the probe: under the sanitizer a whole check took 1116 s of one
  request in Types 2). The development image has 351 tests (333 before), the
  kernel 258 (255).

### The starting positions, answered

1. **Right for the product code, with one grown answer; the tier is the
   Swift tier** (part 1): `background:orange`, no primitive, no new request;
   `method.source` answers a signature's text; one test under `Tests/`.
2. **Right, already built by Types 2** (part 1). After this module the map
   check passes in the development image (351 of 351, `work/head-dev.img`)
   and in one built without `--with types` (318 of 318, the 33 the Types
   package brings left out), both by the aligned release `kajo`.
3. **Right**: the first request takes 1.7 s headless and 2.0 s in the Mac
   shell against the client's 30 s, and nothing waits for it. Five interleaved
   launches each of the starting commit and the head
   (`measure/rt/base-*.txt`, `head-*.txt`, the same `kajo` binary, images of
   each tree): the first request 1680 to 1691 ms on the base, 1739 to 1746 ms
   on the head (3243 methods and signatures against 3181: this module's code
   and tests, 62 more to check); in the target alone 1766 ms
   (`measure/target/target.txt`). In the Mac shell (`measure/shell-diag.txt`,
   three launches each, interleaved): 1904 to 1936 ms on the base, 1969 to
   2032 ms on the head. When it times out (a slow target, a sanitizer) the
   browser drops it quietly (`diagnosticsFailure`), the late reply is dropped
   by the client (no pending entry), and the marks come with the next class
   selection, accept or event (`testAFailedRequestIsDroppedAndAskedAgainLater`).
4. **Built**: asked once per session, nothing on the status line, the browser
   as before (`testATargetWithoutTheCheckerIsAskedOnceAndSaysNothing`:
   five selections, a side change and an event make one request; a new
   session asks once again).
5. **Right** (part 1, `part1/offsets/offsets.txt`), and the window test
   checks a mark after four extra bytes of multi-byte characters
   (`ToolWindowTest>>testTheSourceMarksEachDiagnosticAtItsBytes`).
6. **Built as written**, with the accept's own state: the marks go at the
   first edit and stay away through the accept until the diagnostics reply
   that follows it (`#awaiting`), so offsets of the old text are never drawn
   on the new.
7. **Built, with the class as the unit**: the browser asks again when the
   event names any method of the shown class (its selectors table shows them
   all), not only the shown method; a list when it names its class or the
   list is the image's. A burst of five events while a request is
   outstanding makes no request until the reply, then one
   (`testABurstOfEventsMakesOneRequest`).
8. **Right: the typing rows are inside the starting commit's own spread.**
   Five interleaved launches of each (`measure/typing-none.txt`,
   `typing-storm.txt`, the table `measure/typing-table.txt`, thermal nominal
   on every line), beside part 1's base against itself:

   | load | side | key to redraw p50 ms | p99 ms | max ms | colour p50 ms | colour p99 ms | missed |
   |---|---|---|---|---|---|---|---|
   | none | base | 5.7 [4.6–7.4] | 8.4 [7.2–19.0] | 16.1 [7.8–20.9] | 3.0 [2.7–4.3] | 6.2 [5.2–9.5] | 39 [3–195] |
   | none | head | 5.0 [4.5–8.4] | 7.9 [6.9–9.0] | 9.6 [7.9–10.5] | 2.8 [2.6–4.5] | 6.5 [5.1–7.3] | 26 [1–88] |
   | none | part 1, base A / B | 5.4 / 8.1 | 8.6 / 9.4 | 16.5 / 11.1 | 2.4 / 2.9 | 7.1 / 6.1 | 25 / 2 |
   | storm | base | 3.3 [2.6–6.2] | 3.5 [3.0–6.3] | 6.9 [6.5–6.9] | 1.03 [1.02–1.83] | 1.9 [1.3–4.0] | 1 [1–1] |
   | storm | head | 3.3 [1.4–7.9] | 4.8 [1.9–8.0] | 8.3 [7.1–11.6] | 1.02 [0.99–3.22] | 1.9 [1.3–5.0] | 1 [0–186] |
   | storm | part 1, base A / B | 8.2 / 3.3 | 8.2 / 5.9 | 8.6 / 6.6 | 0.89 / 0.89 | 4.2 / 1.4 | 0 / 1 |

   Every head median lies between the two medians of the base against itself
   or within the base's range; the one storm launch of the head that missed
   186 frames has its like in part 1 (a base launch missed 197). The head's
   browser asks the class's diagnostics when it opens the method, so the
   first request's whole check runs in the image while the typing starts;
   the longest turn is unchanged (14.0 to 15.6 ms against 13.9 to 15.8).
9. **Wrong for `species`, right for `ifError:`.** Each change measured on the
   whole development image before it was kept (`T3Measure image`, the
   aligned release `kajo`; raw files in `measure/ann-*`):

   | step | diagnostics | known receivers | known results | file |
   |---|---|---|---|---|
   | the tools' code of parts 2 to 5 (after one of its own was fixed: a `maybeNil` in `diagnosticStylesIn:`'s first version) | 81 | 15 879 | 10 668 | `ann-0-tools/` |
   | `Collection>>species ^<Self class>` | 81 | 15 890 | 10 684 | `ann-1-collection/` |
   | and `OrderedCollection>>species ^<Self class>` | 81 | 15 890 | 10 684 | `ann-2-species/` |
   | `BlockClosure>>ifError:` with a union of three block types | 76 | 15 890 | 10 684 | `ann-3-iferror/` |
   | the three `lookupSelector:` results (part 6) | 73 | 15 964 | 10 733 | `ann-4-guards/` |
   | the final code | 73 | 16 002 | 10 763 | `final-image/` |

   `species` removes no diagnostic: Types 2's rule that a value typed only as
   some Behavior makes Dynamic instances had already answered the slice's
   `self species new:` diagnostics, so `^<Self class>` types 11 more
   receivers and 16 more results instead (`c species new` is now the
   receiver's class, `TypeCheckerTest>>testSpeciesIsSelfClassWhereItIsTrue`).
   `ifError:` removes the five `arity` diagnostics of `BlockClosureTest>>
   testIfError` and adds none; a block of three arguments is still a
   diagnostic, `argType` rather than `arity` (it is none of the union's
   three). The kernel's own `species` methods outside the brief (String's,
   Symbol's, Utf8View's) carry no type and were left so.

### The image's diagnostics, before and after

81 on the starting commit (`part1/image-1/`), 73 on the final code
(`measure/final-image/image-diagnostics.txt`; the request answers the same
count, `measure/rt/head-1.txt`). By class, before → after: TypeCheckerSample
20 → 20, OrderedCollection 9 → 9, Interval 7 → 7, BlockClosureTest 7 → 2,
DiscoverabilityTest 5 → 5, LiveCompileTest 4 → 4, DevelopmentTest 4 → 4,
ObjectTest 3 → 3, TypeCheckerNarrowSample 2 → 2, String 2 → 2, FractionTest
2 → 2, Fraction 2 → 2, ExceptionTest 2 → 2, DevProtocol 2 → 0, ByteArray 2 → 2,
TestCase 1 → 0, and WriteStream, ReflectionTest, OrganizationTest, Number,
IntegerTest, Float and Collection 1 → 1. The 8 that went: the five `arity`
of `testIfError` and the three `maybeNil` of the unguarded lookups.

The slice's 27 classes keep their 24, each as Types 2 classified it
(`final-image/image-diagnostics.txt` against Types 2's list): 19 of the
experiment's 20 limits (OrderedCollection's nil slots 8 and
`add:beforeIndex:` 1; `Interval[N]` without a bound 5, in `last:` twice,
`setFrom:to:by:` and `size` twice; `Collection>>sum:` 1; `String>>splitOn:`'s
union 2; `WriteStream>>nextPutAll:`'s `byteSize` 1; `Fraction>>coerce:`'s
`asFraction` 1); the 3 limits of Self from arithmetic (`Number`, `Float` and
`Fraction>>negated`); the 1 method variable without a bound
(`Interval class>>from:to:by:`); and the 1 narrowing signature
(`Interval>>select:`). The rest of the 73: 22 written on purpose in the
checker's samples, 25 in kernel and tools tests (faults on purpose, methods
compiled at run time), ByteArray's E 2.

The three lookups (part 6): `TestCase>>tags` answers none for a test whose
selector names no method (`SUnitTest>>testATestWithoutItsMethodHasNoTags`
reaches the nil); `DevProtocol class>>run:in:with:replyTo:` answers an error
when the request's method is gone since `take:` chose it
(`DevelopmentTest>>testARequestWhoseMethodIsGoneIsAnErrorReply` reaches the
nil by running a selector no method has); `DevProtocol class>>describe` is
made from the request methods the pragmas name, so it looks nothing up again
(the nil could come only from a request method removed between the table's
rebuild and the lookup, by another Process; the same test checks every
entry names a method).

### Round trips, before and after

| scope | headless base ms | headless head ms | in the target, head | Mac shell base ms | Mac shell head ms |
|---|---|---|---|---|---|
| the first (any scope) | 1680–1691 | 1739–1746 | 1766 | 1904–1936 | 1969–2032 |
| one method | 0.17–0.27 | 0.17–0.28 | 0.019–0.024 | 0.34–0.42 | 0.36–0.46 |
| one class (TypeCheckerSample, 44) | 2.84–3.39 | 0.96–1.09 | 0.30–0.31 | 4.5–10.8 (p50 9.4) | 2.4–9.9 (p50 2.5) |
| String (81) | 2.12–2.18 | 0.32–0.38 | 0.16 | | |
| the image (3172 / 3243) | 6.42–6.96 | 6.15–6.73 | 4.3–4.8 | 17.6–26.7 | 16.9–26.2 |

Headless: five rounds in each of three launches per side, interleaved
(`measure/rt/`); the Mac shell: five rounds in each of three launches per
side, interleaved (`measure/shell-diag.txt`, the session's `diagnostics`
array). `TypeService keysOfClass:` agrees with the scan for all 239 classes
of the image after a whole check and takes 3.7 ms for all of them against
the scan's 467 ms (`measure/classkeys/classkeys.txt`). The Mac shell's round
trips have a second mode near 9 ms (the base's class scope in 14 of 15
rounds, the head's in 4 of 15) that the headless ones lack; not explained
here (found, below).

### The real target in the Mac shell

The bar asks for the mark in the Mac shell's tests mode, which runs the
kernel image only (`Sources/KajoShellCore/Modes.swift`, `TestsMode` makes its
runtime from `resources.kernelImage`), so the tools' tests cannot run there
without a Swift change. In its place, the head's Release app with the scratch
bench (`scripts/patch-bench.py`, its `showDiagnosed` step) opened the tools
on the image's own socket and the browser on `TypeCheckerSample>>badReturn`
in the AppKit views (`measure/shell-shown.txt`, `"shown"` in the session's
JSON): 1 diagnostic, the status line "1 type diagnostic: answers String |
Nil where String is declared", the window's mark `[24, 27,
"background:orange"]` over `name` in "badReturn ^<String>\n\t^ name\n", and
the selector marked in the table. In the tools' tests the same holds against
fakes (`ToolWindowTest`) and against the real target in the test shell
(`ToolsTests.theBrowserMarksADiagnosticAndFollowsTheFix`, body 1.1 s,
`work/toolstests-2.txt`).

### Typed methods over typed methods

155 of 617 typed methods (part 1, unchanged by this module's code: the
count is of the kernel's patterns).

### Broken variants (run by hand, `scripts/broken.sh`, `scripts/broken.py`, outputs in `broken/`)

| variant | the check that failed |
|---|---|
| the model keeps the marks after an edit (`keep-marks.txt`) | `BrowserModelTest>>testAnAcceptAsksAgainAndTheFirstEditDropsTheMarks`: "Expected #dropped but was #shown"; `ToolWindowTest>>testTheSourceMarksEachDiagnosticAtItsBytes`: "Denial failed" (the orange still there after the edit) |
| the event handler asks again on every event (`every-event.txt`) | `testABurstOfEventsMakesOneRequest`: "Expected 2 but was 6" (the five events each asked) |
| the unknown request asked again at every selection (`ask-again.txt`) | `testATargetWithoutTheCheckerIsAskedOnceAndSaysNothing`: "Expected 1 but was 5"; `DevClientTest>>testAnUnknownRequestIsRememberedAndAskedOncePerSession`: "Assertion failed" |
| the offsets taken as characters and turned into bytes (`characters.txt`) | `ToolWindowTest>>testTheSourceMarksEachDiagnosticAtItsBytes`: "Assertion failed" (the mark four bytes late) |
| no guard in `run:in:with:replyTo:` (`no-run-guard.txt`) | `DevelopmentTest>>testARequestWhoseMethodIsGoneIsAnErrorReply`: "nil does not understand #hasPragma:" |
| no guard in `TestCase>>tags` (`no-tags-guard.txt`) | `SUnitTest>>testATestWithoutItsMethodHasNoTags`: "nil does not understand #pragmas" |

The brief named the fourth "the offsets are taken as bytes"; bytes are the
right unit (position 5), so its broken variant takes them as characters.

### Deviations

- **The tier is the Swift tier**: the brief's real-target test lives in
  `Tests/KajoCompilerTests/ToolsTests.swift` with its probe (part 1). No file
  under `Sources/` changed. The Smalltalk tier's gates were run by hand on the
  same commit (below).
- **One class-scope request per class selection, not one per method shown.**
  The brief has the model ask for the shown method's diagnostics when a
  method is shown and after an accept; part 1's round trips made the class
  scope cheap enough for the selectors' marks (open question 2), and the
  shown method's diagnostics are then a filter of the same reply. So the
  browser asks at a class selection, after an accept (of a method or a class
  definition) and after an event naming the class; showing a method asks
  nothing.
- **An event naming another method of the shown class asks again** (the
  selectors table shows that method's mark); one naming another class does
  not.
- **`method.source` answers a signature without a method**, the one way the
  browser can show one; no new request.
- **`TypeService keysOfClass:`** in the Types package, decided in part 1 from
  the Mac shell's 9.4 ms.
- **The real-target test starts the checker without the whole check**
  (`TypeService startCheckingAll: false` from the probe, which names
  TypeService; the probe is a test fixture, not `tools/` or `kernel/`), the
  reason beside it: a whole check under the sanitizer took 1116 s of a
  request in Types 2, and the first request's time is measured apart. The
  other tools tests in `ToolsTests` now start the whole check when their
  browser first selects a class; it runs in their VM's background and ends
  with the VM.
- **`DevProtocol class>>describe` was restructured** (made from the request
  methods), not guarded: it then looks nothing up and has no nil to guard.
- **The fourth broken variant takes the offsets as characters**, since bytes
  are the right unit.
- **The bar's Mac shell tests mode** runs only the kernel image; the mark was
  shown in the Mac shell's own views through the scratch bench instead (The
  real target in the Mac shell, above).

### Not done

- The first request on a phone or in a Debug app (no device in this module;
  2.6 to 4.0 times the Mac's 1.7 s for a Debug app is 5 to 8 s, inside the 30
  s timeout, not measured).
- An underline in place of the background (a Swift change in both hosts;
  open question 1).
- Changing or adding a signature from the browser (shown read-only).
- The narrowing check for a typed method over a typed one: only its count
  (155).
- Diagnostics in the workspace, the debugger and the inspector (out of the
  brief).

### Found, not this module's

- **The Mac shell's round trips have a second mode near 9 ms** that the
  headless ones do not: the base's class scope in 14 of 15 rounds, the
  head's in 4 of 15 (`measure/shell-diag.txt`), one method's never. Not
  explained; one guess to test is the client's reply waiting for the main
  thread's next turn behind a frame.
- **The test shell's view host does not keep a text view's styles**:
  `(sourceView get: 'styles')` answered 0 in `ToolsTests`' `ToolsShell` while
  the headless wrapper answers the styles; the probe's first version read it
  and its Process stopped on `0 includes:`. The probe now asks the window
  for its marks. The 9c lesson (read-backs a host has no get for) again.
- The nil in `DevProtocol class>>run:in:with:replyTo:` was reachable before
  this module: a request whose method another request removed got a
  doesNotUnderstand of nil in its Process (a stop, in a host that stops for
  the debugger), not an error reply. Fixed in part 6 as the brief asked.

- **`ShellCloseTests.aShellClosedWithADelayPendingFreesItsVM` is thin**: it
  failed once in the Smalltalk tier's `compiler-tests` (Gates, below) by
  reading the Process's state right after the Delay's timer was armed.

### Open questions (built as recommended where there was one)

1. **The mark's look.** Built: `background:orange`, pale on both hosts.
   Recommended: keep it until an underline is wanted, which is a Swift change
   in both hosts.
2. **Marks in the selectors table.** Built: yes; the class scope is 0.3 ms in
   the target, 1.0 ms headless and 2.5 ms p50 in the Mac shell after part 3's
   class keys (9.4 ms before). Recommended: keep.
3. **The checker's start.** Built: the first request, which is now a
   session's first class selection; 1.7 s headless and 2.0 s in the Mac
   shell, in the target's background. Recommended: keep.
4. **The first request's timeout on a slow target.** The client's 30 s
   covers the Mac and, by the Debug factor, a Debug app on the Mac; a phone's
   Debug app is not measured. Recommended: measure the first request on the
   iPhone in the next device run before giving this request a bound of its
   own; until then a timeout only delays the marks to the next selection.
5. **Typed methods over typed methods.** 155 of 617 typed methods override
   something typed (152 a typed method, 3 a signature). Recommended: measure
   what the narrowing rule would report on them (the count of
   contradictions, not of overrides) before deciding to build it.

### Other checks

- `scripts/canonical-tonel.sh --check` lists nothing (rc=0) after the last
  Tonel edit.
- The kernel's tests 258 of 258, the development image's 351 of 351 and a
  development image without `--with types` 318 of 318 (aligned release
  `kajo`, `kajo test`; `work/head-kernel-tests.txt`, `work/head-dev-tests.txt`).
- The changed Swift suites (`ToolsTests`, `TypeCheckerTests`) once under
  ThreadSanitizer with twelve busy loops (`scripts/tsan-load.sh`,
  `work/tsan-load.txt`): 13 tests passed, 0 sanitizer reports, 1753 s; the
  new test's body 44.7 s there (1.1 s without the sanitizer,
  `work/toolstests-2.txt`).
- `ToolsTests.aClassDefinedIntoATagFromTheBrowserMovesWithItsTag` (the thin
  test named in the brief) passed in every run of the suite here.

### Gates

`KAJO_CHECK_OUT=~/kajo-scratch/types-3/check just check ef2f0f2` on cf36665
(the last code commit): the Swift tier (chosen by
`Tests/KajoCompilerTests/ToolsTests.swift`, `TypeCheckerTests.swift` and the
probe; no fuzzer's reader touched), 6 gates, every one `rc=0`, 4 329 s
(`check/gates.log`; swift.org 6.4.2 first on PATH). Against Types 2's run of
the same tier (7ac2711, 4 384 s with `check-tier-test` and two fuzzers this
run did not owe):

| gate | s | 7ac2711 |
|---|---|---|
| clean-build | 20 | 20 |
| swift-test (471 + 185 tests) | 714 | 696 |
| tsan (0 reports) | 3 074 | 3 017 |
| kernel-test (258 tests) | 121 | 119 |
| apps (0 warnings, 0 errors) | 130 | 133 |
| new-check | 270 | 268 |

`new-check` (`check/new-check.txt`, `measure/checker-classes.txt`):
`checker_classes=0 signature_text=0` on macos-release, macos-release-off,
ios-release and ios-release-off; `checker_classes=441 signature_text=2` on
macos-debug (the count of byte lines naming TypeChecker or MethodTypeCheck,
437 in Types 2; not read further). The new tests cost about 18 s of `swift-test` and 57 s of `tsan`
(the new test 45 s under the sanitizer; the other tools tests now start a
whole check in their VM's background).

The Smalltalk tier's gates, which the Swift tier lacks, run on the same
commit (`scripts/check-tier.sh --tier smalltalk ef2f0f2`,
`check/smalltalk/gates.log`): build-image 3 s, dev-image 3 s, kernel-test
120 s (258), tools-test 159 s (351 of 351; the starting commit's 158 s for
333, part 1), golden 78 s (every kernel ok), the Mac shell's tests mode 90 s
(258 of 258), all `rc=0` but **compiler-tests, `rc=1` in 81 s: one failure
not this module's**, `ShellCloseTests.aShellClosedWithADelayPendingFreesItsVM`
at `ShellCloseTests.swift:74` (`vm.state(of: p) == .waiting` read right after
`timersPending == 1`: the Delay arms its timer before its Process waits on
the Semaphore, so the state can still be running; the "wait on what the
program set, not on the state" lesson). It passed in the Swift tier's
`swift-test` and `tsan` on the same commit, 8 of 8 alone
(`work/shellclose-alone.txt`), and the whole `KajoCompilerTests` passed when
run once more (`check/smalltalk/compiler-tests-again.txt`, 185 of 185, 85 s).
No Swift file of the shell or the VM changed in this module.
