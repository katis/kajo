# Development answers (a follow-up to module 9b)

Status: built, 2026-11-07 (b029175 to f6024a3, the code; f7a760c the
fixture's rewrite), from the brief of 2026-11-06 (the owner's
answers to module 9b's open questions, `docs/modules/development-protocol.md`,
"The owner's answers (2026-11-06)"). Three changes:

1. A development image stops the Process of an unhandled error wherever
   its host says a debugger can still come, with or without a client, and
   a client that connects later finds it; batch hosts report and end it.
2. The author mark of a method an agent's session made is a pragma,
   `<author: #'agent:<name>'>`, not Tonel method metadata.
3. A `terminate` whose unwinding was cut off at its bound is counted,
   written on the Transcript and said in the protocol's answers.

Decided and needing no work (the brief): a method that only sends may
join a sealed class; an agent's session has the developer's rights for
now.

Code: `Sources/KajoVM/Headless.swift` (`Options.stopsForDebugger`),
`Shell/Shell.swift` (`ShellVM.stopsForDebugger`, `openProtocol`),
`Shell/ShellBridge.swift` (the setting, an `Atomic<Bool>`),
`Shell/ShellPrimitives.swift` and `Interpreter/Primitives.swift`
(primitive 165); the hosts in `Sources/KajoDev/Target.swift`,
`Sources/KajoApp/Application.swift` (`KajoAppRunner.start`,
`ShellVM.isStoppedForDebugger`), `Sources/KajoShellCore/DevModes.swift`
and `Scenario.swift` (and `debugstop=noclient`); the Tonel reader and the
image build's source records in `Sources/KajoCompiler/Tonel.swift` and
`KernelBuilder.swift`. Kernel: `Debugger`, `DebugStop`, `UnhandledError`,
`UIEventLoop`, `DevSession`, `DevProtocol`, `Process`, `Context`,
`Transcript` (`showLine:`), the new `Unwinding`, `Smalltalk`, `Behavior`,
`Pragma`, `TonelWriter`, `TonelReader`, `TonelLoader`, `DevelopmentTest`.
Tools: `DevTools`, `DebuggerModel`, `ToolWindowTest`. Shells:
`ShellBench breakEventLoopOnce`, `failInProcesses:`. Tests:
`Tests/KajoCompilerTests/DevelopmentAnswersTests.swift` with the fixture
`Fixtures/answers/` (package Answers).

## What it hides

When an error becomes a debugger. Smalltalk code and the tools see one
rule, `Debugger stopsErrors` (an unhandled error in a development image
stops its Process until someone decides, unless the stops stand at their
cap), and do not learn whether a client was there, whether the protocol
had started, or which host runs the image. The host says which it is
with one setting before the image resumes; nothing guesses it from a
socket.

## 1. Stopping without a client

### The host's one setting

`Headless.Options.stopsForDebugger` (default **false**, the batch hosts'
answer) is read by `ShellVM` at its open into its bridge
(`ShellBridge.stopsForDebugger`, an `Atomic<Bool>`), and
`ShellVM.stopsForDebugger` reads and sets it from any thread. **Primitive
165** (`Debugger class primHostStopsErrors`) answers it, false in a
release image; with no shell (`kajo run`, `kajo test`, the image build's
`KernelRun`, the fuzz targets: a VM without a `ShellBridge`) it fails and
the kernel answers false, so those hosts cannot stop by construction.
`Debugger stopsErrors` is `Smalltalk isReleaseImage not and: [Debugger
hostStopsErrors]`; `UnhandledError>>defaultAction` reads it and nothing
else. `ShellVM.openProtocol()` (what every serving host calls before
`DevProtocol start`) also turns the setting on: a host that serves is one
a debugger can come to, and a serving host that did not ask before the
resume (a test's shell, the demo's `protocol=`) still stops. `DevProtocol
start` no longer enables anything; `Debugger enable`, `disable` and
`isEnabled` are gone.

The hosts and their choice (also in `docs/modules/development-protocol.md`,
"Stopping"):

