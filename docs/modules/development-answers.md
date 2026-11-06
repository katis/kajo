# Development answers (a follow-up to module 9b)

Status: brief, 2026-11-06. From the owner's answers to module 9b's open
questions (`docs/modules/development-protocol.md`, "The owner's answers
(2026-11-06)"). The module that builds this rewrites the file as the
as-built description.

Three changes:

1. A development image stops the Process of an unhandled error whether or
   not a client is connected, so a client that connects later finds it.
2. The author mark of a method a session made is a pragma, not Tonel
   method metadata.
3. A `terminate` whose unwinding was cut off at its bound is never silent.

Decided and needing no work: a method that only sends may join a sealed
class; an agent's session has the developer's rights for now.

## What it hides

When an error becomes a debugger. Smalltalk code and the tools see one
rule (an unhandled error in a development image stops its Process until
someone decides) and do not learn whether a client was there, whether the
protocol had started, or which host runs the image.

## 1. Stopping without a client

As built in 9b, `UnhandledError>>defaultAction` sends `Debugger stop:`
only while the protocol serves; otherwise the error is reported and the
Process ends. Since module 11a a development app serves from launch, so
for apps the gap is the time before serving starts and any host that
never serves.

**The rule:** in a development image, an unhandled error stops its
Process as a `DebugStop` wherever a debugger can still come. A release
image is unchanged. What "can still come" means is the design question,
because some hosts run a development image to completion with nobody to
ask:

- `kajo build-image` (a build step that dies must fail the step, as 8d
  fixed), `kajo test` and the shells' tests mode (a forked Process's
  unhandled error must be a reported failure, never a run that waits
  forever), `kajo run` without `--protocol`, the golden and scenario
  modes, the fuzz targets. These keep report-and-end.
- An app's development build, the shells' `mode=dev`, `mode=serve` and
  `mode=devsession`, `kajo run --protocol`: these stop.

Decide how a host says which it is (one setting the host makes before it
resumes the image, read by `defaultAction`; not a guess from whether a
socket is open), make the default the safe one for a batch host, and list
every host with its choice in the doc. No host may hang on a stop nobody
can reach: for each batch host a test runs an image whose forked Process
dies in an unhandled error and asserts the host ends with the report.

What stopping without a client needs that stopping with one did not:

- **A later client finds it.** `process.list` shows the stop as it does
  today; decide whether a new session is also sent `process.stopped` for
  each standing stop when it connects (the tools' debugger opens from that
  event) and build what the tools need to open a debugger on a stop that
  predates them. Test end to end: an error with no client, a client
  connects, sees the frames, defines the missing method and proceeds.
- **Before serving starts.** An error in the app's own start-up, before
  the protocol's Process runs, stops too, and serving still starts
  (serving cannot depend on the Process that stopped).
- **The event loop.** 9c hands the UI event loop to a new Process when a
  tool's error stops the old one. The same must hold for an app's event
  loop with no client: the app keeps drawing and taking events (frames
  measured, as 9b measured 1200 of 1200 with a stopped event loop).
- **A bound.** A loop that fails on every frame would leave one stopped
  Process per failure for as long as no client comes, each holding its
  stack. Stops are capped (a number with its reason); past the cap the
  newest error is reported and its Process ended as in a batch host, and
  that is counted and reported, never silent. A test fills the cap.
- **A sign.** With no client the developer must still learn something
  stopped: the console line exists; decide whether a development app
  shows it in its window too (the pairing screen is one place) and raise
  the choice as a question rather than build new UI on a guess.
- **Saved images.** A snapshot taken with stops standing holds them (8c
  saves Processes); the resumed image lists them. Test it, or refuse the
  save and say why.

Measure: frames missed in the Mac shell and on the iPhone while an app's
event loop sits stopped with no client for 10 s and after a client then
connects and proceeds; the memory a standing stop holds; the cost of a
full cap.

## 2. The author mark as a pragma

Today: `{ #category : #accessing, #author : #'agent:claude' }` in the
method's Tonel metadata, written only for a method a session made, read
by both Tonel readers. The owner chose a pragma. A pragma is part of the
method's source and its literals, so:

- **The form.** One keyword pragma with a Symbol argument; propose the
  selector (`<author: #'agent:claude'>` is the obvious one) and where in
  the method it is written (after the pattern and its comment, before
  temporaries, as the canonical form writes pragmas).
- **Who writes it.** The session adds it to the source of a method it
  compiles for an author, so the image's source and the file agree byte
  for byte; say what happens when the source already carries an author
  pragma (the same author, another author, a developer's session with no
  author compiling a method an agent wrote). The rule must be one a
  person reading `git diff` can predict.
- **Both compilers** agree on a method with the pragma (`CompilerTest`),
  the pragma index answers "the methods an agent wrote" without a new
  table, and the browser shows it from the method as it shows any pragma.
- **The metadata key goes.** The writer no longer writes `#author`; both
  readers treat it as they treat any unknown key, and the doc says what
  that is. No conversion code stays in the tree: the fixtures and any
  file under `kernel/`, `tools/` and `apps/` that carries the key are
  rewritten in their own commit, and the byte-identity round-trip tests
  hold after it.
- `aSessionsProjectRebuildsTheImageItEdited` still finds every method the
  same bytecode for bytecode and source for source, authors included.

## 3. A cut-off unwinding is never silent

The owner left the bound to the runtime's needs. An app cannot have a
Process that cannot be ended, so the bound stays (`Process
unwindBudgetMs`, 1 s). What is missing is knowing when it was used:

- `terminate` answers whether the unwinding ran to its end; a cut-off is
  counted in the image (a counter a host can read as telemetry), written
  to the Transcript with the Process and the block it stood in, and
  `process.terminate`'s reply says so.
- Check first what 9b already does here and build only the difference;
  say in the doc what was there.
- The debugger's terminate and restart use the same unwinding and report
  the same way.

## Verification

Test first. Every gate on the final code commit, outputs to files,
`gates.log` with the commit of each: a clean build with 0 warnings,
`swift test` alone and under 12 busy loops, ThreadSanitizer alone and
under load, `just ios-check`, `just arc-check`, `just golden`, `just
test-release`, `just model-check`, `just soak`, the four `just fuzz
<target> 600` runs with their "libFuzzer build: ok" lines, `just apps`,
`just kernel-test`, `just new-check`. This should not touch the VM core;
if it does, the aligned A/B and the `interpret` diff as usual. Broken
variants: a batch host that stops (the test run hangs to its bound and
fails), the cap removed, a silent cut-off.

## Decision record

ADR 0011 and ADR 0012 each get a "Built (development answers)" note; the
host table goes into `docs/modules/development-protocol.md`'s "Stopping".
