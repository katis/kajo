# Types 3: diagnostics in the tools

## Status

Briefed by the main session on 2026-11-19. The owner: "Start the next types
module". The records are `docs/decisions/43-optional-types.md`,
`44-types-1.md` and `45-types-2.md` (with the owner's "Approve all" for its
five questions); the checker is `docs/modules/types-2.md`. Starting commit:
the commit that adds this file. Not started.

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