| host | setting | where |
|---|---|---|
| `kajo build-image` (`KernelRun`) | reports and ends: no shell | test `theImageBuildsHostReportsAndEndsAForkedProcessError` |
| `kajo test` (`Headless.test`) | reports and ends: no shell | `kajoTestReportsAndEndsAForkedProcessError` |
| `kajo run` without `--protocol`, the shells' golden mode (`Headless.run`) | reports and ends: no shell | `kajoRunReportsAndEndsAForkedProcessError` |
| the fuzz targets | no shell, no Process of the image runs to a stop | by construction |
| the shells' tests, scenario (without `debugstop`), spin, demo without `protocol=` | `ShellVM` with the default false | `aShellVMWithTheDefaultSettingReportsAndEnds` |
| a release app, any release image | false; the primitive answers false in a release image whatever the host says | `aReleaseImageNeverStops` |
| `kajo run --protocol` (`DevTarget`) | true, set by `DevTarget` | `aSavedImageKeepsItsStops`, the 9b tests |
| an app's development build (`KajoAppRunner` with a development half) | true before the image resumes, the app's `open` included | `anAppsStartUpErrorStopsAndServingStillStarts` |
| the shells' `mode=dev`, `mode=devsession` | true in their options | (9c's tools tests) |
| the shells' `mode=serve`, `protocol=tcp`, `debugstop=1`, `debugstop=noclient` | true in the scenario's options | the measurements |
| the demo with `protocol=`, a test's serving shell | turned on by `openProtocol` | `anErrorInAToolStopsOnlyItsProcessAndTheToolsGoOn` |

For each batch host a test runs an image whose forked Process dies in an
unhandled error (`AnswersProbe forkFailureAndWait`: the forked Process's
`missingPart` doesNotUnderstand:) and asserts the host ends, with the
report on the Transcript where the host has one (`Unhandled
MessageNotUnderstood`, then the frames), within a bound (`within`, 120 s,
600 under ThreadSanitizer) past which the test fails rather than waiting
with a hung host.

### A later client finds it

A stop is registered as before (`Debugger`'s table, `process.list`). New:
the stopped Process itself makes its `process.stopped` summary when it
parks (`DebugStop>>noteSummary`: its Contexts are live only to it), and
**session.open's answer lists every standing stop** (`stopped`: the
summaries, by Process id) as the event would have said it. Chosen over a
`process.stopped` event replayed to each new session: the transport
routes events to every session or a reply to one connection, and the
answer to the session's own `session.open` is the one line that reaches
exactly the new client, before any event, with no race between the list
and a stop that happens meanwhile (a later stop is an event as before).
The tools read it: `DevTools standingStops:client:` opens a debugger, as a
`process.stopped` event would, for each listed stop on every
`connection.open`, the first one and every reconnect (a stop that happened
while the link was down included); `ToolWindowTest>>testTheStopsStandingWhenTheSessionOpensOpenDebuggers`.
The CLI and MCP print the answer as it is.

End to end (`anErrorWithNoClientStopsAndALaterClientFindsIt`): a shell VM
with the setting on and no protocol; a forked Process stops at
`AnswersSample>>missingPart`; the host then serves; a client's session
answer lists the stop (reason, error, frames), `process.frames` shows
`AnswersSample>>compute`, `method.compile` defines `missingPart`,
`process.retrySend` re-sends it, and the Process finishes with 42.

### Before serving starts

`KajoAppRunner.start` sets the setting before the image resumes when it
has a development half, so an error in the app's own `open` stops it. The
runner used to wait up to 10 s for `open` to end; it now also stops
waiting when the Process stands stopped (`ShellVM.isStoppedForDebugger`:
`Debugger isStoppedProcessId:` asked in a Process of its own, only while
the open Process is waiting), writes one console line (`<app>: <class>
open stopped for the debugger (process N)`) and tells the development
half, which serves: serving does not depend on that Process. Test
`anAppsStartUpErrorStopsAndServingStillStarts`: `AnswersApp open` sends
`startUpValue`, nothing defines it; the development build serves; a
client's session lists the one stop, defines `AnswersApp
class>>startUpValue`, retries, and the app finishes opening (`started` is
7).

### The event loop

9c's hand-over is unchanged but for its condition: `UIEventLoop
dispatch:` hands the loop to a new Process and passes the error on when
the erring Process is the loop's and `Debugger canStop` (the setting, and
the stops under their cap); otherwise the error goes to the Transcript and
the loop goes on, as in a batch host. So an app's handler that fails with
no client leaves the old loop stopped and the app drawing and taking
events (`theEventLoopHandsOverWithNoClient`: a synthetic event's handler
fails, the next event is handled by a new loop Process, the old one
stands stopped; measured below).

### The cap

`Debugger stopCap` is **32 standing error stops**. Its reason: each holds
its Process, the stack (one malloc'ed segment, 512 KiB reserved at the
apps' 65 536 words, the pages it touched resident), its frames' Contexts
(at most 256) and the exception; measured at about 16 to 18 KB each of
physical footprint (below), so a full cap is about 0.5 MB, and 32 is more
stops than a developer reads before acting while it bounds a loop that
fails every frame to half a second of them. `Debugger stop:ifFull:`
decides under the table's lock: past the cap the error is reported and
the Process ended as in a batch host (`UnhandledError>>reportAndEnd`),
the refusal counted (`Debugger refusedStops`, a host reads it as
telemetry) and written on the Transcript: `Process N not stopped: 32 stops
stand (Debugger stopCap); reported and ended (K refused so far)`. Step and
suspend stops are a client's own doing and are not refused (they count
toward the 32 a later error sees). Test
`stopsAreCappedAndPastTheCapReportedAndEnded` fills it with 40 failing
Processes: 32 stand, 8 are refused with 8 reports and 8 refusal lines, a
further one is refused too and the 32 stay.

`Transcript showLine:` is new: the line and its end in one transcript
event. `show:` then `cr` is two steps and the reports of 40 Processes
failing at once came out merged into each other's lines (the test found
it); the debugger's and the reports' lines use it.

### A sign

With no client the console line exists (`Process N stopped (error): ...`
on the Transcript, which an app writes to standard output; the runner's
line for a stopped `open`). Whether a development app also shows a
standing stop in its window (the pairing screen, a badge) is left to the
owner (question 2); no new UI was built.

### Saved images

A snapshot taken with stops standing holds them: 8c saves the stopped
Processes waiting on their DebugStop's Semaphore with the `Debugger`
table, and the resumed image lists them (`aSavedImageKeepsItsStops`: a
stop saved by `ShellVM.snapshot`, the image resumed in a serving
`DevTarget`, `process.list` names it, the method defined, the send
retried, the result 42). The saved summary is the one made at park; a
batch host that resumes such an image leaves them waiting (`kajo run`
runs until it is quiescent and ends).

## 2. The author mark as a pragma

**The form**: `<author: #'agent:<name>'>`, one keyword pragma with a
Symbol argument, on a line of its own after the message pattern and the
comment and pragmas that follow it, before the temporaries:

```
{ #category : #accessing }
SampleCounter >> reset [
	<author: #'agent:claude'>
	count := 0
]
```

**Who writes it**: `DevSession>>methodCompile:...` compiles
`TonelWriter source: (TonelWriter canonicalSource: source) author:
client`. The rule, one a person reading `git diff` can predict:

- **An agent's compile** (`agent:<name>`) leaves exactly one author
  pragma, its own: any `<author: ...>` in the source (another agent's,
  its own, before or after the temporaries) is taken out, the line going
  with it when nothing else is on it, and its own is put in at the place
  above. Compiling the same source again changes nothing.
- **A developer's compile** (`developer`) is the source as written: a
  mark the developer kept stays, one they deleted is gone, none is added.
  So a developer editing an agent's method in the browser sees the mark in
  the source and decides.
- A source the scanner cannot read is compiled as it is (the compiler
  says why).

`DevelopmentTest>>testAnAgentsAuthorMarkIsOnePragma` holds each case. So
the image's source and the file agree byte for byte: the mark is in the
recorded source.

**Reading it**: `Smalltalk authorOfSelector:in:` reads the method's
`author:` pragma (the `authors` table, `noteAuthor:of:in:` and the image
build's author line are gone); `method.source`'s `author` and the
browser's status line come from it, and the browser shows the pragma in
the source as any pragma. "The methods an agent wrote" is `Pragma
allNamed: #author:` (the pragma index, no new table). `Pragma
consumesPragmas` declares `author:`. Both compilers compile it as any
pragma; `DevelopmentTest>>authorMarkSample` carries one so
`CompilerTest`'s comparison of every method of the image covers it.

**The metadata key goes**: `TonelWriter` writes `{ #category : ... }`
only; both readers (`Tonel.swift`'s and `TonelReader`) read the metadata
for its category and **read and ignore any other key**, `#author`
included, as Pharo's Tonel does a key it does not know; the next write
leaves it out. `TonelMethod.author`, the build's author line in
`recordSources:` (now `Class\nselector\ncategory\npackage\nsource`) and the
loader's notes are gone. The one file that carried the key, the project
fixture's `SampleCounter.class.st`, was rewritten in its own commit
(f7a760c); nothing under `kernel/`, `tools/` or `apps/` carried it.
`aSessionsProjectRebuildsTheImageItEdited` still finds every method the
same bytecode for bytecode and source for source, authors included,
`theProjectWrittenOutIsTheProjectByteForByte` and the kernel's and tools'
byte-identity tests hold.

## 3. A cut-off unwinding is never silent

**What 9b had**: `Process>>terminate` of another Process interrupted it
to run `terminateUnwinding`, waited at most about `Process
unwindBudgetMs` (1000 one-millisecond Delays) and then ended it where it
stood (`primTerminate`), answering nothing about it; the debugger's
terminate made the stopped Process unwind itself with no bound at all (it
replied `true` first), and restart and retry replied before their
unwinding ran. `process.terminate` answered `isTerminated`.

**Built**:

- `Process>>terminate` answers whether the unwinding ran to its end;
  `terminateReporting` answers `true` or the cut-off's description;
  `awaitUnwinding` is the bounded wait both use.
- `terminateUnwinding` and `Context>>restartSendWith:afterUnwinding:`
  note the unwind block they are about to run (`Unwinding note:for:`), so
  the waiting Process can say where the unwinding stood.
- A cut-off is counted (`Unwinding cutOffCount`, telemetry) and written on
  the Transcript: `Process N terminated: its unwinding was cut off after
  1000 ms [] in AnswersSample>>guarded (K cut off so far)`, or `before its
  first unwind block` when it had not started (a main-affine Process no
  turn reached).
- `process.terminate` answers `{process, unwound}` and, when cut off,
  `cutOff` with that description, for a stopped Process and any other.
- **The debugger's terminate** now uses the same bound: the request's
  Process queues the command, the stopped Process unwinds itself on its
  own stack, and the request's Process waits as `terminate` does
  (`DebugStop>>terminate`), so an ensure block that never ends no longer
  holds a debugged Process forever.
- **Restart and retry** unwind the frames above in the stopped Process
  and do not end it, so there is nothing to cut off; their answer now
  comes after the unwinding (`DebugStop>>await:arguments:`): `{unwound:
  true}`, or past the same bound `{unwound: false, cutOff: "Process N has
  not finished unwinding after 1000 ms: [] in ..."}` with the same
  Transcript line; the Process keeps running that block, where
  `process.suspend` and `process.terminate` reach it. Not counted as a
  cut-off (a deviation, below).
- The debugger's window says it in its status line (`terminated; Process
  N terminated: its unwinding was cut off ...`, `DebuggerModel
  unwindingOf:`).

Tests: `DevelopmentTest>>testTerminateEndsAProcessWhoseUnwindBlockHangs`
(terminate answers false, the count rises by one, the block's
description), the running and waiting cases answer true;
`aCutOffUnwindingIsReportedThroughTheProtocol` (a stopped Process and a
waiting one with a hanging ensure block cut off, reported, counted twice;
one whose blocks end unwound; a restart through a hanging block answers
where it stands and counts nothing).

## Measurements

### The memory a standing stop holds, the cost of a full cap

Mac mini (M2 Pro, macOS 27, swift.org 6.4.2), 2026-11-07, release build
with `-enable-testing` (`KAJO_MEASURE=1 swift test -c release -Xswiftc
-enable-testing --scratch-path .build/release-tests --filter
standingStopsMeasured`, `measure/stops-memory.txt`): a VM of its own per
round, a full collection, the process's physical footprint, 32 forked
Processes stopping at a doesNotUnderstand: (the cap), a full collection,
the footprint again.

| round | footprint for 32 stops | per stop | fill (fork to 32 standing) | one error past the cap, to its report and end |
|--:|--:|--:|--:|--:|
| 1 | 1248 KB | 39 KB | 2.32 ms | 2.28 ms |
| 2 | 576 KB | 18 KB | 2.29 ms | 2.28 ms |
| 3 | 528 KB | 16 KB | 2.29 ms | 2.28 ms |
| 4 | 544 KB | 17 KB | 2.28 ms | 2.28 ms |
| 5 | 528 KB | 16 KB | 2.29 ms | 2.28 ms |

About 16 to 18 KB a stop once warm (the first round pays first-use
growth); a full cap about half a megabyte. The times are bounded by the
probe's polling (2 ms) and the refused error's own 1 ms Delays: a full
cap costs nothing measurable in time, and a stop costs nothing while it
stands (it waits on a Semaphore).

### Frames with a stopped event loop and no client

`mode=scenario scenario=idle debugstop=noclient stops=0|31 seconds=10
after=5 warmup=1 workers=5`: at the window's start a frame handler fails
once (the loop hands itself over, the old loop's Process stands stopped
with nobody connected; `stops=31` adds 31 background Processes that stop
the same way, a full cap); after 10 s the shell starts serving on
loopback and a client thread opens a session (its answer lists the
stops), reads the old loop's frames and proceeds it; frames are counted
in the stopped window (serving's start excluded) and for the 5 s after
the proceed. Three launches of each, interleaved.

**Mac mini**, its 120 Hz display, 2026-11-07, thermal nominal
(`measure/mac-noclient.txt`):

| stops | run | stopped window: frames, missed, max gap | after the proceed: frames, missed | session lists | loop frames | open, frames, proceed ms | whole run missed |
|--:|--:|---|---|--:|--:|---|--:|
| 1 | 1 | 1266 of 1266, 0, 8.4 ms | 523 of 523, 0 | 1 | 11 | 10.1, 73.1, 2.1 | 0 |
| 32 | 1 | 1267 of 1266, 0, 8.4 ms | 520 of 521, 0 | 32 | 11 | 17.0, 85.4, 1.1 | 0 |
| 1 | 2 | 1266 of 1266, 0, 8.4 ms | 518 of 519, 0 | 1 | 11 | 14.9, 101.8, 5.3 | 1 |
| 32 | 2 | 1266 of 1266, 0, 8.4 ms | 525 of 525, 0 | 32 | 11 | 11.7, 56.5, 0.5 | 1 |
| 1 | 3 | 1266 of 1266, 0, 8.4 ms | 523 of 523, 0 | 1 | 11 | 11.5, 71.5, 0.5 | 1 |
| 32 | 3 | 1266 of 1266, 0, 8.3 ms | 523 of 523, 0 | 32 | 11 | 15.0, 69.7, 0.5 | 0 |

**iPhone 13 Pro** (iOS, 120 Hz), 2026-11-07, `scripts/device.sh run`,
thermal nominal at the start and end of every launch, workers at QoS
user-initiated (`measure/iphone-noclient.txt`); the first row repeated at
the end:

| stops | run | stopped window: frames, missed, max gap | after the proceed: frames, missed | session lists | open, frames, proceed ms | whole run missed |
|--:|--:|---|---|--:|---|--:|
| 1 | 1 | 1266 of 1265, 0, 8.4 ms | 513 of 513, 0 | 1 | 23.2, 136.8, 5.9 | 1 |
| 32 | 1 | 1266 of 1266, 0, 8.4 ms | 514 of 514, 0 | 32 | 30.0, 121.1, 2.2 | 1 |
| 1 | 2 | 1266 of 1266, 0, 8.3 ms | 512 of 512, 0 | 1 | 26.1, 140.4, 5.3 | 0 |
| 32 | 2 | 1266 of 1266, 0, 8.4 ms | 514 of 514, 0 | 32 | 30.3, 121.5, 1.9 | 1 |
| 1 | 3 | 1266 of 1266, 0, 8.4 ms | 512 of 513, 0 | 1 | 23.5, 135.7, 2.6 | 1 |
| 32 | 3 | 1266 of 1266, 0, 8.4 ms | 514 of 514, 0 | 32 | 30.1, 121.8, 1.3 | 1 |
| 1 | 4 (repeat) | 1266 of 1266, 0, 8.4 ms | 513 of 513, 0 | 1 | 23.5, 137.4, 1.4 | 0 |

In every launch on both machines the old loop handed over once
(`hand_overs=1`), the new loop kept the window drawing, no frame was
missed in the 10 s with the loop stopped and nobody connected, the
session's answer found the stopped loop (and the 31 others with a full
cap), its 11 frames were read, the proceed let it finish its event and
end (`loop_ended=1`), and no frame was missed in the 5 s after. The one
frame the whole run missed in some launches falls between the two
windows, where the shell starts serving: `startServing` turns the main
worker for `DevProtocol start` on the main thread (9b's code, outside
this measurement's windows). A full cap changed nothing in the frames;
the session's answer with 32 summaries took 17 against 10 to 15 ms on the
Mac and 30 against 23 to 26 ms on the phone. The iPad was not run (the
brief asks for the Mac and the iPhone).

## Changes to earlier modules

- **9a**: `ShellVM.stopsForDebugger`, `Headless.Options.stopsForDebugger`,
  the bridge's setting, primitive 165; `openProtocol` turns the setting
  on.
- **9b**: unhandled errors stop by the host's setting, not by the
  protocol serving (`Debugger enable`/`disable`/`isEnabled` removed);
  the stop cap; `session.open`'s `stopped`; the summary made at park;
  `process.terminate`, `process.restart` and `process.retrySend` answer
  `{process, unwound[, cutOff]}` (they answered `true`/`isTerminated`);
  the debugger's terminate is bounded; author marks are pragmas.
- **8b**: `recordSources:`'s records lose the author line; `Pragma
  consumesPragmas` declares `author:`; `Transcript showLine:`;
  `UnhandledError>>reportAndEnd`.
- **8e**: the Tonel writer writes the category only; both readers ignore
  every other key.
- **9c**: `UIEventLoop dispatch:` hands over when `Debugger canStop`;
  `DevTools` opens debuggers for the stops a session's answer lists;
  `DebuggerModel` says a cut-off.
- **11a**: `KajoAppRunner.start` sets the setting for a development
  build and stops waiting for a stopped `open`.
- The shells: `debugstop=noclient` (with `stops=`, `after=`), the
  scenario's setting.
- **An older test's bound**: 9d's
  `PhoneTransportTests>>theServerServesTCPWithTheTokenRuleAndTheLimits`
  waited 10 s (120 under ThreadSanitizer) for the listener's report that
  its pause ended; in the first gate run under twelve busy loops without
  the sanitizer the report, run on a global queue, came later and the
  test failed (`run1/gate-swift-test-load.txt`). The wait is for the
  report, not a bound on its speed, so it is 120 s everywhere now
  (f6024a3); the assertion is unchanged, and the gates ran again from the
  start on that commit.

## Deviations from the brief

- **The setting is turned on by serving as well** (`ShellVM.openProtocol`),
  besides the hosts setting it before the resume: a host that serves is
  one a debugger can come to, and the 9c test shell, which serves without
  going through a mode, would otherwise have reported its tools' errors.
  It is still one setting, made by the host, never read from a socket.
- **A later client learns of standing stops from session.open's answer**,
  not from `process.stopped` events replayed to it (the reason above).
- **Restart and retry are bounded in their answer, not cut off**: they do
  not end the Process, so the brief's "report the same way" is the same
  answer field (`unwound`, `cutOff`) and Transcript line, but not the
  cut-off count. A Process stuck in an unwind block during a restart is
  reached by `process.terminate`, which is bounded and counts.
- **Step and suspend stops are not refused at the cap** (a client asked
  for them); they count toward it.

## Tests

Swift: `KajoCompilerTests` 112 (one of them the measurement, skipped
without `KAJO_MEASURE`) against 100 at the start:
`DevelopmentAnswersTests` 11 (four batch hosts, a release image, a stop
found by a later client, an app's start-up, the event loop with no
client, the cap, a saved image, a cut-off through the protocol) and
`standingStopsMeasured` (`KAJO_MEASURE=1` only); `DevProtocolTests` and
`AgentInterfaceTests` read the pragma. `KajoVMTests` 369 as at the start.
Smalltalk: 205 kernel tests (204 at the start; `DevelopmentTest` 14:
`testAnAgentsAuthorMarkIsOnePragma` new, the author marks, terminate's
answers and the cut-off); the tools' `ToolWindowTest` one more.

## Broken variants run by hand

Each run on the final code with one rule broken, then put back
(`broken/`).

| rule | broken variant | test | result |
|---|---|---|---|
| a batch host never stops | `Debugger stopsErrors` answers true in any development image | the four batch-host tests | fail: `kajo test` errors its test (the forked Process stood stopped, `forkFailureAndWait` timed out after its 10 000 Delays); `kajo run` and the image build's host never end and fail at the 120 s bound; the default shell VM's Process stands stopped (`batch-host-stops.log`) |
| the stops are capped | `stop:ifFull:` never finds the table full | `stopsAreCappedAndPastTheCapReportedAndEnded` | fails: 40 stops stand, none refused, no refusal line, and the further error stands stopped too (`cap-removed.log`) |
| a cut-off is never silent | `awaitUnwinding` ends the Process and answers true, uncounted | `aCutOffUnwindingIsReportedThroughTheProtocol`, `DevelopmentTest>>testTerminateEndsAProcessWhoseUnwindBlockHangs` | fail: the protocol answers `unwound: true` with no `cutOff`, no Transcript line, the count unchanged (8 issues); the kernel test's `deny: p terminate` fails (`silent-cutoff.log`, `silent-cutoff-kernel.log`) |

## Unsafe surface

No `unsafe` site added or removed under `Sources/KajoVM` (the setting is
an `Atomic<Bool>` in the bridge, read by a primitive through the bridge
the shell primitives already reach). The measurement test reads the
footprint with `task_info` (test code, not under strict memory safety).

## Hot-path check and A/B

The VM core changed only outside the interpreter: a field of
`Headless.Options`, the bridge's `Atomic<Bool>`, `ShellVM`'s accessor and
`openProtocol`, and primitive 165 in `shellPrimitive`, reached through
`primitive`'s switch (`case 150...154, 159...161, 164, 165`). Why in the
VM at all: the setting must exist before the image resumes and be read by
any worker, and a value the image held would be saved with it and read by
the next host (a batch host resuming a development host's snapshot would
stop).

**Disassembly** of the starting commit's (7bf1807, from a worktree) and
this commit's (87e63fa) `kajo`, both `-c release -Xswiftc
-enable-testing` with `-align-all-nofallthru-blocks=5 -align-loops=32`,
addresses normalized (`ab/disasm/`, `ab/fn.py`): `interpret` 1320
instructions in both, four `adrp` page numbers differ (the code after it
moved), nothing else; `pollAtJump` 120, `pollAndSend` 319, `lookupMiss`
28 and `primitiveSend` 429 identical instruction for instruction;
`primitive` 328 against 304: the compiler turned the range tests for
primitives 145 to 165 (bit masks) into a byte jump table once 165 joined
the shell's range; no kernel's fast path reaches that part of the switch.
`just arc-check` is in Gates.

**The kernels**, five runs interleaved, `--slice-ms 0`, 2026-11-07 03:02
to 03:07 (load average 2.3 to 2.7), median (min to max) ms, every
checksum the published one on both sides (`ab/bench-ab.txt`):

| kernel | workers | 7bf1807 ms | answers ms | ratio | checksum |
|---|--:|--:|--:|--:|---|
| alloc | 1 | 2980.5 (2972 to 2997) | 2954.1 (2951 to 2982) | **0.991** | 41950911 |
| alloc | 8 | 487.0 (479 to 502) | 487.3 (477 to 491) | **1.001** | 42008248 |
| arith | 1 | 2552.4 (2550 to 2558) | 2537.9 (2534 to 2538) | **0.994** | 372800000 |
| arith | 8 | 351.2 (346 to 353) | 345.5 (344 to 346) | **0.984** | 372800000 |
| fib | 1 | 1691.1 (1691 to 1697) | 1701.1 (1697 to 1703) | **1.006** | 24682992 |
| fib | 8 | 218.6 (217 to 222) | 219.7 (218 to 224) | **1.005** | 24682992 |
| ivars | 1 | 1972.0 (1969 to 1979) | 1965.0 (1963 to 1969) | **0.996** | 36383626 |
| ivars | 8 | 278.1 (276 to 280) | 261.5 (259 to 264) | **0.940** | 71714128 |
| sends | 1 | 2610.0 (2606 to 2614) | 2619.6 (2611 to 2623) | **1.004** | 1066666666666668 |
| sends | 8 | 335.6 (335 to 344) | 362.3 (360 to 367) | **1.080** | 133333335000001 |
| storeheavy | 1 | 2397.9 (2394 to 2402) | 2411.6 (2409 to 2412) | **1.006** | 512000 |
| storeheavy | 8 | 315.1 (314 to 320) | 309.2 (308 to 317) | **0.981** | 512000 |
| Smalltalk closures | 1 | 3789.6 (3787 to 3796) | 3817.2 (3811 to 3820) | **1.007** | 210210000 |
| Smalltalk closures | 8 | 521.3 (514 to 522) | 498.4 (490 to 502) | **0.956** | 209214000 |
| Smalltalk ivars | 1 | 1966.4 (1964 to 1969) | 1967.7 (1964 to 1975) | **1.001** | 36383626 |
| Smalltalk ivars | 8 | 270.0 (267 to 274) | 253.8 (252 to 256) | **0.940** | 71714128 |
| Smalltalk sends | 1 | 2296.0 (2276 to 2304) | 2327.1 (2313 to 2342) | **1.014** | 1066666666666668 |
| Smalltalk sends | 8 | 300.3 (294 to 304) | 317.7 (316 to 319) | **1.058** | 133333335000001 |

One worker: 0.991 to 1.014 (Smalltalk sends 2276 to 2304 against 2313 to
2342, the one range that does not overlap). Eight workers: 0.940 to 1.080;
`sends` on eight (335 to 344 against 360 to 367) was run again, ten runs
interleaved at 03:07 (`ab/bench-ab-sends8.txt`): 347.8 (336 to 368)
against 347.2 (337 to 362), **0.999**. With `interpret` and the send paths
identical, the spread on eight workers both ways is the runs', and by
AGENTS.md's rule the one-worker 1.4 percent on Smalltalk sends is the
link's placement, not code.

## Not done

- No new UI for a standing stop with no client (question 2).
- The iPad rows.
- Stopped Processes with no client hold their stacks until a client
  comes or the app ends; nothing ages them out (the cap bounds them).
- Restart's unwinding is not counted as a cut-off (deviation).

## Open questions for the owner

1. **The cap**: 32 standing error stops, about half a megabyte; past it
   errors are reported and ended. Right number, and should step and
   suspend stops be refused too?
2. **A sign with no client**: the console line exists. Should a
   development app show a standing stop in its window (a badge on the
   pairing screen, the status line), and how?
3. **The author rule**: an agent's compile replaces any author pragma with
   its own; a developer's compiles the source as written (a mark the
   developer leaves stays). Or should a developer's edit of an agent's
   method drop the mark?
4. **Standing stops at connect**: listed in `session.open`'s answer and the
   tools open a debugger for each (up to 32 windows). Keep, or open one
   and list the rest?
5. **Restart's unwinding**: answered after the walk, bounded at 1 s in
   the answer, not cut off. Should a restart that cannot finish its
   unwinding end the Process instead?

## Gates

Every gate ran on **f6024a3** (the last commit that changes code), Mac
mini (M2 Pro), swift.org 6.4.2, 2026-11-07 03:26 to 05:57, every output
in a file and each step logged with its commit (`gates.log`). A first run
on 87e63fa stopped at the second gate: under twelve busy loops 9d's
listener-pause test waited 10 s for a report and failed (`run1/`; the
fix and why under "Changes to earlier modules"); the sequence then ran
again from the start.

| gate | result |
|---|---|
| clean build (`.build/clean-check`) | exit 0, 0 errors, 0 warnings, 20 s (the toolchain's cache) |
| `swift test` | 369 + 112 passed (the measurement skipped), 322 + 99 s |
| under load (12 busy loops) | 369 + 112 passed, 373 + 117 s |
| ThreadSanitizer | 369 + 112 passed, 0 reports, 553 + 2456 s |
| ThreadSanitizer under load | 369 + 112 passed, 0 reports, 716 + 3037 s (the loops kept at twelve throughout) |
| `just ios-check` | exit 0, 0 errors, 0 warnings |
| `just arc-check` | OK: no retain or release on the checked paths, `interpret` 1056 instructions, one indirect branch and one jump table |
| `just golden` | 12 of 12 checksums |
| `just test-release` | 369 + 112 passed |
| `just model-check` | 28 + 5 + 15 passed |
| `just soak` | passed: 1000 seeds under every configuration, no failing seed; the snapshot modes saving 908 to 995 of 1000 |
| `just fuzz kasm 600` | libFuzzer build ok, 2.05 million runs, no crash |
| `just fuzz snapshot 600` | libFuzzer build ok, 2.99 million runs, no crash |
| `just fuzz syntax 600` | libFuzzer build ok, 0.92 million runs, no crash |
| `just fuzz protocol 600` | libFuzzer build ok, 1.54 million runs, no crash |
| `just apps` | macOS and iOS: exit 0, 0 errors, 0 warnings |
| `just kernel-test` | 205 of 205 passed |
| `just new-check` | ok: both targets in both configurations, 0 errors, 0 warnings; the Release products without the protocol |

The four fuzzers ran at the same time, one core each. The A/B and the
disassembly were taken on 87e63fa; f6024a3 changes only that test.

## Commands

```zsh
just mac-shell run out.txt mode=scenario scenario=idle debugstop=noclient stops=31 seconds=10 after=5
scripts/device.sh run out.txt mode=scenario scenario=idle debugstop=noclient stops=0 seconds=10 after=5 workers=5
KAJO_MEASURE=1 swift test -c release -Xswiftc -enable-testing --scratch-path .build/release-tests --filter standingStopsMeasured
swift test --filter DevelopmentAnswersTests
```
